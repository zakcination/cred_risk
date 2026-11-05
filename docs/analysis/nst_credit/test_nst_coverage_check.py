"""Тесты nst_coverage_check на синтетических таблицах. Значения выдуманы.

Запуск: python -m unittest test_nst_coverage_check  (из папки скрипта)
"""

import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import nst_coverage_check as ncc  # noqa: E402

M1, M2, M3 = ncc.METRICS
LAYOUT = dict(header_base=1, first_base=2, last_base=12,
              header_stress=20, first_stress=21, last_stress=31)
NO_OVERRIDE = {"segment": None, "year": None, "quarter": None}

# Заголовок: A year, B quarter, C segment, D-F показатели.
HEADER = {1: "year", 2: "quarter", 3: "segment", 4: M1, 5: M2, 6: M3}

# (segment, база s1, стресс s1, ожидаемая группа по s1)
CASES = [
    ("seg_g1", 0.30, 0.20, "1"),
    ("seg_g2a", 0.25, 0.25, "2а"),
    ("seg_g2b", 0, 0.0, "2б"),
    ("seg_g2v", None, None, "2в"),
    ("seg_g3a", 0.10, None, "3"),
    ("seg_g3b", "", 0.10, "3"),
    ("seg_g4", 0.10, 0.40, "4"),
    ("seg_txt", "#DIV/0!", 0.10, "Н"),
    ("seg_bool", True, 0.10, "Н"),
]


def build(cases=CASES, base_extra=None, stress_extra=None):
    """Таблица {строка: {столбец: значение}}. Стресс записан в обратном порядке
    строк, чтобы проверить сопоставление по ключу, а не по смещению."""
    rows = {LAYOUT["header_base"]: dict(HEADER), LAYOUT["header_stress"]: dict(HEADER)}
    for i, (seg, b, _, _) in enumerate(cases):
        rows[LAYOUT["first_base"] + i] = {1: 2026.0, 2: "Q1", 3: seg, 4: b, 5: 1.0, 6: 1.0}
    for i, (seg, _, s, _) in enumerate(reversed(cases)):
        rows[LAYOUT["first_stress"] + i] = {1: 2026, 2: " Q1 ", 3: seg, 4: s, 5: 1.0, 6: 2.0}
    for r, cells in (base_extra or {}).items():
        rows[r] = cells
    for r, cells in (stress_extra or {}).items():
        rows[r] = cells
    return rows


class TestClassify(unittest.TestCase):
    def test_groups(self):
        for seg, b, s, g in CASES:
            with self.subTest(seg=seg):
                self.assertEqual(ncc.classify(b, s), g)

    def test_exact_no_tolerance(self):
        self.assertEqual(ncc.classify(0.1 + 0.2, 0.3), "1")   # 0.30000000000000004 > 0.3
        self.assertEqual(ncc.classify(-0.0, 0), "2б")

    def test_text_beats_empty(self):
        self.assertEqual(ncc.classify("abc", None), "Н")
        self.assertEqual(ncc.classify(" ", None), "Н")


class TestCheckSheet(unittest.TestCase):
    def run_check(self, rows, layout=LAYOUT, override=NO_OVERRIDE):
        return ncc.check_sheet(rows, "S", layout, override)

    def test_every_group(self):
        counts, details, notes, errors = self.run_check(build())
        self.assertEqual(errors, [])
        expected = {g: 0 for g in ncc.GROUPS}
        for _, _, _, g in CASES:
            expected[g] += 1
        for g in ncc.GROUPS:
            self.assertEqual(counts[(M1, g)], expected[g], g)
        # M2: всюду 1.0 = 1.0; M3: база 1 < стресс 2.
        self.assertEqual(counts[(M2, "2а")], len(CASES))
        self.assertEqual(counts[(M3, "4")], len(CASES))
        # Группа 4 в лист строк не выводится, остальные — да.
        self.assertTrue(all(d["группа"] != "4" for d in details))
        self.assertEqual(len(details), len(CASES) * 2 - expected["4"])

    def test_detail_addresses_follow_key(self):
        _, details, _, _ = self.run_check(build())
        d = next(x for x in details if x["показатель"] == M1 and x["segment"] == "seg_g1")
        self.assertEqual(d["адрес_база"], "S!D2")
        # seg_g1 первый в базе, последний в стрессе.
        self.assertEqual(d["адрес_стресс"], "S!D%d" % (LAYOUT["first_stress"] + len(CASES) - 1))
        self.assertEqual(d["год"], 2026)
        self.assertEqual(d["квартал"], "Q1")
        self.assertAlmostEqual(d["разница"], 0.10)

    def test_unpaired_key(self):
        rows = build(base_extra={12: {1: 2026, 2: "Q2", 3: "lonely", 4: 0.1, 5: 0.1, 6: 0.1}})
        counts, _, _, errors = self.run_check(rows)
        self.assertIsNone(counts)
        self.assertEqual(errors, ["ключ без пары в стрессе: строка S!12"])

    def test_duplicate_key(self):
        rows = build(stress_extra={31: {1: 2026, 2: "Q1", 3: "seg_g1", 4: 0.1, 5: 0.1, 6: 0.1}})
        _, _, _, errors = self.run_check(rows)
        self.assertEqual(len(errors), 1)
        self.assertTrue(errors[0].startswith("дубль ключа: строки S!21 и S!31")
                        or "S!31" in errors[0], errors)

    def test_partial_key(self):
        rows = build(base_extra={12: {1: 2026, 3: "x", 4: 0.1}})
        _, _, _, errors = self.run_check(rows)
        self.assertEqual(errors, ["неполный ключ (нет quarter): S!B12"])

    def test_empty_key_with_values(self):
        rows = build(base_extra={12: {4: 0.1}})
        _, _, _, errors = self.run_check(rows)
        self.assertEqual(errors, ["ключ пуст при непустых показателях: строка S!12"])

    def test_missing_metric_is_error(self):
        rows = build()
        rows[LAYOUT["header_stress"]] = {k: v for k, v in HEADER.items() if v != M3}
        counts, _, _, errors = self.run_check(rows)
        self.assertIsNone(counts)
        self.assertEqual(errors, ["показатель %s не найден в строке заголовка S!20" % M3])

    def test_key_column_override(self):
        rows = build()
        for r in (LAYOUT["header_base"], LAYOUT["header_stress"]):
            rows[r] = {k: v for k, v in HEADER.items() if v != "segment"}
        _, _, _, errors = self.run_check(rows)
        self.assertEqual(len(errors), 2)            # не найден ни по имени, ни по параметру
        counts, _, notes, errors = self.run_check(rows, override=dict(NO_OVERRIDE, segment="C"))
        self.assertEqual(errors, [])
        self.assertIn("база: segment: столбец C по параметру", notes)

    def test_layout_validation(self):
        bad = dict(LAYOUT, first_stress=10)
        self.assertTrue(ncc.validate_layout(bad))
        self.assertEqual(ncc.validate_layout(LAYOUT), [])


class TestColumns(unittest.TestCase):
    def test_letters(self):
        for n, s in ((1, "A"), (26, "Z"), (27, "AA"), (52, "AZ"), (703, "AAA")):
            self.assertEqual(ncc.col_letter(n), s)
            self.assertEqual(ncc.col_index(s), n)
        self.assertEqual(ncc.col_index("12"), 12)


class TestEndToEndXlsx(unittest.TestCase):
    """Синтетический .xlsx во временной папке: чтение, запуск, вывод."""

    def test_main(self):
        import openpyxl
        with tempfile.TemporaryDirectory() as tmp:
            src = os.path.join(tmp, "in.xlsx")
            wb = openpyxl.Workbook()
            ws = wb.active
            ws.title = "S"
            for r, cells in build().items():
                for c, v in cells.items():
                    if v is not None:
                        ws.cell(row=r, column=c, value=v)
            wb.save(src)
            before = sorted(os.listdir(tmp))
            out = os.path.join(tmp, "out.xlsx")
            args = ["--file", src, "--sheets", "S", "--out", out,
                    "--header-base", "1", "--first-base", "2", "--last-base", "12",
                    "--header-stress", "20", "--first-stress", "21", "--last-stress", "31"]
            self.assertEqual(ncc.main(args), 0)
            self.assertEqual(sorted(os.listdir(tmp)), sorted(before + ["out.xlsx"]))
            res = openpyxl.load_workbook(out, read_only=True)
            got = {(r[1], r[2]): r[3] for r in res["счётчики"].iter_rows(min_row=2, values_only=True)}
            res.close()
            self.assertEqual(got[(M1, "1")], 1)
            self.assertEqual(got[(M1, "3")], 2)
            self.assertEqual(got[(M1, "Н")], 2)

            # Ошибка структуры: код 2, результат не пишется.
            out2 = os.path.join(tmp, "out2.xlsx")
            bad = ["--file", src, "--sheets", "S", "нет_листа", "--out", out2] + args[6:]
            self.assertEqual(ncc.main(bad), 2)
            self.assertFalse(os.path.exists(out2))


if __name__ == "__main__":
    unittest.main()
