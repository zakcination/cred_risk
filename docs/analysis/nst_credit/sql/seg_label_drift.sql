/* ============================================================================
   Сколько договоров меняют сегмент из-за метки, а не из-за продукта.

   ЗАЧЕМ
   ---------------------------------------------------------------------------
   Довод «метка в колонке сегмента рвёт историю займа» до сих пор был
   рассуждением. Здесь он превращается в число.

   Если признак индивидуальности стоит в колонке сегмента, заём переезжает
   из своего продуктового сегмента в «Individual loans», как только заёмщик
   пересёк порог 0,2 % капитала. Матрица переходов записывает миграцию,
   которой не было: кредитное качество не менялось.

   Хуже того, порог сам движется — он считается от капитала, а капитал между
   отчётными датами изменился. Скрипт разделяет два источника пересечения:
     - долг заёмщика вырос или упал      -> содержательное изменение
     - порог сдвинулся при том же долге  -> чистый артефакт базы капитала

   ПЕРИОД И ПОРОГИ
   ---------------------------------------------------------------------------
   2024 Q4 -> 2025 Q4, договоры, присутствующие в обеих базах.
     2024: 0,2 % от 461 235 157 000 =   922 470 314 ₸  (балансовый СК)
     2025: 0,2 % от 503 086 114 000 = 1 006 172 228 ₸  (регуляторный СК)
   Разные базы капитала между периодами — ТР13, отдельный открытый вопрос.
   Скрипт берёт пороги такими, какими они фактически применялись.

   Read-only: только SELECT. Один #temp с префиксом файла. MAXDOP 1.
   § 2: агрегаты; в детализации только номер договора, заёмщики — бакетами.
   ========================================================================= */

SET NOCOUNT ON;

DECLARE @t24 float = 461235157000 * 0.002;   --   922 470 314
DECLARE @t25 float = 503086114000 * 0.002;   -- 1 006 172 228

IF OBJECT_ID('tempdb..#drift') IS NOT NULL DROP TABLE #drift;

WITH p24 AS (
    SELECT
          b.loan_id_kr
        , b.iin_bin
        , COALESCE(TRY_CAST(b.ead AS float), 0)                       AS ead24
        , COALESCE(TRY_CAST(b.od AS float),0) + COALESCE(TRY_CAST(b.od_del AS float),0)
        + COALESCE(TRY_CAST(b.interest AS float),0) + COALESCE(TRY_CAST(b.interest_del AS float),0)
        + COALESCE(TRY_CAST(b.correction AS float),0) + COALESCE(TRY_CAST(b.disc_prem AS float),0)
        + COALESCE(TRY_CAST(b.penalty AS float),0)                    AS zadol24
        , CASE
            WHEN COALESCE(TRY_CAST(b.debtor_type AS int),0) = 0
             AND COALESCE(TRY_CAST(b.debtor_se AS int),0) = 0
              THEN CASE TRY_CAST(b.loan_obj AS int)
                     WHEN 1 THEN 'RETEST' WHEN 6 THEN 'RETCAR' ELSE 'RETCON' END
            WHEN TRY_CAST(b.loan_obj AS int) IN (1,2,3) THEN 'COREST'
            WHEN TRY_CAST(b.ent_type AS int) = 1        THEN 'CORLAR'
            WHEN TRY_CAST(b.ent_type AS int) = 2        THEN 'CORMED'
            WHEN TRY_CAST(b.ent_type AS int) = 3        THEN 'RETSML'
            ELSE 'X'
          END                                                         AS seg24
        , CASE WHEN a.bin IS NOT NULL THEN 1 ELSE 0 END               AS list24
    FROM       [CL_PORTFOLIO].[dbo].[AQR2025_B1A_2024_Q4]             AS b
    LEFT JOIN  [personal_tables].[dbo].[RA_NST_B2A_AQR2025_11082025]  AS a
           ON  a.bin = b.iin_bin
    WHERE b.is_del = '0'
),
p25 AS (
    SELECT
          n.loan_id_kr
        , n.iin_bin
        , COALESCE(TRY_CAST(n.ead AS float), 0)                       AS ead25
        , COALESCE(TRY_CAST(n.od AS float),0) + COALESCE(TRY_CAST(n.od_del AS float),0)
        + COALESCE(TRY_CAST(n.interest AS float),0) + COALESCE(TRY_CAST(n.interest_del AS float),0)
        + COALESCE(TRY_CAST(n.correction AS float),0) + COALESCE(TRY_CAST(n.disc_prem AS float),0)
        + COALESCE(TRY_CAST(n.penalty AS float),0)                    AS zadol25
        , CASE
            WHEN COALESCE(TRY_CAST(n.debtor_type AS int),0) = 0
             AND COALESCE(TRY_CAST(n.debtor_se AS int),0) = 0
              THEN CASE TRY_CAST(n.loan_obj AS int)
                     WHEN 1 THEN 'RETEST' WHEN 6 THEN 'RETCAR' ELSE 'RETCON' END
            WHEN TRY_CAST(n.loan_obj AS int) IN (1,2,3) THEN 'COREST'
            WHEN TRY_CAST(n.ent_type AS int) = 1        THEN 'CORLAR'
            WHEN TRY_CAST(n.ent_type AS int) = 2        THEN 'CORMED'
            WHEN TRY_CAST(n.ent_type AS int) = 3        THEN 'RETSML'
            ELSE 'X'
          END                                                         AS seg25
        , CASE WHEN a.bin IS NOT NULL THEN 1 ELSE 0 END               AS list25
    FROM       [CL_PORTFOLIO].[dbo].[AQR2026_B1A_2025_Q4]             AS n
    LEFT JOIN  [personal_tables].[dbo].[RA_NST_B2A_2026_04012026]     AS a
           ON  a.bin = n.iin_bin
    WHERE n.is_del = '0'
),
agg AS (
    SELECT
          a.loan_id_kr, a.iin_bin, a.seg24, a.ead24, a.list24
        , b.seg25, b.ead25, b.list25
        , SUM(a.zadol24) OVER (PARTITION BY a.iin_bin)                AS zb24
        , SUM(b.zadol25) OVER (PARTITION BY b.iin_bin)                AS zb25
    FROM p24 a
    JOIN p25 b ON b.loan_id_kr = a.loan_id_kr
)
SELECT
      loan_id_kr, iin_bin, seg24, seg25, ead24, ead25, zb24, zb25
    , CASE WHEN list24 = 1 OR zb24 > @t24 THEN 1 ELSE 0 END           AS ind24
    , CASE WHEN list25 = 1 OR zb25 > @t25 THEN 1 ELSE 0 END           AS ind25
    -- контрфакт: индивидуальность 2025 года при СТАРОМ пороге.
    -- расхождение с ind25 означает, что пересечение вызвано сдвигом порога
    , CASE WHEN list25 = 1 OR zb25 > @t24 THEN 1 ELSE 0 END           AS ind25_at_old_thr
INTO #drift
FROM agg
OPTION (MAXDOP 1);


/* ============================================================================
   ВЫВОД 1. ГЛАВНЫЙ. Что менялось: продукт, метка, обе или ничего
   ========================================================================= */
SELECT
      CASE WHEN seg24 <> seg25 THEN 'продукт изменился' ELSE 'продукт тот же' END AS product
    , CASE WHEN ind24 <> ind25 THEN 'метка изменилась' ELSE 'метка та же'     END AS label
    , COUNT(*)                                                        AS contracts
    , COUNT(DISTINCT iin_bin)                                         AS borrowers
    , SUM(ead25)                                                      AS ead_2025
FROM #drift
GROUP BY CASE WHEN seg24 <> seg25 THEN 'продукт изменился' ELSE 'продукт тот же' END
       , CASE WHEN ind24 <> ind25 THEN 'метка изменилась' ELSE 'метка та же'     END
ORDER BY contracts DESC;

/* ============================================================================
   ВЫВОД 2. ЦЕНА ОШИБКИ. «Продукт тот же + метка изменилась» — ровно те
            договоры, которые при старой конструкции записали бы миграцию
            между сегментами без единого кредитного события.
   ========================================================================= */
SELECT
      seg25                                                           AS product_segment
    , CASE WHEN ind25 = 1 THEN 'стал индивидуальным' ELSE 'перестал быть' END AS direction
    , COUNT(*)                                                        AS contracts
    , COUNT(DISTINCT iin_bin)                                         AS borrowers
    , SUM(ead25)                                                      AS ead_2025
FROM #drift
WHERE seg24 = seg25 AND ind24 <> ind25
GROUP BY seg25, CASE WHEN ind25 = 1 THEN 'стал индивидуальным' ELSE 'перестал быть' END
ORDER BY ead_2025 DESC;

/* ============================================================================
   ВЫВОД 3. ИЗ ЧЕГО СЛОЖИЛОСЬ ПЕРЕСЕЧЕНИЕ ПОРОГА.
            Долг изменился — содержательно. Порог сдвинулся — артефакт.
   ========================================================================= */
SELECT
      CASE
        WHEN ind25 = 1 AND ind25_at_old_thr = 0 THEN 'пересёк только из-за сдвига порога'
        WHEN ind25 = 1 AND ind25_at_old_thr = 1 THEN 'пересёк бы и при старом пороге'
        WHEN ind25 = 0 AND ind25_at_old_thr = 1 THEN 'не пересёк только из-за сдвига порога'
        ELSE                                         'порог ни при чём'
      END                                                             AS reason
    , COUNT(*)                                                        AS contracts
    , COUNT(DISTINCT iin_bin)                                         AS borrowers
    , SUM(ead25)                                                      AS ead_2025
FROM #drift
WHERE ind24 <> ind25
GROUP BY CASE
        WHEN ind25 = 1 AND ind25_at_old_thr = 0 THEN 'пересёк только из-за сдвига порога'
        WHEN ind25 = 1 AND ind25_at_old_thr = 1 THEN 'пересёк бы и при старом пороге'
        WHEN ind25 = 0 AND ind25_at_old_thr = 1 THEN 'не пересёк только из-за сдвига порога'
        ELSE                                         'порог ни при чём'
      END
ORDER BY ead_2025 DESC;

/* ============================================================================
   ВЫВОД 4. Заёмщики у границы порога — бакетами, без сумм по заёмщику (§ 2)
   ========================================================================= */
SELECT
      CASE
        WHEN zb25 < @t25 * 0.8 THEN 'ниже порога более чем на 20 %'
        WHEN zb25 < @t25       THEN 'ниже порога, в пределах 20 %'
        WHEN zb25 < @t25 * 1.2 THEN 'выше порога, в пределах 20 %'
        ELSE                        'выше порога более чем на 20 %'
      END                                                             AS bucket
    , COUNT(DISTINCT iin_bin)                                         AS borrowers
    , COUNT(*)                                                        AS contracts
    , SUM(ead25)                                                      AS ead_2025
FROM #drift
GROUP BY CASE
        WHEN zb25 < @t25 * 0.8 THEN 'ниже порога более чем на 20 %'
        WHEN zb25 < @t25       THEN 'ниже порога, в пределах 20 %'
        WHEN zb25 < @t25 * 1.2 THEN 'выше порога, в пределах 20 %'
        ELSE                        'выше порога более чем на 20 %'
      END
ORDER BY borrowers DESC;

/* ============================================================================
   ВЫВОД 5. Контроль покрытия
   ========================================================================= */
SELECT 'договоров в обеих базах' AS control, COUNT(*) AS n, SUM(ead25) AS ead FROM #drift
UNION ALL
SELECT 'сегмент не распознан хотя бы в одном году', COUNT(*), SUM(ead25)
FROM #drift WHERE seg24 = 'X' OR seg25 = 'X';

DROP TABLE #drift;
