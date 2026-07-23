# Stage 3 DPD safe-zone & re-default study — action plan

Phase 2 of the Stage 3 cure-rate analysis (phase 1:
[`stage3_cure_analysis.md`](stage3_cure_analysis.md), merged in PR #16). Phase
1 sized cure candidates under a few fixed relaxed-DPD snapshots (n ∈
{1,3,7,10}). This phase derives the DPD "safe zone" threshold from **history**
— does relaxing to DPD≤n actually predict durable cure, or does it just delay
a re-default? — then applies it to size the current candidate list under two
competing recovery rules.

SQL pulls raw ingredients only; all thresholding, streak logic, and re-default
computation runs in pandas (ipynb), per the "purest raw extractions" direction.

## Phase A — data readiness (SQL)

- [x] **Run** `sql/stage3_safezone_discovery.sql` — done 23.07.2026. Resolved:
      **`[Dictionaries].[risk_analytics].[restructuring_v2]`** is the winning
      source — a multi-source (`dlcr$source`) restructuring EVENT table with
      **both previously-missing pieces**: suspension period
      (`grace_od_begin_date`/`grace_od_end_date` for principal,
      `grace_int_begin_date`/`grace_int_end_date` for interest) and
      cancellation (`canc_date`). The RS event log turned out to be a dead end
      (only one field: "Наличие реструктуризации"); `KAN_20250301_for_LGD_
      Fenix_DI_BI` doesn't exist; the `KAN_*_for_LGD` monthly family has a
      real per-month series back to 2018 but the restructuring-end-date
      column's spelling is inconsistent across ~15 months in 2023 (7+ variant
      names) before settling — moot now that `restructuring_v2` supersedes it
      for restructuring info. Fill rates for reference: `KAN_20260601_for_LGD_
      Fenix` 29.5%, `kan_0101_rus` 53.5% (but only 2 of these "_rus" tables
      exist — not a full monthly series, and has a `1899-12-30` null-date
      artifact), `kan_0106_rus` 28.7%.
- [x] *(Claude)* Finalized `stage3_safezone_rolling_extract.sql` §3 against
      `restructuring_v2` (raw event pull, `loan_id = contract_number` assumed
      — unconfirmed, verify row counts) — replaces the placeholder.
- [x] **Run** `stage3_safezone_rolling_extract.sql` — done 23.07.2026. Ladder
      confirmed 08.2025→07.2026 (12 months) as designed. Row counts: §1 Stage 3
      pool 481.818k rows (loan × portfolio_label, ~40k/month), §2 DPD/category
      panel 1.080891M rows, §3 restructuring_v2 join 91.679k rows — the
      `loan_id = contract_number` join key returns a plausible non-trivial
      count, so treat it as working unless the notebook turns up a mismatch.
      **Still open:** export each result set to CSV/parquet for the notebook.

## Phase A.5 — resolved: the Dec-2025→Jan-2026 pool discontinuity

While running Phase A, the Stage 3 pool dropped 54,088 → 28,668 loans between
the December 2025 and January 2026 snapshots — non-uniformly (non-restructured
loans fell 70%, restructured loans only 34%). Investigated in
[`sql/stage3_pool_dropoff_investigation.sql`](../../sql/stage3_pool_dropoff_investigation.sql) —
**98.1% resolved**, not a data bug:

- 26,887 of 27,385 exited loans (98.2%) had **no row at all** in
  `CL_PORTFOLIO_2` on 01.01.2026 (not tag=11, not recategorized — gone
  outright). `KAN_write_off_AQR`/`KAN_sale_KA_AQR` (both confirmed in
  `IFRS9`, not `CL_PORTFOLIO`) explained **0** of them — stale AQR-cycle
  exports, as suspected.
- `[CL_PORTFOLIO].[dbo].[Prodaja&Proschenie_12_2025]` (`Contract`/`Продажа и
  прошение`/`IIN`/`SFK`) explained **26,360 of 26,887 (98.0%)**: 21,341 sold
  (FinCore/ATLAS), 5,016 written off to off-balance (dated 30.12.2025), 3
  forgiven. Plus 498 loans legitimately reclassified out of Stage 3
  (category change). ~527 loans (1.9%) remain unexplained — small enough not
  to chase further.
- **Same pattern confirmed in other months** (082025, 102025, 04-06/2026 so
  far) — but only as a local Excel archive
  (`R:\!!!ukr1\списание-восстановление\{2025,2026}\...`), not SQL.
  [`scripts/writeoff_restoration_scan.py`](../../scripts/writeoff_restoration_scan.py)
  scans it (header row 7, contract = 2nd column, date from sheet name or
  filename) into `censoring_events.csv` for the notebook.

**Methodology consequence for Phase C:** a loan that was sold/written-off/
forgiven exited the panel for a reason **unrelated to credit performance** —
it must be treated as **censored**, not as "safely survived" (the current
re-default logic — `category` never returns to `'3'` → not re-defaulted —
would silently misclassify every one of these as a clean outcome, biasing
every threshold to look safer than it is). Added to locked methodology below;
wiring `censoring_events.csv` into the re-default scan is a Phase C
prerequisite, not yet done.

## Phase B — notebook setup (Python)

[`notebooks/stage3_safezone_analysis.ipynb`](../../notebooks/stage3_safezone_analysis.ipynb)
implements all of Phase B below; run it against your exported CSVs
(`C:\project_mz\surau\DPDRelaxing\raw_data`) and confirm the sanity-check
counts match before moving to Phase C.

- [x] Load the 4 raw extracts into pandas.
- [x] Per `portfolio_asof`, slice each loan's 6-month lookback window from the
      flat DPD/category panel (`build_lookback_dpd`).
- [x] Compute `restr_active_pct` per loan/window (share of the 6 months
      covered by an active, non-cancelled grace period — checks ANY
      qualifying restructuring event's `grace_od_*`/`grace_int_*` window
      against each `snap_date`, excludes events with `canc_date ≤ snap_date`).
      Report **% of the population with a restructuring event defined vs.
      not**, per month — the transparency metric
      (`restructuring_coverage_summary`).

## Phase C — Task #1: find the safe-zone threshold

- [ ] Load `censoring_events.csv` (from `writeoff_restoration_scan.py`, plus
      December's `Prodaja&Proschenie_12_2025` exported the same way) and mark
      any loan whose panel exit coincides with a censoring event as
      **censored**, not re-defaulted/not-re-defaulted — exclude censored
      exits from the re-default-rate denominator rather than counting them as
      clean survivors. Confirm coverage for all 12 months first; log (don't
      silently assume zero events) for any month with no censoring source.
- [ ] For `n ∈ {0, 3, 7, 10, …, 30}`: flag "provisionally recovered" loans per
      portfolio month (DPD ≤ n for the whole 6-month window). Restructuring-
      covered months stay **in** the pool, flagged — not excluded.
- [ ] For each flagged loan, scan forward (up to the latest available report
      date) for the first month `category` returns to `'3'` for **any**
      reason (not just DPD≥91) → re-default flag + months-to-redefault.
- [ ] Build the **threshold × report-month re-default-rate matrix**
      (12 columns), split further by restructuring-covered vs not.
- [ ] Visualize: re-default % vs. n, one line per report month (or a summary
      band) — pick the threshold at the **elbow** where re-default stops
      being flat and starts climbing, rather than a hard-coded cutoff.
      *(Open decision: confirm what "acceptably low" re-default means before
      this step — a fixed ceiling, e.g. <10%, or the visual elbow — flag for
      sign-off once the matrix is in front of us.)*
- [ ] **Decision checkpoint:** lock the DPD safe-zone threshold `n*`.

## Phase D — Task #2: size the candidate list, pick the rule

- [ ] Apply `n*` to the **latest** 6-month window to build the current
      recovery candidate list.
- [ ] **Hypothesis 1 (straight-line):** DPD ≤ n* for all 6 months. Break down
      by delinquent-months-count (1–6) with count / balance / provisions.
- [ ] **Hypothesis 2 (downward-trend, more conservative):** strictly
      monotonic non-increasing DPD across the 6 months
      (`dpd(m-6) ≥ … ≥ dpd(m-1)`), regardless of whether it ever hit zero.
- [ ] Compare H1 vs. H2: overlap, size, balance, provisions, and cross-check
      each against Phase C's re-default matrix for the segment each
      hypothesis would have flagged historically.
- [ ] **Final decision:** recommended rule (H1 / H2 / hybrid), resulting
      population (count / balance / provisions), vs. Retail Business's 12bn ₸
      estimate.

## Phase E — wrap-up

- [ ] Write up methodology + results as a companion to
      `stage3_cure_analysis.md`.
- [ ] Update `sql/README.md` / this plan if new scripts come out of the
      notebook work that belong in the repo.

## Locked methodology (do not re-litigate mid-analysis)

- Restructuring-covered clean months: **kept in the pool, flagged**
  (`restr_active_pct`) — not excluded.
- Re-default = first later month `category` returns to `'3'` **for any
  reason** — first hit counts, no sustained-months requirement.
- Hypothesis 2's "downward trend" = **strict monotonic non-increasing** DPD
  across all 6 months.
- A loan that exits the panel via sale/write-off/forgiveness (per
  `censoring_events.csv`) is **censored**, not a clean survivor — excluded
  from the re-default-rate denominator for the months it would otherwise
  have been observed, not counted as "did not re-default."
