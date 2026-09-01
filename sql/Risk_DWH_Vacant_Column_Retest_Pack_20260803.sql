/* =============================================================================
   ПРОСТЫМ ЯЗЫКОМ:
   Batch 1 расширения метода Сайлау (side-by-side old-vs-new) на колонки
   Dictionary, которые на BI-холсте (dwh_schema_explorer.html) не были тронуты
   НИ ОДНИМ процессом. Методология и правило отбора (Tier A/B/C) — см.
   docs/analysis/risk_dwh_reconciliation/bi_canvas/SAILAU_METHOD.md.
   Каждая секция ниже = один процесс `vac-*` на холсте. Прогнать целиком или
   по секциям, вставить вывод обратно в разговор/PR — статус соответствующего
   процесса обновится с 'hypothesis' на 'proven'/'verified'/'refuted'.
   -----------------------------------------------------------------------------
   RISK_DWH_VACANT_COLUMN_RETEST_PACK — Batch 1 (loans/loans_active/loan_account/
   borrower/pledges), Tier A only. Дата подготовки: 03.08.2026.
   Контрольный срез: 01.07.2026 (параметр @D в каждой секции).
   =============================================================================

   ПРАВИЛА (не нарушать, см. CLAUDE.md):
   - Read-only. Только SELECT, кроме #temp таблиц.
   - MAXDOP 1 на каждой секции.
   - PII не выводить: только агрегаты (COUNT/SUM), номера договоров/ИИН — нет.
   - Не все source покрыты одинаково в каждой секции — это факт схемы старой
     ветки (S01/S17 vs S02/S03 асимметрия), не пропуск. См. комментарий внутри
     секции, если source меньше четырёх.
   ============================================================================= */

-- =============================================================================
-- SECTION 1 / vac-dates01 — Даты открытия/фондирования, S01+S17
-- l_loan_open_date, l_funding_date vs old.open_date/financing_date
-- S02/S03 НЕ включены: старая схема не имеет этой пары колонок для них.
-- =============================================================================
DECLARE @D date = '2026-07-01';
;WITH s01_old AS (
  SELECT contract_id, open_date, financing_date FROM CL_PORTFOLIO.dbo.PORTFOLIO_RS WHERE actual_date = @D
),
s01_new AS (
  SELECT l_loan_id, l_loan_open_date, l_funding_date FROM Dictionaries.risk_analytics.loans_active
  WHERE l_source = 'S01' AND l_report_date = @D
),
s17_old AS (
  SELECT contractnumber, open_date, financing_date FROM CL_PORTFOLIO.dbo.PORTFOLIO_Fenix WHERE actual_date = @D
),
s17_new AS (
  SELECT l_loan_number, l_loan_open_date, l_funding_date FROM Dictionaries.risk_analytics.loans_active
  WHERE l_source = 'S17' AND l_report_date = @D
)
SELECT 'S01' AS source, COUNT(*) AS matched_count,
  SUM(CASE WHEN o.open_date = n.l_loan_open_date THEN 1 ELSE 0 END) AS open_date_match,
  SUM(CASE WHEN o.financing_date = n.l_funding_date THEN 1 ELSE 0 END) AS funding_date_match
FROM s01_old o JOIN s01_new n ON n.l_loan_id = o.contract_id
UNION ALL
SELECT 'S17', COUNT(*),
  SUM(CASE WHEN o.open_date = n.l_loan_open_date THEN 1 ELSE 0 END),
  SUM(CASE WHEN o.financing_date = n.l_funding_date THEN 1 ELSE 0 END)
FROM s17_old o JOIN s17_new n ON n.l_loan_number = o.contractnumber
OPTION (MAXDOP 1);
GO

-- =============================================================================
-- SECTION 2 / vac-firstpmt — Дата первого платежа, S02+S03
-- l_first_repayment_date vs old.first_pmt_date. S01/S17: аналога нет вовсе.
-- =============================================================================
DECLARE @D date = '2026-07-01';
;WITH s03_old AS (
  SELECT contract_number, first_pmt_date FROM CL_PORTFOLIO.dbo.CL_PORTFOLIO_2 WHERE [date] = @D
),
s03_new AS (
  SELECT l_loan_number, l_first_repayment_date FROM Dictionaries.risk_analytics.loans_active
  WHERE l_source = 'S03' AND l_report_date = @D
),
s02_old AS (
  SELECT contract_number, first_pmt_date FROM CL_PORTFOLIO.dbo.PORTFOLIO_CREDITCARDS_WAY4 WHERE [date] = @D
  UNION ALL SELECT contract_number, first_pmt_date FROM CL_PORTFOLIO.dbo.PORTFOLIO_CREDITCARDS_MIGR_WAY4 WHERE [date] = @D
  UNION ALL SELECT contract_number, first_pmt_date FROM CL_PORTFOLIO.dbo.PORTFOLIO_CREDITCARDS_SMART_CARD WHERE [date] = @D
),
s02_new AS (
  SELECT l_loan_number, l_first_repayment_date FROM Dictionaries.risk_analytics.loans_active
  WHERE l_source = 'S02' AND l_report_date = @D
)
SELECT 'S03' AS source, COUNT(*) AS matched_count,
  SUM(CASE WHEN TRY_CONVERT(date,o.first_pmt_date) = n.l_first_repayment_date THEN 1 ELSE 0 END) AS match_count
FROM s03_old o JOIN s03_new n ON n.l_loan_number = o.contract_number
UNION ALL
SELECT 'S02', COUNT(*),
  SUM(CASE WHEN TRY_CONVERT(date,o.first_pmt_date) = n.l_first_repayment_date THEN 1 ELSE 0 END)
FROM s02_old o JOIN s02_new n ON n.l_loan_number = o.contract_number
OPTION (MAXDOP 1);
GO

-- =============================================================================
-- SECTION 3 / vac-closedate — Плановое/факт. закрытие, S01+S17
-- old.close_date (заполнено только у закрытых) против ТРЁХ кандидатов сразу:
-- l_scheduled_closure_date, l_actual_closure_date, l_loan_maturity_date.
-- Цель: определить, какое новое поле — настоящий аналог old.close_date.
-- =============================================================================
DECLARE @D date = '2026-07-01';
;WITH s01_old AS (
  SELECT contract_id, close_date FROM CL_PORTFOLIO.dbo.PORTFOLIO_RS WHERE actual_date = @D AND close_date IS NOT NULL
),
s01_new AS (
  SELECT l_loan_id, l_scheduled_closure_date, l_actual_closure_date, l_loan_maturity_date
  FROM Dictionaries.risk_analytics.loans_active WHERE l_source = 'S01' AND l_report_date = @D
),
s17_old AS (
  SELECT contractnumber, close_date FROM CL_PORTFOLIO.dbo.PORTFOLIO_Fenix WHERE actual_date = @D AND close_date IS NOT NULL
),
s17_new AS (
  SELECT l_loan_number, l_scheduled_closure_date, l_actual_closure_date, l_loan_maturity_date
  FROM Dictionaries.risk_analytics.loans_active WHERE l_source = 'S17' AND l_report_date = @D
)
SELECT 'S01' AS source, COUNT(*) AS old_has_close_date,
  SUM(CASE WHEN o.close_date = n.l_scheduled_closure_date THEN 1 ELSE 0 END) AS matches_scheduled,
  SUM(CASE WHEN o.close_date = n.l_actual_closure_date   THEN 1 ELSE 0 END) AS matches_actual,
  SUM(CASE WHEN o.close_date = n.l_loan_maturity_date    THEN 1 ELSE 0 END) AS matches_maturity
FROM s01_old o JOIN s01_new n ON n.l_loan_id = o.contract_id
UNION ALL
SELECT 'S17', COUNT(*),
  SUM(CASE WHEN o.close_date = n.l_scheduled_closure_date THEN 1 ELSE 0 END),
  SUM(CASE WHEN o.close_date = n.l_actual_closure_date   THEN 1 ELSE 0 END),
  SUM(CASE WHEN o.close_date = n.l_loan_maturity_date    THEN 1 ELSE 0 END)
FROM s17_old o JOIN s17_new n ON n.l_loan_number = o.contractnumber
OPTION (MAXDOP 1);
GO

-- =============================================================================
-- SECTION 4 / vac-branch — Филиал, все source
-- old.filial (универсально) vs l_branch_code/l_branch_name.
-- Первый проход: домен + NULL-rate, НЕ точный crosswalk (словаря код<->имя
-- ни в одном письме не зафиксировано).
-- =============================================================================
DECLARE @D date = '2026-07-01';
;WITH old_branch AS (
  SELECT 'S01' AS source, contract_id AS old_key, filial FROM CL_PORTFOLIO.dbo.PORTFOLIO_RS WHERE actual_date=@D
  UNION ALL SELECT 'S03', contract_number, filial FROM CL_PORTFOLIO.dbo.CL_PORTFOLIO_2 WHERE [date]=@D
  UNION ALL SELECT 'S17', contractnumber, filial FROM CL_PORTFOLIO.dbo.PORTFOLIO_Fenix WHERE actual_date=@D
  UNION ALL SELECT 'S02', contract_number, filial FROM CL_PORTFOLIO.dbo.PORTFOLIO_CREDITCARDS_WAY4 WHERE [date]=@D
  UNION ALL SELECT 'S02', contract_number, filial FROM CL_PORTFOLIO.dbo.PORTFOLIO_CREDITCARDS_MIGR_WAY4 WHERE [date]=@D
  UNION ALL SELECT 'S02', contract_number, filial FROM CL_PORTFOLIO.dbo.PORTFOLIO_CREDITCARDS_SMART_CARD WHERE [date]=@D
),
new_branch AS (
  SELECT l_source, CASE WHEN l_source='S01' THEN l_loan_id ELSE l_loan_number END AS new_key,
         l_branch_code, l_branch_name
  FROM Dictionaries.risk_analytics.loans_active WHERE l_report_date=@D
)
SELECT o.source, COUNT(*) AS matched_count,
  COUNT(DISTINCT o.filial) AS old_distinct_filial_values,
  SUM(CASE WHEN n.l_branch_code IS NULL AND n.l_branch_name IS NULL THEN 1 ELSE 0 END) AS new_branch_both_null
FROM old_branch o JOIN new_branch n ON n.l_source = o.source AND n.new_key = o.old_key
GROUP BY o.source
OPTION (MAXDOP 1);
GO

-- =============================================================================
-- SECTION 5 / vac-rate — Ставка, S01+S17 ТОЛЬКО
-- l_rate тестируется против ДВУХ кандидатов: Eff_prs и ifrs_persent.
-- S02/S03 сознательно исключены: старое поле 'percent' омонимично (ставка ИЛИ
-- % резервирования) — писать проверку до S2T значило бы гадать какую величину
-- вообще сравнивать. Tier C, см. SAILAU_METHOD.md §4.
-- =============================================================================
DECLARE @D date = '2026-07-01';
;WITH s01_old AS ( SELECT contract_id, Eff_prs, ifrs_persent FROM CL_PORTFOLIO.dbo.PORTFOLIO_RS WHERE actual_date=@D ),
s01_new AS ( SELECT l_loan_id, l_rate FROM Dictionaries.risk_analytics.loans_active WHERE l_source='S01' AND l_report_date=@D AND l_rate IS NOT NULL ),
s17_old AS ( SELECT contractnumber, Eff_prs, ifrs_persent FROM CL_PORTFOLIO.dbo.PORTFOLIO_Fenix WHERE actual_date=@D ),
s17_new AS ( SELECT l_loan_number, l_rate FROM Dictionaries.risk_analytics.loans_active WHERE l_source='S17' AND l_report_date=@D AND l_rate IS NOT NULL )
SELECT 'S01' AS source, COUNT(*) AS matched_count,
  SUM(CASE WHEN ABS(TRY_CONVERT(float,n.l_rate) - o.Eff_prs) <= 0.01 THEN 1 ELSE 0 END) AS matches_eff_prs,
  SUM(CASE WHEN ABS(TRY_CONVERT(float,n.l_rate) - o.ifrs_persent) <= 0.01 THEN 1 ELSE 0 END) AS matches_ifrs_persent
FROM s01_old o JOIN s01_new n ON n.l_loan_id = o.contract_id
UNION ALL
SELECT 'S17', COUNT(*),
  SUM(CASE WHEN ABS(TRY_CONVERT(float,n.l_rate) - o.Eff_prs) <= 0.01 THEN 1 ELSE 0 END),
  SUM(CASE WHEN ABS(TRY_CONVERT(float,n.l_rate) - o.ifrs_persent) <= 0.01 THEN 1 ELSE 0 END)
FROM s17_old o JOIN s17_new n ON n.l_loan_number = o.contractnumber
OPTION (MAXDOP 1);
GO

-- =============================================================================
-- SECTION 6 / vac-currency-ext — Валюта, расширение v13 на S02/S03
-- old.valuta vs l_currency. v13 уже закрыл S01/S17 через curr — не дублирует.
-- =============================================================================
DECLARE @D date = '2026-07-01';
;WITH s03_old AS ( SELECT contract_number, valuta FROM CL_PORTFOLIO.dbo.CL_PORTFOLIO_2 WHERE [date]=@D ),
s03_new AS ( SELECT l_loan_number, l_currency FROM Dictionaries.risk_analytics.loans_active WHERE l_source='S03' AND l_report_date=@D ),
s02_old AS (
  SELECT contract_number, valuta FROM CL_PORTFOLIO.dbo.PORTFOLIO_CREDITCARDS_WAY4 WHERE [date]=@D
  UNION ALL SELECT contract_number, valuta FROM CL_PORTFOLIO.dbo.PORTFOLIO_CREDITCARDS_MIGR_WAY4 WHERE [date]=@D
  UNION ALL SELECT contract_number, valuta FROM CL_PORTFOLIO.dbo.PORTFOLIO_CREDITCARDS_SMART_CARD WHERE [date]=@D
),
s02_new AS ( SELECT l_loan_number, l_currency FROM Dictionaries.risk_analytics.loans_active WHERE l_source='S02' AND l_report_date=@D )
SELECT 'S03' AS source, COUNT(*) AS matched_count,
  SUM(CASE WHEN o.valuta = n.l_currency THEN 1 ELSE 0 END) AS match_count
FROM s03_old o JOIN s03_new n ON n.l_loan_number = o.contract_number
UNION ALL
SELECT 'S02', COUNT(*),
  SUM(CASE WHEN o.valuta = n.l_currency THEN 1 ELSE 0 END)
FROM s02_old o JOIN s02_new n ON n.l_loan_number = o.contract_number
OPTION (MAXDOP 1);
GO

-- =============================================================================
-- SECTION 7 / vac-entrepcat — Категория ИП, S02+S03, домен-crosswalk
-- old.[fiziki/yuriki] vs l_entrepreneur_category. ⚠ Написание поля расходится
-- ВНУТРИ старой ветки: WAY4/SMART_CARD = 'fiziki/yuriki' (слэш),
-- MIGR_WAY4 = 'fiziki yuriki' (пробел) — сама по себе находка, не опечатка ниже.
-- =============================================================================
DECLARE @D date = '2026-07-01';
;WITH s02_old AS (
  SELECT contract_number, [fiziki/yuriki] AS fiz_yur FROM CL_PORTFOLIO.dbo.PORTFOLIO_CREDITCARDS_WAY4 WHERE [date]=@D
  UNION ALL SELECT contract_number, [fiziki yuriki] FROM CL_PORTFOLIO.dbo.PORTFOLIO_CREDITCARDS_MIGR_WAY4 WHERE [date]=@D
  UNION ALL SELECT contract_number, [fiziki yuriki] FROM CL_PORTFOLIO.dbo.PORTFOLIO_CREDITCARDS_SMART_CARD WHERE [date]=@D
),
s03_old AS ( SELECT contract_number, [fiziki/yuriki] AS fiz_yur FROM CL_PORTFOLIO.dbo.CL_PORTFOLIO_2 WHERE [date]=@D ),
new_ent AS ( SELECT l_source, l_loan_number, l_entrepreneur_category FROM Dictionaries.risk_analytics.loans_active WHERE l_report_date=@D )
SELECT 'S02' AS source, COUNT(*) AS matched_count,
  COUNT(DISTINCT o.fiz_yur) AS old_distinct_values,
  COUNT(DISTINCT n.l_entrepreneur_category) AS new_distinct_values,
  SUM(CASE WHEN n.l_entrepreneur_category IS NULL THEN 1 ELSE 0 END) AS new_null_count
FROM s02_old o JOIN new_ent n ON n.l_source='S02' AND n.l_loan_number=o.contract_number
UNION ALL
SELECT 'S03', COUNT(*), COUNT(DISTINCT o.fiz_yur), COUNT(DISTINCT n.l_entrepreneur_category),
  SUM(CASE WHEN n.l_entrepreneur_category IS NULL THEN 1 ELSE 0 END)
FROM s03_old o JOIN new_ent n ON n.l_source='S03' AND n.l_loan_number=o.contract_number
OPTION (MAXDOP 1);
GO

-- =============================================================================
-- SECTION 8 / vac-tag — Тег договора, S02+S03 ТОЛЬКО
-- old.tag ИЛИ old.tag_1 vs l_tag. S01/S17: колонки физически отсутствуют.
-- =============================================================================
DECLARE @D date = '2026-07-01';
;WITH s02_old AS (
  SELECT contract_number, tag, tag_1 FROM CL_PORTFOLIO.dbo.PORTFOLIO_CREDITCARDS_WAY4 WHERE [date]=@D
  UNION ALL SELECT contract_number, tag, tag_1 FROM CL_PORTFOLIO.dbo.PORTFOLIO_CREDITCARDS_MIGR_WAY4 WHERE [date]=@D
  UNION ALL SELECT contract_number, tag, tag_1 FROM CL_PORTFOLIO.dbo.PORTFOLIO_CREDITCARDS_SMART_CARD WHERE [date]=@D
),
s03_old AS ( SELECT contract_number, tag, tag_1 FROM CL_PORTFOLIO.dbo.CL_PORTFOLIO_2 WHERE [date]=@D ),
new_tag AS ( SELECT l_source, l_loan_number, l_tag FROM Dictionaries.risk_analytics.loans_active WHERE l_report_date=@D )
SELECT 'S02' AS source, COUNT(*) AS matched_count,
  SUM(CASE WHEN n.l_tag = o.tag THEN 1 ELSE 0 END) AS matches_tag,
  SUM(CASE WHEN n.l_tag = o.tag_1 THEN 1 ELSE 0 END) AS matches_tag_1
FROM s02_old o JOIN new_tag n ON n.l_source='S02' AND n.l_loan_number=o.contract_number
UNION ALL
SELECT 'S03', COUNT(*),
  SUM(CASE WHEN n.l_tag = o.tag THEN 1 ELSE 0 END),
  SUM(CASE WHEN n.l_tag = o.tag_1 THEN 1 ELSE 0 END)
FROM s03_old o JOIN new_tag n ON n.l_source='S03' AND n.l_loan_number=o.contract_number
OPTION (MAXDOP 1);
GO

-- =============================================================================
-- SECTION 9 / vac-dpd-principal — DPD-сиблинг days_past_due_principal, S01+S03
-- Переиспользует правило dpd=new-1 (FINDINGS f5), но на СИБЛИНГ-поле, ранее
-- не тестированное отдельно от суммарного days_past_due.
-- =============================================================================
DECLARE @D date = '2026-07-01';
;WITH s01_old AS ( SELECT contract_id, overdue_days_principal FROM CL_PORTFOLIO.dbo.PORTFOLIO_RS WHERE actual_date=@D ),
s01_new AS ( SELECT l.l_loan_id, la.days_past_due_principal FROM Dictionaries.risk_analytics.loan_account la
  JOIN Dictionaries.risk_analytics.loans l ON l.l_gid=la.la_gid AND l.l_source=la.la_source
  WHERE la.la_source='S01' AND la.la_reporting_date=@D ),
s03_old AS ( SELECT contract_number, overdue_days_principal FROM CL_PORTFOLIO.dbo.CL_PORTFOLIO_2 WHERE [date]=@D ),
s03_new AS ( SELECT l.l_loan_number, la.days_past_due_principal FROM Dictionaries.risk_analytics.loan_account la
  JOIN Dictionaries.risk_analytics.loans l ON l.l_gid=la.la_gid AND l.l_source=la.la_source
  WHERE la.la_source='S03' AND la.la_reporting_date=@D )
SELECT 'S01' AS source,
  SUM(CASE WHEN o.overdue_days_principal IS NOT NULL AND n.days_past_due_principal IS NOT NULL THEN 1 ELSE 0 END) AS both_nonnull,
  SUM(CASE WHEN o.overdue_days_principal IS NOT NULL AND n.days_past_due_principal IS NOT NULL
           AND o.overdue_days_principal = (n.days_past_due_principal-1) THEN 1 ELSE 0 END) AS matched
FROM s01_old o JOIN s01_new n ON n.l_loan_id = o.contract_id
UNION ALL
SELECT 'S03',
  SUM(CASE WHEN o.overdue_days_principal IS NOT NULL AND n.days_past_due_principal IS NOT NULL THEN 1 ELSE 0 END),
  SUM(CASE WHEN o.overdue_days_principal IS NOT NULL AND n.days_past_due_principal IS NOT NULL
           AND o.overdue_days_principal = (n.days_past_due_principal-1) THEN 1 ELSE 0 END)
FROM s03_old o JOIN s03_new n ON n.l_loan_number = o.contract_number
OPTION (MAXDOP 1);
GO

-- =============================================================================
-- SECTION 10 / vac-lastatus — la_status, расширение DWH-12 на S03
-- old.status (S02/S03 only) vs loan_account.la_status. S01/S17: поля status
-- в старой схеме нет вовсе. Первый проход — домен + текстовый матч, чтобы
-- отличить «разные словари одного состояния» от настоящего расхождения.
-- =============================================================================
DECLARE @D date = '2026-07-01';
;WITH old_status AS (
  SELECT 'S03' AS source, contract_number AS old_key, status FROM CL_PORTFOLIO.dbo.CL_PORTFOLIO_2 WHERE [date]=@D
  UNION ALL SELECT 'S02', contract_number, status FROM CL_PORTFOLIO.dbo.PORTFOLIO_CREDITCARDS_WAY4 WHERE [date]=@D
  UNION ALL SELECT 'S02', contract_number, status FROM CL_PORTFOLIO.dbo.PORTFOLIO_CREDITCARDS_MIGR_WAY4 WHERE [date]=@D
),
new_status AS ( SELECT la_source, la_dog_num, la_status FROM Dictionaries.risk_analytics.loan_account WHERE la_reporting_date=@D )
SELECT o.source, COUNT(*) AS matched_count,
  COUNT(DISTINCT o.status) AS old_distinct_status,
  COUNT(DISTINCT n.la_status) AS new_distinct_status,
  SUM(CASE WHEN o.status = n.la_status THEN 1 ELSE 0 END) AS exact_text_match
FROM old_status o JOIN new_status n ON n.la_source=o.source AND n.la_dog_num=o.old_key
GROUP BY o.source
OPTION (MAXDOP 1);
GO

-- =============================================================================
-- SECTION 11 / vac-borrower-demo — Регион/ОКЭД/резидент, S01+S17+S03
-- Join через loans.l_borrower_id С ЯВНЫМ приведением типов (varchar(255) на
-- loans vs bigint на borrower.b_borrower_id — см. находку в шапке холста).
-- Первый проход — заполненность/присоединяемость, не точный crosswalk.
-- =============================================================================
DECLARE @D date = '2026-07-01';
;WITH old_demo AS (
  SELECT 'S01' AS source, contract_id AS old_key, Resident, Sector, activity_sphere, CAST(NULL AS varchar(50)) AS fiz_yur FROM CL_PORTFOLIO.dbo.PORTFOLIO_RS WHERE actual_date=@D
  UNION ALL SELECT 'S17', contractnumber, Resident, Sector, activity_sphere, NULL FROM CL_PORTFOLIO.dbo.PORTFOLIO_Fenix WHERE actual_date=@D
  UNION ALL SELECT 'S03', contract_number, NULL, NULL, NULL, [fiziki/yuriki] FROM CL_PORTFOLIO.dbo.CL_PORTFOLIO_2 WHERE [date]=@D
),
new_link AS (
  SELECT l.l_source, l.l_loan_number, l.l_loan_id, b.b_region, b.b_oked, b.b_oked_code,
         b.b_non_resident_flag, b.b_individual_entrepreneur_flag
  FROM Dictionaries.risk_analytics.loans l
  JOIN Dictionaries.risk_analytics.borrower b
    ON CONVERT(varchar(255), b.b_borrower_id) = l.l_borrower_id
  WHERE l.l_report_date = @D
)
SELECT o.source, COUNT(*) AS matched_count,
  SUM(CASE WHEN n.b_region IS NULL THEN 1 ELSE 0 END) AS new_region_null,
  SUM(CASE WHEN n.b_oked IS NULL AND n.b_oked_code IS NULL THEN 1 ELSE 0 END) AS new_oked_both_null,
  SUM(CASE WHEN o.Resident IS NOT NULL AND n.b_non_resident_flag IS NOT NULL THEN 1 ELSE 0 END) AS resident_both_filled
FROM old_demo o
JOIN new_link n ON n.l_source = o.source AND (n.l_loan_number = o.old_key OR n.l_loan_id = o.old_key)
GROUP BY o.source
OPTION (MAXDOP 1);
GO

-- =============================================================================
-- SECTION 12 / vac-pledge-car — Марка/модель залога-авто, S02+S03
-- old.CARBRAND (свободный текст) vs pledges.c_car_brand/c_car_model/
-- c_collateral_type, через доказанный v8-ключ (c_source+c_loan_gid=l_source+l_gid).
-- Метрика new_has_pledge_car_row (есть ли вообще строка) важнее точного
-- текстового совпадения на первом проходе.
-- =============================================================================
DECLARE @D date = '2026-07-01';
;WITH old_car AS (
  SELECT 'S02' AS source, contract_number AS old_key, CARBRAND FROM CL_PORTFOLIO.dbo.PORTFOLIO_CREDITCARDS_WAY4 WHERE [date]=@D AND CARBRAND IS NOT NULL
  UNION ALL SELECT 'S02', contract_number, CARBRAND FROM CL_PORTFOLIO.dbo.PORTFOLIO_CREDITCARDS_MIGR_WAY4 WHERE [date]=@D AND CARBRAND IS NOT NULL
  UNION ALL SELECT 'S02', contract_number, CARBRAND FROM CL_PORTFOLIO.dbo.PORTFOLIO_CREDITCARDS_SMART_CARD WHERE [date]=@D AND CARBRAND IS NOT NULL
  UNION ALL SELECT 'S03', contract_number, CARBRAND FROM CL_PORTFOLIO.dbo.CL_PORTFOLIO_2 WHERE [date]=@D AND CARBRAND IS NOT NULL
),
new_pledge AS (
  SELECT l.l_source, l.l_loan_number, p.c_car_brand, p.c_car_model, p.c_collateral_type
  FROM Dictionaries.risk_analytics.pledges p
  JOIN Dictionaries.risk_analytics.loans l ON l.l_gid = p.c_loan_gid AND l.l_source = p.c_source
  WHERE l.l_report_date = @D
)
SELECT o.source, COUNT(*) AS old_carbrand_filled_count,
  SUM(CASE WHEN n.c_car_brand IS NOT NULL THEN 1 ELSE 0 END) AS new_has_pledge_car_row,
  SUM(CASE WHEN n.c_car_brand = o.CARBRAND THEN 1 ELSE 0 END) AS exact_text_match
FROM old_car o LEFT JOIN new_pledge n ON n.l_source = o.source AND n.l_loan_number = o.old_key
GROUP BY o.source
OPTION (MAXDOP 1);
GO

-- =============================================================================
-- SECTION 13 / vac-borrower-selfcount — [Tier B] внутренняя согласованность
-- borrower.b_active_loans_count/b_closed_loans_count. НЕ old-vs-new (аналога
-- нет в старой ветке вовсе) — сверка агрегата против фактического COUNT(*).
-- =============================================================================
DECLARE @D date = '2026-07-01';
SELECT b.b_borrower_id, b.b_active_loans_count, b.b_closed_loans_count,
  (SELECT COUNT(*) FROM Dictionaries.risk_analytics.loans_active la
     WHERE CONVERT(varchar(255), b.b_borrower_id) = la.l_borrower_id AND la.l_report_date = @D) AS actual_active_count,
  (SELECT COUNT(*) FROM Dictionaries.risk_analytics.loans lo
     WHERE CONVERT(varchar(255), b.b_borrower_id) = lo.l_borrower_id AND lo.l_report_date = @D
       AND lo.l_actual_closure_date IS NOT NULL) AS actual_closed_count
INTO #borrower_selfcount
FROM Dictionaries.risk_analytics.borrower b
WHERE b.b_report_date = @D;

SELECT
  COUNT(*) AS borrower_rows,
  SUM(CASE WHEN b_active_loans_count = actual_active_count THEN 1 ELSE 0 END) AS active_count_matches,
  SUM(CASE WHEN b_closed_loans_count = actual_closed_count THEN 1 ELSE 0 END) AS closed_count_matches
FROM #borrower_selfcount
OPTION (MAXDOP 1);
DROP TABLE #borrower_selfcount;
GO

-- =============================================================================
-- SECTION 14 / vac-borrower-bankrupt-xref — [Tier B] borrower.b_bankruptcy_flag
-- vs таблица bankrupt. ⚠ Ключ borrower_id=dog_gid НЕ подтверждён (заёмщик vs
-- договор, разный grain) — этот запрос отчасти проверяет, разумно ли вообще
-- их соединять напрямую. Читать результат с этой оговоркой.
-- =============================================================================
DECLARE @D date = '2026-07-01';
SELECT
  SUM(CASE WHEN b.b_bankruptcy_flag = '1' AND bk.b_dog_gid IS NULL THEN 1 ELSE 0 END) AS flag_set_no_bankrupt_row,
  SUM(CASE WHEN (b.b_bankruptcy_flag IS NULL OR b.b_bankruptcy_flag = '0') AND bk.b_dog_gid IS NOT NULL THEN 1 ELSE 0 END) AS bankrupt_row_no_flag,
  COUNT(*) AS borrower_rows
FROM Dictionaries.risk_analytics.borrower b
LEFT JOIN Dictionaries.risk_analytics.bankrupt bk
  ON CONVERT(varchar(255), b.b_borrower_id) = CONVERT(varchar(255), bk.b_dog_gid)
WHERE b.b_report_date = @D
OPTION (MAXDOP 1);
GO

/* =============================================================================
   Не включены в этот pack (уже готовые факты, SQL не нужен):
   - v15 (currency_reserve_percentage) — уже посчитано, см. FINDINGS.md §9.4 п.9.
   - e19 (S01 max DPD-сиблинг) — уже посчитано, см. письмо №2 в
     sailau_to_akberdiyev.md (465/762=61,02%).

   Backlog (Tier B/C, не в этом батче) — см. SAILAU_METHOD.md §5 полностью,
   с обоснованием по каждой таблице. offbalance — единственная Tier-A таблица
   в backlog (есть PORTFOLIO_OFF_BALANCE), отложена по приоритету — кандидат
   №1 на Batch 2.
   ============================================================================= */
