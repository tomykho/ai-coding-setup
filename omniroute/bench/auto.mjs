#!/usr/bin/env node
// Automates run.mjs: one engine per test, one after another, using the DASHBOARD settings (the per-request `engine:<id>`
// header is legacy and not used). For each engine it turns the master switch on, enables ONLY that engine (at the given
// level), clears output styles, probes that it really compresses, runs the bench (`allow-lossy` follows the dashboard),
// then restores your dashboard settings. Multi-engine combos stay manual: set them in the dashboard and run run.mjs.
//
//   node omniroute/bench/auto.mjs                     every engine once + 2 stacks (a single engine ignores its level)
//   ENGINES=caveman,rtk+caveman,rtk:minimal+caveman:ultra node omniroute/bench/auto.mjs   ("+" = stack, levels apply in stacks)
//   PROBE_ONLY=1 node omniroute/bench/auto.mjs        only the compression probes (seconds, almost free), no bench runs
//   node omniroute/bench/auto.mjs --overwrite         rerun engines that already have results
//   RUNS=5 TASKS=small,medium,feature node omniroute/bench/auto.mjs
//
// The shared `off` baseline runs first, once. The probe sends a conversation with something for every engine to compress
// (wordy prose, git log tool output) with `allow-lossy` and reads the response header `tokens=a->b`. It is recorded in
// bench/preflight.json and printed; an engine that saves nothing on the probe is still benched (real tasks may differ).
//
// This writes the `compression` rows (enabled, engines, outputStyles) in ~/.omniroute/storage.sqlite directly. Originals are
// saved to bench/.dashboard-backup.json first and restored when done, on Ctrl+C, or at the next start if a run crashed.
// Avoid touching the dashboard compression settings while it runs.
import { readFileSync, writeFileSync, existsSync, rmSync } from "node:fs";
import { homedir } from "node:os";
import { spawn } from "node:child_process";

const HERE = new URL(".", import.meta.url).pathname;
const BACKUP = `${HERE}.dashboard-backup.json`;
const PROBE_ONLY = !!process.env.PROBE_ONLY;
// Stacks worth benching: probes showed the rtk level matters in a stack (minimal = standard < aggressive) and the caveman level never does.
const STACKS = ["rtk:standard+caveman:full", "rtk:aggressive+caveman:full"];
const KEYS = ["enabled", "engines", "outputStyles"];
// Only caveman and rtk have levels (engineCatalog.ts in the OmniRoute source).
const LEVELS = { caveman: ["lite", "full", "ultra"], rtk: ["minimal", "standard", "aggressive"] };
const { DatabaseSync } = await import("node:sqlite").catch(() => { console.error("Needs Node 22+ (node:sqlite)"); process.exit(2); });
const db = new DatabaseSync(`${homedir()}/.omniroute/storage.sqlite`);
db.exec("PRAGMA busy_timeout = 5000");

const get = (k) => db.prepare("select value from key_value where namespace='compression' and key=?").get(k)?.value;
const set = (k, v) => db.prepare("update key_value set value=? where namespace='compression' and key=?").run(v, k);
const restore = () => {
  if (!existsSync(BACKUP)) return;
  for (const [k, v] of Object.entries(JSON.parse(readFileSync(BACKUP, "utf8")))) set(k, v);
  rmSync(BACKUP); console.log("dashboard compression settings restored");
};

if (existsSync(BACKUP)) { console.log("found a backup from a crashed run:"); restore(); }
const original = Object.fromEntries(KEYS.map((k) => [k, get(k)]));
if (KEYS.some((k) => original[k] === undefined)) { console.error("compression settings not found in OmniRoute DB; open the dashboard compression page once and save"); process.exit(2); }
writeFileSync(BACKUP, JSON.stringify(original));

let child = null;
for (const sig of ["SIGINT", "SIGTERM"]) process.on(sig, () => { child?.kill("SIGTERM"); restore(); process.exit(130); });

// Async spawn (not spawnSync) so the event loop stays free and Ctrl+C / SIGTERM reach the restore handler.
const run = (args) => new Promise((res) => {
  child = spawn("node", [`${HERE}run.mjs`, ...args], { stdio: "inherit", env: process.env });
  child.on("exit", (code) => { child = null; res(code ?? 1); });
});

// Probe: same request shape every time, so engines are comparable.
const cfg = (() => { try { return JSON.parse(readFileSync(`${homedir()}/.claude/settings.json`, "utf8")).env ?? {}; } catch { return {}; } })();
const URL_ = (process.env.BASE_URL ?? cfg.ANTHROPIC_BASE_URL ?? "http://localhost:20128").replace(/\/+$/, "");
const TOKEN = process.env.TOKEN ?? cfg.ANTHROPIC_AUTH_TOKEN ?? "";
const MODEL = process.env.MODEL ?? "claude-haiku-5-5";
const prose = Array.from({ length: 40 }, (_, i) => `I would really like you to please note that, basically, it is actually very important that you simply remember rule ${i + 1}, which is that answers should be kept short.`).join("\n");
const gitLog = Array.from({ length: 60 }, (_, i) => `commit ${(i * 7919 + 104729).toString(16).padStart(40, "a")}\nAuthor: Dev <dev@example.com>\nDate:   Mon Jan ${(i % 28) + 1} 10:00:00 2026 +0000\n\n    change ${i + 1}: fix thing\n`).join("\n");
const probeBody = { model: MODEL, max_tokens: 5, messages: [
  { role: "user", content: `Background:\n${prose}\nNow run git log.` },
  { role: "assistant", content: [{ type: "tool_use", id: "toolu_probe1", name: "Bash", input: { command: "git log" } }] },
  { role: "user", content: [{ type: "tool_result", tool_use_id: "toolu_probe1", content: gitLog }] },
  { role: "assistant", content: "Got it." },
  { role: "user", content: gitLog.slice(0, 3000) + "\nReply with 1." }],
  tools: [{ name: "Bash", description: "Run a shell command", input_schema: { type: "object", properties: { command: { type: "string" } }, required: ["command"] } }] };
async function probe() {
  const r = await fetch(`${URL_}/v1/messages`, { method: "POST", body: JSON.stringify(probeBody), headers: { "content-type": "application/json", "anthropic-version": "2023-06-01",
    authorization: `Bearer ${TOKEN}`, "x-omniroute-compression": "allow-lossy", "X-OmniRoute-No-Cache": "true", "x-omniroute-no-memory": "true" } });
  const h = r.headers.get("x-omniroute-compression") ?? "";
  const t = h.match(/tokens=(\d+)->(\d+)/);
  return { status: r.status, header: h, before: t ? +t[1] : null, after: t ? +t[2] : null };
}
const preflightFile = `${HERE}preflight.json`;
const preflight = existsSync(preflightFile) ? JSON.parse(readFileSync(preflightFile, "utf8")) : {};

let status = 0;
try {
  const engines = JSON.parse(original.engines);
  // Default: each engine once (single engine ignores its level, so caveman/rtk run at their saved level) plus the stacked pair.
  const list = process.env.ENGINES ? process.env.ENGINES.split(",") : [...Object.keys(engines), ...STACKS];
  const specs = [];
  for (const spec of list) { // "ccr", "caveman:lite", or a stack "rtk+caveman" / "rtk:minimal+caveman:ultra" (levels matter only in stacks)
    const parts = spec.split("+").map((p) => { const [id, level] = p.split(":"); return { id, level }; });
    const bad = parts.find(({ id, level }) => !engines[id] || (level && !LEVELS[id]?.includes(level)));
    if (bad) { console.error(`bad engine/level "${bad.id}${bad.level ? ":" + bad.level : ""}" (engines: ${Object.keys(engines).join(", ")}; levels: ${JSON.stringify(LEVELS)})`); status = 2; continue; }
    specs.push(parts);
  }
  if (!TOKEN) { console.error("No token in ~/.claude/settings.json (env.ANTHROPIC_AUTH_TOKEN) or TOKEN env; cannot probe"); process.exit(2); }
  const nameOf = (parts) => parts.map(({ id, level }) => { const l = level ?? engines[id].level; return l ? `${id}:${l}` : id; }).join("+");
  console.log(`${specs.length} tests: ${specs.map(nameOf).join(", ")}`);

  if (!PROBE_ONLY) {
    console.log("\n######## baseline (compression off, shared) ########");
    const b = await run(["--baseline-only"]);
    if (b) status = Math.max(status, b);
  }
  for (const parts of specs) {
    const on = Object.fromEntries(parts.map((p) => [p.id, p.level]));
    const only = Object.fromEntries(Object.entries(engines).map(([k, v]) => [k, { ...v, enabled: k in on, ...(on[k] ? { level: on[k] } : {}) }]));
    set("enabled", "true"); set("engines", JSON.stringify(only)); set("outputStyles", "[]");
    const name = nameOf(parts);
    console.log(`\n######## engine: ${name} ########`);
    await new Promise((r) => setTimeout(r, 5000)); // let OmniRoute pick up the new settings
    const p = await probe().catch((e) => ({ status: 0, header: String(e), before: null, after: null }));
    const saved = p.before !== null ? p.before - p.after : 0;
    preflight[name] = { date: new Date().toISOString(), ...p, saved };
    writeFileSync(preflightFile, JSON.stringify(preflight, null, 2) + "\n");
    console.log(`probe: ${p.before !== null ? `tokens ${p.before}->${p.after}` : `no token stats (${p.status} ${p.header.slice(0, 60)})`}  ${saved > 0 ? "compressing" : "no savings on probe"}`);
    if (PROBE_ONLY) continue;
    const code = await run(process.argv.slice(2));
    if (code) status = Math.max(status, code);
  }
} finally { restore(); }
process.exit(status);
