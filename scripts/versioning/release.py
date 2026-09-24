"""Publish original, verified candidate artifacts; never rebuild or replace assets."""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import tempfile
import urllib.parse
import zipfile

from .build import candidate_by_id, certificate, file_digest, inspect_package
from .github import GitHub, json_text
from .prepare import stable_release
from .rules import CANDIDATE_PATH, Git, VersionError, package_version, version_tuple

FILENAMES = {"android": "app-release.apk", "ios": "OViewer.ipa"}


def require(condition: bool, message: str):
    if not condition:
        raise VersionError(message)


def validate_run(run: dict, workflow: dict, repository: str):
    require(run["workflow_id"] == workflow["id"], "Run belongs to the wrong workflow")
    require(run.get("repository", {}).get("full_name") == repository, "Run is from another repository")
    require(run.get("head_repository", {}).get("full_name") == repository, "Run head is from another repository")
    require(run["status"] == "completed" and run["conclusion"] == "success", "Build run did not finish successfully")
    require(run["event"] == "workflow_dispatch", "Only registered candidate dispatches may be published; PR builds are forbidden")
    require(not run.get("pull_requests"), "A pull request run cannot be published")


def artifact(api, artifacts, name):
    matches = [a for a in artifacts if a["name"] == name]
    require(len(matches) == 1, f"Expected exactly one artifact named {name}")
    item = matches[0]
    require(not item["expired"], f"Artifact {name} has expired; rebuild the same registered candidate")
    return api.request(f"/actions/artifacts/{item['id']}/zip", binary=True)


def read_build(api, platform, run_id, folder):
    workflow = api.request(f"/actions/workflows/build_{platform}.yml")
    run = api.request(f"/actions/runs/{run_id}")
    validate_run(run, workflow, api.repository)
    artifacts = list(api.pages(f"/actions/runs/{run_id}/artifacts", "artifacts"))
    raw = artifact(api, artifacts, "build-metadata")
    with zipfile.ZipFile(io.BytesIO(raw)) as archive:
        require(archive.namelist() == ["build-metadata.json"], "Unexpected metadata archive content")
        metadata = json.loads(archive.read("build-metadata.json"))
    require(metadata.get("schema") == 1, "Unsupported build metadata schema")
    require(metadata.get("platform") == platform, "Metadata platform mismatch")
    require(metadata.get("run_id") == int(run_id), "Metadata run ID mismatch")
    require(metadata.get("run_attempt") == run["run_attempt"], "Metadata is from an earlier run attempt")
    filename = FILENAMES[platform]
    require(metadata.get("filename") == filename, "Unexpected package filename")
    destination = folder / filename
    destination.write_bytes(artifact(api, artifacts, filename))
    for key, value in file_digest(destination).items():
        require(metadata.get(key) == value, f"{platform} artifact {key} mismatch")
    require(run.get("display_title") == f"{platform} / {metadata['candidate_id']}", "Run title does not identify the candidate")
    package = inspect_package(destination, platform, os.environ.get("ANDROID_SIGNING_CERT_SHA256"))
    for key, value in package.items():
        require(metadata.get(key) == value, f"{platform} installed package {key} disagrees with metadata")
    return metadata, destination


def validate_pair(android, ios, candidate, version):
    for metadata in (android, ios):
        for key in ("candidate_id", "build_sha", "source_sha", "version", "build_number"):
            require(metadata.get(key) == candidate[key], f"Candidate/platform {key} mismatch")
    require(version == "v" + candidate["version"], "Release version does not match the candidate")


def validate_tag(api, version, build_sha):
    ref = api.optional("/git/ref/tags/" + urllib.parse.quote(version, safe=""))
    if ref:
        obj = ref["object"]
        for _ in range(8):
            if obj["type"] != "tag":
                break
            obj = api.request(f"/git/tags/{obj['sha']}")["object"]
        require(obj["type"] == "commit" and obj["sha"] == build_sha, "Existing tag points at another commit; it will not be moved")
    return ref


def release_notes(candidate, android, ios):
    summary = "\n".join(f"- {item['subject']} ({item['sha'][:8]})" for item in candidate["summary"])
    notes = candidate["notes"] or "请参阅以下提交摘要。"
    return (f"{notes}\n\n### 候选变更摘要\n\n{summary or '- 无新增普通提交；请检查合并变更。'}\n\n"
            f"### 构建来源\n\n候选：`{candidate['candidate_id']}`\n\n提交：`{candidate['build_sha']}`\n\n"
            f"- Android run ID: {android['run_id']}（第 {android['run_attempt']} 次运行）\n"
            f"- iOS run ID: {ios['run_id']}（第 {ios['run_attempt']} 次运行）\n\n"
            f"### 校验\n\n- APK SHA-256: `{android['sha256']}`\n- IPA SHA-256: `{ios['sha256']}`\n"
            f"- Android 证书 SHA-256: `{android['signing_cert_sha256']}`\n\n"
            "### 安装说明\n\nAndroid 使用固定正式签名，相同签名版本可覆盖安装。\n\niOS 为未签名 IPA，需自行签名安装。\n")


def check_assets(api, release_id, files):
    assets = list(api.pages(f"/releases/{release_id}/assets"))
    expected = {path.name: path for path in files}
    require(len({a["name"] for a in assets}) == len(assets), "Draft contains duplicate asset names")
    require(all(a["name"] in expected for a in assets), "Draft contains unexpected attachments; nothing will be deleted")
    for item in assets:
        path = expected[item["name"]]
        require(item["state"] == "uploaded", f"Attachment {path.name} has incomplete upload state; it will not be overwritten")
        require(item["size"] == path.stat().st_size, f"Existing attachment {path.name} size mismatch")
        content = api.request(f"/releases/assets/{item['id']}", binary=True)
        require(hashlib.sha256(content).hexdigest() == file_digest(path)["sha256"], f"Existing attachment {path.name} SHA-256 mismatch")
    return {a["name"] for a in assets}


def publish(api, version, candidate, files, body, check_only):
    # Include drafts (the public /tags endpoint may not expose a draft).
    matches = [r for r in api.pages("/releases") if r["tag_name"] == version]
    require(len(matches) <= 1, "Multiple releases use this tag")
    existing = matches[0] if matches else None
    if existing:
        require(existing["draft"], "A published release already exists; it will not be replaced")
        require(existing["target_commitish"] == candidate["build_sha"], "Draft target commit does not match the candidate")
        require(existing["body"] == body and not existing["prerelease"], "Draft notes/settings differ from this release plan")
        present = check_assets(api, existing["id"], files)
    else:
        present = set()
    validate_tag(api, version, candidate["build_sha"])
    if check_only:
        print("Validation passed. Check-only mode: no tags, releases or assets were written.")
        return
    release = existing or api.request("/releases", {"tag_name": version, "target_commitish": candidate["build_sha"], "name": version,
                                                    "body": body, "draft": True, "prerelease": False})
    print(f"Draft retained on failure: {release['html_url']}", flush=True)
    for path in files:
        if path.name not in present:
            url = release["upload_url"].split("{", 1)[0] + "?name=" + urllib.parse.quote(path.name)
            api.request(url, path.read_bytes(), method="POST")
    uploaded = check_assets(api, release["id"], files)
    require(uploaded == {p.name for p in files}, "Release attachments are incomplete")
    # Recheck public release/tag state immediately before the irreversible publish.
    current = api.request(f"/releases/{release['id']}")
    require(current["draft"] and current["target_commitish"] == candidate["build_sha"] and current["body"] == body,
            "Draft was changed by another writer during verification")
    if not validate_tag(api, version, candidate["build_sha"]):
        api.request("/git/refs", {"ref": f"refs/tags/{version}", "sha": candidate["build_sha"]})
    published = api.request(f"/releases/{release['id']}", {"draft": False, "make_latest": "true"}, "PATCH")
    require(not published["draft"], "Release did not become public")
    print(f"Published: {published['html_url']}")


def release(api, git, version, android_run_id, ios_run_id, check_only=True):
    require(version.startswith("v"), "Release version must start with v")
    version_tuple(version[1:])
    latest = stable_release(api)
    require(version_tuple(version[1:]) > version_tuple(latest["tag_name"][1:]), "Release version must be greater than the latest stable release")
    git.run("fetch", "origin", "+refs/heads/main:refs/remotes/origin/main", "--tags")
    with tempfile.TemporaryDirectory(prefix="oviewer-release-") as folder:
        folder = Path(folder)
        android, apk = read_build(api, "android", android_run_id, folder)
        ios, ipa = read_build(api, "ios", ios_run_id, folder)
        candidate = candidate_by_id(api, android["candidate_id"])
        validate_pair(android, ios, candidate, version)
        git.run("fetch", "origin", candidate["build_sha"])
        require(git.ancestor(candidate["build_sha"], "origin/main"), "Candidate commit is not contained in main")
        require(git.ancestor(latest["tag_name"], candidate["build_sha"]), "Candidate does not include latest stable release")
        require(git.fingerprint(candidate["build_sha"]) == candidate["fingerprint"], "Candidate content fingerprint mismatch")
        source_record = json.loads(git.file(candidate["build_sha"], CANDIDATE_PATH))
        require(source_record == {k: v for k, v in candidate.items() if k not in {"build_sha", "stage"}}, "Candidate source record disagrees with ledger")
        require(package_version(git.file(candidate["build_sha"], "pubspec.yaml")) == (candidate["version"], candidate["build_number"]), "Source version mismatch")
        for previous in api.pages("/releases"):
            if not previous["draft"] and not previous["prerelease"]:
                previous_version, number = package_version(git.file(previous["tag_name"], "pubspec.yaml"))
                require(previous["tag_name"] == "v" + previous_version, "Previous release tag/source version mismatch")
                require(candidate["build_number"] > number, "Build number must increase beyond every stable release")
        manifest = {"schema": 1, "version": version, "candidate": candidate, "android": android, "ios": ios}
        manifest_file = folder / "release-manifest.json"
        manifest_file.write_text(json_text(manifest), encoding="utf-8")
        checksum_file = folder / "SHA256SUMS.txt"
        checksum_file.write_text("".join(f"{file_digest(p)['sha256']}  {p.name}\n" for p in (apk, ipa, manifest_file)), encoding="utf-8")
        publish(api, version, candidate, [apk, ipa, manifest_file, checksum_file], release_notes(candidate, android, ios), check_only)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--android-run-id", type=int, required=True)
    parser.add_argument("--ios-run-id", type=int, required=True)
    parser.add_argument("--publish", action="store_true", help="Default is read-only validation")
    args = parser.parse_args()
    release(GitHub(), Git(), args.version, args.android_run_id, args.ios_run_id, not args.publish)


if __name__ == "__main__":
    main()
