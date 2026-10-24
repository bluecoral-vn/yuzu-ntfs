#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail
COMMIT="$(git -C "$SRCROOT" rev-parse HEAD)"
PLIST="$TARGET_BUILD_DIR/$INFOPLIST_PATH"
/usr/libexec/PlistBuddy -c 'Delete :YuzuGitCommit' "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :YuzuGitCommit string $COMMIT" "$PLIST"
if [[ "$WRAPPER_EXTENSION" == appex ]]; then
    KOIO="$(/usr/libexec/PlistBuddy -c 'Print :EXAppExtensionAttributes:FSSupportsKernelOffloadedIO' "$PLIST")"
    [[ "$KOIO" == true ]] || { echo 'error: built extension must declare kernel-offloaded I/O'; exit 1; }
    echo "FSSupportsKernelOffloadedIO=$KOIO; YuzuGitCommit=$COMMIT; plist=$PLIST"
fi
