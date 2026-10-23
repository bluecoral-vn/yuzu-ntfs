/* SPDX-License-Identifier: GPL-2.0-only */
#include "engine_e2.h"
#include <ntfscore.h>
#include <ntfsport/bdev.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>

int e2_resident(ntfs_inode_t *);
int e2_map(ntfs_inode_t *, uint64_t, uint64_t, int, nb_extent *, size_t, size_t *);
int e2_prepare(ntfs_inode_t *, uint64_t, uint64_t);
int e2_finish(ntfs_inode_t *, uint64_t, uint64_t);
struct stream { uint64_t ref, base; char *name; struct stream *next; };
struct nb_volume {
    nb_blockdev dev;
    struct ntfs_bdev bdev;
    ntfs_volume_t *core;
    uint64_t root;
    struct stream *streams;
    pthread_mutex_t lock;
};
static int positive(int rc) { return rc < 0 ? -rc : rc; }
static ssize_t device_read(struct ntfs_bdev *b, void *buf, size_t n, uint64_t off) {
    nb_volume *v = b->priv;
    int rc = v->dev.read(v->dev.ctx, off, buf, n);
    return rc ? -positive(rc) : (ssize_t)n;
}
static ssize_t device_write(struct ntfs_bdev *b, const void *buf, size_t n, uint64_t off) {
    nb_volume *v = b->priv;
    if (b->read_only || !v->dev.write) return -EROFS;
    int rc = v->dev.write(v->dev.ctx, off, buf, n);
    return rc ? -positive(rc) : (ssize_t)n;
}
static int device_flush(struct ntfs_bdev *b) {
    nb_volume *v = b->priv;
    return v->dev.flush ? -positive(v->dev.flush(v->dev.ctx)) : 0;
}
static const struct ntfs_bdev_ops device_ops = { .pread = device_read, .pwrite = device_write, .flush = device_flush };
static int device_init(nb_volume *v, const nb_blockdev *dev, int rw) {
    if (!dev || !dev->read || !dev->size || (dev->sector_size != 512 && dev->sector_size != 4096)) return EINVAL;
    if (rw && (!dev->write || !dev->flush)) return EROFS;
    v->dev = *dev;
    v->bdev = (struct ntfs_bdev){ .ops = &device_ops, .size_bytes = dev->size,
        .logical_block_size = dev->sector_size, .physical_block_size = dev->sector_size,
        .read_only = !rw, .priv = v };
    return positive(ntfs_bdev_attach_mapping(&v->bdev));
}
/* Strict UTF-16 decoding preserves normalization and rejects unpaired surrogates. */
static int utf8(const uint16_t *name, size_t len, char out[1021]) {
    if (!name || !len || len > 255) return len > 255 ? ENAMETOOLONG : EINVAL;
    size_t n = 0;
    for (size_t i = 0; i < len; ++i) {
        uint32_t c = name[i];
        if (!c || c == '/') return EINVAL;
        if (c >= 0xd800 && c <= 0xdbff) {
            if (++i == len || name[i] < 0xdc00 || name[i] > 0xdfff) return EILSEQ;
            c = 0x10000 + ((c - 0xd800) << 10) + name[i] - 0xdc00;
        } else if (c >= 0xdc00 && c <= 0xdfff) return EILSEQ;
        if (c < 0x80) out[n++] = c;
        else if (c < 0x800) { out[n++] = 0xc0 | (c >> 6); out[n++] = 0x80 | (c & 63); }
        else if (c < 0x10000) { out[n++] = 0xe0 | (c >> 12); out[n++] = 0x80 | ((c >> 6) & 63); out[n++] = 0x80 | (c & 63); }
        else { out[n++] = 0xf0 | (c >> 18); out[n++] = 0x80 | ((c >> 12) & 63); out[n++] = 0x80 | ((c >> 6) & 63); out[n++] = 0x80 | (c & 63); }
    }
    out[n] = 0;
    return 0;
}
static int utf16(const char *s, size_t len, uint16_t out[255], size_t *n) {
    size_t count = 0;
    for (size_t i = 0; i < len;) {
        uint32_t c = (unsigned char)s[i++], min = 0;
        unsigned more = 0;
        if (c >= 0xf0 && c <= 0xf4) { c &= 7; more = 3; min = 0x10000; }
        else if (c >= 0xe0 && c <= 0xef) { c &= 15; more = 2; min = 0x800; }
        else if (c >= 0xc2 && c <= 0xdf) { c &= 31; more = 1; min = 0x80; }
        else if (c >= 0x80) return EILSEQ;
        while (more--) {
            if (i == len || ((unsigned char)s[i] & 0xc0) != 0x80) return EILSEQ;
            c = (c << 6) | (s[i++] & 63);
        }
        if (c < min || c > 0x10ffff || (c >= 0xd800 && c <= 0xdfff)) return EILSEQ;
        if (count + (c > 0xffff ? 2 : 1) > 255) return ENAMETOOLONG;
        if (c > 0xffff) { c -= 0x10000; out[count++] = 0xd800 | (c >> 10); out[count++] = 0xdc00 | (c & 1023); }
        else out[count++] = c;
    }
    *n = count;
    return 0;
}
static int64_t ticks(struct ntfs_timespec t) { return (t.sec + INT64_C(11644473600)) * INT64_C(10000000) + t.nsec / 100; }
static void attr_out(const struct ntfs_attr *a, uint64_t parent, int resident, nb_attr *out) {
    *out = (nb_attr){ .ref = a->inode_no, .parent_ref = parent, .size = a->size, .alloc_size = a->alloc_size,
        .type = a->type == NTFS_ITEM_DIR ? NB_DIR : a->type == NTFS_ITEM_SYMLINK ? NB_SYMLINK : NB_FILE,
        .ntfs_attrs = a->file_attributes, .nlink = a->nlink,
        .crtime = ticks(a->crtime), .mtime = ticks(a->mtime), .ctime = ticks(a->ctime), .atime = ticks(a->atime),
        .flags = (resident ? NB_RESIDENT : 0) | (a->compressed ? NB_COMPRESSED : 0) | (a->encrypted ? NB_ENCRYPTED : 0) | (a->sparse ? NB_SPARSE : 0) };
}
int nb_e2_mount(const nb_blockdev *dev, int rw, nb_volume **out) {
    if (!out) return EINVAL;
    *out = NULL;
    nb_volume *v = calloc(1, sizeof(*v));
    if (!v) return ENOMEM;
    int rc = device_init(v, dev, rw);
    if (rc) { free(v); return rc; }
    struct ntfs_mount_options opts = { .flags = NTFS_MOUNT_CASE_SENSITIVE | (rw ? 0 : NTFS_MOUNT_RDONLY) };
    rc = positive(ntfs_mount(&v->bdev, &opts, &v->core));
    if (!rc) {
        ntfs_inode_t *root;
        rc = positive(ntfs_volume_root(v->core, &root));
        if (!rc) { v->root = ntfs_inode_number(root); ntfs_inode_put(root); }
    }
    if (rc) {
        if (v->core) ntfs_unmount(v->core);
        ntfs_bdev_detach_mapping(&v->bdev); free(v); return rc;
    }
    rc = pthread_mutex_init(&v->lock, NULL);
    if (rc) { ntfs_unmount(v->core); ntfs_bdev_detach_mapping(&v->bdev); free(v); return rc; }
    *out = v;
    return 0;
}
int nb_e2_unmount(nb_volume *v) {
    if (!v) return EINVAL;
    int rc = positive(ntfs_unmount(v->core));
    ntfs_bdev_detach_mapping(&v->bdev);
    while (v->streams) { struct stream *s = v->streams; v->streams = s->next; free(s->name); free(s); }
    pthread_mutex_destroy(&v->lock);
    free(v);
    return rc;
}
int nb_e2_probe_state(const nb_blockdev *dev, nb_state *out) {
    if (!out) return EINVAL;
    *out = NB_UNSUPPORTED;
    nb_volume v = {0};
    int rc = device_init(&v, dev, 0);
    if (rc) return rc;
    unsigned char signature[11];
    rc = positive(dev->read(dev->ctx, 0, signature, sizeof(signature)));
    if (!rc && !memcmp(signature + 3, "-FVE-FS-", 8)) { *out = NB_BITLOCKER; ntfs_bdev_detach_mapping(&v.bdev); return 0; }
    struct ntfs_volume_info info = {0};
    if (!rc) rc = positive(ntfs_probe(&v.bdev, &info));
    ntfs_bdev_detach_mapping(&v.bdev);
    if (!rc) *out = info.hibernated ? NB_HIBERNATED : info.dirty ? NB_DIRTY_FLAG : !info.logfile_clean ? NB_DIRTY_LOG : info.major_ver != 3 ? NB_UNSUPPORTED : NB_CLEAN;
    return rc;
}
uint64_t nb_e2_root_ref(nb_volume *v) { return v ? v->root : 0; }
int nb_e2_lookup(nb_volume *v, uint64_t dir, const uint16_t *name, size_t len, nb_attr *out) {
    if (!v || !out) return EINVAL;
    char text[1021];
    int rc = utf8(name, len, text);
    if (rc) return rc;
    ntfs_inode_t *parent = NULL, *inode = NULL;
    char *stream_name = strchr(text, ':');
    if (stream_name) { *stream_name++ = 0; if (!*stream_name || strchr(stream_name, ':')) return EINVAL; }
    rc = positive(ntfs_inode_get(v->core, dir, &parent));
    if (!rc) rc = positive(ntfs_lookup(parent, text, &inode));
    struct ntfs_attr a;
    if (!rc) rc = positive(ntfs_getattr(inode, &a));
    if (!rc) attr_out(&a, dir, e2_resident(inode), out);
    if (!rc && stream_name) {
        size_t size;
        rc = positive(ntfs_getxattr(inode, stream_name, NULL, 0, &size));
        if (!rc) {
            pthread_mutex_lock(&v->lock);
            struct stream *s;
            for (s = v->streams; s; s = s->next) if (s->base == a.inode_no && !strcmp(s->name, stream_name)) break;
            if (!s) {
                s = calloc(1, sizeof(*s));
                if (s) {
                    s->name = strdup(stream_name);
                    if (!s->name) { free(s); s = NULL; }
                    else { s->base = a.inode_no; s->ref = v->streams ? v->streams->ref + 1 : UINT64_C(1) << 63; s->next = v->streams; v->streams = s; }
                }
            }
            if (!s) rc = ENOMEM;
            else { out->ref = s->ref; out->size = size; out->alloc_size = 0; out->flags = 0; }
            pthread_mutex_unlock(&v->lock);
        }
    }
    ntfs_inode_put(inode); ntfs_inode_put(parent);
    return rc;
}
struct directory_ctx { nb_volume *v; uint64_t parent; nb_dirent_cb cb; void *ctx; int err; int stopped; };
static int directory_entry(const struct ntfs_dirent *ent, void *opaque) {
    struct directory_ctx *c = opaque;
    if ((ent->name_len == 1 && ent->name[0] == '.') || (ent->name_len == 2 && !memcmp(ent->name, "..", 2))) return 0;
    uint16_t units[255]; size_t len;
    c->err = utf16(ent->name, ent->name_len, units, &len);
    if (c->err) return 1;
    if (!ent->has_attr) { c->err = EIO; return 1; }
    ntfs_inode_t *inode;
    c->err = positive(ntfs_inode_get(c->v->core, ent->inode_no, &inode));
    if (c->err) return 1;
    nb_attr attr; attr_out(&ent->attr, c->parent, e2_resident(inode), &attr);
    ntfs_inode_put(inode);
    /* TT's cookie points at this entry. Its scanner resumes at positions >=
     * cookie, so +1 is the first position after the consumed entry. */
    c->stopped = c->cb(c->ctx, units, len, &attr, ent->cookie + 1) != 0;
    return c->stopped;
}
int nb_e2_readdir(nb_volume *v, uint64_t dir, uint64_t cookie, nb_dirent_cb cb, void *ctx) {
    if (!v || !cb) return EINVAL;
    ntfs_inode_t *inode;
    int rc = positive(ntfs_inode_get(v->core, dir, &inode));
    if (rc) return rc;
    struct directory_ctx c = { .v = v, .parent = dir, .cb = cb, .ctx = ctx };
    bool eof;
    rc = positive(ntfs_readdir(inode, &cookie, true, directory_entry, &c, &eof));
    ntfs_inode_put(inode);
    return c.err ? c.err : rc;
}
int nb_e2_read(nb_volume *v, uint64_t ref, uint64_t off, void *buf, size_t len, size_t *got) {
    if (!v || !got || (!buf && len)) return EINVAL;
    *got = 0;
    if (off > INT64_MAX || len > (uint64_t)INT64_MAX - off) return EFBIG;
    if (ref >> 63) {
        pthread_mutex_lock(&v->lock);
        struct stream *s;
        for (s = v->streams; s && s->ref != ref; s = s->next) {}
        if (!s) { pthread_mutex_unlock(&v->lock); return ENOENT; }
        ntfs_inode_t *inode = NULL;
        int rc = positive(ntfs_inode_get(v->core, s->base, &inode));
        size_t size = 0;
        if (!rc) rc = positive(ntfs_getxattr(inode, s->name, NULL, 0, &size));
        if (!rc && off == 0 && len >= size) {
            rc = positive(ntfs_getxattr(inode, s->name, buf, len, &size));
            if (!rc) *got = size;
        } else if (!rc && off < size && len) {
            /* TT exposes ADS as xattrs, not positional streams. */
            void *data = malloc(size);
            if (!data) rc = ENOMEM;
            else {
                rc = positive(ntfs_getxattr(inode, s->name, data, size, &size));
                if (!rc) { *got = len < size - off ? len : size - off; memcpy(buf, (char *)data + off, *got); }
                free(data);
            }
        }
        ntfs_inode_put(inode); pthread_mutex_unlock(&v->lock); return rc;
    }
    ntfs_inode_t *inode;
    int rc = positive(ntfs_inode_get(v->core, ref, &inode));
    if (rc) return rc;
    ssize_t n = ntfs_read(inode, buf, len, off);
    ntfs_inode_put(inode);
    if (n < 0) return (int)-n;
    *got = n; return 0;
}
int nb_e2_create(nb_volume *v, uint64_t dir, const uint16_t *name, size_t len, uint32_t type, nb_attr *out) {
    if (!v || !out) return EINVAL;
    if (type != NB_FILE && type != NB_DIR) return ENOTSUP;
    char text[1021]; int rc = utf8(name, len, text);
    if (rc) return rc;
    ntfs_inode_t *parent = NULL, *inode = NULL;
    rc = positive(ntfs_inode_get(v->core, dir, &parent));
    if (!rc) rc = positive(type == NB_DIR ? ntfs_mkdir(parent, text, 0755, &inode) : ntfs_create(parent, text, 0644, &inode));
    struct ntfs_attr a;
    if (!rc) rc = positive(ntfs_getattr(inode, &a));
    if (!rc) attr_out(&a, dir, e2_resident(inode), out);
    ntfs_inode_put(inode); ntfs_inode_put(parent); return rc;
}
int nb_e2_write(nb_volume *v, uint64_t ref, uint64_t off, const void *buf, size_t len) {
    if (!v || (!buf && len)) return EINVAL;
    if (off > INT64_MAX || len > (uint64_t)INT64_MAX - off) return EFBIG;
    if (ref >> 63) return ENOTSUP;
    ntfs_inode_t *inode; int rc = positive(ntfs_inode_get(v->core, ref, &inode));
    if (rc) return rc;
    size_t done = 0;
    while (done < len) {
        ssize_t n = ntfs_write(inode, (const char *)buf + done, len - done, off + done);
        if (n <= 0) { rc = n < 0 ? (int)-n : EIO; break; }
        done += n;
    }
    ntfs_inode_put(inode); return rc;
}
int nb_e2_truncate(nb_volume *v, uint64_t ref, uint64_t size) {
    if (!v) return EINVAL;
    if (size > INT64_MAX) return EFBIG;
    if (ref >> 63) return ENOTSUP;
    ntfs_inode_t *inode; int rc = positive(ntfs_inode_get(v->core, ref, &inode));
    if (rc) return rc;
    rc = positive(ntfs_truncate(inode, size)); ntfs_inode_put(inode); return rc;
}
int nb_e2_blockmap(nb_volume *v, uint64_t ref, uint64_t off, uint64_t len, int for_write, nb_extent *out, size_t cap, size_t *count) {
    if (!v || !count || (!out && cap)) return EINVAL;
    *count = 0;
    if (off > INT64_MAX || len > (uint64_t)INT64_MAX - off) return EFBIG;
    if (ref >> 63) return ENOTSUP;
    if (for_write && v->bdev.read_only) return EROFS;
    ntfs_inode_t *inode; int rc = positive(ntfs_inode_get(v->core, ref, &inode));
    if (rc) return rc;
    rc = positive(ntfs_fsync(inode, false));
    if (!rc && for_write) rc = e2_prepare(inode, off, len);
    if (!rc) rc = e2_map(inode, off, len, for_write, out, cap, count);
    ntfs_inode_put(inode); return rc;
}
int nb_e2_complete_io(nb_volume *v, uint64_t ref, uint64_t off, uint64_t len, int status, int for_write) {
    if (!v || len > UINT64_MAX - off) return EINVAL;
    if (status) return positive(status);
    if (!for_write) return 0;
    if (v->bdev.read_only) return EROFS;
    ntfs_inode_t *inode; int rc = positive(ntfs_inode_get(v->core, ref, &inode));
    if (rc) return rc;
    rc = e2_finish(inode, off, len);
    if (!rc) rc = positive(ntfs_fsync(inode, false));
    ntfs_inode_put(inode);
    if (!rc) rc = positive(ntfs_volume_sync(v->core));
    return rc;
}
int nb_e2_sync(nb_volume *v) { return v ? positive(ntfs_volume_sync(v->core)) : EINVAL; }
static const nb_engine engine = {
    nb_e2_probe_state, nb_e2_mount, nb_e2_unmount, nb_e2_root_ref, nb_e2_lookup,
    nb_e2_readdir, nb_e2_read, nb_e2_create, nb_e2_write, nb_e2_truncate,
    nb_e2_blockmap, nb_e2_complete_io, nb_e2_sync
};
const nb_engine *nb_engine_e2(void) { return &engine; }
