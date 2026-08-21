#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Exhibit-set по контуру риск-аппетита. Палитра и правила — dataviz skill.
Один источник истины: docs/analysis/risk_appetite/data/*.csv."""
import csv, os, statistics as st
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle, Patch
from matplotlib.lines import Line2D
import matplotlib.ticker as mticker

DATA = "/home/user/cred_risk/docs/analysis/risk_appetite/data"
OUT  = os.path.dirname(os.path.abspath(__file__))

# ── палитра (reference instance, light mode) ───────────────────────────────
SURFACE  = "#fcfcfb"
INK      = "#0b0b0b"
INK2     = "#52514e"
MUTED    = "#898781"
GRID     = "#e1e0d9"
BASE     = "#c3c2b7"
S1, S2, S3 = "#2a78d6", "#eb6834", "#1baf7a"   # категориальные слоты 1-3
CRIT, WARN, GOOD = "#d03b3b", "#fab219", "#0ca30c"

plt.rcParams.update({
    "font.family": "DejaVu Sans", "font.size": 10,
    "figure.facecolor": SURFACE, "axes.facecolor": SURFACE,
    "savefig.facecolor": SURFACE, "text.color": INK,
    "axes.edgecolor": BASE, "axes.labelcolor": INK2,
    "xtick.color": MUTED, "ytick.color": MUTED,
    "axes.grid": True, "grid.color": GRID, "grid.linewidth": 0.8,
    "axes.axisbelow": True, "axes.spines.top": False, "axes.spines.right": False,
    "legend.frameon": False, "figure.dpi": 200,
})

def rows(name):
    with open(f"{DATA}/{name}", encoding="utf8") as f:
        return list(csv.DictReader(l for l in f if not l.startswith("#")))

def frame(fig, title, kicker, source):
    """Заголовочный блок в стиле аналитического экспоната."""
    fig.text(0.035, 0.965, kicker, fontsize=9, color=S1, weight="bold", va="top")
    fig.text(0.035, 0.925, title, fontsize=15, color=INK, weight="bold", va="top")
    fig.text(0.035, -0.012, source, fontsize=7.5, color=MUTED, va="bottom")

def save(fig, name):
    p = f"{OUT}/{name}.png"
    fig.savefig(p, bbox_inches="tight", pad_inches=0.35)
    plt.close(fig)
    print("→", os.path.basename(p))

# ══════════════════════════════════════════════════════════════════════════
# 1. Восемь с половиной лет без единого превышения
# ══════════════════════════════════════════════════════════════════════════
def ex1():
    from datetime import date
    import matplotlib.dates as mdates
    lim = rows("top20_limit_history.csv")
    eps = rows("top20_breach_episodes.csv")
    d = lambda s: mdates.date2num(date.fromisoformat(s))

    fig, ax = plt.subplots(figsize=(11, 4.2))
    # режимы уровня
    for r in lim:
        x0, x1 = d(r["period_start"]), d(r["period_end"])
        ax.add_patch(Rectangle((x0, 0.55), x1 - x0, 0.30,
                               facecolor=S1, alpha=0.14, edgecolor="none"))
        ax.text(x0 + (x1 - x0) / 2, 0.70, f'уровень {r["limit_pct"]} %',
                ha="center", va="center", fontsize=10, color=S1, weight="bold")
        ax.text(x0 + (x1 - x0) / 2, 0.60, f'{r["n_observations"]} наблюдений',
                ha="center", va="center", fontsize=8, color=INK2)
    # эпизоды превышения
    for r in eps:
        x0, x1 = d(r["start"]), d(r["end"])
        w = max(x1 - x0, 25)
        ax.add_patch(Rectangle((x0, 0.15), w, 0.28, facecolor=CRIT,
                               edgecolor="none", alpha=0.92))
    # разрыв
    gap0, gap1 = d("2017-11-06"), d("2026-05-04")
    ax.annotate("", xy=(gap0, 0.06), xytext=(gap1, 0.06),
                arrowprops=dict(arrowstyle="<->", color=INK2, lw=1.2))
    ax.text(gap0 + (gap1 - gap0) / 2, 0.005,
            "8 лет 6 месяцев без единого превышения",
            ha="center", va="bottom", fontsize=11, color=INK, weight="bold")
    ax.text(d("2016-04-01"), 0.455, "5 эпизодов, 353 дня\nмаксимум 300,51 %",
            fontsize=8.5, color=CRIT, va="top")
    ax.text(d("2026-04-01"), 0.455, "99 дней, не завершён\nмаксимум 103,11 %",
            fontsize=8.5, color=CRIT, va="top", ha="right")

    ax.set_ylim(-0.05, 0.95); ax.set_yticks([])
    ax.set_xlim(d("2016-01-01"), d("2026-12-31"))
    ax.xaxis.set_major_locator(mdates.YearLocator())
    ax.xaxis.set_major_formatter(mdates.DateFormatter("%Y"))
    ax.grid(False); ax.spines["left"].set_visible(False)
    ax.spines["bottom"].set_color(BASE)
    ax.legend(handles=[Patch(facecolor=CRIT, label="превышение действовавшего уровня"),
                       Patch(facecolor=S1, alpha=0.14, label="режим уровня риск-аппетита")],
              loc="upper center", bbox_to_anchor=(0.5, 1.14), ncol=2, fontsize=9)
    frame(fig, "Уровень не ограничивал показатель восемь с половиной лет",
          "ЭКСПОНАТ 1 · КОЭФФИЦИЕНТ ТОП-20",
          "Источник: недельный ряд из 521 наблюдения, 11.05.2016 — 10.08.2026. "
          "Эпизоды считаны относительно уровня, действовавшего на дату, а не текущего.")
    fig.subplots_adjust(top=0.72, bottom=0.18)
    save(fig, "ex1_episodes_timeline")

# ══════════════════════════════════════════════════════════════════════════
# 2. Три четверти пробоя сделал знаменатель
# ══════════════════════════════════════════════════════════════════════════
def ex2():
    r = rows("top20_quarterly_decomposition.csv")
    q  = [x["quarter"].replace(" (на 10.08)", "\n(на 10.08)") for x in r]
    pf = [float(x["portfolio_contrib_pp"]) for x in r]
    cp = [float(x["capital_contrib_pp"])   for x in r]
    tot= [float(x["delta_pp"]) for x in r]
    idx = range(len(q)); w = 0.38

    fig, ax = plt.subplots(figsize=(10, 4.6))
    ax.add_patch(Rectangle((1.5, -10.1), 2.0, 34.1, facecolor=WARN,
                           alpha=0.10, edgecolor="none", zorder=0))
    ax.bar([i - w/2 for i in idx], pf, w, color=S1, label="вклад портфеля")
    ax.bar([i + w/2 for i in idx], cp, w, color=S2, label="вклад капитала")
    ax.axhline(0, color=BASE, lw=1)
    for i, (p, c, t) in enumerate(zip(pf, cp, tot)):
        for v, off in ((p, -w/2), (c, w/2)):
            ax.text(i + off, v + (0.7 if v >= 0 else -0.7), f"{v:+.2f}".replace(".", ","),
                    ha="center", va="bottom" if v >= 0 else "top",
                    fontsize=8.5, color=INK2)
        ax.text(i, 22.4, f"Δ {t:+.2f}".replace(".", ","), ha="center",
                fontsize=9.5, color=INK, weight="bold")
    ax.text(2.5, -9.3, "за два квартала +27,25 пп, из них 74 % — капитал",
            ha="center", fontsize=10, color=INK, weight="bold")
    ax.annotate("собственный капитал\n−107,7 млрд ₸ (−19,66 %)",
                xy=(2 + w/2 - 0.06, 17.0), xytext=(0.15, 15.5),
                fontsize=9, color=S2, va="center",
                arrowprops=dict(arrowstyle="->", color=S2, lw=1.2))
    ax.set_xticks(list(idx)); ax.set_xticklabels(q, fontsize=9)
    ax.set_ylabel("вклад в изменение доли, пп")
    ax.set_ylim(-10.6, 25.5)
    ax.legend(loc="lower left", fontsize=9, bbox_to_anchor=(0.0, 0.02))
    frame(fig, "Уровень пробит знаменателем, а не ростом портфеля",
          "ЭКСПОНАТ 2 · ДЕКОМПОЗИЦИЯ ПРИРАЩЕНИЯ",
          "Точное разложение: Δ = (N₁−N₀)/E₀ + N₁·(E₀−E₁)/(E₀·E₁), где N — задолженность "
          "топ-20 за вычетом денежного обеспечения, E — собственный капитал.")
    fig.subplots_adjust(top=0.78, bottom=0.20)
    save(fig, "ex2_decomposition")

# ══════════════════════════════════════════════════════════════════════════
# 3. Утилизация вводит в заблуждение
# ══════════════════════════════════════════════════════════════════════════
RU = {"top20_to_equity":"Топ-20 / собственный капитал","cor":"Стоимость риска",
      "el_total":"EL совокупный","el_unsecured":"EL необеспеченные",
      "el_secured":"EL обеспеченные","el_other":"EL прочие",
      "pd_unsecured":"PD необеспеченные","pd_unsecured_cash":"PD необесп. денежные",
      "pd_unsecured_goods":"PD необесп. товарные","pd_secured":"PD обеспеченные",
      "pd_other":"PD прочие"}
SEG = {"KB":"КБ","KB_PB":"КБ/ПБ","MSB":"МСБ","RB":"РБ"}

def metrics():
    out = []
    for r in rows("ra_credit_series_q2_2024_q2_2026.csv"):
        qs = [k for k in r if k.startswith("Q")]
        try:
            v = [float(r[q]) for q in qs]
        except ValueError:
            continue
        lim = float(r["limit_pct"])
        s = st.pstdev([v[i+1]-v[i] for i in range(len(v)-1)])
        if s == 0 or r["metric"] not in RU:
            continue
        out.append(dict(name=f'{RU[r["metric"]]} ({SEG[r["segment"]]})',
                        util=100*v[-1]/lim, dist=(lim-v[-1])/s))
    return out

def ex3():
    m = sorted(metrics(), key=lambda x: x["dist"])
    fig, ax = plt.subplots(figsize=(10, 5.4))
    for i, x in enumerate(m):
        col = CRIT if x["dist"] < 0 else (WARN if x["dist"] < 12 else S1)
        ax.barh(i, min(x["dist"], 95), color=col, height=0.5)
        lbl = f'{x["dist"]:.1f} σ'.replace(".", ",") if x["dist"] >= 0 else "нарушен"
        ax.text(max(min(x["dist"], 95), 0) + 1.2, i, lbl, va="center",
                fontsize=8.5, color=INK2, zorder=5,
                bbox=dict(fc=SURFACE, ec="none", pad=1.2))
    ax.axvline(12, color=INK2, lw=1, ls=(0, (4, 3)), zorder=1)
    ax.text(12.8, len(m)-0.4, "граница практической достижимости", fontsize=8.5, color=INK2)
    ax.set_yticks(range(len(m)))
    ax.set_yticklabels([f'{x["name"]}   ·   утилизация {x["util"]:.0f} %' for x in m],
                       fontsize=9)
    ax.set_xlabel("расстояние до лимита в квартальных σ самой метрики")
    ax.set_xlim(-3, 100); ax.set_ylim(-0.8, len(m)-0.2)
    ax.grid(axis="y", visible=False)
    ax.spines["left"].set_visible(False)
    ax.legend(handles=[Patch(facecolor=CRIT, label="нарушен"),
                       Patch(facecolor=WARN, label="активен по динамике"),
                       Patch(facecolor=S1,   label="недостижим в обозримом горизонте")],
              loc="upper center", bbox_to_anchor=(0.5, 1.10), ncol=3, fontsize=9)
    frame(fig, "Высокая утилизация лимита не означает близости к нему",
          "ЭКСПОНАТ 3 · 12 КРЕДИТНЫХ МЕТРИК",
          "σ — стандартное отклонение квартальных приращений, 9 наблюдений Q2 2024 — Q2 2026. "
          "Оценка с широким доверительным интервалом, используется для ранжирования, не как основание уровня.")
    fig.subplots_adjust(top=0.80, left=0.34, bottom=0.14)
    save(fig, "ex3_sigma_vs_utilisation")

# ══════════════════════════════════════════════════════════════════════════
# 4. Обрыв между 88 и 90
# ══════════════════════════════════════════════════════════════════════════
def ex4():
    r = rows("top20_signal_calibration.csv")
    th = [float(x["threshold_pct"]) for x in r]
    wd = [float(x["warning_days"])  for x in r]
    tz = [float(x["time_in_yellow_pct"]) for x in r]

    fig, (a1, a2) = plt.subplots(2, 1, figsize=(9.5, 5.8), sharex=True,
                                 gridspec_kw={"height_ratios": [2, 1], "hspace": 0.18})
    a1.step(th, wd, where="post", color=S1, lw=2)
    a1.plot(th, wd, "o", ms=8, color=S1)
    for x, y in zip(th, wd):
        a1.text(x, y + 3.5, f"{int(y)} дн.", ha="center", fontsize=9, color=INK2)
    a1.plot([88], [63], "o", ms=13, mfc="none", mec=CRIT, mew=2.2)
    a1.annotate("рекомендуемое значение 88 %\n2,4 σ над максимумом режима",
                xy=(88, 63), xytext=(84.6, 34), fontsize=9, color=CRIT,
                arrowprops=dict(arrowstyle="->", color=CRIT, lw=1.2))
    a1.set_ylabel("запас предупреждения, дней"); a1.set_ylim(0, 80)

    a2.bar(th, tz, width=0.55, color=S2)
    for x, y in zip(th, tz):
        a2.text(x, y + 0.12, f"{y:.1f}".replace(".", ",") + " %", ha="center",
                fontsize=8.5, color=INK2)
    a2.set_ylabel("время в жёлтой\nзоне, % ряда"); a2.set_ylim(0, 4.2)
    a2.set_xlabel("сигнальный уровень, % от собственного капитала")
    a2.set_xticks(th)
    for a in (a1, a2):
        a.axvspan(88.5, 89.5, color=WARN, alpha=0.16, zorder=0)
    a1.text(89, 74, "скачок 11,57 пп\nза одно наблюдение\n02.03.2026",
            ha="center", fontsize=8.5, color=INK2)
    frame(fig, "Порог выше 89 % теряет две трети запаса времени",
          "ЭКСПОНАТ 4 · КАЛИБРОВКА СИГНАЛЬНОГО УРОВНЯ",
          "145 наблюдений действующего режима с 20.02.2023. Ложных срабатываний "
          "на всех показанных порогах — ноль; выбор определяется запасом времени и защитой от шума.")
    fig.subplots_adjust(top=0.80, bottom=0.16)
    save(fig, "ex4_threshold_calibration")

# ══════════════════════════════════════════════════════════════════════════
# 5. Чувствительность к капиталу
# ══════════════════════════════════════════════════════════════════════════
def ex5():
    N, E, LIM = 448999.8, 442346.3, 95.0
    shocks = [0.0, -0.05, -0.10, -0.1966, -0.25]
    lab = ["факт\n01.07.2026", "−5 %", "−10 %",
           "−19,66 %\nповторение\nшока Q1 2026", "−25 %"]
    val = [100*N/(E*(1+s)) for s in shocks]

    fig, ax = plt.subplots(figsize=(9.5, 4.8))
    cols = [WARN] + [CRIT]*4
    bars = ax.bar(range(5), val, width=0.55, color=cols)
    bars[0].set_color(S2)
    for i, v in enumerate(val):
        ax.text(i, v + 1.6, f"{v:.2f} %".replace(".", ","), ha="center",
                fontsize=10, color=INK, weight="bold")
        ax.text(i, v - 6.5, f"+{v-LIM:.2f} пп".replace(".", ","), ha="center",
                fontsize=8.5, color="white")
    ax.axhline(LIM, color=INK, lw=1.6)
    ax.text(-0.42, LIM + 2.5, "уровень риск-аппетита 95 %", ha="left",
            fontsize=9.5, color=INK, weight="bold")
    ax.set_xticks(range(5)); ax.set_xticklabels(lab, fontsize=9)
    ax.set_ylabel("доля топ-20 в собственном капитале, %")
    ax.set_ylim(0, 152)
    ax.text(0.02, 0.30,
            "Возврат в уровень при неизменном портфеле: рост капитала на 6,85 %.\n"
            "При неизменном капитале: сокращение задолженности топ-20\nна 6,41 % ≈ 28,8 млрд ₸.",
            transform=ax.transAxes, va="top", fontsize=9.5, color=INK2)
    frame(fig, "Стрессовое значение считается сегодня — без единой новой модели",
          "ЭКСПОНАТ 5 · АНАЛИЗ ЧУВСТВИТЕЛЬНОСТИ",
          "Числитель зафиксирован на 448 999,8 млн ₸, капитал на 01.07.2026 — 442 346,3 млн ₸. "
          "Стрессовый капитал рассчитывается на листе 1.2 Приложения № 2 к Методике стресс-тестирования.")
    fig.subplots_adjust(top=0.80, bottom=0.21)
    save(fig, "ex5_capital_sensitivity")

# ══════════════════════════════════════════════════════════════════════════
# 6. Красная зона за уровнем риск-аппетита
# ══════════════════════════════════════════════════════════════════════════
def ex6():
    d = [("k1", 8.5, 9.0), ("k1-2", 9.5, 10.0), ("k2", 11.0, 11.5),
         ("ACARI", 13.0, 14.0), ("HLA", 20.0, 25.0),
         ("LCR", 105.0, 110.0), ("NSFR", 105.0, 110.0), ("ALRI", 85.0, 90.0)]
    fig, ax = plt.subplots(figsize=(9.5, 4.8))
    for i, (n, lim, red) in enumerate(d):
        base = lim
        ax.plot([0, red - base], [i, i], color=BASE, lw=1, zorder=1)
        ax.add_patch(Rectangle((0, i - 0.19), red - base, 0.38,
                               facecolor=WARN, alpha=0.35, edgecolor="none", zorder=2))
        ax.plot(0, i, "o", ms=10, color=S1, zorder=3)
        ax.plot(red - base, i, "o", ms=10, color=CRIT, zorder=3)
        ax.text(red - base + 0.22, i, f"+{red-base:.1f} пп".replace(".", ","),
                va="center", fontsize=8.5, color=INK2)
        ax.text(-0.22, i, f"{n}   {lim:g} %", va="center", ha="right",
                fontsize=9.5, color=INK)
    ax.set_yticks([]); ax.grid(axis="y", visible=False)
    ax.spines["left"].set_visible(False)
    ax.set_xlim(-1.9, 6.6); ax.set_ylim(-0.7, len(d) - 0.1)
    ax.set_xlabel("расстояние от уровня риск-аппетита до порога красной зоны, пп")
    ax.legend(handles=[Line2D([], [], marker="o", ls="", ms=9, color=S1,
                              label="уровень риск-аппетита"),
                       Line2D([], [], marker="o", ls="", ms=9, color=CRIT,
                              label="порог красной зоны (Приложение № 2 к Методике)"),
                       Patch(facecolor=WARN, alpha=0.35,
                             label="аппетит соблюдён И объявлен высокий уровень риска")],
              loc="upper center", bbox_to_anchor=(0.5, 1.13), ncol=1, fontsize=9)
    frame(fig, "По всем восьми метрикам красная зона стоит за уровнем, а не внутри него",
          "ЭКСПОНАТ 6 · РАСХОЖДЕНИЕ Р1",
          "Метрики с ограничением снизу: чем выше значение, тем лучше. Порог красной зоны выше "
          "уровня риск-аппетита создаёт диапазон, в котором оба утверждения истинны одновременно.")
    fig.subplots_adjust(top=0.70, left=0.22, bottom=0.16)
    save(fig, "ex6_zone_inversion")

# ══════════════════════════════════════════════════════════════════════════
# 7. Миграция рейтингов МСБ
# ══════════════════════════════════════════════════════════════════════════
def ex7():
    r = {x["group"]: x for x in rows("ra_rating_structure.csv") if x["segment"] == "MSB"}
    cols = ["2023_01_01", "2024_01_01", "2025_01_01", "2026_01_01", "2026_07_01"]
    xl = ["01.01.2023", "01.01.2024", "01.01.2025", "01.01.2026", "01.07.2026"]
    low  = [float(r["low"][c])      for c in cols]
    mod  = [float(r["moderate"][c]) for c in cols]
    high = [float(r["high"][c])     for c in cols]

    fig, ax = plt.subplots(figsize=(9.8, 4.8))
    x = range(len(cols))
    ax.stackplot(x, low, mod, high, colors=[S3, WARN, CRIT], alpha=0.9,
                 labels=["низкий (полоса 1–13)", "умеренный (14–33)", "высокий (34–50)"],
                 edgecolor=SURFACE, linewidth=2)
    for i in x:
        ax.text(i, low[i]/2, f"{low[i]:.1f}".replace(".", ","), ha="center",
                va="center", fontsize=9, color="white", weight="bold")
        ax.text(i, low[i] + mod[i]/2, f"{mod[i]:.1f}".replace(".", ","), ha="center",
                va="center", fontsize=9, color=INK, weight="bold")
    ax.annotate("", xy=(4, 39.0), xytext=(2, 63.4),
                arrowprops=dict(arrowstyle="->", color=INK, lw=1.8))
    ax.text(3.05, 54, "низкий: 63,4 % → 39,0 %", fontsize=10, color=INK,
            weight="bold", rotation=-27, ha="center")
    ax.set_xticks(list(x)); ax.set_xticklabels(xl)
    ax.set_ylabel("доля портфеля МСБ, %"); ax.set_ylim(0, 100)
    ax.set_xlim(0, 4)
    ax.legend(loc="lower left", fontsize=9, ncol=3)
    frame(fig, "Действующая метрика этого сдвига не показывает",
          "ЭКСПОНАТ 7 · КРЕДИТОСПОСОБНОСТЬ МСБ",
          "Метрика риск-аппетита фиксирует только выдачи выше уровня отсечения 33, которых за период "
          "не было, — значение метрики всё время равно нулю. Мастер-шкала, Приложение № 4 к Политике.")
    fig.subplots_adjust(top=0.80, bottom=0.16)
    save(fig, "ex7_rating_migration")

# ══════════════════════════════════════════════════════════════════════════
# 8. Мягкость стресс-модели
# ══════════════════════════════════════════════════════════════════════════
def ex8():
    names = ["PD потребительский", "PD автокредитование", "PD ипотека"]
    base  = [12.53, 4.75, 1.70]
    crisis= [13.14, 6.16, 2.19]
    fig, ax = plt.subplots(figsize=(9.5, 4.6))
    y = range(3)
    for i, (b, c) in enumerate(zip(base, crisis)):
        ax.plot([b, c], [i, i], color=BASE, lw=2, zorder=1, solid_capstyle="round")
        ax.plot(b, i, "o", ms=11, color=S1, zorder=3)
        ax.plot(c, i, "o", ms=11, color=CRIT, zorder=3)
        ax.text(c + 0.22, i, f"+{c-b:.2f} пп".replace(".", ","), va="center",
                fontsize=9, color=INK2)
    ax.axvline(15.0, color=INK, lw=1.6)
    ax.text(14.75, 2.42, "лимит риск-аппетита\nPD необеспеченные 15 %", ha="right",
            fontsize=9.5, color=INK, weight="bold")
    ax.add_patch(Rectangle((13.14, -0.22), 15.0-13.14, 0.44, facecolor=GOOD,
                           alpha=0.18, edgecolor="none"))
    ax.text(14.07, -0.52, "запас 1,86 пп после кризисного сценария",
            ha="center", fontsize=9, color=INK2)
    ax.set_yticks(list(y)); ax.set_yticklabels(names, fontsize=10)
    ax.set_xlim(0, 17); ax.set_ylim(-0.85, 2.75)
    ax.set_xlabel("вероятность дефолта, %")
    ax.grid(axis="y", visible=False); ax.spines["left"].set_visible(False)
    ax.legend(handles=[Line2D([], [], marker="o", ls="", ms=9, color=S1, label="базовый сценарий"),
                       Line2D([], [], marker="o", ls="", ms=9, color=CRIT,
                              label="кризисный сценарий (= негативному, они совпадают)")],
              loc="upper left", fontsize=9)
    frame(fig, "Кризисный сценарий добавляет к PD меньше процентного пункта",
          "ЭКСПОНАТ 8 · ЖЁСТКОСТЬ СТРЕСС-МОДЕЛИ",
          "Приложение № 4 к Методике стресс-тестирования, строки 25 и 48. Негативный и кризисный "
          "сценарии совпадают по всем шести макровходам и всем девяти выходам. Калибровка на 2020 год.")
    fig.subplots_adjust(top=0.80, left=0.24, bottom=0.19)
    save(fig, "ex8_stress_mildness")


# ══════════════════════════════════════════════════════════════════════════
# 9. Занижение сценариев и точка исправления
# ══════════════════════════════════════════════════════════════════════════
def ex9():
    r = rows("monthly_credit_stress_2026.csv")
    dates = sorted({x["as_of"] for x in r})
    lab = [d[8:10] + "." + d[5:7] for d in dates]
    def series(sc, key):
        return [float(next(x for x in r if x["as_of"] == d and x["scenario"] == sc)[key])
                for d in dates]
    fixed_from = [i for i, d in enumerate(dates)
                  if next(x for x in r if x["as_of"] == d)["formula_base"] == "fact"][0]

    fig, ax = plt.subplots(figsize=(10, 4.8))
    ax.axvspan(-0.4, fixed_from - 0.5, color=CRIT, alpha=0.07, zorder=0)
    ax.axvline(fixed_from - 0.5, color=INK2, lw=1.2, ls=(0, (4, 3)), zorder=1)
    ax.text(fixed_from - 0.42, 258, "формула исправлена", fontsize=9.5,
            color=INK, weight="bold", va="top")
    ax.text(-0.3, 258, "инкрементальная база", fontsize=9.5, color=CRIT, va="top")
    for sc, col, nm in (("3", CRIT, "кризисный"), ("2", S2, "стрессовый")):
        rep = series(sc, "R_reported"); ok = series(sc, "R_vs_fact")
        ax.plot(range(len(dates)), [v/1000 for v in ok], "-o", color=col, lw=2, ms=7,
                label=f"{nm} — от факта")
        ax.plot(range(len(dates)), [v/1000 for v in rep], "--o", color=col, lw=1.6, ms=6,
                mfc=SURFACE, alpha=0.85, label=f"{nm} — как в отчёте")
        for i in range(fixed_from):
            ax.annotate("", xy=(i, rep[i]/1000), xytext=(i, ok[i]/1000),
                        arrowprops=dict(arrowstyle="-", color=col, lw=0.9, alpha=0.5))
    ax.text(2, 160, "занижение\n×1,84 — ×2,15", ha="center", fontsize=9.5,
            color=INK, weight="bold")
    ax.set_xticks(range(len(dates))); ax.set_xticklabels(lab)
    ax.set_ylabel("дополнительные провизии в сценарии, млрд ₸")
    ax.set_ylim(0, 272); ax.set_xlim(-0.4, len(dates) - 0.6)
    ax.legend(loc="lower right", fontsize=9, ncol=2)
    frame(fig, "Пять отчётов вышли с заниженными вдвое потерями, шестой — уже нет",
          "ЭКСПОНАТ 9 · МЕСЯЧНЫЙ СТРЕСС-ТЕСТ 2026",
          "Сплошная линия — пересчёт от факта, пунктир — значение отчёта. Базовый сценарий "
          "считался от факта всегда и потому не показан: у него расхождения нет.")
    fig.subplots_adjust(top=0.80, bottom=0.14)
    save(fig, "ex9_understatement")

# ══════════════════════════════════════════════════════════════════════════
# 10. Из чего складывается результат
# ══════════════════════════════════════════════════════════════════════════
def ex10():
    names = ["Автомобильное обеспечение", "Недвижимость", "Девальвация", "Нефть"]
    val   = [182268, 37298, 11834, 303]
    tot   = sum(val)
    share = [v / tot * 100 for v in val]
    cols  = [S2, S1, S3, MUTED]
    fig, ax = plt.subplots(figsize=(10, 4.4))
    left = 0
    for v, sh, c in zip(val, share, cols):
        ax.barh(0.45, sh, left=left, height=0.34, color=c,
                edgecolor=SURFACE, linewidth=2)
        if sh > 8:
            ax.text(left + sh/2, 0.45, f"{sh:.1f} %".replace(".", ","), ha="center",
                    va="center", fontsize=12, color="white", weight="bold")
        left += sh
    ax.annotate("нефть — 0,13 %,\nполоска шириной в волос", xy=(99.95, 0.62),
                xytext=(86, 0.74), fontsize=9.5, color=INK2, ha="center", va="bottom",
                arrowprops=dict(arrowstyle="->", color=MUTED, lw=1))
    for k, (n, v, sh, c) in enumerate(zip(names, val, share, cols)):
        y = -0.30 - k * 0.17
        ax.add_patch(Rectangle((1.5, y - 0.045), 2.2, 0.09, facecolor=c, edgecolor="none"))
        ax.text(5.5, y, n, va="center", fontsize=10, color=INK)
        ax.text(52, y, f"{v:,.0f}".replace(",", " ") + " млн ₸", va="center",
                ha="right", fontsize=10, color=INK2)
        ax.text(64, y, f"{sh:.2f} %".replace(".", ","), va="center", ha="right",
                fontsize=10, color=INK, weight="bold")
    ax.text(52, -0.30 + 0.17, "вклад", ha="right", fontsize=9, color=MUTED)
    ax.text(64, -0.30 + 0.17, "доля", ha="right", fontsize=9, color=MUTED)
    ax.set_xlim(0, 100); ax.set_ylim(-1.26, 1.00)
    ax.set_yticks([]); ax.set_xticks([]); ax.grid(False)
    for sp in ax.spines.values(): sp.set_visible(False)
    ax.text(100, -1.10, "П. 37 взвешивает каждый фактор долей портфеля, ему подверженной: нефть\n"
                        "входит через 0,11 %. Это следствие Методики, а не дефект расчёта. При этом\n"
                        "члена по авто в формуле нет вовсе: три фактора против четырёх в сценарии.",
            ha="right", va="center", fontsize=10.5, color=INK, weight="bold")
    frame(fig, "Результат делает фактор, которого нет в формуле Методики",
          "ЭКСПОНАТ 10 · ВКЛАД ФАКТОРОВ, КРИЗИСНЫЙ СЦЕНАРИЙ",
          "Месячная форма на 01.07.2026, после исправления формулы. Сумма вкладов равна "
          "прогнозному изменению стоимости портфеля 231 703 млн ₸.")
    fig.subplots_adjust(top=0.78, bottom=0.08)
    save(fig, "ex10_factor_contribution")

if __name__ == "__main__":
    for f in (ex1, ex2, ex3, ex4, ex5, ex6, ex7, ex8, ex9, ex10):
        f()
