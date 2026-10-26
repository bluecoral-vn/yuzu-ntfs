#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""V-R1 VM-only one-shot acceptance launcher; unrelated transient U is informational."""
import argparse
import os
from pathlib import Path
import pwd
import signal
import subprocess
import sys
import time
from p0_ops import Runner

class UStateMonitor:
    def __init__(self, owned_paths):
        self.owned_paths = tuple(str(path) for path in owned_paths)
        self.waits = {}

    def command_owned(self, command):
        return ('YuzuNTFSModule' in command
                or '/com.apple.fskit.exfat.appex/Contents/MacOS/' in command
                or Path(command.split()[0]).name == 'fskitd'
                or any(name in command for name in ('p0_guest_acceptance.py', 'beta_user_acceptance.py', 'vmrw_oracle.py', 'bench.sh', 'seqio'))
                or any(path in command for path in self.owned_paths))

    def observe(self, text, now, open_paths=None, mounting_benchmark=False):
        current, stops, info = {}, [], []
        for row in text.splitlines():
            fields = row.split(None, 2)
            if len(fields) != 3 or not fields[0].isdigit():
                raise ValueError('Unparseable process inventory: ' + row)
            pid, state, command = int(fields[0]), fields[1], fields[2]
            if 'U' not in state:
                continue
            extension = 'YuzuNTFSModule' in command or '/com.apple.fskit.exfat.appex/Contents/MacOS/' in command
            mount_grace = mounting_benchmark and extension
            paths = (open_paths or {}).get(pid, ())
            owned = self.command_owned(command) or any(
                path in opened for path in self.owned_paths for opened in paths)
            key = (pid, command, owned, mount_grace)
            since = self.waits.get(key, now)
            current[key] = since
            limit = 120 if mount_grace else 20
            limit_text = f'{limit}s' if owned else 'log-only'
            message = f'PID {pid} U for {now - since:.1f}s ({"owned" if owned else "unrelated"}, limit={limit_text}): {command}'
            (stops if owned and now - since >= limit else info).append(message)
        self.waits = current
        return stops, info

def inspect_open_paths(inspection, processes, monitor):
    paths = {}
    for row in processes.splitlines():
        fields = row.split(None, 2)
        # Known command ownership is conclusive; inspect only unknown waits.
        if len(fields) == 3 and 'U' in fields[1] and not monitor.command_owned(fields[2]):
            opened = inspection.run('lsof', '-b', '-a', '-p', fields[0], '-Fn', allowed=(0, 1), timeout=5)
            paths[int(fields[0])] = [line[1:] for line in opened.splitlines() if line.startswith('n')]
    return paths


def wait_for_owned_io(inspection, owned_paths):
    """Final inventory uses the same V-R4 persistence policy as live sampling."""
    monitor = UStateMonitor(owned_paths)
    while True:
        processes = inspection.run('ps', '-axo', 'pid=,state=,command=', timeout=10)
        paths = inspect_open_paths(inspection, processes, monitor)
        stops, info = monitor.observe(processes, time.monotonic(), paths)
        for message in info:
            print('INFO final inventory ' + message, flush=True)
        if stops:
            raise RuntimeError('\n'.join(stops))
        if not any(owned for _, _, owned, _ in monitor.waits):
            return
        time.sleep(1)


def benchmark_mount_active(text, root):
    """V-R3: only an actual mount command for our exact 8 GiB bench images."""
    root = root.resolve()
    for row in text.splitlines():
        fields = row.split(None, 2)
        if len(fields) != 3:
            continue
        args = fields[2].split()
        if len(args) == 6 and args[:4] == ['/sbin/mount', '-F', '-t', 'yuzuntfs']:
            device, target = args[4], Path(args[5]).resolve()
            if not target.is_relative_to(root / 'build/p0-guest') or target.name != 'bench-mount':
                continue
            image = root / 'build/r3/bench-ntfs.img'
        elif len(args) == 5 and Path(args[0]).name == 'diskutil' and args[1:3] == ['mount', '-mountPoint']:
            target, device = Path(args[3]).resolve(), args[4]
            if target != root / 'build/baseline/mount':
                continue
            image = root / 'build/baseline/exfat.img'
        else:
            continue
        if not device.startswith('/dev/disk') or not device[len('/dev/disk'):].isdigit():
            continue
        try:
            if image.resolve().is_relative_to(root) and image.is_file() and image.stat().st_size == 8 * 1024**3:
                return True
        except OSError:
            pass
    return False



def capture_stop(root, process_text):
    """Bounded evidence capture before signaling an acceptance worker."""
    pids = {row.split(None, 2)[0] for row in process_text.splitlines()
            if len(row.split(None, 2)) == 3
            and ('U' in row.split(None, 2)[1] or 'YuzuNTFSModule' in row.split(None, 2)[2])}
    commands = [['sample', pid, '2', '1'] for pid in sorted(pids)]
    commands.append(['/usr/bin/log', 'show', '--last', '3m', '--style', 'compact',
                     '--predicate', 'process == "fskitd" OR process == "YuzuNTFSModule"'])
    with (root / 'build/pre-stop-evidence.log').open('w') as output:
        for command in commands:
            output.write('+ ' + ' '.join(command) + '\n')
            output.flush()
            try:
                output.write(Runner().run(*command, timeout=12))
            except (OSError, RuntimeError) as error:
                output.write('Evidence command failed: ' + str(error) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--entry', default='p0_guest_acceptance.py')
    args = parser.parse_args()
    inspection = Runner()
    if inspection.run('sysctl', '-n', 'kern.hv_vmm_present', timeout=10).strip() != '1':
        parser.error('VM-only acceptance launcher')
    root = args.root.resolve(strict=True)
    if os.geteuid() != 0:
        parser.error('Run monitor as root for system-process open-file inspection; workload runs as root-directory owner')
    owner = pwd.getpwuid(root.stat().st_uid)
    if owner.pw_uid == 0:
        parser.error('Worktree must belong to the guest acceptance user, not root')
    os.chdir(root)
    monitor = UStateMonitor([root / 'build/p0-guest', root / 'build/r3', root / 'build/baseline'])
    with (root / 'build/acceptance.log').open('w') as output, (root / 'build/u-observations.log').open('w') as observations:
        command = ['sudo', '-u', owner.pw_name, '/usr/bin/env', 'HOME=' + owner.pw_dir,
                   'PATH=' + owner.pw_dir + '/bin:/usr/bin:/bin:/usr/sbin:/sbin',
                   sys.executable, str(root / 'scripts' / args.entry), '--timeout', '180', '--bench-timeout', '1800']
        child = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 2700
        while child.poll() is None:
            sampled_at = time.monotonic()
            try:
                processes = inspection.run('ps', '-axo', 'pid=,state=,command=', timeout=10)
                paths = inspect_open_paths(inspection, processes, monitor)
                info_mount = benchmark_mount_active(processes, root)
                stops, info = monitor.observe(processes, time.monotonic(), paths, mounting_benchmark=info_mount)
                for message in info:
                    observations.write('INFO transient ' + message + '\n')
                observations.flush()
                if time.monotonic() > deadline:
                    stops.append('TOTAL DEADLINE')
                if stops:
                    (root / 'build/safety-stop.txt').write_text('\n'.join(stops) + '\n' + processes)
                    capture_stop(root, processes)
                    child.send_signal(signal.SIGTERM)
                    break
            except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
                (root / 'build/safety-stop.txt').write_text('MONITOR ERROR: ' + str(error))
                child.send_signal(signal.SIGTERM)
                break
            time.sleep(max(0, 1 - (time.monotonic() - sampled_at)))
        try:
            status = child.wait(timeout=8)
        except subprocess.TimeoutExpired:
            status = 'survivor PID=' + str(child.pid)
        (root / 'build/acceptance-status.txt').write_text(str(status) + '\n')
    # launchctl submit restarts exited jobs: retain a harmless idle runner until removal.
    while True:
        time.sleep(60)

if __name__ == '__main__':
    main()
