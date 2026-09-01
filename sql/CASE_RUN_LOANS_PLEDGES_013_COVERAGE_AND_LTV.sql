/*==============================================================================
  CASE_RUN_LOANS_PLEDGES_013_COVERAGE_AND_LTV

  Возврат к исходной задаче (Miras, 06.08.2026): категоризировать активные
  договоры с/без залога и посчитать статистику покрытия — теперь количественно
  (сколько договоров) И по стоимости (сколько от суммы кредита покрыто
  стоимостью залога), с разбивкой по source.

  Базовая категоризация count-based уже сделана (CASE_RUN_LOANS_PLEDGES_011,
  результат B1) и кардинальность loan<->collateral (C1-C3) — здесь НЕ
  повторяется, а РАСШИРЯЕТСЯ до value-based покрытия (LTV-подобный коэффициент)
  и явно защищается от известного дефекта:

  ВАЖНО — методология защиты от коллизии c_collateral_id (FINDINGS §D4.1,
  CASE_RUN_PLEDGES_012 RESULT 06/07): для S01 подтверждено, что один
  c_collateral_id может указывать на РАЗНЫЕ физические объекты (разный
  c_bpm_object_id). Наивный `SUM(c_collateral_value) GROUP BY loan` по сырым
  строкам pledges посчитал бы эти конфликтующие строки как отдельные объекты
  ПРАВИЛЬНО (это и есть 2 разных объекта) — риск в другом: настоящие
  ТЕХНИЧЕСКИЕ дубли (88 из 567 пар, RESULT 03: идентичные строки) и
  легитимная история переоценок (214 из 567: та же пара, другая дата — RESULT
  05) задвоили бы сумму, если не дедуплицировать. Здесь для каждого
  объекта — ключ идентичности `c_bpm_object_id` (COALESCE на c_collateral_id,
  если bpm пуст), и берётся ОДНА строка на объект — с последней датой оценки
  (`last_appraisal_date` DESC), как и рекомендовано в письме (Черновик 4).

  ЧАСТИ:
    A1. Population/надёжность c_bpm_object_id как альтернативного ключа
        объекта — шире, чем в CASE_RUN_012 (не только внутри уже найденных
        567 дублей, а на всей MATCHED-популяции); плюс кросс-договорная
        проверка: "общий залог под несколькими договорами" (L9.4/C2) —
        легитимное совместное обеспечение (bpm стабилен) или та же коллизия
        идентификатора маскируется под "shared collateral" (bpm расходится)?
    B1. Покрытие по количеству договоров (%), по source.
    B2. Покрытие по стоимости: Σ(стоимость залога, дедуплицировано по
        объекту) / Σ(l_loan_amount), агрегат и распределение по договору.
    B3. Какая доля B2 приходится на договоры, уже помеченные как затронутые
        известной коллизией идентификатора (S01) — отдельно, чтобы не
        выдавать "чистую" цифру покрытия там, где под ней дефект.

  ОГОВОРКА: денежная база — `l_loan_amount` (подтверждённый мэппинг лимита,
  bi_canvas v-мэппинг c2), НЕ текущий остаток долга — вопрос "какой столбец
  остатка корректен по source" уже открыт отдельно (L6.0, ещё не решён) и
  сознательно не переоткрывается здесь (CLAUDE.md: не углубляться, пока
  предыдущий виток не закрыт причиной).

  Read-only, MAXDOP 1, без PII. @AsOf резолвится от факта (см. FINDINGS §9.7 —
  risk_analytics не хранит историю, хардкод даты уже один раз сломал прогон).
==============================================================================*/

USE [Dictionaries];
SET NOCOUNT ON;

DECLARE @CaseRun varchar(120) = 'CASE_RUN_LOANS_PLEDGES_013_COVERAGE_AND_LTV';
DECLARE @AsOf date = (SELECT MAX(l_report_date) FROM [Dictionaries].[risk_analytics].[loans_active]);


/*==============================================================================
  00 — Scope control
==============================================================================*/
SELECT @CaseRun AS case_run, '00_SCOPE_CONTROL' AS result_set,
       @AsOf AS resolved_AsOf,
       N'object identity = COALESCE(BPM:c_bpm_object_id, CID:c_collateral_id); один представитель на объект — по последней last_appraisal_date' AS dedup_method,
       N'l_loan_amount (подтверждённый лимит/принципал, НЕ текущий остаток — см. открытый вопрос L6.0)' AS money_base
OPTION (MAXDOP 1);


/*==============================================================================
  Материализация рабочих срезов
==============================================================================*/
IF OBJECT_ID('tempdb..#loans_active_keys') IS NOT NULL DROP TABLE #loans_active_keys;
SELECT l_source, l_gid, l_loan_amount, l_collateral_id
INTO #loans_active_keys
FROM [Dictionaries].[risk_analytics].[loans_active]
WHERE l_report_date = @AsOf
OPTION (MAXDOP 1);
CREATE CLUSTERED INDEX ix_lak ON #loans_active_keys(l_source, l_gid);

IF OBJECT_ID('tempdb..#matched_pledges') IS NOT NULL DROP TABLE #matched_pledges;
SELECT p.c_source, p.c_loan_gid, p.c_collateral_id, p.c_bpm_object_id,
       p.c_collateral_value, p.last_appraisal_date
INTO #matched_pledges
FROM [Dictionaries].[risk_analytics].[pledges] p
WHERE p.c_reporting_date = @AsOf
  AND EXISTS (SELECT 1 FROM #loans_active_keys k WHERE k.l_source = p.c_source AND k.l_gid = p.c_loan_gid)
OPTION (MAXDOP 1);
CREATE CLUSTERED INDEX ix_mp ON #matched_pledges(c_source, c_loan_gid);


/*==============================================================================
  A1a — Population c_bpm_object_id на всей MATCHED-популяции (не только
  внутри уже найденных 567 дублей — базовая ставка по source)
==============================================================================*/
SELECT @CaseRun AS case_run, 'A1a_BPM_OBJECT_ID_POPULATION' AS result_set,
       c_source AS source,
       COUNT_BIG(*) AS matched_pledges_rows,
       SUM(CASE WHEN c_bpm_object_id IS NOT NULL THEN 1 ELSE 0 END) AS rows_with_bpm_object_id,
       CAST(100.0 * SUM(CASE WHEN c_bpm_object_id IS NOT NULL THEN 1 ELSE 0 END)
            / NULLIF(COUNT_BIG(*), 0) AS decimal(6,2)) AS pct_with_bpm_object_id
FROM #matched_pledges
GROUP BY c_source
ORDER BY source
OPTION (MAXDOP 1);


/*==============================================================================
  A1b — Кросс-договорная проверка "общего залога" (C2/L9.4): для
  collateral_id, используемого > 1 договором, bpm_object_id стабилен
  (легитимное совместное обеспечение) или расходится (та же коллизия
  идентификатора, замаскированная под "shared collateral")?
==============================================================================*/
IF OBJECT_ID('tempdb..#shared_collateral') IS NOT NULL DROP TABLE #shared_collateral;
SELECT c_source, c_collateral_id,
       COUNT(DISTINCT c_loan_gid) AS distinct_loans,
       COUNT(DISTINCT c_bpm_object_id) AS distinct_bpm_object_ids,
       SUM(CASE WHEN c_bpm_object_id IS NULL THEN 1 ELSE 0 END) AS null_bpm_rows
INTO #shared_collateral
FROM #matched_pledges
WHERE c_collateral_id IS NOT NULL
GROUP BY c_source, c_collateral_id
HAVING COUNT(DISTINCT c_loan_gid) > 1
OPTION (MAXDOP 1);

SELECT @CaseRun AS case_run, 'A1b_SHARED_COLLATERAL_BPM_CONSISTENCY' AS result_set,
       c_source AS source,
       CASE
           WHEN null_bpm_rows > 0 THEN 'BPM_PARTIALLY_NULL_CANNOT_CONFIRM'
           WHEN distinct_bpm_object_ids = 1 THEN 'CONSISTENT (легитимное совместное обеспечение)'
           ELSE 'INCONSISTENT (та же коллизия идентификатора, не настоящее совместное обеспечение)'
       END AS bpm_consistency_class,
       COUNT_BIG(*) AS collateral_id_groups
FROM #shared_collateral
GROUP BY c_source,
       CASE
           WHEN null_bpm_rows > 0 THEN 'BPM_PARTIALLY_NULL_CANNOT_CONFIRM'
           WHEN distinct_bpm_object_ids = 1 THEN 'CONSISTENT (легитимное совместное обеспечение)'
           ELSE 'INCONSISTENT (та же коллизия идентификатора, не настоящее совместное обеспечение)'
       END
ORDER BY source, bpm_consistency_class
OPTION (MAXDOP 1);

DROP TABLE #shared_collateral;


/*==============================================================================
  B1 — Покрытие по КОЛИЧЕСТВУ договоров, %, по source
==============================================================================*/
SELECT @CaseRun AS case_run, 'B1_LOAN_COUNT_COVERAGE' AS result_set,
       source, has_collateral,
       COUNT_BIG(*) AS loans,
       CAST(100.0 * COUNT_BIG(*) / SUM(COUNT_BIG(*)) OVER (PARTITION BY source) AS decimal(6,2)) AS pct_of_source
FROM (
    SELECT k.l_source AS source,
           CASE WHEN EXISTS (SELECT 1 FROM #matched_pledges p WHERE p.c_source = k.l_source AND p.c_loan_gid = k.l_gid)
                THEN 'HAS_COLLATERAL' ELSE 'NO_COLLATERAL' END AS has_collateral
    FROM #loans_active_keys k
) t
GROUP BY source, has_collateral
ORDER BY source, has_collateral
OPTION (MAXDOP 1);


/*==============================================================================
  Дедупликация до "один представитель на объект" — методология из шапки
==============================================================================*/
IF OBJECT_ID('tempdb..#object_rep') IS NOT NULL DROP TABLE #object_rep;
;WITH ranked AS (
    SELECT c_source, c_loan_gid,
           COALESCE(N'BPM:' + CAST(c_bpm_object_id AS nvarchar(30)), N'CID:' + CAST(CAST(c_collateral_id AS bigint) AS nvarchar(30))) AS object_key,
           c_collateral_value,
           ROW_NUMBER() OVER (
               PARTITION BY c_source, c_loan_gid,
                   COALESCE(N'BPM:' + CAST(c_bpm_object_id AS nvarchar(30)), N'CID:' + CAST(CAST(c_collateral_id AS bigint) AS nvarchar(30)))
               ORDER BY last_appraisal_date DESC, c_collateral_value DESC
           ) AS rn
    FROM #matched_pledges
)
SELECT c_source, c_loan_gid, object_key, c_collateral_value
INTO #object_rep
FROM ranked
WHERE rn = 1
OPTION (MAXDOP 1);
CREATE CLUSTERED INDEX ix_or ON #object_rep(c_source, c_loan_gid);


/*==============================================================================
  B2 — Покрытие по СТОИМОСТИ: Σ(стоимость залога, 1 строка/объект) /
  Σ(l_loan_amount), агрегат по source + распределение коэффициента по договору
==============================================================================*/
IF OBJECT_ID('tempdb..#loan_collateral_value') IS NOT NULL DROP TABLE #loan_collateral_value;
SELECT c_source, c_loan_gid,
       SUM(c_collateral_value) AS total_collateral_value,
       COUNT_BIG(*) AS distinct_objects
INTO #loan_collateral_value
FROM #object_rep
GROUP BY c_source, c_loan_gid
OPTION (MAXDOP 1);
CREATE CLUSTERED INDEX ix_lcv ON #loan_collateral_value(c_source, c_loan_gid);

SELECT @CaseRun AS case_run, 'B2a_AGGREGATE_VALUE_COVERAGE' AS result_set,
       k.l_source AS source,
       SUM(ISNULL(v.total_collateral_value, 0)) AS sum_collateral_value,
       SUM(k.l_loan_amount) AS sum_loan_amount,
       CAST(100.0 * SUM(ISNULL(v.total_collateral_value, 0)) / NULLIF(SUM(k.l_loan_amount), 0) AS decimal(8,2)) AS pct_covered_aggregate
FROM #loans_active_keys k
LEFT JOIN #loan_collateral_value v ON v.c_source = k.l_source AND v.c_loan_gid = k.l_gid
GROUP BY k.l_source
ORDER BY source
OPTION (MAXDOP 1);

SELECT @CaseRun AS case_run, 'B2b_PER_LOAN_COVERAGE_DISTRIBUTION' AS result_set,
       source, coverage_bucket,
       COUNT_BIG(*) AS loans_in_bucket
FROM (
    SELECT k.l_source AS source,
           CASE
               WHEN v.total_collateral_value IS NULL THEN '0% (нет залога)'
               WHEN k.l_loan_amount IS NULL OR k.l_loan_amount = 0 THEN 'LOAN_AMOUNT_NULL_OR_ZERO'
               WHEN v.total_collateral_value / k.l_loan_amount < 0.5 THEN '<50%'
               WHEN v.total_collateral_value / k.l_loan_amount < 1.0 THEN '50-100%'
               WHEN v.total_collateral_value / k.l_loan_amount < 1.5 THEN '100-150%'
               WHEN v.total_collateral_value / k.l_loan_amount < 3.0 THEN '150-300%'
               ELSE '>300%'
           END AS coverage_bucket
    FROM #loans_active_keys k
    LEFT JOIN #loan_collateral_value v ON v.c_source = k.l_source AND v.c_loan_gid = k.l_gid
) t
GROUP BY source, coverage_bucket
ORDER BY source, coverage_bucket
OPTION (MAXDOP 1);


/*==============================================================================
  B3 — Доля покрытия (B2), приходящаяся на договоры, УЖЕ помеченные как
  затронутые известной коллизией идентификатора (FINDINGS §D4.1) — не выдавать
  "чистую" цифру там, где под ней подтверждённый дефект
==============================================================================*/
IF OBJECT_ID('tempdb..#affected_loans') IS NOT NULL DROP TABLE #affected_loans;
SELECT DISTINCT c_source, c_loan_gid
INTO #affected_loans
FROM #matched_pledges
WHERE c_collateral_id IS NOT NULL
GROUP BY c_source, c_loan_gid, c_collateral_id
HAVING COUNT(DISTINCT c_bpm_object_id) > 1
OPTION (MAXDOP 1);
-- Примечание: GROUP BY внутри INTO — считает по (loan,collateral_id); DISTINCT снаружи убирает
-- дубли, если у договора несколько затронутых collateral_id.

SELECT @CaseRun AS case_run, 'B3_KNOWN_DEFECT_IMPACT_ON_COVERAGE' AS result_set,
       k.l_source AS source,
       SUM(CASE WHEN af.c_loan_gid IS NOT NULL THEN 1 ELSE 0 END) AS loans_affected_by_id_collision,
       SUM(CASE WHEN af.c_loan_gid IS NOT NULL THEN ISNULL(v.total_collateral_value,0) ELSE 0 END) AS collateral_value_under_affected_loans,
       SUM(ISNULL(v.total_collateral_value, 0)) AS total_collateral_value_all_matched,
       CAST(100.0 * SUM(CASE WHEN af.c_loan_gid IS NOT NULL THEN ISNULL(v.total_collateral_value,0) ELSE 0 END)
            / NULLIF(SUM(ISNULL(v.total_collateral_value, 0)), 0) AS decimal(6,2)) AS pct_of_covered_value_under_known_defect
FROM #loans_active_keys k
LEFT JOIN #loan_collateral_value v ON v.c_source = k.l_source AND v.c_loan_gid = k.l_gid
LEFT JOIN #affected_loans af ON af.c_source = k.l_source AND af.c_loan_gid = k.l_gid
GROUP BY k.l_source
ORDER BY source
OPTION (MAXDOP 1);

DROP TABLE #affected_loans;
DROP TABLE #loan_collateral_value;
DROP TABLE #object_rep;
DROP TABLE #matched_pledges;
DROP TABLE #loans_active_keys;
