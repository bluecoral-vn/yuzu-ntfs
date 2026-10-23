#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Images only. BENCH_IMAGE must be an image file inside this worktree.
set -euo pipefail
exec python3 - "$@" <<'PY'
import atexit, json, os, pathlib, plistlib, statistics, subprocess, sys, threading, time
if len(sys.argv) != 3:
    raise SystemExit('usage: BENCH_IMAGE=/absolute/fixture.img scripts/bench.sh <mountpoint> <label>')
mount = pathlib.Path(sys.argv[1]).resolve()
label = sys.argv[2].replace('|', '/')
root = pathlib.Path.cwd().resolve()
seqio = root / 'tools/seqio'
image = pathlib.Path(os.environ['BENCH_IMAGE']).resolve(strict=True)
if not image.is_relative_to(root) or not image.is_file(): raise SystemExit('BENCH_IMAGE must be a file inside this worktree')
if not mount.is_relative_to(root): raise SystemExit('benchmark mountpoint must be inside this worktree')
readonly = os.environ.get('BENCH_READONLY') == '1'
fstype = os.environ.get('BENCH_FSTYPE', 'yuzuntfs')
if fstype not in ('yuzuntfs', 'ntfs', 'exfat'): raise SystemExit('unsupported image benchmark driver')
allow = pathlib.Path.home() / 'Library/Containers/com.bluecoral.vn.yuzuntfs.fsmodule/Data/Library/Application Support/YuzuNTFS/p0-rw-serials.txt'
with image.open('rb') as f: boot = f.read(512)
serial = f'{int.from_bytes(boot[72:80], "little"):016X}' if boot[3:11] == b'NTFS    ' else None
existing = allow.read_text().splitlines() if allow.exists() else []
if serial:
    allow.parent.mkdir(parents=True, exist_ok=True)
    allow.write_text('\n'.join(dict.fromkeys(existing + [serial])) + '\n')
    def revoke():
        current = allow.read_text().splitlines() if allow.exists() else []
        remaining = [x for x in current if x.upper() != serial]
        if remaining != current: allow.write_text(''.join(x + '\n' for x in remaining))
    atexit.register(revoke)

def checked_device():
    images = plistlib.loads(subprocess.check_output(['hdiutil', 'info', '-plist']))['images']
    attached = next(x for x in images if pathlib.Path(x.get('image-path', '')).resolve() == image)
    nodes = [x['dev-entry'] for x in attached['system-entities'] if x['dev-entry'].startswith('/dev/disk')]
    if len(nodes) != 1: raise SystemExit('benchmark requires one partitionless image device')
    return nodes[0]

# Add the fixture serial BEFORE first mount, and derive the device solely from
# hdiutil's just-attached plist; every subsequent mount verifies image identity.
attached = plistlib.loads(subprocess.check_output(['hdiutil', 'attach', '-nomount', '-plist', str(image)]))
dev = next(x['dev-entry'] for x in attached['system-entities'] if x['dev-entry'].startswith('/dev/disk'))
if dev != checked_device(): raise SystemExit('attachment device mismatch')
mount.mkdir(parents=True, exist_ok=True)
mounted = False
def mount_image():
    global mounted
    if checked_device() != dev: raise SystemExit('image device changed')
    if fstype == 'exfat':
        command = ['diskutil', 'mount']
        if readonly: command += ['readOnly']
        subprocess.run(command + ['-mountPoint', str(mount), dev], check=True)
    else:
        command = ['/sbin/mount', '-F']
        if readonly: command += ['-r']
        subprocess.run(command + ['-t', fstype, dev, str(mount)], check=True)
    mounted = True
def remount():
    global mounted
    if checked_device() != dev: raise SystemExit('image device changed')
    if mounted: subprocess.run(['/sbin/umount', str(mount)], check=True)
    mounted = False
    mount_image()
def cleanup():
    if serial: revoke()
    if mounted: subprocess.run(['/sbin/umount', str(mount)], check=False)
    if checked_device() == dev: subprocess.run(['hdiutil', 'detach', dev], check=False, stdout=subprocess.DEVNULL)
atexit.register(cleanup)
mount_image()

def cpu_sample(stop, values):
    if fstype != 'yuzuntfs': return
    while not stop.is_set():
        pids = subprocess.run(['pgrep', '-u', str(os.getuid()), '-x', 'YuzuNTFSModule'], capture_output=True, text=True).stdout.split()
        if pids:
            output = subprocess.run(['ps', '-p', ','.join(pids), '-o', '%cpu='], capture_output=True, text=True).stdout
            values.append(sum(float(x) for x in output.split()))
        stop.wait(.2)

def timed(action):
    samples, stop = [], threading.Event()
    thread = threading.Thread(target=cpu_sample, args=(stop, samples), daemon=True); thread.start()
    start = time.monotonic()
    try: result = action()
    finally: elapsed = time.monotonic() - start; stop.set(); thread.join()
    return result, elapsed, statistics.mean(samples) if samples else None

def row(run, op, seconds, mib=None, cpu=None):
    print(f'| {label} | {run} | {op} | {seconds:.6f} | {mib:.3f}' if mib is not None else f'| {label} | {run} | {op} | {seconds:.6f} | —', end='')
    print(f' | {cpu:.2f} |' if cpu is not None else ' | N/A |', flush=True)

def seq(mode, path):
    return json.loads(subprocess.check_output([str(seqio), mode, str(path), str(4 * 1024**3)], text=True))

work = mount / '.yuzu-p0-bench'
# A foreign tree is never recursively deleted: marker must match this backing image.
if not readonly:
    marker = work / 'image.txt'
    if work.exists() and (not marker.exists() or marker.read_text() != str(image)):
        raise SystemExit('benchmark tree lacks matching ownership marker')
    work.mkdir(exist_ok=True)
    marker.write_text(str(image))
file = work / 'sequential.bin'
if readonly and not file.exists(): raise SystemExit('read-only baseline needs a preseeded .yuzu-p0-bench/sequential.bin')
print('| Driver | Run | Workload | Seconds | MiB/s | Extension CPU % (sample mean) |', flush=True)
print('|---|---:|---|---:|---:|---:|', flush=True)
for run in range(1, 6):
    remount()
    if not readonly:
        result, elapsed, cpu = timed(lambda: seq('write', file))
        row(run, 'seq-write-4GiB-F_NOCACHE', result['seconds'], result['mib_s'], cpu)
    remount()
    result, elapsed, cpu = timed(lambda: seq('read', file))
    row(run, 'seq-read-4GiB-F_NOCACHE', result['seconds'], result['mib_s'], cpu)
    if readonly: continue
    small = work / 'small'; small.mkdir(exist_ok=True)
    payload = bytes((i * 31) % 256 for i in range(4096))
    def smallcopy():
        source = work / '4k-source'; source.write_bytes(payload)
        import shutil
        for i in range(10000): shutil.copyfile(source, small / f'{i:05d}')
    _, elapsed, cpu = timed(smallcopy); row(run, 'copy-10000x4KiB', elapsed, cpu=cpu)
    tree = work / 'tree'; tree.mkdir(exist_ok=True)
    for i in range(100000): (tree / f'{i:06d}').touch(exist_ok=True)
    remount()
    _, elapsed, cpu = timed(lambda: subprocess.run(['/bin/ls', '-l', str(tree)], stdout=subprocess.DEVNULL, check=True))
    row(run, 'ls-l-100k', elapsed, cpu=cpu)
    remount()
    _, elapsed, cpu = timed(lambda: subprocess.run(['/bin/rm', '-rf', str(tree)], check=True))
    row(run, 'rm-rf-100k', elapsed, cpu=cpu)
    subprocess.run(['/bin/rm', '-rf', str(small)], check=True)
PY
