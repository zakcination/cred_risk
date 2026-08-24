-- НСТ-2026: сегментация кредитного портфеля на 31.12.2025
-- Базирована на AQR-2025 (2024 Q4) с учётом решений дерева и изменяющихся переменных
-- История изменений — в SQL_REVIEW.md / USE_FOR_2026.md
-- ПАРАМЕТРЫ (обновить на отчётную дату):
-- @capital_nst2026 = собственный капитал на 31.12.2025 (из финотчёта)
-- @mrp_2025 = МРП на 01.01.2025 по закону о республиканском бюджете (для § 24 Entrepreneurship Code)
-- ТРЕБУЕТ СВЕРКИ с методруководством НСТ-2026, когда оно получено.

DECLARE @capital_nst2026 FLOAT = 0;  -- ЗАПОЛНИТЬ: собственный капитал на 31.12.2025
DECLARE @mrp_2025 FLOAT = 0;         -- ЗАПОЛНИТЬ: МРП на 01.01.2025
DECLARE @threshold_individual FLOAT = 0.002;  -- 0,2% по Таблице 4, п. Individual loans
DECLARE @threshold_ead_retail FLOAT = 200000000;  -- 200M threshold для розницы (некоторые источники, нестабильно между циклами)

-- Граница крупного бизнеса: > 3,000,000 МРП (Entrepreneurship Code § 6)
DECLARE @large_biz_income FLOAT = @mrp_2025 * 3000000;

-- Граница малого бизнеса: <= 300,000 МРП (§ 3)
DECLARE @small_biz_income FLOAT = @mrp_2025 * 300000;

---
-- B1A: договоры на амортизированной стоимости
---
SELECT n.*
       , COALESCE(CAST(ead AS FLOAT), 0) AS ead_n
       , COALESCE(CAST(od AS FLOAT), 0)
           + COALESCE(CAST(od_del AS FLOAT), 0)
           + COALESCE(CAST(interest AS FLOAT), 0)
           + COALESCE(CAST(interest_del AS FLOAT), 0)
           + COALESCE(CAST(disc_prem AS FLOAT), 0) AS amount  -- задолженность без пеней (п. 44)
       , CASE
           WHEN stage_b = '4' THEN '3'   -- переклассификация stage 4 → stage 3 (значение неизвестно)
           WHEN stage_b = '1111111111111' THEN '1'  -- stub-маркер: пересчитать в stage 1
           ELSE stage_b
         END AS stage
       , CASE
           -- ПРИОРИТЕТ 1: специальные статусы (DISASS, RELATE, CORINV)
           WHEN ENTITY = 'EUB1' THEN 'DISASS'
           WHEN LSBOO = 1 THEN 'RELATE'
           WHEN COALESCE(CAST(f_inv AS FLOAT), 0) = 1 THEN 'CORINV'

           -- ПРИОРИТЕТ 2: индивидуальные займы (агрегат по заёмщику > 0,2% капитала)
           -- ИСПРАВЛЕНО: условие 4 — B2A list; условие 5 — порог (> не >=)
           WHEN a.bin IS NOT NULL THEN 'Individual loans'
           WHEN SUM(COALESCE(CAST(od AS FLOAT), 0)
                    + COALESCE(CAST(od_del AS FLOAT), 0)
                    + COALESCE(CAST(interest AS FLOAT), 0)
                    + COALESCE(CAST(interest_del AS FLOAT), 0)
                    + COALESCE(CAST(correction AS FLOAT), 0)
                    + COALESCE(CAST(disc_prem AS FLOAT), 0)
                    + COALESCE(CAST(penalty AS FLOAT), 0))
                    OVER (PARTITION BY iin_bin)
                > @capital_nst2026 * @threshold_individual
           THEN 'Individual loans'

           -- ПРИОРИТЕТ 3: недвижимость (исключение: loan_obj специальных категорий)
           -- Методика: "При отнесении заёмщиков к категории крупное/среднее/малое не учитываются...
           -- кроме инвестиционных и выданных на приобретение, строительство недвижимости"
           WHEN (DEBTOR_TYPE = 1 OR (DEBTOR_TYPE = 0 AND DEBTOR_SE = 1))
               AND ENT_TYPE IN (1, 2, 3)
               AND LOAN_OBJ IN (1, 2, 3)
               AND LOAN_PURP IN (1, 2, 3, 4, 5, 8) THEN 'COREST'

           -- ПРИОРИТЕТ 4: размер бизнеса (по ent_type из системы)
           -- ТРЕБУЕТ ПРОВЕРКИ: ent_type соответствие § 24 Entrepreneurship Code?
           WHEN COALESCE(CAST(ent_type AS FLOAT), 0) = 1 THEN 'CORLAR'
           WHEN COALESCE(CAST(ent_type AS FLOAT), 0) = 2 THEN 'CORMED'
           WHEN COALESCE(CAST(ent_type AS FLOAT), 0) = 3 THEN 'RETSML'

           -- ПРИОРИТЕТ 5: розница (debtor_type=0, не ИП, EAD ≤ 200M)
           -- ИСПРАВЛЕНО: RETEST теперь требует collateral=1 (обеспеченные жилой недвижимостью)
           -- Было: COLLATERAL check commented на строке 48 AQR2025 скрипта. Включили.
           WHEN COALESCE(CAST(debtor_type AS FLOAT), 0) = 0
               AND COALESCE(CAST(ead AS FLOAT), 0) <= @threshold_ead_retail
               AND COALESCE(CAST(debtor_se AS FLOAT), 0) = 0
               AND COALESCE(CAST(collateral AS FLOAT), 0) = 1  -- ИЗМЕНЕНО: добавлено обратно
               AND portfolio IN ('Mortgage')
           THEN 'RETEST'

           -- RETCAR: обеспеченные займы прочие (не жилая недвижимость)
           WHEN COALESCE(CAST(debtor_type AS FLOAT), 0) = 0
               AND COALESCE(CAST(ead AS FLOAT), 0) <= @threshold_ead_retail
               AND COALESCE(CAST(debtor_se AS FLOAT), 0) = 0
               AND COALESCE(CAST(collateral AS FLOAT), 0) = 1
           THEN 'RETCAR'

           -- RETCON: необеспеченные займы физлиц
           WHEN COALESCE(CAST(debtor_type AS FLOAT), 0) = 0
               AND COALESCE(CAST(ead AS FLOAT), 0) <= @threshold_ead_retail
               AND COALESCE(CAST(debtor_se AS FLOAT), 0) = 0
               AND COALESCE(CAST(collateral AS FLOAT), 0) = 0
           THEN 'RETCON'

           ELSE 'X'  -- не классифицирован
         END AS segment_afr
FROM [CL_PORTFOLIO].[dbo].AQR2026_B1A_2025_Q4 n  -- ИЗМЕНЕНО: таблица для 2025-го отчётного периода
LEFT JOIN [personal_tables].[dbo].RA_NST_B2A_2026_04012026 a ON a.bin = n.IIN_BIN  -- ПРИМЕЧАНИЕ: уточнить дату снимка B2A
WHERE is_del = '0'
;

---
-- B1B: переводные договоры (изменения = изменение признаков, а не амортизированная стоимость)
---
SELECT n.*
       , COALESCE(CAST(ead AS FLOAT), 0) AS ead_n
       , COALESCE(CAST(correction AS FLOAT), 0)
           + COALESCE(CAST(penalty AS FLOAT), 0)
           + COALESCE(CAST(disc_prem AS FLOAT), 0) AS amount  -- только изменения (рассчеты и пени)
       , CASE
           WHEN stage_b = '4' THEN '3'
           WHEN stage_b = '1111111111111' THEN '1'
           ELSE stage_b
         END AS stage
       , CASE
           WHEN ENTITY = 'EUB1' THEN 'DISASS'
           WHEN LSBOO = 1 THEN 'RELATE'
           WHEN COALESCE(CAST(f_inv AS FLOAT), 0) = 1 THEN 'CORINV'

           WHEN a.bin IS NOT NULL THEN 'Individual loans'
           WHEN SUM(COALESCE(CAST(correction AS FLOAT), 0)
                    + COALESCE(CAST(disc_prem AS FLOAT), 0)
                    + COALESCE(CAST(penalty AS FLOAT), 0))
                    OVER (PARTITION BY iin_bin)
                > @capital_nst2026 * @threshold_individual
           THEN 'Individual loans'

           WHEN (DEBTOR_TYPE = 1 OR (DEBTOR_TYPE = 0 AND DEBTOR_SE = 1))
               AND ENT_TYPE IN (1, 2, 3)
               AND LOAN_OBJ IN (1, 2, 3)
               AND LOAN_PURP IN (1, 2, 3, 4, 5, 8) THEN 'COREST'

           WHEN COALESCE(CAST(ent_type AS FLOAT), 0) = 1 THEN 'CORLAR'
           WHEN COALESCE(CAST(ent_type AS FLOAT), 0) = 2 THEN 'CORMED'
           WHEN COALESCE(CAST(ent_type AS FLOAT), 0) = 3 THEN 'RETSML'

           WHEN COALESCE(CAST(debtor_type AS FLOAT), 0) = 0
               AND COALESCE(CAST(ead AS FLOAT), 0) <= @threshold_ead_retail
               AND COALESCE(CAST(debtor_se AS FLOAT), 0) = 0
               AND COALESCE(CAST(collateral AS FLOAT), 0) = 1  -- ИЗМЕНЕНО: добавлено обратно
               AND portfolio IN ('Mortgage')
           THEN 'RETEST'

           WHEN COALESCE(CAST(debtor_type AS FLOAT), 0) = 0
               AND COALESCE(CAST(ead AS FLOAT), 0) <= @threshold_ead_retail
               AND COALESCE(CAST(debtor_se AS FLOAT), 0) = 0
               AND COALESCE(CAST(collateral AS FLOAT), 0) = 1
           THEN 'RETCAR'

           WHEN COALESCE(CAST(debtor_type AS FLOAT), 0) = 0
               AND COALESCE(CAST(ead AS FLOAT), 0) <= @threshold_ead_retail
               AND COALESCE(CAST(debtor_se AS FLOAT), 0) = 0
               AND COALESCE(CAST(collateral AS FLOAT), 0) = 0
           THEN 'RETCON'

           ELSE 'X'
         END AS segment_afr
FROM [CL_PORTFOLIO].[dbo].AQR2026_B1B_2025_Q4 n  -- ИЗМЕНЕНО: таблица для 2025-го отчётного периода
LEFT JOIN [personal_tables].[dbo].RA_NST_B2A_2026_04012026 a ON a.bin = n.IIN_BIN
WHERE is_del = '0'
;

---
-- НЕДОКУМЕНТИРОВАННЫЕ / НЕ РЕАЛИЗОВАННЫЕ:
-- 1. CORGOV: требуется реестр БИН (3 госхолдинга + 2 уровня дочерности, госуч > 50%)
-- 2. Господдержка (п. 242): требуется признак программы поддержки (для ЧПД контура)
-- 3. Переклассификация Individual loans / DISASS в другие портфели (Table 3 требует)
-- 4. Проверка collateral type (жилая vs прочая) для RETEST vs RETCAR разграничения
--    (текущий код различает только наличие залога, не тип)
