/* =============================================================================
   ПРОСТЫМ ЯЗЫКОМ:
   Это НЕ отчёт — это «сырьё» для ноутбука (ipynb). Никакой агрегации, никаких
   COALESCE/CAST/переименований и никакого отбора «последней» строки — всё это
   вы сделаете в Python. Скрипт делает три вещи:
     0) СХЕМА — показывает реальные колонки уже известных таблиц и ищет по
        ключевым словам («реструктур», «приостан», «отмен», «suspens») таблицы/
        колонки, которые отвечают за ПЕРИОД ПРИОСТАНОВКИ и ОТМЕНУ реструктуризации
        — эти два источника в репозитории пока НЕ подтверждены (см. секцию 4).
     1) СЫРОЙ пул 3-й стадии: category=3, без списанных (tag<>11), снимок на
        @AsOf — SELECT *, ни одной вычисляемой колонки.
     2) СЫРАЯ справочная запись по реструктуризации/дефолту/оздоровлению
        (IFRS9.KAN_20260601_for_LGD_Fenix) для контрактов из пула — SELECT *,
        это единственный источник даты реструктуризации, подтверждённый в
        merged-скриптах (`дата окончания реструктуры`, `health_date2`).
     3) СЫРОЙ источник даты дефолта (HISTORY_DEFAULT_ACCOUNT) для тех же
        контрактов — второй сырой ингредиент для COALESCE(default_date),
        который раньше делался в SQL, теперь сделаете сами в pandas.
     4) TODO — период приостановки и отмена реструктуризации: в этом репозитории
        ни одна проверенная колонка под них ещё не встречалась. Запустите
        секцию 0, найдите реальную таблицу/колонку и допишите блок аналогично
        секции 2.
   -----------------------------------------------------------------------------
   Purest raw extracts for notebook-side (ipynb) processing — no derived
   columns, no dedup-to-latest, no COALESCE. Three confirmed raw pulls (Stage 3
   pool, restructuring/cure reference row, default-date source row) scoped to
   the pool's contract numbers, plus a schema/keyword discovery section to
   locate the NOT YET confirmed suspension-period and restructuring-cancellation
   sources (§4 is a template to fill in once §0 surfaces the real table/column).
   T-SQL (Microsoft SQL Server).
   ============================================================================= */

DECLARE @AsOf date = '2026-07-01';   -- snapshot date for the Stage 3 pool

-------------------------------------------------------------------------------
-- 0. SCHEMA DISCOVERY
--    0a. Full column list of the tables already used elsewhere in this repo.
--    0b. Keyword sweep for restructuring / suspension / cancellation tables
--        we have NOT yet confirmed. Run per-database (INFORMATION_SCHEMA is
--        scoped to the current DB — switch with USE or a 3-part name query).
-------------------------------------------------------------------------------

-- 0a. Columns of tables already confirmed & used (CL_PORTFOLIO db).
SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH, ORDINAL_POSITION
FROM [CL_PORTFOLIO].INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME IN ('CL_PORTFOLIO_2', 'HISTORY_DEFAULT_ACCOUNT')
ORDER BY TABLE_NAME, ORDINAL_POSITION;

-- 0a. Columns of the restructuring/cure reference table (IFRS9 db).
SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH, ORDINAL_POSITION
FROM [IFRS9].INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'KAN_20260601_for_LGD_Fenix'
ORDER BY ORDINAL_POSITION;

-- 0b. Keyword sweep in CL_PORTFOLIO: any table/column that smells like
--     "restructuring", "suspension/moratorium", or "cancellation".
SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE
FROM [CL_PORTFOLIO].INFORMATION_SCHEMA.COLUMNS
WHERE COLUMN_NAME LIKE N'%реструктур%' OR COLUMN_NAME LIKE N'%restr%'
   OR COLUMN_NAME LIKE N'%приостан%'   OR COLUMN_NAME LIKE N'%suspens%' OR COLUMN_NAME LIKE N'%моратор%'
   OR COLUMN_NAME LIKE N'%отмен%'      OR COLUMN_NAME LIKE N'%cancel%'
   OR TABLE_NAME  LIKE N'%RESTRUCT%'   OR TABLE_NAME  LIKE N'%РЕСТРУКТУР%'
ORDER BY TABLE_NAME, COLUMN_NAME;

-- 0b. Same sweep in IFRS9.
SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE
FROM [IFRS9].INFORMATION_SCHEMA.COLUMNS
WHERE COLUMN_NAME LIKE N'%реструктур%' OR COLUMN_NAME LIKE N'%restr%'
   OR COLUMN_NAME LIKE N'%приостан%'   OR COLUMN_NAME LIKE N'%suspens%' OR COLUMN_NAME LIKE N'%моратор%'
   OR COLUMN_NAME LIKE N'%отмен%'      OR COLUMN_NAME LIKE N'%cancel%'
   OR TABLE_NAME  LIKE N'%RESTRUCT%'   OR TABLE_NAME  LIKE N'%РЕСТРУКТУР%'
ORDER BY TABLE_NAME, COLUMN_NAME;

-- 0c. Which databases can this login even see? `docs/analysis/credit_risk_
--     knowledge_base.md` documents a NEW mart [Dictionaries].[risk_analytics]
--     with a `restructuring_v2` EVENT table (one row per restructuring event —
--     exactly the shape you'd need for "last" + "cancelled" without guessing).
--     It has never been queried from this repo, so confirm access first:
SELECT name FROM sys.databases ORDER BY name;
-- If [Dictionaries] appears above, point 0b at it too:
--   SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE FROM [Dictionaries].INFORMATION_SCHEMA.COLUMNS
--   WHERE TABLE_NAME LIKE '%restructur%' ORDER BY TABLE_NAME, COLUMN_NAME;
--   SELECT TOP (50) * FROM [Dictionaries].[risk_analytics].[restructuring_v2];  -- eyeball real columns/rows

-------------------------------------------------------------------------------
-- 1. RAW STAGE 3 POOL — category=3, exclude written-off (tag=11), snapshot
--    @AsOf. SELECT * on purpose: every column CL_PORTFOLIO_2 has, untouched.
-------------------------------------------------------------------------------
;WITH pool_contracts AS (
    SELECT contract_number
    FROM [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2]
    WHERE [date] = @AsOf
      AND [category] = '3'
      AND ISNULL([tag], '') <> '11'
)
SELECT a.*
FROM [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2] a
JOIN pool_contracts pc ON pc.contract_number = a.contract_number
WHERE a.[date] = @AsOf;

-------------------------------------------------------------------------------
-- 2. RAW restructuring / default / cure REFERENCE row — one source row per
--    contract from IFRS9.KAN_20260601_for_LGD_Fenix, SELECT * (includes
--    default_date, health_date2, «дата окончания реструктуры», and whatever
--    else lives on this row — check the §0a column list for the exact names,
--    e.g. a suspension-period pair may already be sitting on this same row).
--    Scoped to the pool's contracts; the pool itself is the WHERE in §1, run
--    both in the SAME batch/session or re-declare @AsOf and repeat the CTE.
-------------------------------------------------------------------------------
;WITH pool_contracts AS (
    SELECT contract_number
    FROM [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2]
    WHERE [date] = @AsOf
      AND [category] = '3'
      AND ISNULL([tag], '') <> '11'
)
SELECT c.*
FROM [IFRS9].[dbo].[KAN_20260601_for_LGD_Fenix] c
JOIN pool_contracts pc ON pc.contract_number = c.account_number;

-------------------------------------------------------------------------------
-- 3. RAW default-date source row — HISTORY_DEFAULT_ACCOUNT, SELECT *, same
--    contract scope. The other half of what stage3_cure_pool.sql used to
--    COALESCE() in SQL — do the COALESCE in pandas instead.
-------------------------------------------------------------------------------
;WITH pool_contracts AS (
    SELECT contract_number
    FROM [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2]
    WHERE [date] = @AsOf
      AND [category] = '3'
      AND ISNULL([tag], '') <> '11'
)
SELECT b.*
FROM [CL_PORTFOLIO].[dbo].[HISTORY_DEFAULT_ACCOUNT] b
JOIN pool_contracts pc ON pc.contract_number = b.account_number;

/* =============================================================================
   4. TODO — suspension period & restructuring-cancellation raw extracts.
   NOT written yet: no table in this repo's confirmed history carries a
   suspension/moratorium-period pair or a restructuring-cancellation date. Run
   §0 above; once you have the real table + columns, copy this template:

   ;WITH pool_contracts AS ( ...same as §1... )
   SELECT x.*
   FROM [<db>].[dbo].[<restructuring_event_table>] x
   JOIN pool_contracts pc ON pc.contract_number = x.<account_number_column>;

   If it turns out to be an EVENT table (multiple rows per contract, e.g. the
   documented `restructuring_v2`), pull ALL rows raw (no "keep only latest" —
   do that in pandas with e.g. `.sort_values('event_date').groupby('contract_
   number').tail(1)` for "last restructurization", and filter on whatever
   status/cancel-date column marks a cancellation for the "restr cancellation"
   slice).
   ============================================================================= */

-------------------------------------------------------------------------------
-- Notes
-------------------------------------------------------------------------------
-- * Nothing here is deduplicated, aggregated, cast, or renamed — every SELECT
--   is `alias.*` on purpose so pandas sees exactly what the source table has,
--   including NULLs, dirty values, and duplicate rows if the source has them.
-- * @AsOf fixes the Stage 3 pool to one snapshot date. If you also want the
--   monthly DPD panel (Jan–Jul 2026) for these same contracts, that already
--   exists as ##STAGE3_CURE_POOL_DPD in stage3_cure_pool.sql — run that
--   script too (same session) and pull `SELECT * FROM ##STAGE3_CURE_POOL_DPD`
--   raw, same idea.
-- * §2/§3 assume `account_number` is the join key on both reference tables —
--   confirmed by the LEFT JOIN in stage3_cure_pool.sql / stage3_cure_funnel.sql.
-- * If a contract has more than one row in §2 or §3 (unconfirmed — check
--   COUNT(*) vs COUNT(DISTINCT account_number)), that's real raw data too:
--   don't dedup here, decide the tie-break in Python.
