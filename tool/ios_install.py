#!/usr/bin/env python3
"""Build/download OViewer IPA with GitHub Actions; install via Sideloadly on Windows."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import zipfile

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = "build_ios.yml"
WORKFLOW_NAME = "Build iOS IPA"
MAX_BYTES = 2 * 1024**3


class InstallerError(RuntimeError):
    pass


def require_successful_run(run):
    if run["status"] != "completed" or run["conclusion"] != "success":
        raise InstallerError(
            f"iOS 构建未成功（{run['conclusion'] or run['status']}），终止进程，不下载或安装 IPA。"
            f"日志：{run['html_url']}"
        )


def command(args, *, check=True, input=None):
    result = subprocess.run(args, cwd=ROOT, input=input, capture_output=True,
                            text=True, encoding="utf-8", errors="replace",
                            env={**os.environ, "GIT_TERMINAL_PROMPT": "0", "GCM_INTERACTIVE": "never"})
    if check and result.returncode:
        raise InstallerError(f"命令失败：{args[0]} {args[1]}\n{result.stderr.strip()}")
    return result


def repository(remote="origin"):
    url = command(["git", "remote", "get-url", remote]).stdout.strip()
    match = re.fullmatch(r"(?:https://github\.com/|git@github\.com:)([\w.-]+/[\w.-]+?)(?:\.git)?/?", url)
    if not match:
        raise InstallerError("远程地址必须是 github.com 的 HTTPS 或 SSH 仓库地址。")
    return match[1]


def token(repo):
    value = os.getenv("GH_TOKEN") or os.getenv("GITHUB_TOKEN")
    if value:
        return value
    if shutil.which("gh"):
        result = command(["gh", "auth", "token", "--hostname", "github.com"], check=False)
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
    result = command(["git", "credential", "fill"], check=False,
                     input=f"protocol=https\nhost=github.com\npath={repo}.git\n\n")
    fields = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
    if result.returncode == 0 and fields.get("password"):
        return fields["password"]
    raise InstallerError("未找到 GitHub 凭据。请运行 gh auth login 或设置 GH_TOKEN。"
                         "下载需 Actions:read，触发需 Actions:write，推送需 Contents:write。")


class SafeRedirect(urllib.request.HTTPRedirectHandler):
    """Never forward the GitHub token to the artifact storage host."""
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if urllib.parse.urlsplit(newurl).scheme != "https":
            raise InstallerError("拒绝非 HTTPS 下载重定向。")
        redirected = super().redirect_request(req, fp, code, msg, headers, newurl)
        if redirected and urllib.parse.urlsplit(newurl).netloc != urllib.parse.urlsplit(req.full_url).netloc:
            redirected.remove_header("Authorization")
        return redirected


class GitHub:
    def __init__(self, repo, auth):
        self.base = f"https://api.github.com/repos/{repo}"
        self.auth = auth
        self.opener = urllib.request.build_opener(SafeRedirect())

    def request(self, path, data=None):
        url = self.base + path
        headers = {"Authorization": f"Bearer {self.auth}", "Accept": "application/vnd.github+json",
                   "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "OViewer-IPA-Installer"}
        body = None if data is None else json.dumps(data).encode()
        if body is not None:
            headers["Content-Type"] = "application/json"
        attempts = 3 if data is None else 1  # Never retry an uncertain workflow dispatch.
        for attempt in range(attempts):
            try:
                return self.opener.open(urllib.request.Request(url, data=body, headers=headers), timeout=30)
            except urllib.error.HTTPError as exc:
                if exc.code in (429, 500, 502, 503, 504) and attempt + 1 < attempts:
                    time.sleep(2 ** (attempt + 1))
                    continue
                hints = {401: "GitHub 登录已失效", 403: "权限不足或 API 限流", 404: "仓库、构建或产物不存在／无权访问",
                         410: "产物已过期", 422: "分支或 workflow_dispatch 配置无效"}
                raise InstallerError(f"GitHub HTTP {exc.code}: {hints.get(exc.code, '请求失败')} ({path})") from None
            except (urllib.error.URLError, TimeoutError):
                if attempt + 1 < attempts:
                    time.sleep(2 ** (attempt + 1))
                    continue
                raise InstallerError("GitHub 网络请求失败，请检查网络后重试。触发请求超时时请先检查 Actions 页面。") from None

    def api(self, path, data=None):
        with self.request(path, data) as response:
            raw = response.read()
        return json.loads(raw) if raw else None

    def runs(self, **filters):
        query = urllib.parse.urlencode({"per_page": 10, **filters})
        return self.api(f"/actions/workflows/{WORKFLOW}/runs?{query}")["workflow_runs"]

    def artifacts(self, run_id):
        items = []
        page = 1
        while True:
            batch = self.api(f"/actions/runs/{int(run_id)}/artifacts?per_page=100&page={page}")["artifacts"]
            items.extend(batch)
            if len(batch) < 100:
                return items
            page += 1


def ipa_info(path):
    try:
        with zipfile.ZipFile(path) as archive:
            if sum(i.file_size for i in archive.infolist()) > MAX_BYTES:
                raise InstallerError("IPA 解压大小超过 2 GiB 限制。")
            infos = [i for i in archive.infolist() if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", i.filename)]
            if len(infos) != 1 or infos[0].file_size > 4 * 1024**2:
                raise InstallerError("IPA 必须包含一个 Payload/*.app/Info.plist。")
            info = plistlib.loads(archive.read(infos[0]))
            if not info.get("CFBundleIdentifier"):
                raise InstallerError("IPA 缺少 CFBundleIdentifier。")
            bad = archive.testzip()
            if bad:
                raise InstallerError("IPA CRC 校验失败。")
            return info
    except (zipfile.BadZipFile, plistlib.InvalidFileException, ValueError, OSError) as exc:
        raise InstallerError(f"IPA 无效：{path.name} ({type(exc).__name__})") from None


def unpack_artifact(source, destination):
    """v7 raw IPA is itself a ZIP; distinguish by Payload, not the extension."""
    with zipfile.ZipFile(source) as archive:
        if any(re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n) for n in archive.namelist()):
            shutil.copyfile(source, destination)
        else:
            candidates = [i for i in archive.infolist() if i.filename.lower().endswith(".ipa") and not i.is_dir()]
            if len(candidates) != 1:
                raise InstallerError("产物 ZIP 中必须恰好包含一个 IPA。")
            if candidates[0].file_size > MAX_BYTES:
                raise InstallerError("IPA 超过 2 GiB 限制。")
            # Copy into a fixed path, never extract archive-supplied paths.
            with archive.open(candidates[0]) as src, destination.open("wb") as out:
                shutil.copyfileobj(src, out)
    return ipa_info(destination)


def choose(items, label):
    if not items:
        raise InstallerError(f"没有可选择的{label}。")
    while True:
        value = input(f"选择{label}序号 [1-{len(items)}，0 返回]：").strip()
        if value == "0":
            return None
        if value.isdigit() and 1 <= int(value) <= len(items):
            return items[int(value) - 1]
        print("请输入有效序号。")


def ipa_filename(run, artifact, multiple_artifacts=False):
    name = f"OViewer-{WORKFLOW_NAME} #{int(run['run_number'])}"
    attempt = int(run.get("run_attempt", 1))
    if attempt > 1:
        name += f" (attempt {attempt})"
    if multiple_artifacts:
        name += f" (artifact {int(artifact['id'])})"
    return name + ".ipa"


def download(gh, run, folder):
    require_successful_run(run)
    artifacts = [a for a in gh.artifacts(run["id"]) if not a["expired"] and
                 ("ipa" in a["name"].lower() or "ios" in a["name"].lower() or a["name"] == "artifact")]
    if not artifacts:
        raise InstallerError("此构建没有可下载的 IPA（可能已过期，保留期为 30 天）。")
    if len(artifacts) == 1:
        artifact = artifacts[0]
    else:
        for index, item in enumerate(artifacts, 1):
            print(f"{index}. {item['name']} ({item['size_in_bytes'] / 1024**2:.1f} MiB)")
        artifact = choose(artifacts, "产物")
        if artifact is None:
            return None
    folder.mkdir(parents=True, exist_ok=True)
    name = ipa_filename(run, artifact, multiple_artifacts=len(artifacts) > 1)
    destination = folder / name
    print(f"下载构建 #{run['run_number']} → {destination}", flush=True)
    with tempfile.TemporaryDirectory(prefix=".ipa-", dir=folder) as temp:
        raw, staged = Path(temp) / "artifact.bin", Path(temp) / "validated.ipa"
        digest = hashlib.sha256()
        size = 0
        with gh.request(f"/actions/artifacts/{artifact['id']}/zip") as response, raw.open("wb") as out:
            expected = response.headers.get("Content-Length")
            while chunk := response.read(1024**2):
                size += len(chunk)
                if size > MAX_BYTES:
                    raise InstallerError("下载超过 2 GiB 限制。")
                digest.update(chunk)
                out.write(chunk)
        if expected and size != int(expected):
            raise InstallerError("下载不完整，请重试。")
        wanted = artifact.get("digest")
        if wanted and wanted.startswith("sha256:") and digest.hexdigest() != wanted.split(":", 1)[1]:
            raise InstallerError("产物 SHA-256 不匹配，未保存 IPA。")
        info = unpack_artifact(raw, staged)
        staged.replace(destination)
    metadata = {"run_url": run["html_url"], "run_id": run["id"], "run_number": run["run_number"],
                "run_attempt": run.get("run_attempt", 1), "workflow_name": WORKFLOW_NAME, "sha": run["head_sha"],
                "artifact_id": artifact["id"], "artifact_digest": wanted,
                "ipa_sha256": hashlib.sha256(destination.read_bytes()).hexdigest(),
                "bundle_id": info["CFBundleIdentifier"], "version": info.get("CFBundleShortVersionString")}
    destination.with_suffix(".json").write_text(json.dumps(metadata, indent=2), encoding="utf-8")
    print(f"已保存并校验：{destination} ({size / 1024**2:.1f} MiB)", flush=True)
    return destination


def wait_run(gh, run, timeout):
    deadline, last, reported = time.monotonic() + timeout, None, 0
    print(f"构建：{run['html_url']}", flush=True)
    while True:
        status = (run["status"], run["conclusion"])
        if status != last or time.monotonic() - reported >= 60:
            print(f"构建 #{run['run_number']}：{status[0]} / {status[1] or '-'}", flush=True)
            last, reported = status, time.monotonic()
        if run["status"] == "completed":
            require_successful_run(run)
            return run
        if run["status"] == "in_progress":
            # A failed compilation may be followed by lengthy cleanup steps.
            # Stop as soon as the iOS job/step reports failure, without waiting for cleanup.
            jobs = gh.api(f"/actions/runs/{run['id']}/jobs?filter=latest&per_page=100")["jobs"]
            for job in jobs:
                failed = next((s for s in job.get("steps", [])
                               if s.get("conclusion") in ("failure", "cancelled", "timed_out")), None)
                if failed or job.get("conclusion") in ("failure", "cancelled", "timed_out", "action_required", "startup_failure"):
                    stage = failed["name"] if failed else job["name"]
                    raise InstallerError(f"iOS 构建步骤失败：{stage}，终止进程，不下载或安装 IPA。日志：{run['html_url']}")
        if time.monotonic() >= deadline:
            raise InstallerError(f"等待构建超时；远端构建仍保留。稍后运行 download --run-id {run['id']}")
        time.sleep(15)
        run = gh.api(f"/actions/runs/{run['id']}")


def build(gh, args):
    if command(["git", "status", "--porcelain"]).stdout.strip():
        raise InstallerError("工作区存在未提交修改。请先 git add / git commit 后再运行 auto。")
    branch = command(["git", "symbolic-ref", "--quiet", "--short", "HEAD"]).stdout.strip()
    sha = command(["git", "rev-parse", "HEAD"]).stdout.strip()
    before = {r["id"] for r in gh.runs(branch=branch, head_sha=sha)}
    remote_sha = command(["git", "ls-remote", args.remote, f"refs/heads/{branch}"]).stdout.split()
    changed = not remote_sha or remote_sha[0] != sha
    print(f"推送 {branch} ({sha[:8]}) 到 {args.remote}…", flush=True)
    command(["git", "push", args.remote, f"{sha}:refs/heads/{branch}"])
    run = None
    if changed and branch in ("main", "dev"):
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            candidates = [r for r in gh.runs(branch=branch, head_sha=sha, event="push") if r["id"] not in before]
            if candidates:
                run = max(candidates, key=lambda r: r["id"])
                break
            time.sleep(5)
    if run is None:
        # Unchanged HEAD, doc-only push, or another branch: dispatch once and correlate by unique title.
        request_id = uuid.uuid4().hex
        print("触发 iOS workflow_dispatch…", flush=True)
        gh.api(f"/actions/workflows/{WORKFLOW}/dispatches",
               {"ref": branch, "inputs": {"installer_request_id": request_id}})
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            candidates = [r for r in gh.runs(branch=branch, event="workflow_dispatch", per_page=100)
                          if request_id in r.get("display_title", "")]
            if candidates:
                run = candidates[0]
                if run["head_sha"] != sha:
                    raise InstallerError("触发时远端分支已变化；拒绝下载其他提交的构建。")
                break
            time.sleep(5)
    if run is None:
        raise InstallerError("未找到本次触发的构建，请检查 GitHub Actions 页面。")
    return wait_run(gh, run, args.timeout)


def local_ipa(folder):
    paths = set(folder.rglob("*.ipa")) if folder.exists() else set()
    paths.update(ROOT.glob("*.ipa"))
    build_dir = ROOT / "build" / "ios"
    if build_dir.exists():
        paths.update(build_dir.rglob("*.ipa"))
    return sorted((p.resolve() for p in paths if p.is_file()), key=lambda p: p.stat().st_mtime, reverse=True)


def select_local(folder):
    paths = local_ipa(folder)
    for index, path in enumerate(paths, 1):
        print(f"{index}. {path.relative_to(ROOT) if path.is_relative_to(ROOT) else path} ({path.stat().st_size / 1024**2:.1f} MiB)")
    return choose(paths, "本地 IPA")


def install(path, args):
    ipa_info(path)
    from sideloadly_windows import install_ipa
    try:
        return install_ipa(path, args.sideloadly, args.udid, args.install_timeout)
    except RuntimeError:
        raise
    except Exception as exc:
        raise InstallerError(f"Sideloadly 自动化未完成（{type(exc).__name__}）；请检查窗口或认证提示后重试。") from None


def recent(gh):
    runs = gh.runs()
    for index, run in enumerate(runs, 1):
        title = " ".join(run.get("display_title", "").split())[:75]
        print(f"{index:2}. #{run['run_number']} {run['created_at']} {run['head_branch']} "
              f"{run['head_sha'][:8]} {run['conclusion'] or run['status']} | {title}")
    return runs


def parser():
    p = argparse.ArgumentParser(description="OViewer iOS 构建、下载和 Sideloadly 安装")
    p.add_argument("mode", nargs="?", default="menu", choices=["menu", "auto", "manual", "list", "download", "install", "doctor"])
    p.add_argument("--remote", default="origin")
    p.add_argument("--output", type=Path, default=ROOT / "ipa", help="下载目录，默认项目 ipa/")
    p.add_argument("--run-id", type=int, help="download 指定构建，否则选最近成功的构建")
    p.add_argument("--ipa", type=Path, help="install 指定本地 IPA，否则显示选择菜单")
    p.add_argument("--sideloadly", type=Path, help="Sideloadly.exe 路径，也可设置 SIDELOADLY_PATH")
    p.add_argument("--udid", help="多台 iPad 时指定 USB 设备 UDID")
    p.add_argument("--timeout", type=int, default=3600, help="构建等待秒数")
    p.add_argument("--install-timeout", type=int, default=900, help="安装等待秒数，含人工验证时间")
    p.add_argument("--no-install", action="store_true", help="auto/manual 只下载")
    return p


def auto_device_preflight(args):
    from sideloadly_windows import connected_ipads, select_device
    device = select_device(connected_ipads(), args.udid)
    if device is None:
        print("未检测到 USB iPad，自动流程未启动：不推送、不触发构建、不下载、不启动 Sideloadly。", flush=True)
        return False
    # Keep the same device throughout the build; installation rechecks this UDID.
    args.udid = device["udid"]
    print("已检测到 USB iPad，开始自动流程。", flush=True)
    return True


def main():
    args = parser().parse_args()
    if args.timeout <= 0 or args.install_timeout <= 0:
        raise InstallerError("超时必须大于 0。")
    args.output = args.output.resolve()
    if args.mode == "menu":
        modes = ["auto", "manual", "install", "doctor"]
        print("1. 检测 USB iPad 后推送、构建、下载并安装\n2. 选择最近 10 次 iOS 构建、下载并选择安装\n3. 安装本地 IPA\n4. 检查安装环境")
        args.mode = choose(modes, "操作")
        if args.mode is None:
            return 0
    # This gate deliberately precedes Git, credentials and GitHub requests, including --no-install.
    if args.mode == "auto" and not auto_device_preflight(args):
        return 2
    if args.mode == "doctor":
        from sideloadly_windows import doctor
        doctor(args.sideloadly)
        repo = repository(args.remote)
        GitHub(repo, token(repo)).runs()
        print(f"GitHub Actions 访问正常：{repo}")
        return 0
    if args.mode == "install":
        path = args.ipa.resolve() if args.ipa else select_local(args.output)
        return install(path, args) if path else 0
    repo = repository(args.remote)
    gh = GitHub(repo, token(repo))
    if args.mode == "list":
        recent(gh)
        return 0
    if args.mode == "auto":
        run = build(gh, args)
        require_successful_run(run)
        path = download(gh, run, args.output)
        return install(path, args) if path and not args.no_install else 0
    if args.mode == "manual":
        run = choose(recent(gh), "构建")
        if run is None:
            return 0
    elif args.run_id:
        run = gh.api(f"/actions/runs/{args.run_id}")
        workflow = gh.api(f"/actions/workflows/{WORKFLOW}")
        if run["workflow_id"] != workflow["id"]:
            raise InstallerError("所选 run 不属于 iOS workflow。")
    else:
        runs = gh.runs(status="success")
        if not runs:
            raise InstallerError("没有成功的 iOS 构建。")
        run = runs[0]
    path = download(gh, run, args.output)
    if args.mode == "manual" and path and not args.no_install:
        print("下载完成。选择本地 IPA 后立即开始安装；输入 0 仅保留下载。")
        selected = select_local(args.output)
        return install(selected, args) if selected else 0
    return 0


def entrypoint():
    try:
        return main()
    except KeyboardInterrupt:
        print("\n已停止本地等待；已触发的构建或安装不会被取消。", file=sys.stderr)
        return 130
    except (RuntimeError, OSError, zipfile.BadZipFile, EOFError) as exc:
        print(f"错误：{exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    sys.exit(entrypoint())
