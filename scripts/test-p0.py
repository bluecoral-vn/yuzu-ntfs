#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Recorded-output/pure-policy tests only: never invokes host control commands."""
import contextlib
import io
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import Mock, patch

import p0_ops as ops
import p0_guest_acceptance as guest

# Verbatim successful registration recorded in docs/spikes/p0-r1-enable.md.
REGISTERED = '''+ com.bluecoral.vn.yuzuntfs.fsmodule(0.1.0)
  Path = /Applications/Yuzu NTFS.app/Contents/Extensions/YuzuNTFSModule.appex
  UUID = 7FFBB224-A94D-479D-B839-1E2864C3777D
  Parent Bundle = /Applications/Yuzu NTFS.app
'''
# Same recorded schema, with QCDeployOps' actual historical build-product path.
DUPLICATE = '''  com.bluecoral.vn.yuzuntfs.fsmodule(0.1.0)
  Path = /tmp/yuzu-qc-dd/Build/Products/Debug/YuzuNTFS.app/Contents/Extensions/YuzuNTFSModule.appex
  UUID = 27FFBB22-A94D-479D-B839-1E2864C3777D
'''
NATIVE_MOUNTS = '''/dev/disk3s1s1 on / (apfs, sealed, local, read-only, journaled)
devfs on /dev (devfs, local, nobrowse)
map auto_home on /System/Volumes/Data/home (autofs, automounted, nobrowse)
'''


class P0PureTests(unittest.TestCase):
    def test_recorded_registration_and_duplicate_paths(self):
        records = ops.registrations(REGISTERED + DUPLICATE)
        self.assertEqual(len(records), 2)
        self.assertEqual(records[0]['path'], str(ops.APPEX))
        self.assertIn('/tmp/yuzu-qc-dd/', records[1]['path'])
        self.assertEqual(records[0]['uuid'], '7FFBB224-A94D-479D-B839-1E2864C3777D')
        self.assertEqual(ops.registrations(''), [])

    def test_probe_requires_enabled_exact_installed_url(self):
        enabled = ops.MODULE + ' enabled=true url=' + str(ops.APPEX) + '\n'
        ops.check_probe(enabled, True)
        ops.check_probe('', False)
        ops.check_probe(enabled.replace('true', 'false'), False)
        for output in ['', enabled.replace('true', 'false'), enabled.replace('/Applications/', '/tmp/'), enabled + enabled]:
            with self.assertRaises(RuntimeError):
                ops.check_probe(output, True)
        with self.assertRaises(RuntimeError):
            ops.check_probe(enabled, False)

    def test_disable_enable_preserve_unrelated_modules_and_back_up(self):
        with tempfile.TemporaryDirectory() as directory:
            settings = Path(directory) / 'enabledModules.plist'
            settings.write_bytes(plistlib.dumps(['apple.module', ops.MODULE, 'other.module']))
            runner = Mock(dry=False)
            def output(*command, **kwargs):
                if command[0] == '/sbin/mount':
                    return NATIVE_MOUNTS
                if command[0] == 'pgrep':
                    return ''
                if command[0] == ops.ROOT / 'build/r1/FSClientProbe':
                    state = 'true' if '--expect-enabled' in command else 'false'
                    return ops.MODULE + ' enabled=' + state + ' url=' + str(ops.APPEX)
                raise AssertionError(command)
            runner.run.side_effect = output
            with patch.object(ops, 'SETTINGS', settings), contextlib.redirect_stdout(io.StringIO()):
                ops.set_enabled(runner, False)
                self.assertEqual(plistlib.loads(settings.read_bytes()), ['apple.module', 'other.module'])
                ops.set_enabled(runner, True)
                self.assertEqual(plistlib.loads(settings.read_bytes()), ['apple.module', 'other.module', ops.MODULE])
            self.assertEqual(len(list(Path(directory).glob('*.backup'))), 2)


    def test_incomplete_or_unparsed_registration_fails_closed(self):
        for text in [REGISTERED.replace('UUID =', 'unknown ='), REGISTERED.replace('YuzuNTFSModule.appex', 'Other.appex'), REGISTERED.replace('+ com.', 'HEADER com.')]:
            with self.assertRaises(RuntimeError):
                ops.registrations(text)

    def test_allowlist_exact_lines_and_empty(self):
        self.assertEqual(ops.allowlist(''), [])
        self.assertEqual(ops.allowlist('0123456789abcdef\n'), ['0123456789abcdef'])
        for invalid in ['\n', ' 0123456789ABCDEF', '0123456789ABCDEF ', '0x123456789ABCDEF', '# comment', '123']:
            with self.assertRaises(RuntimeError):
                ops.allowlist(invalid)

    def test_vm_detection_is_exact_fail_closed(self):
        self.assertTrue(ops.is_vm('1\n'))
        for output in ['0\n', '', 'true', 'sysctl: unknown oid', '11']:
            self.assertFalse(ops.is_vm(output))

    def test_unknown_and_coredevice_mounts_block_refresh(self):
        self.assertEqual(ops.active_fskit(NATIVE_MOUNTS), [])
        for kind in ['yuzuntfs', 'DeviceFS', 'lifs', 'fskit', 'newtransport']:
            self.assertEqual(len(ops.active_fskit(NATIVE_MOUNTS + f'guest on /Volumes/test ({kind}, local)\n')), 1)
        with self.assertRaises(RuntimeError):
            ops.active_fskit('unparseable mount output')

    def test_recovery_requires_reboot_or_no_u_and_old_pid_absent(self):
        old = '{ sec = 1, usec = 0 }'
        new = '{ sec = ' + str(int(ops.WEDGED_AT) + 1) + ', usec = 0 }'
        ops.recovered(old, '42 S /bin/launchd\n')
        ops.recovered(new, '42 U /bin/example\n')
        with self.assertRaises(RuntimeError):
            ops.recovered(old, '42 U /bin/cp\n')
        with self.assertRaises(RuntimeError):
            ops.recovered(new, '65911 S /bin/reused-pid\n')
        with self.assertRaises(RuntimeError):
            ops.recovered('unknown', '')

    def test_preflight_rejects_historical_attachment_and_nonempty_allowlist(self):
        runner = Mock(dry=False)
        image = str(ops.ROOT / 'build/r3/mount-test2.img')
        runner.run.side_effect = ['{ sec = 1 }', '42 S launchd', plistlib.dumps({'images': [{'image-path': image}]}).decode(), NATIVE_MOUNTS]
        with self.assertRaisesRegex(RuntimeError, 'Historical attachment'):
            ops.preflight(runner)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'allowlist'
            with patch.object(ops, 'ALLOW', path):
                ops.empty_allowlist()
                path.write_text('0123456789ABCDEF\n')
                with self.assertRaisesRegex(RuntimeError, 'empty'):
                    ops.empty_allowlist()

    def test_all_dry_runs_are_command_and_filesystem_side_effect_free(self):
        runner = ops.Runner(True)
        arguments = Mock(allow_host_readonly=False, bench_image=Path('/test/bench.img'), bench_timeout=1800)
        with patch.object(ops.subprocess, 'Popen', side_effect=AssertionError('dry-run launched a command')), patch.object(ops, 'bundle_metadata', side_effect=AssertionError('dry-run read installed bundle')), patch.object(ops, 'empty_allowlist', side_effect=AssertionError('dry-run read authorization')):
            with contextlib.redirect_stdout(io.StringIO()) as transcript:
                ops.preflight(runner)
                ops.install(runner, Path('/test/staged.app'), 'a' * 40)
                ops.set_enabled(runner, False)
                ops.set_enabled(runner, True)
                guest.dry_plan(runner, arguments)
            self.assertIn('blockmapFile AND completeIO', transcript.getvalue())
            arguments.allow_host_readonly = True
            with contextlib.redirect_stdout(io.StringIO()) as transcript:
                guest.dry_plan(runner, arguments)
            self.assertNotIn('O_WRONLY', transcript.getvalue())
            self.assertNotIn('BENCH_IMAGE=', transcript.getvalue())

    def test_command_timeout_revokes_before_signal_without_wait(self):
        events = []
        runner = ops.Runner(False, timeout=.1, new_session=False)
        runner.before_timeout = lambda: events.append('revoke')
        child = Mock(pid=123)
        child.poll.return_value = None
        child.terminate.side_effect = lambda: events.append('signal')
        with patch.object(ops.subprocess, 'Popen', return_value=child), patch.object(ops.time, 'monotonic', side_effect=[0, 1]):
            with self.assertRaisesRegex(RuntimeError, 'no blocking reap'):
                runner.run('/harmless-recorded-command')
        self.assertEqual(events, ['revoke', 'signal'])
        child.wait.assert_not_called()
        child.communicate.assert_not_called()


if __name__ == '__main__':
    unittest.main()
