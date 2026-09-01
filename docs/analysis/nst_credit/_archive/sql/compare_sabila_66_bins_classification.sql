-- Полное сравнение: 66 BINs Sabila vs наша классификация
-- Задача: для каждого из 66 BINs показать
--   1. Есть ли в B1A?
--   2. Какой сегмент наша логика назначит?
--   3. Совпадает ли с ожиданием (все должны быть "Individual loans")?

DECLARE @capital_nst2026 FLOAT = 503086114000;  -- СК на 01.01.2026 (согласован с анализом Sabila)
DECLARE @threshold_individual FLOAT = 0.002;

-- ============================================================================
-- SABILA'S 66 BINs — создаём временную таблицу
-- ============================================================================
DECLARE @sabila_bins TABLE (
  row_num INT IDENTITY(1,1),
  bin BIGINT,
  borrower_name NVARCHAR(500),
  bank_code VARCHAR(10)
);

-- ВНИМАНИЕ (§2 корневого CLAUDE.md): перечень заёмщиков в репозиторий не коммитится.
-- Список индивидуальных заёмщиков (66 позиций: IIN_BIN + наименование) ведёт Sabila,
-- хранится вне репозитория. Заполнить @sabila_bins в текущей сессии из внешнего
-- источника перед прогоном; полученный файл в git не добавлять.
--
-- Контроль перед прогоном:  SELECT COUNT(*) FROM @sabila_bins;  -- ожидается 66
--
-- INSERT INTO @sabila_bins (bin, borrower_name, bank_code) VALUES ... ;

-- ============================================================================
-- ТАБЛИЦА 1: Проверка наличия в B1A и базовые метрики
-- ============================================================================
SELECT
  s.row_num as sabila_no,
  s.bin,
  CASE WHEN n.IIN_BIN IS NOT NULL THEN 'YES' ELSE 'NO' END as in_b1a,
  COUNT(CASE WHEN n.IIN_BIN IS NOT NULL THEN 1 END) as contracts_count,
  SUM(CASE WHEN n.IIN_BIN IS NOT NULL THEN CAST(n.ead AS FLOAT) ELSE 0 END) as total_ead,
  SUM(CASE WHEN n.IIN_BIN IS NOT NULL THEN
    COALESCE(CAST(n.od AS FLOAT), 0) + COALESCE(CAST(n.od_del AS FLOAT), 0)
    + COALESCE(CAST(n.interest AS FLOAT), 0) + COALESCE(CAST(n.interest_del AS FLOAT), 0)
    + COALESCE(CAST(n.correction AS FLOAT), 0) + COALESCE(CAST(n.disc_prem AS FLOAT), 0)
    + COALESCE(CAST(n.penalty AS FLOAT), 0)
    ELSE 0 END) as total_debt,
  s.borrower_name,
  s.bank_code
FROM @sabila_bins s
LEFT JOIN [CL_PORTFOLIO].[dbo].AQR2026_B1A_2025_Q4 n ON s.bin = n.IIN_BIN AND n.is_del = '0'
GROUP BY s.row_num, s.bin, s.borrower_name, s.bank_code, n.IIN_BIN
ORDER BY s.row_num;

-- ============================================================================
-- ТАБЛИЦА 2: Классификация каждого BIN по нашей логике
-- ============================================================================
SELECT
  s.row_num,
  s.bin,
  s.borrower_name,
  COUNT(*) as contracts,
  SUM(CAST(n.ead AS FLOAT)) as total_ead,
  CASE
    WHEN n.ENTITY = 'EUB1' THEN 'DISASS'
    WHEN n.LSBOO = 1 THEN 'RELATE'
    WHEN COALESCE(CAST(n.f_inv AS FLOAT), 0) = 1 THEN 'CORINV'
    WHEN a.bin IS NOT NULL THEN 'Individual loans (B2A)'
    WHEN SUM(COALESCE(CAST(n.od AS FLOAT), 0) + COALESCE(CAST(n.od_del AS FLOAT), 0)
                     + COALESCE(CAST(n.interest AS FLOAT), 0) + COALESCE(CAST(n.interest_del AS FLOAT), 0)
                     + COALESCE(CAST(n.correction AS FLOAT), 0) + COALESCE(CAST(n.disc_prem AS FLOAT), 0)
                     + COALESCE(CAST(n.penalty AS FLOAT), 0))
         OVER (PARTITION BY n.iin_bin) > @capital_nst2026 * @threshold_individual
    THEN 'Individual loans (threshold)'
    WHEN (COALESCE(CAST(n.debtor_type AS FLOAT), 0) = 1
          OR (COALESCE(CAST(n.debtor_type AS FLOAT), 0) = 0 AND COALESCE(CAST(n.debtor_se AS FLOAT), 0) = 1))
         AND COALESCE(CAST(n.ent_type AS FLOAT), 0) IN (1, 2, 3)
         AND COALESCE(CAST(n.loan_obj AS FLOAT), 0) IN (1, 2, 3)
         AND COALESCE(CAST(n.loan_purp AS FLOAT), 0) IN (1, 2, 3, 4, 5, 8)
    THEN 'COREST'
    WHEN COALESCE(CAST(n.ent_type AS FLOAT), 0) = 1 THEN 'CORLAR'
    WHEN COALESCE(CAST(n.ent_type AS FLOAT), 0) = 2 THEN 'CORMED'
    WHEN COALESCE(CAST(n.ent_type AS FLOAT), 0) = 3 THEN 'RETSML'
    WHEN COALESCE(CAST(n.debtor_type AS FLOAT), 0) = 0
         AND COALESCE(CAST(n.ead AS FLOAT), 0) <= 200000000
         AND COALESCE(CAST(n.debtor_se AS FLOAT), 0) = 0
         AND COALESCE(CAST(n.collateral AS FLOAT), 0) = 1
         AND n.portfolio IN ('Mortgage')
    THEN 'RETEST'
    WHEN COALESCE(CAST(n.debtor_type AS FLOAT), 0) = 0
         AND COALESCE(CAST(n.ead AS FLOAT), 0) <= 200000000
         AND COALESCE(CAST(n.debtor_se AS FLOAT), 0) = 0
         AND COALESCE(CAST(n.collateral AS FLOAT), 0) = 1
    THEN 'RETCAR'
    WHEN COALESCE(CAST(n.debtor_type AS FLOAT), 0) = 0
         AND COALESCE(CAST(n.ead AS FLOAT), 0) <= 200000000
         AND COALESCE(CAST(n.debtor_se AS FLOAT), 0) = 0
         AND COALESCE(CAST(n.collateral AS FLOAT), 0) = 0
    THEN 'RETCON'
    ELSE 'X (unclassified)'
  END as our_classification
FROM @sabila_bins s
LEFT JOIN [CL_PORTFOLIO].[dbo].AQR2026_B1A_2025_Q4 n ON s.bin = n.IIN_BIN AND n.is_del = '0'
LEFT JOIN [personal_tables].[dbo].RA_NST_B2A_2026_04012026 a ON a.bin = s.bin
GROUP BY s.row_num, s.bin, s.borrower_name, n.ENTITY, n.LSBOO, n.f_inv, a.bin, n.iin_bin,
         n.debtor_type, n.debtor_se, n.ent_type, n.loan_obj, n.loan_purp, n.ead, n.portfolio, n.collateral,
         n.od, n.od_del, n.interest, n.interest_del, n.correction, n.disc_prem, n.penalty
ORDER BY s.row_num;

-- ============================================================================
-- ТАБЛИЦА 3: Discrepancies — где наша логика дает НЕ "Individual loans"
-- ============================================================================
SELECT
  'MISMATCH' as status,
  s.row_num,
  s.bin,
  s.borrower_name,
  -- Our classification result
  CASE
    WHEN COUNT(*) = 0 THEN 'NOT IN B1A'
    WHEN n.ENTITY = 'EUB1' THEN 'DISASS'
    WHEN n.LSBOO = 1 THEN 'RELATE'
    WHEN COALESCE(CAST(n.f_inv AS FLOAT), 0) = 1 THEN 'CORINV'
    WHEN a.bin IS NOT NULL THEN 'Individual loans (B2A)'
    WHEN SUM(COALESCE(CAST(n.od AS FLOAT), 0) + COALESCE(CAST(n.od_del AS FLOAT), 0)
                     + COALESCE(CAST(n.interest AS FLOAT), 0) + COALESCE(CAST(n.interest_del AS FLOAT), 0)
                     + COALESCE(CAST(n.correction AS FLOAT), 0) + COALESCE(CAST(n.disc_prem AS FLOAT), 0)
                     + COALESCE(CAST(n.penalty AS FLOAT), 0))
         OVER (PARTITION BY n.iin_bin) > @capital_nst2026 * @threshold_individual
    THEN 'Individual loans (threshold)'
    WHEN (COALESCE(CAST(n.debtor_type AS FLOAT), 0) = 1
          OR (COALESCE(CAST(n.debtor_type AS FLOAT), 0) = 0 AND COALESCE(CAST(n.debtor_se AS FLOAT), 0) = 1))
         AND COALESCE(CAST(n.ent_type AS FLOAT), 0) IN (1, 2, 3)
    THEN 'COREST'
    WHEN COALESCE(CAST(n.ent_type AS FLOAT), 0) IN (1, 2, 3) THEN 'CORLAR/CORMED/RETSML'
    ELSE 'X (other retail)'
  END as our_result,
  CASE WHEN a.bin IS NOT NULL THEN 'YES' ELSE 'NO' END as in_b2a_list,
  SUM(CAST(n.ead AS FLOAT)) as total_ead,
  SUM(COALESCE(CAST(n.od AS FLOAT), 0) + COALESCE(CAST(n.od_del AS FLOAT), 0)
    + COALESCE(CAST(n.interest AS FLOAT), 0) + COALESCE(CAST(n.interest_del AS FLOAT), 0)
    + COALESCE(CAST(n.correction AS FLOAT), 0) + COALESCE(CAST(n.disc_prem AS FLOAT), 0)
    + COALESCE(CAST(n.penalty AS FLOAT), 0)) as total_debt
FROM @sabila_bins s
LEFT JOIN [CL_PORTFOLIO].[dbo].AQR2026_B1A_2025_Q4 n ON s.bin = n.IIN_BIN AND n.is_del = '0'
LEFT JOIN [personal_tables].[dbo].RA_NST_B2A_2026_04012026 a ON a.bin = s.bin
GROUP BY s.row_num, s.bin, s.borrower_name, n.ENTITY, n.LSBOO, n.f_inv, a.bin, n.iin_bin,
         n.debtor_type, n.debtor_se, n.ent_type, n.loan_obj, n.loan_purp, n.ead, n.portfolio, n.collateral,
         n.od, n.od_del, n.interest, n.interest_del, n.correction, n.disc_prem, n.penalty
HAVING NOT (
  -- Exclude rows that ARE correctly classified as Individual loans
  n.ENTITY = 'EUB1' OR n.LSBOO = 1 OR COALESCE(CAST(n.f_inv AS FLOAT), 0) = 1
  OR a.bin IS NOT NULL
  OR (SUM(COALESCE(CAST(n.od AS FLOAT), 0) + COALESCE(CAST(n.od_del AS FLOAT), 0)
                   + COALESCE(CAST(n.interest AS FLOAT), 0) + COALESCE(CAST(n.interest_del AS FLOAT), 0)
                   + COALESCE(CAST(n.correction AS FLOAT), 0) + COALESCE(CAST(n.disc_prem AS FLOAT), 0)
                   + COALESCE(CAST(n.penalty AS FLOAT), 0)) > @capital_nst2026 * @threshold_individual)
)
ORDER BY s.row_num;

-- ============================================================================
-- SUMMARY: сколько совпадений, сколько ошибок
-- ============================================================================
SELECT
  'SUMMARY' as report_type,
  COUNT(*) as total_sabila_bins,
  SUM(CASE WHEN in_b1a = 'YES' THEN 1 ELSE 0 END) as found_in_b1a,
  SUM(CASE WHEN in_b1a = 'NO' THEN 1 ELSE 0 END) as not_in_b1a,
  SUM(CASE WHEN in_b2a = 'YES' THEN 1 ELSE 0 END) as in_b2a_join,
  -- Count how many would be classified as Individual loans by our logic
  SUM(CASE WHEN (in_b2a = 'YES'
             OR debt_above_threshold = 1
             OR in_other_individual_category = 1)
         THEN 1 ELSE 0 END) as classified_as_individual_loans
FROM (
  SELECT
    s.row_num,
    s.bin,
    CASE WHEN n.IIN_BIN IS NOT NULL THEN 'YES' ELSE 'NO' END as in_b1a,
    CASE WHEN a.bin IS NOT NULL THEN 'YES' ELSE 'NO' END as in_b2a,
    CASE WHEN SUM(CAST(n.od + n.od_del + n.interest + n.interest_del
                       + n.correction + n.disc_prem + n.penalty AS FLOAT))
              OVER (PARTITION BY n.iin_bin) > @capital_nst2026 * @threshold_individual
         THEN 1 ELSE 0 END as debt_above_threshold,
    CASE WHEN n.ENTITY = 'EUB1' OR n.LSBOO = 1 OR COALESCE(CAST(n.f_inv AS FLOAT), 0) = 1
         THEN 1 ELSE 0 END as in_other_individual_category
  FROM @sabila_bins s
  LEFT JOIN [CL_PORTFOLIO].[dbo].AQR2026_B1A_2025_Q4 n ON s.bin = n.IIN_BIN AND n.is_del = '0'
  LEFT JOIN [personal_tables].[dbo].RA_NST_B2A_2026_04012026 a ON a.bin = s.bin
) detail;
