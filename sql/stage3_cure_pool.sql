/* =============================================================================
   ПРОСТЫМ ЯЗЫКОМ:
   Собираем «пул» для анализа оздоровления. Берём непустые (с датой дефолта)
   займы 3-й стадии на 01.07.2026 (category=3, без списанных tag=11), тянем дату
   дефолта, дату оздоровления (health_date2) и дату реструктуризации. Затем по
   каждому займу вытягиваем просрочку (dpd) ПОМЕСЯЧНО за каждый месяц с 01.01.2026
   до последней доступной отчётной даты (≤ 01.07.2026). Пул сохраняем отдельными
   таблицами (шапка + помесячная просрочка), чтобы дальше отдельно по нему считать
   смягчение правил (dpd ≤ n).
   -----------------------------------------------------------------------------
   Stage 3 cure POOL builder — head row per contract (default / cure / restr
   dates) + a monthly DPD panel over the CALENDAR window @MonthFrom … @AsOf.

   Output tables (staging — drop when done, or swap to #temp):
     STAGE3_CURE_POOL_HEAD_20260701  — one row per contract (the report "bone")
     STAGE3_CURE_POOL_DPD_20260701   — long form: one row per contract × month
   T-SQL (Microsoft SQL Server).
   ============================================================================= */

DECLARE @AsOf      date = '2026-07-01';   -- reporting / as-of date (last available)
DECLARE @MonthFrom date = '2026-01-01';   -- monthly DPD panel starts here

-------------------------------------------------------------------------------
-- 1. Шапка пула — одна строка на контракт (скелет отчёта + даты).
--    Только непустые: default_date IS NOT NULL.  health_date2 = дата оздоровления.
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
    c.[health_date2]                          AS cure_date,          -- дата оздоровления
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
-- 2. Помесячная просрочка по пулу — КАЛЕНДАРНАЯ сетка @MonthFrom … @AsOf.
--    month_idx     = месяц окна (0 = @MonthFrom, 1, 2, …), для «6 подряд».
--    month_since_default (def+k) — справочно, относительно даты дефолта.
-------------------------------------------------------------------------------
IF OBJECT_ID('[CL_PORTFOLIO].[dbo].[STAGE3_CURE_POOL_DPD_20260701]','U') IS NOT NULL
    DROP TABLE [CL_PORTFOLIO].[dbo].[STAGE3_CURE_POOL_DPD_20260701];

SELECT
    h.contract_number,
    h.default_date,
    p.[date]                                     AS snap_date,
    DATEDIFF(MONTH, @MonthFrom, p.[date])        AS month_idx,             -- 0..N in the window
    DATEDIFF(MONTH, h.default_date, p.[date])    AS month_since_default,   -- def+k (ref)
    p.[dpd],
    p.[balance]                                  AS balance_m,
    p.[category]                                 AS category_m
INTO [CL_PORTFOLIO].[dbo].[STAGE3_CURE_POOL_DPD_20260701]
FROM [CL_PORTFOLIO].[dbo].[STAGE3_CURE_POOL_HEAD_20260701] h
JOIN [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2] p
    ON p.contract_number = h.contract_number
WHERE p.[date] >= @MonthFrom
  AND p.[date] <= @AsOf;                                     -- 01.01.2026 → last available

-------------------------------------------------------------------------------
-- 3. Проверка объёма пула
-------------------------------------------------------------------------------
SELECT
    (SELECT COUNT(*)              FROM [CL_PORTFOLIO].[dbo].[STAGE3_CURE_POOL_HEAD_20260701]) AS pool_contracts,
    (SELECT COUNT(*)              FROM [CL_PORTFOLIO].[dbo].[STAGE3_CURE_POOL_DPD_20260701])  AS pool_month_rows,
    (SELECT COUNT(DISTINCT snap_date) FROM [CL_PORTFOLIO].[dbo].[STAGE3_CURE_POOL_DPD_20260701]) AS months_in_window,
    (SELECT SUM(balance)          FROM [CL_PORTFOLIO].[dbo].[STAGE3_CURE_POOL_HEAD_20260701]) AS pool_balance,
    (SELECT SUM(provisions_total) FROM [CL_PORTFOLIO].[dbo].[STAGE3_CURE_POOL_HEAD_20260701]) AS pool_provisions;


/* =============================================================================
   DEEPER ANALYSIS on the pool (run separately on the staging tables)
   ============================================================================= */

-- (A) Per-contract DPD stats over the calendar window.
--   SELECT d.contract_number, h.default_date, h.cure_date, h.restr_end_date,
--          h.balance, h.provisions_total, h.dpd_asof,
--          COUNT(*) AS months_observed, MAX(d.[dpd]) AS max_dpd,
--          SUM(CASE WHEN d.[dpd] > 0 THEN 1 ELSE 0 END) AS months_overdue
--   FROM [CL_PORTFOLIO].[dbo].[STAGE3_CURE_POOL_DPD_20260701] d
--   JOIN [CL_PORTFOLIO].[dbo].[STAGE3_CURE_POOL_HEAD_20260701] h ON h.contract_number=d.contract_number
--   GROUP BY d.contract_number, h.default_date, h.cure_date, h.restr_end_date,
--            h.balance, h.provisions_total, h.dpd_asof;

-- (B) Calendar pivot — DPD by month (Jan..Jul 2026).
--   SELECT contract_number,
--          MAX(CASE WHEN month_idx=0 THEN [dpd] END) AS [2026-01],
--          MAX(CASE WHEN month_idx=1 THEN [dpd] END) AS [2026-02],
--          MAX(CASE WHEN month_idx=2 THEN [dpd] END) AS [2026-03],
--          MAX(CASE WHEN month_idx=3 THEN [dpd] END) AS [2026-04],
--          MAX(CASE WHEN month_idx=4 THEN [dpd] END) AS [2026-05],
--          MAX(CASE WHEN month_idx=5 THEN [dpd] END) AS [2026-06],
--          MAX(CASE WHEN month_idx=6 THEN [dpd] END) AS [2026-07]
--   FROM [CL_PORTFOLIO].[dbo].[STAGE3_CURE_POOL_DPD_20260701]
--   GROUP BY contract_number;

-- (C) Relaxed-cure count: @CleanMonths consecutive calendar months at dpd ≤ n,
--     n ∈ {0,1,3,7,10}. n=0 = strict; increment over 0 = loans stuck by slips.
--   DECLARE @CleanMonths int = 6;
--   ;WITH ns(n) AS (SELECT n FROM (VALUES(0),(1),(3),(7),(10)) v(n)),
--   clean AS (
--       SELECT d.contract_number, ns.n, d.month_idx
--              - ROW_NUMBER() OVER (PARTITION BY d.contract_number, ns.n ORDER BY d.month_idx) AS grp
--       FROM [CL_PORTFOLIO].[dbo].[STAGE3_CURE_POOL_DPD_20260701] d CROSS JOIN ns
--       WHERE ISNULL(d.[dpd],0) <= ns.n ),
--   runs AS (SELECT contract_number,n,COUNT(*) run_len FROM clean GROUP BY contract_number,n,grp),
--   cured AS (SELECT DISTINCT contract_number,n FROM runs WHERE run_len >= @CleanMonths)
--   SELECT cu.n AS dpd_tolerance, COUNT(*) AS curable_loans,
--          SUM(h.balance) AS curable_balance, SUM(h.balance)/1e9 AS curable_balance_bn,
--          SUM(h.provisions_total) AS provisions_released
--   FROM cured cu JOIN [CL_PORTFOLIO].[dbo].[STAGE3_CURE_POOL_HEAD_20260701] h
--        ON h.contract_number=cu.contract_number
--   GROUP BY cu.n ORDER BY cu.n;

-------------------------------------------------------------------------------
-- Notes
-------------------------------------------------------------------------------
-- * DPD window is CALENDAR (@MonthFrom … @AsOf), monthly. With ~7 months of data,
--   a 6-consecutive-clean rule (C) is tight — lower @CleanMonths or widen
--   @MonthFrom to test looser windows. `month_since_default` is kept for
--   default-relative (def+k) analysis.
-- * cure_date = health_date2 (дата оздоровления); use it to validate that loans
--   the rule marks curable line up with recorded cures, and to measure lag.
-- * "non-null" pool = default_date IS NOT NULL; drop that line to keep all Stage 3.
-- * dpd NULL preserved in the pool; analysis (C) treats NULL as «без просрочки»
--   (ISNULL(dpd,0)) — flip to `dpd IS NOT NULL` to exclude. Mind the S03 dpd
--   off-by-one. S03 (CrediLogic) only — repeat per source.
