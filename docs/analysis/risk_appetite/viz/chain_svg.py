#!/usr/bin/env python3
"""Схема цепочки риск-аппетита и её фактических разрывов -> chain.svg.

Точная схема с подписями собирается как SVG, а не генерируется моделью:
генеративная картинка не умеет держать номера пунктов и цифры.
Правится этот файл, а не .svg.
"""
from html import escape
from pathlib import Path

# --- палитра методики визуализации, светлый режим -------------------------
SURFACE, INK, MUTED, HAIR = "#fcfcfb", "#0b0b0b", "#5b5b58", "#d8d8d3"
OK, WARN, BAD = "#0ca30c", "#fab219", "#d03b3b"
TINT = {OK: "#f0f8f0", WARN: "#fdf6e7", BAD: "#fbf0f0"}

W, H = 1180, 1015
BX, BW, BH = 56, 400, 78          # блок звена
PITCH = 130                        # шаг по вертикали
Y0 = 152                           # верх первого блока
CX = BX + BW // 2                  # ось соединителей
AX = 512                           # левый край колонки пояснений
AW = 1124 - AX

FAM = "Inter, 'Segoe UI', 'Helvetica Neue', Arial, sans-serif"
MONO = "'SF Mono', 'DejaVu Sans Mono', Menlo, Consolas, monospace"

# --- содержание -----------------------------------------------------------
# (заголовок, что это, состояние, пояснения справа)
NODES = [
    ("Риск-ёмкость", "внешняя граница: капитал, ликвидность, нормативы", BAD, [
        "Как отдельная величина **не зафиксирована** — Г12.",
        "Регуляторные минимумы по № 85 есть: k1 8,0 %, k1-2 9,0 %, k2 10,5 %.",
        "Буфер до лимита РА — ровно 0,5 пп по всем трём коэффициентам: "
        "это механическая надбавка, а не результат калибровки.",
    ]),
    ("Риск-аппетит", "25 метрик, из них 14 кредитных", WARN, [
        "Заявление риск-аппетита **как отдельный документ не предъявлено** — вопрос В34.",
        "Для 14 кредитных метрик связь с риск-ёмкостью не прослеживается "
        "ни в одном из прочитанных ВНД.",
    ]),
    ("Лимит", "установлен по всем 25 метрикам", OK, [
        "**Единственное звено, которое есть целиком.**",
        "Но происхождение уровня восстановлено ровно для одного лимита из 25: "
        "топ-20, февраль 2023, 250 % → 95 %, то есть факт + 7 σ — Г17.",
    ]),
    ("Уровень, определённый как допустимый", "п. 18 пп. 2 Правил № 86", BAD, [
        "По всем **14 кредитным метрикам отсутствует**.",
        "Там, где зоны есть — капитал и ликвидность, — они стоят за лимитом: "
        "красная зона наступает уже после его нарушения — Р1.",
    ]),
    ("Мера реагирования", "перечень действий под каждый уровень", BAD, [
        "Перечня мер нет, протокола эскалации нет: кто, в какой срок и кого "
        "уведомляет при приближении — не определено.",
        "Графы 6, 9, 10 Таблицы 2 приложения к Структуре отчёта по ВПОДК не заполнены.",
    ]),
    ("Контроль", "отчёт об уровнях, ежеквартально", WARN, [
        "Отчёт есть, но фиксирует факт против лимита — без сигнального уровня и без мер.",
        "По топ-20 недельный ряд ведётся с 2016 года и в отчётность с этой частотой "
        "не попадает: контроль медленнее данных.",
    ]),
]

# подпись на соединителе и его состояние
LINKS = [
    ("связи нет", BAD),
    ("калибровка от факта", WARN),
    ("звена нет", BAD),
    ("запускать нечем", BAD),
    ("контролировать нечего", BAD),
]

FOOTER = (
    "**Следствие.** За девять кварталов из 14 кредитных лимитов сработал один — "
    "и сразу нарушением, без предупреждения: 75,62 % → 92,66 % → 101,50 % при лимите 95 %. "
    "Цепочка, в которой отсутствуют звенья 1, 4 и 5, не может сработать раньше пробоя: "
    "предупреждать попросту нечем."
)

# --- вёрстка текста -------------------------------------------------------
def wrap(text, limit):
    out, line = [], ""
    for word in text.split():
        cand = f"{line} {word}".strip()
        if len(cand) > limit and line:
            out.append(line)
            line = word
        else:
            line = cand
    if line:
        out.append(line)
    return out

def rich(line, x, y, size, fill, weight="400"):
    """**жирный** внутри строки, без переносов — строка уже свёрнута."""
    parts, cur, bold = [], "", False
    for chunk in line.split("**"):
        if chunk:
            parts.append((chunk, bold))
        bold = not bold
    chunks = []
    for t, b in parts:
        w = "600" if b else weight
        col = ' fill="%s"' % INK if b else ""
        chunks.append('<tspan font-weight="%s"%s>%s</tspan>' % (w, col, escape(t)))
    spans = "".join(chunks)
    return (f'<text x="{x}" y="{y}" font-family="{FAM}" font-size="{size}" '
            f'fill="{fill}">{spans}</text>')

# --- сборка ---------------------------------------------------------------
def build():
    s = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
         f'viewBox="0 0 {W} {H}" role="img" '
         f'aria-label="Цепочка риск-аппетита и её фактические разрывы">']
    s.append("<defs>")
    for name, col in (("ok", OK), ("warn", WARN), ("bad", BAD)):
        s.append(f'<marker id="a-{name}" viewBox="0 0 10 10" refX="9" refY="5" '
                 f'markerWidth="6" markerHeight="6" orient="auto-start-reverse">'
                 f'<path d="M0 0L10 5L0 10z" fill="{col}"/></marker>')
    s.append("</defs>")
    s.append(f'<rect width="{W}" height="{H}" fill="{SURFACE}"/>')

    # шапка
    s.append(f'<text x="{BX}" y="52" font-family="{FAM}" font-size="27" '
             f'font-weight="600" fill="{INK}">Цепочка риск-аппетита и её фактические разрывы</text>')
    s.append(f'<text x="{BX}" y="80" font-family="{FAM}" font-size="13.5" fill="{MUTED}">'
             f'АО «Евразийский банк», контур кредитного риска, на 20.08.2026. '
             f'Ссылки — на пункты нормативных актов и на реестр находок FINDINGS_RA.md.</text>')
    s.append(f'<line x1="{BX}" y1="98" x2="{W-BX}" y2="98" stroke="{HAIR}" stroke-width="1"/>')

    # легенда
    lx = BX
    for col, cap in ((OK, "звено есть"), (WARN, "есть с оговоркой"), (BAD, "отсутствует")):
        s.append(f'<rect x="{lx}" y="114" width="11" height="11" rx="2.5" fill="{col}"/>')
        s.append(f'<text x="{lx+18}" y="124" font-family="{FAM}" font-size="12.5" '
                 f'fill="{MUTED}">{escape(cap)}</text>')
        lx += 24 + len(cap) * 7.1
    s.append(f'<text x="{W-BX}" y="124" text-anchor="end" font-family="{MONO}" '
             f'font-size="11.5" fill="{MUTED}">viz/chain_svg.py</text>')

    for i, (title, sub, state, notes) in enumerate(NODES):
        y = Y0 + i * PITCH

        # блок звена
        s.append(f'<rect x="{BX}" y="{y}" width="{BW}" height="{BH}" rx="7" '
                 f'fill="{TINT[state]}" stroke="{state}" stroke-width="1.4"/>')
        s.append(f'<rect x="{BX}" y="{y}" width="4.5" height="{BH}" rx="2" fill="{state}"/>')
        s.append(f'<text x="{BX+20}" y="{y+24}" font-family="{MONO}" font-size="11.5" '
                 f'fill="{MUTED}">{i+1}</text>')
        tl = wrap(title, 34)
        ty = y + 24 if len(tl) == 1 else y + 21
        for k, ln in enumerate(tl):
            s.append(f'<text x="{BX+42}" y="{ty + k*19}" font-family="{FAM}" font-size="16.5" '
                     f'font-weight="600" fill="{INK}">{escape(ln)}</text>')
        sy = ty + len(tl) * 19 + 6
        for k, ln in enumerate(wrap(sub, 48)):
            s.append(f'<text x="{BX+42}" y="{sy + k*15}" font-family="{FAM}" '
                     f'font-size="12" fill="{MUTED}">{escape(ln)}</text>')

        # пояснения справа
        ay = y + 20
        for note in notes:
            for ln in wrap(note, 74):
                s.append(rich(ln, AX, ay, 12.5, MUTED))
                ay += 17
            ay += 4

        # соединитель
        if i < len(NODES) - 1:
            cap, lstate = LINKS[i]
            y1, y2 = y + BH, y + PITCH
            if lstate == BAD:
                # разрыв: две culotte-отметки и пунктир
                s.append(f'<line x1="{CX}" y1="{y1}" x2="{CX}" y2="{y1+13}" '
                         f'stroke="{lstate}" stroke-width="2.2"/>')
                for dy in (0, 7):
                    s.append(f'<line x1="{CX-8}" y1="{y1+20+dy}" x2="{CX+8}" y2="{y1+14+dy}" '
                             f'stroke="{lstate}" stroke-width="2.2" stroke-linecap="round"/>')
                s.append(f'<line x1="{CX}" y1="{y1+34}" x2="{CX}" y2="{y2}" '
                         f'stroke="{lstate}" stroke-width="2.2" stroke-dasharray="4 4" '
                         f'marker-end="url(#a-bad)"/>')
            else:
                mk = "warn" if lstate == WARN else "ok"
                dash = ' stroke-dasharray="7 4"' if lstate == WARN else ""
                s.append(f'<line x1="{CX}" y1="{y1}" x2="{CX}" y2="{y2}" stroke="{lstate}" '
                         f'stroke-width="2.2"{dash} marker-end="url(#a-{mk})"/>')
            s.append(f'<text x="{CX+16}" y="{y1 + 32}" font-family="{FAM}" font-size="11.5" '
                     f'font-weight="600" fill="{lstate}">{escape(cap)}</text>')

    # следствие
    fy = Y0 + (len(NODES) - 1) * PITCH + BH + 34
    lines = wrap(FOOTER, 118)
    s.append(f'<rect x="{BX}" y="{fy}" width="{W-2*BX}" height="{22 + len(lines)*19}" '
             f'rx="7" fill="{TINT[BAD]}" stroke="{BAD}" stroke-width="1"/>')
    for k, ln in enumerate(lines):
        s.append(rich(ln, BX + 18, fy + 26 + k * 19, 13, INK if k == 0 else MUTED))

    s.append("</svg>")
    return "\n".join(s)

def rasterize(svg_path, png_path, scale=1.4):
    """PNG нужен только для вставки в .docx: docx-js не принимает SVG.
    Источник истины — .svg; PNG всегда пересобирается из него, не правится."""
    import base64
    from playwright.sync_api import sync_playwright
    chrome = "/opt/pw-browsers/chromium-1194/chrome-linux/chrome"
    b64 = base64.b64encode(svg_path.read_bytes()).decode()
    holder = svg_path.with_suffix(".render.html")
    holder.write_text(
        f'<body style="margin:0"><img src="data:image/svg+xml;base64,{b64}" '
        f'width="{W}" height="{H}"></body>', encoding="utf-8")
    with sync_playwright() as p:
        kw = {"executable_path": chrome} if Path(chrome).exists() else {}
        b = p.chromium.launch(**kw)
        pg = b.new_page(viewport={"width": W, "height": H}, device_scale_factor=scale)
        pg.goto("file://" + str(holder.resolve()))
        pg.wait_for_timeout(700)
        pg.screenshot(path=str(png_path))
        b.close()
    holder.unlink()

if __name__ == "__main__":
    import sys
    out = Path(__file__).with_name("chain.svg")
    out.write_text(build(), encoding="utf-8")
    print(f"{out} — {out.stat().st_size} байт")
    if "--png" in sys.argv:
        png = out.with_suffix(".png")
        try:
            rasterize(out, png)
            print(f"{png} — {png.stat().st_size} байт")
        except ImportError:
            print("для --png нужен playwright: pip install playwright")
