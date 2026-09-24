#!/usr/bin/env python3
"""Tests for the hermes-homelab egress proxy. Pure stdlib — run anywhere:

    python3 egress-proxy/test_proxy.py

Covers: allowlist matching (units), default-deny with no files, CONNECT
tunneling to a local origin (full relay), plain HTTP forwarding incl. POST
bodies, deny responses carrying the proxy's own marker, live hot-reload of
the allowlist file, and one real end-to-end CONNECT to github.com (skipped
automatically when the network blocks it).
"""

import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
PROXY_PY = os.path.join(HERE, "proxy.py")

sys.path.insert(0, HERE)
import proxy as proxy_mod  # noqa: E402

PASS = 0
FAIL = 0


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  ok   {name}")
    else:
        FAIL += 1
        print(f"  FAIL {name}  {detail}")


# ── unit: allowlist matcher ────────────────────────────────────────────
print("[1] matcher units")
rules = proxy_mod._parse_rules("Example.COM\n*.foo.bar\n# comment\n\n*\n")
check("parse + case fold + strip '*.'", rules == {"example.com", "foo.bar", "*"}, str(rules))
check("exact match", proxy_mod.host_allowed("example.com", {"example.com"}))
check("subdomain match", proxy_mod.host_allowed("api.example.com", {"example.com"}))
check("deep subdomain match", proxy_mod.host_allowed("a.b.example.com", {"example.com"}))
check("unknown host denied", not proxy_mod.host_allowed("evil.com", {"example.com"}))
check("suffix-string NOT matched (notexample.com)",
      not proxy_mod.host_allowed("notexample.com", {"example.com"}))
check("escape hatch '*'", proxy_mod.host_allowed("anything.net", {"*"}))
check("empty rules deny all", not proxy_mod.host_allowed("example.com", set()))

# load semantics: existing-but-empty user file is authoritative (deny-all);
# missing user file falls back to the baked-in default.
tmp_sem = tempfile.mkdtemp()
user_f = os.path.join(tmp_sem, "user")
default_f = os.path.join(tmp_sem, "default")
with open(default_f, "w") as f:
    f.write("fallback.example\n")
proxy_mod.ALLOWLIST_PATH = user_f
proxy_mod.DEFAULT_PATH = default_f
proxy_mod._rules_cache["mtime"] = None
proxy_mod._rules_cache["rules"] = None
with open(user_f, "w") as f:
    f.write("# empty on purpose\n")
os.utime(user_f, (time.time(), time.time()))
proxy_mod._rules_cache["mtime"] = None
proxy_mod._rules_cache["rules"] = None
check("existing empty user file = deny-all (no fallback)",
      proxy_mod.load_rules() == set(), str(proxy_mod.load_rules()))
os.remove(user_f)
proxy_mod._rules_cache["mtime"] = None
proxy_mod._rules_cache["rules"] = None
check("missing user file falls back to default",
      proxy_mod.load_rules() == {"fallback.example"}, str(proxy_mod.load_rules()))


# ── local origin server (plain HTTP) ───────────────────────────────────
class Origin(BaseHTTPRequestHandler):
    def _reply(self):
        body = b"hello-origin"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self._reply()

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        data = self.rfile.read(n)
        body = b"echo:" + data
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


origin = HTTPServer(("127.0.0.1", 0), Origin)
ORIGIN_PORT = origin.server_address[1]
threading.Thread(target=origin.serve_forever, daemon=True).start()

tmpdir = tempfile.mkdtemp()
allowlist = os.path.join(tmpdir, "allowlist")
default_list = os.path.join(tmpdir, "default")
with open(allowlist, "w") as f:
    f.write(f"127.0.0.1\ngithub.com\n")
with open(default_list, "w") as f:
    f.write("")

PROXY_PORT = free_port()
proc = subprocess.Popen(
    [sys.executable, PROXY_PY],
    env={**os.environ,
         "EGRESS_LISTEN": "127.0.0.1",
         "EGRESS_PORT": str(PROXY_PORT),
         "EGRESS_ALLOWLIST": allowlist,
         "EGRESS_ALLOWLIST_DEFAULT": default_list},
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
)
for _ in range(50):
    try:
        socket.create_connection(("127.0.0.1", PROXY_PORT), timeout=1).close()
        break
    except OSError:
        time.sleep(0.1)


def proxy_request(raw, read_all=False):
    s = socket.create_connection(("127.0.0.1", PROXY_PORT), timeout=10)
    s.sendall(raw)
    s.settimeout(10)
    chunks = []
    try:
        while True:
            d = s.recv(65536)
            if not d:
                break
            chunks.append(d)
            if not read_all and b"\r\n\r\n" in b"".join(chunks):
                break
    except socket.timeout:
        pass
    s.close()
    return b"".join(chunks)


# ── [2] CONNECT tunnel to local origin, full relay ─────────────────────
print("[2] CONNECT tunnel (allowlisted, local origin)")
s = socket.create_connection(("127.0.0.1", PROXY_PORT), timeout=10)
s.sendall(f"CONNECT 127.0.0.1:{ORIGIN_PORT} HTTP/1.1\r\nHost: 127.0.0.1:{ORIGIN_PORT}\r\n\r\n".encode())
head = b""
while b"\r\n\r\n" not in head:
    head += s.recv(4096)
check("200 Connection established", b"200" in head.split(b"\r\n", 1)[0], head[:60].decode())
s.sendall(b"GET /hello HTTP/1.1\r\nHost: origin\r\nConnection: close\r\n\r\n")
resp = b""
try:
    while True:
        d = s.recv(65536)
        if not d:
            break
        resp += d
except socket.timeout:
    pass
s.close()
check("tunnel relays origin response", b"200" in resp and b"hello-origin" in resp, resp[:80].decode())

# ── [3] plain HTTP GET forwarded ───────────────────────────────────────
print("[3] plain HTTP forwarding")
resp = proxy_request(
    f"GET http://127.0.0.1:{ORIGIN_PORT}/hello HTTP/1.1\r\nHost: 127.0.0.1:{ORIGIN_PORT}\r\nConnection: close\r\n\r\n".encode(),
    read_all=True)
check("GET returns 200 + body", b"200" in resp and b"hello-origin" in resp, resp[:80].decode())

# ── [4] plain HTTP POST body survives ──────────────────────────────────
print("[4] POST body forwarding")
resp = proxy_request(
    f"POST http://127.0.0.1:{ORIGIN_PORT}/x HTTP/1.1\r\nHost: 127.0.0.1:{ORIGIN_PORT}\r\nContent-Length: 7\r\nConnection: close\r\n\r\npayload".encode(),
    read_all=True)
check("POST body echoed", b"echo:payload" in resp, resp[-40:].decode(errors="replace"))

# ── [5] deny path (never allowlisted) ──────────────────────────────────
print("[5] denials")
resp = proxy_request(b"CONNECT evil.example.org:443 HTTP/1.1\r\nHost: evil.example.org\r\n\r\n")
check("CONNECT denied with 403", b"403" in resp.split(b"\r\n", 1)[0], resp[:60].decode())
check("deny body carries proxy marker", b"blocked by egress allowlist" in resp, "")
resp = proxy_request(f"GET http://evil.example.org/ HTTP/1.1\r\nHost: evil.example.org\r\nConnection: close\r\n\r\n".encode())
check("plain HTTP denied with 403", b"403" in resp.split(b"\r\n", 1)[0], resp[:60].decode())

# ── [6] hot reload of allowlist ────────────────────────────────────────
print("[6] hot reload")
with open(allowlist, "a") as f:
    f.write("evil.example.org\n")
time.sleep(0.1)
os.utime(allowlist, (time.time(), time.time()))
resp = proxy_request(f"GET http://evil.example.org/ HTTP/1.1\r\nHost: evil.example.org\r\nConnection: close\r\n\r\n".encode(), read_all=True)
check("newly added host now allowed (origin unreachable -> 502, not 403)",
      b"502" in resp.split(b"\r\n", 1)[0], resp[:60].decode())

# ── [7] default-deny when no files at all ──────────────────────────────
print("[7] default deny with empty allowlist")
with open(allowlist, "w") as f:
    f.write("# nothing allowed now\n")
os.utime(allowlist, (time.time(), time.time()))
resp = proxy_request(b"CONNECT github.com:443 HTTP/1.1\r\nHost: github.com\r\n\r\n")
check("even github.com denied when allowlist empty", b"403" in resp.split(b"\r\n", 1)[0], resp[:60].decode())

# ── [8] real network tunnel (self-skipping) ────────────────────────────
print("[8] real end-to-end CONNECT to github.com")
with open(allowlist, "w") as f:
    f.write("github.com\n")
os.utime(allowlist, (time.time(), time.time()))
s = socket.create_connection(("127.0.0.1", PROXY_PORT), timeout=15)
s.sendall(b"CONNECT github.com:443 HTTP/1.1\r\nHost: github.com\r\n\r\n")
s.settimeout(15)
try:
    head = b""
    while b"\r\n\r\n" not in head:
        head += s.recv(4096)
    status = head.split(b"\r\n", 1)[0]
    check("tunnel established to github.com", b"200" in status, status[:60].decode())
except (socket.timeout, OSError) as e:
    print(f"  skip (network blocked here): {e}")
s.close()

# ── [9] local-network guard (holds even through the '*' escape) ────────
print("[9] local-network guard")
with open(allowlist, "w") as f:
    f.write("*\n")
os.utime(allowlist, (time.time(), time.time()))
for target in ("10.0.0.1:80", "192.168.1.1:443", "169.254.169.254:80",
               "100.64.0.1:80", "[fd00::1]:443"):
    resp = proxy_request(f"CONNECT {target} HTTP/1.1\r\nHost: {target}\r\n\r\n".encode())
    check(f"{target} denied despite '*'", b"403" in resp.split(b"\r\n", 1)[0], resp[:60].decode())
resp = proxy_request(f"GET http://10.0.0.1/ HTTP/1.1\r\nHost: 10.0.0.1\r\nConnection: close\r\n\r\n".encode())
check("plain HTTP to LAN denied despite '*'", b"403" in resp.split(b"\r\n", 1)[0], resp[:60].decode())
resp = proxy_request(b"CONNECT 127.0.0.1:" + str(ORIGIN_PORT).encode() + b" HTTP/1.1\r\nHost: x\r\n\r\n")
check("loopback still allowed (proxy-local origin)", b"200" in resp.split(b"\r\n", 1)[0], resp[:60].decode())

proc.terminate()
origin.shutdown()

print(f"\n{PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
