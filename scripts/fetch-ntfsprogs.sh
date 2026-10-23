#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=2022.10.3
SHA256=f20e36ee68074b845e3629e6bced4706ad053804cbaf062fbae60738f854170c
ARCHIVE="$ROOT/vendor/ntfs-3g_ntfsprogs-$VERSION.tgz"
SOURCE="$ROOT/vendor/ntfs-3g_ntfsprogs-$VERSION"
BUILD="$ROOT/vendor/build/ntfs-3g-$VERSION"
STAMP="$BUILD/.installed-$SHA256"
mkdir -p "$BUILD" "$ROOT/tools/bin"
if [[ ! -f "$ARCHIVE" ]]; then
    curl --fail --location --retry 3 \
        "https://tuxera.com/opensource/ntfs-3g_ntfsprogs-$VERSION.tgz" \
        -o "$ARCHIVE.download"
    mv "$ARCHIVE.download" "$ARCHIVE"
fi
printf '%s  %s\n' "$SHA256" "$ARCHIVE" | shasum -a 256 -c -
# Check before even reusing built tools: older versions configured in-source.
# The generated vendor tree is disposable; recover it from the verified archive
# on extra/missing paths, changed bytes, changed types or executable-bit changes.
if python3 - "$ARCHIVE" "$SOURCE" <<'PY'
import pathlib
import sys
import tarfile

archive, source = map(pathlib.Path, sys.argv[1:])
with tarfile.open(archive, "r:gz") as tar:
    prefix = source.name + "/"
    members = {m.name[len(prefix):].rstrip("/"): m for m in tar.getmembers()
               if m.name.rstrip("/") != source.name}
    if source.is_symlink() or not source.is_dir():
        sys.exit(1)
    if {str(p.relative_to(source)) for p in source.rglob("*")} != set(members):
        sys.exit(1)
    for name, member in members.items():
        path = source / name
        if path.is_symlink():
            sys.exit(1)
        if member.isdir():
            if not path.is_dir():
                sys.exit(1)
        elif member.isfile():
            if (not path.is_file()
                    or path.stat().st_mode & 0o111 != member.mode & 0o111
                    or path.read_bytes() != tar.extractfile(member).read()):
                sys.exit(1)
        else:
            sys.exit(1)
PY
then
    echo "ntfsprogs $VERSION source matches verified archive"
else
    echo "Restoring pristine ntfsprogs $VERSION source from verified archive"
    rm -rf "$SOURCE"
    tar -xzf "$ARCHIVE" -C "$ROOT/vendor"
fi
if [[ -f "$STAMP" && -f "$BUILD/libntfs-3g/.libs/libntfs-3g.a" ]]; then
    complete=true
    for tool in mkntfs ntfsinfo ntfsls ntfscat; do
        [[ -x "$ROOT/tools/bin/$tool" ]] || complete=false
    done
    if $complete; then
        echo "ntfsprogs $VERSION already built (static, no FUSE)"
        exit 0
    fi
fi
cd "$BUILD"
# Keep the extracted release pristine: configure and compile out of tree.
# The release includes configure; no autotools, pkg-config or FUSE is needed.
"$SOURCE/configure" --disable-ntfs-3g --enable-ntfsprogs --enable-static --disable-shared \
    --disable-crypto --disable-ldconfig --prefix="$ROOT/tools"
make -j "${JOBS:-4}" -C libntfs-3g
make -j "${JOBS:-4}" -C ntfsprogs mkntfs ntfsinfo ntfsls ntfscat
for tool in mkntfs ntfsinfo ntfsls ntfscat; do
    install -m 755 "$BUILD/ntfsprogs/$tool" "$ROOT/tools/bin/$tool"
done
[[ -f "$BUILD/libntfs-3g/.libs/libntfs-3g.a" ]]
touch "$STAMP"
echo "Built ntfsprogs $VERSION + libntfs-3g.a without FUSE"
