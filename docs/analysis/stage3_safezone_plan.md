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

- [ ] **Run** `sql/stage3_safezone_discovery.sql` (§0a/0b/0c) against the real DB.
- [ ] **Paste back**: which `KAN_*`/`kan_*` table has full 12-month coverage +
      fill rate on the restructuring end-date; any `FIELD_NAME` hit in
      `Реструктуризация_RS$` for suspension-period / cancellation; whether
      `[Dictionaries]` is reachable and what `restructuring_v2` looks like.
- [ ] *(Claude)* Finalize `stage3_safezone_rolling_extract.sql` §3 against the
      confirmed source — replace the `KAN_20260601_for_LGD_Fenix` placeholder.
- [ ] **Run** `stage3_safezone_rolling_extract.sql` end to end and export each
      result set (report-date ladder, Stage 3 pool, DPD/category panel,
      restructuring reference) to CSV/parquet for the notebook.

## Phase B — notebook setup (Python)

- [ ] Load the 4 raw extracts into pandas.
- [ ] Per `portfolio_asof`, slice each loan's 6-month lookback window from the
      flat DPD/category panel.
- [ ] Compute `restr_active_pct` per loan/window (share of the 6 months
      covered by an active restructuring — `snap_date ≤ дата окончания
      реструктуры`). Report **% of the population with a restructuring
      end-date defined vs. not**, per month — the transparency metric.

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
