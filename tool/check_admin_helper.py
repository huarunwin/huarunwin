#!/usr/bin/env python3
"""Check the production XPC authentication and path guards without root access."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    if sys.platform != "darwin" or os.geteuid() == 0:
        sys.exit("Run as an ordinary user on macOS.")
    root = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="huarun-admin-check-") as temporary:
        executable = Path(temporary) / "AdminHelperQA"
        sources = ["tool/admin_helper_qa.swift", "macos/Installer/InstallerOperations.swift",
                   "macos/Installer/AdminService.swift", "macos/Runner/AdminServiceProtocol.swift",
                   "macos/Runner/InstallerProcess.swift"]
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-O", *[str(root / p) for p in sources],
                        "-o", str(executable)], check=True, timeout=120)
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--identifier",
                        "org.example.huarun-admin-qa", str(executable)], check=True)
        subprocess.run([str(executable), *sys.argv[1:]], check=True, timeout=45)


if __name__ == "__main__":
    main()
