/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef NTFS_BRIDGE_H
#define NTFS_BRIDGE_H
#include <stdint.h>
#include <stddef.h>

#define NB_FILE 1u
#define NB_DIR 2u
#define NB_SYMLINK 3u
#define NB_RESIDENT (1u << 0)
#define NB_COMPRESSED (1u << 1)
#define NB_ENCRYPTED (1u << 2)
#define NB_SPARSE (1u << 3)
#define NB_EXT_DATA 1u
#define NB_EXT_HOLE 2u
#define NB_EXT_UNINIT 3u

typedef struct nb_volume nb_volume;
typedef struct { void *ctx; uint64_t size; uint32_t sector_size;
  int (*read)(void *ctx, uint64_t off, void *buf, size_t len);
  int (*write)(void *ctx, uint64_t off, const void *buf, size_t len);
  int (*flush)(void *ctx); } nb_blockdev;
typedef enum { NB_CLEAN, NB_HIBERNATED, NB_FAST_STARTUP, NB_DIRTY_LOG, NB_DIRTY_FLAG, NB_BITLOCKER, NB_UNSUPPORTED } nb_state;
typedef struct { uint64_t ref, parent_ref, size, alloc_size; uint32_t type /*file,dir,symlink*/, ntfs_attrs, nlink;
  int64_t crtime, mtime, ctime, atime /*NTFS 100ns*/; uint32_t flags /*NB_RESIDENT|NB_COMPRESSED|NB_ENCRYPTED|NB_SPARSE*/; } nb_attr;
typedef struct { uint64_t logical, physical, length; uint32_t kind /*NB_EXT_DATA, NB_EXT_HOLE, NB_EXT_UNINIT*/; } nb_extent;
typedef struct { uint64_t total_blocks, free_blocks, total_files, free_files; uint32_t block_size; int read_only; } nb_stat;
#define NB_SET_SIZE (1u << 0)
#define NB_SET_ATIME (1u << 1)
#define NB_SET_MTIME (1u << 2)
#define NB_SET_CRTIME (1u << 3)
/* T7-R2 append-only operations. getattr's parent is supplied by the caller.
 * remove unlinks files or removes empty directories (ENOTEMPTY otherwise).
 * statfs counts clusters and MFT slots; read_only reflects current core state.
 * setattr accepts only NB_SET_* size/times (NTFS 100ns epoch), others EINVAL.
 * rename is POSIX replace-or-move; names use the same UTF-16 rules as lookup.
 * All mutations reject read-only cores. Sync/unmount persists their metadata. */
typedef int (*nb_dirent_cb)(void *ctx, const uint16_t *name, size_t len, const nb_attr *attr, uint64_t next_cookie);
int nb_probe_state(const nb_blockdev *dev, nb_state *out);
int nb_mount(const nb_blockdev *dev, int read_write, nb_volume **out);   /* errno-style return */
int nb_unmount(nb_volume *v);
uint64_t nb_root_ref(nb_volume *v);
int nb_lookup(nb_volume *v, uint64_t dir, const uint16_t *name, size_t len, nb_attr *out);
int nb_readdir(nb_volume *v, uint64_t dir, uint64_t cookie, nb_dirent_cb cb, void *ctx);
int nb_read(nb_volume *v, uint64_t ref, uint64_t off, void *buf, size_t len, size_t *got);
int nb_create(nb_volume *v, uint64_t dir, const uint16_t *name, size_t len, uint32_t type, nb_attr *out);
int nb_write(nb_volume *v, uint64_t ref, uint64_t off, const void *buf, size_t len);
int nb_truncate(nb_volume *v, uint64_t ref, uint64_t size);
int nb_blockmap(nb_volume *v, uint64_t ref, uint64_t off, uint64_t len, int for_write, nb_extent *out, size_t cap, size_t *count);
int nb_complete_io(nb_volume *v, uint64_t ref, uint64_t off, uint64_t len, int status, int for_write);
int nb_sync(nb_volume *v);

/* Runtime dispatch: the exact ABI declarations above specify each operation.
 * Engines export prefixed implementations, not the unprefixed global symbols;
 * callers select a factory and invoke these identically named vtable members.
 * This allows E1 and E2 to coexist without link-time symbol interposition.
 * Return values are positive errno (zero success); device callbacks likewise.
 * A nonzero dirent callback consumes that entry and stops enumeration. Resume
 * with its next_cookie. Names are UTF-16 code units, never NUL-terminated.
 * Blockmap offsets/lengths are bytes. T5-R1/T5-R2/T5-R3:
 * - for_write allocates every hole/unallocated part of [off, off+len), without
 *   pre-zeroing the kernel's write range and without publishing new EOF/VDL.
 *   Allocated bytes at/after initialized_size are NB_EXT_UNINIT.
 *   Exception (T5-R3): newly materialized sparse clusters are zero-filled for
 *   their portion BELOW the existing initialized_size before returning a
 *   mapping, including payload bytes, so an abandoned/failed raw write cannot
 *   expose recycled disk contents. Beyond-VDL payload is not pre-zeroed.
 *   Zeroing is flushed before success. If zeroing/flush fails, restore the
 *   original hole and release its new allocation; failed restoration reports
 *   EIO and enters the core's read-only error path.
 * - Read mapping of nonresident data never allocates: holes are NB_EXT_HOLE;
 *   allocated bytes in [initialized_size,size) are NB_EXT_UNINIT, zero-filled
 *   by caller. T7-R3/R4 amendment: on RW mounts first mapping (read OR write)
 *   converts uncompressed/unencrypted resident data to nonresident, preserving
 *   existing bytes and EOF. This can allocate on a resident read. RO resident
 *   mappings still return ENOTSUP; use buffered reads without any mutation.
 * - Successful write completion raises initialized_size and size to their
 *   respective max(current, off+len), persists metadata, and invalidates cached
 *   data. If off exceeds initialized_size, it first zeroes the gap (sparse holes
 *   may remain holes) and flushes payload/gap BEFORE publishing the new VDL.
 * - Failed completion preserves both sizes; allocated clusters may remain.
 * - Compressed/encrypted mappings return ENOTSUP; use buffered reads.
 *   nb_create regular files start nonresident (except compressed/encrypted
 *   inherited attributes). P0 FSKit rejects writes to those inhibited items.
 * - Write mappings/completion reject a currently read-only or shut-down core
 *   with EROFS, including an errors=remount-ro transition after mount.
 * Callers serialize offloaded I/O with writes, truncate and other offloaded
 * ranges for that inode until completion (including failed completion).
 */
typedef struct nb_engine {
  int (*nb_probe_state)(const nb_blockdev *, nb_state *);
  int (*nb_mount)(const nb_blockdev *, int, nb_volume **);
  int (*nb_unmount)(nb_volume *);
  uint64_t (*nb_root_ref)(nb_volume *);
  int (*nb_lookup)(nb_volume *, uint64_t, const uint16_t *, size_t, nb_attr *);
  int (*nb_readdir)(nb_volume *, uint64_t, uint64_t, nb_dirent_cb, void *);
  int (*nb_read)(nb_volume *, uint64_t, uint64_t, void *, size_t, size_t *);
  int (*nb_create)(nb_volume *, uint64_t, const uint16_t *, size_t, uint32_t, nb_attr *);
  int (*nb_write)(nb_volume *, uint64_t, uint64_t, const void *, size_t);
  int (*nb_truncate)(nb_volume *, uint64_t, uint64_t);
  int (*nb_blockmap)(nb_volume *, uint64_t, uint64_t, uint64_t, int, nb_extent *, size_t, size_t *);
  int (*nb_complete_io)(nb_volume *, uint64_t, uint64_t, uint64_t, int, int);
  int (*nb_sync)(nb_volume *);
  int (*nb_getattr)(nb_volume *, uint64_t ref, uint64_t parent, nb_attr *);
  int (*nb_remove)(nb_volume *, uint64_t dir, const uint16_t *, size_t);
  int (*nb_statfs)(nb_volume *, nb_stat *);
  int (*nb_setattr)(nb_volume *, uint64_t ref, const nb_attr *, uint32_t valid);
  int (*nb_rename)(nb_volume *, uint64_t from_dir, const uint16_t *, size_t,
                   uint64_t to_dir, const uint16_t *, size_t);
} nb_engine;
#endif
