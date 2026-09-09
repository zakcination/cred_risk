# -*- coding: utf-8 -*-
"""
Дамп рабочей книги месячного листа: значения, формулы, форматы.

Путь зашит (SRC). Книга сначала копируется во временный файл — на общем ресурсе
она может быть открыта другим пользователем, и чтение «по месту» тогда отдаёт
файл с блокировкой либо падает. Исходник не изменяется: только чтение.

Зачем формулы отдельно. По значению нельзя отличить, что ячейка ПОСЧИТАНА,
а что ВСТАВЛЕНА как число. Для § 10.2 это и есть вопрос: лист несёт реконструкцию
или отчётные значения. Ответ виден только в формулах.

§ 2: вывод остаётся на машине автора. § 6: дамп ничего не выбирает и не считает.

Запуск:
  python monthly_dump.py                       # зашитый путь, все листы
  python monthly_dump.py --sheet Monthly       # один лист
  python monthly_dump.py "C:\\другой\\файл.xlsx"
"""

import argparse
import os
import shutil
import sys
import tempfile
from datetime import date, datetime

SRC = r"R:\Risk_Appetite\расчеты\Attachment_3_monthly[36]_Credit_Risk_metrics.xlsx"

MAX_ROWS = 200
MAX_COLS = 60
MAX_FORMULAS = 400


def cell(v):
    if v is None:
        return ""
    if isinstance(v, (datetime, date)):
        return v.strftime("%Y-%m-%d")
    if isinstance(v, float):
        if v == int(v) and abs(v) < 1e15:
            return str(int(v))
        return "%.10g" % v
    s = str(v).replace(";", ",").replace("\n", " ").replace("\r", " ")
    return s.strip()


def col_letter(j):
    s = ""
    while j > 0:
        j, r = divmod(j - 1, 26)
        s = chr(65 + r) + s
    return s


def dump_external_links(xlsx_path):
    """Цели внешних связей: [1], [2]… -> путь книги-источника и имена её листов.

    Формула вида ='[1]Лист'!B20 не показывает, ЧТО за книга скрыта под [1].
    Соответствие лежит в xl/externalLinks/externalLinkN.xml и его .rels.
    """
    import re
    import zipfile
    print("\n=== ВНЕШНИЕ СВЯЗИ ===")
    try:
        z = zipfile.ZipFile(xlsx_path)
    except Exception as e:
        print("  не открыть архив: %s" % e.__class__.__name__)
        return
    with z:
        names = sorted(n for n in z.namelist()
                       if re.match(r"xl/externalLinks/externalLink\d+\.xml$", n))
        if not names:
            print("  внешних связей нет")
            return
        for n in names:
            idx = re.search(r"(\d+)\.xml$", n).group(1)
            rels = "xl/externalLinks/_rels/externalLink%s.xml.rels" % idx
            target = "(цель не найдена)"
            try:
                rx = z.read(rels).decode("utf-8", "replace")
                m = re.search(r'Target="([^"]+)"', rx)
                if m:
                    target = m.group(1)
            except KeyError:
                pass
            try:
                xml = z.read(n).decode("utf-8", "replace")
            except Exception:
                xml = ""
            sheets = re.findall(r'<sheetName val="([^"]*)"', xml)
            n_cells = len(re.findall(r"<cell ", xml))
            print("  [%s] -> %s" % (idx, target))
            if sheets:
                print("        листы: %s" % ", ".join(sheets[:20]))
            print("        кэшированных ячеек в книге-приёмнике: %d" % n_cells)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("path", nargs="?", default=SRC)
    ap.add_argument("--sheet", default=None)
    ap.add_argument("--out", default=None, help="куда положить CSV (по умолчанию рядом, папка _dump)")
    ap.add_argument("--max-rows", type=int, default=MAX_ROWS)
    ap.add_argument("--max-cols", type=int, default=MAX_COLS)
    a = ap.parse_args()

    src = a.path
    if not os.path.isfile(src):
        sys.exit("файл не найден: %s" % src)

    # ВАЖНО: вывод НЕ кладётся рядом с источником — книга может лежать на общем
    # ресурсе, и писать туда мы не имеем права. По умолчанию — текущий каталог.
    out = a.out or os.path.join(os.getcwd(), "_dump")
    try:
        os.makedirs(out, exist_ok=True)
    except OSError:
        out = os.path.join(tempfile.gettempdir(), "_dump")
        os.makedirs(out, exist_ok=True)

    tmpdir = tempfile.mkdtemp(prefix="mdump_")
    tmp = os.path.join(tmpdir, "book.xlsx")
    shutil.copy2(src, tmp)
    print("источник : %s" % src)
    print("копия    : %s" % tmp)
    print("вывод    : %s" % out)

    from openpyxl import load_workbook
    wbv = load_workbook(tmp, data_only=True)   # значения
    wbf = load_workbook(tmp, data_only=False)  # формулы

    print("\n=== ЛИСТЫ ===")
    for ws in wbv.worksheets:
        print("  %-24s строк=%-6s кол=%-4s  видимость=%s"
              % (ws.title, ws.max_row, ws.max_column, ws.sheet_state))

    targets = [s for s in wbv.sheetnames if (a.sheet is None or s == a.sheet)]
    if a.sheet and not targets:
        sys.exit("нет листа «%s». Есть: %s" % (a.sheet, ", ".join(wbv.sheetnames)))

    dump_external_links(tmp)

    for name in targets:
        wsv, wsf = wbv[name], wbf[name]
        nr = min(wsv.max_row or 0, a.max_rows)
        nc = min(wsv.max_column or 0, a.max_cols)
        print("\n" + "=" * 70)
        print("=== ЛИСТ «%s» — значения, строк %d, колонок %d ===" % (name, nr, nc))
        print("=" * 70)

        if wsv.merged_cells.ranges:
            rr = [str(r) for r in wsv.merged_cells.ranges][:20]
            print("объединённые: %s%s" % (", ".join(rr),
                                          " …" if len(wsv.merged_cells.ranges) > 20 else ""))

        hdr = ";".join(col_letter(j) for j in range(1, nc + 1))
        print("\n#;%s" % hdr)

        rows_csv = []
        for i in range(1, nr + 1):
            vals = [cell(wsv.cell(i, j).value) for j in range(1, nc + 1)]
            if not any(vals):
                continue
            line = "%d;%s" % (i, ";".join(vals))
            print(line)
            rows_csv.append(line)

        # форматы: что в строке размечено как процент/дата
        print("\n--- форматы по строкам (только непустые, отличные от General) ---")
        for i in range(1, nr + 1):
            fmts = []
            for j in range(1, nc + 1):
                c = wsv.cell(i, j)
                if c.value is None:
                    continue
                f = c.number_format
                if f and f != "General" and f not in fmts:
                    fmts.append(f)
            if fmts:
                print("  r%-4d %s" % (i, " | ".join(fmts[:6])))

        # формулы
        print("\n--- формулы ---")
        n_f = 0
        for i in range(1, nr + 1):
            for j in range(1, nc + 1):
                v = wsf.cell(i, j).value
                if isinstance(v, str) and v.startswith("="):
                    n_f += 1
                    if n_f <= MAX_FORMULAS:
                        print("  %s%d: %s" % (col_letter(j), i, v[:160]))
        n_blank = 0
        for i in range(1, nr + 1):
            for j in range(1, nc + 1):
                fv = wsf.cell(i, j).value
                if isinstance(fv, str) and fv.startswith("=") and wsv.cell(i, j).value is None:
                    n_blank += 1
        if n_blank:
            print("  ВНИМАНИЕ: %d формул без сохранённого значения — в разделе «значения»"
                  % n_blank)
            print("  они выглядят пустыми. Так бывает, если книгу последним сохранял не Excel.")
            print("  Пустота в таких ячейках НЕ означает, что данных нет.")
        if n_f == 0:
            print("  формул нет — все значения вставлены числами")
        elif n_f > MAX_FORMULAS:
            print("  …всего формул %d, показано %d" % (n_f, MAX_FORMULAS))
        else:
            print("  всего формул: %d" % n_f)

        safe = "".join(ch if ch.isalnum() or ch in "-_" else "_" for ch in name)
        p = os.path.join(out, "dump_%s.csv" % safe)
        with open(p, "w", encoding="utf-8-sig") as f:
            f.write("#;%s\n" % hdr)
            f.write("\n".join(rows_csv))
        print("\nCSV листа: %s" % p)

    wbv.close()
    wbf.close()
    shutil.rmtree(tmpdir, ignore_errors=True)


if __name__ == "__main__":
    main()
