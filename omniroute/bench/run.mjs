#!/usr/bin/env node
// Cache-health bench: does your current setup (Claude Code + your hooks/CLIs + OmniRoute defaults) keep the prompt cache?
// Runs real `claude -p` coding tasks against a small inventory repo (data = bench/fixtures/*/data/items.csv, 600 rows)
// with your ~/.claude/settings.json as is. Nothing is forced: no compression header, no hook or engine toggles, so
// OmniRoute applies its dashboard defaults. Each result is graded by bench/tasks/check.py (recomputes the expected
// answers from the CSV), and cache hit / weighted cost are read from the OmniRoute proxy log per session.
//
//   node omniroute/bench/run.mjs               (a config already in results.json is skipped)
//   node omniroute/bench/run.mjs --overwrite   (rerun the current config, e.g. after installing a new CLI)
//   node omniroute/bench/run.mjs --ranking     (print saved results)
//   RUNS=5 TASKS=small,medium,feature node omniroute/bench/run.mjs
//
// Needs: claude CLI, python3, git, Node 22+ (node:sqlite), local OmniRoute. Only a per-run session tag and the
// OmniRoute no-cache/no-memory headers are added through a temp --settings file (token never printed or stored).
// Output: bench/results.json (per config). Approx $0.01 per run on haiku. Exit 0 = ran/skipped, 1 = invalid run, 2 = setup error.
import { readFileSync, writeFileSync, mkdtempSync, cpSync, rmSync, existsSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync, spawn } from "node:child_process";

const HERE = new URL(".", import.meta.url).pathname;
const RUNS = Number(process.env.RUNS ?? 3);
const TASKS = (process.env.TASKS ?? "medium,feature").split(",");
const MAX_CALLS = Number(process.env.MAX_CALLS ?? 20); // hard cap of API calls per run
const MIN_CALLS = Number(process.env.MIN_CALLS ?? 10); // a run with fewer calls is flagged SHORT: it never got past the 8th call where past caches broke
const MODEL = process.env.MODEL ?? "claude-haiku-5-5";
const FIXTURE = { small: "inv", medium: "inv", feature: "inv_fixed", longout: "inv_long" }; // feature starts from the bug-free repo
const OVERWRITE = process.argv.includes("--overwrite");
const DB = `${homedir()}/.omniroute/storage.sqlite`;

for (const [bin, arg] of [["claude", "--version"], ["python3", "--version"], ["git", "--version"]]) {
  if (spawnSync(bin, [arg]).error) { console.error(`${bin} not found`); process.exit(2); }
}
const { DatabaseSync } = await import("node:sqlite").catch(() => { console.error("Needs Node 22+ (node:sqlite)"); process.exit(2); });
const db = new DatabaseSync(DB, { readOnly: true });

// Dashboard settings are recorded for reference, and part of the config key so a changed dashboard is a new entry.
const kv = Object.fromEntries(db.prepare("select key, value from key_value where namespace='compression'").all().map((r) => [r.key, r.value]));
const master = kv.enabled === "true";
const settings = {
  engines: master ? Object.entries(JSON.parse(kv.engines ?? "{}")).filter(([, v]) => v.enabled).map(([k, v]) => (v.level ? `${k}:${v.level}` : k)).sort() : [],
  outputStyles: master ? JSON.parse(kv.outputStyles ?? "[]").map((s) => `${s.id}:${s.level}`).sort() : [],
  master,
};
// Detected, never forced: is the rtk CLI hook active in your Claude Code settings? Saved with the result so runs with and
// without it can be told apart later.
const rtkHook = /\brtk\b/.test(JSON.stringify(JSON.parse(readFileSync(`${homedir()}/.claude/settings.json`, "utf8")).hooks ?? {})) && !spawnSync("rtk", ["--version"]).error;
const label = `${rtkHook ? "with rtk CLI" : "without rtk CLI"} | ${settings.engines.join(", ") || "none"}${settings.outputStyles.length ? ` | styles: ${settings.outputStyles.join(", ")}` : ""}${master ? "" : " | master OFF"}`;
const configKey = JSON.stringify({ ...settings, model: MODEL, tasks: TASKS, runs: RUNS, maxCalls: MAX_CALLS, rtkHook, mode: "default" });

const resultsFile = join(HERE, "results.json");
const all = existsSync(resultsFile) ? JSON.parse(readFileSync(resultsFile, "utf8")) : {};
const sum = (a, f) => a.reduce((s, x) => s + f(x), 0);
const pct = (x) => `${Math.round(x * 100)}%`;

function ranking() {
  const rows = Object.values(all).filter((c) => c.mode === "default"); // older off/allow-lossy entries have another shape
  console.log("\ndate        hit   pass   cost/run  prompt  calls  config");
  for (const c of rows) console.log(`${c.date.slice(0, 10)}  ${pct(c.hit).padStart(4)}  ${c.pass.padStart(5)}  ${String(Math.round(c.costPerRun)).padStart(8)}  ${String(Math.round(c.avgPromptTokens ?? 0)).padStart(6)}  ${(c.apiCalls ?? c.turns ?? 0).toFixed(1).padStart(5)}  ${c.label} | ${c.model}`);
}

if (process.argv.includes("--ranking")) { ranking(); process.exit(0); }
if (all[configKey] && !OVERWRITE) {
  console.log(`Config "${label}" already benchmarked. Skipping (--overwrite to rerun).`);
  ranking(); process.exit(0);
}

// One run: copy fixture, git init, claude -p with your normal settings, read proxy stats by session tag.
// The session is killed as soon as it has made MAX_CALLS API calls (counted in the OmniRoute log), so no run costs more than that.
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const calls = (session) => db.prepare("select count(*) n from call_logs where session_tag=?").get(session).n;
async function runOne(task, run) {
  const session = `bench-${task}-${run}-${Date.now()}`;
  const work = mkdtempSync(join(tmpdir(), "bench-"));
  const settingsFile = `${work}.settings.json`;
  try {
    cpSync(join(HERE, "fixtures", FIXTURE[task]), work, { recursive: true });
    const git = (...a) => spawnSync("git", ["-c", "user.email=b@b", "-c", "user.name=b", ...a], { cwd: work, encoding: "utf8" });
    git("init", "-q"); writeFileSync(join(work, ".git/info/exclude"), "__pycache__/\n"); git("add", "-A"); git("commit", "-qm", "base");

    // No x-omniroute-compression header: OmniRoute uses its dashboard defaults.
    const headers = [`X-OmniRoute-Session-Id: ${session}`, "X-OmniRoute-No-Cache: true", "x-omniroute-no-memory: true"].join("\n");
    writeFileSync(settingsFile, JSON.stringify({ env: { ANTHROPIC_CUSTOM_HEADERS: headers } }));
    const prompt = readFileSync(join(HERE, "tasks", `${task}.txt`), "utf8");
    const child = spawn("claude", ["-p", prompt, "--output-format", "json", "--model", MODEL, "--settings", settingsFile, "--allowedTools", "Bash Read Edit Write Grep Glob"],
      { cwd: work, stdio: ["ignore", "pipe", "ignore"] });
    let stdout = ""; child.stdout.on("data", (d) => (stdout += d));
    let exited = false, capped = false; const done = new Promise((r) => child.on("close", () => { exited = true; r(); }));
    const started = Date.now();
    while (!exited && Date.now() - started < 900_000) {
      if (calls(session) >= MAX_CALLS) { capped = true; child.kill("SIGKILL"); break; }
      await Promise.race([done, sleep(500)]);
    }
    if (!exited) { child.kill("SIGKILL"); await done; }
    let out = {}; try { out = JSON.parse(stdout); } catch {}

    const pass = capped ? null : spawnSync("python3", ["-I", join(HERE, "tasks/check.py"), task, work], { encoding: "utf8" }).status === 0; // a cut-off run didn't finish, so it isn't graded

    // Proxy is the source of truth for tokens (Claude Code's own cost assumes list prices; subscription bills $0).
    // Rows land a moment after the call returns.
    let s; for (let i = 0; i < 5; i++) {
      s = db.prepare("select count(*) n, sum(tokens_in) tin, sum(tokens_cache_read) cr, sum(tokens_cache_creation) cc, sum(tokens_compressed) comp from call_logs where session_tag=?").get(session);
      if (s.n > 0) break; await sleep(1000);
    }
    const tin = Number(s.tin ?? 0), cr = Number(s.cr ?? 0), cc = Number(s.cc ?? 0), comp = Number(s.comp ?? 0);
    return {
      task, run, pass, capped, session, turns: out.num_turns ?? null, requests: s.n,
      prompt_tokens: tin, cache_read: cr, cache_creation: cc, cache_hit: tin ? Number((cr / tin).toFixed(3)) : 0,
      weighted_cost: Math.round(tin - cr - cc + 1.25 * cc + 0.1 * cr), compressed: comp,
      valid: s.n > 0 && (capped || !!out.num_turns), reached: s.n >= MIN_CALLS,
    };
  } finally { rmSync(work, { recursive: true, force: true }); rmSync(settingsFile, { force: true }); }
}

console.log(`Bench: ${label} | ${MODEL} | tasks ${TASKS.join(",")} x ${RUNS} runs | max ${MAX_CALLS} API calls each | your settings as is, OmniRoute defaults`);
const runs = [];
for (const task of TASKS) for (let r = 1; r <= RUNS; r++) {
  const x = await runOne(task, r); runs.push(x);
  console.log(`${task.padEnd(8)} #${r}  ${x.capped ? "CUT " : x.pass ? "PASS" : "FAIL"}  api calls ${String(x.requests).padStart(2)}  prompt ${String(x.prompt_tokens).padStart(6)}  hit ${String(Math.round(x.cache_hit * 100)).padStart(3)}%  compressed ${String(x.compressed).padStart(5)}${x.valid ? "" : "  INVALID"}${x.valid && !x.reached ? `  SHORT (<${MIN_CALLS} calls)` : ""}`);
}

const ok = runs.filter((x) => x.valid);
const invalid = runs.length - ok.length;
const hit = ok.length ? sum(ok, (x) => x.cache_hit) / ok.length : 0;
const costPerRun = ok.length ? sum(ok, (x) => x.weighted_cost) / ok.length : 0;
const avgPromptTokens = ok.length ? sum(ok, (x) => x.prompt_tokens) / ok.length : 0;
const calls_ = ok.length ? sum(ok, (x) => x.requests) / ok.length : 0;
const short = ok.filter((x) => !x.reached).length;
const graded = ok.filter((x) => x.pass !== null);
const pass = `${graded.filter((x) => x.pass).length}/${graded.length} graded (${ok.length - graded.length} cut at ${MAX_CALLS} calls)`;

all[configKey] = { date: new Date().toISOString(), mode: "default", rtkHook, label, model: MODEL, settings, tasks: TASKS, hit, pass, costPerRun, avgPromptTokens, apiCalls: calls_, compressed: sum(ok, (x) => x.compressed), runs };
Object.assign(all, existsSync(resultsFile) ? JSON.parse(readFileSync(resultsFile, "utf8")) : {}, { [configKey]: all[configKey] }); // re-read: another run may have saved meanwhile
writeFileSync(resultsFile, JSON.stringify(all, null, 2) + "\n");

console.log(`\n== ${label} ==\ncache hit: ${pct(hit)} avg   pass: ${pass}   avg prompt tokens/run: ${Math.round(avgPromptTokens)}   avg cost/run: ${Math.round(costPerRun)} (cache-weighted tokens)   avg API calls: ${calls_.toFixed(1)}${short ? `\n${short} run(s) made fewer than ${MIN_CALLS} API calls, so they did not test the late-call cache` : ""}${invalid ? `\n${invalid} run(s) INVALID (no proxy rows or no turns)` : ""}`);
console.log("saved to omniroute/bench/results.json");
ranking();
process.exit(invalid ? 1 : 0);
