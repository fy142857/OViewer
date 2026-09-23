"""Compare machine analyzer output with reviewed diagnostics, ignoring line drift."""
from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path
import subprocess

from .github import json_text
from .rules import VersionError

BASELINE = Path("scripts/versioning/analysis-baseline.json")


def diagnostics(output: str, root: Path) -> list[dict]:
    records = []
    for line in output.splitlines():
        if not line.strip():
            continue
        fields = line.split("|", 7)
        if len(fields) != 8 or fields[0] not in {"ERROR", "WARNING", "INFO"}:
            raise VersionError(f"Unrecognized analyzer output: {line}")
        severity, _, code, path, _, _, _, message = fields
        normalized = path.replace("\\\\", "/").replace("\\", "/")
        root_name = root.resolve().as_posix().rstrip("/") + "/"
        if not normalized.lower().startswith(root_name.lower()):
            raise VersionError("Diagnostic outside repository")
        records.append({"severity": severity, "code": code, "path": normalized[len(root_name):], "message": message})
    return records


def new_diagnostics(actual: list[dict], baseline: list[dict]) -> list[dict]:
    def key(item):
        return tuple(item[k] for k in ("severity", "code", "path", "message"))
    allowed = Counter(key(item) for item in baseline)
    new = []
    for item in actual:
        identity = key(item)
        if allowed[identity]:
            allowed[identity] -= 1
        elif item["severity"] in {"ERROR", "WARNING"}:
            new.append(item)
    return new


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--record", action="store_true", help="Explicit baseline update for review; never used in CI")
    parser.add_argument("--dart", default="dart")
    args = parser.parse_args()
    result = subprocess.run([args.dart, "analyze", "--format", "machine", "lib", "test"], capture_output=True, text=True, encoding="utf-8")
    if result.returncode not in {0, 1, 2, 3}:
        raise VersionError(f"Analyzer failed ({result.returncode}): {result.stderr}")
    output = result.stdout + result.stderr
    actual = diagnostics(output, Path.cwd())
    if result.returncode and not actual:
        raise VersionError("Analyzer failed without diagnostics")
    if args.record:
        BASELINE.write_text(json_text(actual), encoding="utf-8")
    else:
        unexpected = new_diagnostics(actual, json.loads(BASELINE.read_text(encoding="utf-8")))
        if unexpected:
            raise VersionError("New analyzer errors/warnings:\n" + json_text(unexpected))
    print(f"Analyzer: {len(actual)} diagnostics; no new errors or warnings.")


if __name__ == "__main__":
    main()
