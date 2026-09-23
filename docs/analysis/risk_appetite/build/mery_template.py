# -*- coding: utf-8 -*-
"""Шаблон мер реагирования для заполнения — Этап 1, адресат Sabila.

Что здесь и чего здесь нет. Здесь — **полный перебор случаев**: каждое сочетание
зоны, триггеров и фазы перехода вынесено в отдельную строку, чтобы ни один случай
нельзя было пропустить молча. Содержания мер здесь нет и быть не должно: меры
берутся из действующих процедур системы управления рисками (п. 34 пп. 5, 6 Правил
№ 86), а не изобретаются.

Перебор. Четыре состояния зоны × четыре сочетания триггеров = 16 состояний;
каждое умножается на три фазы — вход, удержание, выход — итого **48 случаев**.
Плюс пять правил перехода, которые действуют поперёк состояний и потому вынесены
на отдельный лист.

Уровней реагирования пять, а не сорок восемь, и причина названа на первом листе:
за 36 месяцев по двенадцати метрикам одно превышение лимита и ни одного признанного
реализовавшегося риска. Сорок восемь различных по строгости ответов на таком
материале — утверждение о различиях, которых данные не показывают. Полнота случаев
обеспечивается перебором, различимость ответов — закрытым набором R0…R4.

Запуск:
    python3 mery_template.py ../out/Shablon_mer_reagirovaniya_v1.0.xlsx
    python3 mery_template.py --selftest
"""

import os
import sys

from openpyxl import Workbook, load_workbook
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from openpyxl.utils import get_column_letter

TITLE = Font(name="Calibri", size=13, bold=True, color="0B0B0B")
HEAD = Font(name="Calibri", size=10, bold=True, color="0B0B0B")
BODY = Font(name="Calibri", size=10, color="0B0B0B")
MUTED = Font(name="Calibri", size=9, color="5A5A5A", italic=True)
FILLIN = Font(name="Calibri", size=10, color="1F4E79")

HEAD_BG = PatternFill("solid", fgColor="E8E8E4")
FILL_BG = PatternFill("solid", fgColor="FFF8E1")   # что заполняет Sabila
ZONE_BG = {
    "Зелёная": PatternFill("solid", fgColor="E6F4EA"),
    "Жёлтая": PatternFill("solid", fgColor="FFF4CE"),
    "Красная": PatternFill("solid", fgColor="FBE4E4"),
    "Нарушение лимита": PatternFill("solid", fgColor="F2D7D7"),
}
THIN = Side(style="thin", color="BFBFBF")
BOX = Border(left=THIN, right=THIN, top=THIN, bottom=THIN)
WRAP = Alignment(wrap_text=True, vertical="top")
CENTER = Alignment(horizontal="center", vertical="center", wrap_text=True)

ZONES = ["Зелёная", "Жёлтая", "Красная", "Нарушение лимита"]
TRIGS = [(0, 0, "ни одного"), (1, 0, "только T1 — скачок"),
         (0, 1, "только T2 — разгон"), (1, 1, "оба")]
PHASES = [
    ("Вход", "состояние возникло впервые"),
    ("Удержание", "состояние держится второй период и далее"),
    ("Выход", "состояние улучшилось — что делается при снятии"),
]

LEVELS = [
    ("R0", "Наблюдение в обычном режиме", "ничего не происходит",
     "владелец метрики", "строка в отчёте", "ежемесячно"),
    ("R1", "Учащённое наблюдение", "что-то движется, вмешиваться рано",
     "владелец метрики + БРМ", "еженедельный расчёт", "до выхода из состояния"),
    ("R2", "Разбор причины движения", "нужно понять, что именно происходит",
     "БРМ", "письменно: числитель / знаменатель / пересмотр параметра",
     "5 рабочих дней"),
    ("R3", "Эскалация и план устранения", "нужно действовать",
     "БРМ → КУР", "план со сроком и ответственным", "10 рабочих дней"),
    ("R4", "Протокол нарушения", "лимит пробит и продолжает ухудшаться",
     "КУР → Правление / СД", "уведомление, план, отчёт о ходе",
     "по действующей процедуре"),
]

RULES = [
    ("П1", "Вход",
     "Немедленно, по факту расчёта метрики",
     "Задержка входа обнуляет смысл зоны"),
    ("П2", "Выход через гистерезис",
     "N периодов подряд в лучшем состоянии. N — решение автора",
     "Без гистерезиса метрика на границе даёт дребезг: вход-выход-вход каждый период"),
    ("П3", "Удержание по триггеру",
     "Срабатывание любого триггера держит уровень не ниже R1 два месяца, "
     "даже если зона зелёная",
     "Движение имеет инерцию; один спокойный месяц её не отменяет"),
    ("П4", "Залипание",
     "Два периода подряд в жёлтой без улучшения динамики выводятся "
     "НЕ на меру, а на пересмотр лимита",
     "Постоянное нахождение в жёлтой означает неверную калибровку самого уровня, "
     "а не событие"),
    ("П5", "Панельное правило",
     "Три и более метрик, сработавших в одном месяце, поднимают уровень "
     "на ступень по всей панели и разбираются ОДНИМ разбором",
     "Иначе на одно событие приходит четыре независимых уведомления. "
     "На истории это 6 месяцев из 32"),
]


def level_of(zone_idx, t1, t2):
    """Зона задаёт базовый уровень, каждый триггер поднимает на ступень, потолок R4."""
    return f"R{min(zone_idx + t1 + t2, 4)}"


def put(ws, ref, value, font=BODY, fill=None, align=WRAP, border=True):
    c = ws[ref]
    c.value = value
    c.font = font
    c.alignment = align
    if fill:
        c.fill = fill
    if border:
        c.border = BOX
    return c


def sheet_howto(wb):
    ws = wb.create_sheet("Как заполнять")
    ws.column_dimensions["A"].width = 4
    ws.column_dimensions["B"].width = 108
    put(ws, "B2", "Шаблон мер реагирования по кредитным метрикам риск-аппетита",
        TITLE, border=False)
    text = [
        "",
        "ЧТО ОТ ВАС НУЖНО. Заполнить колонку «Мера» на листе «Случаи» — 48 строк, "
        "по одной на каждое сочетание зоны, триггеров и фазы перехода. Плюс колонки "
        "«Основание», «Ответственный», «Срок».",
        "",
        "ОТКУДА БРАТЬ МЕРЫ. Из действующих процедур системы управления рисками. "
        "П. 34 пп. 5 и 6 Правил № 86 относит разработку триггеров и систем раннего "
        "предупреждения к БРМ, но сами меры должны существовать в процедурах, "
        "а не изобретаться в записке.",
        "",
        "ЕСЛИ ПРОЦЕДУРЫ НЕТ. Так и написать: «процедуры нет». Это отдельный результат "
        "работы, а не пробел в таблице. Перечень уровней, под которые в Банке нет "
        "процедуры, — самостоятельный вывод, который выносится на уполномоченный орган.",
        "",
        "ПОЧЕМУ УРОВНЕЙ ПЯТЬ, А НЕ СОРОК ВОСЕМЬ. Полнота случаев и различимость "
        "ответов — разные вещи. Случаев 48, и все перебраны, чтобы ни один нельзя "
        "было пропустить молча. Но за 36 месяцев по двенадцати метрикам — одно "
        "превышение лимита и ни одного признанного реализовавшегося риска. "
        "Сорок восемь различных по строгости ответов на таком материале были бы "
        "утверждением о различиях, которых данные не показывают. Поэтому меры берутся "
        "из закрытого набора R0…R4, а отображение «случай → уровень» показано явно.",
        "",
        "ЧТО УЖЕ ПРОСТАВЛЕНО И МЕНЯТЬ НЕ НУЖНО. Колонка «Уровень» на листе «Случаи» "
        "рассчитана по правилу: зона задаёт базовый уровень, каждый сработавший "
        "триггер поднимает на одну ступень, выше R4 не поднимается. Если уровень "
        "кажется неверным для конкретного случая — это замечание к правилу, "
        "и его надо высказать, а не править ячейку.",
        "",
        "ЛИСТЫ. «Случаи» — 48 строк для заполнения. «Уровни» — что означает каждый "
        "из R0…R4; подтвердить или поправить. «Переходы» — пять правил, действующих "
        "поперёк состояний. «Пороги» — справочно: границы зон и триггеров по каждой "
        "из двенадцати метрик.",
        "",
        "ОГОВОРКА, КОТОРУЮ НАДО ЗНАТЬ. Две метрики CoR размечены замещающим методом "
        "(90-й процентиль значений за 36 месяцев) и предварительно: формула расчёта "
        "ряда не подтверждена. Граница красной зоны и пороги триггеров по ним — "
        "предложение. На листе «Пороги» они помечены.",
    ]
    r = 4
    for t in text:
        c = ws.cell(row=r, column=2, value=t)
        c.font = BODY if t and not t.isupper() else BODY
        c.alignment = Alignment(wrap_text=True, vertical="top")
        ws.row_dimensions[r].height = max(15, 15 * (len(t) // 95 + 1))
        r += 1
    return ws


def sheet_cases(wb):
    ws = wb.create_sheet("Случаи")
    heads = [("A", "№", 5), ("B", "Зона", 17), ("C", "Триггеры", 18),
             ("D", "Фаза", 12), ("E", "Уровень", 9),
             ("F", "Мера — ЗАПОЛНИТЬ", 44), ("G", "Основание: пункт ВНД "
              "или процедура — ЗАПОЛНИТЬ", 30),
             ("H", "Ответственный — ЗАПОЛНИТЬ", 22), ("I", "Срок — ЗАПОЛНИТЬ", 16)]
    put(ws, "A1", "48 случаев: зона × триггеры × фаза перехода. "
                  "Жёлтые колонки — для заполнения", TITLE, border=False,
        align=Alignment(vertical="center"))
    ws.merge_cells("A1:I1")
    for col, t, w in heads:
        put(ws, f"{col}3", t, HEAD, HEAD_BG, CENTER)
        ws.column_dimensions[col].width = w
    ws.row_dimensions[3].height = 34

    r, n = 4, 0
    for zi, zone in enumerate(ZONES):
        for t1, t2, tname in TRIGS:
            for phase, phase_note in PHASES:
                n += 1
                put(ws, f"A{r}", n, BODY, align=CENTER)
                put(ws, f"B{r}", zone, BODY, ZONE_BG[zone])
                put(ws, f"C{r}", tname, BODY)
                put(ws, f"D{r}", phase, BODY)
                put(ws, f"E{r}", level_of(zi, t1, t2), HEAD, align=CENTER)
                for col in ("F", "G", "H", "I"):
                    put(ws, f"{col}{r}", None, FILLIN, FILL_BG)
                ws.row_dimensions[r].height = 30
                r += 1
    ws.freeze_panes = "A4"
    ws.auto_filter.ref = f"A3:I{r - 1}"
    put(ws, f"A{r + 1}",
        "Фазы: «Вход» — состояние возникло впервые; «Удержание» — держится второй "
        "период и далее; «Выход» — что делается при снятии состояния.",
        MUTED, border=False)
    ws.merge_cells(f"A{r + 1}:I{r + 1}")
    return ws, n


def sheet_levels(wb):
    ws = wb.create_sheet("Уровни")
    put(ws, "A1", "Закрытый набор уровней реагирования — подтвердить или поправить",
        TITLE, border=False, align=Alignment(vertical="center"))
    ws.merge_cells("A1:F1")
    heads = [("A", "Уровень", 10), ("B", "Название", 28), ("C", "Смысл", 34),
             ("D", "Кто действует", 22), ("E", "Форма", 34), ("F", "Срок", 20)]
    for col, t, w in heads:
        put(ws, f"{col}3", t, HEAD, HEAD_BG, CENTER)
        ws.column_dimensions[col].width = w
    for i, row in enumerate(LEVELS):
        r = 4 + i
        for j, val in enumerate(row):
            put(ws, f"{get_column_letter(1 + j)}{r}", val,
                HEAD if j == 0 else BODY, align=CENTER if j == 0 else WRAP)
        ws.row_dimensions[r].height = 34
    r = 4 + len(LEVELS) + 1
    put(ws, f"A{r}",
        "Обязательный элемент R2, без которого он бесполезен: разбор должен отвечать, "
        "движение пришло из ЧИСЛИТЕЛЯ (портфель вырос) или из ЗНАМЕНАТЕЛЯ (капитал "
        "упал). Меры на эти два случая разные, и в одном из них бизнес-подразделения "
        "ни при чём. Январь 2026 — пример: движение целиком из знаменателя.",
        MUTED, border=False)
    ws.merge_cells(f"A{r}:F{r}")
    ws.row_dimensions[r].height = 46
    return ws


def sheet_rules(wb):
    ws = wb.create_sheet("Переходы")
    put(ws, "A1", "Пять правил перехода — действуют поперёк всех состояний",
        TITLE, border=False, align=Alignment(vertical="center"))
    ws.merge_cells("A1:D1")
    heads = [("A", "№", 7), ("B", "Правило", 26), ("C", "Как работает", 52),
             ("D", "Зачем", 52)]
    for col, t, w in heads:
        put(ws, f"{col}3", t, HEAD, HEAD_BG, CENTER)
        ws.column_dimensions[col].width = w
    for i, row in enumerate(RULES):
        r = 4 + i
        for j, val in enumerate(row):
            put(ws, f"{get_column_letter(1 + j)}{r}", val,
                HEAD if j == 0 else BODY, align=CENTER if j == 0 else WRAP)
        ws.row_dimensions[r].height = 48
    r = 4 + len(RULES) + 1
    put(ws, f"A{r}",
        "Открыто и требует решения: N в правиле П2 (на месячном ряде N от 1 до 4 "
        "не меняет числа переключений и стоит 3–8 пп доли ускоренного режима) "
        "и порог «три» в правиле П5 (выбран как первое число, отделяющее 6 месяцев "
        "с массовым срабатыванием от 8 месяцев с одиночным).",
        MUTED, border=False)
    ws.merge_cells(f"A{r}:D{r}")
    ws.row_dimensions[r].height = 46
    return ws


def sheet_thresholds(wb):
    """Справочный лист: границы зон и пороги триггеров по каждой метрике.

    Источник — `calib/method_selection.py`: метод выбирается правилом К1–К3,
    десять метрик на запасе времени, две CoR на замещающем методе.
    """
    here = os.path.dirname(os.path.abspath(__file__))
    sys.path.insert(0, os.path.join(here, "..", "calib"))
    import method_selection as ms

    _dates, res = ms.evaluate()
    res.sort(key=lambda r: (r["method"] != "M(T)", not r["code"] == "top20"))
    rows = []
    for r in res:
        if r["method"] == "M(T)":
            name, note = r["name"], "запас времени M(T)"
        else:
            name = f"CoR — {r['name'][4:].replace('_', '/')}"
            note = ("замещающий метод: 90-й процентиль значений. ПРЕДВАРИТЕЛЬНО — "
                    "формула CoR не подтверждена; граница жёлтой/красной и T1/T2 — "
                    "предложение")
        rows.append((name, r["L"], r["c"]["sigma"], r["green"], r["yellow"],
                     r["t1"], r["t2"], note))

    ws = wb.create_sheet("Пороги")
    put(ws, "A1", "Справочно: границы зон и пороги триггеров по двенадцати метрикам",
        TITLE, border=False, align=Alignment(vertical="center"))
    ws.merge_cells("A1:H1")
    heads = [("A", "Метрика", 30), ("B", "Лимит", 10), ("C", "σ приращений", 12),
             ("D", "Граница зелёной", 15), ("E", "Граница жёлтой", 15),
             ("F", "Порог T1", 11), ("G", "Порог T2", 11), ("H", "Оговорка", 34)]
    for col, t, w in heads:
        put(ws, f"{col}3", t, HEAD, HEAD_BG, CENTER)
        ws.column_dimensions[col].width = w
    ws.row_dimensions[3].height = 30
    for i, (name, lim, s, g, y, t1, t2, note) in enumerate(rows):
        r = 4 + i
        put(ws, f"A{r}", name, BODY)
        for col, v in (("B", lim), ("C", s), ("D", g), ("E", y),
                       ("F", t1), ("G", t2)):
            c = put(ws, f"{col}{r}", v, BODY, align=CENTER)
            c.number_format = "0.0000"
        put(ws, f"H{r}", note, MUTED if "CoR" in name else BODY)
    r = 4 + len(rows) + 1
    put(ws, f"A{r}",
        "Границы: зелёная — значение ниже «Границы зелёной»; жёлтая — между ней "
        "и «Границей жёлтой»; красная — между «Границей жёлтой» и лимитом; "
        "нарушение — лимит и выше. T1 — приращение за месяц не меньше порога; "
        "T2 — изменение за четыре месяца не меньше порога. Все метрики «не более»: "
        "выше значит хуже.", MUTED, border=False)
    ws.merge_cells(f"A{r}:H{r}")
    ws.row_dimensions[r].height = 46
    return ws, len(rows)


def build(path):
    wb = Workbook()
    wb.remove(wb.active)
    sheet_howto(wb)
    _, n_cases = sheet_cases(wb)
    sheet_levels(wb)
    sheet_rules(wb)
    _, n_metrics = sheet_thresholds(wb)
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    wb.save(path)
    return n_cases, n_metrics


def selftest():
    import tempfile
    ok = True

    def check(name, cond, detail=""):
        nonlocal ok
        ok &= bool(cond)
        print(f"  [{'ok' if cond else 'СБОЙ'}] {name}{'  ' + detail if detail else ''}")

    # отображение случая в уровень
    check("зелёная без триггеров — R0", level_of(0, 0, 0) == "R0")
    check("зелёная с обоими — R2", level_of(0, 1, 1) == "R2")
    check("красная без триггеров — R2", level_of(2, 0, 0) == "R2")
    check("нарушение без триггеров — R3", level_of(3, 0, 0) == "R3")
    check("потолок R4", level_of(3, 1, 1) == "R4")
    check("уровней ровно пять", len({level_of(z, a, b)
                                     for z in range(4) for a in (0, 1)
                                     for b in (0, 1)}) == 5)
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "t.xlsx")
        n_cases, n_metrics = build(p)
        check("случаев 48 = 4 зоны × 4 сочетания × 3 фазы", n_cases == 48,
              f"получено {n_cases}")
        check("метрик двенадцать", n_metrics == 12, f"получено {n_metrics}")
        wb = load_workbook(p)
        check("пять листов", len(wb.sheetnames) == 5, ", ".join(wb.sheetnames))
        ws = wb["Случаи"]
        filled = sum(1 for row in ws.iter_rows(min_row=4, max_row=51,
                                               min_col=6, max_col=9)
                     for c in row if c.value is not None)
        check("колонки для заполнения пусты", filled == 0,
              f"заполнено {filled} из 192")
        uniq = {(r[1].value, r[2].value, r[3].value)
                for r in ws.iter_rows(min_row=4, max_row=51)}
        check("все 48 случаев различны", len(uniq) == 48, f"различных {len(uniq)}")
        cor = [r[0].value for r in wb["Пороги"].iter_rows(min_row=4, max_row=15)
               if r[0].value and "CoR" in r[0].value]
        check("обе метрики CoR помечены оговоркой", len(cor) == 2)
        # Записка размечает CoR замещающим методом: граница зелёной — процентиль
        # значений, она положительна. Отрицательная означала бы, что лист снова
        # считает CoR запасом времени и расходится с запиской.
        cor_green = [r[3].value for r in wb["Пороги"].iter_rows(min_row=4, max_row=15)
                     if r[0].value and "CoR" in r[0].value]
        check("границы зелёной по CoR — замещающим методом, совпадают с запиской",
              [round(g, 2) for g in cor_green] == [0.52, 0.24], str(cor_green))
    return ok


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        print("Самопроверка mery_template:")
        sys.exit(0 if selftest() else 1)
    out = sys.argv[1] if len(sys.argv) > 1 else "../out/Shablon_mer_reagirovaniya_v1.0.xlsx"
    a, b = build(out)
    print(f"{out}: случаев {a}, метрик {b}")
