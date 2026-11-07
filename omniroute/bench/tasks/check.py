import sys, csv, subprocess, importlib
task, repo = sys.argv[1], sys.argv[2]
sys.path.insert(0, repo)
r = subprocess.run([sys.executable, "-m", "unittest", "-q"], cwd=repo, capture_output=True, text=True)
ok = r.returncode == 0
c = importlib.import_module("inventory.core")
rows = list(csv.DictReader(open(f"{repo}/data/items.csv")))
items = c.load()
ok &= c.total_value(items) == sum(int(r["qty"]) * int(r["price_cents"]) for r in rows)
ok &= len(c.low_stock(items)) == sum(int(r["qty"]) <= 5 for r in rows)
if task == "medium":
    try:
        rep = c.warehouse_report(items)
        for w in {r["warehouse"] for r in rows}:
            sub = [r for r in rows if r["warehouse"] == w]
            e = {"count": len(sub), "value_cents": sum(int(r["qty"]) * int(r["price_cents"]) for r in sub),
                 "low_stock_skus": sorted(r["sku"] for r in sub if int(r["qty"]) <= 5)}
            ok &= rep[w] == e
        cats = {}
        for r in rows:
            cats[r["category"]] = cats.get(r["category"], 0) + int(r["qty"]) * int(r["price_cents"])
        exp = [f"{k},{v}" for k, v in sorted(cats.items(), key=lambda x: -x[1])[:5]]
        got = [l.strip() for l in open(f"{repo}/report.txt") if l.strip()]
        ok &= got == exp
    except Exception as e:
        print("check error:", e); ok = False
if task == "feature":
    import io, os, tempfile
    def exp(cat=None, wh=None, mq=None):
        sel = [r for r in rows if (cat is None or r["category"] == cat) and (wh is None or r["warehouse"] == wh)
               and (mq is None or int(r["qty"]) >= mq)]
        sel.sort(key=lambda r: (-int(r["qty"]) * int(r["price_cents"]), r["sku"]))
        return ["sku,name,category,qty,price_cents,value_cents"] + [
            f'{r["sku"]},{r["name"]},{r["category"]},{r["qty"]},{r["price_cents"]},{int(r["qty"]) * int(r["price_cents"])}' for r in sel]
    def run(*a):
        p = subprocess.run([sys.executable, "-m", "inventory", "report", *a], cwd=repo, capture_output=True, text=True, timeout=60)
        return [l.rstrip("\r") for l in p.stdout.splitlines() if l.strip()]
    try:
        for args, e in [((), exp()), (("--category", "tools"), exp("tools")), (("--warehouse", "west", "--min-qty", "10"), exp(wh="west", mq=10)),
                        (("--category", "toys", "--warehouse", "north", "--min-qty", "3"), exp("toys", "north", 3)), (("--category", "nope"), exp("nope"))]:
            g = run(*args); ok &= g == e
            if g != e: print("mismatch", args, g[:2], e[:2])
        out = os.path.join(tempfile.mkdtemp(), "r.csv"); run("--category", "bath", "--out", out)
        ok &= [l.rstrip("\r") for l in open(out).read().splitlines() if l.strip()] == exp("bath")
        n = subprocess.run([sys.executable, "-m", "unittest", "-v"], cwd=repo, capture_output=True, text=True).stderr.count(" ... ok")
        ok &= n > 4  # model added tests
    except Exception as e:
        print("check error:", e); ok = False
if task == "longout":
    # rows 35/50/65/80 of the 100-line dump sit in the middle of the output: a truncating compressor loses them
    want = [f"{n}:{rows[n - 1]['qty']}" for n in (35, 50, 65, 80)]
    try:
        got = [l.strip() for l in open(f"{repo}/answer.txt") if l.strip()]
    except OSError:
        got = []
    ok = got == want
    if not ok:
        print("answer mismatch", got, want)
print("PASS" if ok else "FAIL"); sys.exit(0 if ok else 1)
