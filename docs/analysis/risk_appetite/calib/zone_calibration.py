#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Калибровка зон риск-аппетита и проверка их на устаревание.

Два режима:

  python3 zone_calibration.py --selftest
      прогон на синтетическом ряде с известным ответом

  python3 zone_calibration.py ряд.csv --limit 95 --regime-start 2023-02-20
      ряд.csv: две колонки date,value (значение метрики в тех же единицах, что лимит)

Что считает:
  1. Якоря порога       — от максимума режима вверх, от лимита вниз, по квантилям
  2. Развёртка порогов  — запас предупреждения против числа ложных срабатываний
  3. Триггер по скорости — по приращениям, с привязкой к уровню
  4. Тесты на устаревание — Kupiec, Christoffersen, доля времени в зоне,
                            разлом дисперсии, PSI, дрейф максимума

Ничего не печатает в файлы. Стандартный вывод — таблицы и вердикт.
"""
from __future__ import annotations
import argparse, csv, math, sys
from dataclasses import dataclass
from datetime import date, timedelta

import numpy as np
from scipy import stats

# ────────────────────────────────────────────────────────────── утилиты ──
def chi2_p(stat: float, df: int) -> float:
    return float(stats.chi2.sf(stat, df))

def fmt(x, n=2):
    return f"{x:,.{n}f}".replace(",", " ").replace(".", ",")

def hdr(t):
    print("\n" + t)
    print("─" * max(len(t), 60))

# ─────────────────────────────────────────────────────── загрузка ряда ──
@dataclass
class Series:
    d: list          # даты
    v: np.ndarray    # значения
    limit: float
    regime_start: date | None = None

    @property
    def mask_regime(self):
        if self.regime_start is None:
            return np.ones(len(self.v), bool)
        return np.array([x >= self.regime_start for x in self.d])

    def regime(self):
        m = self.mask_regime
        return [x for x, k in zip(self.d, m) if k], self.v[m]

def load(path, limit, regime_start):
    d, v = [], []
    with open(path, encoding="utf8") as f:
        for row in csv.DictReader(l for l in f if not l.startswith("#")):
            k = {c.lower(): c for c in row}
            d.append(date.fromisoformat(row[k["date"]][:10]))
            v.append(float(str(row[k["value"]]).replace(",", ".")))
    o = np.argsort(d)
    return Series([d[i] for i in o], np.array(v)[o], limit, regime_start)

# ──────────────────────────────────────────────── 1. якоря для порога ──
def normal_window(s: Series, runup: int = 13):
    """Нормальный режим = ряд до эпизода. Эпизод начинается не с пробоя, а с разгона,
    поэтому из ряда исключается окно runup наблюдений перед первым пробоем."""
    dr, vr = s.regime()
    br = np.where(vr >= s.limit)[0]
    if not len(br):
        return vr, None
    cut = max(int(br[0]) - runup, 1)
    return vr[:cut], int(br[0])

def anchors(s: Series, runup: int = 13):
    dr, vr = s.regime()
    normal, _ = normal_window(s, runup)
    diffs = np.diff(normal)
    sd = float(np.std(diffs, ddof=1)) if len(diffs) > 1 else float("nan")
    mx = float(normal.max())
    hdr("1. Якоря порога")
    print(f"наблюдений в режиме        {len(vr)}  (из них в нормальном окне {len(normal)})")
    print(f"максимум нормального режима {fmt(mx)}   "
          f"(исключено {runup} наблюдений разгона перед пробоем)")
    print(f"σ приращений нормального окна {fmt(sd, 3)}")
    print(f"лимит                       {fmt(s.limit)}")
    print()
    print(f"{'метод':38}{'значение':>12}{'комментарий':>34}")
    for k in (1, 2, 3):
        print(f"{'от максимума режима + ' + str(k) + ' σ':38}{fmt(mx + k*sd):>12}"
              f"{'поведение показателя' if k==2 else '':>34}")
    for q in (0.90, 0.95, 0.99):
        print(f"{'квантиль ряда ' + str(int(q*100)) + ' %':38}{fmt(float(np.quantile(normal, q))):>12}{'':>34}")
    for share in (0.80, 0.85, 0.90):
        val = s.limit * share
        warn = "ВНУТРИ обычного диапазона" if val <= mx else ""
        print(f"{'доля от лимита ' + str(int(share*100)) + ' %':38}{fmt(val):>12}{warn:>34}")
    return mx, sd

# ─────────────────────────────────────── 2. развёртка порогов по ряду ──
def sweep(s: Series, lo=None, hi=None, step=1.0, runup: int = 13):
    dr, vr = s.regime()
    br = np.where(vr >= s.limit)[0]
    first_breach = int(br[0]) if len(br) else None
    dr_arr = np.array(dr)
    normal, _ = normal_window(s, runup)
    mx = float(normal.max())
    lo = mx - 2 if lo is None else lo
    hi = s.limit - step if hi is None else hi
    if hi <= lo:
        hi = lo + step * 4
    sd_n = float(np.std(np.diff(normal), ddof=1))
    hdr("2. Развёртка порогов: запас предупреждения против ложных срабатываний")
    print(f"{'порог':>9}{'над макс., σ':>14}{'ложных':>9}{'предупр., дней':>16}{'время в зоне':>14}")
    out = []
    sd = sd_n
    t = lo
    while t <= hi + 1e-9:
        sig = np.where(vr >= t)[0]
        if first_breach is None:
            false_n, lead = len(sig), None
        else:
            pre = sig[sig < first_breach]
            false_n = 0 if len(pre) else 0
            # ложное = сигнал, после которого пробоя не случилось в горизонте 2 кварталов
            false_n = int(sum(1 for i in pre
                              if not ((vr[i:i+26] >= s.limit).any())))
            lead = (dr_arr[first_breach] - dr_arr[pre[0]]).days if len(pre) else 0
        tiz = 100 * float((vr >= t).mean())
        out.append((t, false_n, lead, tiz))
        print(f"{fmt(t):>9}{fmt((t-mx)/sd,1):>14}{false_n:>9}"
              f"{(str(lead) if lead is not None else '—'):>16}{fmt(tiz,1)+' %':>14}")
        t += step
    return out

# ───────────────────────────────────────────── 3. триггер по скорости ──
def speed(s: Series, level_floor=None):
    dr, vr = s.regime()
    diffs = np.diff(vr)
    br = np.where(vr >= s.limit)[0]
    fb = int(br[0]) if len(br) else None
    hdr("3. Триггер по скорости")
    print(f"{'порог, ед.':>12}{'срабатываний':>14}{'из них до пробоя':>18}{'с привязкой к уровню':>22}")
    for th in (2, 3, 4, 5, 6, 8):
        idx = np.where(diffs >= th)[0] + 1
        pre = [i for i in idx if fb is None or i < fb]
        bound = [i for i in pre if level_floor is None or vr[i] >= level_floor]
        print(f"{th:>12}{len(idx):>14}{len(pre):>18}{len(bound):>22}")
    print(f"\nмаксимальное приращение за наблюдение: {fmt(float(diffs.max()))}")
    if level_floor is not None:
        print(f"нижняя граница подтверждения: {fmt(level_floor)}")

# ──────────────────────────────────────── 4. тесты на устаревание зон ──
def kupiec(x: int, T: int, p: float):
    """LR unconditional coverage. x — число срабатываний, p — ожидаемая доля."""
    if T == 0 or p <= 0 or p >= 1:
        return float("nan"), float("nan")
    ph = x / T
    if x == 0:
        lr = -2 * (T * math.log(1 - p))
    elif x == T:
        lr = -2 * (T * math.log(p))
    else:
        lr = -2 * ((T - x) * math.log(1 - p) + x * math.log(p)
                   - (T - x) * math.log(1 - ph) - x * math.log(ph))
    return lr, chi2_p(lr, 1)

def christoffersen(flags: np.ndarray):
    """LR independence: кластеризуются ли срабатывания."""
    f = flags.astype(int)
    n = {(0,0):0, (0,1):0, (1,0):0, (1,1):0}
    for a, b in zip(f[:-1], f[1:]):
        n[(int(a), int(b))] += 1
    n00, n01, n10, n11 = n[(0,0)], n[(0,1)], n[(1,0)], n[(1,1)]
    if (n00 + n01) == 0 or (n10 + n11) == 0:
        return float("nan"), float("nan")
    p0 = n01 / (n00 + n01)
    p1 = n11 / (n10 + n11)
    p  = (n01 + n11) / (n00 + n01 + n10 + n11)
    def L(a, b, pr):
        if pr in (0, 1):
            return 0.0
        return a * math.log(1 - pr) + b * math.log(pr)
    lr = -2 * (L(n00 + n10, n01 + n11, p) - L(n00, n01, p0) - L(n10, n11, p1))
    return lr, chi2_p(lr, 1)

def variance_break(s: Series, split: date):
    dr, vr = s.regime()
    dr = np.array(dr)
    a = np.diff(vr[dr < split]); b = np.diff(vr[dr >= split])
    if len(a) < 3 or len(b) < 3:
        return None
    va, vb = float(np.var(a, ddof=1)), float(np.var(b, ddof=1))
    F = max(va, vb) / min(va, vb)
    d1, d2 = (len(a)-1, len(b)-1) if va >= vb else (len(b)-1, len(a)-1)
    return va, vb, F, float(stats.f.sf(F, d1, d2)) * 2

def psi(base: np.ndarray, cur: np.ndarray, bins=10):
    edges = np.quantile(base, np.linspace(0, 1, bins + 1))
    edges[0], edges[-1] = -np.inf, np.inf
    e = np.histogram(base, edges)[0] / len(base)
    a = np.histogram(cur,  edges)[0] / len(cur)
    e = np.clip(e, 1e-6, None); a = np.clip(a, 1e-6, None)
    return float(np.sum((a - e) * np.log(a / e)))

def staleness(s: Series, threshold: float, expected_share: float = 0.05):
    flags_bad: list[str] = []
    dr, vr = s.regime()
    dr = np.array(dr)
    flags = vr >= threshold
    T, x = len(vr), int(flags.sum())
    hdr(f"4. Тесты на устаревание зоны (порог {fmt(threshold)})")

    lr_uc, p_uc = kupiec(x, T, expected_share)
    print(f"4.1 Kupiec: срабатываний {x} из {T} = {fmt(100*x/T,1)} % "
          f"при ожидаемых {fmt(100*expected_share,1)} %")
    bad_uc = p_uc == p_uc and p_uc < 0.05
    if bad_uc: flags_bad.append("частота срабатываний расходится с замыслом (Kupiec)")
    print(f"    LR = {fmt(lr_uc,2)}, p = {fmt(p_uc,4)} → "
          + ("частота срабатываний не соответствует замыслу порога"
             if bad_uc else "частота согласуется с замыслом"))

    lr_i, p_i = christoffersen(flags)
    if p_i == p_i:
        if p_i < 0.05: flags_bad.append("срабатывания кластеризуются (Christoffersen)")
        print(f"4.2 Christoffersen: LR = {fmt(lr_i,2)}, p = {fmt(p_i,4)} → "
              + ("срабатывания кластеризуются — порог реагирует на режим, а не на событие"
                 if p_i < 0.05 else "кластеризации нет"))
    else:
        print("4.2 Christoffersen: не считается — нет обоих состояний")

    tiz = 100 * float(flags.mean())
    if tiz > 5: flags_bad.append("доля времени в зоне выше 5 %")
    verdict = ("норма" if tiz <= 5 else
               "порог слишком низкий — зона перестала быть исключением")
    print(f"4.3 Доля времени в зоне: {fmt(tiz,1)} % → {verdict}")

    if T >= 20:
        mid = dr[len(dr)//2]
        vb = variance_break(s, mid)
        if vb:
            va, vbb, F, p = vb
            if p < 0.05: flags_bad.append("волатильность сменилась (разлом дисперсии)")
            print(f"4.4 Разлом дисперсии на {mid}: σ² {fmt(va,3)} против {fmt(vbb,3)}, "
                  f"F = {fmt(F,2)}, p = {fmt(p,4)} → "
                  + ("волатильность сменилась, порог требует пересчёта"
                     if p < 0.05 else "волатильность стабильна"))
        half = len(vr)//2
        val = psi(vr[:half], vr[half:])
        lab = ("сдвига нет" if val < 0.10 else
               "умеренный сдвиг" if val < 0.25 else "значимый сдвиг распределения")
        if val >= 0.25: flags_bad.append("значимый сдвиг распределения (PSI)")
        elif val >= 0.10: flags_bad.append("умеренный сдвиг распределения (PSI)")
        print(f"4.5 PSI первой половины против второй: {fmt(val,3)} → {lab}")
        m1 = float(vr[:half].max()); m2 = float(vr[half:].max())
        drift_bad = m2 >= threshold - (threshold - m1)*0.25
        if drift_bad: flags_bad.append("максимум подобрался к порогу")
        print(f"4.6 Дрейф максимума: {fmt(m1)} → {fmt(m2)} "
              f"({fmt(m2-m1,2)}) → "
              + ("максимум подобрался к порогу, запас съеден"
                 if drift_bad else "запас сохраняется"))
    else:
        print(f"4.4–4.6 не считаются: {T} наблюдений, нужно не менее 20")

    if x == 0 and T >= 20:
        flags_bad.append("не сработала ни разу — проверить достижимость")
    print("\nВердикт по зоне")
    if not flags_bad:
        print("  зона пригодна, пересчёт не требуется")
    else:
        print(f"  ТРЕБУЕТ ПЕРЕСЧЁТА — сработало признаков: {len(flags_bad)}")
        for b in flags_bad:
            print(f"    · {b}")

# ──────────────────────────────────────────────────────── самопроверка ──
def selftest():
    rng = np.random.default_rng(7)
    d0 = date(2023, 2, 20)
    n1, n2 = 160, 25
    calm = 75 + np.cumsum(rng.normal(0, 1.3, n1))
    calm = np.clip(calm, 66, 84)
    ramp = calm[-1] + np.cumsum(np.abs(rng.normal(1.6, 0.9, n2)))
    v = np.concatenate([calm, ramp])
    d = [d0 + timedelta(weeks=i) for i in range(len(v))]
    s = Series(d, v, limit=95.0, regime_start=d0)
    print("САМОПРОВЕРКА: синтетический ряд, спокойный режим 66–84 с последующим разгоном")
    mx, sd = anchors(s)
    sweep(s, lo=round(mx), hi=94, step=2)
    speed(s, level_floor=mx + 1)
    staleness(s, threshold=round(mx + 2*sd, 1))
    print("\nПроверка ожиданий")
    normal, fb = normal_window(s)
    mx2 = float(normal.max()); sd2 = float(np.std(np.diff(normal), ddof=1))
    th = mx2 + 2 * sd2
    dr, vr = s.regime(); dra = np.array(dr)
    sig = np.where(vr >= th)[0]; pre = sig[sig < fb]
    lead = (dra[fb] - dra[pre[0]]).days if len(pre) else 0
    tiz = 100 * float((vr >= th).mean())
    ok1 = lead >= 30
    ok2 = tiz <= 12
    ok3 = fb is not None
    for name, ok, val in (("порог даёт запас не менее 30 дней", ok1, f"{lead} дн."),
                          ("доля времени в зоне не выше 12 %", ok2, fmt(tiz,1)+" %"),
                          ("эпизод пробоя найден", ok3, str(fb))):
        print(f"  [{'OK ' if ok else 'СБОЙ'}] {name}: {val}")
    print("  итог: " + ("самопроверка пройдена" if ok1 and ok2 and ok3
                        else "САМОПРОВЕРКА НЕ ПРОЙДЕНА"))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv", nargs="?", help="файл date,value")
    ap.add_argument("--limit", type=float)
    ap.add_argument("--regime-start", type=str, default=None)
    ap.add_argument("--threshold", type=float, default=None)
    ap.add_argument("--expected-share", type=float, default=0.05)
    ap.add_argument("--runup", type=int, default=13,
                    help="сколько наблюдений разгона исключить перед пробоем")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest or not a.csv:
        selftest(); return
    if a.limit is None:
        sys.exit("нужен --limit")
    rs = date.fromisoformat(a.regime_start) if a.regime_start else None
    s = load(a.csv, a.limit, rs)
    mx, sd = anchors(s, a.runup)
    sweep(s, lo=round(mx), hi=s.limit - 1, step=1, runup=a.runup)
    speed(s, level_floor=mx + 1)
    staleness(s, a.threshold if a.threshold is not None else round(mx + 2*sd, 1),
              a.expected_share)

if __name__ == "__main__":
    main()
