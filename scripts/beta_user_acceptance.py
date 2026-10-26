#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Fresh disposable VM user flow. Run under p0_vm_monitor.py, never on the host."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / 'build/p0-guest'
CONTROL = WORK / 'control'
APP = Path('/Applications/Yuzu NTFS.app')
GROUP = Path.home() / 'Library/Group Containers/37PX6W22C5.com.bluecoral.vn.yuzuntfs/Library/Application Support/YuzuNTFS'

def run(*args, timeout=90):
    print('+', *map(str, args), flush=True)
    return subprocess.check_output(list(map(str, args)), timeout=timeout)

def require(condition, message):
    if not condition:
        raise RuntimeError(message)

def command(action, device=None, timeout=60, allow_error=False):
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
                require(allow_error or not result['error'], result['error'])
                return result
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        time.sleep(.5)
    raise RuntimeError('App command timed out: ' + action)

def status_record(device, serial, directory=GROUP):
    matches = []
    for path in directory.glob(f'status-{device}-*.json'):
        raw = path.read_bytes()
        if json.loads(raw).get('serial') == int(serial, 16):
            matches.append((path, raw))
    require(len(matches) == 1, 'Missing or ambiguous published status: ' + device)
    return matches[0]

def require_status_removed(path, timeout=10):
    deadline = time.monotonic() + timeout
    while path.exists() and time.monotonic() < deadline:
        time.sleep(.1)
    require(not path.exists(), 'Unload left its published status: ' + str(path))

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
    protected = WORK / 'protected.img'; shutil.copyfile(ROOT / 'fixtures/c64k.img', protected)
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
    protected_device = attach(protected, readonly=True)
    protected_state = drive(protected_device, False)
    require(protected_state['reason'] == 'deviceReadOnly', 'Physical RO must precede missing acknowledgement')
    protected_status, _ = status_record(protected_device, protected_state['serial'])
    command('eject', protected_device); require_status_removed(protected_status)
    print('PASS physical RO reason precedes acknowledgement, unload withdraws status', flush=True)
    device = attach(image)
    readonly = drive(device, False)
    require(readonly['reason'] == 'acknowledgementRequired', 'Initial RO reason missing')
    command('menu'); checkpoint('menu-en')
    command('ack')
    command('writing-on', device)
    writable = drive(device, True)
    mount = Path(writable['mount']); require(mount.is_dir(), 'RW mount absent')
    print('PASS initially RO, beta acknowledgement, per-drive toggle remount RW', flush=True)
    protected_device = attach(protected, readonly=True)
    protected_state = drive(protected_device, False)
    require(protected_state['reason'] == 'deviceReadOnly', 'Physical RO must precede missing allowlist preference')
    protected_status, protected_raw = status_record(protected_device, protected_state['serial'])
    command('writing-on', protected_device)
    protected_after = drive(protected_device, False)
    require(protected_after['reason'] == 'deviceReadOnly' and protected_after['allowed']
            and protected_after['mount'] == protected_state['mount'], 'Opt-in disturbed a physically RO mount')
    _, protected_after_raw = status_record(protected_device, protected_after['serial'])
    require(json.loads(protected_after_raw)['publisherID'] == json.loads(protected_raw)['publisherID'], 'Physically RO opt-in reloaded the volume')
    command('eject', protected_device); require_status_removed(protected_status)
    print('PASS physical RO opt-in retained its existing mount and publisher', flush=True)
    # The common enable/disable guard is exercised with a real active FSKit volume.
    blocked = command('disable', allow_error=True)
    require(blocked['error'] and blocked['enabled'], 'Disable must refuse an active FSKit mount')
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
    hook = GROUP / 'force-read-only'
    require(not hook.exists(), 'Unexpected pre-existing force-RO hook')
    try:
        hook.write_bytes(b'QA permission reduction only\\n')
        try:
            (mount / ('missing-' + str(uuid.uuid4()))).stat()
        except FileNotFoundError:
            pass
        failed = drive(device, False)
        require(failed['reason'] == 'engineError' and failed['mount'] == str(mount), 'RO latch failed to update live UI status')
        _, failed_raw = status_record(device, failed['serial'])
        require(not json.loads(failed_raw)['writable'], 'Extension retained a writable persisted status after the latch')
    finally:
        hook.unlink(missing_ok=True)
    command('writing-off', device); drive(device, False)
    command('writing-on', device); writable = drive(device, True)
    mount = Path(writable['mount'])
    print('PASS forced terminal RO publishes engineError/RO badge; off/on unmount/remount recovers', flush=True)
    clean_status_path, _ = status_record(device, writable['serial'])
    command('eject', device)
    require_status_removed(clean_status_path)
    device = attach(image, readonly=True)
    drive(device, False)
    extracted = run(ROOT / 'tools/bin/ntfscat', image, '/trial-renamed.bin')
    require(extracted == payload, 'Independent ntfscat byte mismatch')
    small = run(ROOT / 'tools/bin/ntfscat', image, '/trial-small.txt')
    require(small == b'Beta user flow\n', 'Small-file byte mismatch')
    print('PASS copy 1000003, small file, rename, delete, app eject, ntfscat bytes; SHA256=' + hashlib.sha256(payload).hexdigest(), flush=True)
    clean_status_path, _ = status_record(device, writable['serial'])
    command('eject', device)
    require_status_removed(clean_status_path)
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
    clean_status_path, clean_status_raw = status_record(device, readonly['serial'])
    dirty_status_path, _ = status_record(unsafe_device, unsafe['serial'])
    command('eject', unsafe_device); command('eject', device)
    require_status_removed(dirty_status_path); require_status_removed(clean_status_path)
    # Simulate crash leftovers for a reused Microsoft Basic Data BSD partition.
    exfat = WORK / 'reused-exfat.dmg'
    run('hdiutil', 'create', '-size', '512m', '-layout', 'GPTSPUD', '-fs', 'ExFAT', '-volname', 'Beta-exFAT', exfat)
    entities = plistlib.loads(run('hdiutil', 'attach', '-plist', exfat))['system-entities']
    exfat_entry = next(entry for entry in entities if Path(entry.get('mount-point', '/')).name == 'Beta-exFAT')
    exfat_device = exfat_entry['dev-entry'].removeprefix('/dev/')
    whole = next(entry['dev-entry'] for entry in entities if re.fullmatch(r'/dev/disk[0-9]+', entry.get('dev-entry', '')))
    stale = json.loads(clean_status_raw); stale['device'] = exfat_device
    scoped_stale = GROUP / ('status-' + exfat_device + '-' + clean_status_path.name.removeprefix('status-' + device + '-'))
    legacy_stale = GROUP / ('status-' + exfat_device + '.json')
    before_policy = (GROUP / 'write-serials.txt').read_bytes()
    try:
        scoped_stale.write_text(json.dumps(stale)); legacy_stale.write_text(json.dumps(stale))
        require(not any(item['device'] == exfat_device for item in command('status')['drives']), 'Stale NTFS state classified exFAT as NTFS')
        rejected = command('writing-on', exfat_device, allow_error=True)
        require(rejected['error'] == 'QA drive not found', 'A stale NTFS control was actionable for exFAT')
        require((GROUP / 'write-serials.txt').read_bytes() == before_policy, 'Rejected exFAT action changed NTFS policy')
        info = plistlib.loads(run('diskutil', 'info', '-plist', exfat_device))
        require(info.get('FilesystemType') == 'exfat', 'Rejected action changed exFAT filesystem/mount')
    finally:
        scoped_stale.unlink(missing_ok=True); legacy_stale.unlink(missing_ok=True)
        run('hdiutil', 'detach', whole)
    print('PASS reused-BSD exFAT ignores scoped and legacy stale status; no writing control/policy change', flush=True)
    result = command('disable'); require(not result['enabled'], 'App disable failed')
    print('PASS Disable Yuzu NTFS after eject', flush=True)
    (ROOT / 'build/user-flow-pass.json').write_text(json.dumps({'passed': True, 'payloadBytes':len(payload), 'sha256':hashlib.sha256(payload).hexdigest()}, indent=2))

if __name__ == '__main__':
    main()
