"""Validate registered candidates and inspect the packages actually built."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import subprocess
import zipfile
from pathlib import Path

from .github import GitHub, json_text
from .prepare import Ledger
from .rules import CANDIDATE_PATH, Git, VersionError, package_version


def candidate_by_id(api: GitHub, candidate_id: str) -> dict:
    matches = [c for c in Ledger(api).data["candidates"] if c["candidate_id"] == candidate_id and c["stage"] == "ready"]
    if len(matches) != 1:
        raise VersionError("Candidate is missing, duplicated or not ready in version-state")
    return matches[0]


def verify_candidate(api: GitHub, git: Git, candidate_id: str) -> dict:
    candidate = candidate_by_id(api, candidate_id)
    if git.text("rev-parse", "HEAD") != candidate["build_sha"]:
        raise VersionError("Checkout does not match registered candidate SHA")
    source = json.loads(git.file("HEAD", CANDIDATE_PATH))
    expected = {k: v for k, v in candidate.items() if k not in {"build_sha", "stage"}}
    if source != expected or git.fingerprint("HEAD") != candidate["fingerprint"]:
        raise VersionError("Candidate record or content fingerprint mismatch")
    if package_version(git.file("HEAD", "pubspec.yaml")) != (candidate["version"], candidate["build_number"]):
        raise VersionError("Candidate version disagrees with pubspec.yaml")
    return candidate


def android_tool(name: str) -> str:
    sdk = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
    if not sdk:
        raise VersionError("Android SDK is required to inspect APKs")
    suffix = ".bat" if os.name == "nt" and name == "apksigner" else ".exe" if os.name == "nt" else ""
    tool = Path(sdk) / "build-tools" / "35.0.0" / (name + suffix)
    if not tool.is_file():
        raise VersionError(f"Missing Android build tool: {tool}")
    return str(tool)


def command(*args) -> str:
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        raise VersionError(f"Package inspection failed: {args[0]}\n{result.stderr}")
    return result.stdout


def certificate(value: str) -> str:
    normalized = value.replace(":", "").strip().lower()
    if not re.fullmatch(r"[0-9a-f]{64}", normalized):
        raise VersionError("Expected a SHA-256 signing certificate fingerprint")
    return normalized


def inspect_package(path: Path, platform: str, expected_certificate: str | None = None) -> dict:
    if platform == "android":
        badging = command(android_tool("aapt"), "dump", "badging", str(path))
        line = next((line for line in badging.splitlines() if line.startswith("package:")), "")
        fields = dict(re.findall(r"(\w+)='([^']*)'", line))
        if fields.get("name") != "com.oviewer.oviewer":
            raise VersionError("Unexpected APK application ID")
        signing = command(android_tool("apksigner"), "verify", "--verbose", "--print-certs", str(path))
        digests = re.findall(r"(?m)^Signer #\d+ certificate SHA-256 digest: ([0-9a-fA-F:]+)$", signing)
        if len(digests) != 1 or not expected_certificate or certificate(digests[0]) != certificate(expected_certificate):
            raise VersionError("APK signing certificate does not match the permanent release key")
        if "CN=Android Debug" in signing:
            raise VersionError("Debug signed APK cannot be published")
        return {"version": fields["versionName"], "build_number": int(fields["versionCode"]), "signing_cert_sha256": certificate(digests[0])}
    if platform != "ios":
        raise VersionError("Unsupported package platform")
    with zipfile.ZipFile(path) as archive:
        entries = [name for name in archive.namelist() if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", name)]
        if len(entries) != 1:
            raise VersionError("IPA must contain exactly one top-level application")
        info = plistlib.loads(archive.read(entries[0]))
        if info.get("CFBundleIdentifier") != "com.oviewer.oviewer":
            raise VersionError("Unexpected IPA bundle identifier")
        return {"version": info["CFBundleShortVersionString"], "build_number": int(info["CFBundleVersion"])}


def file_digest(path: Path) -> dict:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return {"filename": path.name, "size": path.stat().st_size, "sha256": digest.hexdigest()}


def metadata(candidate: dict, path: Path, platform: str, run_id: int, attempt: int, expected_certificate=None) -> dict:
    package = inspect_package(path, platform, expected_certificate)
    if (package["version"], package["build_number"]) != (candidate["version"], candidate["build_number"]):
        raise VersionError("Built package version does not match candidate")
    return {"schema": 1, "candidate_id": candidate["candidate_id"], "platform": platform,
            "build_sha": candidate["build_sha"], "source_sha": candidate["source_sha"],
            "run_id": run_id, "run_attempt": attempt, **package, **file_digest(path)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["resolve", "verify", "metadata"])
    parser.add_argument("--candidate", required=True)
    parser.add_argument("--platform", choices=["android", "ios"])
    parser.add_argument("--file", type=Path)
    args = parser.parse_args()
    api = GitHub()
    if args.command == "resolve":
        candidate = candidate_by_id(api, args.candidate)
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as stream:
            stream.write(f"build_sha={candidate['build_sha']}\n")
        return
    candidate = verify_candidate(api, Git(), args.candidate)
    if args.command == "metadata":
        if not args.file or not args.platform:
            parser.error("metadata requires --file and --platform")
        record = metadata(candidate, args.file, args.platform, int(os.environ["GITHUB_RUN_ID"]), int(os.environ["GITHUB_RUN_ATTEMPT"]), os.environ.get("ANDROID_SIGNING_CERT_SHA256"))
        Path("build-metadata.json").write_text(json_text(record), encoding="utf-8")
        print(json_text(record))


if __name__ == "__main__":
    main()
