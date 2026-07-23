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
- [ ] **Run** `stage3_safezone_rolling_extract.sql` end to end and export each
      result set (report-date ladder, Stage 3 pool, DPD/category panel,
      restructuring events) to CSV/parquet for the notebook.

## Phase B — notebook setup (Python)

- [ ] Load the 4 raw extracts into pandas.
- [ ] Per `portfolio_asof`, slice each loan's 6-month lookback window from the
      flat DPD/category panel.
- [ ] Compute `restr_active_pct` per loan/window (share of the 6 months
      covered by an active grace period — `grace_od_begin_date ≤ snap_date ≤
      grace_od_end_date` and/or the `grace_int_*` pair; pick the most recent
      restructuring event as of each `snap_date` first). Report **% of the
      population with a restructuring event defined vs. not**, per month —
      the transparency metric. Also flag any event with a non-null
      `canc_date` — a cancelled restructuring shouldn't count as "active."

## Phase C — Task #1: find the safe-zone threshold

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
