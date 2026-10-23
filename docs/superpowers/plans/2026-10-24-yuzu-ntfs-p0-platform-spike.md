# Yuzu NTFS P0 — Platform Spike + Engine Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove FSKit enablement (R1), automount precedence (R2) and kernel-offloaded throughput (R3) on macOS 26 + 27, and choose the NTFS engine (E1 vs E2) by measured criteria.

**Architecture:** XcodeGen project with a menu-bar app and an FSKit `FSUnaryFileSystem` extension on `FSBlockDeviceResource`. Engines sit behind one C ABI (`nb_*`, `NTFSBridge`) inside a SwiftPM package so they are testable headless against image files.

**Tech Stack:** Swift 6, FSKit (macOS 26 SDK floor, built with Xcode 27 SDK), C17, SwiftPM C targets, Swift Testing, XcodeGen, ntfsprogs `mkntfs` (built without FUSE), UTM VMs.

**Spec:** `docs/superpowers/specs/2026-10-24-yuzu-ntfs-v0.1-design.md`

**Scope note:** This plan covers P0 only. P1–P6 plans are written after the P0 gate, because their files and tests depend on the chosen engine (D3). P0 spike code (Tasks 3, 4, 7 experiments) is throwaway; the bridge ABI, boot-sector parser, fixtures and bench harness are kept.

## Global Constraints
- Licence GPL-2.0-only for the whole repo (D2); upstream sources kept pristine under `upstream/`.
- macOS 26.0 deployment target, arm64 only (D5). macOS 27 APIs only behind `#available(macOS 27, *)`.
- Bundle ids `com.bluecoral.vn.yuzuntfs` / `com.bluecoral.vn.yuzuntfs.fsmodule`; `FSShortName` `yuzuntfs` (D7). Team `37PX6W22C5`; never touch Yuzu Drag's identity.
- `MARKETING_VERSION 0.1.0`, `CURRENT_PROJECT_VERSION 1` (D1).
- Spike results are written to `docs/spikes/p0-*.md` with OS build, hardware, commands and raw numbers; claims without measurements do not count.
- Never run a write experiment on a disk holding real data; only fixture images and the dedicated test SSD.

## Review Focus
- Disk image attached with `hdiutil attach -nomount` then mounted: probe must handle a resource whose `blockSize` is 4096 (4Kn fixture) — test in Task 2.
- Boot sector with `bytes_per_sector` not a power of two or cluster > 2 MiB must be `notRecognized`, not crash — test in Task 2.
- Unplug during a mounted read listing must not hang `ls` — manual check recorded in Task 4.
- Bridge `nb_readdir` on a 100k-entry directory must resume from a cookie without duplicates — test in Task 5/6.
- KOIO write of a file whose size is not cluster-aligned must read back exact length with zero tail — test in Task 7.

---

### Task 1: Repo scaffold + test environment

**Files:**
- Create: `LICENSE` (GPL-2.0 text), `README.md`, `project.yml`, `App/` (SwiftUI menu-bar app showing "Yuzu NTFS 0.1 Beta"), `Module/` (extension entry + Info.plist with `FSShortName yuzuntfs`, `FSSupportsBlockResources true`, `FSPersonalities` for NTFS), `Module/YuzuNTFSModule.entitlements` (`com.apple.developer.fskit.fsmodule`, app-sandbox), `Packages/NTFSCore/Package.swift`
- Create: `scripts/fetch-ntfsprogs.sh` (builds ntfs-3g release tarball with `--disable-ntfs-3g`, installs `mkntfs`, `ntfsinfo`, `ntfsls`, `ntfscat` into `tools/bin/`), `scripts/make-fixtures.sh`, `docs/testing/vms.md`

- [ ] **Step 1:** `xcodegen generate && xcodebuild -scheme YuzuNTFS -configuration Debug build` → BUILD SUCCEEDED; app + embedded `.appex` present.
- [ ] **Step 2:** `scripts/make-fixtures.sh` creates under `fixtures/` (gitignored): `basic-512.img` (256 MiB, 4 KiB clusters), `4kn.img` (`-s 4096`), `c64k.img` (`-c 65536`), `bigdir.img` (100 000 files via ntfsprogs-less path: generated in the Windows VM, script documents it), `names.img` (CJK, emoji, NFC+NFD pair). Expected: `tools/bin/ntfsinfo -m fixtures/basic-512.img` prints volume info for each.
- [ ] **Step 3:** `docs/testing/vms.md`: UTM Windows 11 ARM (attach `.img` as raw disk, `chkdsk X: /scan`), macOS 26 VM (Virtualization.framework, attach image via USB-mass-storage passthrough or virtual disk). Verify both boot and Windows sees `basic-512.img` as a drive.
- [ ] **Step 4:** Commit `chore: scaffold Yuzu NTFS repo and fixtures`.

### Task 2: Boot-sector parser + probe

**Files:**
- Create: `Packages/NTFSCore/Sources/NTFSProbe/BootSector.swift`
- Modify: `Module/YuzuNTFSFileSystem.swift` (probe uses it)
- Test: `Packages/NTFSCore/Tests/NTFSProbeTests/BootSectorTests.swift`

**Interfaces:**
- Produces: `struct NTFSBootSector: Sendable { bytesPerSector: UInt32; sectorsPerCluster: UInt32; clusterSize: UInt32; totalSectors: UInt64; mftLCN: UInt64; mftMirrLCN: UInt64; mftRecordSize: UInt32; indexRecordSize: UInt32; serial: UInt64 }`, `static func parse(_ bytes: UnsafeRawBufferPointer) throws(NTFSProbeError) -> NTFSBootSector`, `enum NTFSProbeError: Error { case notNTFS, invalidGeometry(String) }`, `var volumeUUID: UUID` (derived from serial, stable).

- [ ] **Step 1: failing tests**
```swift
@Test func parsesMkntfs512() throws { let bs = try NTFSBootSector.parse(fixtureSector("basic-512.img"))
  #expect(bs.bytesPerSector == 512); #expect(bs.clusterSize == 4096); #expect(bs.mftRecordSize == 1024) }
@Test func parses4Kn() throws { #expect(try NTFSBootSector.parse(fixtureSector("4kn.img")).bytesPerSector == 4096) }
@Test func rejectsFAT() { #expect(throws: NTFSProbeError.notNTFS) { try NTFSBootSector.parse(fatSector) } }
@Test(arguments: [513, 0, 8192]) func rejectsBadSectorSize(_ v: UInt16) { #expect(throws: NTFSProbeError.self) { try NTFSBootSector.parse(patch(basic, bps: v)) } }
@Test func rejectsClusterOver2MiB() { #expect(throws: NTFSProbeError.self) { try NTFSBootSector.parse(patch(basic, spcNegativeShift: 22)) } }
@Test func uuidStable() throws { #expect(try NTFSBootSector.parse(s).volumeUUID == NTFSBootSector.parse(s).volumeUUID) }
```
- [ ] **Step 2:** `swift test --package-path Packages/NTFSCore` → FAIL (type missing).
- [ ] **Step 3:** Implement. Signed `sectors_per_cluster` byte (values ≥ 0xF4 mean 2^(−n)), signed `clusters_per_mft_record`; OEM id `"NTFS    "`; `0x55AA` signature.
- [ ] **Step 4:** Tests PASS, also with `--sanitize=address` and `--sanitize=undefined`.
- [ ] **Step 5:** `probeResource` returns `.usable(name: label-or-"NTFS", containerID: FSContainerIdentifier(uuid: bs.volumeUUID))` (label read deferred to engine; P0 uses "NTFS"). Commit `feat: NTFS boot-sector parser and probe`.

### Task 3: Spike R1 — extension enablement

**Files:** Create `docs/spikes/p0-r1-enable.md`; throwaway code in `spikes/r1/`.

- [ ] **Step 1:** On macOS 27 host and macOS 26 VM, with a notarized Debug-signed build in `/Applications`: try (a) System Settings → Login Items & Extensions → File System Extensions toggle; (b) `FSClient.shared.openFileSystemExtensionsSettings()` (27); (c) `pluginkit -e use -i com.bluecoral.vn.yuzuntfs.fsmodule`; (d) TT NTFS Native's documented self-enable path (read `fskit/README.md` in their repo, reproduce, note entitlement/sandbox needs).
- [ ] **Step 2:** For each: works Y/N, user steps, sandbox requirement, `log show --predicate 'process == "fskitd"'` excerpt.
- [ ] **Step 3:** Gate R1: at least one path a normal user can complete on both OS versions without Terminal. Record the chosen path. Commit `docs: P0 R1 enablement findings`.

### Task 4: Spike R2 — automount precedence

**Files:** Create `docs/spikes/p0-r2-automount.md`.

- [ ] **Step 1:** With the extension enabled, `hdiutil attach fixtures/basic-512.img` and plug the test SSD formatted NTFS by the Windows VM. Record `mount | grep -i ntfs`, `diskutil info` "File System Personality", which driver mounted.
- [ ] **Step 2:** If Apple's driver wins: try `FSPersonalities` probe ordering / `FSProbeOrder` keys, `diskutil mount -t yuzuntfs`, `mount -F -t yuzuntfs`, and macOS 27 `mountSingleVolume` (note it needs `com.apple.developer.fskit.mount`; record whether Apple grants it to Developer ID).
- [ ] **Step 3:** Unplug the SSD while `ls -R /Volumes/X` runs; record whether any process hangs (Review Focus).
- [ ] **Step 4:** Gate R2: automatic RW-capable mount through `yuzuntfs` on plug-in, or an app-driven remount within 2 s without admin password. Commit.

### Task 5: Bridge ABI + engine E2 (TT core fork)

**Files:**
- Create: `Packages/NTFSCore/Sources/NTFSBridge/include/ntfs_bridge.h`, `upstream/ttntfs/` (pristine, pinned commit recorded in `upstream/README.md`), `Packages/NTFSCore/Sources/EngineE2/` (build glue + bridge impl)
- Test: `Packages/NTFSCore/Tests/BridgeConformanceTests/` (engine-agnostic, parameterised by engine)

**Interfaces (Produces — both engines implement exactly this):**
```c
typedef struct nb_volume nb_volume;
typedef struct { void *ctx; uint64_t size; uint32_t sector_size;
  int (*read)(void *ctx, uint64_t off, void *buf, size_t len);
  int (*write)(void *ctx, uint64_t off, const void *buf, size_t len);
  int (*flush)(void *ctx); } nb_blockdev;
typedef enum { NB_CLEAN, NB_HIBERNATED, NB_FAST_STARTUP, NB_DIRTY_LOG, NB_DIRTY_FLAG, NB_BITLOCKER, NB_UNSUPPORTED } nb_state;
typedef struct { uint64_t ref, parent_ref, size, alloc_size; uint32_t type /*file,dir,symlink*/, ntfs_attrs, nlink;
  int64_t crtime, mtime, ctime, atime /*NTFS 100ns*/; uint32_t flags /*NB_RESIDENT|NB_COMPRESSED|NB_ENCRYPTED|NB_SPARSE*/; } nb_attr;
typedef struct { uint64_t logical, physical, length; uint32_t kind /*NB_EXT_DATA, NB_EXT_HOLE, NB_EXT_UNINIT*/; } nb_extent;
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
```
- [ ] **Step 1: failing conformance tests** (`@Test(arguments: Engine.allCases)`): `rootListsSystemFilesHidden` (readdir root of `basic-512.img` contains no `$MFT`, contains files written by fixture script); `readMatchesNtfscat` (every fixture file byte-equal to `tools/bin/ntfscat` output); `readdirResumesFromCookie` on `bigdir.img` — collect with a callback that stops every 1000 entries, resume, assert 100 000 unique names; `cleanStateForMkntfs` (`nb_probe_state == NB_CLEAN`); `writeRoundTrip` (create `a.bin`, write 3 MiB + 17 bytes, sync, unmount, remount, read equals, `ntfsinfo` clean); `blockmapCoversFile` (extents for `a.bin` sum to allocated length, data extents readable via raw device equal file content).
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Vendor TT core at a pinned commit into `upstream/ttntfs`; build its `core/` + `platform/` as a C target; implement `nb_*` over its `core/vfs/api.c` API. Do not edit `upstream/`; changes live in `EngineE2/` with a `PATCHES.md`.
- [ ] **Step 4:** All conformance tests PASS for `.e2`, plain and with ASan/UBSan.
- [ ] **Step 5:** Commit `feat: bridge ABI and engine E2`.

### Task 6: Engine E1 (own port of Linux fs/ntfs)

**Files:** Create `upstream/linux-ntfs/` (pristine `fs/ntfs` from a pinned Linux 7.x tag, recorded), `Packages/NTFSCore/Sources/NTFSPlatform/` (kernel API shim: kmalloc, locks, folio/page cache, bio→`nb_blockdev`, time, errno), `Packages/NTFSCore/Sources/EngineE1/`.

**Interfaces:** Consumes `ntfs_bridge.h` from Task 5; adds `.e1` to `Engine.allCases`.

- [ ] **Step 1:** Add `.e1` to the conformance test arguments → FAIL.
- [ ] **Step 2:** Port until every conformance test passes. Keep a diff-size counter: `scripts/upstream-diff-stat.sh` prints changed lines of `EngineE1` vs `upstream/linux-ntfs`.
- [ ] **Step 3:** Conformance PASS for `.e1`, plain + ASan/UBSan. Commit `feat: engine E1 port of Linux fs/ntfs`.

### Task 7: FSKit read/write mount + Spike R3 throughput

**Files:** Modify `Module/YuzuNTFSVolume.swift`, `Module/YuzuNTFSItem.swift` (one live `FSItem` per MFT ref, weak table); create `scripts/bench.sh`, `docs/spikes/p0-r3-throughput.md`.

**Interfaces:** Consumes `nb_*`. Volume implements lookup, enumerate (attributes in-pass), getattr, create, remove, read/write handler for resident files, `blockmapFile`/`completeIO` for non-resident; metadata through `metadataRead/Write` after activation (plain read before).

- [ ] **Step 1:** `bench.sh <mountpoint> <label>` writes a Markdown row: seq write 4 GiB (`dd bs=8m`, `F_NOCACHE` via `mkfile`-free Swift helper `tools/seqio`), seq read 4 GiB after remount, 10 000 × 4 KiB copy, `ls -l` 100k dir, `rm -rf` 100k tree. Run on the test SSD as exFAT (Apple) and as NTFS with Apple's driver (reads only) to get baselines.
- [ ] **Step 2:** Mount fixture + SSD through Yuzu NTFS (whichever engine passes Task 5 first), run bench; then the non-aligned check: write 1 000 003 bytes, remount, `stat -f%z` = 1000003 and `cmp` equal.
- [ ] **Step 3:** Gate R3: seq read and write via KOIO ≥ 90 % of raw device (`dd` on `/dev/rdiskN`, read-only measurement) on macOS 26 and 27. Record CPU% of the extension process. Commit.

### Task 8: Engine selection + P0 gate

**Files:** Create `docs/spikes/p0-engine-selection.md`; modify spec §2 D3 and status line.

- [ ] **Step 1:** For E1 and E2, in this order: (1) conformance + fixture correctness; (2) Windows VM `chkdsk /scan` after the write torture subset (create/rename/delete 10 000 files, 5 fragmented 200 MiB files, ADS) → error count; (3) `bench.sh` rows; (4) `upstream-diff-stat.sh`; (5) licence/attribution notes.
- [ ] **Step 2:** Pick the engine that wins the first criterion where they differ. Update D3 with the result and link the doc. Delete the loser's `Engine*` target and its `upstream/` copy.
- [ ] **Step 3:** P0 gate summary in the doc: R1/R2/R3 pass/fail with links. Commit `docs: P0 gate — engine <E1|E2> selected`.
