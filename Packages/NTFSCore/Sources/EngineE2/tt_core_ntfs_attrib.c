/* SPDX-License-Identifier: GPL-2.0-only */
/* Keep upstream pristine; expose its private allocation-without-EOF primitive. */
#include "../../../../upstream/ttntfs/core/ntfs/attrib.c"

/* Caller holds inode lock and mrec_lock. The old EOF is passed unchanged;
 * prealloc_size grows physical allocation using HOLES_NO, never a sparse run.
 * The core performs its own transactional rollback before publishing EOF. */
int e2_allocate_non_sparse(struct ntfs_inode *ni, s64 allocation)
{
    return ntfs_non_resident_attr_expand(ni, ni->data_size, allocation, HOLES_NO, true);
}

int e2_grow_non_sparse(struct ntfs_inode *ni, s64 size)
{
    return ntfs_non_resident_attr_expand(ni, size, 0, HOLES_NO, true);
}
