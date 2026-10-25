#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Read-only acceptance regressions; no live media operations."""
import hashlib
import plistlib
from pathlib import Path
import sys
import tempfile
import unittest
import p0_guest_acceptance as guest
from p0_ops import Runner


class ReadOnlyAcceptance(unittest.TestCase):
    def test_fskit_mount_identity_with_missing_diskutil_fields(self):
        # diskutil fields observed on the failed 2026-10-25 FSKit mount;
        # mount syntax follows the recorded mount(8) inventory format.
        actual = {'DeviceNode': '/dev/disk12', 'MountPoint': '/tmp/owned-ro'}
        line = '/dev/disk12 on /tmp/owned-ro (yuzuntfs, local, read-only, fskit, mounted by rom)\n'
        guest.check_mount_identity(actual, line, '/dev/disk12', Path('/tmp/owned-ro'), True)
        for bad in (line.replace('read-only, ', ''), line.replace('yuzuntfs', 'ntfs'),
                    line.replace('/dev/disk12', '/dev/disk13'), ''):
            with self.assertRaises(RuntimeError):
                guest.check_mount_identity(actual, bad, '/dev/disk12', Path('/tmp/owned-ro'), True)
        with self.assertRaises(RuntimeError):
            guest.check_mount_identity({**actual, 'ReadOnlyVolume': False}, line, '/dev/disk12', Path('/tmp/owned-ro'), True)

    def test_recorded_ntfs_personality_agrees_with_yuzuntfs_mount(self):
        mount = Path('/Users/rom/Projects/yuzu-ntfs-p0/build/p0-guest/ade18435-844e-4134-a18f-52874b22771d/basic-512-ro-mount')
        actual = {'DeviceNode': '/dev/disk14', 'MountPoint': str(mount),
                  'FilesystemType': 'ntfs', 'WritableVolume': False}
        line = f'/dev/disk14 on {mount} (yuzuntfs, local, nodev, nosuid, read-only, noowners, noatime, fskit, mounted by rom)\n'
        guest.check_mount_identity(actual, line, '/dev/disk14', mount, True)
        for kind in ('msdos', 'exfat', 'apfs'):
            with self.assertRaises(RuntimeError):
                guest.check_mount_identity({**actual, 'FilesystemType': kind}, line, '/dev/disk14', mount, True)
        for bad in (line.replace('yuzuntfs', 'ntfs'), line.replace('/dev/disk14', '/dev/disk15'),
                    line.replace('read-only, ', '')):
            with self.assertRaises(RuntimeError):
                guest.check_mount_identity(actual, bad, '/dev/disk14', mount, True)

    def test_plist_stdout_survives_recorded_hdiutil_stderr(self):
        xml = '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>system-entities</key><array><dict><key>dev-entry</key><string>/dev/disk12</string></dict></array></dict></plist>\n'
        warning = "hdiutil: WARNING: 'hdiutil attach -nomount ...' is deprecated. Please use 'diskutil image attach --noMount ...' instead.\n"
        output = Runner().run(sys.executable, '-c', 'import sys; sys.stdout.write(sys.argv[1]); sys.stderr.write(sys.argv[2])', xml, warning, '-plist')
        self.assertEqual(plistlib.loads(output.encode())['system-entities'][0]['dev-entry'], '/dev/disk12')

    def test_diagnostic_stderr_remains_available(self):
        output = Runner().run(sys.executable, '-c', 'import sys; sys.stderr.write("TeamIdentifier=37PX6W22C5\\n")')
        self.assertIn('TeamIdentifier=37PX6W22C5', output)

    def test_manifest_hashes_reject_wrong_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            mount = Path(directory)
            (mount / 'nonresident.bin').write_bytes(b'payload')
            entry = {'path': '/nonresident.bin', 'type': 'file', 'size': 7, 'sha256': hashlib.sha256(b'payload').hexdigest()}
            guest.verify_manifest_reads(mount, [entry])
            (mount / 'nonresident.bin').write_bytes(b'corrupt')
            with self.assertRaisesRegex(RuntimeError, 'hash mismatch'):
                guest.verify_manifest_reads(mount, [entry])

    def test_bigdir_samples_and_names_cover_manifest(self):
        entries = [{'path': f'/file-{index}', 'type': 'file'} for index in range(100000)]
        self.assertEqual(guest.ro_samples('bigdir', entries), [entries[i] for i in (0, 1, 49999, 99999)])
        self.assertEqual(guest.ro_samples('names', entries[:4]), entries[:4])

    def test_retained_mapping_allows_only_already_mapped_data_changes(self):
        before = {'metadata': b'MFT size=8192 VDL=8192 allocated=8192 runs=1',
                  'data': b'B' * 8192}
        after = {**before, 'data': b'X' + b'B' * 8191}
        guest.check_retained_mapping(before, after, 0, 4096)
        for invalid in ({**after, 'metadata': b'MFT VDL changed'},
                        {**after, 'data': after['data'] + b'X'},
                        {**after, 'data': b'B' * 8191 + b'X'}):
            with self.assertRaises(RuntimeError):
                guest.check_retained_mapping(before, invalid, 0, 4096)

    def test_retained_mapping_writeback_accepts_prompt_success_or_erofs(self):
        guest.retained_writeback(lambda: None)
        def denied():
            raise OSError(30, 'read-only')
        guest.retained_writeback(denied)
        with self.assertRaises(OSError):
            guest.retained_writeback(lambda: (_ for _ in ()).throw(OSError(5, 'I/O error')))

    def test_retained_mapping_writeback_rejects_slow_completion(self):
        from unittest.mock import patch
        with patch.object(guest.time, 'monotonic', side_effect=[1, 7]):
            with self.assertRaisesRegex(RuntimeError, 'prompt'):
                guest.retained_writeback(lambda: None)


if __name__ == '__main__':
    unittest.main()