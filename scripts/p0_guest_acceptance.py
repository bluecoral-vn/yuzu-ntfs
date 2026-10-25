#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Disposable-image guest gate. No live operation is performed by --dry-run."""
import argparse
import errno
import hashlib
import json
import mmap
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import time
import traceback
import uuid

from bench_supervisor import supervise
from p0_ops import ROOT, MODULE, SUPPORT, ALLOW, Runner, require, allowlist, empty_allowlist, is_vm, preflight
from p0_vm_monitor import wait_for_owned_io

RESIDENT_SHA = '4b2720d37f921134bfbb2deb27137d6f08fc55ced90f88c4971f5f42e06e1fc6'
HOOK = SUPPORT / 'p0-force-ro'


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def image_serial(path):
    with path.open('rb') as source:
        boot = source.read(512)
    require(len(boot) == 512 and boot[3:11] == b'NTFS    ', 'Acceptance requires an NTFS fixture image')
    return f'{int.from_bytes(boot[72:80], "little"):016X}'


def revoke(serial):
    if ALLOW.exists():
        current = allowlist(ALLOW.read_text())
        ALLOW.write_text(''.join(line + '\n' for line in current if line.upper() != serial))


def authorize(serial):
    current = allowlist(ALLOW.read_text()) if ALLOW.exists() else []
    require(not current, 'RW admission requires an otherwise empty allowlist')
    ALLOW.parent.mkdir(parents=True, exist_ok=True)
    ALLOW.write_text(serial + '\n')


def phase(name, serial, timeout, action, write=False):
    # Only the supervising parent grants authorization. The worker cannot
    # reauthorize after timeout; supervisor revokes BEFORE signaling its group.
    try:
        supervise(lambda: revoke(serial), name, timeout,
                  authorize=(lambda: authorize(serial)) if write else None)
    except SystemExit as result:
        require(result.code == 0, f'{name} failed: {result.code}; inspect surviving PID/attachment evidence before continuing')
        return
    try:
        action()
        sys.stdout.flush(); sys.stderr.flush()
    except BaseException:
        traceback.print_exc(); sys.stdout.flush(); sys.stderr.flush(); os._exit(1)
    os._exit(0)


def check_mount_identity(actual, mounts, device, mount, readonly):
    prefix = f'{device} on {mount} ('
    rows = [line for line in mounts.splitlines() if line.startswith(prefix) and line.endswith(')')]
    require(len(rows) == 1, 'Missing or duplicated owned mount identity')
    options = rows[0][len(prefix):-1].split(', ')
    require(options[0].lower() == 'yuzuntfs', 'Wrong mounted filesystem')
    require(('read-only' in options) == readonly, 'Unexpected mount read-only flag')
    for key, expected in (('DeviceNode', device), ('MountPoint', str(mount)),
                          ('FilesystemType', 'yuzuntfs'), ('ReadOnlyVolume', readonly)):
        if key in actual:
            value = actual[key]
            if key == 'FilesystemType':
                # diskutil may report the NTFS personality, not the serving driver.
                value = 'yuzuntfs' if value.lower() == 'ntfs' else value.lower()
            require(value == expected, f'Conflicting diskutil mount field: {key}')
    print('Verified owned mount:', rows[0], flush=True)


class Attachment:
    def __init__(self, runner, image, mount, readonly):
        self.runner, self.image, self.mount, self.readonly = runner, image, mount, readonly
        self.dev = None
        self.mounted = False

    def checked(self):
        inventory = plistlib.loads(self.runner.run('hdiutil', 'info', '-plist').encode())
        matches = [item for item in inventory.get('images', []) if Path(item.get('image-path', '')).resolve() == self.image]
        require(len(matches) == 1, 'Owned image attachment absent or duplicated')
        nodes = [item['dev-entry'] for item in matches[0].get('system-entities', []) if item.get('dev-entry', '').startswith('/dev/disk')]
        require(nodes == [self.dev], 'Image/device identity changed; refuse I/O')

    def attach(self):
        self.mount.mkdir(parents=True, exist_ok=False)
        self.reattach()

    def reattach(self):
        require(self.dev is None and not self.mounted, 'Reattach requires a detached owned image')
        info = plistlib.loads(self.runner.run('hdiutil', 'attach', '-nomount', '-plist', self.image).encode())
        nodes = [item['dev-entry'] for item in info['system-entities'] if item.get('dev-entry', '').startswith('/dev/disk')]
        require(len(nodes) == 1, 'Only partitionless owned fixture images are accepted')
        self.dev = nodes[0]
        self.remount()

    def remount(self):
        self.checked()
        if self.mounted:
            self.runner.run('/sbin/umount', self.mount)
            self.mounted = False
        command = ['/sbin/mount', '-F'] + (['-r'] if self.readonly else [])
        self.runner.run(*command, '-t', 'yuzuntfs', self.dev, self.mount)
        self.mounted = True
        actual = plistlib.loads(self.runner.run('diskutil', 'info', '-plist', self.mount).encode())
        check_mount_identity(actual, self.runner.run('/sbin/mount'), self.dev, self.mount, self.readonly)

    def close(self):
        if self.dev is None:
            return
        self.checked()
        if self.mounted:
            self.runner.run('/sbin/umount', self.mount)
            self.mounted = False
        self.runner.run('hdiutil', 'detach', self.dev)
        self.dev = None


def log_phase(path, action):
    # This long-lived command belongs to the deadline-supervised worker group.
    # Never wait without a deadline for a log process or a device operation.
    with path.open('xb') as output:
        command = ['/usr/bin/log', 'stream', '--style', 'compact', '--level', 'info', '--predicate', f'subsystem == "{MODULE}"']
        print('+ ' + ' '.join(command), flush=True)
        logger = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT)
        try:
            time.sleep(.5)
            require(logger.poll() is None, 'log stream did not start')
            action()
            time.sleep(.5)
        finally:
            logger.terminate()
            deadline = time.monotonic() + 3
            while logger.poll() is None and time.monotonic() < deadline:
                time.sleep(.05)
            require(logger.poll() is not None, f'log stream survived termination PID={logger.pid}')


def ro_samples(name, entries):
    if name == 'bigdir':
        require(len(entries) == 100000, 'Unexpected bigdir manifest count')
        return [entries[index] for index in (0, 1, 49999, 99999)]
    if name == 'names':
        return entries
    return [entry for entry in entries if entry['path'] in ('/resident.txt', '/nonresident.bin')]


def verify_manifest_reads(mount, entries):
    for entry in entries:
        require(entry['type'] == 'file', 'RO sample must be a regular file')
        target = mount / entry['path'].lstrip('/')
        actual = digest(target)
        require(actual == entry['sha256'], 'RO manifest hash mismatch: ' + entry['path'])
        require(target.stat().st_size == entry['size'], 'RO manifest size mismatch: ' + entry['path'])
        print(f"RO manifest SHA256 PASS {entry['path']} {actual}", flush=True)


def ro_acceptance(runner, image, mount, evidence, fixture=None):
    require(not HOOK.exists(), 'Remove stale P0 force-RO hook before acceptance')
    empty_allowlist()
    fixture = fixture or ROOT / 'fixtures/basic-512.img'
    manifest = json.loads(fixture.with_suffix('.manifest.json').read_text())
    if fixture.stem not in ('names', 'bigdir'):
        require(any(entry['path'] == '/resident.txt' and entry['sha256'] == RESIDENT_SHA
                    for entry in manifest['entries']), 'Unexpected resident fixture manifest')
    before = digest(image)
    attachment = Attachment(runner, image, mount, True)
    log = evidence / (fixture.stem + '-ro-callbacks.log')
    def workload():
        try:
            attachment.attach()
            attachment.checked()
            empty_allowlist()
            runner.run('/sbin/mount')
            verify_manifest_reads(mount, ro_samples(fixture.stem, manifest['entries']))
            if fixture.stem == 'bigdir':
                listing = runner.run('/bin/ls', '-1', '-A', mount)
                count = len(listing.splitlines())
                require(count == manifest['entry_count'], f'bigdir ls count mismatch: {count}')
                print(f'RO bigdir ls count PASS {count}', flush=True)
            empty_allowlist()
        finally:
            attachment.close()
    log_phase(log, workload)
    after = digest(image)
    require(after == before, 'RO mount changed image bytes')
    print(f'RO image SHA256 unchanged PASS {fixture.name} before={before} after={after}', flush=True)
    text = log.read_text()
    require('bufferedRead' in text if fixture.stem not in ('names', 'bigdir') else 'YuzuNTFSModule' in text,
            'Missing observed RO module callback')
    empty_allowlist()


def refused(action, description):
    try:
        action()
    except OSError as error:
        require(error.errno == errno.EROFS, f'{description}: expected EROFS, got {error}')
        print(description + ': prompt EROFS PASS', flush=True)
    else:
        raise RuntimeError(description + ': write succeeded; RO revocation is NOT established')

def retained_writeback(action):
    started = time.monotonic()
    outcome = 'success'
    try:
        action()
    except OSError as error:
        if error.errno != errno.EROFS:
            raise
        outcome = 'EROFS'
    require(time.monotonic() - started < 5, 'Retained mmap completeIO did not reply promptly')
    print('M-R1 retained mmap writeback prompt ' + outcome + ' PASS', flush=True)


def detached_inode(attachment, name, stage):
    require(attachment.dev is None and not attachment.mounted, 'Inode oracle requires a detached image')
    result = {}
    for key, tool, args in (('metadata', 'ntfsinfo', ['-f', '-v', '-F', '/' + name, str(attachment.image)]),
                            ('data', 'ntfscat', [str(attachment.image), '/' + name])):
        command = [str(ROOT / 'tools/bin' / tool), *args]
        captured = subprocess.run(command, capture_output=True, timeout=20)
        require(captured.returncode == 0, 'Detached inode oracle failed: ' + captured.stderr.decode(errors='replace'))
        result[key] = captured.stdout
        suffix = '.txt' if key == 'metadata' else '.bin'
        (attachment.image.parent / ('m-r1-' + stage + '-' + name + suffix)).write_bytes(captured.stdout)
    return result


def check_retained_mapping(before, after, offset, length):
    require(before['metadata'] == after['metadata'], 'Post-latch MFT metadata/size/VDL/allocation changed')
    require(len(before['data']) == len(after['data']), 'Post-latch file size changed')
    end = offset + length
    require(0 <= offset <= end <= len(before['data']), 'Invalid retained mapping range')
    require(before['data'][:offset] == after['data'][:offset] and before['data'][end:] == after['data'][end:],
            'Post-latch data changed outside previously mapped clusters')

def check_retained_callbacks(text):
    require('completeIO offset=0 length=8192 write=true' in text, 'Missing post-latch retained mmap completion callback')
    # A 512-byte user write may cause a page-sized blockmap (16 KiB on the VM).
    require(any('blockmapFile offset=16384 length=' in line and 'write=true' in line for line in text.splitlines()),
            'NEW write was refused without exercising a new blockmap')



def mapped_transition(attachment):
    target = attachment.mount / 'transition-mmap.bin'
    unmapped = attachment.mount / 'transition-unmapped.bin'
    for path, size in ((target, 8192), (unmapped, 262144)):
        fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_RDWR, 0o600)
        try:
            os.write(fd, b'B' * 8192); os.ftruncate(fd, size); os.fsync(fd)
        finally:
            os.close(fd)
    attachment.close()
    before = {path.name: detached_inode(attachment, path.name, 'before') for path in (target, unmapped)}
    attachment.reattach()
    fd = os.open(target, os.O_RDWR)
    new_fd = os.open(unmapped, os.O_RDWR)
    memory = None
    try:
        memory = mmap.mmap(fd, 8192, access=mmap.ACCESS_WRITE)
        require(memory[:] == before[target.name]['data'], 'Pre-latch cached mapping differs from detached bytes')
        SUPPORT.mkdir(parents=True, exist_ok=True)
        HOOK.touch(exist_ok=False)
        os.statvfs(attachment.mount)
        start = (attachment.image.parent / 'rw-callbacks.log').stat().st_size
        (attachment.image.parent / 'm-r1-callback-start.txt').write_text(str(start))
        def writeback():
            memory[0:1] = b'X'; memory.flush(); os.fsync(fd)
        retained_writeback(writeback)
        def new_mapping():
            os.pwrite(new_fd, b'N' * 512, 16384); os.fsync(new_fd)
        refused(new_mapping, 'M-R1 NEW write blockmap')
    finally:
        if memory is not None:
            memory.close()
        os.close(new_fd); os.close(fd)
        HOOK.unlink(missing_ok=True)
    attachment.close()
    after = {path.name: detached_inode(attachment, path.name, 'after') for path in (target, unmapped)}
    check_retained_mapping(before[target.name], after[target.name], 0, 8192)
    check_retained_mapping(before[unmapped.name], after[unmapped.name], 0, 0)
    print('M-R1 detached MFT/EOF/VDL/runlist/allocation unchanged PASS', flush=True)
    attachment.reattach()
    require(target.read_bytes() == after[target.name]['data'] and unmapped.read_bytes() == after[unmapped.name]['data'],
            'M-R1 remount differs from detached oracle')
    print('M-R1 remount readback PASS', flush=True)
    return start



def transition(attachment, mapped):
    if mapped:
        return mapped_transition(attachment)
    attachment.checked()
    target = attachment.mount / 'transition-fd.bin'
    fd = os.open(target, os.O_CREAT | os.O_EXCL | os.O_RDWR, 0o600)
    try:
        os.write(fd, b'B' * 8192); os.fsync(fd)
        # The retained-mmap case has a separate M-R1 detached metadata gate.
        SUPPORT.mkdir(parents=True, exist_ok=True)
        HOOK.touch(exist_ok=False)
        os.statvfs(attachment.mount)  # explicit next volume operation
        def write():
            os.pwrite(fd, b'X', 0); os.fsync(fd)
        refused(write, 'pre-latch FD')
    finally:
        HOOK.unlink(missing_ok=True)
        os.close(fd)
    # Removing the hook alone must not clear the latch; a fresh mount is needed.
    attachment.remount()


def rw_acceptance(runner, image, mount, evidence):
    attachment = Attachment(runner, image, mount, False)
    source = evidence / 'source-1000003.bin'
    source.write_bytes(bytes((index * 17 + 3) & 255 for index in range(1_000_003)))
    log = evidence / 'rw-callbacks.log'
    mmap_start = []
    def workload():
        try:
            attachment.attach()
            attachment.checked()
            original = (mount / 'resident.txt').read_bytes()
            with (mount / 'resident.txt').open('ab') as resident:
                resident.write(b'P0-append'); resident.flush(); os.fsync(resident.fileno())
            attachment.remount()
            require((mount / 'resident.txt').read_bytes() == original + b'P0-append', 'Resident append/remount mismatch')
            attachment.checked()
            runner.run('/bin/cp', source, mount / 'nonaligned.bin')
            runner.run('stat', '-f%z', mount / 'nonaligned.bin')
            require((mount / 'nonaligned.bin').stat().st_size == 1_000_003, 'Wrong exact copied EOF')
            runner.run('cmp', source, mount / 'nonaligned.bin')
            with (mount / 'nonaligned.bin').open('rb') as copied:
                os.fsync(copied.fileno())
                require(os.pread(copied.fileno(), 1, 1_000_003) == b'', 'Read past EOF returned bytes')
            attachment.remount()
            runner.run('cmp', source, mount / 'nonaligned.bin')
            attachment.checked()
            vdl = mount / 'qca-vdl.bin'
            fd = os.open(vdl, os.O_CREAT | os.O_EXCL | os.O_RDWR, 0o600)
            try:
                os.write(fd, b'A' * 37); os.fsync(fd)
                os.ftruncate(fd, 8192); os.fsync(fd)
                require(os.pread(fd, 8192, 0) == b'A' * 37 + bytes(8192 - 37), 'VDL zero tail mismatch')
            finally:
                os.close(fd)
            attachment.remount()
            require(vdl.read_bytes() == b'A' * 37 + bytes(8192 - 37), 'VDL remount readback mismatch')
            print('37-byte + ftruncate 8192 + remount PASS', flush=True)
            attachment.checked()
            try:
                stream = os.open(mount / 'ads.txt:metadata', os.O_WRONLY)
            except OSError as error:
                require(error.errno in (errno.EPERM, errno.EROFS, errno.EACCES), 'ADS refused for wrong reason: ' + str(error))
                print('ADS write-open refusal PASS', flush=True)
            else:
                os.close(stream); raise RuntimeError('ADS write-open succeeded')
            transition(attachment, False)
            mmap_start.append(transition(attachment, True))
        finally:
            HOOK.unlink(missing_ok=True)
            attachment.close()
    log_phase(log, workload)
    text = log.read_text()
    require('blockmapFile' in text and 'completeIO' in text, 'Copy without observed KOIO blockmapFile/completeIO is NOT acceptance')
    retained = log.read_bytes()[mmap_start[0]:].decode()
    check_retained_callbacks(retained)
    print('M-R1 retained completion + NEW write blockmap callback evidence PASS', flush=True)
    print('Observed KOIO callback evidence:', log, flush=True)


def dry_plan(runner, args):
    runner.run('sysctl', '-n', 'kern.hv_vmm_present')
    print('REQUIRE VM=1, unless --allow-host-readonly (RO subset only); invoke inside lume guest, not the host')
    preflight(runner)
    print('SUPERVISOR RO phase: deadline; empty allowlist; revoke-before-signal; no blocking reap')
    runner.run('/usr/bin/log', 'stream', '--style', 'compact', '--level', 'info', '--predicate', f'subsystem == "{MODULE}"')
    runner.run('hdiutil', 'attach', '-nomount', '-plist', '<new-owned-fixture-copy>')
    runner.run('hdiutil', 'info', '-plist')
    runner.run('/sbin/mount', '-F', '-r', '-t', 'yuzuntfs', '<fresh-derived-device>', '<new-owned-mount>')
    runner.run('diskutil', 'info', '-plist', '<new-owned-mount>')
    print('CHECK resident SHA256=' + RESIDENT_SHA + '; bufferedRead callback; image hash unchanged')
    print('REPEAT RO phase for names and bigdir fixtures; check manifest hashes, bigdir ls count=100000')
    print('CHECK empty RW allowlist before/after every RO workload; final supervised attachment/process inventory')
    runner.run('/sbin/umount', '<new-owned-mount>')
    runner.run('hdiutil', 'detach', '<fresh-derived-device>')
    if args.allow_host_readonly:
        print('HOST READ-ONLY SUBSET: no RW admission, fault hook, or benchmark')
        return
    print('SUPERVISOR RW phase: parent grants ONLY fixture serial; revoke-before-signal on every exit')
    runner.run('hdiutil', 'attach', '-nomount', '-plist', '<new-owned-RW-fixture-copy>')
    runner.run('/sbin/mount', '-F', '-t', 'yuzuntfs', '<fresh-derived-device>', '<new-owned-mount>')
    runner.run('diskutil', 'info', '-plist', '<new-owned-mount>')
    print('CHECK attachment identity before each mutation; append resident + fsync + remount + exact readback')
    runner.run('/bin/cp', '<1000003-byte-source>', '<mount>/nonaligned.bin')
    runner.run('stat', '-f%z', '<mount>/nonaligned.bin')
    runner.run('cmp', '<1000003-byte-source>', '<mount>/nonaligned.bin')
    print('CHECK exact EOF + empty pread-at-EOF; clean remount + cmp; log blockmapFile AND completeIO required')
    print('PYTHON os.write(37 A bytes); fsync; ftruncate(8192); fsync; pread==37 A + zeros; remount/readback')
    print('PYTHON os.open(ads.txt:metadata, O_WRONLY) must fail EPERM/EROFS/EACCES promptly')
    print('PYTHON open FD before hook; touch ' + str(HOOK) + '; statvfs; pwrite/fsync must fail EROFS; remove hook + remount')
    print('M-R1 mmap: detached pre/post ntfsinfo + ntfscat; retained-map writeback success/EROFS <5s; unchanged MFT/EOF/VDL/allocation/runlist; only mapped data may differ; NEW write blockmap EROFS; remount readback')
    runner.run('/sbin/umount', '<new-owned-mount>')
    runner.run('hdiutil', 'detach', '<fresh-derived-device>')
    print('ONLY AFTER EVERY ACCEPTANCE PASSES: supervised benchmark, own deadline and revoke-before-signal')
    runner.run('/usr/bin/env', f'BENCH_IMAGE={args.bench_image}', 'BENCH_FSTYPE=yuzuntfs', f'BENCH_TIMEOUT={args.bench_timeout}', ROOT / 'scripts/bench.sh', '<new-bench-mount>', 'P0-guest')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--allow-host-readonly', action='store_true', help='ONLY the RO subset, never RW or benchmark even inside a VM')
    parser.add_argument('--image', type=Path, default=ROOT / 'fixtures/basic-512.img')
    parser.add_argument('--bench-image', type=Path, default=ROOT / 'build/r3/bench-ntfs.img')
    parser.add_argument('--timeout', type=float, default=180)
    parser.add_argument('--bench-timeout', type=float, default=1800)
    args = parser.parse_args()
    runner = Runner(args.dry_run, new_session=False)
    try:
        require(args.timeout > 0 and args.bench_timeout > 0, 'Deadlines must be positive')
        if args.dry_run:
            dry_plan(runner, args)
            return 0
        require(is_vm(runner.run('sysctl', '-n', 'kern.hv_vmm_present')) or args.allow_host_readonly, 'RW guest acceptance refuses a non-VM host; use --allow-host-readonly for ONLY RO')
        preflight(runner)
        image = args.image.resolve(strict=True)
        require(image.is_relative_to(ROOT) and image.is_file(), 'Fixture must be a regular image within this worktree')
        require(not HOOK.exists(), 'Stale force-RO hook: remove it explicitly before running')
        serial = image_serial(image)
        runner.before_timeout = lambda: revoke(serial)
        evidence = ROOT / 'build/p0-guest' / str(uuid.uuid4())
        evidence.mkdir(parents=True)
        print('Acceptance evidence:', evidence, flush=True)
        for fixture in (image, ROOT / 'fixtures/names.img', ROOT / 'fixtures/bigdir.img'):
            ro_image = evidence / (fixture.stem + '-ro.img')
            shutil.copyfile(fixture, ro_image)
            phase('RO acceptance: ' + str(ro_image), image_serial(fixture), args.timeout,
                  lambda: ro_acceptance(runner, ro_image, evidence / (fixture.stem + '-ro-mount'), evidence, fixture))
        def final_inventory():
            empty_allowlist()
            wait_for_owned_io(runner, [evidence, ROOT / 'build/r3', ROOT / 'build/baseline'])
            inventory = plistlib.loads(runner.run('hdiutil', 'info', '-plist').encode())
            require(not any(Path(item.get('image-path', '')).is_relative_to(evidence) for item in inventory.get('images', [])),
                    'Acceptance image attachment survived cleanup')
            print('RO cleanup PASS: empty RW allowlist; no owned attachments; no persistent owned state-U processes', flush=True)
        phase('RO final inventory', serial, args.timeout, final_inventory)
        if args.allow_host_readonly:
            print('RO SUBSET PASS; no RW/benchmark performed')
            return 0
        rw_image = evidence / 'rw.img'; shutil.copyfile(image, rw_image)
        phase('RW acceptance: ' + str(rw_image), serial, args.timeout,
              lambda: rw_acceptance(runner, rw_image, evidence / 'rw-mount', evidence), write=True)
        bench = args.bench_image.resolve(strict=True)
        require(bench.is_relative_to(ROOT) and bench.is_file() and bench.stat().st_size >= 8 * 1024**3, 'Benchmark requires a dedicated >=8 GiB worktree NTFS image')
        bench_serial = image_serial(bench)
        runner.before_timeout = lambda: revoke(bench_serial)
        phase('Acceptance-passed benchmark: ' + str(bench), bench_serial, args.bench_timeout + 30,
              lambda: runner.run('/usr/bin/env', f'BENCH_IMAGE={bench}', 'BENCH_FSTYPE=yuzuntfs', f'BENCH_TIMEOUT={args.bench_timeout}', ROOT / 'scripts/bench.sh', evidence / 'bench-mount', 'P0-guest', timeout=args.bench_timeout + 10))
        print('P0 GUEST ACCEPTANCE + BENCHMARK PASS')
    except (OSError, ValueError, KeyError, RuntimeError) as error:
        print('P0 GUEST STOP:', error, file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
