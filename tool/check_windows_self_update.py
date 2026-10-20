#!/usr/bin/env python3
"""Run the production Windows updater against disposable background fixtures.

Requires the Visual Studio C++ desktop tools. Keeps its report and fixtures under
build/windows-self-update-qa; never replaces an installed client or changes Hub.
"""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile


ROOT = Path(__file__).resolve().parents[1]


def wait_for(condition, description, timeout=25):
    deadline = time.monotonic() + timeout
    while not condition():
        if time.monotonic() >= deadline:
            raise AssertionError(f"Timed out waiting for {description}")
        time.sleep(0.1)


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    if sys.platform != "win32":
        sys.exit("Run on Windows with the Visual Studio C++ desktop tools.")
    output = ROOT / "build/windows-self-update-qa"
    output.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="run-", dir=output)).resolve()
    powershell = Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"
    vswhere = Path(os.environ["ProgramFiles(x86)"]) / "Microsoft Visual Studio/Installer/vswhere.exe"
    visual_studio = subprocess.check_output([
        str(vswhere), "-latest", "-products", "*", "-requires",
        "Microsoft.VisualStudio.Component.VC.Tools.x86.x64", "-property", "installationPath",
    ], text=True, timeout=30).strip()
    if not visual_studio:
        sys.exit("Visual Studio C++ desktop tools were not found.")
    vcvars = Path(visual_studio) / "VC/Auxiliary/Build/vcvars64.bat"
    hidden = subprocess.CREATE_NO_WINDOW
    (work / "fixture.cpp").write_text('''#include <windows.h>
int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
  HANDLE f = CreateFileW(L"restarted.txt", GENERIC_WRITE, 0, nullptr,
      CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (f == INVALID_HANDLE_VALUE) return 2;
  DWORD n; WriteFile(f, "ok", 2, &n, nullptr); CloseHandle(f); return 0;
}
''', encoding="utf-8")
    (work / "fixture.rc").write_text(r'''#include <windows.h>
1 VERSIONINFO
FILEVERSION 0,1,0,0
PRODUCTVERSION 0,1,0,0
FILEOS VOS_NT_WINDOWS32
FILETYPE VFT_APP
BEGIN
 BLOCK "StringFileInfo"
 BEGIN
  BLOCK "040904e4"
  BEGIN
   VALUE "CompanyName", "win.huarun\0"
   VALUE "FileDescription", "huarunwin\0"
   VALUE "FileVersion", "0.1.0\0"
   VALUE "InternalName", "huarunwin\0"
   VALUE "ProductName", "huarunwin\0"
   VALUE "ProductVersion", "0.1.0\0"
  END
 END
 BLOCK "VarFileInfo"
 BEGIN
  VALUE "Translation", 0x409, 1252
 END
END
''', encoding="utf-8")
    (work / "compile.cmd").write_text(
        f'@echo off\ncall "{vcvars}" >nul\nif errorlevel 1 exit /b 1\n'
        f'cd /d "{work}"\nrc /nologo fixture.rc\nif errorlevel 1 exit /b 1\n'
        'cl /nologo /utf-8 /EHsc fixture.cpp fixture.res /link '
        '/SUBSYSTEM:WINDOWS /OUT:huarunwin.exe\n', encoding="utf-8")
    subprocess.run(["cmd.exe", "/d", "/c", str(work / "compile.cmd")],
                   check=True, creationflags=hidden, timeout=120)
    script = work / "update.ps1"
    script.write_text((ROOT / "assets/updater/windows.ps1").read_text(encoding="utf-8"),
                      encoding="utf-8-sig")
    results = []

    def case(name, *, cancel=False, bad_digest=False, version="0.1.0",
             malformed=False, lock=None, traversal=False):
        target = work / name
        current, incoming, job = (target / part for part in ("current", "incoming", "job"))
        for folder in (current, incoming, job):
            folder.mkdir(parents=True)
        for folder in (current, incoming):
            shutil.copy2(work / "huarunwin.exe", folder / "huarunwin.exe")
            (folder / "data/flutter_assets").mkdir(parents=True)
            for filename in ("marker.txt", "a-must-stay.txt"):
                (folder / "data/flutter_assets" / filename).write_text(
                    "old" if folder == current else "new", encoding="utf-8")
            (folder / "flutter_windows.dll").write_bytes(b"fixture-only")
        if malformed:
            (incoming / "flutter_windows.dll").unlink()
        package = target / "update.zip"
        with zipfile.ZipFile(package, "w") as archive:
            for file in incoming.rglob("*"):
                if file.is_file():
                    archive.write(file, str(Path("bundle") / file.relative_to(incoming)))
            if traversal:
                archive.writestr("../escape.txt", b"bad")
        digest = "0" * 64 if bad_digest else sha256(package)
        parent = subprocess.Popen([
            str(powershell), "-NoProfile", "-NonInteractive", "-Command",
            "[Threading.Thread]::Sleep(60000)",
        ], creationflags=hidden)
        updater = locker = None

        def assert_old():
            for filename in ("marker.txt", "a-must-stay.txt"):
                assert (current / "data/flutter_assets" / filename).read_text() == "old"
            assert sha256(current / "huarunwin.exe") == sha256(work / "huarunwin.exe")
            assert (current / "flutter_windows.dll").read_bytes() == b"fixture-only"

        try:
            updater = subprocess.Popen([
                str(powershell), "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                "-File", str(script), str(package), digest, str(current / "huarunwin.exe"),
                str(parent.pid), version, str(job),
            ], creationflags=hidden, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            wait_for(lambda: (job / "ready").exists() or updater.poll() is not None,
                     f"{name} preparation")
            rejected = bad_digest or malformed or version != "0.1.0" or traversal
            if rejected:
                updater.communicate(timeout=10)
                assert updater.returncode != 0, "Invalid package was accepted"
                assert (job / "error.txt").is_file()
                assert not (job / "ready").exists()
                assert not (job / "result").exists()
                assert not (target / "escape.txt").exists()
                assert_old()
                results.append({"case": name, "outcome": "rejected as expected"})
                return
            assert (job / "ready").exists(), "Updater did not prepare the package"
            assert parent.poll() is None
            assert not (job / "result").exists(), "Replaced files before parent exit"
            assert_old()
            if cancel:
                (job / "cancel").write_text("cancel", encoding="utf-8")
            if lock:
                lock_path = str(current / lock).replace("'", "''")
                ready_path = str(job / "locked").replace("'", "''")
                lock_script = target / "lock.ps1"
                lock_script.write_text(
                    f"$f=[IO.File]::Open('{lock_path}',[IO.FileMode]::Open,"
                    "[IO.FileAccess]::Read,[IO.FileShare]::None); "
                    f"[IO.File]::WriteAllText('{ready_path}','locked'); "
                    "[Threading.Thread]::Sleep(60000); $f.Dispose()", encoding="utf-8-sig")
                locker = subprocess.Popen([
                    str(powershell), "-NoProfile", "-NonInteractive", "-ExecutionPolicy",
                    "Bypass", "-File", str(lock_script),
                ], creationflags=hidden)
                wait_for(lambda: (job / "locked").exists(), f"{name} file lock")
            parent.terminate()
            parent.wait(timeout=5)
            _, errors = updater.communicate(timeout=30)
            if cancel:
                assert updater.returncode == 0, errors.decode(errors="replace")
                assert not (job / "result").exists()
                assert_old()
                assert not (current / "restarted.txt").exists()
            elif lock:
                assert updater.returncode != 0
                assert (job / "error.txt").exists()
                assert not (job / "result").exists()
                locker.terminate()
                locker.wait(timeout=5)
                assert_old()
                wait_for(lambda: (current / "restarted.txt").exists(), "old client restart")
            else:
                assert updater.returncode == 0, errors.decode(errors="replace")
                assert (job / "result").read_text() == "installed"
                assert (current / "data/flutter_assets/marker.txt").read_text() == "new"
                wait_for(lambda: (current / "restarted.txt").exists(), "new client restart")
                backup = Path((job / "backup-path").read_text())
                assert (backup / "data/flutter_assets/marker.txt").read_text() == "old"
            results.append({"case": name, "outcome": "passed"})
        finally:
            for process in (parent, updater, locker):
                if process is not None and process.poll() is None:
                    process.terminate()
                    process.wait(timeout=5)

    try:
        case("success")
        case("cancel", cancel=True)
        case("digest", bad_digest=True)
        case("version", version="0.2.0")
        case("incomplete", malformed=True)
        case("traversal", traversal=True)
        case("locked-directory", lock="data/flutter_assets/marker.txt")
        case("locked-runtime-rollback", lock="flutter_windows.dll")
    finally:
        (work / "report.json").write_text(json.dumps(results, indent=2), encoding="utf-8")
        print(json.dumps(results, indent=2))
        print(f"Report: {work.relative_to(ROOT) / 'report.json'}")


if __name__ == "__main__":
    main()
