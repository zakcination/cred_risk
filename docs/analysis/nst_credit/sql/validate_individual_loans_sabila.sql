-- Валидация: наша логика Individual loans vs список Sabila
-- Задача: найти расхождения и понять причины
-- Выходные данные:
--   1. Какие BINs Sabila отнесла в Individual loans
--   2. Какие наша логика классифицирует как Individual loans
--   3. Несовпадения и причины

-- ============================================================================
-- ПАРАМЕТРЫ (синхронизировать с segmentation_nst2026.sql)
-- ============================================================================
DECLARE @capital_nst2026_regulatory FLOAT = 557685150000;  -- регуляторный (31.12.2025)
DECLARE @capital_aqr2026_actual FLOAT = 503086114000;      -- из анализа Sabila (01.01.26)
DECLARE @threshold_individual FLOAT = 0.002;

-- ДИАГНОСТИКА: какой капитал использовать?
-- Sabila использовала 503.1B, но наши данные на 31.12.2025 дают 557.7B
-- Разница: 54.6B (10.9%) — существенна для Individual loans пороговых случаев

-- ============================================================================
-- ТАБЛИЦА 1: BINs из B1A, агрегированная задолженность, проверка порогов
-- ============================================================================
SELECT
  'Capital comparison' as check_name,
  n.IIN_BIN,
  COUNT(DISTINCT contract_id) as contracts,  -- примечание: adjust column name
  SUM(CAST(ead AS FLOAT)) as total_ead,
  SUM(CAST(od + od_del + interest + interest_del + correction + disc_prem + penalty AS FLOAT)) as total_debt,
  CASE
    WHEN SUM(CAST(od + od_del + interest + interest_del + correction + disc_prem + penalty AS FLOAT))
         > @capital_nst2026_regulatory * @threshold_individual
    THEN 'Individual (by NST-2026 capital)'
    ELSE 'Not Individual'
  END as classification_nst2026,
  CASE
    WHEN SUM(CAST(od + od_del + interest + interest_del + correction + disc_prem + penalty AS FLOAT))
         > @capital_aqr2026_actual * @threshold_individual
    THEN 'Individual (by Sabila capital)'
    ELSE 'Not Individual'
  END as classification_sabila,
  @capital_nst2026_regulatory * @threshold_individual as threshold_nst2026,
  @capital_aqr2026_actual * @threshold_individual as threshold_sabila
FROM [CL_PORTFOLIO].[dbo].AQR2026_B1A_2025_Q4 n
WHERE is_del = '0'
  AND DEBTOR_TYPE = 0  -- only individuals (ФЛ)
GROUP BY n.IIN_BIN
HAVING SUM(CAST(od + od_del + interest + interest_del + correction + disc_prem + penalty AS FLOAT))
       > @capital_aqr2026_actual * @threshold_individual  -- at least above Sabila threshold
ORDER BY total_debt DESC;

-- ============================================================================
-- ТАБЛИЦА 2: Cross-check — наша B2A join логика
-- ============================================================================
-- Sabila's Individual loans list (файл 1) должна совпадать с нашей B2A join результатов
SELECT
  'B2A join check' as metric,
  COUNT(DISTINCT a.bin) as sabila_bins_in_our_b2a,
  SUM(CAST(n.ead AS FLOAT)) / 1000000 as total_ead_mln
FROM [personal_tables].[dbo].RA_NST_B2A_2026_04012026 a
INNER JOIN [CL_PORTFOLIO].[dbo].AQR2026_B1A_2025_Q4 n ON a.bin = n.IIN_BIN
WHERE n.is_del = '0';

-- ============================================================================
-- ТАБЛИЦА 3: Individual loans по нашей логике (оба условия)
-- ============================================================================
SELECT
  'Our Individual loans classification' as metric,
  COUNT(*) as contracts,
  COUNT(DISTINCT IIN_BIN) as unique_borrowers,
  SUM(CAST(ead AS FLOAT)) / 1000000 as ead_mln
FROM [CL_PORTFOLIO].[dbo].AQR2026_B1A_2025_Q4 n
WHERE is_del = '0'
  AND (
    -- Условие 1: в B2A списке
    IIN_BIN IN (SELECT DISTINCT bin FROM [personal_tables].[dbo].RA_NST_B2A_2026_04012026)
    -- Условие 2: порог 0.2% capital
    OR SUM(CAST(od + od_del + interest + interest_del + correction + disc_prem + penalty AS FLOAT))
       OVER (PARTITION BY IIN_BIN) > @capital_nst2026_regulatory * @threshold_individual
  );

-- ============================================================================
-- ТАБЛИЦА 4: Дефекты в классификации (примеры расхождений)
-- ============================================================================
-- BINs где классификация меняется из-за разницы в капитале
SELECT TOP 50
  n.IIN_BIN,
  COUNT(*) as contracts,
  SUM(CAST(ead AS FLOAT)) as total_ead,
  SUM(CAST(od + od_del + interest + interest_del + correction + disc_prem + penalty AS FLOAT)) as total_debt,
  ROUND(SUM(CAST(od + od_del + interest + interest_del + correction + disc_prem + penalty AS FLOAT))
        / @capital_aqr2026_actual / @threshold_individual, 4) as pct_of_sabila_capital,
  CASE
    WHEN SUM(CAST(od + od_del + interest + interest_del + correction + disc_prem + penalty AS FLOAT))
         > @capital_nst2026_regulatory * @threshold_individual
    THEN 'INDIVIDUAL in NST-2026'
    ELSE 'NOT individual in NST-2026'
  END as nst2026_status,
  CASE
    WHEN SUM(CAST(od + od_del + interest + interest_del + correction + disc_prem + penalty AS FLOAT))
         > @capital_aqr2026_actual * @threshold_individual
    THEN 'INDIVIDUAL in Sabila'
    ELSE 'NOT individual in Sabila'
  END as sabila_status
FROM [CL_PORTFOLIO].[dbo].AQR2026_B1A_2025_Q4 n
WHERE is_del = '0'
GROUP BY n.IIN_BIN
HAVING (
  -- Show only those where classification differs
  (SUM(CAST(od + od_del + interest + interest_del + correction + disc_prem + penalty AS FLOAT))
   > @capital_nst2026_regulatory * @threshold_individual
   AND SUM(CAST(od + od_del + interest + interest_del + correction + disc_prem + penalty AS FLOAT))
   <= @capital_aqr2026_actual * @threshold_individual)
  OR
  (SUM(CAST(od + od_del + interest + interest_del + correction + disc_prem + penalty AS FLOAT))
   <= @capital_nst2026_regulatory * @threshold_individual
   AND SUM(CAST(od + od_del + interest + interest_del + correction + disc_prem + penalty AS FLOAT))
   > @capital_aqr2026_actual * @threshold_individual)
)
ORDER BY total_debt DESC;

-- ============================================================================
-- ДИАГНОСТИЧЕСКИЙ ВЫВОД
-- ============================================================================
-- Запустить и проверить:
-- 1. ТАБЛИЦА 1: для каждого BIN показать классификацию по обоим капиталам
-- 2. ТАБЛИЦА 2: подтвердить, что B2A join работает
-- 3. ТАБЛИЦА 3: общие числа по нашей логике
-- 4. ТАБЛИЦА 4: найти BINs на границе (которые меняются из-за капитала)
--
-- После анализа:
-- - Решить: какой капитал использовать (556.7B или 503.1B)?
--   Вариант A: 557.7B (регуляторный на 31.12.2025) — консервативнее
--   Вариант B: 503.1B (использовано Sabila) — согласованнее с её анализом
--   Рекомендация: Уточнить у БРМ какой капитал должен быть в шаблоне НСТ
--
-- - Убедиться: Sabila's 66-BIN список соответствует нашим результатам
-- - Проверить: отсутствующие BINs (есть у нас, но не у Sabila)
