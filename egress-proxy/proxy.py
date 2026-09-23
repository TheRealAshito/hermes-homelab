#!/usr/bin/env python3
"""hermes-homelab egress proxy — default-deny domain allowlist.

A minimal HTTP(S) forward/CONNECT proxy whose only job is to be the single
exit point for the sandboxed agent container. Nothing leaves unless the
requested host matches the allowlist file. This is an ALLOWLIST (default
deny), not a blocklist (default allow).

Allowlist file format (one rule per line, '#' comments):
    example.com         -> allows example.com and *.example.com
    *.example.com       -> same (leading '*.' is stripped)
    *                   -> allows EVERYTHING (escape hatch; removes the guard)

The file is re-read whenever its mtime changes, so edits apply live without
restarting the proxy.

Resolution order for rules: the user file (EGRESS_ALLOWLIST) is authoritative
if it exists — even when empty (empty = intentional deny-all). Only when the
file is MISSING does the baked-in default list apply; if neither exists,
everything is denied.
"""

import os
import socket
import select
import sys
import threading
import time

LISTEN_HOST = os.environ.get("EGRESS_LISTEN", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("EGRESS_PORT", "8888"))
ALLOWLIST_PATH = os.environ.get("EGRESS_ALLOWLIST", "/etc/egress/allowlist")
DEFAULT_PATH = os.environ.get("EGRESS_ALLOWLIST_DEFAULT", "/etc/egress/allowlist.default")

_rules_cache = {"mtime": None, "rules": None}
_rules_lock = threading.Lock()


def log(msg):
    print(f"[egress] {msg}", flush=True)


def _parse_rules(text):
    rules = set()
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip().lower()
        if not line:
            continue
        if line.startswith("*."):
            line = line[2:]
        rules.add(line)
    return rules


def load_rules():
    with _rules_lock:
        try:
            mtime = os.stat(ALLOWLIST_PATH).st_mtime
        except OSError:
            mtime = None
        if _rules_cache["rules"] is not None and _rules_cache["mtime"] == mtime:
            return _rules_cache["rules"]

        rules = set()
        for path in (ALLOWLIST_PATH, DEFAULT_PATH):
            try:
                with open(path) as f:
                    rules = _parse_rules(f.read())
            except OSError:
                continue
            # first EXISTING file is authoritative, even when empty
            # (empty user file = intentional deny-all; missing = use default)
            break
        _rules_cache["mtime"] = mtime
        _rules_cache["rules"] = rules
        log(f"allowlist loaded: {len(rules)} rule(s)")
        return rules


def host_allowed(host, rules):
    host = host.lower().strip(".")
    if "*" in rules:
        return True
    if host in rules:
        return True
    # suffix match: rule 'example.com' covers 'api.example.com'
    parts = host.split(".")
    for i in range(1, len(parts)):
        if ".".join(parts[i:]) in rules:
            return True
    return False


def deny(conn, host, port):
    log(f"DENY  {host}:{port}")
    body = f"blocked by egress allowlist: {host}:{port}\n".encode()
    resp = (
        b"HTTP/1.1 403 Forbidden\r\n"
        b"Content-Type: text/plain\r\n"
        b"Connection: close\r\n"
        + f"Content-Length: {len(body)}\r\n\r\n".encode()
        + body
    )
    try:
        conn.sendall(resp)
    except OSError:
        pass


def tunnel(cli, upstream):
    socks = [cli, upstream]
    try:
        while True:
            r, _, x = select.select(socks, [], socks, 300)
            if x or not r:
                break
            for s in r:
                data = s.recv(65536)
                if not data:
                    return
                (upstream if s is cli else cli).sendall(data)
    except OSError:
        pass
    finally:
        for s in (cli, upstream):
            try:
                s.close()
            except OSError:
                pass


def handle_connect(cli, host, port):
    rules = load_rules()
    if not host_allowed(host, rules):
        deny(cli, host, port)
        cli.close()
        return
    try:
        upstream = socket.create_connection((host, port), timeout=15)
    except OSError as e:
        log(f"FAIL  {host}:{port} ({e})")
        try:
            cli.sendall(b"HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n")
        except OSError:
            pass
        cli.close()
        return
    log(f"ALLOW {host}:{port} (connect)")
    cli.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
    tunnel(cli, upstream)


def handle_http(cli, first_line, headers, body):
    # Plain HTTP absolute-form request: "GET http://host:port/path HTTP/1.1"
    try:
        target = first_line.split(" ", 2)[1]
        rest = first_line.split(" ", 2)[2]
        hostport = target.split("//", 1)[1].split("/", 1)[0]
        path = "/" + target.split("//", 1)[1].split("/", 1)[1] if "/" in target.split("//", 1)[1] else "/"
        host, _, port = hostport.partition(":")
        port = int(port or 80)
    except (IndexError, ValueError):
        cli.sendall(b"HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n")
        cli.close()
        return

    rules = load_rules()
    if not host_allowed(host, rules):
        deny(cli, host, port)
        cli.close()
        return
    try:
        upstream = socket.create_connection((host, port), timeout=15)
    except OSError:
        cli.sendall(b"HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n")
        cli.close()
        return
    log(f"ALLOW {host}:{port} (http)")
    req = f"{first_line.split(' ', 1)[0]} {path} {rest}\r\n".encode() + headers + body
    upstream.sendall(req)
    tunnel(cli, upstream)


def handle(cli, addr):
    try:
        cli.settimeout(30)
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = cli.recv(65536)
            if not chunk:
                cli.close()
                return
            buf += chunk
        head, body = buf.split(b"\r\n\r\n", 1)
        lines = head.split(b"\r\n")
        first = lines[0].decode("latin-1")
        headers = b"\r\n".join(lines[1:]) + b"\r\n\r\n"

        if first.startswith("CONNECT "):
            hostport = first.split(" ", 2)[1]
            host, _, port = hostport.partition(":")
            handle_connect(cli, host, int(port or 443))
        else:
            handle_http(cli, first, headers, body)
    except Exception as e:  # never let one bad request kill the proxy
        log(f"ERROR {addr}: {e}")
        try:
            cli.close()
        except OSError:
            pass


def main():
    load_rules()
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((LISTEN_HOST, LISTEN_PORT))
    srv.listen(256)
    log(f"listening on {LISTEN_HOST}:{srv.getsockname()[1]} (default deny)")
    while True:
        cli, addr = srv.accept()
        threading.Thread(target=handle, args=(cli, addr), daemon=True).start()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
