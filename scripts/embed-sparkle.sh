#!/bin/bash
set -euo pipefail
case "$CONFIGURATION" in
    Debug|Release-Direct) ;;
    *) exit 0 ;;
esac

SOURCE="$BUILT_PRODUCTS_DIR/Sparkle.framework"
DESTINATION="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/Sparkle.framework"
if [[ ! -d "$SOURCE" ]]; then
    printf 'Missing SwiftPM Sparkle framework: %s\n' "$SOURCE" >&2
    exit 1
fi
mkdir -p "$(dirname "$DESTINATION")"
/usr/bin/ditto "$SOURCE" "$DESTINATION"

# Sparkle's sandboxing guide requires signing nested helpers individually;
# Code Sign on Copy alone does not re-sign its XPC services. Never use --deep.
if [[ "${CODE_SIGNING_ALLOWED:-YES}" == YES ]]; then
    IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
    SIGN_OPTIONS=(--force --sign "$IDENTITY" --options runtime)
    if [[ "$IDENTITY" != - ]]; then SIGN_OPTIONS+=(--timestamp); fi
    CONTENTS="$DESTINATION/Versions/B"
    /usr/bin/codesign "${SIGN_OPTIONS[@]}" "$CONTENTS/XPCServices/Installer.xpc"
    /usr/bin/codesign "${SIGN_OPTIONS[@]}" --preserve-metadata=entitlements "$CONTENTS/XPCServices/Downloader.xpc"
    /usr/bin/codesign "${SIGN_OPTIONS[@]}" "$CONTENTS/Autoupdate"
    /usr/bin/codesign "${SIGN_OPTIONS[@]}" "$CONTENTS/Updater.app"
    /usr/bin/codesign "${SIGN_OPTIONS[@]}" "$DESTINATION"
fi
