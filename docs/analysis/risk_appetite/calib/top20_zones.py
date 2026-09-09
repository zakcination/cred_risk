# -*- coding: utf-8 -*-
"""Зонирование топ-20 на месячном ряде 08.2023 — 07.2026: сетка допустимости и пять методов.

Данные: data/top20_monthly_2023_08_2026_07.csv (лист Monthly, дамп 08.09.2026).
Ничего не выбирает (§ 6): перебирает параметры и показывает, какие сочетания удовлетворяют
критериям автора, а какие нет. Вердикт «ни одно» — тоже результат перебора, а не мнение.

Критерии автора (заданы 07.09.2026):
  T   >= 4 месяца хода до пробоя
  X   <= 10 % доля времени в жёлтой зоне
  ложные серии жёлтого <= 2 месяцев подряд
  двойное условие: σ уровней популяционная по всему ряду + σ приращений выборочная по окну 12 или 24

Запуск: python3 top20_zones.py            (все разделы)
        python3 top20_zones.py --selftest  (контроль тождества Займ/СК)
"""
import csv, math, os, statistics as st, sys
from statistics import NormalDist

HERE = os.path.dirname(os.path.abspath(__file__))
CSV = os.path.join(HERE, os.pardir, "data", "top20_monthly_2023_08_2026_07.csv")
T_REQ, X_MAX, FALSE_RUN_MAX = 4, 10.0, 2
N = NormalDist()


def load():
    with open(CSV, encoding="utf-8") as f:
        rows = list(csv.DictReader(f, delimiter=";"))
    num = lambda s: float(s) if s not in ("", None) else None
    return {
        "date":     [r["date"][:7] for r in rows],
        "zaim":     [num(r["zaim_mln"]) for r in rows],
        "sk_old":   [num(r["sk_old_mln"]) for r in rows],
        "sk_new":   [num(r["sk_new_mln"]) for r in rows],
        "old":      [None if num(r["coef_old"]) is None else num(r["coef_old"])*100 for r in rows],
        "new":      [num(r["coef_new"])*100 for r in rows],
    }


def ma(a, k=3):
    return [None if i < k-1 or any(v is None for v in a[i-k+1:i+1])
            else sum(a[i-k+1:i+1])/k for i in range(len(a))]


def deltas(a):
    return [a[i]-a[i-1] for i in range(1, len(a)) if a[i] is not None and a[i-1] is not None]


def selftest(D):
    bad = 0
    for i in range(len(D["date"])):
        if D["old"][i] is not None and abs(D["zaim"][i]/D["sk_old"][i]*100 - D["old"][i]) > 1e-7:
            bad += 1
        if abs(D["zaim"][i]/D["sk_new"][i]*100 - D["new"][i]) > 1e-7:
            bad += 1
    print("контроль тождества Займ/СК: расхождений %d" % bad)
    return bad == 0


# ---------- сетка ----------

def sigma_delta_upto(a, w, t):
    d = [a[i]-a[i-1] for i in range(1, t+1) if a[i] is not None and a[i-1] is not None]
    d = d[-w:]
    return st.stdev(d) if len(d) >= 3 else None


def evaluate(a, L, aa, b, a0, w):
    sig_L = st.pstdev([v for v in a if v is not None])
    z = []
    for t in range(len(a)):
        x = a[t]
        if x is None:
            z.append(None); continue
        if x >= L:
            z.append("К"); continue
        dist = (L - x)/sig_L
        delta = (a[t]-a[t-1]) if t and a[t-1] is not None else None
        sd = sigma_delta_upto(a, w, t)
        B = delta is not None and sd not in (None, 0) and delta >= b*sd
        z.append("Ж" if ((dist <= aa and B) or dist <= a0) else "З")
    ok = [v for v in z if v is not None]
    share = 100.0*ok.count("Ж")/len(ok) if ok else 0.0
    warns = []
    for t in range(len(z)):
        if z[t] == "К" and (t == 0 or z[t-1] != "К"):
            k = 0; i = t-1
            while i >= 0 and z[i] == "Ж":
                k += 1; i -= 1
            warns.append((t, k))
    testable = [(t, k) for t, k in warns if t >= T_REQ]
    min_warn = min((k for _, k in testable), default=None)
    false_max = n_false = 0
    i = 0
    while i < len(z):
        if z[i] == "Ж":
            j = i
            while j+1 < len(z) and z[j+1] == "Ж":
                j += 1
            if (z[j+1] if j+1 < len(z) else None) != "К":
                false_max = max(false_max, j-i+1); n_false += 1
            i = j+1
        else:
            i += 1
    ok_v = (share <= X_MAX and false_max <= FALSE_RUN_MAX and testable
            and min_warn >= T_REQ)
    return dict(share=share, n_red=len(warns), n_testable=len(testable),
                min_warn=min_warn, false_max=false_max, n_false=n_false, ok=bool(ok_v))


def grid(D, out_csv=None):
    S = {"NEW": D["new"], "MA3": ma(D["new"], 3)}
    rows = []
    for sn, a in S.items():
        for L in (95.0, 100.0, 105.0, 108.63):
            for w in (12, 24):
                for aa in [x/4 for x in range(2, 25)]:
                    for b in [x/4 for x in range(0, 13)]:
                        for a0 in [0.0] + [x/4 for x in range(1, 9)]:
                            if a0 > aa:
                                continue
                            r = evaluate(a, L, aa, b, a0, w)
                            r.update(series=sn, L=L, a=aa, b=b, a0=a0, w=w)
                            rows.append(r)
    good = [r for r in rows if r["ok"]]
    print("=== СЕТКА ДОПУСТИМОСТИ ===")
    print("  комбинаций: %d, прошедших все три критерия: %d" % (len(rows), len(good)))
    if out_csv:
        with open(out_csv, "w", newline="", encoding="utf-8-sig") as f:
            wtr = csv.DictWriter(f, fieldnames=["series", "L", "w", "a", "b", "a0", "share",
                                                "n_red", "n_testable", "min_warn", "false_max",
                                                "n_false", "ok"], delimiter=";")
            wtr.writeheader(); wtr.writerows(rows)
        print("  сетка записана: %s" % out_csv)
    return rows


def methods(D):
    a = D["new"]
    sd = st.stdev(deltas(a)); sig_L = st.pstdev(a)
    print("\n=== ПЯТЬ МЕТОДОВ: где встаёт жёлтая линия (ряд NEW) ===")
    for L in (95.0, 108.63):
        n = len(a); xs = list(range(n)); mx = st.mean(xs); my = st.mean(a)
        bb = sum((xs[i]-mx)*(a[i]-my) for i in range(n))/sum((x-mx)**2 for x in xs)
        aq = my - bb*mx
        resid = [a[i]-(aq+bb*xs[i]) for i in range(n)]
        srt = sorted(a)
        m = {
            "М1 параметрический (L-1σ_ур)":   L - sig_L,
            "М2 тренд+остаток (L-1σ_ост)":    L - st.pstdev(resid),
            "М3 эмпирический 90-й перцентиль": srt[int(math.ceil(0.90*n))-1],
            "М4 первое достижение P=10%,T=4":  L - N.inv_cdf(0.90)*sd*math.sqrt(T_REQ),
        }
        print("  L = %.2f %%" % L)
        for k, v in m.items():
            share = 100.0*sum(1 for x in a if x >= v)/n
            print("    %-34s %7.2f %%   доля времени выше %5.1f %%" % (k, v, share))
        print("    %-34s %7.2f %%" % ("разброс методов, пп", max(m.values())-min(m.values())))


def current(D):
    a = D["new"]; sd = st.stdev(deltas(a))
    print("\n=== ТЕКУЩАЯ ТОЧКА %s: коэффициент %.2f %% ===" % (D["date"][-1], a[-1]))
    for L in (95.0, 100.0, 105.0, 108.63, 118.25, 121.93):
        z = (L - a[-1])/(sd*math.sqrt(T_REQ))
        print("  L=%-7.2f запас %+7.2f пп = %+5.2f σ_Δ   P(коснуться за %d мес.) = %5.1f %%"
              % (L, L-a[-1], (L-a[-1])/sd, T_REQ, 100*(1-N.cdf(z))))
    print("\n  снос (МНК):", end="")
    for w in (36, 12, 6):
        seg = a[-w:]; xs = list(range(w)); mx = st.mean(xs); my = st.mean(seg)
        bb = sum((xs[i]-mx)*(seg[i]-my) for i in range(w))/sum((x-mx)**2 for x in xs)
        print("  %d мес. %+0.3f пп/мес" % (w, bb), end="")
    print()


def decomposition(D):
    print("\n=== РАЗЛОЖЕНИЕ ДВУХ ДВИЖЕНИЙ ===")
    for i0, i1, tag in ((28, 29, "12.2025 -> 01.2026"), (31, 35, "03.2026 -> 07.2026")):
        n0, n1 = D["zaim"][i0], D["zaim"][i1]
        e0, e1 = D["sk_new"][i0], D["sk_new"][i1]
        dc = (n1/e1 - n0/e0)*100
        num = (n1-n0)/e0*100
        cap = n0*(1/e1 - 1/e0)*100
        print("  %s  Δкоэф %+6.2f пп = числитель %+6.2f (%3.0f %%) + капитал %+6.2f (%3.0f %%) + перекр. %+.2f"
              % (tag, dc, num, 100*num/dc, cap, 100*cap/dc, dc-num-cap))


if __name__ == "__main__":
    D = load()
    if "--selftest" in sys.argv:
        sys.exit(0 if selftest(D) else 1)
    selftest(D)
    grid(D, os.path.join(HERE, "top20_zone_grid.csv"))
    methods(D)
    current(D)
    decomposition(D)
