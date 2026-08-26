r"""nst_fill_2026.py — заполнение предварительного шаблона сегментации НСТ 2026.

Цель
----
1) Проставить в шаблоне метку индивидуального займа по спискам Sabila.
2) При наличии выгрузки С1 — проставить SEGMENT и «Портфель в шаблоне НСТ».

Шаблон:
  R:\!!!!!НСТ2026\Сегментация\Предварительная\B1A_B1B_01012026_сегментация НСТ_предварит.xlsx

Почему скрипт, а не SQL в NST_CREDIT.md (Н3): читает и пишет xlsx на сетевом
диске R:, который смонтирован только на рабочей машине. Третье исключение
из Н1, основание то же, что у nst_inventory.py.

ПОРЯДОК РАБОТЫ — сначала --inspect, потом --fill
------------------------------------------------
Структура шаблона на момент написания скрипта неизвестна: какая строка шапки,
как называется колонка БИН, есть ли уже колонки под метку. Гадать нельзя (Н4),
поэтому первый режим ничего не пишет, а показывает, что в файле есть:

    python nst_fill_2026.py --inspect

Он печатает листы, найденную строку шапки, все колонки и то, какие из них
опознаны как БИН / ключ займа / сегмент. Если опознание неверное — колонки
задаются вручную (--col-bin, --col-key, ...), и только после этого --fill.

ЧТО СКРИПТ НЕ ДЕЛАЕТ
--------------------
* Не пишет в исходный файл. Никогда. Результат — всегда новый файл рядом
  (или туда, куда указан --out). Папка сетевая и общая; правка на месте
  необратима и видна не только автору.
* Не печатает БИН, ИИН и наименования — ни в консоль, ни в отчёт (раздел 6
  CLAUDE.md контура). Только количества и суммы.
* Не фильтрует список Sabila (Н7). Ни по размеру, ни по «найденности»
  в витрине, ни по чему бы то ни было. Что в файлах — то и метится,
  расхождения выносятся в отчёт как расхождения, а не подгоняются.
* Не содержит строк подключения. Если нужен SQL — строка берётся
  из переменной окружения NST_MSSQL_DSN.

МЕТКА ИНДИВИДУАЛЬНОСТИ — два независимых флага, не каскад
---------------------------------------------------------
Н24: в С1 `individual_basis` присваивается каскадом, `B2A` проверяется первым,
и ветка `threshold` показывает не всех, кто перешагнул порог, а прирост порога
сверх списка (в цикле 2025 Q4 — 5 договоров вместо ожидавшихся сотен).
Здесь оба признака считаются независимо, и колонка основания показывает
состав: `B2A`, `порог`, `B2A+порог`.

Порог — «превышает 0,2 % собственного капитала» (Таблица 4, дословно строго
больше, О13). Капитал НЕ зашит: цикл 2026 — другая отчётная дата и другой
СК. Без --capital флаг порога не считается вовсе, и скрипт об этом говорит.

СЕГМЕНТ И ПОРТФЕЛЬ
------------------
`--seg` принимает CSV выгрузки С1. Ожидается колонка сегмента **слоя 2** —
той, где ветки Individual loans / RELATE / DISASS уже сняты (Г7). Так велит
Таблица 3: для кредитного риска индивидуальные займы и ОУСА «распределены
по другим портфелям».

Если в CSV встретятся псевдосегменты — портфель для этих строк не проставится,
а количество попадёт в отчёт. Домысливать, куда бы они легли, скрипт не станет.

Про `RELATE` открыт О28: в ключевых строках Таблицы 3 ЛСБОО не перечислен,
то есть, похоже, остаётся собственной строкой формы — в отличие от двух
других веток. По умолчанию так и трактуется (--relate own-row).
"""

from __future__ import annotations

import argparse
import csv
import os
import re
import sys
from collections import Counter, defaultdict

TEMPLATE_DEFAULT = (
    r"R:\!!!!!НСТ2026\Сегментация\Предварительная"
    r"\B1A_B1B_01012026_сегментация НСТ_предварит.xlsx"
)

DOLYA_INDIVID = 0.002          # 0,2 % собственного капитала, Таблица 4
HEAD_SCAN = 20                 # сколько верхних строк смотреть в поисках шапки
BIN_RE = re.compile(r"^\d{12}$")

# 13.8: перечень строк листа «КР расчет провизий», колонка `segment`.
# 13 из 14 строк Таблицы 4 совпали с ним имя в имя.
PORTFOLIO = {
    "CORINV": "Инвестиционные займы",
    "COREST": "Займы, выданные на приобретение, строительство недвижимости",
    "CORGOV": "Займы государственным корпорациям",
    "CORLAR": "Прочие займы субъектам крупного предпринимательства",
    "CORMED": "Прочие займы субъектам среднего предпринимательства",
    "RETSML": "Займы субъектам малого предпринимательства",
    "RETEST": "Займы физ. лиц, обеспеченные жилой недвижимостью",
    "RETCAR": "Автокредиты и прочие обеспеченные займы физ. лиц",
    "RETCON": "Потребительские кредиты, кредитные карты и прочие займы физ. лиц",
    "RELATE": "Займы ЛСБОО",
}

# Слой 1 их содержит, слой 2 — не должен (Таблица 3: «распределены по другим
# портфелям»). RELATE сюда НЕ входит: в ключевых строках Таблицы 3 ЛСБОО
# не перечислен, то есть остаётся собственной строкой формы. Основание
# не подтверждено — это О28, и поведение переключается через --relate.
PSEUDO = {"Individual loans", "INDIVIDUAL", "DISASS"}

COL_INDIVID = "Индивидуальный заём"
COL_BASIS = "Основание индивидуальности"
COL_SEGMENT = "SEGMENT"
COL_PORTF = "Портфель в шаблоне НСТ"

CAND = {
    "bin": ["iin_bin", "бин", "иин", "бин/иин", "иин/бин", "bin", "iin",
            "бин заемщика", "бин заёмщика", "идентификатор заемщика"],
    "key": ["loan_id_kr", "loan_id", "credit_line_id", "id", "идентификатор займа",
            "номер займа", "номер договора", "id займа"],
    "segment": ["segment", "сегмент", "segment_nst", "сегмент нст", "segment_afr"],
    "portfolio": ["портфель в шаблоне нст", "портфель", "portfolio"],
    "zadol": ["zadol", "задолженность", "объем задолженности",
              "объём задолженности", "общая задолженность"],
}


# ------------------------------------------------------------------ утилиты

def norm(v) -> str:
    """Приведение заголовка к сопоставимому виду."""
    if v is None:
        return ""
    s = str(v).replace("\n", " ").replace("\xa0", " ")
    s = re.sub(r"[«»\"'`.:;→]", " ", s)
    return re.sub(r"\s+", " ", s).strip().lower()


def as_bin(v) -> str:
    """БИН/ИИН из ячейки. Excel хранит их и числом — тогда теряется ведущий ноль."""
    if v is None:
        return ""
    if isinstance(v, float) and v.is_integer():
        v = int(v)
    if isinstance(v, int):
        return f"{v:012d}" if 0 < v < 10 ** 12 else ""
    s = str(v).strip().replace(" ", "").replace("\xa0", "")
    if s.endswith(".0"):
        s = s[:-2]
    return s if BIN_RE.match(s) else ""


def as_float(v) -> float:
    """Суммы приходят строками с пробелами и запятой (та же причина, что Н15)."""
    if v is None or v == "":
        return 0.0
    if isinstance(v, (int, float)):
        return float(v)
    s = str(v).strip().replace("\xa0", "").replace(" ", "").replace(",", ".")
    try:
        return float(s)
    except ValueError:
        return 0.0


def long_path(p: str) -> str:
    """Префикс живёт ровно на время системного вызова (Н25)."""
    if os.name != "nt":
        return p
    p = os.path.abspath(p)
    if p.startswith("\\\\?\\"):
        return p
    if p.startswith("\\\\"):
        return "\\\\?\\UNC\\" + p[2:]
    return "\\\\?\\" + p


def say(*a):
    print(*a, file=sys.stderr, flush=True)


# ------------------------------------------------------- шапка и колонки

def find_header(ws, scan: int = HEAD_SCAN):
    """Строка шапки — та из верхних, где больше всего нечисловых строк.

    Тот же приём, что в nst_inventory.py --probe: технические строки
    (`sot`, номера колонок, единицы) числовые или короткие, шапка — текстовая.
    """
    best_i, best_score = 1, -1
    for i, row in enumerate(ws.iter_rows(min_row=1, max_row=scan, values_only=True), 1):
        score = sum(
            1 for v in row
            if isinstance(v, str) and len(v.strip()) > 2 and not v.strip().isdigit()
        )
        if score > best_score:
            best_i, best_score = i, score
    return best_i


def col_map(ws, hrow: int):
    """{нормализованное имя: номер колонки}. Дубли имён — в отдельный список (Н23)."""
    m, dup = {}, []
    for j, v in enumerate(next(ws.iter_rows(min_row=hrow, max_row=hrow, values_only=True)), 1):
        n = norm(v)
        if not n:
            continue
        if n in m:
            dup.append(n)
        else:
            m[n] = j
    return m, dup


def resolve(cmap, kind: str, forced: str | None):
    """Логическая колонка → физическая. Явное указание перекрывает угадывание."""
    if forced:
        j = cmap.get(norm(forced))
        if not j:
            raise SystemExit(f"колонка «{forced}» в шапке не найдена")
        return j, norm(forced)
    for c in CAND[kind]:
        if c in cmap:
            return cmap[c], c
    for c in CAND[kind]:                       # затем по вхождению
        for name, j in cmap.items():
            if c in name:
                return j, name
    return None, None


# --------------------------------------------------------- списки Sabila

def read_bins(paths):
    """БИН из файлов Sabila. Union без фильтрации (Н7).

    Колонку не ищем по имени — берём любую ячейку, похожую на БИН.
    Имя колонки в присланных файлах непредсказуемо, а 12 цифр — предсказуемы.
    """
    from openpyxl import load_workbook

    files = []
    for p in paths:
        if os.path.isdir(long_path(p)):
            for e in os.scandir(long_path(p)):
                if e.is_file() and os.path.splitext(e.name)[1].lower() in (
                        ".xlsx", ".xlsm", ".csv", ".txt"):
                    files.append(os.path.join(p, e.name))
        else:
            files.append(p)

    bins, per_file = set(), []
    for f in files:
        found = set()
        ext = os.path.splitext(f)[1].lower()
        try:
            if ext in (".csv", ".txt"):
                with open(long_path(f), encoding="utf-8-sig", newline="") as fh:
                    for row in csv.reader(fh, delimiter=";"):
                        for cell in row:
                            b = as_bin(cell)
                            if b:
                                found.add(b)
            else:
                wb = load_workbook(long_path(f), read_only=True, data_only=True)
                for ws in wb.worksheets:
                    for row in ws.iter_rows(values_only=True):
                        for cell in row:
                            b = as_bin(cell)
                            if b:
                                found.add(b)
                wb.close()
        except Exception as exc:                       # noqa: BLE001
            say(f"  ! {os.path.basename(f)}: {type(exc).__name__}: {exc}")
            continue
        per_file.append((os.path.basename(f), len(found)))
        bins |= found

    return bins, per_file


def read_seg(path: str, col_key: str | None, col_seg: str | None):
    """Выгрузка С1: ключ займа → сегмент слоя 2. CSV с ';' или ','."""
    with open(long_path(path), encoding="utf-8-sig", newline="") as fh:
        sample = fh.read(8192)
        fh.seek(0)
        delim = ";" if sample.count(";") >= sample.count(",") else ","
        rd = csv.DictReader(fh, delimiter=delim)
        heads = {norm(h): h for h in (rd.fieldnames or [])}

        def pick(kind, forced):
            if forced:
                if norm(forced) not in heads:
                    raise SystemExit(f"в {os.path.basename(path)} нет колонки «{forced}»")
                return heads[norm(forced)]
            for c in CAND[kind]:
                if c in heads:
                    return heads[c]
            for c in CAND[kind]:
                for n, orig in heads.items():
                    if c in n:
                        return orig
            return None

        hk, hs = pick("key", col_key), pick("segment", col_seg)
        if not hk or not hs:
            raise SystemExit(
                f"в {os.path.basename(path)} не опознаны колонки: "
                f"ключ={hk}, сегмент={hs}. Задайте --seg-col-key / --seg-col-segment"
            )
        seg = {}
        for r in rd:
            k = (r.get(hk) or "").strip()
            if k:
                seg[k] = (r.get(hs) or "").strip()
        return seg, hk, hs


# ------------------------------------------------------------------ режимы

def inspect(args):
    from openpyxl import load_workbook

    say(f"открываю {args.template}")
    wb = load_workbook(long_path(args.template), read_only=True, data_only=True)
    for ws in wb.worksheets:
        say(f"\n=== лист «{ws.title}» — {ws.max_row} строк × {ws.max_column} колонок")
        hrow = find_header(ws, args.head_scan)
        cmap, dup = col_map(ws, hrow)
        say(f"    шапка определена на строке {hrow}")
        if dup:
            say(f"    ! дубли имён в шапке (Н23): {', '.join(sorted(set(dup)))}")
        for kind in ("bin", "key", "segment", "portfolio", "zadol"):
            j, name = resolve(cmap, kind, None)
            say(f"    {kind:<10} → " + (f"колонка {j} «{name}»" if j else "НЕ ОПОЗНАНА"))
        say("    все колонки шапки:")
        for name, j in sorted(cmap.items(), key=lambda kv: kv[1]):
            say(f"      {j:>3}  {name}")
        for c in (COL_INDIVID, COL_BASIS, COL_SEGMENT, COL_PORTF):
            if norm(c) in cmap:
                say(f"    * колонка «{c}» уже есть — --fill её перезапишет")
        if ws.max_row > 200_000:
            say(f"    ! {ws.max_row} строк: запись через openpyxl съест минуты "
                f"и гигабайты. Рассмотрите --sidecar")
    wb.close()
    say("\nНичего не записано. Дальше: --fill с теми колонками, что опознаны выше.")


def fill(args):
    from openpyxl import load_workbook

    # --- проверки до работы -----------------------------------------------
    # Отказ должен наступать до чтения шаблона, а не после: на файле
    # в полмиллиона строк «уже существует» через десять минут — не проверка.
    out = args.out or default_out(args.template)
    if os.path.exists(long_path(out)) and not args.force:
        raise SystemExit(f"{out} уже существует; укажите другой --out либо --force")
    if os.path.abspath(long_path(out)) == os.path.abspath(long_path(args.template)):
        raise SystemExit("--out совпадает с шаблоном; писать в исходник нельзя")

    # --- источники --------------------------------------------------------
    b2a, per_file = set(), []
    if args.b2a:
        say("читаю списки Sabila…")
        b2a, per_file = read_bins(args.b2a)
        for name, n in per_file:
            say(f"  {name}: {n} БИН")
        say(f"  union: {len(b2a)} БИН")
        if not b2a:
            raise SystemExit("в указанных файлах не нашлось ни одного БИН (12 цифр)")
    else:
        say("! --b2a не задан: метка B2A не считается")

    porog = None
    if args.capital:
        porog = args.capital * DOLYA_INDIVID
        say(f"порог индивидуальности: {porog:,.0f} ₸ "
            f"({DOLYA_INDIVID:.1%} от {args.capital:,.0f} ₸), строго больше (О13)")
    else:
        say("! --capital не задан: флаг порога НЕ считается, метка будет только по B2A")

    seg = {}
    if args.seg:
        seg, hk, hs = read_seg(args.seg, args.seg_col_key, args.seg_col_segment)
        say(f"выгрузка С1: {len(seg)} ключей, «{hk}» → «{hs}»")

    # --- шаблон -----------------------------------------------------------
    say(f"открываю шаблон (формулы сохраняются)…")
    wb = load_workbook(long_path(args.template), data_only=False)
    ws = wb[args.sheet] if args.sheet else wb.worksheets[0]
    hrow = args.header_row or find_header(ws, args.head_scan)
    cmap, dup = col_map(ws, hrow)
    say(f"лист «{ws.title}», шапка на строке {hrow}, {ws.max_row} строк")
    if dup:
        say(f"! дубли имён в шапке: {', '.join(sorted(set(dup)))}")

    j_bin, n_bin = resolve(cmap, "bin", args.col_bin)
    j_key, n_key = resolve(cmap, "key", args.col_key)
    j_zad, n_zad = resolve(cmap, "zadol", args.col_zadol)
    if not j_bin:
        raise SystemExit("колонка БИН не опознана — прогоните --inspect и задайте --col-bin")
    say(f"БИН → колонка {j_bin} «{n_bin}»")
    if j_key:
        say(f"ключ займа → колонка {j_key} «{n_key}»")
    if j_zad:
        say(f"задолженность → колонка {j_zad} «{n_zad}»")

    if porog is not None and not (j_zad or seg):
        raise SystemExit("для флага порога нужна задолженность: --col-zadol либо --seg")

    # --- шаг 1: задолженность по заёмщику ---------------------------------
    # Единица применения — заёмщик (Г8, Н19): порог считается на сумму по БИН,
    # а не по договору.
    zadol_bin: dict[str, float] = defaultdict(float)
    rows = []
    for i, row in enumerate(
            ws.iter_rows(min_row=hrow + 1, max_row=ws.max_row, values_only=True),
            hrow + 1):
        b = as_bin(row[j_bin - 1]) if j_bin <= len(row) else ""
        k = str(row[j_key - 1]).strip() if j_key and j_key <= len(row) and row[j_key - 1] is not None else ""
        z = as_float(row[j_zad - 1]) if j_zad and j_zad <= len(row) else 0.0
        if not b and not k:
            continue
        rows.append((i, b, k, z))
        if b:
            zadol_bin[b] += z
    say(f"строк с данными: {len(rows)}, заёмщиков: {len(zadol_bin)}")

    # --- шаг 2: колонки под запись ----------------------------------------
    out_cols = [COL_INDIVID, COL_BASIS]
    if seg:
        out_cols += [COL_SEGMENT, COL_PORTF]
    at = {}
    free = ws.max_column
    for name in out_cols:
        j = cmap.get(norm(name))
        if j:
            say(f"колонка «{name}» уже есть (колонка {j}) — перезаписывается")
        else:
            free += 1
            j = free
            ws.cell(row=hrow, column=j, value=name)
        at[name] = j

    # --- шаг 3: заполнение ------------------------------------------------
    pseudo_set = PSEUDO | ({"RELATE"} if args.relate == "distribute" else set())

    stat = Counter()          # метка индивидуальности
    seg_stat = Counter()      # сегмент как он пришёл — каждая строка ровно один раз
    warn = Counter()          # почему портфель не проставлен
    miss_key = 0
    for i, b, k, _z in rows:
        f_b2a = 1 if (b and b in b2a) else 0
        f_por = 1 if (porog is not None and b and zadol_bin[b] > porog) else 0
        basis = {(1, 1): "B2A+порог", (1, 0): "B2A", (0, 1): "порог"}.get((f_b2a, f_por), "")
        ws.cell(row=i, column=at[COL_INDIVID], value=1 if basis else 0)
        ws.cell(row=i, column=at[COL_BASIS], value=basis)
        stat[basis or "—"] += 1

        if seg:
            s = seg.get(k, "")
            ws.cell(row=i, column=at[COL_SEGMENT], value=s)
            if not s:
                miss_key += 1
                p = ""
            elif s in pseudo_set:
                p = ""                       # слой 1 в слой 2 не переводим молча
                warn[f"псевдосегмент слоя 1: {s}"] += 1
            else:
                p = PORTFOLIO.get(s, "")
                if not p:
                    warn[f"портфель не задан для сегмента {s}"] += 1
            ws.cell(row=i, column=at[COL_PORTF], value=p)
            seg_stat[s or "ключ не найден в выгрузке"] += 1

    # --- шаг 4: сохранение ------------------------------------------------
    say(f"сохраняю {out} …")
    wb.save(long_path(out))
    wb.close()
    say("готово")

    # --- шаг 5: отчёт (без БИН и наименований) ----------------------------
    report(args, out, stat, seg_stat, warn, b2a, zadol_bin, porog, per_file, miss_key)


def default_out(template: str) -> str:
    base, ext = os.path.splitext(template)
    return f"{base}_метка_индивид{ext}"


def report(args, out, stat, seg_stat, warn, b2a, zadol_bin, porog, per_file, miss_key):
    """Агрегаты в консоль и в CSV рядом с результатом. БИН не выводятся."""
    lines = []

    def add(s=""):
        lines.append(s)
        say(s)

    add("")
    add("=== метка индивидуальности, договоров ===")
    for k in ("B2A", "порог", "B2A+порог", "—"):
        if stat.get(k):
            add(f"  {k:<12} {stat[k]:>9}")

    if b2a:
        hit = {b for b in b2a if b in zadol_bin}
        add("")
        add("=== список Sabila против шаблона (О11) ===")
        for name, n in per_file:
            add(f"  файл {name}: {n} БИН")
        add(f"  union списков:            {len(b2a):>6}")
        add(f"  из них есть в шаблоне:    {len(hit):>6}")
        add(f"  НЕ найдены в шаблоне:     {len(b2a) - len(hit):>6}   <- Н7: разбираем нашу сторону")

    if porog is not None:
        over = sum(1 for z in zadol_bin.values() if z > porog)
        both = sum(1 for b, z in zadol_bin.items() if z > porog and b in b2a)
        add("")
        add("=== порог 0,2 % СК, заёмщиков ===")
        add(f"  перешагнули порог:        {over:>6}")
        add(f"  из них в списке B2A:      {both:>6}")
        add(f"  прирост порога сверх списка: {over - both:>3}   <- Н24: считано независимо")

    if seg_stat:
        add("")
        add("=== сегмент из выгрузки С1, договоров ===")
        for k, n in seg_stat.most_common():
            portf = PORTFOLIO.get(k, "")
            add(f"  {k:<20} {n:>9}   {portf}")
        add(f"  {'ВСЕГО':<20} {sum(seg_stat.values()):>9}")

        if warn:
            add("")
            add("=== портфель НЕ проставлен ===")
            for k, n in warn.most_common():
                add(f"  {k:<44} {n:>9}")
        if miss_key:
            add(f"  {'ключ не найден в выгрузке':<44} {miss_key:>9}")

        pseudo = sum(n for k, n in warn.items() if k.startswith("псевдосегмент"))
        if pseudo:
            add("")
            add(f"  ! {pseudo} строк пришли с сегментом слоя 1. Таблица 3 для")
            add("    кредитного риска требует слоя 2 («распределены по другим")
            add("    портфелям»); домысливать за неё скрипт не станет.")
            add("    Перевыгрузите С1 с сегментом после снятия веток (Г7).")
        if seg_stat.get("RELATE") and args.relate == "own-row":
            add("")
            add(f"  ! RELATE: {seg_stat['RELATE']} договоров отнесены к строке")
            add("    «Займы ЛСБОО». В ключевых строках Таблицы 3 ЛСБОО не")
            add("    перечислен — трактуем как самостоятельную строку, но")
            add("    основание не подтверждено. Это О28; обратное поведение —")
            add("    --relate distribute.")

    add("")
    add(f"результат: {out}")

    rp = os.path.splitext(out)[0] + "_отчет.csv"
    with open(long_path(rp), "w", encoding="utf-8-sig", newline="") as fh:
        w = csv.writer(fh, delimiter=";")
        w.writerow(["строка отчёта"])
        for s in lines:
            w.writerow([s])
    say(f"отчёт:     {rp}")


# --------------------------------------------------------------------- CLI

def main():
    p = argparse.ArgumentParser(
        description="Метка индивидуальных займов и сегмент в шаблоне НСТ 2026",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=r"""
примеры
  # 1. что вообще в шаблоне
  python nst_fill_2026.py --inspect

  # 2. только метка индивидуальности по спискам Sabila
  python nst_fill_2026.py --fill --b2a "R:\!!!!!НСТ2026\Списки Sabila"

  # 3. метка с порогом и сегмент из выгрузки С1
  python nst_fill_2026.py --fill ^
      --b2a "R:\...\список.xlsx" ^
      --capital 503086114000 ^
      --seg C:\work\c1_2026.csv
""")
    p.add_argument("--template", default=TEMPLATE_DEFAULT)
    p.add_argument("--inspect", action="store_true", help="показать структуру, ничего не писать")
    p.add_argument("--fill", action="store_true", help="заполнить (в новый файл)")
    p.add_argument("--out", help="куда сохранить; по умолчанию рядом с суффиксом")
    p.add_argument("--force", action="store_true", help="перезаписать существующий --out")
    p.add_argument("--sheet", help="лист шаблона; по умолчанию первый")
    p.add_argument("--header-row", type=int, help="строка шапки, если определилась неверно")
    p.add_argument("--head-scan", type=int, default=HEAD_SCAN)

    p.add_argument("--b2a", nargs="+", help="файлы/папки списков Sabila (xlsx, csv)")
    p.add_argument("--capital", type=float,
                   help="собственный капитал на отчётную дату, ₸. Без него порог не считается")
    p.add_argument("--seg", help="CSV выгрузки С1: ключ займа → сегмент СЛОЯ 2")
    p.add_argument("--seg-col-key")
    p.add_argument("--seg-col-segment")
    p.add_argument("--relate", choices=("own-row", "distribute"), default="own-row",
                   help="ЛСБОО: своя строка формы «Займы ЛСБОО» (по умолчанию) "
                        "либо распределяются как Individual loans. Открыт О28")

    p.add_argument("--col-bin", help="имя колонки БИН в шаблоне")
    p.add_argument("--col-key", help="имя колонки ключа займа")
    p.add_argument("--col-zadol", help="имя колонки задолженности")

    a = p.parse_args()
    if a.inspect == a.fill:
        p.error("укажите ровно одно: --inspect или --fill")
    try:
        import openpyxl  # noqa: F401
    except ImportError:
        raise SystemExit("нужен openpyxl:  pip install openpyxl")
    (inspect if a.inspect else fill)(a)


if __name__ == "__main__":
    main()
