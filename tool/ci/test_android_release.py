import unittest
from pathlib import Path
import subprocess
import tempfile
from unittest.mock import patch
import zipfile

from android_release import certificate_digest, package, property_value, verify_apk


class AndroidReleaseTests(unittest.TestCase):
    def test_missing_secrets_fail_before_building_or_writing_credentials(self):
        with patch.dict("os.environ", {}, clear=True), patch("android_release.subprocess.run") as run:
            with self.assertRaisesRegex(ValueError, "Configure GitHub signing Secrets"):
                package()
            run.assert_not_called()

    def test_certificate_digest_is_exact_not_a_label_or_partial_digest(self):
        self.assertEqual(certificate_digest(":".join(["AB"] * 32)), "ab" * 32)
        for value in ("", "release", "ab" * 31, "zz" * 32):
            with self.assertRaises(ValueError):
                certificate_digest(value)

    def test_java_properties_cannot_be_injected_by_a_password(self):
        escaped = property_value(" a=b\\c\nstoreFile=other\r\t密")
        self.assertEqual(escaped, "\\ a\\=b\\\\c\\nstoreFile\\=other\\r\\t\\u5bc6")
        self.assertNotIn("\n", escaped)

    def test_debug_channel_accepts_only_its_pinned_debug_certificate(self):
        certificate = "ab" * 32
        signature = (f"Number of signers: 1\nSigner #1 certificate SHA-256 digest: {certificate}\n"
                     "Signer #1 certificate DN: CN=Android Debug, O=Android\n")
        identity = "package: name='win.huarun.huarunwin' versionCode='2042' versionName='0.1.0-pre.42'\n"
        with tempfile.TemporaryDirectory() as directory:
            apk = Path(directory) / "app.apk"
            with zipfile.ZipFile(apk, "w") as archive:
                archive.writestr("lib/arm64-v8a/libflutter.so", b"fixture")
            for expected, valid in [(certificate, True), ("cd" * 32, False)]:
                with self.subTest(expected=expected), \
                        patch("android_release.sdk_tool", side_effect=Path), \
                        patch("android_release.subprocess.run", side_effect=[
                            subprocess.CompletedProcess([], 0, stdout=signature),
                            subprocess.CompletedProcess([], 0, stdout=identity),
                        ]):
                    if valid:
                        record = verify_apk(apk, "0.1.0-pre.42", 42, expected, "arm64-v8a", channel="debug")
                        self.assertEqual(record["certificateSha256"], certificate)
                    else:
                        with self.assertRaises(ValueError):
                            verify_apk(apk, "0.1.0-pre.42", 42, expected, "arm64-v8a", channel="debug")

    def test_actual_apk_metadata_must_match_certificate_version_and_architecture(self):
        certificate = "ab" * 32
        signature = f"Number of signers: 1\nSigner #1 certificate SHA-256 digest: {certificate}\n"
        identity = "package: name='win.huarun.huarunwin' versionCode='2042' versionName='0.1.0-pre.42'\n"
        with tempfile.TemporaryDirectory() as directory:
            apk = Path(directory) / "app.apk"
            with zipfile.ZipFile(apk, "w") as archive:
                archive.writestr("lib/arm64-v8a/libflutter.so", b"fixture")
            cases = [
                (signature, identity, "arm64-v8a", True),
                (signature.replace("Signer #1", "V2 Signer:"), identity, "arm64-v8a", True),
                (signature.replace("Signer #1", "V2 Signer:") +
                 f"V3.1 Signer: certificate SHA-256 digest: {certificate}\n", identity, "arm64-v8a", True),
                (signature.replace("Number of signers: 1", "Number of signers: 2"), identity, "arm64-v8a", False),
                (signature.replace(certificate, "cd" * 32), identity, "arm64-v8a", False),
                (signature + "Signer #1 certificate DN: CN=Android Debug\n", identity, "arm64-v8a", False),
                (signature, identity.replace("2042", "2041"), "arm64-v8a", False),
                (signature, identity.replace("0.1.0-pre.42", "0.1.0"), "arm64-v8a", False),
                (signature, identity.replace("win.huarun.huarunwin", "org.example.other"), "arm64-v8a", False),
                (signature, identity.replace("2042", "1042"), "armeabi-v7a", False),
            ]
            for signed, badging, abi, valid in cases:
                with self.subTest(signed=signed, badging=badging, abi=abi), \
                        patch("android_release.sdk_tool", side_effect=Path), \
                        patch("android_release.subprocess.run", side_effect=[
                            subprocess.CompletedProcess([], 0, stdout=signed),
                            subprocess.CompletedProcess([], 0, stdout=badging),
                        ]):
                    if valid:
                        record = verify_apk(apk, "0.1.0-pre.42", 42, certificate, abi)
                        self.assertEqual(record["versionCode"], 2042)
                        self.assertEqual(record["certificateSha256"], certificate)
                    else:
                        with self.assertRaises(ValueError):
                            verify_apk(apk, "0.1.0-pre.42", 42, certificate, abi)


if __name__ == "__main__":
    unittest.main()
