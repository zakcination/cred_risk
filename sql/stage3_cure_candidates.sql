/* =============================================================================
   ПРОСТЫМ ЯЗЫКОМ:
   Считаем, сколько займов 3-й стадии могли бы «оздоровиться» (перейти во 2-ю
   стадию) при более мягком правиле: заёмщик платит, но из-за мелкой просрочки не
   проходит строгое правило. Количество и сумму сверяем с оценкой РБ (12 млрд тг).
   Версия по «окну» из нескольких месяцев, по всем системам-источникам.
   ---------------------------------------------------------------------------
   Stage 3 "would-cure-under-relaxed-rules" candidates — sizing vs РБ's 12 bn ₸
   =============================================================================
   Business question (Damir, 17.07.2026)
   -------------------------------------
   Many Stage 3 (IFRS 9 default) loans currently sit with LOW or ZERO DPD (well
   under 90 days) — they defaulted once, repaid the overdue part, and have been
   paying, but the CURRENT cure rule is very strict, so they stay in Stage 3.

   Current strict cure rule (Stage 3 -> Stage 2):
     1) fully repay ALL overdue amount, then
     2) 6 consecutive months with DPD = 0 (no overdue at all, not even 1 day).

   A loan that pays for months but slips once (e.g. 5 days late in month 5-6, then
   pays) does NOT cure under the strict rule and stays stuck in Stage 3.

   Retail Business (РБ) estimated such loans at ~12 bn ₸ in Stage 3. Risk needs to
   CONFIRM or REFUTE that number with our own data. This query sizes the
   population under a RELAXED rule and is fully parametrised so we can test
   scenarios and reconcile to РБ.

   Definition used here
   --------------------
   Over the observation window (the last @WindowMonths month-end snapshots up to
   @AsOf), a "relaxed-cure candidate" is a loan that is:
     * currently in Stage 3 at @AsOf (see the pluggable Stage-3 filter, §STAGE3), and
     * currently NOT materially overdue (current DPD <= @CureEntryDpd — the overdue
       part is repaid), and
     * would cure under a relaxed rule: max DPD over the window <= @DpdTolerance, and
     * does NOT cure under the strict rule: it had at least one overdue month in the
       window (max DPD over the window >= 1) — i.e. it is stuck only because of
       minor slips, not a real re-default.

   Output: the candidate loans + a total count and SUM(balance) to compare with
   the 12 bn ₸ figure, split by source system and current bucket.

   Data notes (from docs/analysis)
   -------------------------------
   * Sources unioned: S01 RS, S02 Cards (Way4/MIGR/SMART), S03 CrediLogic, S17 Fenix.
   * `dpd` has a documented off-by-one (dpd = days_past_due - 1) and is NULL-heavy
     / unreliable for S03 (CL). Treat NULL dpd as "no data" (not as 0) and, for a
     final number, prefer the mart `loan_account.days_past_due` or, better, the
     actual repayment_schedule-vs-payments pattern (see §PAYMENTS refinement).
   * `category`/`Basket` is the DELINQUENCY bucket, NOT the IFRS stage. The Stage-3
     population must come from the stage source (a stage column, РБ's contract
     list, or the default markers) — see §STAGE3.

   T-SQL (Microsoft SQL Server).
   ============================================================================= */

-------------------------------------------------------------------------------
-- 0. Parameters
-------------------------------------------------------------------------------
DECLARE @AsOf          date = '2026-07-01';  -- reporting date (Diana: start from 01.07.2026)
DECLARE @WindowMonths  int  = 6;             -- observation window (strict rule uses 6 clean months)
DECLARE @DpdTolerance  int  = 5;             -- relaxed rule: allow slips up to N days (Damir's example: ~5)
DECLARE @CureEntryDpd  int  = 5;             -- "overdue repaid": current DPD must be <= this at @AsOf
DECLARE @WindowStart   date = DATEADD(MONTH, -@WindowMonths, @AsOf);

-------------------------------------------------------------------------------
-- 1. Unified monthly time-series across all six source systems, restricted to
--    the observation window. (Same mapping as b3b_reconciliation_2025.sql;
--    TRY_CAST so dirty values -> NULL instead of aborting.)
-------------------------------------------------------------------------------
;WITH ts AS (
    SELECT 'S03_Credilogic' AS source_system, contract_number,
           TRY_CAST([date] AS date) AS snap_date,
           TRY_CAST([balance] AS decimal(38,2)) AS balance,
           TRY_CAST([dpd] AS int) AS dpd,
           TRY_CAST([category] AS nvarchar(255)) AS bucket
    FROM [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2]
    UNION ALL
    SELECT 'S17_Fenix', contractnumber, TRY_CAST(actual_date AS date),
           TRY_CAST(Total_outstanding AS decimal(38,2)),
           TRY_CAST(overdue_days_principal AS int), TRY_CAST(Basket AS nvarchar(255))
    FROM [CL_PORTFOLIO].[dbo].[PORTFOLIO_Fenix]
    UNION ALL
    SELECT 'S01_RS', contractnumber, TRY_CAST(actual_date AS date),
           TRY_CAST(Total_outstanding AS decimal(38,2)),
           TRY_CAST([dpd] AS int), TRY_CAST(Basket AS nvarchar(255))
    FROM [CL_PORTFOLIO].[dbo].[PORTFOLIO_RS]
    UNION ALL
    SELECT 'S02_MIGR_WAY4', contract_number, TRY_CAST([date] AS date),
           TRY_CAST([balance] AS decimal(38,2)), TRY_CAST([dpd] AS int),
           TRY_CAST([category] AS nvarchar(255))
    FROM [CL_PORTFOLIO].[dbo].[PORTFOLIO_CREDITCARDS_MIGR_WAY4]
    UNION ALL
    SELECT 'S02_SMART_CARD', contract_number, TRY_CAST([date] AS date),
           TRY_CAST([balance] AS decimal(38,2)), TRY_CAST([dpd] AS int),
           TRY_CAST([category] AS nvarchar(255))
    FROM [CL_PORTFOLIO].[dbo].[PORTFOLIO_CREDITCARDS_SMART_CARD]
    UNION ALL
    SELECT 'S02_WAY4', contract_number, TRY_CAST([date] AS date),
           TRY_CAST([balance] AS decimal(38,2)), TRY_CAST([dpd] AS int),
           TRY_CAST([category] AS nvarchar(255))
    FROM [CL_PORTFOLIO].[dbo].[PORTFOLIO_CREDITCARDS_WAY4]
),
win AS (   -- window rows only
    SELECT * FROM ts
    WHERE snap_date >= @WindowStart AND snap_date <= @AsOf
),
-------------------------------------------------------------------------------
-- STAGE3: the currently-Stage-3 population. PLUGGABLE — choose ONE:
--   (A) РБ's contract list  -> put the LOAN_IDs in #stage3(contract_number)
--   (B) a stage column      -> replace the body with the stage=3 predicate
--   (C) derive from markers  -> ever-90+ / collections / writeoff / bankrupt
-- Default below is (A): a temp table you populate before running.
-------------------------------------------------------------------------------
stage3 AS (
    SELECT DISTINCT contract_number FROM #stage3
    -- (B) example:  SELECT contract_number FROM <stage source> WHERE ifrs_stage = 3
    -- (C) example:  SELECT DISTINCT contract_number FROM win WHERE dpd > 90
),
per_contract AS (
    SELECT
        w.contract_number,
        MAX(CASE WHEN w.snap_date = a.asof_snap THEN w.source_system END) AS source_system,
        -- current state at (or nearest to) @AsOf
        MAX(CASE WHEN w.snap_date = a.asof_snap THEN w.balance END)       AS balance_asof,
        MAX(CASE WHEN w.snap_date = a.asof_snap THEN w.dpd END)           AS dpd_asof,
        MAX(CASE WHEN w.snap_date = a.asof_snap THEN w.bucket END)        AS bucket_asof,
        -- behaviour over the window (NULL dpd is ignored, i.e. "no data", not 0)
        MAX(w.dpd)                                                        AS max_dpd_window,
        SUM(CASE WHEN w.dpd > 0 THEN 1 ELSE 0 END)                        AS months_overdue_in_window,
        SUM(CASE WHEN w.dpd > @DpdTolerance THEN 1 ELSE 0 END)            AS months_over_tolerance,
        COUNT(DISTINCT w.snap_date)                                       AS months_observed
    FROM win w
    CROSS APPLY (SELECT MAX(snap_date) AS asof_snap
                 FROM win w2 WHERE w2.contract_number = w.contract_number) a
    WHERE w.contract_number IN (SELECT contract_number FROM stage3)
    GROUP BY w.contract_number
)
-------------------------------------------------------------------------------
-- 2. Candidate loans (detail). Comment this out and run §3 for the headline.
-------------------------------------------------------------------------------
SELECT
    p.contract_number,
    p.source_system,
    p.balance_asof,
    p.dpd_asof,
    p.bucket_asof,
    p.max_dpd_window,
    p.months_overdue_in_window,
    p.months_observed
FROM per_contract p
WHERE p.dpd_asof <= @CureEntryDpd            -- overdue repaid at @AsOf
  AND p.max_dpd_window <= @DpdTolerance       -- would cure under the relaxed rule
  AND p.max_dpd_window >= 1                    -- but slipped -> stuck under the strict rule
ORDER BY p.balance_asof DESC;

/* -----------------------------------------------------------------------------
   3. Headline — count and total balance vs РБ's 12 bn ₸ (run instead of §2:
      wrap §2's SELECT as CTE `cand` and aggregate).
   -----------------------------------------------------------------------------
   SELECT p.source_system,
          COUNT(*)                    AS loans,
          SUM(p.balance_asof)         AS balance_total,
          SUM(p.balance_asof)/1e9     AS balance_bn
   FROM per_contract p
   WHERE p.dpd_asof <= @CureEntryDpd AND p.max_dpd_window BETWEEN 1 AND @DpdTolerance
   GROUP BY p.source_system WITH ROLLUP
   ORDER BY GROUPING(p.source_system), balance_total DESC;

   Sensitivity: re-run for @DpdTolerance IN (1,5,30) and @WindowMonths IN (3,6)
   to bracket the number and see which relaxed rule reproduces РБ's 12 bn.
   ----------------------------------------------------------------------------- */

/* -----------------------------------------------------------------------------
   §PAYMENTS refinement (Diana: «к ним платежи подтянуть и даты платежа»)
   -----------------------------------------------------------------------------
   The DPD-snapshot approach above is a proxy. For the defensible final number,
   drive the same logic off actual payment behaviour from the mart:
     repayment_schedule (due dates/amounts) LEFT JOIN payments / payments_wiring
     (paid dates/amounts) per contract, deriving per-installment days-late, then
     applying the same @DpdTolerance / @WindowMonths / strict-vs-relaxed test.
   Prefer loan_account.days_past_due over the raw portfolio `dpd` (off-by-one,
   NULL-heavy for S03).
   ----------------------------------------------------------------------------- */
