# R1 throwaway enablement probe

This directory is throwaway spike code, not shipping app functionality.

Run on macOS 27 with Xcode selected:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift spikes/r1/FSClientProbe.swift
swift spikes/r1/FSClientProbe.swift --open-settings
```

The second command only opens System Settings. It does not toggle or enable an extension. Do not infer enablement from its Boolean result. Findings and owner-only GUI steps are in `docs/spikes/p0-r1-enable.md`.

For the final status evidence, the probe was compiled and signed with the same Developer ID team as the module (without creating any identity):

```sh
xcrun swiftc spikes/r1/FSClientProbe.swift -o build/r1/FSClientProbe
codesign --force --sign 'Developer ID Application: Nguyen Le (37PX6W22C5)' \
  --options runtime --timestamp build/r1/FSClientProbe
build/r1/FSClientProbe
```

`tt-self-enable.py` reproduces only the agent-reload part of TT NTFS Native's undocumented workaround. It requires our ID to be present already, validates Apple's string-array schema, creates a timestamped backup outside the repo, writes no plist data, and SIGKILLs only the current user's `fskit_agent`. It can drop **other FSKit mounts** for that user. It was run twice under explicit controller rulings, with the second run after the final installation/registration; it is not a supported onboarding or update API. Do not run it casually or from shipping app code.

