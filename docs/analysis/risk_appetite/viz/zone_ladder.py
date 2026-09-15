#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Ряд топ-20 и лестница зон — PNG для вставки в расчётный лист.

Почему отдельный скрипт, а не `charts.py`: тот требует matplotlib, которого
в контейнере сессии нет. Здесь только PIL, который есть везде.

Почему не переиспользуется `zone_series.svg`: он нарисован под прежнюю разметку
с одной жёлтой линией на 99,60, а зоны с 15.09.2026 — лестница 98,21 / 103,42 /
108,63. Картинка, показывающая другие границы, чем лист, хуже её отсутствия.
Excel к тому же не вставляет SVG.

    python3 zone_ladder.py          # -> zone_ladder.png

Палитра — из методики визуализации (см. README.md): поверхность #fcfcfb,
текст #0b0b0b, статусные #d03b3b / #fab219 / #0ca30c за состоянием.
"""

import csv
import math
import os
import statistics as st

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "..", "data", "top20_monthly_2023_08_2026_07.csv")
OUT = os.path.join(HERE, "zone_ladder.png")

W, H = 1800, 950
PAD_L, PAD_R, PAD_T, PAD_B = 120, 330, 90, 110
SURFACE, INK, MUTED, GRID = "#fcfcfb", "#0b0b0b", "#6b6a66", "#e1e0d9"
GREEN, YELLOW, RED, LIMIT = "#e8f4e7", "#fdf3d2", "#f8dedb", "#d03b3b"
LINE = "#2a78d6"
FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
FONT_B = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"

Z90 = 1.2815515655446004
K_G26 = 439961.267 / 503086.114          # СК_бал / СК_рег на 01.01.2026
L_REG = 95.0


def load():
    with open(DATA, encoding="utf-8") as fh:
        rows = list(csv.DictReader(fh, delimiter=";"))
    return [r["date"] for r in rows], [float(r["coef_new"]) * 100 for r in rows]


def main():
    dates, v = load()
    d = [v[i] - v[i - 1] for i in range(1, len(v))]
    sigma = st.stdev(d)
    L = L_REG / K_G26
    g = L - Z90 * sigma * 2              # L − M(4)
    y = L - Z90 * sigma                  # L − M(1)

    lo = min(min(v), g) - 4
    hi = max(max(v), L) + 3
    px = lambda i: PAD_L + i * (W - PAD_L - PAD_R) / (len(v) - 1)
    py = lambda val: H - PAD_B - (val - lo) * (H - PAD_T - PAD_B) / (hi - lo)

    im = Image.new("RGB", (W, H), SURFACE)
    dr = ImageDraw.Draw(im)
    f_t = ImageFont.truetype(FONT_B, 30)
    f_l = ImageFont.truetype(FONT, 20)
    f_s = ImageFont.truetype(FONT, 18)
    f_b = ImageFont.truetype(FONT_B, 21)

    # полосы зон
    for a, b, colour in ((lo, g, GREEN), (g, y, YELLOW), (y, L, RED)):
        dr.rectangle([PAD_L, py(b), W - PAD_R, py(a)], fill=colour)
    dr.rectangle([PAD_L, py(hi), W - PAD_R, py(L)], fill="#f2d2ce")

    # сетка и ось
    step = 5
    t = math.floor(lo / step) * step
    while t <= hi:
        if lo <= t <= hi:
            dr.line([PAD_L, py(t), W - PAD_R, py(t)], fill=GRID)
            dr.text((PAD_L - 14, py(t) - 11), f"{t:.0f}", font=f_s, fill=MUTED,
                    anchor="ra")
        t += step
    dr.rectangle([PAD_L, PAD_T, W - PAD_R, H - PAD_B], outline=GRID)

    # границы
    for val, colour, width in ((g, "#c9a227", 3), (y, "#c0554a", 3), (L, LIMIT, 4)):
        dr.line([PAD_L, py(val), W - PAD_R, py(val)], fill=colour, width=width)

    # ряд
    pts = [(px(i), py(x)) for i, x in enumerate(v)]
    dr.line(pts, fill=LINE, width=4, joint="curve")
    for i, (x, yy) in enumerate(pts):
        r = 7 if i == len(pts) - 1 else 3
        dr.ellipse([x - r, yy - r, x + r, yy + r],
                   fill=(LIMIT if i == len(pts) - 1 else LINE), outline=SURFACE)

    # подписи дат: каждая шестая
    for i in range(0, len(v), 6):
        dr.text((px(i), H - PAD_B + 12), dates[i][:7], font=f_s, fill=MUTED,
                anchor="ma")

    # правое поле — легенда зон
    lx = W - PAD_R + 24
    dr.text((PAD_L, 30), "Топ-20 / собственный капитал: ряд и зоны", font=f_t, fill=INK)
    dr.text((PAD_L, 64),
            "36 месячных точек, 01.08.2023 — 01.07.2026. Границы — L − M(T), "
            "а не подобранные числа.", font=f_s, fill=MUTED)

    cnt = [sum(1 for x in v if x < g), sum(1 for x in v if g <= x < y),
           sum(1 for x in v if y <= x < L), sum(1 for x in v if x >= L)]
    rows = [("Нарушение лимита", L, LIMIT, cnt[3], "уровень превышен"),
            ("Красная", y, "#c0554a", cnt[2], "уровень высокий"),
            ("Жёлтая", g, "#c9a227", cnt[1], "допустимый, нужны меры"),
            ("Зелёная", None, "#2f7d32", cnt[0], "мер не требует")]
    ty = PAD_T + 10
    for name, val, colour, n, tail in rows:
        dr.rectangle([lx, ty + 4, lx + 16, ty + 20], fill=colour)
        dr.text((lx + 26, ty), name, font=f_b, fill=INK)
        ty += 26
        txt = f"от {val:.2f}" if val is not None else f"ниже {g:.2f}"
        dr.text((lx + 26, ty), f"{txt} · {n} из 36", font=f_s, fill=MUTED)
        ty += 22
        dr.text((lx + 26, ty), tail, font=f_s, fill=MUTED)
        ty += 34

    ty += 10
    cur = v[-1]
    dr.text((lx, ty), "Текущая точка", font=f_b, fill=INK)
    dr.text((lx, ty + 26), f"{cur:.4f} — ЖЁЛТАЯ", font=f_b, fill="#8a6d1f")
    dr.text((lx, ty + 52), f"до красной {y - cur:.2f} пп", font=f_s, fill=MUTED)
    dr.text((lx, ty + 74), f"до лимита {L - cur:.2f} пп", font=f_s, fill=MUTED)
    dr.text((lx, ty + 96), f"σ месячного хода {sigma:.2f} пп", font=f_s, fill=MUTED)

    dr.text((PAD_L, H - 34),
            "Собрано viz/zone_ladder.py из data/top20_monthly_2023_08_2026_07.csv. "
            "Границы: зелёная/жёлтая = L − M(4), жёлтая/красная = L − M(1), "
            "красная/нарушение = L.", font=f_s, fill=MUTED)

    im.save(OUT)
    print("написан", os.path.relpath(OUT, HERE))
    print(f"  σ={sigma:.4f}  L={L:.4f}  зел/жёл={g:.4f}  жёл/кр={y:.4f}")
    print(f"  зоны: {cnt[0]} / {cnt[1]} / {cnt[2]} / {cnt[3]}")


if __name__ == "__main__":
    main()
