# `scripts/` — local analyst tooling (DB- or filesystem-connected)

Unlike `topic_classifier/` (an installable package) and `sql/` (pure T-SQL),
this folder holds **local Python scripts that connect to real data** — either
the database (`stage3_dpd_chart.py`) or a local file archive
(`writeoff_restoration_scan.py`). They are not run in CI, and their output can
contain confidential figures, so it always goes to `data/` (git-ignored).

## `writeoff_restoration_scan.py` — write-off/restoration Excel archive scanner

ПРОСТЫМ ЯЗЫКОМ: обходит `R:\!!!ukr1\списание-восстановление\{2025,2026}\...`,
читает каждый `.xlsx` (шапка — 7-я строка листа), берёт только 2-ю колонку
(«Контракт») и дату — сначала из НАЗВАНИЯ ЛИСТА, если там нет — из ИМЕНИ ФАЙЛА
(«...на 29.04.2026 года...» → `2026-04-29`) — и складывает всё в один CSV.
Это сырьё для censoring-логики в
[`docs/analysis/stage3_safezone_plan.md`](../docs/analysis/stage3_safezone_plan.md):
займы, которые продали/списали/простили, не должны засчитываться как
«безопасно вылечились» только потому что пропали из портфеля — SQL-версия of
this exists only for December 2025
(`sql/stage3_pool_dropoff_investigation.sql` §7/§8,
`Prodaja&Proschenie_12_2025`); the other months (082025, 102025, 04-06/2026,
confirmed so far) only exist as this Excel archive.

### Usage

```bash
pip install pandas openpyxl

python scripts/writeoff_restoration_scan.py
# defaults: base-dir R:\!!!ukr1\списание-восстановление, years 2025 2026,
# header row 7 (Excel, 1-indexed), contract column 2 (Excel, 1-indexed),
# out C:\project_mz\surau\DPDRelaxing\raw_data\censoring_events.csv

# override any of those if a particular month's file differs:
python scripts/writeoff_restoration_scan.py --header-row 5 --contract-col 2 --out my_events.csv
```

Prints per-file/per-sheet diagnostics as it goes (files found per year, rows
extracted per file, warnings for files/sheets it couldn't date or read) — a
`[WARN]`/`[ERROR]` line means that file was skipped, not silently miscounted.
Verified end to end against a synthetic `.xlsx` fixture covering both date
sources (filename-only, and multi-sheet-with-dated-sheet-names) before being
shared — real files may still differ; adjust `--header-row`/`--contract-col`
per the printed warnings if a specific month doesn't match.

### Output columns
`contract_number, event_date, source_file, source_sheet` — deliberately
minimal (just the loan id + the date it happened, per what's needed for
censoring), traceable back to the source file/sheet for spot-checking.

## `stage3_dpd_chart.py` — Stage 3 post-default DPD projection

ПРОСТЫМ ЯЗЫКОМ: строит график просрочки (DPD) по месяцам — одна линия на займ
3-й стадии, цвет линии — по статусу (не по займу, займов может быть сотни).
Раскрашивает и считает, сколько займов **обычно чистые, но иногда — на пару
дней — уходят в просрочку** (задержка зарплаты, забыли оплатить и т.п.) — это
и есть популяция-кандидат на смягчение правил оздоровления (Дамир, 17.07.2026).

### Status legend
| Status | Meaning |
|---|---|
| `good` | clean (dpd = 0) every post-default month observed |
| `warning` | **the target segment**: currently OK, and any slip was both **small** (`≤ --relax-tolerance`, default 5 days) **and occasional** (`≤ --max-overdue-months`, default 2 months) — "usually 0, sometimes a couple days late" |
| `serious` | currently OK, but the slip was too big OR too frequent to call "occasional" (a chronic small-slip pattern is not the same as one bad month) |
| `critical` | currently overdue now (above `--cure-entry-dpd`) |
| `no_data` | no post-default snapshot observed in the window |

Classification is computed **only over post-default months**
(`month_since_default ≥ 1`) — the default event itself is always a DPD spike by
definition, so including it would mislabel every recently-defaulted-but-since-clean
loan as "critical". This mirrors the `def+k` convention in
`sql/stage3_dpd_trajectory.sql`.

### Usage

```bash
pip install pandas matplotlib pyodbc python-dotenv

# smoke-test with synthetic data — no DB, no .env needed:
python scripts/stage3_dpd_chart.py --demo

# against the real database — builds the pool via sql/stage3_cure_pool.sql,
# then classifies and plots it (needs a .env at the repo root, see scripts/db.py):
python scripts/stage3_dpd_chart.py --as-of 2026-07-01 --month-from 2026-01-01

# tune what counts as "occasional minor slip":
python scripts/stage3_dpd_chart.py --relax-tolerance 3 --max-overdue-months 1
```

`.env` (repo root, git-ignored):
```
SQL_SERVER=your-server\instance,1433
SQL_DATABASE=CL_PORTFOLIO
SQL_USER=...          # omit for Windows/trusted auth
SQL_PASSWORD=...
```

### Output (always under `data/`, git-ignored)
- `stage3_dpd_projection.png` — the chart. The y-axis is cropped at `--ylim-cap`
  (default 30 DPD) so the near-zero target population is actually readable
  instead of being squeezed flat by a few loans at 60–90+ DPD — cropping is
  **disclosed on the chart**, never silent; the underlying data is untouched.
- `stage3_dpd_classification.csv` — one row per loan: balance, provisions,
  `max_dpd`, `n_overdue`, `current_dpd`, `status` — for further slicing.

### Key options
| Flag | Default | Meaning |
|---|---|---|
| `--cure-entry-dpd` | 5 | current DPD must be ≤ this to count as "currently OK" |
| `--relax-tolerance` | 5 | max DPD a slip can reach and still be "minor" |
| `--max-overdue-months` | 2 | a slip counts as "occasional" only if it happens in at most this many observed months |
| `--relax-thresholds` | `1,3,7,10` | reference dashed lines drawn on the chart |
| `--max-lines` | 400 | plotted-loan cap — every `warning` loan is always kept, the rest are sampled |
| `--ylim-cap` | 30 | y-axis crop (0 disables) |

Both the chart and the CSV are for **exploration**; the authoritative
count/balance/provisions numbers for the regulator conversation come from the
dedicated SQL (`sql/stage3_cure_pool.sql` §B/§C, `sql/stage3_cure_funnel.sql`).
