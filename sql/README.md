# `sql/` — AQR data-check scripts

SQL checks for the AQR / B3B workstream. **Microsoft SQL Server (T-SQL).** These
scripts read schema (table/column names) only — no confidential data values are
stored here.

- **`b3b_reconciliation_2025.sql`** — closed-before-audited-year check across all
  six source-system portfolio tables (below).
- **`b3b_comment_mapping.sql`** — normalize the free-text column-E comments in
  `EUB_B3B_v0` to the NBRK «Причина» dropdown vocabulary and flag what still needs
  manual review; see the mapping table in [`docs/b3b_guide.md`](../docs/b3b_guide.md) §8.
- **`b3b_repayment_comment_template.sql`** — applies ONE universal
  «Комментарии/пояснения Банка» comment («Документы и запрошенные выписки
  вложены в папке «выписки»») to this cycle's B3B population, skipping
  cancelled agreements and loans actually written off
  (`b3b_writeoff_qc_check.sql`) — those get their own comment instead; see
  [`docs/b3b_guide.md`](../docs/b3b_guide.md) §6.1.
- **`b3b_writeoff_qc_check.sql`** — QC gate: cross-checks B3B loans submitted
  with reason `полное погашение` against the write-off-to-loss ledger
  (`spis_v_ubytok_RS`, RS source); any match is a contradiction to fix before
  submission. Generalizes a manual comment-reading catch (4 loans) that this
  cross-check expanded to 20 — see
  [`docs/b3b_guide.md`](../docs/b3b_guide.md) §7.3.
- **`stage3_cure_candidates.sql`** — size the Stage 3 loans that would cure under a
  relaxed rule (stuck only by minor DPD slips) to confirm/refute Retail Business's
  ~12 bn ₸ estimate; methodology in
  [`docs/analysis/stage3_cure_analysis.md`](../docs/analysis/stage3_cure_analysis.md).
- **`stage3_cure_funnel.sql`** — grounded snapshot version (CL_PORTFOLIO_2,
  `category='3'`, exclude `tag='11'`, default_date ≥ 31.12.2025): population funnel
  through each criterion + relaxed-DPD cure counts (loans/balance/provisions/rate)
  for n ∈ {1,3,7,10}.
- **`stage3_dpd_trajectory.sql`** — per Stage-3 contract, DPD at each of the 12
  months after its default date (`def+1 … def+12`) pivoted from the CL_PORTFOLIO_2
  snapshots — the post-default cure/re-default path used to test sustained-cure rules.
- **`stage3_cure_pool.sql`** — materializes the analysis **pool**: a head table
  (non-null Stage-3 contracts at 01.07.2026 + default/restructuring/cure dates)
  and a long-form monthly-DPD table (calendar window @MonthFrom → @AsOf), plus
  deeper-analysis starters (per-contract DPD stats; relaxed-cure count at
  n ∈ {0,1,3,7,10}). Writes to `##` global temp tables — **run this first**, in
  the same session as the two scripts below.
- **`stage3_raw_extract.sql`** — **purest raw pulls for notebook (ipynb) work**:
  no derived columns, no COALESCE, no dedup-to-latest, no aggregation — plain
  `SELECT *` scoped to the Stage 3 pool's contracts (`category='3'`, exclude
  `tag=11`) from each confirmed source table (`CL_PORTFOLIO_2`,
  `HISTORY_DEFAULT_ACCOUNT`, `IFRS9.KAN_20260601_for_LGD_Fenix`), plus a §0
  schema/keyword-discovery block to locate the **not-yet-confirmed**
  suspension-period and restructuring-cancellation sources (candidate: the
  documented `[Dictionaries].[risk_analytics].[restructuring_v2]` event table —
  never queried from this repo, access unconfirmed). §4 is a fill-in-the-blank
  template for that extract once the real table/columns are found.
- **`stage3_safezone_discovery.sql`** / **`stage3_safezone_rolling_extract.sql`**
  — step-by-step action plan for this whole workstream (Task #1: derive the
  DPD safe-zone threshold from a 12-month re-default simulation; Task #2:
  size the candidate list under two competing recovery rules) is in
  [`docs/analysis/stage3_safezone_plan.md`](../docs/analysis/stage3_safezone_plan.md).
- **`stage3_safezone_discovery.sql`** — disambiguated the restructuring
  source before the 12-month DPD safe-zone / re-default simulation. **Resolved
  23.07.2026**: `[Dictionaries].[risk_analytics].[restructuring_v2]` — a
  multi-source restructuring EVENT table with both previously-missing pieces
  (suspension period via `grace_od_*`/`grace_int_*`; cancellation via
  `canc_date`). The RS event log (`Реструктуризация_RS$`) was a dead end
  (one field only); the `KAN_*_for_LGD` monthly family goes back to 2018 but
  has 7+ inconsistent spellings of the restructuring-end-date column across
  2023 — moot now.
- **`stage3_safezone_rolling_extract.sql`** — **purest raw pulls for the
  12-month DPD safe-zone / re-default simulation** (notebook-side): a 12-date
  report ladder (`MMYYYYPORTFOLIO` labels), the raw Stage 3 pool at each date,
  one flat raw monthly panel (dpd/category/balance/tag) spanning 6 months
  before the earliest portfolio date through the latest, and the raw
  restructuring-event pull from `restructuring_v2` (§3, resolved — no longer a
  placeholder). Encodes the locked-in methodology for traceability only —
  restructuring-covered clean months stay in the pool but get flagged (not
  excluded); re-default = first later month where `category` returns to `'3'`
  for any reason; the downward-trend hypothesis is strict monotonic
  non-increasing DPD across the 6-month window.
  All threshold/streak/re-default logic itself runs in pandas, not SQL.
- **`stage3_delinquency_groups.sql`** — per-loan monthly DPD **and** delinquency
  flag, a pattern-group label (e.g. `@345` = delinquent in the 3rd/4th/5th
  observed months), and **episode-aware severity**: DPD is a running day-count,
  so a 3-month-consecutive delinquency doesn't show 3 independent readings — it
  shows one number growing by ~30/31 days/month. This decomposes each loan's
  delinquency into consecutive-run episodes and reports the DPD at the **start**
  of the first episode (the true initial miss, not inflated by elapsed time)
  alongside the longest episode's length (chronicity) and its implied monthly
  increment (a ~30 value confirms continuous non-payment). Per-group quantiles
  (q25/median/q75) of both the raw and corrected metric — compare them to see
  how much a naive `MAX(dpd)` threshold would be misled, and to pick a sensible
  relax threshold on the corrected metric instead.

## `b3b_reconciliation_2025.sql` — closed-before-audited-year check

### The problem
**B3B** is the AQR list of "special-case" contracts that were present at the
start of a quarter and disappeared by its end (they affect the PD calculation).
For CL / CrediLogic source-system loans, the **closing dates** (`dte_close`) are
supplied by the system owner ("Гроз Б.М.Э."). Some of those closing dates fall
**before the audited year (2025)**, yet the loans still appear in the 2025
report. If a contract was "closed before 2025", the regulator will question why
it is in the 2025 population. This is the check behind **§6 of the B3B guide
("Фильтр по аудируемому году")** — see the process runbook in
[`docs/b3b_guide.md`](../docs/b3b_guide.md).

### What the script does
Cross-checks every B3B loan against the objective portfolio time-series and
reports, per loan, its **actual** last presence and state — the evidence that
corroborates or contradicts a "closed-before-2025" claim.

- **Base** (the B3B scope): `[CL_PORTFOLIO].[dbo].[FOR_B3B_AQR2026_16072026]`, key `[LOAN_ID]`
- **Time-series** (snapshots): the `UNION ALL` of **all six source-system portfolio
  tables** (B3B guide §2 — each `loan_id` belongs to one source system, so a B3B
  loan may live in any of these), key `(contract_number, [date])`:

  | source system | table |
  |---|---|
  | Credilogic (CL) | `[CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2]` |
  | Fenix (EBCL) | `[CL_PORTFOLIO].[dbo].[PORTFOLIO_Fenix]` |
  | RS | `[CL_PORTFOLIO].[dbo].[PORTFOLIO_RS]` |
  | Cards — MIGR_WAY4 (W) | `[CL_PORTFOLIO].[dbo].[PORTFOLIO_CREDITCARDS_MIGR_WAY4]` |
  | Cards — SMART_CARD (W) | `[CL_PORTFOLIO].[dbo].[PORTFOLIO_CREDITCARDS_SMART_CARD]` |
  | Cards — WAY4 (W) | `[CL_PORTFOLIO].[dbo].[PORTFOLIO_CREDITCARDS_WAY4]` |

- **Join**: `base.[LOAN_ID] = ts.contract_number`

The source tables do **not** share a schema, so each `UNION ALL` branch maps its
own columns to the canonical output names and `CAST`s to a common type. Only
`CL_PORTFOLIO_2` and the card tables use the canonical names; Fenix/RS differ and
lack `tag_1`/`status`. The mapping (verified against each table's column list):

| canonical | CL_PORTFOLIO_2 | Fenix / RS | Cards (WAY4 / SMART / MIGR) |
|---|---|---|---|
| `contract_number` | `contract_number` | `contractnumber` | `contract_number` |
| `date` | `date` | `actual_date` | `date` |
| `od` | `od` | `outstanding` | `od` |
| `balance` | `balance` | `Total_outstanding` | `balance` |
| `dpd` | `dpd` | Fenix `overdue_days_principal` / RS `dpd` | `dpd` |
| `category` | `category` | `Basket` | `category` |
| `tag_1` | `tag_1` | *(none → NULL)* | `tag_1` |
| `status` | `status` | *(none → NULL)* | `status` |
| `balance_with_discount` | `balance_with_discount` | *(none → NULL)* | *(none → NULL)* |
| `provisions_total` | `provisions_total` | *(none → NULL)** | `provisions_calculated` |

\* Fenix/RS have no single total-provisions column — left NULL; map from the
account columns (Fenix `_1877`/`ifrs_1428`, RS `deb_1877_prov`) if you need it.
`balance` is mapped to `Total_outstanding` (gross) for Fenix/RS. Adjust a branch
if your definition differs.

For each loan it pulls the **latest snapshot across all systems** (`source_system,
date, od, balance, dpd, category, tag_1, status, balance_with_discount,
provisions_total`) plus presence aggregates, and computes review flags:

| Flag | Meaning |
|---|---|
| `missing_in_portfolio` | loan is in B3B scope but has **no** snapshot in **any** source system |
| `no_activity_in_audit_year` | loan has snapshots, but **none** in 2025 → looks gone before 2025 |
| `last_activity_before_audit_year` | its **last-ever** snapshot predates 2025 (strongest signal) |
| `zero_balance_at_last` | balance already 0 at the last snapshot (consistent with a close) |
| `multi_source_system` | loan found in **more than one** source system (data-quality signal; expected = 1) |
| `review_flag` | headline: missing / no-2025-activity / last-before-2025 → **must be reviewed** |

The `source_system` column reports which system holds the latest snapshot.

A loan with real snapshots **inside 2025** (`review_flag = 0`) is defensible: the
portfolio data itself shows it was still present in the audited year, regardless
of a claimed earlier close date.

### Why `ROW_NUMBER()` instead of `MAX(date) + self-join`
The original pattern (`GROUP BY … MAX(date)` self-joined back) duplicates a
contract that has two rows on the same max date. This script uses
`ROW_NUMBER() OVER (PARTITION BY contract_number ORDER BY [date] DESC, [balance] DESC)`
so each loan yields exactly one latest row. Adjust the tie-break to your grain.

### Running it
1. Set the audited-year window at the top (`@AuditYearStart` / `@AuditYearEnd`).
2. **Section 1** is the read-only extract (all base rows, sorted worst-first).
3. **Section 2** filters to `review_flag = 1` (the exceptions only).
4. **Section 3** (optional) persists results into a new table (`SELECT … INTO`).
5. **Section 4** (optional, **destructive**) adds the columns onto the base table
   — back the table up first.

### Extending the reconciliation
To compare against the **claimed** close date and the sale / write-off marks,
`LEFT JOIN` the close-date source (CL/CrediLogic `dte_close`) and
`[CL_PORTFOLIO].[dbo].[SOLD_PORTFOLIO_FOR_LGD]` (`nocont = LOAN_ID`), then compare
the claimed close date against `last_snapshot_date`. Per the B3B guide the status
priority is: assignment/sale → written-off to loss → written-off off-balance →
fully repaid/closed.
