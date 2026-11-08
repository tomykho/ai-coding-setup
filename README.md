# ai-coding-setup

Portable setup for AI coding agents: CLI tools, Claude Code config with a tool-enforcing gate hook, and OmniRoute.
Clone it on a new machine, run one script, restart Claude Code.

```bash
git clone git@github.com:tomykho/ai-coding-setup.git ~/Development/ai-coding-setup
cd ~/Development/ai-coding-setup
./install.sh            # or: tools | claude | copilot | omniroute
```

Needs `python3` (runs the gate hook, standard library only) and `cargo` (Rust, required) for the CLI tools. The installer tells you if either is missing.

# Docs
- OmniRoute (local gateway) docs: http://localhost:20128/docs
- OmniRoute compression guide: https://github.com/cheaper-inference/OmniRoute/blob/main/docs/compression/COMPRESSION_GUIDE.md

## What you get

| Part | Where it goes | How |
|---|---|---|
| CLI tools (`rg`, `fd`, `ast-grep`, `jq`, `yq`, `jc`, `difft`, `shellcheck`, `hyperfine`, `tokei`, `ctags`, `gh`, `bat`) | system / `~/.cargo/bin` | cargo for the Rust tools; dnf for `jq`, `yq`, `jc`, `shellcheck`, `ctags`, `gh` |
| `omniroute/cli-tools-prompt.md`: tells every client (Claude Code, Copilot, ...) which CLI tool to use for what | OmniRoute global system prompt (suffix), `~/.omniroute/storage.sqlite` | `omniroute/set-system-prompt.py`; restart OmniRoute to apply |
| `claude/hooks/cli-tools-gate.py`: blocks risky or token-heavy commands | `~/.claude/hooks/` | symlink |
| `claude/settings.json`: hook registration, output cap, env | `~/.claude/settings.json` | merged with jq (your other keys and secrets are kept) |
| `copilot/vscode-chatLanguageModels.json`: VS Code Copilot custom endpoint (OmniRoute models) | `~/.config/Code/User/chatLanguageModels.json` | written from template; `${OMNIROUTE_API_KEY}` replaced with the key from `~/.omniroute/.env`, never stored here |
| `omniroute/claude-env.json`: points Claude Code at a local OmniRoute | `~/.claude/settings.json` | merged; API key asked for, never stored here |

Symlinked files mean edits in `~/.claude` are edits in this repo: `git diff`, commit, push. The Copilot file is written from a template, so edit `copilot/` here and re-run `./install.sh copilot`.

## OmniRoute notes

**Compression worker bug.** On OmniRoute 3.8.53 the compression worker never spawns
([OmniRoute #18137](https://github.com/cheaper-inference/OmniRoute/issues/18137): `Cannot find module '<path>'` in the
logs, compression silently skipped). Compression is disabled in this setup, so no patch is included.
OmniRoute is installed with npm.

**Compression and the prompt cache (Claude).** Keep compression settings at OmniRoute's defaults (not stored in this
repo) and don't set `rtk` as the default or auto-trigger mode: it rewrites the cached prefix and defeats the prompt cache.

Checking the cache and compression yourself:
- Send requests with `x-omniroute-compression: engine:rtk` (valid values: `off`, `default`, `engine:<name>`, a combo name).
  The response header `x-omniroute-compression` shows what ran; when the compression worker runs it includes `tokens=before->after`.
- `cache_creation_input_tokens` / `cache_read_input_tokens` in the response `usage`, or the `[USAGE]` lines in
  `~/.omniroute/logs/application/app.log`. At info level OmniRoute logs only compression *failures*; successful runs
  are recorded in the `compression_analytics` table of `~/.omniroute/storage.sqlite`.
- `node omniroute/test-cache-compression.mjs` (no arguments) checks that the cache holds with compression `off` and with no header.

**Anthropic-compatible providers (`cinf-a`, `or-a`).** The built-in `cheaperinference` provider (`cinf/...`) only talks
OpenAI format: OmniRoute translates Claude requests to `/v1/chat/completions` and drops every `cache_control` marker, so
the provider falls back to its own implicit cache (late and partial hits). Setting that model's target format to
"Anthropic Messages" does not help: the body becomes Anthropic format but the URL stays `/v1/chat/completions`, which
rejects `tool_use` blocks (HTTP 400 on the first tool call). Revert it. Add a separate provider node instead:

1. Dashboard, Providers, add an **Anthropic Compatible** node.
2. Prefix and base URL (**the `/v1` suffix is required**, otherwise requests miss `/v1/messages`):

   | Prefix | Base URL | Models |
   |---|---|---|
   | `cinf-a` | `https://api.cheaperinference.com/v1` | `cinf-a/claude-haiku-5.5`, `cinf-a/deepseek-v4.1-flash-1017` |
   | `or-a` | `https://openrouter.ai/api/v1` | `or-a/glm-5.3`, `or-a/deepseek-v4.1-flash-1017:floor` |

3. Add the provider's API key as a connection on the new node. Without it every request returns
   `401 provider_not_configured` ("No active credentials").
4. Check it: `node omniroute/test-cache-compression.mjs` with `MODEL=cinf-a/claude-haiku-5.5` (5 requests when the master
   compression switch is off, 10 when on). The pipeline log (`call_log_pipeline_enabled`) should show
   `providerRequest.url` ending in `/v1/messages` and the `cache_control` markers still in the body.

OpenRouter blocks models your privacy or guardrail settings exclude (`404 ... 0 endpoints ... available matching your
guardrail restrictions and data policy`); OmniRoute then puts the credential on cooldown for a while.

**How OmniRoute picks the compression mode (read from the 3.8.53 source, confirmed with curl).**
Docs: `http://localhost:20128/docs`. Compression guide: https://github.com/cheaper-inference/OmniRoute/blob/main/docs/compression/COMPRESSION_GUIDE.md

1. **`defaultMode` in the dashboard is ignored** once the engines panel has been saved (`enginesExplicit`). The enabled
   engines decide: exactly one single-mode engine on gives that engine's mode; two or more give `stacked`
   (`planResolution.ts`, `deriveDefaultPlan.ts`). Same for `/v1/messages` and `/v1/chat/completions`.
2. **Lossy engines are downgraded when the request has no opt-in header** (`lossyRequestPolicy.ts`). `caveman` (`standard`),
   `rtk`, `aggressive`, `ultra`, `relevance`, `omniglyph`, `codex-responses` become `stacked` with the safe pipeline
   (`session-dedup` + `lite` without tool-result truncation, which saves nothing on typical input). The header shows
   `stacked; source=default` and Caveman never runs. Claude Code sends no header, so engine toggles alone cannot enable lossy compression for it.
3. **Opt in per request** with `x-omniroute-compression: allow-lossy` (keeps the dashboard plan as configured) or
   `engine:<id>`. `engine:<id>` is ignored (falls back to `stacked; source=default`) if that engine is disabled in the panel.
   A bare `rtk` is not a valid value. `off`, `default` and `safe` do not opt in.
4. **Auto-trigger** (`autoTriggerMode`) only applies when `autoTriggerTokens > 0`. It is 0 here, so it does nothing.
5. **Output styles** (e.g. Ponytail) inject a system block (about 300 tokens) when enabled. **Auto-Clarity Bypass** skips that
   injection when the last 3 messages match words like delete or security. Leave it off with styles on: the injection would
   flip between turns and break the cache. Styles in this repo: `omniroute/output-styles.json` (see "Chosen setup" below).
6. Dashboard "Token Saver": *Input compression* = Caveman engine, *Tool output* = RTK engine, *LLM output* = legacy
   `cavemanOutputMode` (terse-reply instruction).

### Chosen setup: output styles `ponytail` (ultra) + `terse-prose` (full), input compression off

Output styles shape the model's replies, not the request, so they cannot hurt the prompt cache. Compression engines are off
because they can break the prompt cache. `omniroute/output-styles.json` holds `terse-prose` (full) and `ponytail` (ultra);
`./install.sh omniroute` writes it to the OmniRoute `compression/outputStyles` setting with `omniroute/set-output-styles.py`
(restart OmniRoute to apply). It does not touch the compression engines: switch them off yourself in the dashboard.

- `terse-prose`: drops filler, articles and hedging from replies, keeps technical content exact. It does not touch code.
- `ponytail`: "lazy senior dev" (smallest working change, no unrequested abstractions). Built-in safeguard: it must not simplify
  away input validation at trust boundaries, error handling that prevents data loss, security measures or accessibility basics.
- Each enabled style injects a system block (about 300 tokens). Keep **Auto-Clarity Bypass** off, otherwise the injection flips between turns and breaks the cache.

## The gate (`cli-tools-gate.py`)

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

Allowed on purpose: single-file `grep`, `cmd | grep`, `sed -n`, `cmd | sed`, writes to `/tmp` or `/dev/null`.

Every block is logged. After a week, see which rules earn their keep:

```bash
cut -f2 ~/.claude/logs/cli-tools-gate.log | sort | uniq -c | sort -rn
```

`settings.json` also sets `BASH_MAX_OUTPUT_LENGTH=15000`, capping any one command at ~3.7k tokens.

## Not in this repo

Secrets (OmniRoute API key, provider keys in OmniRoute's `storage.sqlite`), OmniRoute's general settings
(machine-specific), and personal Claude Code permissions.

## Keep OmniRoute local only

OmniRoute is meant to run on this machine only. In `~/.omniroute/.env`, bind it to loopback:

```
HOST=127.0.0.1
```

Then restart OmniRoute. Check the exact variable name against your OmniRoute version's docs.
