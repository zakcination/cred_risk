#!/usr/bin/env python3
"""Проверка покрытия провизиями: база против стресса.

Для каждого листа из --sheets читаются два блока строк: базовый и стрессовый.
Столбцы показателей ищутся в строке заголовка блока по точным именам
(METRICS). Строки базы и стресса сопоставляются по ключу год + квартал +
segment, а не по смещению строк.

Группы (сравнение точное, без допуска и округления):
  1   база > стресс
  2а  база = стресс, не ноль
  2б  0 = 0
  2в  пусто в обоих
  3   число только в одном из двух
  4   база < стресс
  Н   хотя бы в одной ячейке текст или ошибка (не число)

Пустая ячейка: None или пустая строка "". Строка из пробелов считается текстом.
Логическое значение (ИСТИНА/ЛОЖЬ) числом не считается.

Ошибки (скрипт завершается с кодом 2 и ничего не пишет):
  - лист не найден; показатель не найден в строке заголовка;
  - столбец ключа не найден ни по имени, ни по параметру;
  - неполный ключ при непустых показателях; дубль ключа внутри блока;
  - ключ без пары в другом блоке.

Вывод: --out (.xlsx) с листами «счётчики» и «строки». В stdout только
счётчики и номера столбцов, без значений ячеек. Входной файл только читается.

Зависимости: openpyxl (.xlsx), pyxlsb (.xlsb).
"""

import argparse
import os
import sys
from collections import OrderedDict

METRICS = ("coverage_ratio_s1_end", "coverage_ratio_s2_end", "coverage_ratio_s3_end")
KEY_NAMES = OrderedDict([("year", "year"), ("quarter", "quarter"), ("segment", "segment")])
GROUPS = ("1", "2а", "2б", "2в", "3", "4", "Н")
ROW_GROUPS = ("1", "2а", "2б", "2в", "3", "Н")


class CheckError(Exception):
    """Ошибка структуры входа; сообщение содержит только адреса и имена."""


# ---------------------------------------------------------------- адреса

def col_letter(col):
    """1 -> A, 27 -> AA."""
    s = ""
    while col > 0:
        col, r = divmod(col - 1, 26)
        s = chr(65 + r) + s
    return s


def col_index(spec):
    """'C' -> 3, '3' -> 3. Номер столбца с 1."""
    spec = str(spec).strip()
    if spec.isdigit():
        n = int(spec)
        if n < 1:
            raise CheckError("номер столбца должен быть >= 1: %s" % spec)
        return n
    if not spec.isalpha():
        raise CheckError("столбец задаётся буквой или номером: %s" % spec)
    n = 0
    for ch in spec.upper():
        n = n * 26 + (ord(ch) - 64)
    return n


def addr(sheet, row, col):
    return "%s!%s%d" % (sheet, col_letter(col), row)


# ---------------------------------------------------------------- чтение

def read_rows_xlsx(path, sheet, wanted):
    """{номер строки: {номер столбца: значение}} для строк из wanted."""
    import openpyxl
    wb = openpyxl.load_workbook(path, read_only=True, data_only=True)
    try:
        if sheet not in wb.sheetnames:
            raise CheckError("лист не найден: %s" % sheet)
        ws = wb[sheet]
        out = {}
        lo, hi = min(wanted), max(wanted)
        for r_idx, row in enumerate(ws.iter_rows(min_row=lo, max_row=hi, values_only=True), lo):
            if r_idx in wanted:
                out[r_idx] = {c: v for c, v in enumerate(row, 1) if v is not None}
        return out
    finally:
        wb.close()


def read_rows_xlsb(path, sheet, wanted):
    from pyxlsb import open_workbook
    out = {}
    hi = max(wanted)
    with open_workbook(path) as wb:
        if sheet not in wb.sheets:
            raise CheckError("лист не найден: %s" % sheet)
        with wb.get_sheet(sheet) as ws:
            for row in ws.rows(sparse=True):
                if not row:
                    continue
                r_idx = row[0].r + 1
                if r_idx > hi:
                    break
                if r_idx in wanted:
                    out[r_idx] = {c.c + 1: c.v for c in row if c.v is not None}
    return out


def read_sheet(path, sheet, wanted):
    ext = os.path.splitext(path)[1].lower()
    if ext == ".xlsb":
        return read_rows_xlsb(path, sheet, wanted)
    if ext in (".xlsx", ".xlsm"):
        return read_rows_xlsx(path, sheet, wanted)
    raise CheckError("неподдерживаемый формат: %s" % ext)


# ---------------------------------------------------------------- логика

def kind(v):
    """'num' | 'empty' | 'text'. Ошибка Excel приходит строкой и попадает в 'text'."""
    if v is None or (isinstance(v, str) and v == ""):
        return "empty"
    if isinstance(v, bool):
        return "text"
    if isinstance(v, (int, float)):
        return "num"
    return "text"


def classify(base, stress):
    kb, ks = kind(base), kind(stress)
    if kb == "text" or ks == "text":
        return "Н"
    if kb == "empty" and ks == "empty":
        return "2в"
    if kb == "empty" or ks == "empty":
        return "3"
    if base > stress:
        return "1"
    if base < stress:
        return "4"
    return "2б" if base == 0 else "2а"


def norm_key_part(v):
    """2026.0 -> 2026; строки без крайних пробелов; пусто -> None."""
    if v is None:
        return None
    if isinstance(v, bool):
        return v
    if isinstance(v, float) and v.is_integer():
        return int(v)
    if isinstance(v, str):
        s = v.strip()
        return s if s else None
    return v


def find_columns(header, sheet, header_row, key_override):
    """Ищет столбцы показателей и ключа в строке заголовка.

    header: {столбец: значение}. key_override: {'year': 'C' | None, ...}.
    Возвращает (metrics {имя: столбец}, keys {часть: столбец}, notes).
    """
    by_name = {}
    for c, v in header.items():
        if isinstance(v, str):
            by_name.setdefault(v.strip(), []).append(c)

    errors, notes = [], []
    metrics = {}
    for m in METRICS:
        cols = by_name.get(m, [])
        if not cols:
            errors.append("показатель %s не найден в строке заголовка %s!%d"
                          % (m, sheet, header_row))
        elif len(cols) > 1:
            errors.append("показатель %s встречается %d раз в заголовке: %s"
                          % (m, len(cols), ", ".join(addr(sheet, header_row, c) for c in cols)))
        else:
            metrics[m] = cols[0]

    keys = {}
    for part, name in KEY_NAMES.items():
        cols = by_name.get(name, [])
        if len(cols) == 1:
            keys[part] = cols[0]
            notes.append("%s: столбец %s по имени" % (part, col_letter(cols[0])))
        elif len(cols) > 1:
            errors.append("столбец %s встречается %d раз в заголовке: %s"
                          % (name, len(cols), ", ".join(addr(sheet, header_row, c) for c in cols)))
        elif key_override.get(part):
            keys[part] = col_index(key_override[part])
            notes.append("%s: столбец %s по параметру" % (part, col_letter(keys[part])))
        else:
            errors.append("столбец %s не найден в строке заголовка %s!%d и не задан параметром --%s-col"
                          % (name, sheet, header_row, part))
    return metrics, keys, notes, errors


def collect_block(rows, sheet, first, last, metrics, keys):
    """{ключ: (номер строки, {показатель: значение})} и список ошибок."""
    out, errors = OrderedDict(), []
    for r in range(first, last + 1):
        cells = rows.get(r, {})
        key = tuple(norm_key_part(cells.get(keys[p])) for p in KEY_NAMES)
        vals = {m: cells.get(c) for m, c in metrics.items()}
        if all(k is None for k in key):
            if all(kind(v) == "empty" for v in vals.values()):
                continue                       # пустая строка внутри диапазона
            errors.append("ключ пуст при непустых показателях: строка %s!%d" % (sheet, r))
            continue
        if any(k is None for k in key):
            miss = [p for p, k in zip(KEY_NAMES, key) if k is None]
            errors.append("неполный ключ (нет %s): %s"
                          % (", ".join(miss), ", ".join(addr(sheet, r, keys[p]) for p in miss)))
            continue
        if key in out:
            errors.append("дубль ключа: строки %s!%d и %s!%d" % (sheet, out[key][0], sheet, r))
            continue
        out[key] = (r, vals)
    return out, errors


def check_sheet(rows, sheet, layout, key_override):
    """Проверка одного листа по уже прочитанным строкам.

    rows: {номер строки: {номер столбца: значение}}.
    layout: dict с header_base, header_stress, first_base, last_base, first_stress, last_stress.
    Возвращает (counts {(показатель, группа): n}, details [dict], notes, errors).
    """
    L = layout
    mb, kb, nb, eb = find_columns(rows.get(L["header_base"], {}), sheet, L["header_base"], key_override)
    ms, ks, ns, es = find_columns(rows.get(L["header_stress"], {}), sheet, L["header_stress"], key_override)
    notes = ["база: " + n for n in nb] + ["стресс: " + n for n in ns]
    errors = eb + es
    if errors:
        return None, None, notes, errors

    base, e1 = collect_block(rows, sheet, L["first_base"], L["last_base"], mb, kb)
    stress, e2 = collect_block(rows, sheet, L["first_stress"], L["last_stress"], ms, ks)
    errors = e1 + e2
    for k, (r, _) in base.items():
        if k not in stress:
            errors.append("ключ без пары в стрессе: строка %s!%d" % (sheet, r))
    for k, (r, _) in stress.items():
        if k not in base:
            errors.append("ключ без пары в базе: строка %s!%d" % (sheet, r))
    if errors:
        return None, None, notes, errors

    counts = OrderedDict(((m, g), 0) for m in METRICS for g in GROUPS)
    details = []
    for key, (rb, vb) in base.items():
        rs, vs = stress[key]
        for m in METRICS:
            b, s = vb[m], vs[m]
            g = classify(b, s)
            counts[(m, g)] += 1
            if g in ROW_GROUPS:
                diff = b - s if kind(b) == "num" and kind(s) == "num" else None
                details.append(OrderedDict([
                    ("показатель", m), ("группа", g), ("segment", key[2]), ("лист", sheet),
                    ("год", key[0]), ("квартал", key[1]),
                    ("база", b), ("стресс", s), ("разница", diff),
                    ("адрес_база", addr(sheet, rb, mb[m])),
                    ("адрес_стресс", addr(sheet, rs, ms[m])),
                ]))
    return counts, details, notes, []


def layout_rows(layout):
    L = layout
    return ({L["header_base"], L["header_stress"]}
            | set(range(L["first_base"], L["last_base"] + 1))
            | set(range(L["first_stress"], L["last_stress"] + 1)))


def validate_layout(L):
    errs = []
    if not L["header_base"] < L["first_base"] <= L["last_base"]:
        errs.append("база: нужно header-base < first-base <= last-base")
    if not L["header_stress"] < L["first_stress"] <= L["last_stress"]:
        errs.append("стресс: нужно header-stress < first-stress <= last-stress")
    b = set(range(L["first_base"], L["last_base"] + 1))
    s = set(range(L["first_stress"], L["last_stress"] + 1))
    if b & s:
        errs.append("диапазоны базы и стресса пересекаются")
    return errs


# ---------------------------------------------------------------- вывод

def write_out(path, all_counts, all_details):
    import openpyxl
    wb = openpyxl.Workbook()
    ws = wb.active
    ws.title = "счётчики"
    ws.append(["лист", "показатель", "группа", "n"])
    for sheet, counts in all_counts.items():
        for (m, g), n in counts.items():
            ws.append([sheet, m, g, n])
    wd = wb.create_sheet("строки")
    cols = ["показатель", "группа", "segment", "лист", "год", "квартал",
            "база", "стресс", "разница", "адрес_база", "адрес_стресс"]
    wd.append(cols)
    for d in all_details:
        wd.append([d[c] for c in cols])
    wb.save(path)


def print_counts(all_counts, stream):
    head = "%-20s %-24s " % ("лист", "показатель") + " ".join("%6s" % g for g in GROUPS)
    print(head, file=stream)
    for sheet, counts in all_counts.items():
        for m in METRICS:
            print("%-20s %-24s " % (sheet[:20], m)
                  + " ".join("%6d" % counts[(m, g)] for g in GROUPS), file=stream)


# ---------------------------------------------------------------- запуск

def parse_args(argv):
    p = argparse.ArgumentParser(description="Покрытие провизиями: база против стресса по ключу год+квартал+segment.")
    p.add_argument("--file", required=True, help=".xlsb или .xlsx")
    p.add_argument("--sheets", required=True, nargs="+", help="листы для проверки")
    p.add_argument("--out", required=True, help="путь результата .xlsx")
    p.add_argument("--header-base", type=int, default=45)
    p.add_argument("--header-stress", type=int, default=249)
    p.add_argument("--first-base", type=int, default=46)
    p.add_argument("--last-base", type=int, default=237)
    p.add_argument("--first-stress", type=int, default=250)
    p.add_argument("--last-stress", type=int, default=441)
    p.add_argument("--segment-col", help="буква или номер, если имени segment нет в заголовке")
    p.add_argument("--year-col", help="буква или номер, если имени year нет в заголовке")
    p.add_argument("--quarter-col", help="буква или номер, если имени quarter нет в заголовке")
    return p.parse_args(argv)


def main(argv=None):
    a = parse_args(argv)
    layout = {k: getattr(a, k) for k in
              ("header_base", "header_stress", "first_base", "last_base", "first_stress", "last_stress")}
    override = {"segment": a.segment_col, "year": a.year_col, "quarter": a.quarter_col}

    errors = validate_layout(layout)
    if not os.path.isfile(a.file):
        errors.append("входной файл не найден")
    if os.path.splitext(a.out)[1].lower() != ".xlsx":
        errors.append("--out должен иметь расширение .xlsx")
    if os.path.exists(a.out) and os.path.isfile(a.file) and os.path.samefile(a.out, a.file):
        errors.append("--out совпадает с входным файлом")
    if errors:
        for e in errors:
            print("ОШИБКА: " + e, file=sys.stderr)
        return 2

    wanted = layout_rows(layout)
    all_counts, all_details = OrderedDict(), []
    for sheet in a.sheets:
        try:
            rows = read_sheet(a.file, sheet, wanted)
            counts, details, notes, errs = check_sheet(rows, sheet, layout, override)
        except CheckError as e:
            notes, errs = [], [str(e)]
        for n in notes:
            print("%s | %s" % (sheet, n))
        if errs:
            errors.extend(errs)
            continue
        all_counts[sheet] = counts
        all_details.extend(details)

    if errors:
        for e in errors:
            print("ОШИБКА: " + e, file=sys.stderr)
        print("Ошибок: %d. Результат не записан." % len(errors), file=sys.stderr)
        return 2

    write_out(a.out, all_counts, all_details)
    print_counts(all_counts, sys.stdout)
    print("строк на листе «строки»: %d" % len(all_details))
    return 0


if __name__ == "__main__":
    sys.exit(main())
