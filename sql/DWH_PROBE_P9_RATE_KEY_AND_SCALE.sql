/*==============================================================================
  DWH_PROBE_P9_RATE_KEY_AND_SCALE — закрывает три хвоста после P8

  ХВОСТ 1. P8d дал `dlcr_dog_num -> l_loan_number` = 100% на всех источниках,
  НО джойн шёл на `SELECT DISTINCT l_loan_number` БЕЗ УЧЁТА ИСТОЧНИКА. По T18
  номер договора даёт 9 659 коллизий между источниками — значит строка ставки
  S01 могла совпасть с номером договора S03 и засчитаться как матч. 100% —
  верхняя граница, а не покрытие. Это прямое нарушение правила CLAUDE.md
  («группировка по номеру договора без source смешивает клиентов») в моей же
  пробе. Здесь ключ тестируется парой (source, номер), и рядом печатается,
  сколько матчей теряется от добавления source — это и есть цена ошибки.

  ХВОСТ 2. `loan_id` дал 0% совпадений при том, что `l_loan_id` кастуется в
  bigint без единого сбоя. Не установлено, заполнена ли колонка вообще:
  проверка grain фильтровала `loan_id IS NOT NULL` и вернула пусто, что
  одинаково согласуется и с «все NULL», и с «заполнена и уникальна».
  Для письма автору марта разница принципиальная.

  ХВОСТ 3. Шкала. В одной колонке одного источника сосуществуют значения
  (0;1] и (1;100] — 68% `interest_rate` у S17 ниже единицы. Правило «< 1 →
  ×100» напрашивается, но это ГИПОТЕЗА: `0,5` может быть и «0,5%», и «50%».
  Разводится через кредитную программу (`l_rate`, §11.1):
    - обе шкалы ВНУТРИ одной программы  -> дефект загрузки, ×100 применимо;
    - программы разделены по шкалам     -> значения корректны, ×100 сломает.
  Тест сформулирован так, чтобы ответ был однозначным в обе стороны.

  Правила: только SELECT, MAXDOP 1, без PII (номера договоров и названия
  программ выводятся только как счётчики групп). MAXDOP 1 обязателен: джойн
  6,97 млн строк ставки к 8,26 млн строк loans.
  ЗАПУСКАТЬ ЦЕЛИКОМ ОТ ПЕРВОЙ СТРОКИ (Msg 137).
==============================================================================*/

USE [Dictionaries];
SET NOCOUNT ON;

DECLARE @Suite varchar(60) = 'L1_PROBES';
DECLARE @AsOf  date = (SELECT MAX(l_report_date) FROM [Dictionaries].[risk_analytics].[loans]);

SELECT @Suite AS suite, '00_SCOPE' AS scenario, @AsOf AS resolved_asof
OPTION (MAXDOP 1);


/*------------------------------------------------------------------------------
  Материализация. Ключ — ПАРА (source, номер). Приведение типов один раз,
  дальше голые сравнения (иначе non-sargable, L11.1/L4.1).
------------------------------------------------------------------------------*/
IF OBJECT_ID('tempdb..#lnum') IS NOT NULL DROP TABLE #lnum;
SELECT DISTINCT l_source, l_loan_number
INTO #lnum
FROM [Dictionaries].[risk_analytics].[loans]
WHERE l_report_date = @AsOf AND l_loan_number IS NOT NULL
OPTION (MAXDOP 1);
CREATE CLUSTERED INDEX ix_lnum ON #lnum(l_source, l_loan_number);

IF OBJECT_ID('tempdb..#lnum_any') IS NOT NULL DROP TABLE #lnum_any;
SELECT DISTINCT l_loan_number
INTO #lnum_any
FROM [Dictionaries].[risk_analytics].[loans]
WHERE l_report_date = @AsOf AND l_loan_number IS NOT NULL
OPTION (MAXDOP 1);
CREATE CLUSTERED INDEX ix_lnum_any ON #lnum_any(l_loan_number);


/*==============================================================================
  A — КЛЮЧ С УЧЁТОМ ИСТОЧНИКА против ключа без него.
  Разница между колонками — это и есть завышение из P8d.
==============================================================================*/
SELECT @Suite AS suite, 'P9a_KEY_WITH_VS_WITHOUT_SOURCE' AS scenario,
       r.[dlcr$source] AS source,
       COUNT_BIG(*) AS rate_rows,
       SUM(CASE WHEN a.l_loan_number IS NOT NULL THEN 1 ELSE 0 END) AS matched_ignoring_source,
       SUM(CASE WHEN s.l_loan_number IS NOT NULL THEN 1 ELSE 0 END) AS matched_with_source,
       SUM(CASE WHEN a.l_loan_number IS NOT NULL AND s.l_loan_number IS NULL
                THEN 1 ELSE 0 END) AS false_matches_from_ignoring_source,
       CAST(100.0 * SUM(CASE WHEN s.l_loan_number IS NOT NULL THEN 1 ELSE 0 END)
            / NULLIF(COUNT_BIG(*), 0) AS decimal(9,4)) AS true_match_pct
FROM [Dictionaries].[risk_analytics].[interest_rates] r
LEFT JOIN #lnum_any a ON a.l_loan_number = r.dlcr_dog_num
LEFT JOIN #lnum     s ON s.l_source = r.[dlcr$source]
                     AND s.l_loan_number = r.dlcr_dog_num
GROUP BY r.[dlcr$source]
ORDER BY source
OPTION (MAXDOP 1);


/*==============================================================================
  B — ЗАПОЛНЕНА ЛИ `loan_id` ВООБЩЕ. Для письма автору марта разница между
  «колонка пустая» и «колонка из другого пространства» принципиальная.
==============================================================================*/
SELECT @Suite AS suite, 'P9b_LOAN_ID_POPULATION' AS scenario,
       [dlcr$source] AS source,
       COUNT_BIG(*) AS rows_total,
       SUM(CASE WHEN loan_id IS NULL THEN 1 ELSE 0 END) AS loan_id_null,
       SUM(CASE WHEN loan_id = 0 THEN 1 ELSE 0 END) AS loan_id_zero,
       COUNT(DISTINCT loan_id) AS distinct_loan_id,
       MIN(loan_id) AS min_loan_id,
       MAX(loan_id) AS max_loan_id
FROM [Dictionaries].[risk_analytics].[interest_rates]
GROUP BY [dlcr$source]
ORDER BY source
OPTION (MAXDOP 1);

/* Длина значения — грубый, но решающий признак «другого пространства»:
   у l_gid своё число разрядов, у l_loan_id своё. */
SELECT @Suite AS suite, 'P9c_LOAN_ID_SHAPE' AS scenario,
       source, id_digits, rows_cnt
FROM (
    SELECT [dlcr$source] AS source,
           LEN(CONVERT(varchar(30), loan_id)) AS id_digits,
           COUNT_BIG(*) AS rows_cnt
    FROM [Dictionaries].[risk_analytics].[interest_rates]
    WHERE loan_id IS NOT NULL
    GROUP BY [dlcr$source], LEN(CONVERT(varchar(30), loan_id))
) d
ORDER BY source, rows_cnt DESC
OPTION (MAXDOP 1);

/* Не является ли loan_id на самом деле gid. Проверяем покрытием, не догадкой. */
SELECT @Suite AS suite, 'P9d_LOAN_ID_VS_GID' AS scenario,
       r.[dlcr$source] AS source,
       COUNT_BIG(*) AS rate_rows,
       SUM(CASE WHEN g.l_gid IS NOT NULL THEN 1 ELSE 0 END) AS matched_to_l_gid,
       CAST(100.0 * SUM(CASE WHEN g.l_gid IS NOT NULL THEN 1 ELSE 0 END)
            / NULLIF(COUNT_BIG(*), 0) AS decimal(9,4)) AS match_pct
FROM [Dictionaries].[risk_analytics].[interest_rates] r
LEFT JOIN (SELECT DISTINCT l_gid FROM [Dictionaries].[risk_analytics].[loans]
           WHERE l_report_date = @AsOf) g
       ON g.l_gid = r.loan_id
GROUP BY r.[dlcr$source]
ORDER BY source
OPTION (MAXDOP 1);


/*==============================================================================
  C — РЕАЛЬНОЕ ПОКРЫТИЕ АКТИВНОГО ПОРТФЕЛЯ по подтверждённому ключу.
  P8h мерил по неработающему loan_id и потому дал 0 — цифра ничего не значила.
==============================================================================*/
SELECT @Suite AS suite, 'P9e_ACTIVE_RATE_COVERAGE' AS scenario,
       l.l_source AS source,
       COUNT_BIG(*) AS active_loans,
       SUM(CASE WHEN r.dlcr_dog_num IS NOT NULL THEN 1 ELSE 0 END) AS loans_with_rate,
       CAST(100.0 * SUM(CASE WHEN r.dlcr_dog_num IS NOT NULL THEN 1 ELSE 0 END)
            / NULLIF(COUNT_BIG(*), 0) AS decimal(9,4)) AS coverage_pct
FROM [Dictionaries].[risk_analytics].[loans_active] l
LEFT JOIN (
    SELECT DISTINCT [dlcr$source] AS src, dlcr_dog_num
    FROM [Dictionaries].[risk_analytics].[interest_rates]
    WHERE dlcr_dog_num IS NOT NULL
) r ON r.src = l.l_source AND r.dlcr_dog_num = l.l_loan_number
WHERE l.l_report_date = @AsOf
GROUP BY l.l_source
ORDER BY source
OPTION (MAXDOP 1);


/*==============================================================================
  D — ШКАЛА: дефект загрузки или свойство продукта.

  Для каждой кредитной программы (`l_rate`) смотрим, какие шкалы в ней
  встречаются. Ответ однозначен в обе стороны:
    «ОБЕ ШКАЛЫ В ОДНОЙ ПРОГРАММЕ» -> дефект, правило ×100 применимо;
    «программа целиком в одной шкале» -> ×100 сломает корректные данные.
==============================================================================*/
IF OBJECT_ID('tempdb..#rate_prog') IS NOT NULL DROP TABLE #rate_prog;
SELECT l.l_source, l.l_rate AS programme, r.interest_rate, r.effective_rate
INTO #rate_prog
FROM [Dictionaries].[risk_analytics].[loans] l
JOIN [Dictionaries].[risk_analytics].[interest_rates] r
     ON r.[dlcr$source] = l.l_source
    AND r.dlcr_dog_num  = l.l_loan_number
WHERE l.l_report_date = @AsOf
  AND l.l_rate IS NOT NULL
  AND r.interest_rate IS NOT NULL
  AND r.interest_rate > 0
OPTION (MAXDOP 1);

SELECT @Suite AS suite, 'P9f_SCALE_WITHIN_PROGRAMME' AS scenario,
       source, scale_state,
       COUNT_BIG(*) AS programmes,
       SUM(loans) AS loans_affected
FROM (
    SELECT l_source AS source, programme,
           COUNT_BIG(*) AS loans,
           CASE WHEN MIN(CASE WHEN interest_rate <= 1 THEN 1 ELSE 0 END)
                  < MAX(CASE WHEN interest_rate <= 1 THEN 1 ELSE 0 END)
                THEN N'ОБЕ ШКАЛЫ В ОДНОЙ ПРОГРАММЕ (дефект загрузки)'
                WHEN MAX(CASE WHEN interest_rate <= 1 THEN 1 ELSE 0 END) = 1
                THEN N'вся программа в шкале (0;1]'
                ELSE N'вся программа в шкале (1;100]'
           END AS scale_state
    FROM #rate_prog
    GROUP BY l_source, programme
) d
GROUP BY source, scale_state
ORDER BY source, loans_affected DESC
OPTION (MAXDOP 1);

/* Контроль: если внутри программы обе шкалы, то у «долевых» строк значение
   ×100 должно попадать в диапазон «процентных» строк той же программы.
   Если не попадает — гипотеза ×100 неверна, и это НЕ шкала. */
SELECT @Suite AS suite, 'P9g_X100_PLAUSIBILITY' AS scenario,
       source,
       COUNT_BIG(*) AS mixed_programmes,
       SUM(CASE WHEN frac_x100_min >= pct_min * 0.5
                 AND frac_x100_max <= pct_max * 2.0
                THEN 1 ELSE 0 END) AS x100_lands_in_range,
       SUM(CASE WHEN frac_x100_min <  pct_min * 0.5
                  OR frac_x100_max >  pct_max * 2.0
                THEN 1 ELSE 0 END) AS x100_does_not_fit
FROM (
    SELECT l_source AS source, programme,
           MIN(CASE WHEN interest_rate <= 1 THEN interest_rate * 100 END) AS frac_x100_min,
           MAX(CASE WHEN interest_rate <= 1 THEN interest_rate * 100 END) AS frac_x100_max,
           MIN(CASE WHEN interest_rate >  1 THEN interest_rate END)       AS pct_min,
           MAX(CASE WHEN interest_rate >  1 THEN interest_rate END)       AS pct_max
    FROM #rate_prog
    GROUP BY l_source, programme
    HAVING MIN(CASE WHEN interest_rate <= 1 THEN 1 ELSE 0 END)
         < MAX(CASE WHEN interest_rate <= 1 THEN 1 ELSE 0 END)
) d
GROUP BY source
ORDER BY source
OPTION (MAXDOP 1);


/*==============================================================================
  E — ЗАГЛУШКИ И НУЛИ: отделить «не заполнено» от «реально ноль».
  У S17 effective_rate = 0 на 76% строк — это не APR 0%, а пропуск, закодированный
  нулём. У S03 максимум ровно 999,0 — техническая заглушка.
==============================================================================*/
SELECT @Suite AS suite, 'P9h_SENTINELS_AND_ZEROS' AS scenario,
       [dlcr$source] AS source,
       COUNT_BIG(*) AS rows_total,
       SUM(CASE WHEN effective_rate = 0 THEN 1 ELSE 0 END) AS eff_zero,
       SUM(CASE WHEN effective_rate = 999 THEN 1 ELSE 0 END) AS eff_999,
       SUM(CASE WHEN effective_rate > 100 AND effective_rate <> 999 THEN 1 ELSE 0 END) AS eff_over_100_other,
       SUM(CASE WHEN initial_effective_rate = 999 THEN 1 ELSE 0 END) AS init_eff_999,
       SUM(CASE WHEN interest_rate = 0 THEN 1 ELSE 0 END) AS ir_zero,
       /* Ноль ГЭСВ при ненулевой номинальной — экономически невозможен. */
       SUM(CASE WHEN effective_rate = 0 AND interest_rate > 0 THEN 1 ELSE 0 END) AS eff_zero_but_nominal_positive
FROM [Dictionaries].[risk_analytics].[interest_rates]
GROUP BY [dlcr$source]
ORDER BY source
OPTION (MAXDOP 1);


IF OBJECT_ID('tempdb..#lnum')      IS NOT NULL DROP TABLE #lnum;
IF OBJECT_ID('tempdb..#lnum_any')  IS NOT NULL DROP TABLE #lnum_any;
IF OBJECT_ID('tempdb..#rate_prog') IS NOT NULL DROP TABLE #rate_prog;
