/*==============================================================================
  CASE_RUN_PLEDGES_012_S01_DUPLICATE_LOAN_COLLATERAL_PAIRS

  Находка из CASE_RUN_LOANS_PLEDGES_011 (06.08.2026, срез 2026-08-01, результат
  D4): в pledges есть пары (договор, залог) — по подтверждённому ключу
  pledges.c_source+c_loan_gid = loans_active.l_source+l_gid (v8) — представленные
  НЕСКОЛЬКИМИ сырыми строками pledges вместо одной. Только источник S01.
  Первый прогон: 567 задвоенных пар, 3 651 сырых строк вместо 567 (избыток
  3 084 строки, ~6,4× в среднем). S03/S17 — 0 задвоений.

  Этот скрипт — самостоятельное воспроизведение находки для приложения к
  письму: пересчитывает то же самое заново, независимой от основного
  check-скрипта логикой, и на один шаг углубляет вопрос — задвоенные строки
  ИДЕНТИЧНЫ по значению залога (простое техническое дублирование строки) или
  РАЗЛИЧАЮТСЯ (конкурирующие/несинхронизированные оценки под одной и той же
  парой — более серьёзный дефект, не просто лишняя строка)?

  ВАЖНО (урок 06.08.2026, см. FINDINGS.md §9.7): `risk_analytics`
  перезаписывается целиком на каждой загрузке, истории не хранит. `@AsOf`
  здесь резолвится от факта (`MAX(l_report_date)`), не хардкодится. Если этот
  скрипт запущен позже даты обнаружения (`@OriginalFindingDate` ниже) —
  расхождение с "ранее сообщённым" может быть либо реальным исправлением
  дефекта, либо эффектом смены снимка (то же правило, что для S03/94 732,
  FINDINGS §9.7). RESULT 04 явно помечает, сравнимы ли даты, прежде чем
  делать вывод "исправлено"/"не исправлено".

  Read-only, MAXDOP 1, без PII (номера договоров/gid — технические
  идентификаторы, не выводятся вместе с ФИО/ИИН/IBAN). Только агрегаты.
==============================================================================*/

USE [Dictionaries];
SET NOCOUNT ON;

DECLARE @CaseRun varchar(120) = 'CASE_RUN_PLEDGES_012_S01_DUPLICATE_LOAN_COLLATERAL_PAIRS';
DECLARE @AsOf date = (SELECT MAX(l_report_date) FROM [risk_analytics].[loans_active]);

-- Ранее сообщённое (CASE_RUN_LOANS_PLEDGES_011, 06.08.2026, срез 2026-08-01) — для контроля.
DECLARE @OriginalFindingDate date = '2026-08-01';
DECLARE @PriorDuplicatedPairs_S01 int = 567;
DECLARE @PriorTotalRawRows_S01 int = 3651;
DECLARE @PriorExcessRows_S01 int = 3084;


/*==============================================================================
  RESULT 00 — Область и метод проверки
==============================================================================*/
SELECT
    @CaseRun AS case_run,
    '00_SCOPE_CONTROL' AS result_set,
    @AsOf AS resolved_AsOf,
    @OriginalFindingDate AS original_finding_date,
    CASE WHEN @AsOf = @OriginalFindingDate
             THEN N'ТА ЖЕ ДАТА — прямое сравнение с прежними числами корректно'
         ELSE N'ДРУГАЯ ДАТА — risk_analytics не хранит историю (FINDINGS §9.7); расхождение с ранее сообщённым может быть сменой снимка, а не исправлением дефекта'
    END AS date_comparability_note,
    N'pledges.c_source+c_loan_gid = loans_active.l_source+l_gid (v8, независимо подтверждено в CASE_RUN_LOANS_PLEDGES_011 A3: c_loan_gid один даёт тот же matched-счётчик, что и с source)' AS canonical_key_used
OPTION (MAXDOP 1);


/*==============================================================================
  Материализация MATCHED loan<->pledges строк (независимый пересчёт D4)
==============================================================================*/
IF OBJECT_ID('tempdb..#loans_active_keys') IS NOT NULL DROP TABLE #loans_active_keys;
SELECT l_source, l_gid
INTO #loans_active_keys
FROM [risk_analytics].[loans_active]
WHERE l_report_date = @AsOf
OPTION (MAXDOP 1);
CREATE CLUSTERED INDEX ix_lak ON #loans_active_keys(l_source, l_gid);

IF OBJECT_ID('tempdb..#pair_rows') IS NOT NULL DROP TABLE #pair_rows;
SELECT p.c_source, p.c_loan_gid, p.c_collateral_id, p.c_collateral_value, p.last_appraisal_date
INTO #pair_rows
FROM [risk_analytics].[pledges] p
WHERE p.c_reporting_date = @AsOf
  AND EXISTS (SELECT 1 FROM #loans_active_keys k WHERE k.l_source = p.c_source AND k.l_gid = p.c_loan_gid)
OPTION (MAXDOP 1);
CREATE CLUSTERED INDEX ix_pr ON #pair_rows(c_source, c_loan_gid, c_collateral_id);

IF OBJECT_ID('tempdb..#pair_counts') IS NOT NULL DROP TABLE #pair_counts;
SELECT c_source, c_loan_gid, c_collateral_id,
       COUNT_BIG(*) AS raw_row_count,
       MIN(c_collateral_value) AS min_collateral_value,
       MAX(c_collateral_value) AS max_collateral_value,
       MIN(last_appraisal_date) AS min_appraisal_date,
       MAX(last_appraisal_date) AS max_appraisal_date
INTO #pair_counts
FROM #pair_rows
GROUP BY c_source, c_loan_gid, c_collateral_id
OPTION (MAXDOP 1);
CREATE CLUSTERED INDEX ix_pc ON #pair_counts(c_source, c_loan_gid, c_collateral_id);


/*==============================================================================
  RESULT 01 — Задвоенные пары (loan,collateral) по source: пересчёт D4
==============================================================================*/
SELECT
    @CaseRun AS case_run,
    '01_DUPLICATED_PAIRS_BY_SOURCE' AS result_set,
    c_source AS source,
    COUNT_BIG(*) AS duplicated_pairs,
    SUM(raw_row_count) AS total_raw_rows_involved,
    SUM(raw_row_count - 1) AS excess_rows
FROM #pair_counts
WHERE raw_row_count > 1
GROUP BY c_source
ORDER BY source
OPTION (MAXDOP 1);


/*==============================================================================
  RESULT 02 — Распределение "сколько сырых строк на задвоенную пару"
  (равномерное 2x-дублирование или длинный хвост?)
==============================================================================*/
SELECT
    @CaseRun AS case_run,
    '02_DUPLICATE_DEPTH_DISTRIBUTION' AS result_set,
    c_source AS source,
    CASE WHEN raw_row_count = 2 THEN '2x'
         WHEN raw_row_count BETWEEN 3 AND 5 THEN '3-5x'
         WHEN raw_row_count BETWEEN 6 AND 10 THEN '6-10x'
         ELSE '11x+' END AS duplication_depth,
    COUNT_BIG(*) AS pairs_in_bucket
FROM #pair_counts
WHERE raw_row_count > 1
GROUP BY c_source,
    CASE WHEN raw_row_count = 2 THEN '2x'
         WHEN raw_row_count BETWEEN 3 AND 5 THEN '3-5x'
         WHEN raw_row_count BETWEEN 6 AND 10 THEN '6-10x'
         ELSE '11x+' END
ORDER BY source, duplication_depth
OPTION (MAXDOP 1);


/*==============================================================================
  RESULT 03 — Стабильность значения залога внутри задвоенной пары:
  дубли идентичны (техническая копия строки) или расходятся (конкурирующие
  оценки под одним и тем же ключом — отдельный, более серьёзный вопрос)?
==============================================================================*/
SELECT
    @CaseRun AS case_run,
    '03_DUPLICATE_VALUE_STABILITY' AS result_set,
    c_source AS source,
    COUNT_BIG(*) AS duplicated_pairs_total,
    SUM(CASE
            WHEN min_collateral_value IS NULL AND max_collateral_value IS NULL THEN 1
            WHEN min_collateral_value IS NOT NULL AND max_collateral_value IS NOT NULL
                 AND min_collateral_value = max_collateral_value THEN 1
            ELSE 0
        END) AS pairs_with_identical_value,
    COUNT_BIG(*) - SUM(CASE
            WHEN min_collateral_value IS NULL AND max_collateral_value IS NULL THEN 1
            WHEN min_collateral_value IS NOT NULL AND max_collateral_value IS NOT NULL
                 AND min_collateral_value = max_collateral_value THEN 1
            ELSE 0
        END) AS pairs_with_differing_value
FROM #pair_counts
WHERE raw_row_count > 1
GROUP BY c_source
ORDER BY source
OPTION (MAXDOP 1);


/*==============================================================================
  RESULT 04 — Контроль воспроизводимости против ранее сообщённых чисел
  (567 / 3 651 / 3 084 для S01, CASE_RUN_LOANS_PLEDGES_011 D4, срез 01.08.2026)
==============================================================================*/
DECLARE @LiveDuplicatedPairs_S01 int, @LiveTotalRawRows_S01 int, @LiveExcessRows_S01 int;

SELECT @LiveDuplicatedPairs_S01 = COUNT_BIG(*),
       @LiveTotalRawRows_S01 = SUM(raw_row_count),
       @LiveExcessRows_S01 = SUM(raw_row_count - 1)
FROM #pair_counts
WHERE c_source = N'S01' AND raw_row_count > 1;

SELECT
    @CaseRun AS case_run,
    '04_REPRODUCTION_CONTROL' AS result_set,
    ISNULL(@LiveDuplicatedPairs_S01, 0) AS live_duplicated_pairs_S01,
    @PriorDuplicatedPairs_S01 AS prior_reported_duplicated_pairs_S01,
    ISNULL(@LiveTotalRawRows_S01, 0) AS live_total_raw_rows_S01,
    @PriorTotalRawRows_S01 AS prior_reported_total_raw_rows_S01,
    ISNULL(@LiveExcessRows_S01, 0) AS live_excess_rows_S01,
    @PriorExcessRows_S01 AS prior_reported_excess_rows_S01,
    CASE
        WHEN @AsOf <> @OriginalFindingDate
            THEN N'ДРУГАЯ ДАТА СНИМКА — расхождение (если есть) неинтерпретируемо как починка/поломка, см. 00_SCOPE_CONTROL'
        WHEN ISNULL(@LiveDuplicatedPairs_S01,0) = @PriorDuplicatedPairs_S01
             AND ISNULL(@LiveTotalRawRows_S01,0) = @PriorTotalRawRows_S01
            THEN N'MATCHES_PRIOR_FINDING'
        ELSE N'DIFFERS_ON_SAME_DATE_REVIEW_REQUIRED'
    END AS control_status
OPTION (MAXDOP 1);


/*==============================================================================
  RESULT 05 — Среди пар с РАЗНЫМИ значениями (03): различается ли дата оценки
  между сырыми строками? Различается → правдоподобна история переоценок, не
  задвоение (нужен фильтр "последняя по дате" при потреблении). Дата ТА ЖЕ, а
  значение разное → историей не объясняется, это конфликт данных внутри
  одного снимка на одном и том же ключе.
==============================================================================*/
SELECT
    @CaseRun AS case_run,
    '05_DIFFERING_VALUE_VS_APPRAISAL_DATE' AS result_set,
    c_source AS source,
    CASE
        WHEN min_appraisal_date IS NULL OR max_appraisal_date IS NULL
            THEN 'APPRAISAL_DATE_NULL_CANNOT_CLASSIFY'
        WHEN min_appraisal_date <> max_appraisal_date
            THEN 'DIFFERING_DATE (правдоподобна история переоценок)'
        ELSE 'SAME_DATE_DIFFERING_VALUE (историей не объясняется)'
    END AS explanation_class,
    COUNT_BIG(*) AS pairs_in_class
FROM #pair_counts
WHERE raw_row_count > 1
  AND NOT (min_collateral_value IS NULL AND max_collateral_value IS NULL)
  AND NOT (min_collateral_value IS NOT NULL AND max_collateral_value IS NOT NULL AND min_collateral_value = max_collateral_value)
GROUP BY c_source,
    CASE
        WHEN min_appraisal_date IS NULL OR max_appraisal_date IS NULL
            THEN 'APPRAISAL_DATE_NULL_CANNOT_CLASSIFY'
        WHEN min_appraisal_date <> max_appraisal_date
            THEN 'DIFFERING_DATE (правдоподобна история переоценок)'
        ELSE 'SAME_DATE_DIFFERING_VALUE (историей не объясняется)'
    END
ORDER BY source, explanation_class
OPTION (MAXDOP 1);

DROP TABLE #pair_counts;
DROP TABLE #pair_rows;
DROP TABLE #loans_active_keys;
