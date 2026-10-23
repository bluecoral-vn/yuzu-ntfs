# P0 R2 — automount precedence

## Verdict and limits

**Provisional selection PASS on macOS 27 image fixtures only.** After adding `FSMediaTypes` / `FSProbeOrder` metadata, DiskArbitration automatically selected `com.bluecoral.vn.yuzuntfs.fsmodule`, invoked its probe, then its `loadResource`. The latter deliberately returns `ENOTSUP` (errno 45); consequently **no Yuzu volume mounted and no RW capability is established**. Without that metadata Apple's built-in NTFS mounted the same fixture read-only, without invoking Yuzu.

**The full R2 product gate remains OPEN.** Neither automatic RW mounting nor a successful app-driven remount within 2 seconds has been demonstrated. The current engine cannot load volumes. Physical SSD plug-in/unplug, Windows-formatted media, GPT/MBR partitioned NTFS, and macOS 26 are **PENDING-OWNER**. The successful precedence result is not a shipping gate or permission to test valuable data.

Host: macOS **27.0.1 (26A434)**, arm64; Xcode **27.1 (27A9275)**; macOS **27.0 SDK (26A425)**. Experiments: **2026-10-24, UTC+07:00**, approximately 02:22–02:27. `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. All attached devices were the project's generated fixture images, explicitly read-only. `/dev/disk8` was assigned during these runs; never reuse that identifier without inspecting a fresh attach result. No sudo, security-setting changes, non-fixture disk writes, capability requests, or pushes occurred.

## Experiment matrix

| Path | Observed result | Meaning |
|---|---|---|
| Original R1 metadata, `hdiutil attach -readonly fixtures/basic-512.img` | Apple NTFS mounted `/Volumes/Yuzu-basic-512`; personality NTFS, bundle `ntfs`, `read-only, fskit`; Yuzu not invoked | Existing `FSPersonalities` alone was insufficient for automount discovery |
| Added media matches and probe order 100, first attach immediately after agent reload | Apple mounted; FSKit probes failed `NSCocoaErrorDomain 4099` / `ENOENT` | Transient agent-readiness failure, **not** evidence that ordering failed |
| Same unchanged installation, after signed FSClient reports enabled=true | Auto-attach reached Yuzu probe and `loadResource` errno 45; attach returned “no mountable file systems” | Yuzu wins automatic selection when agent is responsive; Apple does not rescue this load failure |
| `attach -nomount` then `diskutil mount readOnly` | Mount failed; Yuzu load attempts in logs; disk info has `File System: None` | DiskArbitration path reaches intentional engine boundary |
| `diskutil mount -t yuzuntfs /dev/disk8` | Usage error, exit 1 | This diskutil has **no `-t` filesystem-selector option** |
| `/sbin/mount -F -r -t yuzuntfs ...` | Exit 69, loading resource unsupported | Explicit manual FSKit selection reaches Yuzu; no admin password requested on this owned image |
| macOS 27 `FSClient.mountSingleVolume` | Signed unentitled probe: `EPERM`; daemon explicitly says missing mount entitlement | Entitlement boundary demonstrated; no successful remount or 2-second acceptance claim |
| Force-detach bigdir image during `ls -R` | Detach exit 0 in 0.822 s; `ls` exit 1 by 0.823 s | No observed hang in **Apple's** mounted-driver image case; does not exercise Yuzu |

## Baseline: Apple's driver wins

With the enabled/notarized R1 installation, before metadata changes:

```sh
hdiutil attach -readonly fixtures/basic-512.img
diskutil info /dev/disk8
/sbin/mount
pluginkit -mADvvv -i com.bluecoral.vn.yuzuntfs.fsmodule
```

Raw output excerpts:

```text
/dev/disk8                                      /Volumes/Yuzu-basic-512
File System Personality:   NTFS
Type (Bundle):             ntfs
Name (User Visible):       Windows NT File System (NTFS)
Media Read-Only:           Yes
Volume Read-Only:          Yes (read-only mount flag set)
/dev/disk8 on /Volumes/Yuzu-basic-512 (ntfs, local, nodev, nosuid, read-only, noowners, noatime, fskit, mounted by rom)
+ com.bluecoral.vn.yuzuntfs.fsmodule(0.1.0)
  UUID = 7FFBB224-A94D-479D-B839-1E2864C3777D
  Path = /Applications/Yuzu NTFS.app/Contents/Extensions/YuzuNTFSModule.appex
```

Logs from the bounded 02:22:54–02:23:00 attach window:

```text
02:22:55.517 diskarbitrationd[429] FSModule missing information
02:22:55.517 diskarbitrationd[429] Found FSModule: <private> (×2)
02:22:55.520 fskitd[616] ... apply resource error ((null)), probe resource error ((null))
02:22:55.520 diskarbitrationd[429] ... probed disk ... failure.
02:22:55.522 fskitd[616] ... apply resource error ((null)), probe resource error ((null))
02:22:55.531 diskarbitrationd[429] ... probed disk ... success.
02:22:55.622 diskarbitrationd[429] ... mounted disk ... success.
```

No `YuzuNTFSModule` probe/load activity occurred in that window. Module identities in DiskArbitration logs are privacy-redacted, so the “missing information” attribution to Yuzu is an **inference** supported by the missing keys and disappearance of that diagnostic after the change, not a decoded private identifier.

### What Apple's NTFS is on this host

`/System/Library/Filesystems/ntfs.fs/Contents/Info.plist` declares:

- Bundle ID `com.apple.filesystems.util.ntfs`, version **3.14.3**.
- `FSImplementation = [UserFS]` — **not a legacy NTFS kext declaration**.
- Personality `NTFS`, name `Windows NT File System (NTFS)`, probe executable `ntfs.util`, mount executable metadata `mount_ntfs`.
- Native probe orders: Windows_NTFS **1000**, Microsoft Basic Data GUID **2000**, Partitionless **4000**.

The signed native probe executable has code-signing identifier **`com.apple.ntfs`**. On the read-only, unmounted fixture:

```sh
/System/Library/Filesystems/ntfs.fs/Contents/Resources/ntfs.util -p disk8 removable readonly
```

```text
Yuzu-basic-512
# process exit 255
```

SDK `usr/include/sys/loadable_fs.h` defines `FSUR_RECOGNIZED = -1` (“implies that a mount is possible”): Unix exit **255** is therefore native probe **recognized**, not an ordinary probe failure. It is not an FSKit `FSMatchResult` value. Do not infer an Apple `.usableButLimited` result from its read-only mount.

No Apple NTFS `.appex` appeared among the installed FSKit extensions or under `/System/Library/ExtensionKit/Extensions`; the installed Apple FSKit modules enumerated were exfat, msdos, ftp and CoreDevice DeviceFS. `kmutil showloaded --list-only` had **no NTFS-name kext**, but did have generic transport **`com.apple.filesystems.lifs (1)`**. Thus the evidenced native driver identity is Apple's **UserFS `ntfs` implementation**, using a mount carrying the `fskit` flag / generic LIFS transport; this investigation does not invent a `com.apple.fskit.ntfs` extension identifier or attribute a legacy NTFS kext. Native internal implementation details beyond these observations were not decoded.

## Metadata intervention

Verified actual key names and nesting in:

- `/System/Library/ExtensionKit/Extensions/com.apple.fskit.exfat.appex/Contents/Info.plist`: `EXAppExtensionAttributes.FSMediaTypes.<match>.FSMediaProperties` and sibling `FSProbeOrder`; `FSPersonalities` is separate.
- `/System/Library/Filesystems/ntfs.fs/Contents/Info.plist`: the same media match dictionaries and native order values above.

Added `EXAppExtensionAttributes.FSMediaTypes` to `Module/Info.plist`:

| Match | Properties | Probe order |
|---|---|---|
| Partitionless | Leaf=true, Whole=true | 100 |
| Windows_NTFS | Content Hint=Windows_NTFS, Leaf=true | 100 |
| EBD0A0A2-B9E5-4433-87C0-68B6B72699C7 | Content Hint=that GUID, Leaf=true | 100 |

No probe executable names were invented or copied from Apple's unrelated exfat helper: this FSKit module supplies `probeResource` itself. Existing `FSShortName=yuzuntfs`, `FSSupportsBlockResources`, `FSPersonalities.NTFS` and mount-option syntax remain intact. These matches nominate media for the real NTFS signature parser; they do not force recognition of non-NTFS volumes. **Only the partitionless match was exercised.** Windows_NTFS/GUID matching and precedence against other third-party drivers remain untested.

The source already returns `.usable(name: "NTFS", containerID: ...)`. SDK `FSResource.h` defines `notRecognized=0`, `recognized=1`, `usableButLimited=2`, `usable=3`; there is no stronger public probe result to try. Lowering the result would misrepresent the existing probe and does not repair absent automount metadata. This experiment changes **media discovery plus ordering together**; it does not isolate whether order 100, rather than merely adding media matches, is necessary or optimal. No unrelated personality key or system metadata was changed.

### Build / install / single authorized reload

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -scheme YuzuNTFS -configuration Release-Direct -derivedDataPath build/r1 build
ditto -c -k --keepParent 'build/r1/Build/Products/Release-Direct/Yuzu NTFS.app' build/r2/YuzuNTFS-r2.zip
xcrun notarytool submit build/r2/YuzuNTFS-r2.zip --keychain-profile yuzu-notary --wait --output-format json
xcrun stapler staple 'build/r1/Build/Products/Release-Direct/Yuzu NTFS.app'
ditto 'build/r1/Build/Products/Release-Direct/Yuzu NTFS.app' '/Applications/Yuzu NTFS.app'
pluginkit -r "$PWD/build/r1/Build/Products/Release-Direct/Yuzu NTFS.app/Contents/Extensions/YuzuNTFSModule.appex"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$PWD/build/r1/Build/Products/Release-Direct/Yuzu NTFS.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f '/Applications/Yuzu NTFS.app'
pluginkit -a '/Applications/Yuzu NTFS.app/Contents/Extensions/YuzuNTFSModule.appex'
pluginkit -e use -i com.bluecoral.vn.yuzuntfs.fsmodule
pluginkit -mADvvv -i com.bluecoral.vn.yuzuntfs.fsmodule
python3 spikes/r1/tt-self-enable.py
```

Observed `BUILD SUCCEEDED`; notarization **Accepted**, submission `9a258d8a-54a0-402c-936d-9405c6ef9bc7`; staple succeeded. Only the known local build registration was removed, leaving one installed registration, UUID **A4CBA0F8-C5D5-49AB-B764-8014B8668B8C**. PlugInKit printed version `(null)` after this registration even though the installed plist reads `0.1.0`; signature, visibility and actual invocation succeeded. No additional reinstall or registration was done to chase that cosmetic discrepancy.

**Exactly one R2 agent restart:** at **02:25:44**, backed up the string-array settings plist to:

```text
/Users/rom/Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist.yuzuntfs-backup-20261024-022544
SIGKILL current-user fskit_agent 54858
```

The helper required our entry already present and made **zero plist writes**; before/after diff was empty. No unrelated entries or another user's/root process were changed. Subsequent agent PID was **84907**. The two restarts documented in R1 preceded this task; only **one** of this task's maximum two was used. No second R2 restart occurred. Restore command, **not executed**:

```sh
cp '/Users/rom/Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist.yuzuntfs-backup-20261024-022544' \
   '/Users/rom/Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist'
```

This remains an undocumented, potentially disruptive R1 fallback, not a shipping enable/update method. No fixture was mounted at reload time. The immediate 02:25:52 auto-attach found three modules but got XPC 4099 / `ENOENT` on all three FSKit probes and fell through to Apple NTFS. After `build/r1/FSClientProbe` returned our installed URL with `enabled=true`, a fresh attach worked at the selection level. **Do not equate an issued reload with a ready agent.**

Final installed `codesign --verify --deep --strict` exited zero and `spctl --assess --type execute --verbose=2` reported `accepted`, `source=Notarized Developer ID`.

## Decisive automatic selection evidence

No manual `mount -t yuzuntfs` command was part of this attach interval:

```sh
hdiutil detach /dev/disk8              # detach transient Apple mount
hdiutil attach -readonly fixtures/basic-512.img
```

```text
# attach exit 1, elapsed 0.364 s
hdiutil: attach failed - no mountable file systems
```

Raw unified-log excerpts from **02:26:14**:

```text
02:26:14.548 diskarbitrationd[429] Found FSModule: <private> (three entries)
02:26:14.577 fskit_agent[84907] Launching process ... bundleID: com.bluecoral.vn.yuzuntfs.fsmodule,
  URL: file:///Applications/Yuzu%20NTFS.app/Contents/Extensions/YuzuNTFSModule.appex/
02:26:14.684 YuzuNTFSModule[86321] readFirstSectorAndLog reading from 3 got rv 512 error (null)
02:26:14.684 YuzuNTFSModule[86321] Successful read, first characters eb52:904e
02:26:14.684 fskitd[616] ... apply resource error ((null)), probe resource error ((null))
02:26:14.688 YuzuNTFSModule[86321] readFirstSectorAndLog reading from 3 got rv 512 error (null)
02:26:14.736 YuzuNTFSModule[86330] -[FSModuleConnector loadResource:options:replyHandler:]:start
02:26:14.736 YuzuNTFSModule[86330] configureUserClient for FSModule com.bluecoral.vn.yuzuntfs.fsmodule returned error ((null))
02:26:14.736 YuzuNTFSModule[86330] ... load error Error Domain=NSPOSIXErrorDomain Code=45,
  container status Error Domain=NSPOSIXErrorDomain Code=35
02:26:14.738 diskarbitrationd[429] ... probed disk ... success.
02:26:14.738 diskarbitrationd[429] staged fsmodule ... success.
02:26:14.807 YuzuNTFSModule[86338] -[FSModuleConnector loadResource:options:replyHandler:]:start
02:26:14.807 YuzuNTFSModule[86338] configureUserClient for FSModule com.bluecoral.vn.yuzuntfs.fsmodule returned error ((null))
02:26:14.809 fskitd[616] ... apply resource error ((null)), load resource error (Error Domain=NSPOSIXErrorDomain Code=45)
```

Framework first-sector diagnostics, the source's `.usable` reply, DiskArbitration's successful staging, and module-specific load calls together evidence probe/selection/load. The private probe-result payload itself is not decoded. Errno 45 is exactly the existing intentional `loadResource` rejection, not NTFS corruption. `hdiutil` automatically removed the failed attachment (`diskutil info /dev/disk8` then returned “Could not find disk”). Apple **did not mount a fallback** in this successful-selection trial.

To preserve the device for disk info and manual alternatives:

```sh
hdiutil attach -readonly -nomount fixtures/basic-512.img
diskutil mount readOnly /dev/disk8
diskutil info /dev/disk8
/sbin/mount -F -r -t yuzuntfs /dev/disk8 "$PWD/build/r2/mountpoint"
```

```text
# diskutil mount exit 1, elapsed 0.188 s
Volume on disk8 failed to mount
# diskutil info exit 0
Volume Name:               Not applicable (no file system)
Mounted:                   Not applicable (no file system)
File System:               None
Volume UUID:               14620282-E51A-5CC4-B004-1076F82C6C71
Media Read-Only:           Yes
# explicit mount exit 69, elapsed 0.059 s
mount: Loading resource: The operation couldn’t be completed. Operation not supported
mount: FSKit unavailable
```

There is **no successful Yuzu File System Personality string** to report because loading never completes; logs, not a fabricated mounted personality, prove selection. Before metadata changes the explicit manual mount had also reached the same expected load error (0.071 s). Failed command duration is not successful remount latency.

The requested `diskutil mount -t yuzuntfs /dev/disk8` returned exit 1 and:

```text
Usage:   diskutil mount [readOnly] [nobrowse] [-mountOptions Opt[,Opt]*]
         [-mountPoint Path] DiskIdentifier|DeviceNode
```

## macOS 27 app-driven mount alternative

SDK `FSClient.h` exposes `mountSingleVolume(resource:bundleID:options:completionHandler:)`, macOS 27 (V3), documenting the required **`com.apple.developer.fskit.mount`** entitlement and mounting within `/Volumes`. It only mounts modules visible to the caller.

Inspected Xcode's actual capability metadata at:

```text
/Applications/Xcode.app/Contents/SharedFrameworks/DVTPortal.framework/Versions/A/Resources/DVTPortalCachedPortalCapabilities.json
```

Raw `FSKIT_MOUNTER` fields:

```json
{
  "id": "FSKIT_MOUNTER",
  "name": "FSKit Mounter",
  "isPublic": true,
  "canRequestFromPortal": false,
  "developmentOnly": false,
  "distributionApprovalRequired": false,
  "distributionTypes": ["AD_HOC", "DEVELOPER_ID", "DEVELOPMENT", "STORE"],
  "profileKey": "com.apple.developer.fskit.mount",
  "valueType": "BOOLEAN",
  "value": "true"
}
```

**Metadata verdict: Developer ID is supported / grantable according to Xcode's public capability catalogue, with no distribution approval requirement. Actual grant to this team/profile is NOT VERIFIED.** No capability enablement, profile mutation, POST, or request to Apple was made. The public ASC API's separate enum limitation found in R1 must not be read as proof that this mounter capability is ungrantable. Current host signing does not already contain it.

Throwaway `spikes/r2/MountSingleVolumeProbe.swift` exercises the **authorization boundary only**, using an `FSPathURLResource` naming the read-only fixture device. It is **not a block-device remounter**: the inspected public block-resource header exposes no fresh BSD-name proxy initializer, and the path-resource authorization result cannot establish that an entitled block mount would work.

```sh
xcrun swiftc -parse-as-library -framework FSKit spikes/r2/MountSingleVolumeProbe.swift -o build/r2/MountSingleVolumeProbe
codesign --force --sign 'Developer ID Application: Nguyen Le (37PX6W22C5)' --options runtime --timestamp build/r2/MountSingleVolumeProbe
build/r2/MountSingleVolumeProbe /dev/disk8
```

```text
# Initial options ["-r"] were rejected before entitlement checking:
domain=NSPOSIXErrorDomain code=45 ... Operation not supported invalid option (-r)
# Corrected options ["-o", "ro"] match the installed module's shortOptions=o:
# exit 1
domain=NSPOSIXErrorDomain code=1 ... Operation not permitted elapsed=0.005905625 seconds
02:27:10.364 fskitd[616] Incomming connection, entitled 0
02:27:10.366 fskitd[616] ... tokenHasMountEntitlement:forPath:]:hasEntitlement(0)
02:27:10.366 fskitd[616] Client is missing 'com.apple.developer.fskit.mount' entitlement
```

No forged entitlement, private constructor, or false mount success was introduced. General API references: [Apple FSKit](https://developer.apple.com/documentation/fskit), [FSClient](https://developer.apple.com/documentation/fskit/fsclient). The local SDK and Xcode catalogue above are the precise versioned evidence for this host.

## Force-detach during directory traversal

This was deliberately run **before** the metadata intervention, while Apple's native implementation could mount the image. `fixtures/bigdir.img` supplies enough entries that `ls` was still running when detach was launched:

```sh
hdiutil attach -readonly fixtures/bigdir.img
diskutil info /dev/disk8
```

Confirmed `/Volumes/Yuzu-bigdir`, bundle `ntfs`, personality NTFS, read-only media/volume. The test harness launched these without a shell pipeline:

```python
lsproc = subprocess.Popen(["/bin/ls", "-R", "/Volumes/Yuzu-bigdir"],
                          stdout=ls_output_file, stderr=subprocess.STDOUT)
print(lsproc.pid, lsproc.poll())  # 81129, None: still running
subprocess.run(["hdiutil", "detach", "-force", "/dev/disk8"], timeout=15)
lsproc.wait(timeout=10)
```

```text
ls pid 81129 state before detach None
hdiutil detach -force /dev/disk8: exit=0 elapsed=0.822s
"disk8" ejected.
ls exit 1 elapsed 0.823 seconds; no hang
ls output bytes 135796
ls: /Volumes/Yuzu-bigdir: No such file or directory
```

There was actual directory output before removal, not merely an idle/stopped process. Neither `ls` nor detach hit its deadline; no process kill was needed. This demonstrates bounded behavior for **one image detach through Apple's NTFS**, not a real USB disconnect, not Yuzu's volume lifecycle, and not a system-wide hang guarantee. Real-hardware unplug-during-ls remains **PENDING-OWNER**.

## Final state and checks exercised

- One metadata-only signed build; notarized Accepted, stapled, installed; codesign deep/strict and Gatekeeper checks succeeded.
- One scoped R2 user-agent restart with timestamped backup and zero settings writes; no reinstall/registration afterward.
- Original Apple auto-mount, native probe status, ordered auto-selection, DiskArbitration manual attempt, explicit FSKit manual attempt, invalid diskutil syntax, and signed mount API entitlement rejection were exercised.
- `hdiutil detach /dev/disk8` finally returned exit 0 (`"disk8" ejected.`); final `hdiutil info -plist` contained **no image path under this repo's fixtures directory**.
- Installed app remains the R2 metadata build; NTFS fixture auto-attachment now selects Yuzu and therefore **fails to mount until Task 5 provides an engine**. This expected consequence is important for the next task.
- Raw local command captures and unified logs are in ignored `build/r2/`; durable commands and raw excerpts are included here. The only retained R2 code is the explicitly marked throwaway authorization probe.
