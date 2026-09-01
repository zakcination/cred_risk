# -*- coding: utf-8 -*-
"""Рендер витрины риск-метрик в HTML: полочка = нормативный документ.

Запуск: python3 build/render_showcase.py [--fixture]
  --fixture — собрать витрину на демонстрационных значениях (данных банка нет)
"""

import html as H
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import showcase as S  # noqa: E402

ROOT = S.ROOT
ZONE_RU = {"red": "красная", "yellow": "жёлтая", "green": "зелёная", "na": "нет данных"}


def e(s):
    return H.escape(str(s or ""))


def spark(series, m, w=132, h=34):
    """Мини-график: область, линия лимита, выделенная последняя точка."""
    vals = [v for v in series if v is not None]
    if len(vals) < 2:
        return ""
    lim = S.num(m["limit"])
    lo, hi = min(vals), max(vals)
    if lim is not None:
        lo, hi = min(lo, lim), max(hi, lim)
    rng = (hi - lo) or 1
    pad = rng * 0.15
    lo, hi = lo - pad, hi + pad
    rng = hi - lo

    def xy(i, v):
        x = 1 + i * (w - 2) / (len(vals) - 1)
        y = h - 1 - (v - lo) / rng * (h - 2)
        return x, y

    pts = [xy(i, v) for i, v in enumerate(vals)]
    line = " ".join(f"{x:.1f},{y:.1f}" for x, y in pts)
    area = f"{pts[0][0]:.1f},{h} " + line + f" {pts[-1][0]:.1f},{h}"
    out = [f'<svg class="spark" viewBox="0 0 {w} {h}" width="{w}" height="{h}" '
           f'aria-hidden="true">']
    if lim is not None and lo <= lim <= hi:
        ly = h - 1 - (lim - lo) / rng * (h - 2)
        out.append(f'<line x1="0" y1="{ly:.1f}" x2="{w}" y2="{ly:.1f}" '
                   f'class="spark-lim"/>')
    out.append(f'<polygon points="{area}" class="spark-area"/>')
    out.append(f'<polyline points="{line}" class="spark-line"/>')
    out.append(f'<circle cx="{pts[-1][0]:.1f}" cy="{pts[-1][1]:.1f}" r="2.6" '
               f'class="spark-dot"/>')
    out.append("</svg>")
    return "".join(out)


def gauge(r):
    """Полоса утилизации с засечками сигнального уровня и лимита."""
    u = r["util"]
    if u is None:
        return ""
    pos = max(2, min(100, u))
    sig, lim = S.num(r["signal"]), S.num(r["limit"])
    tick = ""
    if sig and lim:
        sp = (sig / lim * 100) if r["direction"] == "up_bad" else (lim / sig * 100)
        if 0 < sp < 100:
            tick = f'<i class="tick" style="left:{sp:.0f}%"></i>'
    over = min(100, max(0, u - 100)) if u > 100 else 0
    return (f'<div class="gauge" role="img" aria-label="утилизация {u:.0f} %">'
            f'<div class="fill z-{r["zone"]}" style="width:{min(pos,100):.0f}%"></div>'
            f'{tick}<i class="lim"></i>'
            f'{f"<div class=over style=width:{over:.0f}%></div>" if over else ""}'
            f'</div>')


def card(r):
    d = r["dyn"]
    val = S.ru(d["last"]) if d["last"] is not None else "—"
    unit = e(r["unit"])
    bits = []
    if d["over_limit"]:
        bits.append(f'<span class="chip crit">выше лимита {d["over_limit"]} мес.</span>')
    elif d["in_zone"]:
        bits.append(f'<span class="chip warn">в зоне {d["in_zone"]} мес.</span>')
    if r["counter"] != "single":
        cls = "crit" if r["counter_fired"] else (
            "warn" if r["counter_need"] and r["counter_now"] >= r["counter_need"] * .5 else "")
        bits.append(f'<span class="chip {cls}">{e(r["counter_text"])}</span>')
    if d["eta"] is not None:
        bits.append(f'<span class="chip">до лимита ~{S.ru(d["eta"], 1)} мес.</span>')
    if d["sigma_dist"] is not None and abs(d["sigma_dist"]) < 12:
        bits.append(f'<span class="chip">запас {S.ru(d["sigma_dist"], 1)} σ</span>')
    if r["breaches_12"] if "breaches_12" in r else d["breaches_12"] > 1:
        bits.append(f'<span class="chip warn">{d["breaches_12"]} пробоя за 12 мес.</span>')

    speeds = []
    for key, lab in (("speed_p", "период"), ("speed_q", "квартал"), ("speed_y", "год")):
        if d[key] is not None:
            sign = "+" if d[key] > 0 else ""
            speeds.append(f'<span><b>{lab}</b> {sign}{S.ru(d[key], 2)}</span>')

    return f"""
<article class="card z-{r['zone']}">
  <header>
    <code>{e(r['code'])}</code>
    <span class="zone z-{r['zone']}">{ZONE_RU[r['zone']]}</span>
  </header>
  <h3>{e(r['name'])}</h3>
  <div class="figure"><b>{val}</b><span>{unit}</span>
    <em>лимит {e(r['limit']) or '—'}{(' · сигнал ' + e(r['signal'])) if r['signal'] else ''}</em>
  </div>
  {gauge(r)}
  <div class="row">{spark(r['series'], r)}
    <div class="speeds">{''.join(speeds) or '<span class="mut">нет ряда</span>'}</div>
  </div>
  <div class="chips">{''.join(bits)}</div>
  <footer>
    <span class="freq" title="частота данных / частота контроля">
      {S.FREQ_RU.get(r['data_freq'], r['data_freq'])} → {S.FREQ_RU.get(r['monitor_freq'], r['monitor_freq'])}
      {'<b class="mism">разрыв</b>' if r['freq_mismatch'] else ''}
    </span>
    <span class="src">{e(r['source'])}</span>
  </footer>
</article>"""


def build(rows, shelves, cons, out_path, note):
    by_shelf = {}
    for r in rows:
        by_shelf.setdefault(r["shelf"], []).append(r)
    order = {"red": 0, "yellow": 1, "green": 2, "na": 3}

    n_red = sum(1 for r in rows if r["zone"] == "red")
    n_yel = sum(1 for r in rows if r["zone"] == "yellow")
    n_edge = sum(1 for r in rows if r["counter"] != "single" and r["counter_need"]
                 and 0 < r["counter_now"] < r["counter_need"])
    n_mism = sum(1 for r in rows if r["freq_mismatch"])
    n_data = sum(1 for r in rows if r["zone"] != "na")

    shelf_html = []
    for sh in shelves:
        items = sorted(by_shelf.get(sh["shelf"], []), key=lambda r: order[r["zone"]])
        live = [r for r in items if r["zone"] != "na"]
        idle = [r for r in items if r["zone"] == "na"]
        idle_html = ""
        if idle:
            chips = "".join(f'<span class="idle">{e(r["code"])} · {e(r["name"])}</span>'
                            for r in idle)
            idle_html = (f'<div class="idle-wrap"><h4>Ожидают данных '
                         f'({len(idle)})</h4><div class="idle-list">{chips}</div></div>')
        shelf_html.append(f"""
<section class="shelf">
  <div class="rail">
    <h2>{e(sh['title'])}</h2>
    <p class="act">{e(sh['act'])}</p>
    <p class="reqs">{e(sh['reqs'])}</p>
    <p class="role">{e(sh['role'])}</p>
    <p class="own">Владелец мониторинга: {e(sh['monitor_owner'])}</p>
    <p class="count">{len(items)} метрик · с данными {len(live)}</p>
  </div>
  <div class="cards">{''.join(card(r) for r in live) or
     '<p class="mut empty">По этой полочке ещё нет наблюдений.</p>'}{idle_html}</div>
</section>""")

    crows = []
    for c in cons:
        crows.append(f"""<tr class="lvl-{e(c['level'])}">
  <td><code>{e(c['key'])}</code></td><td>{e(c['trigger'])}</td>
  <td>{e(c['consequence'])}</td><td class="dl">{e(c['deadline'])}</td>
  <td class="nm">{e(c['norm'])}</td>
  <td class="pub">{'публично' if c['public'] == 'да' else '—'}</td></tr>""")

    html = f"""<title>Витрина риск-метрик</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Golos+Text:wght@400;500;600;700&family=IBM+Plex+Mono:wght@400;500;600&display=swap">
<style>
:root {{
  --bg:#F5F7FA; --surface:#FFFFFF; --surface-2:#EDF1F6; --ink:#151D27;
  --muted:#5C6B7C; --line:#D6DEE8; --accent:#35507A; --accent-soft:#E4EAF4;
  --ok:#2F7D52; --ok-bg:#E8F2EC; --warn:#A9711A; --warn-bg:#FBF1DF;
  --crit:#A0392A; --crit-bg:#FAE9E5; --shadow:0 1px 2px rgba(21,29,39,.06);
}}
@media (prefers-color-scheme: dark) {{
  :root:not([data-theme="light"]) {{
    --bg:#0E141A; --surface:#161E27; --surface-2:#1D2731; --ink:#E6EDF4;
    --muted:#94A5B6; --line:#28323E; --accent:#8AA9DA; --accent-soft:#1C2836;
    --ok:#61BB8B; --ok-bg:#16261E; --warn:#D6A244; --warn-bg:#2A2213;
    --crit:#E07E68; --crit-bg:#2C1A16; --shadow:0 1px 2px rgba(0,0,0,.4);
  }}
}}
:root[data-theme="dark"] {{
  --bg:#0E141A; --surface:#161E27; --surface-2:#1D2731; --ink:#E6EDF4;
  --muted:#94A5B6; --line:#28323E; --accent:#8AA9DA; --accent-soft:#1C2836;
  --ok:#61BB8B; --ok-bg:#16261E; --warn:#D6A244; --warn-bg:#2A2213;
  --crit:#E07E68; --crit-bg:#2C1A16; --shadow:0 1px 2px rgba(0,0,0,.4);
}}
* {{ box-sizing:border-box; }}
body {{ margin:0; background:var(--bg); color:var(--ink);
  font:400 15px/1.55 "Golos Text","Segoe UI",system-ui,sans-serif;
  font-variant-numeric:tabular-nums; }}
.wrap {{ max-width:1280px; margin:0 auto; padding:34px 22px 70px; }}
h1 {{ font-size:30px; font-weight:700; letter-spacing:-.01em; margin:0 0 6px;
  text-wrap:balance; }}
.sub {{ color:var(--muted); margin:0 0 4px; font-size:15px; }}
.meta {{ color:var(--muted); font-size:12.5px; margin:0 0 26px;
  font-family:"IBM Plex Mono",monospace; }}
.strip {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(150px,1fr));
  gap:10px; margin-bottom:14px; }}
.stat {{ background:var(--surface); border:1px solid var(--line); border-radius:8px;
  padding:12px 14px; box-shadow:var(--shadow); }}
.stat b {{ display:block; font-size:26px; font-weight:600; line-height:1.1;
  font-family:"IBM Plex Mono",monospace; }}
.stat span {{ font-size:12px; color:var(--muted); text-transform:uppercase;
  letter-spacing:.06em; }}
.stat.crit b {{ color:var(--crit); }} .stat.warn b {{ color:var(--warn); }}
.note {{ background:var(--accent-soft); border-left:3px solid var(--accent);
  border-radius:0 6px 6px 0; padding:11px 15px; font-size:13.5px; margin:0 0 30px; }}
.shelf {{ display:grid; grid-template-columns:236px 1fr; gap:20px; margin:0 0 30px;
  padding-top:20px; border-top:2px solid var(--ink); }}
.rail h2 {{ font-size:18px; font-weight:600; margin:0 0 8px; text-wrap:balance; }}
.rail p {{ margin:0 0 6px; font-size:12.5px; color:var(--muted); }}
.rail .act {{ color:var(--accent); font-weight:500; }}
.rail .reqs {{ font-family:"IBM Plex Mono",monospace; font-size:11.5px; }}
.rail .count {{ font-family:"IBM Plex Mono",monospace; font-size:11.5px;
  padding-top:6px; border-top:1px solid var(--line); }}
.cards {{ display:grid; grid-template-columns:repeat(auto-fill,minmax(268px,1fr));
  gap:12px; align-content:start; }}
.card {{ background:var(--surface); border:1px solid var(--line); border-radius:9px;
  padding:13px 14px; box-shadow:var(--shadow); border-left:3px solid var(--line);
  display:flex; flex-direction:column; gap:8px; }}
.card.z-red {{ border-left-color:var(--crit); }}
.card.z-yellow {{ border-left-color:var(--warn); }}
.card.z-green {{ border-left-color:var(--ok); }}
.card header {{ display:flex; justify-content:space-between; align-items:center; }}
.card code {{ font-family:"IBM Plex Mono",monospace; font-size:11.5px;
  color:var(--muted); }}
.card h3 {{ font-size:14px; font-weight:600; margin:0; line-height:1.3; }}
.zone {{ font-size:10.5px; text-transform:uppercase; letter-spacing:.07em;
  padding:2px 7px; border-radius:20px; font-weight:600; }}
.zone.z-red {{ background:var(--crit-bg); color:var(--crit); }}
.zone.z-yellow {{ background:var(--warn-bg); color:var(--warn); }}
.zone.z-green {{ background:var(--ok-bg); color:var(--ok); }}
.zone.z-na {{ background:var(--surface-2); color:var(--muted); }}
.figure {{ display:flex; align-items:baseline; gap:5px; flex-wrap:wrap; }}
.figure b {{ font-family:"IBM Plex Mono",monospace; font-size:24px; font-weight:600; }}
.figure span {{ color:var(--muted); font-size:13px; }}
.figure em {{ margin-left:auto; font-style:normal; font-size:11.5px;
  color:var(--muted); font-family:"IBM Plex Mono",monospace; }}
.gauge {{ position:relative; height:7px; background:var(--surface-2);
  border-radius:4px; overflow:visible; }}
.gauge .fill {{ height:100%; border-radius:4px; }}
.fill.z-red {{ background:var(--crit); }} .fill.z-yellow {{ background:var(--warn); }}
.fill.z-green {{ background:var(--ok); }} .fill.z-na {{ background:var(--muted); }}
.gauge .tick {{ position:absolute; top:-3px; width:1.5px; height:13px;
  background:var(--warn); opacity:.75; }}
.gauge .lim {{ position:absolute; top:-3px; right:0; width:2px; height:13px;
  background:var(--ink); }}
.gauge .over {{ position:absolute; top:0; right:-1px; height:7px;
  background:repeating-linear-gradient(45deg,var(--crit),var(--crit) 3px,
  transparent 3px,transparent 6px); border-radius:0 4px 4px 0; }}
.row {{ display:flex; align-items:center; gap:10px; justify-content:space-between; }}
.spark {{ display:block; flex:0 0 auto; }}
.spark-area {{ fill:var(--accent); opacity:.13; }}
.spark-line {{ fill:none; stroke:var(--accent); stroke-width:1.6; }}
.spark-dot {{ fill:var(--accent); }}
.spark-lim {{ stroke:var(--crit); stroke-width:1; stroke-dasharray:3 3; opacity:.6; }}
.speeds {{ display:flex; flex-direction:column; gap:1px; font-size:11px;
  color:var(--muted); font-family:"IBM Plex Mono",monospace; text-align:right; }}
.speeds b {{ font-weight:400; opacity:.7; }}
.chips {{ display:flex; flex-wrap:wrap; gap:5px; }}
.chip {{ font-size:11px; padding:2px 7px; border-radius:5px;
  background:var(--surface-2); color:var(--muted); }}
.chip.warn {{ background:var(--warn-bg); color:var(--warn); font-weight:500; }}
.chip.crit {{ background:var(--crit-bg); color:var(--crit); font-weight:500; }}
.card footer {{ display:flex; justify-content:space-between; gap:8px;
  font-size:10.5px; color:var(--muted); border-top:1px solid var(--line);
  padding-top:7px; margin-top:auto; }}
.freq .mism {{ color:var(--crit); }}
.src {{ font-family:"IBM Plex Mono",monospace; text-align:right; }}
.idle-wrap {{ grid-column:1/-1; }}
.idle-wrap h4 {{ font-size:11.5px; text-transform:uppercase; letter-spacing:.06em;
  color:var(--muted); margin:6px 0 7px; font-weight:600; }}
.idle-list {{ display:flex; flex-wrap:wrap; gap:5px; }}
.idle {{ font-size:11px; color:var(--muted); background:var(--surface);
  border:1px dashed var(--line); border-radius:5px; padding:3px 8px; }}
.mut {{ color:var(--muted); }} .empty {{ font-size:13px; }}
h2.sec {{ font-size:20px; margin:38px 0 12px; padding-top:18px;
  border-top:2px solid var(--ink); }}
.tbl {{ overflow-x:auto; background:var(--surface); border:1px solid var(--line);
  border-radius:9px; box-shadow:var(--shadow); }}
table {{ border-collapse:collapse; width:100%; font-size:13px; min-width:900px; }}
th {{ text-align:left; background:var(--surface-2); color:var(--muted);
  font-size:11px; text-transform:uppercase; letter-spacing:.05em;
  padding:9px 12px; border-bottom:1px solid var(--line); font-weight:600; }}
td {{ padding:9px 12px; border-bottom:1px solid var(--line); vertical-align:top; }}
tr:last-child td {{ border-bottom:none; }}
td code {{ font-family:"IBM Plex Mono",monospace; font-size:11.5px;
  color:var(--accent); }}
.dl, .nm, .pub {{ font-size:11.5px; color:var(--muted); }}
.nm {{ font-family:"IBM Plex Mono",monospace; }}
tr.lvl-3 td, tr.lvl-2 td {{ background:transparent; }}
tr.lvl-3 code {{ color:var(--crit); }}
.rules {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(240px,1fr));
  gap:12px; margin-top:12px; }}
.rule {{ background:var(--surface); border:1px solid var(--line); border-radius:9px;
  padding:13px 15px; box-shadow:var(--shadow); }}
.rule h3 {{ font-size:13.5px; margin:0 0 5px; }}
.rule p {{ margin:0; font-size:12.5px; color:var(--muted); }}
footer.page {{ margin-top:34px; padding-top:16px; border-top:1px solid var(--line);
  font-size:12px; color:var(--muted); }}
@media (max-width:820px) {{
  .shelf {{ grid-template-columns:1fr; }}
  .rail {{ padding-bottom:6px; border-bottom:1px solid var(--line); }}
}}
</style>
<div class="wrap">
<h1>Витрина риск-метрик</h1>
<p class="sub">Полочка — нормативный документ. Карточка — метрика: факт против лимита,
зона, длительность нахождения в зоне, скорость приближения и частота наблюдения.</p>
<p class="meta">БРМ, АО «Евразийский банк» · docs/analysis/risk_showcase · 19.08.2026 · {note}</p>

<div class="strip">
  <div class="stat crit"><b>{n_red}</b><span>в красной зоне</span></div>
  <div class="stat warn"><b>{n_yel}</b><span>в жёлтой зоне</span></div>
  <div class="stat warn"><b>{n_edge}</b><span>счётчик идёт</span></div>
  <div class="stat"><b>{n_data}/{len(rows)}</b><span>метрик с данными</span></div>
  <div class="stat crit"><b>{n_mism}</b><span>контроль реже данных</span></div>
</div>
<p class="note"><b>Как читать.</b> Полоса — утилизация лимита: засечка внутри —
сигнальный уровень, тёмная черта справа — сам лимит, штриховка за краем — пробой.
Чип со счётчиком показывает, сколько периодов из требуемых нормой уже набрано
(например, «4 из 6 месяцев подряд» по № 119). Строка внизу карточки — частота
данных → частота контроля; пометка «разрыв» означает, что контроль реже
наблюдения и сигнал может быть замечен позже, чем возник.</p>

{''.join(shelf_html)}

<h2 class="sec">Последствия несоблюдения</h2>
<div class="tbl"><table>
<thead><tr><th>Ключ</th><th>Событие</th><th>Что наступает</th><th>Срок</th>
<th>Норма</th><th>Публичность</th></tr></thead>
<tbody>{''.join(crows)}</tbody></table></div>

<h2 class="sec">Правила ведения витрины</h2>
<div class="rules">
  <div class="rule"><h3>Частота контроля = частота данных</h3>
    <p>Если ряд недельный, смотреть еженедельно. Метрики с пометкой «разрыв»
    в карточке — кандидаты на учащение контроля.</p></div>
  <div class="rule"><h3>Порог наблюдения ниже порога реагирования</h3>
    <p>Сигнальный уровень ставится с запасом от лимита и калибруется
    по волатильности метрики, а не «на глаз».</p></div>
  <div class="rule"><h3>Длительность — такая же величина, как факт</h3>
    <p>Счётчики нормы (6 месяцев подряд, 3 раза за 6 месяцев) и число месяцев
    в зоне ведутся наравне со значением: часть последствий наступает
    именно от длительности.</p></div>
  <div class="rule"><h3>Пустая метрика — тоже сигнал</h3>
    <p>Если по метрике несколько периодов подряд нет данных либо ровный ноль,
    это повод проверить саму метрику, а не радоваться.</p></div>
  <div class="rule"><h3>Один документ со статусом всех метрик</h3>
    <p>Витрина закрывает графы 6, 9 и 10 Таблицы 2 приложения к Структуре
    отчёта по ВПОДК: зона, случаи достижения уровня и их длительность.</p></div>
  <div class="rule"><h3>Значения сверяются с текстом</h3>
    <p>Метрики с непроверенным значением помечаются в реестре
    (verified = no) и не используются в отчётности до сверки.</p></div>
</div>

<footer class="page">Источник значений — реестр registry/metrics.csv (полочки,
пороги, счётчики, частоты, ссылки на пункты); расчёт динамики —
build/showcase.py (самопроверка на фикстуре). Данные банка в репозиторий
не попадают.</footer>
</div>"""
    with open(out_path, "w", encoding="utf-8") as fh:
        fh.write(html)
    return html


def main():
    metrics = S.read("registry/metrics.csv")
    shelves = S.read("registry/shelves.csv")
    cons = S.read("registry/consequences.csv")
    if "--fixture" in sys.argv:
        _, _ = None, None
        rows, _m = S.selftest_rows()
        note = "ДЕМОНСТРАЦИОННЫЕ значения (фикстура) — данных банка нет"
    else:
        obs_path = os.path.join(ROOT, "data", "observations.csv")
        obs = S.read("data/observations.csv") if os.path.exists(obs_path) else []
        rows = S.collect(metrics, obs)
        note = f"наблюдений в data/observations.csv: {len(obs)}"
    out = os.path.join(ROOT, "out", "vitrina.html")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    build(rows, shelves, cons, out, note)
    print(f"написан {out} ({os.path.getsize(out) // 1024} КБ)")


if __name__ == "__main__":
    main()
