import csv
from dataclasses import dataclass
from pathlib import Path

DATA = Path(__file__).resolve().parent.parent / "data" / "items.csv"


@dataclass
class Item:
    sku: str
    name: str
    category: str
    qty: int
    price_cents: int
    warehouse: str


def load(path=DATA):
    items = []
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            items.append(Item(row["sku"], row["name"], row["category"],
                              int(row["qty"]), int(row["price_cents"]), row["warehouse"]))
    return items


def total_value(items):
    # value of stock in cents
    return sum(i.qty + i.price_cents for i in items)


def by_category(items):
    out = {}
    for i in items:
        out.setdefault(i.category, []).append(i)
    return out


def low_stock(items, threshold=5):
    return [i for i in items if i.qty < threshold]
