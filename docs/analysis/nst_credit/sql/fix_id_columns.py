# -*- coding: utf-8 -*-
"""Идентификаторы B1A/B1B -> текст, чтобы VLOOKUP в Excel работал.

ЧТО ДЕЛАЕТ
------------------------------------------------------------------------------
  loan_id, loan_id_kr, id, credit_line_id  -> текст без хвоста .0,
                                              без экспоненты, без 'nan';
  iin_bin                                  -> текст, дополненный слева
                                              нулями до 12 знаков.
Остальные колонки не трогаются и остаются числами: суммы в Excel считаются.

ВЫХОД — КНИГА, А НЕ CSV
------------------------------------------------------------------------------
CSV для этой задачи не годится: Excel при открытии заново разбирает
070640010774 как число, и нули слетают опять. Поэтому на выходе .xlsx,
где колонки-идентификаторы имеют текстовый формат ("@"): значение остаётся
текстом и при просмотре, и при правке, и обе стороны VLOOKUP сходятся.
CSV можно дополнительно получить ключом --csv.

ПОЧЕМУ БЫСТРО
------------------------------------------------------------------------------
Прежняя версия писала openpyxl по ячейке (около 22 млн объектов Cell)
в режиме mode='a', который грузит книгу целиком, и делала это прямо
на сетевом диске. Здесь: копия на локальный диск, чтение один раз,
запись через xlsxwriter в постоянной памяти, возврат результата.

Запуск (без аргументов — путь тот же, что у nst_fill_2026.py):
  python fix_id_columns.py
  python fix_id_columns.py --work-dir C:\\work        # если %TEMP% на сети
  python fix_id_columns.py --engine calamine        # если долго идёт чтение
  python fix_id_columns.py --csv                    # ещё и CSV
  python fix_id_columns.py --selftest               # проверить сам скрипт
"""

import argparse
import os
import shutil
import sys
import tempfile
import time

# Колонки-идентификаторы. iin_bin обрабатывается особо — дополняется до 12.
ID_COLS = ["loan_id", "loan_id_kr", "id", "credit_line_id", "iin_bin"]
IIN_COL = "iin_bin"
IIN_LEN = 12
SHEETS = ["B1A", "B1B"]

SRC_DEFAULT = (
    r"R:\!!!!!НСТ2026\Сегментация\Предварительная"
    r"\B1A_B1B_01012026_сегментация НСТ_предварит.xlsx"
)

DRIVE_TYPE = {0: "неизвестен", 1: "корня нет", 2: "съёмный",
              3: "локальный", 4: "СЕТЕВОЙ", 5: "CD", 6: "RAM-диск"}


def drive_kind(path):
    """Локальный диск или сетевой. Нужно, чтобы рабочая папка не оказалась
    на сетевом диске молча: %TEMP% в перемещаемом профиле лежит на SMB,
    и тогда копия на локальный диск не состоялась вовсе."""
    p = os.path.abspath(path)
    if p.startswith("\\\\"):
        return "СЕТЕВОЙ (UNC)"
    if os.name != "nt":
        return "не Windows, тип диска не проверяется"
    try:
        import ctypes
        root = os.path.splitdrive(p)[0] + os.sep
        t = ctypes.windll.kernel32.GetDriveTypeW(ctypes.c_wchar_p(root))
    except Exception:
        return "не определён"
    return DRIVE_TYPE.get(t, "код %d" % t)


def to_text(v):
    """Значение ячейки -> текст: без 'nan', без экспоненты, без хвоста .0

    Порядок проверок важнее их состава. Строка из одних цифр возвращается
    КАК ЕСТЬ и раньше всего остального: '0001234567890' уже лежит текстом,
    и прогонять его через float значит стереть нули самому —
    float('0001234567890') = 1234567890.0.

    Через float проходит только то, что уже несёт признак числа: точку
    или экспоненту. 21225.0 -> 21225 ; 9.4054e+11 -> 940540000000.
    """
    if v is None:
        return ""
    s = str(v).strip()
    if s == "" or s.lower() in ("nan", "none", "nat"):
        return ""
    if s.isascii() and s.isdigit():
        return s
    try:
        f = float(s)
        if f == int(f) and abs(f) < 1e18:
            return str(int(f))
    except (ValueError, OverflowError):
        pass
    return s


def to_iin(v):
    """БИН/ИИН -> ровно 12 знаков, дополнение нулями слева.
    Нечисловое значение не трогается: превращать мусор в 000000000000 нельзя,
    он станет неотличим от настоящего идентификатора."""
    s = to_text(v)
    if s == "":
        return ""
    if s.isascii() and s.isdigit() and len(s) < IIN_LEN:
        return s.zfill(IIN_LEN)
    return s


# Ловушки, на которых скрипт проверяется. Список ведётся: каждый случай,
# на котором он однажды ошибся, остаётся здесь навсегда.
SELFTEST = [
    # (функция, вход,            ожидание,          почему)
    (to_text, 15222.0,           "15222",           "число float-ом — хвост .0 убрать"),
    (to_text, "15222.0",         "15222",           "то же строкой"),
    (to_text, 9.4054e+11,        "940540000000",    "экспонента — развернуть"),
    (to_text, "0001234567890",   "0001234567890",   "текст из цифр — НЕ трогать, нули уцелели"),
    (to_text, "00015222",        "00015222",        "то же, короткое"),
    (to_text, None,              "",                "пусто"),
    (to_text, "",                "",                "пусто"),
    (to_text, "nan",             "",                "литерал 'nan' от .astype(str)"),
    (to_text, "NaT",             "",                "литерал 'NaT'"),
    (to_text, "F06/73-76-КБ/2016", "F06/73-76-КБ/2016", "нечисловой идентификатор"),
    (to_iin,  70640010774,       "070640010774",    "БИН числом — дополнить до 12"),
    (to_iin,  "70640010774",     "070640010774",    "БИН строкой — дополнить до 12"),
    (to_iin,  7.0640010774e+10,  "070640010774",    "БИН экспонентой — развернуть и дополнить"),
    (to_iin,  "070640010774",    "070640010774",    "уже 12 знаков — оставить"),
    (to_iin,  "123456789012",    "123456789012",    "12 знаков без нуля — оставить"),
    (to_iin,  "",                "",                "пусто остаётся пустым"),
    (to_iin,  "не БИН",          "не БИН",          "мусор не превращать в 000000000000"),
]


def selftest():
    bad = 0
    for fn, src, want, why in SELFTEST:
        got = fn(src)
        ok = got == want
        bad += not ok
        print("  %s %-8s %-22r -> %-18r %s"
              % ("ok  " if ok else "СБОЙ", fn.__name__, src, got,
                 why if ok else "ОЖИДАЛОСЬ %r" % want))
    print("")
    print("проверок %d, сбоев %d" % (len(SELFTEST), bad))
    return 1 if bad else 0


def profile(df, sheet, log):
    """Короткая сводка по колонкам-идентификаторам: что получилось на выходе."""
    log("")
    log("  колонка          непусто    пусто  с ведущим нулём   длина")
    for col in ID_COLS:
        if col not in df.columns:
            log("  %-16s колонки нет" % col)
            continue
        vals = df[col]
        nonempty = vals[vals != ""]
        if len(nonempty) == 0:
            log("  %-16s %7d  %7d" % (col, 0, len(vals)))
            continue
        lens = nonempty.str.len()
        log("  %-16s %7d  %7d  %15d   %d..%d"
            % (col, len(nonempty), int((vals == "").sum()),
               int(nonempty.str.startswith("0").sum()), lens.min(), lens.max()))


def write_book(path, frames, log):
    """Книга через xlsxwriter в постоянной памяти: колонки-идентификаторы
    получают текстовый формат '@', остальные пишутся как есть и остаются
    числами."""
    import xlsxwriter
    wb = xlsxwriter.Workbook(path, {"constant_memory": True,
                                    "strings_to_numbers": False,
                                    "default_date_format": "dd.mm.yyyy"})
    fmt_txt = wb.add_format({"num_format": "@"})
    fmt_hdr = wb.add_format({"bold": True})
    for sheet, df in frames:
        ws = wb.add_worksheet(sheet)
        cols = list(df.columns)
        for j, c in enumerate(cols):
            if c in ID_COLS:
                ws.set_column(j, j, 20, fmt_txt)
        ws.write_row(0, 0, cols, fmt_hdr)
        ws.freeze_panes(1, 0)
        t = time.time()
        for i, row in enumerate(df.itertuples(index=False, name=None), start=1):
            # NaN в числовых колонках -> пустая ячейка
            ws.write_row(i, 0, [None if (isinstance(v, float) and v != v) else v
                                for v in row])
        log("  %s: %d строк за %.1f с" % (sheet, len(df), time.time() - t))
    wb.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=SRC_DEFAULT, help="исходная книга")
    ap.add_argument("--out-dir", default=None,
                    help="куда положить результат; по умолчанию папка источника")
    ap.add_argument("--out-name", default=None,
                    help="имя книги на выходе; по умолчанию <имя источника>_TEXT.xlsx")
    ap.add_argument("--work-dir", default=None,
                    help="рабочая папка для локальной копии; по умолчанию %TEMP%")
    ap.add_argument("--sheets", nargs="*", default=SHEETS)
    ap.add_argument("--csv", action="store_true", help="дополнительно выгрузить CSV")
    ap.add_argument("--engine", default=None,
                    help="движок чтения: calamine быстрее openpyxl в 10-20 раз")
    ap.add_argument("--selftest", action="store_true",
                    help="проверить to_text/to_iin на известных ловушках и выйти")
    a = ap.parse_args()
    if a.selftest:
        sys.exit(selftest())

    t0 = time.time()
    import pandas as pd
    t_import = time.time() - t0

    lines = []
    def log(s=""):
        print(s, flush=True)
        lines.append(s)

    if not os.path.isfile(a.src):
        sys.exit("файл не найден: %s" % a.src)
    if a.out_dir is None:
        a.out_dir = os.path.dirname(os.path.abspath(a.src))
    if a.out_name is None:
        a.out_name = os.path.splitext(os.path.basename(a.src))[0] + "_TEXT.xlsx"
    os.makedirs(a.out_dir, exist_ok=True)

    # 1. на локальный диск: сетевой не должен участвовать в работе
    if a.work_dir:
        os.makedirs(a.work_dir, exist_ok=True)
    tmpdir = tempfile.mkdtemp(prefix="fixid_", dir=a.work_dir)

    kind_work = drive_kind(tmpdir)
    log("источник      : %s   [%s]" % (a.src, drive_kind(a.src)))
    log("рабочая папка : %s   [%s]" % (tmpdir, kind_work))
    log("результат     : %s   [%s]" % (os.path.join(a.out_dir, a.out_name),
                                       drive_kind(a.out_dir)))
    if "СЕТЕВОЙ" in kind_work:
        log("")
        log("  ВНИМАНИЕ: рабочая папка сама на сетевом диске — копии на локальный")
        log("  диск не произошло. Задайте --work-dir C:\\work")
    log("")

    local = os.path.join(tmpdir, os.path.basename(a.src))
    log("копирую на локальный диск...")
    t = time.time(); shutil.copy2(a.src, local); t_copy_in = time.time() - t
    mb = os.path.getsize(local) / 2**20
    rate = ("%.1f МБ/с" % (mb / t_copy_in)) if t_copy_in > 0.05 else "быстрее, чем измеримо"
    log("  %.1f МБ за %.1f с (%s)" % (mb, t_copy_in, rate))
    stages = [("импорт pandas", t_import), ("копирование с сетевого диска", t_copy_in)]

    # Текстом читаются ТОЛЬКО идентификаторы. Числовые колонки остаются
    # числами, иначе суммы в Excel перестанут считаться.
    kw = dict(dtype={c: str for c in ID_COLS})
    if a.engine:
        kw["engine"] = a.engine

    frames = []
    for sheet in a.sheets:
        log("")
        log("=" * 64)
        log("лист %s" % sheet)
        log("=" * 64)
        t = time.time()
        try:
            df = pd.read_excel(local, sheet_name=sheet, **kw)
        except ValueError as e:
            log("  лист не прочитан: %s" % e); continue
        dt = time.time() - t
        stages.append(("чтение %s (локально)" % sheet, dt))
        log("  %d строк x %d колонок за %.1f с" % (df.shape[0], df.shape[1], dt))

        t = time.time()
        padded = 0
        for col in ID_COLS:
            if col not in df.columns:
                continue
            if col == IIN_COL:
                before = df[col].map(to_text)
                df[col] = df[col].map(to_iin)
                padded = int(((before != "") &
                              (before.str.len() < IIN_LEN) &
                              (df[col].str.len() == IIN_LEN)).sum())
            else:
                df[col] = df[col].map(to_text)
        stages.append(("приведение к тексту %s" % sheet, time.time() - t))
        log("  приведено к тексту за %.1f с" % stages[-1][1])
        if padded:
            log("  iin_bin дополнено нулями до 12 знаков: %d значений" % padded)

        profile(df, sheet, log)
        frames.append((sheet, df))

    if not frames:
        sys.exit("ни один лист не прочитан")

    # 2. книга: идентификаторы текстом, остальное числами
    log("")
    log("пишу книгу...")
    t = time.time()
    book = os.path.join(tmpdir, a.out_name)
    write_book(book, frames, log)
    stages.append(("запись книги (локально)", time.time() - t))
    log("  готово за %.1f с (%.1f МБ)" % (stages[-1][1], os.path.getsize(book) / 2**20))
    written = [(book, a.out_name)]

    if a.csv:
        t = time.time()
        for sheet, df in frames:
            cp = os.path.join(tmpdir, "%s.csv" % sheet)
            df.to_csv(cp, index=False, sep=";", encoding="utf-8-sig")
            written.append((cp, "%s.csv" % sheet))
        stages.append(("запись CSV (локально)", time.time() - t))
        log("  CSV за %.1f с" % stages[-1][1])
        log("  напоминание: Excel при открытии CSV снова разберёт цифры как число")
        log("  и ведущие нули слетят. Для VLOOKUP пользоваться книгой, не CSV.")

    # 3. вернуть результат
    log("")
    log("переношу результат в %s" % a.out_dir)
    t = time.time()
    for src_f, name in written:
        dst = os.path.join(a.out_dir, name)
        shutil.copy2(src_f, dst)
        log("  %s" % dst)
    stages.append(("перенос результата", time.time() - t))

    total = time.time() - t0
    log("")
    log("=" * 64)
    log("ГДЕ УШЛО ВРЕМЯ")
    log("=" * 64)
    net = 0.0
    for name, dt in stages:
        log("  %-38s %7.1f с   %5.1f %%" % (name, dt, 100.0 * dt / total if total else 0))
        if "сетев" in name or "перенос" in name:
            net += dt
    other = max(total - sum(d for _, d in stages), 0.0)
    log("  %-38s %7.1f с   %5.1f %%" % ("прочее (служебное)", other,
                                        100.0 * other / total if total else 0))
    log("  " + "-" * 56)
    log("  %-38s %7.1f с   %5.1f %%" % ("в том числе по сети", net,
                                        100.0 * net / total if total else 0))
    log("")
    log("итого %.1f с (%.1f мин)" % (total, total / 60))

    with open(os.path.join(a.out_dir, "fix_id_columns_log.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    shutil.rmtree(tmpdir, ignore_errors=True)


if __name__ == "__main__":
    main()
