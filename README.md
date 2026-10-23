# Yuzu NTFS

Yuzu NTFS **0.1 Beta** is an independent, GPL-2.0-only NTFS driver and menu-bar app for **macOS 26.0+ on Apple Silicon (arm64)**. The entire repository is licensed under GNU GPL version 2 only; see [LICENSE](LICENSE). It has no shared code dependency on Yuzu Drag.

## Current platform spike

The app shows “Yuzu NTFS 0.1 Beta” and Quit in a menu-bar extra. Its embedded FSKit module deliberately recognizes no resources and refuses to load volumes with `ENOTSUP`. **This is not yet a usable NTFS driver.** Do not attach valuable data to experimental driver builds.

Identifiers: app `com.bluecoral.vn.yuzuntfs`, module `com.bluecoral.vn.yuzuntfs.fsmodule`, FS short name `yuzuntfs`; Apple team `37PX6W22C5`. Version `0.1.0`, build `1`; Swift 6 strict concurrency. `Packages/NTFSCore` is an intentionally empty SwiftPM package, ready for the probe and C engine targets in subsequent tasks. It builds without a dummy target.

## Build

Requirements: Xcode 27.1 (tested host toolchain), XcodeGen, an arm64 Mac; Python 3 for the fixture acceptance checker. `project.yml` is the source of truth; the generated Xcode project is not committed.

```sh
xcodegen generate
xcodebuild -scheme YuzuNTFS -configuration Debug -derivedDataPath build build
swift build --package-path Packages/NTFSCore
```

The result is `build/Build/Products/Debug/YuzuNTFS.app`, containing `Contents/Extensions/YuzuNTFSModule.appex`. Debug explicitly ad-hoc signs the module with its FSKit and sandbox entitlements: Xcode's normal signing path requires a provisioning profile even with identity `-`. This verifies packaging only, **not OS approval or extension loading**. Provisioned signing and runtime mounting are later spike tasks; no SIP/security changes are needed or recommended here. Release signing is not configured for distribution.

## Offline test corpus

```sh
scripts/make-fixtures.sh
scripts/check-fixtures.py
```

The bootstrap downloads the upstream [NTFS-3G 2022.10.3 release](https://github.com/tuxera/ntfs-3g/releases/tag/2022.10.3), verifies tarball SHA-256 `f20e36ee68074b845e3629e6bced4706ad053804cbaf062fbae60738f854170c`, and builds `mkntfs`, `ntfsinfo`, `ntfsls`, `ntfscat` and static `libntfs-3g.a` with `--disable-ntfs-3g --enable-ntfsprogs --enable-static --disable-shared`. **No FUSE, autotools installation, root access, or VM is required.** Downloads/builds stay in ignored `vendor/`, binaries in ignored `tools/bin/`. The pinned upstream release is a test-only tool dependency, not an engine-selection decision; its own upstream license notices remain in the extracted source.

A small C program in `tools/fixturegen/` authors files directly through that static library, flushes/unmounts, remounts read-only, compares every authored file/stream byte against its deterministic source pattern and emits SHA-256 manifests. The Python checker independently reads all small-corpus files/streams and representative big-directory files through `ntfscat`, checks root listing counts, boot-sector geometry, hard-link identity and the normalization pair. Every bigdir file is read back by the C generator; Python samples four of them to avoid 100,000 process launches.

| Image | Size | Sector / cluster | Authored corpus |
|---|---:|---:|---|
| `basic-512.img` | 256 MiB | 512 / 4096 | Resident file, 4 MiB + 123-byte non-resident file, 2 MiB fragmented file, allocation blocker, ADS, hard link, subdirectory + nested file |
| `4kn.img` | 256 MiB | 4096 / 4096 | Same content corpus |
| `c64k.img` | 256 MiB | 512 / 65536 | Same content corpus |
| `bigdir.img` | 512 MiB | 512 / 4096 | 100,000 resident 32-byte files in the root |
| `names.img` | 256 MiB | 512 / 4096 | CJK, emoji, distinct `café.txt` (NFC) and `café.txt` (NFD) |

Each `fixtures/<stem>.manifest.json` has an `entries` array of every **authored user path**, not NTFS system metadata. Entries contain `path`, `type`, `size`, `sha256`, `mft_record`; data entries also contain `data_runs`. Directories use size `0` and SHA-256 `null`; ADS paths use `/ads.txt:metadata`. Hard-linked paths share an MFT record and hash. Resident streams have zero allocated data runs; the fragmented file is asserted to have multiple non-sparse runs. The content is a deterministic binary pattern, including the small `.txt` fixtures, not human-readable prose.

Images and manifests are generated and gitignored; never commit them. Generation is idempotent: input fingerprints plus image/manifest checksums reuse unchanged images, and mutations invalidate reuse. For tests that write, copy the image first. `mkntfs`'s regular-file and non-bootable-volume warnings are expected: these are raw NTFS **volumes**, not boot disks or GPT disk images. Timestamps and volume serials are not byte-reproducible; file contents and path sets are.

VM boot, Windows drive visibility and `chkdsk` are **PENDING-OWNER**. See [VM testing](docs/testing/vms.md).
