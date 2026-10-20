"""Check and build with the project's pinned Flutter SDK."""

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


def flutter_command():
    if os.environ.get("GITHUB_ACTIONS") == "true":
        executable = shutil.which("flutter")
        if not executable:
            raise ValueError("Set up Flutter with flutter-action before building")
        return [executable]
    executable = shutil.which("fvm")
    if not executable:
        raise ValueError("Install FVM and expose it in PATH")
    return [executable, "flutter"]


def flutter(*args):
    run(*flutter_command(), *args)


def setup():
    version = json.loads((ROOT / ".fvmrc").read_text())["flutter"]
    command = flutter_command()
    if os.environ.get("GITHUB_ACTIONS") != "true":
        run(command[0], "install", version, "--skip-pub-get")
    # A fresh Windows SDK prints bootstrap progress before any machine output.
    flutter("--version")
    result = subprocess.run([*command, "--version", "--machine"],
                            text=True, capture_output=True, check=True)
    installed = json.loads(result.stdout)
    if installed["frameworkVersion"] != version:
        raise ValueError(f"Flutter SDK must match .fvmrc version {version}")
    print(f"Flutter {version} verified ({installed['frameworkRevision']})")


def package(architecture):
    if architecture not in ("arm64", "amd64"):
        raise ValueError("macOS package architecture must be arm64 or amd64")
    info = json.loads((ROOT / "build/release/metadata.json").read_text())
    OUTPUT.mkdir(parents=True, exist_ok=True)
    flags = ("--release", "--build-name", info["build_name"], "--build-number", info["build_number"],
             f'--dart-define=HUARUNWIN_VERSION={info["app_version"]}',
             f'--dart-define=HUARUNWIN_UPDATE_CHANNEL={info["update_channel"]}')
    os.environ["FLUTTER_MACOS_ARM64_ONLY"] = "false"
    os.environ["FLUTTER_XCODE_ARCHS"] = "arm64" if architecture == "arm64" else "x86_64"
    os.environ["FLUTTER_XCODE_EXCLUDED_ARCHS"] = "x86_64" if architecture == "arm64" else "arm64"
    flutter("build", "macos", *flags)
    run("bash", ROOT / "tool/ci/package_macos.sh",
        env={**os.environ, "ASSET_STEM": info["asset_stem"] + f"-macos-{architecture}",
             "MACOS_ARCH": architecture})


def main():
    os.chdir(ROOT)
    command = sys.argv[1] if len(sys.argv) >= 2 else ""
    if command == "package" and len(sys.argv) == 3:
        package(sys.argv[2])
        return
    if len(sys.argv) != 2:
        raise ValueError("Usage: python tool/ci/build.py setup|deps|verify|package <arm64|amd64>")
    if command == "setup":
        setup()
    elif command == "deps":
        flutter("pub", "get", "--enforce-lockfile")
    elif command == "verify":
        flutter("analyze")
        flutter("test")
    else:
        raise ValueError("Usage: python tool/ci/build.py setup|deps|verify|package <arm64|amd64>")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        sys.exit(f"Build failed: {error}")
