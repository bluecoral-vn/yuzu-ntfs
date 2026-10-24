#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""P0-only operator gates. Importing this module performs no host operations."""
import argparse
import datetime
import hashlib
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
MODULE = 'com.bluecoral.vn.yuzuntfs.fsmodule'
APP = Path('/Applications/Yuzu NTFS.app')
APPEX = APP / 'Contents/Extensions/YuzuNTFSModule.appex'
LSREGISTER = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
SUPPORT = Path.home() / 'Library/Containers' / MODULE / 'Data/Library/Application Support/YuzuNTFS'
ALLOW = SUPPORT / 'p0-rw-serials.txt'
SETTINGS = Path.home() / 'Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist'
# Recorded staged-build timestamp in the already-wedged session (QCDeployOps).
WEDGED_AT = datetime.datetime.fromisoformat('2026-10-24T18:28:20+07:00').timestamp()


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def registrations(text):
    """Parse verbose pluginkit records, including -D duplicate/election prefixes."""
    records = []
    current = None
    for line in text.splitlines():
        if re.match(r'^\s*[+\-!= ]*' + re.escape(MODULE) + r'\(', line):
            current = {}
            records.append(current)
        elif current is not None:
            match = re.match(r'\s*(Path|UUID)\s*=\s*(.*?)\s*$', line)
            if match:
                current[match[1].lower()] = match[2]
    for record in records:
        require(set(record) == {'path', 'uuid'}, 'Incomplete pluginkit record; refusing cleanup')
        require(Path(record['path']).name == 'YuzuNTFSModule.appex', 'Unexpected registered bundle path')
        require(re.fullmatch(r'[0-9A-Fa-f-]{36}', record['uuid']), 'Invalid plugin UUID')
    require(text.count(MODULE + '(') == len(records), 'Unparsed pluginkit entry')
    return records


def allowlist(contents):
    lines = contents.splitlines()
    require(all(re.fullmatch(r'[0-9A-Fa-f]{16}', line) for line in lines), 'Malformed RW allowlist')
    return lines


def is_vm(output):
    return output.strip() == '1'


def active_fskit(mount_output):
    # Fail closed for unknown transports, including DeviceFS/CoreDevice/lifs.
    native = {'apfs', 'hfs', 'devfs', 'autofs', 'nfs', 'smbfs', 'webdav', 'udf', 'cd9660'}
    active = []
    for line in mount_output.splitlines():
        match = re.search(r'\(([^, )]+)', line)
        require(match is not None, 'Cannot parse mount inventory')
        if match[1].lower() not in native:
            active.append(line)
    return active


def recovered(boot_output, process_output):
    match = re.search(r'sec\s*=\s*(\d+)', boot_output)
    require(match is not None, 'Cannot parse kern.boottime')
    rows = [line.split(None, 2) for line in process_output.splitlines() if line.strip()]
    require(all(len(row) == 3 and row[0].isdigit() for row in rows), 'Cannot parse process inventory')
    require(all(row[0] != '65911' for row in rows), 'Historical PID 65911 is present (including PID reuse): stop')
    require(int(match[1]) > WEDGED_AT or not any('U' in row[1] for row in rows), 'No reboot and state-U processes remain')


class Runner:
    def __init__(self, dry=False, timeout=30, new_session=True):
        self.dry = dry
        self.timeout = timeout
        self.new_session = new_session
        self.before_timeout = None

    def run(self, *command, allowed=(0,), timeout=None):
        args = [str(value) for value in command]
        print('+ ' + shlex.join(args), flush=True)
        if self.dry:
            return ''
        # Do not use subprocess.run(timeout): its kill+communicate can wait
        # forever for a state-U process. Poll only; never block-reap on failure.
        with tempfile.TemporaryFile() as output:
            child = subprocess.Popen(args, stdout=output, stderr=subprocess.STDOUT, start_new_session=self.new_session, cwd=ROOT)
            deadline = time.monotonic() + (timeout or self.timeout)
            while child.poll() is None:
                if time.monotonic() >= deadline:
                    if self.before_timeout is not None:
                        self.before_timeout()  # guest authorization revoked FIRST
                    try:
                        if self.new_session:
                            os.killpg(child.pid, signal.SIGTERM)
                        else:
                            child.terminate()  # already in the supervised worker group
                    except ProcessLookupError:
                        pass
                    raise RuntimeError(f'Deadline: PID/PGID={child.pid}, command={shlex.join(args)}; no blocking reap or forced device cleanup')
                time.sleep(.05)
            output.seek(0)
            text = output.read().decode(errors='replace')
        print(text, end='', flush=True)
        require(child.returncode in allowed, f'Command failed ({child.returncode}): {shlex.join(args)}')
        return text


def empty_allowlist():
    if ALLOW.exists():
        require(not allowlist(ALLOW.read_text()), 'RW allowlist must be empty')


def no_active(runner):
    text = runner.run('/sbin/mount')
    if not runner.dry:
        require(not active_fskit(text), 'Active/unknown FSKit-capable volume: refuse settings/agent/registration changes')


def preflight(runner):
    boot = runner.run('sysctl', '-n', 'kern.boottime')
    processes = runner.run('ps', '-axo', 'pid=,state=,command=')
    attachments = runner.run('hdiutil', 'info', '-plist')
    no_active(runner)
    print(f'CHECK empty well-formed RW allowlist: {ALLOW}', flush=True)
    if runner.dry:
        print('CHECK reboot newer than recorded wedge OR no state-U processes; PID 65911 absent; no historical build/r3 attachments')
        return
    recovered(boot, processes)
    images = plistlib.loads(attachments.encode()).get('images', [])
    for image in images:
        name = str(image.get('image-path', ''))
        require(not re.search(r'/build/r3/(exfat|mount-test|mount-test2)\.img$', name), f'Historical attachment remains: {name}')
    empty_allowlist()
    print('P0 PREFLIGHT PASS')


def probe(runner, enabled):
    text = runner.run(ROOT / 'build/r1/FSClientProbe', '--expect-enabled' if enabled else '--expect-disabled', '--expect-path', APPEX)
    if not runner.dry:
        check_probe(text, enabled)


def check_probe(text, enabled):
    lines = [line for line in text.splitlines() if line.startswith(MODULE)]
    parsed = [re.fullmatch(re.escape(MODULE) + r' enabled=(true|false) url=(.*)', line) for line in lines]
    require(all(parsed), 'Unparsed FSClientProbe Yuzu result')
    if enabled:
        require(len(parsed) == 1 and parsed[0][1] == 'true' and parsed[0][2] == str(APPEX), 'Yuzu absent/disabled/duplicated/wrong installed URL')
    else:
        require(all(match[1] == 'false' for match in parsed), 'Yuzu still enabled')

def set_enabled(runner, enabled):
    no_active(runner)
    print(f'BACKUP {SETTINGS}; merge/remove ONLY {MODULE}; preserve all other entries', flush=True)
    if not runner.dry:
        before = SETTINGS.read_bytes() if SETTINGS.exists() else plistlib.dumps([])
        modules = plistlib.loads(before)
        require(isinstance(modules, list) and all(isinstance(value, str) for value in modules), 'Unexpected enabledModules schema')
        backup = SETTINGS.with_name(SETTINGS.name + '.yuzu-' + str(time.time_ns()) + '.backup')
        backup.parent.mkdir(parents=True, exist_ok=True)
        with backup.open('xb') as target:
            target.write(before)
        print('Backup:', backup, '; inverse: scripts/p0-' + ('disable' if enabled else 'enable') + '.sh')
        updated = [value for value in modules if value != MODULE]
        if enabled:
            updated.append(MODULE)
        if updated != modules:
            require(not SETTINGS.exists() or SETTINGS.read_bytes() == before, 'Settings changed concurrently; backup retained, stop')
            with tempfile.NamedTemporaryFile(dir=SETTINGS.parent, delete=False) as temporary:
                temporary.write(plistlib.dumps(updated))
                temporary_name = temporary.name
            os.replace(temporary_name, SETTINGS)
        no_active(runner)
    pids = runner.run('pgrep', '-u', os.getuid(), '-x', 'fskit_agent', allowed=(0, 1))
    if runner.dry:
        runner.run('kill', '-KILL', '<each-current-user-fskit_agent-PID>')
    else:
        for value in pids.split():
            require(value.isdigit(), 'Unparseable agent PID')
            identity = runner.run('ps', '-p', value, '-o', 'uid=,comm=').strip().split(None, 1)
            require(len(identity) == 2 and identity[0] == str(os.getuid()) and Path(identity[1]).name == 'fskit_agent', 'Agent identity changed; stop')
            os.kill(int(value), signal.SIGKILL)
            print('Refreshed current-user fskit_agent', value)
    # Retry readiness only, under a finite total cap; never repeat a refresh.
    if runner.dry:
        probe(runner, enabled)
    else:
        deadline = time.monotonic() + 30
        while True:
            try:
                probe(runner, enabled)
                break
            except RuntimeError:
                if time.monotonic() >= deadline:
                    raise
                time.sleep(1)


def bundle_metadata(app):
    extension = app / 'Contents/Extensions/YuzuNTFSModule.appex'
    app_info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    module_info = plistlib.loads((extension / 'Contents/Info.plist').read_bytes())
    commit = app_info.get('YuzuGitCommit', '')
    require(re.fullmatch(r'[a-f0-9]{40}', commit) is not None, 'Missing/invalid app YuzuGitCommit')
    require(module_info.get('YuzuGitCommit') == commit, 'App/module git identity mismatch')
    require(module_info['EXAppExtensionAttributes'].get('FSSupportsKernelOffloadedIO') is True, 'KOIO declaration must be true')
    executable = extension / 'Contents/MacOS' / module_info['CFBundleExecutable']
    value = hashlib.sha256()
    with executable.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            value.update(chunk)
    return commit, value.hexdigest()


def install(runner, staged, expected_commit):
    preflight(runner)
    inventory = runner.run('pluginkit', '-mADvvv', '-i', MODULE)
    if runner.dry:
        records = [{'path': '<each-non-/Applications-registration>/YuzuNTFSModule.appex'}]
        print('CHECK staged app + module YuzuGitCommit == expected commit; KOIO=true')
    else:
        commit, digest = bundle_metadata(staged)
        require(commit == expected_commit, f'Staged commit {commit} != expected {expected_commit}')
        print('STAGED YuzuGitCommit=', commit, 'module SHA256=', digest)
        records = registrations(inventory)
    for record in records:
        extension = Path(record['path'])
        if extension == APPEX:
            continue
        if not runner.dry:
            require(extension.suffix == '.appex' and extension.parent.name == 'Extensions' and extension.parent.parent.name == 'Contents' and extension.parent.parent.parent.suffix == '.app', 'Unsafe parent-app derivation')
        parent = extension.parent.parent.parent if not runner.dry else '<parent-app-of-each-noninstalled-copy>'
        runner.run('pluginkit', '-r', extension)
        runner.run(LSREGISTER, '-u', parent)
    runner.run('ditto', staged, APP, timeout=120)
    if not runner.dry:
        installed_commit, installed_digest = bundle_metadata(APP)
        require((installed_commit, installed_digest) == (commit, digest), 'Installed binary hash/commit mismatch')
    print('ASSERT installed executable SHA256 and both YuzuGitCommit values equal staged/expected')
    runner.run('codesign', '--verify', '--deep', '--strict', APP)
    runner.run('spctl', '--assess', '--type', 'execute', '--verbose=2', APP, timeout=60)
    runner.run(LSREGISTER, '-f', APP)
    runner.run('pluginkit', '-a', APPEX)
    runner.run('pluginkit', '-e', 'use', '-i', MODULE)
    final = runner.run('pluginkit', '-mADvvv', '-i', MODULE)
    if not runner.dry:
        final = registrations(final)
        require(len(final) == 1 and final[0]['path'] == str(APPEX), 'Expected exactly one /Applications registration')
        print('INSTALLED UUID=', final[0]['uuid'])
    print('ASSERT exactly one registration at installed URL; RECORD plugin UUID')
    set_enabled(runner, True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['preflight', 'install', 'disable', 'enable'])
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--staged', type=Path, default=ROOT / 'build/release/Yuzu NTFS.app')
    parser.add_argument('--expected-commit', default=None)
    args = parser.parse_args()
    runner = Runner(args.dry_run)
    try:
        if args.action == 'preflight':
            preflight(runner)
        elif args.action == 'install':
            require(args.dry_run or re.fullmatch(r'[a-f0-9]{40}', args.expected_commit or '') is not None, 'Pass --expected-commit FULL_SHA from the approved candidate')
            install(runner, args.staged.resolve(), args.expected_commit)
        else:
            preflight(runner)
            set_enabled(runner, args.action == 'enable')
    except (OSError, ValueError, KeyError, RuntimeError) as error:
        print('P0 STOP:', error, file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
