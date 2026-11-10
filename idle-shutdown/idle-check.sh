#!/usr/bin/env bash
# idle-check.sh — power this machine off when no AI client is using it.
#
#   activity = newest of: OmniRoute request log, pi transcript write, boot time
#   session  = a pi process, or a live connection on the SSH port
#   blockers = a pi tool still running, dpkg/apt holding the lock, hold file
#
# Power off when activity is older than OPEN_MIN (session) or IDLE_MIN (no session),
# and no blocker is set. A session only buys time; it never resets the clock.
#
# Exit: 0 = keep running, 10 = would power off, 1 = error.
# Usage: idle-check.sh [--status] [--quiet]
set -uo pipefail

CONF=${IDLE_CHECK_CONF:-/etc/idle-check.conf}
# shellcheck disable=SC1090
[ -r "$CONF" ] && . "$CONF"

# Test mode (idle-ctl test): short tiers for a trial run. Kept in /run, so it is gone
# after a reboot, and it expires on its own — a trial must never become the default.
TEST_CONF=${TEST_CONF:-/run/idle-shutdown-test}
TEST_ACTIVE=
if [ -e "$TEST_CONF" ]; then
  # Only trust a root-owned file, or — for an unprivileged run such as `idle-ctl status`
  # — one owned by the caller. The service runs as root, so a file another user can
  # rewrite must never be sourced.
  owner=$(stat -c %U "$TEST_CONF" 2>/dev/null)
  trusted=0
  [ "$owner" = root ] && trusted=1
  [ "$(id -u)" != 0 ] && [ "$owner" = "$(id -un)" ] && trusted=1
  if [ "$trusted" = 0 ]; then
    printf '%s: ignoring %s: owned by %s\n' "${0##*/}" "$TEST_CONF" "${owner:-?}" >&2
  else
    until_epoch=$(sed -n 's/^UNTIL=//p' "$TEST_CONF" 2>/dev/null | tail -1)
    if [ -n "$until_epoch" ] && [ "$(date +%s)" -ge "$until_epoch" ] 2>/dev/null; then
      rm -f "$TEST_CONF" 2>/dev/null
      printf '%s: test mode expired, back to the configured tiers\n' "${0##*/}" >&2
    else
      # shellcheck disable=SC1090
      . "$TEST_CONF" && TEST_ACTIVE=1
    fi
  fi
fi

# ── Defaults (conf file / environment override) ─────────────────────────────
DRY_RUN=${DRY_RUN:-1}         # 1 = log the decision, never power off
IDLE_MIN=${IDLE_MIN:-60}      # minutes of no activity, no session open
OPEN_MIN=${OPEN_MIN:-120}     # minutes of no activity, session still open
GRACE_SEC=${GRACE_SEC:-60}    # warning before poweroff, then one re-check
SSH_PORT=${SSH_PORT-22}      # empty = ignore SSH sessions
PI_PROC_NAME=${PI_PROC_NAME:-pi}
PI_USER=${PI_USER:-}
PI_HOME=${PI_HOME:-}
PI_SESSIONS_DIR=${PI_SESSIONS_DIR:-}
OMNI_DB=${OMNI_DB:-}
# What counts as a real client request. Default-deny: only these path prefixes reset the
# clock, so any housekeeping endpoint OmniRoute adds later is ignored by construction.
# call_logs also records connection health tests (hourly, on /api/providers/test) and
# model syncs; counting those means the clock never reaches the threshold.
OMNI_ALLOW_PATHS=${OMNI_ALLOW_PATHS-/v1/messages,/v1/responses,/v1/chat/completions}
# Paths that are known housekeeping: skipped without a word. Anything else skipped is
# reported to the journal, so a real endpoint missing from the allowlist is visible.
OMNI_INTERNAL_PATHS=${OMNI_INTERNAL_PATHS-/api/}
HOLD_FILE=${HOLD_FILE:-/run/idle-shutdown-hold}
NOW=${NOW:-}                  # epoch override, for tests
BOOT_EPOCH=${BOOT_EPOCH:-}    # boot override, for tests

STATUS=0
QUIET=0
for arg in "$@"; do
  case $arg in
    --status) STATUS=1 ;;
    --quiet) QUIET=1 ;;
    -h | --help)
      sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      printf '%s: unknown argument: %s\n' "${0##*/}" "$arg" >&2
      exit 1
      ;;
  esac
done

log() { [ "$QUIET" = 1 ] || printf '%s %s\n' "$(date -Is)" "$*"; }

die() {
  printf '%s: %s\n' "${0##*/}" "$*" >&2
  exit 1
}

# ── Resolve paths from the target user ──────────────────────────────────────
resolve_user() {
  if [ -z "$PI_USER" ]; then
    if [ "$(id -u)" = 0 ]; then
      local h
      for h in /home/*; do
        if [ -d "$h/.pi" ]; then
          PI_USER=$(stat -c %U "$h")
          PI_HOME=$h
          break
        fi
      done
    else
      PI_USER=$(id -un)
      PI_HOME=$HOME
    fi
  fi
  [ -n "$PI_USER" ] || die "cannot determine PI_USER; set it in $CONF"
  if [ -z "$PI_HOME" ]; then
    PI_HOME=$(getent passwd "$PI_USER" | cut -d: -f6)
  fi
  [ -n "$PI_HOME" ] || die "cannot determine PI_HOME for $PI_USER"
  : "${PI_SESSIONS_DIR:=$PI_HOME/.pi/agent/sessions}"
  : "${OMNI_DB:=$PI_HOME/.omniroute/storage.sqlite}"
}

# ── Signals ─────────────────────────────────────────────────────────────────
ts_to_epoch() { date -d "$1" +%s 2>/dev/null; }

# Newest OmniRoute request on an allowlisted path, from any machine. Default-deny: the
# table also holds OmniRoute's own traffic (provider health tests hourly, model syncs),
# and counting that means the clock never reaches the threshold. Rows are written at
# completion, so a request that is still streaming has no row yet — pi_busy covers
# the local case.
omni_last_request() {
  [ -r "$OMNI_DB" ] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  local ts
  ts=$(python3 - "$OMNI_DB" "$OMNI_ALLOW_PATHS" "$OMNI_INTERNAL_PATHS" "${NOW:-$(date +%s)}" "$IDLE_MIN" <<'PY'
import datetime, sqlite3, sys

db_path, allow_s, internal_s = sys.argv[1], sys.argv[2], sys.argv[3]
cutoff = datetime.datetime.fromtimestamp(
    int(sys.argv[4]) - int(sys.argv[5]) * 60, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")

def prefixes(s):
    return [p for p in (x.strip() for x in s.split(",")) if p]

def like(p):  # entries are literal prefixes, so escape LIKE's own metacharacters
    return p.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%"

def any_of(ps):
    return " or ".join("path like ? escape '\\'" for _ in ps)

def none_of(ps):
    # A NULL path never matches a LIKE, so spell out "not one of ours".
    return "(path is null or not (%s))" % any_of(ps)

allow, internal = prefixes(allow_s), prefixes(internal_s)

try:
    # mode=ro, never immutable: the live WAL holds the newest rows.
    db = sqlite3.connect("file:%s?mode=ro" % db_path, uri=True, timeout=3)

    def newest(cond, args):
        row = db.execute("select max(timestamp) from call_logs where %s" % cond, args).fetchone()
        return (row and row[0]) or None

    try:
        if allow:
            ts = newest(any_of(allow), [like(p) for p in allow])
        else:
            ts = newest("1=1", [])  # allowlist disabled: count every row
    except Exception as e:
        # Schema drift must never look like "no activity" — that would power off
        # while requests are flowing. Fall back to the unfiltered newest row.
        sys.stderr.write("idle-check: call_logs filter failed (%s); using unfiltered rows\n" % e)
        ts = newest("1=1", [])
    sys.stdout.write(ts or "")

    # What did we skip? Known housekeeping is silent; anything else is worth a line in
    # the journal, or a real endpoint missing from the allowlist stays invisible.
    if allow and ts:
        conds, args = [none_of(allow)], [like(p) for p in allow]
        if internal:
            conds.append(none_of(internal))
            args.extend(like(p) for p in internal)
        row = db.execute(
            "select max(timestamp), path from call_logs where %s" % " and ".join(conds),
            args).fetchone()
        if row and row[0] and row[0] >= cutoff and row[1] not in (None, "", "unknown"):
            sys.stderr.write(
                "idle-check: ignoring call_logs path %s at %s; add it to OMNI_ALLOW_PATHS "
                "if that is real traffic\n" % (row[1], row[0]))
except Exception:
    pass
PY
  )
  [ -n "$ts" ] || return 1
  ts_to_epoch "$ts"
}

# Newest write to any pi transcript. An open-but-AFK TUI writes nothing.
pi_last_write() {
  [ -d "$PI_SESSIONS_DIR" ] || return 1
  local m
  m=$(find "$PI_SESSIONS_DIR" -type f -name '*.jsonl' -printf '%T@\n' 2>/dev/null |
    sort -rn | head -1 | cut -d. -f1)
  [ -n "$m" ] || return 1
  printf '%s\n' "$m"
}

pi_pids() {
  if [ -n "$PI_USER" ]; then
    pgrep -u "$PI_USER" -x "$PI_PROC_NAME" 2>/dev/null && return 0
  fi
  pgrep -x "$PI_PROC_NAME" 2>/dev/null
}

# A session holding this host open: established connections to <port> from anywhere
# but this host. Loopback peers are excluded (an `ssh localhost` is not a session).
connections_on() {
  local port=$1 n
  [ -n "$port" ] || {
    printf '0\n'
    return 0
  }
  command -v ss >/dev/null 2>&1 || {
    printf '0\n'
    return 0
  }
  n=$(ss -Htn state established "( sport = :$port )" 2>/dev/null |
    awk '{print $4}' |
    grep -cvE '^(127\.[0-9.]+|\[::1\]|\[::ffff:127\.)')
  case $n in '' | *[!0-9]*) n=0 ;; esac
  printf '%s\n' "$n"
}

# pi is running a tool (bash, ...) — never pull the plug mid-command.
pi_busy() {
  local p c
  for p in $(pi_pids); do
    for c in $(pgrep -P "$p" 2>/dev/null); do
      [ "$(ps -o stat= -p "$c" 2>/dev/null | cut -c1)" = Z ] && continue
      return 0
    done
  done
  return 1
}

# Never power off in the middle of an upgrade.
pkg_busy() {
  if command -v fuser >/dev/null 2>&1; then
    fuser -s /var/lib/dpkg/lock-frontend 2>/dev/null && return 0
    fuser -s /var/lib/dpkg/lock 2>/dev/null && return 0
  fi
  pgrep -x 'dpkg|apt|apt-get|dpkg-deb' >/dev/null 2>&1 && return 0
  return 1
}

human_age() {
  local s=$1
  if [ "$s" -lt 0 ] 2>/dev/null; then
    printf '?'
  elif [ "$s" -lt 3600 ]; then
    printf '%dm' $((s / 60))
  else
    printf '%dh%02dm' $((s / 3600)) $(((s % 3600) / 60))
  fi
}

# ── Evaluate ────────────────────────────────────────────────────────────────
# Sets DECISION (keep|shutdown), IDLE_SEC, TIER_MIN, REASONS, BLOCKERS,
# and A_OMNI / A_PI / A_BOOT ages in seconds (-1 = unknown).
evaluate() {
  local now boot last last_src a pids ssh

  now=${NOW:-$(date +%s)}
  boot=${BOOT_EPOCH:-$(awk '/^btime/ {print $2}' /proc/stat)}

  A_OMNI=-1
  A_PI=-1
  a=$(omni_last_request) && A_OMNI=$((now - a))
  a=$(pi_last_write) && A_PI=$((now - a))
  A_BOOT=$((now - boot))

  last=$boot
  last_src=boot
  if [ "$A_OMNI" -ge 0 ] && [ $((now - A_OMNI)) -gt "$last" ]; then
    last=$((now - A_OMNI))
    last_src=omni
  fi
  if [ "$A_PI" -ge 0 ] && [ $((now - A_PI)) -gt "$last" ]; then
    last=$((now - A_PI))
    last_src=pi
  fi
  IDLE_SEC=$((now - last))

  # Session present?
  local reasons=""
  pids=$(pi_pids | tr '\n' ' ' | sed 's/ *$//')
  [ -n "$pids" ] && reasons="pi($pids)"
  ssh=$(connections_on "$SSH_PORT")
  [ "${ssh:-0}" -gt 0 ] && reasons="${reasons:+$reasons,}ssh($ssh)"
  if [ -n "$reasons" ]; then
    TIER_MIN=$OPEN_MIN
  else
    TIER_MIN=$IDLE_MIN
  fi
  REASONS=${reasons:--}

  # Blockers
  local blockers=""
  [ -e "$HOLD_FILE" ] && blockers="${blockers:+$blockers,}hold-file"
  pi_busy && blockers="${blockers:+$blockers,}pi-busy"
  pkg_busy && blockers="${blockers:+$blockers,}dpkg/apt"
  BLOCKERS=${blockers:--}

  if [ "$IDLE_MIN" -le 0 ] && [ "$OPEN_MIN" -le 0 ]; then
    DECISION=keep
    REASONS="$REASONS,disabled"
  elif [ "$IDLE_SEC" -ge $((TIER_MIN * 60)) ] && [ "$BLOCKERS" = - ]; then
    DECISION=shutdown
  else
    DECISION=keep
  fi

  printf 'verdict=%s idle=%s tier=%sm session=%s last=%s omni=%s pi=%s boot=%s blockers=%s%s\n' \
    "$DECISION" "$(human_age "$IDLE_SEC")" "$TIER_MIN" "$REASONS" "$last_src" \
    "$(human_age "$A_OMNI")" "$(human_age "$A_PI")" "$(human_age "$A_BOOT")" "$BLOCKERS" \
    "${TEST_ACTIVE:+ mode=test}"

}

# ── Main ────────────────────────────────────────────────────────────────────
resolve_user
evaluate

if [ "$STATUS" = 1 ]; then
  [ "$DECISION" = shutdown ] && exit 10
  exit 0
fi

[ "$DECISION" = shutdown ] || exit 0

if [ "$DRY_RUN" = 1 ]; then
  log "DRY_RUN=1: would power off (idle=$(human_age "$IDLE_SEC") tier=${TIER_MIN}m)"
  exit 10
fi

log "idle $(human_age "$IDLE_SEC") >= ${TIER_MIN}m with no activity; powering off in ${GRACE_SEC}s"
log "cancel with: idle-ctl hold"
if command -v wall >/dev/null 2>&1; then
  printf 'idle-check: no AI activity for %s, powering off in %ss.\n  cancel now with: sudo idle-ctl hold\n' \
    "$(human_age "$IDLE_SEC")" "$GRACE_SEC" | wall 2>/dev/null || true
fi
sleep "$GRACE_SEC"

evaluate
if [ "$DECISION" = shutdown ]; then
  log "powering off now"
  systemctl poweroff || shutdown -h now
  exit 0
fi
log "grace re-check says keep; not powering off"
exit 0
