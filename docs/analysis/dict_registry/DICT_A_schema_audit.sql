/*  DICT_A_schema_audit.sql — живой аудит схемы Dictionaries.risk_analytics
    Контур: dict_registry. Составлено 01.09.2026.

    Назначение: получить имена объектов и колонок ИЗ БАЗЫ, а не из памяти и не из
    BI-канваса. Раздел 4 корневого CLAUDE.md: имя колонки не равно семантике,
    поэтому § 3 и § 4 сразу дают заполненность — строка реестра без числа не заводится.

    Правила соблюдены: только SELECT; трёхчастные имена; MAXDOP 1 на тяжёлом шаге;
    PII не выводится — только имена объектов и агрегаты; #temp с префиксом файла.
    Порядок: сначала агрегат, потом детализация.
*/

SET NOCOUNT ON;

/* ─────────────────────────────────────────────────────────────────────────
   § 1. Инвентарь таблиц схемы — сколько объектов и какого типа
   ───────────────────────────────────────────────────────────────────────── */
SELECT  t.TABLE_TYPE,
        COUNT(*) AS objects_cnt
FROM    [Dictionaries].[INFORMATION_SCHEMA].[TABLES] AS t
WHERE   t.TABLE_SCHEMA = 'risk_analytics'
GROUP BY t.TABLE_TYPE
ORDER BY objects_cnt DESC;

/* ─────────────────────────────────────────────────────────────────────────
   § 2. Колонки по объектам — имена берутся отсюда и больше ниоткуда
   ───────────────────────────────────────────────────────────────────────── */
SELECT  c.TABLE_NAME,
        COUNT(*)                                             AS columns_cnt,
        SUM(CASE WHEN c.IS_NULLABLE = 'YES' THEN 1 ELSE 0 END) AS nullable_cnt
FROM    [Dictionaries].[INFORMATION_SCHEMA].[COLUMNS] AS c
WHERE   c.TABLE_SCHEMA = 'risk_analytics'
GROUP BY c.TABLE_NAME
ORDER BY c.TABLE_NAME;

/* Детализация — после агрегата, а не вместо него.
   Раскомментировать по одной таблице, не по всей схеме разом. */
-- SELECT  c.COLUMN_NAME, c.DATA_TYPE, c.CHARACTER_MAXIMUM_LENGTH,
--         c.NUMERIC_PRECISION, c.NUMERIC_SCALE, c.IS_NULLABLE
-- FROM    [Dictionaries].[INFORMATION_SCHEMA].[COLUMNS] AS c
-- WHERE   c.TABLE_SCHEMA = 'risk_analytics'
--   AND   c.TABLE_NAME   = N'<одна таблица>'
-- ORDER BY c.ORDINAL_POSITION;

/* ─────────────────────────────────────────────────────────────────────────
   § 3. Историзация: у каких объектов есть колонка отчётной даты
        Проверяемая гипотеза, а не догадка: loan_account и restructuring_v2
        историзованы (FINDINGS § 11.2 и § 11.4). Здесь список кандидатов целиком.
   ───────────────────────────────────────────────────────────────────────── */
SELECT  c.TABLE_NAME,
        c.COLUMN_NAME,
        c.DATA_TYPE
FROM    [Dictionaries].[INFORMATION_SCHEMA].[COLUMNS] AS c
WHERE   c.TABLE_SCHEMA = 'risk_analytics'
  AND   (c.COLUMN_NAME LIKE '%report_date%' OR c.COLUMN_NAME LIKE '%as_of%'
         OR c.COLUMN_NAME LIKE '%snapshot%')
ORDER BY c.TABLE_NAME, c.COLUMN_NAME;

/* ─────────────────────────────────────────────────────────────────────────
   § 4. Шаблон заполненности — единственный способ завести строку в FIELDS.md

        Подставить объект и колонку. Возвращает долю заполнения и число
        различных значений: без них семантика в реестр не пишется.
        PII не выводится — только счётчики.
   ───────────────────────────────────────────────────────────────────────── */
-- SELECT  la_source,
--         COUNT(*)                                                     AS rows_total,
--         SUM(CASE WHEN <колонка> IS NULL THEN 1 ELSE 0 END)           AS rows_null,
--         CAST(100.0 * SUM(CASE WHEN <колонка> IS NULL THEN 1 ELSE 0 END)
--              / NULLIF(COUNT(*), 0) AS decimal(5,2))                  AS null_pct,
--         COUNT(DISTINCT <колонка>)                                    AS distinct_cnt
-- FROM    [Dictionaries].[risk_analytics].[<объект>]
-- GROUP BY la_source
-- ORDER BY la_source
-- OPTION (MAXDOP 1);

/* ─────────────────────────────────────────────────────────────────────────
   § 5. Что этот скрипт НЕ делает

   Не выводит значения полей, не строит выборки по заёмщикам, не обращается к
   CL_PORTFOLIO. Старая база — контур cl_registry, отдельный скрипт.
   Сопоставление двух ветвей — контур risk_dwh_reconciliation, не этот.
   ───────────────────────────────────────────────────────────────────────── */
