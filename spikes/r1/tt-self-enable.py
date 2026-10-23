#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# Throwaway R1 reproduction, authorized by controller T3-R1. Not product code.
# Undocumented Apple-internal settings: may break on any macOS update.
import datetime
import difflib
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess

module = "com.bluecoral.vn.yuzuntfs.fsmodule"
path = Path.home() / "Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist"
before = path.read_bytes()
modules = plistlib.loads(before)
if not isinstance(modules, list) or not all(isinstance(item, str) for item in modules):
    raise SystemExit("Unexpected Apple schema: refusing to modify")
stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
backup = path.with_name(path.name + ".yuzuntfs-backup-" + stamp)
if backup.exists():
    raise SystemExit("Backup already exists: refusing to overwrite")
shutil.copy2(path, backup)
if module not in modules:
    raise SystemExit("Our entry is absent: no plist mutation authorized by this reproduction")
print("backup:", backup)
print("".join(difflib.unified_diff(
    plistlib.dumps(plistlib.loads(before)).decode().splitlines(keepends=True),
    plistlib.dumps(plistlib.loads(path.read_bytes())).decode().splitlines(keepends=True),
    fromfile="before", tofile="after")), end="")
pids = subprocess.run(["pgrep", "-u", str(os.getuid()), "-x", "fskit_agent"],
                      capture_output=True, text=True)
if pids.returncode not in (0, 1):
    raise SystemExit("Cannot enumerate own fskit_agent; plist backup retained")
for line in pids.stdout.splitlines():
    pid = int(line)
    os.kill(pid, signal.SIGKILL)
    print("SIGKILL current-user fskit_agent", pid)
print("restore command:", "cp", repr(str(backup)), repr(str(path)))
