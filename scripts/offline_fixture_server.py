"""Deterministic, local-only HTTP fixtures for the isolated emulator APK.

Run from the repository root: python -m scripts.offline_fixture_server
Control/read evidence at http://127.0.0.1:8765/control and /stats.
No gallery traffic, credentials or real user images are used.
"""
from __future__ import annotations

import argparse
import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import threading
import time
from urllib.parse import parse_qs, urlsplit

LOCK = threading.Lock()
STATE = {"enabled": True, "delay": 1.0, "pages": 12, "requests": [], "active": 0, "peak": 0}
FORMATS = json.loads((Path(__file__).resolve().parents[1] / "test/fixtures/page_image_formats.json").read_text())
FORMATS["gif"] = "R0lGODlhAgACAIEAAP8AAAAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAAAgACAAAIBgABCAQQEAAh+QQBCgABACwAAAAAAgACAIEAAP8AAAAAAAAAAAAIBgABCAQQEAA7"


def index(site: str, gid: int, part: int) -> str:
    origin = "https://exhentai.org" if site == "ex" else "https://e-hentai.org"
    total = STATE["pages"]
    count = (total + 5) // 6
    links = "".join(f'<td><a href="{origin}/g/{gid}/abc123/?p={n}">{n + 1}</a></td>' for n in range(count))
    thumbs = "".join(f'<div class="gdtm"><a href="{origin}/s/{n + 1:08x}/{gid}-{n + 1}">'
                     f'<img alt="{n + 1}" src="http://10.0.2.2:8765/cover/{gid}"></a></div>'
                     for n in range(part * 6, min((part + 1) * 6, total)))
    return f'''<html><head><link rel="canonical" href="{origin}/g/{gid}/abc123/"></head><body>
      <h1 id="gn">Offline Fixture {site.upper()} {gid}</h1><h1 id="gj">Offline Fixture</h1>
      <div id="gd1"><img src="http://10.0.2.2:8765/cover/{gid}"></div><div id="gdc"><div>Misc</div></div>
      <div id="gdd"><table><tr><td class="gdt1">Length:</td><td class="gdt2">{total} pages</td></tr>
      <tr><td class="gdt1">Posted:</td><td class="gdt2">2026-10-13 12:00</td></tr><tr><td class="gdt1">Language:</td><td class="gdt2">English</td></tr></table></div>
      <table class="ptt"><tr><td>&lt;</td>{links}<td>&gt;</td></tr></table><div id="gdt">{thumbs}</div></body></html>'''


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlsplit(self.path)
        query = parse_qs(url.query)
        if url.path == "/control":
            with LOCK:
                if "enabled" in query:
                    STATE["enabled"] = query["enabled"][0] == "1"
                if "delay" in query:
                    STATE["delay"] = max(0, min(30, float(query["delay"][0])))
                if "pages" in query:
                    STATE["pages"] = max(1, min(120, int(query["pages"][0])))
                if "reset" in query:
                    STATE["requests"] = []
                    STATE["peak"] = STATE["active"]
            return self.reply(json.dumps(STATE).encode(), "application/json")
        if url.path == "/stats":
            with LOCK:
                data = json.dumps(STATE).encode()
            return self.reply(data, "application/json")
        with LOCK:
            STATE["requests"].append(url.path)
            enabled = STATE["enabled"]
        if not enabled:
            return self.reply(b"fixture offline", "text/plain", 503)
        parts = url.path.strip("/").split("/")
        if parts[0] in {"image", "cover"}:
            page = int(parts[-1]) if parts[0] == "image" else 0
            kind = ["png", "gif", "jpeg", "webp"][page % 4]
            if parts[0] == "image":
                with LOCK:
                    STATE["active"] += 1
                    STATE["peak"] = max(STATE["peak"], STATE["active"])
                try:
                    time.sleep(STATE["delay"])
                    self.reply(base64.b64decode(FORMATS[kind]), "image/" + kind)
                finally:
                    with LOCK:
                        STATE["active"] -= 1
                return
            return self.reply(base64.b64decode(FORMATS[kind]), "image/" + kind)
        site = parts[0] if parts[0] in {"eh", "ex"} else "eh"
        origin = "https://exhentai.org" if site == "ex" else "https://e-hentai.org"
        if len(parts) > 3 and parts[1] == "g":
            return self.reply(index(site, int(parts[2]), int(query.get("p", ["0"])[0])).encode(), "text/html")
        if len(parts) > 3 and parts[1] == "s":
            gid, number = map(int, parts[3].split("-"))
            return self.reply(f'<img id="img" src="http://10.0.2.2:8765/image/{site}/{gid}/{number - 1}" '
                              'style="width: 2px; height: 2px">'.encode(), "text/html")
        cards = "".join(f'<div><a href="{origin}/g/{gid}/abc123/"><div class="glink">Offline Fixture {site.upper()} {gid}</div>'
                        f'<img src="http://10.0.2.2:8765/cover/{gid}"></a>'
                        '<div class="cs">Misc</div><div class="gl5t">12 pages</div></div>' for gid in [1001, 1002, 1003])
        self.reply(f'<div class="itg gld">{cards}</div>'.encode(), "text/html")

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        self.reply(b'{"gmetadata": [{"title_jpn": "Offline Fixture"}]}', "application/json")

    def reply(self, data: bytes, mime: str, status: int = 200):
        try:
            self.send_response(status)
            self.send_header("Content-Type", mime)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass  # Expected when pause/delete cancels an in-flight page.

    def log_message(self, format, *args):
        pass


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"Offline fixture server on 127.0.0.1:{args.port}", flush=True)
    server.serve_forever()
