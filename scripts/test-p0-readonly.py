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


if __name__ == '__main__':
    unittest.main()