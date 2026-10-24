/* SPDX-License-Identifier: GPL-2.0-only */
#include <linux/slab.h>
#include <linux/workqueue.h>
#include <ntfsport/bdev.h>
static _Thread_local size_t fail_ra_size;
static void *e2_kzalloc(size_t size, gfp_t flags)
{
    if (fail_ra_size && size == fail_ra_size) { fail_ra_size = 0; return NULL; }
    return kzalloc(size, flags);
}
static void e2_precalc_free_clusters(struct work_struct *work);
/* This pristine translation unit initializes only precalc_work. */
#undef INIT_WORK
#define INIT_WORK(w, f) do { INIT_LIST_HEAD(&(w)->entry); (w)->func = e2_precalc_free_clusters; (w)->state = 0; (w)->wq = NULL; } while (0)
#define kzalloc e2_kzalloc
#include "../../../../upstream/ttntfs/core/ntfs/super.c"
#undef kzalloc
int e2_fail_free_init(struct ntfs_bdev *);
void e2_report_initialization_error(struct ntfs_bdev *, int);
static void e2_precalc_free_clusters(struct work_struct *work)
{
    struct ntfs_volume *vol = container_of(work, struct ntfs_volume, precalc_work);
    if (e2_fail_free_init(vol->sb->s_bdev)) fail_ra_size = sizeof(struct file_ra_state);
    precalc_free_clusters(work);
    fail_ra_size = 0;
    if (!NVolFreeClusterKnown(vol)) {
        /* A terminated producer must never leave allocation/statfs waiting. */
        /* Publish the actual cause before errors/RO can make ntfs_mount
         * reject the volume through its generic EROFS reason ladder. */
        e2_report_initialization_error(vol->sb->s_bdev, ENOMEM);
        atomic64_set(&vol->free_clusters, -ENOMEM);
        NVolSetErrors(vol);
        vol->sb->s_flags |= SB_RDONLY;
        NVolSetFreeClusterKnown(vol);
        wake_up_all(&vol->free_waitq);
    }
}
