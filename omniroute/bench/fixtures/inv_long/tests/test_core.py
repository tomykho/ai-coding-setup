import unittest
from inventory.core import load, total_value, low_stock, by_category, Item


class CoreTests(unittest.TestCase):
    def test_load_count(self):
        self.assertEqual(len(load()), 600)

    def test_total_value_small(self):
        items = [Item("a", "a", "c", 2, 150, "n"), Item("b", "b", "c", 3, 100, "n")]
        self.assertEqual(total_value(items), 600)

    def test_low_stock_inclusive(self):
        items = [Item("a", "a", "c", 5, 1, "n"), Item("b", "b", "c", 6, 1, "n")]
        self.assertEqual([i.sku for i in low_stock(items)], ["a"])

    def test_by_category_keys(self):
        self.assertEqual(set(by_category(load())),
                         {"tools", "garden", "kitchen", "office", "toys", "sports", "auto", "bath"})


if __name__ == "__main__":
    unittest.main()
