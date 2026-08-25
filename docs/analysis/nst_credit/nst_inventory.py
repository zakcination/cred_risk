r"""
Инвентаризация папки материалов НСТ (R:\!!!!!НСТ2025) — что там вообще есть.

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
  python nst_inventory.py "R:\!!!!!НСТ2025"
  python nst_inventory.py "R:\!!!!!НСТ2025" --fast       # без шага 2
  python nst_inventory.py "R:\!!!!!НСТ2025" --max-mb 50  # не открывать больше
  python nst_inventory.py "R:\!!!!!НСТ2025" --jobs 16    # потоков на шаге 2
  python nst_inventory.py "R:\!!!!!НСТ2025" --quiet      # без живого прогресса

  --probe: прицельно вскрыть файл или папку. Результат — ТРИ CSV в --out:
    probe_columns.csv      колонка, сколько различных значений, сколько выгружено
    probe_values.csv       длинный формат: файл; лист; колонка; значение
    probe_header_grid.csv  сырая сетка верхних строк — читать многоуровневую
                           и объединённую шапку как есть, без догадок скрипта
  Так находится перечень значений измерения «Портфель в шаблоне НСТ»:
  python nst_inventory.py --probe "R:\!!!!!НСТ2025\Финальный шаблон и документы по НСТ2024"
  python nst_inventory.py --probe "R:\...\2025_КР расчет провизий_V5 (факт...).xlsx"

  --only «подстрока»  — шаг 2 только по файлам, чей путь её содержит
  --out ПАПКА         — куда выгрузить probe (по умолчанию probe_out/).
                        --probe ВСЕГДА пишет три CSV, на экран идёт
                        только сводка: терминал такой объём не держит,
                        перечни режутся, верх уходит за буфер.
  --full              — дополнительно вывалить все значения на экран
  --col «подстрока»   — вместе с --probe: только колонки с таким именем
  --distinct N        — поднять порог «это ещё измерение» (по умолчанию 50)
  --sheet «подстрока» — вместе с --probe: только листы с таким именем.
                        Нужно для шаблона: в нём 34 листа, часть по 16 384
                        колонки, и читать их все незачем.

СКОРОСТЬ — где она берётся и где её нет
  шаг 1  os.scandir вместо os.walk + os.stat. На Windows DirEntry.stat()
         берётся из листинга каталога и НЕ делает отдельного обращения
         к SMB. Это убирает половину сетевых round-trip'ов без потоков.
  шаг 2  ГЛАВНОЕ — не потоки, а то, что шапка читается без разбора файла.
         .xlsx открывается как zip: из листа берутся первые строки,
         из таблицы общих строк — только те, на которые они ссылаются,
         размер листа — из <dimension>. Стоимость перестаёт зависеть
         от размера файла:

             файл 20,8 МБ, 120 000 строк
             openpyxl read_only  19,300 с
             zip-читатель         0,005 с      в 3 500 раз быстрее

         Проверено на всём тестовом дереве: 281 строка выдачи,
         0 расхождений с openpyxl. openpyxl остаётся запасным путём.

         Потоки — второстепенны, и на реальной папке НСТ они НЕ помогли:
         прогон 16 потоками давал ~1 файл в секунду, потому что время
         уходило в разбор XML под GIL, а не в сеть. Прежний замер
         с имитацией задержки (4,6x на восьми потоках) был оптимистичен
         именно поэтому: sleep отпускает GIL целиком, а разбор — нет.
         Вывод: правильный ответ на «медленно» здесь был не «больше
         потоков», а «не делать эту работу».
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
import logging
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

PROBE_ROWS       = 5000  # --probe: сколько строк читаем ради значений
PROBE_DISTINCT   = 50    # больше этого различных значений — колонка не измерение
PROBE_HEAD_SCAN  = 15    # среди скольких верхних строк ищем настоящую шапку

# «Data Validation extension is not supported» и подобное: файл читается,
# предупреждение только засоряет вывод
warnings.filterwarnings("ignore", category=UserWarning, module="openpyxl")
# pypdf пишет «Multiple definitions in dictionary…» через logging в тот же
# поток, что и строка прогресса, и рвёт её посередине
logging.getLogger("pypdf").setLevel(logging.ERROR)
logging.getLogger("pypdf._reader").setLevel(logging.ERROR)


def human(n):
    for u in ("Б", "КБ", "МБ", "ГБ"):
        if n < 1024:
            return f"{n:.0f} {u}"
        n /= 1024
    return f"{n:.1f} ТБ"


def short_path(p):
    r"""Снять префикс \\?\ — обратная операция к long_path().

    Без неё os.scandir(long_path(d)) отдаёт entry.path С префиксом,
    а root остаётся без него, и os.path.relpath падает:
    ValueError: path is on mount '\\?\R:', start on mount 'R:'.
    Ошибка воспроизводится ТОЛЬКО на Windows — на Linux long_path()
    не делает ничего, поэтому тесты её не поймали.

    Правило: длинный путь живёт ровно на время системного вызова,
    в структурах данных лежит обычный."""
    if p.startswith("\\\\?\\UNC\\"):          # \\?\UNC\server\share
        return "\\\\" + p[8:]
    if p.startswith("\\\\?\\"):                 # \\?\R:\...
        return p[4:]
    return p


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
                    f"{rate:.1f}/с, осталось ~{eta / 60:.0f} мин")
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
                        stack.append(short_path(entry.path))
                        continue
                    st = entry.stat(follow_symlinks=False)
                    size, mtime = st.st_size, st.st_mtime
                except OSError as e:
                    errors.append(e)
                    size, mtime = -1, 0
                full = short_path(entry.path)
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
# ---- быстрый читатель .xlsx: шапка без разбора всего файла ----------------
# openpyxl даже в read_only разбирает поток целиком и тянет таблицу общих
# строк. На файлах расчёта по 100-500 МБ это давало ~1 файл в секунду,
# и потоки не помогали: время уходит в разбор XML под GIL, а не в сеть.
# Здесь .xlsx открывается как zip, и читаются ровно первые строки листа
# плюс те общие строки, на которые они ссылаются. Стоимость перестаёт
# зависеть от размера файла.
NS = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"
NSR = "{http://schemas.openxmlformats.org/officeDocument/2006/relationships}"


def _xlsx_sheet_head(zf, part, max_rows):
    """Первые строки листа + ссылки на общие строки + размер из <dimension>."""
    import xml.etree.ElementTree as ET
    rows, dim, need = [], None, set()
    with zf.open(part) as fh:
        for _, el in ET.iterparse(fh, events=("end",)):
            if el.tag == NS + "dimension":
                dim = el.get("ref")
            elif el.tag == NS + "row":
                cells = []
                for c in el:
                    t, v = c.get("t"), c.find(NS + "v")
                    if t == "inlineStr":
                        is_ = c.find(NS + "is")
                        cells.append(("lit", "".join(
                            x.text or "" for x in is_.iter(NS + "t"))
                            if is_ is not None else ""))
                    elif v is None:
                        cells.append(("lit", ""))
                    elif t == "s":
                        i = int(v.text)
                        need.add(i)
                        cells.append(("s", i))
                    else:
                        cells.append(("lit", v.text or ""))
                rows.append(cells)
                el.clear()
                if len(rows) >= max_rows:
                    break
    return rows, dim, need


def _xlsx_shared(zf, need):
    """Только те общие строки, которые встретились в шапке. Ранний выход
    по максимальному индексу — полный проход по таблице на 500 МБ не нужен."""
    import xml.etree.ElementTree as ET
    out = {}
    if not need:
        return out
    try:
        fh = zf.open("xl/sharedStrings.xml")
    except KeyError:
        return out
    hi, i = max(need), 0
    with fh:
        for _, el in ET.iterparse(fh, events=("end",)):
            if el.tag != NS + "si":
                continue
            if i in need:
                out[i] = "".join(t.text or "" for t in el.iter(NS + "t"))
            el.clear()
            if i >= hi:
                break
            i += 1
    return out


def _dim_size(ref):
    """'A1:T77' -> (77, 20). Размер листа без чтения данных."""
    if not ref or ":" not in ref:
        return -1, 0
    end = ref.split(":")[1]
    letters = "".join(ch for ch in end if ch.isalpha())
    digits = "".join(ch for ch in end if ch.isdigit())
    col = 0
    for ch in letters:
        col = col * 26 + (ord(ch.upper()) - 64)
    return (int(digits) if digits else -1), col


def sheets_xlsx_fast(path):
    import xml.etree.ElementTree as ET
    with zipfile.ZipFile(long_path(path)) as zf:
        wb = ET.fromstring(zf.read("xl/workbook.xml"))
        rels = {r.get("Id"): r.get("Target") for r in
                ET.fromstring(zf.read("xl/_rels/workbook.xml.rels"))}
        out, pending = [], []
        need_all = set()
        for sh in wb.iter(NS + "sheet"):
            tgt = rels.get(sh.get(NSR + "id"), "")
            part = ("xl/" + tgt.lstrip("/")) if not tgt.startswith("xl/") else tgt
            part = part.replace("xl/xl/", "xl/")
            try:
                rows, dim, need = _xlsx_sheet_head(zf, part, MAX_HEADER_ROWS)
            except KeyError:
                continue
            need_all |= need
            pending.append((sh.get("name"), rows, dim))
        shared = _xlsx_shared(zf, need_all)
        for name, rows, dim in pending:
            head = []
            for cells in rows:
                vals = [shared.get(v, "") if kind == "s" else str(v)
                        for kind, v in cells[:MAX_SHEET_COLS]]
                vals = [v.strip() for v in vals if v and v.strip()]
                if vals:
                    head.append(" | ".join(vals))
            nrows, ncols = _dim_size(dim)
            out.append({"sheet": name, "rows": nrows, "cols": ncols,
                        "header": " // ".join(head)[:2000]})
        return out


def sheets_xlsx(path):
    """Быстрый путь через zip, при любой неожиданности — openpyxl."""
    try:
        res = sheets_xlsx_fast(path)
        if res:
            return res
    except Exception:
        pass
    return sheets_xlsx_openpyxl(path)


def sheets_xlsx_openpyxl(path):
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


def inspect(files, max_mb, jobs, quiet=False, only=None):
    rows, skipped = [], Counter()
    todo = []
    for f in files:
        ext = f["ext"]
        if only and only.lower() not in f["rel"].lower():
            continue
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
            rows = ws.iter_rows(max_row=PROBE_ROWS, values_only=True)
            # Шапкой берём не первую заполненную строку, а ЛУЧШУЮ из верхних:
            # в шаблоне НСТ сверху идут технические строки («1», «2», «3»),
            # и прежняя редакция подписывала колонки ими.
            head_buf, header, best, head_i = [], None, -1, -1
            for i, row in enumerate(rows):
                head_buf.append(row)
                score = sum(1 for c in row if isinstance(c, str) and c.strip()
                            and not c.strip().isdigit())
                if score > best:
                    best, head_i = score, i
                    header = [str(c).strip() if c is not None else ""
                              for c in row]
                if i + 1 >= PROBE_HEAD_SCAN:
                    break
            vals, over, nrows = defaultdict(Counter), set(), 0
            # Пропускаем ВСЁ, что выше шапки включительно. Данные начинаются
            # ниже, а сверху идут технические строки: в шаблоне НСТ это
            # нумерация «1, 2, 3…», и её значения попадали в перечень
            # как полноправные — «Портфель» показывал 12 вместо 11.
            for j, row in enumerate(list(head_buf) + list(rows)):
                if j <= head_i:
                    continue
                nrows += 1
                for i, c in enumerate(row):
                    if c is None or i in over:
                        continue
                    s = str(c).strip()
                    if not s:
                        continue
                    vals[i][s] += 1
                    if len(vals[i]) > PROBE_DISTINCT:
                        over.add(i)
                        vals[i] = Counter()      # не держим ПДн в памяти
            cols = []
            for i, name in enumerate(header or []):
                if not name and i not in vals and i not in over:
                    continue
                if i in over:
                    cols.append({"col": i + 1, "name": name, "raznyh": -1,
                                 "bolshe_poroga": 1, "vals": []})
                else:
                    cnt = vals.get(i, Counter())
                    # частота: значение измерения встречается сотни раз,
                    # затесавшийся мусор из шапки — один. Видно без догадок.
                    v = sorted(cnt.items(), key=lambda kv: (-kv[1], kv[0]))
                    cols.append({"col": i + 1, "name": name, "raznyh": len(v),
                                 "bolshe_poroga": 0, "vals": v})
            # Сырая сетка верхних строк: в шаблоне шапка многоуровневая
            # и объединённая, и единственный честный способ её прочитать —
            # посмотреть на клетки как есть, а не на догадку скрипта.
            grid = []
            for r, row in enumerate(head_buf):
                for c, v in enumerate(row):
                    if v is not None and str(v).strip():
                        grid.append((r + 1, c + 1, str(v).strip()))
            out.append({"sheet": ws.title, "rows_read": nrows,
                        "header": header or [], "cols": cols,
                        "head_grid": grid, "head_row": head_i + 1})
    finally:
        wb.close()
    return out


def probe(target, quiet=False, sheet_like=None, col_like=None, full=False,
          out_dir="probe_out"):
    """Вскрыть файл или папку и ВЫГРУЗИТЬ результат в CSV.

    Печать в терминал не годится: на реальном шаблоне вывод — тысячи строк,
    перечни режутся, а верх прокручивается за пределы буфера. Поэтому
    основная выдача — три файла, а на экран идёт только сводка."""
    targets = []
    if os.path.isdir(target):
        for dp, dn, fn in os.walk(target):
            targets += [os.path.join(dp, f) for f in fn
                        if os.path.splitext(f)[1].lower() in
                        (".xlsx", ".xlsm", ".xltx") and not f.startswith("~$")]
        base = target
    else:
        targets = [target]
        base = os.path.dirname(target)

    os.makedirs(out_dir, exist_ok=True)
    cols_rows, val_rows, head_rows, errors = [], [], [], []
    prog = Progress("probe", total=len(targets), quiet=quiet)

    for t in sorted(targets):
        rel = os.path.relpath(t, base) if base else os.path.basename(t)
        try:
            sheets = probe_xlsx(t)
        except Exception as e:
            errors.append((rel, f"{type(e).__name__}: {e}"))
            prog.tick(note=os.path.basename(t))
            continue
        for sh in sheets:
            if sheet_like and sheet_like.lower() not in sh["sheet"].lower():
                continue
            for r, c, v in sh["head_grid"]:
                head_rows.append({"file": rel, "sheet": sh["sheet"],
                                  "row": r, "col": c, "value": v,
                                  "is_header_row": int(r == sh["head_row"])})
            for cc in sh["cols"]:
                if not cc["name"]:
                    continue
                if col_like and col_like.lower() not in cc["name"].lower():
                    continue
                cols_rows.append({"file": rel, "sheet": sh["sheet"],
                                  "col": cc["col"], "name": cc["name"],
                                  "rows_read": sh["rows_read"],
                                  "raznyh": cc["raznyh"],
                                  "bolshe_poroga": cc["bolshe_poroga"],
                                  "znacheniy_vygruzheno": len(cc["vals"])})
                for v, n in cc["vals"]:
                    val_rows.append({"file": rel, "sheet": sh["sheet"],
                                     "col": cc["col"], "name": cc["name"],
                                     "value": v, "vstrechaetsya": n})
        prog.tick(note=os.path.basename(t))
    prog.close(f"листов разобрано, колонок {len(cols_rows)}")

    def w(name, rows, cols):
        path = os.path.join(out_dir, name)
        with open(path, "w", newline="", encoding="utf-8-sig") as f:
            wr = csv.DictWriter(f, fieldnames=cols, extrasaction="ignore",
                                delimiter=";")
            wr.writeheader()
            wr.writerows(rows)
        print(f"  {path}  ({len(rows)} строк)")
        return path

    print(f"\n--probe: файлов {len(targets)}, выгрузка в {out_dir}/")
    w("probe_columns.csv", cols_rows,
      ["file", "sheet", "col", "name", "rows_read", "raznyh",
       "bolshe_poroga", "znacheniy_vygruzheno"])
    w("probe_values.csv", val_rows,
      ["file", "sheet", "col", "name", "value", "vstrechaetsya"])
    w("probe_header_grid.csv", head_rows,
      ["file", "sheet", "row", "col", "value", "is_header_row"])
    if errors:
        w("probe_errors.csv", [{"file": a, "error": b} for a, b in errors],
          ["file", "error"])

    print("\nСВОДКА — колонки, похожие на измерение (значений 2..50):")
    dims = [c for c in cols_rows
            if not c["bolshe_poroga"] and 2 <= c["raznyh"] <= PROBE_DISTINCT]
    for c in sorted(dims, key=lambda r: (-r["raznyh"]))[:40]:
        print(f"  {c['raznyh']:>4} знач.  «{c['sheet'][:22]:<22}» "
              f"[{c['col']:>3}] {c['name'][:60]}")
    if not dims:
        print("  таких нет — либо лист пуст, либо --distinct задан слишком низко")

    print(f"\nВ probe_values.csv у каждого значения стоит vstrechaetsya —")
    print("  сколько раз оно встретилось. Значение измерения встречается")
    print("  сотни раз, случайный мусор из шапки — один; видно без догадок.")
    print(f"\nКолонки с числом различных значений больше {PROBE_DISTINCT} "
          "выгружены без значений (raznyh = -1, bolshe_poroga = 1):")
    print("  это признак «не измерение» и одновременно защита ПДн —")
    print("  колонка с БИН или наименованием в probe_values.csv не попадает.")

    if full:
        for c in cols_rows:
            vs = [f'{v["value"]}  ({v["vstrechaetsya"]})' for v in val_rows
                  if (v["file"], v["sheet"], v["col"]) ==
                     (c["file"], c["sheet"], c["col"])]
            if vs:
                print(f"\n  «{c['sheet']}» [{c['col']}] {c['name']} "
                      f"({c['raznyh']}):")
                for v in vs:
                    print(f"      {v}")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    if "--probe" in sys.argv:
        sheet_like = col_like = None
        if "--sheet" in sys.argv:
            sheet_like = sys.argv[sys.argv.index("--sheet") + 1]
        if "--col" in sys.argv:
            col_like = sys.argv[sys.argv.index("--col") + 1]
        if "--distinct" in sys.argv:
            globals()["PROBE_DISTINCT"] = int(
                sys.argv[sys.argv.index("--distinct") + 1])
        out_dir = "probe_out"
        if "--out" in sys.argv:
            out_dir = sys.argv[sys.argv.index("--out") + 1]
        probe(sys.argv[sys.argv.index("--probe") + 1], sheet_like=sheet_like,
              col_like=col_like, full="--full" in sys.argv, out_dir=out_dir,
              quiet="--quiet" in sys.argv or not sys.stderr.isatty())
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
    only = None
    if "--only" in sys.argv:
        only = sys.argv[sys.argv.index("--only") + 1]
    if not os.path.isdir(root):
        print(f"нет такой папки: {root}")
        sys.exit(2)

    t0 = time.time()
    print(f"шаг 1: обход {root} …")
    files, errors = walk(root, quiet=quiet)
    print(f"       найдено {len(files)} файлов")

    def dump(name, rows, cols):
        if not rows:
            return
        with open(name, "w", newline="", encoding="utf-8-sig") as f:
            w = csv.DictWriter(f, fieldnames=cols, extrasaction="ignore",
                               delimiter=";")
            w.writeheader()
            w.writerows(rows)
        print(f"       записан {name} ({len(rows)} строк)")

    # Опись пишется СРАЗУ, а не в конце: шаг 1 занимает полсекунды, шаг 2 —
    # десятки минут, и прерывание шага 2 не должно стоить описи.
    dump("nst2025_inventory.csv", files,
         ["rel", "dir", "name", "ext", "size", "size_h", "mtime", "depth",
          "interest"])

    struct, skipped = [], Counter()
    if not fast:
        print(f"шаг 2: чтение структуры офисных файлов, потоков {jobs}"
              + (f", только «{only}»" if only else "") + " …")
        struct, skipped = inspect(files, max_mb, jobs, quiet=quiet, only=only)
        print(f"       разобрано листов/документов: {len(struct)}")

    print("шаг 3: поиск шаблона НСТ …")
    tmpl = find_template(struct)

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
