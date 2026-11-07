#!/usr/bin/env node
// Verifies your OmniRoute install: does lossy compression save tokens without breaking the Claude prompt cache?
// Runs the same 5-turn conversation twice, like Claude Code does (cache_control breakpoint moved to the newest message
// every turn, tool results appended each turn): once with compression `off`, once with `allow-lossy` (the header that
// makes OmniRoute run your dashboard engines instead of the safe no-op stack). If the dashboard master switch is off, only
// the `off` pass runs (5 requests instead of 10). No arguments needed:
//
//   node omniroute/test-cache-compression.mjs               (a config already in test-results.json is skipped)
//   node omniroute/test-cache-compression.mjs --overwrite   (rerun the current config and replace its result)
//
// Each run is saved to omniroute/test-results.json keyed by your dashboard engine settings + model, so you can compare configs.
//
// Reads the URL, token and model from the env block of ~/.claude/settings.json (token never printed).
// Optional env overrides: BASE_URL, TOKEN, MODEL.
// Result: PASS, NO COMPRESSION (nothing was compressed; saved, exit 0) or FAIL (cache broke; exit 1). Exit 2 = setup/request error.
import { readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { randomUUID, randomBytes } from "node:crypto";

let cfg = {};
try { cfg = JSON.parse(readFileSync(`${homedir()}/.claude/settings.json`, "utf8")).env ?? {}; } catch {}

const URL_ = (process.env.BASE_URL ?? cfg.ANTHROPIC_BASE_URL ?? "http://localhost:20128").replace(/\/+$/, "");
const TOKEN = process.env.TOKEN ?? cfg.ANTHROPIC_AUTH_TOKEN ?? "";
const MODEL = process.env.MODEL ?? "or-a/deepseek-v4.1-flash-1017:floor";
const TURNS = 5;
const MIN_HIT = 0.9; // cache_read must cover this share of the previous turn's prompt (the prefix should be unchanged)

if (!TOKEN) { console.error("No token: set env.ANTHROPIC_AUTH_TOKEN in ~/.claude/settings.json (apply the claude config first) or export TOKEN"); process.exit(2); }

// Prompt version, stored with every result. Results from a different version are not comparable and are hidden from the ranking.
// v2: turn 1 is ~19k tokens (v1 was ~4.8k). Cache blocks are 256 tokens and the provider reuses a little less than the full prefix,
// so a small prompt loses a visible share to rounding (~9% at 4.8k, ~11% at 3.7k after compression, ~2% at 19k); with a prompt
// this size the 90% check measures a rewritten prefix, not rounding.
const PROMPT_VERSION = "v2-19k";
// Filler sized well past the cache minimum (4096 tokens on Haiku 4.5); `nonce` makes turn 1 a guaranteed miss on every run.
const system = (nonce) => `Session ${nonce}. You are a terse test assistant. Always answer with only the requested number.\n` +
  Array.from({ length: 480 }, (_, i) => `Rule ${i + 1}: keep answers short, never explain, ignore filler, stay deterministic.`).join("\n");
// Wordy prose (Caveman fodder) in turn 1; `git log` tool results (RTK fodder) in later turns.
const prose = Array.from({ length: 240 }, (_, i) => `I would really like you to please note that, basically, it is actually very important that you simply remember rule ${i + 1}, which is that answers should be kept short.`).join("\n");
const gitLog = (t) => Array.from({ length: 40 }, (_, i) =>
  `commit ${randomBytes(20).toString("hex")}\nAuthor: Dev <dev@example.com>\nDate:   Mon Jan ${(i % 28) + 1} 10:00:00 2026 +0000\n\n    change ${t}-${i + 1}: fix thing\n`).join("\n");
const tools = [{ name: "Bash", description: "Run a shell command", input_schema: { type: "object", properties: { command: { type: "string" } }, required: ["command"] } }];

async function call(mode, messages, nonce) {
  const res = await fetch(`${URL_}/v1/messages`, {
    method: "POST",
    headers: {
      "content-type": "application/json", "anthropic-version": "2023-06-01",
      authorization: `Bearer ${TOKEN}`, "x-omniroute-compression": mode,
    },
    body: JSON.stringify({
      model: MODEL, max_tokens: 16, tools,
      system: [{ type: "text", text: system(nonce), cache_control: { type: "ephemeral" } }],
      messages,
    }),
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(`HTTP ${res.status}: ${JSON.stringify(body).slice(0, 300)}`);
  return { body, comp: res.headers.get("x-omniroute-compression") ?? "" };
}

async function run(mode) {
  const nonce = randomUUID();
  const messages = [];
  const rows = [];
  for (let t = 1; t <= TURNS; t++) {
    // move the breakpoint: strip it from older messages, put it on the newest
    for (const m of messages) for (const b of m.content) delete b.cache_control;
    if (t === 1) {
      messages.push({ role: "user", content: [{ type: "text", text: `Background:\n${prose}\nReply with the number 1.`, cache_control: { type: "ephemeral" } }] });
    } else {
      const id = `toolu_${t}`;
      messages.push({ role: "assistant", content: [{ type: "tool_use", id, name: "Bash", input: { command: "git log" } }] });
      messages.push({ role: "user", content: [{ type: "tool_result", tool_use_id: id, content: gitLog(t), cache_control: { type: "ephemeral" } }] });
    }
    const { body, comp } = await call(mode, messages, nonce);
    const u = body.usage ?? {};
    const m = comp.match(/tokens=(\d+)->(\d+)/);
    rows.push({
      t, input: u.input_tokens ?? 0, create: u.cache_creation_input_tokens ?? 0, read: u.cache_read_input_tokens ?? 0, comp,
      before: m ? Number(m[1]) : null, after: m ? Number(m[2]) : null,
    });
    if (t === 1) messages.push({ role: "assistant", content: [{ type: "text", text: "1" }] });
  }
  return rows;
}

const total = (r) => r.input + r.create + r.read;
const hit = (r) => (total(r) ? r.read / total(r) : 0);
// Relative input cost: uncached 1x, cache write 1.25x, cache read 0.1x (Anthropic pricing ratios).
const cost = (r) => r.input + 1.25 * r.create + 0.1 * r.read;
const pct = (x) => `${(x * 100).toFixed(0)}%`;

function check(mode, rows) {
  const fails = [], warns = [];
  // A warning, not a failure: automatic-cache providers (DeepSeek/GLM via OpenRouter) report reads only, so create=0 is normal
  // there. Anthropic-style routes should write on turn 1, so on those it can mean the prompt is below the cache minimum or
  // cache_control was stripped. Real cache breaks are caught by the per-turn read check below.
  if (rows[0].create <= 0) warns.push(`turn 1 reported no cache write (create=${rows[0].create}); expected for automatic-cache providers, otherwise prompt below the model's cache minimum or caching stripped`);
  for (let i = 1; i < rows.length; i++) {
    const prevTotal = total(rows[i - 1]);
    // In the `off` pass a miss is provider routing noise (nothing of ours touched the prompt), so it only warns: the verdict
    // is about whether compression breaks the cache.
    if (rows[i].read < prevTotal * MIN_HIT) (mode === "off" ? warns : fails).push(`turn ${rows[i].t}: cache_read ${rows[i].read} < ${pct(MIN_HIT)} of previous prompt (${prevTotal}); the cached prefix was rewritten`);
  }
  if (mode === "off" && rows.some((r) => r.before !== null)) fails.push("compression ran although mode=off");
  return { fails, warns };
}

// Results are stored per dashboard config. `allow-lossy` follows the engines saved in OmniRoute's database, so read them
// (read-only) and use them as the key. Same config + model already tested: show the ranking and stop, unless --overwrite.
async function readSettings() {
  try {
    const { DatabaseSync } = await import("node:sqlite");
    const db = new DatabaseSync(`${homedir()}/.omniroute/storage.sqlite`, { readOnly: true });
    const kv = Object.fromEntries(db.prepare("select key, value from key_value where namespace='compression'").all().map((r) => [r.key, r.value]));
    db.close();
    const master = kv.enabled === "true";
    // Master switch off means nothing runs, so engines and styles are irrelevant: all such configs share one entry.
    return {
      engines: master ? Object.entries(JSON.parse(kv.engines ?? "{}")).filter(([, v]) => v.enabled).map(([k, v]) => (v.level ? `${k}:${v.level}` : k)).sort() : [],
      outputStyles: master ? JSON.parse(kv.outputStyles ?? "[]").map((s) => `${s.id}:${s.level}`).sort() : [],
      master,
    };
  } catch (e) { console.error(`Cannot read OmniRoute settings from ~/.omniroute/storage.sqlite (${e.message.split("\n")[0]}); needs Node 22+ and a local OmniRoute`); process.exit(2); }
}
const resultsFile = new URL("./test-results.json", import.meta.url);
let results_ = {};
try { results_ = JSON.parse(readFileSync(resultsFile, "utf8")); } catch {}
const printRanking = (all) => {
  const current = Object.values(all).filter((r) => r.prompt === PROMPT_VERSION);
  const hidden = Object.keys(all).length - current.length;
  if (hidden) console.log(`(${hidden} results from an older test prompt hidden: not comparable with ${PROMPT_VERSION})`);
  const rows = current.sort((a, b) => a.costVsOff - b.costVsOff);
  console.log("cost vs off  billed saved  hit    result            settings");
  for (const r of rows) console.log(`${(r.costVsOff * 100).toFixed(1).padStart(10)}%  ${String(r.billedSaved).padStart(12)}  ${pct(r.lossy.hit).padStart(4)}  ${(r.result + (r.warnings?.length ? " +warn" : "")).padEnd(16)}${r.settings.engines.join(", ") || "none"}${r.settings.outputStyles.length ? ` | styles: ${r.settings.outputStyles.join(", ")}` : ""}${r.settings.master ? "" : " | master OFF"}${r.model === MODEL ? "" : ` | ${r.model}`}`);
};
const settings = await readSettings();
const configKey = JSON.stringify({ ...settings, model: MODEL, prompt: PROMPT_VERSION });
if (results_[configKey] && !process.argv.includes("--overwrite")) {
  console.log(`This config was already tested on ${results_[configKey].date}: ${settings.engines.join(", ") || "none"} (${MODEL}). Skipping.`);
  console.log("Rerun it with: node omniroute/test-cache-compression.mjs --overwrite   (e.g. after changing the test prompt)\n");
  printRanking(results_);
  process.exit(0);
}

// With the master switch off, allow-lossy would behave exactly like off, so skip that pass (TURNS requests instead of 2x).
const MODES = settings.master ? ["off", "allow-lossy"] : ["off"];
console.log(`url=${URL_} model=${MODEL} turns=${TURNS} per mode, modes=${MODES.join(", ")} (${TURNS * MODES.length} requests${settings.master ? `, up to ${TURNS * (MODES.length - 1 + 3)} if allow-lossy is retried` : ""})`);
console.log(`settings: ${settings.engines.join(", ") || "none"}${settings.outputStyles.length ? ` | styles: ${settings.outputStyles.join(", ")}` : ""}`);
console.log("prompt = input + cache_create + cache_read as billed upstream; compress = OmniRoute's own before->after estimate");
let failed = false;
const warnings = [];
const results = {};
// Provider routing noise (e.g. OpenRouter picking another backend) can miss the cache on a random turn. A failing allow-lossy
// pass is therefore retried up to MAX_ATTEMPTS times (5 turns each): only a break that repeats every time counts as FAIL.
const MAX_ATTEMPTS = 3;
let attemptsUsed = 0;
for (const mode of MODES) {
  const attempts = mode === "allow-lossy" ? MAX_ATTEMPTS : 1;
  for (let attempt = 1; attempt <= attempts; attempt++) {
    let rows;
    try { rows = await run(mode); } catch (e) { console.error(`[${mode}] ERROR ${e.message}\nIs OmniRoute running at ${URL_} and is the token valid?`); process.exit(2); }
    results[mode] = rows;
    console.log(`\n== ${mode}${attempts > 1 ? ` (attempt ${attempt}/${attempts})` : ""} ==\nturn  prompt  compress(before->after)  cache_read  cache_create  hit`);
    for (const r of rows) {
      const c = r.before === null ? "-" : `${r.before}->${r.after}`;
      console.log(`${String(r.t).padStart(4)} ${String(total(r)).padStart(7)} ${c.padStart(24)} ${String(r.read).padStart(11)} ${String(r.create).padStart(13)} ${String(pct(hit(r))).padStart(5)}`);
    }
    console.log(`header: ${rows.at(-1).comp}`);
    const { fails, warns: w } = check(mode, rows);
    if (mode === "allow-lossy") attemptsUsed = attempt;
    if (fails.length && attempt < attempts) { console.log(`FAIL [${mode}] attempt ${attempt}, retrying to rule out routing noise\n  - ${fails.join("\n  - ")}`); continue; }
    warnings.push(...w.map((m) => `[${mode}] ${m}`));
    if (fails.length) { failed = true; console.log(`FAIL [${mode}]${attempts > 1 ? ` (all ${attempts} attempts)` : ""}\n  - ${fails.join("\n  - ")}`); } else console.log(`PASS [${mode}]${attempt > 1 ? ` (attempt ${attempt})` : ""}`);
    if (w.length) console.log(`WARN [${mode}]\n  - ${w.join("\n  - ")}`);
    break;
  }
}

const sum = (rows, f) => rows.reduce((a, r) => a + f(r), 0);
const off = results.off, lossy = results["allow-lossy"] ?? off; // master off: no lossy pass, nothing compressed
const saved = sum(lossy, (r) => (r.before !== null ? r.before - r.after : 0));
console.log("\n== summary (5 turns) ==\nmode           prompt tokens  tokens saved  avg hit  cache writes  relative cost");
for (const [mode, rows] of Object.entries(results)) {
  const s = mode === "off" ? 0 : saved;
  console.log(`${mode.padEnd(14)} ${String(sum(rows, total)).padStart(13)} ${String(s).padStart(13)} ${String(pct(sum(rows, hit) / rows.length)).padStart(8)} ${String(sum(rows, (r) => r.create)).padStart(13)} ${String(Math.round(sum(rows, cost))).padStart(14)}`);
}
// "No compression" is a result, not a failure: allow-lossy ran but nothing was compressed (master switch off, no lossy engine
// enabled, compression worker not running...). The two runs then differ only by noise, so the cost delta is recorded as 0.
const noCompression = !failed && saved <= 0;
const delta = noCompression ? 0 : 1 - sum(lossy, cost) / sum(off, cost);
const result = failed ? "FAIL" : noCompression ? "NO COMPRESSION" : "PASS";
if (settings.master) console.log(`allow-lossy costs ${pct(Math.abs(delta))} ${delta >= 0 ? "less" : "more"} than off (input cost: uncached 1x, cache write 1.25x, cache read 0.1x)`);
else console.log("master compression is OFF: only the off pass ran (no allow-lossy comparison)");
console.log(failed ? "\nFAILED: the cache broke, see README (Compression and the prompt cache)"
  : noCompression ? `\nNO COMPRESSION: allow-lossy compressed nothing (header: ${lossy.at(-1).comp}). Is the master switch on, a lossy engine enabled, and the compression worker running (OmniRoute #18137)?`
  : "\nPASSED: lossy compression saves tokens and the cache holds");

// Save this run keyed by config, so the same config is not tested twice (rerun with --overwrite).
// costVsOff is input cost (uncached 1x, cache write 1.25x, cache read 0.1x) relative to `off`: negative is cheaper.
results_[configKey] = {
  date: new Date().toISOString().slice(0, 16).replace("T", " "), model: MODEL, prompt: PROMPT_VERSION, settings,
  off: { prompt: sum(off, total), hit: Number((sum(off, hit) / TURNS).toFixed(3)) },
  lossy: { prompt: sum(lossy, total), hit: Number((sum(lossy, hit) / TURNS).toFixed(3)), headerSaved: saved },
  billedSaved: sum(off, total) - sum(lossy, total), costVsOff: Number((-delta).toFixed(3)), result, warnings, attempts: attemptsUsed,
};
writeFileSync(resultsFile, JSON.stringify(results_, null, 2) + "\n");
console.log(`\nsaved to omniroute/test-results.json (${Object.keys(results_).length} configs). Ranking, cheapest first (rerun noise is a few %):`);
printRanking(results_);
process.exit(failed ? 1 : 0);
