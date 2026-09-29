"""Собирает файлы для вставки в Power BI из PBI_model.dax и проверяет модель.

Источник правды — PBI_model.dax. Правится только он, затем:

    python build_paste.py

На выходе:
    PBI_tables.dax    — 5 таблиц: Моделирование → Новая таблица, по одной;
    PBI_measures.dax  — все меры одним блоком DEFINE для «Представления запросов DAX»
                        и два контрольных запроса EVALUATE с известным ответом.

Проверки (любая ошибка — выход с кодом 1, файлы не пишутся):
    1. строки таблицы «Показатель» и ветки меры «Значение» — одни и те же имена, в том же порядке;
    2. каждая мера, на которую ссылаются [Имя] без таблицы, определена;
    3. каждый столбец факта fact_x[col] есть на выходе PBI_fact_x.sql;
    4. имена мер не повторяются, «Порядок» показателей не повторяется.

Только стандартная библиотека. Файлы читаются и пишутся в папке скрипта.
"""
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
MODEL = HERE / "PBI_model.dax"
TABLE_ORDER = ["Меры", "dim_source", "dim_month", "dim_product", "Показатель"]
FACT_SQL = {
    "fact_flow": "PBI_fact_flow.sql",
    "fact_stock": "PBI_fact_stock.sql",
    "fact_borrowers": "PBI_fact_borrowers.sql",
    "fact_default": "PBI_fact_default.sql",
    "fact_stage": "PBI_fact_stage.sql",
    "fact_vintage": "PBI_fact_vintage.sql",
}
MARKER = re.compile(r"^// (ТАБЛИЦА|МЕРА|ДИНАМИЧЕСКАЯ СТРОКА ФОРМАТА)")
SECTION = re.compile(r"^// [─=]")


def parse_model(text):
    """Блоки модели: список (вид, имя, определение). Вид — ТАБЛИЦА, МЕРА или ФОРМАТ."""
    lines = text.splitlines()
    blocks, i = [], 0
    while i < len(lines):
        m = MARKER.match(lines[i])
        if not m:
            i += 1
            continue
        kind = {"ДИНАМИЧЕСКАЯ СТРОКА ФОРМАТА": "ФОРМАТ"}.get(m.group(1), m.group(1))
        i += 1
        while i < len(lines) and (lines[i].startswith("//") or not lines[i].strip()):
            if MARKER.match(lines[i]) or SECTION.match(lines[i]):
                break
            i += 1
        body = []
        while i < len(lines) and not MARKER.match(lines[i]) and not SECTION.match(lines[i]):
            body.append(lines[i])
            i += 1
        while body and (not body[-1].strip() or body[-1].startswith("//")):
            body.pop()
        if not body:
            continue
        if kind == "ФОРМАТ":
            blocks.append((kind, "", "\n".join(body)))
            continue
        head, _, rest = body[0].partition(" =")
        expr = "\n".join([rest.strip()] + body[1:]).strip()
        blocks.append((kind, head.strip(), expr))
    return blocks


def sql_columns(path):
    """Имена столбцов на выходе SQL: последний SELECT верхнего уровня до FROM."""
    sql = re.sub(r"/\*.*?\*/", "", path.read_text(encoding="utf-8"), flags=re.S)
    sql = re.sub(r"--[^\n]*", "", sql)
    starts = [m.start() for m in re.finditer(r"(?im)^SELECT\b", sql)]
    if not starts:
        raise ValueError(f"{path.name}: нет SELECT в начале строки")
    seg = sql[starts[-1] + len("SELECT"):]
    depth, items, cur, j = 0, [], "", 0
    while j < len(seg):
        ch = seg[j]
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        elif (depth == 0 and seg[j:j + 4].upper() == "FROM" and (j == 0 or seg[j - 1].isspace())
              and (j + 4 >= len(seg) or not (seg[j + 4].isalnum() or seg[j + 4] == "_"))):
            break
        if ch == "," and depth == 0:
            items.append(cur)
            cur = ""
        else:
            cur += ch
        j += 1
    items.append(cur)
    cols = []
    for it in items:
        it = it.strip()
        if not it:
            continue
        m = re.search(r"\bAS\s+\[?([\w$]+)\]?\s*$", it, flags=re.I)
        cols.append(m.group(1) if m else re.split(r"[.\s]", it)[-1].strip("[]"))
    return cols


def main():
    errors = []
    blocks = parse_model(MODEL.read_text(encoding="utf-8"))
    tables = {n: e for k, n, e in blocks if k == "ТАБЛИЦА"}
    measures = [(n, e) for k, n, e in blocks if k == "МЕРА"]
    fmt = next((e for k, _, e in blocks if k == "ФОРМАТ"), None)
    mnames = [n for n, _ in measures]

    missing_tables = [t for t in TABLE_ORDER if t not in tables]
    if missing_tables:
        errors.append(f"нет таблиц: {missing_tables}")
    dups = sorted({n for n in mnames if mnames.count(n) > 1})
    if dups:
        errors.append(f"повтор имён мер: {dups}")

    # 1. Показатель ↔ Значение
    ind = re.findall(r'\{\s*"([^"]+)",\s*"([^"]+)",\s*(\d+),\s*"([^"]+)"\s*\}', tables.get("Показатель", ""))
    ind_names = [r[0] for r in ind]
    orders = [int(r[2]) for r in ind]
    if len(set(orders)) != len(orders):
        errors.append("«Порядок» в «Показатель» повторяется")
    switch = dict(measures).get("Значение", "")
    branches = re.findall(r'^\s*"([^"]+)",\s*\[([^\]]+)\]', switch, flags=re.M)
    if [b[0] for b in branches] != ind_names:
        a, b = set(ind_names), {x[0] for x in branches}
        errors.append(f"«Показатель» и «Значение» расходятся: только в таблице {sorted(a - b)}, "
                      f"только в Значение {sorted(b - a)}; порядок совпадает: {a == b}")

    # 2. ссылки на меры
    known = set(mnames)
    for n, e in measures:
        for ref in re.findall(r"(?<![\w'\]])\[([^\]]+)\]", e):
            if ref.startswith("@") or ref in known:
                continue
            errors.append(f"мера «{n}» ссылается на [{ref}] — такой меры нет")

    # 3. столбцы фактов
    for fact, fname in FACT_SQL.items():
        try:
            cols = set(sql_columns(HERE / fname))
        except (OSError, ValueError) as ex:
            errors.append(str(ex))
            continue
        used = set()
        for _, e in measures:
            used |= set(re.findall(rf"\b{fact}\[([^\]]+)\]", e))
        for t in TABLE_ORDER:
            used |= set(re.findall(rf"\b{fact}\[([^\]]+)\]", tables.get(t, "")))
        for col in sorted(used - cols):
            errors.append(f"{fact}[{col}] — нет на выходе {fname}")

    if errors:
        print("ОШИБКИ:")
        for e in errors:
            print("  -", e)
        return 1

    # PBI_tables.dax
    out = ["// PBI_tables.dax — СОБРАНО build_paste.py из PBI_model.dax. Руками не править.",
           "// Каждый блок: Моделирование → Новая таблица → заменить «Таблица = » блоком → Enter.",
           "// Порядок важен: dim_month читает fact_flow и fact_stock — сначала загрузить факты.", ""]
    for i, t in enumerate(TABLE_ORDER, 1):
        out += [f"// ═══ {i}. {t}", f"{t} =", tables[t], ""]
    (HERE / "PBI_tables.dax").write_text("\n".join(out), encoding="utf-8")

    # PBI_measures.dax
    out = ["// PBI_measures.dax — СОБРАНО build_paste.py из PBI_model.dax. Руками не править.",
           f"// {len(measures)} мер. Представление запросов DAX → новый запрос → вставить файл целиком →",
           "// «Выполнить» (F5): внизу две таблицы — сверить с ожидаемым в комментариях EVALUATE.",
           "// Сошлось → надпись над DEFINE «Обновить модель: добавить новые меры» → меры появятся в «Меры».",
           "// Затем мера «Значение» → Средства меры → Формат → Динамический → выражение:",
           f"//     {fmt.strip() if fmt else ''}",
           "", "DEFINE"]
    for n, e in measures:
        body = "\n".join("        " + ln if ln.strip() else ln for ln in e.splitlines())
        out += [f"    MEASURE 'Меры'[{n}] =", body, ""]
    out += [
        "// Контроль 1 — месяц 2026-08 (прогоны 24–28.09.2026). Ожидается:",
        "//   остаток 1 521,6 | покрытие 0,074 | уровень просрочки 0,093 | объём выдач 50,5 | выдач 2 006",
        "//   карт выдано 228 | новых дефолтов 1 473 | в дефолте 64,4 | Stage 3 + 4 155,6 | доля 0,102",
        "EVALUATE",
        "CALCULATETABLE (",
        "    ROW (",
        '        "Общий остаток, млрд ₸",            [Общий остаток, млрд ₸],',
        '        "Покрытие провизиями",              [Покрытие провизиями],',
        '        "Управленческий уровень просрочки", [Управленческий уровень просрочки],',
        '        "Объём выдач, млрд ₸",              [Объём выдач, млрд ₸],',
        '        "Количество выдач",                 [Количество выдач],',
        '        "Карты: выдано",                    [Карты: выдано],',
        '        "Новые дефолты, шт",                [Новые дефолты, шт],',
        '        "В дефолте, млрд ₸",                [В дефолте, млрд ₸],',
        '        "Stage 3 + 4, млрд ₸",              [Stage 3 + 4, млрд ₸],',
        '        "Доля Stage 3 + 4",                 [Доля Stage 3 + 4]',
        "    ),",
        "    TREATAS ( { DATE ( 2026, 8, 1 ) }, dim_month[Date] )",
        ")",
        "",
        "// Контроль 2 — стадии, месяц 2026-07 (точно, повтор STG_0). Ожидается:",
        "//   Stage 1 1 359,4 | Stage 2 30,1 | Stage 3 150,7 | POCI 5,9",
        "EVALUATE",
        "CALCULATETABLE (",
        "    ROW (",
        '        "Stage 1, млрд ₸", [Stage 1, млрд ₸],',
        '        "Stage 2, млрд ₸", [Stage 2, млрд ₸],',
        '        "Stage 3, млрд ₸", [Stage 3, млрд ₸],',
        '        "POCI, млрд ₸",    [POCI, млрд ₸]',
        "    ),",
        "    TREATAS ( { DATE ( 2026, 7, 1 ) }, dim_month[Date] )",
        ")",
        "",
    ]
    (HERE / "PBI_measures.dax").write_text("\n".join(out), encoding="utf-8")
    print(f"ok: таблиц {len(TABLE_ORDER)}, мер {len(measures)}, показателей {len(ind_names)}, "
          f"веток «Значение» {len(branches)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
