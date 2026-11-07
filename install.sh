#!/usr/bin/env bash
# Reapply AI coding setup on a new machine. Safe to re-run.
#   ./install.sh            everything: tools, claude, copilot, omniroute
#   ./install.sh tools      CLI tools (cargo required; dnf for the non-Rust ones)
#   ./install.sh claude     gate hook (symlinked), settings.json (merged)
#   ./install.sh copilot    VS Code Copilot custom endpoint (OmniRoute models)
#   ./install.sh omniroute  OmniRoute (npm) + CLI-tools system prompt + its Claude Code env
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
  say "cargo: ripgrep fd-find bat tokei difftastic hyperfine ast-grep"
  cargo install --locked ripgrep fd-find bat tokei difftastic hyperfine ast-grep
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

case "${1:-all}" in
  all) tools; claude; copilot; omniroute ;;
  tools) tools ;;
  claude) claude ;;
  copilot) copilot ;;
  omniroute) omniroute ;;
  *) echo "usage: $0 [all|tools|claude|copilot|omniroute]" >&2; exit 2 ;;
esac
say "done. Restart Claude Code to pick up changes."
