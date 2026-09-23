"""Prepare/resume one candidate. Run only in the serialized prepare workflow."""
from __future__ import annotations

import argparse
import json
import os
import re

from .github import GitHub, json_text
from .rules import CANDIDATE_PATH, Git, VersionError, next_version, package_version, reusable_candidate, version_tuple, with_version

LEDGER_BRANCH = "version-state"
LEDGER_PATH = "ledger.json"


class Ledger:
    def __init__(self, api: GitHub):
        self.api = api
        self.head = api.ref(LEDGER_BRANCH)
        self.data = json.loads(api.file(self.head, LEDGER_PATH)) if self.head else {"schema": 1, "last_build_number": 1, "candidates": []}
        if self.data["schema"] != 1:
            raise VersionError("Unsupported version ledger schema")

    def save(self):
        commit = self.api.commit(self.head, {LEDGER_PATH: json_text(self.data)}, "chore: update candidate ledger")
        self.api.compare_and_swap(LEDGER_BRANCH, self.head, commit)
        self.head = commit


def stable_release(api: GitHub) -> dict:
    releases = [r for r in api.pages("/releases") if not r["draft"] and not r["prerelease"]]
    if not releases:
        raise VersionError("No stable release available as a version baseline")
    for release in releases:
        if not release["tag_name"].startswith("v"):
            raise VersionError("Stable release tag must use vX.Y.Z")
        version_tuple(release["tag_name"][1:])
    return max(releases, key=lambda r: version_tuple(r["tag_name"][1:]))


def prepare(api: GitHub, git: Git, branch: str, source: str) -> dict | None:
    if branch not in {"dev", "main"} or not re.fullmatch(r"[0-9a-f]{40}", source):
        raise VersionError("Only exact commits on dev/main can prepare candidates")
    ledger = Ledger(api)
    base = stable_release(api)["tag_name"]
    git.run("fetch", "origin", f"refs/tags/{base}:refs/tags/{base}", f"refs/heads/{branch}:refs/remotes/origin/{branch}")
    # A retried run may point at the source immediately before our version commit.
    for candidate in ledger.data["candidates"]:
        if candidate["source_sha"] == source and candidate["branch"] == branch and candidate["base_tag"] == base:
            return finish(api, ledger, candidate)
    if api.ref(branch) != source:
        raise VersionError("Source branch advanced; stop this stale preparation")
    commits = git.commits(base, source)
    fingerprint = git.fingerprint(source)
    registered = {c["build_sha"] for c in ledger.data["candidates"]}
    version, summary = next_version(base[1:], commits, registered)
    candidate = reusable_candidate(ledger.data["candidates"], fingerprint, source, base, git)
    if candidate:
        return candidate
    if fingerprint == git.fingerprint(base):
        return None
    # A docs-only change after an existing candidate uses the ancestor above;
    # an unchanged release tree does not allocate even on manual dispatch.
    _, released_number = package_version(git.file(base, "pubspec.yaml"))
    number = max(ledger.data["last_build_number"], released_number) + 1
    candidate = {"schema": 1, "candidate_id": f"{version}+{number}", "version": version,
                 "build_number": number, "source_sha": source, "branch": branch,
                 "base_tag": base, "fingerprint": fingerprint, "summary": summary}
    try:
        changelog = git.file(source, "CHANGELOG.md")
    except VersionError:
        changelog = ""
    # Freeze approved notes with the candidate; later docs changes cannot silently
    # change release notes for an already tested binary.
    match = re.search(r"(?ms)^## \[" + re.escape(version) + r"\][^\n]*\n(.*?)(?=^## |\Z)", changelog)
    if not match:
        match = re.search(r"(?ms)^## \[Unreleased\]\s*\n(.*?)(?=^## |\Z)", changelog)
    candidate["notes"] = match[1].strip() if match else ""
    build_sha = api.commit(source, {
        "pubspec.yaml": with_version(git.file(source, "pubspec.yaml"), version, number),
        CANDIDATE_PATH: json_text(candidate),
    }, f"chore(release): prepare {version}+{number}")
    candidate.update(build_sha=build_sha, stage="reserved")
    ledger.data["last_build_number"] = number
    ledger.data["candidates"].append(candidate)
    # Persist allocation + exact version commit before changing the source branch.
    ledger.save()
    return finish(api, ledger, candidate)


def finish(api: GitHub, ledger: Ledger, candidate: dict) -> dict:
    head = api.ref(candidate["branch"])
    if head == candidate["source_sha"] and candidate["stage"] == "reserved":
        api.compare_and_swap(candidate["branch"], head, candidate["build_sha"])
    elif head != candidate["build_sha"]:
        # A ready candidate remains retryable even after subsequent development.
        # Reserved candidates may only recover if their exact commit is present.
        comparison = api.request(f"/compare/{candidate['build_sha']}...{head}")
        if comparison["status"] not in {"ahead", "identical"}:
            raise VersionError("Branch advanced without the reserved candidate; allocation remains recorded")
    if candidate["stage"] != "ready":
        candidate["stage"] = "ready"
        ledger.save()
    return candidate


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--branch", required=True)
    parser.add_argument("--source", required=True)
    args = parser.parse_args()
    candidate = prepare(GitHub(), Git(), args.branch, args.source)
    output = {"candidate_id": candidate["candidate_id"] if candidate else "", "build_sha": candidate["build_sha"] if candidate else ""}
    print(json_text(output))
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as stream:
            for key, value in output.items():
                stream.write(f"{key}={value}\n")


if __name__ == "__main__":
    main()
