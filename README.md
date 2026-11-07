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

**Compression and the prompt cache (Claude).** Tested against OmniRoute 3.8.53 with multi-turn requests
(Claude Code moves its `cache_control` breakpoint to the newest message every turn):

| Compression | Turn 2 `cache_create` / `cache_read` | Result |
|---|---|---|
| default (`stacked`: `session-dedup` + `lite`) | 7 / 13,532 | cache holds |
| `engine:rtk` | 3,114 / **0** | full cache miss, prefix rewritten |

`rtk` skips a `tool_result` while it carries the breakpoint, then compresses it on the next turn once the breakpoint
has moved on. That changes the cached prefix, so everything after it is rewritten (about 1.25x input price instead of 0.1x).
So keep the default stack for Claude Code and leave compression settings at OmniRoute's defaults (not stored in this repo) and don't set `rtk` as the default or auto-trigger mode. `rtk` is fine
where the prefix isn't cached.

Checking it yourself:
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

Measured with the test script, compression off, 5 turns, about 48.6k prompt tokens (Claude about 66k). Relative cost is
cache efficiency only (uncached 1x, write 1.25x, read 0.1x), not real prices. Single runs; `:floor` routing can vary.

| Route | First cache hit | Avg hit | Relative cost |
|---|---|---|---|
| `or-a/glm-5.3` | turn 2 | 58% | 18636 |
| `or-a/deepseek-v4.1-flash-1017:floor` | turn 2 | 56% | 19675 |
| `cinf/deepseek-v4.1-flash-1017` | turn 3 | 47% | 22446 |
| `cinf-a/deepseek-v4.1-flash-1017` | turn 4 | 32% | 28880 |
| `cc/claude-haiku-5-5` | turn 2 | 61% | 29712 |
| `cinf-a/claude-haiku-5.5` | turn 3 (turn 2 misses) | 48% | 37150 |
| `cinf/claude-haiku-5.5` | turn 2 (partial) | 42% | 31463 |

Takeaways: on `cinf`, the Anthropic node fixes Claude caching (reads and writes reported, `cache_create` > 0) but not
turn 2, which reads 0 even though the logged upstream prefix is identical (system, tools and first message match; only
the `cache_control` marker moves). It does not help DeepSeek, whose cache is automatic and ignores `cache_control`.
OpenRouter routes later requests for a model to the same provider (sticky routing, keyed on a hash of the first system
and first non-system message when no `session_id` is sent), so it needs no extra header and works for every CLI tool.
The script reports FAIL for automatic-cache providers because they report `cache_create=0`; read the per-turn table instead.

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

| Test (haiku, 5 turns, breakpoint moved each turn) | Tokens | Cache |
|---|---|---|
| no header, any engine settings | no savings (safe stack) | holds |
| `allow-lossy` / `engine:caveman`, Caveman only, prose-heavy text | 5,057 to 3,707 (about 26%) | holds, 14 new tokens per turn |
| `allow-lossy`, Caveman + `rtk` + `ccr`, `git log` tool results | 10,356 to 7,374 at turn 5 (about 29%) | **breaks every turn**: `cache_read` stuck at about 3,960, `cache_create` grows to about 8,400 |

So for Claude Code: if you want lossy compression, send `allow-lossy` (or `engine:caveman`) with only `caveman` enabled
and keep `rtk` off. The Caveman savings above come from filler-heavy prose; real code and tool output will save much less.
Not tested: whether Claude Code can send the header through `ANTHROPIC_CUSTOM_HEADERS`, what `ccr` does, answer quality under Caveman.

### Compression findings (conclusion: not worth it, compression is disabled)

Tools: `omniroute/test-cache-compression.mjs` (5 turns per engine, results in `omniroute/test-results.json`, keyed by
engine settings + model + prompt version) and one-off 10/15-turn runs with large real source files as tool results
(`omniroute/test-results-15turn.json`). The JSON files are local only (gitignored); the tables are under
[Benchmark data](#benchmark-data) below. Cost units: uncached 1x, cache write 1.25x, cache read 0.1x. Everything below is
from single runs unless stated, so small differences are noise.

**Cache-safe, but saves almost nothing on real sessions**

| Engines (`allow-lossy`) | Wordy-prose test (turn 1 about 17k tokens) | Real 15-turn session, 13 large files |
|---|---|---|
| `caveman:full`, `ultra`, `aggressive` | about 6% cheaper, hit 69% (off: 70%) | 0.2% fewer tokens, tool results untouched |
| `caveman:full` + `ultra` | 16% cheaper, hit 67% | same; 15 interleaved pairs vs `off`: median cost 0.8% lower, mean 0.3% higher (noise) |
| `llmlingua` | 16% cheaper, hit 67% | 0.3% fewer tokens, tool results untouched, extra miss at turn 4 |

- The big savings come only from artificially wordy prose. Tool results are most of the tokens and these engines pass them through
  byte-identical (checked via the pipeline log; no code, paths or identifiers changed).
- Cache misses happen randomly even with compression `off` (provider-side, turn costs swing by 5-9k units), so one run cannot
  show a 1% difference.
- `ultra`'s "slm" tier has no effect on the stacked (`allow-lossy`) path: it only uses the heuristic. `aggressive`/`ultra` are
  downgraded to `standard` for caching providers (`cachingAware.ts`), so on `cc/` the engine choice changed nothing.

**Breaks the cache or the content: do not enable**

- `lite`: truncates tool results older than the current turn to 2,000 characters (`DEFAULT_MAX_TOOL_LENGTH` in `lite.ts`,
  keeps head and tail with `... [N lines elided] ...`). A result is whole on the turn it arrives and cut the next turn, so its bytes
  change and every turn misses. Measured: 222k to 41k characters (81% cut), cache hit below 90% on turns 2-15, 2,294 identifiers
  lost. Raising `maxToolLength` would not fix the cache problem.
- `rtk:minimal`: broke the cache in the tests (about 8% more expensive on the large prompt).
- `aggressive`: progressive aging re-compresses the last few messages every turn (by distance from the end), which should
  break the cache in long sessions. Not shown in the 5-turn test (aging never fired), so unverified.

**Haiku (`cc/claude-haiku-5-5`) with `cache_control` on the newest message, 10 turns**

- `off`: no miss, cost 94,450. Any compression config (`caveman:full`, `+ultra`, `ultra`, `aggressive`, with or without output
  styles): a miss at turn 8 (about 10k tokens rewritten), cost about 103k, and 6 tokens saved. The header was `standard` every
  time, so the engine setting did not change the pipeline on this route. Cause not found (next step would be to diff the turn-7
  message between requests 7 and 8 with pipeline logging on).
- Test scripts that send no `cache_control` show 0 cache reads on Claude models: always send the marker.

**Other notes**

- Cache reads on `or-a/` come in 256-token blocks, so the per-turn hit ratio can read 89% on a ~4k prompt with nothing wrong.
- Automatic-cache providers (DeepSeek/GLM via OpenRouter) report reads only (`cache_create=0`); the test treats that as a warning.
- Enabling pipeline logging (`call_log_pipeline_enabled`) shows what the provider actually received
  (`pipeline.providerRequest.body`); turn it off afterwards, it stores full bodies.
- Not tested: answer quality under any engine, `rtk` and `llmlingua` on real tool output beyond the runs above, `ponytail`
  (it only adds output-style instructions; the test caps replies at 16 tokens).

### Benchmark data

Raw numbers behind the findings above. Cost is cache-weighted tokens (uncached 1x, write 1.25x, read 0.1x), not real prices. The raw JSON stays local (gitignored); per-run rows are in `omniroute/bench/results.csv` and per-run diffs in `omniroute/bench/diffs/`.

#### Task benchmark (`omniroute/bench/run.mjs`, `auto.mjs`)

Real coding tasks through Claude Code, model `claude-haiku-5-5`, compression off vs `allow-lossy`. `Cost vs off`: negative = cheaper.
##### Compression settings vs off

| Engines | Output styles | Tasks | Runs (off) | Pass off | Pass lossy | Hit off | Hit lossy | Cost vs off | Result |
|---|---|---|---|---|---|---|---|---|---|
| rtk:minimal | none | small, feature | 6 | 6/6 | 6/6 | 87.4% | 87.6% | 0.2% | PASS |
| caveman:full + rtk:standard | none | small, feature | 6 | 6/6 | 6/6 | 86.6% | 86.7% | -1.2% | PASS |
| caveman:full + rtk:aggressive | none | small, feature | 6 | 6/6 | 6/6 | 86.6% | 86.8% | -2.2% | PASS |
| caveman:full + rtk:minimal | none | longout | 3 | 3/3 | 3/3 | 80.2% | 80.2% | -0.1% | PASS |
| caveman:full + rtk:standard | none | longout | 3 | 3/3 | 3/3 | 80.2% | 80.2% | 0% | PASS |
| caveman:full + rtk:aggressive | none | longout | 3 | 3/3 | 0/3 | 80.2% | 82.9% | -17.2% | QUALITY DROP |
| rtk:standard | none | longout | 2 | 2/2 | 0/2 | 80.5% | 83.6% | -19.7% | QUALITY DROP |
| caveman:full | none | longout | 2 | 2/2 | 2/2 | 80.5% | 80.5% | 0% | PASS |

##### Baseline (compression off)

| Task | Runs | Pass | Avg prompt tokens | Avg cache hit | Avg weighted cost |
|---|---|---|---|---|---|
| feature | 3 | 3/3 | 87118 | 84.4% | 24250 |
| longout | 10 | 10/10 | 55889 | 80.3% | 18215 |
| small | 3 | 3/3 | 86198 | 88.8% | 19667 |

##### Compression probes

One request with wordy prose and git-log tool output, per engine (from `auto.mjs`). Engines showing no change may still act on other inputs.

| Engine | Tokens before | After | Saved |
|---|---|---|---|
| session-dedup | n/a | n/a | 0 |
| ccr | n/a | n/a | 0 |
| lite | n/a | n/a | 0 |
| rtk:minimal | 4815 | 3696 | 1119 |
| codex-responses | n/a | n/a | 0 |
| headroom | n/a | n/a | 0 |
| relevance | n/a | n/a | 0 |
| caveman:lite | 2401 | 1951 | 450 |
| aggressive | 2401 | 1951 | 450 |
| llmlingua | 4815 | 3427 | 1388 |
| ultra | 2401 | 1951 | 450 |
| omniglyph | n/a | n/a | 0 |
| rtk:standard | 4815 | 3696 | 1119 |
| caveman:full | 2401 | 1951 | 450 |
| rtk:aggressive | 4815 | 3696 | 1119 |
| caveman:ultra | 2401 | 1951 | 450 |
| rtk:standard+caveman:full | 4815 | 3246 | 1569 |
| rtk:minimal+caveman:ultra | 4815 | 3246 | 1569 |
| rtk:minimal+caveman:lite | 4815 | 3246 | 1569 |
| rtk:minimal+caveman:full | 4815 | 3246 | 1569 |
| rtk:standard+caveman:lite | 4815 | 3246 | 1569 |
| rtk:standard+caveman:ultra | 4815 | 3246 | 1569 |
| rtk:aggressive+caveman:lite | 4815 | 2416 | 2399 |
| rtk:aggressive+caveman:full | 4815 | 2416 | 2399 |
| rtk:aggressive+caveman:ultra | 4815 | 2416 | 2399 |

#### Cache and compression test (`omniroute/test-cache-compression.mjs`)

Single runs. A FAIL on automatic-cache providers (DeepSeek) is expected: they report `cache_create=0`.
##### 5-turn test

| Model | Engines | Output styles | Master | Prompt off | Hit off | Prompt lossy | Hit lossy | Billed saved | Cost vs off | Result |
|---|---|---|---|---|---|---|---|---|---|---|
| cc/claude-haiku-5-5 | caveman:full | none | true | 66456 | 60.8% | 63819 | 59.9% | 2637 | -2.9% | PASS |
| cc/claude-haiku-5-5 | none | none | false | 66507 | 60.7% | 66507 | 60.7% | 0 | 0% | NO COMPRESSION |
| cc/claude-haiku-5-5 | ccr + headroom + lite + rtk:standard + session-dedup | ponytail:ultra, terse-prose:ultra | true | 69007 | 61.5% | 54664 | 51% | 14343 | 11.1% | FAIL |
| cc/claude-haiku-5-5 | lite + rtk:standard | ponytail:ultra, terse-prose:ultra | true | 69084 | 61.5% | 54728 | 50.9% | 14356 | 11.2% | FAIL |
| cc/claude-haiku-5-5 | caveman:lite + rtk:minimal | ponytail:ultra, terse-prose:ultra | true | 69002 | 61.5% | 58654 | 44% | 10348 | 35.5% | FAIL |
| cc/claude-haiku-5-5 | caveman:lite + rtk:minimal | none | true | 66565 | 60.7% | 53876 | 41.4% | 12689 | 33.4% | FAIL |
| deepseek-v4.1-flash | none | none | false | 50422 | 57.2% | 50480 | 57.1% | -58 | 0.3% | FAIL |
| deepseek-v4.1-flash | caveman:lite + rtk:minimal | none | true | 50387 | 57.2% | 41315 | 44.7% | 9072 | 12.1% | FAIL |
| deepseek-v4.1-flash | rtk:minimal | none | true | 50409 | 57.2% | 43510 | 45.8% | 6899 | 16% | FAIL |
| deepseek-v4.1-flash | caveman:full | none | true | 50440 | 56.7% | 48378 | 56.4% | 2062 | -4.4% | FAIL |
| deepseek-v4.1-flash | caveman:lite | none | true | 50494 | 57.1% | 48413 | 56.4% | 2081 | -3.4% | FAIL |
| cinf/deepseek-v4.1-flash-1017 | caveman:lite | none | true | 50457 | 46.9% | 48348 | 27.1% | 2109 | 43.2% | FAIL |
| cc/claude-haiku-5-5 | caveman:lite | none | true | 69007 | 61.5% | 66444 | 60.7% | 2563 | -2.6% | PASS |
| cinf/deepseek-v4.1-flash-1017 | none | none | false | 48481 | 46.5% | 48481 | 46.5% | 0 | 0% | FAIL |
| cinf/claude-haiku-5.5 | none | none | false | 56807 | 41.6% | 56807 | 41.6% | 0 | 0% | FAIL |
| cinf-a/claude-haiku-5.5 | none | none | false | 66359 | 47.6% | 66359 | 47.6% | 0 | 0% | FAIL |
| or-a/deepseek-v4.1-flash-1017:floor | none | none | false | 50357 | 57.3% | 50357 | 57.3% | 0 | 0% | FAIL |
| cinf-a/deepseek-v4.1-flash-1017 | none | none | false | 48694 | 32% | 48694 | 32% | 0 | 0% | FAIL |
| or-a/glm-5.3 | none | none | false | 48646 | 58.4% | 48646 | 58.4% | 0 | 0% | FAIL |
| or-a/deepseek-v4.1-flash-1017:floor | caveman:lite + lite + rtk:minimal | none | true | 50497 | 57.1% | 35809 | 44.3% | 14688 | -0.9% | FAIL |
| or-a/deepseek-v4.1-flash-1017:floor | caveman:lite | none | true | 50406 | 57.2% | 48372 | 44.8% | 2034 | 15% | FAIL |
| or-a/deepseek-v4.1-flash-1017:floor | caveman:full | none | true | 50459 | 45.4% | 48359 | 56.5% | 2100 | -19.2% | FAIL |
| or-a/deepseek-v4.1-flash-1017:floor | lite | none | true | 50422 | 45.5% | 40145 | 50.1% | 10277 | -16.8% | FAIL |
| or-a/deepseek-v4.1-flash-1017:floor | rtk:minimal | none | true | 50376 | 57.2% | 43310 | 42.4% | 7066 | 23.2% | FAIL |
| or-a/deepseek-v4.1-flash-1017:floor | session-dedup | none | true | 50441 | 57.2% | 50418 | 57.2% | 23 | 0% | NO COMPRESSION |
| or-a/deepseek-v4.1-flash-1017:floor | relevance | none | true | 50399 | 57.2% | 50442 | 45.5% | -43 | 19.6% | FAIL |
| or-a/deepseek-v4.1-flash-1017:floor | headroom | none | true | 50398 | 56.7% | 50627 | 57.3% | -229 | 0% | NO COMPRESSION |
| or-a/deepseek-v4.1-flash-1017:floor | ccr | none | true | 50455 | 51.6% | 50493 | 57.1% | -38 | -10.9% | FAIL |
| or-a/deepseek-v4.1-flash-1017:floor | aggressive | none | true | 50503 | 57.1% | 48436 | 56.4% | 2067 | -3.4% | PASS |
| or-a/deepseek-v4.1-flash-1017:floor | ultra | none | true | 50347 | 57.3% | 48389 | 56.4% | 1958 | -2.9% | PASS |
| or-a/deepseek-v4.1-flash-1017:floor | llmlingua | none | true | 50461 | 57.1% | 45254 | 54.5% | 5207 | -7.5% | FAIL |
| or-a/deepseek-v4.1-flash-1017:floor | omniglyph | none | true | 50521 | 57.1% | 50516 | 51.1% | 5 | 13.6% | FAIL |
| or-a/deepseek-v4.1-flash-1017:floor | llmlingua | none | true | 111676 | 69.5% | 90738 | 67.3% | 20938 | -15.9% | PASS |
| or-a/deepseek-v4.1-flash-1017:floor | ultra | none | true | 111641 | 69.5% | 103284 | 68.7% | 8357 | -6.3% | PASS |
| or-a/deepseek-v4.1-flash-1017:floor | aggressive | none | true | 111775 | 69.4% | 103280 | 68.7% | 8495 | -6.7% | PASS |
| or-a/deepseek-v4.1-flash-1017:floor | caveman:full | none | true | 111752 | 69.4% | 103213 | 68.6% | 8539 | -6.2% | PASS |
| or-a/deepseek-v4.1-flash-1017:floor | rtk:minimal | none | true | 111777 | 69.4% | 104755 | 64.9% | 7022 | 8.3% | FAIL |
| or-a/deepseek-v4.1-flash-1017:floor | caveman:full + ultra | none | true | 111571 | 69.6% | 90052 | 67.2% | 21519 | -16.3% | PASS |

##### 15-turn session (13 large files)

| Model | Label | Mode | Total tokens | Cost | Cache-miss turns |
|---|---|---|---|---|---|
| or-a/deepseek-v4.1-flash-1017:floor | off | off | 65273 | 112140 | 2, 3 |
| or-a/deepseek-v4.1-flash-1017:floor | caveman+ultra | allow-lossy | 65112 | 115047 | 2, 3 |
| or-a/deepseek-v4.1-flash-1017:floor | llmlingua | allow-lossy | 65072 | 118635 | 2, 3, 4 |
| or-a/deepseek-v4.1-flash-1017:floor | lite+caveman:full | allow-lossy | 14097 | 93611 | 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 |
| or-a/deepseek-v4.1-flash-1017:floor | lite | allow-lossy | 14105 | 96225 | 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 |
| or-a/deepseek-v4.1-flash-1017:floor | off | off | 17172 | 21341 | 2, 3 |
| or-a/deepseek-v4.1-flash-1017:floor | off | off | 17172 | 21341 | 2, 3 |
| or-a/deepseek-v4.1-flash-1017:floor | off | off | 17172 | 21341 | 2, 3 |
| or-a/deepseek-v4.1-flash-1017:floor | off | off | 17172 | 32631 | 2, 3, 4, 5 |
| or-a/deepseek-v4.1-flash-1017:floor | off | off | 17172 | 28483 | 2, 3, 4 |
| or-a/deepseek-v4.1-flash-1017:floor | caveman:full+ultra+ponytail | allow-lossy | 17368 | 21399 | 2 |
| or-a/deepseek-v4.1-flash-1017:floor | caveman:full+ultra+ponytail | allow-lossy | 17368 | 21169 | 2 |
| or-a/deepseek-v4.1-flash-1017:floor | caveman:full+ultra+ponytail | allow-lossy | 17368 | 21169 | 2 |
| or-a/deepseek-v4.1-flash-1017:floor | caveman:full+ultra+ponytail | allow-lossy | 17368 | 21169 | 2 |
| or-a/deepseek-v4.1-flash-1017:floor | caveman:full+ultra | allow-lossy | 41794 | 61082 | 2 |
| cc/claude-haiku-5-5 | caveman:full+ultra | allow-lossy | 67379 | 334375 | 2, 3, 4, 5, 6, 7, 8, 9, 10 |
| cc/claude-haiku-5-5 | caveman:full+ultra | allow-lossy | 67379 | 103313 | 8 |
| cc/claude-haiku-5-5 | caveman:full | allow-lossy | 67578 | 103653 | 8 |
| cc/claude-haiku-5-5 | caveman:full | allow-lossy | 67578 | 103653 | 8 |
| cc/claude-haiku-5-5 | caveman:full | allow-lossy | 67180 | 102897 | 8 |
| cc/claude-haiku-5-5 | off | allow-lossy | 67584 | 94450 | none |
| cc/claude-haiku-5-5 | ultra | allow-lossy | 67576 | 103649 | 8 |
| cc/claude-haiku-5-5 | aggressive | allow-lossy | 67577 | 103651 | 8 |

### Chosen setup: output styles `ponytail` (ultra) + `terse-prose` (full), input compression off

Output styles shape the model's replies, not the request, so they cannot hurt the prompt cache. Compression engines are off
because of the findings above. `omniroute/output-styles.json` holds `terse-prose` (full) and `ponytail` (ultra);
`./install.sh omniroute` writes it to the OmniRoute `compression/outputStyles` setting with `omniroute/set-output-styles.py`
(restart OmniRoute to apply). It does not touch the compression engines: switch them off yourself in the dashboard.

- `terse-prose`: drops filler, articles and hedging from replies, keeps technical content exact. It does not touch code.
- `ponytail`: "lazy senior dev" (smallest working change, no unrequested abstractions). Built-in safeguard: it must not simplify
  away input validation at trust boundaries, error handling that prevents data loss, security measures or accessibility basics.
- Each enabled style injects a system block (about 300 tokens, one in the system prompt at turn 1: 979 vs 581 tokens in the Haiku
  test). Keep **Auto-Clarity Bypass** off, otherwise the injection flips between turns and breaks the cache.
- **Not verified:** whether `ponytail ultra` lowers code quality (skipped tests, edge cases or error handling beyond the
  safeguard's list), and whether terse replies drop caveats you need in review. The cache test cannot measure this (replies capped
  at 16 tokens).
- How to verify: take 3-8 real tasks with a known-good result (bug with a failing test, small feature, refactor, script needing
  error handling), run each from the same commit with no style and with the chosen styles, then compare tests passing,
  `git diff --stat`, whether existing validation/error handling survived, and output tokens. Read the diffs by hand; passing
  tests will not show a skipped edge case.

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
