"""Pure version rules and Git content identity, shared by CI and tests."""
from __future__ import annotations

import hashlib
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


def next_version(base: str, commits: list[Commit], registered: set[str]) -> tuple[str, list[dict]]:
    major, minor, patch = version_tuple(base)
    level = 0
    summary = []
    for commit in commits:
        if commit.merge or commit.sha in registered:
            continue
        match = CONVENTIONAL.match(commit.message)
        if not match or match[1] not in TYPES:
            raise VersionError(f"Non-conventional commit {commit.sha}: {commit.message.splitlines()[0]}")
        if not any(not ignored_path(p) for p in commit.paths):
            continue
        breaking = bool(match[2] or re.search(r"(?m)^BREAKING(?: CHANGE|-CHANGE):\s*\S", commit.message))
        level = max(level, 3 if breaking else 2 if match[1] == "feat" else 1)
        summary.append({"sha": commit.sha, "type": match[1], "subject": commit.message.splitlines()[0]})
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


def reusable_candidate(records: list[dict], fingerprint: str, source: str, base_tag: str, git: Git) -> dict | None:
    for item in sorted(records, key=lambda c: c["build_number"], reverse=True):
        if (item["base_tag"] == base_tag and item["fingerprint"] == fingerprint
                and item["stage"] == "ready" and git.ancestor(item["build_sha"], source)):
            return item
    return None
