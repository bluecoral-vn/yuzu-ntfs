#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Build/sign only the standalone readiness probe; never run it or register an app.
set -euo pipefail
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec python3 - "$ROOT" <<'PY'
import base64
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
sys.path.insert(0, str(root / "scripts"))
from p0_ops import TEAM, check_probe_signature

identities = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"],
                            capture_output=True, text=True, check=True).stdout
records = dict(re.findall(r'^\s*\d+\)\s+([0-9A-F]{40})\s+"([^"]+)"\s*$', identities, re.MULTILINE))
certificates = subprocess.run(["security", "find-certificate", "-a", "-p", "-c", "Developer ID Application:"],
                              capture_output=True, check=True).stdout
identity = None
for pem in re.findall(rb"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", certificates, re.DOTALL):
    der = base64.b64decode(b"".join(pem.splitlines()[1:-1]))
    fingerprint = hashlib.sha1(der).hexdigest().upper()
    if not records.get(fingerprint, "").startswith("Developer ID Application:"):
        continue
    subject = subprocess.run(["openssl", "x509", "-inform", "der", "-noout", "-subject",
                              "-nameopt", "sep_multiline,utf8,sname"],
                             input=der, capture_output=True, check=True).stdout.decode()
    units = [line.partition("=")[2].strip() for line in subject.splitlines()
             if line.partition("=")[0].strip() == "OU"]
    if units == [TEAM]:
        identity = fingerprint
        break
if identity is None:
    raise SystemExit("No installed Developer ID Application identity with certificate OU " + TEAM
                     + "; no certificates will be created.")

output = root / "build/r1/FSClientProbe"
output.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix=".fsclientprobe-", dir=output.parent) as directory:
    candidate = Path(directory) / "FSClientProbe"
    subprocess.run(["xcrun", "swiftc", "-framework", "FSKit", str(root / "spikes/r1/FSClientProbe.swift"),
                    "-o", str(candidate)], cwd=root, check=True)
    subprocess.run(["codesign", "--force", "--sign", identity, "--options", "runtime", "--timestamp",
                    str(candidate)], check=True)
    subprocess.run(["codesign", "--verify", "--strict", str(candidate)], check=True)
    signature = subprocess.run(["codesign", "-dvv", str(candidate)],
                               capture_output=True, text=True, check=True)
    check_probe_signature(signature.stdout + signature.stderr)
    os.replace(candidate, output)
print("Built", output, "TeamIdentifier=" + TEAM, "identity=" + identity)
PY
