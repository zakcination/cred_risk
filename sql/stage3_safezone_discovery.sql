/* =============================================================================
   ПРОСТЫМ ЯЗЫКОМ:
   Перед тем как строить 12-месячную симуляцию «безопасной зоны» DPD и считать
   re-default rate, нужно решить, ИЗ КАКОЙ таблицы брать «дата окончания
   реструктуры» на каждую из 12 отчётных дат. Ваш поиск по ключевым словам
   (0b в stage3_raw_extract.sql) нашёл НЕСКОЛЬКО кандидатов вместо одного:
     • KAN_20260601_for_LGD_Fenix          — уже используется (июнь 2026)
     • KAN_20250301_for_LGD_Fenix_DI_BI    — та же семья, март 2025 (другой суффикс!)
     • kan_0101_rus / kan_0106_rus         — Restructuring_End_Date, Max_Restructuring_Actual
     • Реструктуризация_RS$                — RS: журнал событий (FIELD_NAME/FIELD_VALUE)
     • AQR20xx_B1A/B1B/B3C_* (много копий)  — RESTR_DATE/RESTR_COUNT — это
       ЗАМОРОЖЕННЫЕ регуляторные выгрузки прошлых циклов AQR, часто с версиями
       (_v1, _V1_08042026) — НЕ использовать как «сырой» операционный источник:
       не факт, что совпадает по значениям с текущей CL_PORTFOLIO_2, и не месячные.
   Ни «период приостановки», ни «отмена реструктуризации» ни в одной таблице
   пока НЕ найдены. Этот скрипт не считает ничего — только профилирует
   кандидатов (сколько строк, сколько заполнено, диапазон дат) и ищет
   suspension/cancellation в RS-журнале событий, чтобы выбрать источник
   осознанно, а не наугад.
   -----------------------------------------------------------------------------
   Disambiguation discovery — profile the restructuring-end-date candidates
   surfaced by stage3_raw_extract.sql §0b before committing to one for the
   12-month DPD safe-zone / re-default simulation. No AQR quarterly exports —
   those are frozen regulatory snapshots, not a live monthly operational feed.
   T-SQL (Microsoft SQL Server).
   ============================================================================= */

-------------------------------------------------------------------------------
-- 1. Enumerate every KAN/kan-named table (both DBs) — is there really one per
--    month for a trailing 12-month window, or only the two we've spotted?
-------------------------------------------------------------------------------
SELECT t.name AS table_name, c.name AS column_name, ty.name AS data_type
FROM [IFRS9].sys.tables t
JOIN [IFRS9].sys.columns c ON c.object_id = t.object_id
JOIN [IFRS9].sys.types   ty ON ty.user_type_id = c.user_type_id
WHERE t.name LIKE 'KAN[_]%' OR t.name LIKE 'kan[_]%'
ORDER BY t.name, c.column_id;

SELECT t.name AS table_name, c.name AS column_name, ty.name AS data_type
FROM [CL_PORTFOLIO].sys.tables t
JOIN [CL_PORTFOLIO].sys.columns c ON c.object_id = t.object_id
JOIN [CL_PORTFOLIO].sys.types   ty ON ty.user_type_id = c.user_type_id
WHERE t.name LIKE 'KAN[_]%' OR t.name LIKE 'kan[_]%'
ORDER BY t.name, c.column_id;

-------------------------------------------------------------------------------
-- 2. Profile the 4 known candidates: row count, how many have a restructuring
--    end date at all, and the date's own range (sanity: does it look like a
--    real per-snapshot value, or a stale/frozen one?).
--    ⚠ DB prefixes are a GUESS based on where the naming pattern matches the
--    already-confirmed table (KAN_* → IFRS9, kan_*_rus → CL_PORTFOLIO). If a
--    line errors with "invalid object name", move it to the other DB and re-run.
-------------------------------------------------------------------------------
SELECT 'KAN_20260601_for_LGD_Fenix' AS source_table,
       COUNT(*)                                       AS rows_total,
       COUNT([дата окончания реструктуры])             AS rows_with_restr_end_date,
       MIN([дата окончания реструктуры])                AS min_date,
       MAX([дата окончания реструктуры])                AS max_date
FROM [IFRS9].[dbo].[KAN_20260601_for_LGD_Fenix]
UNION ALL
SELECT 'KAN_20250301_for_LGD_Fenix_DI_BI',
       COUNT(*), COUNT([дата окончания реструктуры]),
       MIN([дата окончания реструктуры]), MAX([дата окончания реструктуры])
FROM [IFRS9].[dbo].[KAN_20250301_for_LGD_Fenix_DI_BI]
UNION ALL
SELECT 'kan_0101_rus',
       COUNT(*), COUNT([Restructuring_End_Date]),
       MIN([Restructuring_End_Date]), MAX([Restructuring_End_Date])
FROM [CL_PORTFOLIO].[dbo].[kan_0101_rus]
UNION ALL
SELECT 'kan_0106_rus',
       COUNT(*), COUNT([Restructuring_End_Date]),
       MIN([Restructuring_End_Date]), MAX([Restructuring_End_Date])
FROM [CL_PORTFOLIO].[dbo].[kan_0106_rus];

-------------------------------------------------------------------------------
-- 3. Hunt for suspension-period / cancellation inside the RS restructuring
--    EVENT log (one row per field change — FIELD_NAME/FIELD_VALUE pairs).
--    If a "приостан.../suspens.../моратор.../отмен.../cancel..." value shows
--    up here, this table is the raw per-event source for §4 of
--    stage3_raw_extract.sql (RS-sourced loans only — Fenix/CL would need
--    their own equivalent, if one exists).
-------------------------------------------------------------------------------
SELECT DISTINCT [FIELD_NAME]
FROM [CL_PORTFOLIO].[dbo].[Реструктуризация_RS$]
ORDER BY [FIELD_NAME];

-------------------------------------------------------------------------------
-- 4. [Dictionaries] mart — only run if it appeared in §0c's sys.databases
--    list (stage3_raw_extract.sql). `restructuring_v2` is documented as an
--    EVENT table (one row per restructuring event) — exactly the shape
--    needed for "last restructurization" + "cancellation", covering all
--    source systems at once, if this login can actually reach it.
-------------------------------------------------------------------------------
SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE
FROM [Dictionaries].INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'restructuring_v2'
ORDER BY ORDINAL_POSITION;

-------------------------------------------------------------------------------
-- Notes
-------------------------------------------------------------------------------
-- * Goal: pick ONE restructuring-end-date source with (a) full coverage across
--   the trailing 12 report months and (b) a low NULL rate, before the 12-month
--   safe-zone/re-default simulation is built on top of it. Whichever of §1-4
--   wins, the actual monthly loan-by-loan extract (mirroring stage3_
--   raw_extract.sql's pattern, one raw SELECT * per @AsOf) comes next.
-- * Nothing here computes a threshold or a re-default rate yet — that's
--   blocked on picking the source (this script) plus two methodology calls
--   (restructuring-covered clean months in/out of the safe-zone pool; re-default
--   monitoring horizon) that are the analyst's call, not a data question.
