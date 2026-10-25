#!/usr/bin/env python3
"""Headless benchmark preflight tests: execute only before disk operations."""
import os
import pathlib
import subprocess
import signal
import time
import ast
import plistlib
from types import SimpleNamespace
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = pathlib.Path(__file__).with_name('bench.sh')
PREFIX = SCRIPT.read_text().split("<<'PY'\n", 1)[1].split('def checked_device():', 1)[0]

class BenchPreflight(unittest.TestCase):
    def test_termination_during_parent_setup_never_releases_worker(self):
        with tempfile.TemporaryDirectory() as directory:
            allow = pathlib.Path(directory) / 'allow'
            code = f"""
import atexit, os, pathlib, signal, sys, time
sys.path.insert(0, {str(SCRIPT.parent)!r})
import bench_supervisor as supervisor
allow = pathlib.Path({str(allow)!r})
def revoke():
    allow.unlink(missing_ok=True)
atexit.register(revoke)
original = os.setpgid
def interrupted_setup(pid, group):
    original(pid, group)
    if pid > 0:
        os.kill(os.getpid(), signal.SIGTERM)
supervisor.os.setpgid = interrupted_setup
supervisor.supervise(revoke, 'startup fixture', 3)
time.sleep(0.05)
allow.write_text('worker reauthorized')
os._exit(0)
"""
            result = subprocess.run([sys.executable, '-c', code], capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 128 + signal.SIGTERM, result.stderr.decode())
            self.assertFalse(allow.exists(), result.stderr.decode())

    def test_supervisor_deadline_revokes_before_terminating_worker(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = pathlib.Path(directory) / 'revoked'
            code = (
                'import pathlib, time, sys; '
                f'sys.path.insert(0, {str(SCRIPT.parent)!r}); '
                'from bench_supervisor import supervise; '
                f'p=pathlib.Path({str(marker)!r}); '
                'supervise(lambda:p.write_text(\"revoked\"), \"test attachment\", 0.05); '
                'time.sleep(0.3)'
            )
            start = time.monotonic()
            result = subprocess.run([sys.executable, '-c', code], capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 124)
            self.assertEqual(marker.read_text(), 'revoked')
            self.assertIn(b'authorization revoked FIRST', result.stderr)
            self.assertIn(b'PID/PGID=', result.stderr)
            self.assertLess(time.monotonic() - start, 2)

    def test_mount_identity_is_checked_before_workload(self):
        source = SCRIPT.read_text().split("<<'PY'\n", 1)[1].rsplit('\nPY', 1)[0]
        module = ast.parse(source)
        function = next(node for node in module.body if isinstance(node, ast.FunctionDef) and node.name == 'mount_image')
        for device, filesystem in [('/dev/wrong', 'yuzuntfs'), ('/dev/test', 'exfat')]:
            def output(command, **kwargs):
                if command[0] == '/sbin/mount':
                    return f'{device} on /safe/mount ({filesystem}, local, fskit)\n'
                return plistlib.dumps({'DeviceNode': device, 'FilesystemType': filesystem, 'MountPoint': '/safe/mount'})
            subprocess_fake = SimpleNamespace(run=lambda *a, **k: None, check_output=output)
            namespace = dict(checked_device=lambda: '/dev/test', dev='/dev/test', fstype='yuzuntfs', readonly=False, mount=pathlib.Path('/safe/mount'), subprocess=subprocess_fake, plistlib=plistlib, mounted=False)
            exec(compile(ast.Module(body=[function], type_ignores=[]), str(SCRIPT), 'exec'), namespace)
            with self.assertRaisesRegex(SystemExit, 'mismatch'):
                namespace['mount_image']()

    def test_yuzu_mount_accepts_authoritative_row_and_ntfs_personality(self):
        source = SCRIPT.read_text().split("<<'PY'\n", 1)[1].rsplit('\nPY', 1)[0]
        function = next(node for node in ast.parse(source).body if isinstance(node, ast.FunctionDef) and node.name == 'mount_image')
        for fields in ({}, {'FilesystemType': 'ntfs'}):
            with self.subTest(fields=fields):
                info = {'DeviceNode': '/dev/test', 'MountPoint': '/safe/mount', **fields}
                def output(command, **kwargs):
                    if command[0] == '/sbin/mount':
                        return '/dev/test on /safe/mount (yuzuntfs, local, fskit)\n'
                    return plistlib.dumps(info)
                fake = SimpleNamespace(run=lambda *a, **k: None, check_output=output)
                namespace = dict(checked_device=lambda: '/dev/test', dev='/dev/test', fstype='yuzuntfs', readonly=False, mount=pathlib.Path('/safe/mount'), subprocess=fake, plistlib=plistlib, mounted=False)
                exec(compile(ast.Module(body=[function], type_ignores=[]), str(SCRIPT), 'exec'), namespace)
                namespace['mount_image']()

    def test_image_driver_mismatch_rejected_before_authorization(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            image = root / 'fixture.img'
            boot = bytearray(512)
            boot[3:11] = b'NTFS    '
            boot[72:80] = (123).to_bytes(8, 'little')
            image.write_bytes(boot)
            previous = os.getcwd()
            try:
                os.chdir(root)
                with patch.dict(os.environ, HOME=str(root), BENCH_IMAGE=str(image), BENCH_FSTYPE='exfat'), patch.object(sys, 'argv', ['bench', str(root / 'mount'), 'test']):
                    with self.assertRaisesRegex(SystemExit, 'mismatch'):
                        exec(compile(PREFIX, str(SCRIPT), 'exec'), {})
                self.assertFalse((root / 'Library').exists())
            finally:
                os.chdir(previous)

if __name__ == '__main__':
    unittest.main()
