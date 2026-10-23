#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=2022.10.3
SHA256=f20e36ee68074b845e3629e6bced4706ad053804cbaf062fbae60738f854170c
ARCHIVE="$ROOT/vendor/ntfs-3g_ntfsprogs-$VERSION.tgz"
SOURCE="$ROOT/vendor/ntfs-3g_ntfsprogs-$VERSION"
STAMP="$ROOT/tools/bin/.ntfsprogs-$VERSION-$SHA256"
mkdir -p "$ROOT/vendor" "$ROOT/tools/bin"
if [[ -f "$STAMP" && -f "$SOURCE/libntfs-3g/.libs/libntfs-3g.a" ]]; then
    complete=true
    for tool in mkntfs ntfsinfo ntfsls ntfscat; do
        [[ -x "$ROOT/tools/bin/$tool" ]] || complete=false
    done
    if $complete; then
        echo "ntfsprogs $VERSION already built (static, no FUSE)"
        exit 0
    fi
fi
if [[ ! -f "$ARCHIVE" ]]; then
    curl --fail --location --retry 3 \
        "https://tuxera.com/opensource/ntfs-3g_ntfsprogs-$VERSION.tgz" \
        -o "$ARCHIVE.download"
    mv "$ARCHIVE.download" "$ARCHIVE"
fi
printf '%s  %s\n' "$SHA256" "$ARCHIVE" | shasum -a 256 -c -
if [[ ! -d "$SOURCE" ]]; then
    tar -xzf "$ARCHIVE" -C "$ROOT/vendor"
fi
cd "$SOURCE"
# The release tarball includes configure: no autotools, pkg-config or FUSE needed.
./configure --disable-ntfs-3g --enable-ntfsprogs --enable-static --disable-shared \
    --disable-crypto --disable-ldconfig --prefix="$ROOT/tools"
make -j "${JOBS:-4}" -C libntfs-3g
make -j "${JOBS:-4}" -C ntfsprogs mkntfs ntfsinfo ntfsls ntfscat
for tool in mkntfs ntfsinfo ntfsls ntfscat; do
    install -m 755 "$SOURCE/ntfsprogs/$tool" "$ROOT/tools/bin/$tool"
done
[[ -f "$SOURCE/libntfs-3g/.libs/libntfs-3g.a" ]]
touch "$STAMP"
echo "Built ntfsprogs $VERSION + libntfs-3g.a without FUSE"
