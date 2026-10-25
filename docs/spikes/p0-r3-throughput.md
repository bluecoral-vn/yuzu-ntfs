<!-- SPDX-License-Identifier: GPL-2.0-only -->
# P0 R3 — FSKit RW and image throughput

## Verdict

**macOS 27 VM functional gate: PASS under controller ruling M-R1.** The
sector-covering KOIO fix passes resident append/remount, nonaligned
1000003-byte copy/EOF/remount, VDL zero tails, ADS refusal and the documented
retained-mapping RO boundary. Physical-SSD and macOS 26 acceptance remain
pending. Benchmark results and their separate V-R3 mount-time rule are
reported in [Append corruption root cause (2026-10-25)](#append-corruption-root-cause-2026-10-25).
The pre-reboot kernel wedge and the failed intermediate candidates below
are historical evidence, not the current mounted-functional verdict.

| Gate/environment | Read | Write | Verdict |
|---|---:|---:|---|
| macOS 27 internal-SSD image, raw backing file | 10,559.323 MiB/s median | 11,963.303 MiB/s median | Measured; not a physical-device baseline |
| macOS 27 Yuzu KOIO, isolated VM | Functional PASS | Functional PASS under M-R1 | Performance: V-R3 benchmark section below |
| macOS 27 Apple exFAT, isolated VM | V-R3 benchmark below | V-R3 benchmark below | Comparison uses the same guest virtual disk type |
| macOS 27 Apple NTFS image | Not measured in VM | Read-only / N/A | No native-NTFS throughput claim |
| Physical SSD, macOS 27 | PENDING-OWNER | PENDING-OWNER | No physical device used |
| macOS 26 | PENDING-OWNER | PENDING-OWNER | No macOS 26 VM available |

The historical host raw-file numbers are not a guest/physical-device denominator. V-R3 measures guest raw backing files, Apple exFAT and Yuzu separately, including mount latency; only observed timed workloads may be compared. Image/VM results cannot close the physical-SSD/macOS-26 gate.

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

Command per row: `tools/seqio write|read build/r3/raw.img 4294967296`. The historical helper used O_TRUNC. The current helper opens without O_TRUNC, uses O_NOFOLLOW/O_NONBLOCK, verifies the opened descriptor is a regular file with fstat, then ftruncate; **never point raw writes at a formatted image or a device**. Raw JSON capture is in ignored `build/r3/raw-results.json`.

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

### 1. Isolate media BEFORE reboot

Disconnect all NTFS disks before reboot and keep them disconnected until installation,
duplicate pruning and readiness verification are complete. The old `/Applications` module
can claim media immediately after boot; an empty RW allowlist does not disable probing.
**Quitting the menu-bar app is not a kill switch.** Do not run any live steps below on
the currently wedged host. No daemon/device teardown is a substitute for recovery.

### 2. Finish candidate builds before registration

Build/sign/notarize a fresh committed Release-Direct candidate using the existing R1
signing procedure; the old staged `build/release` artifact predates this QC wave.
Both built Info.plists now embed `YuzuGitCommit`; version/build remain 0.1.0/1 (D1).
The build asserts the processed extension's `FSSupportsKernelOffloadedIO=true`.
There is no established working registration opt-out in Xcode 27.1: testing
`REGISTER_APP_WITH_LAUNCH_SERVICES=NO` still ran RegisterWithLaunchServices, so
the ineffective setting was removed. Swift Build's macOS app registration producer
has no suppression-setting guard. Inventory all registrations, including the final
`/tmp/yuzu-qc-fix-dd/Build/Products/Debug/YuzuNTFS.app` and earlier `/tmp/yuzu-qc-dd`
builds. Manual discovery can rediscover unpacked duplicate apps. Keep unused
candidates as archives, not discoverable app bundles; never build during acceptance.

Build and team-sign the readiness probe without running it. The helper selects an existing Developer ID certificate by installed fingerprint and certificate OU, verifies `TeamIdentifier=37PX6W22C5`, and performs no app registration:

```sh
scripts/build-fsclientprobe.sh
```

Do not use raw `swiftc` as a replacement: it leaves an ad-hoc probe, and FSClient's caller-team filtering can hide Yuzu even when the installed module is enabled. Operator commands reject a missing/wrong-team probe signature before using its readiness result.

### 3. Preflight, install, exercise rollback, enable (media still disconnected)

From the worktree root, first inspect each `--dry-run` transcript. Dry-run executes
no control command and changes no authorization/settings/registration state.

```sh
scripts/p0-preflight.sh --dry-run
scripts/p0-install.sh --dry-run --staged 'build/release/Yuzu NTFS.app'
scripts/p0-disable.sh --dry-run
scripts/p0-enable.sh --dry-run
scripts/p0-preflight.sh
scripts/p0-install.sh --staged 'build/release/Yuzu NTFS.app' --expected-commit FULL_APPROVED_40_HEX_COMMIT
scripts/p0-disable.sh
scripts/p0-enable.sh
```

Preflight requires a boot newer than the recorded wedged-session timestamp OR no
state-U processes; PID 65911 must be absent even if reused. It refuses historical
`build/r3/{exfat,mount-test,mount-test2}.img` attachments, active/unknown FSKit-capable
mounts, and a nonempty or malformed RW allowlist. Owner ruling Q-R4 exempts exactly
one Apple CoreDevice mount: type `devicefs`, mountpoint
`$HOME/Library/Developer/CoreDevice/DeviceFS`, source
`devices -- file://$HOME/Library/Containers/com.apple.CoreDevice.CoreDeviceService/Data/`.
A second DeviceFS or any other FSKit/unknown user transport still blocks. This
exception does not authorize mounting or changing CoreDevice registrations.
Owner ruling Q-R5 classifies kernel-native `nullfs` (including AppTranslocation),
`msdos` and `exfat` without an `fskit` mount flag as safe for agent refresh, like
the existing native types. An `fskit` flag always blocks except the exact Q-R4
exception; Yuzu/NTFS and unknown transports remain blocked even without that flag.
Every external command has a deadline and failure stops the procedure.

Install inventories `pluginkit -mADvvv` plus all Yuzu-identifier `.app` bundles in
the worktree and `/tmp/yuzu-qc*`, including currently unregistered duplicates.
It validates every candidate's bundle identity and isolation scope **before**
changing registration state; any outside-worktree/outside-QC-temp path, alias
or unverifiable parent is listed for the operator and makes installation stop.
Historical external DerivedData copies must be isolated by the operator if reported;
the script never deletes them without authorization. There is no LS database reset.
After scoped unregistering and copying to `/Applications`, the installer verifies
the executable SHA-256, both git identities, KOIO, signature and Gatekeeper. Only
then does it archive **every known noninstalled Yuzu bundle, including staging**,
verify each zip with `unzip -t`, and remove its unpacked bundle. Archives live in
`build/archive/`; do not unpack them during testing. A failed archive check preserves
the unpacked source and prevents final registration/refresh. It repeats inventory,
registers the installed app last, requires exactly one `/Applications` entry,
records its UUID, and only then refreshes the current user's `fskit_agent`.
FSClientProbe must show enabled=true at the exact installed URL.

Enable/disable back up `enabledModules.plist`, merge/remove only Yuzu's string and
preserve all unrelated entries. Both refuse active FSKit-capable mounts before any
settings change or refresh. Disable requires FSClientProbe to show Yuzu absent or
disabled. It is a **no-active-volume rollback/kill switch**, not live write revocation.
If disabling is refused because a volume is active, revoke its allowlist admission,
stop the workload under its supervisor and arrange a clean unmount/recovery; do not
force-kill filesystem daemons. A backup path and inverse script are printed.
`pluginkit -e ignore` alone and deleting the allowlist alone are NOT disablement.
After verified disablement, any optional Apple-driver rollback probe must use a
freshly derived disposable-image device and assert `FilesystemType=ntfs` plus
`ReadOnlyVolume=true`; no native-driver rollback result is claimed here.

### 4. Guest acceptance, before throughput

Run the first RW acceptance inside an isolated macOS lume VM with this worktree,
fixtures and the installed candidate available in the guest. Do not send live
commands back to the host. The script requires `kern.hv_vmm_present=1`; its only
host override, `--allow-host-readonly`, runs exclusively the RO subset and no bench.

```sh
scripts/p0-guest-acceptance.sh --dry-run
# Inside the recovered guest ONLY; dedicated >=8 GiB NTFS bench image, detached:
scripts/p0-guest-acceptance.sh --bench-image "$PWD/build/r3/bench-ntfs.img"
# Optional recovered-host RO subset, never a bypass for RW:
scripts/p0-guest-acceptance.sh --allow-host-readonly
```

Each phase uses the existing non-mounted-I/O supervisor, finite total/command
deadlines and parent-owned fixture authorization. On failure/timeout it revokes
before signaling its owned process group, reports surviving PID/possible image
attachments, never blocks reaping a state-U child and never force-unmounts/kills
filesystem daemons. Stop and investigate surviving attachments before another run.
The reusable supervisor restores the caller's signal mask and handlers before
returning its exit status, so later phases and their loggers remain interruptible.

The RO phase checks the resident SHA-256, observed buffered-read callback and
unchanged image hash. The RW phase verifies resident append/remount, the formerly
wedging exact 1,000,003-byte cp/stat/cmp/remount/EOF workload, 37-byte write then
ftruncate(8192) zeros and remount readback, ADS write-open refusal, and pre-latch
FD plus mmap writeback transitions. Logs must contain actual `blockmapFile` and
`completeIO`; a successful copy via an unproven transport is not acceptance.
Only after every gate succeeds does it invoke the existing bounded bench harness.
Evidence, fixture copies and callback logs are retained under `build/p0-guest/`.

The **P0-only** fault hook is
`~/Library/Containers/com.bluecoral.vn.yuzuntfs.fsmodule/Data/Library/Application Support/YuzuNTFS/p0-force-ro`.
Its presence latches effective RO on the next operation. Writes/map/completion
then reply EROFS; removing the file does not unlatch an existing volume. The guest
test removes it and remounts between FD/mmap cases. A stale hook makes a subsequent
acceptance refuse until explicitly removed. Remove this hook in P1 (Q-R2).
Read completions use the append-only non-mutating physical-extent query for cache
purges: they never call the read mapper, promote, pad VDL or write after the latch.
Eligibility is fixed at item publication (Q-R1), not flipped on RO. Previously
retained kernel mappings are **not physically revoked**; the guest gate deliberately
fails if cached FD/mmap writeback succeeds. T7-R5's unreported cached-write ordering
limitation is still open. The inhibited-write root cause remains inferred/plausible,
not proved fixed by headless tests; TT is a byte-copy engine oracle, not a KOIO oracle.

### 5. Dedicated 8 GiB images and benchmark rows

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

### Targeted re-review FR-1 / FR-2

FR-1 amends the final G1 gate to a complete static reply-path audit; runtime coverage remains supporting evidence rather than a claim that every SDK-mediated branch was exercised. The re-review found and this round corrects a stale EOF classification race: size setters now retain both item and volume locks continuously from current EOF read through overlap checking and mutation. Ordinary buffered gap growth also preallocates real clusters before TT writes, and low-level size growth now updates mtime/ctime and inode dirty bookkeeping.

The remaining narrowing/overflow sites are checked: resource geometry before allocation and bridge descriptor construction, NSError codes before Int32 conversion, reference IDs and enumeration cookies before offsetting, and logical/physical extents before signed SDK offsets. Geometry failures propagate through actual probe/load reply handlers. Existing ordinary lock/device/writeback dependencies are not a guarantee that a wedged kernel I/O will complete.

Benchmark authorization now belongs exclusively to the supervising parent. Signals are blocked across fork/setup; the worker cannot proceed before receiving a go-pipe token. Startup cancellation closes that gate and revokes authorization before attempting SIGTERM of the owned group. Signal-delivery denial is reported without escalation, blocking reap or forced device cleanup. This supersedes the earlier worker-granted authorization description.

FR-2 explicitly permits the repository's existing ad-hoc Debug build phase, but does not permit mounting, attachment, installation, notarization or host recovery operations in this wave. The transport/reboot prerequisite and unverified mounted-write gate remain unchanged.

Final FR-1 headless verification: 17 probe/policy + 24 glue + 27 bridge tests passed plain, ASan and explicitly linked UBSan; 4 benchmark-control + 2 seqio Python tests passed; the generated Debug app build succeeded (artifact 579). N1–N4/T1–T3 are addressed. No mounted/device-progress or original-kernel-wedge resolution is inferred from these results.

## Post-reboot install — 2026-10-24

**STOPPED at live preflight; no installation or registration/settings changes performed.**
The authorized candidate was built from `70df3979eb28b13b5d10a365bc6b55cf09019429`
before any install attempt. All build commands completed before live preflight;
no images were attached, no mounts requested, and no guest acceptance/benchmark run.

Commands and key outputs (worktree root; Xcode commands use
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`):

```sh
xcodegen generate
xcodebuild -scheme YuzuNTFS -configuration Release-Direct -derivedDataPath build/r1 build
# Corrected probe recipe; the historical run used raw swiftc here and omitted signing.
scripts/build-fsclientprobe.sh
ditto 'build/r1/Build/Products/Release-Direct/Yuzu NTFS.app' 'build/release/Yuzu NTFS.app'
ditto -c -k --keepParent 'build/release/Yuzu NTFS.app' build/release/YuzuNTFS-notary.zip
xcrun notarytool submit build/release/YuzuNTFS-notary.zip \
  --key ~/.appstoreconnect/private_keys/AuthKey_5Y9N24UTB9.p8 \
  --key-id 5Y9N24UTB9 --issuer e8671c23-6675-4e90-84ff-ce9e70887b9a \
  --wait --output-format json
# Accepted; ID f3e8437c-9c24-4121-a864-8e2db782617e
xcrun stapler staple 'build/release/Yuzu NTFS.app'
# The staple and validate action worked!
codesign --verify --deep --strict 'build/release/Yuzu NTFS.app'
# exit 0
spctl --assess --type execute --verbose=2 'build/release/Yuzu NTFS.app'
# accepted; source=Notarized Developer ID
```

The Developer ID-signed app has team `37PX6W22C5`, hardened runtime, and timestamp
`24 Oct 2026 at 23:17:55`. Both processed app/module `YuzuGitCommit` values equal
the full approved commit above; processed
`EXAppExtensionAttributes:FSSupportsKernelOffloadedIO` is `true`.
Staged module executable SHA-256:
`882554b13dff03569f70ebe79434c676d3ac2156c012758ad5d6842cbfd45c22`.
The build emitted the multiple-matching-destinations warning; a warning-free build
is not claimed.

All four runbook dry-runs (`p0-preflight`, `p0-install --staged
'build/release/Yuzu NTFS.app'`, `p0-disable`, `p0-enable`) completed without control
mutations. The subsequent **live** `scripts/p0-preflight.sh` exited 1:

```text
kern.boottime: Sat Oct 24 22:33:27 2026
devices -- file:///Users/rom/Library/Containers/com.apple.CoreDevice.CoreDeviceService/Data/
  on /Users/rom/Library/Developer/CoreDevice/DeviceFS
  (devicefs, local, nodev, nosuid, noowners, noatime, quarantine, nobrowse, fskit, mounted by rom)
P0 STOP: Active/unknown FSKit-capable volume: refuse settings/agent/registration changes
```

Per the explicit stop-on-preflight-failure instruction, no live installer,
disable/enable, DerivedData cleanup, registration pruning, daemon refresh or
post-install probe was run. Installed-vs-staged hash equality, exactly-one
registration, final RW allowlist and readiness are **not established** by this
attempt. Plugin UUID: **not collected (installation not attempted)**.
`mount` showed the existing CoreDevice FSKit mount above and no Yuzu volumes.
The signed/notarized/stapled candidate remains staged in `build/release`;
installation requires resolution of this preflight blocker under separate
authorization, not bypassing the guard.

### Q-R4 retry — 2026-10-24

Owner authorized the exact Apple CoreDevice DeviceFS exception, committed as
`6500c85` (`fix(ops): tolerate Apple CoreDevice DeviceFS during P0 agent refresh`).
The staged application was **not rebuilt**: its embedded approved app commit,
notarization ID and module hash above remain the candidate identity.
The guard exempts only one exact source/type/mountpoint tuple; any second DeviceFS,
wrong path/source/type or additional FSKit volume is refused.

The recorded-mount regression failed before the implementation. Afterwards:

```sh
python3 scripts/test-p0.py          # 12 tests: OK
python3 scripts/test-p0-install.py  # 4 tests: OK
python3 scripts/test-p0-phases.py   # 1 test: OK
python3 scripts/test-bench.py       # 4 tests: OK
python3 scripts/test-seqio.py       # 2 tests: OK
scripts/p0-preflight.sh            # exit 1; stop before installation
```

An initial `python3 -m unittest discover -s scripts -p 'test*.py'` found no tests
(exit 5, because these test filenames contain hyphens); the explicit commands
above exercised all five Python test files, **23 tests passed**.

The live inventory still contains two non-exempt unknown transports:

```text
/Applications/Sublime Merge.app on /private/var/folders/vf/l44gfxzd5bj3xhlpjlf9qy5w0000gn/T/AppTranslocation/8C44EA7B-5D66-423C-89D0-B9909247AEF8 (nullfs, local, nodev, nosuid, read-only, nobrowse, mounted by rom)
/Applications/Sublime Text.app on /private/var/folders/vf/l44gfxzd5bj3xhlpjlf9qy5w0000gn/T/AppTranslocation/6E552FE6-52A9-493A-8C41-88664FF17CA1 (nullfs, local, nodev, nosuid, read-only, nobrowse, mounted by rom)
P0 STOP: Active/unknown FSKit-capable volume: refuse settings/agent/registration changes
```

Q-R4 deliberately does not exempt `nullfs`, so the retry stopped without changing
these apps, mounts, registrations or settings. No live install, plugin UUID,
post-refresh DeviceFS-return observation or readiness result is available.
CoreDevice DeviceFS was present at the failed preflight; no refresh occurred.
No Yuzu volume appears in the recorded mount inventory. The original empty-
allowlist/final-hash/exactly-one-registration checks remain pending installation.

### Q-R5 live installation — 2026-10-25

Q-R5 corrected the guard's classification of kernel-native transports, committed
as `184d40b` (`fix(ops): classify kernel-native mounts separately from FSKit`).
Recorded Sublime AppTranslocation `nullfs` mounts now pass; their `fskit`-flagged
variants fail. Native-type flag variants and flagless Yuzu/NTFS/DeviceFS/lifs are
also covered. The new regression failed before implementation; all five explicit
Python test commands above then passed **24 tests** (13 + 4 + 1 + 4 + 2).
No app or probe rebuild occurred; the installed app remains the approved
`70df3979eb28b13b5d10a365bc6b55cf09019429` candidate.

```sh
scripts/p0-preflight.sh
# P0 PREFLIGHT PASS
scripts/p0-install.sh --staged 'build/release/Yuzu NTFS.app' \
  --expected-commit 70df3979eb28b13b5d10a365bc6b55cf09019429
# P0 PREFLIGHT PASS
# Refused external DerivedData/YuzuNTFS-ggixrolbwswkchdvpwinppvvteuz candidate before mutation.
pluginkit -r "$HOME/Library/Developer/Xcode/DerivedData/YuzuNTFS-ggixrolbwswkchdvpwinppvvteuz/Build/Products/Debug/YuzuNTFS.app/Contents/Extensions/YuzuNTFSModule.appex"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -u "$HOME/Library/Developer/Xcode/DerivedData/YuzuNTFS-ggixrolbwswkchdvpwinppvvteuz/Build/Products/Debug/YuzuNTFS.app"
/bin/rm -rf -- "$HOME/Library/Developer/Xcode/DerivedData/YuzuNTFS-ggixrolbwswkchdvpwinppvvteuz"
scripts/p0-install.sh --staged 'build/release/Yuzu NTFS.app' \
  --expected-commit 70df3979eb28b13b5d10a365bc6b55cf09019429
```

The only `YuzuNTFS-*` DerivedData directory present was removed under Q-R3.
The retry copied to `/Applications`, verified installed/staged binary hash and
both git identities, strict deep signature and Gatekeeper
`accepted; source=Notarized Developer ID`, then archived/zip-tested/removed seven
unpacked worktree candidates (including staging). No LaunchServices reset or
other application's registrations were changed. The stapled staged candidate
is preserved in `build/archive/Yuzu NTFS-1792864144590595000.zip`.

Final registration: **exactly one**, URL
`/Applications/Yuzu NTFS.app/Contents/Extensions/YuzuNTFSModule.appex`,
UUID **`798BF996-E6FE-4AB2-B806-C6F25DDF293C`**. Installed executable SHA-256:
**`882554b13dff03569f70ebe79434c676d3ac2156c012758ad5d6842cbfd45c22`**,
identical to the pre-install staged value. Final `codesign --verify --deep
--strict` exited 0 and final `spctl --assess --type execute --verbose=2`
reported `accepted; source=Notarized Developer ID`. Installed processed module
metadata still has `YuzuGitCommit=70df3979eb28b13b5d10a365bc6b55cf09019429`,
`FSSupportsKernelOffloadedIO=true`, version/build 0.1.0/1.

Installer backed up settings to
`~/Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist.yuzu-1792864145567367000.backup`
and refreshed only current-user `fskit_agent` PID **2722**. Comparing that backup
with the current plist proved all unrelated enabledModules entries unchanged;
Yuzu's identifier is present. **However the readiness gate failed**:

```text
FSClientProbe --expect-enabled --expect-path /Applications/Yuzu NTFS.app/Contents/Extensions/YuzuNTFSModule.appex
com.apple.fskit.exfat enabled=true ...
com.apple.fskit.msdos enabled=true ...
com.apple.fskit.ftp enabled=true ...
com.apple.dt.CoreDevice.Extensions.DeviceFS enabled=true ...
Yuzu absent, disabled, duplicated or wrong URL
P0 STOP: Command failed (1): .../build/r1/FSClientProbe --expect-enabled ...
```

The installer's bounded 30-second readiness retries never listed Yuzu. The
installer therefore exited **1**: installed and registered is **not ready/enabled
proof**, despite the plist election and single registration. Pluginkit renders
the installed version as `((null))` although its processed Info.plist contains
version 0.1.0/build 1; no cause is inferred. Read-only unified logs from the new
agent PID 81212 include `could not resolve URL while initializing a bundle record!`;
the private path is not exposed, so this is not proof of the readiness failure's
cause.

Final RW allowlist size: **0 bytes**. Final `mount` inventory contains **no Yuzu
or NTFS volume**. CoreDevice DeviceFS disappeared following the refresh and
remained absent throughout an additional bounded 30-second `/sbin/mount`
observation; its module was still enumerated enabled by FSClientProbe.
No manual remount, image attach, daemon escalation, registration reset,
guest acceptance, benchmark or build followed installation.
**Result: installation performed; readiness BLOCKED, not a completed enabled install.**

## Readiness diagnosis and correction — 2026-10-25

The Q-R5 readiness failure above was a **diagnostic caller-signing defect**, not evidence that the installed module was disabled. The recorded compile-only command had replaced `build/r1/FSClientProbe` with an ad-hoc/linker-signed executable (`TeamIdentifier=not set`). On this host that caller enumerated Apple modules and DeviceFS but omitted Yuzu. A copy of the **same executable**, changed only to a signature from the existing Developer ID team `37PX6W22C5`, immediately reported:

```text
com.bluecoral.vn.yuzuntfs.fsmodule enabled=true url=/Applications/Yuzu NTFS.app/Contents/Extensions/YuzuNTFSModule.appex
```

The isolated comparison at `00:55:23` used unsigned PID `97052` (exit 1) and team-signed PID `97053` (exit 0). The adjacent `fskitd` records identify the first caller's `getTeamIDForToken:` failure / `errno 2, retrieving team ID`; the signed caller's connection has no corresponding team-lookup error. This is a caller audit-token lookup, not a missing module provisioning profile.

`pluginkit -mADvvv` still showed exactly one elected installed module, UUID `798BF996-E6FE-4AB2-B806-C6F25DDF293C`. The installed signature/profile authorized the FSKit entitlement and team; its block/offloaded-I/O metadata and embedded git commit were not changed. The `((null))` PlugInKit version display did not prevent successful enumeration after signing only the caller. No agent refresh, module rebuild/reinstall, registration/reset, image attachment or mount was needed or performed for this correction. DeviceFS mount recovery and NTFS mounted behavior were not tested or inferred.

Use `scripts/build-fsclientprobe.sh` for all future probe builds. It builds/signs the standalone executable with a verified installed Developer ID certificate fingerprint and certificate OU, then checks its signature/team before replacing the previous probe. `p0_ops.py` now checks exactly one `TeamIdentifier=37PX6W22C5` record from `codesign -dvv` before either enabled or disabled readiness queries; an absent/wrong-team result is rejected with the build-helper instruction. Recorded-output Python regression tests cover unsigned, missing, wrong-team, malformed and duplicate team records plus guard-before-query ordering. This corrects **readiness enumeration only**; it does not close any RW, throughput, VM or no-Terminal acceptance gate.

Verification for this correction: `python3 scripts/test-p0.py`, `test-p0-install.py`, `test-p0-phases.py`, `test-bench.py`, and `test-seqio.py` passed **27 tests total** (16 + 4 + 1 + 4 + 2). `scripts/build-fsclientprobe.sh` successfully built and strict-verified the standalone probe using existing identity fingerprint `357630FEC1EA6B2B0871F13013DC8353D1107BC1` and required team `37PX6W22C5`. These checks do not run an installer, change registration/settings, or refresh the agent.

## Host read-only acceptance (2026-10-25)

The first authorized host RO attempt stopped before mounting: `hdiutil attach
-nomount -plist` returned valid XML followed by a stderr deprecation warning.
The operator runner had merged stderr into the plist response, causing
`ExpatError: junk after document element`. Evidence directory:
`build/p0-guest/0420c8bb-7d00-46e8-947f-ae054fd9b450`.
No timeout or mounted I/O occurred. A separate deadline-supervised cleanup
re-derived the sole owned device from `hdiutil info -plist` and cleanly detached
the image. The RW allowlist remained empty.

The runner now captures stdout/stderr separately while retaining diagnostics.
The RO gate also samples resident/nonresident hashes against the basic manifest,
all names-fixture hashes, and bigdir entries 0, 1, 49999 and 99999; it checks
the bigdir `ls -1 -A` count against 100000, logs actual mount identity, prints
before/after image hashes, and supervises the final no-attachment/no-U inventory.
Each fixture is a freshly copied, script-attached image; no RW admission,
benchmark, agent refresh or installed-module changes are part of this gate.
The recorded warning regression and manifest/sample regressions passed;
all six Python operator suites passed 31 tests (4 + 16 + 4 + 1 + 4 + 2).

The next authorized attempt reached the mount but stopped before file reads:
FSKit's `diskutil info -plist` returned the correct `DeviceNode`/`MountPoint`
but omitted `FilesystemType` and `ReadOnlyVolume`. Cleanup cleanly unmounted and
detached it. The separately supervised final audit found no owned attachment,
no state-U process and an empty RW allowlist. The image and pristine fixture
both hashed `f1f66e80cc137d09aa3f409973a2fe56a9ab756f4e0c103a8286a9e7c02bef5b`.
Evidence: `build/p0-host-ro-20261025.log`,
`build/p0-host-ro-final-audit-20261025.log`, and
`build/p0-guest/5fc6222b-0b00-4711-a944-55d281560a3c`.

The mount guard now requires an exact fresh-device/mountpoint `mount(8)` row,
filesystem type `yuzuntfs`, and the requested read-only flag. Any diskutil field
that is present must independently agree; absent fields cannot substitute for
mount identity. Regression tests cover the observed missing-field shape plus
wrong device/type, missing mount/RO flag, and contradictory diskutil RO metadata.
All six Python suites pass 32 tests (5 + 16 + 4 + 1 + 4 + 2).

### Final authorized live outcome: FAIL — nonresident RO read returned EBUSY

After both dry-runs and the two reviewed harness corrections, the final live
`scripts/p0-guest-acceptance.sh --allow-host-readonly` stopped on
`OSError: [Errno 16] Resource busy` while hashing `nonresident.bin`. This was
**not a timeout**. No further mount/read retries were made.

| Check | Result and observed evidence |
|---|---|
| Fixture-only, fresh script attachment | PASS — copied `basic-512.img`, freshly derived `/dev/disk12`; no real disk used |
| Our filesystem and RO mount | PASS — exact owned mount row below; diskutil agreed on device and mountpoint |
| Resident manifest SHA-256 | PASS — `4b2720d37f921134bfbb2deb27137d6f08fc55ced90f88c4971f5f42e06e1fc6` |
| Nonresident manifest SHA-256 | FAIL — read returned EBUSY before a complete hash; expected `e987c93a0a4837eaf02125d47e7ebf24dbe507cfc47a49c88e1f2f27492a9e8e` |
| Names hashes / bigdir samples / bigdir `ls` count | NOT REACHED — stopped at the first failed fixture; no extra attachments attempted |
| Serving-module callback evidence | PASS — installed `YuzuNTFSModule` PID 47328 emitted buffered read and read-only block mappings below |
| Image unchanged | PASS — pristine source/before and detached result both `f1f66e80cc137d09aa3f409973a2fe56a9ab756f4e0c103a8286a9e7c02bef5b` |
| Clean unmount + detach | PASS — supervised `umount` and `hdiutil detach` succeeded; final inventory found no owned attachment |
| RW allowlist empty | PASS — 0 bytes before/after every attempt and at final audit; no RW authorization path invoked |
| No state-U process afterwards | PASS — separately deadline-supervised final process inventory returned `[]` |
| Prohibited operations | NONE — no RW test, bench, agent refresh, rebuild/reinstall or real-media operation |

Exact mount evidence (the device number is historical evidence, never reusable):

```text
/dev/disk12 on /Users/rom/Projects/yuzu-ntfs-p0/build/p0-guest/26b7b675-ad7a-4d31-bf18-363e052d1f4f/basic-512-ro-mount (yuzuntfs, local, nodev, nosuid, read-only, noowners, noatime, fskit, mounted by rom)
2026-10-25 01:23:28.633 YuzuNTFSModule[47328] P0KOIO bufferedRead offset=0 length=512
2026-10-25 01:23:28.636 YuzuNTFSModule[47328] P0KOIO blockmapFile offset=0 length=1048576 write=false
2026-10-25 01:23:28.637 YuzuNTFSModule[47328] P0KOIO blockmapFile offset=1048576 length=1048576 write=false
```

Durable local evidence: `build/p0-host-ro-final-run-20261025.log`,
`build/p0-host-ro-final-run-audit-20261025.log`, and
`build/p0-guest/26b7b675-ad7a-4d31-bf18-363e052d1f4f/basic-512-ro-callbacks.log`.
The EBUSY cause is not established here; these read-only results do not close
the RO acceptance gate, RW, KOIO completion, VM or throughput gates.

### Code-only correction — read mappings do not own write leases (2026-10-25)

The earlier `5fc6222b-0b00-4711-a944-55d281560a3c` evidence directory stopped
at mount identity, before reads; its callback log has only the filter header.
The EBUSY read belongs to `26b7b675-ad7a-4d31-bf18-363e052d1f4f`:
`build/p0-host-ro-final-run-20261025.log:2349` records errno 16, and that
directory's `basic-512-ro-callbacks.log:4-5` records read blockmaps at 0 and
1048576 without an intervening completion. These logs do not record operation
IDs or per-callback reply errors, so they alone cannot prove ID values or that
the kernel would never complete a read.

The headless reproduction identifies the source: the pre-fix
`Module/YuzuNTFSVolume.swift:372` registered **every** explicit operation,
including reads. Its next different-ID blockmap hit the explicit EBUSY reply
at lines 368–369. `YuzuNTFSItem.normal` also rejected buffered reads while that
operation remained registered (line 55). Commit `70d2a9b` had replaced the
cross-callback wait with this nonblocking EBUSY guard, but had preserved the
incorrect read ownership. This is module lease admission, not an engine read
error; the two-map reproducer fails at the second mapping with errno 16.

Only explicit **write** mappings now register extents for shrink protection.
Read mappings neither acquire/append to that lease nor reject another mapping's
lease, and a failed read map cannot release a write lease. Existing write
contention still replies EBUSY immediately; shrink still rejects overlapping
outstanding write extents. No cross-callback wait was introduced.

Three actual-volume/real-engine regressions (four cases) use disposable offline
fixture copies, a test-only SDK resource/extent packer/data buffer, and no mount:

- RO and RW: map 0 and 1048576 with different explicit IDs, omit every
  `completeIO`, then buffered-read and map again; verify bytes and zero RO writes.
- Read-map then shrink and unlink: shrink succeeds, published inode pin retains
  the unlinked allocation, and another map resolves the same physical storage.
- Outstanding write then independent read-map/read-completion: only write
  extents protect shrink; overlapping shrink returns EBUSY until write completion.

All three regressions failed against the old code (five issues, including
second-read-map errno 16) and passed after the write-only lease correction.
The SDK 27 completion-status optionality warning remains unchanged.
No app/release build, registration, install or mounted retry is part of this
correction; the live RO acceptance gate remains open.

Final headless matrix: **17 probe/policy + 33 glue + 30 bridge tests** passed
in each of plain (449.700 s bridge), ASan (500.271 s bridge) and explicitly
runtime-linked UBSan (460.247 s bridge), with no sanitizer diagnostics.
All six Python suites passed **32 tests** (4 + 16 + 4 + 1 + 5 + 2).
Commands used:

```sh
swift test --package-path Packages/NTFSCore
swift test --package-path Packages/NTFSCore --sanitize=address
swift test --package-path Packages/NTFSCore --sanitize=undefined \
  -Xlinker /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang/21/lib/darwin/libclang_rt.ubsan_osx_dynamic.dylib
python3 scripts/test-bench.py
python3 scripts/test-p0.py
python3 scripts/test-p0-install.py
python3 scripts/test-p0-phases.py
python3 scripts/test-p0-readonly.py
python3 scripts/test-seqio.py
```

### Read-lease review correction R-R1 — partial-VDL interleaving

Allowing read blockmaps during a write lease exposed another interaction:
`EngineE2/internal.c` padded and flushed a partial VDL sector even when the
read requested a disjoint range. With VDL 37 and EOF 8192, a kernel write
could land bytes 37–511, then a read at either 0 or 4096 would erase them
before the write completion. The new exact-interleaving regression failed
on both offsets: one device write during the read, zeroed payload, and zeros
persisted after completion/remount.

Per ruling R-R1, lease presence is checked while holding the item I/O lock
continuously through the mapping call. An outstanding explicit **write**
selects append-only `nb_read_map_during_write`: no fsync, promotion, allocation,
zeroing or flush; DATA extends through the block-rounded VDL and UNINIT follows
that boundary. Completion remains responsible for the write's partial-sector
tail. Without a write lease, the original read-map zero/flush is retained:
unconditionally returning DATA would expose stale bytes from Windows-written
partial-VDL sectors. RO partial-VDL maps remain unsupported/inhibited.
Read maps still own no lease and never wait for another callback.

Regressions cover read offsets 0 and 4096 with an outstanding write (landed
payload survives completion and an RO remount), the same offsets without a
lease (poisoned tail becomes zeros while bytes 0–36 survive), and RO maps
(ENOTSUP, zero writes, buffered prefix/tail correct). Packed DATA/zeroFill
types are asserted; A2's aligned mapping boundaries remain unchanged.

R-R1 final matrix (same commands above): **17 probe/policy + 36 glue + 30 bridge
tests** passed plain (466.691 s bridge), ASan (434.834 s bridge), and explicitly
linked UBSan (465.710 s bridge), with no sanitizer diagnostics. All six Python
suites again passed **32 tests**. The SDK completion optionality warning remains.
No app/release build, registration, install, live mount or push was performed.

## Reinstall + host RO rerun (2026-10-25)

**STOPPED at installer scope validation; no retry or live acceptance run.**
Approved source was `7381280eb695465a60e5516d272b6ba11cda99ce`.
Release-Direct built successfully into `build/release` using
`-derivedDataPath build/reinstall-7381280` and an explicit
`CONFIGURATION_BUILD_DIR=$PWD/build/release`. The existing Developer ID signing
configuration was used. The team-signed FSClientProbe was built before installation
(`TeamIdentifier=37PX6W22C5`, identity
`357630FEC1EA6B2B0871F13013DC8353D1107BC1`). No build followed installation.

API-key notarization submission `8608ed95-13a8-4320-ac5f-bde60b590700`
was **Accepted**; stapling succeeded. Staged `codesign --verify --deep --strict`
passed and `spctl` reported `accepted`, `source=Notarized Developer ID`.
Both Info.plists contained the approved full commit, extension KOIO was `true`,
`Contents/Resources/AppIcon.icns` existed and `CFBundleIconName=AppIcon`.
Staged module executable SHA-256:
`99afd94e43102b83c853972e7208307884fe12bccc58693d2e1444ff7ad720eb`.

All five operator/acceptance dry-runs succeeded. Live `p0-preflight.sh` passed;
the installer repeated preflight successfully, including the empty RW allowlist.
Neither mount inventory contained DeviceFS; no DeviceFS operation or agent refresh
was performed.

The single live installer invocation used the approved full `--expected-commit`
and stopped with exit 1 **before registration/copy/settings changes**:

```text
P0 STOP: Refusing out-of-scope, aliased or unverified bundle(s); operator must isolate them: /Users/rom/Library/Developer/Xcode/DerivedData/YuzuNTFS-ggixrolbwswkchdvpwinppvvteuz/Build/Products/Debug/YuzuNTFS.app
```

Thus the current script does **not** implement the requested Q-R3 DerivedData
pruning authorization. No manual isolation, script modification or retry was made,
as the execution instruction requires stopping on the first failure.
Installer evidence: `build/p0-reinstall-20261025.log`.
Inventory showed installed plugin UUID `798BF996-E6FE-4AB2-B806-C6F25DDF293C`
(old installation), DerivedData UUID `695E4915-CF22-4DAB-A520-BA16B753FEF2`,
and staged UUID `CD61B063-7F0C-4598-A59D-88C7DDB1A333`.
No new installed UUID or enabled=true readiness result is claimed.

Resident hash, nonresident hash, names hashes, bigdir hashes/count, callback
evidence and image-unchanged checks were all **NOT RUN**. Disable/enable rollback
was not reached. The allowlist was not changed; no RW, benchmark, real-media
operation, daemon kill, subsequent build or push was performed.

### Authorized Q-R3 continuation

Controller authorized implementing Q-R3 and resuming from preflight with the
already-notarized candidate, without rebuilding. Commit `68d001b`
(`fix(ops): prune own DerivedData builds (Q-R3)`) permits only the exact
`DerivedData/YuzuNTFS-*/Build/Products/*/{YuzuNTFS,Yuzu NTFS}.app` layout,
with bundle identity verification and no symlink escape. Every validated bundle
is unregistered, archived/verified, then only its `.app` is removed. The four
installer tests passed, including own unregistered DerivedData isolation and
refusal of another project's DerivedData. An initial test exposed macOS `/var`
parent canonicalization; that predicate was corrected before live execution.

Resumed preflight and installation both passed. The historical DerivedData app
and staging app were archived and removed; unrelated DerivedData directories were
not removed. Installed executable identity/hash, strict signing and Gatekeeper
passed. Exactly one plugin remained at `/Applications/Yuzu NTFS.app`, UUID
`1EF2587D-D171-470B-9CC6-964700A9A2E7`. The existing team-signed probe reported:

```text
com.bluecoral.vn.yuzuntfs.fsmodule enabled=true url=/Applications/Yuzu NTFS.app/Contents/Extensions/YuzuNTFSModule.appex
```

Settings backup:
`enabledModules.plist.yuzu-1792870143451919000.backup` in the existing FSKit
group-container directory. Only current-user `fskit_agent` PID 89237 was refreshed.
DeviceFS was absent from mount inventories before refresh and during acceptance;
its registered module remained visible in the probe. No DeviceFS mount was affected.

The single authorized RO invocation exited 1, without timeout or retry, before
any file read. Fresh owned fixture attachment `/dev/disk14` mounted at
`build/p0-guest/ade18435-844e-4134-a18f-52874b22771d/basic-512-ro-mount`;
`mount` identified `yuzuntfs` with `read-only,fskit`, but `diskutil` reported
`FilesystemType=ntfs` and `WritableVolume=false`. The harness stopped at
`RuntimeError: Conflicting diskutil mount field: FilesystemType`.
Supervised unmount and detach both succeeded (`"disk14" ejected`).
Resident/nonresident hashes, names, bigdir hashes/count and image-unchanged checks
were **NOT REACHED**; no pass is inferred from the successful mount. Allowlist
checks passed empty and no authorization was added. No RW or bench ran.

Evidence: `build/p0-reinstall-qr3-preflight-20261025.log`,
`build/p0-reinstall-qr3-20261025.log`, and
`build/p0-host-ro-qr3-20261025.log`. No app/probe rebuild, subsequent mount attempt
or push was performed.

### Authorized personality-rule correction and RO PASS

Controller clarified that `mount(8)` is authoritative for the serving driver:
the exact owned device/mountpoint must show `yuzuntfs` and the requested RO flag.
`diskutil FilesystemType=ntfs` is an agreeing personality name, not a competing
driver. Commit `2d52e1b` (`fix(ops): accept ntfs personality for yuzuntfs mounts`)
accepts that value only after the authoritative checks; msdos/exfat/apfs still
conflict. All six read-only Python regressions passed, including the recorded
failed-run fields and wrong-device/type/RO rejection.

The one newly authorized `--allow-host-readonly` invocation exited **0**:
**RO SUBSET PASS**, with no rebuild/reinstall/refresh or RW/benchmark.
Evidence directory:
`build/p0-guest/8f172f33-2e04-4941-962e-671f6381630c`;
complete transcript: `build/p0-host-ro-personality-20261025.log`.

| Check | Result |
|---|---|
| Owned Yuzu RO mounts | PASS for basic, names and bigdir; exact fresh device/mountpoint/type/RO checks |
| Resident SHA-256 | PASS — `4b2720d37f921134bfbb2deb27137d6f08fc55ced90f88c4971f5f42e06e1fc6` |
| Nonresident SHA-256 | PASS — `e987c93a0a4837eaf02125d47e7ebf24dbe507cfc47a49c88e1f2f27492a9e8e` |
| Names SHA-256 | PASS — all four manifest samples, including CJK, emoji and both accent forms |
| Bigdir SHA-256 | PASS — manifest samples 000000, 000001, 049999, 099999 |
| Bigdir enumeration | PASS — `ls -1 -A` count exactly 100000 |
| Images unchanged | PASS — basic `f1f66e80cc137d09aa3f409973a2fe56a9ab756f4e0c103a8286a9e7c02bef5b`; names `4bb6b3ca62aeece6843ae756fdafbac897e224813c67ea1d81395d031eacd10e`; bigdir `4d905c4e6851bf0d15f6f28dfaf57bf2d18b2685551a498a72bfbe5b7e51c0bf` before=after |
| Callback evidence | PASS — PID 91916 bufferedRead offset 0 length 512, followed by read-only blockmaps at 0, 1048576, 2097152 and 3145728 |
| Cleanup | PASS — clean unmount/detach for every fixture; empty allowlist, no owned attachments and no state-U processes |

No EBUSY or timeout occurred. DeviceFS remained absent from mount inventories
and was unaffected. hdiutil's attach/detach deprecation warnings remain benign
diagnostics. These results close only this host RO subset, not RW, VM,
writeback/completion or throughput gates. No physical media or push was used.

## VM RW acceptance (2026-10-25)

**FAIL / R3 VM-provisional NO-GO.** Ran only inside disposable clone
`yuzu-qc-run-ntfs-20261025-rw` of stopped golden `yuzu-qc-27-dev`.
Guest: macOS 27.0.1 **26A434**, arm64, **4 vCPU / 12 GiB RAM / 80 GB**
virtio-backed disk; `kern.hv_vmm_present=1`. This is not physical-SSD evidence.
The VM was launched through host launchctl with a read-only payload share and
all Virtualization VM processes were assigned background task policy.

The installed host candidate was zipped with `ditto --keepParent` (the original
staged app had already been archived by installation), copied into the guest,
and installed using unchanged `p0-install.sh --expected-commit
7381280eb695465a60e5516d272b6ba11cda99ce`. Executable SHA-256 matched
`99afd94e43102b83c853972e7208307884fe12bccc58693d2e1444ff7ad720eb`;
signature/Gatekeeper passed; installed UUID
`14B0B7EE-EBD3-4003-A699-58EA20290389`; team-signed FSClientProbe reported
**enabled=true** at the exact installed path. No host install, refresh, mount,
RW authorization or filesystem workload was performed.

Guest prerequisites/anomalies: the golden has no command-line developer tools,
so its `/usr/bin/python3` is an installation stub. A copied Homebrew Python 3.15
framework executable supplied the runtime inside the disposable guest; no keys
or notary credentials were shared. Raw runtime symlinks produced virtio-fs
`Too many levels of symbolic links`; the actual versioned framework executable
worked. The share was unmounted before preflight because AppleVirtIOFS is not
an allowed transport during agent refresh. Initial installer stopped safely at
`pluginkit -r` for an unregistered staged extension; explicitly registering that
staged extension in guest GUI session allowed the unchanged installer to finish.
An 8 GiB detached regular NTFS bench image was created with guest `mkntfs`.

| Acceptance check | Observed result |
|---|---|
| RO basic/names/bigdir | PASS: manifest hashes, exactly 100000 entries, unchanged image hashes, clean detach and final empty allowlist/no-U inventory |
| RW resident append prerequisite | **FAIL:** `resident.write(b'P0-append'); resident.flush()` raised `OSError: [Errno 22] Invalid argument` |
| 1000003-byte cp/stat/cmp/remount/EOF | NOT REACHED |
| KOIO blockmap + completeIO acceptance | NOT PROVEN; failure precedes required copy |
| VDL 37 + ftruncate 8192 / remount | NOT REACHED |
| ADS refusal | NOT REACHED |
| Force-RO open FD / mmap / remount readback | NOT REACHED |

The first evidence run was
`6c009676-d800-4782-a918-3cdb12adcfb4`. The guest launchctl submit service
unexpectedly restarted the completed failing command: subsequent RO-only
attempt directories are `94c6a843-471a-4e62-84a2-b860f0f8467d` and
`1044501b-a389-42ba-98f4-b0ade11f17d0`. These are **not** successful retries
or additional RW acceptance. At the first observation, guest `mds_stores`
PID 325 was `Us`; execution was stopped, then the launchctl service removed
to prevent further restarts. No timed-out cp or persistent RW-U process was
observed. The safety stop is mandatory even though later samples showed
mds_stores waiting and its U state was transient; causation is not established.
Future guest runners must be one-shot (or remain alive after recording their
exit) rather than a launchctl-submit command that exits and gets relaunched.

| Driver | Runs | Seq read/write 4 GiB | Copy 10k x 4 KiB | ls/rm 100k |
|---|---:|---|---|---|
| Yuzu KOIO | 0 | NOT RUN | NOT RUN | NOT RUN |
| Apple exFAT, same guest disk type | 0 | NOT RUN | NOT RUN | NOT RUN |
| Raw guest backing file | 0 | NOT RUN | N/A | N/A |

Benchmarks were withheld because acceptance failed; no rates, ratios or
performance pass can be inferred. Physical SSD and macOS 26 remain pending.

Evidence: `build/qc-runs/20261025-vmrw/` contains install/dry-run transcripts,
complete first-failure log in `acceptance-observation.log`, final stop and
process/image inventories, mds_stores and module stack samples embedded in
`final-stop.log` / `acceptance-final.log`, unified fskitd/module logs, and
`guest-artifacts.zip` containing callback logs (no guest `.ips` was present).
Logs include FSKit's missing `maxFileSizeInBits/maxFileSize` warning and
deactivation `close_kernel_fd` / unregister status `-536870212`; no root cause
or fix is claimed.

Cleanup: final guest inventory showed no attached images and an empty RW
allowlist. Requested guest shutdown returned the expected NIOSSH tcpShutdown.
Host launchctl service was removed; an immediate delete raced shutdown, then
Lume cleared its stale run lock and **deleted the clone successfully**.
The fresh host payload share was removed; goldens and evidence were retained.
No push was performed.

### Headless correction — byte-shaped append blockmaps (2026-10-25)

**Superseded by the VR2 corruption correction below.** The EINVAL diagnosis
was correct, but widening the requested mapping was not a valid fix. A2's
alignment requirement concerns internal extent split points, not an arbitrary
byte-shaped request's first or last byte. The real SDK serializer accepts
byte offsets and lengths. The payload-only tests described here did not model
the kernel's request-origin transfer buffer or cold-sector RMW.


The first failure is now traced to the **A2 extent-start alignment guard in
`YuzuNTFSVolume.blockmapFile`**, not resident promotion or successful-completion
range validation. In `guest-artifacts.zip`, the first run's `rw-callbacks.log`
lines 5–9 show read mapping `(offset: 0, length: 37)` followed by two append
mapping requests `(37, 9)` and completions `(0, 46)`. The read mapping promotes
the resident inode on this writable mount. `module-log.log:891–898` reports
blockmap reply **22**, operation IDs **6/7**, before endIO reply **22** with
**ioStatus 22**, operation ID **0**. `acceptance-observation.log:102280–102282`
places the user-visible error at `resident.flush()`, before `os.fsync`.

The bridge accepts byte ranges and returns the requested logical/physical
offsets. Consequently `[37,46)` reached the old guard with logical offset 37
and physical offset `LCN * clusterSize + 37`; both fail sector-start alignment.
The existing partial-end exception already allowed an end beyond old EOF for
writes, so it was **not** the rejected branch. Real-handler regressions against
the unmodified guard reproduced EINVAL for both resident append paths (with
and without the preceding read promotion) and a non-resident append at EOF
4194427. A 1000003-byte write separately exposed its non-block-sized packed tail.
Focused RED: artifact 889; focused GREEN: artifact 891.

The `ad91731` candidate prepared and packed covering device sectors:
`[37,46)` became `[0,512)` and `[0,1000003)` became `[0,1000448)`.
Although the SDK permits DATA beyond EOF, that permission does **not**
authorize moving the start of the kernel's requested transfer. VR2 below
demonstrated that this widening was corrupting, despite passing those tests.
The correction now keeps both mapping coordinates and length exact; only
allocation and the kernel's underlying device I/O are sector-rounded.

The observed `(0,46)` completion is valid even though the map requested `(37,9)`;
it need not exactly match a mapping range. Its failed status 22 is propagated
by the bridge, not invented by T1–T3 validation. No size-setattr failure appears
before the first blockmap error. The later synchronize error at
`module-log.log:900` is not evidence that synchronize originated the append
failure; the saved logs do not identify the lower-level source of that later
sync error independently.

Tests use the actual volume handlers, E2 bridge and copied disposable image,
with only the SDK packer/resource boundary supplied in process. They perform
physical payload writes, complete the observed prefix range, synchronize/close,
and offline-remount readback including exact EOF. They also retain the existing
T5-R2 gap/partial-tail zeroing and R-R1 outstanding-write/read-map interleavings.
The 1000003-byte case is a **headless regression**, not a claim the unreached VM
copy ran. The VM acceptance verdict remains NO-GO pending a new authorized VM
run; no host mount, attachment, installation or push is part of this correction.

Final headless verification: **17 probe/policy + 39 glue + 30 bridge tests**
passed in each of plain (322.086 s bridge, artifact 894), ASan (377.449 s
bridge, `build/qc-runs/20261025-vmrw/headless-asan.log`), and explicitly linked
UBSan (364.305 s bridge, `build/qc-runs/20261025-vmrw/headless-ubsan.log`).
`otool -L` also confirmed `libclang_rt.ubsan_osx_dynamic.dylib` on the bridge
test executable. No sanitizer diagnostics were reported. The first ASan
tool invocation was interrupted by a harness timeout after probe/glue passed;
it was not counted as a green full run. The complete captured-output retry
exited 0. The existing SDK completion-optionality warning remains.

All six Python suites passed **33 tests** using
`for file in scripts/test-*.py; do python3 "$file" || exit; done`
(bench 4, install 4, phases 1, readonly 6, policy/ops 16, seqio 2).

## VM RW acceptance rerun (2026-10-25)

Candidate `ad91731a05332dcd35b2589dedb61646da7255f8` built Release-Direct
successfully, notarization `1a047664-9519-425f-9f04-f20f57809c91` Accepted,
stapled, strict signature/Gatekeeper verified. Both git identities matched,
KOIO=true and AppIcon metadata/resource were present; module SHA-256
`7832c147fdd584b3b52ea01d208d17875a01e07b56d04afc6e76edb9089cf494`.
No host installation was performed. Guest macOS 27.0.1 / 26A434, 4 vCPU,
12 GiB RAM, 80 GB virtio disk, cloned from `yuzu-qc-27-dev`.

First rerun clone `yuzu-qc-run-ntfs-20261025-rerun` installed the candidate,
reported enabled=true, then the old overly broad monitor stopped immediately
on unrelated `homeeventsd` PID 877 state U, before any filesystem phase.
Evidence/stacks: `build/qc-runs/20261025-vmrw-rerun/`.
The guest shut down, launchctl service was removed and clone deleted.

**Controller ruling V-R1:** unrelated transient U is ordinary disk wait.
`scripts/p0_vm_monitor.py` samples every two seconds and immediately stops
for acceptance/module/benchmark processes or processes whose arguments,
cwd or open files reference owned test paths. Any unrelated process
continuously U for at least 20 seconds also stops; shorter waits are logged
as informational. A process leaving U or changing identity resets its timer.
The root VM-only monitor inspects open files but runs acceptance as the
worktree owner, records status, and remains idle until launchctl removal
to prevent automatic reruns. Example inside the guest:

```sh
sudo /Users/lume/bin/python3 scripts/p0_vm_monitor.py --root /Users/lume/yuzu-ntfs
```

Four recorded-state Python regression tests passed (transient homeeventsd,
continuous mds_stores, reset/PID reuse, and owned command/open-path cases).

V-R1 fresh clone `yuzu-qc-run-ntfs-20261025-vr1` reused that same notarized
build (no rebuild). Guest install/readiness passed; RO basic and names hashes
and image preservation passed, as did bigdir sample hashes. The monitor
stopped on owned `ls -1 -A <bigdir-ro-mount>` PID 1170 in U before enumeration
completed. The process had exited before its stack could be sampled.
Module stack, unified logs, recorded process states and callback logs are in
`build/qc-runs/20261025-vmrw-vr1/`. No RW/adjacent-byte/bench result exists.
The guest was shut down and its launchctl service removed.

**Controller ruling V-R2 supersedes V-R1's immediate owned-U stop.**
Brief U while an FSKit upcall is served is normal for owned callers too.
The monitor now samples every one second and requires continuous U for
at least 20 seconds for any process; phase deadlines still apply.
Before a persistence/deadline stop it captures bounded samples of all current
U processes and YuzuNTFSModule plus fskitd/module logs before signaling.
Regression coverage now includes 19 informational owned-U samples followed by
a mandatory stop at 20 seconds, for owned arguments/workers/module/open paths.

### V-R2 final fresh-clone result — data corruption, NO-GO

Monitor fix commits: `c798972` (V-R1), `98b917e` (V-R2).
Four recorded-state tests passed after the V-R2 test first reproduced the
immediate-stop bug. Clone `yuzu-qc-run-ntfs-20261025-vr2` reused the same
stapled `ad91731` build, without rebuilding or installing on the host.
Guest OS/CPU/RAM/disk were unchanged: 27.0.1 / 26A434, 4 vCPU, 12 GiB,
80 GB virtio disk. Exact installed identity/hash and enabled=true passed.

The single actual acceptance run was
`9ff07144-67e3-4a0e-ac3b-5b31ccd53f85`.
RO basic/names/bigdir hashes, 100000-entry enumeration, unchanged images,
empty allowlist and final no-attachment/no-U inventory all **passed**.
Transient U states were logged informationally; there was no persistent-U
or phase timeout. RW append no longer returned EINVAL, but its clean
remount readback **failed** with `Resident append/remount mismatch`.

Additional disposable instrumentation left the acceptance assertions
unchanged and captured `ntfscat` output only on **fully detached** images:
before the first RW mount, after append before remount, and after final
unmount/detach. It rederived the owned image device at each reattachment.
Each snapshot retained full file bytes, SHA-256, length and first/last
512 logical bytes for resident.txt, nonresident.bin and any existing
nonaligned.bin/ads.txt.

| Detached resident.txt evidence | Bytes |
|---|---|
| Before append, size 37 | `0b2a496887a6c5e4032241607f9ebddcfb1a39587796b5d4f31231506f8eadcceb0a294867` |
| Expected after append, size 46 | Original 37 bytes followed by ASCII `P0-append` |
| Actual after append and final detach, size 46 | ASCII `P0-append` at **offset 0**, followed by **37 zero bytes** |

Thus the detached oracle proves destruction of the pre-existing bytes
adjacent to the append range, not merely a mounted-cache mismatch.
The unrelated nonresident.bin remained unchanged in all three snapshots
(`e987c93a0a4837eaf02125d47e7ebf24dbe507cfc47a49c88e1f2f27492a9e8e`).
This evidence does not expose physical sector slack beyond logical EOF:
ntfscat emits only the stream's logical bytes.

| Check/workload | V-R2 result |
|---|---|
| Resident append/remount/adjacent-byte preservation | **FAIL — confirmed detached data corruption** |
| 1000003-byte cp/stat/cmp/EOF/remount + adjacent bytes | NOT REACHED |
| Required copy blockmap/completeIO gate | NOT REACHED; append callback logs retained, not a copy pass |
| VDL 37 + ftruncate 8192 + remount | NOT REACHED |
| ADS write refusal | NOT REACHED |
| Force-RO open FD / mmap / remount | NOT REACHED |
| Yuzu 4 GiB seq read/write, copy 10k x 4 KiB, ls/rm 100k | 0 runs — withheld |
| Same-guest Apple exFAT comparison | 0 runs — withheld |
| Raw guest backing-file baseline | 0 runs — withheld |

**R3 VM-provisional NO-GO.** No throughput numbers/ratios or physical-SSD
claim; macOS 26 and physical SSD remain pending.

Evidence: `build/qc-runs/20261025-vmrw-vr2/` includes complete acceptance,
transient-U observations, installed identity/readiness, final process/image
inventories, unified logs and module stack samples. `guest-artifacts.zip`
preserves the **corrupted detached rw.img**, callback logs, source payload
and all detached-oracle before/after files and JSON head/tail records.
`oracle-summary.txt` records exact resident bytes. The guest DiagnosticReports
directory was empty. Build/notary/staple/metadata evidence remains in
`build/qc-runs/20261025-vmrw-rerun/`.

Cleanup completed: RW failure's supervised clean unmount/detach succeeded,
final guest hdiutil images was empty, allowlist was zero bytes and no force-RO
hook remained. Guest shutdown returned expected tcpShutdown, guest runner
and host launchctl service were removed, final clone was deleted and the
payload share removed. Prior rerun clones were also deleted. Goldens and
host installation were not modified; no push.

## VR2 corruption analysis and exact-coordinate correction (2026-10-25)

### What the saved evidence actually contains

The archived `rw.img` was extracted under the ignored
`build/qc-runs/20261025-vmrw-vr2/extracted/` directory and inspected without
attachment or an OS filesystem mount. `tools/bin/ntfsinfo -v -F /resident.txt`
reports MFT 64, unnamed $DATA **nonresident**, allocated/data/initialized
sizes **4096/46/46**, and the single run **VCN 0 -> LCN 0x32a9, length 1**.
The cluster size is 4096, so its physical byte offset is **53121024**.
A raw read at that address independently shows `P0-append` followed by zeros;
this is not only an ntfscat/cache interpretation. The golden $DATA is resident
with 37 bytes and no runlist.

VR2 retained callback ranges, but **did not log packed extents, operation IDs
or per-callback inode sizes**. There is no separate complete VR2 module log:
`final-evidence.log` is the post-failure log/sample collection, and the zip's
`rw-callbacks.log` is the live P0 callback log. The guest was already destroyed,
so these fields cannot be recovered as direct observations. The following
packed tuples are reconstructed from that log, the exact `ad91731` mapping
implementation and the detached runlist; they must not be described as
observed packet captures.

| Guest timestamp / PID | Observed callback | Reconstructed packed (logical, physical, length, FSKit type) / effect |
|---|---|---|
| 01:08:44.704 / 1252 | WRITE map (0,36) | (0,53116928,512,DATA), first fsevents UUID **[INFERENCE]** |
| 01:08:44.707 / 1252 | WRITE complete (0,36) | Exact EOF/VDL 36; zero tail [36,512) |
| 01:08:45.387 / 1252 | READ map (0,37) | resident.txt promotion; (0,53121024,37,DATA) |
| 01:08:45.393 / 1252 | WRITE map (37,9) | **(0,53121024,512,DATA)**, not the requested byte origin |
| 01:08:45.393 / 1252 | WRITE complete (0,46) | Exact EOF/VDL 46; no VDL-to-offset gap; zero tail [46,512) |
| 01:08:48.060 / 1311 | WRITE map (0,36) | (0,53125120,512,DATA), recreated fsevents UUID **[INFERENCE]** |
| 01:08:48.061 / 1311 | WRITE complete (0,36) | Exact EOF/VDL 36; zero tail [36,512) |
| 01:08:48.616 / 1311 | READ map (0,46) | (0,53121024,46,DATA), corrupted resident.txt on remount |

The fsevents attributions are not invented file identities in the callback
log: that log has none. They are supported by the 36-byte UUID left at LCN
0x32a8 and the final `.fseventsd/fseventsd-uuid` at LCN 0x32aa (MFT 72,
sequence 2, allocated/data/initialized 4096/36/36). Only those two incidental
file attributions/first-run allocation remain inferential. No read completion
was logged. The earlier VM run's full `module-log.log:891-898` establishes
the previous failure shape: write maps (37,9), IDs 6/7, replied EINVAL 22;
their unspecified-ID completions (0,46) propagated ioStatus 22.

### Root cause and the competing hypotheses

The earlier fix confused allocation/block alignment with the range described
to FSKit. A byte append's transfer buffer still starts at file byte 37.
Returning a first extent at logical 0 / physical cluster start changes the
physical origin of that transfer. The detached result places its nine bytes
exactly **37 bytes too early**. The following 37 logical bytes are zeros in
both detached snapshots. The controller's kernel model therefore treats the
first returned physical address as the start of the requested buffer; it
does not silently rebase that buffer to rescue a mismatching logical origin.
The exact internal kernel zero-buffer sequence is **[INFERENCE]**, not exposed
by these user-space callback logs; a new VM run remains the real oracle.

An in-process probe of the **real macOS 27 FSExtentPacker**, not the capture
subclass, accepts `(logical:37, physical:53121061, length:9)` and serializes
those exact values. The old A2 rejection was our own guard, not an SDK
rejection. Both read and write responses now start exactly at their request;
subsequent extents are contiguous, and physical/logical intra-sector offsets
must agree. Internal splits remain aligned, including the UINT32-sized batch
limit, without rounding either request boundary.

The other proposed causes were checked rather than patched speculatively:

- **Promotion persistence / initialized size:** real-handler/E2 tests inspect
  raw backing-file bytes **before returning to simulated writeback**, and
  invoke external ntfsinfo while the headless engine is open. Promotion has
  already persisted the original 37 bytes and $DATA sizes 4096/37/37.
  E2's existing conversion -> fsync and device flush/purge order is retained;
  no unproven second promotion implementation or upstream patch was added.
- **READ mapping zeroFill of [0,37):** the covering READ mapping is DATA through
  the partial VDL sector, and the RMW model actually reads it from disk.
  Above VDL it honors zeroFill and kernel-known EOF. Removing promotion
  persistence or returning zeroFill for the prefix breaks readback.
- **T5-R2 completion zeroing:** the observed completion starts at 0, below
  pre-existing VDL 37, so `[VDL,offset)` is empty. Its partial-tail zeroing
  starts at 46, not 0 or 9. It cannot explain erasure inside `[0,46)`.
  R-R1's non-mutating read route during a write lease and T5-R2's exact
  completion/tail semantics are unchanged.

These headless checks exclude the proposed E2 cache/VDL causes in the tested
device model; they do not claim direct observation of the destroyed guest's
pre-write metadata cache. Future P0 logs now include operation ID and every
packed logical/physical/length/type, so the VM retry need not infer them.

### Explicit kernel RMW test contract and audit

The real handlers and E2 still operate on copied disposable NTFS images.
Only the SDK construction/packer boundary is supplied in process. A cold
kernel write is now modeled as:

1. Require the first WRITE extent's logical start to equal the original
   request offset, and every later run to be contiguous. Require its total
   length to equal the request. A widened response fails with
   **"WRITE mapping does not start at request"** before unsafe I/O.
2. Obtain the real handler's READ mapping for all covering device sectors.
   Enforce the same exact-start/contiguity rule for those READ responses.
3. Populate whole-sector cache buffers using DATA bytes from raw disk and
   zeroFill as zeros; zero bytes beyond the kernel's known EOF.
4. Overlay the user's bytes at their original file offset, then write the
   **entire covering sectors**, using the exact WRITE translation. Complete
   only the reported byte range, synchronize and check offline remount bytes.

This deliberately does not reproduce the kernel by an ideal `pwrite` of only
the payload, nor "correct" an invalid mapping by compensating its offset.
An exploratory logical-address-rebased RMW model passed the broken candidate:
that was evidence the model was too permissive, **not** a successful corruption
reproduction. The strict model's pre-fix RED (artifact 960) failed resident
append in both promotion orders, nonresident unaligned-EOF append, and the
1000003-byte copy's oversized mapping. Focused GREEN is artifact 962.
The RED pins the rejected request-origin contract; it is not claimed to be
a byte-for-byte replay of inaccessible kernel internals.

Converted important payload-only regressions in both actual-handler and
bridge tests: resident append, nonresident EOF 4194427 append, 1000003-byte
new/shrunk/allocated writes, partial-VDL tracked/untracked completion,
unaligned cached-edge overwrite and the poisoned 3 MiB+5-byte gap write.
Added actual-handler RMW-37 -> ftruncate-8192 -> remount, plus gap writes at
211 and 6191 with initialized-prefix, gap, payload and tail preservation.
Before append writeback the test also checks durable original bytes and
external ntfsinfo's initialized size, rather than trusting E2's cached reads.

Every remaining direct test pwrite was classified: block-device transport
callbacks are infrastructure; full-sector/full-4096-byte writes in lifetime,
ordering and failed-cache-invalidation tests already write their complete
device buffers; stale-slack/failed-write poison injection intentionally writes
raw disk bytes and must not gain zeroFill semantics. Those are intentionally
unchanged, not unconverted ordinary byte-write simulations.

### Final headless verification for this correction

All three full SwiftPM runs exited **0**, each with **17 probe/policy +
42 actual-module glue + 30 bridge tests** (including every fixture-entry
ntfscat comparison). Bridge suite durations were **393.011 s plain**,
**492.966 s ASan**, and **461.874 s explicitly runtime-linked UBSan**.
`otool -L` confirmed `@rpath/libclang_rt.ubsan_osx_dynamic.dylib` on the
bridge test executable after the UBSan run. No sanitizer diagnostics were
reported. Existing SDK completion-status optionality warnings remain;
engine error messages from deliberate fault-injection cases are expected.

Commands were the full `swift test --package-path Packages/NTFSCore`, the
same with `--sanitize=address`, and the same with `--sanitize=undefined
-Xlinker /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang/21/lib/darwin/libclang_rt.ubsan_osx_dynamic.dylib`.
All seven `scripts/test-*.py` suites also exited 0: **37 tests**
(bench 4, policy/ops 16, install 4, phases 1, readonly 6, seqio 2,
VM monitor 4). Durable output is under
`build/qc-runs/20261025-vmrw-vr2/headless-rmw-{plain,asan,ubsan,python}.log`.

The correction and these checks used no host image attachment, host mount,
app build/registration/installation or push. They do **not** close the VM RW
acceptance gate or claim that inaccessible kernel internals were reproduced.

## VM RW acceptance — exact extents (2026-10-25)

**FAIL / R3 VM-provisional NO-GO.** Approved candidate
`ac94fd650b255d400f077334021cde5c377509e1` (including `efdf1ac`) built
Release-Direct, Developer ID signed, notarized
`72432e1b-eb45-4f19-af2b-570afa00b1ab` **Accepted**, stapled and verified
with strict codesign/Gatekeeper. Both embedded git identities matched;
KOIO=true and AppIcon name/resource passed. Module executable SHA-256:
`7c7c6e11d97dc40a418db4e0ad8722986a6e8fe6b6f674f860a209dbcda2ae23`.
No host installation, agent refresh, image attachment or mounted workload.

Fresh clone `yuzu-qc-run-ntfs-20261025-exact`:
macOS **27.0.1 / 26A434**, **4 vCPU / 12 GiB / 80 GB virtio disk**,
VM flag 1, read-only payload share unmounted before guest install.
The unchanged installer verified the exact staged identity and enabled=true.
The single acceptance evidence UUID was
`4aec4b3a-d0a4-4521-ada5-4ed730dec492`.

| Gate | Result |
|---|---|
| RO basic/names/bigdir hashes | PASS |
| RO enumeration / unchanged images / clean detach | PASS, exactly 100000 entries |
| Resident append + clean remount | **FAIL — same detached data corruption** |
| 1000003-byte cp/stat/cmp/EOF/remount | NOT REACHED |
| Copy KOIO evidence | NOT REACHED; append callbacks captured below |
| VDL 37 + ftruncate 8192 / remount | NOT REACHED |
| ADS write refusal | NOT REACHED |
| Force-RO open fd / mmap / remount | NOT REACHED |

Detached ntfscat snapshots before first mount, after append before remount,
and after final detach show original **37 bytes** becoming **46 bytes**:
ASCII `P0-append` at offset **0**, followed by **37 zero bytes**.
Expected original37 + append9 did not survive. This is a disk-byte failure,
not merely stale mounted readback. The first/last logical 512-byte records,
full bytes, hashes and corrupted detached image are retained.

Crucially, the new public packExtent trace now confirms the exact byte-origin
mapping, yet the failure remains:

```text
blockmapFile offset=0 length=37 write=false operationID=5
packExtent ref=64 operationID=5 logical=0 physical=53121024 length=37 zeroFill=false
blockmapFile offset=37 length=9 write=true operationID=6
packExtent ref=64 operationID=6 logical=37 physical=53121061 length=9 zeroFill=false
completeIO offset=0 length=46 write=true operationID=6
```

No causal explanation is inferred from these coordinates. The acceptance
stopped on the first mismatch; no patched test, second RW attempt or
benchmark was run. V-R2 supervision logged transient U but encountered no
continuous >=20-second U or phase deadline.

| Benchmark driver | Runs | Seq read/write 4 GiB | Copy 10k x 4 KiB | ls/rm 100k |
|---|---:|---|---|---|
| Yuzu KOIO | 0 | NOT RUN | NOT RUN | NOT RUN |
| Apple exFAT, same guest disk type | 0 | NOT RUN | NOT RUN | NOT RUN |
| Raw guest backing file | 0 | NOT RUN | N/A | N/A |

Numbers/medians/ratios remain unavailable because RW acceptance failed.
Verdict is **VM-provisional NO-GO**, not physical-SSD evidence;
macOS 26 and physical SSD remain pending.

Evidence: `build/qc-runs/20261025-vmrw-exact/` contains build/notary/staple/
identity/install transcripts, complete acceptance observations,
`rw-callbacks.log`, full `module-log.log` captured with `--info --debug`,
module samples and final inventories, `oracle-summary.txt`,
the preserved guest-only `vmrw_oracle.py` instrument, and
`guest-artifacts.zip` with the corrupted rw.img, callback logs and detached
before/after oracle files. Guest DiagnosticReports was empty.

VM-capacity anomaly: another session started `origami-glass` after initial
inventory, occupying VNC 5997 and the second Apple VM slot alongside sync14.
Our failed launch service was removed; capacity was checked every 60 seconds
until a slot became available (about five minutes). No peer VM was stopped.
New-helper QoS detection briefly backgrounded peer PID 65802; controller-
authorized `taskpolicy -B -p 65802` succeeded before waiting. At actual
launch only our newly created helper received background QoS. Automatic VNC
port selection avoided the occupied port.

Cleanup completed: supervised RW unmount/detach succeeded, final guest image
inventory was empty, RW allowlist zero bytes, no force-RO hook. Requested
shutdown returned expected tcpShutdown; guest runner and our host service
were removed, our clone deleted and payload share removed. Goldens and other
sessions' VMs were left intact. No push.

## Append corruption root cause (2026-10-25)

This section supersedes the exact-coordinate contract proposed above. The
macOS 27 SDK serializer accepts byte-granular extents, but acceptance by the
serializer does **not** prove those extents are safe for kernel device I/O.

### Targeted observations

Evidence is retained in `build/qc-runs/20261025-append-contract/`.
The unchanged exact-extent candidate was installed in a fresh
`yuzu-qc-27-dev` clone. A deadline-supervised `O_RDWR | O_APPEND` probe
recorded the mounted bytes before open, before write, before fsync, after
fsync, after close, and after clean unmount/remount:

- Before write: the correct original 37 fixture bytes.
- Before/after fsync and after close: the correct original37 + `P0-append`.
- After remount: `P0-append` at offset 0 followed by 37 zeros.
- The READ callback was KOIO `blockmapFile(0,37)`, returning **DATA** at
  physical 53121024, length 37, not buffered `read` or zeroFill.
- The WRITE callback returned logical37/physical53121061/length9; completion
  was `(0,46)`. The original kernel-visible cached file contents were
  demonstrably correct. Missing original data in the cache (H1) is excluded.

The minimal sector-covering experiment changed mapping boundaries to
`floor(offset / deviceSector)` through `ceil((offset + length) / deviceSector)`.
The item was published with `flags=NB_RESIDENT`, `size=37`, `inhibit=false`.
The first READ promoted it and returned DATA logical0/physical53121024/length512.
The kernel retained that map: append needed **no WRITE blockmap**, and
`completeIO(0,46,unspecified)` followed. All mounted snapshots **and clean
remount** contained original37 + append9. The exact and sector experiment
images, callback logs and full snapshots are in `exact-probe.zip` and
`sector-probe.zip`; the line-by-line observations are also in
`exact-probe-result.log` and `sector-probe-result.log`.

The evidenced boundary error is supplying byte-sized mappings to a
sector-oriented retained device mapping/writeback path, not VDL zeroFill or
resident promotion losing the prefix. The kernel's internal arithmetic that
turns the invalid byte mapping into the observed payload-at-zero transfer
remains **[INFERENCE]**; a completeIO range alone does not expose its source
buffer or prove it wrote a whole VM page. A 512-byte covering mapping fixes
this fixture, so requiring a whole VM page is not supported by this evidence.

### NTFSKit oracle attempt

Reference: [NTFSKit 96ecccb1](https://github.com/whereteam/ntfskit/tree/96ecccb1b1f6dba2ecd158ed0ff9a21e7917c80d).
The test-only checkout was instrumented to log every packed extent and
blockmap/completion request, built with its real NTFS-3G and libbde
dependencies, and installed **without Yuzu** in a separate fresh clone.
Developer ID signing and then ad-hoc signing were both attempted.
The final enabled-module enumeration reported the reference enabled=true,
but launching it failed with ExtensionKit error 2: AMFI/taskgated reported
restricted FSKit entitlements and **no matching provisioning profile**.
No reference blockmap ran, so there is **no empirical NTFSKit mapping
comparison** and no claim that its append behavior is correct. Source
inspection alone shows its bridge emits exact byte ranges, like the failing
Yuzu candidate; this is not a working oracle. See
`oracle-{enabled-result,launch-blocker,adhoc-result}.log`.
No security policy, SIP setting or third-party provisioning identity was changed.

### Corrected implementation and regressions

Both READ and WRITE pack responses now cover complete device sectors;
allocation/map growth does not publish rounded EOF. Completion still uses
the kernel's exact byte range, including unspecified completions that reuse
a prior READ map. Every packed extent is checked for logical, physical and
length sector alignment. The source logs publication eligibility as well as
every read/write packed tuple.

The prior headless RMW model incorrectly repaired an invalid tuple by
subtracting the intra-sector physical offset before its simulated pwrite.
It now requires whole-sector mappings and writes them without such rebasing.
Regressions cover explicit resident append, reuse of a READ map with no
WRITE blockmap, nonaligned nonresident EOF, 1000003-byte writes, VDL tail
zeros, gap writes, outstanding-write read maps and exact detached EOF.
The new sector-mapping regression first failed on the old tuple `(37,+37,9)`.

The benchmark's Yuzu mount guard also reuses the acceptance validator:
the owned `mount(8)` row is authoritative, absent diskutil FSKit fields are
allowed, and a reported `ntfs` personality is accepted only for an already
proven `yuzuntfs` row. Wrong device, filesystem, mountpoint or RO state still
fails closed. The new recorded-output regression first reproduced both
false refusals before the guard was changed.

### Final headless verification and signed candidate

Full plain, ASan and explicitly runtime-linked UBSan SwiftPM commands all
exited **0**, each running **17 probe/policy + 44 actual-module glue +
30 bridge tests**, including every fixture-entry ntfscat comparison.
Bridge durations were **464.755 s**, **436.167 s** and **446.623 s**.
`otool -L` confirms `@rpath/libclang_rt.ubsan_osx_dynamic.dylib`.
No sanitizer diagnostics occurred; the existing SDK completion-status
optionality warning and deliberate engine fault-injection messages remain.
All seven Python suites exited 0: **38 tests** (benchmark 5, policy/ops 16,
install 4, phases 1, readonly 6, seqio 2, VM monitor 4).
Output: `headless-matrix.log`, `ubsan-linked-runtime.log`, `python.log`.

An initial plain invocation's 300-second deadline was too short for the
100000-entry detached oracle comparison; its surviving helper was sampled
and terminated, not mistaken for a filesystem deadlock. A preliminary full
run then exposed an incorrect test-only assumption that completion cache
purge queries must also be rounded. That expectation was restored: the
new contract concerns **packed kernel mappings**, not non-I/O purge queries.
The final three complete runs above use the corrected tests.

Source candidate **`61e93f1507c737fbaff9020e251988a794bbeaa3`** was built
Release-Direct, Developer ID signed, notarized submission
**`38f6d552-267b-4f95-b990-f6b4c96e5c46` Accepted**, stapled and
strict-codesign/Gatekeeper verified. Both embedded commits match;
KOIO=true and AppIcon metadata match. Module executable SHA-256:
`ee6da00c102129d896452e850edc03f2fc8bba2847dbf8fbaafedb10d8832c65`.
The final artifact is `YuzuNTFS-61e93f1-stapled.zip`.

### Controller ruling M-R1 — retained mappings after the RO latch

The first full final-candidate VM run passed RO basic/names/bigdir (including
100000 names and unchanged images), resident append/remount, the 1000003-byte
cp/stat/cmp/EOF/remount workload with real KOIO callbacks, VDL 37 followed by
ftruncate(8192)/remount, ADS refusal, and pre-latch-FD EROFS. Its original
strict mmap-revocation assertion stopped: msync/fsync succeeded through a
retained mapping. That original failure is retained in
`final-guest-artifacts.zip` and `final-acceptance-observed.log`; no benchmark
was allowed past that then-failing gate.

**M-R1 changes the P0 acceptance contract**, not the extension binary:
after the RO latch the kernel may write data within already-allocated,
already-mapped clusters. Returning EROFS from completeIO does not revoke
those device mappings. P0 must still reply promptly, leave target MFT
metadata/EOF/VDL/allocation/runlist unchanged, and return EROFS for every
**NEW** write blockmap. This is a documented P0 limitation, not a claim of
complete cached-write revocation.

The replacement gate captures verbose detached ntfsinfo and ntfscat
snapshots before mapping and after the post-latch operation. It compares
the entire target inode metadata dump, exact file lengths and all bytes
outside the previously mapped range. A second pre-opened file has an
unmapped range at 16384: a post-latch 512-byte write must exercise a NEW
blockmap and receive EROFS, with its detached metadata and bytes unchanged.
The retained mmap msync/fsync must return success or EROFS in under five
seconds; callback evidence must include its completion and the denied NEW
write mapping. Fresh remount bytes must agree with the detached oracle.

**P1 item:** revoke retained mappings using macOS 27
`FSVolume.DataCacheHandler.setCacheState(push/invalidate)`, with real
pre-latch FD and mmap tests. This is not implemented by the P0 gate change.
The same limitation is recorded in `ntfs_bridge.h`.
All seven Python suites pass after three new M-R1 regressions first failed
on the missing gate functions: **41 tests** total (`python-m-r1.log`).

### M-R1 mounted result and callback predicate correction

The revised workload in the **same staged 61e93f1 binary and clone** passed
prompt retained mmap writeback (success), NEW-write EROFS, both detached
verbose inode metadata comparisons, allocation/runlist/EOF/VDL preservation,
data confinement, and remount readback. The retained file's first byte
changed from B to X; the unmapped file remained byte-identical. No new
allocation or target metadata change is accepted by this gate.

The initial callback-evidence predicate incorrectly required the NEW
blockmap's length to equal the user's 512-byte write. The actual VM log
shows **READ(16384,16384)** zeroFill followed by three denied
**WRITE(16384,16384)** attempts (operation IDs 69, 70, 71), without a packed
write extent. This is a page-sized kernel request, not missing blockmap
evidence. The predicate now requires the correct NEW logical origin and
write flag without inventing a request length. A recorded-page-size
regression covers the observed shape and rejects missing/read-only records.
All Python suites pass: **42 tests**, `python-m-r1-final.log`.

The corrected predicate was replayed against the already-collected real
callback sequence beginning at retained READ operation 66, together with
the detached before/after metadata/data artifacts and actual remount
verdicts. No mounted workload was silently rerun to disguise the harness
false failure. `resume-mr1-evidence.py` records that exact validation and
continues only then into the unchanged deadline-supervised benchmark.
Evidence UUID: `97d699ee-c831-4097-85fd-89c9d37ba69b`;
callbacks: `mr1-rw-callbacks.log`; workload: `mr1-acceptance-observed.log`.

### Benchmark mount finding and controller ruling V-R3

The first benchmark attempt, after M-R1 validation, reached the dedicated
8 GiB image's initial mount. V-R2 correctly stopped on extension PID 2228
continuously in U for **20.5 seconds**, before any timed workload row.
The disk-image helper sample was servicing backing-file pread. Subsequent
captured logs show that the mount finished at about **41 seconds**, then
the supervisor's signal caused a clean spontaneous unmount. This evidence
does not establish a deadlock; the first attempt produced **zero** timed
benchmark runs. The RW allowlist was revoked before signaling.

**V-R3 permits up to 120 seconds in U for the filesystem extension only
during an actual MOUNT command for the owned 8 GiB benchmark images.**
Other processes, other images, every non-mount phase and phase deadlines
retain V-R2's 20-second rule. The monitor validates the actual mount command,
owned image/mount paths and exact 8 GiB backing-file size; leaving the mount
phase restores the normal timer. Recorded-state tests cover 120-second
extension waits, unchanged 20-second limits for everyone else, phase exit,
foreign/small images, and Yuzu/Apple exFAT mount recognition.

The benchmark now records initial and remount command duration as separate
rows, excluding the later identity-validation commands. A recorded 41-second
mount timer first failed before implementation. All Python suites pass:
**45 tests** (`python-vr3.log`). No extension executable changed.

**P1 performance item:** free-space initialization / $MFT and $Bitmap scans
through a sparse image must not block mount. Report the measured Yuzu vs
Apple exFAT mount latency independently of sequential transfer throughput.
V-R3 authorizes one benchmark rerun on a fresh clone with the same signed,
notarized, stapled 61e93f1 artifact; the earlier functional acceptance remains
the immutable prerequisite, not a request to repeat mounted workloads.


### Controller ruling V-R4 — unrelated disk wait and durable rows

The V-R3 comparison attempt stopped on unrelated `spindump` PID 527 in U
for 20.2 seconds during Apple exFAT I/O, not on Yuzu or an owned filesystem
worker. V-R3's mount-only grace had correctly recognized Apple's extension.
That interrupted attempt is retained as `vr3-baseline-guest-artifacts.zip`;
no lost subprocess output is reconstructed into invented timing numbers.

**V-R4 supersedes V-R2 for unrelated daemons:** only owned workers,
processes touching the owned mounts/images, filesystem extensions and
fskitd trigger the 20-second stop. Unrelated spindump/logd/mds/homeeventsd
waits are always logged and never stop a run. V-R3's 120-second mount-only
extension exception and all phase deadlines remain unchanged. Ownership
changes reset the timer; a daemon accessing an owned mount is not exempt.

Every completed benchmark row is now appended, flushed and fsynced
immediately to `build/r3/bench-<fstype>.log`, independently of the outer
supervisor's temporary stdout capture. This includes initial/remount
latencies and prevents a later stop from losing already-measured rows.
Recorded regressions first reproduced both the unrelated-daemon false stop
and the missing durable row. All Python suites pass: **46 tests**,
`python-vr4.log`. The extension executable remains unchanged.

