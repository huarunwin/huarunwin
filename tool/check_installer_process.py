#!/usr/bin/env python3
"""Exercise the installer's process IO and deadlines without installing apps."""
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = r'''
import Foundation

var lines: [String] = []
let streamed = try InstallerProcess.run("/bin/sh", ["-c", "printf 'preparing\\n'; printf 'diagnostic' >&2; printf 'done\\n'"], timeout: 3, onLine: { lines.append($0) })
precondition(streamed.status == 0 && lines == ["preparing", "done"] && streamed.stderr == "diagnostic")
print("PASS streams phases and captures stderr")

let noisy = try InstallerProcess.run("/usr/bin/python3", ["-c", "import sys; sys.stderr.write('e'*200000); sys.stdout.write('o'*200000)"], timeout: 5, outputLimit: 1024)
precondition(noisy.status == 0 && noisy.truncated && noisy.stdout.utf8.count == 1024 && noisy.stderr.utf8.count == 16384)
print("PASS drains simultaneous full pipes with bounded output")

let start = ProcessInfo.processInfo.systemUptime
let hung = try InstallerProcess.run("/bin/sleep", ["5"], timeout: 0.1)
precondition(hung.timedOut && hung.status != 0 && ProcessInfo.processInfo.systemUptime - start < 3)
print("PASS terminates a timed-out system tool")

let flooding = try InstallerProcess.run("/usr/bin/python3", ["-c", "import os\nwhile True: os.write(1,b'x'*8192); os.write(2,b'e'*8192)"], timeout: 0.1, outputLimit: 128)
precondition(flooding.timedOut && flooding.truncated && flooding.stdout.utf8.count == 128)
print("PASS continuous output cannot prevent the deadline")

let childStart = ProcessInfo.processInfo.systemUptime
let inherited = try InstallerProcess.run("/bin/sh", ["-c", "/bin/sleep 2 & printf 'parent done'"], timeout: 3)
precondition(inherited.status == 0 && inherited.stdout == "parent done" && ProcessInfo.processInfo.systemUptime - childStart < 1.5)
print("PASS inherited child pipes do not hold the installer open")
'''

with tempfile.TemporaryDirectory(prefix='huarun-process-test-') as temporary:
    directory = pathlib.Path(temporary)
    main = directory / 'main.swift'
    main.write_text(SOURCE)
    executable = directory / 'checks'
    subprocess.run(['xcrun', 'swiftc', str(ROOT / 'macos/Runner/InstallerProcess.swift'), str(main), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=15)
