"""Build universal macOS packages with the project's pinned Flutter SDK."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "build/release/packages"


def run(*args, **kwargs):
    subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def flutter(*args):
    fvm = shutil.which("fvm")
    if not fvm:
        raise ValueError("Install FVM and expose it in PATH")
    run(fvm, "flutter", *args)


def setup():
    version = json.loads((ROOT / ".fvmrc").read_text())["flutter"]
    fvm = shutil.which("fvm")
    if not fvm:
        raise ValueError("Install FVM and expose it in PATH")
    run(fvm, "install", version, "--skip-pub-get")
    flutter("--version")


def package():
    info = json.loads((ROOT / "build/release/metadata.json").read_text())
    OUTPUT.mkdir(parents=True, exist_ok=True)
    flags = ("--release", "--build-name", info["build_name"], "--build-number", info["build_number"],
             f'--dart-define=HUARUNWIN_VERSION={info["app_version"]}',
             f'--dart-define=HUARUNWIN_UPDATE_CHANNEL={info["update_channel"]}')
    os.environ["FLUTTER_MACOS_ARM64_ONLY"] = "false"
    flutter("build", "macos", *flags)
    run("bash", ROOT / "tool/ci/package_macos.sh",
        env={**os.environ, "ASSET_STEM": info["asset_stem"] + "-macos-universal"})


def main():
    os.chdir(ROOT)
    command = sys.argv[1] if len(sys.argv) == 2 else ""
    if command == "setup":
        setup()
    elif command == "deps":
        flutter("pub", "get", "--enforce-lockfile")
    elif command == "verify":
        flutter("analyze")
        flutter("test")
    elif command == "package":
        package()
    else:
        raise ValueError("Usage: python tool/ci/build.py setup|deps|verify|package")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        sys.exit(f"Build failed: {error}")
