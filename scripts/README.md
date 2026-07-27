# `scripts/` — local analyst tooling (DB- or filesystem-connected)

Unlike `topic_classifier/` (an installable package) and `sql/` (pure T-SQL),
this folder holds **local Python scripts that connect to real data** — either
the database (`stage3_dpd_chart.py`) or a local file archive
(`writeoff_restoration_scan.py`). They are not run in CI, and their output can
contain confidential figures, so it always goes to `data/` (git-ignored).

## `writeoff_restoration_scan.py` — write-off/restoration Excel archive scanner

ПРОСТЫМ ЯЗЫКОМ: обходит `R:\!!!ukr1\списание-восстановление\{2025,2026}\...`,
читает каждый `.xlsx` (шапка — 7-я строка листа), берёт только 2-ю колонку
(«Контракт») и дату операции — и складывает всё в один CSV.

**Как определяется дата.** Месяц берётся из ПАПКИ (`\2025\12.2025\...`), имя
листа/файла может только уточнить ДЕНЬ внутри этого месяца. Причина не
косметическая: в архиве есть файлы, скопированные с прошлого месяца без
переименования листа — `SERVICING_tag11_20251229.xlsx` с листом
`SERVICING_tag11_20251030`. Приоритет «сначала лист» проставил бы декабрьскому
списанию октябрьскую дату; папка так не ошибается, а расхождение печатается
строкой `[INFO] ... trusting the folder (stale copied name?)`.

Распознаются `29.04.2026`, компактный `20251229` (семейство `SERVICING_tag11_*`)
и словами («30 декабря»). Если день установить не удалось, а папка известна —
ставится 1-е число с пометкой `date_precision='month'`; для censoring этого
достаточно, сверка идёт с помесячными срезами.
Это сырьё для censoring-логики в
[`docs/analysis/stage3_safezone_plan.md`](../docs/analysis/stage3_safezone_plan.md):
займы, которые продали/списали/простили, не должны засчитываться как
«безопасно вылечились» только потому что пропали из портфеля — SQL-версия of
this exists only for December 2025
(`sql/stage3_pool_dropoff_investigation.sql` §7/§8,
`Prodaja&Proschenie_12_2025`); the other months (082025, 102025, 04-06/2026,
confirmed so far) only exist as this Excel archive.

### Два режима

**`--prilozhenie` — список прощений и списаний.** Читает только
«Приложение №1 (Credilogic)» за все месяцы 2025–2026. Разметка подтверждённая
(27.07.2026) и потому зашита, а не подбирается: **шапка — 1-я строка Excel,
данные со 2-й, номер контракта — 1-я колонка.** Регулярка ловит все написания
номера (`№1`, `No1`, `N1`, `#1`, просто `1`) и суффиксы вроде
`_дополнительный список`, но не цепляет «Приложение №2».

**Без флага — весь архив.** Здесь разметка у файлов разная, поэтому шапка
**ищется**: скрипт сканирует верх листа на ячейку «контракт»/«договор»/«займ» и
берёт колонку под ней, с откатом на `--header-row`/`--contract-col`.

В обоих режимах, если найденная шапка расходится с заданной, печатается
`[INFO] header search points at rN/col M` — заданная всё равно применяется
(она указана, а не угадана), но расхождение видно. Такой файл стоит посмотреть
через `--inspect`.

### Usage

```bash
pip install pandas openpyxl

# 1) сначала посмотреть на структуру, ничего не извлекая
python scripts/writeoff_restoration_scan.py --prilozhenie --inspect

# 2) собрать список прощений/списаний
python scripts/writeoff_restoration_scan.py --prilozhenie

# весь архив целиком, с поиском шапки
python scripts/writeoff_restoration_scan.py
# defaults: base-dir R:\!!!ukr1\списание-восстановление, years 2025 2026,
# out C:\project_mz\surau\DPDRelaxing\raw_data\censoring_events.csv

# ручное задание разметки
python scripts/writeoff_restoration_scan.py --header-row 5 --contract-col 0 --no-auto-detect
```

**`--inspect` стоит запускать первым** на любом незнакомом наборе файлов: он
печатает верхний левый угол каждого листа и то, что скрипт в нём распознал, —
это дешевле, чем потом разбираться, почему в CSV попали не те значения.

From a Jupyter cell, call `run_scan()` directly instead of the CLI (`%run`
leaks ipykernel's own launch args like `--f=...kernel-....json` into
`sys.argv`, which `main()` now tolerates via `parse_known_args`, but calling
the function directly skips argument parsing entirely):

```python
import sys
sys.path.append(r"..\scripts")   # adjust to wherever scripts/ is from the notebook
from writeoff_restoration_scan import run_prilozhenie_scan

run_prilozhenie_scan(inspect=True)      # посмотреть структуру
df = run_prilozhenie_scan()             # собрать список прощений/списаний
```

`run_prilozhenie_scan()` — это `run_scan()` с уже подставленным фильтром имён и
подтверждённой разметкой; любой аргумент можно перекрыть
(`run_prilozhenie_scan(years=["2026"], out="only_2026.csv")`).

Prints per-file/per-sheet diagnostics as it goes (files found per year, rows
extracted per file, warnings for files/sheets it couldn't date or read) — a
`[WARN]`/`[ERROR]` line means that file was skipped, not silently miscounted.
Verified end to end against a synthetic `.xlsx` fixture covering both date
sources (filename-only, and multi-sheet-with-dated-sheet-names) before being
shared — real files may still differ; adjust `--header-row`/`--contract-col`
per the printed warnings if a specific month doesn't match.

### Output columns
`contract_number, event_date, date_precision, date_source, source_file,
source_sheet` — the loan id + when it happened, plus how confidently that date
was established (`day`/`month`, and whether it came from the sheet name, the
file name or the folder), traceable back to the source for spot-checking.

Two summaries print at the end and both are worth reading before using the CSV:
**rows by month** (does every month of the analysis panel have events, or is one
silently missing?) and **how the dates were resolved** (a large `folder/month`
share means most events are only month-accurate). Any file that yielded zero
rows is listed explicitly — a file present but empty is a coverage gap, not a
non-event.

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
