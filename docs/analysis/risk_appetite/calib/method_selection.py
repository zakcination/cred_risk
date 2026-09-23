# -*- coding: utf-8 -*-
"""Правило выбора метода разметки зон и разметка всех двенадцати кредитных метрик.

Источник всех чисел раздела `INSERT_11_metrik.md`. Заменяет `zones_all12.py`.

ЕДИНЫЙ ПОДХОД. Для всех двенадцати показателей общие: уровень доверия 90 %,
окно — 36 месячных наблюдений (08.2023 — 07.2026), четыре зоны Приложения № 2,
граница красной зоны — один отчётный период хода до уровня, ежегодная
перекалибровка. Различается только способ оценки хода показателя.

ОСНОВНОЙ МЕТОД — запас времени M(T) = z(0,90)·σ_Δ·√T, T = 4 и T = 1 месяц.
Выбран для топ-20 и применяется к любому показателю, выполняющему три условия.
Условия выведены из предпосылок самой формулы, а не из результата:

  К1. Невырожденность. Буфер на цикл реагирования меньше уровня:
      L − M(4) > 0. Иначе граница зелёной зоны лежит ниже нуля и зона
      пуста по построению.
  К2. Однородность хода по календарю. Одна σ и множитель √T предполагают,
      что приращения всех месяцев одинаково распределены. Проверка —
      равенство дисперсий приращений месяцев годового закрытия
      (февраль–март) и остальных месяцев, тест Левене с центрированием
      по медиане (Brown–Forsythe), уровень 5 %. Тест выбран потому, что
      приращения большинства рядов ненормальны, а классический F-тест
      к ненормальности неустойчив; его p-значение печатается для раскрытия.
  К3. Адекватность. Буфер z·σ·√T не уже эмпирического 90-го процентиля
      фактических T-месячных изменений более чем на допуск 25 % —
      удвоенную стандартную ошибку оценки σ на 35 приращениях
      (1/√(2·34) ≈ 12 %). Проверяется при T = 1 и T = 4.

Формальная нормальность месячных приращений условием НЕ является: формула
работает с суммой T приращений, и достаточность буфера проверяется прямо (К3).

ЗАМЕЩАЮЩИЙ МЕТОД — для показателя, не выполнившего хотя бы одно условие.
Та же доверительная вероятность, то же окно, оценка непараметрическая:
  граница зелёной  = 90-й процентиль значений показателя за 36 месяцев
                     после отсечения выбросов по правилу Тьюки (1,5 × IQR);
  граница красной  = L − Q90 месячного изменения (эмпирический аналог M(1));
  порог T1 / T2    = Q90 месячного / четырёхмесячного изменения.
Граница зелёной — решение автора. Граница красной и пороги триггеров —
предложение, требующее подтверждения; печатается с этой пометкой.

    python3 method_selection.py              # все таблицы
    python3 method_selection.py --csv        # + ../data/zones_all12.csv
    python3 method_selection.py --selftest
"""

import csv
import os
import statistics as st
import sys
from collections import Counter

import numpy as np
from scipy import stats

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import trigger_audit as ta                                      # noqa: E402

Z = ta.Z90
P = 0.90
TOL = 0.25                  # К3: 2·SE(σ) на 35 приращениях
ALPHA = 0.05                # К2: уровень теста Левене
CLOSE = ("02", "03")        # месяцы годового закрытия
IQR_K = 1.5                 # правило Тьюки
OUT = os.path.join(HERE, "..", "data", "zones_all12.csv")
RETAIL = ("el_", "pd_")


def q90(x):
    return float(np.quantile(np.asarray(x, dtype=float), P))


def tsum(v, T):
    return [v[i + T] - v[i] for i in range(len(v) - T)]


def criteria(v, L, dates):
    """Три условия применимости M(T). dates — 'ГГГГ-ММ' той же длины, что v."""
    d = np.diff(v)
    s = float(np.std(d, ddof=1))
    if s <= 0:
        raise ValueError("σ_Δ = 0: ряд постоянный")
    m1, m4 = Z * s, Z * s * 2
    green, yellow = L - m4, L - m1
    k1 = green > 0

    close = np.array([dates[i + 1][5:7] in CLOSE for i in range(len(d))])
    a, b = d[close], d[~close]
    ratio = float(np.std(a, ddof=1) / np.std(b, ddof=1))
    p_lev = float(stats.levene(a, b, center="median").pvalue)
    f = np.var(a, ddof=1) / np.var(b, ddof=1)
    p_f = float(2 * min(stats.f.cdf(f, len(a) - 1, len(b) - 1),
                        stats.f.sf(f, len(a) - 1, len(b) - 1)))
    dm = d - d.mean()
    share = float((dm[close] ** 2).sum() / (dm ** 2).sum())
    k2 = p_lev >= ALPHA

    dev = {}
    for T in (1, 4):
        emp = q90(tsum(v, T))
        dev[T] = (Z * s * T ** 0.5 - emp) / abs(emp) if emp else float("inf")
    k3 = min(dev.values()) >= -TOL

    return dict(sigma=s, m1=m1, m4=m4, green=green, yellow=yellow,
                k1=k1, ratio=ratio, p_lev=p_lev, p_f=p_f, share=share,
                n_close=int(close.sum()), k2=k2, dev1=dev[1], dev4=dev[4],
                k3=k3, ok=k1 and k2 and k3)


def tukey_trim(v):
    """Значения внутри заборов Тьюки и отсечённые (индекс, значение)."""
    q1, q3 = np.quantile(v, [0.25, 0.75])
    lo, hi = q1 - IQR_K * (q3 - q1), q3 + IQR_K * (q3 - q1)
    keep = [x for x in v if lo <= x <= hi]
    cut = [(i, x) for i, x in enumerate(v) if not lo <= x <= hi]
    return keep, cut


def empirical(v, L):
    """Замещающий метод. Возвращает границы, пороги и отсечённые точки."""
    keep, cut = tukey_trim(v)
    g = q90(keep)
    q1m, q4m = q90(tsum(v, 1)), q90(tsum(v, 4))
    return dict(green=g, green_raw=q90(v), yellow=L - q1m, t1=q1m,
                t2=max(q4m, q1m), cut=cut)


def zone_of(x, g, y, L):
    return 3 if x >= L else 2 if x >= y else 1 if x >= g else 0


ZN = ("зелёная", "жёлтая", "красная", "НАРУШЕНИЕ")


def fsm_load(v, g, y, L, thr1, thr4):
    """Уровни R0…R4 по месяцам, где определены оба триггера (с 5-го)."""
    zones = [zone_of(x, g, y, L) for x in v]
    t1 = {i for i in range(1, len(v)) if v[i] - v[i - 1] >= thr1}
    t2 = {i for i in range(ta.T2_WINDOW, len(v))
          if v[i] - v[i - ta.T2_WINDOW] >= thr4}
    lv = Counter(ta.LEVEL[(zones[i], int(i in t1), int(i in t2))]
                 for i in range(ta.T2_WINDOW, len(v)))
    return lv, len(t1), len(t2), zones


def evaluate():
    dates, series = ta.load_series(with_cor=True)
    rows = []
    for code, name, L, v in series:
        c = criteria(v, L, dates)
        r = dict(code=code, name=name, L=L, v=v, c=c, fact=v[-1],
                 retail=code.startswith(RETAIL))
        if c["ok"]:
            r.update(method="M(T)", green=c["green"], yellow=c["yellow"],
                     t1=c["m1"], t2=c["m4"], cut=[], proposal=False)
        else:
            e = empirical(v, L)
            r.update(method="эмпирический", green=e["green"], yellow=e["yellow"],
                     t1=e["t1"], t2=e["t2"], cut=e["cut"], green_raw=e["green_raw"],
                     proposal=True)
        r["zone"] = ZN[zone_of(r["fact"], r["green"], r["yellow"], L)]
        r["load"], r["n_t1"], r["n_t2"], r["zones"] = fsm_load(
            v, r["green"], r["yellow"], L, r["t1"], r["t2"])
        rows.append(r)
    return dates, rows


def mark(b):
    return "да" if b else "НЕТ"


def run(dump=False):
    dates, rows = evaluate()
    print(f"Окно {dates[0]} — {dates[-1]}, {len(dates)} мес.; p = {P}, z = {Z:.4f}")
    print("\n1. ТРИ УСЛОВИЯ ПРИМЕНИМОСТИ ЗАПАСА ВРЕМЕНИ\n")
    print(f"{'показатель':<32}{'гр.зел.':>9}{'К1':>4}"
          f"{'σфм/σпр':>9}{'доля фм':>9}{'Левене p':>10}{'F p':>8}{'К2':>4}"
          f"{'T=1':>7}{'T=4':>7}{'К3':>4}  метод")
    print("-" * 112)
    for r in rows:
        c = r["c"]
        print(f"{r['name']:<32}{c['green']:>9.3f}{mark(c['k1']):>4}"
              f"{c['ratio']:>9.2f}{c['share']:>8.0%} {c['p_lev']:>10.4f}"
              f"{c['p_f']:>8.4f}{mark(c['k2']):>4}"
              f"{c['dev1']:>+7.0%}{c['dev4']:>+7.0%}{mark(c['k3']):>4}  {r['method']}")
    n = rows[0]["c"]["n_close"]
    print(f"\nК1: граница зелёной L − M(4) > 0. К2: Левене (медиана) p ≥ {ALPHA}; "
          f"«доля фм» — доля дисперсии приращений,\nприходящаяся на {n} из 35 "
          f"приращений февраля–марта (при однородности ≈ {n / 35:.0%}). "
          f"К3: расхождение буфера с эмпирическим Q90\nне ниже −{TOL:.0%}; "
          f"плюс — модель шире факта.")
    worst = min(rows, key=lambda r: min(r["c"]["dev1"], r["c"]["dev4"])
                if r["c"]["k1"] else 9)
    print(f"Ближайший к порогу К3: {worst['name']} "
          f"({min(worst['c']['dev1'], worst['c']['dev4']):+.0%}).")
    f_only = [r["name"] for r in rows if r["c"]["p_f"] < ALPHA and r["c"]["k2"]]
    if f_only:
        print(f"Раскрытие: F-тест на уровне 5 % отклонил бы также: {', '.join(f_only)}; "
              f"на уровне 1 % оба теста выделяют только: "
              f"{', '.join(r['name'] for r in rows if r['c']['p_f'] < .01)}.")

    print("\n2. ГРАНИЦЫ ЗОН И ПОЛОЖЕНИЕ НА 07.2026\n")
    print(f"{'показатель':<32}{'метод':>13}{'уровень':>9}{'факт':>9}"
          f"{'гр.зел.':>9}{'гр.кр.':>9}{'зона':>10}{'запас, пп':>11}{'в σ':>7}{'утил.':>7}")
    print("-" * 116)
    for r in rows:
        room = r["green"] - r["fact"]
        dist = (r["L"] - r["fact"]) / r["c"]["sigma"]
        print(f"{r['name']:<32}{r['method']:>13}{r['L']:>9.2f}{r['fact']:>9.2f}"
              f"{r['green']:>9.3f}{r['yellow']:>9.3f}{r['zone']:>10}"
              f"{room:>+11.2f}{dist:>7.1f}{r['fact'] / r['L']:>7.0%}"
              + ("  *" if r["proposal"] else ""))
    print("«запас, пп» — до границы зелёной; «в σ» — (уровень − факт)/σ_Δ; "
          "* — граница красной — предложение.")

    print("\n3. ЗАМЕЩАЮЩИЙ МЕТОД — ПОДРОБНО\n")
    for r in rows:
        if r["method"] == "M(T)":
            continue
        v = r["v"]
        cut = ", ".join(f"{dates[i]}: {x:+.2f}" for i, x in r["cut"]) or "нет"
        above = [(dates[i], x) for i, x in enumerate(v) if x >= r["green"]]
        pos = [dates[i] for i, x in enumerate(v) if x > 0]
        d = np.diff(v)
        i_mx = int(np.argmax(d))
        print(f"── {r['name']}, уровень {r['L']:.2f}, факт {r['fact']:+.3f} → {r['zone']}")
        print(f"   отсечено по Тьюки: {cut}")
        print(f"   граница зелёной {r['green']:+.3f} ({r['green'] / r['L']:.1%} уровня); "
              f"без отсечения {r['green_raw']:+.3f} — сдвиг "
              f"{r['green'] - r['green_raw']:+.3f} пп")
        print(f"   граница красной L − Q90(1 мес) = {r['yellow']:.3f}   "
              f"пороги T1 {r['t1']:.3f}, T2 {r['t2']:.3f}   [предложение]")
        print(f"   месяцев не ниже границы зелёной: {len(above)} из {len(v)} — "
              + ", ".join(f"{m} {x:+.2f}" for m, x in above))
        print(f"   наибольшее месячное повышение: {dates[i_mx + 1]} {d[i_mx]:+.3f} пп "
              f"= {d[i_mx] / r['L']:.0%} уровня")
        print(f"   месяцев с положительным значением: {len(pos)}"
              + (f" — {pos[0]} … {pos[-1]}" if pos else ""))
        print()

    print("4. НАГРУЗКА МАШИНЫ МЕР, 32 месяца × показатель\n")
    groups = (("девять розничных", [r for r in rows if r["retail"]]),
              ("топ-20", [r for r in rows if r["code"] == "top20"]),
              ("две CoR [пороги — предложение]",
               [r for r in rows if r["method"] != "M(T)"]))
    for title, sel in groups:
        tot = sum((r["load"] for r in sel), Counter())
        n = sum(tot.values())
        t1, t2 = sum(r["n_t1"] for r in sel), sum(r["n_t2"] for r in sel)
        print(f"   {title:<34} наблюдений {n:>4}:  "
              + "  ".join(f"{k} {tot.get(k, 0):>3}" for k in ("R0", "R1", "R2", "R3", "R4"))
              + f"   срабатываний T1 {t1}, T2 {t2}")
    ret = [r for r in rows if r["retail"]]
    print("   по розничным: " + "; ".join(
        f"{r['name'].replace('ожидаемые потери, ', '')} {r['n_t1']}/{r['n_t2']}"
        for r in ret))
    t1r = sum(r["n_t1"] for r in ret)
    print(f"   частота T1 по розничным: {t1r} из {35 * len(ret)} = "
          f"{t1r / (35 * len(ret)):.1%} (расчётная 10 %)")

    if dump:
        with open(OUT, "w", encoding="utf-8", newline="") as fh:
            w = csv.writer(fh, delimiter=";")
            w.writerow(["metric", "method", "limit", "fact", "sigma_d",
                        "k1_green_mt", "k2_ratio", "k2_levene_p", "k2_f_p",
                        "k3_dev_t1", "k3_dev_t4", "green_bound", "red_bound",
                        "t1", "t2", "zone", "dist_sigma", "utilisation",
                        "red_bound_is_proposal"])
            for r in rows:
                c = r["c"]
                w.writerow([r["name"], r["method"], f"{r['L']:.4f}",
                            f"{r['fact']:.4f}", f"{c['sigma']:.4f}",
                            f"{c['green']:.4f}", f"{c['ratio']:.3f}",
                            f"{c['p_lev']:.4f}", f"{c['p_f']:.4f}",
                            f"{c['dev1']:.3f}", f"{c['dev4']:.3f}",
                            f"{r['green']:.4f}", f"{r['yellow']:.4f}",
                            f"{r['t1']:.4f}", f"{r['t2']:.4f}", r["zone"],
                            f"{(r['L'] - r['fact']) / c['sigma']:.2f}",
                            f"{r['fact'] / r['L']:.4f}", int(r["proposal"])])
        print(f"\nвыгружено: {os.path.normpath(OUT)}")
    return rows


def selftest():
    ok = True

    def check(name, cond, detail=""):
        nonlocal ok
        ok &= bool(cond)
        print(f"  [{'ok' if cond else 'СБОЙ'}] {name}{'  ' + detail if detail else ''}")

    rng = np.random.default_rng(7)
    dates = [f"{2023 + (7 + i) // 12}-{(7 + i) % 12 + 1:02d}" for i in range(36)]

    # К2 ловит календарный режим и не ловит однородный ряд
    d = rng.normal(0, 0.1, 35)
    d_reg = d.copy()
    for i in range(35):
        if dates[i + 1][5:7] in CLOSE:
            d_reg[i] *= 6
    flat = np.concatenate([[5.0], 5.0 + np.cumsum(d)])
    reg = np.concatenate([[5.0], 5.0 + np.cumsum(d_reg)])
    check("К2 отклоняет ряд с шестикратной σ в феврале–марте",
          not criteria(reg, 50.0, dates)["k2"],
          f"p = {criteria(reg, 50.0, dates)['p_lev']:.4f}")
    check("К2 принимает однородный ряд", criteria(flat, 50.0, dates)["k2"],
          f"p = {criteria(flat, 50.0, dates)['p_lev']:.4f}")

    # К1 ловит вырожденную зону
    noisy = [3.0 + (2.5 if i % 2 else -2.5) for i in range(36)]
    check("К1 отклоняет ряд, у которого M(4) больше уровня",
          not criteria(noisy, 3.0, dates)["k1"])

    # Тьюки: отсекает подложенный выброс, не трогает остальное
    base = list(np.linspace(0.0, 1.0, 35)) + [-9.0]
    keep, cut = tukey_trim(base)
    check("Тьюки отсекает ровно подложенный выброс",
          len(cut) == 1 and cut[0][1] == -9.0, f"отсечено {len(cut)}")

    # реальные данные
    _dates, rows = evaluate()
    by = {r["code"]: r for r in rows}
    check("показателей двенадцать", len(rows) == 12)
    emp = sorted(r["code"] for r in rows if r["method"] != "M(T)")
    check("замещающий метод — ровно две CoR", emp == ["cor_kb_pb", "cor_msb"], str(emp))
    check("CoR КБ не проходит К1 и К2",
          not by["cor_kb_pb"]["c"]["k1"] and not by["cor_kb_pb"]["c"]["k2"])
    check("CoR МСБ проходит К1, не проходит К2",
          by["cor_msb"]["c"]["k1"] and not by["cor_msb"]["c"]["k2"])
    check("ни один показатель на M(T) не занижает буфер сверх допуска",
          all(r["c"]["k3"] for r in rows if r["method"] == "M(T)"))
    t = by["top20"]
    check("границы топ-20 совпадают с запиской: 98,21 / 103,42",
          round(t["green"], 2) == 98.21 and round(t["yellow"], 2) == 103.42,
          f"{t['green']:.2f} / {t['yellow']:.2f}")
    s, m1, m4, *_ = ta.audit_one(t["v"], t["L"])
    check("M(1), M(4) совпадают с trigger_audit",
          abs(m1 - t["t1"]) < 1e-12 and abs(m4 - t["t2"]) < 1e-12)
    check("лестница CoR монотонна: зелёная < красная < уровень",
          all(r["green"] < r["yellow"] < r["L"] for r in rows
              if r["method"] != "M(T)"))
    ret = sum((r["load"] for r in rows if r["retail"]), Counter())
    check("нагрузка по розничным: R0 259, R1 24, R2 5",
          (ret["R0"], ret["R1"], ret["R2"], ret["R3"]) == (259, 24, 5, 0), str(dict(ret)))
    return ok


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        print("Самопроверка method_selection:")
        sys.exit(0 if selftest() else 1)
    run(dump="--csv" in sys.argv)
