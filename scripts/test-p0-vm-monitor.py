#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
import unittest
import ast
from pathlib import Path
from types import SimpleNamespace
import p0_vm_monitor
from p0_vm_monitor import UStateMonitor

class RecordedProcessStates(unittest.TestCase):
    def test_known_owned_u_worker_skips_redundant_lsof_but_unknown_is_inspected(self):
        source = Path(p0_vm_monitor.__file__).read_text()
        loop = next(node for node in ast.walk(ast.parse(source))
                    if isinstance(node, ast.For) and ast.unparse(node.iter) == 'result.stdout.splitlines()')
        calls = []
        def inspect(command, **kwargs):
            calls.append(command)
            return SimpleNamespace(returncode=0, stdout='n/owned/mount/file\n', stderr='')
        namespace = dict(paths={}, monitor=UStateMonitor(['/owned/mount']),
                         result=SimpleNamespace(stdout='2376 U /owned/mount/seqio write file\n88 U /usr/libexec/mds'),
                         subprocess=SimpleNamespace(run=inspect))
        exec(compile(ast.Module(body=[loop], type_ignores=[]), p0_vm_monitor.__file__, 'exec'), namespace)
        self.assertEqual(calls, [['lsof', '-b', '-a', '-p', '88', '-Fn']])
        self.assertEqual(namespace['paths'], {88: ['/owned/mount/file']})

    def test_recorded_homeeventsd_transient_is_info(self):
        monitor = UStateMonitor(['/Users/lume/yuzu-ntfs/build/p0-guest'])
        stop, info = monitor.observe('877 U /System/Library/PrivateFrameworks/HomeKitEvents.framework/Support/homeeventsd', 0)
        self.assertFalse(stop)
        self.assertIn('877', info[0])
        self.assertFalse(monitor.observe('877 S /System/Library/PrivateFrameworks/HomeKitEvents.framework/Support/homeeventsd', 2)[0])

    def test_unrelated_continuous_wait_is_logged_and_never_stops(self):
        monitor = UStateMonitor([])
        for now in (0, 20, 120, 3600):
            stop, info = monitor.observe('325 Us /usr/sbin/spindump', now)
            self.assertFalse(stop)
            self.assertIn('325', info[0])

    def test_wait_reset_and_pid_reuse(self):
        monitor = UStateMonitor([])
        monitor.observe('325 U mds_stores', 0)
        monitor.observe('325 S mds_stores', 18)
        self.assertFalse(monitor.observe('325 U mds_stores', 20)[0])
        self.assertFalse(monitor.observe('325 U other-daemon', 40)[0])

    def test_owned_args_workers_module_and_open_paths_require_persistence(self):
        for command, paths in [('cp /owned/mount/a /tmp/a', {}), ('YuzuNTFSModule -BSServiceDomains', {}), ('/usr/libexec/fskitd', {}), ('python p0_guest_acceptance.py', {}), ('python vmrw_oracle.py', {}), ('mds_stores', {50: ['/owned/mount']})]:
            with self.subTest(command=command):
                monitor = UStateMonitor(['/owned/mount'])
                for now in range(20):
                    self.assertFalse(monitor.observe('50 U ' + command, now, paths)[0])
                self.assertTrue(monitor.observe('50 U ' + command, 20, paths)[0])

    def test_vr3_mount_only_extends_extension_wait_to_120_seconds(self):
        monitor = UStateMonitor([])
        row = '50 U /Applications/Yuzu NTFS.app/Contents/MacOS/YuzuNTFSModule'
        for now in range(120):
            self.assertFalse(monitor.observe(row, now, mounting_benchmark=True)[0])
        self.assertTrue(monitor.observe(row, 120, mounting_benchmark=True)[0])
        self.assertFalse(monitor.observe(row, 121, mounting_benchmark=False)[0])
        self.assertTrue(monitor.observe(row, 141, mounting_benchmark=False)[0])
        apple = UStateMonitor([])
        apple_row = '70 U /System/Library/ExtensionKit/Extensions/com.apple.fskit.exfat.appex/Contents/MacOS/com.apple.fskit.exfat'
        apple.observe(apple_row, 0, mounting_benchmark=True)
        self.assertFalse(apple.observe(apple_row, 119, mounting_benchmark=True)[0])
        self.assertTrue(apple.observe(apple_row, 120, mounting_benchmark=True)[0])
        other = UStateMonitor(['/owned'])
        other.observe('60 U cp /owned/a /owned/b', 0, mounting_benchmark=True)
        self.assertTrue(other.observe('60 U cp /owned/a /owned/b', 20, mounting_benchmark=True)[0])

    def test_vr3_requires_actual_owned_eight_gib_benchmark_mount(self):
        import tempfile
        from pathlib import Path
        from p0_vm_monitor import benchmark_mount_active
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            image = root / 'build/r3/bench-ntfs.img'
            image.parent.mkdir(parents=True)
            with image.open('wb') as output:
                output.truncate(8 * 1024**3)
            row = f'50 S /sbin/mount -F -t yuzuntfs /dev/disk9 {root}/build/p0-guest/owned/bench-mount'
            self.assertTrue(benchmark_mount_active(row, root))
            for invalid in (row.replace('bench-mount', 'rw-mount'), row.replace(str(root), '/foreign'), row.replace('/sbin/mount', '/bin/cp')):
                self.assertFalse(benchmark_mount_active(invalid, root))
            with image.open('wb') as output:
                output.truncate(256 * 1024**2)
            self.assertFalse(benchmark_mount_active(row, root))
            exfat = root / 'build/baseline/exfat.img'
            exfat.parent.mkdir()
            with exfat.open('wb') as output:
                output.truncate(8 * 1024**3)
            apple_row = f'70 S diskutil mount -mountPoint {root}/build/baseline/mount /dev/disk10'
            self.assertTrue(benchmark_mount_active(apple_row, root))

if __name__ == '__main__':
    unittest.main()
