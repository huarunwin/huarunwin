#!/usr/bin/env python3
"""Check local packages; --install-fixture also checks installation and replacement."""
import argparse
import json
import os
import pathlib
import plistlib
import select
import shutil
import subprocess
import tempfile
import zipfile
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--install-fixture', action='store_true',
                    help='Install and replace a uniquely named test app in /Applications, then remove it; never uses root.')
options = parser.parse_args()


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


with tempfile.TemporaryDirectory(prefix='huarun-installer-tests-') as work:
    work = pathlib.Path(work)
    helper = work / 'helper'
    run('xcrun', 'swiftc', str(ROOT / 'macos/Installer/main.swift'),
        str(ROOT / 'macos/Runner/InstallerProcess.swift'), '-o', str(helper))
    payload = work / 'payload'
    app = payload / 'Fixture.app'
    binary = app / 'Contents/MacOS/Fixture'
    binary.parent.mkdir(parents=True)
    shutil.copy2(helper, binary)
    with (app / 'Contents/Info.plist').open('wb') as stream:
        plistlib.dump({'CFBundleIdentifier': 'win.huarun.fixture', 'CFBundleExecutable': 'Fixture', 'CFBundlePackageType': 'APPL'}, stream)

    def inspect(package, expected=None):
        process = subprocess.run([str(helper), 'prepare', str(package)], capture_output=True, text=True)
        result = json.loads(process.stdout)
        if expected is not None:
            assert process.returncode != 0 and result['code'] == expected, result
        else:
            assert process.returncode == 0, result
            prepared = pathlib.Path(result['path'])
            assert prepared.is_dir() and prepared.name == 'Fixture.app'
            assert prepared.parent.name.startswith('huarun-install-')
            shutil.rmtree(prepared.parent)
        return result

    archive = work / 'fixture.zip'
    run('/usr/bin/ditto', '-c', '-k', '--keepParent', str(app), str(archive))
    inspect(archive)
    print('PASS ZIP preparation, bundle validation and CPU architecture')

    # Exercise signature classification without using a signing identity or
    # keychain. These observations describe the package, never Apple trust.
    signing_app = work / 'signing/Fixture.app'
    shutil.copytree(app, signing_app)
    signing_zip = work / 'signing.zip'

    def inspect_signature(expected):
        if signing_zip.exists():
            signing_zip.unlink()
        run('/usr/bin/ditto', '-c', '-k', '--keepParent', str(signing_app), str(signing_zip))
        result = inspect(signing_zip)
        assert result['signature'] == expected, result
        assert result['teamIdentifier'] == '' and result['notarization'] == 'unknown', result
        assert result['assessment'] in ['accepted', 'rejected', 'unknown'], result

    run('/usr/bin/codesign', '--force', '--sign', '-', str(signing_app))
    inspect_signature('adhoc')
    print('PASS identifies ad-hoc signatures without claiming notarization')
    resource = signing_app / 'Contents/Resources/signature-check.txt'
    resource.parent.mkdir(exist_ok=True)
    resource.write_text('changed after signing')
    inspect_signature('invalid')
    print('PASS reports a changed signed bundle as invalid')
    run('/usr/bin/codesign', '--remove-signature', str(signing_app))
    inspect_signature('unsigned')
    print('PASS unsigned applications remain eligible for preparation')

    # An internal framework symlink is valid; one escaping the app is not.
    os.symlink('/etc', app / 'Contents/External')
    unsafe = work / 'unsafe.zip'
    run('/usr/bin/ditto', '-c', '-k', '--keepParent', str(app), str(unsafe))
    inspect(unsafe, 'package')
    (app / 'Contents/External').unlink()
    print('PASS rejects symlinks escaping the bundle')

    traversal = work / 'traversal.zip'
    with zipfile.ZipFile(traversal, 'w') as zf:
        zf.writestr('../outside.txt', 'must not be extracted')
    inspect(traversal, 'package')
    assert not (work / 'outside.txt').exists()
    print('PASS rejects archive traversal')

    shutil.copytree(app, payload / 'Second.app')
    multi = work / 'multiple.zip'
    run('/usr/bin/ditto', '-c', '-k', '--keepParent', str(payload), str(multi))
    inspect(multi, 'package')
    shutil.rmtree(payload / 'Second.app')
    print('PASS rejects ambiguous multiple-app packages')

    disk = work / 'fixture.dmg'
    run('/usr/bin/hdiutil', 'create', '-srcfolder', str(payload), '-volname', 'Huarun Installer Test', '-format', 'UDZO', str(disk))
    inspect(disk)
    print('PASS DMG mount, app preparation and detach')

    invalid_commit = subprocess.run([str(helper), 'commit', '/tmp/Untrusted.app', 'true'], capture_output=True, text=True)
    assert invalid_commit.returncode != 0 and json.loads(invalid_commit.stdout)['code'] == 'package'
    print('PASS rejects unprepared installation requests')

    if options.install_fixture:
        assert os.geteuid() != 0, 'Run this validation as an ordinary user.'
        identity = uuid.uuid4().hex
        unique = 'HuarunValidation-' + identity + '.app'
        named_app = payload / unique
        app.rename(named_app)
        info_path = named_app / 'Contents/Info.plist'
        info = plistlib.loads(info_path.read_bytes())
        info['CFBundleIdentifier'] = 'win.huarun.validation.' + identity
        info_path.write_bytes(plistlib.dumps(info))
        version_path = pathlib.Path('Contents/Resources/validation-version.txt')
        (named_app / version_path).parent.mkdir()
        (named_app / version_path).write_text('1')
        install_zip = work / 'install.zip'
        run('/usr/bin/ditto', '-c', '-k', '--keepParent', str(named_app), str(install_zip))
        prepared = pathlib.Path(json.loads(run(str(helper), 'prepare', str(install_zip)))['path'])
        destination = pathlib.Path('/Applications') / unique
        assert not os.path.lexists(destination)
        installed = False
        try:
            run('/usr/bin/xattr', '-w', 'com.apple.quarantine', '0081;00000000;HuarunValidation;', str(prepared))
            run('/usr/bin/xattr', '-w', 'com.apple.quarantine', '0081;00000000;HuarunValidation;', str(prepared / 'Contents/Info.plist'))
            result = json.loads(run(str(helper), 'commit', str(prepared), 'true'))
            installed = True
            assert result['path'] == str(destination)
            assert (destination / 'Contents/MacOS/Fixture').read_bytes() == helper.read_bytes()
            assert 'com.apple.quarantine' not in run('/usr/bin/xattr', str(destination))
            assert 'com.apple.quarantine' not in run('/usr/bin/xattr', str(destination / 'Contents/Info.plist'))
            print('PASS ordinary /Applications installation and recursive quarantine removal')

            def rejected_commit(code):
                rejected = subprocess.run([str(helper), 'commit', str(prepared), 'true'], capture_output=True, text=True)
                result = json.loads(rejected.stdout)
                assert rejected.returncode != 0 and result['code'] == code, rejected.stdout
                return result

            (prepared / version_path).write_text('2')
            result = json.loads(run(str(helper), 'commit', str(prepared), 'true'))
            assert result['path'] == str(destination)
            assert (destination / version_path).read_text() == '2'
            assert not (destination / unique).exists()
            print('PASS same-identity reinstall atomically replaces the old application')

            prepared_binary = prepared / 'Contents/MacOS/Fixture'
            prepared_binary.write_bytes(b'invalid executable')
            rejected_commit('package')
            assert (destination / version_path).read_text() == '2'
            assert (destination / 'Contents/MacOS/Fixture').read_bytes() == helper.read_bytes()
            shutil.copy2(helper, prepared_binary)
            print('PASS invalid replacement leaves the installed application unchanged')

            (prepared / version_path).write_text('3')
            run('/usr/bin/chflags', 'uchg', str(destination))
            try:
                rejected_commit('permission_required')
                assert (destination / version_path).read_text() == '2'
            finally:
                run('/usr/bin/chflags', 'nouchg', str(destination))
            print('PASS failed atomic swap preserves the old application')

            installed_info = destination / 'Contents/Info.plist'
            conflicting = dict(info, CFBundleIdentifier='win.huarun.unrelated')
            installed_info.write_bytes(plistlib.dumps(conflicting))
            rejected_commit('app_mismatch')
            assert plistlib.loads(installed_info.read_bytes()) == conflicting
            assert (destination / version_path).read_text() == '2'
            installed_info.write_bytes(plistlib.dumps(info))
            print('PASS unrelated application with the same name is preserved')

            saved = work / 'saved-installed.app'
            shutil.move(destination, saved)
            try:
                destination.symlink_to(saved, target_is_directory=True)
                rejected_commit('app_mismatch')
                assert destination.is_symlink() and (saved / version_path).read_text() == '2'
                destination.unlink()
                destination.write_text('unrelated file')
                rejected_commit('app_mismatch')
                assert destination.read_text() == 'unrelated file'
            finally:
                if destination.is_symlink() or destination.is_file():
                    destination.unlink()
                elif destination.exists():
                    shutil.rmtree(destination)
                shutil.move(saved, destination)
            print('PASS same-name files and symlinks are not replaced')

            running_source = work / 'running.swift'
            running_source.write_text('''import AppKit
final class FixtureDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("READY")
        fflush(stdout)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        CommandLine.arguments.contains("--refuse-quit") ? .terminateCancel : .terminateNow
    }
}
let app = NSApplication.shared
let delegate = FixtureDelegate()
app.delegate = delegate
app.setActivationPolicy(.prohibited)
app.run()
''')
            installed_binary = destination / 'Contents/MacOS/Fixture'
            run('xcrun', 'swiftc', str(running_source), '-o', str(installed_binary))
            driver_source = work / 'main.swift'
            driver_source.write_text('''import AppKit
let args = CommandLine.arguments
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
DispatchQueue.main.async {
    DispatchQueue.global().async {
        do {
            try RunningApplicationQuitter.quit(path: args[1], bundleIdentifier: args[2], timeout: 1)
            print("ok")
            exit(0)
        } catch let error as NSError {
            print(error.userInfo["installerCode"] as? String ?? "unknown")
            exit(1)
        }
    }
}
app.run()
''')
            quit_driver = work / 'quit-driver'
            run('xcrun', 'swiftc', str(ROOT / 'macos/Runner/RunningApplicationQuitter.swift'), str(driver_source), '-o', str(quit_driver))

            for refuses_quit in [True, False]:
                fixture_args = [str(installed_binary)] + (['--refuse-quit'] if refuses_quit else [])
                running = subprocess.Popen(fixture_args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                try:
                    ready, _, _ = select.select([running.stdout], [], [], 10)
                    assert ready and running.stdout.readline().strip() == 'READY', 'Background fixture did not start.'
                    result = rejected_commit('running')
                    assert result['path'] == str(destination)
                    assert result['bundleIdentifier'] == info['CFBundleIdentifier']
                    assert (destination / version_path).read_text() == '2'
                    if refuses_quit:
                        wrong_identity = subprocess.run([str(quit_driver), str(destination), 'win.huarun.unrelated'], capture_output=True, text=True, timeout=10)
                        assert wrong_identity.returncode != 0 and wrong_identity.stdout.strip() == 'changed', wrong_identity
                        assert running.poll() is None
                        print('PASS quit request refuses a mismatched application identity')
                    quitting = subprocess.run([str(quit_driver), str(destination), info['CFBundleIdentifier']], capture_output=True, text=True, timeout=10)
                    if refuses_quit:
                        assert quitting.returncode != 0 and quitting.stdout.strip() == 'quit_failed', quitting
                        assert running.poll() is None
                        rejected_commit('running')
                        assert (destination / version_path).read_text() == '2'
                        print('PASS declined quit times out without force quitting or replacing the app')
                    else:
                        assert quitting.returncode == 0 and quitting.stdout.strip() == 'ok', quitting
                        running.wait(timeout=5)
                        run(str(helper), 'commit', str(prepared), 'true')
                        assert (destination / version_path).read_text() == '3'
                        print('PASS normal quit waits for termination and then permits replacement')
                finally:
                    if running.poll() is None:
                        running.terminate()
                        try:
                            running.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            running.kill()
                            running.wait(timeout=5)
        finally:
            if installed:
                shutil.rmtree(destination)
            shutil.rmtree(prepared.parent)
