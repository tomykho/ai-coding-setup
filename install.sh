#!/usr/bin/env bash
# Reapply AI coding setup on a new machine. Safe to re-run.
#   ./install.sh            no target: asks which parts to install (TTY only)
#   ./install.sh tools      CLI tools (cargo required; dnf for the non-Rust ones)
#   ./install.sh claude     gate hook (symlinked), settings.json (merged)
#   ./install.sh copilot    VS Code Copilot custom endpoint (OmniRoute models)
#   ./install.sh omniroute  OmniRoute (npm) + CLI-tools system prompt + its Claude Code env
#   ./install.sh all        everything above (never `idle`: it changes machine behaviour)
#   ./install.sh sandbox [--apply]  pi-sandbox launcher: remote pi sees only ~/Projects
#   ./install.sh idle --apply [IDLE_MIN] [OPEN_MIN]  auto power-off when no AI client is active
#                            tiers default to 60 and 120 minutes
# Several targets at once are fine: ./install.sh claude copilot
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
OMNIROUTE_URL=${OMNIROUTE_URL:-http://localhost:20128}

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

need_python() {
  have python3 && return
  warn "python3 not found (runs the gate hook). Install it, then re-run."
  exit 1
}

tools() {
  have cargo || { warn "cargo required. Install Rust (https://rustup.rs), then re-run './install.sh tools'"; exit 1; }
  say "cargo: ripgrep fd-find tokei difftastic hyperfine ast-grep"
  cargo install --locked ripgrep fd-find tokei difftastic hyperfine ast-grep
  if have dnf; then
    say "dnf packages (not on crates.io)"
    sudo dnf install -y jq yq jc ShellCheck ctags
    if ! dnf repolist 2>/dev/null | grep -q gh-cli; then # gh from GitHub's repo (Fedora's lags)
      sudo dnf config-manager addrepo --from-repofile=https://cli.github.com/packages/rpm/gh-cli.repo
    fi
    sudo dnf install -y gh --repo gh-cli
  else
    warn "No dnf. Install manually: jq yq jc shellcheck ctags gh"
  fi
}

link() { # link <repo file> <target>: back up a real file once, then symlink
  local src=$1 dst=$2
  mkdir -p "$(dirname "$dst")"
  if [ -e "$dst" ] && [ ! -L "$dst" ]; then
    mv "$dst" "$dst.bak-$(date +%Y%m%d%H%M%S)"
    warn "backed up existing $dst"
  fi
  ln -sfn "$src" "$dst"
  say "linked $dst -> $src"
}

merge_settings() { # merge_settings <json file>: deep-merge into settings.json; repo wins, other keys and secrets kept
  local add=$1
  mkdir -p "$CLAUDE_DIR"; [ -f "$SETTINGS" ] || echo '{}' >"$SETTINGS"
  cp "$SETTINGS" "$SETTINGS.bak-$(date +%Y%m%d%H%M%S)"
  jq --arg home "$HOME" -s '
    (.[1] | walk(if type == "string" then gsub("__HOME__"; $home) else . end)) as $add
    | (.[0] * ($add | del(.hooks)))
    | if $add.hooks.PreToolUse then
        .hooks.PreToolUse = ((.hooks.PreToolUse // [])
          | map(select(all(.hooks[]?; (.command // "") | test("cli-tools-gate") | not))))
          + $add.hooks.PreToolUse
      else . end' "$SETTINGS" "$add" >"$SETTINGS.tmp"
  mv "$SETTINGS.tmp" "$SETTINGS"
  chmod 600 "$SETTINGS"
  say "merged $(basename "$add") into $SETTINGS (backup kept next to it)"
}

claude() {
  have jq || { warn "jq required: run './install.sh tools' first"; exit 1; }
  need_python
  # CLI-tools guide is no longer a CLAUDE.md: OmniRoute injects it (see `omniroute`). Remove our old symlink only.
  [ -L "$CLAUDE_DIR/CLAUDE.md" ] && [ "$(readlink "$CLAUDE_DIR/CLAUDE.md")" = "$REPO/claude/CLAUDE.md" ] && rm -f "$CLAUDE_DIR/CLAUDE.md"
  rm -f "$CLAUDE_DIR/hooks/cli-tools-gate.ts" # replaced by the Python port
  link "$REPO/claude/hooks/cli-tools-gate.py" "$CLAUDE_DIR/hooks/cli-tools-gate.py"
  merge_settings "$REPO/claude/settings.json"
}

copilot() {
  vscode_models
}

vscode_models() { # VS Code Copilot custom endpoint: repo template + OmniRoute key injected (key never stored here)
  local dst="$HOME/.config/Code/User/chatLanguageModels.json" key
  [ -d "$(dirname "$dst")" ] || { warn "VS Code not found, skipping chatLanguageModels.json"; return; }
  have jq || { warn "jq required: run './install.sh tools' first"; exit 1; }
  key=$(omniroute_key)
  [ -n "$key" ] || warn "No OmniRoute key in ~/.omniroute/.env; replace \${OMNIROUTE_API_KEY} in $dst yourself"
  (umask 077
   jq --arg k "$key" 'if $k == "" then . else walk(if type == "string" then gsub("\\$\\{OMNIROUTE_API_KEY\\}"; $k) else . end) end' \
     "$REPO/copilot/vscode-chatLanguageModels.json" >"$dst.tmp" || { rm -f "$dst.tmp"; exit 1; }
   [ -f "$dst" ] && cp "$dst" "$dst.bak-$(date +%Y%m%d%H%M%S)"
   mv "$dst.tmp" "$dst")
  say "wrote $dst"
}

omniroute_key() { # OmniRoute API key from its .env (never stored in this repo)
  sed -n 's/^OMNIROUTE_API_KEY=//p' "$HOME/.omniroute/.env" 2>/dev/null | tr -d '"' || true
}

omniroute() {
  have jq || { warn "jq required: run './install.sh tools' first"; exit 1; }
  if ! have omniroute; then
    have npm || { warn "npm not found. Install Node (e.g. fnm install --lts), then re-run './install.sh omniroute'"; exit 1; }
    say "installing OmniRoute (npm global)"; npm i -g omniroute
  fi
  need_python
  python3 -I "$REPO/omniroute/set-system-prompt.py" "$REPO/omniroute/cli-tools-prompt.md" \
    || warn "system prompt not written (start OmniRoute once, then re-run './install.sh omniroute')"
  python3 -I "$REPO/omniroute/set-output-styles.py" "$REPO/omniroute/output-styles.json" \
    || warn "output styles not written (start OmniRoute once, then re-run './install.sh omniroute')"
  merge_settings "$REPO/omniroute/claude-env.json"
  if [ -z "$(jq -r '.env.ANTHROPIC_AUTH_TOKEN // empty' "$SETTINGS")" ]; then
    if [ -t 0 ]; then
      read -rsp "OmniRoute API key for Claude Code (ANTHROPIC_AUTH_TOKEN, empty to skip): " token; echo
      if [ -n "$token" ]; then
        jq --arg t "$token" '.env.ANTHROPIC_AUTH_TOKEN = $t' "$SETTINGS" >"$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
        chmod 600 "$SETTINGS"
      fi
    else
      warn "Set env.ANTHROPIC_AUTH_TOKEN in $SETTINGS to your OmniRoute API key"
    fi
  fi
}

idle() { # idle [--apply] [IDLE_MIN] [OPEN_MIN]: power off after IDLE_MIN/OPEN_MIN with no AI client activity
  local src="$REPO/idle-shutdown" apply= user home
  local idle_min=60 open_min=120 n=0
  for arg in "$@"; do
    case $arg in
      --apply) apply=1 ;;
      *[!0-9]* | '') warn "idle: need whole minutes, got '$arg'"; exit 2 ;;
      *)
        n=$((n + 1))
        case $n in
          1) idle_min=$arg ;;
          2) open_min=$arg ;;
          *) warn "idle: too many arguments (usage: idle [--apply] [IDLE_MIN] [OPEN_MIN])"; exit 2 ;;
        esac
        ;;
    esac
  done
  user=${PI_USER:-${SUDO_USER:-$USER}}
  home=$(getent passwd "$user" | cut -d: -f6)

  say "idle shutdown for user $user (home $home): $idle_min min idle, $open_min min if pig or an SSH shell is open"
  say "  /etc/idle-check.conf                        (DRY_RUN=0: it will power off when the rule is met)"
  say "  /usr/local/bin/idle-check.sh, idle-ctl"
  say "  /etc/systemd/system/idle-check.{service,timer}   every 5 min"
  say "  hold file: /run/idle-shutdown-hold"

  if [ -z "$apply" ]; then
    warn "dry run: nothing written. Re-run './install.sh idle --apply${idle_min:+ $idle_min $open_min}' to install."
    return 0
  fi

  need_python
  sudo install -m 0644 "$src/idle-check.conf" /etc/idle-check.conf
  sudo sed -i "s|^PI_USER=.*|PI_USER=$user|; s|^PI_HOME=.*|PI_HOME=$home|; \
    s|^IDLE_MIN=.*|IDLE_MIN=$idle_min|; s|^OPEN_MIN=.*|OPEN_MIN=$open_min|" /etc/idle-check.conf
  sudo install -m 0755 "$src/idle-check.sh" /usr/local/bin/idle-check.sh
  sudo install -m 0755 "$src/idle-ctl" /usr/local/bin/idle-ctl
  sudo install -m 0644 "$src/idle-check.service" "$src/idle-check.timer" /etc/systemd/system/
  sudo systemctl daemon-reload
  sudo systemctl enable --now idle-check.timer

  say "installed live: it will power off when the rule is met ($idle_min min idle, $open_min min with a session)"
  say "  watch:      sudo journalctl -u idle-check -f"
  say "  one verdict: idle-ctl status"
  say "  log only:   sudo sed -i 's/^DRY_RUN=0/DRY_RUN=1/' /etc/idle-check.conf"
}

sandbox() { # sandbox [--apply]: pi-sandbox launcher + bubblewrap, for remote sessions
  local src="$REPO/sandbox" apply= root=${PI_SANDBOX_ROOT:-$HOME/Projects}
  [ "${1:-}" = --apply ] && apply=1

  say "pi sandbox: pi runs as $USER, but sees only $root (rest of /home is not mounted)"
  say "  /usr/local/bin/pi-sandbox          (root-owned: the agent cannot rewrite it)"
  say "  needs bubblewrap (apt); idle-shutdown and OmniRoute keep working unchanged"
  say "  GitHub: host-token mode by default; gh-mint (App tokens) once an App is configured"
  say "  ~/.config/gh-mint                 gh-mint.sh + shims + gh-mint.service"
  say "                                    stays inactive until an App's .env exists"

  if [ -z "$apply" ]; then
    warn "dry run: nothing written. Re-run './install.sh sandbox --apply' to install."
    return 0
  fi

  have bwrap || { say "installing bubblewrap"; sudo apt-get install -y bubblewrap; }
  sudo install -m 0755 "$src/pi-sandbox.sh" /usr/local/bin/pi-sandbox
  # The token broker is user-owned (it holds App keys) and inert until an App is
  # configured in ~/.config/gh-mint/apps/, so installing it here cannot change
  # how gh behaves yet; the sandbox stays in legacy mode until then.
  if [ -x "$src/gh-mint/gh-mint.sh" ]; then
    "$src/gh-mint/gh-mint.sh" install || warn "gh-mint install failed (optional; see sandbox/README.md)"
  fi
  say "installed. Point Paseo/PiChamber at 'pi-sandbox' instead of 'pi'"
  say "  GitHub App tokens (optional): sandbox/README.md, 'App mode'"
  say "  verify:  pi-sandbox --check"
  say "  shell:   pi-sandbox --shell"
}

TARGETS="tools claude copilot omniroute all idle sandbox"

usage() {
  warn "usage: ${0##*/} [TARGET...]"
  warn "  no target: ask which parts to install (needs a terminal)"
  warn "  targets:   tools claude copilot omniroute all"
  warn "             idle [--apply] [IDLE_MIN] [OPEN_MIN]"
  warn "             sandbox [--apply]   confine remote pi sessions to ~/Projects"
}

choose() { # sets CHOSEN: read a menu answer, map it to target names
  [ -t 0 ] || {
    warn "no target given and stdin is not a terminal; pass one explicitly."
    usage
    exit 2
  }
  cat >&2 <<EOF

Which parts of the setup should be installed? (nothing is written until you pick)
  1) tools      CLI tools (cargo + dnf: ripgrep, fd, gh, jq, ...)
  2) claude     Claude Code: gate hook (symlinked) + settings.json (merged)
  3) copilot    VS Code Copilot custom endpoint (OmniRoute models)
  4) omniroute  OmniRoute (npm) + CLI-tools system prompt + its Claude Code env
  5) idle       idle-shutdown: show the plan only (add --apply later to install live)
  6) all        everything above except idle
  7) sandbox    pi-sandbox: remote pi sessions see only ~/Projects (show plan only)

EOF
  local ans tok
  local -a toks
  printf 'Numbers or names, space-separated [2 4]: ' >&2
  read -r ans || {
    printf '\n' >&2
    exit 2
  }
  CHOSEN=()
  read -ra toks <<<"${ans//,/ }" # commas or spaces, no globbing
  for tok in ${toks[@]+"${toks[@]}"}; do
    case $tok in
      1 | tools) CHOSEN+=(tools) ;;
      2 | claude) CHOSEN+=(claude) ;;
      3 | copilot) CHOSEN+=(copilot) ;;
      4 | omniroute) CHOSEN+=(omniroute) ;;
      5 | idle) CHOSEN+=(idle) ;;
      6 | all) CHOSEN+=(all) ;;
      7 | sandbox) CHOSEN+=(sandbox) ;;
      q | quit | n | no) warn "aborted; nothing installed"; exit 2 ;;
      *)
        warn "unknown choice: $tok (numbers 1-7, or names); nothing installed"
        exit 2
        ;;
    esac
  done
  [ ${#CHOSEN[@]} -gt 0 ] || {
    warn "nothing selected; nothing installed"
    exit 2
  }
  printf '\n' >&2
}

run() { # run <target> [idle args...]: one step, in canonical order
  case $1 in
    tools) tools && say "done." ;;
    claude) claude && say "done. Restart Claude Code to pick up changes." ;;
    copilot) copilot && say "done. Restart VS Code to pick up the models." ;;
    omniroute) omniroute && say "done. Restart Claude Code to pick up changes." ;;
    idle)
      shift
      idle "$@"
      ;;
    all)
      run tools
      run claude
      run copilot
      run omniroute
      say "done. Restart Claude Code to pick up changes."
      ;;
  esac
}

[ $# -gt 0 ] || { choose; set -- "${CHOSEN[@]}"; }

while [ $# -gt 0 ]; do
  case $1 in
    -h | --help)
      usage
      exit 0
      ;;
    idle) # idle swallows the rest: idle [--apply] [IDLE_MIN] [OPEN_MIN]
      shift
      run idle "$@"
      set --
      ;;
    sandbox)
      shift
      sandbox "$@"
      set --
      ;;
    tools | claude | copilot | omniroute | all)
      run "$1"
      shift
      ;;
    *)
      warn "unknown target: $1"
      usage
      exit 2
      ;;
  esac
done
