/* =============================================================================
   ПРОСТЫМ ЯЗЫКОМ:
   Между снимками на 01.12.2025 и 01.01.2026 пул 3-й стадии (для скрипта
   безопасной зоны) упал почти вдвое: 54 088 → 28 668 займов, и НЕ равномерно —
   займы БЕЗ реструктуризации пропали на 70%, а с реструктуризацией — на 34%.
   Этот скрипт ищет причину:
     1) Строим множество «ушедших» займов (были в пуле на 01.12.2025, но не на
        01.01.2026) и смотрим, ЧТО с ними случилось на 01.01.2026 по самой
        CL_PORTFOLIO_2 — исчезли совсем / стали tag=11 (списаны — наше же
        условие ИСКЛЮЧАЕТ их из пула, это не обязательно значит, что займ
        реально пропал из банка) / сменилась категория (излечились/
        реклассифицированы) / необъяснимо (нужно смотреть отдельно).
     2) Сверяем «ушедших» с объёмом списаний (KAN_write_off_AQR) и продаж
        (KAN_sale_KA_AQR) за последние ~2 недели декабря 2025 — и в целом по
        банку, и именно среди «ушедших» займов.
   ⚠ KAN_write_off_AQR / KAN_sale_KA_AQR имеют суффикс «_AQR» — как и
   AQR20XX_B1A/B1B/B3C таблицы, это МОГУТ быть точечные выгрузки под конкретный
   цикл AQR, а не непрерывно обновляемый операционный журнал. §5 добавляет
   схему-разведку по spis_v_ubytok_RS / SOLD_PORTFOLIO_FOR_LGD как более
   «живую» альтернативу, если объёмы из §3/§4 не объясняют разрыв.
   §7/§8 — прямая наводка: [CL_PORTFOLIO].[dbo].[Prodaja&Proschenie_12_2025]
   («Продажа & Прощение», декабрь 2025) — похоже на точный список декабрьских
   продаж/прощений долга, что отлично совпадает с 98.2% «ушедших» займов,
   которые просто ИСЧЕЗЛИ из CL_PORTFOLIO_2 (не tag=11, а именно исчезли).
   -----------------------------------------------------------------------------
   Investigate the Dec-2025 -> Jan-2026 Stage 3 pool drop-off (54,088 -> 28,668
   loans, non-uniform: non-restructured loans fell 70%, restructured only 34%).
   Builds the exited-loan set directly from CL_PORTFOLIO_2 and classifies each
   by what actually happened to it, then cross-checks write-off/sale volume in
   the last ~2 weeks of December against that set. T-SQL (Microsoft SQL Server).
   ============================================================================= */

DECLARE @DecAsOf     date = '2025-12-01';   -- pool snapshot that shows the drop
DECLARE @JanAsOf     date = '2026-01-01';   -- pool snapshot after the drop
DECLARE @WindowStart date = '2025-12-15';   -- "last ~2 weeks of December"
DECLARE @WindowEnd   date = '2025-12-31';

-------------------------------------------------------------------------------
-- 1. Build the pools and the EXITED set (in Dec pool, not in Jan pool) —
--    same category='3'/tag<>'11' definition used everywhere else in this
--    workstream (stage3_safezone_rolling_extract.sql).
-------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..##DEC_POOL') IS NOT NULL DROP TABLE ##DEC_POOL;
SELECT contract_number, [balance], [provisions_total]
INTO ##DEC_POOL
FROM [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2]
WHERE [date] = @DecAsOf AND [category] = '3' AND ISNULL([tag], '') <> '11';

IF OBJECT_ID('tempdb..##JAN_POOL') IS NOT NULL DROP TABLE ##JAN_POOL;
SELECT contract_number
INTO ##JAN_POOL
FROM [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2]
WHERE [date] = @JanAsOf AND [category] = '3' AND ISNULL([tag], '') <> '11';

IF OBJECT_ID('tempdb..##EXITED') IS NOT NULL DROP TABLE ##EXITED;
SELECT d.contract_number, d.[balance], d.[provisions_total]
INTO ##EXITED
FROM ##DEC_POOL d
LEFT JOIN ##JAN_POOL j ON j.contract_number = d.contract_number
WHERE j.contract_number IS NULL;

SELECT COUNT(*) AS exited_loans, SUM([balance]) AS exited_balance,
       SUM([provisions_total]) AS exited_provisions
FROM ##EXITED;

-------------------------------------------------------------------------------
-- 2. Classify every exited loan by what CL_PORTFOLIO_2 shows for it on
--    @JanAsOf — the loan may still have a row there even though it dropped
--    out of the POOL (e.g. tag flipped to 11).
-------------------------------------------------------------------------------
;WITH classified AS (
    SELECT
        e.contract_number, e.[balance], e.[provisions_total],
        jan.[category] AS jan_category, jan.[tag] AS jan_tag,
        CASE
            WHEN jan.contract_number IS NULL THEN N'GONE — no row in CL_PORTFOLIO_2 at all on 01.01.2026'
            WHEN ISNULL(jan.[tag], '') = '11' THEN N'WRITTEN OFF (tag=11) — pool exclusion rule, still on balance sheet'
            WHEN jan.[category] <> '3' THEN N'CATEGORY CHANGED — reclassified out of Stage 3'
            ELSE N'UNEXPLAINED — still category=3, tag<>11; investigate individually'
        END AS exit_reason
    FROM ##EXITED e
    LEFT JOIN [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2] jan
        ON jan.contract_number = e.contract_number AND jan.[date] = @JanAsOf
)
SELECT exit_reason, COUNT(*) AS loans, SUM([balance]) AS balance, SUM([provisions_total]) AS provisions
FROM classified
GROUP BY exit_reason
ORDER BY loans DESC;

-------------------------------------------------------------------------------
-- 3. Write-off volume — overall in the window, and restricted to the exited
--    Stage 3 set (does write-off activity actually cover these loans?).
-------------------------------------------------------------------------------
SELECT COUNT(*) AS writeoffs_in_window, COUNT(DISTINCT [CONTRACT_NUMBER]) AS distinct_contracts
FROM [CL_PORTFOLIO].[dbo].[KAN_write_off_AQR]
WHERE [Write_off_date] >= @WindowStart AND [Write_off_date] <= @WindowEnd;

SELECT COUNT(*) AS exited_and_written_off, SUM(e.[balance]) AS balance
FROM ##EXITED e
JOIN [CL_PORTFOLIO].[dbo].[KAN_write_off_AQR] w
    ON w.[CONTRACT_NUMBER] = e.contract_number
WHERE w.[Write_off_date] >= @WindowStart AND w.[Write_off_date] <= @WindowEnd;

-------------------------------------------------------------------------------
-- 4. Sale volume — same pattern, KAN_sale_KA_AQR.
-------------------------------------------------------------------------------
SELECT COUNT(*) AS sales_in_window, COUNT(DISTINCT contract_number) AS distinct_contracts,
       SUM([discount]) AS total_discount
FROM [CL_PORTFOLIO].[dbo].[KAN_sale_KA_AQR]
WHERE [sale_date] >= @WindowStart AND [sale_date] <= @WindowEnd;

SELECT COUNT(*) AS exited_and_sold, SUM(e.[balance]) AS balance
FROM ##EXITED e
JOIN [CL_PORTFOLIO].[dbo].[KAN_sale_KA_AQR] s
    ON s.contract_number = e.contract_number
WHERE s.[sale_date] >= @WindowStart AND s.[sale_date] <= @WindowEnd;

-------------------------------------------------------------------------------
-- 5. Fallback discovery — only run if §3/§4 don't explain most of the drop.
--    schema of two more candidate ledgers referenced elsewhere in this repo
--    (spis_v_ubytok_RS in b3b_writeoff_qc_check.sql; SOLD_PORTFOLIO_FOR_LGD
--    in b3b_reconciliation_2025.sql) — neither has a confirmed date column yet.
-------------------------------------------------------------------------------
SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE
FROM [CL_PORTFOLIO].INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME IN ('spis_v_ubytok_RS', 'SOLD_PORTFOLIO_FOR_LGD')
ORDER BY TABLE_NAME, ORDINAL_POSITION;

-------------------------------------------------------------------------------
-- 6. Summary — does write-off + sale volume among the exited set add up to
--    the total exited count? Whatever's left over is §2's "GONE"/"UNEXPLAINED"
--    buckets not covered by either ledger — worth a closer look.
-------------------------------------------------------------------------------
SELECT
    (SELECT COUNT(*) FROM ##EXITED) AS total_exited,
    (SELECT COUNT(*) FROM ##EXITED e JOIN [CL_PORTFOLIO].[dbo].[KAN_write_off_AQR] w
        ON w.[CONTRACT_NUMBER] = e.contract_number
        WHERE w.[Write_off_date] >= @WindowStart AND w.[Write_off_date] <= @WindowEnd) AS covered_by_writeoff,
    (SELECT COUNT(*) FROM ##EXITED e JOIN [CL_PORTFOLIO].[dbo].[KAN_sale_KA_AQR] s
        ON s.contract_number = e.contract_number
        WHERE s.[sale_date] >= @WindowStart AND s.[sale_date] <= @WindowEnd) AS covered_by_sale;

-------------------------------------------------------------------------------
-- 7. Direct lead: Prodaja&Proschenie_12_2025 ("Продажа & Прощение" = sale &
--    forgiveness, December 2025) — sounds like exactly a December sale/
--    forgiveness batch list. Schema first (name unconfirmed beyond what the
--    "&" in the table name implies — two categories in one table?).
-------------------------------------------------------------------------------
SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH, ORDINAL_POSITION
FROM [CL_PORTFOLIO].INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'Prodaja&Proschenie_12_2025'
ORDER BY ORDINAL_POSITION;

SELECT TOP (20) * FROM [CL_PORTFOLIO].[dbo].[Prodaja&Proschenie_12_2025];

-------------------------------------------------------------------------------
-- 8. Cross-check against the GONE population (§2). ⚠ ADJUST [contract_number]
--    to whatever §7 shows as the real loan-id column — this is a guess based
--    on the convention used everywhere else in CL_PORTFOLIO. Same for a
--    reason/type column if you want to split sale vs forgiveness counts.
-------------------------------------------------------------------------------
;WITH gone AS (
    SELECT e.contract_number, e.[balance]
    FROM ##EXITED e
    LEFT JOIN [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2] jan
        ON jan.contract_number = e.contract_number AND jan.[date] = @JanAsOf
    WHERE jan.contract_number IS NULL   -- the 26,887 "GONE — no row at all" bucket from §2
)
SELECT COUNT(*) AS gone_and_in_prodaja_proschenie, SUM(g.[balance]) AS balance
FROM gone g
JOIN [CL_PORTFOLIO].[dbo].[Prodaja&Proschenie_12_2025] pp
    ON pp.[contract_number] = g.contract_number;   -- ⚠ confirm real column name from §7

-------------------------------------------------------------------------------
-- Notes
-------------------------------------------------------------------------------
-- * @WindowStart/@WindowEnd cover the last ~2 weeks of December 2025 per the
--   hypothesis (year-end AQR/audited-year cleanup) — widen if §6's coverage
--   is low, in case the activity is spread across more of December.
-- * §2's "WRITTEN OFF (tag=11)" bucket matters for methodology: those loans
--   are still on CL_PORTFOLIO_2, just excluded by OUR pool definition — not
--   necessarily evidence the bank actually wrote them off that week. Cross-
--   reference against §3 to confirm the tag flip corresponds to a real
--   KAN_write_off_AQR event, not just a tag update on its own.
-- * If §6's covered_by_writeoff + covered_by_sale is well short of
--   total_exited, the explanation is probably NOT write-off/sale at all —
--   check §8 next (Prodaja&Proschenie_12_2025 is the strongest lead so far:
--   98.2% of exits vanished from CL_PORTFOLIO_2 entirely rather than being
--   tag-flagged, which fits a sale/forgiveness batch that removes the row
--   outright), or consider a category/methodology change effective 01.01.2026
--   rather than a portfolio event if §8 also comes up short.
