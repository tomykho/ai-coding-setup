#!/usr/bin/env python3
"""Write omniroute/cli-tools-prompt.md into OmniRoute's global system prompt (suffix).

OmniRoute injects it into every request it proxies (Claude Code, VS Code Copilot, ...),
so no per-client CLAUDE.md / AGENTS.md / copilot-instructions is needed.
Idempotent. Usage: set-system-prompt.py <prompt.md> [db path]
"""
import json
import os
import sqlite3
import sys

prompt_file = sys.argv[1]
db = sys.argv[2] if len(sys.argv) > 2 else os.path.expanduser("~/.omniroute/storage.sqlite")

if not os.path.exists(db):
    sys.exit(f"{db} not found: start OmniRoute once, then re-run")

text = open(prompt_file, encoding="utf-8").read().strip()
con = sqlite3.connect(db, timeout=10)
row = con.execute("select value from key_value where namespace='settings' and key='systemPrompt'").fetchone()
cfg = json.loads(row[0]) if row else {}
new = {**cfg, "enabled": True, "prefixPrompt": "", "suffixPrompt": text}

if cfg == new:
    print("systemPrompt already up to date")
else:
    value = json.dumps(new)
    if row:
        con.execute("update key_value set value=? where namespace='settings' and key='systemPrompt'", (value,))
    else:
        con.execute("insert into key_value (namespace, key, value) values ('settings','systemPrompt',?)", (value,))
    con.commit()
    print("systemPrompt updated: restart OmniRoute to apply")
