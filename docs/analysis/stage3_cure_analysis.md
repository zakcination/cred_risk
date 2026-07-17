# Stage 3 "cure-under-relaxed-rules" sizing — methodology

**Ask (Damir, 17.07.2026):** many Stage 3 (IFRS 9 default) loans sit with low/zero
DPD — they defaulted once, repaid the overdue part, and keep paying, but the
strict cure rule keeps them in Stage 3. Retail Business (РБ) sized these at
**~12 bn ₸**. Risk must **confirm or refute** with our own data. Query:
[`sql/stage3_cure_candidates.sql`](../../sql/stage3_cure_candidates.sql).

## The two rules
| | Rule |
|---|---|
| **Strict (current)** | (1) fully repay all overdue, then (2) **6 consecutive months with DPD = 0** (no overdue at all). |
| **Relaxed (proposed to test)** | overdue repaid **and** DPD stayed within a small tolerance (`@DpdTolerance`, e.g. ≤ 5 days) over the window — minor slips allowed. |

## Candidate definition (what we count)
A loan is a **stuck-by-minor-slips** candidate when, over the last `@WindowMonths`
month-ends up to `@AsOf`, it is:
1. currently **Stage 3** at `@AsOf` (pluggable — see below);
2. **not materially overdue now**: `dpd_asof ≤ @CureEntryDpd` (overdue repaid);
3. **would cure under the relaxed rule**: `max DPD over window ≤ @DpdTolerance`;
4. **does not cure under the strict rule**: `max DPD over window ≥ 1` (had ≥1 overdue month — a minor slip, not a re-default).

So the target set is `max_dpd_window ∈ [1, @DpdTolerance]` with the overdue
currently cleared. We then **SUM(balance) at `@AsOf`** and compare to 12 bn ₸.

## Parameters (defaults reflect Damir's example)
| Param | Default | Meaning |
|---|---|---|
| `@AsOf` | `2026-07-01` | reporting date (Diana: start from 01.07.2026) |
| `@WindowMonths` | `6` | observation window (strict rule uses 6 clean months) |
| `@DpdTolerance` | `5` | relaxed slip tolerance in days (Damir's example ≈ 5) |
| `@CureEntryDpd` | `5` | max current DPD to treat the overdue as repaid |

**Sensitivity:** re-run for `@DpdTolerance ∈ {1, 5, 30}` and `@WindowMonths ∈ {3, 6}`
to bracket the number and find which relaxed rule reproduces РБ's 12 bn.

## Data approach
- Reuses the **six-source portfolio union** (S01 RS, S02 Cards ×3, S03 CrediLogic,
  S17 Fenix) — the same mapping as the B3B reconciliation — to build a per-contract
  **monthly DPD + balance** series, then aggregates over the window. This matches
  Magzhan's point that behaviour must be read across **several dates**, not one.
- `NULL` DPD is treated as **"no data"** (ignored), not as 0.

## Open decisions (blocking a final number)
1. **Stage-3 source.** `category`/`Basket` is the *delinquency bucket*, not the
   IFRS stage. Pick one: **(A)** РБ's contract list (Bereket asked РБ for it) →
   load into `#stage3`; **(B)** a stage column if one exists; **(C)** derive from
   default markers (ever-90+ / `collections` / `writeoff` / `bankrupt`). Default
   in the script is (A).
2. **DPD source & off-by-one.** Portfolio `dpd` is off-by-one (`= days_past_due − 1`)
   and NULL-heavy for S03. For the defensible number, drive off the mart
   `loan_account.days_past_due` or, best, **actual payments** (Diana: pull
   `repayment_schedule` vs `payments`/`payments_wiring`, days-late per installment).
   The DPD-snapshot version is the fast proxy; the payments version is the §PAYMENTS
   refinement in the script.
3. **Tolerance & window.** Confirm `@DpdTolerance = 5` and `@WindowMonths = 6`
   (or Magzhan's "last 3 months").

## To reconcile with РБ
Ask РБ for their contract list + methodology (tolerance, window, stage source).
Load their list into `#stage3`, run our query on it, and diff: same loans? same
balance? The gap tells us whether the 12 bn holds, and our sensitivity grid shows
which rule assumptions produce it.
