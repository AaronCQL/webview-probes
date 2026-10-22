#!/usr/bin/env python3
"""Loopback HTTP server used as the COI alternative to a custom scheme.

Serves web/ under /coi/ (with COOP/COEP) and /nocoi/, plus /ping, /wping, /echo,
/result/<phase> (printed as RESULT lines) and /cmd/arrivals.

usage: loopback.py <port> <webroot>
"""
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlparse

ROOT = sys.argv[2] if len(sys.argv) > 2 else "web"
arrivals = []


def fnv1a(b):
    h = 0x811C9DC5
    for x in b:
        h ^= x
        h = (h * 0x01000193) & 0xFFFFFFFF
    return h


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def send(self, status, body, ctype="text/plain; charset=utf-8", coi=False):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Cross-Origin-Resource-Policy", "same-origin")
        if coi:
            self.send_header("Cross-Origin-Opener-Policy", "same-origin")
            self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.end_headers()
        self.wfile.write(body)

    def handle_any(self):
        u = urlparse(self.path)
        p = u.path
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        b = self.body() if self.command == "POST" else b""
        if p.startswith("/coi/") or p.startswith("/nocoi/"):
            coi = p.startswith("/coi/")
            rel = p[5:] if coi else p[7:]
            f = os.path.join(ROOT, os.path.normpath(rel))
            if os.path.isfile(f):
                ct = "text/html; charset=utf-8" if f.endswith(".html") else "text/javascript"
                return self.send(200, open(f, "rb").read(), ct, coi)
            return self.send(404, b"")
        if p == "/ping":
            return self.send(200, b"pong")
        if p == "/wping":
            arrivals.append(time.time() * 1000)
            return self.send(200, b"ok")
        if p == "/echo":
            m = q.get("marker", "").encode()
            j = {"len": len(b), "fnv": fnv1a(b), "ct": self.headers.get("Content-Type", ""), "marker": bool(m) and m in b, "src": "http"}
            return self.send(200, json.dumps(j).encode(), "application/json")
        if p.startswith("/result/"):
            print("RESULT loopback-" + unquote(p[8:]) + " " + b.decode("utf-8", "replace"), flush=True)
            return self.send(200, b"ok")
        if p == "/cmd/arrivals":
            lo, hi = float(q.get("from", 0)), float(q.get("to", 0))
            n = sum(1 for t in arrivals if lo < t < hi)
            return self.send(200, json.dumps({"count": n, "total": len(arrivals)}).encode())
        return self.send(404, b"")

    do_GET = handle_any
    do_POST = handle_any


if __name__ == "__main__":
    port = int(sys.argv[1])
    print(f"PROBE loopback server on 127.0.0.1:{port}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
