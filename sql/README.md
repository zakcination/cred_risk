# `sql/` — AQR data-check scripts

SQL checks for the AQR / B3B workstream. **Microsoft SQL Server (T-SQL).** These
scripts read schema (table/column names) only — no confidential data values are
stored here.

## `b3b_reconciliation_2025.sql` — closed-before-audited-year check

### The problem
**B3B** is the AQR list of "special-case" contracts that were present at the
start of a quarter and disappeared by its end (they affect the PD calculation).
For CL / CrediLogic source-system loans, the **closing dates** (`dte_close`) are
supplied by the system owner ("Гроз Б.М.Э."). Some of those closing dates fall
**before the audited year (2025)**, yet the loans still appear in the 2025
report. If a contract was "closed before 2025", the regulator will question why
it is in the 2025 population. This is the check behind **§6 of the B3B guide
("Фильтр по аудируемому году")**.

### What the script does
Cross-checks every B3B loan against the objective portfolio time-series and
reports, per loan, its **actual** last presence and state — the evidence that
corroborates or contradicts a "closed-before-2025" claim.

- **Base** (the B3B scope): `[CL_PORTFOLIO].[dbo].[FOR_B3B_AQR2026_16072026]`, key `[LOAN_ID]`
- **Time-series** (snapshots): `[CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2]`, key `(contract_number, [date])`
- **Join**: `base.[LOAN_ID] = ts.contract_number`

For each loan it pulls the **latest snapshot** (`date, od, balance, dpd,
category, tag_1, status, balance_with_discount, provisions_total`) plus presence
aggregates, and computes review flags:

| Flag | Meaning |
|---|---|
| `missing_in_portfolio` | loan is in B3B scope but has **no** snapshot in the time-series |
| `no_activity_in_audit_year` | loan has snapshots, but **none** in 2025 → looks gone before 2025 |
| `last_activity_before_audit_year` | its **last-ever** snapshot predates 2025 (strongest signal) |
| `zero_balance_at_last` | balance already 0 at the last snapshot (consistent with a close) |
| `review_flag` | headline: any of the above → **must be reviewed** before defending inclusion |

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
