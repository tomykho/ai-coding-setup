#!/usr/bin/env python3
"""Write omniroute/output-styles.json into OmniRoute's compression/outputStyles setting.

Output styles shape the model's replies (not the request), so they do not hurt the prompt cache.
Only outputStyles is touched: compression engines are left as they are (this repo recommends them off).
Idempotent. Usage: set-output-styles.py <styles.json> [db path]
"""
import json
import os
import sqlite3
import sys

styles_file = sys.argv[1]
db = sys.argv[2] if len(sys.argv) > 2 else os.path.expanduser("~/.omniroute/storage.sqlite")

if not os.path.exists(db):
    sys.exit(f"{db} not found: start OmniRoute once, then re-run")

value = json.dumps(json.load(open(styles_file, encoding="utf-8")))
con = sqlite3.connect(db, timeout=10)
row = con.execute("select value from key_value where namespace='compression' and key='outputStyles'").fetchone()

if row and json.loads(row[0]) == json.loads(value):
    print("outputStyles already up to date")
else:
    if row:
        con.execute("update key_value set value=? where namespace='compression' and key='outputStyles'", (value,))
    else:
        con.execute("insert into key_value (namespace, key, value) values ('compression','outputStyles',?)", (value,))
    con.commit()
    print("outputStyles updated: restart OmniRoute to apply")
