#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Count maintained integration code, not pristine source or source symlinks.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec python3 - "$ROOT" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
directory = root / 'Packages/NTFSCore/Sources/EngineE2'
baseline = root / 'upstream/ttntfs'
if not directory.is_dir() or not baseline.is_dir():
    sys.exit('EngineE2 or its pristine upstream/ttntfs baseline is missing')
authored = patch_added = patch_removed = files = 0
for path in sorted(directory.rglob('*')):
    if not path.is_file() or path.is_symlink():
        continue
    lines = path.read_text().splitlines()
    if path.suffix in ('.c', '.h'):
        authored += len(lines)
        files += 1
    elif path.suffix in ('.patch', '.diff'):
        patch_added += sum(line.startswith('+') and not line.startswith('+++') for line in lines)
        patch_removed += sum(line.startswith('-') and not line.startswith('---') for line in lines)
print(f'EngineE2: baseline=upstream/ttntfs; glue={authored} physical C/header lines in {files} files; '
      f'patches=+{patch_added}/-{patch_removed}; maintained_total={authored + patch_added + patch_removed}')
print('EngineE1: absent — deferred under T6-R2; no E1 size comparison is available.')
print('Excludes pristine vendored files, symlinked sources, docs, build configuration and tests.')
print('Totals measure maintained integration surface, not a similarity diff between unrelated glue and kernel files.')
PY
