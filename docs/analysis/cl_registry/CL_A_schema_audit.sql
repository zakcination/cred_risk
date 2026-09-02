/*  CL_A_schema_audit.sql — живой аудит схемы CL_PORTFOLIO.dbo (старая база)
    Контур: cl_registry. Составлено 01.09.2026.

    Назначение: получить состав таблиц и колонок ИЗ БАЗЫ. Для старой ветви это
    правило дороже, чем для mart: по S02 колонки l_loan_id, ID и LOAN_ID_KR
    искали в переписке, а по схеме их нет вовсе (FINDINGS § 1).

    Правила раздела 4: только SELECT; трёхчастные имена; MAXDOP 1 на тяжёлом
    шаге; PII не выводится — имена объектов и агрегаты; #temp с префиксом файла.
*/

SET NOCOUNT ON;

/* ─────────────────────────────────────────────────────────────────────────
   § 1. Какие PORTFOLIO_* вообще есть — состав по источникам проверяется здесь,
        а не по памяти о том, что кому соответствует
   ───────────────────────────────────────────────────────────────────────── */
SELECT  t.TABLE_NAME,
        t.TABLE_TYPE
FROM    [CL_PORTFOLIO].[INFORMATION_SCHEMA].[TABLES] AS t
WHERE   t.TABLE_SCHEMA = 'dbo'
  AND   (t.TABLE_NAME LIKE 'PORTFOLIO[_]%' OR t.TABLE_NAME LIKE 'CL[_]PORTFOLIO%')
ORDER BY t.TABLE_NAME;

/* ─────────────────────────────────────────────────────────────────────────
   § 2. Ширина объектов — агрегат раньше детализации
   ───────────────────────────────────────────────────────────────────────── */
SELECT  c.TABLE_NAME,
        COUNT(*) AS columns_cnt
FROM    [CL_PORTFOLIO].[INFORMATION_SCHEMA].[COLUMNS] AS c
WHERE   c.TABLE_SCHEMA = 'dbo'
GROUP BY c.TABLE_NAME
ORDER BY c.TABLE_NAME;

/* ─────────────────────────────────────────────────────────────────────────
   § 3. Ключевые колонки: где вообще есть contract_id, contract_number,
        contractnumber. Отвечает на вопрос «каким ключом связывать источник»
        до того, как ключ будет выбран.
   ───────────────────────────────────────────────────────────────────────── */
SELECT  c.TABLE_NAME,
        c.COLUMN_NAME,
        c.DATA_TYPE,
        c.CHARACTER_MAXIMUM_LENGTH
FROM    [CL_PORTFOLIO].[INFORMATION_SCHEMA].[COLUMNS] AS c
WHERE   c.TABLE_SCHEMA = 'dbo'
  AND   c.COLUMN_NAME IN (N'contract_id', N'contract_number', N'contractnumber',
                          N'l_loan_id', N'ID', N'LOAN_ID_KR')
ORDER BY c.TABLE_NAME, c.COLUMN_NAME;

/* Отрицательный результат этого запроса — тоже результат: по S02 он показывает,
   что l_loan_id, ID и LOAN_ID_KR в OLD-картах отсутствуют. Строку в реестр
   заводит именно он, а не переписка. */

/* ─────────────────────────────────────────────────────────────────────────
   § 4. Шаблон проверки уникальности кандидата в ключи

        S17 показал, почему шаг обязателен: contract_id там не уникален —
        до 33 договоров на один идентификатор (FINDINGS § 1).
        Подставить объект и колонку.
   ───────────────────────────────────────────────────────────────────────── */
-- SELECT  COUNT(*)                       AS rows_total,
--         COUNT(DISTINCT <ключ>)         AS keys_distinct,
--         MAX(dup.cnt)                   AS max_rows_per_key
-- FROM    [CL_PORTFOLIO].[dbo].[<объект>] AS t
-- CROSS APPLY (SELECT COUNT(*) AS cnt
--              FROM   [CL_PORTFOLIO].[dbo].[<объект>] AS d
--              WHERE  d.<ключ> = t.<ключ>) AS dup
-- OPTION (MAXDOP 1);
--
-- Примечание: CROSS APPLY ставится ПОСЛЕ фильтра — раздел 4. В шаблоне фильтра
-- нет, поэтому на большом объекте запускать только с ограничением по дате среза.

/* ─────────────────────────────────────────────────────────────────────────
   § 5. Чего этот скрипт не делает

   Не обращается к Dictionaries.risk_analytics и не сопоставляет ветви.
   Новая ветвь — контур dict_registry, сверка — risk_dwh_reconciliation.
   ───────────────────────────────────────────────────────────────────────── */
