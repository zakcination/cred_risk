/*==============================================================================
  DWH_SCENARIOS_L1_EASY — сценарии E01–E35 (уровень 1: одна таблица)

  Исполняемая версия набора из `docs/analysis/risk_dwh_reconciliation/
  DWH_TEST_SCENARIOS.md`. Каждый результат помечен `scenario` = ID сценария,
  чтобы вывод сопоставлялся с таблицей ловушек T1–T25 построчно.

  ЧТО ЭТО ТЕСТИРУЕТ (уровень 1): населённость полей, домены значений,
  фактические типы, NULL-семантику. Ключи и связи здесь НЕ проверяются —
  это уровни 2/3.

  ПРАВИЛА (CLAUDE.md, не нарушать):
  - Только SELECT, read-only. MAXDOP 1 на тяжёлых.
  - Без PII: ни ИИН/ФИО/номеров договоров/IBAN в выводе. Только агрегаты.
  - @AsOf резолвится ОТ ФАКТА, не хардкодится — жёсткая дата уже один раз
    дала 0 строк во всём скрипте (FINDINGS §9.7: историзации нет, снимок
    перезаписывается).

  ЧИТАТЬ ВЫВОД ТАК: «0» никогда не означает «чисто» автоматически. Для S02
  отсутствие продукта (T9) и отсутствие залогов (T10) — свойство продукта;
  для S17 пустой l_collateral_id (T11) при живых залогах — свойство модели.
  Дефект от нормы отличает разрез по source, а не общий итог.
==============================================================================*/

USE [Dictionaries];
SET NOCOUNT ON;

DECLARE @Suite  varchar(60) = 'L1_EASY';
DECLARE @AsOf   date = (SELECT MAX(l_report_date) FROM [Dictionaries].[risk_analytics].[loans_active]);
DECLARE @StaleAppraisalMonths int = 24;   -- E29: порог устаревания оценки залога

SELECT @Suite AS suite, '00_SCOPE' AS scenario, @AsOf AS resolved_asof,
       @StaleAppraisalMonths AS stale_appraisal_months
OPTION (MAXDOP 1);


/*---------------------------------------------------------------- E01 ------*/
SELECT @Suite AS suite, 'E01_ACTIVE_BY_SOURCE' AS scenario,
       l_source AS source, COUNT_BIG(*) AS active_loans
FROM [Dictionaries].[risk_analytics].[loans_active] WHERE l_report_date = @AsOf
GROUP BY l_source ORDER BY source OPTION (MAXDOP 1);

/*---- E02: T9 — у S02 ожидается 100% NULL, это не пустой портфель ----------*/
SELECT @Suite AS suite, 'E02_PRODUCT_MIX' AS scenario,
       l_source AS source,
       ISNULL(l_product_type, N'(NULL)') AS product_type,
       COUNT_BIG(*) AS loans
FROM [Dictionaries].[risk_analytics].[loans] WHERE l_report_date = @AsOf
GROUP BY l_source, ISNULL(l_product_type, N'(NULL)')
ORDER BY source, loans DESC OPTION (MAXDOP 1);

/*---- E03: один код филиала должен давать ровно одно название --------------*/
SELECT @Suite AS suite, 'E03_BRANCH_CODE_NAME_CONSISTENCY' AS scenario,
       COUNT_BIG(*) AS distinct_branch_codes,
       SUM(CASE WHEN name_variants > 1 THEN 1 ELSE 0 END) AS codes_with_multiple_names,
       MAX(name_variants) AS max_names_per_code
FROM (
    SELECT l_branch_code, COUNT(DISTINCT l_branch_name) AS name_variants
    FROM [Dictionaries].[risk_analytics].[loans]
    WHERE l_report_date = @AsOf AND l_branch_code IS NOT NULL
    GROUP BY l_branch_code
) b OPTION (MAXDOP 1);

/*---------------------------------------------------------------- E04 ------*/
SELECT @Suite AS suite, 'E04_CURRENCY_DOMAIN' AS scenario,
       ISNULL(l_currency, N'(NULL)') AS currency, COUNT_BIG(*) AS loans
FROM [Dictionaries].[risk_analytics].[loans] WHERE l_report_date = @AsOf
GROUP BY ISNULL(l_currency, N'(NULL)') ORDER BY loans DESC OPTION (MAXDOP 1);

/*---- E05: отрицательные/нулевые/аномальные сроки --------------------------*/
SELECT @Suite AS suite, 'E05_TERM_BUCKETS' AS scenario,
       l_source AS source,
       CASE WHEN l_initial_term_months IS NULL THEN '(NULL)'
            WHEN l_initial_term_months <= 0    THEN '<=0 (АНОМАЛИЯ)'
            WHEN l_initial_term_months <= 12   THEN '01-12'
            WHEN l_initial_term_months <= 36   THEN '13-36'
            WHEN l_initial_term_months <= 60   THEN '37-60'
            WHEN l_initial_term_months <= 360  THEN '61-360'
            ELSE '>360 (АНОМАЛИЯ)' END AS term_bucket,
       COUNT_BIG(*) AS loans
FROM [Dictionaries].[risk_analytics].[loans] WHERE l_report_date = @AsOf
GROUP BY l_source,
       CASE WHEN l_initial_term_months IS NULL THEN '(NULL)'
            WHEN l_initial_term_months <= 0    THEN '<=0 (АНОМАЛИЯ)'
            WHEN l_initial_term_months <= 12   THEN '01-12'
            WHEN l_initial_term_months <= 36   THEN '13-36'
            WHEN l_initial_term_months <= 60   THEN '37-60'
            WHEN l_initial_term_months <= 360  THEN '61-360'
            ELSE '>360 (АНОМАЛИЯ)' END
ORDER BY source, term_bucket OPTION (MAXDOP 1);

/*---- E06: децили суммы. Считаем по активному периметру (577к), не по всей
      loans (8,26 млн) — сортировка под MAXDOP 1 иначе неоправданно дорога.
      Ноль и отрицательные вынесены отдельно, а не растворены в 1-мville. ---*/
SELECT @Suite AS suite, 'E06a_AMOUNT_SANITY' AS scenario,
       l_source AS source,
       SUM(CASE WHEN l_loan_amount IS NULL THEN 1 ELSE 0 END) AS null_amount,
       SUM(CASE WHEN l_loan_amount < 0     THEN 1 ELSE 0 END) AS negative_amount,
       SUM(CASE WHEN l_loan_amount = 0     THEN 1 ELSE 0 END) AS zero_amount,
       COUNT_BIG(*) AS rows_total
FROM [Dictionaries].[risk_analytics].[loans_active] WHERE l_report_date = @AsOf
GROUP BY l_source ORDER BY source OPTION (MAXDOP 1);

SELECT @Suite AS suite, 'E06b_AMOUNT_DECILES' AS scenario,
       decile, COUNT_BIG(*) AS loans,
       MIN(l_loan_amount) AS min_amount, MAX(l_loan_amount) AS max_amount,
       CAST(AVG(l_loan_amount) AS decimal(38,2)) AS avg_amount
FROM (
    SELECT l_loan_amount, NTILE(10) OVER (ORDER BY l_loan_amount) AS decile
    FROM [Dictionaries].[risk_analytics].[loans_active]
    WHERE l_report_date = @AsOf AND l_loan_amount > 0
) d GROUP BY decile ORDER BY decile OPTION (MAXDOP 1);

/*---- E07: T25 — l_rate varchar. СНАЧАЛА аудит нечисловых, потом среднее ---*/
SELECT @Suite AS suite, 'E07a_RATE_TYPE_AUDIT' AS scenario,
       l_source AS source,
       COUNT_BIG(*) AS rows_total,
       SUM(CASE WHEN l_rate IS NULL THEN 1 ELSE 0 END) AS rate_null,
       SUM(CASE WHEN l_rate IS NOT NULL AND TRY_CONVERT(decimal(18,6), l_rate) IS NULL
                THEN 1 ELSE 0 END) AS rate_not_numeric
FROM [Dictionaries].[risk_analytics].[loans] WHERE l_report_date = @AsOf
GROUP BY l_source ORDER BY source OPTION (MAXDOP 1);

SELECT @Suite AS suite, 'E07b_RATE_BY_PRODUCT' AS scenario,
       l_source AS source, ISNULL(l_product_type, N'(NULL)') AS product_type,
       COUNT_BIG(*) AS loans_with_numeric_rate,
       CAST(MIN(TRY_CONVERT(decimal(18,6), l_rate)) AS decimal(18,4)) AS min_rate,
       CAST(AVG(TRY_CONVERT(decimal(18,6), l_rate)) AS decimal(18,4)) AS avg_rate,
       CAST(MAX(TRY_CONVERT(decimal(18,6), l_rate)) AS decimal(18,4)) AS max_rate
FROM [Dictionaries].[risk_analytics].[loans]
WHERE l_report_date = @AsOf AND TRY_CONVERT(decimal(18,6), l_rate) IS NOT NULL
GROUP BY l_source, ISNULL(l_product_type, N'(NULL)')
ORDER BY source, product_type OPTION (MAXDOP 1);

/*---- E08: open_date vs funding_date — что считать «выдачей» ---------------*/
SELECT @Suite AS suite, 'E08_ORIGINATION_BY_MONTH' AS scenario,
       l_source AS source,
       CONVERT(char(7), l_loan_open_date, 126) AS open_month,
       COUNT_BIG(*) AS loans_opened,
       SUM(CASE WHEN l_funding_date IS NULL THEN 1 ELSE 0 END) AS no_funding_date,
       SUM(CASE WHEN l_funding_date < l_loan_open_date THEN 1 ELSE 0 END) AS funded_before_open_ANOMALY
FROM [Dictionaries].[risk_analytics].[loans]
WHERE l_report_date = @AsOf
  AND l_loan_open_date >= DATEADD(MONTH, -12, @AsOf) AND l_loan_open_date <= @AsOf
GROUP BY l_source, CONVERT(char(7), l_loan_open_date, 126)
ORDER BY source, open_month OPTION (MAXDOP 1);

/*---------------------------------------------------------------- E09 ------*/
SELECT @Suite AS suite, 'E09_NO_ACTUAL_CLOSURE' AS scenario,
       l_source AS source, COUNT_BIG(*) AS loans_without_closure_date
FROM [Dictionaries].[risk_analytics].[loans]
WHERE l_report_date = @AsOf AND l_actual_closure_date IS NULL
GROUP BY l_source ORDER BY source OPTION (MAXDOP 1);

/*---- E10: срок вышел, а договор не закрыт --------------------------------*/
SELECT @Suite AS suite, 'E10_MATURED_NOT_CLOSED' AS scenario,
       l_source AS source, COUNT_BIG(*) AS matured_but_open
FROM [Dictionaries].[risk_analytics].[loans]
WHERE l_report_date = @AsOf
  AND l_loan_maturity_date IS NOT NULL AND l_loan_maturity_date < @AsOf
  AND l_actual_closure_date IS NULL
GROUP BY l_source ORDER BY source OPTION (MAXDOP 1);

/*---- E11: T12 — ожидается 100% NULL по l_limit ----------------------------*/
SELECT @Suite AS suite, 'E11_LIMIT_FILL_RATE' AS scenario,
       l_source AS source, COUNT_BIG(*) AS rows_total,
       SUM(CASE WHEN l_limit IS NOT NULL THEN 1 ELSE 0 END) AS limit_filled,
       SUM(CASE WHEN l_unutilized_limit IS NOT NULL THEN 1 ELSE 0 END) AS unutilized_filled
FROM [Dictionaries].[risk_analytics].[loans] WHERE l_report_date = @AsOf
GROUP BY l_source ORDER BY source OPTION (MAXDOP 1);

/*---------------------------------------------------------------- E12 ------*/
SELECT @Suite AS suite, 'E12_STATUS_DOMAIN' AS scenario,
       l_source AS source, ISNULL(l_loan_status, N'(NULL)') AS loan_status,
       COUNT_BIG(*) AS loans
FROM [Dictionaries].[risk_analytics].[loans] WHERE l_report_date = @AsOf
GROUP BY l_source, ISNULL(l_loan_status, N'(NULL)')
ORDER BY source, loans DESC OPTION (MAXDOP 1);

/*---------------------------------------------------------------- E13 ------*/
SELECT @Suite AS suite, 'E13_BORROWERS_BY_REGION' AS scenario,
       ISNULL(b_region, N'(NULL)') AS region, COUNT_BIG(*) AS borrowers
FROM [Dictionaries].[risk_analytics].[borrower] WHERE b_report_date = @AsOf
GROUP BY ISNULL(b_region, N'(NULL)') ORDER BY borrowers DESC OPTION (MAXDOP 1);

/*---- E14: тип клиента vs флаг ИП — согласованность ------------------------*/
SELECT @Suite AS suite, 'E14_BORROWER_TYPE_VS_IE_FLAG' AS scenario,
       ISNULL(b_borrower_type, N'(NULL)') AS borrower_type,
       ISNULL(b_individual_entrepreneur_flag, N'(NULL)') AS ie_flag,
       COUNT_BIG(*) AS borrowers
FROM [Dictionaries].[risk_analytics].[borrower] WHERE b_report_date = @AsOf
GROUP BY ISNULL(b_borrower_type, N'(NULL)'), ISNULL(b_individual_entrepreneur_flag, N'(NULL)')
ORDER BY borrowers DESC OPTION (MAXDOP 1);

/*---- E15: возраст. 1900-01-01 и будущее — отдельными бакетами -------------*/
SELECT @Suite AS suite, 'E15_AGE_BUCKETS' AS scenario,
       CASE WHEN b_date_of_birth IS NULL THEN '(NULL)'
            WHEN b_date_of_birth > @AsOf THEN 'ДАТА В БУДУЩЕМ (АНОМАЛИЯ)'
            WHEN b_date_of_birth <= '1901-01-01' THEN '<=1901 (заглушка «нет данных»)'
            WHEN DATEDIFF(YEAR, b_date_of_birth, @AsOf) < 18 THEN '<18 (АНОМАЛИЯ)'
            WHEN DATEDIFF(YEAR, b_date_of_birth, @AsOf) <= 25 THEN '18-25'
            WHEN DATEDIFF(YEAR, b_date_of_birth, @AsOf) <= 35 THEN '26-35'
            WHEN DATEDIFF(YEAR, b_date_of_birth, @AsOf) <= 45 THEN '36-45'
            WHEN DATEDIFF(YEAR, b_date_of_birth, @AsOf) <= 60 THEN '46-60'
            WHEN DATEDIFF(YEAR, b_date_of_birth, @AsOf) <= 100 THEN '61-100'
            ELSE '>100 (АНОМАЛИЯ)' END AS age_bucket,
       COUNT_BIG(*) AS borrowers
FROM [Dictionaries].[risk_analytics].[borrower] WHERE b_report_date = @AsOf
GROUP BY
       CASE WHEN b_date_of_birth IS NULL THEN '(NULL)'
            WHEN b_date_of_birth > @AsOf THEN 'ДАТА В БУДУЩЕМ (АНОМАЛИЯ)'
            WHEN b_date_of_birth <= '1901-01-01' THEN '<=1901 (заглушка «нет данных»)'
            WHEN DATEDIFF(YEAR, b_date_of_birth, @AsOf) < 18 THEN '<18 (АНОМАЛИЯ)'
            WHEN DATEDIFF(YEAR, b_date_of_birth, @AsOf) <= 25 THEN '18-25'
            WHEN DATEDIFF(YEAR, b_date_of_birth, @AsOf) <= 35 THEN '26-35'
            WHEN DATEDIFF(YEAR, b_date_of_birth, @AsOf) <= 45 THEN '36-45'
            WHEN DATEDIFF(YEAR, b_date_of_birth, @AsOf) <= 60 THEN '46-60'
            WHEN DATEDIFF(YEAR, b_date_of_birth, @AsOf) <= 100 THEN '61-100'
            ELSE '>100 (АНОМАЛИЯ)' END
ORDER BY age_bucket OPTION (MAXDOP 1);

/*---- E16: домен флага банкротства (тип varchar(max)) ----------------------*/
SELECT @Suite AS suite, 'E16_BANKRUPTCY_FLAG_DOMAIN' AS scenario,
       CONVERT(nvarchar(100), ISNULL(b_bankruptcy_flag, N'(NULL)')) AS bankruptcy_flag_value,
       ISNULL(b_bankruptcy_type, N'(NULL)') AS bankruptcy_type,
       COUNT_BIG(*) AS borrowers
FROM [Dictionaries].[risk_analytics].[borrower] WHERE b_report_date = @AsOf
GROUP BY CONVERT(nvarchar(100), ISNULL(b_bankruptcy_flag, N'(NULL)')),
         ISNULL(b_bankruptcy_type, N'(NULL)')
ORDER BY borrowers DESC OPTION (MAXDOP 1);

/*---- E17: POCI-флаг и дата присвоения — согласованы? ---------------------*/
SELECT @Suite AS suite, 'E17_POCI_FLAG_VS_DATE' AS scenario,
       CONVERT(nvarchar(100), ISNULL(b_poci_flag, N'(NULL)')) AS poci_flag,
       CASE WHEN b_poci_assignment_date IS NULL THEN 'ДАТА ПУСТА' ELSE 'ДАТА ЕСТЬ' END AS poci_date_state,
       COUNT_BIG(*) AS borrowers
FROM [Dictionaries].[risk_analytics].[borrower] WHERE b_report_date = @AsOf
GROUP BY CONVERT(nvarchar(100), ISNULL(b_poci_flag, N'(NULL)')),
         CASE WHEN b_poci_assignment_date IS NULL THEN 'ДАТА ПУСТА' ELSE 'ДАТА ЕСТЬ' END
ORDER BY borrowers DESC OPTION (MAXDOP 1);

/*---- E18: доход. numeric(10,0) — потолок ~9,99 млрд, для ЮЛ мало ----------*/
SELECT @Suite AS suite, 'E18_INCOME_DISTRIBUTION' AS scenario,
       ISNULL(b_borrower_type, N'(NULL)') AS borrower_type,
       CASE WHEN b_monthly_income IS NULL THEN '(NULL)'
            WHEN b_monthly_income = 0 THEN '0 (нет данных или реально ноль?)'
            WHEN b_monthly_income < 0 THEN '<0 (АНОМАЛИЯ)'
            WHEN b_monthly_income <= 200000 THEN '<=200k'
            WHEN b_monthly_income <= 500000 THEN '200k-500k'
            WHEN b_monthly_income <= 1000000 THEN '500k-1M'
            ELSE '>1M' END AS income_bucket,
       COUNT_BIG(*) AS borrowers
FROM [Dictionaries].[risk_analytics].[borrower] WHERE b_report_date = @AsOf
GROUP BY ISNULL(b_borrower_type, N'(NULL)'),
       CASE WHEN b_monthly_income IS NULL THEN '(NULL)'
            WHEN b_monthly_income = 0 THEN '0 (нет данных или реально ноль?)'
            WHEN b_monthly_income < 0 THEN '<0 (АНОМАЛИЯ)'
            WHEN b_monthly_income <= 200000 THEN '<=200k'
            WHEN b_monthly_income <= 500000 THEN '200k-500k'
            WHEN b_monthly_income <= 1000000 THEN '500k-1M'
            ELSE '>1M' END
ORDER BY borrower_type, income_bucket OPTION (MAXDOP 1);

/*---------------------------------------------------------------- E19 ------*/
SELECT @Suite AS suite, 'E19_NON_RESIDENT' AS scenario,
       ISNULL(b_non_resident_flag, N'(NULL)') AS non_resident_flag,
       COUNT_BIG(*) AS borrowers
FROM [Dictionaries].[risk_analytics].[borrower] WHERE b_report_date = @AsOf
GROUP BY ISNULL(b_non_resident_flag, N'(NULL)') ORDER BY borrowers DESC OPTION (MAXDOP 1);

/*---------------------------------------------------------------- E20 ------*/
SELECT @Suite AS suite, 'E20_DECEASED_BORROWERS' AS scenario,
       COUNT_BIG(*) AS borrowers_with_death_date,
       SUM(CASE WHEN b_date_of_death > @AsOf THEN 1 ELSE 0 END) AS death_date_in_future_ANOMALY
FROM [Dictionaries].[risk_analytics].[borrower]
WHERE b_report_date = @AsOf AND b_date_of_death IS NOT NULL OPTION (MAXDOP 1);

/*---- E21: устаревание рейтинга клиента -----------------------------------*/
SELECT @Suite AS suite, 'E21_CLIENT_RATING_STALENESS' AS scenario,
       CASE WHEN b_client_rating IS NULL THEN 'РЕЙТИНГА НЕТ'
            WHEN b_client_rating_date IS NULL THEN 'РЕЙТИНГ ЕСТЬ, ДАТЫ НЕТ'
            WHEN b_client_rating_date < DATEADD(MONTH, -12, @AsOf) THEN 'СТАРШЕ 12 МЕС'
            ELSE 'АКТУАЛЕН (<=12 МЕС)' END AS rating_state,
       COUNT_BIG(*) AS borrowers
FROM [Dictionaries].[risk_analytics].[borrower] WHERE b_report_date = @AsOf
GROUP BY CASE WHEN b_client_rating IS NULL THEN 'РЕЙТИНГА НЕТ'
              WHEN b_client_rating_date IS NULL THEN 'РЕЙТИНГ ЕСТЬ, ДАТЫ НЕТ'
              WHEN b_client_rating_date < DATEADD(MONTH, -12, @AsOf) THEN 'СТАРШЕ 12 МЕС'
              ELSE 'АКТУАЛЕН (<=12 МЕС)' END
ORDER BY borrowers DESC OPTION (MAXDOP 1);

/*---- E22: T15 — балансы между источниками НЕ сопоставимы напрямую ---------*/
SELECT @Suite AS suite, 'E22_BALANCE_BY_SOURCE' AS scenario,
       la_source AS source, COUNT_BIG(*) AS accounts,
       CAST(SUM(total_balance_debt)      AS decimal(38,2)) AS sum_total_balance_debt,
       CAST(SUM(principal_balance_debt)  AS decimal(38,2)) AS sum_principal_balance,
       CAST(SUM(discounted_balance_debt) AS decimal(38,2)) AS sum_discounted_balance
FROM [Dictionaries].[risk_analytics].[loan_account] WHERE la_reporting_date = @AsOf
GROUP BY la_source ORDER BY source OPTION (MAXDOP 1);

/*---- E23: T13 off-by-one, T14 NULL≠0. Оба показаны явно ------------------*/
SELECT @Suite AS suite, 'E23_DPD_BUCKETS' AS scenario,
       la_source AS source,
       CASE WHEN days_past_due IS NULL THEN '(NULL) — НЕ РАВНО 0'
            WHEN days_past_due < 0  THEN '<0 (АНОМАЛИЯ)'
            WHEN days_past_due = 0  THEN '0'
            WHEN days_past_due <= 30 THEN '1-30'
            WHEN days_past_due <= 60 THEN '31-60'
            WHEN days_past_due <= 90 THEN '61-90'
            ELSE '90+' END AS dpd_bucket,
       COUNT_BIG(*) AS accounts
FROM [Dictionaries].[risk_analytics].[loan_account] WHERE la_reporting_date = @AsOf
GROUP BY la_source,
       CASE WHEN days_past_due IS NULL THEN '(NULL) — НЕ РАВНО 0'
            WHEN days_past_due < 0  THEN '<0 (АНОМАЛИЯ)'
            WHEN days_past_due = 0  THEN '0'
            WHEN days_past_due <= 30 THEN '1-30'
            WHEN days_past_due <= 60 THEN '31-60'
            WHEN days_past_due <= 90 THEN '61-90'
            ELSE '90+' END
ORDER BY source, dpd_bucket OPTION (MAXDOP 1);

/*---- E24: T19 — бакет формируется независимо от DPD-полей -----------------*/
SELECT @Suite AS suite, 'E24_DELINQUENCY_BUCKET' AS scenario,
       la_source AS source,
       ISNULL(CONVERT(varchar(20), delinquency_bucket), '(NULL)') AS delinquency_bucket,
       COUNT_BIG(*) AS accounts
FROM [Dictionaries].[risk_analytics].[loan_account] WHERE la_reporting_date = @AsOf
GROUP BY la_source, ISNULL(CONVERT(varchar(20), delinquency_bucket), '(NULL)')
ORDER BY source, delinquency_bucket OPTION (MAXDOP 1);

/*---- E25: ключевые счета ГК, в т.ч. спорный 18771 -------------------------*/
SELECT @Suite AS suite, 'E25_KEY_GL_ACCOUNTS' AS scenario,
       la_source AS source,
       SUM(CASE WHEN la_account_1401  <> 0 THEN 1 ELSE 0 END) AS nonzero_1401,
       SUM(CASE WHEN la_account_1428  <> 0 THEN 1 ELSE 0 END) AS nonzero_1428,
       SUM(CASE WHEN la_account_18771 <> 0 THEN 1 ELSE 0 END) AS nonzero_18771,
       SUM(CASE WHEN la_account_1818  <> 0 THEN 1 ELSE 0 END) AS nonzero_1818,
       SUM(CASE WHEN la_account_1838  <> 0 THEN 1 ELSE 0 END) AS nonzero_1838,
       COUNT_BIG(*) AS accounts
FROM [Dictionaries].[risk_analytics].[loan_account] WHERE la_reporting_date = @AsOf
GROUP BY la_source ORDER BY source OPTION (MAXDOP 1);

/*---- E26: T14 — заполненность ВСЕХ DPD-полей. У S17 ожидается 0 по interest */
SELECT @Suite AS suite, 'E26_DPD_FIELD_FILL_RATES' AS scenario,
       la_source AS source, COUNT_BIG(*) AS rows_total,
       SUM(CASE WHEN days_past_due IS NOT NULL THEN 1 ELSE 0 END) AS f_days_past_due,
       SUM(CASE WHEN days_past_due_principal IS NOT NULL THEN 1 ELSE 0 END) AS f_principal,
       SUM(CASE WHEN days_past_due_interest IS NOT NULL THEN 1 ELSE 0 END) AS f_interest,
       SUM(CASE WHEN days_past_due_overdue_principal IS NOT NULL THEN 1 ELSE 0 END) AS f_overdue_principal,
       SUM(CASE WHEN max_days_past_due_principal_interest IS NOT NULL THEN 1 ELSE 0 END) AS f_max_pi
FROM [Dictionaries].[risk_analytics].[loan_account] WHERE la_reporting_date = @AsOf
GROUP BY la_source ORDER BY source OPTION (MAXDOP 1);

/*---------------------------------------------------------------- E27 ------*/
SELECT @Suite AS suite, 'E27_COLLATERAL_TYPE_MIX' AS scenario,
       c_source AS source, ISNULL(c_collateral_type, N'(NULL)') AS collateral_type,
       COUNT_BIG(*) AS pledge_rows
FROM [Dictionaries].[risk_analytics].[pledges] WHERE c_reporting_date = @AsOf
GROUP BY c_source, ISNULL(c_collateral_type, N'(NULL)')
ORDER BY source, pledge_rows DESC OPTION (MAXDOP 1);

/*---- E28: марки авто — свободный текст, нужна нормализация ---------------*/
SELECT TOP (20) @Suite AS suite, 'E28_TOP_CAR_BRANDS' AS scenario,
       ISNULL(c_car_brand, N'(NULL)') AS car_brand, COUNT_BIG(*) AS pledge_rows
FROM [Dictionaries].[risk_analytics].[pledges]
WHERE c_reporting_date = @AsOf AND c_car_brand IS NOT NULL
GROUP BY ISNULL(c_car_brand, N'(NULL)') ORDER BY pledge_rows DESC OPTION (MAXDOP 1);

/*---- E29: устаревание оценки залога — регуляторное требование ------------*/
SELECT @Suite AS suite, 'E29_STALE_APPRAISAL' AS scenario,
       c_source AS source,
       CASE WHEN last_appraisal_date IS NULL THEN 'ДАТЫ ОЦЕНКИ НЕТ'
            WHEN last_appraisal_date > @AsOf THEN 'ДАТА В БУДУЩЕМ (АНОМАЛИЯ)'
            WHEN last_appraisal_date < DATEADD(MONTH, -@StaleAppraisalMonths, @AsOf)
                 THEN 'УСТАРЕЛА (>порога)'
            ELSE 'АКТУАЛЬНА' END AS appraisal_state,
       COUNT_BIG(*) AS pledge_rows
FROM [Dictionaries].[risk_analytics].[pledges] WHERE c_reporting_date = @AsOf
GROUP BY c_source,
       CASE WHEN last_appraisal_date IS NULL THEN 'ДАТЫ ОЦЕНКИ НЕТ'
            WHEN last_appraisal_date > @AsOf THEN 'ДАТА В БУДУЩЕМ (АНОМАЛИЯ)'
            WHEN last_appraisal_date < DATEADD(MONTH, -@StaleAppraisalMonths, @AsOf)
                 THEN 'УСТАРЕЛА (>порога)'
            ELSE 'АКТУАЛЬНА' END
ORDER BY source, appraisal_state OPTION (MAXDOP 1);

/*---------------------------------------------------------------- E30 ------*/
SELECT @Suite AS suite, 'E30_COLLATERAL_VALUE_SANITY' AS scenario,
       c_source AS source, COUNT_BIG(*) AS pledge_rows,
       SUM(CASE WHEN c_collateral_value IS NULL THEN 1 ELSE 0 END) AS value_null,
       SUM(CASE WHEN c_collateral_value = 0 THEN 1 ELSE 0 END) AS value_zero,
       SUM(CASE WHEN c_collateral_value < 0 THEN 1 ELSE 0 END) AS value_negative_ANOMALY,
       CAST(MAX(c_collateral_value) AS decimal(38,2)) AS max_value
FROM [Dictionaries].[risk_analytics].[pledges] WHERE c_reporting_date = @AsOf
GROUP BY c_source ORDER BY source OPTION (MAXDOP 1);

/*---- E31: полнота НОК-блока ----------------------------------------------*/
SELECT @Suite AS suite, 'E31_NOK_BLOCK_COMPLETENESS' AS scenario,
       c_source AS source, COUNT_BIG(*) AS pledge_rows,
       SUM(CASE WHEN nok_appraiser_name IS NULL THEN 1 ELSE 0 END) AS no_appraiser_name,
       SUM(CASE WHEN nok_license_number IS NULL THEN 1 ELSE 0 END) AS no_license,
       SUM(CASE WHEN nok_last_appraised_value IS NULL THEN 1 ELSE 0 END) AS no_nok_value,
       SUM(CASE WHEN nok_accreditation_status IS NULL THEN 1 ELSE 0 END) AS no_accreditation
FROM [Dictionaries].[risk_analytics].[pledges] WHERE c_reporting_date = @AsOf
GROUP BY c_source ORDER BY source OPTION (MAXDOP 1);

/*---- E32: T23 — дубли завышают объём. Смотрим и сырое, и distinct ---------*/
SELECT @Suite AS suite, 'E32_PAYMENTS_BY_MONTH' AS scenario,
       p_source AS source,
       CONVERT(char(7), p_VALUE_DATE, 126) AS value_month,
       COUNT_BIG(*) AS raw_payment_rows,
       COUNT_BIG(DISTINCT CONCAT(p_CREDIT_ACCOUNT, '|', CONVERT(char(10), p_VALUE_DATE, 126), '|', p_total)) AS distinct_payment_signatures,
       CAST(SUM(p_total) AS decimal(38,2)) AS sum_total_raw
FROM [Dictionaries].[risk_analytics].[payments]
WHERE p_VALUE_DATE >= DATEADD(MONTH, -12, @AsOf) AND p_VALUE_DATE <= @AsOf
GROUP BY p_source, CONVERT(char(7), p_VALUE_DATE, 126)
ORDER BY source, value_month OPTION (MAXDOP 1);

/*---- E33: report_date vs restructuring_date ------------------------------*/
SELECT @Suite AS suite, 'E33_RESTRUCTURING_BY_MONTH' AS scenario,
       [dlcr$source] AS source,
       CONVERT(char(7), restructuring_date, 126) AS restr_month,
       COUNT_BIG(*) AS events
FROM [Dictionaries].[risk_analytics].[restructuring_v2]
WHERE restructuring_date >= DATEADD(MONTH, -24, @AsOf) AND restructuring_date <= @AsOf
GROUP BY [dlcr$source], CONVERT(char(7), restructuring_date, 126)
ORDER BY source, restr_month OPTION (MAXDOP 1);

/*---------------------------------------------------------------- E34 ------*/
SELECT @Suite AS suite, 'E34_RESTRUCTURING_CANCELLED' AS scenario,
       [dlcr$source] AS source, COUNT_BIG(*) AS events,
       SUM(CASE WHEN canc_date IS NOT NULL THEN 1 ELSE 0 END) AS cancelled,
       SUM(CASE WHEN canc_date IS NOT NULL AND canc_date < restructuring_date
                THEN 1 ELSE 0 END) AS cancelled_before_start_ANOMALY
FROM [Dictionaries].[risk_analytics].[restructuring_v2]
GROUP BY [dlcr$source] ORDER BY source OPTION (MAXDOP 1);

/*---- E35: единица payment_deferral не документирована — смотрим диапазон --*/
SELECT @Suite AS suite, 'E35_PAYMENT_DEFERRAL_RANGE' AS scenario,
       [dlcr$source] AS source, COUNT_BIG(*) AS events,
       SUM(CASE WHEN payment_deferral IS NULL THEN 1 ELSE 0 END) AS deferral_null,
       MIN(payment_deferral) AS min_deferral,
       CAST(AVG(payment_deferral) AS decimal(18,4)) AS avg_deferral,
       MAX(payment_deferral) AS max_deferral
FROM [Dictionaries].[risk_analytics].[restructuring_v2]
GROUP BY [dlcr$source] ORDER BY source OPTION (MAXDOP 1);
