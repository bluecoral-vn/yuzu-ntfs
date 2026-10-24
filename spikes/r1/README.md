# R1 throwaway enablement probe

This directory is throwaway spike code, not shipping app functionality.

Run on macOS 27 with Xcode selected:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
scripts/build-fsclientprobe.sh
build/r1/FSClientProbe --expect-enabled \
  --expect-path '/Applications/Yuzu NTFS.app/Contents/Extensions/YuzuNTFSModule.appex'
build/r1/FSClientProbe --open-settings
```

The `--open-settings` command only opens System Settings. It does not toggle or enable an extension. Do not infer enablement from its Boolean result. Findings and owner-only GUI steps are in `docs/spikes/p0-r1-enable.md`.

The build script selects an already-installed Developer ID certificate by fingerprint and certificate OU, signs only the standalone probe, verifies `TeamIdentifier=37PX6W22C5`, and never creates a certificate or runs/registers the app. Do not replace it with raw `swift`/`swiftc`: an ad-hoc caller on this host only enumerates Apple modules and falsely reports Yuzu absent. `p0_ops.py` rejects missing/wrong-team probe signatures before querying readiness.

`tt-self-enable.py` reproduces only the agent-reload part of TT NTFS Native's undocumented workaround. It requires our ID to be present already, validates Apple's string-array schema, creates a timestamped backup outside the repo, writes no plist data, and SIGKILLs only the current user's `fskit_agent`. It can drop **other FSKit mounts** for that user. It was run twice under explicit controller rulings, with the second run after the final installation/registration; it is not a supported onboarding or update API. Do not run it casually or from shipping app code.

