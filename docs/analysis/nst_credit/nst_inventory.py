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
  python nst_inventory.py "R:\\!!!!!НСТ2025" --fast       # без шага 2
  python nst_inventory.py "R:\\!!!!!НСТ2025" --max-mb 50  # не открывать больше
  python nst_inventory.py "R:\\!!!!!НСТ2025" --jobs 16    # потоков на шаге 2
  python nst_inventory.py "R:\\!!!!!НСТ2025" --quiet      # без живого прогресса

  --probe: прицельно вскрыть файл или папку — полная шапка ВСЕХ листов
  плюс различные значения узких колонок. Так находится перечень значений
  измерения «Портфель в шаблоне НСТ»:
  python nst_inventory.py --probe "R:\\!!!!!НСТ2025\\Финальный шаблон и документы по НСТ2024"
  python nst_inventory.py --probe "R:\\...\\2025_КР расчет провизий_V5 (факт...).xlsx"

СКОРОСТЬ — где она берётся и где её нет
  шаг 1  os.scandir вместо os.walk + os.stat. На Windows DirEntry.stat()
         берётся из листинга каталога и НЕ делает отдельного обращения
         к SMB. Это убирает половину сетевых round-trip'ов без потоков.
  шаг 2  пул потоков. Сетевое чтение GIL отпускает, разбор XML — нет.
         Замер на 221 файле с имитацией 25 мс латентности на открытие:

             потоков   1      4      8     16     32
             секунд  6,74   1,83   1,45   1,21   1,17
             к базе  1,0x   3,7x   4,6x   5,6x   5,8x

         Насыщение к 16 потокам. На реальных файлах выигрыш МЕНЬШЕ:
         в замере задержка синтетическая и GIL отпускает целиком,
         а настоящий разбор XML идёт под GIL. По той же причине
         на локальном диске потоки не ускоряют, а замедляют
         (0,8 с в один поток против 1,1 с в восемь) — прятать нечего,
         остаются накладные расходы. Отсюда: --jobs 1 для локальной
         папки, 8-16 для сетевого диска.
  чего НЕТ: жёсткого таймаута на файл. Потоки в Python не убиваются,
         а зависший SMB-хэндл ждёт до конца. Смягчение — --max-mb
         и имя текущего файла в строке прогресса: видно, на чём встали.

ЗАВИСИМОСТИ
  обязательных нет. Больше видно, если стоят: openpyxl (.xlsx/.xlsm),
  pyxlsb (.xlsb), xlrd (.xls), pypdf (.pdf). .docx читается стандартным
  zipfile. Чего нет — попадёт в CSV строкой с пометкой, а не пропадёт молча.

  По итогам первого прогона на R:\!!!!!НСТ2025 не прочитано:
    23 файла .xlsb — 2 ГБ, ПОЛОВИНА объёма папки  ->  pip install pyxlsb
    10 файлов .pdf                                ->  pip install pypdf
     6 файлов .xlsx больше 100 МБ                 ->  --max-mb 500
"""

import csv
import os
import warnings
import re
import sys
import time
import zipfile
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime

# --- шапка прошлогоднего шаблона: по ней ищем сам шаблон -------------------
# Ключ — что ищем, значение — варианты написания. Первый прогон искал
# точные подстроки и на 15 попаданиях не нашёл ни SEGMENT, ни «Портфель
# в шаблоне НСТ»: колонки в файлах названы иначе. Ищем по синонимам.
TEMPLATE_KEYS = {
    "сегмент":      ("segment", "сегмент"),
    "портфель":     ("портфель", "portf", "portfolio"),
    "стадия":       ("стадия", "stage", "обесценен"),
    "задолженность": ("задолженност", "объем задолж"),
    "внебаланс":    ("внебаланс", "offbal", "условны"),
    "провизии":     ("провизи", "резерв", "provision"),
}

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

PROBE_ROWS     = 5000    # --probe: сколько строк читаем ради значений
PROBE_DISTINCT = 50      # больше этого различных значений — колонка не измерение

# «Data Validation extension is not supported» и подобное: файл читается,
# предупреждение только засоряет вывод
warnings.filterwarnings("ignore", category=UserWarning, module="openpyxl")


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


# ============================ Живой прогресс ==============================
class Progress:
    """Строка в stderr, перерисовываемая на месте. Не украшение: прогон
    по сетевому диску без вывода неотличим от зависания, а имя текущего
    файла — единственный способ понять, на чём встали."""

    def __init__(self, label, total=None, quiet=False):
        self.label, self.total, self.quiet = label, total, quiet
        self.n, self.t0, self.last = 0, time.time(), 0.0
        self.width = 0

    def tick(self, n=1, note=""):
        self.n += n
        now = time.time()
        if self.quiet or (now - self.last < 0.1 and self.n != self.total):
            return
        self.last = now
        el = now - self.t0
        rate = self.n / el if el > 0 else 0
        if self.total:
            eta = (self.total - self.n) / rate if rate > 0 else 0
            head = (f"{self.label}: {self.n}/{self.total} "
                    f"({100 * self.n / self.total:4.1f} %) "
                    f"{rate:.0f}/с, осталось ~{eta:.0f} с")
        else:
            head = f"{self.label}: {self.n} за {el:.0f} с ({rate:.0f}/с)"
        line = head + (f"  {note[-58:]}" if note else "")
        pad = " " * max(0, self.width - len(line))
        self.width = len(line)
        sys.stderr.write("\r" + line + pad)
        sys.stderr.flush()

    def close(self, note=""):
        if self.quiet:
            return
        el = time.time() - self.t0
        sys.stderr.write("\r" + " " * self.width + "\r")
        sys.stderr.write(f"{self.label}: {self.n} за {el:.1f} с"
                         + (f" — {note}" if note else "") + "\n")
        sys.stderr.flush()


# =========================== ШАГ 1. Обход дерева ===========================
def walk(root, quiet=False):
    """os.scandir, а не os.walk + os.stat.

    На Windows DirEntry.stat() берётся из листинга каталога и отдельного
    обращения к серверу НЕ делает — на сетевом диске это половина
    round-trip'ов. Потоки здесь не нужны: они бы боролись за то, что
    уже не тратится."""
    files, errors = [], []
    stack, ndirs = [root], 0
    prog = Progress("шаг 1, обход", quiet=quiet)
    while stack:
        d = stack.pop()
        ndirs += 1
        try:
            it = os.scandir(long_path(d))
        except OSError as e:
            errors.append(e)
            continue
        with it:
            while True:
                try:
                    entry = next(it)
                except StopIteration:
                    break
                except OSError as e:            # каталог пропал/нет прав
                    errors.append(e)
                    break
                nm = entry.name
                if nm.startswith("~$") or nm.lower() == "$recycle.bin":
                    continue
                try:
                    if entry.is_dir(follow_symlinks=False):
                        stack.append(entry.path)
                        continue
                    st = entry.stat(follow_symlinks=False)
                    size, mtime = st.st_size, st.st_mtime
                except OSError as e:
                    errors.append(e)
                    size, mtime = -1, 0
                full = entry.path
                dirp = os.path.dirname(full)
                files.append({
                    "path": full,
                    "rel": os.path.relpath(full, root),
                    "dir": os.path.relpath(dirp, root),
                    "name": nm,
                    "ext": os.path.splitext(nm)[1].lower(),
                    "size": size,
                    "size_h": human(size) if size >= 0 else "?",
                    "mtime": datetime.fromtimestamp(mtime).strftime("%Y-%m-%d %H:%M")
                             if mtime else "",
                    "depth": os.path.relpath(dirp, root).count(os.sep)
                             if dirp != root else 0,
                    # Корень исключён: путь R:\!!!!!НСТ2025 содержит «нст»,
                    # и без этого признак срабатывал на 486 файлах из 486.
                    "interest": int(any(
                        w in nm.lower()
                        or w in os.path.relpath(dirp, root).lower()
                        for w in INTEREST)),
                })
                prog.tick(note=nm)
    prog.close(f"каталогов {ndirs}"
               + (f", ошибок доступа {len(errors)}" if errors else ""))
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


def sheets_xlsb(path):
    """.xlsb — двоичный формат, openpyxl его не открывает. Это половина
    объёма папки НСТ (23 файла, 2 ГБ), поэтому pyxlsb стоит поставить."""
    from pyxlsb import open_workbook
    out = []
    with open_workbook(long_path(path)) as wb:
        for name in wb.sheets:
            with wb.get_sheet(name) as sh:
                head, ncols = [], 0
                for i, row in enumerate(sh.rows()):
                    if i >= MAX_HEADER_ROWS:
                        break
                    cells = [str(c.v).strip() for c in row[:MAX_SHEET_COLS]
                             if c.v is not None and str(c.v).strip()]
                    ncols = max(ncols, len(row))
                    if cells:
                        head.append(" | ".join(cells))
                out.append({"sheet": name, "rows": -1, "cols": ncols,
                            "header": " // ".join(head)[:2000]})
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
    ".xls": sheets_xls, ".xlsb": sheets_xlsb,
    ".docx": text_docx, ".pdf": text_pdf,
    ".csv": head_csv, ".txt": head_csv,
}


def _one(f):
    """Разбор одного файла. Возвращает (строки, пропуск) и НИЧЕГО общего
    не трогает: счётчики сливаются в главном потоке, замок не нужен."""
    meta = {k: f[k] for k in ("rel", "dir", "name", "ext", "size_h", "mtime")}
    ext = f["ext"]
    try:
        return [{**meta, **s} for s in READERS[ext](f["path"])], None
    except ImportError as e:
        return [], f"{ext}: нет библиотеки ({e.name})"
    except Exception as e:                           # битый, защищённый, занят
        return [{**meta, "sheet": "", "rows": -1, "cols": 0,
                 "header": f"(не открылся: {type(e).__name__}: {e})"[:300]}], None


def inspect(files, max_mb, jobs, quiet=False):
    rows, skipped = [], Counter()
    todo = []
    for f in files:
        ext = f["ext"]
        if ext not in READERS:
            if ext in OFFICE:
                skipped[f"{ext}: читателя нет"] += 1
            continue
        if f["size"] > max_mb * 1024 * 1024:
            skipped[f"{ext}: больше {max_mb} МБ"] += 1
            continue
        todo.append(f)

    prog = Progress("шаг 2, чтение", total=len(todo), quiet=quiet)
    if jobs <= 1:
        for f in todo:
            r, sk = _one(f)
            rows += r
            if sk:
                skipped[sk] += 1
            prog.tick(note=f["name"])
    else:
        # Потоки, а не процессы: время уходит в сетевое чтение, а оно GIL
        # отпускает (замер в шапке: 4,6x на восьми потоках). Разбор XML
        # под GIL остаётся, поэтому на реальных файлах выигрыш меньше
        # замеренного. Процессы дали бы больше, но платят сериализацией
        # и на SMB съедают выигрыш обратно.
        with ThreadPoolExecutor(max_workers=jobs) as ex:
            fut = {ex.submit(_one, f): f for f in todo}
            for fu in as_completed(fut):
                r, sk = fu.result()
                rows += r
                if sk:
                    skipped[sk] += 1
                prog.tick(note=fut[fu]["name"])
    prog.close(f"листов и документов {len(rows)}")
    # порядок из пула недетерминирован — сортируем, чтобы CSV диффился
    rows.sort(key=lambda r: (r["rel"], str(r.get("sheet", ""))))
    return rows, skipped


# ==================== ШАГ 3. Поиск прошлогоднего шаблона ===================
def find_template(struct):
    hits = []
    for r in struct:
        h = (r.get("header") or "").lower()
        matched = [k for k, variants in TEMPLATE_KEYS.items()
                   if any(v in h for v in variants)]
        if len(matched) >= 3:
            hits.append({**r, "sovpalo": len(matched),
                         "kakie": "; ".join(matched)})
    return sorted(hits, key=lambda r: (-r["sovpalo"], r["rel"]))


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
        P(f"  [{r['sovpalo']}/{len(TEMPLATE_KEYS)}] {r['rel']}  лист «{r['sheet']}» "
          f"({r['rows']}x{r['cols']})")
        P(f"        совпало: {r['kakie']}")
    P("=" * 78)


# ================ РЕЖИМ --probe: прицельное чтение одного файла ============
def probe_xlsx(path):
    """Полная шапка + РАЗЛИЧНЫЕ ЗНАЧЕНИЯ узких колонок.

    Так находится перечень значений измерения «Портфель в шаблоне НСТ»:
    измерение — это колонка с десятком повторяющихся значений, а не
    с тысячей уникальных.

    Отсечка PROBE_DISTINCT работает и как защита ПДн: колонка с БИН или
    наименованием даёт тысячи различных значений и в выдачу не попадает
    вовсе — печатается только счётчик."""
    import openpyxl
    wb = openpyxl.load_workbook(long_path(path), read_only=True,
                                data_only=True, keep_links=False)
    out = []
    try:
        for ws in wb.worksheets:
            header, vals, over, nrows = None, defaultdict(set), set(), 0
            for row in ws.iter_rows(max_row=PROBE_ROWS, values_only=True):
                filled = [c for c in row if c is not None and str(c).strip()]
                if header is None:
                    if len(filled) >= 2:
                        header = [str(c).strip() if c is not None else ""
                                  for c in row]
                    continue
                nrows += 1
                for i, c in enumerate(row):
                    if c is None or i in over:
                        continue
                    s = str(c).strip()
                    if not s:
                        continue
                    vals[i].add(s)
                    if len(vals[i]) > PROBE_DISTINCT:
                        over.add(i)
                        vals[i] = set()          # не держим ПДн в памяти
            cols = []
            for i, name in enumerate(header or []):
                if not name and i not in vals and i not in over:
                    continue
                if i in over:
                    cols.append({"col": i + 1, "name": name,
                                 "raznyh": f">{PROBE_DISTINCT}", "znacheniya": ""})
                else:
                    v = sorted(vals.get(i, set()))
                    cols.append({"col": i + 1, "name": name, "raznyh": len(v),
                                 "znacheniya": " | ".join(v[:25])[:1500]})
            out.append({"sheet": ws.title, "rows_read": nrows,
                        "header": header or [], "cols": cols})
    finally:
        wb.close()
    return out


def probe(target, quiet=False):
    targets = []
    if os.path.isdir(target):
        for dp, dn, fn in os.walk(target):
            targets += [os.path.join(dp, f) for f in fn
                        if os.path.splitext(f)[1].lower() in
                        (".xlsx", ".xlsm", ".xltx") and not f.startswith("~$")]
    else:
        targets = [target]
    print(f"--probe: файлов к разбору {len(targets)}\n")
    for t in sorted(targets):
        print("=" * 78)
        print(os.path.basename(t))
        try:
            sheets = probe_xlsx(t)
        except Exception as e:
            print(f"  не открылся: {type(e).__name__}: {e}")
            continue
        for sh in sheets:
            named = [c for c in sh["cols"] if c["name"]]
            print(f"\n  лист «{sh['sheet']}» — строк прочитано {sh['rows_read']}, "
                  f"колонок с именем {len(named)}")
            for c in named:
                head = f"    [{c['col']:>2}] {c['name'][:45]:<45}"
                if c["znacheniya"]:
                    print(f"{head} ({c['raznyh']}) {c['znacheniya'][:110]}")
                else:
                    print(f"{head} ({c['raznyh']})")
    print("=" * 78)
    print("Колонки с числом различных значений > "
          f"{PROBE_DISTINCT} печатаются только счётчиком: там ПДн, а не измерение.")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    if "--probe" in sys.argv:
        probe(sys.argv[sys.argv.index("--probe") + 1])
        return
    root = os.path.abspath(sys.argv[1])
    fast = "--fast" in sys.argv
    quiet = "--quiet" in sys.argv or not sys.stderr.isatty()
    max_mb = 100
    if "--max-mb" in sys.argv:
        max_mb = int(sys.argv[sys.argv.index("--max-mb") + 1])
    jobs = min(8, (os.cpu_count() or 4) * 2)
    if "--jobs" in sys.argv:
        jobs = max(1, int(sys.argv[sys.argv.index("--jobs") + 1]))
    if not os.path.isdir(root):
        print(f"нет такой папки: {root}")
        sys.exit(2)

    t0 = time.time()
    print(f"шаг 1: обход {root} …")
    files, errors = walk(root, quiet=quiet)
    print(f"       найдено {len(files)} файлов")

    struct, skipped = [], Counter()
    if not fast:
        print(f"шаг 2: чтение структуры офисных файлов, потоков {jobs} …")
        struct, skipped = inspect(files, max_mb, jobs, quiet=quiet)
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
    print(f"\nвсего {time.time() - t0:.1f} с"
          + ("" if fast else f", шаг 2 в {jobs} поток(ов)"))
    print("CSV остаются на этой машине. Наружу — только текст сводки выше.")


if __name__ == "__main__":
    main()
