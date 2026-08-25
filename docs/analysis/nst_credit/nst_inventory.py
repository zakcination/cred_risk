"""
Инвентаризация папки материалов НСТ (R:\\!!!!!НСТ2025) — что там вообще есть.

Исключение из Н1 по основанию Н3: скрипт передаётся человеку на прогон
на машине, где смонтирован сетевой диск. В контейнере сессии этого диска нет.

ЧТО СКРИПТ ДЕЛАЕТ
  шаг 1  обходит дерево, пишет метаданные каждого файла
  шаг 2  открывает офисные файлы и читает ТОЛЬКО структуру:
         имена листов, размеры, первые строки шапки
  шаг 3  ищет прошлогодний шаблон НСТ по колонкам заголовка
  шаг 4  печатает сводку и пишет три CSV

ЧЕГО СКРИПТ НЕ ДЕЛАЕТ
  не читает данные строк — только шапки; не копирует файлы;
  не открывает то, что не распознал; ничего никуда не отправляет.

КОНФИДЕНЦИАЛЬНОСТЬ
  Выдача содержит ИМЕНА ФАЙЛОВ и ЗАГОЛОВКИ КОЛОНОК. В именах папок ВНД
  и выгрузок может стоять что угодно, вплоть до БИН. Файлы `nst2025_*.csv`
  остаются на рабочей машине; в репозиторий и вовне уходит только сводка
  шага 4 (счётчики, расширения, листы) — она безымянная.

ЗАПУСК
  python nst_inventory.py "R:\\!!!!!НСТ2025"
  python nst_inventory.py "R:\\!!!!!НСТ2025" --fast      # без шага 2
  python nst_inventory.py "R:\\!!!!!НСТ2025" --max-mb 50 # не открывать больше

ЗАВИСИМОСТИ
  обязательных нет. Больше видно, если стоят: openpyxl (.xlsx/.xlsm),
  xlrd (.xls), pypdf (.pdf). .docx читается стандартным zipfile.
  Чего нет — попадёт в CSV как строка с пометкой, а не пропадёт молча.
"""

import csv
import os
import re
import sys
import zipfile
from collections import Counter, defaultdict
from datetime import datetime

# --- шапка прошлогоднего шаблона: по ней ищем сам шаблон -------------------
TEMPLATE_KEYS = [
    "SEGMENT",
    "Портфель в шаблоне НСТ",
    "Стадия кредитного обесценения",
    "Объем задолженности",
    "Объем внебалансовых обязательств",
    "Объем провизий",
]

# слова, по которым файл интересен независимо от расширения
INTEREST = [
    "нст", "nst", "сегмент", "segment", "шаблон", "template",
    "методруководство", "инструкция", "aqr", "b2a", "700", "аррфр",
    "системн", "значим", "d-sib", "dsib", "провиз", "стад",
]

OFFICE = {".xlsx", ".xlsm", ".xltx", ".xls", ".xlsb", ".docx", ".doc",
          ".pdf", ".csv", ".txt", ".pptx"}

MAX_HEADER_ROWS = 6      # сколько строк шапки читаем с листа
MAX_SHEET_COLS  = 40     # сколько колонок шапки записываем


def human(n):
    for u in ("Б", "КБ", "МБ", "ГБ"):
        if n < 1024:
            return f"{n:.0f} {u}"
        n /= 1024
    return f"{n:.1f} ТБ"


def long_path(p):
    """Windows: обход ограничения в 260 символов."""
    if os.name == "nt" and not p.startswith("\\\\?\\"):
        if p.startswith("\\\\"):
            return "\\\\?\\UNC" + p[1:]
        return "\\\\?\\" + os.path.abspath(p)
    return p


# =========================== ШАГ 1. Обход дерева ===========================
def walk(root):
    files, errors = [], []
    for dirpath, dirnames, filenames in os.walk(root, onerror=errors.append):
        dirnames[:] = [d for d in dirnames
                       if not d.startswith("~$") and d.lower() != "$recycle.bin"]
        depth = dirpath[len(root):].count(os.sep)
        for fn in filenames:
            if fn.startswith("~$"):          # временные файлы Office
                continue
            full = os.path.join(dirpath, fn)
            try:
                st = os.stat(long_path(full))
                size, mtime = st.st_size, st.st_mtime
            except OSError as e:
                errors.append(e)
                size, mtime = -1, 0
            files.append({
                "path": full,
                "rel": os.path.relpath(full, root),
                "dir": os.path.relpath(dirpath, root),
                "name": fn,
                "ext": os.path.splitext(fn)[1].lower(),
                "size": size,
                "size_h": human(size) if size >= 0 else "?",
                "mtime": datetime.fromtimestamp(mtime).strftime("%Y-%m-%d %H:%M")
                         if mtime else "",
                "depth": depth,
                "interest": int(any(w in fn.lower() or w in dirpath.lower()
                                    for w in INTEREST)),
            })
    return files, errors


# ====================== ШАГ 2. Структура офисных файлов ====================
def sheets_xlsx(path):
    import openpyxl
    wb = openpyxl.load_workbook(long_path(path), read_only=True,
                                data_only=True, keep_links=False)
    out = []
    try:
        for ws in wb.worksheets:
            head = []
            for i, row in enumerate(ws.iter_rows(max_row=MAX_HEADER_ROWS,
                                                 max_col=MAX_SHEET_COLS,
                                                 values_only=True)):
                cells = [str(c).strip() for c in row if c is not None
                         and str(c).strip()]
                if cells:
                    head.append(" | ".join(cells))
                if i + 1 >= MAX_HEADER_ROWS:
                    break
            out.append({"sheet": ws.title,
                        "rows": ws.max_row, "cols": ws.max_column,
                        "header": " // ".join(head)[:2000]})
    finally:
        wb.close()
    return out


def sheets_xls(path):
    import xlrd
    bk = xlrd.open_workbook(path, on_demand=True)
    out = []
    for name in bk.sheet_names():
        sh = bk.sheet_by_name(name)
        head = []
        for r in range(min(MAX_HEADER_ROWS, sh.nrows)):
            cells = [str(sh.cell_value(r, c)).strip()
                     for c in range(min(MAX_SHEET_COLS, sh.ncols))
                     if str(sh.cell_value(r, c)).strip()]
            if cells:
                head.append(" | ".join(cells))
        out.append({"sheet": name, "rows": sh.nrows, "cols": sh.ncols,
                    "header": " // ".join(head)[:2000]})
        bk.unload_sheet(name)
    return out


def text_docx(path, limit=40):
    """Абзацы .docx без сторонних библиотек — это обычный zip с XML."""
    with zipfile.ZipFile(long_path(path)) as z:
        xml = z.read("word/document.xml").decode("utf-8", "ignore")
    parts = re.findall(r"<w:t[^>]*>(.*?)</w:t>", xml, re.S)
    text, buf = [], ""
    for p in parts:
        buf += re.sub(r"<[^>]+>", "", p)
        if len(buf) > 80:
            text.append(buf.strip())
            buf = ""
        if len(text) >= limit:
            break
    if buf.strip():
        text.append(buf.strip())
    return [{"sheet": "", "rows": len(parts), "cols": 0,
             "header": " // ".join(text)[:2000]}]


def text_pdf(path, pages=2):
    from pypdf import PdfReader
    rd = PdfReader(long_path(path))
    txt = " ".join((rd.pages[i].extract_text() or "")
                   for i in range(min(pages, len(rd.pages))))
    return [{"sheet": "", "rows": len(rd.pages), "cols": 0,
             "header": re.sub(r"\s+", " ", txt)[:2000]}]


def head_csv(path, lines=3):
    """Первые строки текстового файла. Файл короче `lines` — не ошибка:
    прежняя редакция ловила StopIteration и выбрасывала уже прочитанное,
    из-за чего шапка двухстрочного шаблона терялась целиком."""
    for enc in ("utf-8-sig", "cp1251", "utf-16"):
        try:
            head = []
            with open(long_path(path), encoding=enc) as f:
                for i, line in enumerate(f):
                    if i >= lines:
                        break
                    head.append(line.rstrip("\r\n"))
            if not head:
                return [{"sheet": enc, "rows": 0, "cols": 0, "header": "(пусто)"}]
            sep = max(";,\t", key=head[0].count)
            return [{"sheet": f"{enc}, разделитель {sep!r}",
                     "rows": len(head), "cols": head[0].count(sep) + 1,
                     "header": " // ".join(head)[:2000]}]
        except (UnicodeDecodeError, LookupError):
            continue
    return [{"sheet": "", "rows": -1, "cols": 0, "header": "(кодировка не определена)"}]


READERS = {
    ".xlsx": sheets_xlsx, ".xlsm": sheets_xlsx, ".xltx": sheets_xlsx,
    ".xls": sheets_xls, ".docx": text_docx, ".pdf": text_pdf,
    ".csv": head_csv, ".txt": head_csv,
}


def inspect(files, max_mb):
    rows, skipped = [], Counter()
    for f in files:
        ext = f["ext"]
        if ext not in READERS:
            if ext in OFFICE:
                skipped[f"{ext}: читателя нет"] += 1
            continue
        if f["size"] > max_mb * 1024 * 1024:
            skipped[f"{ext}: больше {max_mb} МБ"] += 1
            continue
        try:
            for s in READERS[ext](f["path"]):
                rows.append({**{k: f[k] for k in ("rel", "dir", "name", "ext",
                                                  "size_h", "mtime")}, **s})
        except ImportError as e:
            skipped[f"{ext}: нет библиотеки ({e.name})"] += 1
        except Exception as e:                       # файл битый/защищённый
            rows.append({**{k: f[k] for k in ("rel", "dir", "name", "ext",
                                              "size_h", "mtime")},
                         "sheet": "", "rows": -1, "cols": 0,
                         "header": f"(не открылся: {type(e).__name__}: {e})"[:300]})
    return rows, skipped


# ==================== ШАГ 3. Поиск прошлогоднего шаблона ===================
def find_template(struct):
    hits = []
    for r in struct:
        h = (r.get("header") or "").lower()
        matched = [k for k in TEMPLATE_KEYS if k.lower() in h]
        if len(matched) >= 2:
            hits.append({**r, "sovpalo": len(matched),
                         "kakie": "; ".join(matched)})
    return sorted(hits, key=lambda r: -r["sovpalo"])


# ============================ ШАГ 4. Сводка ===============================
def report(root, files, struct, tmpl, errors, skipped):
    P = print
    P("=" * 78)
    P(f"ПАПКА: {root}")
    P(f"файлов {len(files)}, суммарно {human(sum(max(f['size'],0) for f in files))}, "
      f"каталогов {len({f['dir'] for f in files})}, "
      f"глубина до {max((f['depth'] for f in files), default=0)}")
    if errors:
        P(f"ошибок доступа при обходе: {len(errors)}")

    P("\n--- по расширениям ---")
    by = defaultdict(lambda: [0, 0])
    for f in files:
        by[f["ext"] or "(без расширения)"][0] += 1
        by[f["ext"] or "(без расширения)"][1] += max(f["size"], 0)
    for ext, (n, sz) in sorted(by.items(), key=lambda kv: -kv[1][0]):
        P(f"  {ext:<20} {n:>5} шт  {human(sz):>10}")

    P("\n--- по годам последнего изменения ---")
    yr = Counter(f["mtime"][:4] for f in files if f["mtime"])
    for y, n in sorted(yr.items()):
        P(f"  {y}: {n}")

    P("\n--- каталоги верхнего уровня ---")
    top = defaultdict(lambda: [0, 0])
    for f in files:
        k = f["dir"].split(os.sep)[0] if f["dir"] != "." else "(корень)"
        top[k][0] += 1
        top[k][1] += max(f["size"], 0)
    for k, (n, sz) in sorted(top.items(), key=lambda kv: -kv[1][0]):
        P(f"  {k[:55]:<55} {n:>5} шт  {human(sz):>10}")

    P(f"\n--- файлы по ключевым словам ({len(INTEREST)} слов) ---")
    P(f"  отмечено интересными: {sum(f['interest'] for f in files)}")

    if skipped:
        P("\n--- не открывали ---")
        for k, n in skipped.most_common():
            P(f"  {k}: {n}")

    P("\n" + "=" * 78)
    P("ШАБЛОН НСТ — файлы, где шапка совпала с колонками прошлогодней формы")
    if not tmpl:
        P("  НЕ НАЙДЕН. Значит либо шаблон лежит в .xlsb (читателя нет),")
        P("  либо шапка на другом языке/в объединённых ячейках ниже 6-й строки.")
        P("  Поднять MAX_HEADER_ROWS и прогнать снова по подпапке с шаблонами.")
    for r in tmpl[:15]:
        P(f"  [{r['sovpalo']}/6] {r['rel']}  лист «{r['sheet']}» "
          f"({r['rows']}x{r['cols']})")
        P(f"        совпало: {r['kakie']}")
    P("=" * 78)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    root = os.path.abspath(sys.argv[1])
    fast = "--fast" in sys.argv
    max_mb = 100
    if "--max-mb" in sys.argv:
        max_mb = int(sys.argv[sys.argv.index("--max-mb") + 1])
    if not os.path.isdir(root):
        print(f"нет такой папки: {root}")
        sys.exit(2)

    print(f"шаг 1: обход {root} …")
    files, errors = walk(root)
    print(f"       найдено {len(files)} файлов")

    struct, skipped = [], Counter()
    if not fast:
        print("шаг 2: чтение структуры офисных файлов …")
        struct, skipped = inspect(files, max_mb)
        print(f"       разобрано листов/документов: {len(struct)}")

    print("шаг 3: поиск шаблона НСТ …")
    tmpl = find_template(struct)

    def dump(name, rows, cols):
        if not rows:
            return
        with open(name, "w", newline="", encoding="utf-8-sig") as f:
            w = csv.DictWriter(f, fieldnames=cols, extrasaction="ignore",
                               delimiter=";")
            w.writeheader()
            w.writerows(rows)
        print(f"       записан {name} ({len(rows)} строк)")

    dump("nst2025_inventory.csv", files,
         ["rel", "dir", "name", "ext", "size", "size_h", "mtime", "depth", "interest"])
    dump("nst2025_structure.csv", struct,
         ["rel", "dir", "name", "ext", "size_h", "mtime", "sheet", "rows", "cols", "header"])
    dump("nst2025_template.csv", tmpl,
         ["rel", "sheet", "rows", "cols", "sovpalo", "kakie", "header"])

    report(root, files, struct, tmpl, errors, skipped)
    print("\nCSV остаются на этой машине. Наружу — только текст сводки выше.")


if __name__ == "__main__":
    main()
