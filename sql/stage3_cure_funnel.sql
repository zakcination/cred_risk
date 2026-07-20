/* =============================================================================
   Stage 3 cure funnel — how much is cut off by each criterion, and the cure
   population under a relaxed DPD rule (n ∈ {1,3,7,10}). CrediLogic / S03 base.
   =============================================================================
   Grounded on the reviewer's query (17.07.2026):
     base   = [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2] at date = @AsOf
     стадия = category = '3'  (category IS the IFRS 9 stage here)
     exclude tag = '11' (written off / off-balance)
     default_date from HISTORY_DEFAULT_ACCOUNT / IFRS9 LGD table
     keep only default_date NOT NULL and >= @DefaultCutoff (31.12.2025)
   Then: relax the DPD cure threshold by n days, n ∈ {1,3,7,10}, and size the
   would-cure population (loans / balance / provisions) + cure rate at each n.

   Two result sets:
     (1) FUNNEL — counts, balance and provisions surviving each criterion.
     (2) PER-N  — cure candidates at dpd ≤ n for n ∈ {1,3,7,10}.

   T-SQL (Microsoft SQL Server).
   ============================================================================= */

-------------------------------------------------------------------------------
-- 0. Parameters
-------------------------------------------------------------------------------
DECLARE @AsOf          date = '2026-07-01';
DECLARE @DefaultCutoff date = '2025-12-31';   -- keep default_date >= this (exclude older & NULL)

-------------------------------------------------------------------------------
-- 1. Base population + per-row criterion flags.
--    default_date: reviewer's SELECT used the IFRS9 LGD table (c), but for
--    CL_PORTFOLIO_2 (CrediLogic) that Fenix LGD table will rarely match, so we
--    take HISTORY_DEFAULT_ACCOUNT (b) first, then fall back to (c). Swap if the
--    canonical default date lives elsewhere.  ⚠ CONFIRM the source.
-------------------------------------------------------------------------------
;WITH base AS (
    SELECT
        a.contract_number,
        a.[dpd],
        a.[balance],
        a.[balance_with_discount],
        a.[provisions_total],
        a.[tag],
        COALESCE(b.default_date, c.default_date) AS default_date
    FROM [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2] a
    LEFT JOIN [CL_PORTFOLIO].[dbo].[HISTORY_DEFAULT_ACCOUNT] b
        ON a.contract_number = b.account_number
    LEFT JOIN [IFRS9].[dbo].[KAN_20260601_for_LGD_Fenix] c
        ON a.contract_number = c.account_number
    WHERE a.[date] = @AsOf
      AND a.[category] = '3'          -- Stage 3
),
flagged AS (
    SELECT *,
        CASE WHEN ISNULL([tag], '') <> '11' THEN 1 ELSE 0 END              AS keep_tag,
        CASE WHEN default_date IS NOT NULL THEN 1 ELSE 0 END               AS def_notnull,
        CASE WHEN default_date >= @DefaultCutoff THEN 1 ELSE 0 END         AS def_recent
    FROM base
)
-------------------------------------------------------------------------------
-- (1) FUNNEL — how much survives each criterion (count / balance / provisions).
-------------------------------------------------------------------------------
SELECT
    'stage3 total (category=3, '+CONVERT(varchar,@AsOf,120)+')'      AS step, COUNT(*) AS loans,
        SUM(balance) AS balance, SUM(provisions_total) AS provisions
    FROM flagged
UNION ALL SELECT '  + exclude tag = 11',
        SUM(keep_tag),
        SUM(CASE WHEN keep_tag=1 THEN balance END),
        SUM(CASE WHEN keep_tag=1 THEN provisions_total END) FROM flagged
UNION ALL SELECT '  + default_date not null',
        SUM(CASE WHEN keep_tag=1 AND def_notnull=1 THEN 1 ELSE 0 END),
        SUM(CASE WHEN keep_tag=1 AND def_notnull=1 THEN balance END),
        SUM(CASE WHEN keep_tag=1 AND def_notnull=1 THEN provisions_total END) FROM flagged
UNION ALL SELECT '  + default_date >= '+CONVERT(varchar,@DefaultCutoff,120)+'  (=ELIGIBLE)',
        SUM(CASE WHEN keep_tag=1 AND def_notnull=1 AND def_recent=1 THEN 1 ELSE 0 END),
        SUM(CASE WHEN keep_tag=1 AND def_notnull=1 AND def_recent=1 THEN balance END),
        SUM(CASE WHEN keep_tag=1 AND def_notnull=1 AND def_recent=1 THEN provisions_total END) FROM flagged
UNION ALL SELECT '     of which dpd IS NULL (assumption-sensitive)',
        SUM(CASE WHEN keep_tag=1 AND def_notnull=1 AND def_recent=1 AND [dpd] IS NULL THEN 1 ELSE 0 END),
        SUM(CASE WHEN keep_tag=1 AND def_notnull=1 AND def_recent=1 AND [dpd] IS NULL THEN balance END),
        SUM(CASE WHEN keep_tag=1 AND def_notnull=1 AND def_recent=1 AND [dpd] IS NULL THEN provisions_total END) FROM flagged;


/* -----------------------------------------------------------------------------
   (2) PER-N — relaxed cure population at dpd ≤ n, n ∈ {1,3,7,10}.
   NULL dpd is counted as "not overdue" (ISNULL(dpd,0)); the funnel above shows
   how many rows that assumption moves — flip to `AND dpd IS NOT NULL` to exclude.
   Run this block on its own (re-declare @AsOf/@DefaultCutoff if in a new batch).
   -----------------------------------------------------------------------------
;WITH base AS ( ...same as §1... ),
eligible AS (
    SELECT [dpd], [balance], [provisions_total]
    FROM base
    WHERE ISNULL([tag],'') <> '11'
      AND default_date IS NOT NULL
      AND default_date >= @DefaultCutoff
),
ns(n) AS ( SELECT n FROM (VALUES (1),(3),(7),(10)) v(n) )
SELECT
    ns.n,
    (SELECT COUNT(*) FROM eligible)                                        AS eligible_loans,
    COUNT(CASE WHEN ISNULL(e.[dpd],0) <= ns.n THEN 1 END)                  AS cure_loans,
    SUM (CASE WHEN ISNULL(e.[dpd],0) <= ns.n THEN e.[balance] END)         AS cure_balance,
    SUM (CASE WHEN ISNULL(e.[dpd],0) <= ns.n THEN e.[provisions_total] END) AS cure_provisions_released,
    CAST(100.0 * COUNT(CASE WHEN ISNULL(e.[dpd],0) <= ns.n THEN 1 END)
         / NULLIF((SELECT COUNT(*) FROM eligible),0) AS decimal(5,2))      AS cure_rate_pct_by_count
FROM eligible e CROSS JOIN ns
GROUP BY ns.n
ORDER BY ns.n;
   ----------------------------------------------------------------------------- */

-------------------------------------------------------------------------------
-- Notes / assumptions to confirm
-------------------------------------------------------------------------------
-- * default_date source: COALESCE(HISTORY_DEFAULT_ACCOUNT, IFRS9 LGD). Your
--   SELECT used the IFRS9 (Fenix) table; for CL contracts it may not match —
--   confirm which table holds the canonical default date for CrediLogic.
-- * dpd NULL: treated as "not overdue" (curable). S03 dpd is NULL-heavy, so this
--   assumption is material — the funnel surfaces the NULL count so you can judge.
-- * dpd off-by-one (dpd = days_past_due - 1 in the mart): if it applies to this
--   raw column, use `ISNULL(dpd,0) <= n - 1` (or `+1`) to align the threshold.
-- * tag NULL kept (ISNULL(tag,'')<>'11'); plain `tag <> '11'` would also drop NULLs.
-- * S03 (CrediLogic) only. Repeat per source or use the six-source union
--   (stage3_cure_candidates.sql) for the whole book; category='3' must mean the
--   IFRS stage in each source.
-- * Snapshot at @AsOf sizes "currently performing" Stage-3 loans. For SUSTAINED
--   performance (max dpd ≤ n across the last N months — no re-default), use the
--   window logic in stage3_cure_candidates.sql.
