#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


class BetaAcceptanceTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('beta_acceptance', Path(__file__).with_name('beta_user_acceptance.py'))
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.module.CONTROL = self.root / 'control'
        self.module.CONTROL.mkdir()

    def result(self, error):
        value = {'id': 'test-id', 'error': error, 'enabled': True, 'drives': []}
        (self.module.CONTROL / 'result.json').write_text(json.dumps(value))
        return value

    def test_unexpected_app_error_still_fails(self):
        self.result('refused')
        with patch.object(self.module.uuid, 'uuid4', return_value='test-id'):
            with self.assertRaisesRegex(RuntimeError, 'refused'):
                self.module.command('writing-on', 'disk9')

    def test_explicit_negative_assertion_can_receive_actual_error(self):
        expected = self.result('QA drive not found')
        with patch.object(self.module.uuid, 'uuid4', return_value='test-id'):
            self.assertEqual(self.module.command('writing-on', 'disk9', allow_error=True), expected)

    def test_status_capture_is_scoped_to_device_and_serial(self):
        current = self.root / 'status-disk9-current.json'
        current.write_text(json.dumps({'serial': 16}))
        (self.root / 'status-disk9-other.json').write_text(json.dumps({'serial': 17}))
        (self.root / 'status-disk9s1-current.json').write_text(json.dumps({'serial': 16}))
        path, raw = self.module.status_record('disk9', '0000000000000010', directory=self.root)
        self.assertEqual(path, current)
        self.assertEqual(json.loads(raw), {'serial': 16})

    def test_ambiguous_published_status_fails(self):
        for suffix in ['a', 'b']:
            (self.root / f'status-disk9-{suffix}.json').write_text(json.dumps({'serial': 16}))
        with self.assertRaises(RuntimeError):
            self.module.status_record('disk9', '10', directory=self.root)

    def test_unload_assertion_never_accepts_a_lingering_file(self):
        path = self.root / 'status-disk9-current.json'
        path.touch()
        with self.assertRaises(RuntimeError):
            self.module.require_status_removed(path, timeout=0)
        path.unlink()
        self.module.require_status_removed(path, timeout=0)


if __name__ == '__main__':
    unittest.main()
