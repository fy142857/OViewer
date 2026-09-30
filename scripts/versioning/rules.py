"""Pure version rules and Git content identity, shared by CI and tests."""
from __future__ import annotations

import hashlib
import json
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path


class VersionError(RuntimeError):
    pass


VERSION = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")
PUBSPEC = re.compile(r"^version: (\d+\.\d+\.\d+)\+([1-9]\d*)\s*$", re.MULTILINE)
CONVENTIONAL = re.compile(r"^([a-z]+)(?:\([^\r\n()]+\))?(!)?: \S[^\r\n]*")
TYPES = {"feat", "fix", "perf", "refactor", "build", "ci", "test", "chore", "revert", "docs", "style"}
CANDIDATE_PATH = ".release/candidate.json"
CORRECTIONS_PATH = ".release/change-classifications.json"
CHANGE_LEVELS = {"fix": 1, "enhancement": 1, "performance": 1,
                 "maintenance": 1, "feature": 2, "breaking": 3}
IMPACTS = {1: "patch", 2: "minor", 3: "major"}


def version_tuple(value: str) -> tuple[int, int, int]:
    if not VERSION.fullmatch(value):
        raise VersionError(f"Invalid stable version: {value!r}")
    return tuple(map(int, value.split(".")))


def package_version(text: str) -> tuple[str, int]:
    matches = list(PUBSPEC.finditer(text))
    if len(matches) != 1:
        raise VersionError("pubspec.yaml must contain exactly one version: X.Y.Z+N")
    version, number = matches[0].groups()
    version_tuple(version)
    return version, int(number)


def with_version(text: str, version: str, number: int) -> str:
    package_version(text)
    version_tuple(version)
    if not 0 < number <= 2100000000:
        raise VersionError("Build number outside Android versionCode range")
    # Do not let \s consume the following blank lines.
    return re.sub(r"^version:[^\r\n]*", f"version: {version}+{number}", text, count=1, flags=re.MULTILINE)


def ignored_path(path: str) -> bool:
    path = path.lower()
    return (path.endswith(".md") or path.startswith("docs/")
            or ("/" not in path and path.startswith("license"))
            or path == CANDIDATE_PATH)


@dataclass(frozen=True)
class Commit:
    sha: str
    message: str
    paths: tuple[str, ...]
    merge: bool = False


def load_corrections(text: str | None) -> list[dict]:
    if text is None:
        return []
    try:
        data = json.loads(text)
        if not isinstance(data, dict) or set(data) != {"schema", "corrections"} or data["schema"] != 1:
            raise ValueError("Expected schema 1 and corrections")
        if not isinstance(data["corrections"], list):
            raise ValueError("corrections must be a list")
        seen = set()
        for item in data["corrections"]:
            if not isinstance(item, dict) or set(item) != {"base_tag", "commit", "kind", "reason"}:
                raise ValueError("Expected base_tag, commit, kind and reason")
            if not all(isinstance(value, str) for value in item.values()):
                raise ValueError("Correction values must be strings")
            if not item["base_tag"].startswith("v"):
                raise ValueError("Correction baseline must be a release tag")
            version_tuple(item["base_tag"][1:])
            if not re.fullmatch(r"[0-9a-f]{40}", item["commit"]):
                raise ValueError("Correction commit must be a full SHA")
            if item["kind"] not in CHANGE_LEVELS or not item["reason"].strip():
                raise ValueError("Correction needs a valid kind and explanation")
            identity = (item["base_tag"], item["commit"])
            if identity in seen:
                raise ValueError("Duplicate correction")
            seen.add(identity)
        return data["corrections"]
    except (ValueError, TypeError, VersionError) as error:
        raise VersionError(f"Invalid {CORRECTIONS_PATH}: {error}") from error


def _trailer(message: str, name: str) -> str | None:
    message = message.replace("\r\n", "\n")
    values = re.findall(r"(?mi)^" + re.escape(name) + r":[ \t]*([^\r\n]*)$", message)
    if len(values) > 1 or (values and not values[0].strip()):
        raise VersionError(f"{name} must occur once with a nonempty value")
    return values[0].strip() if values else None


def classify_change(commit: Commit, match, correction: dict | None) -> dict:
    marker = bool(match[2] or re.search(r"(?m)^BREAKING(?: CHANGE|-CHANGE):\s*\S", commit.message))
    kind = correction["kind"] if correction else _trailer(commit.message, "Change-Kind")
    reason = correction["reason"] if correction else _trailer(commit.message, "Change-Reason")
    if kind not in CHANGE_LEVELS or not reason:
        raise VersionError(f"Commit {commit.sha} needs Change-Kind and Change-Reason; do not infer version impact from its prefix")
    if marker and kind != "breaking":
        raise VersionError(f"Commit {commit.sha}: a BREAKING change cannot be downgraded to {kind}")
    if kind == "breaking" and not marker and not correction:
        raise VersionError(f"Commit {commit.sha}: breaking needs ! or a BREAKING CHANGE declaration")
    if kind == "feature" and not any(
            p.startswith(("lib/", "android/", "ios/", "assets/")) or p == "pubspec.yaml"
            for p in commit.paths if not ignored_path(p)):
        raise VersionError(f"Commit {commit.sha}: tooling/test-only changes are not an application feature")
    effective_type = {"feature": "feat", "fix": "fix", "enhancement": "fix",
                      "performance": "perf", "maintenance": "chore"}.get(kind, match[1])
    return {"sha": commit.sha, "type": effective_type,
            "original_type": match[1], "subject": commit.message.splitlines()[0],
            "change_kind": kind, "version_impact": IMPACTS[CHANGE_LEVELS[kind]],
            "classification_reason": reason,
            "classification_source": "correction" if correction else "commit-trailers"}


def next_version(base: str, commits: list[Commit], registered: set[str],
                 corrections: list[dict] = ()) -> tuple[str, list[dict]]:
    major, minor, patch = version_tuple(base)
    level = 0
    summary = []
    active = {c["commit"]: c for c in corrections if c["base_tag"] == "v" + base}
    applied = set()
    for commit in commits:
        if commit.merge or commit.sha in registered:
            continue
        match = CONVENTIONAL.match(commit.message)
        if not match or match[1] not in TYPES:
            subject = commit.message.splitlines()[0] if commit.message.splitlines() else "(empty)"
            raise VersionError(f"Non-conventional commit {commit.sha}: {subject}")
        if not any(not ignored_path(p) for p in commit.paths):
            continue
        try:
            change = classify_change(commit, match, active.get(commit.sha))
        except VersionError as error:
            raise VersionError(f"Classification failed for {commit.sha}: {error}") from error
        level = max(level, CHANGE_LEVELS[change["change_kind"]])
        summary.append(change)
        applied.add(commit.sha)
    if active.keys() - applied:
        raise VersionError("Corrections must target effective, non-automation commits since this release: "
                           + ", ".join(sorted(active.keys() - applied)))
    if level == 3:
        return f"{major + 1}.0.0", summary
    if level == 2:
        return f"{major}.{minor + 1}.0", summary
    # Effective changes introduced by a merge resolution still need a patch.
    return f"{major}.{minor}.{patch + 1}", summary


class Git:
    def __init__(self, root: str | Path = "."):
        self.root = Path(root)

    def run(self, *args: str) -> bytes:
        result = subprocess.run(["git", *args], cwd=self.root, capture_output=True)
        if result.returncode:
            raise VersionError(result.stderr.decode("utf-8", "replace").strip())
        return result.stdout

    def text(self, *args: str) -> str:
        return self.run(*args).decode("utf-8").strip()

    def ancestor(self, older: str, newer: str) -> bool:
        result = subprocess.run(["git", "merge-base", "--is-ancestor", older, newer], cwd=self.root, capture_output=True)
        if result.returncode not in (0, 1):
            raise VersionError(result.stderr.decode("utf-8", "replace"))
        return result.returncode == 0

    def file(self, ref: str, path: str) -> str:
        return self.run("show", f"{ref}:{path}").decode("utf-8")

    def optional_file(self, ref: str, path: str) -> str | None:
        if not self.run("ls-tree", "-z", ref, "--", path):
            return None
        return self.file(ref, path)

    def fingerprint(self, ref: str) -> str:
        digest = hashlib.sha256()
        for entry in self.run("ls-tree", "-rz", "--full-tree", ref).split(b"\0"):
            if not entry:
                continue
            info, path = entry.split(b"\t", 1)
            name = path.decode("utf-8")
            if ignored_path(name):
                continue
            mode, kind, oid = info.split()
            if name == "pubspec.yaml":
                data = self.run("cat-file", "blob", oid.decode())
                normalized = with_version(data.decode("utf-8"), "0.0.0", 1).encode("utf-8")
                oid = hashlib.sha256(normalized).hexdigest().encode()
            digest.update(mode + b" " + kind + b" " + path + b"\0" + oid + b"\0")
        return digest.hexdigest()

    def commits(self, base: str, source: str) -> list[Commit]:
        if not self.ancestor(base, source):
            raise VersionError("Source branch must include the latest stable release; synchronize it first")
        result = []
        for sha in self.text("rev-list", "--reverse", f"{base}..{source}").splitlines():
            parents = self.text("rev-list", "--parents", "-n", "1", sha).split()[1:]
            paths = self.run("diff-tree", "--no-commit-id", "--name-only", "-r", "--root", "-z", sha)
            result.append(Commit(sha, self.file_message(sha), tuple(p.decode("utf-8") for p in paths.split(b"\0") if p), len(parents) > 1))
        return result

    def file_message(self, sha: str) -> str:
        return self.text("show", "-s", "--format=%B", sha)


def reusable_candidate(records: list[dict], fingerprint: str, source: str, base_tag: str, git: Git,
                       version: str | None = None) -> dict | None:
    for item in sorted(records, key=lambda c: c["build_number"], reverse=True):
        if (item["base_tag"] == base_tag and item["fingerprint"] == fingerprint
                and item["stage"] == "ready" and (version is None or item.get("version") == version)
                and git.ancestor(item["build_sha"], source)):
            return item
    return None
