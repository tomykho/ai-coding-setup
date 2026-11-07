#!/usr/bin/env python3
# PreToolUse Bash|Read gate, for every project (user CLAUDE.md rules), enforced instead of remembered.
# Run by settings.json as `python3 <this file>`; standard library only.
#
# Search: recursive `grep -r` denied (use rg / ast-grep); single-file grep and `... | grep` filtering stay allowed.
# Edits: `sed -i` / `perl -pi` denied (use Edit: diff shown, no-match errors, /rewind works); plain sed allowed.
# Writes: `> file`, `>> file`, `tee file` outside /tmp, /dev, $VARS denied (use Write tool, same reasons as sed -i).
# Output size: `tree` (without -L), `ls -R`, `git log` without a bound and not piped denied.
# GitHub: curl/wget to github.com / api.github.com / raw.githubusercontent.com denied (use gh).
# Files: `find` without -maxdepth denied (use fd). JSON: python `-m json.tool` / inline json scripts denied (use jq); `python3 file.py` allowed.
import json
import os
import re
import sys
from datetime import datetime, timezone

A = re.A  # ASCII classes, like the JS regexes this was ported from

try:
    inp = json.load(sys.stdin)
except Exception:
    sys.exit(0)  # unreadable input: never block
tool = inp.get("tool_name") or ""
ti = inp.get("tool_input") or {}

GREP = ("Banned (CLAUDE.md, CLI tools): use `rg` for text search or `ast-grep run -p '<pattern>' -l <lang>` for code "
        "structure instead of recursive grep (rg skips vendor/node_modules). Single-file grep and `cmd | grep x` are fine.")
FIND = ("Banned (CLAUDE.md, CLI tools): use `fd` instead of find (respects .gitignore). "
        "e.g. `fd -e php`, `fd -t d name`, `fd -d 2`, `fd --changed-within 1d`, `fd -x cmd {}` / `-X cmd` for -exec. "
        "`find ... -maxdepth N` is fine.")
SED_I = ("Banned (CLAUDE.md, CLI tools): don't edit files in place via Bash (`sed -i`, `perl -pi`): no diff, silent no-match, "
         "and /rewind can't undo it. Use the Edit tool; for code across many files, `ast-grep run -p ... -r ...` (preview), then `-U`. "
         "`sed -n N,Mp` and `cmd | sed ...` are fine.")
JSON_PY = ("Banned (CLAUDE.md, CLI tools): use `jq` (or `yq`, `jc <cmd> | jq`) instead of inline Python for JSON. "
           "If jq truly can't do it, Write the script to a file and run `python3 <file>`.")
WRITE = ("Banned (CLAUDE.md, CLI tools): don't write files via shell redirects/tee (no diff, /rewind can't undo it). "
         "Use the Write tool (or Edit). Redirects to /tmp/..., /dev/null or $VAR paths are fine.")
TREE = ("Banned (CLAUDE.md, CLI tools): recursive listings flood context. Use `fd -d 2` (or `fd -t d`), `tokei` for an overview, "
        "or `tree -L 2`.")
GITLOG = ("Banned (CLAUDE.md, CLI tools): unbounded `git log` prints the whole history. Add a bound: "
          "`git log --oneline -n 20`, `--since=2.weeks`, a range `a..b`, `-- <path>`, `-S`/`--grep`, or pipe to `head`.")
GH = ("Banned (CLAUDE.md, CLI tools): use `gh` for GitHub (authenticated, compact): `gh api repos/o/r/...`, "
      "`gh release download -R o/r -p <asset>`, `gh api repos/o/r/contents/<path> --jq .content | base64 -d`.")

# every deny is logged (TSV: time, rule, cwd, command) to judge which rules earn their retry cost:
#   cut -f2 ~/.claude/logs/cli-tools-gate.log | sort | uniq -c | sort -rn
LOG = os.environ.get("CLI_TOOLS_GATE_LOG") or os.path.expanduser("~/.claude/logs/cli-tools-gate.log")  # env override for tests
RULES = {GREP: "grep", FIND: "find", SED_I: "sed-i", JSON_PY: "json-py", WRITE: "write", TREE: "tree", GITLOG: "git-log", GH: "gh"}


def deny(why):
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        what = re.sub(r"\s+", " ", str(ti.get("command") or ti.get("file_path") or ""))[:300]
        now = datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
        with open(LOG, "a") as f:
            f.write("\t".join([now, RULES.get(why, "?"), inp.get("cwd") or "", what]) + "\n")
    except Exception:
        pass  # logging must never break the gate
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": why}}))
    sys.exit(0)


if tool == "Read":
    sys.exit(0)

raw = ti.get("command") or ""

# inline python (-c / stdin heredoc) doing JSON, or json.tool: jq's job
py = r"\bpython[\d.]*\s+(?:-\w+\s+)*"
if (re.search(py + r"-m\s+json\.tool\b", raw, A) or
        (re.search(py + r"(?:-c\b|-\s*<<|<<)", raw, A) and re.search(r"\bimport\s+json\b|\bjson\.(?:loads?|dumps?)\b", raw, A))):
    deny(JSON_PY)
# checked on raw: URLs usually sit inside quotes
if re.search(r"\b(?:curl|wget|xh|http)\b[^\n|;&]*?\b(?:api\.github\.com|github\.com|raw\.githubusercontent\.com)\b", raw, A):
    deny(GH)

# recursive grep / unbounded find walk vendor/ and node_modules/ (rg / fd skip .gitignored dirs); single-file grep is fine
pre = r"^\s*(?:\w+=\S*\s+)*(?:sudo\s+|command\s+|env\s+)*"
grep = re.compile(pre + r"[ef]?grep\b", A)
grep_recursive = re.compile(r"\s(?:-[a-zA-Z]*[rR]|--(?:dereference-)?recursive\b|-d\s*recurse\b|--directories=recurse\b)", A)
find = re.compile(pre + r"find\b(?!.*\s-maxdepth\s)", A)
# in-place edit flag in any pipe stage (incl. `rg -l x | xargs sed -i ...`); quoted args blanked so 's/-i/x/' doesn't count
sed_i = re.compile(r"^\s*(?:\w+=\S*\s+)*(?:sudo\s+|command\s+|env\s+|xargs\s+(?:-\S+\s+)*)*"
                   r"(?:sed\s+(?:\S+\s+)*?(?:-[a-zA-Z]*i|--in-place)|perl\s+(?:-\S+\s+)*-[lnpaw0-9]*i)", A)
tree = re.compile(pre + r"(?:tree\b(?!.*\s-L\s*\d)|ls\s+(?:\S+\s+)*?-[a-zA-Z]*R)", A)
git_log = re.compile(pre + r"git\s+(?:-C\s+\S+\s+|-c\s+\S+\s+|--?\S+\s+)*log\b", A)
log_bound = re.compile(r"\s(?:-n\s*\d|-\d+\b|--max-count|--since|--after|--until|--before|--\s|-S|-G|--grep|--author|-L)|\S\.\.\S", A)
# redirect / tee targets; `2>&1`, `>&2`, `>(cmd)` aren't files. Allowed: /tmp, /var/tmp, /dev, $VAR paths (mktemp etc.)
redirect = re.compile(r"(?:^|[^<>&\d])(?:\d?>>?|&>>?)\s*([^\s&|;<>()][^\s|;<>()]*)", A)
tee_args = re.compile(r"\btee\s+([^<>]*)", A)  # stop at redirects: `tee f >/dev/null`
quoted = re.compile(r"'[^']*'|\"[^\"]*\"")
quoted_target = re.compile(r"((?:\d?>>?|&>>?)\s*)?('[^']*'|\"[^\"]*\")", A)


def unquote(s):
    return quoted.sub("Q", s)


def ok_target(t):
    return re.match(r"(?:/tmp/|/var/tmp/|/dev/|\$)", t) is not None


def writes_file(part):
    # blank quoted text (`echo "a > b"`), but keep a quoted redirect target's content (`> "/tmp/x"`)
    part = quoted_target.sub(lambda m: m.group(1) + m.group(2)[1:-1] if m.group(1) else "Q", part)
    for m in redirect.finditer(part):
        if not ok_target(m.group(1)):
            return True
    tee = tee_args.search(part)
    return bool(tee) and any(a and not a.startswith("-") and not ok_target(a) for a in re.split(r"\s+", tee.group(1)))


def mask(m):
    # mask separators inside quotes so a regex like 'a|b' isn't mistaken for a pipe; in single quotes,
    # backticks and newlines are literal too (e.g. `bun -e '...'` code), in double quotes backticks still substitute
    s = m.group(0)
    return re.sub(r"[|;&`\n]" if s[0] == "'" else r"[|;&\n]", "\x00", s)


# heredoc bodies are data (file contents, script text), not commands: drop them before splitting
cmd = re.sub(r"<<-?\s*(['\"]?)(\w+)\1[^\n]*\n[\s\S]*?\n\s*\2\s*(?=\n|\Z)", "<<HEREDOC", raw, flags=A)
cmd = quoted.sub(mask, cmd)
for seg in re.split(r"&&|\|\||;|\n|\$\(|`", cmd):
    stages = seg.split("|")
    head = stages[0]  # after a pipe, head/tail filter command output: fine
    if grep.search(head) and grep_recursive.search(unquote(head)):
        deny(GREP)
    if find.search(head):
        deny(FIND)
    if any(sed_i.search(unquote(p)) for p in stages):
        deny(SED_I)
    if any(writes_file(p) for p in stages):
        deny(WRITE)
    if tree.search(unquote(head)):
        deny(TREE)
    if git_log.search(unquote(head)) and "|" not in seg and not log_bound.search(unquote(head)):
        deny(GITLOG)
