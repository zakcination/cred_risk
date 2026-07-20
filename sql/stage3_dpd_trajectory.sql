/* =============================================================================
   ПРОСТЫМ ЯЗЫКОМ:
   По каждому займу 3-й стадии показываем просрочку (dpd) по месяцам после даты
   дефолта — колонки def+1 … def+12 (видно, как заёмщик платил после дефолта).
   Затем считаем, сколько займов «оздоровилось» бы при мягком правиле: 6 месяцев
   подряд с просрочкой ≤ n дней (n = 0 строго / 1 / 3 / 7 / 10).
   ---------------------------------------------------------------------------
   Stage 3 post-default DPD trajectory — dpd at each of the 12 months after the
   default date, per contract (def+1 … def+12). CrediLogic / S03.
   =============================================================================
   For every Stage-3 loan (CL_PORTFOLIO_2, date=@AsOf, category='3', tag<>'11')
   pull its DPD from the monthly snapshots at 1..12 months AFTER its default date,
   pivoted into columns def+1 … def+12. This shows the cure / re-default path:
   who paid down and stayed clean, who slipped a little, who re-defaulted.

   DPD source: [CL_PORTFOLIO_2] (monthly snapshots, per contract).
   Month index: m = DATEDIFF(MONTH, default_date, snap_date), i.e. reporting
   months after default (snapshots are first-of-month, so m=1 is the first
   month-end reported after the default event).

   T-SQL (Microsoft SQL Server).
   ============================================================================= */

DECLARE @AsOf date = '2026-07-01';

;WITH stage3 AS (
    SELECT
        a.contract_number,
        a.[balance],
        a.[provisions_total],
        a.[dpd]                                       AS dpd_asof,
        COALESCE(b.default_date, c.default_date)      AS default_date,
        c.[дата окончания реструктуры]                AS restr_end_date
    FROM [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2] a
    LEFT JOIN [CL_PORTFOLIO].[dbo].[HISTORY_DEFAULT_ACCOUNT] b
        ON a.contract_number = b.account_number
    LEFT JOIN [IFRS9].[dbo].[KAN_20260601_for_LGD_Fenix] c
        ON a.contract_number = c.account_number
    WHERE a.[date] = @AsOf
      AND a.[category] = '3'
      AND ISNULL(a.[tag], '') <> '11'
),
traj AS (   -- every post-default monthly snapshot, tagged with months-since-default
    SELECT
        s.contract_number,
        DATEDIFF(MONTH, s.default_date, p.[date]) AS m,
        p.[dpd]
    FROM stage3 s
    JOIN [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2] p
        ON p.contract_number = s.contract_number
    WHERE s.default_date IS NOT NULL
      AND DATEDIFF(MONTH, s.default_date, p.[date]) BETWEEN 1 AND 12
),
pivoted AS (
    SELECT contract_number,
        MAX(CASE WHEN m = 1  THEN dpd END) AS [def+1],
        MAX(CASE WHEN m = 2  THEN dpd END) AS [def+2],
        MAX(CASE WHEN m = 3  THEN dpd END) AS [def+3],
        MAX(CASE WHEN m = 4  THEN dpd END) AS [def+4],
        MAX(CASE WHEN m = 5  THEN dpd END) AS [def+5],
        MAX(CASE WHEN m = 6  THEN dpd END) AS [def+6],
        MAX(CASE WHEN m = 7  THEN dpd END) AS [def+7],
        MAX(CASE WHEN m = 8  THEN dpd END) AS [def+8],
        MAX(CASE WHEN m = 9  THEN dpd END) AS [def+9],
        MAX(CASE WHEN m = 10 THEN dpd END) AS [def+10],
        MAX(CASE WHEN m = 11 THEN dpd END) AS [def+11],
        MAX(CASE WHEN m = 12 THEN dpd END) AS [def+12]
    FROM traj
    GROUP BY contract_number
)
SELECT
    s.contract_number,
    s.default_date,
    s.restr_end_date               AS [дата окончания реструктуры],
    s.balance,
    s.provisions_total,
    s.dpd_asof,
    p.[def+1],  p.[def+2],  p.[def+3],  p.[def+4],  p.[def+5],  p.[def+6],
    p.[def+7],  p.[def+8],  p.[def+9],  p.[def+10], p.[def+11], p.[def+12]
FROM stage3 s
LEFT JOIN pivoted p ON p.contract_number = s.contract_number
ORDER BY s.contract_number;


-------------------------------------------------------------------------------
-- (2) СКОЛЬКО ЗАЙМОВ «ОЗДОРОВИЛОСЬ» БЫ при мягком правиле.
--     Правило: есть 6 месяцев ПОДРЯД с просрочкой dpd ≤ n (после дефолта).
--     n = 0 — текущее строгое правило (база); n = 1/3/7/10 — смягчения.
--     Прирост от смягчения = (строка n) − (строка 0).
-------------------------------------------------------------------------------
DECLARE @CleanMonths int = 6;   -- сколько чистых месяцев подряд нужно для cure

;WITH stage3 AS (
    SELECT a.contract_number, a.[balance], a.[provisions_total],
           COALESCE(b.default_date, c.default_date) AS default_date
    FROM [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2] a
    LEFT JOIN [CL_PORTFOLIO].[dbo].[HISTORY_DEFAULT_ACCOUNT] b ON a.contract_number = b.account_number
    LEFT JOIN [IFRS9].[dbo].[KAN_20260601_for_LGD_Fenix]      c ON a.contract_number = c.account_number
    WHERE a.[date] = @AsOf AND a.[category] = '3' AND ISNULL(a.[tag],'') <> '11'
),
traj AS (
    SELECT s.contract_number, DATEDIFF(MONTH, s.default_date, p.[date]) AS m, p.[dpd]
    FROM stage3 s
    JOIN [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2] p ON p.contract_number = s.contract_number
    WHERE s.default_date IS NOT NULL AND DATEDIFF(MONTH, s.default_date, p.[date]) BETWEEN 1 AND 12
),
ns(n) AS ( SELECT n FROM (VALUES (0),(1),(3),(7),(10)) v(n) ),
-- «чистые» месяцы (dpd ≤ n); islands of consecutive months via (m − ROW_NUMBER())
clean AS (
    SELECT t.contract_number, ns.n, t.m,
           t.m - ROW_NUMBER() OVER (PARTITION BY t.contract_number, ns.n ORDER BY t.m) AS grp
    FROM traj t CROSS JOIN ns
    WHERE ISNULL(t.[dpd], 0) <= ns.n          -- NULL dpd = «без просрочки» (см. заметку)
),
runs AS (
    SELECT contract_number, n, COUNT(*) AS run_len
    FROM clean GROUP BY contract_number, n, grp
),
cured AS (
    SELECT DISTINCT contract_number, n FROM runs WHERE run_len >= @CleanMonths
)
SELECT
    cu.n                       AS dpd_tolerance,      -- 0 = строго
    COUNT(*)                   AS curable_loans,
    SUM(s.balance)             AS curable_balance,
    SUM(s.balance)/1e9         AS curable_balance_bn,
    SUM(s.provisions_total)    AS provisions_released
FROM cured cu
JOIN stage3 s ON s.contract_number = cu.contract_number
GROUP BY cu.n
ORDER BY cu.n;
-- Прирост «оздоровлённых» от смягчения правила до n дней = (curable at n) − (curable at 0).

-------------------------------------------------------------------------------
-- Notes
-------------------------------------------------------------------------------
-- * m = DATEDIFF(MONTH, default_date, snap_date) counts reporting months (month
--   boundaries) after default; with first-of-month snapshots, def+1 is the first
--   month-end after the default event. Adjust to '> default_date' month if you
--   want strictly-elapsed months.
-- * dpd is shown RAW (NULL = no snapshot / no data that month; not forced to 0),
--   so the trajectory reflects the actual reported pattern. Mind the S03 dpd
--   off-by-one (dpd = days_past_due − 1) and NULL-heaviness when reading it.
-- * default_date = COALESCE(HISTORY_DEFAULT_ACCOUNT, IFRS9 LGD) — confirm the
--   canonical source for CL; rows with NULL default_date get NULL def+k.
-- * S03 (CrediLogic) only; repeat per source for the whole book.
-- * On this trajectory you can compute cure/re-default directly, e.g. MAX over
--   def+1..def+6 ≤ n (relaxed clean window) — the sustained version of the
--   snapshot funnel in stage3_cure_funnel.sql.
