#!/usr/bin/env bash
# paseo-sandbox.sh -- run the Paseo daemon with $HOME confined to ~/Projects.
#
# Why this exists: pi-sandbox.sh confines the `pi` process Paseo *spawns*, but
# the daemon itself is long-lived and does host-side work -- terminal panes,
# clone, worktree creation, reading files to render diffs. Wrapping only the
# agent leaves all of that with full access to the whole home directory.
#
# So wrap the daemon: nothing outside ~/Projects is bound in, which makes every
# child it ever creates -- including the pi it spawns for a session -- start
# from that boundary.
#
# ~/Projects is the *only* writable host tree. Two things that used to sit
# beside it were folded in:
#   * Paseo's own state (~/.paseo -> ~/Projects/.paseo) via PASEO_HOME. It held
#     the daemon credential and the schedules directory, i.e. the two things a
#     compromised session most wants: a token and somewhere durable to persist.
#   * pi's transcripts: only session dirs whose workspace is inside ~/Projects
#     are mounted at all, so the rest of the host's agent history (sessions run
#     from ~, /tmp, other trees) is not readable from inside.
#
# Usage (from a systemd unit, or by hand):
#   paseo-sandbox.sh /path/to/paseo daemon run
set -euo pipefail

HOME_DIR=${PASEO_SANDBOX_HOME:-$HOME}
PROJECTS=${PI_SANDBOX_ROOT:-$HOME_DIR/Projects}
AGENT=${PI_CODING_AGENT_DIR:-$HOME_DIR/.pi/agent}
SESSIONS=${PI_SANDBOX_SESSIONS_DIR:-$AGENT/sessions}

# Paseo's state directory. Defaults to inside the tree; anything outside is
# bound separately below, which reintroduces a second writable mount, so only
# set this if you know why.
STATE=${PASEO_SANDBOX_STATE:-$PROJECTS/.paseo}

BWRAP=${BWRAP:-/usr/bin/bwrap}

command -v "$BWRAP" >/dev/null 2>&1 || { echo "$0: no $BWRAP" >&2; exit 1; }
[ -d "$PROJECTS" ] || { echo "$0: no such directory: $PROJECTS" >&2; exit 1; }

# The daemon learns its state location from the environment, so export it before
# the exec below (`resolveDaemonTarget` reads PASEO_HOME for `daemon run`). The
# *host* CLI needs the same variable or it will look for a daemon at ~/.paseo
# that no longer exists -- see sandbox/README.md.
#
# PASEO_HOST must not be set alongside it: paseo refuses to start with both
# ("Choose --home or --host explicitly").
mkdir -p "$STATE"
export PASEO_HOME=$STATE

# --- session dirs -----------------------------------------------------------
# pi names a workspace's transcript dir by the encoded cwd, e.g.
#   /home/tomykho/Projects/foo  ->  --home-tomykho-Projects-foo--
# so a prefix match on the encoded $PROJECTS is a reliable "is this workspace
# inside the boundary" test, at any nesting depth.
SESSION_PREFIX="--$(printf '%s' "${PROJECTS#/}" | tr '/' -)"

session_binds=()
if [ -d "$SESSIONS" ]; then
  shopt -s nullglob
  for d in "$SESSIONS"/"$SESSION_PREFIX"-*; do
    [ -d "$d" ] || continue
    session_binds+=(--bind "$d" "$AGENT/sessions/${d##*/}")
  done
  shopt -u nullglob
fi

# Workspaces that have no session dir yet (a project created after the daemon
# started) can be pre-declared; pi's dir is created host-side so the first
# transcript survives instead of landing in the namespace tmpfs.
if [ -n "${PI_SANDBOX_SESSIONS_RW:-}" ]; then
  IFS=: read -r -a _ws <<<"$PI_SANDBOX_SESSIONS_RW"
  for ws in "${_ws[@]}"; do
    [ -n "$ws" ] || continue
    name="--$(printf '%s' "${ws#/}" | tr '/' -)--"
    mkdir -p "$SESSIONS/$name"
    session_binds+=(--bind "$SESSIONS/$name" "$AGENT/sessions/$name")
  done
fi

# Paseo's state only needs a mount of its own when it is not already covered by
# the ~/Projects bind.
state_binds=()
case "$STATE" in
  "$PROJECTS"/*) ;;
  *) state_binds=(--bind "$STATE" "$STATE") ;;
esac

# The daemon's own executable is a node script; node lives under $HOME, so the
# fnm install dir has to stay reachable or the shebang cannot resolve.
NODE_ROOT=$(cd "$(dirname "$(command -v node)")/.." && pwd)

# --- agent runtime ----------------------------------------------------------
# The daemon spawns whatever PI_COMMAND names. PiG (pig) is a single static
# binary that the host keeps in ~/.local/bin, which this namespace does not
# mount. Bind it at the same path so an unchanged PI_COMMAND resolves, and
# switch PiG to shared mode: it then reads the ~/.pi/agent the daemon already
# mounts instead of ~/.pig, which is not bound (and, with $HOME read-only,
# cannot be created).
agent_binds=()
PI_AGENT_COMMAND=${PI_COMMAND:-pi}
case "${PI_AGENT_COMMAND##*/}" in
  pig)
    # Shared mode for the agent dir; product state (packed-extension cell cache,
    # docs, Piglets) still goes to PIG_HOME, which must be writable and in-tree.
    export PIG_USE_PI_DIRS=1
    export PIG_HOME=${PI_SANDBOX_PIG_HOME:-$PROJECTS/.pig-home}
    mkdir -p "$PIG_HOME"
    case "$PIG_HOME" in
      "$PROJECTS" | "$PROJECTS"/*) ;;   # already inside the writable tree
      *) agent_binds+=(--bind "$PIG_HOME" "$PIG_HOME") ;;
    esac
    pig_bin=$(command -v "$PI_AGENT_COMMAND" 2>/dev/null || true)
    if [ -n "$pig_bin" ]; then
      pig_bin=$(readlink -f "$pig_bin")
      agent_binds+=(--ro-bind "$pig_bin" "$pig_bin")
    else
      printf '%s: warning: PI_COMMAND is pig but no pig binary is on PATH\n' "${0##*/}" >&2
    fi
    ;;
esac

# --- GitHub credential -------------------------------------------------------
# PI_SANDBOX_GH picks it; neither mode mounts ~/.ssh (see the GIT_CONFIG_*
# exports below for why the sandbox pushes over https and never over ssh).
#
#   app     (default once an owner is configured; 'broker' is an alias)
#           ~/.config/gh is NOT mounted. One unix socket to gh-mint.service on
#           the host, answering per call: an App installation token (60 minutes,
#           that installation's repos and permissions) for owners you can
#           install an App on, or a fine-grained PAT from
#           ~/.config/gh-mint/tokens/<owner> for owners you cannot -- someone
#           else's personal account, where you are only a collaborator.
#           That credential goes to EVERY agent sharing this namespace, so the
#           socket is worth exactly its scope, not the account's.
#
#   legacy
#           ~/.config/gh bound writable, so `gh` reads the real hosts.yml and
#           refreshes in place: the daemon carries the host's `repo` scope and
#           an exfiltratable ~6 month refresh token.
GH_MODE=${PI_SANDBOX_GH:-}
MINT_HOME=${GH_MINT_HOME:-$HOME_DIR/.config/gh-mint}
MINT_SOCK=${GH_MINT_SOCK:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/gh-mint/gh-mint.sock}
if [ -z "$GH_MODE" ]; then
  GH_MODE=legacy
  for f in "$MINT_HOME/apps"/*.env "$MINT_HOME/tokens"/*; do
    [ -f "$f" ] && { GH_MODE=app; break; }
  done
fi
GH_OWNER=${PI_SANDBOX_GH_OWNER:-}
gh_binds=()
gh_mint_binds=()
case $GH_MODE in
  app | broker)
    GH_MODE=app
    MINT_SOCK_IN=/run/gh-mint/${MINT_SOCK##*/}
    [ -x "$MINT_HOME/bin/gh" ] || {
      printf '%s: PI_SANDBOX_GH=app, but %s/bin/gh is missing\n' "${0##*/}" "$MINT_HOME" >&2
      printf '  install it: %s/gh-mint/gh-mint.sh install\n' "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" >&2
      exit 1
    }
    [ -S "$MINT_SOCK" ] ||
      printf '%s: warning: %s is not there -- gh/git inside will fail (systemctl --user start gh-mint)\n' \
        "${0##*/}" "$MINT_SOCK" >&2
    if [ -z "$GH_OWNER" ]; then # exactly one owner configured -> the default
      n=0 only=
      for f in "$MINT_HOME/apps"/*.env "$MINT_HOME/tokens"/*; do
        [ -f "$f" ] || continue
        n=$((n + 1)) f=${f##*/} only=${f%.env}
      done
      [ "$n" -eq 1 ] && GH_OWNER=$only
    fi
    gh_mint_binds+=(--ro-bind "$MINT_HOME/bin" /opt/gh-mint/bin)
    # The directory, not the socket: a socket bind pins its inode, so restarting
    # gh-mint.service would leave a running sandbox talking to a dead one.
    [ -d "$(dirname "$MINT_SOCK")" ] &&
      gh_mint_binds+=(--bind "$(dirname "$MINT_SOCK")" /run/gh-mint)
    ;;
  legacy)
    if [ -d "$HOME_DIR/.config/gh" ]; then
      gh_binds+=(--bind "$HOME_DIR/.config/gh" "$HOME_DIR/.config/gh")
    fi
    ;;
  *)
    printf '%s: PI_SANDBOX_GH must be app (alias broker) or legacy (got %s)\n' \
      "${0##*/}" "$GH_MODE" >&2
    exit 1
    ;;
esac

args=(
  --die-with-parent
  --dev /dev
  --proc /proc
  --tmpfs /tmp

  # System directories: executable and readable, never writable.
  --ro-bind /usr /usr
  --ro-bind-try /bin /bin
  --ro-bind-try /sbin /sbin
  --ro-bind-try /lib /lib
  --ro-bind-try /lib64 /lib64
  --ro-bind /etc /etc
  # ssh refuses a config file whose ownership it cannot verify, and inside a user
  # namespace every host root-owned file appears as nobody:nogroup, which made
  # `git fetch`/`push` in the sandbox die with "Bad owner or permissions on
  # /etc/ssh/ssh_config.d/20-systemd-ssh-proxy.conf". Drop-ins are the strict
  # check, so mask that dir; /etc/ssh/ssh_config still applies.
  --tmpfs /etc/ssh/ssh_config.d
  --ro-bind-try /run/systemd/resolve /run/systemd/resolve

  # $HOME itself is a tmpfs, so it starts empty, and it is remounted read-only
  # at the end: a write like `mkdir ~/test2` then FAILS with EACCES instead of
  # silently landing in a throwaway overlay that is invisible from the host and
  # vanishes with the daemon -- which is what made the GUI look like it worked.
  --tmpfs "$HOME_DIR"
  # Scratch dirs Paseo insists on having (caches, per-provider homes). These
  # stay ephemeral on purpose; nothing outside the tree survives a restart.
  --tmpfs "$HOME_DIR/.cache"
  --tmpfs "$HOME_DIR/.config"
  --tmpfs "$HOME_DIR/.claude"
  --tmpfs "$HOME_DIR/.codex"
  --tmpfs "$HOME_DIR/.bun"
  # pi writes its own state (trust.json, cache) next to its sessions, so that
  # dir must be writable. It is a tmpfs -- a fresh agent home on every daemon
  # start -- with model config read-only and in-tree session dirs bound in.
  --tmpfs "$AGENT"

  # Only these entries are real, and only ~/Projects is writable:
  #   ~/Projects     the only writable tree (Paseo's state is inside it now)
  #   node           the fnm install dir (read-only)
  --bind "$PROJECTS" "$PROJECTS"
  --ro-bind "$NODE_ROOT" "$NODE_ROOT"
  ${state_binds[@]+"${state_binds[@]}"}

  # pi's model config, because the pi the daemon spawns reads it from here.
  #
  # Transcripts, narrowed: $AGENT/sessions is an empty tmpfs dir and only the
  # session dirs of workspaces inside ~/Projects are bound into it. The host's
  # other history -- sessions whose cwd was ~, /tmp, another tree -- is not
  # mounted, so a prompt-injected agent cannot read every prompt ever typed on
  # this machine. Writes for an unmounted workspace land in the tmpfs and are
  # discarded: restart the unit to pick up a new project, or declare it in
  # PI_SANDBOX_SESSIONS_RW=/path/one:/path/two.
  #
  # idle-shutdown is unaffected: pi_last_write() reads the host directory
  # directly, not this namespace.
  --dir "$AGENT/sessions"
  ${session_binds[@]+"${session_binds[@]}"}
  --ro-bind-try "$AGENT/settings.json" "$AGENT/settings.json"
  --ro-bind-try "$AGENT/models.json" "$AGENT/models.json"
  --ro-bind-try "$AGENT/models-store.json" "$AGENT/models-store.json"
  --ro-bind-try "$AGENT/install" "$AGENT/install"
  --ro-bind-try "$AGENT/bin" "$AGENT/bin"

  # PiG's binary (and an out-of-tree PIG_HOME), when PI_COMMAND selects it (see
  # "agent runtime" above).
  ${agent_binds[@]+"${agent_binds[@]}"}

  # git identity, if present (never ~/.ssh: keys are not needed here and
  # mounting them would hand the daemon everything the sandbox hides from pi).
  --ro-bind-try "$HOME_DIR/.gitconfig" "$HOME_DIR/.gitconfig"
  --ro-bind-try "$HOME_DIR/.config/git" "$HOME_DIR/.config/git"

  # gh: either the host's writable config (legacy) or the mint shim + broker
  # socket (app). No ssh keys in either mode.
  ${gh_binds[@]+"${gh_binds[@]}"}
  ${gh_mint_binds[@]+"${gh_mint_binds[@]}"}

  --chdir "$PROJECTS"

  # Last: make $HOME read-only. ~/Projects is a separate mountpoint and stays
  # writable; everything else fails cleanly with EROFS.
  --remount-ro "$HOME_DIR"
)

# Git identity for the sandbox. This host has no ~/.gitconfig and its repos
# carry no local identity, so a commit inside the sandbox would otherwise die
# with "Author identity unknown". Default to the host's gh account identity;
# override by exporting these in the unit.
export GIT_AUTHOR_NAME=${GIT_AUTHOR_NAME:-Tomy Kho}
export GIT_AUTHOR_EMAIL=${GIT_AUTHOR_EMAIL:-mail@tomykho.dev}
export GIT_COMMITTER_NAME=${GIT_COMMITTER_NAME:-$GIT_AUTHOR_NAME}
export GIT_COMMITTER_EMAIL=${GIT_COMMITTER_EMAIL:-$GIT_AUTHOR_EMAIL}

# How git authenticates now that no ssh key is mounted. Everything is passed
# through the environment rather than written to a gitconfig file, so the host's
# own git behaviour (ssh remotes, ssh keys) is untouched and nothing about this
# has to be installed on the host:
#   * each https://github.com credential is minted per call instead of cached --
#     `gh auth git-credential` in legacy mode, the broker in app mode;
#   * existing `git@github.com:` remotes are rewritten to https, so a session
#     does not have to re-point a single remote before pushing.
# GIT_CONFIG_* appends to the normal config stack (highest priority), so a host
# gitconfig, if it ever appears, is still read.
# useHttpPath (app mode) makes git pass path=<owner>/<repo>.git to the helper,
# which is what lets one sandbox serve several owners with one App each.
if [ "$GH_MODE" = app ]; then
  export PATH=/opt/gh-mint/bin:$PATH
  export GH_MINT_SOCK=$MINT_SOCK_IN
  [ -n "$GH_OWNER" ] && export GH_MINT_OWNER="$GH_OWNER"
  export GIT_CONFIG_COUNT=3
  export GIT_CONFIG_KEY_0=credential.https://github.com.helper
  export GIT_CONFIG_VALUE_0='!gh-mint-credential'
  export GIT_CONFIG_KEY_1=credential.https://github.com.useHttpPath
  export GIT_CONFIG_VALUE_1=true
  export GIT_CONFIG_KEY_2=url.https://github.com/.insteadOf
  export GIT_CONFIG_VALUE_2=git@github.com:
else
  export GIT_CONFIG_COUNT=2
  export GIT_CONFIG_KEY_0=credential.https://github.com.helper
  export GIT_CONFIG_VALUE_0='!gh auth git-credential'
  export GIT_CONFIG_KEY_1=url.https://github.com/.insteadOf
  export GIT_CONFIG_VALUE_1=git@github.com:
fi
# No ssh route at all: an unrewritten ssh remote fails at once instead of using
# a key this namespace does not have.
export GIT_SSH_COMMAND=/bin/false

# The environment is intentionally inherited rather than cleared: the unit
# already exports PI_COMMAND and TMPDIR, and dropping those would silently
# un-sandbox the pi that gets spawned.
exec "$BWRAP" "${args[@]}" "$@"
