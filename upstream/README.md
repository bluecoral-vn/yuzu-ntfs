<!-- SPDX-License-Identifier: GPL-2.0-only -->
# Pinned upstream sources

## TT NTFS Native (engine E2)

- Repository: https://github.com/dr-kbadawi/ttntfs
- Commit: `36cc849a3ed867b8b6ee3fbc805ba2385cb79cdb`
- Retrieved: 2026-10-24
- Licence: GPL version 2; preserve the upstream per-file SPDX expressions (including GPL-2.0-or-later where present). See `ttntfs/LICENSE` and `ttntfs/COPYRIGHT`.
- Subset: `core/` and `platform/` source/header/build files, excluding tests and the unused stub, plus COPYRIGHT/LICENSE. No upstream file is patched.

`Packages/NTFSCore/Sources/EngineE2/tt_*.c` are relative symlinks to this pristine subset. Build integration, ABI translation and private runlist access live outside it; see that target's `PATCHES.md`.
