# -*- coding: utf-8 -*-
"""Зона как переключатель частоты наблюдения, а не как предсказание.

Зелёная  x <  y            ежемесячно
Жёлтая   y <= x < L        еженедельно
Красная  x >= L            еженедельно + эскалация

Гистерезис: выход из ускоренного режима только после k подряд месяцев ниже y.
"""
import csv, math, os, statistics as st
from statistics import NormalDist

import os
HERE = os.path.dirname(os.path.abspath(__file__))
CSV = os.path.join(HERE, os.pardir, "data", "top20_monthly_2023_08_2026_07.csv")
rows = list(csv.DictReader(open(CSV, encoding="utf-8"), delimiter=";"))
DATE = [r["date"][:7] for r in rows]
X = [float(r["coef_new"])*100 for r in rows]
n = len(X)
sd = st.stdev([X[i]-X[i-1] for i in range(1, n)])
N = NormalDist()

def run(L, y, k):
    """k — сколько месяцев подряд ниже y нужно, чтобы вернуться в ежемесячный режим."""
    zone, fast, below = [], [], 0
    state = False                       # True = ускоренный режим
    for i, x in enumerate(X):
        z = "К" if x >= L else ("Ж" if x >= y else "З")
        zone.append(z)
        if z in ("Ж", "К"):
            state, below = True, 0
        elif state:
            below += 1
            if below >= k:
                state = False
        fast.append(state)
    switches = sum(1 for i in range(1, n) if fast[i] != fast[i-1]) + (1 if fast[0] else 0)
    share_fast = 100.0*sum(fast)/n
    # предупреждение перед каждым красным эпизодом: месяцев в ускоренном режиме до него
    warns = []
    for i in range(n):
        if zone[i] == "К" and (i == 0 or zone[i-1] != "К"):
            j, c = i-1, 0
            while j >= 0 and fast[j]:
                c += 1; j -= 1
            warns.append((DATE[i], c))
    testable = [c for d, c in warns if DATE.index(d) >= 1]
    return dict(zone="".join(zone), share_fast=share_fast, switches=switches,
                warns=warns, min_warn=min(testable) if testable else None,
                n_red=len(warns), reports=12 + share_fast/100.0*(52-12))

print("σ приращений месячного ряда: %.2f пп; текущая точка %s = %.2f %%\n" % (sd, DATE[-1], X[-1]))

for L in (95.0, 100.0, 105.0, 108.63):
    print("=" * 74)
    print("УРОВЕНЬ L = %.2f %%   (красных месяцев: %d из %d)"
          % (L, sum(1 for x in X if x >= L), n))
    print("%-8s %8s %9s %9s %8s %10s" %
          ("жёлт y", "доля уск.", "переключ", "предупр", "отч/год", "запас, σ_Δ"))
    ys = [L - t*sd for t in (0.25, 0.5, 0.75, 1.0, 1.5, 2.0)]
    for y in ys:
        r = run(L, y, k=2)
        w = "нет крас." if r["min_warn"] is None else ("%d мес." % r["min_warn"])
        print("%-8.2f %7.1f %% %9d %9s %8.0f %10.2f"
              % (y, r["share_fast"], r["switches"], w, r["reports"], (L-y)/sd))

print("\n" + "=" * 74)
print("ГИСТЕРЕЗИС: сколько месяцев ниже жёлтой линии нужно для возврата (L=108.63, y=L-1σ_Δ)")
y = 108.63 - sd
print("%-4s %10s %10s" % ("k", "доля уск.", "переключений"))
for k in (1, 2, 3, 4):
    r = run(108.63, y, k)
    print("%-4d %9.1f %% %10d" % (k, r["share_fast"], r["switches"]))

print("\n" + "=" * 74)
print("ЦЕНА КАЖДОЙ УСТУПКИ (L = 108,63 %, гистерезис 2 мес.)")
print("%-34s %10s %10s %10s" % ("вариант", "предупр", "доля уск.", "отч/год"))
for lab, y in (("жёлтая = L - 0,25σ_Δ (101,6 %)", 108.63-0.25*sd),
               ("жёлтая = L - 0,5σ_Δ  (100,6 %)", 108.63-0.5*sd),
               ("жёлтая = L - 1σ_Δ    (104,6→)", 108.63-1.0*sd),
               ("жёлтая = L - 1,5σ_Δ", 108.63-1.5*sd),
               ("жёлтая = L - 2σ_Δ", 108.63-2.0*sd)):
    r = run(108.63, y, 2)
    w = "нет крас." if r["min_warn"] is None else ("%d мес." % r["min_warn"])
    print("%-34s %10s %9.1f %% %10.0f" % (lab, w, r["share_fast"], r["reports"]))

print("\n" + "=" * 74)
print("НЕДЕЛЬНЫЙ РЯД: та же конструкция при σ_Δ = 2,225 пп (окно с 2019, 06_summary2)")
sw = 2.225
for L in (95.0, 108.63):
    for T in (2, 4, 8):
        y = L - N.inv_cdf(0.90)*sw*math.sqrt(T)
        print("  L=%-7.2f предупреждение %d нед. (%.1f мес.) -> жёлтая линия %.2f %%, запас %.2f пп"
              % (L, T, T/4.33, y, L-y))
