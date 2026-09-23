"""Small GitHub client with non-overwriting Git reference transactions."""
from __future__ import annotations

import base64
import json
import os
import urllib.error
import urllib.parse
import urllib.request

from .rules import VersionError


class APIError(VersionError):
    def __init__(self, status: int, path: str, body: str):
        self.status = status
        super().__init__(f"GitHub {status} {path}: {body[:1200]}")


class SafeRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        redirected = super().redirect_request(req, fp, code, msg, headers, newurl)
        if redirected is not None and urllib.parse.urlsplit(req.full_url).netloc != urllib.parse.urlsplit(newurl).netloc:
            redirected.remove_header("Authorization")
        if urllib.parse.urlsplit(newurl).scheme != "https":
            raise VersionError("Refusing non-HTTPS download redirect")
        return redirected


class GitHub:
    def __init__(self, repository: str | None = None, token: str | None = None):
        self.repository = repository or os.environ["GITHUB_REPOSITORY"]
        self.token = token or os.environ["GH_TOKEN"]
        self.base = f"https://api.github.com/repos/{self.repository}"
        self.opener = urllib.request.build_opener(SafeRedirect())

    def request(self, path: str, data=None, method=None, binary=False):
        url = path if path.startswith("https://") else self.base + path
        host = urllib.parse.urlsplit(url).netloc
        if host not in {"api.github.com", "uploads.github.com"}:
            raise VersionError("Unexpected GitHub API host")
        headers = {"Authorization": f"Bearer {self.token}", "Accept": "application/octet-stream" if binary else "application/vnd.github+json",
                   "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "OViewer-release"}
        if isinstance(data, bytes):
            headers["Content-Type"] = "application/octet-stream"
        elif data is not None:
            data = json.dumps(data, ensure_ascii=False).encode("utf-8")
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with self.opener.open(request, timeout=120) as response:
                content = response.read()
                return content if binary else json.loads(content) if content else None
        except urllib.error.HTTPError as error:
            raise APIError(error.code, path, error.read().decode("utf-8", "replace")) from error

    def optional(self, path: str):
        try:
            return self.request(path)
        except APIError as error:
            if error.status == 404:
                return None
            raise

    def pages(self, path: str, key: str | None = None):
        separator = "&" if "?" in path else "?"
        for page in range(1, 1001):
            response = self.request(f"{path}{separator}per_page=100&page={page}")
            items = response[key] if key else response
            yield from items
            if len(items) < 100:
                return
        raise VersionError("GitHub pagination exceeded safety limit")

    def ref(self, branch: str):
        item = self.optional("/git/ref/heads/" + urllib.parse.quote(branch, safe=""))
        return item["object"]["sha"] if item else None

    def file(self, ref: str, path: str) -> str:
        response = self.request(f"/contents/{path}?ref={urllib.parse.quote(ref, safe='')}")
        if response.get("encoding") != "base64":
            raise VersionError(f"Expected a small text file: {path}")
        return base64.b64decode(response["content"]).decode("utf-8")

    def commit(self, parent: str | None, files: dict[str, str], message: str) -> str:
        tree = {"tree": [{"path": path, "mode": "100644", "type": "blob", "content": text} for path, text in files.items()]}
        if parent:
            tree["base_tree"] = self.request(f"/git/commits/{parent}")["tree"]["sha"]
        tree_sha = self.request("/git/trees", tree)["sha"]
        return self.request("/git/commits", {"message": message, "tree": tree_sha, "parents": [parent] if parent else []})["sha"]

    def compare_and_swap(self, branch: str, expected: str | None, commit: str):
        if self.ref(branch) != expected:
            raise VersionError(f"Branch {branch} advanced; refusing to overwrite it")
        # The commit must have exactly the old head as its parent. Combined with
        # force=false this also rejects a writer racing the preceding read.
        parents = [p["sha"] for p in self.request(f"/git/commits/{commit}")["parents"]]
        if parents != ([expected] if expected else []):
            raise VersionError("Compare-and-swap commit has unexpected parents")
        if expected is None:
            self.request("/git/refs", {"ref": f"refs/heads/{branch}", "sha": commit})
        else:
            self.request("/git/refs/heads/" + urllib.parse.quote(branch, safe=""), {"sha": commit, "force": False}, "PATCH")


def json_text(value) -> str:
    return json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
