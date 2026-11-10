#!/usr/bin/env bash
# test_idle_check.sh — decision-table tests for idle-check.sh.
# No root, no systemd, no real poweroff: DRY_RUN stays 1 and the signals are fake.
#
#   ./test_idle_check.sh
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CHECK=$HERE/idle-check.sh
TMP=$(mktemp -d)
FAKE_PID=
HOLDER_PID=
cleanup() {
  [ -n "$FAKE_PID" ] && kill "$FAKE_PID" 2>/dev/null
  [ -n "$HOLDER_PID" ] && kill "$HOLDER_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

pass=0
fail=0
NOW=$(date +%s)
OLD=$((NOW - 4 * 3600)) # 4h ago: past every threshold
PROC=idle-test-nonexistent
SSH_T=65112 # stands in for the SSH port

mkdir -p "$TMP/sessions"
: >"$TMP/hold"

iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.000Z; }

fake_db() { # fake_db <epoch> [path] [request_type]: storage.sqlite with one call_logs row
  rm -f "$TMP/storage.sqlite"
  python3 - "$TMP/storage.sqlite" "$(iso "$1")" "${2-}" "${3-}" <<'PY'
import sqlite3, sys
null = lambda v: v if v else None
db = sqlite3.connect(sys.argv[1])
db.execute("create table call_logs(timestamp text, path text, request_type text)")
db.execute("insert into call_logs values (?, ?, ?)", (sys.argv[2], null(sys.argv[3]), null(sys.argv[4])))
db.commit()
PY
}

pi_session() { # pi_session <epoch>: one transcript with a chosen mtime
  local f=$TMP/sessions/2026-01-01T00-00-00-000Z_test.jsonl
  printf '{"type":"message"}\n' >"$f"
  touch -d "@$1" "$f"
}

# A stand-in "pi" process: sets its own /proc/<pid>/comm, so pgrep -x finds it.
fake_pi() {
  python3 -c '
import time
with open("/proc/self/comm", "w") as f:
    f.write("idle-fake-pi")
time.sleep(300)
' &
  FAKE_PID=$!
  for _ in $(seq 50); do
    pgrep -x idle-fake-pi >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  echo "could not start fake pi process" >&2
  return 1
}

run() { # run [extra env assignments...]
  env \
    IDLE_CHECK_CONF=/dev/null \
    TEST_CONF="$TMP/test.conf" \
    NOW="$NOW" \
    BOOT_EPOCH=$((NOW - 6 * 3600)) \
    PI_USER="$(id -un)" \
    PI_HOME="$TMP" \
    PI_SESSIONS_DIR="$TMP/sessions" \
    OMNI_DB="$TMP/storage.sqlite" \
    PI_PROC_NAME="$PROC" \
    SSH_PORT="$SSH_T" \
    DRY_RUN=1 \
    HOLD_FILE="$TMP/hold" \
    IDLE_MIN=60 \
    OPEN_MIN=120 \
    "$@" "$CHECK" --status 2>&1
}

expect() { # expect <keep|shutdown> <label> [extra env...]
  local want=$1 label=$2
  shift 2
  local rc out
  out=$(run "$@")
  rc=$?
  if { [ "$want" = shutdown ] && [ "$rc" = 10 ]; } || { [ "$want" = keep ] && [ "$rc" = 0 ]; }; then
    pass=$((pass + 1))
    printf 'ok   %-40s %s\n' "$label" "${out#verdict=}"
  else
    fail=$((fail + 1))
    printf 'FAIL %-40s want=%s rc=%s\n     %s\n' "$label" "$want" "$rc" "$out"
  fi
}

echo "== activity signals =="
rm -f "$TMP/hold"
fake_db "$OLD"
pi_session "$OLD"
expect shutdown "4h old, nothing running"

fake_db "$((NOW - 5 * 60))" /v1/chat/completions
expect keep "omni request 5m ago"

fake_db "$OLD"
pi_session "$((NOW - 5 * 60))"
expect keep "pi session written 5m ago"

fake_db "$((NOW - 90 * 60))"
pi_session "$((NOW - 90 * 60))"
expect shutdown "90m idle, no session"

echo "== only allowlisted paths count ="
for p in /api/providers/test /api/providers/abc/models /v1/embeddings /healthz; do
  fake_db "$((NOW - 5 * 60))" "$p"
  pi_session "$OLD"
  expect shutdown "5m ago on $p, ignored"
done

for p in /v1/messages /v1/responses /v1/chat/completions /v1/chat/completions/tool; do
  fake_db "$((NOW - 5 * 60))" "$p"
  pi_session "$OLD"
  expect keep "5m ago on $p"
done

fake_db "$((NOW - 5 * 60))" /v1/embeddings
pi_session "$OLD"
expect keep "unlisted path counts via OMNI_ALLOW_PATHS=/v1/" OMNI_ALLOW_PATHS=/v1/

expect keep "allowlist empty counts every row" OMNI_ALLOW_PATHS=

expect shutdown "internal list only silences the warning, not the rule" OMNI_INTERNAL_PATHS=

fake_db "$((NOW - 5 * 60))"
pi_session "$OLD"
expect shutdown "row with no path, ignored"

echo "== 1h without a session, 2h with one =="
fake_pi || exit 1
PROC=idle-fake-pi

fake_db "$((NOW - 90 * 60))"
pi_session "$((NOW - 90 * 60))"
expect keep "90m idle + pi process open"

fake_db "$((NOW - 130 * 60))"
pi_session "$((NOW - 130 * 60))"
expect shutdown "130m idle + pi process open"

fake_db "$((NOW - 30 * 60))"
pi_session "$((NOW - 30 * 60))"
expect shutdown "30m idle + pi open, OPEN_MIN=20" OPEN_MIN=20

echo "== session sockets =="
ip=$(hostname -I 2>/dev/null | awk '{print $1}')

hold_sockets() { # hold_sockets <port...>: listen and connect to self, stay up 120s
  python3 - "$ip" "$@" <<'PY' &
import socket, sys, time
ip, ports = sys.argv[1], [int(p) for p in sys.argv[2:]]
srv = []
for p in ports:
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((ip, p))
    s.listen(1)
    srv.append(s)
cli = [socket.create_connection((ip, p), timeout=5) for p in ports]
time.sleep(120)
PY
  HOLDER_PID=$!
  sleep 1
}

if [ -n "$ip" ]; then
  PROC=idle-test-nonexistent

  hold_sockets "$SSH_T"
  fake_db "$((NOW - 90 * 60))"
  pi_session "$((NOW - 90 * 60))"
  expect keep "90m idle + SSH socket open"
  expect shutdown "90m idle + SSH socket, SSH_PORT disabled" SSH_PORT=
  kill "$HOLDER_PID" 2>/dev/null
  HOLDER_PID=
else
  echo "skip  no routable IP for the socket tests"
fi

echo "== hard blockers =="
: >"$TMP/hold"
fake_db "$OLD"
pi_session "$OLD"
expect keep "hold file present"
rm -f "$TMP/hold"

echo "== test mode ="
printf 'IDLE_MIN=20\nOPEN_MIN=20\nGRACE_SEC=5\nUNTIL=%s\n' "$((NOW + 600))" >"$TMP/test.conf"
fake_db "$((NOW - 30 * 60))" /v1/chat/completions
pi_session "$((NOW - 30 * 60))"
expect shutdown "30m idle, test tier 20m"
expect keep "no test file, real tier 60m" TEST_CONF="$TMP/absent.conf"
rm -f "$TMP/test.conf"

printf 'IDLE_MIN=5\nOPEN_MIN=5\nUNTIL=%s\n' "$((NOW - 60))" >"$TMP/test.conf"
expect keep "expired test file ignored (would be 5m)"
[ -e "$TMP/test.conf" ] && echo "FAIL expired test file not removed" && fail=$((fail + 1))

echo "== disabled =="
expect keep "IDLE_MIN=0 and OPEN_MIN=0" IDLE_MIN=0 OPEN_MIN=0

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
