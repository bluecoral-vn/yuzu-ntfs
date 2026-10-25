#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Temporary-bundle tests with recorded PlugInKit schemas; no host commands."""
from pathlib import Path
import plistlib
import shutil
import tempfile
import unittest
from unittest.mock import patch
import zipfile
import sys

import p0_ops as ops

COMMIT = 'a' * 40
UUID = '7FFBB224-A94D-479D-B839-1E2864C3777D'


def bundle(path):
    extension = path / 'Contents/Extensions/YuzuNTFSModule.appex/Contents'
    (extension / 'MacOS').mkdir(parents=True)
    (path / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.bluecoral.vn.yuzuntfs', 'YuzuGitCommit': COMMIT}))
    (extension / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': ops.MODULE, 'CFBundleExecutable': 'YuzuNTFSModule', 'YuzuGitCommit': COMMIT, 'EXAppExtensionAttributes': {'FSSupportsKernelOffloadedIO': True}}))
    (extension / 'MacOS/YuzuNTFSModule').write_bytes(b'recorded-test-binary')


def record(path):
    # Same schema/UUID as the successful record in p0-r1-enable.md.
    return f'+ {ops.MODULE}(0.1.0)\n  Path = {path}/Contents/Extensions/YuzuNTFSModule.appex\n  UUID = {UUID}\n  Parent Bundle = {path}\n'


class FakeRunner:
    dry = False
    def __init__(self, installed, duplicate, fail_archive=False):
        self.installed, self.duplicate = installed, duplicate
        self.commands = []
        self.inventories = 0
        self.fail_archive = fail_archive
    def run(self, *command, **kwargs):
        args = [str(value) for value in command]
        self.commands.append(args)
        if args[:2] == ['pluginkit', '-mADvvv']:
            self.inventories += 1
            return record(self.installed) + (record(self.duplicate) if self.inventories == 1 else '')
        if args[0] == 'ditto' and '-c' not in args:
            shutil.copytree(args[1], args[2], dirs_exist_ok=True)
        elif args[0] == 'ditto':
            source, archive = Path(args[-2]), Path(args[-1])
            with zipfile.ZipFile(archive, 'w') as output:
                for path in source.rglob('*'):
                    if path.is_file(): output.write(path, path.relative_to(source.parent))
        elif args[0] == '/usr/bin/unzip':
            if self.fail_archive: raise RuntimeError('archive verification failed')
            with zipfile.ZipFile(args[-1]) as archive:
                assert archive.testzip() is None
        elif args[0] == '/bin/rm':
            shutil.rmtree(args[-1])
        return ''


class InstallerIsolation(unittest.TestCase):
    def fresh_absence(self, plugin=False, parent=False, fatal=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); repo = root / 'repo'
            temporary = root / 'tmp'; temporary.mkdir()
            staged = repo / 'build/release/Yuzu NTFS.app'
            installed = root / 'Applications/Yuzu NTFS.app'
            bundle(staged)
            class FreshRunner(FakeRunner):
                def run(self, *command, **kwargs):
                    args = [str(value) for value in command]
                    if args[:2] == ['pluginkit', '-r'] and plugin:
                        raise RuntimeError('absent plugin must not be unregistered')
                    if args[:2] == [str(ops.LSREGISTER), '-u'] and parent:
                        message = f'failed to scan {staged}: {-50 if fatal else -10814}\n from spotlight'
                        return ops.Runner().run(sys.executable, '-c', f'print({message!r}); raise SystemExit(1)')
                    text = super().run(*command, **kwargs)
                    return text.replace(record(staged), '') if plugin and args[:2] == ['pluginkit', '-mADvvv'] else text
            runner = FreshRunner(installed, staged)
            with patch.object(ops, 'ROOT', repo), patch.object(ops, 'QC_TEMP', temporary), patch.object(ops, 'DERIVED_DATA', root / 'DerivedData'), patch.object(ops, 'APP', installed), patch.object(ops, 'APPEX', installed / 'Contents/Extensions/YuzuNTFSModule.appex'), patch.object(ops, 'preflight'), patch.object(ops, 'set_enabled'):
                ops.install(runner, staged, COMMIT)
            self.assertFalse(staged.exists())
            self.assertTrue(installed.exists())

    def test_fresh_guest_absent_plugin_is_isolated_without_unregister(self):
        self.fresh_absence(plugin=True)

    def test_fresh_guest_absent_parent_app_10814_is_isolated(self):
        self.fresh_absence(parent=True)

    def test_parent_app_other_unregister_failure_is_fatal(self):
        with self.assertRaises(RuntimeError):
            self.fresh_absence(parent=True, fatal=True)

    def test_install_archives_duplicates_and_staged_only_after_verified_copy(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo, temporary = root / 'repo', root / 'tmp'
            temporary.mkdir()
            staged, duplicate = repo / 'build/release/Yuzu NTFS.app', repo / 'build/Debug/YuzuNTFS.app'
            installed = root / 'Applications/Yuzu NTFS.app'
            bundle(staged); bundle(duplicate)
            unregistered = temporary / 'yuzu-qc-dd/Build/Products/Debug/YuzuNTFS.app'
            bundle(unregistered)
            runner = FakeRunner(installed, duplicate)
            with patch.object(ops, 'ROOT', repo), patch.object(ops, 'QC_TEMP', temporary), patch.object(ops, 'DERIVED_DATA', root / 'DerivedData'), patch.object(ops, 'APP', installed), patch.object(ops, 'APPEX', installed / 'Contents/Extensions/YuzuNTFSModule.appex'), patch.object(ops, 'preflight'), patch.object(ops, 'set_enabled') as refresh:
                ops.install(runner, staged, COMMIT)
                refresh.assert_called_once()
            self.assertTrue(installed.is_dir())
            self.assertFalse(staged.exists(), 'staged candidate can still be rediscovered')
            self.assertFalse(duplicate.exists(), 'duplicate build can still be rediscovered')
            self.assertFalse(unregistered.exists(), 'unregistered QC bundle can still be rediscovered')
            archives = list((repo / 'build/archive').glob('*.zip'))
            self.assertEqual(len(archives), 3)
            for archive in archives:
                with zipfile.ZipFile(archive) as saved:
                    self.assertTrue(any(name.endswith('MacOS/YuzuNTFSModule') for name in saved.namelist()))
            removals = [i for i, command in enumerate(runner.commands) if command[0] == '/bin/rm']
            registration = next(i for i, command in enumerate(runner.commands) if command[:2] == ['pluginkit', '-a'])
            self.assertTrue(all(index < registration for index in removals))
            self.assertGreaterEqual(runner.inventories, 3)

    def test_unregistered_own_derived_data_copy_is_archived(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo, temporary = root / 'repo', root / 'tmp'
            temporary.mkdir()
            staged = repo / 'build/release/Yuzu NTFS.app'
            external = root / 'DerivedData/YuzuNTFS-recorded/Build/Products/Debug/YuzuNTFS.app'
            installed = root / 'Applications/Yuzu NTFS.app'
            bundle(staged); bundle(external)
            runner = FakeRunner(installed, staged)
            with patch.object(ops, 'ROOT', repo), patch.object(ops, 'QC_TEMP', temporary), patch.object(ops, 'DERIVED_DATA', root / 'DerivedData'), patch.object(ops, 'APP', installed), patch.object(ops, 'APPEX', installed / 'Contents/Extensions/YuzuNTFSModule.appex'), patch.object(ops, 'preflight'), patch.object(ops, 'set_enabled') as refresh:
                ops.install(runner, staged, COMMIT)
                refresh.assert_called_once()
            self.assertFalse(external.exists())
            self.assertTrue(external.parent.exists(), 'must preserve DerivedData directory')
            self.assertNotIn(['pluginkit', '-r', str(external / 'Contents/Extensions/YuzuNTFSModule.appex')], runner.commands)
            self.assertIn([str(ops.LSREGISTER), '-u', str(external)], runner.commands)
            self.assertEqual(len(list((repo / 'build/archive').glob('*.zip'))), 2)

    def test_outside_scope_bundle_is_listed_and_never_modified(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo, temporary = root / 'repo', root / 'tmp'
            temporary.mkdir()
            staged, outside = repo / 'build/release/Yuzu NTFS.app', root / 'DerivedData/OtherProject-recorded/Build/Products/Debug/YuzuNTFS.app'
            installed = root / 'Applications/Yuzu NTFS.app'
            bundle(staged); bundle(outside)
            runner = FakeRunner(installed, outside)
            with patch.object(ops, 'ROOT', repo), patch.object(ops, 'QC_TEMP', temporary), patch.object(ops, 'DERIVED_DATA', root / 'DerivedData'), patch.object(ops, 'APP', installed), patch.object(ops, 'APPEX', installed / 'Contents/Extensions/YuzuNTFSModule.appex'), patch.object(ops, 'preflight'), patch.object(ops, 'set_enabled') as refresh:
                with self.assertRaisesRegex(RuntimeError, 'outside|scope'):
                    ops.install(runner, staged, COMMIT)
                refresh.assert_not_called()
            self.assertTrue(outside.exists())
            self.assertFalse(any(command[:2] == ['pluginkit', '-r'] or command[0] == '/bin/rm' for command in runner.commands))

    def test_failed_archive_verification_preserves_unpacked_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo, temporary = root / 'repo', root / 'tmp'
            temporary.mkdir()
            staged, duplicate = repo / 'build/release/Yuzu NTFS.app', repo / 'build/Debug/YuzuNTFS.app'
            installed = root / 'Applications/Yuzu NTFS.app'
            bundle(staged); bundle(duplicate)
            runner = FakeRunner(installed, duplicate, fail_archive=True)
            with patch.object(ops, 'ROOT', repo), patch.object(ops, 'QC_TEMP', temporary), patch.object(ops, 'DERIVED_DATA', root / 'DerivedData'), patch.object(ops, 'APP', installed), patch.object(ops, 'APPEX', installed / 'Contents/Extensions/YuzuNTFSModule.appex'), patch.object(ops, 'preflight'), patch.object(ops, 'set_enabled') as refresh:
                with self.assertRaisesRegex(RuntimeError, 'archive verification failed'):
                    ops.install(runner, staged, COMMIT)
                refresh.assert_not_called()
            self.assertTrue(staged.exists() and duplicate.exists())
            self.assertFalse(any(command[0] == '/bin/rm' or command[:2] == ['pluginkit', '-a'] for command in runner.commands))


if __name__ == '__main__':
    unittest.main()
