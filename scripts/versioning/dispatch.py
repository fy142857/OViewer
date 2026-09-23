"""Dispatch both registered candidate builds without allocating another number."""
import argparse
import re

from .build import candidate_by_id
from .github import GitHub
from .rules import VersionError


def dispatch(api, candidate_id, branch):
    candidate_by_id(api, candidate_id)
    if branch not in {"dev", "main"}:
        raise VersionError("Dispatch branch must be dev or main")
    for platform in ("android", "ios"):
        workflow = f"build_{platform}.yml"
        title = f"{platform} / {candidate_id}"
        # No retry of an uncertain POST. A workflow rerun first looks for an
        # already accepted dispatch (including one accepted before interruption).
        runs = api.pages(f"/actions/workflows/{workflow}/runs?event=workflow_dispatch", "workflow_runs")
        existing = next((r for r in runs if r.get("display_title") == title
                         and (r["status"] != "completed" or r["conclusion"] == "success")), None)
        if existing:
            print(f"Reusing {platform} run {existing['id']}")
        else:
            api.request(f"/actions/workflows/{workflow}/dispatches", {"ref": branch, "inputs": {"candidate_id": candidate_id}})
            print(f"Dispatched {platform}: {candidate_id}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--candidate", required=True)
    parser.add_argument("--branch", required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"\d+\.\d+\.\d+\+[1-9]\d*", args.candidate):
        raise VersionError("Invalid candidate ID")
    dispatch(GitHub(), args.candidate, args.branch)


if __name__ == "__main__":
    main()
