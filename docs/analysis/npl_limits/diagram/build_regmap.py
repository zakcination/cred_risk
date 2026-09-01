# -*- coding: utf-8 -*-
"""Карта нормативной базы кейса 98-3: дерево «кто кого порождает».

Пишет regmap.svg. PNG для вставки в Word снимается браузером
(deviceScaleFactor 2); в среде без браузера SVG самодостаточен.
Все связи — по преамбулам и ссылкам самих документов, без домыслов.
"""

INK, MUTED, ACC, WARN = "#16202b", "#5b6b7a", "#1c5b57", "#a8492f"
RULE, TINT, TEAL_BG, WARN_BG = "#c8d2da", "#eef3f5", "#f2f7f6", "#fbf3f0"
W, H = 1560, 1050

def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

def box(x, y, w, h, fill, stroke, dash=""):
    d = f' stroke-dasharray="7,5"' if dash else ""
    return (f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="10" '
            f'fill="{fill}" stroke="{stroke}" stroke-width="2"{d}/>')

def text(x, y, s, size=15, fill=INK, w="normal", anchor="start"):
    return (f'<text x="{x}" y="{y}" font-family="Arial" font-size="{size}" '
            f'fill="{fill}" font-weight="{w}" text-anchor="{anchor}">{esc(s)}</text>')

def lines(x, y, rows, size=13, fill=INK, lh=18, anchor="start"):
    return "".join(text(x, y + i * lh, r, size, fill, "normal", anchor)
                   for i, r in enumerate(rows))

def arrow(x1, y1, x2, y2, color=MUTED, dash="", label="", lx=None, ly=None):
    d = f' stroke-dasharray="6,5"' if dash else ""
    s = (f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{color}" '
         f'stroke-width="1.8" marker-end="url(#arr)"{d}/>')
    if label:
        px = lx if lx is not None else (x1 + x2) / 2
        py = ly if ly is not None else (y1 + y2) / 2 - 6
        s += (f'<text x="{px}" y="{py}" font-family="Arial" font-size="12.5" '
              f'fill="{MUTED}" text-anchor="middle" stroke="white" '
              f'stroke-width="5" paint-order="stroke">{esc(label)}</text>')
    return s

p = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
     f'viewBox="0 0 {W} {H}"><defs>'
     f'<marker id="arr" markerWidth="9" markerHeight="9" refX="8" refY="4.5" '
     f'orient="auto"><path d="M0,0 L9,4.5 L0,9 z" fill="{MUTED}"/></marker>'
     f'</defs><rect width="{W}" height="{H}" fill="white"/>']

p.append(text(30, 42, "Карта нормативной базы кейса 98-3: кто кого порождает", 24, INK, "bold"))
p.append(text(30, 68, "БРМ · контур docs/analysis/npl_limits · 19.08.2026 · связи — по преамбулам и ссылкам самих документов", 13, MUTED))

# легенда
p.append(box(1080, 26, 450, 56, "white", RULE))
p.append(f'<line x1="1100" y1="46" x2="1150" y2="46" stroke="{MUTED}" stroke-width="1.8" marker-end="url(#arr)"/>')
p.append(text(1160, 50, "издан на основании / прямая норма", 12.5, MUTED))
p.append(f'<line x1="1100" y1="68" x2="1150" y2="68" stroke="{MUTED}" stroke-width="1.8" stroke-dasharray="6,5" marker-end="url(#arr)"/>')
p.append(text(1160, 72, "используется в расчёте / изменяет", 12.5, MUTED))

# ------------------------------------------------- корень и № 306 -------
rx, ry, rw, rh = 560, 100, 440, 96
p.append(box(rx, ry, rw, rh, INK, INK))
p.append(text(rx + rw / 2, ry + 30, "Закон «О банках и банковской деятельности»", 16, "white", "bold", "middle"))
p.append(text(rx + rw / 2, ry + 52, "№ 258-VIII от 16.01.2026 · в силе с 19.03.2026", 13, "#cfd8de", "normal", "middle"))
p.append(text(rx + rw / 2, ry + 74, "ст. 72 · ст. 78–81 · ст. 85 · ст. 87–92", 13, "#cfd8de", "normal", "middle"))

p.append(box(60, 100, 380, 96, WARN_BG, WARN, dash="1"))
p.append(text(250, 130, "Закон № 306-VIII от 11.06.2026", 15, INK, "bold", "middle"))
p.append(lines(250, 152, ["поправки терминологические (ст. 1 п. 77);",
                          "ст. 69 (банк. тайна) — с 01.01.2027;",
                          "статей 72, 78–92 не затрагивает"], 12.5, MUTED, 17, "middle"))
p.append(arrow(440, 148, 560, 148, WARN, dash="1", label="изменяет", lx=500, ly=138))

# ------------------------------------------------- уровень АРРФР --------
row2 = [
 (30,  "Правила СУР и ВК", "АРРФР № 86 от 28.04.2026", "рег. № 38586",
  ["риск-аппетит, ВПОДК;", "СРП и триггеры — обязанность", "БРМ (п. 34 пп. 5, 6)"], "СУР и ВК"),
 (340, "Пруденциальные нормативы", "АРРФР № 85 от 28.04.2026", "рег. № 38587",
  ["глава 11 (пп. 98–108):", "лимит 98-3 · план мероприятий", "п. 99: план = «не нарушение»"], "ст. 72"),
 (650, "Правила применения мер", "НБ № 272 от 29.10.2018", "рег. № 17789 · ред. 20.04.2026",
  ["процедура предписаний ст. 80;", "меры (кроме рекомендательных)", "публикуются на сайте (п. 5)"], "ст. 78–81"),
 (960, "Значения признаков ухудшения", "АРРФР № 119 от 07.08.2026", "рег. № 39529",
  ["счётчик: 6 мес ДС3 ≥ 10 %", "при КПП < 40 % → усиленный", "надзор; 15/20 % — разово"], "ст. 85 пп. 2, 4"),
 (1270, "Требования к плану", "восстановления · АРРФР № 108", "от 27.07.2026 · рег. № 39435",
  ["состав, ранние сигналы;", "до 30 апреля за отчётный год;", "реализация ≤ 12 месяцев"], "ст. 88 п. 4"),
]
y2, bw, bh = 300, 280, 130
for x, t1, t2, t3, body, edge in row2:
    p.append(box(x, y2, bw, bh, TEAL_BG, ACC))
    p.append(text(x + bw / 2, y2 + 24, t1, 14.5, INK, "bold", "middle"))
    p.append(text(x + bw / 2, y2 + 43, t2, 12.5, ACC, "bold", "middle"))
    p.append(text(x + bw / 2, y2 + 60, t3, 12, MUTED, "normal", "middle"))
    p.append(lines(x + bw / 2, y2 + 82, body, 12.5, INK, 16, "middle"))
    cx = x + bw / 2
    p.append(arrow(rx + rw / 2 + (cx - (rx + rw / 2)) * 0.25, ry + rh,
                   cx, y2, MUTED, label=edge, lx=cx + (0 if abs(cx-(rx+rw/2))<200 else 0), ly=y2 - 10))

# ------------------------------------------------- опорные акты ---------
row3 = [
 (340, "Правила провизий", "АРРФР № 61 от 29.09.2025", "рег. № 36994",
  ["критерии обесценения:", "периметр НЗ и кредитов", "3 стадии + ПСКО"]),
 (650, "Макропруденциальные", "нормативы · НБ № 52", "от 25.08.2025 · рег. № 36722",
  ["входят в признак ст. 85", "п. 2 пп. 1 и в условия выхода", "из режимов (ст. 87, 89)"]),
 (960, "Системная значимость", "НБ № 240 от 23.12.2019", "рег. № 19925",
  ["списки системно значимых:", "стресс-тест фактора 98-1", "(№ 85 п. 108; № 119 п. 108)"]),
]
y3 = 540
for x, t1, t2, t3, body in row3:
    p.append(box(x, y3, bw, bh - 10, TINT, MUTED))
    p.append(text(x + bw / 2, y3 + 24, t1, 14.5, INK, "bold", "middle"))
    p.append(text(x + bw / 2, y3 + 43, t2, 12.5, MUTED, "bold", "middle"))
    p.append(text(x + bw / 2, y3 + 60, t3, 12, MUTED, "normal", "middle"))
    p.append(lines(x + bw / 2, y3 + 80, body, 12.5, INK, 16, "middle"))

p.append(arrow(480 - 30, y3, 460, y2 + bh, MUTED, dash="1", label="периметр НЗ", lx=408, ly=y3 - 40))
p.append(arrow(480 + 60, y3, 1040, y2 + bh, MUTED, dash="1", label="кредиты 3 стадии", lx=700, ly=y3 - 62))
p.append(arrow(790, y3, 1080, y2 + bh, MUTED, dash="1", label="признак пп. 1; выход из режимов", lx=940, ly=y3 - 8))
p.append(arrow(1100, y3, 1120, y2 + bh, MUTED, dash="1", label="сценарии стресс-теста", lx=1180, ly=y3 - 12))
p.append(arrow(1040, y3, 560, y2 + bh, MUTED, dash="1", label="п. 108", lx=620, ly=y3 - 38))

# ------------------------------------------------- лента кейса ----------
p.append(text(30, 764, "Траектория кейса 98-3 по этой карте:", 15, INK, "bold"))
steps = [
 (30,  "Превышение лимита 98-3", "НЗ/СП ≥ 10 % (гл. 11 № 85, п. 107 пп. 3)", TEAL_BG, ACC),
 (420, "План мероприятий, 5 раб. дней", "п. 99, п. 102 № 85 — «не нарушение»", TEAL_BG, ACC),
 (810, "Если счётчик № 119 закрылся", "6 мес ДС3 ≥ 10 % и КПП < 40 %", WARN_BG, WARN),
 (1200, "Режимы ст. 87 → 89", "выход: 6 мес чистого соблюдения", WARN_BG, WARN),
]
y4, bw4, bh4 = 784, 330, 76
for i, (x, t1, t2, bg, st) in enumerate(steps):
    p.append(box(x, y4, bw4, bh4, bg, st))
    p.append(text(x + bw4 / 2, y4 + 32, t1, 14, INK, "bold", "middle"))
    p.append(text(x + bw4 / 2, y4 + 54, t2, 12.5, MUTED, "normal", "middle"))
    if i:
        p.append(arrow(x - 60, y4 + bh4 / 2, x, y4 + bh4 / 2, MUTED))

p.append(text(30, 920, "Чтение карты: сверху вниз — от закона к подзаконным актам; серые опорные акты дают определения и списки,", 13, MUTED))
p.append(text(30, 940, "без которых верхние не считаются. Лента внизу — путь нашего кейса; красная зона наступает только при", 13, MUTED))
p.append(text(30, 960, "закрытии счётчика № 119 либо срыве плана (тогда — сразу режим восстановления, № 119 п. 16 пп. 6).", 13, MUTED))

p.append("</svg>")
open(__file__.replace("build_regmap.py", "regmap.svg"), "w", encoding="utf-8").write("".join(p))
print("regmap.svg записан")
