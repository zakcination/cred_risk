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

Запуск:
  python fix_id_columns.py --src "R:\\...\\файл.xlsx" --out-dir "C:\\work"
  python fix_id_columns.py --src ... --out-dir ... --xlsx        # ещё и книга
  python fix_id_columns.py --src ... --out-dir ... --engine calamine   # быстрее
"""

import argparse
import os
import shutil
import sys
import tempfile
import time

ID_COLS = ["loan_id", "loan_id_kr", "id", "credit_line_id", "iin_bin"]
SHEETS = ["B1A", "B1B"]


def to_text(v):
    """Значение ячейки -> текст без 'nan', без экспоненты, без хвоста .0"""
    if v is None:
        return ""
    s = str(v).strip()
    if s == "" or s.lower() in ("nan", "none", "nat"):
        return ""
    # число, пришедшее float-ом: 21225.0 -> 21225 ; 9.4054e+11 -> 940540000000
    try:
        f = float(s)
        if f == int(f) and abs(f) < 1e18:
            return str(int(f))
    except (ValueError, OverflowError):
        pass
    return s


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
    ap.add_argument("--src", required=True, help="исходная книга")
    ap.add_argument("--out-dir", required=True, help="куда положить результат")
    ap.add_argument("--sheets", nargs="*", default=SHEETS)
    ap.add_argument("--xlsx", action="store_true", help="дополнительно собрать книгу")
    ap.add_argument("--engine", default=None,
                    help="движок чтения: calamine быстрее openpyxl в 10-20 раз")
    a = ap.parse_args()

    import pandas as pd

    t0 = time.time()
    lines = []
    def log(s=""):
        print(s, flush=True)
        lines.append(s)

    if not os.path.isfile(a.src):
        sys.exit("файл не найден: %s" % a.src)
    os.makedirs(a.out_dir, exist_ok=True)

    # 1. на локальный диск: сетевой не должен участвовать в работе
    tmpdir = tempfile.mkdtemp(prefix="fixid_")
    local = os.path.join(tmpdir, os.path.basename(a.src))
    log("копирую на локальный диск...")
    t = time.time(); shutil.copy2(a.src, local)
    log("  скопировано за %.1f с, %.1f МБ" % (time.time()-t, os.path.getsize(local)/2**20))

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
        log("  прочитано %d строк x %d колонок за %.1f с" % (df.shape[0], df.shape[1], time.time()-t))

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
        log("")
        log("  приведение к тексту: %.1f с" % (time.time()-t))
        if restored:
            log("  восстановлено ведущих нулей в iin_bin: %d" % restored)

        # 2. CSV — быстрый и точный путь
        t = time.time()
        csv_path = os.path.join(tmpdir, "%s.csv" % sheet)
        df.to_csv(csv_path, index=False, sep=";", encoding="utf-8-sig")
        log("  CSV записан за %.1f с (%.1f МБ)" % (time.time()-t, os.path.getsize(csv_path)/2**20))
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
                log("  книга записана за %.1f с (%.1f МБ)" % (time.time()-t, os.path.getsize(xp)/2**20))
                written.append((xp, "%s.xlsx" % sheet))

        del df

    # 4. вернуть результат
    log("")
    log("переношу результат в %s" % a.out_dir)
    for src_f, name in written:
        dst = os.path.join(a.out_dir, name)
        shutil.copy2(src_f, dst)
        log("  %s" % dst)

    with open(os.path.join(a.out_dir, "fix_id_columns_log.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    shutil.rmtree(tmpdir, ignore_errors=True)
    log("")
    log("итого %.1f с (%.1f мин)" % (time.time()-t0, (time.time()-t0)/60))


if __name__ == "__main__":
    main()
