#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Independent ntfsprogs readback checks for the generated, user-authored corpus."""
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import unicodedata

ROOT = Path(__file__).resolve().parent.parent
EXPECTED = {
    "basic-512": (512, 4096, 9),
    "4kn": (4096, 4096, 9),
    "c64k": (512, 65536, 9),
    "bigdir": (512, 4096, 100000),
    "names": (512, 4096, 4),
}


def run(tool, *args):
    return subprocess.check_output([str(ROOT / "tools/bin" / tool), *map(str, args)])


def main():
    for name, (sector, cluster, count) in EXPECTED.items():
        image = ROOT / "fixtures" / f"{name}.img"
        manifest = json.loads(image.with_suffix(".manifest.json").read_text())
        entries = manifest["entries"]
        assert len(entries) == manifest["entry_count"] == count, name
        assert len({e["path"] for e in entries}) == count, "duplicate manifest path"
        with image.open("rb") as disk:
            boot = disk.read(512)
        assert boot[3:11] == b"NTFS    "
        assert struct.unpack_from("<H", boot, 11)[0] == sector
        assert boot[13] * sector == cluster
        run("ntfsinfo", "-m", image)
        expected_root = 7 if name in ("basic-512", "4kn", "c64k") else count
        listed = run("ntfsls", "-p", "/", image).decode("utf-8").splitlines()
        assert len(listed) == expected_root, (name, len(listed), expected_root)
        sampled = entries if name != "bigdir" else [entries[i] for i in (0, 1, 49999, 99999)]
        for entry in sampled:
            if entry["type"] == "directory":
                assert entry["size"] == 0 and entry["sha256"] is None
                continue
            path = entry["path"]
            if entry["type"] == "stream":
                path, stream = path.rsplit(":", 1)
                data = run("ntfscat", "-n", stream, image, path)
            else:
                # Darwin ntfsprogs normally normalizes NFD input to NFC. Read by
                # MFT reference so the independent read cannot alias the NFC file.
                data = run("ntfscat", "-i", entry["mft_record"], image)
            assert len(data) == entry["size"], (name, path)
            assert hashlib.sha256(data).hexdigest() == entry["sha256"], (name, path)
        if name in ("basic-512", "4kn", "c64k"):
            by_path = {e["path"]: e for e in entries}
            assert by_path["/resident.txt"]["mft_record"] == by_path["/resident-hardlink.txt"]["mft_record"]
            assert by_path["/fragmented.bin"]["data_runs"] > 1
        if name == "names":
            paths = [e["path"] for e in entries]
            assert any("中文" in p for p in paths) and any("😀" in p for p in paths)
            assert len(set(map(lambda p: unicodedata.normalize("NFC", p), paths))) == count - 1
            assert len({e["mft_record"] for e in entries}) == count
        print(f"{name}: sector={sector} cluster={cluster} entries={count}; ntfsinfo/list/read/hash PASS")


if __name__ == "__main__":
    main()
