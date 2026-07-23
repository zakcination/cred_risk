/* =============================================================================
   ПРОСТЫМ ЯЗЫКОМ:
   Сырьё для симуляции «безопасной зоны» DPD и re-default rate за 12 отчётных
   месяцев (MMYYYYPORTFOLIO). Три сырых выгрузки:
     0) Лестница из 12 отчётных дат, заканчивающаяся @LastAsOf.
     1) Пул 3-й стадии (category=3, без tag=11) на КАЖДУЮ из 12 дат — SELECT *,
        с меткой portfolio_label/portfolio_asof, чтобы в pandas разложить по
        месяцам.
     2) Один общий сырой помесячный «пласт» (dpd, category, balance, tag) по
        ВСЕМ контрактам, попавшим хоть в один из 12 пулов — от 6 месяцев до
        САМОЙ РАННЕЙ отчётной даты (запас назад для окна из 6 чистых месяцев)
        и до @LastAsOf (запас вперёд — мониторить re-default). Не 12 отдельных
        выгрузок — один плоский лист, а разложение по (портфель, смещение)
        делаете в Python.
     3) Справочная запись по реструктуризации — теперь из подтверждённого
        источника [Dictionaries].[risk_analytics].[restructuring_v2] (журнал
        СОБЫТИЙ реструктуризации по ВСЕМ источникам, найден через discovery-
        скрипт 23.07.2026). Именно здесь лежат ранее не найденные период
        приостановки (grace_od_*/grace_int_*) и дата отмены реструктуризации
        (canc_date) — SELECT * без фильтра «последняя запись», раскладку по
        (портфель, контракт) делаете в Python.

   Зафиксированные решения по методологии (для трассируемости — считать всё
   равно в Python, тут только сырые данные):
     • Месяцы, покрытые активной реструктуризацией (snap_date ≤ дата окончания
       реструктуры), НЕ исключаются из пула — остаются, но нужно посчитать
       restr_active_pct и сравнить re-default rate реструктурированных vs нет.
     • re-default = первый ПОСЛЕ пула месяц, где category снова = '3', по
       ЛЮБОЙ причине (не только dpd≥91) — считается по первому попаданию, без
       требования подряд идущих месяцев.
     • Гипотеза 2 (нисходящий тренд): строго монотонное невозрастание dpd по
       всем 6 месяцам окна (dpd(m-6) ≥ dpd(m-5) ≥ … ≥ dpd(m-1)).
   -----------------------------------------------------------------------------
   Raw extracts for the 12-month DPD safe-zone / re-default simulation. No
   derived columns beyond the report-date ladder itself; all threshold/streak/
   re-default logic happens downstream in pandas. T-SQL (Microsoft SQL Server).
   ============================================================================= */

DECLARE @LastAsOf   date = '2026-07-01';   -- latest available reporting date (anchor)
DECLARE @MonthsBack int  = 12;             -- rolling window of portfolio dates

-------------------------------------------------------------------------------
-- 0. Report-date ladder — 12 monthly anchors ending @LastAsOf, oldest first.
--    portfolio_label matches your MMYYYYPORTFOLIO naming (e.g. 072026PORTFOLIO).
-------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..##SAFEZONE_REPORT_DATES') IS NOT NULL DROP TABLE ##SAFEZONE_REPORT_DATES;

;WITH n(n) AS (
    SELECT TOP (@MonthsBack) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1
    FROM sys.all_objects
)
SELECT
    DATEADD(MONTH, -n.n, @LastAsOf)                                            AS asof_date,
    n.n                                                                        AS months_back,
    RIGHT('0' + CAST(MONTH(DATEADD(MONTH, -n.n, @LastAsOf)) AS varchar(2)), 2)
      + CAST(YEAR(DATEADD(MONTH, -n.n, @LastAsOf)) AS varchar(4)) + 'PORTFOLIO' AS portfolio_label
INTO ##SAFEZONE_REPORT_DATES
FROM n;

SELECT * FROM ##SAFEZONE_REPORT_DATES ORDER BY asof_date;

-------------------------------------------------------------------------------
-- 1. RAW Stage 3 pool at each of the 12 report dates. SELECT * — every
--    CL_PORTFOLIO_2 column, untouched, one row per (contract, portfolio_label).
-------------------------------------------------------------------------------
SELECT a.*, rd.portfolio_label, rd.asof_date AS portfolio_asof
FROM [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2] a
JOIN ##SAFEZONE_REPORT_DATES rd ON a.[date] = rd.asof_date
WHERE a.[category] = '3'
  AND ISNULL(a.[tag], '') <> '11';

-------------------------------------------------------------------------------
-- 2. RAW monthly panel — dpd/category/balance/tag for every contract that
--    appears in ANY of the 12 pools, spanning 6 months before the EARLIEST
--    portfolio date through @LastAsOf. One flat pull, not 12 separate ones.
-------------------------------------------------------------------------------
;WITH pool_contracts AS (
    SELECT DISTINCT a.contract_number
    FROM [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2] a
    JOIN ##SAFEZONE_REPORT_DATES rd ON a.[date] = rd.asof_date
    WHERE a.[category] = '3' AND ISNULL(a.[tag], '') <> '11'
),
span AS (
    SELECT DATEADD(MONTH, -6, MIN(asof_date)) AS panel_from, @LastAsOf AS panel_to
    FROM ##SAFEZONE_REPORT_DATES
)
SELECT p.contract_number, p.[date] AS snap_date, p.[dpd], p.[category], p.[balance],
       p.[balance_with_discount], p.[provisions_total], p.[tag]
FROM [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2] p
JOIN pool_contracts pc ON pc.contract_number = p.contract_number
CROSS JOIN span s
WHERE p.[date] >= s.panel_from AND p.[date] <= s.panel_to;

-------------------------------------------------------------------------------
-- 3. RAW restructuring EVENT log — [Dictionaries].[risk_analytics].
--    [restructuring_v2], confirmed reachable and multi-source (dlcr$source).
--    SELECT * — every column, every event row per contract, no "keep only
--    last" filter (do that in pandas: sort by restructuring_date/report_date,
--    groupby(loan_id).tail(1)). Has BOTH previously-missing pieces:
--      • suspension period — grace_od_begin_date/grace_od_end_date (principal),
--        grace_int_begin_date/grace_int_end_date (interest) — separate pairs.
--      • cancellation — canc_date.
--    ⚠ Join key assumed loan_id = contract_number (same assumption used
--    everywhere else cross-system in this repo) — unconfirmed, check row
--    counts below if the join looks too thin.
-------------------------------------------------------------------------------
;WITH pool_contracts AS (
    SELECT DISTINCT a.contract_number
    FROM [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2] a
    JOIN ##SAFEZONE_REPORT_DATES rd ON a.[date] = rd.asof_date
    WHERE a.[category] = '3' AND ISNULL(a.[tag], '') <> '11'
)
SELECT r.*
FROM [Dictionaries].[risk_analytics].[restructuring_v2] r
JOIN pool_contracts pc ON pc.contract_number = r.loan_id;

-------------------------------------------------------------------------------
-- Notes
-------------------------------------------------------------------------------
-- * §2's panel is intentionally over-wide (union of all 12 pools' lookback/
--   lookforward needs) — filter/reshape per portfolio_label in pandas rather
--   than re-querying per month.
-- * category is numeric-as-text in CL_PORTFOLIO_2 ('3' = Stage 3) — this IS
--   the "any Stage 3 criterion" signal for the re-default definition; no
--   separate DPD≥91 check needed once you're comparing category across months.
-- * §3's restructuring_v2 is an EVENT table — a contract can have multiple
--   rows (multiple restructurings over time). "Last restructuring as of each
--   portfolio_asof" is a pandas-side filter (restructuring_date <= asof_date,
--   keep the max), not something this raw pull decides.
-- * restr_active_pct (Phase B of the plan) should use grace_od_end_date /
--   grace_int_end_date from here instead of KAN's "дата окончания реструктуры"
--   — more precise (separate principal/interest) and from the confirmed
--   multi-source table, not a single-source monthly snapshot family.
-- * @LastAsOf caps the lookforward window for re-default monitoring — the most
--   recent portfolio dates will have little/no forward runway yet (right-
--   censoring); handle that in pandas, don't drop those rows in SQL.
