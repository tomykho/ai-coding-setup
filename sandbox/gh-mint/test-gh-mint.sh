#!/usr/bin/env bash
# test-gh-mint.sh — exercise the token broker without a GitHub App.
#
# A stub GitHub API stands in for api.github.com, so the JWT signing, the mint
# request, the socket broker, the gh shim and the git credential helper can all
# be tested offline. Nothing here touches github.com or needs a real key.
#
#   ./test-gh-mint.sh          # quiet: exit 0 on success
#   ./test-gh-mint.sh -v       # show each check
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
VERBOSE=${1:-}
TMP=$(mktemp -d)
PORT_FILE=$TMP/port
MINT_COUNT=$TMP/mints
PASS=0 FAIL=0

cleanup() {
  [ -n "${STUB_PID:-}" ] && kill "$STUB_PID" 2>/dev/null
  [ -n "${SERVE_PID:-}" ] && kill "$SERVE_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

ok() { PASS=$((PASS + 1)); [ -n "$VERBOSE" ] && printf '  ok   %s\n' "$*"; return 0; }
no() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$*" >&2; }
check() { # check <description> <command...>
  local d=$1; shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else no "$d"; fi
}
eq() { # eq <description> <got> <want>
  if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2', want '$3')"; fi
}

# ── fixtures ────────────────────────────────────────────────────────────────
export GH_MINT_HOME=$TMP/gh-mint
APPS=$GH_MINT_HOME/apps
mkdir -p "$APPS" "$GH_MINT_HOME/keys"
openssl genrsa -out "$GH_MINT_HOME/keys/tomykho.pem" 2048 2>/dev/null
chmod 600 "$GH_MINT_HOME/keys/tomykho.pem"
: >"$MINT_COUNT"

cat >"$APPS/tomykho.env" <<EOF
APP_ID=424242
INSTALL_ID=999
KEY_FILE=$GH_MINT_HOME/keys/tomykho.pem
EOF

# ── stub api.github.com ─────────────────────────────────────────────────────
cat >"$TMP/stub.py" <<'PY'
import json, os, sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT_FILE, COUNT = sys.argv[1], sys.argv[2]
seen = []

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    def log_message(self, *a): pass

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        auth = self.headers.get("Authorization", "")
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        with open(COUNT + ".requests", "a") as f:
            f.write(auth + "\n" + body.decode() + "\n")
        n = int(open(COUNT).read().strip() or 0) if os.path.exists(COUNT) else 0
        n += 1
        open(COUNT, "w").write(str(n))
        exp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + 3600))
        self._json(201, {
            "token": "ghs_stub%d" % n,
            "expires_at": exp,
            "permissions": {"contents": "write", "pull_requests": "write"},
            "repositories": [{"full_name": "tomykho/ai-coding-setup"}],
        })

    def do_GET(self):
        if self.path.startswith("/app/installations"):
            self._json(200, [{"id": 999, "account": {"login": "tomykho"},
                              "repository_selection": "selected"}])
        elif self.path.startswith("/user/repos"):
            self._json(200, [{"full_name": "essedigital/website"},
                             {"full_name": "essedigital/api"}])
        elif self.path.startswith("/user"):
            self._json(200, {"login": "tomykho"})
        elif self.path.startswith("/installation/repositories"):
            if not self.headers.get("Authorization", "").startswith("Bearer ghs_stub"):
                return self._json(401, {"message": "Bad credentials"})
            self._json(200, {"repositories": [
                {"full_name": "tomykho/ai-coding-setup"}]})
        else:
            self._json(404, {"message": "Not Found"})

srv = HTTPServer(("127.0.0.1", 0), H)
open(PORT_FILE, "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY

python3 "$TMP/stub.py" "$PORT_FILE" "$MINT_COUNT" &
STUB_PID=$!
for _ in $(seq 100); do [ -s "$PORT_FILE" ] && break; sleep 0.05; done
[ -s "$PORT_FILE" ] || { echo "stub API did not start" >&2; exit 1; }

STUB_PORT=$(cat "$PORT_FILE")
export GH_MINT_API="http://127.0.0.1:$STUB_PORT"
export GH_MINT_SOCK=$TMP/run/gh-mint.sock
MINT=$HERE/gh-mint.sh

# ── 1. JWT ──────────────────────────────────────────────────────────────────
tok=$("$MINT" token --owner tomykho 2>"$TMP/err")
eq "token minted from a stub API" "$tok" "ghs_stub1"

jwt=$(head -1 "$MINT_COUNT.requests" | sed 's/^Bearer //')
eq "JWT has three segments" "$(printf '%s' "$jwt" | awk -F. '{print NF}')" 3
b64d() { # b64d <b64url>: decode without requiring GNU base64 to guess padding
  local s
  s=$(printf '%s' "$1" | tr '_-' '/+')
  case $((${#s} % 4)) in 2) s="$s==" ;; 3) s="$s=" ;; esac
  printf '%s' "$s" | base64 -d 2>/dev/null
}

hdr=$(b64d "${jwt%%.*}")
eq "JWT header alg" "$(printf '%s' "$hdr" | jq -r .alg)" "RS256"
payload=$(b64d "$(printf '%s' "$jwt" | cut -d. -f2)")
eq "JWT iss is the app id" "$(printf '%s' "$payload" | jq -r .iss)" "424242"
ttl=$(($(printf '%s' "$payload" | jq -r .exp) - $(printf '%s' "$payload" | jq -r .iat)))
check "JWT lifetime within GitHub's 10 minute cap ($((ttl - 60))s)" test "$ttl" -le 660

# Signature verifies against the App's public key.
printf '%s' "${jwt%.*}" >"$TMP/sig.in"   # h.p, exactly the signed bytes
b64d "${jwt##*.}" >"$TMP/sig.bin"
openssl rsa -in "$GH_MINT_HOME/keys/tomykho.pem" -pubout -out "$TMP/pub.pem" 2>/dev/null
check "JWT signature verifies" openssl dgst -sha256 -verify "$TMP/pub.pem" \
  -signature "$TMP/sig.bin" "$TMP/sig.in"

# ── 2. request body / narrowing ─────────────────────────────────────────────
eq "no narrowing requested by default" "$(sed -n 2p "$MINT_COUNT.requests")" "{}"
cat >>"$APPS/tomykho.env" <<'EOF'
REPOS=ai-coding-setup,dotfiles
PERMISSIONS=contents:write,pull_requests:write
EOF
: >"$MINT_COUNT.requests"
"$MINT" token --owner tomykho >/dev/null 2>&1
body=$(sed -n 2p "$MINT_COUNT.requests")
eq "REPOS narrowed in the request" "$(printf '%s' "$body" | jq -c .repositories)" '["ai-coding-setup","dotfiles"]'
eq "PERMISSIONS narrowed in the request" "$(printf '%s' "$body" | jq -r '.permissions.contents')" "write"
grep -v '^REPOS=\|^PERMISSIONS=' "$APPS/tomykho.env" >"$TMP/app.env" &&
  mv "$TMP/app.env" "$APPS/tomykho.env"

# ── 3. check subcommand ─────────────────────────────────────────────────────
out=$("$MINT" check --owner tomykho 2>&1)
check "check reports the scope" grep -q "scope 1 repo" <<<"$out"
check "check names the hour limit" grep -q "60 min hard limit" <<<"$out"

# ── 4. socket broker ────────────────────────────────────────────────────────
: >"$MINT_COUNT"
"$MINT" serve >"$TMP/serve.log" 2>&1 &
SERVE_PID=$!
for _ in $(seq 100); do [ -S "$GH_MINT_SOCK" ] && break; sleep 0.05; done
[ -S "$GH_MINT_SOCK" ] || { echo "broker socket never appeared: $(cat "$TMP/serve.log")" >&2; exit 1; }

eq "socket is 0600" "$(stat -c %a "$GH_MINT_SOCK")" "600"
t1=$(curl -sfN --unix-socket "$GH_MINT_SOCK" 'http://localhost/token?owner=tomykho')
eq "broker returns a token" "$t1" "ghs_stub1"
t2=$(curl -sfN --unix-socket "$GH_MINT_SOCK" 'http://localhost/token?owner=tomykho')
eq "second call served from cache" "$t2" "ghs_stub1"
eq "cached: one mint for two calls" "$(cat "$MINT_COUNT")" "1"
check "unknown owner is an error" bash -c \
  "! curl -sfN --unix-socket '$GH_MINT_SOCK' 'http://localhost/token?owner=nope'"
eq "path traversal rejected" \
  "$(curl -s -o /dev/null -w '%{http_code}' --unix-socket "$GH_MINT_SOCK" \
    'http://localhost/token?owner=..%2F..%2Fetc')" "400"
eq "health endpoint" \
  "$(curl -sfN --unix-socket "$GH_MINT_SOCK" http://localhost/health | jq -r .ok)" "true"

# ── 5. git credential helper (useHttpPath) ──────────────────────────────────
cred=$(printf 'protocol=https\nhost=github.com\npath=tomykho/ai-coding-setup.git\n\n' |
  GH_MINT_SOCK=$GH_MINT_SOCK "$HERE/bin/gh-mint-credential" get)
eq "helper username" "$(sed -n 's/^username=//p' <<<"$cred")" "x-access-token"
eq "helper password is a token" "$(sed -n 's/^password=//p' <<<"$cred")" "ghs_stub1"
eq "helper store is a no-op" \
  "$(printf 'protocol=https\nhost=github.com\n\n' | "$HERE/bin/gh-mint-credential" store; echo "rc=$?")" \
  "rc=0"

# ── 6. gh shim ──────────────────────────────────────────────────────────────
mkdir -p "$TMP/wt" && cd "$TMP/wt" && git init -q . &&
  git remote add origin https://github.com/tomykho/ai-coding-setup.git
# shellcheck disable=SC2016  # the generated script expands $GH_TOKEN itself
printf '#!/bin/sh\nprintf "%%s\\n" "$GH_TOKEN"\n' >"$TMP/fake-gh"
chmod +x "$TMP/fake-gh"
eq "shim injects GH_TOKEN for the repo owner" \
  "$(GH_MINT_SOCK=$GH_MINT_SOCK GH_MINT_REAL_GH=$TMP/fake-gh "$HERE/bin/gh" --version 2>&1)" \
  "ghs_stub1"

git remote set-url origin https://github.com/stranger/repo.git
if GH_MINT_SOCK=$GH_MINT_SOCK GH_MINT_REAL_GH=$TMP/fake-gh \
  "$HERE/bin/gh" --version >/dev/null 2>&1; then
  no "shim must fail when the repo owner has no App"
else
  ok "shim fails when the repo owner has no App"
fi
eq "shim explains the failure" \
  "$(GH_MINT_SOCK=$GH_MINT_SOCK GH_MINT_REAL_GH=$TMP/fake-gh "$HERE/bin/gh" --version 2>&1 >/dev/null |
    grep -c 'cannot mint')" "1"

git remote set-url origin git@github.com:tomykho/ai-coding-setup.git
eq "scp-style remote resolves the owner too" \
  "$(GH_MINT_SOCK=$GH_MINT_SOCK GH_MINT_REAL_GH=$TMP/fake-gh "$HERE/bin/gh" --version 2>&1)" \
  "ghs_stub1"

# ── 7. an owner no App can serve: a PAT, same socket, no cache ──────────────
TOKENS=$GH_MINT_HOME/tokens
mkdir -p "$TOKENS"
printf 'github_pat_stubcollab\n' >"$TOKENS/essedigital"
chmod 644 "$TOKENS/essedigital"
eq "PAT owner served from the token file" \
  "$("$MINT" token --owner essedigital 2>/dev/null)" "github_pat_stubcollab"
eq "a loose PAT mode is called out" \
  "$("$MINT" token --owner essedigital 2>&1 >/dev/null | grep -c 'chmod 600')" "1"
chmod 600 "$TOKENS/essedigital"
eq "kind is reported as pat" \
  "$("$MINT" token --owner essedigital --json | jq -r .kind)" "pat"
eq "broker serves the PAT" \
  "$(curl -sfN --unix-socket "$GH_MINT_SOCK" 'http://localhost/token?owner=essedigital')" \
  "github_pat_stubcollab"
printf 'github_pat_rotated\n' >"$TOKENS/essedigital"
eq "rotating the file takes effect at once" \
  "$(curl -sfN --unix-socket "$GH_MINT_SOCK" 'http://localhost/token?owner=essedigital')" \
  "github_pat_rotated"
eq "a PAT never enters the cache" \
  "$(curl -sfN --unix-socket "$GH_MINT_SOCK" http://localhost/health |
    jq -r '.cached | index("essedigital") // "none"')" "none"
eq "owners lists both kinds" \
  "$("$MINT" owners | awk '{print $1" "$2}' | sort | tr '\n' ' ')" \
  "essedigital token tomykho app "
out=$("$MINT" check --owner essedigital 2>&1)
check "check says a PAT is not hourly" grep -q "does not die in an hour" <<<"$out"
check "check lists the PAT's repos" grep -q "scope 2 repo" <<<"$out"
mkdir -p "$TMP/tokonly/tokens"
printf 'github_pat_only\n' >"$TMP/tokonly/tokens/only"
chmod 600 "$TMP/tokonly/tokens/only"
eq "owner resolves from a token file alone" \
  "$(GH_MINT_HOME=$TMP/tokonly "$MINT" token)" "github_pat_only"

# ── 8. missing config is a clear error ──────────────────────────────────────
eq "no App configured" \
  "$(GH_MINT_HOME=$TMP/empty "$MINT" token --owner nobody 2>&1 | sed 's/^[^:]*: //' | head -1)" \
  "no App configured for owner 'nobody' (expected $TMP/empty/apps/nobody.env)"

printf '\n%s: %d passed, %d failed\n' "${0##*/}" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
