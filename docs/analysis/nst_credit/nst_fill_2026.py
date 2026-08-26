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
    python nst_fill_2026.py --inspect

Ничего не пишет; печатает листы, строку шапки, все колонки и то, какие
из них опознаны. Прогон 26.08.2026 дал:

    лист B1A — 566 605 строк × 115 колонок, шапка на строке 1
    лист B1B —   1 845 строк ×  99 колонок, шапка на строке 1

и снял три допущения, под которые скрипт был написан первым заходом.

ЧТО ИЗ ЭТОГО СЛЕДУЕТ — три решения, каждое проверяемо
------------------------------------------------------
**1. Оба листа, а не первый.** B1A — балансовая часть, B1B — кредитные линии.
Расчёт по одному B1A теряет 27 БИН и 3,67 млрд EAD (Д2, О9).

**2. Задолженность считается, а не ищется.** Одной колонки в B1A нет, есть
слагаемые `od, od_del, interest, interest_del, correction, disc_prem, penalty` —
ровно формула С1, строка в строку (Н18). В B1B слагаемых нет вовсе: там
`limit` и `offbal`, то есть внебаланс. Поэтому **порог считается по B1A**,
а B1B в сумму задолженности не входит — но метку получает, потому что метка
ставится на заёмщика, а не на лист.

**3. Потоковая запись.** 566 605 × 115 через `load_workbook` — это гигабайты
и минуты. По умолчанию (`--write stream`) исходник читается построчно
и пишется в новый файл построчно же: память постоянная. Цена — теряются
форматирование и формулы. Для выгрузки витрины это приемлемо; если шаблон
всё-таки содержит формулы, есть `--write inplace` (медленно, но сохраняет)
и `--sidecar` (только CSV с ключом и метками, шаблон не трогается вовсе).

ЧТО СКРИПТ НЕ ДЕЛАЕТ
--------------------
* Не пишет в исходный файл. Никогда. Папка сетевая и общая; правка
  на месте необратима и видна не только автору.
* Не печатает БИН, ИИН и наименования — ни в консоль, ни в отчёт
  (раздел 6 CLAUDE.md контура). Только количества и суммы.
* Не фильтрует список Sabila (Н7). Что в файлах — то и метится,
  расхождения выносятся в отчёт, а не подгоняются.
* Не содержит строк подключения.

МЕТКА ИНДИВИДУАЛЬНОСТИ — два независимых флага, не каскад
---------------------------------------------------------
Н24: в С1 `individual_basis` присваивается каскадом, `B2A` проверяется первым,
и ветка `threshold` показывает не всех, кто перешагнул порог, а прирост порога
сверх списка (в 2025 Q4 — 5 договоров вместо ожидавшихся сотен). Здесь оба
признака считаются независимо, колонка основания показывает состав:
`B2A`, `порог`, `B2A+порог`.

Порог — «превышает 0,2 % собственного капитала» (Таблица 4, дословно строго
больше, О13). Капитал НЕ зашит: цикл 2026 — другая отчётная дата и другой СК.
Без --capital флаг порога не считается вовсе, и скрипт об этом говорит.

Сумма по заёмщику берётся по активным строкам: С1 фильтрует `is_del = '0'`,
и удалённые договоры не должны раздувать порог.

СВЕРКА С `ind_sign`
-------------------
В B1A есть колонка `ind_sign` — похоже, признак индивидуальности уже
в витрине. Молча добавлять рядом свой и не смотреть на него нельзя.
Скрипт строит перекрёстную таблицу «наша метка × ind_sign» и печатает её.
Совпадает — хорошо; расходится — вопрос к витрине до подачи, а не после.

СЕГМЕНТ И ПОРТФЕЛЬ
------------------
`--seg` принимает CSV выгрузки С1. Ожидается колонка сегмента **слоя 2** —
той, где ветки Individual loans / RELATE / DISASS уже сняты (Г7). Так велит
Таблица 3: для кредитного риска индивидуальные займы и ОУСА «распределены
по другим портфелям». Псевдосегменты слоя 1 портфель не получают, их
количество идёт в отчёт: домысливать за Таблицу 3 скрипт не станет.

Про `RELATE` открыт О28 — по умолчанию своя строка «Займы ЛСБОО»
(--relate distribute для обратного).
"""

from __future__ import annotations

import argparse
import csv
import os
import re
import sys
import time
from collections import Counter, defaultdict

TEMPLATE_DEFAULT = (
    r"R:\!!!!!НСТ2026\Сегментация\Предварительная"
    r"\B1A_B1B_01012026_сегментация НСТ_предварит.xlsx"
)

# Перечень Sabila цикла 2026. Не подставляется молча — только подсказка
# в --help: --b2a задаётся явно, чтобы в отчёте было видно, что именно читали.
B2A_HINT = (
    r"R:\!!!!!НСТ2026\Сегментация\Индивидуальные заемщики от Сабилы"
    r"\Список инд. заемщиков для НСТ.xlsx"
)

DOLYA_INDIVID = 0.002          # 0,2 % собственного капитала, Таблица 4
HEAD_SCAN = 20
BIN_RE = re.compile(r"^\d{12}$")
BIG_SHEET = 100_000            # выше этого inplace не предлагается
TICK = 50_000                  # шаг прогресса

# Формула задолженности С1, строка в строку (Н18).
ZADOL_PARTS = ["od", "od_del", "interest", "interest_del",
               "correction", "disc_prem", "penalty"]
ZADOL_CORE = "od"              # без него лист задолженности не несёт

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
# не перечислен, то есть остаётся собственной строкой формы. О28.
PSEUDO = {"Individual loans", "INDIVIDUAL", "DISASS"}

COL_INDIVID = "Индивидуальный заём"
COL_BASIS = "Основание индивидуальности"
COL_SEGMENT = "SEGMENT"
COL_PORTF = "Портфель в шаблоне НСТ"
COL_WHY = "Основание сегмента"
SHEET_METOD = "Методология"

CAND = {
    "bin": ["iin_bin", "бин", "иин", "бин/иин", "иин/бин", "bin", "iin",
            "бин заемщика", "бин заёмщика"],
    "key": ["loan_id_kr", "loan_id", "credit_line_id", "id",
            "номер займа", "номер договора"],
    "segment": ["segment", "сегмент", "segment_nst", "сегмент нст", "segment_afr"],
    "zadol": ["zadol", "задолженность", "объем задолженности",
              "объём задолженности", "общая задолженность"],
}

# Поля каскада. Все присутствуют и в B1A, и в B1B — проверено --inspect 26.08.2026.
CASCADE_FIELDS = ["entity", "lsboo", "f_inv", "debtor_type", "debtor_se",
                  "ent_type", "loan_obj", "loan_purp", "collateral", "ead"]

# =====================================================================
#  МЕТОДОЛОГИЯ РАСПРЕДЕЛЕНИЯ СЕГМЕНТОВ
#
#  Единственный источник и для расчёта, и для методички, которая уходит
#  вместе с файлом. Разъехаться они не могут: cascade() возвращает номер,
#  metodologiya() печатает эту же таблицу. Править — только здесь.
#
#  Порядок ветвления воспроизводит С1 строка в строку, включая приоритет
#  (Н18): доля «неверных» отнесений поля меряется внутри его собственной
#  ветки, и переставленное условие меняет результат, а не только вид.
#
#  № : (сегмент, условие дословно, что это значит, основание)
# =====================================================================
RULES = {
    1:  ("DISASS", "entity = 'EUB1'",
         "Заём на балансе организации по управлению стрессовыми активами",
         "Таблица 4: «все займы на балансе ОУСА по амортизированной стоимости»"),
    2:  ("RELATE", "lsboo = 1",
         "Заём лицу, связанному с банком особыми отношениями",
         "Таблица 4: «согласно требованиям регуляторной отчётности»"),
    3:  ("CORINV", "f_inv = 1",
         "Инвестиционный заём",
         "Таблица 4: срок ≥ 5 лет, запрет полного досрочного погашения, ЮЛ, "
         "бизнес-план. Флаг проставляет источник — см. О3"),
    4:  ("Individual loans", "БИН заёмщика в перечне индивидуальных",
         "Заёмщик признан индивидуально значимым",
         "Перечень Sabila (Н7: принимается неизменным). Основания в Таблице 4 "
         "для этого критерия нет — О6"),
    5:  ("Individual loans", "задолженность заёмщика > 0,2 % собственного капитала",
         "Порог индивидуальности",
         "Таблица 4: «все займы, общая задолженность которых превышает 0,2 % "
         "от собственного капитала Банка». Строго больше (О13). Считается "
         "на сумму по БИН, а не по договору (Г8)"),
    6:  ("COREST",
         "(debtor_type = 1 ИЛИ (debtor_type = 0 И debtor_se = 1)) "
         "И ent_type ∈ {1,2,3} И loan_obj ∈ {1,2,3} И loan_purp ∈ {1,2,3,4,5,8}",
         "Заём на приобретение или строительство недвижимости",
         "Таблица 4: «согласно требованиям регуляторной отчётности» (Н12)"),
    7:  ("CORLAR", "ent_type = 1",
         "Субъект крупного предпринимательства",
         "ст. 24 п. 6 ПК РК: > 250 работников и/или доход > 3 000 000 МРП. "
         "Численность и доход в витрине отсутствуют — О2"),
    8:  ("CORMED", "ent_type = 2",
         "Субъект среднего предпринимательства",
         "ст. 24 п. 5 ПК РК: не малое и не крупное"),
    9:  ("RETSML", "ent_type = 3",
         "Субъект малого предпринимательства",
         "ст. 24 п. 3 ПК РК: ≤ 100 работников и доход ≤ 300 000 МРП"),
    10: ("RETEST",
         "debtor_type = 0 И debtor_se = 0 И ead ≤ 200 млн И loan_obj = 1",
         "Заём физлицу, обеспеченный жилой недвижимостью",
         "Таблица 4: «согласно требованиям регуляторной отчётности» (Н12)"),
    11: ("RETCAR",
         "debtor_type = 0 И debtor_se = 0 И ead ≤ 200 млн И collateral = 1",
         "Автокредит либо иной обеспеченный заём физлицу",
         "Таблица 4: «согласно требованиям регуляторной отчётности» (Н12)"),
    12: ("RETCON",
         "debtor_type = 0 И debtor_se = 0 И ead ≤ 200 млн, прочее",
         "Потребительский кредит, кредитная карта, прочий заём физлицу",
         "Остаток розничной ветки"),
    13: ("X", "ни одно условие выше не выполнено",
         "ТРЕБУЕТ РУЧНОГО РАЗБОРА",
         "Чаще всего — отсутствует ent_type у юрлица либо ead > 200 млн "
         "у физлица. Строку разбирает ответственное подразделение"),
}

# Слой 2 — распределение по Таблице 3, колонка «кредитный риск»:
# «Индивидуальные займы» и «займы, переданные в ОУСА» распределены
# по другим портфелям. Значит на слое 2 эти правила пропускаются,
# и заём доходит до продуктовой ветки (Г7, доказана на 1 470 договорах).
# RELATE (правило 2) в ключевых строках Таблицы 3 не перечислен —
# по умолчанию остаётся своей строкой формы. Это О28.
SKIP_L2 = {1, 4, 5}
NO_PORTFOLIO = "требует ручного разбора"


# ------------------------------------------------------------------ утилиты

def norm(v) -> str:
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


def as_int(v):
    """TRY_CAST, а не CAST (Н15): коды приходят nvarchar с нечисловым содержимым."""
    if v is None or v == "":
        return None
    if isinstance(v, bool):
        return int(v)
    if isinstance(v, (int, float)):
        return int(v)
    s = str(v).strip().replace("\xa0", "").replace(" ", "").replace(",", ".")
    try:
        return int(float(s))
    except ValueError:
        return None


def cascade(v: dict, skip: frozenset) -> int:
    """Каскад С1, строка в строку, включая порядок ветвления (Н18).

    v — приведённые значения строки; skip — номера пропускаемых правил
    (слой 2 по Таблице 3). Возвращает номер сработавшего правила из RULES.
    """
    if 1 not in skip and str(v.get("entity") or "").strip() == "EUB1":
        return 1
    if 2 not in skip and v.get("lsboo") == 1:
        return 2
    if 3 not in skip and (v.get("f_inv") or 0) == 1:
        return 3
    if 4 not in skip and v.get("in_b2a"):
        return 4
    if 5 not in skip and v.get("over_porog"):
        return 5

    dt, dse = v.get("debtor_type"), v.get("debtor_se")
    et, lo = v.get("ent_type"), v.get("loan_obj")
    lp, col = v.get("loan_purp"), v.get("collateral")

    if (dt == 1 or (dt == 0 and dse == 1)) and et in (1, 2, 3) \
            and lo in (1, 2, 3) and lp in (1, 2, 3, 4, 5, 8):
        return 6
    if et == 1:
        return 7
    if et == 2:
        return 8
    if et == 3:
        return 9
    if (dt or 0) == 0 and (dse or 0) == 0 and (v.get("ead") or 0.0) <= 200_000_000:
        if lo == 1:
            return 10
        if (col or 0) == 1:
            return 11
        return 12
    return 13


def is_active(v) -> bool:
    """`is_del` приходит и строкой '0', и числом 0, и пустым."""
    if v is None or v == "":
        return True
    return str(v).strip() in ("0", "0.0", "False", "false")


def cell(row, j: int):
    """Значение колонки j (1-based) из кортежа строки; хвост бывает обрезан."""
    return row[j - 1] if j and j <= len(row) else None


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


class Tick:
    """Прогресс по строкам: на 566 тысячах молчание неотличимо от зависания."""

    def __init__(self, label: str):
        self.label, self.n, self.t0 = label, 0, time.monotonic()

    def __call__(self, k: int = 1):
        self.n += k
        if self.n % TICK == 0:
            dt = time.monotonic() - self.t0
            say(f"    {self.label}: {self.n:,} строк, {self.n / max(dt, 1e-9):,.0f}/с")

    def done(self):
        dt = time.monotonic() - self.t0
        say(f"    {self.label}: {self.n:,} строк за {dt:.1f} с")


# ------------------------------------------------------- шапка и колонки

def find_header(ws, scan: int = HEAD_SCAN) -> int:
    """Строка шапки — та из верхних, где больше всего нечисловых строк."""
    best_i, best_score = 1, -1
    for i, row in enumerate(ws.iter_rows(min_row=1, max_row=scan, values_only=True), 1):
        score = sum(1 for v in row
                    if isinstance(v, str) and len(v.strip()) > 2 and not v.strip().isdigit())
        if score > best_score:
            best_i, best_score = i, score
    return best_i


def col_map(ws, hrow: int):
    """{нормализованное имя: номер колонки}. Дубли — отдельным списком (Н23)."""
    m, dup = {}, []
    head = next(ws.iter_rows(min_row=hrow, max_row=hrow, values_only=True))
    for j, v in enumerate(head, 1):
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
    for c in CAND[kind]:
        for name, j in cmap.items():
            if c in name:
                return j, name
    return None, None


class Plan:
    """Разбор одного листа: где что лежит и умеет ли лист задолженность."""

    def __init__(self, ws, args):
        self.title = ws.title
        self.hrow = args.header_row or find_header(ws, args.head_scan)
        self.cmap, self.dup = col_map(ws, self.hrow)
        self.j_bin, self.n_bin = resolve(self.cmap, "bin", args.col_bin)
        self.j_key, self.n_key = resolve(self.cmap, "key", args.col_key)
        self.j_isdel = self.cmap.get("is_del")
        self.j_indsign = self.cmap.get("ind_sign")
        self.ncol = ws.max_column or max(self.cmap.values(), default=0)
        self.maxrow = ws.max_row or 0          # в read_only бывает None

        j_one, n_one = resolve(self.cmap, "zadol", args.col_zadol)
        self.zadol_one = j_one
        self.zadol_parts = [] if j_one else [
            self.cmap[p] for p in ZADOL_PARTS if p in self.cmap]
        self.has_zadol = bool(j_one) or (ZADOL_CORE in self.cmap)
        self.zadol_names = ([n_one] if j_one
                            else [p for p in ZADOL_PARTS if p in self.cmap])

        # Поля каскада. Отсутствующее поле — не повод «считать как получится»:
        # каскад без ent_type отправит юрлиц в розницу и промолчит.
        self.casc = {f: self.cmap.get(f) for f in CASCADE_FIELDS}
        self.casc_missing = [f for f, j in self.casc.items() if not j]

    def zadol(self, row) -> float:
        if self.zadol_one:
            return as_float(cell(row, self.zadol_one))
        return sum(as_float(cell(row, j)) for j in self.zadol_parts)

    def vals(self, row) -> dict:
        """Приведённые значения полей каскада для одной строки."""
        v = {f: as_int(cell(row, self.casc[f])) if self.casc[f] else None
             for f in CASCADE_FIELDS}
        v["entity"] = cell(row, self.casc["entity"]) if self.casc["entity"] else None
        v["ead"] = as_float(cell(row, self.casc["ead"])) if self.casc["ead"] else 0.0
        return v

    def describe(self):
        say(f"  лист «{self.title}»: шапка {self.hrow}, {self.ncol} колонок")
        if self.dup:
            say(f"    ! дубли имён в шапке (Н23): {', '.join(sorted(set(self.dup)))}")
        say(f"    БИН → {self.j_bin} «{self.n_bin}»"
            + (f", ключ → {self.j_key} «{self.n_key}»" if self.j_key else ", ключа нет"))
        if self.has_zadol:
            say(f"    задолженность = {' + '.join(self.zadol_names)}")
        else:
            say("    задолженности нет — лист в сумму порога НЕ входит")
        if self.j_isdel:
            say(f"    is_del → колонка {self.j_isdel}, неактивные в порог не идут")
        if self.j_indsign:
            say(f"    ind_sign → колонка {self.j_indsign}, будет сверка с нашей меткой")
        if self.casc_missing:
            say(f"    ! полей каскада нет: {', '.join(self.casc_missing)} — "
                f"сегмент на этом листе не считается")
        else:
            say("    все поля каскада на месте, сегмент считается")


# --------------------------------------------------------- списки Sabila

def read_bins(paths):
    """БИН из файлов Sabila. Union без фильтрации (Н7).

    Колонку не ищем по имени — берём любую ячейку, похожую на БИН.
    Имя колонки в присланных файлах непредсказуемо, 12 цифр — предсказуемы.
    """
    from openpyxl import load_workbook

    files = []
    for p in paths:
        if os.path.isdir(long_path(p)):
            for e in sorted(os.scandir(long_path(p)), key=lambda e: e.name):
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
                        for c in row:
                            b = as_bin(c)
                            if b:
                                found.add(b)
            else:
                wb = load_workbook(long_path(f), read_only=True, data_only=True)
                for ws in wb.worksheets:
                    for row in ws.iter_rows(values_only=True):
                        for c in row:
                            b = as_bin(c)
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
    """Выгрузка С1: ключ займа → сегмент слоя 2."""
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
                f"в {os.path.basename(path)} не опознаны колонки: ключ={hk}, "
                f"сегмент={hs}. Задайте --seg-col-key / --seg-col-segment")
        seg = {}
        for r in rd:
            k = (r.get(hk) or "").strip()
            if k:
                seg[k] = (r.get(hs) or "").strip()
        return seg, hk, hs


# ------------------------------------------------------------------ inspect

def inspect(args):
    from openpyxl import load_workbook

    say(f"открываю {args.template}")
    wb = load_workbook(long_path(args.template), read_only=True, data_only=True)
    for ws in wb.worksheets:
        say(f"\n=== лист «{ws.title}» — {ws.max_row} строк × {ws.max_column} колонок")
        pl = Plan(ws, args)
        pl.describe()
        say("    все колонки шапки:")
        for name, j in sorted(pl.cmap.items(), key=lambda kv: kv[1]):
            say(f"      {j:>3}  {name}")
        for c in (COL_INDIVID, COL_BASIS, COL_SEGMENT, COL_PORTF):
            if norm(c) in pl.cmap:
                say(f"    * «{c}» уже есть (колонка {pl.cmap[norm(c)]}) — --fill перезапишет")
        if (ws.max_row or 0) > BIG_SHEET:
            say(f"    ! {ws.max_row} строк — пишем потоком (--write stream, по умолчанию)")
    wb.close()
    say("\nНичего не записано.")


# --------------------------------------------------------------------- fill

def fill(args):
    from openpyxl import Workbook, load_workbook

    out = args.out or default_out(args.template)
    if os.path.abspath(long_path(out)) == os.path.abspath(long_path(args.template)):
        raise SystemExit("--out совпадает с шаблоном; писать в исходник нельзя")
    if os.path.exists(long_path(out)) and not args.force:
        raise SystemExit(f"{out} уже существует; укажите другой --out либо --force")

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
        say(f"порог: {porog:,.0f} ₸ ({DOLYA_INDIVID:.1%} от {args.capital:,.0f} ₸), "
            f"строго больше (О13)")
    else:
        say("! --capital не задан: флаг порога НЕ считается, метка только по B2A")

    seg = {}
    if args.seg:
        seg, hk, hs = read_seg(args.seg, args.seg_col_key, args.seg_col_segment)
        say(f"выгрузка С1: {len(seg)} ключей, «{hk}» → «{hs}»")

    # --- проход 1: задолженность по заёмщику ------------------------------
    # Нужен ровно для порога: правило П5 меряется на сумму по БИН (Г8, Н19),
    # а сумму нельзя узнать, не дочитав файл до конца. Без --capital правило
    # не применяется — тогда и прохода нет, работа вдвое короче.
    #
    # Цена прохода реальна: openpyxl на 200 тыс. строк × 115 колонок тратит
    # ~23 с на открытие (таблица общих строк) и ~40 с на чтение. Молчать
    # об этом нельзя, поэтому Tick печатает прогресс каждые 50 тыс. строк.
    need_pass1 = porog is not None
    wb = load_workbook(long_path(args.template), read_only=True, data_only=True)
    sheets = pick_sheets(wb, args)
    plans = {}
    zadol_bin: dict[str, float] = defaultdict(float)
    rowcnt, delcnt = Counter(), Counter()

    for ws in sheets:
        pl = Plan(ws, args)
        pl.describe()
        if not pl.j_bin:
            raise SystemExit(f"лист «{ws.title}»: колонка БИН не опознана, задайте --col-bin")
        plans[ws.title] = pl

    if need_pass1:
        say("проход 1 из 2 — сумма задолженности по заёмщику")
        for ws in sheets:
            pl = plans[ws.title]
            t = Tick(ws.title)
            for row in ws.iter_rows(min_row=pl.hrow + 1, values_only=True):
                b = as_bin(cell(row, pl.j_bin))
                if not b and not cell(row, pl.j_key):
                    continue
                rowcnt[ws.title] += 1
                t()
                if pl.j_isdel and not is_active(cell(row, pl.j_isdel)):
                    delcnt[ws.title] += 1
                    continue                   # С1 фильтрует is_del = '0'
                if b and pl.has_zadol:
                    zadol_bin[b] += pl.zadol(row)
            t.done()
        say(f"строк: {sum(rowcnt.values()):,}, из них неактивных "
            f"{sum(delcnt.values()):,}; заёмщиков с задолженностью: {len(zadol_bin):,}")
        if not zadol_bin:
            raise SystemExit("порог задан, но ни на одном листе нет задолженности")
    else:
        say("проход 1 пропущен: без --capital правило П5 (порог) не применяется")
    wb.close()

    # --- проход 2: запись --------------------------------------------------
    ctx = Ctx(args, b2a, porog, zadol_bin, seg or None)

    def new_cols(pl: Plan):
        """Куда писать. Существующие имена перезаписываются, прочие в хвост."""
        at, free = {}, pl.ncol
        for name in OUT_COLS:
            j = pl.cmap.get(norm(name))
            if not j:
                free += 1
                j = free
            at[name] = j
        return at, free

    say(f"проход {'2 из 2' if need_pass1 else '1 из 1'} — запись, "
        f"режим {args.write}")

    if args.write == "sidecar":
        sidecar(args, out, sheets_ro(args), plans, ctx)
    elif args.write == "stream":
        src = load_workbook(long_path(args.template), read_only=True, data_only=True)
        dst = Workbook(write_only=True)
        for ws in src.worksheets:
            if ws.title == SHEET_METOD:        # старая методичка перегенерируется
                continue
            ows = dst.create_sheet(title=ws.title)
            pl = plans.get(ws.title)
            if pl is None:                     # лист не наш — переносим как есть
                for row in ws.iter_rows(values_only=True):
                    ows.append(list(row))
                continue
            at, width = new_cols(pl)
            t = Tick(ws.title)
            for i, row in enumerate(ws.iter_rows(values_only=True), 1):
                vals = list(row) + [None] * (width - len(row))
                if i == pl.hrow:
                    for name, j in at.items():
                        vals[j - 1] = name
                elif i > pl.hrow:
                    for name, v in (ctx.row(pl, row) or {}).items():
                        vals[at[name] - 1] = v
                    t()
                ows.append(vals)
            t.done()
        metodologiya(dst.create_sheet(title=SHEET_METOD), args, porog, b2a, per_file)
        say(f"сохраняю {out} …")
        dst.save(long_path(out))
        src.close()
        say("! форматирование и формулы шаблона в потоковом режиме не переносятся")
    else:                                       # inplace
        # Размер листа известен либо из прохода 1, либо из <dimension> файла.
        # Если не известен ни оттуда, ни оттуда — отказываем, а не «пробуем»:
        # inplace на неизвестном объёме кончается тем, что машина уходит
        # в своп, а не сообщением об ошибке.
        big, unknown = [], []
        for t, pl in plans.items():
            known = max(rowcnt.get(t, 0), pl.maxrow)
            if not known:
                unknown.append(t)
            elif known > BIG_SHEET:
                big.append(t)
        if (big or unknown) and not args.force:
            why = []
            if big:
                why.append(f"листы {', '.join(big)} больше {BIG_SHEET:,} строк")
            if unknown:
                why.append(f"размер листов {', '.join(unknown)} неизвестен "
                           f"(нет <dimension>, проход 1 не выполнялся)")
            raise SystemExit(
                "; ".join(why) + ". inplace грузит книгу целиком — используйте "
                "--write stream либо --force")
        wb = load_workbook(long_path(args.template), data_only=False)
        for ws in sheets_by_title(wb, plans):
            pl = plans[ws.title]
            at, _ = new_cols(pl)
            for name, j in at.items():
                ws.cell(row=pl.hrow, column=j, value=name)
            t = Tick(ws.title)
            for i, row in enumerate(
                    ws.iter_rows(min_row=pl.hrow + 1, values_only=True), pl.hrow + 1):
                for name, v in (ctx.row(pl, row) or {}).items():
                    ws.cell(row=i, column=at[name], value=v)
                t()
            t.done()
        if SHEET_METOD in wb.sheetnames:
            del wb[SHEET_METOD]
        metodologiya(wb.create_sheet(title=SHEET_METOD), args, porog, b2a, per_file)
        say(f"сохраняю {out} …")
        wb.save(long_path(out))
        wb.close()

    say("готово")
    report(args, out, ctx, b2a, zadol_bin, porog, per_file, rowcnt, delcnt, plans)


OUT_COLS = [COL_SEGMENT, COL_PORTF, COL_WHY, COL_INDIVID, COL_BASIS]


class Ctx:
    """Расчёт одной строки плюс накопление статистики.

    Здесь сходятся оба слоя: слой 1 — каскад целиком, слой 2 — он же
    с пропуском правил, которые Таблица 3 велит распределять (SKIP_L2).
    Номер сработавшего правила пишется в строку, чтобы ответственное
    подразделение видело, почему сегмент такой, и спорило с условием,
    а не с результатом.
    """

    def __init__(self, args, b2a, porog, zadol_bin, seg_csv):
        self.args, self.b2a, self.porog = args, b2a, porog
        self.zadol_bin, self.seg_csv = zadol_bin, seg_csv
        self.skip2 = frozenset(SKIP_L2 | ({2} if args.relate == "distribute" else set()))
        self.rows = Counter()          # строк с данными по листам
        self.stat = Counter()          # метка индивидуальности
        self.seg1 = Counter()          # сегмент слоя 1
        self.seg2 = Counter()          # строка формы, слой 2
        self.rule1 = Counter()         # какое правило сработало
        self.cross = Counter()         # наша метка × ind_sign
        self.miss_key = Counter()
        self.no_casc = Counter()

    def row(self, pl: Plan, row):
        b = as_bin(cell(row, pl.j_bin))
        k = cell(row, pl.j_key)
        k = str(k).strip() if k is not None else ""
        if not b and not k:
            return None
        self.rows[pl.title] += 1

        f_b2a = bool(b and b in self.b2a)
        f_por = bool(self.porog is not None and b
                     and self.zadol_bin.get(b, 0.0) > self.porog)
        basis = {(1, 1): "B2A+порог", (1, 0): "B2A",
                 (0, 1): "порог"}.get((int(f_b2a), int(f_por)), "")
        self.stat[basis or "—"] += 1
        out = {COL_INDIVID: 1 if basis else 0, COL_BASIS: basis}

        if pl.j_indsign:
            src = cell(row, pl.j_indsign)
            self.cross[(basis or "—", "" if src is None else str(src).strip())] += 1

        if pl.casc_missing:
            self.no_casc[pl.title] += 1
            return out

        v = pl.vals(row)
        v["in_b2a"], v["over_porog"] = f_b2a, f_por

        if self.seg_csv is not None:           # выгрузка С1 перекрывает расчёт
            s1 = self.seg_csv.get(k, "")
            if not s1:
                self.miss_key[pl.title] += 1
            why = "сегмент из выгрузки С1" if s1 else "ключ не найден в выгрузке С1"
            p = "" if (s1 in PSEUDO or not s1) else PORTFOLIO.get(s1, NO_PORTFOLIO)
        else:
            r1 = cascade(v, frozenset())
            s1 = RULES[r1][0]
            self.rule1[r1] += 1
            why = f"П{r1}: {RULES[r1][1]} → {s1}"
            if s1 == "X":
                p = NO_PORTFOLIO
            elif r1 in self.skip2:
                r2 = cascade(v, self.skip2)
                s2 = RULES[r2][0]
                p = PORTFOLIO.get(s2, NO_PORTFOLIO)
                why += f"; слой 2 (Таблица 3) П{r2}: {RULES[r2][1]} → {s2}"
            else:
                p = PORTFOLIO.get(s1, NO_PORTFOLIO)

        self.seg1[s1 or "не определён"] += 1
        self.seg2[p or "не проставлен"] += 1
        if pl.j_isdel and not is_active(cell(row, pl.j_isdel)):
            why += " [is_del = 1: в сумму порога не входит]"

        out[COL_SEGMENT] = s1
        out[COL_PORTF] = p
        out[COL_WHY] = why
        return out


def sheets_ro(args):
    from openpyxl import load_workbook
    wb = load_workbook(long_path(args.template), read_only=True, data_only=True)
    return wb


def pick_sheets(wb, args):
    if args.sheet:
        want = {norm(s) for s in args.sheet}
        got = [ws for ws in wb.worksheets if norm(ws.title) in want]
        if not got:
            raise SystemExit(f"листов {args.sheet} в шаблоне нет")
        return got
    return list(wb.worksheets)


def sheets_by_title(wb, plans):
    return [wb[t] for t in plans if t in wb.sheetnames]


def sidecar(args, out, wb, plans, ctx):
    """CSV с ключом и результатом — шаблон не трогается вовсе."""
    path = os.path.splitext(out)[0] + ".csv"
    with open(long_path(path), "w", encoding="utf-8-sig", newline="") as fh:
        w = csv.writer(fh, delimiter=";")
        w.writerow(["лист", "ключ"] + OUT_COLS)
        for ws in wb.worksheets:
            pl = plans.get(ws.title)
            if pl is None:
                continue
            t = Tick(ws.title)
            for row in ws.iter_rows(min_row=pl.hrow + 1, values_only=True):
                r = ctx.row(pl, row)
                if r is None:
                    continue
                k = cell(row, pl.j_key)
                w.writerow([ws.title, "" if k is None else str(k).strip()]
                           + [r.get(c, "") for c in OUT_COLS])
                t()
            t.done()
    wb.close()
    say(f"sidecar: {path} — соединять по ключу займа, шаблон не изменён")

    mp = os.path.splitext(out)[0] + "_методология.csv"
    with open(long_path(mp), "w", encoding="utf-8-sig", newline="") as fh:
        w = csv.writer(fh, delimiter=";")
        for r in metod_rows(args, ctx.porog, ctx.b2a, []):
            w.writerow(r)
    say(f"методология: {mp}")


# -------------------------------------------------------------- методология

def metod_rows(args, porog, b2a, per_file):
    """Методичка распределения сегментов — из той же таблицы RULES.

    Уходит адресатам вместе с файлом, поэтому объясняет не только «что»,
    но и «почему»: два слоя, чем они отличаются и где у нас открытые вопросы.
    Ответственное подразделение должно уметь оспорить условие, а не догадаться
    о нём по результату.
    """
    rows = [
        ["МЕТОДОЛОГИЯ РАСПРЕДЕЛЕНИЯ СЕГМЕНТОВ НСТ"],
        [],
        ["Сегментация назначает не разрез отчётности, а поведение под стрессом:"],
        ["на каждый портфель надевается свой набор PD, LGD, CCF и матрица миграции,"],
        ["и через провизии он приходит в достаточность капитала. Ошибка сегмента —"],
        ["это неверный параметр на соответствующем объёме книги, а не неточность разреза."],
        [],
        ["ДВА СЛОЯ"],
        ["Слой 1 — первичная сегментация AQR (Таблица 4 Методруководства НСТ)."],
        ["  Колонка «" + COL_SEGMENT + "». Содержит в том числе Individual loans,"],
        ["  RELATE и DISASS как самостоятельные значения."],
        ["Слой 2 — строка формы подачи (Таблица 3, колонка «кредитный риск»)."],
        ["  Колонка «" + COL_PORTF + "». Таблица 3 дословно: «Индивидуальные займы»"],
        ["  и «займы, переданные в ОУСА» — РАСПРЕДЕЛЕНЫ ПО ДРУГИМ ПОРТФЕЛЯМ."],
        ["  Поэтому на слое 2 правила " + ", ".join(f"П{n}" for n in sorted(SKIP_L2))],
        ["  пропускаются, и заём доходит до продуктовой ветки."],
        [],
        ["Колонка «" + COL_WHY + "» показывает оба слоя: какое условие сработало"],
        ["на слое 1 и, если сегмент распределялся, какое на слое 2."],
        [],
        ["УСЛОВИЯ. Проверяются СТРОГО СВЕРХУ ВНИЗ: сработало — дальше не идём."],
        ["Порядок — часть правила. Переставленное условие меняет результат."],
        [],
        ["№", "Условие", "Сегмент (слой 1)", "Строка формы (слой 2)",
         "Что это значит", "Основание"],
    ]
    skip2 = SKIP_L2 | ({2} if args.relate == "distribute" else set())
    for n in sorted(RULES):
        seg, cond, meaning, base = RULES[n]
        if n in skip2:
            form = "распределяется — см. правила ниже"
        elif seg == "X":
            form = NO_PORTFOLIO
        else:
            form = PORTFOLIO.get(seg, NO_PORTFOLIO)
        rows.append([n, cond, seg, form, meaning, base])

    rows += [
        [],
        ["МЕТКА ИНДИВИДУАЛЬНОСТИ — отдельно от сегмента"],
        ["Колонки «" + COL_INDIVID + "» и «" + COL_BASIS + "»."],
        ["Два признака считаются НЕЗАВИСИМО, а не каскадом, поэтому основание"],
        ["показывает состав: B2A, порог, либо B2A+порог одновременно."],
        ["Метка сохраняется и после распределения сегмента: она нужна ЧПД,"],
        ["объясняет происхождение провизий и показывает концентрацию внутри"],
        ["продуктового портфеля."],
        [],
        ["  порог 0,2 % СК:",
         f"{porog:,.0f} ₸".replace(",", " ") if porog else "НЕ ЗАДАН — правило П5 не применялось"],
        ["  перечень индивидуальных:", f"{len(b2a)} БИН" if b2a else "не задан — правило П4 не применялось"],
    ]
    for name, n in per_file:
        rows.append(["    файл:", name, f"{n} БИН"])

    rows += [
        [],
        ["ОТКРЫТЫЕ ВОПРОСЫ — на что опереться нельзя"],
        ["П3  CORINV: флаг f_inv источником не проставляется, сегмент пуст (О3)."],
        ["П4  Перечень индивидуальных: основания в Таблице 4 нет (О6)."],
        ["    При этом П4 даёт подавляющее большинство меток, а П5 — единицы."],
        ["П7-П9 Размер предпринимательства: численность работников и годовой доход"],
        ["    по ст. 24 ПК РК в витрине отсутствуют, ent_type берётся как есть (О2)."],
        ["П2  ЛСБОО: остаётся ли своей строкой формы — не подтверждено (О28)."],
        ["    Текущий режим: --relate " + args.relate],
        ["    CORGOV (госкорпорации) не формируется: нет справочника БИН (О4)."],
        [],
        ["ЧТО ДЕЛАТЬ ОТВЕТСТВЕННОМУ ПОДРАЗДЕЛЕНИЮ"],
        ["1. Строки с сегментом X — разобрать поимённо: ни одно условие не выполнено."],
        ["2. Строки, где условие сработало, но результат неверен, — указать, КАКОЕ"],
        ["   условие даёт неверный результат и почему. Спор о номере условия"],
        ["   продуктивен, спор о сегменте — нет."],
        ["3. Размер предпринимательства (П7-П9) проверяется по двум величинам"],
        ["   ст. 24 ПК РК: среднегодовая численность работников и среднегодовой доход."],
    ]
    return rows


def metodologiya(ws, args, porog, b2a, per_file):
    for r in metod_rows(args, porog, b2a, per_file):
        ws.append(r)


def default_out(template: str) -> str:
    base, ext = os.path.splitext(template)
    return f"{base}_метка_индивид{ext}"


# -------------------------------------------------------------------- отчёт

def report(args, out, ctx, b2a, zadol_bin, porog, per_file, rowcnt, delcnt, plans):
    """Агрегаты в консоль и в CSV рядом с результатом. БИН не выводятся."""
    lines = []
    stat, cross, miss_key = ctx.stat, ctx.cross, ctx.miss_key

    def add(s=""):
        lines.append(s)
        say(s)

    add("")
    add("=== строк обработано ===")
    for t, n in ctx.rows.items():
        note = "" if plans[t].has_zadol else "   (в порог не входит)"
        if rowcnt:
            add(f"  {t:<10} {n:>10,}   неактивных {delcnt.get(t, 0):>8,}{note}")
        else:
            add(f"  {t:<10} {n:>10,}{note}")

    add("")
    add("=== метка индивидуальности, договоров ===")
    for k in ("B2A", "порог", "B2A+порог", "—"):
        if stat.get(k):
            add(f"  {k:<12} {stat[k]:>10,}")

    if b2a:
        hit = {b for b in b2a if b in zadol_bin}
        add("")
        add("=== список Sabila против шаблона (О11) ===")
        for name, n in per_file:
            add(f"  файл {name}: {n} БИН")
        add(f"  union списков:            {len(b2a):>6}")
        add(f"  есть в шаблоне:           {len(hit):>6}")
        add(f"  НЕ найдены в шаблоне:     {len(b2a) - len(hit):>6}   <- Н7: разбираем нашу сторону")

    if porog is not None:
        over = sum(1 for z in zadol_bin.values() if z > porog)
        both = sum(1 for b, z in zadol_bin.items() if z > porog and b in b2a)
        add("")
        add("=== порог 0,2 % СК, заёмщиков ===")
        add(f"  перешагнули порог:           {over:>6}")
        add(f"  из них в списке B2A:         {both:>6}")
        add(f"  прирост порога сверх списка: {over - both:>6}   <- Н24: считано независимо")

    if cross:
        add("")
        add("=== наша метка × ind_sign витрины ===")
        ours = sorted({a for a, _ in cross})
        theirs = sorted({b for _, b in cross})
        add("  " + "метка".ljust(12) + "".join(f"{('ind_sign=' + (b or 'пусто')):>20}" for b in theirs))
        for a in ours:
            add("  " + a.ljust(12) + "".join(f"{cross.get((a, b), 0):>20,}" for b in theirs))
        add("  Расходится — вопрос к витрине до подачи, а не после.")

    if ctx.rule1:
        add("")
        add("=== какое условие сработало, договоров (слой 1) ===")
        for n in sorted(ctx.rule1):
            add(f"  П{n:<3} {RULES[n][0]:<18} {ctx.rule1[n]:>10,}   {RULES[n][1][:52]}")
        add(f"  {'ВСЕГО':<23} {sum(ctx.rule1.values()):>10,}")

    if ctx.seg1:
        add("")
        add("=== слой 1 → слой 2, договоров ===")
        add(f"  {'сегмент':<20} {'договоров':>10}")
        for k, n in ctx.seg1.most_common():
            add(f"  {k:<20} {n:>10,}")
        add("")
        add(f"  {'строка формы':<62} {'договоров':>10}")
        for k, n in ctx.seg2.most_common():
            add(f"  {k[:60]:<62} {n:>10,}")

    if ctx.seg1.get("X"):
        add("")
        add(f"  ! X: {ctx.seg1['X']:,} строк — ни одно условие не выполнено.")
        add("    Это и есть список на ручной разбор: причина в колонке")
        add(f"    «{COL_WHY}», строки распределяются по подразделениям.")
    if miss_key:
        add("")
        for t, n in miss_key.items():
            add(f"  ! ключ не найден в выгрузке С1, лист {t}: {n:,}")
    if ctx.no_casc:
        add("")
        for t, n in ctx.no_casc.items():
            add(f"  ! лист {t}: {n:,} строк без полей каскада — сегмент не считался")
    if ctx.rule1.get(2) and args.relate == "own-row":
        add("")
        add(f"  ! RELATE: {ctx.rule1[2]:,} договоров отнесены к строке «Займы ЛСБОО».")
        add("    В ключевых строках Таблицы 3 ЛСБОО не перечислен — трактуем")
        add("    как самостоятельную строку, но основание не подтверждено.")
        add("    Это О28; обратное поведение — --relate distribute.")

    add("")
    if args.write == "sidecar":
        add(f"результат: {os.path.splitext(out)[0] + '.csv'} (шаблон не изменён)")
    else:
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
  # 1. что в шаблоне
  python nst_fill_2026.py --inspect

  # 2. только метка индивидуальности по перечню Sabila
  python nst_fill_2026.py --fill ^
      --b2a "R:\!!!!!НСТ2026\Сегментация\Индивидуальные заемщики от Сабилы\Список инд. заемщиков для НСТ.xlsx"

  # 2а. перечень Sabila вместе с выгрузкой B2A — union, без отбора (Н7).
  #     Отчёт покажет БИН по каждому файлу отдельно: это прямой замер О11.
  python nst_fill_2026.py --fill --b2a "R:\...\Список инд. заемщиков для НСТ.xlsx" "R:\...\b2a.csv"

  # 3. метка с порогом и сегмент из выгрузки С1
  python nst_fill_2026.py --fill ^
      --b2a "R:\...\Список инд. заемщиков для НСТ.xlsx" ^
      --capital 503086114000 ^
      --seg C:\work\c1_2026.csv

  # 4. шаблон не трогать, отдать CSV под VLOOKUP
  python nst_fill_2026.py --fill --b2a ... --write sidecar
""")
    p.add_argument("--template", default=TEMPLATE_DEFAULT)
    p.add_argument("--inspect", action="store_true", help="показать структуру, ничего не писать")
    p.add_argument("--fill", action="store_true", help="заполнить (в новый файл)")
    p.add_argument("--out", help="куда сохранить; по умолчанию рядом с суффиксом")
    p.add_argument("--force", action="store_true",
                   help="перезаписать --out; для inplace — согласиться на большой лист")
    p.add_argument("--write", choices=("stream", "inplace", "sidecar"), default="stream",
                   help="stream — потоком, память постоянная, формулы теряются (по умолчанию); "
                        "inplace — сохраняет форматирование, но грузит книгу целиком; "
                        "sidecar — только CSV, шаблон не трогается")
    p.add_argument("--sheet", nargs="+", help="какие листы обрабатывать; по умолчанию все")
    p.add_argument("--header-row", type=int, help="строка шапки, если определилась неверно")
    p.add_argument("--head-scan", type=int, default=HEAD_SCAN)

    p.add_argument("--b2a", nargs="+", help="файлы/папки списков Sabila (xlsx, csv)")
    p.add_argument("--capital", type=float,
                   help="собственный капитал на отчётную дату, ₸. Без него порог не считается")
    p.add_argument("--seg", help="CSV выгрузки С1: ключ займа → сегмент СЛОЯ 2")
    p.add_argument("--seg-col-key")
    p.add_argument("--seg-col-segment")
    p.add_argument("--relate", choices=("own-row", "distribute"), default="own-row",
                   help="ЛСБОО: своя строка «Займы ЛСБОО» (по умолчанию) либо "
                        "распределяются как Individual loans. Открыт О28")

    p.add_argument("--col-bin", help="имя колонки БИН в шаблоне")
    p.add_argument("--col-key", help="имя колонки ключа займа")
    p.add_argument("--col-zadol", help="имя колонки задолженности, если она одна")

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
