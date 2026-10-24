<!-- SPDX-License-Identifier: GPL-2.0-only -->
# P0 R3 — FSKit RW and image throughput

## Verdict

**BLOCKED-PENDING-REBOOT.** A real Yuzu read-only image mount and an allowlisted read/write image mount were reached. The first mounted 1,000,003-byte `cp` wedged in kernel writeback before any active extension data upcall. Its extension was terminated under controller authorization; `cp` remained uninterruptible and subsequent image transport operations stalled. The controller stopped all further mount/attach attempts and requires an owner reboot before resuming.

The resident-file routing fix below is implemented and engine-tested, **not verified through a corrected mount**. No working mounted RW copy/remove, exact-size remount check, Finder copy, mounted KOIO throughput, Apple baseline throughput, CPU percentage, or R3 performance pass is claimed. The source deliverable and repeatable image-only harness are retained so the next session can resume without reconstructing this investigation.

| Gate/environment | Read | Write | Verdict |
|---|---:|---:|---|
| macOS 27 internal-SSD image, raw backing file | 10,559.323 MiB/s median | 11,963.303 MiB/s median | Measured; not a physical-device baseline |
| macOS 27 Yuzu KOIO image | BLOCKED | BLOCKED | BLOCKED-PENDING-REBOOT |
| macOS 27 Apple exFAT image | BLOCKED | BLOCKED | Transport unavailable before first workload |
| macOS 27 Apple NTFS image | BLOCKED | Read-only / N/A | Native selection/forced mounting must be established after reboot |
| Physical SSD, macOS 27 | PENDING-OWNER | PENDING-OWNER | No physical device used |
| macOS 26 | PENDING-OWNER | PENDING-OWNER | No macOS 26 VM available |

The provisional KOIO thresholds against this image-file baseline would be **9,503.391 MiB/s read** and **10,766.973 MiB/s write** (90% of medians). There is no numerator yet; a speed ratio cannot be calculated. Internal-image results cannot close the physical-SSD/macOS-26 gate.

## Environment and method

Observed 2026-10-24, UTC+07:00:

```text
sw_vers:
ProductName: macOS
ProductVersion: 27.0.1
BuildVersion: 26A434
sysctl -n hw.model: Mac17,7
architecture: arm64
xcodebuild -version: Xcode 27.1 / Build version 27A9275
SDK: macOS 27.0
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
Deployment target: macOS 26.0
```

`tools/seqio` is an executable Swift helper: one aligned 8 MiB buffer, deterministic nonzero payload, `F_NOCACHE`, loops over short reads/writes and EINTR, and `fsync` included in write timing. Timing excludes interpreter startup and payload initialization. Raw means a disposable **4 GiB regular backing-image file** (`build/r3/raw.img`) on the internal SSD, not `/dev/rdiskN`. No attached/formatted image was overwritten for the raw baseline. Each row transferred exactly 4,294,967,296 bytes. Raw-file runs have no volume to unmount; F_NOCACHE is the raw-run cache control. Mounted runs must unmount/remount between operations as implemented in the harness.

### Raw numbers (five runs, not estimates)

| Driver | Run | Operation | Seconds | MiB/s | Extension CPU % |
|---|---:|---|---:|---:|---|
| Raw image file | 1 | write | 0.424100 | 9658.090 | N/A — no extension |
| Raw image file | 1 | read | 0.390051 | 10501.177 | N/A |
| Raw image file | 2 | write | 0.342380 | 11963.303 | N/A |
| Raw image file | 2 | read | 0.384725 | 10646.556 | N/A |
| Raw image file | 3 | write | 0.324004 | 12641.800 | N/A |
| Raw image file | 3 | read | 0.390115 | 10499.468 | N/A |
| Raw image file | 4 | write | 0.344686 | 11883.268 | N/A |
| Raw image file | 4 | read | 0.385792 | 10617.122 | N/A |
| Raw image file | 5 | write | 0.322508 | 12700.444 | N/A |
| Raw image file | 5 | read | 0.387904 | 10559.323 | N/A |
| Raw image file | median | write | 0.342380 | 11963.303 | N/A |
| Raw image file | median | read | 0.387904 | 10559.323 | N/A |

Command per row: `tools/seqio write|read build/r3/raw.img 4294967296`. The helper opens writes with O_TRUNC; **never point raw writes at a formatted image or a device**. Raw JSON capture is in ignored `build/r3/raw-results.json`.

`bench.sh` emits a Markdown row per workload/run, five runs of: 4 GiB sequential write, cold 4 GiB read, 10,000 × 4 KiB copies, cold `ls -l` of 100,000 entries, cold `rm -rf` of that tree. Read-only mode runs only sequential reads from a preseeded file. A matching image-path marker guards the benchmark tree against deleting foreign data. Extension CPU is the mean of summed current-user `YuzuNTFSModule` `%cpu` samples at 0.2-second intervals around each command; it is not whole-system CPU, Instruments CPU, or a calibrated process-time delta. Native-driver rows use N/A. No extension CPU number was collected in this blocked run; the idle stack sample is **not** a CPU measurement. Script syntax and fail-closed invalid-driver handling were exercised; the full harness still requires a successful mounted run.

## Safety and implemented paths

**T7-R1:** RW is permitted only when the boot serial parsed by NTFSProbe appears as an exact 16-hex-digit line in this extension-sandbox file:

```text
/Users/rom/Library/Containers/com.bluecoral.vn.yuzuntfs.fsmodule/Data/Library/Application Support/YuzuNTFS/p0-rw-serials.txt
```

The module resolves it as `NSHomeDirectory()/Library/Application Support/YuzuNTFS/p0-rw-serials.txt` from inside the sandbox. Missing, unreadable, empty, malformed, nonmatching files fail closed. Device read-only state and `--rdonly` also override the list. Other NTFS volumes open the engine read-only. macOS 26.4+ `requestedMountOptions.readOnly` communicates that mode to the kernel; kernel mount-flag reporting on 26.0–26.3 remains unverified even though engine writes are denied. The list was empty at handoff. Bench/test instructions grant only disposable fixture serials before mount and revoke them on cleanup; they do not authorize the owner's real disks.

The Swift volume implements activation/load container state, lookup, attribute reads and size/timestamp changes, create, remove, rename, in-pass directory attributes, cookies/verifier, resident RO buffered reads, guarded buffered writes, KOIO mappings/completion, and statfs. It maintains a weak MFT-ref identity table and uses macOS 27 `tryReclaim`, with the macOS 26 protocol path preserved. Compressed/encrypted P0 items stay inhibited and reject write-open, size change and buffered writes with EPERM.

After activation, engine device operations use fixed-sector FSBlockDeviceResource metadataRead/metadataWrite, synchronous metadata flush, and purge engine-touched file-data sectors around direct KOIO. Pre-mount operations use ordinary reads/writes. Requests to a given metadata sector always have the same offset/length; partial sectors use RMW. The bridge remains the only engine ABI used by Swift.

T7-R2 append-only ABI additions supply getattr, remove(file/empty directory), statfs, size/times setattr, and POSIX rename. Existing signatures are unchanged. Setattr applies size before explicit times because upstream truncation otherwise overwrites requested mtime. No upstream source was patched.

Plain SwiftPM tests compile the **actual** Module volume/device/item source through three source symlinks, not a second implementation. Final `swift test --package-path Packages/NTFSCore` exited zero: **17 probe/policy tests, 3 Swift volume-logic tests, and 18 BridgeConformanceTests**, including all 100,028 fixture-entry ntfscat comparisons. Bridge suite duration: **314.709 s**. Unit coverage pins weak identity reuse, no strong retention of dead items, stale reclaim protection, RW/RO resident routing, compressed/encrypted write rejection, and allowlist fail-closed decisions. Bridge additions cover metadata-operation remount persistence, empty/new/shrunk-file KOIO writes, existing resident read-map/append preservation, and RO resident no-conversion/no-device-writes.

An intermediate added assertion incorrectly expected the NTFS dirty bit to remain set **after** `nb_sync`. Reading `ntfs_sync_fs` established that TT clears it at a successful durable checkpoint; that assertion was corrected to expect clean checkpoint flags. This was a test-assumption failure, not presented as a new proven engine defect. Promotion now sets the in-core dirty flag before its metadata mutation, matching other TT mutators.

The final source also built with Release-Direct (`xcodebuild` exit 0), and its built app passed `codesign --verify --deep --strict`. It was **not reinstalled or notarized again** after the controller stopped transport experiments. The SDK 27 completion-status header is annotated nonnull despite documenting nil for success; the deliberately Optional Swift parameter therefore emits a nullability warning. Xcode also emitted “command failed with exit code 0” alongside that warning while the overall build exited 0. These diagnostics are disclosed, not claimed warning-free. Task 7 ran plain tests only, not another sanitizer matrix.


## Wedge incident and causal evidence

### Timeline

1. **04:43:49** — First Task 7 signed/notarized install, UUID `F5220637-0611-46A6-A84B-3D7FB40F6758`; current-user fskit_agent PID 84907 restarted with timestamped settings backup. A native Apple RO mount occurred during discovery. Explicit Yuzu load returned EAGAIN: SDK `FSUnaryFileSystem.loadResource` requires clearing container state to `.ready`; that omission was corrected.
2. **04:46:14** — Corrected install, UUID `D782EC36-0128-43C0-9CA1-F433E964D3C6`; restart PID 60409, backed up first. An old probe endpoint then returned XPC4099 / invalid destination port. A controller-authorized SIGTERM to the verified current-user installed Yuzu probe allowed the next explicit Yuzu mount to succeed.
3. **04:46:17 safety slip** — A manually typed read-only mount command referenced disk9 although the fresh attach had returned disk13. Probe failed with NTFSProbeError; no successful mount or write occurred. disk9 was already absent when inspected. The mistake is not concealed: every subsequent device mount/write command derives and checks its identifier from hdiutil's image mapping. Do not reuse recorded disk numbers.
4. **04:47:07** — Real explicit Yuzu RO mount at `build/r3/mountpoint`: `ls -la` succeeded, reported modes 0644/0755 rather than Apple's 0777 presentation, and `stat` of nonresident.bin returned 4194427. Resident data was readable, but a complete manifest comparison was not performed. Unmount/detach succeeded.
5. **04:47:28** — Temporary image copy, fixture serial `4C1003685FD44DA4` allowlisted before attach; explicit Yuzu RW mount succeeded, diskutil reported WritableVolume=true. `/bin/cp nonaligned-source.bin mountpoint/nonaligned.bin` blocked. Its payload was exactly 1,000,003 deterministic bytes. Python's command timeout sent SIGKILL to cp but could not reap the kernel-U process; the overall test was interrupted at 90 seconds. The serial was revoked in cleanup.
6. **04:49:12** — Sample of serving extension PID 65902: main run loop idle, TT writer thread waiting on a condition variable, ntfs-bg-io worker waiting, dispatch worker idle. There was no active Swift/bridge data operation. **04:50:57** cp sample showed `fcopyfile → copyfile_data → write`, not a userspace copy loop or bridge lock wait. `ps` reported cp PID 65911, UID 501, state U, wchan `-` (no decoded kernel wait-channel name).
7. Controller approved terminating only the installed, current-user extension serving this disposable image. SIGTERM did not exit it; SIGKILL removed it, but cp remained U. Force-unmount had also hung. Independent exFAT diskutil mount and later fresh NTFS image attach stalled. No fskitd/root process was killed, no sudo/security changes/reboot was attempted.
8. **04:56:37** — Resident-routing correction signed, notarized, stapled and installed, UUID `EE4ED92B-6C00-4AB4-A105-FEA38D8F1D53`; current-user agent PID 63901 restarted after backup. FSClient reported enabled=true. A fresh `mount-test2.img` attachment never returned to the test within 90 seconds. Final inventory shows it attached, without a mountpoint. Consequently the requested next-write log-stream/stack capture could not start: execution never reached the mount/write step.
9. Controller stopped all further mount/attach attempts. Code/unit tests and offline engine verification continued. The final weak-table/policy test extraction and scratch-buffer reuse were not reinstalled; rebuild the final source after reboot.

Unified-log excerpts support the lifecycle/endpoint findings:

```text
04:44:05.126 YuzuNTFSModule[60585] unexpected container state ... NSPOSIXErrorDomain Code=35
04:46:23.357 fskitd ... mach_error=[0x10000003: (ipc/send) invalid destination port]
04:46:23.357 fskitd ... checkIn ... NSCocoaErrorDomain Code=4099
```

Durable sample extracts (full local captures: `build/r3/hung-write.sample.txt`, `build/r3/hung-cp.sample.txt`):

```text
YuzuNTFSModule[65902]:
  main → NSRunLoop → mach_msg2_trap
  writer_main (tt_platform_pagecache_pagecache.c:1172) → __psynch_cvwait
  worker_main (tt_platform_src_work.c:50) → __psynch_cvwait
  dispatch worker → __workq_kernreturn
cp[65911]:
  fcopyfile → copyfile_internal → copyfile_data → write
```

### Root-cause analysis and bounded fix

The initial implementation inhibited resident items, including newly created empty files. macOS 27 accepted their creation, then streaming writes blocked in kernel writeback without sending data upcalls. This matches the previously documented [NTFSKit mixed-KOIO hazard](https://github.com/whereteam/ntfskit/blob/96ecccb1b1f6dba2ecd158ed0ff9a21e7917c80d/NTFSModule/NTFSVolume.swift#L1033-L1038). Extension samples exclude an actively blocked Swift callback/bridge mutex at the sampled time. The causal classification is supported by that mechanism plus the matching zero-upcall symptom; a corrected mount is still required to conclusively demonstrate resolution here.

Controller rulings T7-R3/R4 amend the original resident-ENOTSUP ABI policy:

- New ordinary regular files convert their empty $DATA to nonresident at create.
- Existing RW uncompressed/unencrypted resident items are published as KOIO-eligible. First blockmap, **read or write**, converts them before supplying extents, preserving original bytes and EOF. Lookup/getattr/enumeration do not promote.
- RO resident reads stay inhibited and use the buffered handler without conversion. Compressed/encrypted items remain inhibited and cannot be written in this P0.
- Conversion of existing data marks the volume dirty, occurs under the inode/MFT locks and is synced before mapping; all earlier allocation, uninitialized-size, sparse zeroing and exact-byte completion semantics remain in force.

An exploratory truncate-to-4096-then-zero approach failed because TT re-residentizes on shrink. It was replaced, not retained as a workaround. Regression tests now cover actual post-shrink write behavior irrespective of residency.

**Open P1 design issue:** promoting an RW resident file on its first read is a metadata mutation. Investigate promotion only at write-open with OpenClose operations and whether FSKit honors a dynamic per-item inhibit-attribute change. Do not silently treat this P0 policy as the final product design. macOS 27's new Handler/DataCacheHandler path is not implemented; this spike uses the SDK's compatible deprecated Operations protocols for deployment on 26.

## Resume after owner reboot (not yet executed)

First confirm the owner rebooted and the old cp U-state/image attachments are gone. Do not attempt daemon kills or another mount in the wedged session. Work only in this worktree, never with physical disks.

### 1. Rebuild final source, sign/notarize/install, re-enable

```sh
cd /Users/rom/Projects/yuzu-ntfs-p0
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test --package-path Packages/NTFSCore
scripts/setup-signing.sh
xcodegen generate
xcodebuild -scheme YuzuNTFS -configuration Release-Direct -derivedDataPath build/r3 build
```

Zip the built app to a **new** zip filename, submit, staple, install with ditto, and unregister only known local build copies as in `p0-r1-enable.md`. The `yuzu-notary` keychain profile is absent on this Mac; controller approved the existing ASC key directly, without modifying keychain profiles:

```sh
ditto -c -k --keepParent 'build/r3/Build/Products/Release-Direct/Yuzu NTFS.app' build/r3/YuzuNTFS-resume.zip
xcrun notarytool submit build/r3/YuzuNTFS-resume.zip \
  --key /Users/rom/.appstoreconnect/private_keys/AuthKey_5Y9N24UTB9.p8 \
  --key-id 5Y9N24UTB9 --issuer e8671c23-6675-4e90-84ff-ce9e70887b9a --wait
xcrun stapler staple 'build/r3/Build/Products/Release-Direct/Yuzu NTFS.app'
ditto 'build/r3/Build/Products/Release-Direct/Yuzu NTFS.app' '/Applications/Yuzu NTFS.app'
pluginkit -r "$PWD/build/r3/Build/Products/Release-Direct/Yuzu NTFS.app/Contents/Extensions/YuzuNTFSModule.appex"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "$PWD/build/r3/Build/Products/Release-Direct/Yuzu NTFS.app"
"$LSREGISTER" -f '/Applications/Yuzu NTFS.app'
pluginkit -a '/Applications/Yuzu NTFS.app/Contents/Extensions/YuzuNTFSModule.appex'
pluginkit -e use -i com.bluecoral.vn.yuzuntfs.fsmodule
pluginkit -mADvvv -i com.bluecoral.vn.yuzuntfs.fsmodule
python3 spikes/r1/tt-self-enable.py
build/r1/FSClientProbe
```

Record the new UUID and **each** agent restart. The helper backs up enabledModules.plist, preserves all existing entries byte-for-byte when ours is already present, and restarts only the current user's agent. Never reload while any Yuzu/user volume is served. Wait for enabled=true and resolve stale probe endpoints only under the same scoped controller authorization; a restart alone is not readiness proof. Verify installed codesign/Gatekeeper as in R1.

### 2. Fixture correctness, before throughput

Use a new copy of `fixtures/basic-512.img` and a new empty mountpoint below `build/r3/`. In a test script with `try/finally`:

1. Parse bytes 72–79 little-endian after verifying NTFS OEM signature; write its 16-digit hex serial to the sandbox allowlist while preserving unrelated lines. Always remove that serial in finally, including timeout/attach failures.
2. `hdiutil attach -nomount -plist <new-image>`; obtain the device **from that result**, then verify `hdiutil info -plist` maps it to this exact image under this worktree before **every** mount/write command. No manually typed or reused disk identifiers.
3. Capture image SHA-256. Explicit `/sbin/mount -F -t yuzuntfs <derived-device> <new-mountpoint>`; `ls -l` and `stat` resident.txt only; unmount, hash again, require equality. Any automatic system write must be investigated rather than waved through as promotion.
4. Remount; read resident.txt and nonresident.bin and compare their size/SHA-256 against the fixture manifest (and ntfscat bytes). Append known bytes to resident.txt, fsync, unmount/remount, and verify original bytes plus append exactly. This proves existing-resident write routing as well as read routing. Check cp/ls/rm and a Finder copy on this disposable image.
5. Generate exactly 1,000,003 deterministic nonzero source bytes. Copy through the mounted volume with Terminal `cp`; fsync destination, unmount/remount, then run:

   ```sh
   stat -f%z "$MOUNT/nonaligned.bin"   # must print 1000003
   cmp "$SOURCE" "$MOUNT/nonaligned.bin"  # exit 0
   ```

   Also assert pread at EOF returns no bytes. For a visible zero-tail test, grow this disposable file to its next cluster boundary, fsync/remount and assert every newly exposed byte is zero, then restore the exact original length and repeat stat/cmp. This is pending mounted verification, not the already-green raw-engine test.
6. Keep a bounded log stream during the first corrected write (`process == "YuzuNTFSModule" OR subsystem BEGINSWITH "com.apple.fskit"`), record extension PID and sample if stalled, and `ps -o pid,uid,state,wchan,command -p <copy-pid>`. Avoid another unbounded Python wait for a kernel-U child. If it wedges again, revoke serial first and escalate; no daemon/reboot workaround without owner action.
7. Cleanly unmount/detach; remove fixture serial even on failure. Retain only evidence, not a background log stream or helper process.

### 3. Dedicated 8 GiB images and benchmark rows

Create partitionless image files under `build/r3/`; never format a device not derived from a freshly attached owned image. An exFAT image was successfully created using an 8 GiB truncated regular file, `hdiutil attach -nomount -plist`, then `/sbin/newfs_exfat -v YUZUR3EXFAT <derived-device>` (no sudo). `hdiutil create` formatting returned EPERM on this host, so don't silently switch to physical media. For NTFS, truncate a new file to 8 GiB and use `tools/bin/mkntfs -F -Q -L YUZUR3NTFS <image-file>` while detached.

From the worktree root, with images detached and fresh empty mountpoints:

```sh
BENCH_IMAGE="$PWD/build/r3/bench-ntfs.img" BENCH_FSTYPE=yuzuntfs \
  scripts/bench.sh "$PWD/build/r3/bench-yuzu-mount" Yuzu-E2
BENCH_IMAGE="$PWD/build/r3/bench-exfat.img" BENCH_FSTYPE=exfat \
  scripts/bench.sh "$PWD/build/r3/bench-exfat-mount" Apple-exFAT
```

The harness grants the fixture serial before initial mount, derives and rechecks its image device, and revokes on exit **before** unmount cleanup. Native exFAT uses `diskutil mount -mountPoint` because this host's explicit `mount -F -t exfat` reported “does not support operation mount”; the non-F native helper instead attempted kmutil and failed permissions. Never add sudo to make the baseline work.

For Apple's NTFS read-only baseline, first preserve a separate NTFS image containing the 4 GiB benchmark file. Try explicit native read-only selection on that **image**, verify mount identity is Apple's `ntfs`, and record impossible if native selection cannot be forced safely. R2 did not establish a working post-precedence force-native recipe. `BENCH_FSTYPE=ntfs BENCH_READONLY=1` exposes the explicit attempt; an error is not a native benchmark. Do not relabel a Yuzu RO mount as Apple. Do not disable unrelated modules or edit global discovery metadata just for a timing row.

Save all emitted rows, compute per-workload median of five runs, and fill this table only from actual results:

| Driver | Runs | Seq read MiB/s median | Seq write MiB/s median | Copy 10k×4KiB s | ls 100k s | rm 100k s | Extension CPU % |
|---|---:|---:|---:|---:|---:|---:|---|
| Raw backing file | 5 | 10559.323 | 11963.303 | N/A | N/A | N/A | N/A |
| Apple exFAT image | 0 | BLOCKED | BLOCKED | BLOCKED | BLOCKED | BLOCKED | N/A |
| Apple NTFS RO image | 0 | BLOCKED | N/A | N/A | BLOCKED | N/A | N/A |
| Yuzu E2 KOIO image | 0 | BLOCKED | BLOCKED | BLOCKED | BLOCKED | BLOCKED | BLOCKED |

Only then compare Yuzu read/write medians with raw and issue a **provisional image-only** R3 verdict; physical SSD and macOS 26 remain PENDING-OWNER.

## Remaining owner-visible state

At final read-only inventory, project attachments were `build/r3/exfat.img` (disk8), `build/r3/mount-test.img` (disk9), and `build/r3/mount-test2.img` (disk10), none with a mountpoint. **These identifiers are historical only.** cp PID 65911 remained UID 501/state U; its SIGKILL could not complete while blocked in kernel write. No owned log stream, diskutil/hdiutil timeout client, or serving Yuzu extension remained. No source fixture was modified. The sandbox allowlist was empty. Do not delete backing files while attached; owner reboot, then re-inventory before cleanup. No system daemon, physical disk, security setting, or other repository was changed.

## Code-only review correction, round 1

Before resuming mounted writes, four review findings were corrected in source: successful root/lookup/create publication now shares the identity/reclaim critical section through the SDK reply; each live item pins its core inode until successful reclaim (append-only `nb_hold`/`nb_release`); rename replacement acquires both source and target I/O guards in stable MFT-ref order; and completions release only their own operation ID. Round 1 also made cached completions wait behind an explicit operation; **round 2/T7-R5 removes that incorrect wait**, as documented below. Their cache purge still obtains its own physical mapping rather than clearing another operation's extents. Fragmented mappings consume ENOBUFS prefixes and continue in bounded 128-extent batches.

Deterministic unit regressions exercise publication exclusion, unrelated/unspecified completion ownership, real pinned replacement/unlink with MFT-reuse attempts and deferred cluster freeing, and an actual bridge-fragmented file with more than 128 extents. This round performs no mount, attach, app build, signing, installation or daemon operation. Its final plain test result and commit are appended to the Task 7 report; the mounted R3 verdict remains **BLOCKED-PENDING-REBOOT**.

Final round-1 plain verification (`swift test --package-path Packages/NTFSCore`, exit 0): **17 probe/policy + 7 actual Swift glue + 18 bridge tests**; full fixture-entry ntfscat verification passed, bridge duration **304.572 s**. This supersedes the pre-review three-test glue count above. No additional app build or mounted verification is claimed.

## Code-only review correction, round 2 — completion arrival ordering

T7-R5 supersedes round 1's cached-completion wait. Each item's separate completion lock serializes already-arrived metadata completions; a cached `.unspecified` completion is applied immediately without waiting for an unrelated outstanding explicit mapping. The I/O-state lock still protects metadata/extent state, and only a matching explicit operation ID releases that mapping lease.

The real-image regression drives **`completing` itself**: VDL=4096; a retained cached mapping covers [4096,8192), explicit owner B covers [8192,12288); both payloads land; cached completion is delivered before B. Before the fix it waited, B zeroed the lower gap, and remounted bytes were wrong. After the fix the cached metadata completion advances VDL to 8192 before B is applied, so B's gap zeroing cannot erase those completed bytes. The test also verifies B retains its ID/extents until its own completion and checks the entire 12 KiB file after offline unmount/remount. Focused Swift glue verification passed all **8** tests. No host mount/attach/install was attempted.

### Open P1 issue: physically landed but unreported beyond-VDL writes

The reverse/unreported case remains unresolved by this P0 ABI: a lower cached write may physically land beyond VDL while a higher range's completion reaches `nb_complete_io` first. The higher completion's zero_gap can erase the lower payload before the lower completion is reported. The engine cannot distinguish such unreported valid bytes from recycled/uninitialized disk contents; simply skipping zeroing would expose stale disk data. Arrival-order processing fixes the **delivered-first** case, not this stronger guarantee.

Two candidate P1 designs require investigation: (1) track outstanding/retained mappings beyond VDL in the volume and defer gap zeroing until those writes complete, with the necessary validity/lifetime semantics; or (2) never hand out **cacheable** mappings beyond VDL. Controller ruling T7-R5 explicitly defers this pending-write/validity design rather than inventing a new ABI in P0. The limitation is also documented beside the T5-R2 gap-zeroing contract in `ntfs_bridge.h`. It is not a production-safety or out-of-order/unreported-write guarantee. R3 remains **BLOCKED-PENDING-REBOOT**.

Final round-2 plain verification (`swift test --package-path Packages/NTFSCore`, exit 0): **17 probe/policy + 8 Swift glue + 18 bridge tests**. Bridge suite and all fixture-entry ntfscat comparisons passed in **305.746 s**. This supersedes round 1's completion-wait policy and seven-test glue count; it does not change the mounted gate verdict.

## Final-review safety restrictions (F-R1/F-R2)

Already-sparse on-disk files now follow the compressed-file P0 restriction: readable, but not write-openable, not size-changeable and not KOIO-write eligible. The bridge independently rejects data writes, write mappings and write completion with EPERM. The earlier sparse-hole materialization/rollback implementation remains guarded code, not an authorization path. Its publication ordering was unsafe against TT's background writeback; the P1 implementation must allocate detached clusters via lcnalloc, zero and flush them, then insert their runlist/mapping pairs. Merely deferring mapping-pair updates or gating the writer is insufficient. E8's initialization-plus-rollback fault is moot under this cutover: no P0 caller can reach sparse materialization, and the fixture-only sparse constructor does not bypass write guards.

Ordinary `truncate`/size-setattr growth is explicitly different: it allocates real clusters with HOLES_NO, preserves the non-sparse flag, updates EOF and leaves VDL unchanged. Reads of the uninitialized extension return zeros; later completed writes use T5-R2 gap initialization. Raw mapping preallocates with the original EOF rather than expanding and fallibly restoring sizes. A 64 KiB growth/zero-read/later-4096-offset-KOIO-write/remount regression covers this distinction.

The Swift volume latches an effective read-only transition before resident eligibility and write-open/write-mapping authorization. Already-issued kernel mappings cannot be revoked with this ABI; completions must still be answered, invalidate cached data, and return the core's EROFS without advancing EOF/VDL. No claim is made that previously issued mappings cannot physically write after the transition.

Benchmark control now runs in a separate non-mounted-I/O supervisor with a total deadline (`BENCH_TIMEOUT`, default 1800 seconds) and SIGINT/SIGTERM handling. It revokes the serial before signaling only its owned worker process group, does no blocking reap/forced teardown after deadline, and reports the PID/group and potentially surviving image attachment. Signature mismatches are rejected before authorization; mounted backing device/type/mountpoint are verified before workloads. `seqio write` uses O_NOFOLLOW, requires a regular descriptor before truncation, and cannot write devices. Only headless tests exercised these safety changes; the benchmark itself was not mounted or run.

The host reboot, owner-dependent hardware/macOS 26 checks and corrected mounted-write acceptance remain outstanding. See the final fix report for per-finding evidence and any remaining coverage gaps.

### Reply-path hardening and namespace lifetime

The final-review continuation rejects negative/overflowing I/O ranges before conversion and before waiting for item state, and rejects invalid FSItem types instead of force-casting. Explicit mapping contention is answered with EBUSY rather than waiting for another callback. This does **not** apply to unlink/rename replacement: those namespace operations proceed immediately and existing inode pins defer physical reclamation. Size changes reject only an explicit in-flight extent overlapping the tail of an actual shrink; growth, completed operations and retained cached mappings do not own such a rejection lease. The SDK's setter contract (`FSVolume.h:665–688`) does not promise a drain, while `FSVolumeExtent.h:139–142` explicitly allows retained mappings to be reused.

The latest final-source matrix passed 17 probe/policy + 17 glue + 25 bridge tests plain, under ASan and under explicitly runtime-linked UBSan, plus the Debug app build. Actual-handler reply-once coverage is broader but remains incomplete for filesystem resource handlers, enumeration and real SDK buffer/packer branches. These green checks are not permission to resume mounted tests or a proof that every callback path is hang-free; see the final fix report's uncovered-path table.
