<!-- SPDX-License-Identifier: GPL-2.0-only -->
# P0 E1 feasibility: pristine Linux NTFS user-space port

## Decision — controller ruling T6-R2

**E1 deferred; revisit after v0.1 if TT upstream stalls**.

P0 does not build E1 or add `.e1` to `Engine.allCases`. E2 will be selected provisionally in Task 8. The independent compatibility-layer cost below is beyond this platform spike; this is not evidence that a user-space Linux NTFS port is impossible. No E2-core substitution, NULL factory, success stub or both-engine conformance claim is made.

## Source examined

- **Linux v7.3**, released **2026-10-18**, commit timestamp `2026-10-18T23:14:58Z`.
- Annotated tag object: `091b06388b117fefdcb63336ac09956a4914b961`.
- Peeled commit: **`c03c1a14507dfaf8b856c2608f9ac216021fc222`**.
- [kernel.org release data](https://www.kernel.org/releases.json), retrieved 2026-10-24, reports `latest_stable.version = 7.3`. The releases array labels the final 7.3 release `mainline` and the older maintenance release 7.2.12 `stable`; selection follows `latest_stable`.
- Tag resolved using `git ls-remote https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git refs/tags/v7.3 'refs/tags/v7.3^{}'`. [Commit metadata](https://api.github.com/repos/torvalds/linux/git/commits/c03c1a14507dfaf8b856c2608f9ac216021fc222) confirms timestamp and `Linux 7.3` message.
- [Release archive](https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.3.tar.xz), downloaded SHA-256 `87363c24f10e06321eb362765521094e94471f6bff8bce2d6b3e40f39f004953`. This records downloaded bytes, not independent PGP authentication.
- Examined all **57 files** of `fs/ntfs/`. No NTFS-specific `include/` header is directly included. The generic Linux API dependencies below require compatibility implementations, not indiscriminate kernel-header vendoring.
- The temporary repository copy was removed under T6-R2; no Linux E1 source is committed. Original GPL-2.0-or-later and optional decompressor MIT notices were preserved during investigation.

## Compile evidence

Commands ran from repository root on macOS/arm64 with the existing TT platform headers. These are syntax probes, not a linked engine or conformance RED/GREEN.

### Execution environment

Identification was recorded on 2026-10-24 during review fix round 1, on the same host used for the original probes; these identification commands do not rerun either probe.

```sh
sw_vers
uname -m
sysctl -n machdep.cpu.brand_string hw.model
xcodebuild -version
clang --version
```

Output, in command order:

```text
ProductName:        macOS
ProductVersion:     27.0.1
BuildVersion:       26A434
arm64
Apple M5 Max
Mac17,7
Xcode 27.1
Build version 27A9275
Apple clang version 21.0.0 (clang-2100.3.34.2)
Target: arm64-apple-darwin27.0.0
Thread model: posix
InstalledDir: /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin
```

`sysctl` reports the CPU brand first and hardware model second. The probes used `xcrun clang`; the installed compiler directory above identifies the selected Xcode toolchain.

### Probe 1: unchanged platform

```sh
xcrun clang -fsyntax-only -fno-modules -fno-strict-aliasing -fwrapv \
  -I upstream/ttntfs/platform/include \
  -iquote /tmp/linux-7.3/fs/ntfs /tmp/linux-7.3/fs/ntfs/iomap.c
```

Exit 1; first error: `ntfs.h:22: fatal error: 'linux/blk_types.h' file not found`.

### Probe 2: expose the semantic gap

A disposable `/tmp/yuzu-e1-probe/linux/blk_types.h` containing `#include <linux/bio.h>` exposed TT's already-defined block types. At the time, the pristine source was temporarily copied under `upstream/linux-ntfs/`:

```sh
xcrun clang -fsyntax-only -ferror-limit=40 -fno-modules \
  -fno-strict-aliasing -fwrapv \
  -I /tmp/yuzu-e1-probe -I upstream/ttntfs/platform/include \
  -iquote upstream/linux-ntfs/fs/ntfs upstream/linux-ntfs/fs/ntfs/aops.c
```

Exit 1: **27 errors, 4 warnings**. First errors were conflicting declarations of `ntfs_bdev_read` and `ntfs_bdev_write`: pristine driver parameters use `struct block_device *` / `struct super_block *`, while TT platform declarations use `struct ntfs_bdev *` and different parameter types. Subsequent errors include missing `struct folio_iter`, `bio_for_each_folio_all`, iomap read/writeback contexts, read/readahead/writepages functions and callback implementations. The disposable header was removed. Reproduction requires re-fetching the pinned source and recreating that diagnostic-only include wrapper.

The missing header itself is easy to wrap; **the incompatible data/metadata I/O contracts are the blocker**.

## Inventory method and estimates

Counts are static call-expression sites across pristine `fs/ntfs/**/*.{c,h}`, excluding comments and string/character literals. Callback references are counted separately. Optional WOF code is included where noted. Counts are not runtime invocation totals. This inventory records identified absent APIs and observed ABI conflicts; it is not an assertion that a full compiling port has exposed every incompatible struct member.

**All difficulty and LOC estimates below are [INFERENCE]**, approximate authored physical C/header lines. Shared infrastructure overlaps between rows; do not sum them as independent estimates. Unsupported kernel-only interfaces should be explicitly excluded by documented E1-owned port patches, never implemented as success no-ops.

### Iomap: absent, not merely incomplete

TT `platform/include/linux/iomap.h` is **14 lines**, with three forward declarations and `iomap_dirty_folio`. Its comment explicitly states: “iomap does not exist in the port: file data bypasses the page cache and metadata goes through a_ops.” Linux v7.3 unconditionally builds the iomap-dependent NTFS translation units.

| Missing API | Direct calls / callback references | Difficulty / rough LOC [INFERENCE] |
|---|---|---|
| Mapping types, flags, iterator-next macros/protocol | `.iomap_next` 6 occurrences; `iomap_valid` 1 | Moderate, 250–500; use the pinned 7.3 protocol |
| `iomap_read_folio` | 1 call, aops.c:106 | Moderate, 150–300 shared read path |
| `iomap_readahead` | 1 call, aops.c:249 | Moderate, 80–180 |
| `iomap_bio_read_folio_range` | 1 callback reference, aops.c:47 | Moderate, 120–250 |
| `iomap_bio_submit_read_endio` | 1 call, aops.c:43 | Moderate, 60–120 |
| `iomap_finish_folio_read` | 1 call, aops.c:35 | Moderate, 80–160 |
| `iomap_file_buffered_write` | 2 calls, file.c:530,656 | **Hard**, 400–800; partial folios, inline data, VDL and failure unwind |
| `iomap_writepages` | 1 call, aops.c:288 | **Hard**, 350–700; dirty/error/redirty semantics |
| `iomap_add_to_ioend` | 1 call, iomap.c:813 | **Hard**, 150–300 shared ioend infrastructure |
| `iomap_ioend_writeback_submit` | 1 callback reference | **Hard**, 150–300 shared completion ownership |
| `iomap_zero_range` | 4 calls: inode.c:2443; file.c:986,1002; iomap.c:381 | **Hard**, 180–350; holes, uninitialized data and cache coherence |
| `iomap_dio_rw` | 2 calls, file.c:478,516 | **Hard**, 300–600; alignment/fallback and end-I/O publication |
| `iomap_seek_hole`, `iomap_seek_data` | 1 call each, file.c:436,441 | Straightforward, 80–160 shared mapping walk |
| `iomap_fiemap` | 1 call, file.c:746 | Moderate, 80–180 |
| `iomap_page_mkwrite` | 1 call, file.c:694 | Hard real VM integration; explicit bridge-only exclusion 20–50 |
| `iomap_swapfile_activate` | 1 call, aops.c:302 | Kernel swap unavailable; explicit exclusion 10–30 |
| `iomap_is_partially_uptodate` | 2 callback references | Moderate, 60–120 shared range-state tracking |
| `iomap_release_folio`, `iomap_invalidate_folio` | 2 callback references each | Moderate, 80–160 shared lifecycle |
| Contexts/operation structures | read context 3 type references; writepage context 2; read ops 1; dio ops 1 | Moderate, 150–250 shared type contracts |

TT already provides `iomap_dirty_folio` (2 direct NTFS calls); it is not missing.

### Page cache / address-space ABI

TT `platform/include/linux/mm_types.h:73–76` defines only `read_folio(mapping, folio)` and `write_folio(mapping, folio)`. Its actual pagecache calls these at pagecache.c:581 and :619. Pristine Linux defines `read_folio(file, folio)`, `writepages`, readahead and lifecycle callbacks and initializes **2 full aops tables** (aops.c:306–331). Casting between the tables is incorrect.

An E1-owned adapter needs to bridge these contracts without recursively reentering cache read/writeback: **hard, 350–700 LOC [INFERENCE]**, in addition to shared iomap work. Missing helpers:

| Helpers | Direct calls / references | Difficulty / rough LOC [INFERENCE] |
|---|---|---|
| `filemap_grab_folio`, `folio_contains`, `folio_next_pos` | 1, 3, 2 calls; latter two optional WOF | Straightforward, 30–70 |
| `memcpy_from_page`, `memcpy_to_page`, `memzero_page`, `page_offset` | 1, 2, 2, 1 calls | Straightforward, 40–80 |
| `filemap_migrate_folio`, `generic_error_remove_folio` | 2 callback references each | Moderate cache error removal, 40–100; exclude real VM migration |
| `struct readahead_control` / range bookkeeping | aops.c parameter and accesses | Moderate, 100–200 shared read infrastructure |

TT already has real folio locks, dirty tracking, `writeback_iter`, invalidation and synchronous bio submission. Those are reusable building blocks, not implementations of full Linux aops/iomap semantics.

### Bio and device layer

| Facility | Static sites | Existing or missing / difficulty [INFERENCE] |
|---|---|---|
| `bio_alloc`, `bio_put` | 7, 11 calls | Provided; adapt block-device types, moderate 60–150 shared LOC |
| `bio_add_folio`, `bio_add_page`, `bio_add_vmalloc_chunk` | 4, 1, 1 calls | Provided |
| `submit_bio`, `submit_bio_wait` | 5, 5 calls | Provided synchronously; preserve completion ownership |
| `bio_chain`, `bio_end_sector`, `bio_max_segs` | 1, 2, 2 calls | Provided |
| `blk_status_to_errno` | 1 call | Provided |
| `struct folio_iter`, `bio_for_each_folio_all` | 1 declaration, 1 loop | Missing; TT vectors retain addresses, not source folio identity. Moderate 80–160 LOC |
| `bdev_rw_virt` | 1 call | Missing; straightforward 30–70 LOC |
| `blkdev_issue_zeroout` | 1 call | Missing; straightforward 50–100 LOC |
| `is_vmalloc_addr` | 1 call | Missing; straightforward 10–30 LOC with truthful allocation semantics |
| `ntfs_bdev_read`, `ntfs_bdev_write` | 2 conflicting declarations | Incompatible signatures; moderate 50–100 LOC namespace/type adapters |

Both engines also compile identically named Linux driver globals. Prefixing only `nb_e1_*` cannot isolate them. An E1-only generated namespace mapping is needed, including separation from TT platform `ntfs_bdev_*`: straightforward/moderate, 50–150 authored LOC plus generated symbol list [INFERENCE].

### Other identified missing kernel calls

| Facility group | Exact direct-call counts | Difficulty / rough LOC [INFERENCE] |
|---|---|---|
| Generic file/iteration | `generic_file_read_iter` 1; `generic_write_checks` 1; `generic_write_sync` 1; `generic_file_llseek_size` 1; `filemap_splice_read` 1; `vfs_setpos` 1 | Moderate, 180–350 shared with iomap; exclude splice if not exposed |
| Metadata/timestamps | `d_backing_inode` 1; `file_accessed` 2; `file_modified` 2; `file_update_time` 1; `generic_fillattr` 1; `setattr_copy` 1; `setattr_prepare` 1 | Moderate, 150–300 |
| Size/I/O/cache growth | `inode_dio_wait` 2; `inode_newsize_ok` 3; `pagecache_isize_extended` 2 | Moderate, 80–180 |
| Mount/VM boundaries | `mnt_drop_write_file` 1; `mnt_want_write_file` 1; `sb_end_pagefault` 1; `sb_start_pagefault` 1; `vma_desc_test_all` 1 | Moderate mount-state work, 50–120; exclude actual VM paths |
| ACL/delayed links | `posix_acl_chmod` 1; `set_delayed_call` 1 | Moderate, 50–150 or explicit unsupported ACL operation |
| Dentry/aliases | `d_add_ci` 1; `d_instantiate` 1; `d_instantiate_new` 4; `d_obtain_alias` 1; `d_splice_alias` 2; `dentry_path_raw` 1; `full_name_hash` 1; `is_subdir` 1 | Moderate, 180–400; ownership and references |
| Export | `generic_fh_to_dentry` 1; `generic_fh_to_parent` 1 | NFS not exposed by bridge; explicit exclusion 20–60 |
| Inode creation/state | `init_special_inode` 1; `inode_state_set` 1; `simple_inode_init_ts` 3; `simple_rename_timestamp` 1; `alloc_inode_sb` 1; `inode_generic_drop` 1; `sb_end_intwrite` 1; `sb_start_intwrite` 1 | Moderate, 100–220 |
| Typed allocations | `kmalloc_obj` 5; `kmalloc_objs` 5; `kzalloc_obj` 8; `kzalloc_objs` 1; `kvzalloc_obj` 1; `kvzalloc_objs` 5; `kvmemdup` 1; `kvrealloc` 2 | Straightforward, 60–120; preserve checked sizes and zero/realloc semantics |
| User/kernel boundaries | `capable` 4; `compat_ptr` 1; `copy_from_user` 1; `copy_to_user` 2; `get_user` 1; `strndup_user` 1 | Kernel ioctl paths not exposed; explicit exclusion 40–100; no fake isolation |
| Control/utilities | `register_sysctl` 1; `unregister_sysctl_table` 1; `str_plural` 1 | Exclude sysctl.o; utility 5–15 |

Full file/inode/export operation structures need compatibility work too: TT `struct export_operations` is only `{ void *dummy; }`. Adding missing function declarations alone does not make the kernel initializers type-correct.

### Missing generic include files

All angle-bracket includes were compared with TT `platform/include`; **8 distinct paths** are absent:

| Header | Exact include sites | Difficulty / LOC [INFERENCE] |
|---|---|---|
| `linux/blk_types.h` | ntfs.h:22 (1) | Straightforward wrapper 10–30; block semantics remain |
| `linux/exportfs.h` | namei.c:9 (1) | Exclude export or moderate 30–80 declarations plus behavior |
| `linux/string_choices.h` | attrib.c:19 (1) | Straightforward 5–15 |
| `linux/proc_fs.h`, `linux/sysctl.h` | sysctl.c:15,16 (1 each) | Explicit sysctl translation-unit exclusion |
| `linux/unaligned.h` | wof.c:14; lib/decompress_common.h:19 (2) | Straightforward 40–80 |
| `linux/array_size.h` | lib/lzx_decompress.c:12; lib/xpress_decompress.c:14 (2) | Straightforward 5–15 |
| `linux/bits.h` | lib/lzx_decompress.c:13 (1) | Straightforward 10–30 |

The last three rows mainly concern optional WOF decompression, not required by the existing fixture corpus.

## What TT actually did

Inspected [TT NTFS Native](https://github.com/dr-kbadawi/ttntfs) at the exact E2 pin **`36cc849a3ed867b8b6ee3fbc805ba2385cb79cdb`**, not current HEAD. The locally vendored subset excludes TT's own `upstream/`, but its repository contains `upstream/linux-v7.1/fs/ntfs/`. `upstream/UPSTREAM.md` identifies Linux v7.1 commit **`8cd9520d35a6c38db6567e97dd93b1f11f185dc6`** and explicitly says the port lives in `core/`.

TT `core/vfs/aops.c:4–23` states that it **replaces fs/ntfs/aops.c and iomap.c**, uses its custom whole-folio read/write callbacks, and substitutes a zero-range helper for `iomap_zero_range`. File/inode/namei implementations also move to `core/vfs/`; direct read/write lives in core/vfs/api.c. This is patched/replaced core, **not a full platform iomap implementation**. Copying it into E1 would violate T6-R1.

Relevant history command:

```sh
git log --oneline 36cc849a3ed867b8b6ee3fbc805ba2385cb79cdb -- \
  core/ntfs/aops.c core/ntfs/iomap.c core/ntfs/file.c \
  platform/include/linux/iomap.h upstream
```

Result:

```text
0b9f8ef Name the copyright holder, stamp builds with version and commit, show both in Settings
3f2f779 Scaffold: design docs, contract headers, page cache, FSKit app, vendored Linux 7.1 ntfs
```

The initial scaffold already contains the replaced design; no stepwise iomap-removal series was exposed by this path history.

Measured TT v7.1-baseline-to-port changes (physical lines, Python SequenceMatcher with autojunk=False):

| Pristine → TT destination | Added | Removed | Baseline lines | Port lines |
|---|---:|---:|---:|---:|
| aops.c → core/vfs/aops.c | 508 | 244 | 305 | 569 |
| iomap.c → absent same-name translation unit | 0 | 882 | 882 | 0 |
| file.c → core/vfs/file.c | 107 | 712 | 1160 | 555 |
| inode.c → core/vfs/inode.c | 93 | 125 | 3787 | 3755 |
| namei.c → core/vfs/namei.c | 661 | 706 | 1693 | 1648 |
| bdev-io.c → absent same-name translation unit | 0 | 120 | 120 | 0 |

These are TT's **v7.1 replacement deltas**, not E1 glue size or v7.3-v7.1 evolution.

## Cost and retained metric

**[INFERENCE] Approximately 4,000–8,000 additional authored C/header LOC**, before tests, documentation and newly exposed assumptions, for the independent iomap subset, cache/aops adapter, VFS surface, block namespace/type isolation and real bridge implementation. This is a rough engineering bound, not a completed-port measurement or promise. The most difficult work is correctness-sensitive buffered write/writeback, initialized-size publication and cache coherence, not the small missing header wrappers.

`scripts/upstream-diff-stat.sh` measures only existing engine-maintained C/header lines and unified patch additions/removals against the pristine TT baseline. At investigation time E2 had **548 physical C/header lines in 3 files**, no patch files. Pristine symlinked source, docs, tests and build configuration are excluded. E1 is absent, not a zero-cost completed port.

No upstream Linux bug was demonstrated; reduced-shim incompatibility is not an upstream NTFS defect. No E1 conformance/plain/ASan/UBSan run was performed. Deferral leaves the real E2 conformance suite unchanged and avoids fabricating a second engine for an unfair comparison.
