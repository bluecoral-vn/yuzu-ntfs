# Yuzu NTFS — Development

Yuzu NTFS **0.1 Beta** is an independent, GPL-2.0-only NTFS driver and menu-bar app for **macOS 26.0+ on Apple Silicon (arm64)**. The entire repository is licensed under GNU GPL version 2 only; see [LICENSE](../LICENSE). It has no shared code dependency on Yuzu Drag.

## Current platform spike

**P0 provisionally closed; engine E2 selected** (TT NTFS Native). E1 is deferred under T6-R2. R1/R2/R3 remain provisional: R3 is VM-indicative within target band, not formal hardware acceptance. GUI toggle, macOS 26, physical SSD medians + surprise removal, and Windows `chkdsk` are **PENDING-OWNER**; chkdsk may overturn selection. See the [engine decision, evidence table and open P1 limitations](spikes/p0-engine-selection.md).

The public-trial app includes first-run backup acknowledgement, guarded extension enable/disable, drive status/actions, per-drive write opt-in and EN/VI localization. The extension checks the acknowledgement and allowlist in `37PX6W22C5.com.bluecoral.vn.yuzuntfs/Library/Application Support/YuzuNTFS` (`beta-ack`, `write-serials.txt`), independently probes clean state, and publishes `status-<bsdName>-<serial-derived-volume-UUID>.json` with NTFS serial, media UUID, actual DA appearance time, update time, mode and reason. The app requires the current Disk Arbitration NTFS personality, matching serial-derived volume UUID/media/attachment time, and a non-stale timestamp before showing writing controls. It revalidates attachment identity before changing preferences and before/after asynchronous unmount; device write-protection overrides preferences. Unload removes only that incarnation's status, while crash leftovers and reused BSD names fail closed. Missing/unreadable/malformed policy fails closed. It never reads the historical P0 allowlist paths.
Each status publisher has its own record ID. Publishing and conditional withdrawal share a per-status POSIX file lock, so an old unload cannot delete a replacement publisher's record even on the same attachment. The hidden lock inode remains stable across operations. This is coordination among trusted local-user processes, not authentication or protection against other same-user software.
Status is withdrawn on volume unmount/deactivation, filesystem unload and ordinary deinitialization. In the macOS 27 guest, normal eject delivered `deactivateVolume` without a corresponding filesystem-unload callback; cleanup therefore cannot depend on `unloadResource` alone. Abrupt process death can still leave a file, which current DA identity/appearance validation rejects.

Mounted macOS 27 VM checks now pass read-only corpus verification, resident append/remount, nonaligned 1000003-byte copy/EOF/remount, VDL zero-tail preservation and ADS write refusal with sector-covering KOIO mappings. **P0 limitation (M-R1):** the read-only latch rejects new write mappings and metadata changes but cannot revoke kernel-retained mappings; data in already-mapped, already-allocated clusters may still change. Physical-SSD/macOS 26 acceptance and production safety are not established. See the [R3 runbook and evidence](spikes/p0-r3-throughput.md#append-corruption-root-cause-2026-10-25). [R1 enablement](spikes/p0-r1-enable.md) and [R2 automount findings](spikes/p0-r2-automount.md) are historical evidence.

Use the [operator procedure](spikes/p0-r3-throughput.md#resume-after-owner-reboot-not-yet-executed): `p0-preflight.sh` → `p0-install.sh` → verified `p0-disable.sh`/`p0-enable.sh` rollback gate → `p0-guest-acceptance.sh` inside an isolated lume guest. Mounted RW tests belong in the VM, never on the host. All tools offer `--dry-run`. Quitting the app does not disable its independently hosted filesystem extension.

Identifiers: app `com.bluecoral.vn.yuzuntfs`, module `com.bluecoral.vn.yuzuntfs.fsmodule`, FS short name `yuzuntfs`; Apple team `37PX6W22C5`; App Group `37PX6W22C5.com.bluecoral.vn.yuzuntfs`. Version `0.1.0`, build `2`; Swift 6 strict concurrency. `Packages/NTFSCore` contains the probe, shared beta policy/status/enablement logic, C bridge/engine integration, headless image conformance tests, and FSKit glue tests.

The host remains unsandboxed for the owner-approved scoped settings merge; the extension remains sandboxed. Both targets carry the App Groups entitlement. Following the controller's 2026-10-26 ruling, this macOS-only Developer ID app uses Apple's documented team-prefixed group; no group portal registration or profile entry is required ([Apple guidance](https://developer.apple.com/documentation/xcode/accessing-app-group-containers)). `REGISTER_APP_GROUPS` is not enabled. The existing API-key Xcode provisioning route remains for FSKit only. Enable/disable rejects active FSKit mounts (including unknown types), except the single exact Apple CoreDevice DeviceFS exception Q-R4/Q-R5. Each edit preserves other module IDs, backs up first, and refreshes only identity-checked current-user `fskit_agent` PIDs.

The app uses DiskArbitration unmount→mount callbacks without sudo or force unmount for the selected BSD volume. A busy unmount reports an error and preserves the saved preference for next mount. Unsafe states always override opt-in. The `force-read-only` App Group fault hook only reduces permissions; M-R1 is unchanged. Older spike documents describe historical P0 paths; current harnesses use the shared beta paths.

Disk Arbitration's required FSKit maintenance entry point performs **read-only boot-sector, clean-state and root-MFT/mountability verification**, not repair. Dirty, hibernated, Fast Startup, BitLocker and unsupported states fail with Windows recovery instructions; `-y` cannot clear flags or replay journals. The checker replaces write callbacks with `EROFS` and refuses an activated volume. Following controller ruling B-R1 and Apple's `FSResource.h`/`FSTask.h` example, detectable startup failures throw synchronously with no returned Progress and no task-completion call; otherwise work is enqueued on the real maintenance queue, with progress and `FSTask.didComplete` completed exactly once, never inline on the start-method stack. The public API offers no “caller received Progress” acknowledgement; asynchronous dispatch is not claimed as that stronger cross-thread guarantee, and no sleeps or purported receipt barriers are used. Formatting is unsupported. Missing bound resources fail closed. DA errors preserve the actual dissenter text/status rather than claiming every failure is a busy drive.
An opt-in for an unsafe or physically read-only drive is saved for a future clean/writable attachment, but the app leaves the existing RO mount in place rather than needlessly unmounting it for a known-refused RW request. The reason remains visible; extension-side admission is still authoritative.
All first transitions into the terminal read-only latch publish `writable=false` / `engineError` immediately from the latch setter, including checkpoint failures and the force-RO hook; publication does not depend on a later write-eligibility query. The app separates the actual mount's RW flag from logical write admission, so a RO error badge does not prevent an explicit off-toggle from remounting the still-RW kernel mount read-only. M-R1's retained-mapping limitation still applies until remount/eject.

For isolated guest UI acceptance only, launch the installed app with `--qa-control <directory>`. The flag is ignored outside a VM (`kern.hv_vmm_present != 1`). JSON `command.json` actions (`status`, `ack`, `enable`, `disable`, `writing-on`/`writing-off`/`eject` with `device`, `menu`, `onboarding`) call the exact UI model actions and atomically return `result.json` with the request `id`. This is no alternate write-admission path. Do not run RW acceptance on the host. Diagnostic export is user-initiated; logs may contain disk/path details. Updates are manual; Sparkle is not linked.

`scripts/beta_user_acceptance.py`, run under the privileged `p0_vm_monitor.py` in a fresh disposable guest, adds physical-RO precedence/opt-in checks using `c64k.img`, forced-latch live-status checks, real unload withdrawal, and a GPT Microsoft Basic Data exFAT partition with simulated scoped/legacy crash leftovers. Negative QA assertions explicitly request the actual error response; ordinary commands still fail on any error. Its headless helper regressions are `python3 scripts/test-beta-user-acceptance.py`. Neither that harness nor its QA flag bypasses production admission.

## Build

Requirements: Xcode 27.1 (tested host toolchain), XcodeGen, an arm64 Mac; Python 3 for the ntfsprogs source-integrity check and fixture acceptance checker. `project.yml` is the source of truth; the generated Xcode project is not committed.

```sh
xcodegen generate
xcodebuild -scheme YuzuNTFS -configuration Debug -derivedDataPath build build
swift build --package-path Packages/NTFSCore
```

After generating the offline fixtures below, run the full plain and ASan suites, then explicitly instrument C with UBSan and link its actual runtime:

```sh
swift test --package-path Packages/NTFSCore
swift test --package-path Packages/NTFSCore --sanitize=address
RUNTIME_DIR="$(xcrun clang --print-runtime-dir)"
swift test --package-path Packages/NTFSCore -Xcc -fsanitize=undefined -Xlinker "$RUNTIME_DIR/libclang_rt.ubsan_osx_dynamic.dylib" -Xlinker -rpath -Xlinker "$RUNTIME_DIR"
```

Confirm the exercised test executable links `libclang_rt.ubsan_osx_dynamic.dylib` with `otool -L`; merely naming a sanitizer is not runtime-coverage evidence. Missing fixture images fail with instructions to run `scripts/make-fixtures.sh`, rather than skipping coverage.

The result is `build/Build/Products/Debug/YuzuNTFS.app`, containing `Contents/Extensions/YuzuNTFSModule.appex`. Debug explicitly ad-hoc signs the module with its FSKit and sandbox entitlements: Xcode's normal signing path requires a provisioning profile even with identity `-`. This verifies packaging only, **not OS approval or extension loading**. `Release-Direct` uses manual Developer ID profiles, hardened runtime, and secure timestamps; run `scripts/setup-signing.sh` to register only this project's IDs and install profiles using an existing identity and the configured App Store Connect API key. No certificate or private key is created. No SIP/security changes are needed or recommended. See [R1 enablement findings](spikes/p0-r1-enable.md) for notarization, runtime evidence, owner-only Settings steps, and the unresolved macOS 26 gate.

## Offline test corpus

```sh
scripts/make-fixtures.sh
scripts/check-fixtures.py
```

The bootstrap downloads the upstream [NTFS-3G 2022.10.3 release](https://github.com/tuxera/ntfs-3g/releases/tag/2022.10.3), verifies tarball SHA-256 `f20e36ee68074b845e3629e6bced4706ad053804cbaf062fbae60738f854170c`, and builds `mkntfs`, `ntfsinfo`, `ntfsls`, `ntfscat` and static `libntfs-3g.a` with `--disable-ntfs-3g --enable-ntfsprogs --enable-static --disable-shared`. **No FUSE, autotools installation, root access, or VM is required.** The extracted source stays pristine at `vendor/ntfs-3g_ntfsprogs-2022.10.3/`; configure and compilation run out-of-tree under `vendor/build/ntfs-3g-2022.10.3/`. Generated `config.h` is in that build directory and the static library is at `vendor/build/ntfs-3g-2022.10.3/libntfs-3g/.libs/libntfs-3g.a`. Both trees and the archive are gitignored; installed binaries go in ignored `tools/bin/`. The pinned upstream release is a test-only tool dependency, not an engine-selection decision; its own upstream license notices remain in the extracted source.

Before reusing the source or installed tools, the bootstrap verifies the archive checksum and compares the extracted source's exact path set, file types, bytes and executable bits against that archive. Missing, modified or in-source-configured trees are automatically replaced by a fresh extraction. Treat this ignored test-tool source tree as disposable: local edits there are intentionally discarded. This also upgrades the original in-source bootstrap layout without requiring manual cleanup.

A small C program in `tools/fixturegen/` authors files directly through that static library, flushes/unmounts, remounts read-only, compares every authored file/stream byte against its deterministic source pattern and emits SHA-256 manifests. The Python checker independently reads all small-corpus files/streams and representative big-directory files through `ntfscat`, checks root listing counts, boot-sector geometry, hard-link identity and the normalization pair. Every bigdir file is read back by the C generator; Python samples four of them to avoid 100,000 process launches.

| Image | Size | Sector / cluster | Authored corpus |
|---|---:|---:|---|
| `basic-512.img` | 256 MiB | 512 / 4096 | Resident file, 4 MiB + 123-byte non-resident file, 2 MiB fragmented file, allocation blocker, ADS, hard link, subdirectory + nested file |
| `4kn.img` | 256 MiB | 4096 / 4096 | Same content corpus |
| `c64k.img` | 256 MiB | 512 / 65536 | Same content corpus |
| `bigdir.img` | 512 MiB | 512 / 4096 | 100,000 resident 32-byte files in the root |
| `names.img` | 256 MiB | 512 / 4096 | CJK, emoji, distinct `café.txt` (NFC) and `café.txt` (NFD) |

Each `fixtures/<stem>.manifest.json` has an `entries` array of every **authored user path**, not NTFS system metadata. Entries contain `path`, `type`, `size`, `sha256`, `mft_record`; data entries also contain `data_runs`. Directories use size `0` and SHA-256 `null`; ADS paths use `/ads.txt:metadata`. Hard-linked paths share an MFT record and hash. Resident streams have zero allocated data runs; the fragmented file is asserted to have multiple non-sparse runs. The content is a deterministic binary pattern, including the small `.txt` fixtures, not human-readable prose.

Images and manifests are generated and gitignored; never commit them. Generation is idempotent: one active `fixtures/.generation-cache` record contains the input fingerprint and that published corpus's image/manifest checksums. Reuse requires both a matching fingerprint and matching checksums; switching input revisions (including reverting to a previously generated revision) regenerates the corpus. The record is invalidated before replacing any image and published atomically only after successful checks. For tests that write, copy the image first. `mkntfs`'s regular-file and non-bootable-volume warnings are expected: these are raw NTFS **volumes**, not boot disks or GPT disk images. Timestamps and volume serials are not byte-reproducible; file contents and path sets are.

VM boot, Windows drive visibility and `chkdsk` are **PENDING-OWNER**. See [VM testing](testing/vms.md).
