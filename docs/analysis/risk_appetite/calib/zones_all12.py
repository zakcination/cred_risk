# -*- coding: utf-8 -*-
"""Разметка всех двенадцати кредитных метрик и диагностика пригодности зоны.

Записка размечает одну метрику — топ-20. Требование п. 18 Правил № 86 относится
ко всем. Этот прогон закрывает разрыв и одновременно отвечает на вопрос, который
возникает сразу за ним: **одинаково ли осмысленна зона на всех двенадцати.**

Ответ — нет, и это не дефект метода, а результат. Диагностика — расстояние
до уровня в единицах волатильности:

    D = (уровень − факт) / σ_Δ

и время, за которое метрика физически дойдёт до уровня при наблюдавшейся
волатильности. Оно получается обращением формулы запаса времени: если
M(T) = z·σ·√T должно сравняться с расстоянием, то

    T* = (D / z)²  месяцев.

Три класса, и граница между ними в данных, а не назначена:

    A. D < 5 σ    — зона работает: метрика в досягаемости уровня
    B. D ≥ 15 σ, но утилизация ≥ 70 % — зона по запасу времени пуста,
                    осмысленную границу даёт стресс-якорь
    C. D ≥ 15 σ и утилизация < 35 % — метрика далеко от уровня при любом
                    методе; вопрос к уровню, а не к разметке

Порог 15 σ взят из `ZONES_METHOD.md`, метод D: «если > 15–20 σ, зонирование
бессмысленно, пересматривать надо лимит». Он назначен не нами и не под результат.

ОГОВОРКА, БЕЗ КОТОРОЙ ЧИСЛА ВВОДЯТ В ЗАБЛУЖДЕНИЕ. T* считается на σ окна
08.2023 — 07.2026. Окно благополучное: EL и PD падают три года подряд. «548 лет»
означает «при такой же волатильности, как последние три года», а не «никогда».
Структурный сдвиг меняет σ, и тогда меняется всё.

Запуск:
    python3 zones_all12.py            # таблица и сводка
    python3 zones_all12.py --csv      # + выгрузка в ../data/zones_all12.csv
    python3 zones_all12.py --selftest
"""

import csv
import os
import statistics as st
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "build"))

Z90 = 1.2815515655446004
L_TOP20 = 108.6304
D_WORKS = 5.0        # ниже — зона работает
D_EMPTY = 15.0       # выше — зона по запасу времени пуста (ZONES_METHOD, метод D)
UTIL_TIGHT = 70.0    # утилизация, при которой стресс-якорь ещё что-то говорит
UTIL_FAR = 35.0      # ниже — метрика далеко при любом методе


def load():
    """[(название, уровень, ряд, признак CoR), …] — все двенадцать, в процентах."""
    import metrics_data as md
    with open(os.path.join(HERE, "..", "data",
                           "top20_monthly_2023_08_2026_07.csv"),
              encoding="utf-8") as fh:
        top = list(csv.DictReader(fh, delimiter=";"))
    out = [("Топ-20 / СК", L_TOP20,
            [float(r["coef_new"]) * 100 for r in top], False)]
    for _c, title, _s, lim, vals in md.METRICS_RB:
        name = (title.replace("ожидаемые потери, ", "")
                     .replace("вероятность дефолта, ", ""))
        out.append((name, lim, list(vals), False))
    for code, _t, _s, lim, _col in md.METRICS_COR:
        key = "cor_kb_pb" if code == "cor_kb_pb" else "cor_msb"
        out.append((f"CoR {key[4:].upper().replace('_', '/')}", lim,
                    [float(r[key]) * 100 for r in top], True))
    return out


def assess(limit, values):
    """σ_Δ, буферы, границы, зона, диагностика D и T*."""
    diffs = [values[i] - values[i - 1] for i in range(1, len(values))]
    sigma = st.stdev(diffs)
    if sigma <= 0:
        raise ValueError("σ_Δ = 0: ряд постоянный")
    m1, m4 = Z90 * sigma, Z90 * sigma * 2
    fact = values[-1]
    green, yellow = limit - m4, limit - m1
    if fact >= limit:
        zone = "НАРУШЕНИЕ"
    elif fact >= yellow:
        zone = "красная"
    elif fact >= green:
        zone = "жёлтая"
    else:
        zone = "зелёная"
    dist = (limit - fact) / sigma
    tstar = (dist / Z90) ** 2 if dist > 0 else 0.0
    util = fact / limit * 100
    return dict(sigma=sigma, m1=m1, m4=m4, fact=fact, green=green,
                yellow=yellow, zone=zone, dist=dist, tstar=tstar,
                util=util, degenerate=green <= 0)


def classify(a):
    """Класс пригодности зоны. Возвращает (буква, краткое описание)."""
    if a["dist"] <= 0:
        return "A", "уровень превышен"
    if a["degenerate"]:
        return "A", "зона вырождена — нужен эмпирический метод"
    if a["dist"] < D_WORKS:
        return "A", "зона работает"
    if a["dist"] >= D_EMPTY and a["util"] >= UTIL_TIGHT:
        return "B", "зона пуста; граница — от стресс-якоря"
    if a["dist"] >= D_EMPTY and a["util"] < UTIL_FAR:
        return "C", "далеко при любом методе; вопрос к уровню"
    return "B", "промежуточный случай — решает автор"


def ru_time(months):
    if months < 12:
        return f"{months:.0f} мес"
    return f"{months / 12:.0f} лет"


def run(dump_csv=False):
    rows = []
    for name, limit, vals, is_cor in load():
        a = assess(limit, vals)
        cls, note = classify(a)
        rows.append((name, limit, is_cor, a, cls, note))
    rows.sort(key=lambda r: (r[4], r[3]["dist"]))

    print(f"{'метрика':<30}{'уровень':>8}{'факт':>8}{'σ_Δ':>7}"
          f"{'гр.зел':>9}{'гр.жёл':>9}{'зона':>11}{'D, σ':>7}{'T*':>9}"
          f"{'утил':>6}{'кл':>4}")
    print("-" * 108)
    last = None
    for name, limit, is_cor, a, cls, _n in rows:
        if last and cls != last:
            print("-" * 108)
        last = cls
        print(f"{name:<30}{limit:>8.2f}{a['fact']:>8.2f}{a['sigma']:>7.3f}"
              f"{a['green']:>9.2f}{a['yellow']:>9.2f}{a['zone']:>11}"
              f"{a['dist']:>7.1f}{ru_time(a['tstar']):>9}"
              f"{a['util']:>5.0f}%{cls:>4}")
    print("-" * 108)

    for cls, title in (("A", "зона по запасу времени работает"),
                       ("B", "зона пуста, граница — от стресс-якоря"),
                       ("C", "метрика далеко при любом методе")):
        sel = [r for r in rows if r[4] == cls]
        print(f"\n{cls}. {title}: {len(sel)} из {len(rows)}")
        for name, _l, _c, a, _cl, note in sel:
            print(f"     {name:<30}D = {a['dist']:>5.1f} σ, T* = "
                  f"{ru_time(a['tstar']):<9} — {note}")

    works = [r for r in rows if r[4] == "A"]
    rest = [r for r in rows if r[4] != "A"]
    if works and rest:
        print(f"\nРазрыв в выборке: максимум D среди класса A = "
              f"{max(r[3]['dist'] for r in works):.1f} σ, "
              f"минимум среди остальных = {min(r[3]['dist'] for r in rest):.1f} σ. "
              f"Граница между классами лежит в данных, а не назначена.")
    cors = [r[0] for r in rows if r[2]]
    print(f"\nПредварительно (открыт вопрос об источнике ряда): {', '.join(cors)}")

    if dump_csv:
        p = os.path.join(HERE, "..", "data", "zones_all12.csv")
        with open(p, "w", encoding="utf-8", newline="") as fh:
            w = csv.writer(fh, delimiter=";")
            w.writerow(["metric", "limit", "fact", "sigma_d", "m1", "m4",
                        "green_bound", "yellow_bound", "zone", "dist_sigma",
                        "tstar_months", "utilisation_pct", "class",
                        "provisional"])
            for name, limit, is_cor, a, cls, _n in rows:
                w.writerow([name, f"{limit:.4f}", f"{a['fact']:.4f}",
                            f"{a['sigma']:.4f}", f"{a['m1']:.4f}",
                            f"{a['m4']:.4f}", f"{a['green']:.4f}",
                            f"{a['yellow']:.4f}", a["zone"],
                            f"{a['dist']:.2f}", f"{a['tstar']:.1f}",
                            f"{a['util']:.2f}", cls, int(is_cor)])
        print(f"\nвыгружено: {os.path.normpath(p)}")
    return rows


def selftest():
    ok = True

    def check(name, cond, detail=""):
        nonlocal ok
        ok &= bool(cond)
        print(f"  [{'ok' if cond else 'СБОЙ'}] {name}{'  ' + detail if detail else ''}")

    # T* обращает формулу запаса времени: при T = T* буфер равен расстоянию
    a = assess(10.0, [5.0 + 0.1 * (i % 3) for i in range(36)])
    m_at_tstar = Z90 * a["sigma"] * (a["tstar"] ** 0.5)
    check("T* обращает M(T): буфер при T* равен расстоянию",
          abs(m_at_tstar - (10.0 - a["fact"])) < 1e-6,
          f"{m_at_tstar:.6f} против {10.0 - a['fact']:.6f}")

    # вырожденный случай ловится
    noisy = [3.0 + (2.5 if i % 2 else -2.5) for i in range(36)]
    b = assess(3.0, noisy)
    check("вырожденная зона распознана", b["degenerate"],
          f"граница зелёной {b['green']:.3f}")
    check("вырожденная попадает в класс A", classify(b)[0] == "A")

    # классы на реальных данных
    rows = [(n, l, c, assess(l, v)) for n, l, v, c in load()]
    cls = [classify(a)[0] for _n, _l, _c, a in rows]
    check("метрик двенадцать", len(rows) == 12, f"получено {len(rows)}")
    check("класс A — три метрики", cls.count("A") == 3, f"A={cls.count('A')}")
    check("классы покрывают все метрики",
          cls.count("A") + cls.count("B") + cls.count("C") == 12)
    works = [a["dist"] for (_n, _l, _c, a), k in zip(rows, cls) if k == "A"]
    rest = [a["dist"] for (_n, _l, _c, a), k in zip(rows, cls) if k != "A"]
    check("между классами есть разрыв", min(rest) - max(works) > 10,
          f"{max(works):.1f} σ против {min(rest):.1f} σ")
    check("обе CoR помечены предварительными",
          sum(1 for _n, _l, c, _a in rows if c) == 2)
    return ok


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        print("Самопроверка zones_all12:")
        sys.exit(0 if selftest() else 1)
    run(dump_csv="--csv" in sys.argv)
