# ai-dotfiles

Portable setup for AI coding agents: CLI tools, Claude Code config with a tool-enforcing gate hook, and OmniRoute.
Clone it on a new machine, run one script, restart Claude Code.

```bash
git clone <this repo> ~/Development/ai-dotfiles
cd ~/Development/ai-dotfiles
./install.sh            # or: tools | claude | omniroute
```

Needs `bun` (runs the gate hook) and, on Fedora, `cargo` for newer tool versions. The installer tells you if either is missing.

## What you get

| Part | Where it goes | How |
|---|---|---|
| CLI tools (`rg`, `fd`, `ast-grep`, `jq`, `yq`, `jc`, `difft`, `shellcheck`, `hyperfine`, `tokei`, `ctags`, `gh`, `bat`) | system / `~/.cargo/bin` | dnf + cargo on Fedora, brew on macOS |
| `claude/CLAUDE.md`: tells Claude which CLI tool to use for what | `~/.claude/CLAUDE.md` | symlink |
| `claude/hooks/cli-tools-gate.ts`: blocks risky or token-heavy commands | `~/.claude/hooks/` | symlink |
| `claude/settings.json`: hook registration, output cap, env | `~/.claude/settings.json` | merged with jq (your other keys and secrets are kept) |
| `omniroute/claude-env.json`: points Claude Code at a local OmniRoute | `~/.claude/settings.json` | merged; API key asked for, never stored here |
| `omniroute/compression-settings.json`: OmniRoute compression + output styles | OmniRoute (`PUT /api/settings/compression`) | applied via its API |

Symlinked files mean edits in `~/.claude` are edits in this repo: `git diff`, commit, push.
After changing OmniRoute settings in its dashboard, run `./install.sh export` and commit.

## The gate (`cli-tools-gate.ts`)

A Claude Code `PreToolUse` hook on Bash and Read. It costs nothing when it allows a command (no output, ~7 ms) and
~200-300 tokens when it blocks (Claude reads the reason and retries). Rules are kept only where a block pays off:

| Blocked | Use instead | Why |
|---|---|---|
| `grep -r` | `rg`, `ast-grep` | rg skips `vendor/`, `node_modules/` |
| `find` without `-maxdepth` | `fd` | same |
| `tree` (no `-L`), `ls -R`, unbounded `git log` | `fd -d 2`, `tokei`, `git log --oneline -n 20` | output floods context |
| `sed -i`, `perl -pi`, `> file`, `tee file` (outside `/tmp`) | Edit / Write tools | shows a diff, errors on no-match, `/rewind` can undo |
| inline Python for JSON | `jq`, `yq`, `jc` | |
| `curl` to GitHub | `gh` | authenticated, compact JSON |
| reading a whole long Markdown doc (needs `rtk`) | `rtk bulk-read --question` | answer instead of the whole file |

Allowed on purpose: single-file `grep`, `cmd | grep`, `sed -n`, `cmd | sed`, writes to `/tmp` or `/dev/null`.

Every block is logged. After a week, see which rules earn their keep:

```bash
cut -f2 ~/.claude/logs/cli-tools-gate.log | sort | uniq -c | sort -rn
```

`settings.json` also sets `BASH_MAX_OUTPUT_LENGTH=15000`, capping any one command at ~3.7k tokens.

## Not in this repo

Secrets (OmniRoute API key, provider keys in OmniRoute's `storage.sqlite`), OmniRoute's general settings
(machine-specific: OIDC secret, machine id, Tailscale URL), and personal Claude Code permissions.
