"""Dispatch both registered candidate builds without allocating another number."""
import argparse
import json
import re

from .build import candidate_by_id
from .github import GitHub
from .rules import Git, VersionError
from .test_policy import candidate_scope, run_title, verified_run, workflow_runs


def dispatch(api, candidate_id, branch, slow_tests='auto', git=None):
    candidate = candidate_by_id(api, candidate_id)
    if branch not in {"dev", "main"}:
        raise VersionError("Dispatch branch must be dev or main")
    runs = workflow_runs(api)
    scope = candidate_scope(api, git or Git(), candidate, runs, slow_tests)
    print(f"Slow tests: {scope['mode']}; {scope['reason']}")
    for platform in ("android", "ios"):
        workflow = f"build_{platform}.yml"
        title = run_title(platform, candidate_id, scope['mode'])
        # No retry of an uncertain POST. A workflow rerun first looks for an
        # already accepted dispatch (including one accepted before interruption).
        existing = next((r for r in runs[platform] if r.get("display_title") == title
                         and (r["status"] != "completed" or r["conclusion"] == "success")
                         and verified_run(api, r, candidate, platform)), None)
        if existing:
            print(f"Reusing {platform} run {existing['id']}")
        else:
            api.request(f"/actions/workflows/{workflow}/dispatches", {"ref": branch, "inputs": {
                "candidate_id": candidate_id, "skip_reader_prefetch_tests": scope['mode'] == 'skip',
                "test_scope": json.dumps(scope, ensure_ascii=False)}})
            print(f"Dispatched {platform}: {candidate_id} / slow:{scope['mode']}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--candidate", required=True)
    parser.add_argument("--branch", required=True)
    parser.add_argument("--slow-tests", choices=['auto', 'run', 'skip'], default='auto')
    args = parser.parse_args()
    if not re.fullmatch(r"\d+\.\d+\.\d+\+[1-9]\d*", args.candidate):
        raise VersionError("Invalid candidate ID")
    dispatch(GitHub(), args.candidate, args.branch, args.slow_tests)


if __name__ == "__main__":
    main()
