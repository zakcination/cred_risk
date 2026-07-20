/* =============================================================================
   ПРОСТЫМ ЯЗЫКОМ:
   Собираем «пул» для анализа оздоровления. Берём непустые (с датой дефолта)
   займы 3-й стадии на 01.07.2026 (category=3, без списанных tag=11) и по каждому
   вытягиваем просрочку (dpd) ПОМЕСЯЧНО от даты дефолта до 01.07.2026. Пул
   сохраняем отдельными таблицами (шапка + помесячная просрочка), чтобы дальше
   по нему отдельно считать смягчение правил оздоровления (dpd ≤ n).
   -----------------------------------------------------------------------------
   Stage 3 cure POOL builder — one persisted head row per contract + a monthly
   post-default DPD history (default_date → @AsOf), for deeper analysis.

   Anchor = default_date (from HISTORY_DEFAULT_ACCOUNT / IFRS9 LGD). Restructuring
   end date carried along. DPD pulled per contract from CL_PORTFOLIO_2 for every
   monthly snapshot after the default date up to (and including) @AsOf — the
   horizon is variable per contract (recent defaults → fewer months) and capped
   at @AsOf ("only pull dpd until 01.07.2026").

   Output tables (staging — drop when done, or swap to #temp):
     STAGE3_CURE_POOL_HEAD_20260701  — one row per contract (the report "bone")
     STAGE3_CURE_POOL_DPD_20260701   — long form: one row per contract × month
   T-SQL (Microsoft SQL Server).
   ============================================================================= */

DECLARE @AsOf date = '2026-07-01';

-------------------------------------------------------------------------------
-- 1. Шапка пула — одна строка на контракт (скелет отчёта + даты).
--    Только непустые: default_date IS NOT NULL.
-------------------------------------------------------------------------------
IF OBJECT_ID('[CL_PORTFOLIO].[dbo].[STAGE3_CURE_POOL_HEAD_20260701]','U') IS NOT NULL
    DROP TABLE [CL_PORTFOLIO].[dbo].[STAGE3_CURE_POOL_HEAD_20260701];

SELECT
    a.contract_number,
    a.[date]                                  AS asof_date,
    a.[category],
    a.[dpd]                                   AS dpd_asof,
    a.[balance],
    a.[balance_with_discount],
    a.[provisions_total],
    COALESCE(b.default_date, c.default_date)  AS default_date,
    c.[дата окончания реструктуры]            AS restr_end_date
INTO [CL_PORTFOLIO].[dbo].[STAGE3_CURE_POOL_HEAD_20260701]
FROM [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2] a
LEFT JOIN [CL_PORTFOLIO].[dbo].[HISTORY_DEFAULT_ACCOUNT] b
    ON a.contract_number = b.account_number
LEFT JOIN [IFRS9].[dbo].[KAN_20260601_for_LGD_Fenix] c
    ON a.contract_number = c.account_number
WHERE a.[date] = @AsOf
  AND a.[category] = '3'
  AND ISNULL(a.[tag],'') <> '11'
  AND COALESCE(b.default_date, c.default_date) IS NOT NULL;   -- непустые Stage 3

-------------------------------------------------------------------------------
-- 2. Помесячная просрочка по пулу: от default_date (не включая) до @AsOf.
--    month_since_default = DATEDIFF(MONTH, default_date, snap_date)  (def+k).
-------------------------------------------------------------------------------
IF OBJECT_ID('[CL_PORTFOLIO].[dbo].[STAGE3_CURE_POOL_DPD_20260701]','U') IS NOT NULL
    DROP TABLE [CL_PORTFOLIO].[dbo].[STAGE3_CURE_POOL_DPD_20260701];

SELECT
    h.contract_number,
    h.default_date,
    DATEDIFF(MONTH, h.default_date, p.[date]) AS month_since_default,   -- def+k
    p.[date]      AS snap_date,
    p.[dpd],
    p.[balance]   AS balance_m,
    p.[category]  AS category_m
INTO [CL_PORTFOLIO].[dbo].[STAGE3_CURE_POOL_DPD_20260701]
FROM [CL_PORTFOLIO].[dbo].[STAGE3_CURE_POOL_HEAD_20260701] h
JOIN [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2] p
    ON p.contract_number = h.contract_number
WHERE p.[date] > h.default_date
  AND p.[date] <= @AsOf;                                     -- только до 01.07.2026

-------------------------------------------------------------------------------
-- 3. Проверка объёма пула
-------------------------------------------------------------------------------
SELECT
    (SELECT COUNT(*) FROM [CL_PORTFOLIO].[dbo].[STAGE3_CURE_POOL_HEAD_20260701]) AS pool_contracts,
    (SELECT COUNT(*) FROM [CL_PORTFOLIO].[dbo].[STAGE3_CURE_POOL_DPD_20260701])  AS pool_month_rows,
    (SELECT SUM(balance)          FROM [CL_PORTFOLIO].[dbo].[STAGE3_CURE_POOL_HEAD_20260701]) AS pool_balance,
    (SELECT SUM(provisions_total) FROM [CL_PORTFOLIO].[dbo].[STAGE3_CURE_POOL_HEAD_20260701]) AS pool_provisions;


/* =============================================================================
   DEEPER ANALYSIS on the pool (run these separately on the staging tables)
   ============================================================================= */

-- (A) Per-contract DPD stats over the observed post-default months.
--   SELECT d.contract_number, h.default_date, h.restr_end_date, h.balance, h.provisions_total,
--          COUNT(*)                    AS months_observed,
--          MIN(d.month_since_default)  AS first_def_k,
--          MAX(d.month_since_default)  AS last_def_k,
--          MAX(d.[dpd])                AS max_dpd,
--          SUM(CASE WHEN d.[dpd] > 0 THEN 1 ELSE 0 END) AS months_overdue,
--          h.dpd_asof
--   FROM [CL_PORTFOLIO].[dbo].[STAGE3_CURE_POOL_DPD_20260701] d
--   JOIN [CL_PORTFOLIO].[dbo].[STAGE3_CURE_POOL_HEAD_20260701] h ON h.contract_number = d.contract_number
--   GROUP BY d.contract_number, h.default_date, h.restr_end_date, h.balance, h.provisions_total, h.dpd_asof;

-- (B) Relaxed-cure count: how many cure with 6 consecutive months at dpd ≤ n,
--     n ∈ {0,1,3,7,10}. n=0 is today's strict rule; increment over 0 = the loans
--     stuck only by minor slips (the population behind РБ's 12 bn).
--   DECLARE @CleanMonths int = 6;
--   ;WITH ns(n) AS (SELECT n FROM (VALUES(0),(1),(3),(7),(10)) v(n)),
--   clean AS (
--       SELECT d.contract_number, ns.n, d.month_since_default AS m,
--              d.month_since_default
--                - ROW_NUMBER() OVER (PARTITION BY d.contract_number, ns.n ORDER BY d.month_since_default) AS grp
--       FROM [CL_PORTFOLIO].[dbo].[STAGE3_CURE_POOL_DPD_20260701] d CROSS JOIN ns
--       WHERE ISNULL(d.[dpd],0) <= ns.n ),
--   runs AS (SELECT contract_number,n,COUNT(*) run_len FROM clean GROUP BY contract_number,n,grp),
--   cured AS (SELECT DISTINCT contract_number,n FROM runs WHERE run_len >= @CleanMonths)
--   SELECT cu.n AS dpd_tolerance, COUNT(*) AS curable_loans,
--          SUM(h.balance) AS curable_balance, SUM(h.balance)/1e9 AS curable_balance_bn,
--          SUM(h.provisions_total) AS provisions_released
--   FROM cured cu JOIN [CL_PORTFOLIO].[dbo].[STAGE3_CURE_POOL_HEAD_20260701] h
--        ON h.contract_number = cu.contract_number
--   GROUP BY cu.n ORDER BY cu.n;

-------------------------------------------------------------------------------
-- Notes
-------------------------------------------------------------------------------
-- * Staging tables persist for repeated deeper analysis; DROP them when done, or
--   replace the two SELECT…INTO targets with #temp tables for a session only.
-- * Anchor is default_date; if a dedicated cure/health date should anchor the
--   window instead, swap it in §2.
-- * def+k = DATEDIFF(MONTH, default_date, snap) can exceed 12 for older defaults
--   (long form has no 12-column limit); horizon is capped at @AsOf.
-- * dpd shown raw (NULL preserved in the pool); analysis (B) treats NULL as
--   «без просрочки» via ISNULL(dpd,0) — flip to `dpd IS NOT NULL` to exclude.
--   Mind the S03 dpd off-by-one. S03 (CrediLogic) only — repeat per source.
