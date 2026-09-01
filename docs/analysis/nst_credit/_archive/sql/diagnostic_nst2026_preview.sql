-- Диагностика: предпросмотр сегментации НСТ-2026 с новыми параметрами
-- Цель: идентифицировать изменения относительно AQR-2025 из-за капитала и МРП
-- Запустить после заполнения основного скрипта segmentation_nst2026.sql

DECLARE @capital_aqr2025 FLOAT = 461235157000;  -- СК на 01.01.2025 (была в AQR2025 скрипте)
DECLARE @capital_nst2026 FLOAT = 503086114000;  -- СК на 01.01.2026 (согласован с анализом Sabila)
DECLARE @mrp_2025 FLOAT = 3932;
DECLARE @threshold_individual FLOAT = 0.002;

-- ============================================================================
-- ТАБЛИЦА 1: Распределение по сегментам на НСТ-2026
-- ============================================================================
SELECT
  'NST-2026 (31.12.2025)' as period,
  segment_afr,
  COUNT(*) as contracts,
  SUM(CAST(ead_n AS FLOAT)) as total_ead,
  ROUND(SUM(CAST(ead_n AS FLOAT)) / SUM(SUM(CAST(ead_n AS FLOAT))) OVER () * 100, 2) as ead_pct
FROM (
  SELECT
    CASE
      WHEN ENTITY = 'EUB1' THEN 'DISASS'
      WHEN LSBOO = 1 THEN 'RELATE'
      WHEN COALESCE(CAST(f_inv AS FLOAT), 0) = 1 THEN 'CORINV'
      WHEN a.bin IS NOT NULL THEN 'Individual loans'
      WHEN SUM(COALESCE(CAST(od AS FLOAT), 0) + COALESCE(CAST(od_del AS FLOAT), 0)
               + COALESCE(CAST(interest AS FLOAT), 0) + COALESCE(CAST(interest_del AS FLOAT), 0)
               + COALESCE(CAST(correction AS FLOAT), 0) + COALESCE(CAST(disc_prem AS FLOAT), 0)
               + COALESCE(CAST(penalty AS FLOAT), 0)) OVER (PARTITION BY iin_bin)
           > @capital_nst2026 * @threshold_individual THEN 'Individual loans'
      WHEN (DEBTOR_TYPE = 1 OR (DEBTOR_TYPE = 0 AND DEBTOR_SE = 1))
           AND ENT_TYPE IN (1, 2, 3) AND LOAN_OBJ IN (1, 2, 3) AND LOAN_PURP IN (1, 2, 3, 4, 5, 8)
      THEN 'COREST'
      WHEN COALESCE(CAST(ent_type AS FLOAT), 0) = 1 THEN 'CORLAR'
      WHEN COALESCE(CAST(ent_type AS FLOAT), 0) = 2 THEN 'CORMED'
      WHEN COALESCE(CAST(ent_type AS FLOAT), 0) = 3 THEN 'RETSML'
      WHEN COALESCE(CAST(debtor_type AS FLOAT), 0) = 0
           AND COALESCE(CAST(ead AS FLOAT), 0) <= 200000000
           AND COALESCE(CAST(debtor_se AS FLOAT), 0) = 0
           AND COALESCE(CAST(collateral AS FLOAT), 0) = 1
           AND portfolio IN ('Mortgage')
      THEN 'RETEST'
      WHEN COALESCE(CAST(debtor_type AS FLOAT), 0) = 0
           AND COALESCE(CAST(ead AS FLOAT), 0) <= 200000000
           AND COALESCE(CAST(debtor_se AS FLOAT), 0) = 0
           AND COALESCE(CAST(collateral AS FLOAT), 0) = 1
      THEN 'RETCAR'
      WHEN COALESCE(CAST(debtor_type AS FLOAT), 0) = 0
           AND COALESCE(CAST(ead AS FLOAT), 0) <= 200000000
           AND COALESCE(CAST(debtor_se AS FLOAT), 0) = 0
           AND COALESCE(CAST(collateral AS FLOAT), 0) = 0
      THEN 'RETCON'
      ELSE 'X'
    END as segment_afr,
    COALESCE(CAST(ead AS FLOAT), 0) as ead_n
  FROM [CL_PORTFOLIO].[dbo].AQR2026_B1A_2025_Q4 n
  LEFT JOIN [personal_tables].[dbo].RA_NST_B2A_2026_04012026 a ON a.bin = n.IIN_BIN
  WHERE is_del = '0'
) segs
GROUP BY segment_afr
ORDER BY ead_pct DESC;

-- ============================================================================
-- ТАБЛИЦА 2: Влияние капитала: сколько заёмщиков переклассифицировалось из-за изменения порога
-- ============================================================================
SELECT
  'Impact of capital change' as metric,
  COUNT(*) as borrowers_above_old_threshold,
  COUNT(CASE WHEN zadol > @capital_nst2026 * @threshold_individual
         THEN 1 END) as also_above_new_threshold,
  COUNT(CASE WHEN zadol <= @capital_nst2026 * @threshold_individual
         THEN 1 END) as drop_below_new_threshold
FROM (
  SELECT
    iin_bin,
    SUM(COALESCE(CAST(od AS FLOAT), 0) + COALESCE(CAST(od_del AS FLOAT), 0)
        + COALESCE(CAST(interest AS FLOAT), 0) + COALESCE(CAST(interest_del AS FLOAT), 0)
        + COALESCE(CAST(correction AS FLOAT), 0) + COALESCE(CAST(disc_prem AS FLOAT), 0)
        + COALESCE(CAST(penalty AS FLOAT), 0)) as zadol
  FROM [CL_PORTFOLIO].[dbo].AQR2026_B1A_2025_Q4
  WHERE is_del = '0'
  GROUP BY iin_bin
  HAVING SUM(COALESCE(CAST(od AS FLOAT), 0) + COALESCE(CAST(od_del AS FLOAT), 0)
        + COALESCE(CAST(interest AS FLOAT), 0) + COALESCE(CAST(interest_del AS FLOAT), 0)
        + COALESCE(CAST(correction AS FLOAT), 0) + COALESCE(CAST(disc_prem AS FLOAT), 0)
        + COALESCE(CAST(penalty AS FLOAT), 0)) > @capital_aqr2025 * @threshold_individual
) AS crossing;

-- ============================================================================
-- ТАБЛИЦА 3: Проверка пустых сегментов (CORINV, CORGOV, f_inv распределение)
-- ============================================================================
SELECT
  'CORINV check' as check_name,
  COUNT(*) as loans_with_f_inv_1,
  ROUND(SUM(CAST(ead AS FLOAT)) / 1000000, 1) as ead_mln
FROM [CL_PORTFOLIO].[dbo].AQR2026_B1A_2025_Q4
WHERE is_del = '0' AND COALESCE(CAST(f_inv AS FLOAT), 0) = 1
UNION ALL
SELECT
  'RETCARTEST collateral check' as check_name,
  COUNT(*) as loans,
  ROUND(SUM(CAST(ead AS FLOAT)) / 1000000, 1) as ead_mln
FROM [CL_PORTFOLIO].[dbo].AQR2026_B1A_2025_Q4
WHERE is_del = '0'
  AND COALESCE(CAST(debtor_type AS FLOAT), 0) = 0
  AND COALESCE(CAST(debtor_se AS FLOAT), 0) = 0
  AND COALESCE(CAST(ead AS FLOAT), 0) <= 200000000
  AND portfolio = 'Mortgage'
  AND COALESCE(CAST(collateral AS FLOAT), 0) = 0  -- без залога но в Mortgage!
;

-- ============================================================================
-- ТАБЛИЦА 4: Диагностика collateral коллизии (RETEST без залога)
-- ============================================================================
SELECT
  COUNT(*) as loans_portfolio_mortgage_no_collateral,
  ROUND(SUM(CAST(ead AS FLOAT)) / 1000000, 2) as ead_mln,
  'Risk: these will match both RETEST (old) and RETCON (new branch)' as note
FROM [CL_PORTFOLIO].[dbo].AQR2026_B1A_2025_Q4
WHERE is_del = '0'
  AND COALESCE(CAST(debtor_type AS FLOAT), 0) = 0
  AND COALESCE(CAST(debtor_se AS FLOAT), 0) = 0
  AND COALESCE(CAST(ead AS FLOAT), 0) <= 200000000
  AND portfolio = 'Mortgage'
  AND COALESCE(CAST(collateral AS FLOAT), 0) = 0;

-- ============================================================================
-- ТАБЛИЦА 5: Distribution по debtor_type (Individual vs Business branching)
-- ============================================================================
SELECT
  COALESCE(CAST(debtor_type AS FLOAT), 0) as debtor_type,
  COUNT(*) as contracts,
  ROUND(SUM(CAST(ead AS FLOAT)) / 1000000, 1) as ead_mln,
  ROUND(SUM(CAST(ead AS FLOAT)) / SUM(SUM(CAST(ead AS FLOAT))) OVER () * 100, 2) as ead_pct,
  CASE WHEN COALESCE(CAST(debtor_type AS FLOAT), 0) = 0 THEN 'Individual (ФЛ)'
       WHEN COALESCE(CAST(debtor_type AS FLOAT), 0) = 1 THEN 'Legal entity (ЮЛ)'
       ELSE 'Unknown' END as type_name
FROM [CL_PORTFOLIO].[dbo].AQR2026_B1A_2025_Q4
WHERE is_del = '0'
GROUP BY COALESCE(CAST(debtor_type AS FLOAT), 0)
ORDER BY ead_mln DESC;
