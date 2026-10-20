"""Release metadata and GitHub publication; no credentials are stored on disk."""

import hashlib
import json
import os
from pathlib import Path
import re
import sys
from urllib.error import HTTPError
from urllib.parse import quote, urlencode
from urllib.request import Request, urlopen


OUTPUT = Path("build/release")
NUMBER = r"(?:0|[1-9][0-9]*)"
IDENTIFIER = rf"(?:{NUMBER}|[0-9]*[A-Za-z-][0-9A-Za-z-]*)"
VERSION = rf"({NUMBER}\.{NUMBER}\.{NUMBER})(-{IDENTIFIER}(?:\.{IDENTIFIER})*)?"
SEMVER = VERSION + r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
PACKAGES = ("macos-arm64.dmg", "macos-amd64.dmg", "android-armeabi-v7a.apk",
            "android-arm64-v8a.apk", "android-x86_64.apk", "android-signing.json")


def validate_changelog(data):
    if not isinstance(data, dict):
        raise ValueError("changelog.json must be an object")
    published = data.get("publishedVersion")
    if not isinstance(published, str) or not re.fullmatch(VERSION, published):
        raise ValueError("publishedVersion must be a semantic version without build metadata")
    releases = data.get("releases")
    if not isinstance(releases, list):
        raise ValueError("changelog.json must contain a releases array")
    versions = set()
    for entry in releases:
        if not isinstance(entry, dict):
            raise ValueError("Each changelog entry must be an object")
        version = entry.get("version")
        if not isinstance(version, str) or not re.fullmatch(VERSION, version):
            raise ValueError("Each changelog version must be a semantic version without build metadata")
        if version in versions:
            raise ValueError(f"Duplicate changelog version: {version}")
        versions.add(version)
        changes = entry.get("changes")
        if (not isinstance(changes, list) or not changes
                or any(not isinstance(item, str) or not item.strip() for item in changes)):
            raise ValueError(f"Changelog for {version} must contain non-empty changes")
    if published not in versions:
        raise ValueError(f"publishedVersion {published} has no changelog")
    return data


def metadata(env, pubspec, changelog):
    validate_changelog(changelog)
    match = re.search(r"^version:\s*[\"']?([^\s\"']+)", pubspec, re.MULTILINE)
    base = re.fullmatch(SEMVER, match[1]) if match else None
    if not base:
        raise ValueError("pubspec.yaml must contain a semantic version")
    ref = env["GITHUB_REF"]
    if ref == "refs/heads/main":
        tag, pre, version = "pre", True, base[1]
        app_version = f'{version}-pre.{env["GITHUB_RUN_NUMBER"]}'
        notes_version = match[1].split("+", 1)[0]
    elif ref.startswith("refs/tags/") and ref != "refs/tags/pre":
        tag = ref.removeprefix("refs/tags/")
        parsed = re.fullmatch("v" + VERSION, tag)
        if not parsed:
            raise ValueError("Release tags must use v<version>, for example v0.1.0")
        notes_version = app_version = tag[1:]
        version, pre = parsed[1], bool(parsed[2])
        if not any(entry["version"] == notes_version for entry in changelog["releases"]):
            raise ValueError(f"Missing changelog for tag {tag}; add version {notes_version} to changelog.json")
    else:
        raise ValueError("Only main and non-reserved tags can be released")
    sha = env["GITHUB_SHA"]
    number = env["GITHUB_RUN_NUMBER"]
    if not re.fullmatch(r"[0-9a-f]{40}", sha) or not number.isdecimal() or int(number) < 1:
        raise ValueError("Invalid GitHub build identity")
    # Pre-release versions include the run number; reruns keep the same names.
    # The source commit and build record remain in the release notes.
    stem = f"HuarunWin-{app_version}"
    changes = next((entry["changes"] for entry in changelog["releases"]
                    if entry["version"] == notes_version), [])
    return dict(tag=tag, prerelease=pre, sha=sha, build_name=version,
                build_number=number, asset_stem=stem, app_version=app_version,
                version=app_version if tag == "pre" else tag,
                changes=changes, changelog=changelog,
                update_channel="debug" if pre else "release",
                assets=[f"{stem}-{suffix}" for suffix in PACKAGES]
                + (["changelog.json"] if tag != "pre" else [])
                + [f"{stem}.sha256"])


class GitHub:
    def __init__(self, repo, token):
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
            raise ValueError("Invalid repository")
        self.root = f"https://api.github.com/repos/{repo}"
        self.token = token

    def request(self, method, path, data=None, missing_ok=False, asset=None):
        url = path if path.startswith("https://") else self.root + path
        headers = {"Authorization": f"Bearer {self.token}",
                   "Accept": "application/vnd.github+json",
                   "X-GitHub-Api-Version": "2022-11-28"}
        if asset:
            headers.update({"Content-Type": "application/octet-stream",
                            "Content-Length": str(asset.stat().st_size)})
            with asset.open("rb") as stream:
                return self._send(Request(url, data=stream, headers=headers, method=method))
        if data is not None:
            data = json.dumps(data).encode()
            headers["Content-Type"] = "application/json"
        return self._send(Request(url, data=data, headers=headers, method=method), missing_ok)

    @staticmethod
    def _send(request, missing_ok=False):
        try:
            with urlopen(request, timeout=120) as response:
                content = response.read()
                return json.loads(content) if content else None
        except HTTPError as error:
            if missing_ok and error.code == 404:
                return None
            raise RuntimeError(f"GitHub API returned HTTP {error.code}") from None


def current_commit(api, tag):
    ref = "heads/main" if tag == "pre" else "tags/" + quote(tag, safe="")
    obj = api.request("GET", "/git/ref/" + ref)["object"]
    for _ in range(8):
        if obj["type"] == "commit":
            return obj["sha"]
        if obj["type"] != "tag":
            break
        obj = api.request("GET", "/git/tags/" + obj["sha"])["object"]
    raise ValueError("Tag does not point to a commit")


def publish(api, info, directory, run_url):
    paths = [directory / name for name in info["assets"]]
    for path in paths:
        if not path.is_file() or not path.stat().st_size:
            raise ValueError(f"Missing or empty release asset: {path.name}")
    if current_commit(api, info["tag"]) != info["sha"]:
        print("Source has advanced; skipping this outdated release.")
        return False

    release = api.request("GET", "/releases/tags/" + quote(info["tag"], safe=""), missing_ok=True)
    created = release is None
    if created:
        release = api.request("POST", "/releases", {
            "tag_name": info["tag"], "target_commitish": info["sha"], "draft": True,
            "prerelease": info["prerelease"], "name": info["version"],
        })
    endpoint = f'/releases/{release["id"]}'
    old_assets = release.get("assets", [])
    uploaded = []
    try:
        existing_names = {asset["name"] for asset in old_assets}
        body = release.get("body") or ""
        if info["tag"] != "pre" and not release.get("draft") and "changelog.json" in existing_names:
            if info["sha"] not in body:
                raise ValueError("This version is already published from a different commit; use a new version")
            print("This version is already published; retaining its packages and changelog.")
            return True
        if (set(info["assets"]).issubset(existing_names) and not release.get("draft")
                and run_url in body and info["sha"] in body):
            for asset in old_assets:
                if asset["name"] not in info["assets"]:
                    api.request("DELETE", f'/releases/assets/{asset["id"]}')
            print("This build is already published.")
            return True
        if existing_names.intersection(info["assets"]):
            raise ValueError("Incomplete release with conflicting assets; inspect it before retrying")
        for path in paths:
            upload = release["upload_url"].split("{", 1)[0]
            asset = api.request("POST", upload + "?" + urlencode({"name": path.name}), asset=path)
            uploaded.append(asset["id"])
        if current_commit(api, info["tag"]) != info["sha"]:
            raise ValueError("Source changed during upload; previous release retained")
    except Exception:
        # New uploads may fail, but the last published build remains available.
        if created:
            api.request("DELETE", endpoint)
        else:
            for asset_id in uploaded:
                api.request("DELETE", f"/releases/assets/{asset_id}")
        raise

    if info["tag"] == "pre":
        ref = api.request("GET", "/git/ref/tags/pre", missing_ok=True)
        if ref:
            api.request("PATCH", "/git/refs/tags/pre", {"sha": info["sha"], "force": True})
        else:
            api.request("POST", "/git/refs", {"ref": "refs/tags/pre", "sha": info["sha"]})
    changes = "\n".join(f"- {change}" for change in info["changes"])
    changelog_notes = f"## 更新日志\n\n{changes}\n\n" if changes else ""
    download_root = run_url.split("/actions/runs/", 1)[0] + "/releases/download/" + quote(info["tag"], safe="")
    downloads = []
    for platform, architecture, suffix in (
        ("Android", "ARM64", "android-arm64-v8a.apk"),
        ("Android", "ARMv7", "android-armeabi-v7a.apk"),
        ("Android", "x86_64", "android-x86_64.apk"),
        ("macOS 13+", "Apple Silicon", "macos-arm64.dmg"),
        ("macOS 13+", "Intel", "macos-amd64.dmg"),
    ):
        name = f'{info["asset_stem"]}-{suffix}'
        label = "DMG" if suffix.endswith(".dmg") else "APK"
        downloads.append(f"| {platform} | {architecture} | [{label}]({download_root}/{name}) |")
    notes = (f"{changelog_notes}## 下载\n\n| 平台 | 架构 | 安装包 |\n| --- | --- | --- |\n"
             + "\n".join(downloads)
             + f'\n\n源码：`{info["sha"]}` · [构建记录]({run_url})\n\n'
             "证书指纹见 android-signing.json 附件，文件校验值见 .sha256 附件。")
    api.request("PATCH", endpoint, {
        "name": "预发布 · " + info["version"] if info["tag"] == "pre" else info["tag"],
        "body": notes, "draft": False, "prerelease": info["prerelease"],
        "make_latest": "false" if info["prerelease"] else "legacy",
    })
    # Remove obsolete packages only after the new build has been published.
    for asset in old_assets:
        api.request("DELETE", f'/releases/assets/{asset["id"]}')
    return True


def main():
    command = sys.argv[1] if len(sys.argv) == 2 else ""
    if command == "validate":
        validate_changelog(json.loads(Path("changelog.json").read_text()))
        print("Changelog is valid.")
    elif command == "metadata":
        info = metadata(os.environ, Path("pubspec.yaml").read_text(),
                        json.loads(Path("changelog.json").read_text()))
        OUTPUT.mkdir(parents=True, exist_ok=True)
        (OUTPUT / "metadata.json").write_text(json.dumps(info, ensure_ascii=False, indent=2) + "\n")
        if os.environ.get("GITHUB_OUTPUT"):
            with open(os.environ["GITHUB_OUTPUT"], "a") as output:
                for key in ("build_name", "build_number", "asset_stem", "update_channel"):
                    output.write(f"{key}={info[key]}\n")
                output.write(f'android_signing_prefix=ANDROID_{info["update_channel"].upper()}\n')
        print(f'Release: {info["tag"]}; version: {info["version"]}; native version: {info["build_name"]}')
    elif command == "publish":
        info = json.loads((OUTPUT / "metadata.json").read_text())
        # Recompute identity instead of trusting metadata left by a previous job.
        if info != metadata(os.environ, Path("pubspec.yaml").read_text(),
                            json.loads(Path("changelog.json").read_text())):
            raise ValueError("Release metadata does not match this run")
        repo = os.environ["GITHUB_REPOSITORY"]
        url = f'https://github.com/{repo}/actions/runs/{os.environ["GITHUB_RUN_ID"]}'
        packages = OUTPUT / "packages"
        if "changelog.json" in info["assets"]:
            (packages / "changelog.json").write_text(
                json.dumps(info["changelog"], ensure_ascii=False, indent=2) + "\n")
        with (packages / info["assets"][-1]).open("w") as checksums:
            for name in info["assets"][:-1]:
                with (packages / name).open("rb") as asset:
                    digest = hashlib.sha256()
                    for chunk in iter(lambda: asset.read(1024 * 1024), b""):
                        digest.update(chunk)
                checksums.write(f"{digest.hexdigest()}  {name}\n")
        result = publish(GitHub(repo, os.environ["GH_TOKEN"]), info, packages, url)
        if os.environ.get("GITHUB_STEP_SUMMARY"):
            with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
                summary.write(f'[Release](https://github.com/{repo}/releases/tag/{quote(info["tag"], safe="")})\n'
                              if result else "源码已有更新，本次未覆盖 Release。\n")
    else:
        raise ValueError("Usage: python3 tool/ci/release.py validate|metadata|publish")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        sys.exit(f"Release failed: {error}")
