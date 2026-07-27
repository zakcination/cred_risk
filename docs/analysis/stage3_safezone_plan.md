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
- [x] Classify each loan-month into **three** states, not a boolean
      (`classify_restructuring`): `active` — a qualifying, non-cancelled
      event's `grace_od_*`/`grace_int_*` window covers the `snap_date`;
      `unknown` — a qualifying event exists but carries **no usable grace
      dates** to test against; `not_active` — no qualifying event at all, or
      every one has dates and the snapshot falls outside all of them.
      Yields `restr_active_pct` **and** `restr_unknown_pct` per loan/window
      (`compute_restr_state_pct`), denominated on months actually observed,
      not on a fixed 6.
      *Why three:* an undated event scored as `False` reports a genuinely
      restructured loan as "no payment holiday" — silently biasing the whole
      restructured-vs-not comparison in Phase C on a denominator of unknown
      quality. `restr_unknown_pct` is a **data-quality** reading, never a
      risk reading.
- [x] Report the transparency metric as **two** numbers, not one
      (`restructuring_coverage_summary`), per month: `pct_with_event` — does
      the loan have a restructuring event at all; `pct_event_dated` — of
      those, how many carry usable grace dates. `pct_with_event` alone
      answers the weaker question: a loan can have an event on record and
      still be unanswerable.

## Phase C — Task #1: find the safe-zone threshold

- [x] Load `censoring_events.csv` and audit its coverage — done in the
      notebook (`censoring_coverage_report`, `censored_from_month`).
      Real run 27.07.2026: **22 902 rows, 22 494 distinct contracts** across
      six months (08/10/12·2025, 04/05/06·2026) from the
      «Приложение №1 (Credilogic)» annexes.
- [x] **Sales resolved — no gap.** There is no sale register outside 12.2025
      because **there were no sales outside 12.2025** (БРМ, 27.07.2026).
      That distinction decides the whole question: "no source" would leave
      every other month's re-default rate a lower bound; "no events" makes it
      exact. The confirmation is recorded in the notebook as a dated,
      attributed constant (`SALES_DID_NOT_OCCUR`), not folded into an
      assumption — an auditor is entitled to see which of the two we relied
      on. Worth stating why it mattered: in 12.2025, the one month with both
      sources, sales outnumbered write-offs **21 341 to 5 016**, so had sales
      been happening unseen elsewhere, the invisible half would have been the
      larger one.
- [x] **Six write-off-free months confirmed — the lower-bound caveat is gone.**
      09, 11·2025 and 01, 02, 03, 07·2026 have no rows in the Credilogic
      archive, and БРМ confirmed 27.07.2026 that **no write-off batch ran** in
      them — "не проводилось", not "файла нет". Recorded as a dated, attributed
      constant (`WRITEOFF_DID_NOT_OCCUR` + `WRITEOFF_DID_NOT_OCCUR_SOURCE`)
      alongside the sales equivalent, listed literally by month rather than
      derived as "whatever the archive lacks" — otherwise a future panel month
      would inherit a confirmation nobody gave for it.
      With this, **both** exit types are covered across all twelve months, the
      coverage table reads `полное` throughout, and Phase C's re-default rate is
      an exact number rather than a lower bound.
      Two things to keep in view, since the whole censoring layer now rests on
      them: the coverage is carried by **two verbal confirmations, not by data**
      — if either is withdrawn, those months must return to `НЕ ПОДТВЕРЖДЕНО`
      rather than stay as last computed. And a declaration can go stale in one
      direction: a later scanner run finding events in a month declared empty.
      `declared_but_present` raises on exactly that, because the coverage table
      gives evidence priority and would otherwise read `полное` off the new
      events while the contradicted confirmation sat unnoticed in the code.
- [x] **Restorations — the file cannot answer it, so the panel does.**
      Confirmed 27.07.2026 that «Приложение №1» has **no operation-type
      column**: `Контракт · Дни просрочки · КОРЗИНА · Провизии % в LAM ·
      Задолженность без учёта дисконта · Задолженность с учётом дисконта ·
      ОД · Все провизии · Дисконты · Штраф 1860 · Провизии 18770 · Продукт ·
      Тэг` — the loan's balance-sheet position at the moment of the
      operation, with nothing distinguishing a write-off from a restoration.
      (The layout also drifts between months — 05.2026 renames «Дисконты» to
      «Дисконт / премия» — which is a further reason to read only the
      contract-number column.)
      Resolved by observation instead (`censoring_reentry_check`): a loan
      that genuinely left stops appearing in `CL_PORTFOLIO_2`, one that was
      restored does not. Any censored contract still present in the panel at
      or after its M+1 boundary is dropped from the censoring set, and
      **Phase C uses `censored_from_clean`, not `censored_from`.** This is
      stronger evidence than a flag would have been: it observes what
      happened to the loan rather than what was written about it.
- [ ] For `n ∈ {0, 3, 7, 10, …, 30}`: flag "provisionally recovered" loans per
      portfolio month (DPD ≤ n for the whole 6-month window). Restructuring-
      covered months stay **in** the pool, flagged — not excluded.
- [ ] For each flagged loan, scan forward for the first month `category`
      returns to `'3'` for **any** reason (not just DPD≥91) → re-default
      flag + months-to-redefault.
      ⚠ **Open decision — settle before writing this step.** `@LastAsOf`
      equals the newest portfolio date, so forward runway is 11 months for
      the 08.2025 cohort and **zero** for 07.2026. Scanning "up to the
      latest available report date" gives every column a different
      observation opportunity, so the re-default rate falls mechanically
      toward the recent end and an elbow read off that curve is a
      censoring artifact, not a signal.
      **Settled 27.07.2026: compute all three of K = 3, 6, 9** rather than
      pick one. Each is a defensible reading of "how long must a loan stay
      clean before the cure is durable", and the trade-off is visible in the
      data rather than argued about — a longer horizon is stricter evidence
      but costs cohorts, because only months with a full K of forward data
      are comparable:

      | K | Comparable cohorts | Which |
      |---|---|---|
      | 3 | 9 | 08.2025 – 04.2026 |
      | 6 | 6 | 08.2025 – 01.2026 |
      | 9 | 3 | 08.2025 – 10.2025 |

      If the elbow sits at the same `n` under all three, the threshold is a
      property of the portfolio and the finding is robust — which is the
      answer worth having in front of a regulator. If it moves with K, `n*`
      must always be quoted together with the horizon it was measured on.
- [x] **Threshold × cohort matrices built** (`redefault_matrix`) for each K,
      returning rate, denominator and censored-out count together — a rate
      without its base invites reading 100% off two loans.
- [x] **Split the matrix by restructuring state** — built
      (`redefault_split_matrix`), with the `unknown` share reported per cell
      (threshold × cohort) and pooled, plus an explicit verdict per threshold.
      Two things worth stating, because they decide how the output reads:
      - The loan-level segment follows the same priority as the month-level
        rule — `restructured` (any confirmed `active` month) > `unknown` (any
        unanswerable month, **including** a state that was never computed) >
        `not_restructured` (every observed month confirmed `not_active`). A
        `NaN` state goes to `unknown`, never to `not_restructured`: that
        collapse is the exact one the locked methodology forbids.
      - `UNKNOWN_MATERIALITY = 0.10` is set **before** the numbers are seen, and
        a cell above it prints `НЕ ПОДДЕРЖАНО` rather than a difference. A thin
        base (< `MIN_BASE` either side) prints `НЕТ БАЗЫ` instead — deliberately
        a separate verdict, since thin bases are fixed by accumulating cohorts
        and `unknown` is fixed only by populating grace dates upstream.
      Verified on synthetic cohorts: segment priority (including `active` beating
      `unknown` on the same loan), censored loans leaving the denominator without
      becoming survivors, `unknown` share measured off the flagged population
      rather than the pool, and all three verdict branches.
- [ ] Visualize: re-default % vs. n, one line per report month (or a summary
      band) — pick the threshold at the **elbow** where re-default stops
      being flat and starts climbing, rather than a hard-coded cutoff.
      **Settled 27.07.2026: the matrix is read first, and the criterion for
      "acceptably low" is chosen after seeing it** — an explicit call, not an
      oversight. What that costs is one specific thing, and it should be
      written into the Phase E methodology rather than left for a reviewer to
      notice: a threshold selected after the outcome is visible cannot also be
      presented as a prediction that the data then confirmed. State plainly
      that `n*` was chosen from this matrix.
      The cheap mitigation, which costs nothing here because all three horizons
      are already computed: pick `n*` on the pooled K=6 curve, then check it
      holds on views not used to pick it — the per-cohort spread and the K=3 /
      K=9 curves. Agreement there is genuine out-of-sample support for the
      choice; disagreement means `n*` is an artefact of the view it was read
      off, and must be quoted with that view attached.
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
- Restructuring coverage is **three-valued**, never boolean: `active` /
  `not_active` / `unknown`. A restructuring event whose grace dates are not
  populated makes that month `unknown` — it is never collapsed into
  `not_active`. Any restructured-vs-not comparison must report the `unknown`
  share alongside it; a segment whose `restr_unknown_pct` is material does
  not support a conclusion about restructuring, in either direction.
- Re-default = first later month with **DPD ≥ 91** (`STAGE3_DPD_TRIGGER`) —
  first hit counts, no sustained-months requirement.
  *Revised 27.07.2026.* This item previously read "first later month
  `category` returns to `'3'`", which is degenerate on this population: these
  loans are **in** Stage 3 at the observation month precisely because the
  current cure rule has not released them, so `category` is still `'3'` at
  M+1 and every flagged loan would score as a re-default. The question being
  asked is counterfactual — *had we cured this loan, would it have
  deteriorated back to Stage 3 severity?* — and a DPD trigger answers it
  without depending on the cure mechanics the study exists to change.
  The category-based version is retained as a **cross-check**
  (`redefault_category`: the loan must first leave Stage 3, then return). It
  measures something real but only over loans today's rule already released
  — a smaller, self-selected population — so it validates direction, never
  sets the threshold.
- Hypothesis 2's "downward trend" = **strict monotonic non-increasing** DPD
  across all 6 months.
- A loan that exits the panel via sale/write-off/forgiveness (per
  `censoring_events.csv`) is **censored**, not a clean survivor — excluded
  from the re-default-rate denominator for the months it would otherwise
  have been observed, not counted as "did not re-default."
- **Censoring starts at M+1, not M.** An event dated month M leaves month M
  itself observed. Grounded, not stylistic: the December write-off ran on
  30.12.2025 and those loans are still in the 01.12.2025 snapshot, gone by
  01.01.2026. Censoring from M would discard one month of genuine
  observation per censored loan — systematically, one-directionally, across
  22k+ loans. Archive dates are month-precision only (`date_precision='month'`
  throughout: the Credilogic annexes carry no date in their filenames), so
  M+1 is also the finest boundary the data supports.
- Where a contract has several events, the **first** one sets the boundary.
- **"No source" and "no events" are recorded as different things.** The
  coverage table is built from the panel's month list, not from the CSV's
  contents, so a month absent from the file appears as a row with its own
  status rather than disappearing. A month counts as fully covered only when
  it either has events on record **or** has a dated, attributed confirmation
  that none occurred (`SALES_DID_NOT_OCCUR`, `WRITEOFF_DID_NOT_OCCUR`).
  Anything else is `НЕ ПОДТВЕРЖДЕНО` and makes that month's re-default rate a
  lower bound. An empty month is never silently read as a clean month.
  As of 27.07.2026 every panel month satisfies one of the two, so no month is
  `НЕ ПОДТВЕРЖДЕНО` — but the rule stands, and a wider `@LastAsOf` will pull in
  months that fail it again. The confirmations are scoped to the months named in
  them, never extended forward.
- **A confirmation that contradicts the evidence is a stop, not a precedence
  rule.** If a month declared event-free later shows events in the archive, the
  run raises (`declared_but_present`) instead of quietly preferring either side.
  The declaration may have covered a different period, or the archive may have
  been extended; both are answerable questions, and neither is answered by
  picking the source that happens to be checked first.
