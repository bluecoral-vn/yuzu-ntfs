#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Registers only Yuzu NTFS IDs; reuses an existing Developer ID certificate.
# ASC_KEY_PATH / ASC_KEY_ID / ASC_ISSUER_ID may override the default API key.
set -euo pipefail
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec python3 - "$ROOT" <<'PY'
import base64
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import hashlib

root = Path(sys.argv[1])
key_id = os.environ.get("ASC_KEY_ID", "5Y9N24UTB9")
issuer = os.environ.get("ASC_ISSUER_ID", "e8671c23-6675-4e90-84ff-ce9e70887b9a")
key_path = Path(os.environ.get("ASC_KEY_PATH", str(Path.home() / f".appstoreconnect/private_keys/AuthKey_{key_id}.p8")))
team = "37PX6W22C5"
identifiers = [("com.bluecoral.vn.yuzuntfs", "Yuzu NTFS", "Yuzu NTFS Developer ID"),
               ("com.bluecoral.vn.yuzuntfs.fsmodule", "Yuzu NTFS FSKit Module", "Yuzu NTFS FSKit Module Developer ID")]

def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()

def jwt():
    header = b64(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    now = int(time.time())
    claims = b64(json.dumps({"iss": issuer, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"}).encode())
    message = (header + "." + claims).encode()
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(key_path)],
                         input=message, capture_output=True, check=True).stdout
    # ECDSA P-256 DER sequence -> fixed-width JOSE r || s.
    if der[0] != 0x30 or der[2] != 0x02:
        raise SystemExit("Unexpected ECDSA signature encoding")
    length = der[3]
    r = int.from_bytes(der[4:4 + length], "big")
    offset = 4 + length
    if der[offset] != 0x02:
        raise SystemExit("Unexpected ECDSA signature encoding")
    length = der[offset + 1]
    s = int.from_bytes(der[offset + 2:offset + 2 + length], "big")
    return message.decode() + "." + b64(r.to_bytes(32, "big") + s.to_bytes(32, "big"))

def api(method, path, payload=None):
    request = urllib.request.Request("https://api.appstoreconnect.apple.com/v1/" + path,
        method=method, headers={"Authorization": "Bearer " + jwt(), "Content-Type": "application/json"},
        data=json.dumps(payload).encode() if payload is not None else None)
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            body = response.read()
            return json.loads(body) if body else None
    except urllib.error.HTTPError as error:
        # Error JSON contains no JWT or private key material.
        raise SystemExit(f"ASC {method} {path}: HTTP {error.code}: {error.read().decode()}") from None

def query(resource, **filters):
    return resource + "?" + urllib.parse.urlencode(filters)

def all_items(resource):
    result = api("GET", resource + "?limit=200")
    items = result["data"]
    while result.get("links", {}).get("next"):
        next_path = result["links"]["next"].split("/v1/", 1)[1]
        result = api("GET", next_path)
        items.extend(result["data"])
    return items

bundles = {}
for identifier, name, _ in identifiers:
    matches = api("GET", query("bundleIds", **{"filter[identifier]": identifier}))["data"]
    bundle = matches[0] if matches else api("POST", "bundleIds", {"data": {"type": "bundleIds", "attributes": {
        "identifier": identifier, "name": name, "platform": "MAC_OS"}}})["data"]
    bundles[identifier] = bundle["id"]
    print("Bundle ID:", identifier, bundle["id"])

module_id = bundles[identifiers[1][0]]
def module_capability_enabled():
    capabilities = api("GET", f"bundleIds/{module_id}/bundleIdCapabilities")["data"]
    return any(item["attributes"]["capabilityType"] == "FSKIT_MODULE" for item in capabilities)

identities = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"],
                            capture_output=True, text=True, check=True).stdout
if not module_capability_enabled():
    # Public ASC POST rejects FSKIT_MODULE (409); Xcode's provisioning service knows it.
    # This may report no registered development Macs yet still enable the capability.
    # No certificate creation is needed: reuse the installed Apple Development identity.
    if "Apple Development:" not in identities or "(" + team + ")" not in identities:
        raise SystemExit("Install the existing Apple Development identity before Xcode provisioning; no certificate creation authorized.")
    subprocess.run(["xcodegen", "generate"], cwd=root, check=True)
    result = subprocess.run(["xcodebuild", "-scheme", "YuzuNTFS", "-configuration", "Release-Direct",
        "-derivedDataPath", "build/signing-bootstrap", "-destination", "generic/platform=macOS",
        "CODE_SIGN_STYLE=Automatic", "CODE_SIGN_IDENTITY=Apple Development", "PROVISIONING_PROFILE_SPECIFIER=",
        "DEVELOPMENT_TEAM=" + team, "-allowProvisioningUpdates", "-authenticationKeyPath", str(key_path),
        "-authenticationKeyID", key_id, "-authenticationKeyIssuerID", issuer, "build"], cwd=root)
    if not module_capability_enabled():
        raise SystemExit("Xcode provisioning did not enable FSKit Module. Enable it on App ID "
                         "com.bluecoral.vn.yuzuntfs.fsmodule in the Developer portal, then rerun. "
                         f"Xcode exit status: {result.returncode}")
    print("FSKIT_MODULE enabled by Xcode provisioning service; bootstrap exit", result.returncode)

certificate_id = None
for cert in all_items("certificates"):
    attrs = cert["attributes"]
    if attrs["certificateType"] not in ("DEVELOPER_ID_APPLICATION", "DEVELOPER_ID_APPLICATION_G2"):
        continue
    der = base64.b64decode(attrs["certificateContent"])
    if hashlib.sha1(der).hexdigest().upper() in identities:
        certificate_id = cert["id"]
        break
if certificate_id is None:
    raise SystemExit("No existing Developer ID Application certificate with installed private key. No certificate created.")

profiles = all_items("profiles")
for identifier, _, profile_name in identifiers:
    selected = None
    for item in profiles:
        attrs = item["attributes"]
        if attrs["name"] != profile_name or attrs["profileType"] != "MAC_APP_DIRECT":
            continue
        content = base64.b64decode(attrs["profileContent"])
        decoded = plistlib.loads(subprocess.run(["security", "cms", "-D"], input=content,
                                              capture_output=True, check=True).stdout)
        entitlements = decoded["Entitlements"]
        if entitlements.get("com.apple.application-identifier") != team + "." + identifier:
            raise SystemExit("Profile name belongs to another identifier: refusing to modify it")
        if attrs["profileState"] == "ACTIVE" and (not identifier.endswith(".fsmodule") or
                                                   entitlements.get("com.apple.developer.fskit.fsmodule") is True):
            selected = item
            break
        # Delete only this exact Yuzu NTFS profile whose decoded identifier was checked above.
        api("DELETE", "profiles/" + item["id"])
    if selected is None:
        selected = api("POST", "profiles", {"data": {"type": "profiles", "attributes": {
            "name": profile_name, "profileType": "MAC_APP_DIRECT"}, "relationships": {
            "bundleId": {"data": {"type": "bundleIds", "id": bundles[identifier]}},
            "certificates": {"data": [{"type": "certificates", "id": certificate_id}]}}}})["data"]
    attrs = selected["attributes"]
    content = base64.b64decode(attrs["profileContent"])
    for suffix in ("Library/Developer/Xcode/UserData/Provisioning Profiles", "Library/MobileDevice/Provisioning Profiles"):
        directory = Path.home() / suffix
        directory.mkdir(parents=True, exist_ok=True)
        (directory / (attrs["uuid"] + ".provisionprofile")).write_bytes(content)
    print("Installed:", profile_name, attrs["uuid"])
print("Ready: xcodegen generate && xcodebuild -scheme YuzuNTFS -configuration Release-Direct -derivedDataPath build/r1 build")
PY
