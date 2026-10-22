#!/usr/bin/env python3
"""Exercise the macOS updater against disposable, background-only app bundles.

Never replaces an installed client, requests administrator access, or publishes
update metadata. All fixtures and updater backups live in a temporary directory.
"""

import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
IDENTITY = "win.huarun.huarunwin"


def run(*args):
    return subprocess.run([str(arg) for arg in args], check=True,
                          capture_output=True, text=True, timeout=120).stdout


def wait_for(condition, description, timeout=30):
    deadline = time.monotonic() + timeout
    while not condition():
        if time.monotonic() > deadline:
            raise AssertionError(f"Timed out waiting for {description}")
        time.sleep(0.05)


def main():
    if sys.platform != "darwin" or os.geteuid() == 0:
        sys.exit("Run as an ordinary user on macOS.")
    with tempfile.TemporaryDirectory(prefix="huarun-self-update-qa-") as temporary:
        work = Path(temporary).resolve()
        helper = work / "updater"
        run("xcrun", "swiftc", ROOT / "macos/Installer/main.swift",
            ROOT / "macos/Runner/InstallerProcess.swift",
            ROOT / "macos/Installer/AdminService.swift",
            ROOT / "macos/Installer/InstallerOperations.swift",
            ROOT / "macos/Runner/AdminServiceProtocol.swift", "-o", helper)
        source = work / "main.swift"
        source.write_text('''import AppKit
final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if args.count == 3 {
            try! "ready".write(toFile: args[1], atomically: true, encoding: .utf8)
            Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                if FileManager.default.fileExists(atPath: args[2]) { NSApp.terminate(nil) }
            }
        } else {
            let info = Bundle.main.infoDictionary!
            let marker = info["HuarunQAMarker"] as! String
            let version = info["CFBundleShortVersionString"] as! String
            try! version.write(toFile: marker, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }
}
let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.prohibited)
app.run()
''')
        binary = work / "Fixture"
        run("xcrun", "swiftc", source, "-o", binary)
        processes = []
        bundles = []

        def fixture(folder, version="0.2.0", build="2", channel="debug", identity=IDENTITY):
            app = folder / "HuarunSelfUpdateQA.app"
            contents = app / "Contents"
            (contents / "MacOS").mkdir(parents=True)
            (contents / "Resources").mkdir()
            shutil.copy2(binary, contents / "MacOS/Fixture")
            (contents / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": identity,
                "CFBundleExecutable": "Fixture",
                "CFBundleName": "HuarunSelfUpdateQA",
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": version.split("-")[0],
                "CFBundleVersion": build,
                "LSUIElement": True,
                "HuarunQAMarker": str(folder.parent / "relaunched"),
            }))
            (contents / "Resources/huarunwin-build.plist").write_bytes(plistlib.dumps({
                "version": version, "channel": channel,
            }))
            run("/usr/bin/codesign", "--force", "--sign", "-", app)
            bundles.append(app)
            return app

        def start(app, name):
            ready, quit_file = app.parent / (name + ".ready"), app.parent / (name + ".quit")
            process = subprocess.Popen([str(app / "Contents/MacOS/Fixture"), str(ready), str(quit_file)],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            processes.append(process)
            wait_for(lambda: ready.exists() or process.poll() is not None, "fixture launch")
            assert ready.exists(), process.stderr.read().decode()
            return process, quit_file

        def stop(process, quit_file):
            quit_file.write_text("quit")
            process.wait(timeout=10)

        def case(name, *, version="0.2.0", expected=None, cancel=False, second_instance=False, **incoming_options):
            folder = work / name
            folder.mkdir()
            current = fixture(folder / "current", version="0.1.0", build="1")
            incoming = fixture(folder / "incoming", version=version, **incoming_options)
            if name == "invalid-signature":
                (incoming / "Contents/Resources/changed-after-signing").write_text("invalid")
            if name == "wrong-prerelease":
                version = "0.2.0-rc.2"
            job = folder / "job"
            job.mkdir()
            parent, quit_file = start(current, "parent")
            other = start(current, "other") if second_instance else None
            updater = subprocess.Popen([str(helper), "self-update", str(incoming), str(current),
                                        str(parent.pid), version, str(job), str(os.getuid()), "debug"],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            processes.append(updater)
            try:
                wait_for(lambda: (job / "ready").exists() or updater.poll() is not None, "updater preparation")
                info_path = current / "Contents/Info.plist"
                assert plistlib.loads(info_path.read_bytes())["CFBundleShortVersionString"] == "0.1.0"
                assert parent.poll() is None, "Updater must not terminate the current app"
                if (job / "ready").exists():
                    if cancel:
                        (job / "cancel").write_text("cancel")
                    else:
                        stop(parent, quit_file)
                stdout, stderr = updater.communicate(timeout=30)
                if expected:
                    assert updater.returncode != 0, (name, stdout, stderr)
                    assert json.loads(stdout)["code"] == expected, (name, stdout, stderr)
                    assert (job / "error.txt").read_text().strip()
                    assert not (job / "result").exists()
                    assert plistlib.loads(info_path.read_bytes())["CFBundleShortVersionString"] == "0.1.0"
                else:
                    assert updater.returncode == 0, (name, stdout, stderr)
                    assert (job / "result").read_text() == "installed"
                    backup = Path((job / "backup-path").read_text()).resolve()
                    assert backup.is_relative_to(folder.resolve()), backup
                    assert plistlib.loads((backup / "Contents/Info.plist").read_bytes())["CFBundleShortVersionString"] == "0.1.0"
                    assert plistlib.loads(info_path.read_bytes())["CFBundleShortVersionString"] == version.split("-")[0]
                    wait_for(lambda: (folder / "relaunched").exists(), "updated app relaunch")
                    assert (folder / "relaunched").read_text() == version.split("-")[0]
                    run("/usr/bin/codesign", "--verify", "--deep", "--strict", current)
                print(f"PASS {name}", flush=True)
            finally:
                if parent.poll() is None:
                    stop(parent, quit_file)
                if other and other[0].poll() is None:
                    stop(*other)
                if updater.poll() is None:
                    updater.terminate()
                    updater.wait(timeout=10)

        try:
            case("upgrade-and-relaunch")
            case("prerelease-and-relaunch", version="0.2.0-rc.2")
            case("wrong-identity", identity="win.huarun.unrelated", expected="update_identity")
            case("wrong-prerelease", version="0.2.0-rc.1", expected="update_identity")
            case("wrong-channel", channel="release", expected="update_identity")
            case("invalid-signature", expected="update_signature")
            case("reject-downgrade", version="0.0.9", expected="update_downgrade")
            case("cancel-before-exit", cancel=True, expected="update_cancelled")
            case("another-instance", second_instance=True, expected="running")
        finally:
            for process in processes:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=10)
            registrar = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
            for app in bundles:
                subprocess.run([registrar, "-u", str(app)], capture_output=True)


if __name__ == "__main__":
    main()
