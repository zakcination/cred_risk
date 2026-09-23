#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Сортировка двенадцати кредитных метрик по нормальности и разметка зон.

Задача в три шага:
  1. проверить, какие метрики подчиняются нормальному распределению;
  2. к нормальным применить согласованный метод M(T) = z(p)·σ_Δ·√T;
  3. к ненормальным применить историческую симуляцию и разметить зоны.

    python3 normality_triage.py            # все таблицы
    python3 normality_triage.py --csv      # + ../data/zones_by_method.csv

ВЫБОР МЕТОДА ПО ЗОНАМ ЗДЕСЬ БОЛЬШЕ НЕ ДЕЛАЕТСЯ. Шаг 3 и `zones_by_method.csv`
отбирают замещающий метод только по вырожденности и занижению (К1, К3) и не
проверяют однородность хода по календарю (К2). Действующее правило — все три
условия — и разметка, на которую ссылается записка, — в `method_selection.py`.
Здесь остаются формальные тесты нормальности (шаг 1), решающая проверка
(шаг 2) и режимная симуляция CoR, на которые записка ссылается как на доводы.

────────────────────────────────────────────────────────────────────────────
ЧТО ИМЕННО ПРОВЕРЯЕТСЯ, И ПОЧЕМУ НЕ ПРОСТО «НОРМАЛЬНОСТЬ»

Учебниковая проверка идёт по приращениям Δ. Но M(T) опирается не на Δ,
а на СУММУ T приращений, и по центральной предельной теореме сумма ближе
к нормальной, чем слагаемое. Метрика может провалить Шапиро-Уилка на Δ
и при этом давать верный квантиль на сумме — именно он и нужен формуле.

Поэтому проверок две, и решает вторая:

  A. Формальная — Шапиро-Уилк, Жарк-Бера, Андерсон-Дарлинг по Δ.
  B. Решающая — совпадает ли нормальный квантиль z·σ·√T с эмпирическим
     квантилем фактических T-месячных изменений при том же p.

ВЕРДИКТ ТРЁХЗНАЧНЫЙ, И НАПРАВЛЕНИЕ РАСХОЖДЕНИЯ ВАЖНЕЕ ВЕЛИЧИНЫ:

  • совпадает (≤ 25 %)                      → M(T), модель верна;
  • модель ЗАВЫШАЕТ буфер                   → M(T) годится, она консервативна;
                                              завышение безопасно, его объявляют;
  • модель ЗАНИЖАЕТ буфер                   → опасно, нужна замена;
  • завышение настолько велико, что
    M(4) ≥ лимита                           → зона вырождается, метод НЕПРИГОДЕН
                                              не по безопасности, а по полезности.

Последний случай — ровно CoR КБ/ПБ: M(4) = 3,2850 при лимите 3,00, граница
зелёной уходит в минус. Формально безопасно, практически бесполезно.

Порог 25 % — удвоенная собственная погрешность σ (±12 % на 36 точках):
внутри этого коридора расхождение неразличимо от шума оценки самой σ.
Порог — предмет решения автора.

АЛЬТЕРНАТИВА ДЛЯ НЕНОРМАЛЬНЫХ: историческая симуляция — эмпирический
p-квантиль фактических T-месячных изменений, без предположения о форме.
Это не самодельный приём: BCBS d457 (MAR30) допускает историческую
симуляцию наравне с параметрической моделью, и для тяжёлых хвостов она
в практике преобладает. Для CoR у неё есть дополнительное преимущество,
которого нет у σ: календарный режим (σ февраля-марта впятеро выше прочих,
Г36) попадает в эмпирическое распределение сам, в своей естественной доле,
тогда как единая σ его размазывает.

ЦЕНА МЕТОДА, КОТОРУЮ НАДО ОБЪЯВЛЯТЬ. Окна перекрываются: на 36 точках при
T = 4 их 32, но независимых всего 8. Эмпирический квантиль 0,90 по восьми
независимым наблюдениям — это фактически максимум выборки. Он честен в том
смысле, что не додумывает хвост, но его точность низкая, и повышать её
нечем, кроме удлинения ряда.
"""

import argparse
import csv
import os
import statistics as st
import sys

import numpy as np
from scipy import stats

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "build"))
from metrics_data import load_rb, METRICS_COR                    # noqa: E402

DATA = os.path.join(HERE, "..", "data")
T20 = os.path.join(DATA, "top20_monthly_2023_08_2026_07.csv")
OUT = os.path.join(DATA, "zones_by_method.csv")

P = 0.90
Z = stats.norm.ppf(P)
K_G26 = 439961.267 / 503086.114
TOL = 0.25                       # порог расхождения A/B, решение автора


def series():
    """(код, имя, лимит, 36 значений). Все ряды месячные."""
    with open(T20, encoding="utf-8") as fh:
        rows = list(csv.DictReader(fh, delimiter=";"))
    out = [("top20", "Топ-20 / СК", 95.0 / K_G26,
            [float(r["coef_new"]) * 100 for r in rows])]
    for code, name, seg, lim, _c in METRICS_COR:
        out.append((f"{code}", f"CoR {seg.replace('_', '/')}", lim,
                    [float(r[code]) * 100 for r in rows]))
    _d, rb = load_rb()
    for code, name, seg, lim, vals in rb:
        out.append((code, name.replace("ожидаемые потери, ", ""), lim, vals))
    return out


def tsum_changes(v, T):
    """Фактические T-месячные изменения, перекрывающиеся окна."""
    return [v[i + T] - v[i] for i in range(len(v) - T)]


def block_formal(data):
    print("=" * 96)
    print("ШАГ 1 — ФОРМАЛЬНАЯ ПРОВЕРКА НОРМАЛЬНОСТИ ПРИРАЩЕНИЙ (n = 35)\n")
    print(f"{'метрика':30s} {'асим.':>7s} {'эксц.':>7s} "
          f"{'Шапиро p':>9s} {'Жарк-Бера p':>12s} {'Андерсон A²':>12s} {'вердикт':>10s}")
    res = {}
    for code, name, lim, v in data:
        d = np.diff(v)
        sw = stats.shapiro(d)
        jb = stats.jarque_bera(d)
        ad = stats.anderson(d, dist="norm")
        ok = sw.pvalue > 0.05 and jb.pvalue > 0.05 and ad.statistic < 0.752
        res[code] = ok
        print(f"{name:30s} {stats.skew(d):7.3f} {stats.kurtosis(d, fisher=False):7.2f} "
              f"{sw.pvalue:9.4f} {jb.pvalue:12.4f} {ad.statistic:12.3f} "
              f"{'НОРМА' if ok else 'НЕ норма':>10s}")
    print("\nПороги: Шапиро и Жарк-Бера p > 0,05; Андерсон A² < 0,752 (5 %).")
    print("«НЕ норма» = провалена хотя бы одна из трёх.\n")
    return res


def block_decisive(data):
    print("=" * 96)
    print("ШАГ 2 — РЕШАЮЩАЯ ПРОВЕРКА: совпадает ли квантиль модели с фактическим\n")
    print(f"сравнивается z·σ·√T против эмпирического {P:.0%}-квантиля "
          f"фактических T-месячных изменений\n")
    print(f"{'метрика':30s} " + " ".join(f"{'T='+str(T):>22s}" for T in (1, 4))
          + f" {'вердикт':>10s}")
    print(f"{'':30s} " + " ".join(f"{'модель':>7s} {'факт':>7s} {'расх.':>6s}"
                                  for _ in (1, 4)) + "")
    res = {}
    for code, name, lim, v in data:
        s = st.stdev(np.diff(v))
        line, worst, under = f"{name:30s} ", 0.0, False
        for T in (1, 4):
            model = Z * s * (T ** 0.5)
            emp = float(np.quantile(tsum_changes(v, T), P))
            dev = (model - emp) / abs(emp) if emp else float("inf")
            worst = max(worst, abs(dev))
            under |= dev < -TOL
            line += f" {model:7.4f} {emp:7.4f} {dev:+5.0%}"
        s_ = st.stdev(np.diff(v))
        degen = Z * s_ * 2 >= lim                      # M(4) ≥ лимита
        if degen:
            v_ = "ВЫРОЖДЕН"
        elif worst <= TOL:
            v_ = "ГОДЕН"
        elif under:
            v_ = "ЗАНИЖАЕТ"
        else:
            v_ = "консерв."
        res[code] = v_
        print(line + f" {v_:>10s}")
    print(f"\nПорог {TOL:.0%} = удвоенная собственная погрешность σ (±12 % на 36 точках).")
    print("«консерв.» = модель завышает буфер: безопасно, зона шире нужного.")
    print("«ЗАНИЖАЕТ» = модель уже фактического хода: опасно, требует замены.")
    print("«ВЫРОЖДЕН» = M(4) ≥ лимита, граница зелёной уходит за него: метод непригоден.\n")
    return res


def ladder(v, lim, T_yellow=4, T_red=1, empirical=False):
    """Границы лестницы. empirical=True — исторический квантиль вместо z·σ·√T.

    МОНОТОННОСТЬ. z·σ·√T растёт с T по построению, эмпирический квантиль — нет:
    у метрики с сильным трендом вниз 90-й процентиль четырёхмесячных изменений
    может оказаться МЕНЬШЕ месячного, потому что снос съедает рост. Тогда
    граница зелёной уходит выше жёлтой и лестница переворачивается. Здесь это
    чинится явным `max`, а факт срабатывания возвращается наружу — прятать его
    нельзя, это свойство метода, а не округление.
    """
    s = st.stdev(np.diff(v))
    if empirical:
        my = float(np.quantile(tsum_changes(v, T_yellow), P))
        mr = float(np.quantile(tsum_changes(v, T_red), P))
    else:
        my, mr = Z * s * T_yellow ** 0.5, Z * s * T_red ** 0.5
    fixed = my < mr
    my = max(my, mr)
    return lim - my, lim - mr, my, mr, fixed


def zones_of(v, g, y, lim):
    """Раскладка ряда по зонам: зелёная / жёлтая / красная / нарушение."""
    c = [0, 0, 0, 0]
    for x in v:
        c[0 if x < g else 1 if x < y else 2 if x < lim else 3] += 1
    return c


def block_zones(data, verdict, want_csv):
    print("=" * 96)
    print("ШАГ 3 — ЗОНЫ. Нормальным — M(T); ненормальным — историческая симуляция\n")
    print(f"{'метрика':30s} {'метод':14s} {'лимит':>8s} {'зел./жёл.':>10s} "
          f"{'жёл./кр.':>10s} {'факт':>9s} {'зона':>9s} {'з/ж/к/н из 36':>15s}")
    rows = []
    for code, name, lim, v in data:
        emp = verdict[code] in ("ВЫРОЖДЕН", "ЗАНИЖАЕТ")
        g, y, my, mr, fixed = ladder(v, lim, empirical=emp)
        c = zones_of(v, g, y, lim)
        x = v[-1]
        zone = "зелёная" if x < g else "жёлтая" if x < y else "красная" if x < lim else "НАРУШЕН"
        print(f"{name:30s} {'ист. симуляция' if emp else 'M(T) = z·σ·√T':14s} "
              f"{lim:8.2f} {g:10.4f} {y:10.4f} {x:9.4f} {zone:>9s} "
              f"{f'{c[0]}/{c[1]}/{c[2]}/{c[3]}':>15s}"
              + ("   ← лестница переворачивалась, выправлена" if fixed else ""))
        rows.append(dict(metric=code, name=name, method="empirical" if emp else "MT",
                         limit=round(lim, 4), green_yellow=round(g, 4),
                         yellow_red=round(y, 4), fact=round(x, 4), zone=zone,
                         n_green=c[0], n_yellow=c[1], n_red=c[2], n_breach=c[3]))
    if want_csv:
        with open(OUT, "w", encoding="utf-8", newline="") as fh:
            w = csv.DictWriter(fh, fieldnames=list(rows[0]), delimiter=";")
            w.writeheader(); w.writerows(rows)
        print("\nзаписано", os.path.relpath(OUT, HERE))
    return rows


def block_cor_detail(data, verdict):
    """Развёрнуто по двум CoR — ради них всё и затевалось."""
    print("\n" + "=" * 96)
    print("CoR ПОДРОБНО: два метода рядом, чтобы видеть цену выбора\n")
    for code, name, lim, v in data:
        if not code.startswith("cor"):
            continue
        s = st.stdev(np.diff(v))
        print(f"── {name}, лимит {lim:.2f}, σ_Δ = {s:.4f}, факт {v[-1]:+.4f}")
        for emp, tag in ((False, "M(T) = z·σ·√T"), (True, "историческая симуляция")):
            g, y, my, mr, _f = ladder(v, lim, empirical=emp)
            c = zones_of(v, g, y, lim)
            x = v[-1]
            zone = ("зелёная" if x < g else "жёлтая" if x < y else
                    "красная" if x < lim else "НАРУШЕН")
            print(f"   {tag:24s} M(4)={my:7.4f} M(1)={mr:7.4f}  "
                  f"границы {g:8.4f} / {y:8.4f}  факт → {zone.upper()}")
            print(f"   {'':24s} раскладка 36 точек: зелёная {c[0]}, жёлтая {c[1]}, "
                  f"красная {c[2]}, нарушение {c[3]}")
        ind = (len(v) - 1) // 4
        print(f"   независимых 4-месячных окон: {ind} (перекрывающихся "
              f"{len(v) - 4}) — точность квантиля низкая, это цена метода\n")


CLOSE = {"02", "03"}          # окно годового закрытия, установлено в Г36


def block_regime(data):
    """Режимная историческая симуляция для CoR — прямое применение Г36.

    Безрежимный квантиль страдает тем же, чем и единая σ: он усредняет по
    календарю, а движение CoR в феврале-марте пятикратно сильнее. Здесь
    квантиль считается раздельно, и каждая точка ряда оценивается границей
    СВОЕГО месяца. Это не подгонка: разделение объявлено заранее находкой
    Г36 и проверено на всех двенадцати метриках — календарный режим есть
    только у двух CoR.
    """
    with open(T20, encoding="utf-8") as fh:
        dates = [r["date"] for r in csv.DictReader(fh, delimiter=";")]
    print("=" * 96)
    print("РЕЖИМНАЯ ИСТОРИЧЕСКАЯ СИМУЛЯЦИЯ ДЛЯ CoR (Г36)\n")
    for code, name, lim, v in data:
        if not code.startswith("cor"):
            continue
        d1 = [(dates[i + 1], v[i + 1] - v[i]) for i in range(len(v) - 1)]
        w4 = [(dates[i + 1:i + 5], v[i + 4] - v[i]) for i in range(len(v) - 4)]
        bnd = {}
        print(f"── {name}, лимит {lim:.2f}, факт {v[-1]:+.4f}\n")
        print(f"   {'режим':20s} {'n(1м)':>6s} {'Q90(1м)':>9s} {'n(4м)':>6s} "
              f"{'Q90(4м)':>9s} {'гр. зел.':>9s} {'гр. жёлт.':>10s}")
        for tag, sel in (("обычные месяцы", False), ("окно закрытия", True)):
            a1 = [x for dt, x in d1 if (dt[5:7] in CLOSE) == sel]
            a4 = [x for ms, x in w4
                  if any(m[5:7] in CLOSE for m in ms) == sel]
            q1 = float(np.quantile(a1, P))
            q4 = max(float(np.quantile(a4, P)), q1)
            bnd[sel] = (lim - q4, lim - q1)
            print(f"   {tag:20s} {len(a1):6d} {q1:9.4f} {len(a4):6d} {q4:9.4f} "
                  f"{lim - q4:9.4f} {lim - q1:10.4f}")
        c = [0, 0, 0, 0]
        for i, x in enumerate(v):
            g, y = bnd[dates[i][5:7] in CLOSE]
            c[0 if x < g else 1 if x < y else 2 if x < lim else 3] += 1
        t = sum(c)
        print(f"\n   ОЖИДАЕМАЯ РАСКЛАДКА 36 ТОЧЕК (каждая — границей своего месяца):")
        print(f"     зелёная {c[0]:2d} ({100 * c[0] / t:4.1f} %)   "
              f"жёлтая {c[1]:2d} ({100 * c[1] / t:4.1f} %)   "
              f"красная {c[2]:2d} ({100 * c[2] / t:4.1f} %)   "
              f"нарушение {c[3]:2d} ({100 * c[3] / t:4.1f} %)")
        g, y = bnd[dates[-1][5:7] in CLOSE]
        z = ("ЗЕЛЁНАЯ" if v[-1] < g else "ЖЁЛТАЯ" if v[-1] < y
             else "КРАСНАЯ" if v[-1] < lim else "НАРУШЕН")
        print(f"     текущая точка {dates[-1]} (обычный месяц) → {z}\n")
    print("   ОГОВОРКИ, без которых цифры подавать нельзя:")
    print("     • в окне закрытия n(1м) = 6 — три года по два месяца; квантиль 0,90")
    print("       по шести наблюдениям есть фактически максимум выборки;")
    print("     • там же лестница вырождается: Q90(4м) < Q90(1м), выправлено max,")
    print("       и граница зелёной совпала с жёлтой — в закрытие зон две, а не три;")
    print("     • открыта Д15: чем является ряд CoR, неизвестно. Любая разметка")
    print("       CoR остаётся предварительной до ответа владельца файла.\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", action="store_true")
    a = ap.parse_args()
    data = series()
    block_formal(data)
    verdict = block_decisive(data)
    block_zones(data, verdict, a.csv)
    block_cor_detail(data, verdict)
    block_regime(data)


if __name__ == "__main__":
    main()
