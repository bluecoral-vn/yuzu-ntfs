#!/usr/bin/env python3
"""Headless seqio write safety regression; never opens a disk device."""
import pathlib
import subprocess
import tempfile
import unittest

SEQIO = pathlib.Path(__file__).resolve().parents[1] / 'tools/seqio'

class SeqioSafety(unittest.TestCase):
    def test_write_rejects_symlink_without_truncating_target(self):
        with tempfile.TemporaryDirectory() as directory:
            target = pathlib.Path(directory) / 'target'
            target.write_bytes(b'preserve me')
            link = pathlib.Path(directory) / 'link'
            link.symlink_to(target)
            result = subprocess.run([str(SEQIO), 'write', str(link), '1'], capture_output=True, timeout=60)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(target.read_bytes(), b'preserve me')

    def test_write_rejects_nonregular_descriptor(self):
        result = subprocess.run([str(SEQIO), 'write', '/dev/null', '1'], capture_output=True, timeout=60)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'regular file', result.stderr)

if __name__ == '__main__':
    unittest.main()
