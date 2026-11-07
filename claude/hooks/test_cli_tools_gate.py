#!/usr/bin/env python3
# Table-driven test for cli-tools-gate.py:  python3 claude/hooks/test_cli_tools_gate.py
# GATE="bun /path/old-gate.ts" python3 test_cli_tools_gate.py  runs another implementation against the same table.
import json
import os
import shlex
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
GATE = shlex.split(os.environ.get("GATE", "")) or [sys.executable, os.path.join(HERE, "cli-tools-gate.py")]

# (command, expected rule logged, or None = allowed)
CASES = [
    ("grep -r foo .", "grep"), ("grep -rn foo src", "grep"), ("egrep -R foo .", "grep"), ("grep --recursive foo .", "grep"),
    ("sudo grep -r foo /etc", "grep"), ("FOO=1 grep -ri foo .", "grep"),
    ("grep foo file.txt", None), ("cat f | grep -r foo", None), ("rg foo", None),
    ("find . -name '*.py'", "find"), ("find . -maxdepth 2 -name x", None), ("fd -e py", None),
    ("sed -i 's/a/b/' f", "sed-i"), ("sed -i.bak s/a/b/ f", "sed-i"), ("perl -pi -e 's/a/b/' f", "sed-i"),
    ("rg -l x | xargs sed -i s/a/b/", "sed-i"), ("sed -n 1,5p f", None), ("cat f | sed 's/-i/x/'", None),
    ("echo hi > out.txt", "write"), ("echo hi >> out.txt", "write"), ("cat f | tee out.txt", "write"), ("cat > f <<EOF\nx\nEOF", "write"),
    ("echo hi > /tmp/x", None), ("echo hi > /dev/null", None), ("ls 2>&1", None), ("echo hi > $TMPDIR/x", None),
    ("echo 'a > b'", None), ('echo "a > b"', None), ('echo hi > "/tmp/x"', None), ("cmd >/dev/null 2>&1", None),
    ("cat f | tee -a /tmp/x", None), ("cat f | tee f >/dev/null", "write"),
    ("tree", "tree"), ("tree -L 2", None), ("ls -R", "tree"), ("ls -laR dir", "tree"), ("ls -la", None),
    ("git log", "git-log"), ("git -C x log", "git-log"), ("git log --oneline -n 20", None), ("git log -5", None),
    ("git log --since=2.weeks", None), ("git log a..b", None), ("git log | head", None), ("git log -- path", None),
    ("git status", None), ("git diff", None),
    ("curl https://github.com/x/y", "gh"), ("curl -s https://api.github.com/repos/o/r", "gh"),
    ("wget raw.githubusercontent.com/o/r/main/f", "gh"), ("curl https://example.com", None), ("gh api repos/o/r", None),
    ("python3 -m json.tool f", "json-py"), ("python -c 'import json; print(1)'", "json-py"),
    ("python3 - <<EOF\nimport json\nEOF", "json-py"), ("python3 script.py", None), ("python3 -c 'print(1)'", None),
    ("echo a && grep -r x .", "grep"), ("true; find .", "find"), ("echo $(grep -r x .)", "grep"),
    ("echo 'a|b;c' | cat", None), ("cat <<EOF\ngrep -r x\nEOF", None),
    ("", None),
]


def run(tool, tool_input, log):
    p = subprocess.run(GATE, input=json.dumps({"tool_name": tool, "tool_input": tool_input, "cwd": "/x"}), text=True,
                       capture_output=True, env={**os.environ, "CLI_TOOLS_GATE_LOG": log})
    out = p.stdout.strip()
    denied = bool(out) and json.loads(out)["hookSpecificOutput"]["permissionDecision"] == "deny"
    rule = None
    if os.path.exists(log) and os.path.getsize(log):
        with open(log) as f:
            rule = f.read().splitlines()[-1].split("\t")[1]
        os.remove(log)
    return p.returncode, denied, rule


fails = 0
with tempfile.TemporaryDirectory() as d:
    log = os.path.join(d, "gate.log")
    for cmd, want in CASES:
        rc, denied, rule = run("Bash", {"command": cmd}, log)
        if rc != 0 or denied != (want is not None) or rule != want:
            fails += 1
            print(f"FAIL {cmd!r}: want {want}, got rc={rc} denied={denied} rule={rule}")
    rc, denied, _ = run("Read", {"file_path": "/etc/passwd"}, log)
    if rc != 0 or denied:
        fails += 1
        print("FAIL Read must be allowed")
    p = subprocess.run(GATE, input="not json", text=True, capture_output=True)
    if p.returncode != 0 or p.stdout:
        fails += 1
        print("FAIL bad stdin must fail open")
print(f"{len(CASES) + 2 - fails}/{len(CASES) + 2} passed")
sys.exit(1 if fails else 0)
