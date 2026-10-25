#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
import unittest
from p0_vm_monitor import UStateMonitor

class RecordedProcessStates(unittest.TestCase):
    def test_recorded_homeeventsd_transient_is_info(self):
        monitor = UStateMonitor(['/Users/lume/yuzu-ntfs/build/p0-guest'])
        stop, info = monitor.observe('877 U /System/Library/PrivateFrameworks/HomeKitEvents.framework/Support/homeeventsd', 0)
        self.assertFalse(stop)
        self.assertIn('877', info[0])
        self.assertFalse(monitor.observe('877 S /System/Library/PrivateFrameworks/HomeKitEvents.framework/Support/homeeventsd', 2)[0])

    def test_unrelated_continuous_wait_stops_at_twenty_seconds(self):
        monitor = UStateMonitor([])
        for now in range(0, 20, 2):
            self.assertFalse(monitor.observe('325 Us /System/Library/Metadata/mds_stores', now)[0])
        self.assertTrue(monitor.observe('325 Us /System/Library/Metadata/mds_stores', 20)[0])

    def test_wait_reset_and_pid_reuse(self):
        monitor = UStateMonitor([])
        monitor.observe('325 U mds_stores', 0)
        monitor.observe('325 S mds_stores', 18)
        self.assertFalse(monitor.observe('325 U mds_stores', 20)[0])
        self.assertFalse(monitor.observe('325 U other-daemon', 40)[0])

    def test_owned_args_workers_module_and_open_paths_stop_immediately(self):
        for command, paths in [('cp /owned/mount/a /tmp/a', {}), ('YuzuNTFSModule -BSServiceDomains', {}), ('python p0_guest_acceptance.py', {}), ('python vmrw_oracle.py', {}), ('unknown-command', {50: ['/owned/mount']})]:
            with self.subTest(command=command):
                self.assertTrue(UStateMonitor(['/owned/mount']).observe('50 U ' + command, 0, paths)[0])

if __name__ == '__main__':
    unittest.main()
