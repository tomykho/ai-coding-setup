// PreToolUse Bash|Read gate, for every project (user CLAUDE.md rules), enforced instead of remembered.
// Run by settings.json as `<abs path to bun> <this file>`; uses Bun-only APIs, so Node can't run it.
//
// Search: recursive `grep -r` denied (use rg / ast-grep); single-file grep and `... | grep` filtering stay allowed.
// Edits: `sed -i` / `perl -pi` denied (use Edit: diff shown, no-match errors, /rewind works); plain sed allowed.
// Writes: `> file`, `>> file`, `tee file` outside /tmp, /dev, $VARS denied (use Write tool, same reasons as sed -i).
// Output size: `tree` (without -L), `ls -R`, `git log` without a bound and not piped denied.
// GitHub: curl/wget to github.com / api.github.com / raw.githubusercontent.com denied (use gh).
// Files: `find` without -maxdepth denied (use fd). JSON: python `-m json.tool` / inline json scripts denied (use jq); `python3 file.py` allowed.
// Reading docs (when rtk is installed):
//   denied: reading a whole project Markdown doc over MIN_LINES lines (Read without limit, cat/head/tail/less).
//   allowed: `rtk bulk-read --question`, rg + range reads to quote or edit lines, CLAUDE.md/AGENTS.md, .claude/.
import { appendFileSync, mkdirSync, realpathSync, readFileSync } from "node:fs";
import { basename, dirname, resolve, sep } from "node:path";
import { homedir } from "node:os";

const MIN_LINES = 80; // shorter docs are cheaper to read than to delegate

const inp = await Bun.stdin.json();
const tool: string = inp.tool_name ?? "";
const ti = inp.tool_input ?? {};
const rtk = Bun.which("rtk") !== null;
const root: string = process.env.CLAUDE_PROJECT_DIR || inp.cwd || process.cwd();

const DOCS = "Banned (CLAUDE.md, CLI tools): to learn what a doc says, run `rtk bulk-read --question \"...\" <paths>`. " +
  "To quote or edit exact lines, `rg` for them, then Read with offset/limit or `sed -n N,Mp`.";
const GREP = "Banned (CLAUDE.md, CLI tools): use `rg` for text search or `ast-grep run -p '<pattern>' -l <lang>` for code " +
  "structure instead of recursive grep (rg skips vendor/node_modules). Single-file grep and `cmd | grep x` are fine.";
const FIND = "Banned (CLAUDE.md, CLI tools): use `fd` instead of find (respects .gitignore). " +
  "e.g. `fd -e php`, `fd -t d name`, `fd -d 2`, `fd --changed-within 1d`, `fd -x cmd {}` / `-X cmd` for -exec. " +
  "`find ... -maxdepth N` is fine.";
const SED_I = "Banned (CLAUDE.md, CLI tools): don't edit files in place via Bash (`sed -i`, `perl -pi`): no diff, silent no-match, " +
  "and /rewind can't undo it. Use the Edit tool; for code across many files, `ast-grep run -p ... -r ...` (preview), then `-U`. " +
  "`sed -n N,Mp` and `cmd | sed ...` are fine.";
const JSON_PY = "Banned (CLAUDE.md, CLI tools): use `jq` (or `yq`, `jc <cmd> | jq`) instead of inline Python for JSON. " +
  "If jq truly can't do it, Write the script to a file and run `python3 <file>`.";

const WRITE = "Banned (CLAUDE.md, CLI tools): don't write files via shell redirects/tee (no diff, /rewind can't undo it). " +
  "Use the Write tool (or Edit). Redirects to /tmp/..., /dev/null or $VAR paths are fine.";
const TREE = "Banned (CLAUDE.md, CLI tools): recursive listings flood context. Use `fd -d 2` (or `fd -t d`), `tokei` for an overview, " +
  "or `tree -L 2`.";
const GITLOG = "Banned (CLAUDE.md, CLI tools): unbounded `git log` prints the whole history. Add a bound: " +
  "`git log --oneline -n 20`, `--since=2.weeks`, a range `a..b`, `-- <path>`, `-S`/`--grep`, or pipe to `head`.";
const GH = "Banned (CLAUDE.md, CLI tools): use `gh` for GitHub (authenticated, compact): `gh api repos/o/r/...`, " +
  "`gh release download -R o/r -p <asset>`, `gh api repos/o/r/contents/<path> --jq .content | base64 -d`.";

// every deny is logged (TSV: time, rule, cwd, command) to judge which rules earn their retry cost:
//   cut -f2 ~/.claude/logs/cli-tools-gate.log | sort | uniq -c | sort -rn
const LOG = process.env.CLI_TOOLS_GATE_LOG || `${homedir()}/.claude/logs/cli-tools-gate.log`; // env override for tests
const RULES: Record<string, string> = { [DOCS]: "docs", [GREP]: "grep", [FIND]: "find", [SED_I]: "sed-i", [JSON_PY]: "json-py",
  [WRITE]: "write", [TREE]: "tree", [GITLOG]: "git-log", [GH]: "gh" };

function deny(why: string): never {
  try {
    mkdirSync(dirname(LOG), { recursive: true });
    const what = String(ti.command ?? ti.file_path ?? "").replace(/\s+/g, " ").slice(0, 300);
    appendFileSync(LOG, [new Date().toISOString(), RULES[why] ?? "?", inp.cwd ?? "", what].join("\t") + "\n");
  } catch {} // logging must never break the gate
  console.log(JSON.stringify({ hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: why } }));
  process.exit(0);
}

function real(p: string): string {
  try { return realpathSync(p); } catch { return p; }
}

/** A project Markdown doc worth delegating: inside the project, not CLAUDE.md/AGENTS.md or .claude/, long. */
function longDoc(path: string): boolean {
  path = path.replace(/^["']+|["']+$/g, "").replace(/^~(?=\/|$)/, homedir());
  const p = real(resolve(root, path));
  if (!p.endsWith(".md") || !p.startsWith(real(root) + sep) || p.includes("/.claude/")) return false;
  if (["CLAUDE.md", "AGENTS.md"].includes(basename(p))) return false;
  try {
    const buf = readFileSync(p);
    let n = 0;
    for (const b of buf) if (b === 10) n++;
    if (buf.length && buf[buf.length - 1] !== 10) n++; // last line without trailing newline
    return n > MIN_LINES;
  } catch {
    return false;
  }
}

if (tool === "Read") {
  if (rtk && !ti.limit && longDoc(ti.file_path ?? "")) deny(DOCS);
  process.exit(0);
}

const raw: string = ti.command ?? "";

// inline python (-c / stdin heredoc) doing JSON, or json.tool: jq's job
const py = String.raw`\bpython[\d.]*\s+(?:-\w+\s+)*`;
if (new RegExp(py + String.raw`-m\s+json\.tool\b`).test(raw) ||
    (new RegExp(py + String.raw`(?:-c\b|-\s*<<|<<)`).test(raw) && /\bimport\s+json\b|\bjson\.(?:loads?|dumps?)\b/.test(raw))) deny(JSON_PY);
// checked on raw: URLs usually sit inside quotes
if (/\b(?:curl|wget|xh|http)\b[^\n|;&]*?\b(?:api\.github\.com|github\.com|raw\.githubusercontent\.com)\b/.test(raw)) deny(GH);

// recursive grep / unbounded find walk vendor/ and node_modules/ (rg / fd skip .gitignored dirs); single-file grep is fine
const grep = /^\s*(?:\w+=\S*\s+)*(?:sudo\s+|command\s+|env\s+)*[ef]?grep\b/;
const grepRecursive = /\s(?:-[a-zA-Z]*[rR]|--(?:dereference-)?recursive\b|-d\s*recurse\b|--directories=recurse\b)/;
const find = /^\s*(?:\w+=\S*\s+)*(?:sudo\s+|command\s+|env\s+)*find\b(?!.*\s-maxdepth\s)/;
// in-place edit flag in any pipe stage (incl. `rg -l x | xargs sed -i ...`); quoted args blanked so 's/-i/x/' doesn't count
const sedI = /^\s*(?:\w+=\S*\s+)*(?:sudo\s+|command\s+|env\s+|xargs\s+(?:-\S+\s+)*)*(?:sed\s+(?:\S+\s+)*?(?:-[a-zA-Z]*i|--in-place)|perl\s+(?:-\S+\s+)*-[lnpaw0-9]*i)/;
const unquote = (s: string) => s.replace(/'[^']*'|"[^"]*"/g, "Q");
const dump = /^\s*(?:cat|head|tail|less|more|bat)\b(?![^>]*>)/; // `cat > f <<EOF` writes, not reads
const pre = String.raw`^\s*(?:\w+=\S*\s+)*(?:sudo\s+|command\s+|env\s+)*`;
const tree = new RegExp(pre + String.raw`(?:tree\b(?!.*\s-L\s*\d)|ls\s+(?:\S+\s+)*?-[a-zA-Z]*R)`);
const gitLog = new RegExp(pre + String.raw`git\s+(?:-C\s+\S+\s+|-c\s+\S+\s+|--?\S+\s+)*log\b`);
const logBound = /\s(?:-n\s*\d|-\d+\b|--max-count|--since|--after|--until|--before|--\s|-S|-G|--grep|--author|-L)|\S\.\.\S/;
// redirect / tee targets; `2>&1`, `>&2`, `>(cmd)` aren't files. Allowed: /tmp, /var/tmp, /dev, $VAR paths (mktemp etc.)
const redirect = /(?:^|[^<>&\d])(?:\d?>>?|&>>?)\s*([^\s&|;<>()][^\s|;<>()]*)/g;
const teeArgs = /\btee\s+([^<>]*)/; // stop at redirects: `tee f >/dev/null`
const okTarget = (t: string) => /^(?:\/tmp\/|\/var\/tmp\/|\/dev\/|\$)/.test(t);
function writesFile(part: string): boolean {
  // blank quoted text (`echo "a > b"`), but keep a quoted redirect target's content (`> "/tmp/x"`)
  part = part.replace(/((?:\d?>>?|&>>?)\s*)?('[^']*'|"[^"]*")/g, (_, r, q) => (r ? r + q.slice(1, -1) : "Q"));
  for (const m of part.matchAll(redirect)) if (!okTarget(m[1])) return true;
  const tee = part.match(teeArgs);
  return !!tee && tee[1].split(/\s+/).some((a) => a && !a.startsWith("-") && !okTarget(a));
}

// mask separators inside quotes so a regex like 'a|b' isn't mistaken for a pipe; in single quotes,
// backticks and newlines are literal too (e.g. `bun -e '...'` code), in double quotes backticks still substitute
// heredoc bodies are data (file contents, script text), not commands: drop them before splitting
const cmd = raw
  .replace(/<<-?\s*(['"]?)(\w+)\1[^\n]*\n[\s\S]*?\n\s*\2\s*(?=\n|$)/g, "<<HEREDOC")
  .replace(/'[^']*'|"[^"]*"/g, (m) => m.replace(m[0] === "'" ? /[|;&`\n]/g : /[|;&\n]/g, "\x00"));
for (const seg of cmd.split(/&&|\|\||;|\n|\$\(|`/)) {
  const head = seg.split("|")[0]; // after a pipe, head/tail filter command output: fine
  if (grep.test(head) && grepRecursive.test(unquote(head))) deny(GREP);
  if (find.test(head)) deny(FIND);
  if (seg.split("|").some((p) => sedI.test(unquote(p)))) deny(SED_I);
  if (seg.split("|").some(writesFile)) deny(WRITE);
  if (tree.test(unquote(head))) deny(TREE);
  if (gitLog.test(unquote(head)) && !seg.includes("|") && !logBound.test(unquote(head))) deny(GITLOG);
  if (rtk && dump.test(head) && head.trim().split(/\s+/).slice(1).some(longDoc)) deny(DOCS); // longDoc strips quotes, then checks .md
}
