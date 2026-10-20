import copy
import io
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
import unittest
from unittest.mock import Mock, patch
from urllib.error import URLError

from release import (HUB_UPDATES_URL, check_tag, current_commit, main, metadata, publish,
                     release_notes, validate_channel, validate_hub_changelog)


SHA = "a" * 40
PUBSPEC = "name: example\nversion: 0.1.0+1\n"
UPDATES = {
    "release": {
        "publishedVersion": "0.1.0",
        "releases": [
            {"version": version, "changes": [f"Changes for {version}"]}
            for version in ("0.1.0", "2.3.4")
        ],
    },
    "debug": {
        "publishedVersion": None,
        "releases": [{"version": "0.1.0-pre.42", "changes": ["Preview changes"]}],
    },
}


def identity(ref="refs/heads/dev", *, updates=None, **extra):
    return metadata({"GITHUB_REF": ref, "GITHUB_SHA": SHA, "GITHUB_RUN_NUMBER": "42", **extra},
                    PUBSPEC, UPDATES if updates is None else updates)


class MetadataTests(unittest.TestCase):
    def test_dev_is_fixed_pre_with_android_macos_and_windows_packages(self):
        info = identity()
        self.assertEqual((info["tag"], info["prerelease"], info["version"]), ("pre", True, "0.1.0-pre.42"))
        self.assertEqual(info["build_name"], "0.1.0")
        self.assertEqual(info["update_channel"], "debug")
        self.assertEqual(len(info["assets"]), 11)
        self.assertEqual([Path(name).suffix for name in info["assets"]],
                         [".dmg", ".dmg", ".exe", ".zip", ".exe", ".zip",
                          ".apk", ".apk", ".apk", ".json", ".sha256"])
        for architecture in ("amd64", "arm64"):
            for suffix in ("-setup.exe", ".zip"):
                self.assertIn(f'HuarunWin-0.1.0-pre.42-windows-{architecture}{suffix}', info["assets"])

    def test_semantic_tag_overrides_pubspec_version(self):
        info = identity("refs/tags/v2.3.4")
        self.assertEqual((info["tag"], info["build_name"], info["prerelease"]), ("v2.3.4", "2.3.4", False))
        self.assertEqual(info["update_channel"], "release")
        self.assertEqual(info["app_version"], "2.3.4")
        self.assertNotIn("changelog.json", info["assets"])
        self.assertEqual(info["changes"], ["Changes for 2.3.4"])

    def test_tag_requires_matching_changelog_and_canonical_name(self):
        for ref in ("refs/tags/v9.9.9", "refs/tags/release/october", "refs/tags/2.3.4",
                    "refs/tags/v2.3.4-rc.1", "refs/tags/v2.3.4+1", "refs/tags/v02.3.4",
                    "refs/tags/V2.3.4", "refs/tags/v2.3", "refs/tags/v2.3.4.5"):
            with self.subTest(ref=ref), self.assertRaises(ValueError):
                identity(ref)

    def test_future_notes_do_not_change_published_version(self):
        updates = copy.deepcopy(UPDATES)
        info = identity("refs/tags/v2.3.4", updates=updates)
        self.assertEqual(info["app_version"], "2.3.4")
        self.assertEqual(updates, UPDATES)
        self.assertNotIn("changelog", info)

    def test_dev_pre_build_does_not_publish_update_metadata(self):
        info = identity()
        self.assertNotIn("changelog.json", info["assets"])
        self.assertEqual(info["app_version"], "0.1.0-pre.42")
        self.assertEqual(info["changes"], ["Preview changes"])

    def test_dev_without_exact_debug_notes_does_not_use_release_or_base_version_notes(self):
        updates = copy.deepcopy(UPDATES)
        updates["debug"]["releases"] = [{"version": "0.1.0", "changes": ["Different version"]}]
        self.assertEqual(identity(updates=updates)["changes"], [])

    def test_disallow_other_branches_and_reserved_tag(self):
        for ref in ("refs/heads/main", "refs/heads/feature", "refs/tags/pre"):
            with self.assertRaises(ValueError):
                identity(ref)

    def test_reruns_keep_the_build_identity(self):
        self.assertEqual(identity(GITHUB_RUN_ATTEMPT="1"), identity(GITHUB_RUN_ATTEMPT="2"))

    def test_previous_platform_environment_cannot_enable_other_builds(self):
        self.assertEqual(identity(), identity(BUILD_PLATFORMS="macos,ios,android,windows,linux"))

    def test_reject_invalid_build_identity(self):
        for values in ({"GITHUB_SHA": "bad"}, {"GITHUB_RUN_NUMBER": "0"}):
            with self.assertRaises(ValueError):
                identity(**values)


class HubChannelTests(unittest.TestCase):
    def test_validation_accepts_pr_context_without_local_files(self):
        script = Path(__file__).with_name("release.py").resolve()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            env = {key: value for key, value in os.environ.items()
                   if not key.startswith("GITHUB_")}
            env["GITHUB_REF"] = "refs/pull/7/merge"
            result = subprocess.run([sys.executable, str(script), "validate"],
                                    cwd=root, env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((root / "build").exists())

    def test_reject_missing_published_notes_duplicate_versions_and_empty_changes(self):
        for failure in ("missing", "duplicate", "empty", "blank", "invalid_version"):
            data = copy.deepcopy(UPDATES["release"])
            if failure == "missing":
                data["publishedVersion"] = "8.0.0"
            elif failure == "duplicate":
                data["releases"].append(data["releases"][0])
            elif failure == "invalid_version":
                data["releases"][0]["version"] = "0.01.0"
            else:
                data["releases"][0]["changes"] = [] if failure == "empty" else [" "]
            with self.subTest(failure=failure), self.assertRaises(ValueError):
                validate_channel(data)


class HubChangelogTests(unittest.TestCase):
    def setUp(self):
        self.feed = copy.deepcopy(UPDATES)
        self.feed["release"]["publishedVersion"] = None

    def test_prepared_notes_allow_null_or_previous_published_version_without_download_url(self):
        for published in (None, "0.1.0"):
            self.feed["release"]["publishedVersion"] = published
            before = copy.deepcopy(self.feed)
            validate_hub_changelog(self.feed, "2.3.4")
            self.assertEqual(self.feed, before)

    def test_reject_missing_version_wrong_channel_duplicate_notes_and_invalid_changes(self):
        invalid = [None, {}, {"debug": self.feed["release"]},
                   {"release": {"publishedVersion": None, "releases": []}}]
        for changes in (None, [], [" "], [7], "Notes"):
            feed = copy.deepcopy(self.feed)
            feed["release"]["releases"][0]["changes"] = changes
            invalid.append(feed)
        duplicate = copy.deepcopy(self.feed)
        duplicate["release"]["releases"].append(duplicate["release"]["releases"][0])
        invalid.append(duplicate)
        missing_pointer = copy.deepcopy(self.feed)
        del missing_pointer["release"]["publishedVersion"]
        invalid.append(missing_pointer)
        for feed in invalid:
            with self.subTest(feed=feed), self.assertRaises(ValueError):
                validate_hub_changelog(feed, "0.1.0")
        with self.assertRaisesRegex(ValueError, "Missing Hub changelog"):
            validate_hub_changelog(self.feed, "9.9.9")

    def test_preflight_reads_the_public_feed_without_authentication(self):
        with (patch("release.urlopen", return_value=io.BytesIO(json.dumps(self.feed).encode())) as fetch,
              patch("release.Path.read_text", side_effect=AssertionError("Local files must not be read"))):
            self.assertEqual(check_tag("v0.1.0"), "0.1.0")
        request = fetch.call_args.args[0]
        self.assertEqual(request.full_url, HUB_UPDATES_URL)
        self.assertIsNone(request.get_header("Authorization"))
        self.assertEqual(fetch.call_args.kwargs["timeout"], 30)

    def test_network_or_json_failure_does_not_fall_back_to_local_notes(self):
        for error in (URLError("offline"), TimeoutError("timed out")):
            with (patch("release.urlopen", side_effect=error),
                  self.assertRaisesRegex(ValueError, "Cannot validate Hub")):
                check_tag("v0.1.0")
        with (patch("release.urlopen", return_value=io.BytesIO(b"not json")),
              self.assertRaisesRegex(ValueError, "Cannot validate Hub")):
            check_tag("v0.1.0")

    def test_ci_formal_tags_require_hub_notes_but_dev_and_pull_requests_do_not(self):
        for ref in ("refs/tags/v0.1.0", "refs/heads/dev", "refs/pull/7/merge"):
            with (patch("sys.argv", ["release.py", "validate"]),
                  patch.dict(os.environ, {"GITHUB_REF": ref}),
                  patch("release.Path.read_text", side_effect=AssertionError("Local files must not be read")),
                  patch("release.urlopen", return_value=io.BytesIO(b"{}")) as fetch,
                  patch("builtins.print")):
                if ref.startswith("refs/tags/"):
                    with self.assertRaisesRegex(ValueError, "Invalid Hub"):
                        main()
                    fetch.assert_called_once()
                else:
                    main()
                    fetch.assert_not_called()


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.info = identity()
        for name in self.info["assets"]:
            (self.directory / name).write_bytes(b"package")

    def test_missing_package_prevents_any_release_write(self):
        (self.directory / self.info["assets"][0]).unlink()
        api = Mock()
        with self.assertRaises(ValueError):
            publish(api, self.info, self.directory, "https://example.test/run")
        api.request.assert_not_called()

    def test_missing_windows_package_prevents_any_release_write(self):
        (self.directory / f'{self.info["asset_stem"]}-windows-arm64-setup.exe').unlink()
        api = Mock()
        with self.assertRaises(ValueError):
            publish(api, self.info, self.directory, "https://example.test/run")
        api.request.assert_not_called()

    def test_download_badges_link_to_each_package_in_the_exact_release(self):
        for ref, tag in (("refs/heads/dev", "pre"), ("refs/tags/v2.3.4", "v2.3.4")):
            with self.subTest(tag=tag):
                info = identity(ref)
                notes = release_notes(info, "https://github.com/example/app/actions/runs/42")
                for name in info["assets"]:
                    if Path(name).suffix in (".exe", ".zip", ".apk", ".dmg"):
                        self.assertIn(f"https://github.com/example/app/releases/download/{tag}/{name}", notes)
                self.assertIn("logo=github", notes)
                self.assertIn("logo=android", notes)
                self.assertIn("logo=apple", notes)
                self.assertIn("| Windows |", notes)
                self.assertNotIn("/releases/latest/download/", notes)

    def test_old_dev_run_does_not_overwrite_pre(self):
        api = Mock()
        api.request.return_value = {"object": {"type": "commit", "sha": "b" * 40}}
        self.assertFalse(publish(api, self.info, self.directory, "https://example.test/run"))
        api.request.assert_called_once_with("GET", "/git/ref/heads/dev")

    def test_annotated_tags_resolve_to_commit(self):
        api = Mock()
        api.request.side_effect = [{"object": {"type": "tag", "sha": "b" * 40}},
                                   {"object": {"type": "commit", "sha": SHA}}]
        self.assertEqual(current_commit(api, "v1.0.0"), SHA)

    def fake_api(self, fail_upload=False, tag="pre", published=False):
        calls = []
        counter = 100

        def request(method, path, data=None, **kwargs):
            nonlocal counter
            calls.append((method, path, data))
            if path.startswith("/git/ref/"):
                return {"object": {"type": "commit", "sha": SHA}}
            if path == "/releases/tags/" + tag:
                return {"id": 1, "draft": tag != "pre" and not published,
                        "upload_url": "https://uploads.github.com/test{?name}",
                        "body": SHA if published else "",
                        "assets": ([{"id": i + 5, "name": name} for i, name in enumerate(self.info["assets"])]
                                   if published else [{"id": 5, "name": "previous.zip"}])}
            if method == "POST" and path.startswith("https://uploads"):
                counter += 1
                if fail_upload and counter == 102:
                    raise RuntimeError("upload interrupted")
                return {"id": counter}
            return {}

        return Mock(request=request), calls

    def test_upload_failure_keeps_previous_release_and_tag(self):
        api, calls = self.fake_api(fail_upload=True)
        with self.assertRaises(RuntimeError):
            publish(api, self.info, self.directory, "https://example.test/run")
        self.assertIn(("DELETE", "/releases/assets/101", None), calls)
        self.assertFalse(any(method == "PATCH" for method, _, _ in calls))
        self.assertNotIn(("DELETE", "/releases/assets/5", None), calls)

    def test_replaces_old_assets_only_after_publication(self):
        api, calls = self.fake_api()
        self.assertTrue(publish(api, self.info, self.directory, "https://example.test/run"))
        patch = next(i for i, call in enumerate(calls) if call[0:2] == ("PATCH", "/releases/1"))
        delete = calls.index(("DELETE", "/releases/assets/5", None))
        self.assertGreater(delete, patch)
        self.assertEqual(calls[patch][2]["prerelease"], True)
        self.assertEqual(calls[patch][2]["make_latest"], "false")
        self.assertIn("Preview changes", calls[patch][2]["body"])

    def test_tag_uses_hub_notes_without_uploading_a_changelog_snapshot(self):
        self.info = identity("refs/tags/v2.3.4")
        for name in self.info["assets"]:
            (self.directory / name).write_bytes(b"package")
        api, calls = self.fake_api(tag="v2.3.4")
        self.assertTrue(publish(api, self.info, self.directory, "https://example.test/run"))
        uploads = [(i, path) for i, (method, path, _) in enumerate(calls)
                   if method == "POST" and path.startswith("https://uploads")]
        patch = next(i for i, call in enumerate(calls) if call[0:2] == ("PATCH", "/releases/1"))
        self.assertEqual(len(uploads), len(self.info["assets"]))
        self.assertTrue(all(i < patch and "changelog.json" not in path for i, path in uploads))
        self.assertIn("Changes for 2.3.4", calls[patch][2]["body"])

    def test_repeat_tag_publication_preserves_published_notes_and_packages(self):
        self.info = identity("refs/tags/v2.3.4")
        for name in self.info["assets"]:
            (self.directory / name).write_bytes(b"package")
        api, calls = self.fake_api(tag="v2.3.4", published=True)
        self.assertTrue(publish(api, self.info, self.directory, "https://example.test/new-run"))
        self.assertTrue(all(method == "GET" for method, _, _ in calls))

    def test_published_tag_with_other_source_or_incomplete_assets_is_not_modified(self):
        self.info = identity("refs/tags/v2.3.4")
        for name in self.info["assets"]:
            (self.directory / name).write_bytes(b"package")
        for body, assets in (("b" * 40, self.info["assets"]), (SHA, self.info["assets"][:-1])):
            api = Mock()
            api.request.side_effect = [
                {"object": {"type": "commit", "sha": SHA}},
                {"id": 1, "draft": False, "body": body, "assets": [{"name": name} for name in assets]},
            ]
            with self.assertRaises(ValueError):
                publish(api, self.info, self.directory, "https://example.test/new-run")
            self.assertTrue(all(call.args[0] == "GET" for call in api.request.call_args_list))


if __name__ == "__main__":
    unittest.main()
