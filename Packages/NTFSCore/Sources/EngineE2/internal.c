/* SPDX-License-Identifier: GPL-2.0-only */
/* Private TT types stay in this translation unit, not the bridge ABI. */
#define ntfs_attr tt_internal_attr
#define ntfs_getattr tt_internal_getattr
#define ntfs_setattr tt_internal_setattr
#include "ntfs.h"
#include "attrib.h"
#include "runlist.h"
#include "mft.h"
#include <linux/pagemap.h>
#include <ntfsport/bdev.h>
#undef ntfs_attr
#undef ntfs_getattr
#undef ntfs_setattr
#undef ntfs_bdev_write
#include <ntfscore.h>
#include "engine_e2.h"

int e2_resident(ntfs_inode_t *h) { return !NInoNonResident(NTFS_I((struct inode *)h)); }

/* Caller holds i_rwsem exclusive and mrec_lock. No data is zeroed here. */
static int set_sizes(struct ntfs_inode *ni, uint64_t data, uint64_t initialized)
{
    struct ntfs_attr_search_ctx *ctx = ntfs_attr_get_search_ctx(ni, NULL);
    if (!ctx) return -ENOMEM;
    int err = ntfs_attr_lookup(ni->type, ni->name, ni->name_len, CASE_SENSITIVE, 0, NULL, 0, ctx);
    if (!err) {
        ctx->attr->data.non_resident.data_size = cpu_to_le64(data);
        ctx->attr->data.non_resident.initialized_size = cpu_to_le64(initialized);
        write_lock(&ni->size_lock);
        ni->data_size = data;
        ni->initialized_size = initialized;
        i_size_write(VFS_I(ni), data);
        write_unlock(&ni->size_lock);
        mark_mft_record_dirty(ctx->ntfs_ino);
    }
    ntfs_attr_put_search_ctx(ctx);
    return err;
}

int e2_prepare(ntfs_inode_t *h, uint64_t off, uint64_t len)
{
    struct inode *vi = (struct inode *)h;
    struct ntfs_inode *ni = NTFS_I(vi);
    if (off > INT64_MAX || len > (uint64_t)INT64_MAX - off) return EFBIG;
    inode_lock(vi);
    int err = 0;
    if (!NInoNonResident(ni) || NInoCompressed(ni) || NInoEncrypted(ni)) { err = -ENOTSUP; goto done; }
    if (!len) goto done;
    if (!(ni->vol->vol_flags & VOLUME_IS_DIRTY)) {
        err = ntfs_set_volume_flags(ni->vol, VOLUME_IS_DIRTY);
        if (err) goto done;
    }
    uint64_t old_data = ni->data_size, old_init = ni->initialized_size;
    if (off + len > (uint64_t)ni->allocated_size) {
        mutex_lock(&ni->mrec_lock);
        err = ntfs_attr_expand(ni, off + len, 0);
        /* Expansion may change EOF; allocation must not publish the raw I/O. */
        int restore = set_sizes(ni, old_data, old_init);
        mutex_unlock(&ni->mrec_lock);
        if (!err) err = restore;
        if (err) goto done;
    }
    uint64_t cluster = ni->vol->cluster_size;
    s64 vcn = off / cluster, end = (off + len - 1) / cluster + 1;
    while (vcn < end) {
        s64 lcn, count;
        bool allocated;
        mutex_lock(&ni->mrec_lock);
        down_write(&ni->runlist.lock);
        err = ntfs_attr_map_cluster(ni, vcn, &lcn, &count, end - vcn, &allocated, true, false);
        up_write(&ni->runlist.lock);
        mutex_unlock(&ni->mrec_lock);
        if (err) break;
        if (count <= 0 || lcn < 0) { err = -EIO; break; }
        vcn += count;
    }
done:
    inode_unlock(vi);
    return err < 0 ? -err : err;
}

/* Zero only the valid-data gap, preserving already-written sector edge bytes.
 * The page-cache zero helper is unsuitable here: a cached UNINIT page contains
 * zeros and flushing it would overwrite the kernel's new bytes in that page. */
static int zero_gap(struct ntfs_inode *ni, uint64_t start, uint64_t end)
{
    static const unsigned char zero[4096] = {0};
    unsigned char edge[4096];
    struct ntfs_bdev *dev = ni->vol->sb->s_bdev;
    uint64_t cluster = ni->vol->cluster_size, sector = dev->logical_block_size;
    while (start < end) {
        down_write(&ni->runlist.lock);
        struct runlist_element *run = ntfs_attr_find_vcn_nolock(ni, start / cluster, NULL);
        if (IS_ERR(run)) { int err = (int)PTR_ERR(run); up_write(&ni->runlist.lock); return err; }
        uint64_t next = min_t(uint64_t, end, (run->vcn + run->length) * cluster);
        s64 lcn = run->lcn;
        uint64_t physical = lcn < 0 ? 0 : (uint64_t)lcn * cluster + start - (uint64_t)run->vcn * cluster;
        up_write(&ni->runlist.lock);
        if (next <= start) return -EIO;
        if (lcn == LCN_HOLE) { start = next; continue; }
        if (lcn < 0) return -EIO;
        while (start < next) {
            size_t n;
            int err;
            size_t edge_off = physical % sector;
            if (edge_off || next - start < sector) {
                uint64_t aligned = physical - edge_off;
                n = min_t(uint64_t, sector - edge_off, next - start);
                err = ntfs_bdev_read(dev, edge, aligned, sector);
                if (err) return err;
                memset(edge + edge_off, 0, n);
                err = ntfs_bdev_write(dev, edge, aligned, sector);
            } else {
                n = min_t(uint64_t, sizeof(zero), round_down(next - start, sector));
                err = ntfs_bdev_write(dev, zero, physical, n);
            }
            if (err) return err;
            physical += n;
            start += n;
        }
    }
    return 0;
}

int e2_finish(ntfs_inode_t *h, uint64_t off, uint64_t len)
{
    struct inode *vi = (struct inode *)h;
    struct ntfs_inode *ni = NTFS_I(vi);
    if (off > INT64_MAX || len > (uint64_t)INT64_MAX - off) return EFBIG;
    inode_lock(vi);
    int err = 0;
    if (!NInoNonResident(ni) || NInoCompressed(ni) || NInoEncrypted(ni)) { err = -ENOTSUP; goto done; }
    if (!len) goto done;
    if (off + len > (uint64_t)ni->allocated_size) { err = -EINVAL; goto done; }
    uint64_t first = min_t(uint64_t, off, ni->initialized_size);
    err = invalidate_inode_pages2_range(vi->i_mapping, first / PAGE_SIZE, (off + len - 1) / PAGE_SIZE);
    if (err) goto done;
    if (off > (uint64_t)ni->initialized_size) err = zero_gap(ni, ni->initialized_size, off);
    /* Both raw payload and gap zeros must reach the device before VDL changes. */
    if (!err) err = ntfs_bdev_flush(ni->vol->sb->s_bdev);
    if (err) goto done;
    mutex_lock(&ni->mrec_lock);
    err = set_sizes(ni, max_t(uint64_t, ni->data_size, off + len), max_t(uint64_t, ni->initialized_size, off + len));
    mutex_unlock(&ni->mrec_lock);
    if (!err) {
        inode_set_mtime_to_ts(vi, inode_set_ctime_current(vi));
        NInoSetFileNameDirty(ni);
        mark_inode_dirty(vi);
    }
done:
    inode_unlock(vi);
    return err < 0 ? -err : err;
}

int e2_map(ntfs_inode_t *h, uint64_t off, uint64_t len, int for_write, nb_extent *out, size_t cap, size_t *count)
{
    struct inode *vi = (struct inode *)h;
    struct ntfs_inode *ni = NTFS_I(vi);
    uint64_t end, pos = off, cluster = ni->vol->cluster_size;
    size_t used = 0;
    int err = 0;
    *count = 0;
    if (len > UINT64_MAX - off) return EINVAL;
    if (!NInoNonResident(ni) || NInoCompressed(ni) || NInoEncrypted(ni)) return ENOTSUP;
    inode_lock_shared(vi);
    if (off > (uint64_t)ni->allocated_size || len > (uint64_t)ni->allocated_size - off) { err = EINVAL; goto done; }
    end = off + len;
    while (pos < end) {
        struct runlist_element *run;
        down_write(&ni->runlist.lock);
        run = ntfs_attr_find_vcn_nolock(ni, pos / cluster, NULL);
        if (IS_ERR(run)) { err = (int)-PTR_ERR(run); up_write(&ni->runlist.lock); break; }
        uint64_t run_end = (uint64_t)(run->vcn + run->length) * cluster;
        uint64_t next = run_end < end ? run_end : end;
        uint32_t kind = run->lcn == LCN_HOLE ? NB_EXT_HOLE : NB_EXT_DATA;
        if (run->lcn < 0 && run->lcn != LCN_HOLE) { err = EIO; up_write(&ni->runlist.lock); break; }
        uint64_t initialized = ni->initialized_size;
        if (kind == NB_EXT_DATA && pos >= initialized && (for_write || pos < (uint64_t)ni->data_size)) kind = NB_EXT_UNINIT;
        if (pos < initialized && initialized < next && (for_write || initialized < (uint64_t)ni->data_size)) next = initialized;
        if (used == cap) { err = ENOBUFS; up_write(&ni->runlist.lock); break; }
        out[used++] = (nb_extent){ .logical = pos,
            .physical = run->lcn < 0 ? 0 : (uint64_t)run->lcn * cluster + pos - (uint64_t)run->vcn * cluster,
            .length = next - pos, .kind = kind };
        up_write(&ni->runlist.lock);
        if (next <= pos) { err = EIO; break; }
        pos = next;
    }
done:
    inode_unlock_shared(vi);
    *count = used;
    return err;
}
