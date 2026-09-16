#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Расстояние до лимита в собственных σ — 12 кредитных метрик, месячный ряд.

Заменяет `ex3_sigma_vs_utilisation.png`, посчитанный на квартальном ряде из
девяти точек. Прежний файл остаётся в репозитории: по нему собран § 3
аналитической записки v0.5, и стереть его — значит потерять доказательство
того, что вывод проверялся (§ 5 корневого CLAUDE.md, образец — PR #15).

**Что изменилось помимо данных.** У прежней версии вертикаль стояла на 12 σ
с подписью «граница практической достижимости» — число ниоткуда. Здесь границы
берутся из той же модели, что и зоны книги:

    попасть на лимит за T месяцев с вероятностью 10 % ⇔ расстояние < z(0,90)·√T

то есть 1,2816 σ для T = 1 и 2,5631 σ для T = 4 — ровно границы M(1) и M(4),
по которым размечены зоны в расчётном листе. Поэтому цвет столбика на картинке
совпадает с зоной метрики на листе «Метрики» по построению, а не по совпадению:
это проверка согласованности, а не украшение.

Ось логарифмическая: расстояния разнесены от 1,75 σ до 103,94 σ, на линейной
шкале девять метрик из двенадцати слились бы в одну полосу. Подписи дают точное
значение, столбик служит только для ранжирования.

Почему PIL, а не matplotlib: matplotlib в контейнере сессии нет (та же причина,
что в `zone_ladder.py`); `charts.py` собирался в другой среде.

    python3 ex3m_distance.py        # -> ex3m_distance.png
"""

import csv
import math
import os
import statistics as st
import sys

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "build"))
from metrics_data import load_rb, METRICS_COR            # noqa: E402

T20 = os.path.join(HERE, "..", "data", "top20_monthly_2023_08_2026_07.csv")
OUT = os.path.join(HERE, "ex3m_distance.png")

Z90 = 1.2815515655446004
K_G26 = 439961.267 / 503086.114          # СК_бал / СК_рег на 01.01.2026
L_REG = 95.0

W, H = 1900, 1070
PAD_L, PAD_R, PAD_T, PAD_B = 600, 570, 216, 122
SURFACE, INK, MUTED, GRID = "#fcfcfb", "#0b0b0b", "#6b6a66", "#e1e0d9"
BAND_G, BAND_Y, BAND_R = "#e8f4e7", "#fdf3d2", "#f8dedb"
BAR_G, BAR_Y, BAR_R = "#2f7d32", "#c9a227", "#c0554a"
FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
FONT_B = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"

SHORT = {
    "el_total": "EL общий",
    "el_unsecured": "EL необеспеченные",
    "el_secured": "EL обеспеченные",
    "el_other": "EL прочие",
    "pd_unsecured": "PD необеспеченные",
    "pd_unsecured_cash": "PD необесп., наличные",
    "pd_unsecured_goods": "PD необесп., товарные",
    "pd_secured": "PD обеспеченные",
    "pd_other": "PD прочие",
}


def ru(x, nd):
    """Русский формат: запятая и типографский минус."""
    return f"{x:.{nd}f}".replace("-", "−").replace(".", ",")


def tstar_ru(t):
    """T* в месяцах. Дальше 10 лет это уже экстраполяция σ, и её не показываем."""
    if t < 24:
        return f"T* = {t:.0f} мес"
    if t <= 120:
        return f"T* = {t / 12:.0f} лет"
    return "T* > 10 лет"


def stat(v, lim):
    d = [v[i] - v[i - 1] for i in range(1, len(v))]
    s = st.stdev(d)
    dist = (lim - v[-1]) / s
    return dict(sigma=s, fact=v[-1], lim=lim, util=100 * v[-1] / lim,
                dist=dist, tstar=(dist / Z90) ** 2)


def collect():
    with open(T20, encoding="utf-8") as fh:
        rows = list(csv.DictReader(fh, delimiter=";"))
    out = [("Топ-20 / собственный капитал", "КБ",
            stat([float(r["coef_new"]) * 100 for r in rows], L_REG / K_G26))]
    seg_ru = {"KB_PB": "КБ/ПБ", "MSB": "МСБ", "RB": "РБ"}
    for code, _name, seg, lim, _col in METRICS_COR:
        out.append(("CoR — стоимость риска", seg_ru[seg],
                    stat([float(r[code]) * 100 for r in rows], lim)))
    _dates, rb = load_rb()
    for code, _name, seg, lim, vals in rb:
        out.append((SHORT[code], seg_ru[seg], stat(vals, lim)))
    return sorted(out, key=lambda x: x[2]["dist"])


def zone(dist):
    if dist < Z90:
        return BAR_R, "красная"
    if dist < Z90 * 2:
        return BAR_Y, "жёлтая"
    return BAR_G, "зелёная"


def main():
    m = collect()
    lo, hi = 1.0, 135.0
    lx = lambda x: (PAD_L + (math.log10(max(x, lo)) - math.log10(lo))
                    / (math.log10(hi) - math.log10(lo)) * (W - PAD_L - PAD_R))
    band = (H - PAD_T - PAD_B) / len(m)

    im = Image.new("RGB", (W, H), SURFACE)
    dr = ImageDraw.Draw(im)
    f_t = ImageFont.truetype(FONT_B, 32)
    f_n = ImageFont.truetype(FONT_B, 21)
    f_l = ImageFont.truetype(FONT, 20)
    f_s = ImageFont.truetype(FONT, 18)

    # фоновые полосы зон
    for a, b, colour in ((lo, Z90, BAND_R), (Z90, Z90 * 2, BAND_Y), (Z90 * 2, hi, BAND_G)):
        dr.rectangle([lx(a), PAD_T, lx(b), H - PAD_B], fill=colour)

    # логарифмическая сетка
    for t in (1, 2, 3, 5, 10, 20, 30, 50, 100):
        if lo <= t <= hi:
            dr.line([lx(t), PAD_T, lx(t), H - PAD_B], fill=GRID)
            dr.text((lx(t), H - PAD_B + 12), str(t), font=f_s, fill=MUTED, anchor="ma")
    dr.rectangle([PAD_L, PAD_T, W - PAD_R, H - PAD_B], outline=GRID)

    # границы модели: две строки, чтобы подписи не налезали друг на друга
    for val, lab, dy in ((Z90, "z·√1 = 1,28 σ  ·  граница красной", 56),
                         (Z90 * 2, "z·√4 = 2,56 σ  ·  граница жёлтой", 30)):
        dr.line([lx(val), PAD_T - dy + 20, lx(val), H - PAD_B], fill="#8a8781", width=2)
        dr.text((lx(val) + 8, PAD_T - dy), lab, font=f_s, fill=INK)

    for i, (name, seg, s) in enumerate(m):
        yc = PAD_T + i * band + band / 2
        colour, zname = zone(s["dist"])
        dr.rectangle([PAD_L, yc - 11, lx(s["dist"]), yc + 11], fill=colour)
        dr.text((PAD_L - 16, yc - 21), name, font=f_n, fill=INK, anchor="ra")
        util = "утил. < 0" if s["util"] < 0 else f"утил. {s['util']:.0f} %"
        dr.text((PAD_L - 16, yc + 4),
                f"{seg}  ·  факт {ru(s['fact'], 2)}, лимит {ru(s['lim'], 2)}  ·  {util}",
                font=f_s, fill=MUTED, anchor="ra")
        dr.text((lx(s["dist"]) + 14, yc - 10),
                f"{ru(s['dist'], 2)} σ   ·   {tstar_ru(s['tstar'])}   ·   {zname}",
                font=f_l, fill=INK)

    dr.text((30, 30), "Утилизация лимита не измеряет близость к нему", font=f_t, fill=INK)
    for j, line in enumerate((
            "12 кредитных метрик, 36 месячных точек 01.08.2023 — 01.07.2026. "
            "σ — стандартное отклонение месячного приращения самой метрики.",
            "T* = (расстояние / z)² — через сколько месяцев лимит достижим с "
            "вероятностью 10 %. Дальше 10 лет это экстраполяция σ, и величина не показана.",
            "Цвет столбика — зона по модели M(T) = z·σ·√T. Он совпадает с зоной "
            "листа «Метрики» расчётного листа по построению, а не по совпадению.")):
        dr.text((30, 74 + j * 24), line, font=f_s, fill=MUTED)

    dr.text((30, H - 74),
            "Ось логарифмическая: расстояния разнесены от 1,75 σ до 103,94 σ. "
            "Столбик ранжирует, точное значение — в подписи.", font=f_s, fill=MUTED)
    dr.text((30, H - 48),
            "Собрано viz/ex3m_distance.py из тех же CSV, что и расчётный лист. "
            "Заменяет ex3_sigma_vs_utilisation.png (квартальный ряд, 9 точек, "
            "вертикаль 12 σ без основания).", font=f_s, fill=MUTED)

    im.save(OUT)
    print("написан", os.path.relpath(OUT, HERE))
    for name, seg, s in m:
        print(f"  {name:30s} {seg:8s} σ={s['sigma']:7.4f} "
              f"утил={s['util']:6.1f}%  {s['dist']:7.2f} σ  T*={s['tstar']:8.1f} мес  "
              f"{zone(s['dist'])[1]}")


if __name__ == "__main__":
    main()
