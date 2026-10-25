/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef ENGINE_E2_H
#define ENGINE_E2_H
#include <ntfs_bridge.h>
const nb_engine *nb_engine_e2(void);
/* Headless fault/fixture hooks, not members of the filesystem bridge ABI. */
#define NB_E2_FAIL_PROMOTION 1u
#define NB_E2_FAIL_AFTER_ALLOCATION 2u
#define NB_E2_FAIL_FREE_INIT 4u
#define NB_E2_DELAY_FREE_INIT 8u
int nb_e2_test_mount(const nb_blockdev *, int, unsigned, nb_volume **);
int nb_e2_test_fault(nb_volume *, unsigned);
int nb_e2_test_sparse_fixture(nb_volume *, uint64_t, uint64_t);
#endif
