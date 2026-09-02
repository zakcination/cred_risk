/* =============================================================================
   D15-A. Аудит имён: где лежат график платежей и фактические платежи
   =============================================================================
   ПРОСТЫМ ЯЗЫКОМ: прежде чем считать, на сколько дней заёмщик опаздывает,
   надо узнать, в каких таблицах и колонках лежат «дата по графику» и «дата
   фактического платежа». Этот скрипт ничего не считает — он только показывает,
   что есть в базе.

   Зачем отдельным шагом. В `stage3_cure_candidates.sql` раздел §PAYMENTS
   описан словами («repayment_schedule LEFT JOIN payments / payments_wiring»)
   и никогда не был написан кодом. Имена оттуда — из переписки, а не из базы.
   Правило контура: имена колонок берутся из живого INFORMATION_SCHEMA,
   не из прошлогоднего скрипта и не по памяти.

   Read-only. Только SELECT из системных представлений.
   T-SQL (Microsoft SQL Server).

   КАК ЗАПУСКАТЬ: блок 1 — в каждой базе-кандидате по очереди (USE <db>),
   потому что INFORMATION_SCHEMA видит только текущую базу.
   ============================================================================= */

SET NOCOUNT ON;

-------------------------------------------------------------------------------
-- 0. Какие базы вообще есть — чтобы знать, где запускать блок 1
-------------------------------------------------------------------------------
SELECT name AS database_name, state_desc, create_date
FROM sys.databases
WHERE state_desc = 'ONLINE'
ORDER BY name;

-------------------------------------------------------------------------------
-- 1. Таблицы, похожие на график платежей и на платежи
--    Запускать в каждой базе-кандидате: USE [<db>]; затем этот блок.
-------------------------------------------------------------------------------
SELECT
      t.TABLE_CATALOG
    , t.TABLE_SCHEMA
    , t.TABLE_NAME
    , t.TABLE_TYPE
    , (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS c
       WHERE c.TABLE_CATALOG = t.TABLE_CATALOG
         AND c.TABLE_SCHEMA  = t.TABLE_SCHEMA
         AND c.TABLE_NAME    = t.TABLE_NAME)          AS columns_cnt
FROM INFORMATION_SCHEMA.TABLES AS t
WHERE t.TABLE_NAME LIKE '%payment%'
   OR t.TABLE_NAME LIKE '%schedule%'
   OR t.TABLE_NAME LIKE '%grafik%'
   OR t.TABLE_NAME LIKE '%график%'
   OR t.TABLE_NAME LIKE '%platezh%'
   OR t.TABLE_NAME LIKE '%repay%'
   OR t.TABLE_NAME LIKE '%instal%'
   OR t.TABLE_NAME LIKE '%loan_account%'
ORDER BY t.TABLE_SCHEMA, t.TABLE_NAME;

-------------------------------------------------------------------------------
-- 2. Колонки этих таблиц. Смотрим, что из нужного есть:
--    плановая дата, фактическая дата, плановая сумма, фактическая сумма,
--    номер взноса, ключ договора, признак источника.
-------------------------------------------------------------------------------
SELECT
      c.TABLE_SCHEMA
    , c.TABLE_NAME
    , c.ORDINAL_POSITION
    , c.COLUMN_NAME
    , c.DATA_TYPE
    , c.CHARACTER_MAXIMUM_LENGTH
    , c.IS_NULLABLE
FROM INFORMATION_SCHEMA.COLUMNS AS c
WHERE c.TABLE_NAME LIKE '%payment%'
   OR c.TABLE_NAME LIKE '%schedule%'
   OR c.TABLE_NAME LIKE '%repay%'
   OR c.TABLE_NAME LIKE '%instal%'
   OR c.TABLE_NAME LIKE '%loan_account%'
ORDER BY c.TABLE_SCHEMA, c.TABLE_NAME, c.ORDINAL_POSITION;

-------------------------------------------------------------------------------
-- 3. Обратный поиск: колонки с говорящими именами по ВСЕЙ базе.
--    Ловит таблицы, названия которых ни на что не похожи, а колонки — да.
-------------------------------------------------------------------------------
SELECT
      c.TABLE_SCHEMA
    , c.TABLE_NAME
    , c.COLUMN_NAME
    , c.DATA_TYPE
FROM INFORMATION_SCHEMA.COLUMNS AS c
WHERE c.COLUMN_NAME LIKE '%due%date%'
   OR c.COLUMN_NAME LIKE '%plan%date%'
   OR c.COLUMN_NAME LIKE '%date%plan%'
   OR c.COLUMN_NAME LIKE '%pay%date%'
   OR c.COLUMN_NAME LIKE '%date%pay%'
   OR c.COLUMN_NAME LIKE '%fact%date%'
   OR c.COLUMN_NAME LIKE '%oper%date%'
   OR c.COLUMN_NAME LIKE '%days_past_due%'
   OR c.COLUMN_NAME LIKE '%instal%'
ORDER BY c.TABLE_SCHEMA, c.TABLE_NAME, c.COLUMN_NAME;

-------------------------------------------------------------------------------
-- 4. Есть ли в самих портфельных таблицах день платежа по графику.
--    Если есть — часть Г-DPD-1 считается вообще без платёжных таблиц:
--    структурная просрочка концентрируется на договорах с датой платежа
--    в конце месяца (см. Н9 — снимок только на 1-е число).
-------------------------------------------------------------------------------
SELECT
      c.TABLE_NAME
    , c.COLUMN_NAME
    , c.DATA_TYPE
FROM [CL_PORTFOLIO].INFORMATION_SCHEMA.COLUMNS AS c
WHERE c.TABLE_NAME IN ('CL_PORTFOLIO_2', 'PORTFOLIO_Fenix', 'PORTFOLIO_RS',
                       'PORTFOLIO_CREDITCARDS_MIGR_WAY4',
                       'PORTFOLIO_CREDITCARDS_SMART_CARD',
                       'PORTFOLIO_CREDITCARDS_WAY4')
ORDER BY c.TABLE_NAME, c.ORDINAL_POSITION;

/* -----------------------------------------------------------------------------
   ЧТО ВЕРНУТЬ ОБРАТНО

   Из блоков 1-3 нужны четыре имени, и без них D15-B (слой 2) не пишется:
     * таблица графика     + колонки: ключ договора, номер взноса,
                             плановая дата, плановая сумма
     * таблица платежей    + колонки: ключ договора, фактическая дата,
                             фактическая сумма
     * признак источника (source_system) в обеих — если его нет, соединение
       по одному номеру договора даёт cross-source коллизии: их
       задокументировано 9 659 (ревизия 21.07.2026, пункт 1)
     * есть ли `loan_account.days_past_due` — он предпочтительнее сырого
       портфельного `dpd` (off-by-one, NULL-heavy для S03)

   Из блока 4 — есть ли день платежа по графику прямо в портфеле.
   ----------------------------------------------------------------------------- */
