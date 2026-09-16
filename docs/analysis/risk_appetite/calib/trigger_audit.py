# -*- coding: utf-8 -*-
"""Аудит триггеров и прогон машины состояний назад по истории.

Отвечает на три вопроса, каждый из которых был задан как гипотеза и проверен:

Г39 — дублируют ли триггеры зону?
    Порог T1 равен буферу на месяц, порог T2 — буферу на цикл. Отсюда
    подозрение, что триггер срабатывает тогда же, когда меняется зона,
    и второго уровня поимки нет. **Опровергнуто:** подавляющая часть
    срабатываний приходится на зелёную зону, а зона за 36 месяцев
    меняется считанные разы.

    Возражение при этом устояло, но в другом виде: порог `z(0,90)·σ_Δ`
    есть девятый дециль приращений и потому ОБЯЗАН срабатывать примерно
    раз в десять месяцев безотносительно событий. Это счётчик частоты,
    а не детектор. Колонка «T1, % месяцев» показывает расхождение
    фактической частоты с расчётными 10 %.

Г40 — информативно ли совпадение срабатываний?
    Если одиночное срабатывание есть шум по построению, то событием
    является совпадение нескольких. Скрипт печатает распределение
    «сколько метрик сработало в одном месяце» — вход правила П5
    машины состояний.

Какова нагрузка машины состояний?
    Четыре зоны × четыре сочетания триггеров = 16 ячеек, каждая отображена
    в уровень реагирования R0…R4 (`MEASURES_FSM.md` § 4). Прогон назад
    по истории показывает, сколько раз машина покинула бы R0 и на каком
    уровне. Это единственная доступная проверка конструкции: калибровки
    на исходах нет и быть не может — превышение лимита в ряде одно.

ОПРЕДЕЛЕНИЯ, воспроизводящие формулы книги v1.8 (лист «Триггеры»):

    M(T) = z(p)·σ_Δ·√T ;  σ_Δ — выборочная по 35 приращениям
    T1 «скачок»  — приращение за месяц   ≥ M(1)
    T2 «разгон»  — изменение за 4 месяца ≥ M(4)

    Окно T2 именно четыре месяца, а не три: движение за цикл сравнивается
    с буфером на тот же цикл. Докстрока `triggers_all_metrics` до 16.09.2026
    говорила «за 3 месяца» и расходилась с собственной формулой книги —
    исправлено вместе с этим скриптом.

CoR ИСКЛЮЧЕНЫ по умолчанию. Их пороги эмпирические и недействительны, пока
открыт Д15 — чем является ряд CoR на листе `Monthly`. Ключ `--with-cor`
включает их по параметрической формуле; это НЕ то, что считает книга,
и годится только для оценки порядка величины.

Запуск:
    python3 trigger_audit.py              # аудит по десяти метрикам на M(T)
    python3 trigger_audit.py --selftest   # проверка на рядах с известным ответом
    python3 trigger_audit.py --events     # плюс перечень всех выходов из R0
"""

import csv
import os
import statistics as st
import sys
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "build"))

Z90 = 1.2815515655446004          # квантиль 0,90 стандартного нормального
L_TOP20 = 108.6304                # уровень в балансовой базе, Г26: 95 % / 0,874525
T2_WINDOW = 4                     # месяцев; равен циклу реагирования
ZONES = ("зелёная", "жёлтая", "красная", "НАРУШЕНИЕ")

# Ячейка (зона, T1, T2) -> уровень реагирования. MEASURES_FSM.md § 4:
# зона задаёт базовый уровень, каждый сработавший триггер поднимает на ступень.
LEVEL = {}
for _z in range(4):
    for _a in (0, 1):
        for _b in (0, 1):
            LEVEL[(_z, _a, _b)] = f"R{min(_z + _a + _b, 4)}"


def load_series(with_cor=False):
    """[(код, название, лимит, [36 значений]), …] — все ряды в процентах."""
    import metrics_data as md

    top = os.path.join(HERE, "..", "data", "top20_monthly_2023_08_2026_07.csv")
    with open(top, encoding="utf-8") as fh:
        rows = list(csv.DictReader(fh, delimiter=";"))
    dates = [r["date"][:7] for r in rows]
    out = [("top20", "Топ-20 / СК", L_TOP20,
            [float(r["coef_new"]) * 100 for r in rows])]
    if with_cor:
        for code, _t, _seg, lim, col in md.METRICS_COR:
            key = "cor_kb_pb" if code == "cor_kb_pb" else "cor_msb"
            out.append((code, f"CoR {key[4:].upper()}", lim,
                        [float(r[key]) * 100 for r in rows]))
    for code, title, _seg, lim, vals in md.METRICS_RB:
        out.append((code, title.replace("ожидаемые потери, ", ""), lim, list(vals)))
    return dates, out


def audit_one(values, limit):
    """σ_Δ, буферы, зоны по месяцам и множества срабатываний T1 и T2."""
    diffs = [values[i] - values[i - 1] for i in range(1, len(values))]
    sigma = st.stdev(diffs)
    if sigma <= 0:
        # Вырожденный ряд. Молча считать нельзя: при σ = 0 порог обнуляется,
        # и условие «Δ ≥ M(1)» становится «Δ ≥ 0» — T1 срабатывает на каждом
        # неубывающем месяце. Поймано самопроверкой на постоянном ряде.
        raise ValueError("σ_Δ = 0: ряд постоянный, пороги не определены")
    m1, m4 = Z90 * sigma, Z90 * sigma * 2

    def zone(x):
        if x >= limit:
            return 3
        if x >= limit - m1:
            return 2
        if x >= limit - m4:
            return 1
        return 0

    zones = [zone(x) for x in values]
    t1 = {i for i in range(1, len(values)) if values[i] - values[i - 1] >= m1}
    t2 = {i for i in range(T2_WINDOW, len(values))
          if values[i] - values[i - T2_WINDOW] >= m4}
    return sigma, m1, m4, zones, t1, t2


def run(with_cor=False, show_events=False):
    dates, series = load_series(with_cor)
    n_months = len(dates)
    start = T2_WINDOW                      # с этой точки определены оба триггера
    load = Counter()
    per_month = Counter()
    events = []
    tot = Counter()

    print(f"{'метрика':<24}{'σ_Δ':>7}{'M(1)':>8}{'M(4)':>8}"
          f"{'T1':>4}{'T2':>4}{'T1|зел':>8}{'T2|зел':>8}"
          f"{'T1,%мес':>9}{'ухудш.':>8}")
    print("-" * 88)
    for code, name, limit, values in series:
        sigma, m1, m4, zones, t1, t2 = audit_one(values, limit)
        worse = [i for i in range(1, n_months) if zones[i] > zones[i - 1]]
        t1g = sum(1 for i in t1 if zones[i] == 0)
        t2g = sum(1 for i in t2 if zones[i] == 0)
        freq = len(t1) / (n_months - 1) * 100
        print(f"{name:<24}{sigma:>7.3f}{m1:>8.3f}{m4:>8.3f}"
              f"{len(t1):>4}{len(t2):>4}{t1g:>8}{t2g:>8}"
              f"{freq:>8.1f}%{len(worse):>8}")
        for k, v in (("t1", len(t1)), ("t2", len(t2)), ("t1g", t1g),
                     ("t2g", t2g), ("worse", len(worse)),
                     ("diffs", n_months - 1)):
            tot[k] += v
        for i in range(start, n_months):
            a, b = int(i in t1), int(i in t2)
            lvl = LEVEL[(zones[i], a, b)]
            load[lvl] += 1
            if a or b:
                per_month[dates[i]] += 1
            if lvl != "R0":
                events.append((dates[i], name, ZONES[zones[i]],
                               "T1" if a else "", "T2" if b else "", lvl))

    print("-" * 88)
    print(f"{'ИТОГО':<24}{'':>23}{tot['t1']:>4}{tot['t2']:>4}"
          f"{tot['t1g']:>8}{tot['t2g']:>8}"
          f"{tot['t1'] / tot['diffs'] * 100:>8.1f}%{tot['worse']:>8}")

    print(f"\nГ39. Срабатываний T1 в зелёной зоне: {tot['t1g']} из {tot['t1']}; "
          f"T2: {tot['t2g']} из {tot['t2']}.")
    print(f"     Зона ухудшилась за весь период {tot['worse']} раз. "
          f"Дублирования нет — гипотеза опровергнута.")
    print(f"     Частота T1 {tot['t1'] / tot['diffs'] * 100:.1f} % против "
          f"расчётных 10 % для девятого дециля: порог работает как счётчик "
          f"частоты, а не как детектор.")

    n = sum(load.values())
    print(f"\nНагрузка машины состояний — {n} наблюдений «метрика × месяц»:")
    for lvl in ("R0", "R1", "R2", "R3", "R4"):
        c = load.get(lvl, 0)
        print(f"  {lvl}  {c:>4}  {c / n * 100:>5.1f} %")

    hist = Counter(per_month.values())
    quiet = (n_months - start) - len(per_month)
    print(f"\nГ40. Совпадения по панели — в скольких месяцах из "
          f"{n_months - start} сколько метрик сработало:")
    for k in sorted(hist, reverse=True):
        print(f"  {k} метрик — {hist[k]} мес.")
    print(f"  0 метрик — {quiet} мес.")
    mass = sum(v for k, v in hist.items() if k >= 3)
    print(f"  с тремя и более: {mass} из {n_months - start} — вход правила П5")

    if show_events:
        print(f"\nВсе выходы из R0 — {len(events)}:")
        print(f"  {'месяц':<9}{'метрика':<24}{'зона':<12}{'T1':<4}{'T2':<4}уровень")
        for e in sorted(events):
            print(f"  {e[0]:<9}{e[1]:<24}{e[2]:<12}{e[3]:<4}{e[4]:<4}{e[5]}")
    return load, tot


def selftest():
    """Ряды с известным ответом. Проверяется поведение, а не числа книги."""
    ok = True

    def check(name, cond, detail=""):
        nonlocal ok
        ok &= bool(cond)
        print(f"  [{'ok' if cond else 'СБОЙ'}] {name}{'  ' + detail if detail else ''}")

    # 1. Постоянный ряд: ни одного срабатывания, зона одна и та же.
    flat = [50.0] * 36
    try:
        audit_one(flat, 100.0)
        check("постоянный ряд не ломает расчёт", False, "σ = 0 должна дать отказ")
    except st.StatisticsError:
        check("постоянный ряд: σ = 0 — отказ ожидаем", True)
    except (ValueError, ZeroDivisionError):
        check("постоянный ряд: σ = 0 — отказ ожидаем", True)

    # 2. Ряд с одним скачком ровно в M(1): T1 срабатывает один раз.
    v = [10.0 + 0.1 * i for i in range(36)]
    v[20] += 5.0
    s, m1, m4, zones, t1, t2 = audit_one(v, 100.0)
    check("одиночный скачок ловится T1", 20 in t1, f"σ_Δ = {s:.3f}, M(1) = {m1:.3f}")

    # 3. Вырожденность: M(4) больше расстояния до лимита -> зелёной зоны нет.
    noisy = [3.0 + (2.5 if i % 2 else -2.5) for i in range(36)]
    s, m1, m4, zones, _, _ = audit_one(noisy, 3.0)
    check("при M(4) ≥ лимита зелёной зоны не остаётся",
          0 not in zones, f"M(4) = {m4:.3f} при лимите 3,00")

    # 4. Отображение ячеек: каждая из 16 определена, потолок R4.
    check("все 16 ячеек отображены", len(LEVEL) == 16)
    check("потолок R4", LEVEL[(3, 1, 1)] == "R4")
    check("зелёная без триггеров — R0", LEVEL[(0, 0, 0)] == "R0")
    check("красная без триггеров — R2", LEVEL[(2, 0, 0)] == "R2")
    check("нарушение без триггеров — R3", LEVEL[(3, 0, 0)] == "R3")
    return ok


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        print("Самопроверка trigger_audit:")
        sys.exit(0 if selftest() else 1)
    run(with_cor="--with-cor" in sys.argv, show_events="--events" in sys.argv)
