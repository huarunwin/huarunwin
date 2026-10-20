"""Build Android releases with an existing signing identity and verify each APK."""

import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parents[2]
APPLICATION_ID = "win.huarun.huarunwin"
ABIS = {"armeabi-v7a": "armv7", "arm64-v8a": "arm64", "x86_64": "x64"}
# Flutter 3.47.6 split APK codes: ABI_VERSION * 1000 + build number.
# Recheck the pinned Flutter Gradle plugin when upgrading .fvmrc.
ABI_VERSION_OFFSETS = {"armeabi-v7a": 1000, "arm64-v8a": 2000, "x86_64": 4000}
SECRETS = ("ANDROID_KEYSTORE_BASE64", "ANDROID_KEYSTORE_PASSWORD", "ANDROID_KEY_ALIAS",
           "ANDROID_KEY_PASSWORD", "ANDROID_SIGNING_CERT_SHA256")


def certificate_digest(value: str) -> str:
    digest = value.replace(":", "").strip().lower()
    if not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise ValueError("ANDROID_SIGNING_CERT_SHA256 must be the release certificate SHA-256")
    return digest


def property_value(value: str) -> str:
    # java.util.Properties reads Latin-1 and treats backslashes as escapes.
    encoded = []
    for character in value:
        if character in "\\:=#! ":
            encoded.append("\\" + character)
        elif character == "\n":
            encoded.append("\\n")
        elif character == "\r":
            encoded.append("\\r")
        elif character == "\t":
            encoded.append("\\t")
        elif ord(character) > 126:
            units = character.encode("utf-16-be")
            encoded.extend(f"\\u{int.from_bytes(units[i:i + 2], 'big'):04x}"
                           for i in range(0, len(units), 2))
        else:
            encoded.append(character)
    return "".join(encoded)


def sdk_tool(name: str) -> Path:
    sdk = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
    if not sdk:
        raise ValueError("Set ANDROID_HOME to the Android SDK")
    candidates = [path for path in (Path(sdk) / "build-tools").glob(f"*/{name}")
                  if re.fullmatch(r"\d+(?:\.\d+)*", path.parent.name)]
    if not candidates:
        raise ValueError(f"Android SDK build-tools must provide {name}")
    return max(candidates, key=lambda path: tuple(map(int, path.parent.name.split("."))))


def verify_apk(apk: Path, version: str, build_number: int,
               expected_certificate: str, abi: str, *, channel: str = "release") -> dict:
    if channel not in {"debug", "release"}:
        raise ValueError("Unknown Android signing channel")
    result = subprocess.run([str(sdk_tool("apksigner")), "verify", "--verbose", "--print-certs", str(apk)],
                            text=True, capture_output=True, check=True)
    signer_count = re.search(r"^Number of signers:\s*(\d+)\s*$", result.stdout, re.MULTILINE)
    # Recent build-tools print scheme-specific labels, e.g. "V2 Signer:".
    # A single signer may be repeated across schemes; never include a source stamp.
    certificates = {certificate_digest(value) for value in re.findall(
        r"^(?:Signer #\d+|V\d+(?:\.\d+)? Signer(?: #\d+)?):? certificate SHA-256 digest: ([0-9a-fA-F]+)\s*$",
        result.stdout, re.MULTILINE | re.IGNORECASE)}
    if not signer_count or int(signer_count[1]) != 1 or certificates != {expected_certificate}:
        raise ValueError("APK signing certificate does not match the configured release identity")
    if channel == "release" and re.search(
            r"certificate DN:.*CN=Android Debug(?:,|$)", result.stdout, re.IGNORECASE | re.MULTILINE):
        raise ValueError("A debug signing certificate cannot be published to the release channel")
    badging = subprocess.run([str(sdk_tool("aapt")), "dump", "badging", str(apk)],
                             text=True, capture_output=True, check=True).stdout
    package = re.search(r"^package: name='([^']+)' versionCode='(\d+)' versionName='([^']+)'", badging, re.MULTILINE)
    if (not package or package[1] != APPLICATION_ID or package[3] != version
            or int(package[2]) != build_number + ABI_VERSION_OFFSETS[abi]):
        raise ValueError("APK application ID, version name or version code does not match this release")
    with zipfile.ZipFile(apk) as archive:
        architectures = {name.split('/')[1] for name in archive.namelist()
                         if name.startswith('lib/') and name.endswith('.so')}
    if architectures != {abi}:
        raise ValueError("APK native architecture does not match its asset name")
    return {"file": apk.name, "platform": "Android", "arch": ABIS[abi],
            "applicationId": package[1], "version": package[3], "versionCode": int(package[2]),
            "certificateSha256": expected_certificate,
            "sha256": hashlib.sha256(apk.read_bytes()).hexdigest()}


def package() -> None:
    missing = [name for name in SECRETS if not os.environ.get(name)]
    if missing:
        raise ValueError("Configure GitHub signing Secrets before publishing: " + ", ".join(missing))
    expected = certificate_digest(os.environ["ANDROID_SIGNING_CERT_SHA256"])
    info = json.loads((ROOT / "build/release/metadata.json").read_text())
    if info["update_channel"] not in {"debug", "release"}:
        raise ValueError("Unknown Android signing channel")
    properties = ROOT / "android/key.properties"
    if properties.exists():
        raise ValueError("Refusing to overwrite android/key.properties; use a clean CI checkout")
    fvm = shutil.which("fvm")
    if not fvm:
        raise ValueError("Install FVM before building")
    output = ROOT / "build/release/packages"
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="huarunwin-signing-") as directory:
        store = Path(directory) / "release.jks"
        store.write_bytes(base64.b64decode("".join(os.environ["ANDROID_KEYSTORE_BASE64"].split()), validate=True))
        store.chmod(0o600)
        values = {"storeFile": str(store), "storePassword": os.environ["ANDROID_KEYSTORE_PASSWORD"],
                  "keyAlias": os.environ["ANDROID_KEY_ALIAS"], "keyPassword": os.environ["ANDROID_KEY_PASSWORD"]}
        created = False
        try:
            with properties.open("x", encoding="ascii") as stream:
                created = True
                properties.chmod(0o600)
                stream.write("".join(f"{key}={property_value(value)}\n" for key, value in values.items()))
            subprocess.run([fvm, "flutter", "build", "apk", "--release", "--no-pub", "--split-per-abi",
                            "--build-name", info["app_version"], "--build-number", info["build_number"],
                            f'--dart-define=HUARUNWIN_VERSION={info["app_version"]}',
                            f'--dart-define=HUARUNWIN_UPDATE_CHANNEL={info["update_channel"]}'],
                           cwd=ROOT, check=True)
            verified = []
            for abi in ABIS:
                source = ROOT / f"build/app/outputs/flutter-apk/app-{abi}-release.apk"
                record = verify_apk(source, info["app_version"], int(info["build_number"]), expected, abi,
                                    channel=info["update_channel"])
                target = output / f'{info["asset_stem"]}-android-{abi}.apk'
                shutil.copyfile(source, target)
                record["file"] = target.name
                verified.append(record)
            (output / f'{info["asset_stem"]}-android-signing.json').write_text(
                json.dumps({"channel": info["update_channel"], "packages": verified}, indent=2) + "\n")
        finally:
            if created:
                properties.unlink(missing_ok=True)


if __name__ == "__main__":
    try:
        package()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        # Never include captured tool output or signing values in CI errors.
        sys.exit(str(error) if isinstance(error, ValueError) else "Android release build or verification failed")
