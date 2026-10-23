# P0 R1 — FSKit extension enablement

## Verdict and scope

**Provisional technical PASS on macOS 27 only:** a normally signed, notarized, stapled, sandboxed Yuzu NTFS module was enabled and invoked on a read-only fixture without sudo or any SIP/security-setting changes. The final mount reached `loadResource` and its intentional `ENOTSUP` (Darwin errno 45), rather than an unknown/disabled-filesystem error.

**The full R1 product gate remains OPEN / PENDING-OWNER.** The brief requires a normal-user, no-Terminal path on both macOS 26 and 27. The owner-only Settings toggle was deliberately not clicked, the macOS 26 VM is unavailable, and the only completed host enablement sequence includes TT NTFS Native's undocumented per-user agent restart. A shipping Enable button is not implemented or validated by this spike. Do not interpret the technical result as approval to ship the workaround.

Host: macOS **27.0.1**, build **26A434**, arm64; Xcode **27.1**, build **27A9275**, macOS 27.0 SDK build **26A425**. Experiments: 2026-10-24, local time UTC+07:00. PlugInKit timestamps are UTC. Installed app: `/Applications/Yuzu NTFS.app`, version `0.1.0` / build `1`.

## Paths tested

“Enable works” means the complete path achieved enabled-module visibility **and** reached our module on the fixture, not just that a command exited zero.

| Path | macOS 27 result | User steps / sandbox requirement | macOS 26 |
|---|---|---|---|
| (a) System Settings toggle | **PENDING-OWNER**; not clicked, no Y/N enablement claim | Open General → Login Items & Extensions → Extensions / By Category → File System Extensions → information button → enable Yuzu NTFS. This is an OS UI action; the module remains sandboxed. See exact owner procedure below. | **PENDING-OWNER** |
| (b) `FSClient.shared.openFileSystemExtensionsSettings()` | **Y** for opening Settings (`true`); **N** as an enable operation by itself | Run the throwaway Swift probe with `--open-settings`, or expose this public API from the eventual app UI, then the user must toggle in Settings. Tested from an unsandboxed Swift process; sandboxed-host behavior was **not tested**. Available on macOS 27. | **Unavailable** API; GUI path **PENDING-OWNER** |
| (c) `pluginkit -e use -i com.bluecoral.vn.yuzuntfs.fsmodule` | **Y** for election (`+`); **N** as a sufficient standalone enablement path | Terminal command. Tested unsandboxed; arbitrary process execution / equivalent behavior from a sandboxed host was not tested. Neither election nor registration alone proved a live module. | **PENDING-OWNER** |
| (d) TT NTFS Native self-enable sequence | **Y**, in combination with valid signing, a single installed registration and an agent reload after that final registration | TT documents merge-adding our ID to Apple's per-user string-array plist and SIGKILLing only the user's `fskit_agent`. Our ID already existed, so **no plist edit was made**; only timestamped backups and the user-agent reload were reproduced. Requires an **unsandboxed host** according to TT's source: Apple's restricted group-container path and signalling another process are outside the app sandbox. Our module itself stayed sandboxed. | **PENDING-OWNER**; TT's published 26.3 / 26.6.2 results are reference claims, not this project's tests |

Chosen **technical fallback** on the tested host: (d), after (c), duplicate-registration pruning and stable final installation. Preferred **product path** remains (a), with (b) as a macOS 27 convenience opener, pending the owner's actual toggle test. If (a) does not work, the only demonstrated fallback is undocumented and requires a separate product/distribution decision; no no-Terminal product path is yet accepted.

## Signing and provisioning findings

`com.apple.developer.fskit.fsmodule` is **restricted**, not a self-asserted/unrestricted entitlement. The module's initial Developer ID profile omitted it; Xcode stopped with:

```text
Provisioning profile "Yuzu NTFS FSKit Module Developer ID" doesn't include the FSKit Module capability.
Provisioning profile "Yuzu NTFS FSKit Module Developer ID" doesn't include the com.apple.developer.fskit.fsmodule entitlement.
```

Apple's published ASC `CapabilityType` list omits FSKit. Xcode 27.1's `DVTPortalCachedPortalCapabilities.json` identifies the capability as `FSKIT_MODULE`, public, with Developer ID support and no distribution approval requirement. Nevertheless, public `POST /v1/bundleIdCapabilities` with `capabilityType: FSKIT_MODULE` returned HTTP **409**, invalid capability-type enum.

**Working capability setup:** Xcode's own automatic provisioning service, authenticated with the existing ASC API key, enabled `FSKIT_MODULE` on our extension App ID. The archive command then failed because the team had no registered Mac development devices, **but the capability change persisted**. A subsequent ASC GET confirmed `Q4V58PT697_FSKIT_MODULE`. Regenerating only our just-created incomplete module profile through ASC then produced the required entitlement. No portal GUI, certificate creation, or signing bypass was needed.

Resources created / reused:

| Resource | Value |
|---|---|
| App identifier / ASC resource | `com.bluecoral.vn.yuzuntfs` / `K8AFDDVQ6Z` |
| Module identifier / ASC resource | `com.bluecoral.vn.yuzuntfs.fsmodule` / `Q4V58PT697` |
| Existing Developer ID certificate reused | `AH6S2Z57KL`, SHA-1 `357630FEC1EA6B2B0871F13013DC8353D1107BC1` |
| App direct profile | `Yuzu NTFS Developer ID`, UUID `61276098-fc82-4503-90c6-2e83ab66e060`, resource `JQ9PU276NH` |
| Final module direct profile | `Yuzu NTFS FSKit Module Developer ID`, UUID `0e16a405-f1d6-451f-9c9a-1ce927499569`, resource `G8TLHBGNNJ` |
| Incomplete module profile replaced | Resource `MRCC4464UB`, UUID `8b8c7be7-3cb4-4990-930a-cfef6cb94518`; only this task-created profile was deleted |
| Host Mac registered, under controller authorization | `rom Mac - Yuzu NTFS P0`, UDID `00006050-0019092E14F1401C`, ASC resource `T3C2UXP3SW`; POST returned `PROCESSING`. This registration was not needed for the successful manual Developer ID build. |

Both App IDs were submitted as platform `MAC_OS`; ASC returned `UNIVERSAL`, its normal representation here. Profiles were installed under both `~/Library/Developer/Xcode/UserData/Provisioning Profiles/` and `~/Library/MobileDevice/Provisioning Profiles/`. The replacement module profile explicitly contains `com.apple.developer.fskit.fsmodule = true`.

`scripts/setup-signing.sh` reproduces scoped App ID registration, Xcode capability bootstrap if needed, existing-certificate selection, profile creation/reuse and installation. It never calls the certificate-creation API, prints no JWT/private key, and refuses to delete a same-name profile whose decoded application identifier is not ours. The already-enabled/profile-reuse path was exercised successfully. The fresh-account bootstrap branch encodes the Xcode provisioning route exercised manually in this spike; it was not replayed against a second fresh account.

`project.yml` now keeps Debug ad-hoc buildable and adds `Release-Direct`: manual Developer ID signing, named per-target profiles, hardened runtime, timestamp, and no injected base/debug entitlement. The shipping-style app has no `get-task-allow`; module entitlements include the authorized FSKit entitlement and `com.apple.security.app-sandbox = true`. The host is unsandboxed. No Yuzu Drag identifiers, profiles, certificates or source files were modified.

## Build, notarization, installation

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
scripts/setup-signing.sh
xcodegen generate
xcodebuild -scheme YuzuNTFS -configuration Release-Direct -derivedDataPath build/r1 build
ditto -c -k --keepParent 'build/r1/Build/Products/Release-Direct/Yuzu NTFS.app' build/r1/YuzuNTFS.zip
xcrun notarytool submit build/r1/YuzuNTFS.zip --keychain-profile yuzu-notary --wait --output-format json
xcrun stapler staple 'build/r1/Build/Products/Release-Direct/Yuzu NTFS.app'
ditto 'build/r1/Build/Products/Release-Direct/Yuzu NTFS.app' '/Applications/Yuzu NTFS.app'
open '/Applications/Yuzu NTFS.app'
```

Observed `** BUILD SUCCEEDED **`. Initial notarization submission `4ae6215f-4890-43fb-aac4-d0890b9d4d36` was **Accepted**. During diagnosis, the module gained `FSActivateOptionSyntax: { shortOptions: "o:" }`, matching Apple's Xcode template and TT's mount-option metadata; that build's submission `e1935a07-bc3a-4aea-b10e-957466b9069e` was also **Accepted**, stapled, and is the final installed build. The metadata change alone did **not** solve stale discovery; the successful combined configuration should not be mistaken for an isolated proof that this key caused the fix.

Final `codesign --verify --deep --strict '/Applications/Yuzu NTFS.app'` exited zero. `spctl --assess --type execute --verbose=2` reported:

```text
/Applications/Yuzu NTFS.app: accepted
source=Notarized Developer ID
```

Built bundle location and metadata were checked: `.appex` is correctly in `Contents/Extensions/`, `EXAppExtensionAttributes.EXExtensionPointIdentifier` is `com.apple.fskit.fsmodule`, `FSShortName` is `yuzuntfs`, block resources are enabled, and there is no legacy `NSExtension` dictionary. No layout workaround was needed. The requested locally installed FUSE-T reference could not be found: both Spotlight's exact module-ID search and PlugInKit returned no matches. Its enabled-list entry is not proof that its binary is installed on this Mac.

## Registration and UUID-cache finding

Before election, `pluginkit -mAvvv -p com.apple.fskit.fsmodule` listed our module with a blank election prefix. After `pluginkit -e use -i com.bluecoral.vn.yuzuntfs.fsmodule`, it showed `+`. Initially `FSClient.installedExtensions` still omitted Yuzu, and mount failed before invoking our extension.

**Use `-D` to expose duplicates.** `pluginkit -mADvvv -i com.bluecoral.vn.yuzuntfs.fsmodule` revealed four copies, including old ad-hoc Debug builds. Only the three known noninstalled copies were pruned:

```sh
pluginkit -r \
 '/Users/rom/Projects/yuzu-ntfs-p0/build/Build/Products/Debug/YuzuNTFS.app/Contents/Extensions/YuzuNTFSModule.appex' \
 '/Users/rom/Projects/yuzu-ntfs-p0/build/r1/Build/Products/Release-Direct/Yuzu NTFS.app/Contents/Extensions/YuzuNTFSModule.appex' \
 '/Users/rom/Library/Developer/Xcode/DerivedData/YuzuNTFS-ggixrolbwswkchdvpwinppvvteuz/Build/Products/Debug/YuzuNTFS.app/Contents/Extensions/YuzuNTFSModule.appex'
```

The corresponding parent app paths were also unregistered with:

```sh
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u '/Users/rom/Projects/yuzu-ntfs-p0/build/Build/Products/Debug/YuzuNTFS.app'
"$LSREGISTER" -u '/Users/rom/Projects/yuzu-ntfs-p0/build/r1/Build/Products/Release-Direct/Yuzu NTFS.app'
"$LSREGISTER" -u '/Users/rom/Library/Developer/Xcode/DerivedData/YuzuNTFS-ggixrolbwswkchdvpwinppvvteuz/Build/Products/Debug/YuzuNTFS.app'
"$LSREGISTER" -f '/Applications/Yuzu NTFS.app'
pluginkit -e use -i com.bluecoral.vn.yuzuntfs.fsmodule
```

No other module or app was unregistered. The final `-mADvvv` output contained **one** Yuzu entry:

```text
+ com.bluecoral.vn.yuzuntfs.fsmodule(0.1.0)
  Path = /Applications/Yuzu NTFS.app/Contents/Extensions/YuzuNTFSModule.appex
  UUID = 7FFBB224-A94D-479D-B839-1E2864C3777D
  Parent Bundle = /Applications/Yuzu NTFS.app
```

Yuzu briefly appeared `enabled=true` after duplicate pruning, then disappeared again after reinstallation/re-registration. The final agent restart **after** stable installation and registration restored `enabled=true` and enabled the successful module invocation. This sequence is consistent with TT's documented plugin-UUID cache; the internal cached UUID is private in logs, so the cache mechanism itself is not independently decoded here.

**Product implication:** onboarding and updates must be designed for **install → first launch / registration → final enablement state refresh**. A Sparkle update can register a new plugin UUID; a previously checked election or enabled-list entry is not enough to promise that the new module will run. Never restart the agent while a user volume may be served. Re-registration also produced `launchd: remove all extension instances: caller = pkd` in the host log. Do not build/register extra copies during a live-volume test.

## TT fallback: exact state handling and restore

Reference read: TT's `fskit/README.md`, `fskit/scripts/enable-module.sh`, and `fskit/NTFS/ModuleEnabler.swift`. Its mechanism is a per-user plist write plus a process signal, **not a public FSClient enable API**. It is undocumented Apple-internal state and **may break on any OS update**. It is only a technical fallback, not an accepted product path.

The initial inspected plist was an XML **array of strings** containing six Apple IDs. Before our reproduction it already contained two additional entries:

```diff
   <string>com.apple.dt.CoreDevice.Extensions.DeviceFS</string>
+  <string>com.bluecoral.vn.yuzuntfs.fsmodule</string>
+  <string>org.fuset.fskit-srv.module</string>
```

`stat` reported plist mtime `2026-10-24 01:56:57 +0700`, after the first public Settings opener call (`01:56:51`) and before the post-install PlugInKit election (`01:58:31`). **The writer was not observed.** Settings initialization is an inference, not a proven attribution; this spike did not add either entry. An initial reproduction invocation refused before writes/signals because our entry already existed. Under the controller's revised ruling, the script was constrained to require our existing entry, preserve the entire plist byte-for-byte, back it up and restart only our user agent. FUSE-T's entry was never changed.

Executed commands, each once under explicit controller authorization:

```sh
python3 spikes/r1/tt-self-enable.py
# First successful run: backup ...enabledModules.plist.yuzuntfs-backup-20261024-015959
# SIGKILL current-user fskit_agent 1700

# After final installation, duplicate pruning and final registration:
python3 spikes/r1/tt-self-enable.py
# Second authorized run: backup ...enabledModules.plist.yuzuntfs-backup-20261024-020919
# SIGKILL current-user fskit_agent 42660
```

The script uses `pgrep -u <current uid> -x fskit_agent` and Python `os.kill(pid, SIGKILL)`. It never signals root's daemon or another user's agent. **Before/after plist diff for each successful run: empty (no bytes or entries changed).** Backups are outside the repo, next to the original:

```text
/Users/rom/Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist.yuzuntfs-backup-20261024-015959
/Users/rom/Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist.yuzuntfs-backup-20261024-020919
```

Exact restore command for the final backup (not executed, because no plist edit needed restoring):

```sh
cp '/Users/rom/Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist.yuzuntfs-backup-20261024-020919' \
   '/Users/rom/Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist'
```

Restoring a plist does not make an already-running agent reload it; no additional restart is authorized by this document. **Agent restart can disrupt other FSKit mounts:** the first restart generated `spontaneous unmount done` / cleanup logs for the existing CoreDevice DeviceFS mount. It is not safe to assume that checking only Yuzu's mounts prevents collateral unmounts. No physical NTFS disk was used or modified.

## Final fixture invocation and log evidence

Only `fixtures/basic-512.img` was attached, read-only and without mounting. The attachment returned `/dev/disk8`; this device number is this run's value, not a reusable constant. No volume was successfully mounted, as expected at this phase.

```sh
hdiutil attach -readonly -nomount fixtures/basic-512.img
/sbin/mount -F -r -t yuzuntfs /dev/disk8 \
  /Users/rom/Projects/yuzu-ntfs-p0/build/r1/mountpoint
hdiutil detach /dev/disk8
```

After the final stable-registration restart, the same-team signed FSClient probe printed:

```text
com.bluecoral.vn.yuzuntfs.fsmodule enabled=true
```

Final mount output, exit **69**:

```text
mount: Loading resource: The operation couldn’t be completed. Operation not supported
mount: FSKit unavailable
```

The generic trailing “FSKit unavailable” is **not** interpreted alone. The paired extension and daemon logs prove it reached our deliberate loading rejection:

```text
02:09:23.443 fskit_agent[54858] Launching process ... bundleID: com.bluecoral.vn.yuzuntfs.fsmodule,
  URL: file:///Applications/Yuzu%20NTFS.app/Contents/Extensions/YuzuNTFSModule.appex/
02:09:24.156 YuzuNTFSModule[54956] AppSandbox
02:09:24.326 YuzuNTFSModule[54956] readFirstSectorAndLog reading from 3 got rv 512 error (null)
02:09:24.327 fskitd[616] ... probe resource error ((null))
02:09:24.374 YuzuNTFSModule[54978] -[FSModuleConnector loadResource:options:replyHandler:]:start
02:09:24.374 YuzuNTFSModule[54978] configureUserClient for FSModule com.bluecoral.vn.yuzuntfs.fsmodule returned error ((null))
02:09:24.374 YuzuNTFSModule[54978] ... load error Error Domain=NSPOSIXErrorDomain Code=45,
  container status Error Domain=NSPOSIXErrorDomain Code=35
02:09:24.375 fskitd[616] ... apply resource error ((null)),
  load resource error (Error Domain=NSPOSIXErrorDomain Code=45)
```

`Module/YuzuNTFSFileSystem.swift` intentionally replies `POSIXError(.ENOTSUP)` from `loadResource`. The container-status errno 35 is a companion framework diagnostic, not an assertion of NTFS data corruption. The fixture was detached successfully (`"disk8" ejected`). The mountpoint remains an empty ignored build directory.

Earlier failure evidence, retained to distinguish election from actual invocation:

```text
# Before stable registration/reload:
mount: Filesystem yuzuntfs does not support operation mount
mount: File system named yuzuntfs unable to mount
# Other attempts, including -r before the final reload:
mount: Unable to invoke task
# mount log at 02:07:09:
FSClient(Private) installedExtensionWithShortName: ... No extension with fsShortName (<private>) found.
# Public Settings opener baseline fskitd log at 01:56:51.598:
Incomming connection, entitled 0
# Its result was openFileSystemExtensionsSettings=true, not enablement.
```

Log capture used:

```sh
/usr/bin/log show --last 2m --style compact --info --debug \
 --predicate 'process == "YuzuNTFSModule" OR (process == "fskitd" AND (eventMessage CONTAINS[c] "load" OR eventMessage CONTAINS[c] "error" OR eventMessage CONTAINS[c] "probe")) OR (process == "fskit_agent" AND eventMessage CONTAINS[c] "yuzu")'
# Per-path daemon-only baseline:
/usr/bin/log show --last 10m --style compact --predicate 'process == "fskitd"'
```

## Exact owner-only GUI check

No Settings control was clicked by the agent. On the installed, notarized app:

1. Open **System Settings → General → Login Items & Extensions**.
2. In **Extensions**, choose **By Category** if shown, then **File System Extensions**, then its information button.
3. Find **Yuzu NTFS / YuzuNTFSModule**, confirm it belongs to the installed Yuzu NTFS app, and turn its toggle on. If it is already on, report that state rather than toggling it off while any FSKit volume might be active.
4. Record whether the toggle stays on, any authentication/error dialog, and the macOS version/build. The agent must then correlate a fresh FSClient state and fixture-only mount log; a visual toggle alone does not close R1.
5. Repeat on a macOS 26 VM when available, using that OS's GUI path (the public opener API is macOS 27-only).

The owner GUI path, a no-Terminal app-facing flow, macOS 26 behavior, sandboxed-host Settings opening, and safe update/onboarding handling are deliberately **not claimed verified**. Throwaway code is limited to `spikes/r1/`; signing setup and the direct configuration are retained.

## Sources

- [Apple FSKit overview](https://developer.apple.com/documentation/fskit)
- [Apple FSKit module entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.fskit.fsmodule)
- [Apple ASC CapabilityType](https://developer.apple.com/documentation/appstoreconnectapi/capabilitytype)
- Local Xcode `DVTPortal.framework/.../DVTPortalCachedPortalCapabilities.json`, `FSKIT_MODULE` entry, and File System Extension template `TemplateInfo.plist`.
- [TT NTFS Native fskit README](https://github.com/dr-kbadawi/ttntfs/blob/main/fskit/README.md)
- [TT enable-module.sh](https://github.com/dr-kbadawi/ttntfs/blob/main/fskit/scripts/enable-module.sh)
- [TT ModuleEnabler.swift](https://github.com/dr-kbadawi/ttntfs/blob/main/fskit/NTFS/ModuleEnabler.swift)
- [TT project.yml](https://github.com/dr-kbadawi/ttntfs/blob/main/fskit/project.yml)

TT's assertions about macOS 26 and App Store limitations are third-party claims, not substitutes for this project's acceptance tests or distribution review.
