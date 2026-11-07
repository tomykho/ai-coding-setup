#!/usr/bin/env bash
# Reapply AI coding setup on a new machine. Safe to re-run.
#   ./install.sh            everything: tools, claude, omniroute
#   ./install.sh tools      CLI tools (dnf/brew + cargo)
#   ./install.sh claude     CLAUDE.md + gate hook (symlinked), settings.json (merged)
#   ./install.sh omniroute  OmniRoute + its Claude Code env + compression settings
#   ./install.sh export     pull live OmniRoute compression settings back into this repo
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
OMNIROUTE_URL=${OMNIROUTE_URL:-http://localhost:20128}

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

need_bun() {
  have bun && return
  BUN="$HOME/.bun/bin/bun"; [ -x "$BUN" ] && return
  warn "bun not found. Install it, then re-run: curl -fsSL https://bun.sh/install | bash"
  exit 1
}

tools() {
  if have dnf; then
    say "dnf packages"
    sudo dnf install -y ripgrep fd-find bat jq yq jc ShellCheck tokei ctags
    if ! dnf repolist 2>/dev/null | grep -q gh-cli; then # gh from GitHub's repo (Fedora's lags)
      sudo dnf config-manager addrepo --from-repofile=https://cli.github.com/packages/rpm/gh-cli.repo
    fi
    sudo dnf install -y gh --repo gh-cli
    if ! have cargo; then
      warn "cargo not found. Install Rust (https://rustup.rs), then re-run './install.sh tools'"
      return
    fi
    say "cargo (newer than Fedora): difftastic hyperfine ast-grep fd-find"
    cargo install --locked difftastic hyperfine ast-grep fd-find
  elif have brew; then
    say "brew packages"
    brew install ripgrep fd bat jq yq jc shellcheck tokei universal-ctags gh difftastic hyperfine ast-grep
  else
    warn "No dnf or brew. Install manually: ripgrep fd bat jq yq jc shellcheck tokei ctags gh difftastic hyperfine ast-grep"
  fi
  have rtk || warn "rtk not found (used for 'rtk bulk-read' and compact output). Install it separately."
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
  local add=$1 bun
  bun=$(command -v bun || echo "$HOME/.bun/bin/bun")
  mkdir -p "$CLAUDE_DIR"; [ -f "$SETTINGS" ] || echo '{}' >"$SETTINGS"
  cp "$SETTINGS" "$SETTINGS.bak-$(date +%Y%m%d%H%M%S)"
  jq --arg bun "$bun" --arg home "$HOME" -s '
    (.[1] | walk(if type == "string" then gsub("__BUN__"; $bun) | gsub("__HOME__"; $home) else . end)) as $add
    | (.[0] * ($add | del(.hooks)))
    | if $add.hooks.PreToolUse then
        .hooks.PreToolUse = ((.hooks.PreToolUse // [])
          | map(select(all(.hooks[]?; (.command // "") | test("cli-tools-gate") | not))))
          + $add.hooks.PreToolUse
      else . end' "$SETTINGS" "$add" >"$SETTINGS.tmp"
  mv "$SETTINGS.tmp" "$SETTINGS"
  say "merged $(basename "$add") into $SETTINGS (backup kept next to it)"
}

claude() {
  have jq || { warn "jq required: run './install.sh tools' first"; exit 1; }
  need_bun
  link "$REPO/claude/CLAUDE.md" "$CLAUDE_DIR/CLAUDE.md"
  link "$REPO/claude/hooks/cli-tools-gate.ts" "$CLAUDE_DIR/hooks/cli-tools-gate.ts"
  merge_settings "$REPO/claude/settings.json"
}

omniroute_key() { # OmniRoute API key from its .env (never stored in this repo)
  sed -n 's/^OMNIROUTE_API_KEY=//p' "$HOME/.omniroute/.env" 2>/dev/null | tr -d '"' || true
}

omniroute() {
  have jq || { warn "jq required: run './install.sh tools' first"; exit 1; }
  need_bun
  have omniroute || { say "installing OmniRoute (bun global)"; bun add -g omniroute; }
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
  if ! curl -sf -o /dev/null "$OMNIROUTE_URL/api/settings/compression" -H "Authorization: Bearer $(omniroute_key)"; then
    warn "OmniRoute not reachable at $OMNIROUTE_URL. Start it ('omniroute'), finish setup in the dashboard, then re-run './install.sh omniroute'"
    return
  fi
  curl -sf -X PUT "$OMNIROUTE_URL/api/settings/compression" -H "Authorization: Bearer $(omniroute_key)" \
    -H 'Content-Type: application/json' --data @"$REPO/omniroute/compression-settings.json" -o /dev/null
  say "applied OmniRoute compression settings"
}

export_omniroute() {
  curl -sf "$OMNIROUTE_URL/api/settings/compression" -H "Authorization: Bearer $(omniroute_key)" \
    | jq -S . >"$REPO/omniroute/compression-settings.json.tmp"
  mv "$REPO/omniroute/compression-settings.json.tmp" "$REPO/omniroute/compression-settings.json"
  say "exported OmniRoute compression settings; review with 'git diff' and commit"
}

case "${1:-all}" in
  all) tools; claude; omniroute ;;
  tools) tools ;;
  claude) claude ;;
  omniroute) omniroute ;;
  export) export_omniroute ;;
  *) echo "usage: $0 [all|tools|claude|omniroute|export]" >&2; exit 2 ;;
esac
say "done. Restart Claude Code to pick up changes."
