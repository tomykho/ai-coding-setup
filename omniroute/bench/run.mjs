#!/usr/bin/env node
// Code-quality bench: does lossy compression make Claude Code write worse code, or cost more?
// Runs real `claude -p` coding tasks against a small inventory repo (data = bench/fixtures/*/data/items.csv, 600 rows),
// once with compression `off` and once with `allow-lossy` (= your OmniRoute dashboard engines). Each result is graded by
// bench/tasks/check.py, which recomputes the expected answers from the CSV, so a model that lost context fails.
//
//   node omniroute/bench/run.mjs               (a config already in results.json is skipped)
//   node omniroute/bench/run.mjs --overwrite   (rerun the current config)
//   node omniroute/bench/run.mjs --rebaseline  (redo the shared `off` baseline, stored in baseline.json)
//   RUNS=5 TASKS=small,medium,feature node omniroute/bench/run.mjs
// `off` ignores the engines, so it runs once per model+tasks+RUNS and every config is compared against it.
//
// Needs: claude CLI, python3, git, Node 22+ (node:sqlite), local OmniRoute. Uses your ~/.claude/settings.json as is
// (token never printed or stored); only the per-run compression header is added through a temp --settings file.
// Output: bench/results.json (per config) and bench/results.csv (one row per run). Approx $0.01 per run on haiku.
// Exit 0 = ran/skipped, 1 = a variant failed its validity gate, 2 = setup error.
import { readFileSync, writeFileSync, mkdtempSync, cpSync, rmSync, mkdirSync, existsSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

const HERE = new URL(".", import.meta.url).pathname;
const RUNS = Number(process.env.RUNS ?? 3);
const TASKS = (process.env.TASKS ?? "small,feature").split(",");
const MODEL = process.env.MODEL ?? "claude-haiku-5-5";
const VARIANTS = ["off", "allow-lossy"];
const FIXTURE = { small: "inv", medium: "inv", feature: "inv_fixed", longout: "inv_long" }; // feature starts from the bug-free repo
const OVERWRITE = process.argv.includes("--overwrite");
const REBASELINE = process.argv.includes("--rebaseline");
const DB = `${homedir()}/.omniroute/storage.sqlite`;

for (const [bin, arg] of [["claude", "--version"], ["python3", "--version"], ["git", "--version"]]) {
  if (spawnSync(bin, [arg]).error) { console.error(`${bin} not found`); process.exit(2); }
}
const { DatabaseSync } = await import("node:sqlite").catch(() => { console.error("Needs Node 22+ (node:sqlite)"); process.exit(2); });
const db = new DatabaseSync(DB, { readOnly: true });

// Dashboard settings = the config key (same logic as test-cache-compression.mjs; master off collapses to one entry).
const kv = Object.fromEntries(db.prepare("select key, value from key_value where namespace='compression'").all().map((r) => [r.key, r.value]));
const master = kv.enabled === "true";
const settings = {
  engines: master ? Object.entries(JSON.parse(kv.engines ?? "{}")).filter(([, v]) => v.enabled).map(([k, v]) => (v.level ? `${k}:${v.level}` : k)).sort() : [],
  outputStyles: master ? JSON.parse(kv.outputStyles ?? "[]").map((s) => `${s.id}:${s.level}`).sort() : [],
  master,
};
const label = `${settings.engines.join(", ") || "none"}${settings.outputStyles.length ? ` | styles: ${settings.outputStyles.join(", ")}` : ""}${master ? "" : " | master OFF"}`;
const configKey = JSON.stringify({ ...settings, model: MODEL, tasks: TASKS });
const BASELINE_ONLY = process.argv.includes("--baseline-only");

const resultsFile = join(HERE, "results.json");
const all = existsSync(resultsFile) ? JSON.parse(readFileSync(resultsFile, "utf8")) : {};
const csvCell = (v) => (/[",\n]/.test(String(v)) ? `"${String(v).replaceAll('"', '""')}"` : String(v));
function writeCsv() {
  const cols = ["config", "model", "variant", "task", "run", "pass", "valid", "prompt_tokens", "cache_hit", "weighted_cost", "compressed", "turns", "added", "removed", "defs_added", "tests_added", "session"];
  const baseRuns = Object.values(existsSync(baseFile) ? JSON.parse(readFileSync(baseFile, "utf8")) : {}).flatMap((b) => b.runs.map((r) => ({ ...r, label: "baseline (off)", model: MODEL })));
  const rows = [...baseRuns, ...Object.values(all).flatMap((c) => c.runs.map((r) => ({ ...r, label: c.label, model: c.model })))]
    .map((r) => [r.label, r.model, ...cols.slice(2).map((k) => r[k] ?? "")]);
  writeFileSync(join(HERE, "results.csv"), [cols, ...rows].map((r) => r.map(csvCell).join(",")).join("\n") + "\n");
}
const sum = (a, f) => a.reduce((s, x) => s + f(x), 0);
function ranking() {
  console.log("\ncost vs off  pass off  pass lossy  hit    config");
  const rows = Object.values(all).sort((a, b) => a.costVsOff - b.costVsOff);
  for (const c of rows) console.log(`${(c.costVsOff * 100).toFixed(1).padStart(10)}%  ${c.off.pass.padStart(8)}  ${c.lossy.pass.padStart(10)}  ${String(Math.round(c.lossy.hit * 100)).padStart(3)}%   ${c.label}${c.model === MODEL ? "" : ` | ${c.model}`}`);
}

if (process.argv.includes("--ranking")) { ranking(); process.exit(0); }
if (!BASELINE_ONLY && all[configKey] && !OVERWRITE) {
  console.log(`Config "${label}" already benchmarked. Skipping (--overwrite to rerun).`);
  ranking(); process.exit(0);
}

// One run: copy fixture, git init, claude -p with the variant header, grade, diff, read proxy stats by session tag.
function runOne(variant, task, run) {
  const session = `bench-${variant}-${task}-${run}-${Date.now()}`;
  const work = mkdtempSync(join(tmpdir(), "bench-"));
  const settingsFile = `${work}.settings.json`;
  try {
    cpSync(join(HERE, "fixtures", FIXTURE[task]), work, { recursive: true });
    const git = (...a) => spawnSync("git", ["-c", "user.email=b@b", "-c", "user.name=b", ...a], { cwd: work, encoding: "utf8" });
    git("init", "-q"); writeFileSync(join(work, ".git/info/exclude"), "__pycache__/\n"); git("add", "-A"); git("commit", "-qm", "base");

    const headers = [`X-OmniRoute-Session-Id: ${session}`, "X-OmniRoute-No-Cache: true", "x-omniroute-no-memory: true", `x-omniroute-compression: ${variant}`].join("\n");
    writeFileSync(settingsFile, JSON.stringify({ env: { ANTHROPIC_CUSTOM_HEADERS: headers } }));
    const prompt = readFileSync(join(HERE, "tasks", `${task}.txt`), "utf8");
    const p = spawnSync("claude", ["-p", prompt, "--output-format", "json", "--model", MODEL, "--settings", settingsFile, "--allowedTools", "Bash Read Edit Write Grep Glob"],
      { cwd: work, encoding: "utf8", timeout: 900_000 });
    let out = {}; try { out = JSON.parse(p.stdout); } catch {}

    const pass = spawnSync("python3", ["-I", join(HERE, "tasks/check.py"), task, work], { encoding: "utf8" }).status === 0;
    git("add", "-A");
    const base = git("rev-list", "--max-parents=0", "HEAD").stdout.trim();
    const diff = git("diff", "--cached", base).stdout;
    mkdirSync(join(HERE, "diffs"), { recursive: true });
    writeFileSync(join(HERE, "diffs", `${variant}-${task}-${run}.diff`), diff);
    const num = git("diff", "--cached", "--numstat", base).stdout.trim().split("\n").filter(Boolean).map((l) => l.split("\t").map(Number));

    // Proxy is the source of truth for tokens (Claude Code's own cost assumes list prices; subscription bills $0).
    // Rows land a moment after the call returns.
    let s; for (let i = 0; i < 5; i++) {
      s = db.prepare("select count(*) n, sum(tokens_in) tin, sum(tokens_cache_read) cr, sum(tokens_cache_creation) cc, sum(tokens_compressed) comp from call_logs where session_tag=?").get(session);
      if (s.n > 0) break; spawnSync("sleep", ["1"]);
    }
    const tin = Number(s.tin ?? 0), cr = Number(s.cr ?? 0), cc = Number(s.cc ?? 0), comp = Number(s.comp ?? 0);
    const added = sum(num, (n) => n[0] || 0);
    return {
      variant, task, run, pass, session, turns: out.num_turns ?? null,
      prompt_tokens: tin, cache_hit: tin ? Number((cr / tin).toFixed(3)) : 0,
      weighted_cost: Math.round(tin - cr - cc + 1.25 * cc + 0.1 * cr), compressed: comp,
      // off must compress nothing; allow-lossy that compresses nothing is "no compression", not a failure.
      valid: s.n > 0 && !!out.num_turns && (variant !== "off" || comp === 0),
      added, removed: sum(num, (n) => n[1] || 0),
      defs_added: (diff.match(/^\+\s*(def|class) /gm) ?? []).length,
      tests_added: (diff.match(/^\+\s*def test_/gm) ?? []).length,
    };
  } finally { rmSync(work, { recursive: true, force: true }); rmSync(settingsFile, { force: true }); }
}

// `off` never touches the engines, so it is the same baseline for every config: run it once per model+tasks (--rebaseline
// to redo it) and only run allow-lossy per config.
const baseFile = join(HERE, "baseline.json");
const baseKey = JSON.stringify({ model: MODEL, tasks: TASKS, runs: RUNS });
const bases = existsSync(baseFile) ? JSON.parse(readFileSync(baseFile, "utf8")) : {};
const line = (v, task, r, x) => console.log(`${v.padEnd(11)} ${task.padEnd(8)} #${r}  ${x.pass ? "PASS" : "FAIL"}  prompt ${String(x.prompt_tokens).padStart(6)}  hit ${String(Math.round(x.cache_hit * 100)).padStart(3)}%  compressed ${String(x.compressed).padStart(5)}  +${x.added}/-${x.removed}  tests+${x.tests_added}${x.valid ? "" : "  INVALID"}`);
const loop = (v) => { const out = []; for (const task of TASKS) for (let r = 1; r <= RUNS; r++) { const x = runOne(v, task, r); out.push(x); line(v, task, r, x); } return out; };
const agg = (a0) => {
  const a = a0.filter((x) => x.valid);
  return { n: a.length, pass: `${a.filter((x) => x.pass).length}/${a.length}`, prompt: sum(a, (x) => x.prompt_tokens), cost: sum(a, (x) => x.weighted_cost),
    hit: a.length ? sum(a, (x) => x.cache_hit) / a.length : 0, compressed: sum(a, (x) => x.compressed), testsAdded: sum(a, (x) => x.tests_added) };
};
if (!bases[baseKey] || REBASELINE) {
  console.log(`Baseline (compression off, shared by every engine) | ${MODEL} | tasks ${TASKS.join(",")} x ${RUNS} runs`);
  const runs = loop("off");
  bases[baseKey] = { date: new Date().toISOString(), runs, ...agg(runs) };
  writeFileSync(baseFile, JSON.stringify(bases, null, 2) + "\n");
}
const base = bases[baseKey];
if (BASELINE_ONLY) process.exit(base.runs.some((x) => !x.valid) ? 1 : 0);

console.log(`Bench: ${label} | ${MODEL} | tasks ${TASKS.join(",")} x ${RUNS} runs, allow-lossy vs saved baseline (${base.date.slice(0, 10)})`);
const runs = loop("allow-lossy");

const off = { ...base, runs: undefined, date: undefined }, lossy = agg(runs);
const invalid = runs.filter((x) => !x.valid).length + base.runs.filter((x) => !x.valid).length;
const perRun = (a) => (a.n ? a.cost / a.n : 0); // per valid run, so a dropped run doesn't skew the comparison
const costVsOff = perRun(off) ? Number((perRun(lossy) / perRun(off) - 1).toFixed(3)) : 0;
const passRate = (a) => Number(a.pass.split("/")[0]) / (Number(a.pass.split("/")[1]) || 1);
const result = invalid ? "INVALID RUNS" : passRate(lossy) < passRate(off) ? "QUALITY DROP" : lossy.compressed <= 0 ? "NO COMPRESSION" : "PASS";

all[configKey] = { date: new Date().toISOString(), label, model: MODEL, settings, tasks: TASKS, off, lossy, costVsOff, result, runs };
Object.assign(all, existsSync(resultsFile) ? JSON.parse(readFileSync(resultsFile, "utf8")) : {}, { [configKey]: all[configKey] }); // re-read: other engines may have saved meanwhile
writeFileSync(resultsFile, JSON.stringify(all, null, 2) + "\n");
writeCsv();

console.log(`\n== ${label} ==\npass:  off ${off.pass}  allow-lossy ${lossy.pass}\ncost:  ${(costVsOff * 100).toFixed(1)}% vs off (cache-weighted, per run)   hit: off ${Math.round(off.hit * 100)}%  lossy ${Math.round(lossy.hit * 100)}%\ncompressed tokens (lossy): ${lossy.compressed}   tests added: off ${off.testsAdded}  lossy ${lossy.testsAdded}\nresult: ${result}${invalid ? ` (${invalid} run(s) failed the validity gate, e.g. no proxy rows or compression ran under off)` : ""}`);
console.log("saved to omniroute/bench/results.json and results.csv; diffs in omniroute/bench/diffs/");
ranking();
process.exit(invalid ? 1 : 0);
