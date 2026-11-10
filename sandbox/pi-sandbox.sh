#!/usr/bin/env bash
# pi-sandbox.sh — run pi with access to one project tree and nothing else.
#
# Same UID as the normal user, so pi's transcripts, OmniRoute traffic and the
# idle-shutdown check all keep working unchanged. The boundary is a bubblewrap
# namespace: /home is not mounted at all, only $PI_SANDBOX_ROOT is.
#
#   pi-sandbox.sh [pi args...]        run pi sandboxed (PiG when installed)
#   pi-sandbox.sh --shell             same boundary, plain bash (for debugging)
#   pi-sandbox.sh --check             show what the sandbox can and cannot see
#
# Which pi: PiG (~/.local/bin/pig) if present, else the upstream launcher at
# $AGENT/bin/pi. Override with PI_SANDBOX_PI_BIN=/path/to/pi (a bare name is
# looked up on PATH, so PI_SANDBOX_PI_BIN=pi forces upstream).
#
# Install (root-owned, so the agent cannot rewrite the launcher):
#   sudo install -m 0755 pi-sandbox.sh /usr/local/bin/pi-sandbox
#
# Requires bubblewrap: sudo apt install bubblewrap
set -uo pipefail

# ── What the sandbox exposes ────────────────────────────────────────────────
ROOT=${PI_SANDBOX_ROOT:-$HOME/Projects}      # the only writable tree
AGENT=${PI_HOME:-$HOME}/.pi/agent            # pi config, sessions, install

# Spawners (Paseo, Zed) start pi with the workspace as its directory. Keep that
# directory when it is inside the writable tree, and fall back to the tree's root
# otherwise — --chdir into an unbound path would fail the whole sandbox.
CDIR=$ROOT
case "${PWD:-}" in
  "$ROOT" | "$ROOT"/*) CDIR=$PWD ;;
esac

# ── Which pi to run ─────────────────────────────────────────────────────────
# PiG is one static binary in ~/.local/bin, which the sandbox does not mount, so
# that single file is bound read-only at /opt/pi-runtime/pig. The upstream Pi
# launcher lives under $AGENT/bin, which is mounted anyway. PI_SANDBOX_PI_BIN
# overrides the choice (and is resolved through PATH, so PI_SANDBOX_PI_BIN=pi
# forces the upstream launcher).
PI_BIN=${PI_SANDBOX_PI_BIN:-}
if [ -n "$PI_BIN" ]; then
  PI_BIN=$(command -v "$PI_BIN" 2>/dev/null) || :
else
  for c in "${PIG_INSTALL_DIR:-$HOME/.local/bin}/pig" "$AGENT/bin/pi"; do
    [ -x "$c" ] && { PI_BIN=$c; break; }
  done
fi
[ -n "$PI_BIN" ] && [ -x "$PI_BIN" ] || {
  printf '%s: cannot find a pi binary (tried %s/pig and %s/bin/pi)\n' \
    "${0##*/}" "${PIG_INSTALL_DIR:-$HOME/.local/bin}" "$AGENT" >&2
  printf '  set PI_SANDBOX_PI_BIN=/path/to/pi to choose one\n' >&2
  exit 127
}
PI_BIN=$(readlink -f "$PI_BIN")
PI_ROOT=${PI_BIN%/*}
PI_RUN=$PI_BIN
case $PI_BIN in
  "$AGENT"/*) ;;                       # already bound read-only below
  *) PI_RUN=/opt/pi-runtime/${PI_BIN##*/}; PI_NEEDS_BIND=1 ;;
esac

# PiG keeps its own tree (~/.pig) by default. None of it is mounted here, so run
# it in shared mode: PIG_USE_PI_DIRS=1 makes it read the ~/.pi/agent this script
# already narrows (settings, models, per-workspace sessions) -- which is also
# the directory Paseo and idle-shutdown look in. Shared mode still keeps PiG's
# product state (extension cell cache, staged SDKs, docs) in PIG_HOME, and that
# has to be writable, so it lives inside the tree and survives restarts.
IS_PIG=
PIG_HOME_DIR=
case ${PI_BIN##*/} in
  pig)
    IS_PIG=1
    PIG_HOME_DIR=${PI_SANDBOX_PIG_HOME:-$ROOT/.pig-home}
    ;;
esac

# Node for pi. Prefer pi's own runtime; otherwise follow whatever `node` resolves
# to right now (fnm's per-shell symlink resolves to the real version directory).
NODE_ROOT=
node_bin_dir=$(dirname "$(readlink -f "$(command -v node 2>/dev/null)" 2>/dev/null)" 2>/dev/null)
for c in "${XDG_DATA_HOME:-$HOME/.local/share}/pi-node/current/bin" "$node_bin_dir"; do
  [ -n "$c" ] && [ -x "$c/node" ] && { NODE_ROOT=${c%/bin}; break; }
done
[ -n "$NODE_ROOT" ] || {
  printf '%s: cannot find node (pi needs it); install Node or pi\n' "${0##*/}" >&2
  exit 127
}

BWRAP=$(command -v bwrap) || {
  printf '%s: bubblewrap not found; install it: sudo apt install bubblewrap\n' "${0##*/}" >&2
  exit 127
}

[ -d "$ROOT" ] || {
  printf '%s: sandbox root does not exist: %s\n' "${0##*/}" "$ROOT" >&2
  exit 1
}

MODE=run
case ${1:-} in
  --shell) MODE=shell; shift ;;
  --check) MODE=check; shift ;;
esac

# ── GitHub access: App tokens (default) or the host's gh token ──────────────
# PI_SANDBOX_GH picks the credential. Neither mode mounts ~/.ssh: push, fetch
# and `gh pr checkout` go over https, because a passphrase-less key is
# account-wide, never expires, and is copyable rather than merely usable.
#
#   app     (default once an owner is configured; 'broker' is an alias)
#           ~/.config/gh is NOT mounted. The sandbox sees one unix socket to
#           gh-mint.service on the host, which answers per call:
#             - an App installation token, for an owner you can install an App
#               on: 60 minutes, that installation's repos and permissions;
#             - a fine-grained PAT, for an owner you cannot (someone else's
#               personal account, where you are only a collaborator), read from
#               ~/.config/gh-mint/tokens/<owner>. Long-lived, so its own repo
#               list and expiry are the boundary -- and still never mounted.
#           `gh` and `git` ask on every invocation, so a long session never
#           carries a token more than seconds old and key material never enters
#           the namespace at all.
#
#   legacy
#           ~/.config/gh bound writable, so `gh` reads the real hosts.yml and
#           refreshes in place. `gh` inside IS the host's gh at the host's scope
#           (`repo`), and an exfiltrated hosts.yml also carries a ~6 month
#           refresh token. Still the fallback: it needs no setup at all.
GH_MODE=${PI_SANDBOX_GH:-}
MINT_HOME=${GH_MINT_HOME:-$HOME/.config/gh-mint}
MINT_SOCK=${GH_MINT_SOCK:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/gh-mint/gh-mint.sock}
if [ -z "$GH_MODE" ]; then
  GH_MODE=legacy
  for f in "$MINT_HOME/apps"/*.env "$MINT_HOME/tokens"/*; do
    [ -f "$f" ] && { GH_MODE=app; break; }
  done
fi
GH_OWNER=${PI_SANDBOX_GH_OWNER:-}
GH_PATH_PREFIX=
gh_binds=()
case $GH_MODE in
  app | broker)
    GH_MODE=app
    MINT_SOCK_IN=/run/gh-mint/${MINT_SOCK##*/} # inside: the broker's directory
    if [ ! -x "$MINT_HOME/bin/gh" ]; then
      printf '%s: PI_SANDBOX_GH=app, but %s/bin/gh is missing\n' "${0##*/}" "$MINT_HOME" >&2
      printf '  install it: %s/gh-mint/gh-mint.sh install\n' "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" >&2
      exit 1
    fi
    [ -S "$MINT_SOCK" ] ||
      printf '%s: warning: %s is not there -- gh/git inside will fail\n  start it on the host: systemctl --user start gh-mint\n' \
        "${0##*/}" "$MINT_SOCK" >&2
    if [ -z "$GH_OWNER" ]; then # exactly one owner configured -> the default
      n=0 only=
      for f in "$MINT_HOME/apps"/*.env "$MINT_HOME/tokens"/*; do
        [ -f "$f" ] || continue
        n=$((n + 1)) f=${f##*/} only=${f%.env}
      done
      [ "$n" -eq 1 ] && GH_OWNER=$only
    fi
    GH_PATH_PREFIX=/opt/gh-mint/bin:
    ;;
  legacy)
    if [ -d "$HOME/.config/gh" ]; then
      gh_binds+=(--bind "$HOME/.config/gh" "$HOME/.config/gh")
    fi
    ;;
  *)
    printf '%s: PI_SANDBOX_GH must be app (alias broker) or legacy (got %s)\n' \
      "${0##*/}" "$GH_MODE" >&2
    exit 1
    ;;
esac

# ── Build the command ───────────────────────────────────────────────────────
session_binds=()
# pi creates its session dirs mode 0700 (SESSION_DIR_MODE = 448); match it, because
# a transcript is the most sensitive file here. mkdir -m only tightens the dirs it
# creates, so chmod the leaf explicitly ("-p -m" would leave the parent at umask).
add_dir_bind() {  # $1 = absolute host dir to expose read-write
  mkdir -p "$1" || {
    printf '%s: cannot create session dir %s\n' "${0##*/}" "$1" >&2
    exit 1
  }
  chmod 0700 "$1" 2>/dev/null || :
  session_binds+=(--bind "$1" "$1")
}
add_session() {  # $1 = workspace path, as pi would see it
  local name
  # Must match pi's getDefaultSessionDirPath byte for byte:
  #   `--${cwd.replace(/^[/\\]/,"").replace(/[/\\:]/g,"-")}--`
  # Note the colon: pi folds it too, so a path containing one would otherwise
  # land in a directory this bind never covers and the first write would EROFS.
  name="--$(printf '%s' "${1#/}" | tr '/\\:' '-')--"
  add_dir_bind "$AGENT/sessions/$name"
}
add_session "$CDIR"
# settings.sessionDir replaces the cwd-derived path wholesale (pi's
# SettingsManager.getSessionDir), so if it is set the directory above is never
# written and transcripts would hit the read-only agent dir. Bind the real one.
# Cheap string test first: no reason to pay for a node start on every launch.
if [ -r "$AGENT/settings.json" ] && grep -q '"sessionDir"' "$AGENT/settings.json" 2>/dev/null; then
  session_dir_cfg=$("$NODE_ROOT/bin/node" -e '
    let s = {};
    try { s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); } catch {}
    if (s && typeof s.sessionDir === "string" && s.sessionDir) console.log(s.sessionDir);
  ' "$AGENT/settings.json" 2>/dev/null) || session_dir_cfg=
  # Expand a leading ~/ by hand: a quoted tilde never expands, and letting the
  # shell expand one would defeat the absolute-path check below.
  tilde='~'
  if [ "${session_dir_cfg:0:2}" = "$tilde/" ]; then
    session_dir_cfg=$HOME/${session_dir_cfg:2}
  fi
  case $session_dir_cfg in
    '') ;;
    /*) add_dir_bind "$session_dir_cfg" ;;
    *) printf '%s: settings.sessionDir is not absolute, ignoring: %s\n' \
         "${0##*/}" "$session_dir_cfg" >&2 ;;
  esac
fi
if [ -n "${PI_SANDBOX_SESSIONS_RW:-}" ]; then
  IFS=: read -r -a _ws <<<"$PI_SANDBOX_SESSIONS_RW"
  for ws in "${_ws[@]}"; do
    [ -n "$ws" ] && add_session "$ws"
  done
fi

args=(
  --die-with-parent
  --new-session                 # no TIOCSTI into the parent terminal
  --unshare-pid --unshare-ipc --unshare-uts --unshare-cgroup-try
  --proc /proc
  --dev /dev
  --tmpfs /tmp
  # Read-only system. /home and /root are never mounted wholesale, so every other
  # user directory, ~/.omniroute, ~/.config/gh and so on are simply absent --
  # except the two GitHub-related binds added after this block (~/.config/gh
  # writable, ~/.ssh read-only), which are what make gh and ssh work here.
  --ro-bind-try /usr /usr
  --ro-bind-try /bin /bin
  --ro-bind-try /sbin /sbin
  --ro-bind-try /lib /lib
  --ro-bind-try /lib64 /lib64
  --ro-bind-try /etc /etc
  # ssh refuses a config file whose ownership it cannot verify, and inside a user
  # namespace every host root-owned file appears as nobody:nogroup -- which made
  # `git fetch`/`push` die with "Bad owner or permissions on
  # /etc/ssh/ssh_config.d/20-systemd-ssh-proxy.conf". The Include'd drop-ins are
  # the strict check, so mask that dir; /etc/ssh/ssh_config still applies.
  --tmpfs /etc/ssh/ssh_config.d
  --ro-bind-try /run/systemd/resolve /run/systemd/resolve   # DNS
  --ro-bind-try "$NODE_ROOT" "$NODE_ROOT"
  --bind "$ROOT" "$ROOT"
  # Only this workspace's session log is writable (that is idle-shutdown's
  # signal). Everything else in ~/.pi/agent is read-only or absent, so sandboxed
  # code cannot rewrite settings or plant an extension the *host* would auto-load
  # and execute later.
  #
  # The transcript *directory* is narrowed too: the host's sessions dir holds the
  # whole machine's history (cwd ~, /tmp, other trees), and mounting it whole
  # would let any injected session read every prompt ever typed here. Only the
  # dir for this cwd is bound; the rest is an empty tmpfs dir.
  --dir "$AGENT/sessions"
  ${session_binds[@]+"${session_binds[@]}"}
  # pi's code and launcher stay read-only even inside the sandbox.
  --ro-bind-try "$AGENT/install" "$AGENT/install"
  --ro-bind-try "$AGENT/bin" "$AGENT/bin"
  --ro-bind-try "$AGENT/settings.json" "$AGENT/settings.json"
  --ro-bind-try "$AGENT/models.json" "$AGENT/models.json"
  # Read-only: a host git config if one ever exists. Identity itself is passed in
  # as GIT_AUTHOR_*/GIT_COMMITTER_* env vars below, because this host has no
  # ~/.gitconfig and commits would otherwise fail.
  --ro-bind-try "$HOME/.gitconfig" "$HOME/.gitconfig"
  --ro-bind-try "$HOME/.config/git" "$HOME/.config/git"
  --chdir "$CDIR"
  --clearenv
  --setenv HOME "$HOME"
  --setenv USER "${USER:-$(id -un)}"
  --setenv LOGNAME "${LOGNAME:-$(id -un)}"
  --setenv TMPDIR /tmp
  --setenv PATH "${GH_PATH_PREFIX}$NODE_ROOT/bin:/usr/local/bin:/usr/bin:/bin"
  --setenv PI_SANDBOX_PI_RESOLVED "$PI_RUN"
)

# A pi that lives outside $AGENT. Read-only: the binary is never the thing we
# write. PiG is a single file, so only that file is bound (its directory,
# ~/.local/bin, holds unrelated host tools); any other binary gets its whole
# directory, in case it needs assets next to it.
if [ -n "$IS_PIG" ]; then
  mkdir -p "$PIG_HOME_DIR" || {
    printf '%s: cannot create PIG_HOME %s\n' "${0##*/}" "$PIG_HOME_DIR" >&2
    exit 1
  }
  case $PIG_HOME_DIR in
    "$ROOT" | "$ROOT"/*) ;;             # already inside the writable tree
    *) args+=(--bind "$PIG_HOME_DIR" "$PIG_HOME_DIR") ;;
  esac
  args+=(--ro-bind "$PI_BIN" "$PI_RUN"
         --setenv PIG_USE_PI_DIRS 1
         --setenv PIG_HOME "$PIG_HOME_DIR")
elif [ -n "${PI_NEEDS_BIND:-}" ]; then
  args+=(--ro-bind "$PI_ROOT" /opt/pi-runtime)
fi

# Deliberately NOT mounted: auth.json (provider credentials), extensions/
# (host code execution on the next unsandboxed run), models-store.json (cache).

# Extra paths, when a project genuinely needs a tool cache outside the tree:
#   PI_SANDBOX_EXTRA=$HOME/.cargo,$HOME/.npm        writable
#   PI_SANDBOX_EXTRA_RO=$HOME/.rustup               read-only
# Keep these out of the default set: every extra bind is a way out of the boundary.
add_binds() { # add_binds <rw|ro> <comma list>
  local kind=$1 list=$2 p
  [ -n "$list" ] || return 0
  local IFS=,
  for p in $list; do
    [ -n "$p" ] || continue
    [ -e "$p" ] || { printf '%s: skipping missing extra path %s\n' "${0##*/}" "$p" >&2; continue; }
    if [ "$kind" = ro ]; then args+=(--ro-bind "$p" "$p"); else args+=(--bind "$p" "$p"); fi
  done
}
add_binds rw "${PI_SANDBOX_EXTRA:-}"
add_binds ro "${PI_SANDBOX_EXTRA_RO:-}"

# GitHub. legacy: the host's real gh config, writable so gh refreshes its own
# token. app: a read-only shim dir plus the broker socket -- the socket is
# bound (not --ro-bind) because connect(2) on a unix socket needs write access
# to the inode, and read-only would fail the whole handshake.
args+=(${gh_binds[@]+"${gh_binds[@]}"})
if [ "$GH_MODE" = app ]; then
  args+=(--ro-bind "$MINT_HOME/bin" /opt/gh-mint/bin
         --setenv GH_MINT_SOCK "$MINT_SOCK_IN")
  # The *directory*, not the socket: binding the socket would pin its inode, so a
  # `systemctl --user restart gh-mint` would leave a running sandbox talking to a
  # dead one. /run/user/<uid> is the user's own writable tree on the host, so
  # exposing this subdirectory to the agent grants nothing it could not do there.
  if [ -d "$(dirname "$MINT_SOCK")" ]; then
    args+=(--bind "$(dirname "$MINT_SOCK")" /run/gh-mint)
  fi
  [ -n "$GH_OWNER" ] && args+=(--setenv GH_MINT_OWNER "$GH_OWNER")
fi
args+=(--setenv PI_SANDBOX_GH_MODE "$GH_MODE")

# How git authenticates without an ssh key. Passed through the environment, so
# the host's own git (ssh remotes, ssh keys) is untouched and nothing has to be
# installed host-side, and existing `git@github.com:` remotes are rewritten to
# https so no remote has to be re-pointed before a push. Credentials come per
# call, never cached: `gh auth git-credential` in legacy mode, the mint broker
# in app mode.
if [ "$GH_MODE" = app ]; then
  # useHttpPath is what lets one sandbox serve several owners (one App each):
  # git then passes path=<owner>/<repo>.git, and the helper mints from that
  # owner's installation instead of guessing.
  args+=(--setenv GIT_CONFIG_COUNT 3
         --setenv GIT_CONFIG_KEY_0 credential.https://github.com.helper
         --setenv GIT_CONFIG_VALUE_0 '!gh-mint-credential'
         --setenv GIT_CONFIG_KEY_1 credential.https://github.com.useHttpPath
         --setenv GIT_CONFIG_VALUE_1 true
         --setenv GIT_CONFIG_KEY_2 url.https://github.com/.insteadOf
         --setenv GIT_CONFIG_VALUE_2 git@github.com:)
else
  args+=(--setenv GIT_CONFIG_COUNT 2
         --setenv GIT_CONFIG_KEY_0 credential.https://github.com.helper
         --setenv GIT_CONFIG_VALUE_0 '!gh auth git-credential'
         --setenv GIT_CONFIG_KEY_1 url.https://github.com/.insteadOf
         --setenv GIT_CONFIG_VALUE_1 git@github.com:)
fi
# No ssh route at all: an unrewritten ssh remote fails immediately instead of
# trying a key this namespace does not have (and instead of hanging on one).
args+=(--setenv GIT_SSH_COMMAND /bin/false)

# No git identity exists on this host, so supply one or commits die with
# "Author identity unknown". Mirrors paseo-sandbox.sh; override via the caller's
# environment.
args+=(--setenv GIT_AUTHOR_NAME "${GIT_AUTHOR_NAME:-Tomy Kho}"
       --setenv GIT_AUTHOR_EMAIL "${GIT_AUTHOR_EMAIL:-mail@tomykho.dev}"
       --setenv GIT_COMMITTER_NAME "${GIT_COMMITTER_NAME:-${GIT_AUTHOR_NAME:-Tomy Kho}}"
       --setenv GIT_COMMITTER_EMAIL "${GIT_COMMITTER_EMAIL:-${GIT_AUTHOR_EMAIL:-mail@tomykho.dev}}")

# Forward only the variables a session legitimately needs. Credentials
# (GH_TOKEN, SSH_AUTH_SOCK, ANTHROPIC_API_KEY, ...) stay outside.
for v in TERM COLORTERM LANG LANGUAGE SHELL TZ \
  PI_SANDBOX_ROOT PI_HOME PI_SESSIONS_DIR \
  PI_MODEL PI_PROVIDER PI_SESSION PI_SESSION_DIR PI_EXTENSIONS \
  PI_NON_INTERACTIVE PI_NO_UPDATE_CHECK XDG_CONFIG_HOME XDG_STATE_HOME \
  PI_SANDBOX_EXTRA PI_SANDBOX_EXTRA_RO; do
  [ -n "${!v:-}" ] || continue
  args+=(--setenv "$v" "${!v}")
done

case $MODE in
  shell) exec "$BWRAP" "${args[@]}" bash ;;
  check)
    exec "$BWRAP" "${args[@]}" bash -s <<'EOS'
echo "HOME=$HOME"
echo "pwd=$(pwd)"
echo "--- visible in /home:"
ls -A /home 2>/dev/null || echo "(empty)"
echo "--- sibling of Projects reachable?"
for p in "$HOME/.ssh" "$HOME/.omniroute" "$HOME/Documents" \
  "$HOME/.pi/agent/auth.json" "$HOME/.pi/agent/extensions" \
  "$HOME/.pi/agent/settings.json"; do
  if [ ! -e "$p" ]; then echo "  hidden   $p"
  elif [ -w "$p" ]; then echo "  WRITABLE $p"
  else echo "  readable $p (ro)"; fi
done
echo "--- writable?"
touch "$HOME/Projects/.sandbox-probe" 2>/dev/null &&
  { echo "  yes: $HOME/Projects (host)"; rm -f "$HOME/Projects/.sandbox-probe"; } ||
  echo "  NO: $HOME/Projects"
touch "$HOME/.sandbox-probe" 2>/dev/null &&
  { echo "  $HOME is a private tmpfs here: writes vanish at exit, host untouched"; rm -f "$HOME/.sandbox-probe"; } ||
  echo "  no:  $HOME"
echo "--- github: mode ${PI_SANDBOX_GH_MODE:-?}"
if [ "${PI_SANDBOX_GH_MODE:-}" = app ]; then
  echo "    gh on PATH: $(command -v gh 2>/dev/null || echo MISSING)"
  echo "    ~/.config/gh: $( [ -e "$HOME/.config/gh" ] && echo PRESENT || echo absent )"
  # Probe liveness and minting separately: "service not running" and "no App
  # configured" look the same to the sandbox but need different fixes.
  sock=${GH_MINT_SOCK:-/run/gh-mint/gh-mint.sock}
  h=$(curl -s --max-time 10 --unix-socket "$sock" http://localhost/health -w $'\n%{http_code}' 2>/dev/null)
  case ${h##*$'\n'} in
    200) echo "    broker: up" ;;
    *) echo "    broker: socket unreachable -- is gh-mint.service running on the host?" ;;
  esac
  if [ -n "${GH_MINT_OWNER:-}" ]; then
    resp=$(curl -s --max-time 10 --unix-socket "$sock" \
      "http://localhost/token?owner=$GH_MINT_OWNER" -w $'\n%{http_code}' 2>/dev/null)
    code=${resp##*$'\n'}
    resp=${resp%$'\n'*}
    case $code in
      200) echo "    mint:  ok, ${#resp} chars for owner $GH_MINT_OWNER" ;;
      *) echo "    mint:  HTTP $code: ${resp%$'\n'}" ;;
    esac
  else
    echo "    owner: none configured -- write \$HOME/.config/gh-mint/apps/<owner>.env"
  fi
  echo "    git helper: $(git config --get credential.https://github.com.helper 2>/dev/null)"
fi
echo "--- node: $(command -v node) ($(node -v 2>/dev/null))"
echo "--- pi: $PI_SANDBOX_PI_RESOLVED"
"$PI_SANDBOX_PI_RESOLVED" --version 2>&1 | head -1 | sed 's/^/    /'
echo "    writable: $( [ -w "$PI_SANDBOX_PI_RESOLVED" ] && echo YES || echo no )"
echo -n "--- OmniRoute reachable: "
(exec 3<>/dev/tcp/127.0.0.1/20128) 2>/dev/null && echo "yes (tcp 20128)" || echo "NO"
echo "--- processes visible: $(ps -e --no-headers | wc -l)"
EOS
    ;;
  *)
    # Resolve pi explicitly rather than through PATH, so a file dropped in the
    # project tree can never become the entry point.
    exec "$BWRAP" "${args[@]}" "$PI_RUN" "$@"
    ;;
esac
