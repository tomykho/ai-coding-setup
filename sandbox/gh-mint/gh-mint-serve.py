#!/usr/bin/env python3
"""gh-mint broker: answer "token for owner X" over a unix socket.

The sandbox gets a socket, never a credential. For an owner that has an App, each
answer is an installation token — 60 minutes, that installation's repositories and
permissions — so the worst case of a leaked sandbox is bounded by the App's grant
and by the hour, not by what the account can do. For an owner where no App can be
installed (someone else's account, where you are a collaborator) the same socket
serves a fine-grained PAT from $GH_MINT_HOME/tokens/<owner>: also never mounted
into the sandbox, but long-lived, so its own repo list and expiry are the boundary.

Protocol is deliberately trivial:  GET /token?owner=<login>  → the token,
GET /health → {"ok":true,...}. Only the owner of the socket can connect (0600),
and only tokens already narrowed by the App can be minted.

Tokens are cached in memory until 5 minutes before they expire, so a session
that pushes every minute still makes one API call an hour.
"""

import json
import os
import re
import socketserver
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler
from urllib.parse import parse_qs, urlparse

MINT = os.environ.get("GH_MINT_BIN") or os.path.join(
    os.path.dirname(os.path.realpath(__file__)), "gh-mint.sh"
)
DEFAULT_OWNER = os.environ.get("GH_MINT_OWNER", "").strip()
SKEW = 300  # re-mint this many seconds before expiry
OWNER_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$")  # also guards the env path
cache = {}
lock = threading.Lock()


def mint(owner):
    """(token, expires_at, cached?) — minting shells out so there is one impl."""
    with lock:
        ent = cache.get(owner)
        if ent and ent["deadline"] > time.time():
            return ent["token"], ent["expires_at"], True
    proc = subprocess.run(
        [MINT, "token", "--json", "--owner", owner],
        capture_output=True,
        text=True,
        timeout=60,
    )
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or f"gh-mint exited {proc.returncode}")
    try:
        data = json.loads(proc.stdout)
        token = data["token"]
    except (ValueError, KeyError):
        raise RuntimeError("gh-mint returned no token") from None
    expires_at = data.get("expires_at") or ""
    if not expires_at:
        # A static PAT (another user's account, you are only a collaborator).
        # Never cache it: rotation is "overwrite the file", and it must take
        # effect on the next request, not up to an hour later.
        return token, "", False
    deadline = time.time() + 3600 - SKEW
    if expires_at:
        try:
            deadline = (
                datetime.strptime(expires_at, "%Y-%m-%dT%H:%M:%SZ")
                .replace(tzinfo=timezone.utc)
                .timestamp()
                - SKEW
            )
        except ValueError:
            pass
    with lock:
        cache[owner] = {"token": token, "expires_at": expires_at, "deadline": deadline}
    return token, expires_at, False


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def log_message(self, fmt, *args):  # never log a token, and stay quiet
        pass

    def _send(self, code, body, ctype="text/plain; charset=utf-8"):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802 (http.server naming)
        url = urlparse(self.path)
        query = parse_qs(url.query)

        if url.path == "/health":
            with lock:
                owners = sorted(cache)
            self._send(200, json.dumps({"ok": True, "cached": owners}), "application/json")
            return

        if url.path not in ("/token", "/"):
            self._send(404, "not found\n")
            return

        owner = (query.get("owner") or [DEFAULT_OWNER])[0].strip()
        if not owner:
            self._send(400, "owner required\n")
            return
        if not OWNER_RE.match(owner):
            self._send(400, "bad owner\n")
            return
        try:
            token, expires_at, cached = mint(owner)
        except Exception as exc:  # noqa: BLE001 — report, never leak a key
            self._send(500, f"mint failed: {exc}\n")
            return
        self._send(200, token + "\n")


class UnixServer(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True
    allow_reuse_address = True

    def get_request(self):
        req, _ = super().get_request()
        return req, ("localhost", 0)


def main(argv):
    sock = argv[1] if len(argv) > 1 else os.environ.get(
        "GH_MINT_SOCK", f"/run/user/{os.getuid()}/gh-mint/gh-mint.sock"
    )
    os.umask(0o077)
    os.makedirs(os.path.dirname(sock), mode=0o700, exist_ok=True)
    try:
        os.unlink(sock)  # stale from a crash / a previous boot
    except FileNotFoundError:
        pass
    server = UnixServer(sock, Handler)
    os.chmod(sock, 0o600)
    print(f"gh-mint: listening on {sock}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        try:
            os.unlink(sock)
        except FileNotFoundError:
            pass


if __name__ == "__main__":
    sys.exit(main(sys.argv) or 0)
