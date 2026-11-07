"""Print the first 100 inventory rows, one per line (a long command output for the bench)."""
import csv
from pathlib import Path

DATA = Path(__file__).resolve().parent.parent / "data" / "items.csv"
with open(DATA, newline="") as f:
    for n, r in enumerate(csv.DictReader(f), 1):
        if n > 100:
            break
        print(f"row {n:03d} {r['sku']},{r['name'].replace(' ', '_')},{r['category']},qty={r['qty']},price_cents={r['price_cents']},{r['warehouse']}")
