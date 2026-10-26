#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Fresh disposable VM user flow. Run under p0_vm_monitor.py, never on the host."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / 'build/p0-guest'
CONTROL = WORK / 'control'
APP = Path('/Applications/Yuzu NTFS.app')

def run(*args, timeout=90):
    print('+', *map(str, args), flush=True)
    return subprocess.check_output(list(map(str, args)), timeout=timeout)

def require(condition, message):
    if not condition:
        raise RuntimeError(message)

def command(action, device=None, timeout=60):
    request = {'id': str(uuid.uuid4()), 'action': action}
    if device: request['device'] = device
    temporary = CONTROL / 'pending.json'
    temporary.write_text(json.dumps(request))
    temporary.replace(CONTROL / 'command.json')
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            result = json.loads((CONTROL / 'result.json').read_text())
            if result['id'] == request['id']:
                print(json.dumps(result, sort_keys=True), flush=True)
                require(not result['error'], result['error'])
                return result
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        time.sleep(.5)
    raise RuntimeError('App command timed out: ' + action)

def checkpoint(name):
    (ROOT / 'build/checkpoint').write_text(name)
    marker = ROOT / ('build/continue-' + name)
    deadline = time.monotonic() + 240
    while not marker.exists():
        require(time.monotonic() < deadline, 'Screenshot checkpoint timeout: ' + name)
        time.sleep(1)

def drive(device, writable=None):
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        result = command('status')
        found = next((item for item in result['drives'] if item['device'] == device), None)
        if found is not None and (writable is None or found['writable'] == writable):
            return found
        time.sleep(1)
    raise RuntimeError('Drive/mode not listed: ' + device)

def attach(image, readonly=False):
    arguments = ['hdiutil', 'attach', '-plist']
    if readonly: arguments.append('-readonly')
    data = plistlib.loads(run(*arguments, image))
    devices = [entry['dev-entry'] for entry in data['system-entities'] if entry.get('dev-entry', '').startswith('/dev/disk')]
    require(len(devices) == 1, 'Fixture must be partitionless')
    return devices[0].removeprefix('/dev/')

def start(language):
    run('open', '-n', APP, '--args', '--qa-control', CONTROL, '-AppleLanguages', '(' + language + ')')
    result = command('status')
    return result

def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--timeout'); parser.add_argument('--bench-timeout'); parser.parse_args()
    require(run('sysctl', '-n', 'kern.hv_vmm_present').strip() == b'1', 'VM only')
    WORK.mkdir(parents=True, exist_ok=True); CONTROL.mkdir(exist_ok=True)
    image = WORK / 'trial.img'; shutil.copyfile(ROOT / 'fixtures/basic-512.img', image)
    dirty = WORK / 'dirty.img'; shutil.copyfile(ROOT / 'fixtures/basic-512.img', dirty)
    # Offline fixture-only NTFS $Volume dirty flag. Change the serial to distinguish the two drives.
    with dirty.open('r+b') as stream:
        boot = bytearray(stream.read(512)); boot[72:80] = (int.from_bytes(boot[72:80], 'little') ^ 0x5500000055).to_bytes(8, 'little')
        stream.seek(0); stream.write(boot)
        cluster = int.from_bytes(boot[11:13], 'little') * boot[13]
        mft = int.from_bytes(boot[48:56], 'little') * cluster
        record_size = 1 << (256 - boot[64]) if boot[64] >= 128 else boot[64] * cluster
        offset = mft + 3 * record_size
        stream.seek(offset); record = bytearray(stream.read(record_size))
        require(record[:4] == b'FILE', 'Missing $Volume fixture record')
        position = int.from_bytes(record[20:22], 'little')
        while position + 24 <= len(record):
            kind = int.from_bytes(record[position:position+4], 'little')
            length = int.from_bytes(record[position+4:position+8], 'little')
            if kind == 0x70:
                value = position + int.from_bytes(record[position+20:position+22], 'little')
                flags = value + 10
                require(flags + 2 < len(record) and flags % 512 not in (510,511), 'Unsafe fixture patch offset')
                record[flags:flags+2] = (int.from_bytes(record[flags:flags+2], 'little') | 1).to_bytes(2, 'little')
                stream.seek(offset); stream.write(record); break
            require(length >= 24 and kind != 0xffffffff, 'Missing $VOLUME_INFORMATION')
            position += length
    dmg = ROOT / 'Yuzu-NTFS-0.1.0-Beta.dmg'
    mounted = plistlib.loads(run('hdiutil', 'attach', '-readonly', '-plist', dmg))
    entries = mounted['system-entities']; location = next(Path(x['mount-point']) for x in entries if 'mount-point' in x)
    run('ditto', location / APP.name, APP)
    run('hdiutil', 'detach', location)
    run('/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister', '-f', '-R', '-trusted', APP)
    initial = start('en')
    require(not initial['acknowledged'], 'Fresh first run must not be acknowledged')
    command('onboarding'); checkpoint('onboarding-en')
    enabled = command('enable'); require(enabled['enabled'], 'App enable failed')
    print('PASS install, first run, app enable', flush=True)
    device = attach(image)
    readonly = drive(device, False)
    require(readonly['reason'] == 'acknowledgementRequired', 'Initial RO reason missing')
    command('menu'); checkpoint('menu-en')
    command('ack')
    command('writing-on', device)
    writable = drive(device, True)
    mount = Path(writable['mount']); require(mount.is_dir(), 'RW mount absent')
    print('PASS initially RO, beta acknowledgement, per-drive toggle remount RW', flush=True)
    # The common enable/disable guard is exercised with a real active FSKit volume.
    blocked_request = {'id': str(uuid.uuid4()), 'action': 'disable'}
    (CONTROL / 'command.json').write_text(json.dumps(blocked_request))
    time.sleep(5)
    blocked = json.loads((CONTROL / 'result.json').read_text())
    require(blocked['id'] == blocked_request['id'] and blocked['error'] and blocked['enabled'], 'Disable must refuse an active FSKit mount')
    # A status action retains the UI's previous error until the next real action; writing-on clears it.
    command('writing-on', device)
    payload = bytes((index * 17 + 31) % 256 for index in range(1000003))
    source = WORK / 'source.bin'; source.write_bytes(payload)
    shutil.copyfile(source, mount / 'trial-copy.bin')
    (mount / 'trial-small.txt').write_bytes(b'Beta user flow\n')
    (mount / 'trial-copy.bin').rename(mount / 'trial-renamed.bin')
    (mount / 'trial-delete.txt').write_bytes(b'delete me')
    (mount / 'trial-delete.txt').unlink()
    require((mount / 'trial-renamed.bin').read_bytes() == payload, 'Mounted copy mismatch')
    command('eject', device)
    device = attach(image, readonly=True)
    drive(device, False)
    extracted = run(ROOT / 'tools/bin/ntfscat', image, '/trial-renamed.bin')
    require(extracted == payload, 'Independent ntfscat byte mismatch')
    small = run(ROOT / 'tools/bin/ntfscat', image, '/trial-small.txt')
    require(small == b'Beta user flow\n', 'Small-file byte mismatch')
    print('PASS copy 1000003, small file, rename, delete, app eject, ntfscat bytes; SHA256=' + hashlib.sha256(payload).hexdigest(), flush=True)
    command('eject', device)
    device = attach(image)
    drive(device, True)
    command('writing-off', device)
    readonly = drive(device, False)
    require(readonly['reason'] == 'notAllowed', 'Writing-off reason missing')
    mount = Path(readonly['mount'])
    require((mount / 'trial-renamed.bin').read_bytes() == payload, 'RO reattach bytes mismatch')
    require(not (mount / 'trial-delete.txt').exists(), 'Deleted file returned')
    require(not (mount / 'trial-copy.bin').exists(), 'Old rename source returned')
    print('PASS reattach, off-toggle remount RO, persisted rename/delete/data', flush=True)
    unsafe_device = attach(dirty)
    unsafe = drive(unsafe_device, False)
    require(unsafe['reason'] == 'dirtyFlag', 'Dirty fixture reason incorrect: ' + unsafe['reason'])
    command('writing-on', unsafe_device)
    unsafe = drive(unsafe_device, False)
    require(unsafe['reason'] == 'dirtyFlag' and unsafe['allowed'], 'Unsafe allowlist override admitted writes')
    print('PASS dirty fixture remains RO despite opt-in, reason dirtyFlag', flush=True)
    run('pkill', '-x', 'Yuzu NTFS')
    time.sleep(2)
    start('vi'); command('onboarding'); checkpoint('onboarding-vi')
    command('menu'); checkpoint('menu-vi')
    command('eject', unsafe_device); command('eject', device)
    result = command('disable'); require(not result['enabled'], 'App disable failed')
    print('PASS Disable Yuzu NTFS after eject', flush=True)
    (ROOT / 'build/user-flow-pass.json').write_text(json.dumps({'passed': True, 'payloadBytes':len(payload), 'sha256':hashlib.sha256(payload).hexdigest()}, indent=2))

if __name__ == '__main__':
    main()
