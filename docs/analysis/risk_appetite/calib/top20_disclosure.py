#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Раскрытие расчёта по топ-20: числа и графики из одного прогона.

Зачем отдельный скрипт, когда есть top20_zones.py и top20_cadence.py: те считают
варианты и перебирают сетку, этот — воспроизводит **опубликованные** числа и рисует
их. Если какое-то число записки здесь не воспроизводится, это дефект записки,
а не скрипта, и он должен быть виден.

SVG пишется без внешних зависимостей: matplotlib нужен только charts.py и на
рабочей машине, а раскрытие обязано собираться везде, где есть python3.

    python3 top20_disclosure.py            # ../viz/zone_*.svg + ledger на stdout
    python3 top20_disclosure.py --selftest # сверка с опубликованными числами
"""
import csv, json, math, os, statistics as st, sys

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "..", "data", "top20_monthly_2023_08_2026_07.csv")
VIZ  = os.path.join(HERE, "..", "viz")

Z90 = 1.2815515655446004          # квантиль стандартного нормального для 0,90
K_G26 = 0.87453                   # E_бал / E_рег на 01.01.2026 (Г26)
L_REG = 95.0                      # уровень в регуляторной базе

# палитра — та же, что в viz/charts.py
SURFACE, INK, INK2, MUTED = "#fcfcfb", "#0b0b0b", "#52514e", "#898781"
GRID, BASE = "#e1e0d9", "#c3c2b7"
S1, CRIT, WARN, GOOD = "#2a78d6", "#d03b3b", "#fab219", "#0ca30c"


# ── данные ────────────────────────────────────────────────────────────────
def load():
    with open(DATA, encoding="utf-8") as fh:
        rows = list(csv.DictReader(fh, delimiter=";"))
    out = []
    for r in rows:
        out.append({
            "date": r["date"],
            "zaim": float(r["zaim_mln"]),
            "sk":   float(r["sk_new_mln"]),
            "coef": float(r["coef_new"]) * 100.0,
        })
    return out


# ── числа ─────────────────────────────────────────────────────────────────
def ledger(rows):
    v = [r["coef"] for r in rows]
    d = [v[i] - v[i - 1] for i in range(1, len(v))]
    sigma = st.stdev(d)                       # выборочная, n−1 — так считают D и H
    i_max = v.index(max(v))
    # Метод B опирается на ДРУГУЮ σ. Восстановлено обратным счётом от
    # опубликованных 113,17: популяционная σ приростов, из которых исключены
    # два прироста, примыкающих к выбросу 01.2024 (вход в него и выход из него).
    # Это третье определение σ в одной таблице методов — см. DISCLOSURE.md, Р-Д1.
    d_wo = [x for j, x in enumerate(d) if j not in (i_max - 1, i_max)]
    sigma_wo = st.pstdev(d_wo)

    L = L_REG / K_G26                          # пересчёт уровня под балансовую базу
    q = lambda p: quantile(v, p)
    share = lambda x: sum(1 for t in v if t >= x) / len(v)
    margin = lambda T: Z90 * sigma * math.sqrt(T)

    cur = v[-1]
    led = {
        "ряд": {"точек": len(v), "с": rows[0]["date"], "по": rows[-1]["date"]},
        "σ_Δ": sigma,
        "σ_B (иная база)": sigma_wo,
        "текущая точка": cur,
        "максимум ряда": max(v),
        "дата максимума": rows[i_max]["date"],
        "уровень L (балансовая база)": L,
        "запас T=1": margin(1), "запас T=2": margin(2),
        "запас T=3": margin(3), "запас T=4": margin(4),
        "квантиль 85 %": q(0.85), "квантиль 90 %": q(0.90), "квантиль 95 %": q(0.95),
        "H: требуемый лимит T=3": q(0.90) + margin(3),
        "D: расстояние до L, σ": (L - cur) / sigma,
        "D: расстояние до 95, σ": (L_REG - cur) / sigma,
        "F: падение СК до L, %": 100.0 * (cur / L - 1.0),
        "B: max + 2σ_B": max(v) + 2 * sigma_wo,
        "обратный счёт при L=95: жёлтая": L_REG - margin(3),
        "обратный счёт при L=95: доля времени": share(L_REG - margin(3)),
        "доля времени выше 99,60": share(99.60),
    }
    for T, yl in ((1, None), (2, None), (3, None)):
        led[f"цикл T={T}: жёлтая"] = L - margin(T)
        led[f"цикл T={T}: доля"] = share(L - margin(T))
    led["триггеры"] = triggers(rows)
    return led, v, d, sigma, L


def quantile(vals, p):
    """Линейная интерполяция между порядковыми статистиками (как numpy по умолчанию)."""
    s = sorted(vals)
    h = (len(s) - 1) * p
    lo = math.floor(h)
    hi = math.ceil(h)
    return s[lo] + (h - lo) * (s[hi] - s[lo])


def triggers(rows, d_sk=-3.0, d_zaim=5.0):
    """Триггеры на движение: ΔСК ≤ −3 % или ΔЗайм ≥ +5 % за месяц."""
    out = []
    for i in range(1, len(rows)):
        a, b = rows[i - 1], rows[i]
        dsk = (b["sk"] - a["sk"]) / a["sk"] * 100.0
        dzm = (b["zaim"] - a["zaim"]) / a["zaim"] * 100.0
        if dsk <= d_sk or dzm >= d_zaim:
            out.append({"date": b["date"], "ΔСК": dsk, "ΔЗайм": dzm, "коэф": b["coef"]})
    return out


# ── SVG без зависимостей ──────────────────────────────────────────────────
def svg_open(w, h, title):
    return [f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" '
            f'viewBox="0 0 {w} {h}" font-family="Inter, Segoe UI, Arial, sans-serif">',
            f'<rect width="{w}" height="{h}" fill="{SURFACE}"/>',
            f'<title>{esc(title)}</title>']


def esc(s):
    return (str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def txt(x, y, s, size=12, fill=INK, anchor="start", weight="400"):
    return (f'<text x="{x:.1f}" y="{y:.1f}" font-size="{size}" fill="{fill}" '
            f'text-anchor="{anchor}" font-weight="{weight}">{esc(s)}</text>')


def line(x1, y1, x2, y2, stroke=GRID, w=1, dash=None):
    d = f' stroke-dasharray="{dash}"' if dash else ""
    return (f'<line x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}" '
            f'stroke="{stroke}" stroke-width="{w}"{d}/>')


def chart_series(led, rows, v, L):
    """C1 — ряд, уровень, жёлтая линия, зоны."""
    W, H = 980, 460
    ml, mr, mt, mb = 64, 210, 56, 54
    pw, ph = W - ml - mr, H - mt - mb
    lo, hi = 74.0, 116.0
    yl = led["цикл T=3: жёлтая"]
    X = lambda i: ml + pw * i / (len(v) - 1)
    Y = lambda y: mt + ph * (hi - y) / (hi - lo)

    s = svg_open(W, H, "Топ-20: ряд, уровень и зоны")
    s.append(f'<rect x="{ml}" y="{Y(hi):.1f}" width="{pw}" height="{Y(L)-Y(hi):.1f}" fill="{CRIT}" opacity="0.07"/>')
    s.append(f'<rect x="{ml}" y="{Y(L):.1f}" width="{pw}" height="{Y(yl)-Y(L):.1f}" fill="{WARN}" opacity="0.10"/>')
    s.append(f'<rect x="{ml}" y="{Y(yl):.1f}" width="{pw}" height="{Y(lo)-Y(yl):.1f}" fill="{GOOD}" opacity="0.07"/>')
    for g in range(75, 116, 5):
        s.append(line(ml, Y(g), ml + pw, Y(g)))
        s.append(txt(ml - 8, Y(g) + 4, f"{g}", 11, MUTED, "end"))
    for i, r in enumerate(rows):
        if r["date"][5:7] == "01":
            s.append(txt(X(i), H - mb + 18, r["date"][:4], 11, MUTED, "middle"))
            s.append(line(X(i), mt, X(i), mt + ph, GRID, 1, "2 3"))
    s.append(line(ml, Y(L), ml + pw, Y(L), CRIT, 2))
    s.append(line(ml, Y(yl), ml + pw, Y(yl), WARN, 2))
    s.append(line(ml, Y(L_REG), ml + pw, Y(L_REG), MUTED, 1.5, "6 4"))
    pts = " ".join(f"{X(i):.1f},{Y(y):.1f}" for i, y in enumerate(v))
    s.append(f'<polyline points="{pts}" fill="none" stroke="{INK}" stroke-width="2"/>')
    s.append(f'<circle cx="{X(len(v)-1):.1f}" cy="{Y(v[-1]):.1f}" r="5" fill="{S1}"/>')
    s.append(txt(X(len(v) - 1) - 10, Y(v[-1]) - 12, f'{v[-1]:.2f}', 12, S1, "end", "600"))

    lx = ml + pw + 18
    s.append(txt(lx, mt + 4, "Уровень и зоны", 12, INK, "start", "600"))
    leg = [(CRIT, f"L = {L:.2f} % — лимит", "балансовая база"),
           (WARN, f"жёлтая = {yl:.2f} %", f"{led['цикл T=3: доля']:.1%} времени"),
           (MUTED, f"{L_REG:.0f} % — тот же лимит", "регуляторная база"),
           (S1, f"07.2026 = {v[-1]:.2f} %", f"{led['D: расстояние до L, σ']:.2f} σ до лимита")]
    y = mt + 28
    for c, a, b in leg:
        s.append(f'<rect x="{lx}" y="{y-9}" width="12" height="3" fill="{c}"/>')
        s.append(txt(lx + 18, y, a, 11.5, INK))
        s.append(txt(lx + 18, y + 15, b, 10.5, MUTED))
        y += 40
    s.append(txt(ml, 26, "Топ-20 / собственный капитал: 36 месяцев, уровень и зоны", 15, INK, "start", "600"))
    s.append(txt(ml, 43, f'Источник: data/top20_monthly_2023_08_2026_07.csv, колонка coef_new · {rows[0]["date"]} — {rows[-1]["date"]}', 11, MUTED))
    s.append("</svg>")
    return "\n".join(s)


def chart_methods(led):
    """C2 — восемь методов: жёлтая линия против доли времени."""
    ms = [("A 85 %", 92.34, 0.361), ("A 90 %", 97.77, 0.167),
          ("B max+2σ", led["B: max + 2σ_B"], 0.0),
          ("B′ max", led["максимум ряда"], 0.028),
          ("C кв. 95 %", led["квантиль 95 %"], 0.056),
          ("C кв. 90 %", led["квантиль 90 %"], 0.111),
          ("H цикл T=3", led["цикл T=3: жёлтая"], led["цикл T=3: доля"]),
          ("М1 L−1σ", 102.50, 0.028), ("М2 тренд", 102.61, 0.028)]
    W, H = 980, 420
    ml, mr, mt, mb = 64, 210, 56, 54
    pw, ph = W - ml - mr, H - mt - mb
    lo, hi = 88.0, 116.0
    X = lambda y: ml + pw * (y - lo) / (hi - lo)
    Y = lambda p: mt + ph * (1 - p / 0.40)
    s = svg_open(W, H, "Восемь методов на одной шкале")
    for g in range(90, 116, 5):
        s.append(line(X(g), mt, X(g), mt + ph))
        s.append(txt(X(g), mt + ph + 18, f"{g}", 11, MUTED, "middle"))
    for p in (0.0, 0.1, 0.2, 0.3, 0.4):
        s.append(line(ml, Y(p), ml + pw, Y(p)))
        s.append(txt(ml - 8, Y(p) + 4, f"{p:.0%}", 11, MUTED, "end"))
    L = led["уровень L (балансовая база)"]
    s.append(line(X(L), mt, X(L), mt + ph, CRIT, 2))
    s.append(txt(X(L) - 6, mt + 14, f"лимит {L:.2f}", 11, CRIT, "end", "600"))
    for name, yline, p in ms:
        if not (lo <= yline <= hi):
            continue
        col = CRIT if yline >= L else (S1 if name.startswith(("H", "C")) else BASE)
        r = 6 if name.startswith("H") else 4.5
        s.append(f'<circle cx="{X(yline):.1f}" cy="{Y(p):.1f}" r="{r}" fill="{col}"/>')
        s.append(txt(X(yline), Y(p) - 11, name, 10.5, INK2, "middle"))
    lx = ml + pw + 18
    s.append(txt(lx, mt + 4, "Как читать", 12, INK, "start", "600"))
    for i, t in enumerate(["Ось X — жёлтая линия метода.",
                           "Ось Y — доля времени в жёлтой зоне.",
                           "Метод правее лимита переворачивается:",
                           "жёлтая выше красной — зоны нет.",
                           "H и C сходятся в 0,05 пп — это",
                           "независимое подтверждение:",
                           "C смотрит на распределение,",
                           "H — на длину процесса."]):
        s.append(txt(lx, mt + 26 + i * 17, t, 11, MUTED))
    s.append(txt(ml, 26, "Восемь методов калибровки на одном стенде", 15, INK, "start", "600"))
    s.append(txt(ml, 43, "Метод, защищаемый в собственных терминах, несравним с другим. Общая шкала — жёлтая линия и доля времени", 11, MUTED))
    s.append("</svg>")
    return "\n".join(s)


def chart_cycle(led):
    """C3 — требуемый лимит как функция цикла решения."""
    W, H = 980, 400
    ml, mr, mt, mb = 64, 210, 56, 54
    pw, ph = W - ml - mr, H - mt - mb
    lo, hi = 100.0, 114.0
    Ts = [1, 2, 3, 4]
    req = [led["квантиль 90 %"] + led[f"запас T={T}"] for T in Ts]
    X = lambda T: ml + pw * (T - 1) / 3
    Y = lambda y: mt + ph * (hi - y) / (hi - lo)
    s = svg_open(W, H, "Требуемый лимит как функция цикла решения")
    for g in range(100, 115, 2):
        s.append(line(ml, Y(g), ml + pw, Y(g)))
        s.append(txt(ml - 8, Y(g) + 4, f"{g}", 11, MUTED, "end"))
    L = led["уровень L (балансовая база)"]
    s.append(line(ml, Y(L), ml + pw, Y(L), CRIT, 2, "6 4"))
    s.append(txt(ml + 6, Y(L) - 8, f"пересчёт базы: {L:.2f} %", 11, CRIT, "start", "600"))
    pts = " ".join(f"{X(T):.1f},{Y(y):.1f}" for T, y in zip(Ts, req))
    s.append(f'<polyline points="{pts}" fill="none" stroke="{S1}" stroke-width="2.5"/>')
    for T, y in zip(Ts, req):
        s.append(f'<circle cx="{X(T):.1f}" cy="{Y(y):.1f}" r="5" fill="{S1}"/>')
        s.append(txt(X(T), Y(y) - 13, f"{y:.2f}", 11.5, INK, "middle", "600"))
        s.append(txt(X(T), mt + ph + 20, f"T = {T} мес.", 11.5, MUTED, "middle"))
    lx = ml + pw + 18
    s.append(txt(lx, mt + 4, "Что показывает", 12, INK, "start", "600"))
    for i, t in enumerate(["Два независимых пути дают", "один уровень:", "",
                           f"· пересчёт базы → {L:.2f} %",
                           f"· квартал реагирования → {req[2]:.2f} %", "",
                           f"расхождение {abs(L-req[2]):.2f} пп.", "",
                           "Уровень не выбран под факт —", "его требует длина цикла."]):
        s.append(txt(lx, mt + 26 + i * 17, t, 11, MUTED if i not in (3, 4, 6) else INK2))
    s.append(txt(ml, 26, "Цикл решения задаёт минимальное расстояние до лимита", 15, INK, "start", "600"))
    s.append(txt(ml, 43, "Жёлтая линия на квантиле 90 % ряда; запас = z(0,90) · σ_Δ · √T", 11, MUTED))
    s.append("</svg>")
    return "\n".join(s)


def chart_triggers(led, rows, v, L):
    """C4 — срабатывания триггеров на движение."""
    W, H = 980, 400
    ml, mr, mt, mb = 64, 210, 56, 54
    pw, ph = W - ml - mr, H - mt - mb
    lo, hi = 74.0, 116.0
    X = lambda i: ml + pw * i / (len(v) - 1)
    Y = lambda y: mt + ph * (hi - y) / (hi - lo)
    dates = [r["date"] for r in rows]
    s = svg_open(W, H, "Триггеры на движение")
    for g in range(75, 116, 10):
        s.append(line(ml, Y(g), ml + pw, Y(g)))
        s.append(txt(ml - 8, Y(g) + 4, f"{g}", 11, MUTED, "end"))
    s.append(line(ml, Y(L), ml + pw, Y(L), CRIT, 1.5))
    s.append(line(ml, Y(led["цикл T=3: жёлтая"]), ml + pw, Y(led["цикл T=3: жёлтая"]), WARN, 1.5))
    pts = " ".join(f"{X(i):.1f},{Y(y):.1f}" for i, y in enumerate(v))
    s.append(f'<polyline points="{pts}" fill="none" stroke="{BASE}" stroke-width="2"/>')
    for t in led["триггеры"]:
        i = dates.index(t["date"])
        s.append(line(X(i), mt, X(i), mt + ph, S1, 1.5, "3 3"))
        s.append(f'<circle cx="{X(i):.1f}" cy="{Y(t["коэф"]):.1f}" r="5" fill="{S1}"/>')
        lab = f'ΔСК {t["ΔСК"]:+.1f}' if t["ΔСК"] <= -3 else f'ΔЗайм {t["ΔЗайм"]:+.1f}'
        s.append(txt(X(i), mt - 6, t["date"][:7], 10, INK2, "middle"))
        s.append(txt(X(i), Y(t["коэф"]) + 18, lab, 10, S1, "middle"))
    lx = ml + pw + 18
    s.append(txt(lx, mt + 4, "Триггеры на движение", 12, INK, "start", "600"))
    for i, t in enumerate(["ΔСК ≤ −3 % или ΔЗайм ≥ +5 %", "за месяц — независимо от зоны.", "",
                           f"Сработали {len(led['триггеры'])} раза из 35.", "",
                           "Январь 2026 уровневой зоной", "не предупреждался в принципе:", "вход сделан капиталом."]):
        s.append(txt(lx, mt + 26 + i * 17, t, 11, MUTED))
    s.append(txt(ml, 26, "Триггеры на движение: шесть срабатываний на 35 приростах", 15, INK, "start", "600"))
    s.append(txt(ml, 43, "Уровневая зона не видит быстрый вход; триггер по движению видит", 11, MUTED))
    s.append("</svg>")
    return "\n".join(s)


# ── выход ─────────────────────────────────────────────────────────────────
PUBLISHED = {                       # что напечатано в DECOMPOSITION.md § 11.10
    "σ_Δ": 4.07, "уровень L (балансовая база)": 108.63,
    "запас T=1": 5.21, "запас T=2": 7.37, "запас T=3": 9.03, "запас T=4": 10.42,
    "квантиль 85 %": 98.19, "квантиль 90 %": 99.55, "квантиль 95 %": 101.01,
    "H: требуемый лимит T=3": 108.58, "текущая точка": 101.50,
    "максимум ряда": 105.90, "D: расстояние до L, σ": 1.75,
    "F: падение СК до L, %": -6.6, "обратный счёт при L=95: жёлтая": 85.97,
    "обратный счёт при L=95: доля времени": 0.861,
    "цикл T=1: жёлтая": 103.42, "цикл T=2: жёлтая": 101.26, "цикл T=3: жёлтая": 99.60,
    "цикл T=1: доля": 0.028, "цикл T=2: доля": 0.056, "цикл T=3: доля": 0.111,
    "B: max + 2σ_B": 113.17,
}


def decimals(x):
    """Сколько знаков после запятой в опубликованном числе."""
    t = f"{x!r}"
    return len(t.split(".")[1].rstrip("0")) if "." in t and t.split(".")[1].rstrip("0") else 0


def main():
    rows = load()
    led, v, d, sigma, L = ledger(rows)

    if "--selftest" in sys.argv:
        bad = 0
        print(f'{"показатель":38s} {"опубликовано":>13s} {"пересчёт":>11s} {"откл.":>9s}  допуск')
        for k, want in PUBLISHED.items():
            got = led[k]
            # допуск = половина последнего опубликованного разряда: число,
            # напечатанное как 9,03, не обязано сходиться точнее 0,005
            tol = 0.5 * 10 ** (-decimals(want)) + 1e-12
            ok = abs(got - want) <= tol
            bad += 0 if ok else 1
            mark = "" if ok else "  ← НЕ СХОДИТСЯ"
            print(f'{k:38s} {want:13.4f} {got:11.4f} {got-want:+9.4f}  ±{tol:.4f}{mark}')
        print(f"\nне сходится: {bad}")
        return 1 if bad else 0

    os.makedirs(VIZ, exist_ok=True)
    for name, svg in (("zone_series", chart_series(led, rows, v, L)),
                      ("zone_methods", chart_methods(led)),
                      ("zone_cycle", chart_cycle(led)),
                      ("zone_triggers", chart_triggers(led, rows, v, L))):
        p = os.path.join(VIZ, name + ".svg")
        with open(p, "w", encoding="utf-8") as fh:
            fh.write(svg)
        print("написан", os.path.relpath(p, HERE))
    print()
    print(json.dumps({k: (round(x, 4) if isinstance(x, float) else x)
                      for k, x in led.items() if k != "триггеры"},
                     ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
