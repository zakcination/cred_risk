#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Расчётный лист по топ-20: каждое опубликованное число — живой формулой Excel.

Назначение одно: защитить числа § 11.10 `DECOMPOSITION.md` и `DISCLOSURE.md`
на комитете, в самом Excel, без обращения к python. Поэтому в книге нет ни одного
посчитанного заранее значения — только ряд, параметры и формулы поверх них.

    python3 raschet_list.py            # собрать книгу
    python3 raschet_list.py --verify   # вычислить формулы книги и сверить каждое
                                       # число с опубликованным (нужен `formulas`)

Сверка обязательна: формула, набранная руками, может разойтись с той, что описана
словами, и увидеть это можно только вычислением. Допуск — половина последнего
напечатанного разряда, как в `calib/top20_disclosure.py --selftest`.

Сверка считает не «то же самое на python», а сами формулы листа — иначе проверялась
бы вторая реализация, а не книга. Первая версия делала это прогоном LibreOffice;
в контейнере сессии soffice не открывает даже пустую книгу («source file could not
be loaded»), поэтому путь заменён на движок `formulas`.

Две ошибки, которые эта сверка уже поймала и которые глазами не видны:
имена `z90` и `kG26` оказались синтаксически допустимыми адресами ячеек (Z90, KG26) —
Excel такие имена не создаёт, и формулы читали бы пустые ячейки вместо параметров;
лист «Три сигмы» ссылался на строку заголовка блока вместо строки σ.
"""

import csv
import os
import sys

from openpyxl import Workbook
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from openpyxl.utils import get_column_letter
from openpyxl.workbook.defined_name import DefinedName

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "..", "data", "top20_monthly_2023_08_2026_07.csv")
OUT = os.path.join(HERE, "..", "out", "Raschetny_list_RA_top20_v1.0.xlsx")

# ── оформление ────────────────────────────────────────────────────────────
INK = "FF0B0B0B"
MUTED = "FF6B6A66"
HEAD_BG = "FFEDEBE3"
BLOCK_BG = "FFF6F5F0"
WARN_BG = "FFFFF4D6"
THIN = Side(style="thin", color="FFD8D6CC")
BOX = Border(left=THIN, right=THIN, top=THIN, bottom=THIN)

F_TITLE = Font(name="Calibri", size=14, bold=True, color=INK)
F_HEAD = Font(name="Calibri", size=10, bold=True, color=INK)
F_BLOCK = Font(name="Calibri", size=11, bold=True, color=INK)
F_BODY = Font(name="Calibri", size=10, color=INK)
F_MUTED = Font(name="Calibri", size=9, color=MUTED)
F_MONO = Font(name="Consolas", size=9, color=MUTED)
WRAP = Alignment(wrap_text=True, vertical="top")
TOP = Alignment(vertical="top")


def load_rows():
    with open(DATA, encoding="utf-8") as fh:
        return list(csv.DictReader(fh, delimiter=";"))


def put(ws, cell, value, font=F_BODY, fmt=None, align=TOP, fill=None, border=False):
    c = ws[cell]
    c.value = value
    c.font = font
    c.alignment = align
    if fmt:
        c.number_format = fmt
    if fill:
        c.fill = PatternFill("solid", fgColor=fill)
    if border:
        c.border = BOX
    return c


# ── лист «Ряд» ────────────────────────────────────────────────────────────
def sheet_series(wb, rows):
    """Исходный ряд и всё, что считается построчно. Ничего агрегированного."""
    ws = wb.create_sheet("Ряд")
    put(ws, "A1", "Ряд топ-20: 36 месячных точек, 01.08.2023 — 01.07.2026", F_TITLE)
    put(ws, "A2", "Источник: data/top20_monthly_2023_08_2026_07.csv, дамп листа "
                  "Monthly рабочей книги 08.09.2026 (DECOMPOSITION § 11.7). "
                  "Колонки A–D — как в выгрузке, E–K — расчёт.", F_MUTED, align=WRAP)
    ws.merge_cells("A2:K2")
    ws.row_dimensions[2].height = 28

    heads = [
        ("A", "Дата", 12),
        ("B", "Займ топ-20, млн ₸", 16),
        ("C", "СК балансовый, млн ₸", 17),
        ("D", "coef_new (доля)", 14),
        ("E", "v = coef_new × 100", 15),
        ("F", "Δ = v(t) − v(t−1)", 15),
        ("G", "ΔСК, %", 10),
        ("H", "ΔЗайм, %", 11),
        ("I", "В базе метода B", 13),
        ("J", "Δ для метода B", 14),
        ("K", "Триггер", 13),
    ]
    for col, title, width in heads:
        put(ws, f"{col}4", title, F_HEAD, align=Alignment(wrap_text=True, vertical="bottom"),
            fill=HEAD_BG, border=True)
        ws.column_dimensions[col].width = width
    ws.row_dimensions[4].height = 30

    first, last = 5, 5 + len(rows) - 1
    max_v_row = None
    best = None
    for i, r in enumerate(rows):
        rr = first + i
        put(ws, f"A{rr}", r["date"], F_BODY, border=True)
        put(ws, f"B{rr}", float(r["zaim_mln"]), F_BODY, "#,##0.0", border=True)
        put(ws, f"C{rr}", float(r["sk_new_mln"]), F_BODY, "#,##0.0", border=True)
        put(ws, f"D{rr}", float(r["coef_new"]), F_BODY, "0.00000000", border=True)
        put(ws, f"E{rr}", f"=D{rr}*100", F_BODY, "0.0000", border=True)
        cv = float(r["coef_new"]) * 100.0
        if best is None or cv > best:
            best, max_v_row = cv, rr
        if i == 0:
            for col in ("F", "G", "H", "J", "K"):
                put(ws, f"{col}{rr}", "—", F_MUTED, border=True)
            put(ws, f"I{rr}", "—", F_MUTED, border=True)
            continue
        p = rr - 1
        put(ws, f"F{rr}", f"=E{rr}-E{p}", F_BODY, "0.0000", border=True)
        put(ws, f"G{rr}", f"=(C{rr}-C{p})/C{p}*100", F_BODY, "0.00", border=True)
        put(ws, f"H{rr}", f"=(B{rr}-B{p})/B{p}*100", F_BODY, "0.00", border=True)
        put(ws, f"J{rr}", f'=IF(I{rr}=1,F{rr},"")', F_BODY, "0.0000", border=True)
        put(ws, f"K{rr}",
            f'=IF(AND(G{rr}<=-3,H{rr}>=5),"оба",IF(G{rr}<=-3,"СК",IF(H{rr}>=5,"Займ","")))',
            F_BODY, border=True)

    # Метод B исключает два прироста, примыкающих к выбросу: вход в него и выход.
    excl = {max_v_row, max_v_row + 1}
    for rr in range(first + 1, last + 1):
        flag = 0 if rr in excl else 1
        c = put(ws, f"I{rr}", flag, F_BODY, "0", border=True)
        if flag == 0:
            c.fill = PatternFill("solid", fgColor=WARN_BG)

    note = last + 2
    put(ws, f"A{note}",
        "Колонка I — база метода B. Ноль стоит у двух приростов, примыкающих к максимуму "
        f"ряда ({rows[max_v_row - first]['date']}): вход в выброс и выход из него. "
        "Это определение восстановлено обратным счётом от опубликованных 113,17 и в тексте "
        "методов не приведено — см. DISCLOSURE.md, Р-Д1. Колонка J гасит эти два значения, "
        "поэтому STDEVP по ней считает σ метода B, а STDEV по F — σ методов D и H.",
        F_MUTED, align=WRAP)
    ws.merge_cells(f"A{note}:K{note}")
    ws.row_dimensions[note].height = 58
    ws.freeze_panes = "A5"
    return first, last, max_v_row


# ── лист «Параметры» ──────────────────────────────────────────────────────
def sheet_params(wb):
    ws = wb.create_sheet("Параметры")
    put(ws, "A1", "Параметры расчёта", F_TITLE)
    put(ws, "A2", "Всё, что не выводится из ряда. Меняется здесь — пересчитывается везде.",
        F_MUTED)
    for col, w in (("A", 26), ("B", 30), ("C", 14), ("D", 62)):
        ws.column_dimensions[col].width = w
    for col, title in (("A", "Параметр"), ("B", "Обозначение"),
                       ("C", "Значение"), ("D", "Откуда")):
        put(ws, f"{col}4", title, F_HEAD, fill=HEAD_BG, border=True)

    params = [
        ("Квантиль нормального для 0,90", "z(0,90)", 1.2815515655446004, "0.000000",
         "Стандартное нормальное распределение. Проверка в самом Excel: "
         "=NORMSINV(0,9) даёт то же число"),
        ("Отношение баз капитала", "k (Г26)", 0.87453, "0.00000",
         "E_балансовый / E_регуляторный на 01.01.2026. Находка Г26: с 01.01.2026 "
         "знаменатель метрики сменил базу, уровень при этом не пересматривался"),
        ("Уровень в регуляторной базе", "L_рег", 95.0, "0.00",
         "Действующий уровень риск-аппетита по топ-20. Приложение № 3 к Политике "
         "(VND-02). История уровня: 250 % → 95 %, см. data/top20_limit_history.csv"),
        ("Длина цикла реагирования, мес.", "T", 3, "0",
         "ДОПУЩЕНИЕ, не измеренная величина. Пока длина цикла не закреплена "
         "в регламенте, метод H держится на ней со слов — DISCLOSURE § 6"),
        ("Порог триггера по капиталу, %", "порог ΔСК", -3.0, "0.0",
         "Месячное падение СК, при котором наблюдение ускоряется независимо от зоны"),
        ("Порог триггера по портфелю, %", "порог ΔЗайм", 5.0, "0.0",
         "Месячный рост задолженности топ-20, при котором наблюдение ускоряется"),
    ]
    r = 5
    for name, sign, val, fmt, src in params:
        put(ws, f"A{r}", name, F_BODY, align=WRAP, border=True)
        put(ws, f"B{r}", sign, F_BODY, border=True)
        put(ws, f"C{r}", val, F_BLOCK, fmt, border=True)
        put(ws, f"D{r}", src, F_MUTED, align=WRAP, border=True)
        ws.row_dimensions[r].height = 30
        r += 1

    warn = r + 1
    put(ws, f"A{warn}",
        "T = 3 — единственный параметр здесь, у которого нет внешнего источника. "
        "Если на комитете спросят «почему три месяца», честный ответ: длина цикла "
        "решения не измерена, и это записано как незакрытый пункт. Поставьте другое "
        "число в C8 — вся книга пересчитается, и станет видно, что уровень от этого "
        "меняется на 1,4–1,5 пп за каждый месяц цикла.", F_MUTED, align=WRAP)
    ws.merge_cells(f"A{warn}:D{warn}")
    ws.row_dimensions[warn].height = 58
    return {"z_90": "C5", "k_G26": "C6", "L_reg": "C7", "T_cikl": "C8",
            "por_sk": "C9", "por_zaim": "C10"}


# ── лист «Расчёт» ─────────────────────────────────────────────────────────
def sheet_calc(wb, first, last):
    """Каждая строка: словами — формулой — значением — опубликованным — расхождением."""
    ws = wb.create_sheet("Расчёт")
    put(ws, "A1", "Расчётный лист: формула, вход, результат", F_TITLE)
    put(ws, "A2",
        "Колонка D считается формулой из листов «Ряд» и «Параметры». Колонка E — то, что "
        "напечатано в DECOMPOSITION § 11.10 и DISCLOSURE § 2. Колонка G должна быть «да» "
        "во всех строках: иначе опубликованное число разошлось с расчётом.",
        F_MUTED, align=WRAP)
    ws.merge_cells("A2:H2")
    ws.row_dimensions[2].height = 30

    for col, w in (("A", 38), ("B", 46), ("C", 40), ("D", 13),
                   ("E", 13), ("F", 12), ("G", 10), ("H", 22)):
        ws.column_dimensions[col].width = w
    heads = ("Показатель", "Формула словами", "Формула в этой книге", "Значение",
             "Опубликовано", "Расхождение", "Сходится", "Где напечатано")
    for i, t in enumerate(heads):
        put(ws, f"{get_column_letter(i + 1)}4", t, F_HEAD, fill=HEAD_BG, border=True,
            align=Alignment(wrap_text=True, vertical="bottom"))
    ws.row_dimensions[4].height = 30

    rows_out = []          # (row, tolerance) для сверки
    anchors = {}
    r = [5]

    def block(title):
        put(ws, f"A{r[0]}", title, F_BLOCK, fill=BLOCK_BG)
        for c in "BCDEFGH":
            put(ws, f"{c}{r[0]}", None, fill=BLOCK_BG)
        r[0] += 1

    def line(key, label, words, formula, published, fmt, where, tol=None):
        rr = r[0]
        put(ws, f"A{rr}", label, F_BODY, align=WRAP, border=True)
        put(ws, f"B{rr}", words, F_BODY, align=WRAP, border=True)
        put(ws, f"C{rr}", formula, F_MONO, align=WRAP, border=True)
        put(ws, f"D{rr}", "=" + formula, F_BLOCK, fmt, border=True)
        put(ws, f"E{rr}", published, F_BODY, fmt, border=True)
        put(ws, f"F{rr}", f"=D{rr}-E{rr}", F_BODY, "0.000000", border=True)
        dec = fmt.split(".")[1].count("0") if "." in fmt else 0
        t = tol if tol is not None else 0.5 * 10 ** (-dec) + 1e-12
        tol_txt = f"{t:.10f}".rstrip("0")
        put(ws, f"G{rr}", f'=IF(ABS(F{rr})<={tol_txt},"да","НЕТ")', F_BODY, border=True,
            align=Alignment(horizontal="center", vertical="top"))
        put(ws, f"H{rr}", where, F_MUTED, align=WRAP, border=True)
        ws.row_dimensions[rr].height = 30
        rows_out.append((rr, t))
        if key:
            anchors[key] = f"D{rr}"
        r[0] += 1

    # ── база
    block("1. База: что даёт сам ряд")
    line("sigma_d", "σ_Δ — с.к.о. месячных приростов",
         "выборочное с.к.о. (n−1) по всем 35 приростам",
         "STDEV(d)", 4.0667, "0.0000", "DISCLOSURE § 2.1")
    line("sigma_B", "σ метода B",
         "популяционное с.к.о. приростов без двух, примыкающих к выбросу 01.2024",
         "STDEVP(dB)", 3.6326, "0.0000", "DISCLOSURE Р-Д1")
    line("sigma_lvl", "σ уровней (метод М1)",
         "выборочное с.к.о. самих значений ряда, не приростов",
         "STDEV(v)", 6.2201, "0.0000", "DISCLOSURE Р-Д1")
    line("v_last", "Текущая точка, 01.07.2026", "последнее значение ряда",
         f"'Ряд'!E{last}", 101.5041, "0.0000", "DISCLOSURE § 2.1")
    line("v_max", "Максимум ряда, 01.2024", "наибольшее значение ряда",
         "MAX(v)", 105.9003, "0.0000", "DISCLOSURE § 2.1")
    line(None, "Число точек", "сколько наблюдений в ряде", "COUNT(v)", 36, "0",
         "DISCLOSURE § 1")

    # ── уровень
    block("2. Уровень")
    line("L", "L — уровень в балансовой базе",
         "действующий уровень 95 %, пересчитанный под балансовый капитал: L_рег / k",
         "L_reg/k_G26", 108.6298, "0.0000", "DISCLOSURE § 2.2")
    put(ws, f"A{r[0]}",
        "Это одна величина в двух системах измерения, а не два разных лимита. "
        "Фраза «пробит лимит 95 % по балансовому капиталу» — категориальная ошибка: "
        "числитель берётся из одной базы, знаменатель из другой.",
        F_MUTED, align=WRAP)
    ws.merge_cells(f"A{r[0]}:H{r[0]}")
    ws.row_dimensions[r[0]].height = 30
    r[0] += 1

    # ── запас и жёлтая линия
    block("3. Запас на реагирование M(T) = z(0,90) · σ_Δ · √T и жёлтая линия L − M(T)")
    pub_m = {1: 5.2117, 2: 7.3705, 3: 9.0270, 4: 10.4235}
    pub_y = {1: 103.4180, 2: 101.2593, 3: 99.6028, 4: 98.2063}
    pub_s = {1: 2.8, 2: 5.6, 3: 11.1, 4: 16.7}
    pub_n = {1: 1, 2: 2, 3: 4, 4: 6}
    for T in (1, 2, 3, 4):
        line(f"M{T}", f"Запас M(T) при T = {T}", "z(0,90) × σ_Δ × корень из T",
             f"z_90*{anchors['sigma_d']}*SQRT({T})", pub_m[T], "0.0000",
             "DISCLOSURE § 2.3")
        line(f"Y{T}", f"Жёлтая линия при T = {T}", "L − M(T)",
             f"{anchors['L']}-{anchors[f'M{T}']}", pub_y[T], "0.0000",
             "DISCLOSURE § 2.3")
        line(None, f"Наблюдений выше жёлтой, T = {T}",
             "сколько точек ряда не ниже жёлтой линии",
             f'COUNTIF(v,">="&{anchors[f"Y{T}"]})', pub_n[T], "0",
             "DISCLOSURE § 2.3, Р-Д3")
        line(None, f"Доля времени выше жёлтой, T = {T}", "их доля от 36 наблюдений",
             f'COUNTIF(v,">="&{anchors[f"Y{T}"]})/COUNT(v)*100', pub_s[T], "0.0",
             "DISCLOSURE § 2.3, Р-Д3")
    put(ws, f"A{r[0]}",
        "Р-Д3: доля в процентах от 36 наблюдений читается точнее, чем есть. "
        "2,8 % — это одно наблюдение, 11,1 % — четыре. На комитете доля называется "
        "только вместе с числом наблюдений, поэтому строка «Наблюдений» стоит выше "
        "строки «Доля», а не под ней.", F_MUTED, align=WRAP)
    ws.merge_cells(f"A{r[0]}:H{r[0]}")
    ws.row_dimensions[r[0]].height = 30
    r[0] += 1

    # ── квантили
    block("4. Квантили ряда (метод C). Линейная интерполяция между порядковыми статистиками")
    for p, pub in ((85, 98.1887), (90, 99.5485), (95, 101.0117)):
        line(f"q{p}", f"Квантиль {p} %", f"значение, ниже которого лежит {p} % ряда",
             f"PERCENTILE(v,0.{p})", pub, "0.0000", "DISCLOSURE § 2.5")

    # ── два пути
    block("5. Два независимых пути к одному уровню")
    line("H3", "Метод H: квантиль 90 % + запас T = 3", "квантиль₉₀(v) + M(3)",
         f"{anchors['q90']}+{anchors['M3']}", 108.5755, "0.0000", "DISCLOSURE § 2.4")
    line(None, "Расхождение двух путей", "L (пересчёт базы) − H (цикл решения)",
         f"{anchors['L']}-{anchors['H3']}", 0.0543, "0.0000", "DISCLOSURE § 2.4")
    put(ws, f"A{r[0]}",
        "Главный довод против упрёка «уровень подогнан под факт»: пути не связаны "
        "по построению. Первый смотрит на отношение баз капитала, второй — на "
        "распределение ряда и длину процесса. Сходятся на 0,05 пп.", F_MUTED, align=WRAP)
    ws.merge_cells(f"A{r[0]}:H{r[0]}")
    ws.row_dimensions[r[0]].height = 30
    r[0] += 1

    # ── производные
    block("6. Производные метрики")
    line(None, "D — расстояние до L, в σ", "(L − текущая точка) / σ_Δ",
         f"({anchors['L']}-{anchors['v_last']})/{anchors['sigma_d']}", 1.752, "0.000",
         "DISCLOSURE § 2.6")
    line(None, "D при сохранении L = 95", "(95 − текущая точка) / σ_Δ",
         f"(L_reg-{anchors['v_last']})/{anchors['sigma_d']}", -1.599, "0.000",
         "DISCLOSURE § 2.6")
    line(None, "F — падение СК до достижения L, %", "текущая точка / L − 1, в процентах",
         f"({anchors['v_last']}/{anchors['L']}-1)*100", -6.56, "0.00",
         "DISCLOSURE § 2.6")
    line(None, "Метод B: максимум + 2σ_B", "max(v) + 2 × σ метода B",
         f"{anchors['v_max']}+2*{anchors['sigma_B']}", 113.1655, "0.0000",
         "DISCLOSURE Р-Д1")

    # ── цена решения «не трогаем»
    block("7. Цена решения «уровень не трогаем»: обратный счёт при L = 95")
    line("Y95", "Жёлтая линия при L = 95", "95 − M(3)",
         f"L_reg-{anchors['M3']}", 85.9730, "0.0000", "DISCLOSURE § 2.6")
    line(None, "Наблюдений выше неё", "сколько точек ряда не ниже 85,97",
         f'COUNTIF(v,">="&{anchors["Y95"]})', 31, "0", "DISCLOSURE § 2.6")
    line(None, "Доля времени выше неё", "их доля от 36 наблюдений",
         f'COUNTIF(v,">="&{anchors["Y95"]})/COUNT(v)*100', 86.1, "0.0",
         "DISCLOSURE § 2.6")
    put(ws, f"A{r[0]}",
        "31 наблюдение из 36 — это светофор с постоянно горящей жёлтой лампой. "
        "Именно это число отвечает на предложение «оставить 95 % и ничего не менять».",
        F_MUTED, align=WRAP)
    ws.merge_cells(f"A{r[0]}:H{r[0]}")
    ws.row_dimensions[r[0]].height = 28
    r[0] += 1

    # ── итог сверки
    r[0] += 1
    total = r[0]
    lo, hi = rows_out[0][0], rows_out[-1][0]
    put(ws, f"A{total}", "Строк не сошлось", F_BLOCK, fill=BLOCK_BG, border=True)
    put(ws, f"B{total}", f'=COUNTIF(G{lo}:G{hi},"НЕТ")', F_BLOCK, "0", fill=BLOCK_BG,
        border=True)
    put(ws, f"C{total}",
        "Ноль означает: все опубликованные числа воспроизводятся формулами этой книги. "
        "Это не означает, что формулы верны по существу — воспроизводимость и "
        "правильность разные вещи.", F_MUTED, align=WRAP, fill=BLOCK_BG, border=True)
    ws.merge_cells(f"C{total}:H{total}")
    ws.row_dimensions[total].height = 32
    ws.freeze_panes = "A5"
    return rows_out, anchors


# ── лист «Три сигмы» ──────────────────────────────────────────────────────
def sheet_sigmas(wb, anchors):
    ws = wb.create_sheet("Три сигмы")
    put(ws, "A1", "Р-Д1: в таблице восьми методов три разные σ", F_TITLE)
    put(ws, "A2",
        "Это первый вопрос, который задаст любой, кто читает таблицу методов внимательно. "
        "Ответ лучше дать самому, до вопроса.", F_MUTED)
    for col, w in (("A", 16), ("B", 46), ("C", 13), ("D", 13), ("E", 56)):
        ws.column_dimensions[col].width = w
    for col, t in (("A", "Методы"), ("B", "Какая σ"), ("C", "Значение"),
                   ("D", "К σ_Δ"), ("E", "Что из этого следует")):
        put(ws, f"{col}4", t, F_HEAD, fill=HEAD_BG, border=True)

    base = f"'Расчёт'!{anchors['sigma_d']}"
    data = [
        ("D, H", "выборочное с.к.о. приростов, все 35",
         f"'Расчёт'!{anchors['sigma_d']}", 4.0667,
         "Базовая. На ней стоят запас M(T) и расстояние D"),
        ("B", "популяционное с.к.о. приростов без двух, примыкающих к выбросу 01.2024",
         f"'Расчёт'!{anchors['sigma_B']}", 3.6326,
         "На 11 % меньше базовой — и метод получает за это более высокую жёлтую линию. "
         "Основание исключать режимный выброс есть, но в тексте методов оно не написано "
         "и восстановлено обратным счётом от опубликованных 113,17"),
        ("М1", "выборочное с.к.о. самих уровней, не приростов",
         f"'Расчёт'!{anchors['sigma_lvl']}", 6.2201,
         "Мера разброса уровня за три года, а не месячного хода. С первыми двумя "
         "несопоставима в принципе"),
    ]
    checks = []
    r = 5
    for meth, what, ref, pub, why in data:
        put(ws, f"A{r}", meth, F_BLOCK, border=True)
        put(ws, f"B{r}", what, F_BODY, align=WRAP, border=True)
        put(ws, f"C{r}", f"={ref}", F_BLOCK, "0.0000", border=True)
        put(ws, f"D{r}", f"=C{r}/{base}", F_BODY, "0.0%", border=True)
        put(ws, f"E{r}", why, F_MUTED, align=WRAP, border=True)
        ws.row_dimensions[r].height = 46
        checks.append(("ТРИ СИГМЫ", f"C{r}", pub, 0.00005))
        r += 1

    r += 1
    put(ws, f"A{r}",
        "Что с этим делать. Либо привести все методы к одной σ, либо назвать σ каждого "
        "прямо в строке таблицы методов. Второе честнее: у метода B есть содержательное "
        "основание исключать режимный выброс — но основание должно быть написано, "
        "а не восстанавливаться обратным счётом. Метод, защищаемый в собственных "
        "терминах, несравним с методом, защищаемым в своих.", F_BODY, align=WRAP)
    ws.merge_cells(f"A{r}:E{r}")
    ws.row_dimensions[r].height = 60
    return checks


# ── лист «Триггеры» ───────────────────────────────────────────────────────
def sheet_triggers(wb, first, last):
    ws = wb.create_sheet("Триггеры")
    put(ws, "A1", "Триггеры на движение: ΔСК ≤ −3 % или ΔЗайм ≥ +5 % за месяц", F_TITLE)
    put(ws, "A2",
        "Срабатывают независимо от зоны. Все 35 приростов показаны целиком — "
        "выборка из шести строк была бы недоказуема: не видно, что остальные 29 "
        "условию не отвечают.", F_MUTED, align=WRAP)
    ws.merge_cells("A2:E2")
    ws.row_dimensions[2].height = 28
    for col, w in (("A", 13), ("B", 12), ("C", 12), ("D", 14), ("E", 14)):
        ws.column_dimensions[col].width = w
    for col, t in (("A", "Дата"), ("B", "ΔСК, %"), ("C", "ΔЗайм, %"),
                   ("D", "Коэффициент"), ("E", "Что сработало")):
        put(ws, f"{col}4", t, F_HEAD, fill=HEAD_BG, border=True)

    r = 5
    for src in range(first + 1, last + 1):
        put(ws, f"A{r}", f"='Ряд'!A{src}", F_BODY, border=True)
        put(ws, f"B{r}", f"='Ряд'!G{src}", F_BODY, "0.00", border=True)
        put(ws, f"C{r}", f"='Ряд'!H{src}", F_BODY, "0.00", border=True)
        put(ws, f"D{r}", f"='Ряд'!E{src}", F_BODY, "0.00", border=True)
        put(ws, f"E{r}", f"='Ряд'!K{src}", F_BODY, border=True)
        r += 1

    tot = r + 1
    put(ws, f"A{tot}", "Сработало", F_BLOCK, fill=BLOCK_BG, border=True)
    rng = f"E5:E{r - 1}"
    put(ws, f"B{tot}",
        f'=COUNTIF({rng},"Займ")+COUNTIF({rng},"СК")+COUNTIF({rng},"оба")',
        F_BLOCK, "0", fill=BLOCK_BG, border=True)
    put(ws, f"C{tot}", f"=B{tot}/{r - 5}*100", F_BLOCK, "0.0", fill=BLOCK_BG, border=True)
    put(ws, f"D{tot}", "из 35 приростов, %", F_MUTED, fill=BLOCK_BG, border=True)

    note = tot + 2
    put(ws, f"A{note}",
        "Строка 01.2026 — та, ради которой триггеры и заводятся: вход сделан капиталом "
        "(ΔСК = −7,92 %), а не портфелем, и уровневая зона его не предупреждала "
        "в принципе. Зона смотрит на значение коэффициента, триггер — на его движение; "
        "это разные инструменты, и один другого не заменяет.", F_BODY, align=WRAP)
    ws.merge_cells(f"A{note}:E{note}")
    ws.row_dimensions[note].height = 58
    ws.freeze_panes = "A5"
    return [("ТРИГГЕРЫ", f"B{tot}", 6, 0.5),
            ("ТРИГГЕРЫ", f"C{tot}", 6 / 35 * 100, 0.05)]


# ── лист «Как защищать» ───────────────────────────────────────────────────
def sheet_guide(wb):
    ws = wb.create_sheet("Как защищать", 0)
    ws.column_dimensions["A"].width = 40
    ws.column_dimensions["B"].width = 104
    put(ws, "A1", "Расчётный лист по топ-20: как им пользоваться на комитете", F_TITLE)
    put(ws, "A2", "Собрано 14.09.2026 из data/top20_monthly_2023_08_2026_07.csv. "
                  "Книга собирается build/raschet_list.py — правки вносятся в скрипт, "
                  "а не в готовый файл.", F_MUTED, align=WRAP)
    ws.merge_cells("A2:B2")
    ws.row_dimensions[2].height = 28

    blocks = [
        ("Что в книге",
         "Лист «Ряд» — 36 точек и всё, что считается построчно. Лист «Параметры» — "
         "четыре входа, которые не выводятся из ряда. Лист «Расчёт» — каждое "
         "опубликованное число живой формулой, рядом напечатанное значение и "
         "расхождение. Лист «Три сигмы» — ответ на самый неудобный вопрос к таблице "
         "методов. Лист «Триггеры» — все 35 приростов, а не выбранные шесть."),
        ("Главное свойство",
         "В книге нет ни одного вбитого руками результата. Любое число на слайде "
         "выделяется в колонке D листа «Расчёт», и в строке формул видно, из чего оно "
         "получено. Если кто-то не согласен с параметром — он меняется на листе "
         "«Параметры», и вся книга пересчитывается при нём."),
        ("Ответ на «откуда 108,63»",
         "Уровень 95 % задан в регуляторной базе капитала. С 01.01.2026 знаменатель "
         "метрики — балансовый капитал (Г26), и k = 0,87453 есть отношение баз. "
         "108,63 — тот же самый уровень, выраженный в новой базе. Второй, независимый "
         "путь: квантиль 90 % ряда плюс запас на три месяца даёт 108,58. Сходимость "
         "двух путей на 0,05 пп и есть довод, что уровень не подогнан."),
        ("Ответ на «почему T = 3»",
         "Честный: длина цикла решения не измерена и в регламенте не закреплена. "
         "Это записано как незакрытый пункт, а не спрятано. Поставьте на листе "
         "«Параметры» T = 2 или T = 4 — видно, что уровень двигается примерно "
         "на 1,4–1,5 пп за месяц цикла, и станет предметен разговор о том, "
         "сколько на самом деле занимает решение."),
        ("Ответ на «а если ничего не менять»",
         "Лист «Расчёт», блок 7. При сохранении уровня 95 % жёлтая линия ложится "
         "на 85,97, и выше неё оказывается 31 наблюдение из 36. Светофор с постоянно "
         "горящей лампой не является системой раннего предупреждения."),
        ("Три места, где книга слаба — сказать самому",
         "Р-Д1: в таблице методов три разные σ, и у метода B определение восстановлено "
         "обратным счётом (лист «Три сигмы»). Р-Д2: ряд обрывается на 01.07.2026, "
         "то есть на дату записки 30.09 факт отстаёт на три месяца. Р-Д3: доля времени "
         "в процентах от 36 наблюдений читается точнее, чем есть."),
        ("Чего книга не доказывает",
         "Что формулы верны по существу. Она доказывает ровно одно: числа получены "
         "из ряда объявленными формулами. Верна ли формула, тот ли ряд, та ли метрика — "
         "из воспроизводимости не следует."),
    ]
    r = 4
    for title, text in blocks:
        put(ws, f"A{r}", title, F_BLOCK, align=WRAP, fill=BLOCK_BG, border=True)
        put(ws, f"B{r}", text, F_BODY, align=WRAP, border=True)
        ws.row_dimensions[r].height = max(44, 13 * (len(text) // 95 + 1))
        r += 1
    return ws


# ── сборка ────────────────────────────────────────────────────────────────
def build():
    rows = load_rows()
    wb = Workbook()
    wb.remove(wb.active)
    first, last, max_row = sheet_series(wb, rows)
    p = sheet_params(wb)
    calc_rows, anchors = sheet_calc(wb, first, last)
    extra = sheet_sigmas(wb, anchors)
    extra += sheet_triggers(wb, first, last)
    sheet_guide(wb)

    names = {
        "v": f"'Ряд'!$E${first}:$E${last}",
        "d": f"'Ряд'!$F${first + 1}:$F${last}",
        "dB": f"'Ряд'!$J${first + 1}:$J${last}",
        "z_90": f"'Параметры'!${p['z_90'][0]}${p['z_90'][1:]}",
        "k_G26": f"'Параметры'!${p['k_G26'][0]}${p['k_G26'][1:]}",
        "L_reg": f"'Параметры'!${p['L_reg'][0]}${p['L_reg'][1:]}",
        "T_cikl": f"'Параметры'!${p['T_cikl'][0]}${p['T_cikl'][1:]}",
    }
    for nm, ref in names.items():
        wb.defined_names[nm] = DefinedName(nm, attr_text=ref)

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    wb.save(OUT)
    return OUT, calc_rows, extra


def verify(path, calc_rows, extra=()):
    """Пересчитать книгу движком формул и сверить D с E построчно.

    Считает не python по своим правилам, а сами формулы книги — то есть проверяется
    именно то, что увидит Excel. Движок `formulas` в зависимостях репозитория
    не значится; без него сверка не выполняется и об этом говорится прямо,
    а не подменяется молчаливым «ок»."""
    try:
        import formulas
    except ImportError:
        raise RuntimeError(
            "движок формул не установлен: pip install formulas.\n"
            "Без него сверить книгу нечем — python-пересчёт проверял бы "
            "собственную реализацию, а не формулы листа."
        )
    import warnings
    warnings.filterwarnings("ignore")
    xl = formulas.ExcelModel().loads(path).finish()
    sol = xl.calculate()
    book = {}
    for key, val in sol.items():
        if "!" not in str(key):
            continue
        addr = str(key).split("!")[-1]
        sheet = str(key).split("]")[-1].split("!")[0].rstrip("'")
        try:
            book[(sheet, addr)] = val.value[0, 0]
        except Exception:
            book[(sheet, addr)] = None

    bad = []
    for rr, tol in calc_rows:
        got = book.get(("РАСЧЁТ", f"D{rr}"))
        want = book.get(("РАСЧЁТ", f"E{rr}"))
        label = book.get(("РАСЧЁТ", f"A{rr}"))
        if got is None or isinstance(got, str):
            bad.append(f"  строка {rr} ({label}): формула не вычислилась -> {got!r}")
            continue
        if abs(float(got) - float(want)) > tol:
            bad.append(f"  строка {rr} ({label}): {float(got):.6f} против "
                       f"{float(want):.6f}, допуск {tol}")

    for sheet, addr, want, tol in extra:
        got = book.get((sheet, addr))
        if got is None or isinstance(got, str):
            bad.append(f"  {sheet}!{addr}: формула не вычислилась -> {got!r}")
            continue
        if abs(float(got) - float(want)) > tol:
            bad.append(f"  {sheet}!{addr}: {float(got):.6f} против {float(want):.6f}, "
                       f"допуск {tol}")
    return bad, len(calc_rows) + len(extra), book


def main():
    path, calc_rows, extra = build()
    print(f"собрано: {os.path.relpath(path, HERE)}  ({len(calc_rows)} сверяемых чисел)")
    if "--verify" not in sys.argv:
        print("сверка не запускалась — для неё нужен ключ --verify")
        return 0
    bad, total, _ = verify(path, calc_rows, extra)
    if bad:
        print(f"РАСХОЖДЕНИЙ: {len(bad)} из {total}")
        print("\n".join(bad))
        return 1
    print(f"сверка пройдена: все {total} чисел вычислены по формулам самой книги "
          f"и сошлись с опубликованными")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
