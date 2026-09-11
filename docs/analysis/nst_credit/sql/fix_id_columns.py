# -*- coding: utf-8 -*-
"""Приведение идентификаторов B1A/B1B к тексту без потери значений.

ЧТО БЫЛО НЕ ТАК В ПРЕЖНЕЙ ВЕРСИИ
------------------------------------------------------------------------------
1. openpyxl писал 548 тыс. строк по ячейке — около 22 млн объектов Cell.
   Это десятки минут и много гигабайт памяти; на практике упирается в своп.
2. mode='a' грузит всю книгу в память перед дописыванием.
3. Блок wb.remove(...) + wb.close() без wb.save() ничего не сохранял — изменения
   отбрасывались. Книга грузилась дважды, первый раз впустую.
4. Работа велась прямо на сетевом диске: файл в сотню мегабайт ходил по SMB
   несколько раз.
5. .astype(str) на пустых ячейках давал строку 'nan', а iin_bin через
   to_numeric(errors='coerce').fillna(0) превращал нечисловой БИН
   в 000000000000, неотличимый от настоящего.

ЧЕГО ЭТОТ СКРИПТ СДЕЛАТЬ НЕ МОЖЕТ
------------------------------------------------------------------------------
Восстановить ведущие нули, которых в книге уже нет. Если идентификатор лежит
числом, нули потеряны при выгрузке из базы — чинить надо экспорт, а не результат.
Поэтому первым делом печатается диагностика: в каком виде значения лежат
в источнике. Без неё «починенный» файл может по-прежнему не соединяться
по трети ключей.

ПОРЯДОК РАБОТЫ
------------------------------------------------------------------------------
  1. копия с сетевого диска на локальный — вся работа локально;
  2. чтение с dtype=str и keep_default_na=False: ничего не парсится в число,
     пустое остаётся пустым;
  3. диагностика по каждой колонке-идентификатору;
  4. запись. По умолчанию CSV — секунды вместо часов и точное сохранение текста.
     --xlsx включает запись книги через xlsxwriter в постоянной памяти;
  5. возврат результата на сетевой диск.

Сеть участвует ровно в двух шагах — 1 и 5, по одному проходу каждый.
Шаги 2-4 идут на локальном диске. В конце печатается таблица «где ушло время»
с отдельной строкой «в том числе по сети»: она и отвечает, диск ли узкое место.

Рабочая папка берётся из %TEMP%, и её тип диска проверяется: в корпоративной
среде %TEMP% нередко лежит в перемещаемом профиле, и тогда «локальная работа»
молча идёт по SMB. Если так — скрипт предупреждает, задать явно: --work-dir.

Запуск (без аргументов берётся тот же путь, что у nst_fill_2026.py):
  python fix_id_columns.py
  python fix_id_columns.py --work-dir C:\\work        # если %TEMP% на сети
  python fix_id_columns.py --out-dir C:\\work         # результат локально
  python fix_id_columns.py --engine calamine        # если долго идёт чтение
  python fix_id_columns.py --xlsx                   # ещё и книга
"""

import argparse
import os
import shutil
import sys
import tempfile
import time

ID_COLS = ["loan_id", "loan_id_kr", "id", "credit_line_id", "iin_bin"]
SHEETS = ["B1A", "B1B"]

# Путь по умолчанию — тот же, что у nst_fill_2026.py. Скрипт запускается
# без аргументов; --src нужен только для копии файла или другого периода.
SRC_DEFAULT = (
    r"R:\!!!!!НСТ2026\Сегментация\Предварительная"
    r"\B1A_B1B_01012026_сегментация НСТ_предварит.xlsx"
)

DRIVE_TYPE = {0: "неизвестен", 1: "корня нет", 2: "съёмный",
              3: "локальный", 4: "СЕТЕВОЙ", 5: "CD", 6: "RAM-диск"}


def drive_kind(path):
    """Локальный диск или сетевой. Нужно, чтобы рабочая папка не оказалась
    на сетевом диске молча: в корпоративной среде %TEMP% нередко лежит
    в перемещаемом профиле, и тогда «локальная работа» идёт по SMB."""
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
    """Значение ячейки -> текст без 'nan', без экспоненты, без хвоста .0

    Порядок проверок здесь важнее их состава. Строка из одних цифр
    возвращается КАК ЕСТЬ и раньше всего остального: '0001234567890' — это
    идентификатор, уже лежащий текстом, и его ведущие нули уцелели при
    выгрузке. Прогонять его через float значит сделать ровно то, ради
    предотвращения чего скрипт написан: float('0001234567890') = 1234567890.0,
    и три нуля исчезают на постобработке, а не на выгрузке.

    Через float проходит только то, что пришло числом и потому уже содержит
    признак числа — точку или экспоненту: 21225.0 -> 21225,
    9.4054e+11 -> 940540000000.
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


# Ловушки, на которых скрипт проверяется. Список ведётся: каждый случай,
# на котором он однажды ошибся, остаётся здесь навсегда.
SELFTEST = [
    # (вход,                 ожидание,          почему)
    (15222.0,                "15222",           "число float-ом — хвост .0 убрать"),
    ("15222.0",              "15222",           "то же строкой"),
    (9.4054e+11,             "940540000000",    "экспонента — развернуть"),
    ("0001234567890",        "0001234567890",   "текст из цифр — НЕ трогать, нули уцелели"),
    ("00015222",             "00015222",        "то же, короткое"),
    ("070640010774",         "070640010774",    "БИН текстом — оставить как есть"),
    (None,                   "",                "пусто"),
    ("",                     "",                "пусто"),
    ("nan",                  "",                "литерал 'nan' от .astype(str)"),
    ("NaT",                  "",                "литерал 'NaT'"),
    ("F06/73-76-КБ/2016",    "F06/73-76-КБ/2016", "нечисловой идентификатор"),
    ("не БИН",               "не БИН",          "мусор не превращать в 000000000000"),
]


def selftest():
    bad = 0
    for src, want, why in SELFTEST:
        got = to_text(src)
        ok = got == want
        bad += not ok
        print("  %s %-22r -> %-22r %s" % ("ok  " if ok else "СБОЙ",
                                          src, got,
                                          why if ok else "ОЖИДАЛОСЬ %r" % want))
    print("")
    print("проверок %d, сбоев %d" % (len(SELFTEST), bad))
    return 1 if bad else 0


def diagnose(df, sheet, log):
    log("")
    log("--- %s: в каком виде лежат идентификаторы ---" % sheet)
    for col in ID_COLS:
        if col not in df.columns:
            log("  %-16s колонки нет" % col)
            continue
        vals = df[col]
        n = len(vals)
        empty = int((vals == "").sum())
        nonempty = vals[vals != ""]
        if len(nonempty) == 0:
            log("  %-16s пусто во всех %d строках" % (col, n))
            continue
        lead0 = int(nonempty.str.startswith("0").sum())
        numeric = int(nonempty.str.fullmatch(r"\d+").sum())
        lens = nonempty.str.len()
        log("  %-16s непусто %7d | пусто %7d | с ведущим нулём %7d | только цифры %7d | длина %d..%d"
            % (col, len(nonempty), empty, lead0, numeric, lens.min(), lens.max()))

        if col == "iin_bin":
            # БИН и ИИН по закону всегда 12 знаков. Значение короче 12 при
            # полностью числовом составе — потерянный ведущий ноль, и он
            # восстанавливается однозначно. Это единственная колонка, где так можно.
            short = nonempty[(lens < 12) & nonempty.str.fullmatch(r"\d+")]
            if len(short):
                log("      ПОТЕРЯННЫЕ НУЛИ: %d значений короче 12 знаков при числовом составе."
                    % len(short))
                log("      Для БИН/ИИН длина фиксирована законом — восстанавливаются дополнением слева.")
            long_ = nonempty[lens > 12]
            if len(long_):
                log("      ВНИМАНИЕ: %d значений длиннее 12 знаков — это не БИН и не ИИН." % len(long_))
        elif lead0 == 0 and numeric == len(nonempty):
            log("      ВНИМАНИЕ: ни одного значения с ведущим нулём при полностью числовом составе.")
            log("      Длина здесь не фиксирована, поэтому восстановить нули нельзя:")
            log("      сколько их было, из этого файла не следует. Чинить надо выгрузку из базы.")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=SRC_DEFAULT, help="исходная книга")
    ap.add_argument("--out-dir", default=None,
                    help="куда положить результат; по умолчанию папка источника")
    ap.add_argument("--work-dir", default=None,
                    help="рабочая папка для локальной копии; по умолчанию %TEMP%. "
                         "Указать явно, если %TEMP% лежит в перемещаемом профиле")
    ap.add_argument("--sheets", nargs="*", default=SHEETS)
    ap.add_argument("--xlsx", action="store_true", help="дополнительно собрать книгу")
    ap.add_argument("--engine", default=None,
                    help="движок чтения: calamine быстрее openpyxl в 10-20 раз")
    ap.add_argument("--selftest", action="store_true",
                    help="проверить to_text на известных ловушках и выйти")
    a = ap.parse_args()
    if a.selftest:
        sys.exit(selftest())
    if a.out_dir is None:
        a.out_dir = os.path.dirname(os.path.abspath(a.src))

    t0 = time.time()
    import pandas as pd
    t_import = time.time() - t0
    lines = []
    def log(s=""):
        print(s, flush=True)
        lines.append(s)

    if not os.path.isfile(a.src):
        sys.exit("файл не найден: %s" % a.src)
    os.makedirs(a.out_dir, exist_ok=True)

    # 1. на локальный диск: сетевой не должен участвовать в работе
    if a.work_dir:
        os.makedirs(a.work_dir, exist_ok=True)
    tmpdir = tempfile.mkdtemp(prefix="fixid_", dir=a.work_dir)

    kind_src = drive_kind(a.src)
    kind_work = drive_kind(tmpdir)
    log("источник      : %s   [%s]" % (a.src, kind_src))
    log("рабочая папка : %s   [%s]" % (tmpdir, kind_work))
    log("результат     : %s   [%s]" % (a.out_dir, drive_kind(a.out_dir)))
    if "СЕТЕВОЙ" in kind_work:
        log("")
        log("  ВНИМАНИЕ: рабочая папка сама на сетевом диске — копия на локальный")
        log("  диск не состоялась, и весь выигрыш от неё пропадает. Задайте")
        log("  --work-dir на локальном диске, например --work-dir C:\\work")
    log("")

    local = os.path.join(tmpdir, os.path.basename(a.src))
    log("копирую на локальный диск...")
    t = time.time(); shutil.copy2(a.src, local)
    t_copy_in = time.time() - t
    mb = os.path.getsize(local) / 2**20
    rate = ("%.1f МБ/с" % (mb / t_copy_in)) if t_copy_in > 0.05 else "быстрее, чем измеримо"
    log("  скопировано за %.1f с, %.1f МБ (%s)" % (t_copy_in, mb, rate))
    stages = [("импорт pandas", t_import),
              ("копирование с сетевого диска", t_copy_in)]

    kw = dict(dtype=str, keep_default_na=False, na_filter=False)
    if a.engine:
        kw["engine"] = a.engine

    written = []
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
        log("  прочитано %d строк x %d колонок за %.1f с" % (df.shape[0], df.shape[1], dt))

        diagnose(df, sheet, log)

        t = time.time()
        for col in ID_COLS:
            if col in df.columns:
                df[col] = df[col].map(to_text)
        # восстановление ведущих нулей — только для БИН/ИИН, где длина задана законом
        restored = 0
        if "iin_bin" in df.columns:
            m = df["iin_bin"].str.fullmatch(r"\d{1,11}").fillna(False)
            restored = int(m.sum())
            if restored:
                df.loc[m, "iin_bin"] = df.loc[m, "iin_bin"].str.zfill(12)
        dt = time.time() - t
        stages.append(("приведение к тексту %s" % sheet, dt))
        log("")
        log("  приведение к тексту: %.1f с" % dt)
        if restored:
            log("  восстановлено ведущих нулей в iin_bin: %d" % restored)

        # 2. CSV — быстрый и точный путь
        t = time.time()
        csv_path = os.path.join(tmpdir, "%s.csv" % sheet)
        df.to_csv(csv_path, index=False, sep=";", encoding="utf-8-sig")
        dt = time.time() - t
        stages.append(("запись CSV %s (локально)" % sheet, dt))
        log("  CSV записан за %.1f с (%.1f МБ)" % (dt, os.path.getsize(csv_path)/2**20))
        written.append((csv_path, "%s.csv" % sheet))

        # 3. книга — только если попросили
        if a.xlsx:
            try:
                import xlsxwriter  # noqa: F401
            except ImportError:
                log("  xlsxwriter не установлен, книга не собрана: pip install xlsxwriter")
            else:
                t = time.time()
                xp = os.path.join(tmpdir, "%s.xlsx" % sheet)
                with pd.ExcelWriter(xp, engine="xlsxwriter",
                                    engine_kwargs={"options": {"constant_memory": True,
                                                               "strings_to_numbers": False}}) as w:
                    df.to_excel(w, sheet_name=sheet, index=False)
                dt = time.time() - t
                stages.append(("запись книги %s (локально)" % sheet, dt))
                log("  книга записана за %.1f с (%.1f МБ)" % (dt, os.path.getsize(xp)/2**20))
                written.append((xp, "%s.xlsx" % sheet))

        del df

    # 4. вернуть результат
    log("")
    log("переношу результат в %s" % a.out_dir)
    t = time.time()
    for src_f, name in written:
        dst = os.path.join(a.out_dir, name)
        shutil.copy2(src_f, dst)
        log("  %s" % dst)
    stages.append(("перенос результата", time.time() - t))

    with open(os.path.join(a.out_dir, "fix_id_columns_log.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    shutil.rmtree(tmpdir, ignore_errors=True)
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
    log("  %-38s %7.1f с   %5.1f %%" % ("прочее (служебное)",
                                        max(total - sum(d for _, d in stages), 0.0),
                                        100.0 * max(total - sum(d for _, d in stages), 0.0) / total if total else 0))
    log("  " + "-" * 56)
    log("  %-38s %7.1f с   %5.1f %%" % ("в том числе по сети", net,
                                        100.0 * net / total if total else 0))
    log("")
    log("  Если доля «по сети» мала, а долго идёт чтение — узкое место не диск,")
    log("  а разбор книги: пробуйте --engine calamine.")
    log("")
    log("итого %.1f с (%.1f мин)" % (total, total / 60))


if __name__ == "__main__":
    main()
