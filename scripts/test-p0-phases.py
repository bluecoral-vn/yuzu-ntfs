#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Harmless-process supervision regression; no disk, module or daemon commands."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

SCRIPTS = Path(__file__).resolve().parent


class SequentialPhases(unittest.TestCase):
    def test_second_phase_sigterm_revokes_and_terminates_logger(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            logger_code = '''import os, pathlib, signal, sys, time
root = pathlib.Path(sys.argv[1])
def stop(signum, frame):
    with (root / 'events').open('a') as output: output.write('logger-terminated\\n')
    os._exit(0)
signal.signal(signal.SIGTERM, stop)
(root / 'ready').write_text(str(os.getpid()))
while True: time.sleep(.02)
'''
            control_code = '''import os, pathlib, subprocess, sys, time
sys.path.insert(0, sys.argv[1])
import p0_guest_acceptance as guest
root = pathlib.Path(sys.argv[2])
def event(value):
    with (root / 'events').open('a') as output: output.write(value + '\\n')
guest.revoke = lambda serial: event('revoke-' + serial)
guest.authorize = lambda serial: event('authorize-' + serial)
guest.phase('one', 'one', 10, lambda: None)
def second():
    (root / 'worker').write_text(str(os.getpid()))
    subprocess.Popen([sys.executable, '-c', sys.argv[3], str(root)])
    while True: time.sleep(.02)
guest.phase('two', 'two', 10, second, write=True)
event('phase-three-started')
'''
            child = subprocess.Popen([sys.executable, '-c', control_code, str(SCRIPTS), str(root), logger_code],
                                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)
            output = ''
            try:
                deadline = time.monotonic() + 5
                while not (root / 'ready').exists() and time.monotonic() < deadline and child.poll() is None:
                    time.sleep(.02)
                self.assertTrue((root / 'ready').exists(), 'phase 2 logger never started')
                child.send_signal(signal.SIGTERM)
                try:
                    output = child.communicate(timeout=3)[0]
                except subprocess.TimeoutExpired:
                    self.fail('phase 2 ignored SIGTERM after phase 1 changed the signal mask')
                self.assertNotEqual(child.returncode, 0, output)
                deadline = time.monotonic() + 3
                while 'logger-terminated' not in (root / 'events').read_text() and time.monotonic() < deadline:
                    time.sleep(.02)
                events = (root / 'events').read_text().splitlines()
                self.assertNotIn('phase-three-started', events)
                self.assertIn('logger-terminated', events)
                self.assertLess(events.index('revoke-two'), events.index('logger-terminated'))
                self.assertIn('authorization revoked FIRST', output)
            finally:
                # Only these owned, harmless Python processes are cleaned up.
                if (root / 'worker').exists():
                    try: os.killpg(int((root / 'worker').read_text()), signal.SIGKILL)
                    except ProcessLookupError: pass
                if child.poll() is None:
                    child.kill()
                child.communicate(timeout=3)


if __name__ == '__main__':
    unittest.main()
