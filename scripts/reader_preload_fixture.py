"""Local controlled-network fixtures for the real-device reader benchmark.

No external traffic or user data. Each case gets an immutable network profile
and distinct URLs so disk/memory caches cannot leak between comparisons.
"""
from __future__ import annotations

import argparse
import json
import random
import struct
import threading
import time
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit


def image_bytes() -> bytes:
    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', zlib.crc32(kind + data))
    width, height = 900, 1500
    rows = bytearray()
    for y in range(height):
        rows.append(0)
        for x in range(width):
            value = 230 if ((x // 75 + y // 125) % 2) else 50
            rows.extend((value, value, value))
    # An ignored ancillary chunk gives every real image transfer the same
    # ~128 KiB payload without making the visual asset or decode nondeterministic.
    padding = random.Random(71).randbytes(128 * 1024)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!2I5B', width, height, 8, 2, 0, 0, 0))
            + chunk(b'vpAg', padding) + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))


PNG = image_bytes()
LOCK = threading.Lock()
CASES: dict[int, dict] = {}
NEXT_ID = int(time.time() * 1000) % 1000000000
PLAN = None
OUTPUT = None


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def do_POST(self):
        global NEXT_ID
        if self.headers.get('Transfer-Encoding', '').lower() == 'chunked':
            chunks = []
            while True:
                size = int(self.rfile.readline().strip().split(b';')[0], 16)
                if not size:
                    self.rfile.readline()
                    break
                chunks.append(self.rfile.read(size))
                self.rfile.read(2)
            raw = b''.join(chunks)
        else:
            raw = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        if urlsplit(self.path).path == '/result':
            result = json.loads(raw)
            deadline = time.monotonic() + 5
            while CASES[result['gid']]['active'] and time.monotonic() < deadline:
                time.sleep(0.02)
            with LOCK:
                case = CASES[result['gid']]
                result['http'] = {k: v for k, v in case.items() if k != 'bandwidth_lock'}
                with open(OUTPUT, 'a', encoding='utf-8') as stream:
                    stream.write(json.dumps(result) + '\n')
            return self.reply(b'{}', 'application/json')
        if urlsplit(self.path).path == '/case':
            config = json.loads(raw)
            with LOCK:
                NEXT_ID += 1
                gid = NEXT_ID
                CASES[gid] = dict(config, start=time.monotonic(), events=[], active=0, peak=0,
                                 next_byte_time=0.0, bandwidth_lock=threading.Lock())
            return self.reply(json.dumps({'gid': gid, 'image_bytes': len(PNG)}).encode(), 'application/json')
        self.reply(b'{"gmetadata":[]}', 'application/json')

    def do_GET(self):
        uri = urlsplit(self.path)
        parts = uri.path.strip('/').split('/')
        if parts[0] == 'health':
            return self.reply(b'oviewer-reader-preload-fixture', 'text/plain')
        if parts[0] == 'plan':
            with open(PLAN, encoding='utf-8-sig') as stream:
                return self.reply(json.dumps(json.load(stream)).encode(), 'application/json')
        if parts[0] == 'stats':
            with LOCK:
                case = CASES[int(parts[1])]
                data = {k: v for k, v in case.items() if k != 'bandwidth_lock'}
            return self.reply(json.dumps(data).encode(), 'application/json')
        if parts[0] in ('eh', 'ex'):
            parts = parts[1:]
        try:
            if parts[0] == 'g':
                gid = int(parts[1])
                case = CASES[gid]
                page = int(parse_qs(uri.query).get('p', ['0'])[0])
                total, page_size = 120, 40
                thumbs = ''.join(f'<div class="gdtm"><a href="https://e-hentai.org/s/{i+1:08x}/{gid}-{i+1}">'
                                  f'<img alt="{i+1}" src="http://127.0.0.1:8765/cover"></a></div>'
                                  for i in range(page*page_size, min((page+1)*page_size, total)))
                links = ''.join(f'<td><a href="https://e-hentai.org/g/{gid}/abc123/?p={p}">{p+1}</a></td>' for p in range(3))
                html = (f'<h1 id="gn">Reader benchmark {gid}</h1><div id="gdd"><table><tr><td>Length:</td><td>{total} pages</td></tr></table></div>'
                        f'<table class="ptt"><tr><td>&lt;</td>{links}<td>&gt;</td></tr></table><div id="gdt">{thumbs}</div>')
                return self.transfer(case, 'index', page, html.encode(), 'text/html', 20)
            if parts[0] == 's':
                gid, number = map(int, parts[2].split('-'))
                case = CASES[gid]
                html = (f'<img id="img" src="http://127.0.0.1:8765/image/{gid}/{number-1}" style="width:900px;height:1500px">'
                        + '<!--' + 'fixture ' * 2048 + '-->')
                delay = case['html_ms']
                if case.get('jitter'):
                    delay = [100, 200, 1400, 350, 700][(number - 1) % 5]
                return self.transfer(case, 'html', number-1, html.encode(), 'text/html', delay)
            if parts[0] == 'image':
                gid, page = int(parts[1]), int(parts[2])
                case = CASES[gid]
                return self.transfer(case, 'image', page, PNG, 'image/png', case['image_ms'])
        except (ValueError, KeyError, IndexError):
            return self.reply(b'Unknown fixture', 'text/plain', 404)
        if parts[0] == 'cover':
            return self.reply(PNG, 'image/png')
        self.reply(b'<div class="itg gld"></div>', 'text/html')

    def transfer(self, case, kind, page, data, mime, delay):
        with LOCK:
            event = dict(kind=kind, page=page, start_ms=(time.monotonic()-case['start'])*1000, bytes=0)
            case['events'].append(event)
            case['active'] += 1
            case['peak'] = max(case['peak'], case['active'])
        try:
            time.sleep(delay / 1000)
            self.send_response(200)
            self.send_header('Content-Type', mime)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            for offset in range(0, len(data), 8192):
                block = data[offset:offset+8192]
                with case['bandwidth_lock']:
                    now = time.monotonic()
                    due = max(now, case['next_byte_time']) + len(block) / (case['kbps'] * 1024)
                    case['next_byte_time'] = due
                time.sleep(max(0, due-time.monotonic()))
                self.wfile.write(block)
                self.wfile.flush()
                event['bytes'] += len(block)
            event['completed'] = True
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            event['completed'] = False
        finally:
            with LOCK:
                case['active'] -= 1
                event['end_ms'] = (time.monotonic()-case['start'])*1000

    def reply(self, data, mime, status=200):
        self.send_response(status)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *_):
        pass


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=8765)
    parser.add_argument('--plan', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    PLAN, OUTPUT = args.plan, args.output
    print(f'reader fixture on 127.0.0.1:{args.port}', flush=True)
    ThreadingHTTPServer(('127.0.0.1', args.port), Handler).serve_forever()
