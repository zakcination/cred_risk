"""Stage 3 post-default DPD projection — one line per loan, 7-month view.

ПРОСТЫМ ЯЗЫКОМ:
Строим график: по оси X — месяцы (2026-01 … последняя доступная дата), по оси
Y — просрочка (dpd). Каждый займ 3-й стадии — своя линия. Линии красятся по
статусу (не по займу — займов может быть сотни, у каждого своя линия не имеет
смысла): зелёный — уже чистый весь период; жёлтый — ровно случай Дамира (сейчас
без просрочки, но был один срыв ≤ порога смягчения — кандидат на оздоровление
при мягком правиле); оранжевый — срыв был больше допуска (пограничный случай);
красный — сейчас в просрочке / не выходит из дефолта. Пунктирные горизонтальные
линии отмечают пороги смягчения n = 1, 3, 7, 10 дней.

Requirements (real DB mode): pandas, matplotlib, pyodbc, python-dotenv
    pip install pandas matplotlib pyodbc python-dotenv
и файл .env в корне репозитория (см. scripts/db.py).

Usage
-----
    # smoke-test with synthetic data, no DB needed:
    python scripts/stage3_dpd_chart.py --demo

    # against the real database (builds the pool via sql/stage3_cure_pool.sql,
    # then plots + classifies it):
    python scripts/stage3_dpd_chart.py --as-of 2026-07-01 --month-from 2026-01-01

Output
------
    data/stage3_dpd_projection.png   — the chart
    data/stage3_dpd_classification.csv — per-loan classification (balance, status, …)
`data/` is git-ignored (see .gitignore) — safe default for confidential output.
"""

from __future__ import annotations

import argparse
import random
import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")  # headless-safe; pass --show to also open a window
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D

import pandas as pd

REPO_ROOT = Path(__file__).resolve().parent.parent
SQL_POOL_SCRIPT = REPO_ROOT / "sql" / "stage3_cure_pool.sql"

# Status palette (dataviz skill — fixed status colors, never themed as series):
STATUS_COLOR = {
    "good": "#0ca30c",       # clean the whole window
    "warning": "#fab219",    # Damir's case: currently OK, one slip within tolerance
    "serious": "#ec835a",    # currently OK, but the worst slip exceeded tolerance
    "critical": "#d03b3b",   # currently overdue now (or no data to judge)
    "no_data": "#9a9a90",
}
STATUS_LABEL = {
    "good": "Чистый весь период",
    "warning": "Обычно 0, редкий мелкий срыв (кандидат)",
    "serious": "Срыв слишком большой или частый",
    "critical": "Сейчас в просрочке / не оздоровился",
    "no_data": "Недостаточно данных",
}
# draw order: least- to most-important, so the "story" (warning) sits on top
DRAW_ORDER = ["no_data", "critical", "serious", "good", "warning"]


def classify(max_dpd: float, n_overdue: float, current_dpd: float,
             cure_entry_dpd: int, relax_tol: int, max_overdue_months: int) -> str:
    """'warning' = typically 0 with only OCCASIONAL small slips (salary delay,
    forgot to pay), not just "the worst slip was small". Two independent tests:
    magnitude (max_dpd <= relax_tol) AND frequency (n_overdue <= max_overdue_months).
    A loan that slips a little EVERY month fails the frequency test even if each
    slip is tiny — that's a chronic pattern, not "occasional", and belongs in
    'serious' for closer review rather than being waved through as a cure candidate.
    """
    if pd.isna(max_dpd):
        return "no_data"
    if max_dpd <= 0:
        return "good"
    if pd.notna(current_dpd) and current_dpd <= cure_entry_dpd:
        if max_dpd <= relax_tol and n_overdue <= max_overdue_months:
            return "warning"
        return "serious"
    return "critical"


def load_demo_data(n_loans: int, seed: int) -> pd.DataFrame:
    """Synthetic pool matching the shapes we care about, for a DB-free smoke test.

    Each archetype is a post-default DPD path indexed by k = months-since-default
    (k=0 is the default event itself, always a spike — that's what "defaulting"
    means). `default_month_idx` places that path against the 7-month calendar
    window (month_idx 0..6): many real loans defaulted well before the window
    starts, so their in-window view never shows the k=0 spike at all — only the
    already-recovered (or still-bad) tail. That heterogeneity is what makes the
    classifier meaningful; a fixed "everyone spikes at month 0" demo would defeat
    the point (see the k>=1-only rule in build_classification).
    """
    rng = random.Random(seed)
    archetypes = {
        # k:            0    1    2    3    4    5    6    7    8    9   10   11   12
        "good":     [90, 30,  5,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0],
        "warning":  [90, 30,  0,  0,  0,  3,  0,  0,  0,  0,  0,  0,  0],  # Damir's slip at k=5
        "serious":  [90, 45,  0,  0, 20,  0,  0,  0,  0,  0,  0,  0,  0],  # bigger slip at k=4
        "critical": [90, 60, 70, 40, 55, 30, 65, 50, 60, 45, 55, 60, 50],  # never settles
    }
    weights = {"good": 0.25, "warning": 0.30, "serious": 0.15, "critical": 0.20}
    rows = []
    for i in range(n_loans):
        cid = f"DEMO{i:04d}"
        balance = rng.uniform(200_000, 15_000_000)
        provisions = balance * rng.uniform(0.2, 0.6)
        sparse = rng.random() < 0.10  # ~10% of loans have gaps in reporting
        kind = rng.choices(list(weights), weights=list(weights.values()))[0]
        path = archetypes[kind]
        default_month_idx = rng.randint(-8, 3)  # most defaults predate the window
        for month_idx in range(7):
            k = month_idx - default_month_idx
            if k < 0:
                dpd = None  # not yet in default at this calendar month
            else:
                dpd = path[k] if k < len(path) else path[-1]
                if dpd is not None and dpd > 0:
                    dpd = max(0, dpd + rng.randint(-4, 4))  # jitter so archetypes don't look stamped
                if sparse and rng.random() < 0.15:
                    dpd = None  # missing snapshot
            rows.append(
                dict(
                    contract_number=cid,
                    balance=balance,
                    provisions_total=provisions,
                    month_idx=month_idx,
                    month_since_default=k,
                    snap_date=f"2026-{month_idx+1:02d}-01",
                    dpd=dpd,
                )
            )
    return pd.DataFrame(rows)


def load_db_data(as_of: str, month_from: str) -> pd.DataFrame:
    """Build the pool via sql/stage3_cure_pool.sql, then pull it as a DataFrame."""
    from scripts.db import connect  # lazy: only needed for real DB mode

    if not SQL_POOL_SCRIPT.exists():
        raise FileNotFoundError(f"Pool builder script not found: {SQL_POOL_SCRIPT}")

    pool_sql = SQL_POOL_SCRIPT.read_text(encoding="utf-8")
    # Override the script's own defaults with the CLI values (same param names).
    pool_sql = pool_sql.replace(
        "DECLARE @AsOf      date = '2026-07-01';",
        f"DECLARE @AsOf      date = '{as_of}';",
    ).replace(
        "DECLARE @MonthFrom date = '2026-01-01';",
        f"DECLARE @MonthFrom date = '{month_from}';",
    )

    conn = connect()
    try:
        cur = conn.cursor()
        cur.execute(pool_sql)  # builds ##STAGE3_CURE_POOL_HEAD / _DPD, ends with a summary SELECT
        # advance to the result set that has rows (the §3 summary SELECT)
        summary = None
        while True:
            try:
                summary = cur.fetchall()
                if summary:
                    break
            except Exception:
                pass
            if not cur.nextset():
                break
        if summary:
            cols = [c[0] for c in cur.description]
            print("Pool volume:", dict(zip(cols, summary[0])))

        query = """
            SELECT d.contract_number, h.balance, h.provisions_total,
                   h.default_date, h.cure_date, d.month_idx, d.month_since_default,
                   d.snap_date, d.[dpd]
            FROM ##STAGE3_CURE_POOL_DPD d
            JOIN ##STAGE3_CURE_POOL_HEAD h ON h.contract_number = d.contract_number
            ORDER BY d.contract_number, d.month_idx;
        """
        return pd.read_sql(query, conn)
    finally:
        conn.close()


def build_classification(df: pd.DataFrame, cure_entry_dpd: int, relax_tol: int,
                          max_overdue_months: int) -> pd.DataFrame:
    """One row per contract with a status label.

    max_dpd / n_overdue are computed ONLY over post-default months
    (month_since_default >= 1) — the default event itself (k=0) is always a DPD
    spike by definition, so including it would make every loan that defaulted
    inside the plotted window look "critical" regardless of how well it behaved
    afterwards. This mirrors the def+k convention used throughout
    sql/stage3_dpd_trajectory.sql.
    """
    post_default = df[df["month_since_default"] >= 1]
    stats = post_default.groupby("contract_number")["dpd"].agg(
        max_dpd="max",
        n_overdue=lambda s: (s > 0).sum(),
    )

    per_loan = df.groupby("contract_number").agg(
        balance=("balance", "first"),
        provisions_total=("provisions_total", "first"),
    )
    per_loan = per_loan.join(stats)  # NaN max_dpd if no post-default row observed yet -> "no_data"

    # current dpd = last observed (non-null) reading by month_idx, any k
    last_obs = (
        df.dropna(subset=["dpd"])
        .sort_values("month_idx")
        .groupby("contract_number")
        .tail(1)
        .set_index("contract_number")["dpd"]
        .rename("current_dpd")
    )
    per_loan = per_loan.join(last_obs)
    per_loan["status"] = per_loan.apply(
        lambda r: classify(r["max_dpd"], r["n_overdue"], r["current_dpd"],
                            cure_entry_dpd, relax_tol, max_overdue_months),
        axis=1,
    )
    return per_loan.reset_index()


def sample_for_plot(per_loan: pd.DataFrame, cap: int, seed: int) -> set[str]:
    """Keep every 'warning' loan (the story) + a capped random sample of the rest."""
    warning_ids = set(per_loan.loc[per_loan["status"] == "warning", "contract_number"])
    rest = per_loan.loc[per_loan["status"] != "warning", "contract_number"].tolist()
    remaining_budget = max(cap - len(warning_ids), 0)
    rng = random.Random(seed)
    rest_sample = set(rng.sample(rest, min(remaining_budget, len(rest))))
    return warning_ids | rest_sample


def plot(df: pd.DataFrame, per_loan: pd.DataFrame, plotted_ids: set[str], out_path: Path,
         relax_thresholds: list[int], title_suffix: str = "", ylim_cap: float | None = None) -> None:
    status_by_id = per_loan.set_index("contract_number")["status"].to_dict()
    month_labels = (
        df[["month_idx", "snap_date"]].drop_duplicates().sort_values("month_idx")
    )
    month_labels["ym"] = month_labels["snap_date"].astype(str).str.slice(0, 7)

    fig, ax = plt.subplots(figsize=(11, 6.5))
    ax.set_facecolor("#fcfcfb")
    fig.patch.set_facecolor("#fcfcfb")

    for status in DRAW_ORDER:
        ids = [i for i in plotted_ids if status_by_id.get(i) == status]
        color = STATUS_COLOR[status]
        alpha = 0.55 if status == "warning" else 0.22
        lw = 1.4 if status == "warning" else 1.0
        for cid in ids:
            sub = df[(df["contract_number"] == cid)].sort_values("month_idx")
            ax.plot(sub["month_idx"], sub["dpd"], color=color, alpha=alpha, linewidth=lw)

    for n in relax_thresholds:
        ax.axhline(n, color="#9a9a90", linestyle="--", linewidth=0.8, alpha=0.6, zorder=0)
        ax.annotate(f"n={n}", xy=(month_labels["month_idx"].max(), n),
                    xytext=(4, 0), textcoords="offset points",
                    fontsize=8, color="#52514e", va="center")

    ax.set_xticks(month_labels["month_idx"])
    ax.set_xticklabels(month_labels["ym"], color="#0b0b0b")
    ax.set_xlabel("Месяц (отчётная дата)", color="#52514e")
    ax.set_ylabel("Просрочка, дней (DPD)", color="#52514e")
    ax.tick_params(colors="#52514e")
    for spine in ("top", "right"):
        ax.spines[spine].set_visible(False)
    for spine in ("left", "bottom"):
        ax.spines[spine].set_color("#c9c8bd")

    counts = per_loan["status"].value_counts()
    subtitle = " · ".join(f"{STATUS_LABEL[s]}: {counts.get(s,0)}" for s in DRAW_ORDER if counts.get(s, 0))
    ax.set_title(
        f"Стадия 3 — траектория просрочки по месяцам{title_suffix}\n"
        f"показано {len(plotted_ids)} из {len(per_loan)} займов",
        color="#0b0b0b", fontsize=13, loc="left", pad=28,
    )
    ax.text(0, 1.02, subtitle, transform=ax.transAxes, fontsize=9, color="#52514e")

    legend_handles = [
        Line2D([0], [0], color=STATUS_COLOR[s], lw=2.5, label=f"{STATUS_LABEL[s]} ({counts.get(s,0)})")
        for s in DRAW_ORDER
    ]
    ax.legend(handles=legend_handles, loc="upper left", bbox_to_anchor=(1.02, 1.0),
              frameon=False, fontsize=9)

    # Cap the y-axis so the near-zero "story" population (good/warning — the
    # whole point of this chart) isn't squeezed into a sliver by a few loans
    # sitting at 60-90+ DPD. Matplotlib simply stops drawing above the ylim —
    # no data is altered — but we DISCLOSE what's cropped instead of hiding it
    # silently (dataviz "no silent caps" rule).
    if ylim_cap and ylim_cap > 0:
        plotted_df = df[df["contract_number"].isin(plotted_ids)]
        cropped_points = plotted_df[plotted_df["dpd"] > ylim_cap]
        cropped_loans = cropped_points["contract_number"].nunique()
        ax.set_ylim(0, ylim_cap)
        if cropped_loans:
            ax.text(
                1.0, -0.12,
                f"↑ обрезано сверху: {cropped_loans} займов с dpd > {ylim_cap:g} "
                f"(макс. {plotted_df['dpd'].max():.0f}); полные данные — в CSV",
                transform=ax.transAxes, ha="right", fontsize=8, color="#52514e",
            )

    fig.tight_layout()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out_path, dpi=150, bbox_inches="tight")
    print(f"Saved chart -> {out_path}")


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--demo", action="store_true", help="use synthetic data, no DB needed")
    p.add_argument("--demo-loans", type=int, default=250)
    p.add_argument("--as-of", default="2026-07-01")
    p.add_argument("--month-from", default="2026-01-01")
    p.add_argument("--cure-entry-dpd", type=int, default=5, help="current DPD must be <= this to be 'currently OK'")
    p.add_argument("--relax-tolerance", type=int, default=5, help="max DPD slip still treated as 'minor' (e.g. a couple days)")
    p.add_argument("--max-overdue-months", type=int, default=2,
                   help="a slip only counts as 'occasional' if it happens in at most this many "
                        "observed post-default months; more often = chronic, not minor")
    p.add_argument("--relax-thresholds", default="1,3,7,10", help="reference lines n on the chart")
    p.add_argument("--max-lines", type=int, default=400, help="cap on plotted loans (all 'warning' kept + sample of rest)")
    p.add_argument("--ylim-cap", type=float, default=30,
                   help="crop the y-axis at this DPD so the near-zero population is readable "
                        "(0 disables cropping); classification/CSV always use full values")
    p.add_argument("--seed", type=int, default=42)
    p.add_argument("--out", default=str(REPO_ROOT / "data" / "stage3_dpd_projection.png"))
    p.add_argument("--csv-out", default=str(REPO_ROOT / "data" / "stage3_dpd_classification.csv"))
    p.add_argument("--show", action="store_true", help="also open an interactive window")
    args = p.parse_args()

    if args.demo:
        df = load_demo_data(args.demo_loans, args.seed)
        title_suffix = "  [DEMO — синтетические данные]"
    else:
        df = load_db_data(args.as_of, args.month_from)
        title_suffix = f"  ({args.month_from} … {args.as_of})"

    per_loan = build_classification(df, args.cure_entry_dpd, args.relax_tolerance, args.max_overdue_months)
    plotted_ids = sample_for_plot(per_loan, args.max_lines, args.seed)

    print("\nПо статусам (после отбора для графика — pool в целом):")
    summary = per_loan.groupby("status").agg(
        loans=("contract_number", "count"),
        balance=("balance", "sum"),
        provisions=("provisions_total", "sum"),
    ).reindex(DRAW_ORDER).dropna(how="all")
    print(summary.to_string(float_format=lambda v: f"{v:,.0f}"))

    csv_path = Path(args.csv_out)
    csv_path.parent.mkdir(parents=True, exist_ok=True)
    per_loan.to_csv(csv_path, index=False)
    print(f"\nSaved per-loan classification -> {csv_path}")

    thresholds = [int(x) for x in args.relax_thresholds.split(",") if x.strip()]
    plot(df, per_loan, plotted_ids, Path(args.out), thresholds, title_suffix, args.ylim_cap)

    if args.show:
        plt.show()
    return 0


if __name__ == "__main__":
    sys.exit(main())
