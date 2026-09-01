/*==============================================================================
  CASE_RUN_PLEDGES_009_S03_CORRECTED_KEY_EVIDENCE

  Уточнение к письму от 17.07.2026 («Результаты проверки справочников
  заёмщиков и залогов на 01.07.2026», п.3 / DWH-15).

  Прежний прогон присоединял pledges к периметру по la_loan_id = t.loan_id —
  ключу, не входящему в подтверждённый канонический набор NEW-internal
  связей. Канонический ключ (тот же паттерн, что loan_account<->loans:
  la_gid=l_gid AND la_source=l_source) — pledges.c_source + c_loan_gid =
  loans_active.l_source + l_gid. Этот скрипт пересчитывает ту же проверку
  по корректному ключу.

  Ограничения:
  - Только SELECT, без изменения данных (MAXDOP 1 на тяжёлых запросах).
  - Без PII: результат только по source, без номеров договоров/ИИН/gid.
  - Не воспроизводит буквально прежний (некорректный) запрос — ниже
    приведено только ранее сообщённое число для контраста, не пересчёт
    старой логики.
  - Баланс не входит в этот прогон (см. письмо — предоставляется отдельно
    после согласования формулы, тот же вопрос, что L6.0 в основном
    check-скрипте: total_balance_debt различается по составу счетов
    между источниками).
==============================================================================*/

USE [Dictionaries];
SET NOCOUNT ON;

DECLARE @CaseRun varchar(120) = 'CASE_RUN_PLEDGES_009_S03_CORRECTED_KEY_EVIDENCE';
DECLARE @AsOf date = '2026-07-01';

-- Ранее сообщённое (письмо от 17.07.2026, DWH-15) — для контраста, НЕ пересчитывается этим запросом.
DECLARE @PriorReportedCount int = 49;
DECLARE @PriorReportedBalance decimal(38,2) = 367700497.14;


/*==============================================================================
  RESULT 00 — Область и метод проверки
==============================================================================*/
SELECT
    @CaseRun AS case_run,
    '00_SCOPE_CONTROL' AS result_set,
    @AsOf AS report_date,
    'pledges.c_source + c_loan_gid = loans_active.l_source + l_gid' AS canonical_key_used,
    'la_loan_id = t.loan_id (прогон 17.07.2026)' AS prior_key_used,
    @PriorReportedCount AS prior_reported_contract_count_S03,
    @PriorReportedBalance AS prior_reported_balance_S03;


/*==============================================================================
  RESULT 01 — Активные договоры с l_collateral_id, но без строки в pledges,
  по корректному ключу, в разрезе source
==============================================================================*/
SELECT
    @CaseRun AS case_run,
    '01_MISSING_PLEDGE_BY_SOURCE_CANONICAL_KEY' AS result_set,
    a.l_source AS source,
    COUNT_BIG(*) AS active_with_collateral_id_but_no_pledge
FROM [Dictionaries].[risk_analytics].[loans_active] a
WHERE a.l_report_date = @AsOf
  AND a.l_collateral_id IS NOT NULL
  AND NOT EXISTS (
      SELECT 1 FROM [Dictionaries].[risk_analytics].[pledges] p
      WHERE p.c_reporting_date = @AsOf
        AND p.c_source = a.l_source
        AND p.c_loan_gid = a.l_gid
  )
GROUP BY a.l_source
ORDER BY active_with_collateral_id_but_no_pledge DESC
OPTION (MAXDOP 1);


/*==============================================================================
  RESULT 02 — Контроль воспроизводимости (ожидание: S03 = 94 732, как в письме)
==============================================================================*/
DECLARE @ActualS03Count int;

SELECT @ActualS03Count = COUNT_BIG(*)
FROM [Dictionaries].[risk_analytics].[loans_active] a
WHERE a.l_report_date = @AsOf
  AND a.l_source = N'S03'
  AND a.l_collateral_id IS NOT NULL
  AND NOT EXISTS (
      SELECT 1 FROM [Dictionaries].[risk_analytics].[pledges] p
      WHERE p.c_reporting_date = @AsOf
        AND p.c_source = a.l_source
        AND p.c_loan_gid = a.l_gid
  )
OPTION (MAXDOP 1);

SELECT
    @CaseRun AS case_run,
    '02_REPRODUCTION_CONTROL' AS result_set,
    @ActualS03Count AS actual_S03_count,
    CONVERT(int, 94732) AS expected_S03_count,
    @PriorReportedCount AS superseded_prior_count,
    CASE
        WHEN @ActualS03Count = 94732 THEN 'MATCHES_LETTER_04_08_2026'
        ELSE 'RESULT_DIFFERS_REVIEW_REQUIRED'
    END AS control_status;
