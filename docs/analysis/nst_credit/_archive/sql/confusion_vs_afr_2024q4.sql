/* ============================================================================
   Матрица ошибок: наш скрипт против эталона АФР.

   База      : AQR2025_B1A_2024_Q4 + RA_NST_segment_AQR2025 (segment_afr)
               Это единственный период, где эталон есть. В 2025 Q4 его нет,
               поэтому калибровать правила можно только здесь.
   Read-only : только SELECT, единственный #temp с префиксом файла.
   Результат : 8 таблиц — сводная точность, матрица ошибок, таксономия
               расхождений и разбор причин по каждому типу.

   Сравниваются ДВА набора правил:
     cur — действующий segmentation_nst2026.sql (collateral + portfolio)
     fix — предлагаемый (loan_obj, флаги вынесены из сегмента)

   TRY_CAST вместо CAST везде: колонки сумм — nvarchar, в них есть нечисловой
   мусор. Именно он давал "Error converting data type nvarchar to float".
   ========================================================================= */

SET NOCOUNT ON;

DECLARE @capital   float = 461235157000;   -- СК на 01.01.2025 (период эталона)
DECLARE @thr_ind   float = 0.002;
DECLARE @thr_ead   float = 200000000;

IF OBJECT_ID('tempdb..#conf_scored') IS NOT NULL DROP TABLE #conf_scored;

/* ---- 1. База: признаки + эталон + агрегат задолженности по заёмщику ----- */
WITH conf_base AS (
    SELECT
          b.loan_id_kr
        , b.iin_bin
        , b.entity
        , b.lsboo
        , TRY_CAST(b.f_inv       AS int)   AS f_inv_n
        , TRY_CAST(b.debtor_type AS int)   AS debtor_type_n
        , TRY_CAST(b.debtor_se   AS int)   AS debtor_se_n
        , TRY_CAST(b.ent_type    AS int)   AS ent_type_n
        , TRY_CAST(b.loan_obj    AS int)   AS loan_obj_n
        , TRY_CAST(b.loan_purp   AS int)   AS loan_purp_n
        , TRY_CAST(b.collateral  AS int)   AS collateral_n
        , b.portfolio
        , COALESCE(TRY_CAST(b.ead AS float), 0)                     AS ead_n
        , COALESCE(TRY_CAST(b.od           AS float), 0)
        + COALESCE(TRY_CAST(b.od_del       AS float), 0)
        + COALESCE(TRY_CAST(b.interest     AS float), 0)
        + COALESCE(TRY_CAST(b.interest_del AS float), 0)
        + COALESCE(TRY_CAST(b.correction   AS float), 0)
        + COALESCE(TRY_CAST(b.disc_prem    AS float), 0)
        + COALESCE(TRY_CAST(b.penalty      AS float), 0)             AS zadol
        , s.segment_afr                                              AS afr
        , CASE WHEN a.bin IS NOT NULL THEN 1 ELSE 0 END              AS in_b2a
    FROM       [CL_PORTFOLIO].[dbo].[AQR2025_B1A_2024_Q4]            AS b
    LEFT JOIN  [personal_tables].[dbo].[RA_NST_segment_AQR2025]      AS s
           ON  s.loan_id_kr = b.loan_id_kr
    LEFT JOIN  [personal_tables].[dbo].[RA_NST_B2A_AQR2025_11082025] AS a
           ON  a.bin = b.iin_bin
    WHERE b.is_del = '0'
),
conf_agg AS (
    SELECT *, SUM(zadol) OVER (PARTITION BY iin_bin) AS zadol_borrower
    FROM conf_base
)
SELECT
      loan_id_kr, iin_bin, entity, lsboo, f_inv_n
    , debtor_type_n, debtor_se_n, ent_type_n, loan_obj_n, loan_purp_n
    , collateral_n, portfolio, ead_n, zadol, zadol_borrower, afr, in_b2a

    /* ---- ДЕЙСТВУЮЩИЕ правила (segmentation_nst2026.sql) ---------------- */
    , CASE
        WHEN entity = 'EUB1'                          THEN 'DISASS'
        WHEN lsboo  = 1                               THEN 'RELATE'
        WHEN COALESCE(f_inv_n, 0) = 1                 THEN 'CORINV'
        WHEN in_b2a = 1                               THEN 'Individual loans'
        WHEN zadol_borrower > @capital * @thr_ind     THEN 'Individual loans'
        WHEN (debtor_type_n = 1 OR (debtor_type_n = 0 AND debtor_se_n = 1))
             AND ent_type_n  IN (1, 2, 3)
             AND loan_obj_n  IN (1, 2, 3)
             AND loan_purp_n IN (1, 2, 3, 4, 5, 8)    THEN 'COREST'
        WHEN ent_type_n = 1                           THEN 'CORLAR'
        WHEN ent_type_n = 2                           THEN 'CORMED'
        WHEN ent_type_n = 3                           THEN 'RETSML'
        WHEN COALESCE(debtor_type_n, 0) = 0 AND ead_n <= @thr_ead
             AND COALESCE(debtor_se_n, 0) = 0
             AND COALESCE(collateral_n, 0) = 1
             AND portfolio IN ('Mortgage')            THEN 'RETEST'
        WHEN COALESCE(debtor_type_n, 0) = 0 AND ead_n <= @thr_ead
             AND COALESCE(debtor_se_n, 0) = 0
             AND COALESCE(collateral_n, 0) = 1        THEN 'RETCAR'
        WHEN COALESCE(debtor_type_n, 0) = 0 AND ead_n <= @thr_ead
             AND COALESCE(debtor_se_n, 0) = 0
             AND COALESCE(collateral_n, 0) = 0        THEN 'RETCON'
        ELSE 'X'
      END AS cur

    /* ---- ПРЕДЛАГАЕМЫЕ правила ------------------------------------------
       Отличия:
         1. DISASS / RELATE / CORINV / Individual loans НЕ конечные значения —
            это флаги, заём всё равно классифицируется по продукту (Таблица 3).
         2. Розница делится по loan_obj, а не по collateral / portfolio.
         3. Из фильтра COREST убраны loan_purp 4 и 5 (в данных не существуют)
            и снято требование заполненного ent_type.
         4. Снят порог EAD 200 млн — в Таблице 4 его нет.                  */
    , CASE
        WHEN COALESCE(debtor_type_n, 0) = 0 AND COALESCE(debtor_se_n, 0) = 0
          THEN CASE loan_obj_n
                 WHEN 1 THEN 'RETEST'
                 WHEN 6 THEN 'RETCAR'
                 ELSE        'RETCON'
               END
        WHEN loan_obj_n IN (1, 2, 3)                  THEN 'COREST'
        WHEN ent_type_n = 1                           THEN 'CORLAR'
        WHEN ent_type_n = 2                           THEN 'CORMED'
        WHEN ent_type_n = 3                           THEN 'RETSML'
        ELSE 'X'
      END AS fix
INTO #conf_scored
FROM conf_agg
OPTION (MAXDOP 1);


/* ============================================================================
   ТАБЛИЦА 1. Сводная точность: действующие правила против предлагаемых
   ========================================================================= */
SELECT
      'ИТОГО' AS scope
    , COUNT(*)                                                    AS rows_total
    , SUM(CASE WHEN afr IS NULL THEN 1 ELSE 0 END)                AS no_ground_truth
    , SUM(CASE WHEN afr IS NOT NULL AND cur = afr THEN 1 ELSE 0 END) AS cur_hit
    , SUM(CASE WHEN afr IS NOT NULL AND fix = afr THEN 1 ELSE 0 END) AS fix_hit
    , ROUND(100.0 * SUM(CASE WHEN afr IS NOT NULL AND cur = afr THEN 1 ELSE 0 END)
            / NULLIF(SUM(CASE WHEN afr IS NOT NULL THEN 1 ELSE 0 END), 0), 2) AS cur_acc_pct
    , ROUND(100.0 * SUM(CASE WHEN afr IS NOT NULL AND fix = afr THEN 1 ELSE 0 END)
            / NULLIF(SUM(CASE WHEN afr IS NOT NULL THEN 1 ELSE 0 END), 0), 2) AS fix_acc_pct
FROM #conf_scored;


/* ============================================================================
   ТАБЛИЦА 2. Таксономия расхождений действующих правил
   Каждое расхождение отнесено к одному типу — по причине, а не по паре кодов.
   ========================================================================= */
SELECT
      err_type
    , COUNT(*)                                   AS contracts
    , ROUND(SUM(ead_n) / 1000000000.0, 2)        AS ead_bln
    , ROUND(100.0 * SUM(ead_n) / SUM(SUM(ead_n)) OVER (), 2) AS ead_pct
FROM (
    SELECT ead_n,
      CASE
        WHEN afr IS NULL                                    THEN 'F. без эталона'
        WHEN cur = afr                                      THEN 'OK'
        WHEN cur IN ('DISASS','RELATE','CORINV','Individual loans')
                                                            THEN 'A. флаг вместо продукта'
        WHEN cur IN ('RETEST','RETCAR','RETCON')
         AND afr IN ('RETEST','RETCAR','RETCON')            THEN 'B. розница: критерий деления'
        WHEN cur IN ('CORLAR','CORMED','RETSML','COREST')
         AND afr IN ('CORLAR','CORMED','RETSML','COREST')   THEN 'C. размер бизнеса (ent_type)'
        WHEN cur = 'X'                                      THEN 'E. не классифицирован'
        ELSE                                                     'D. розница ↔ бизнес'
      END AS err_type
    FROM #conf_scored
) t
GROUP BY err_type
ORDER BY ead_bln DESC;


/* ============================================================================
   ТАБЛИЦА 3. Матрица ошибок действующих правил (только расхождения)
   ========================================================================= */
SELECT TOP 40
      cur                                   AS our_segment
    , afr                                   AS afr_segment
    , COUNT(*)                              AS contracts
    , ROUND(SUM(ead_n) / 1000000.0, 1)      AS ead_mln
FROM #conf_scored
WHERE afr IS NOT NULL AND cur <> afr
GROUP BY cur, afr
ORDER BY contracts DESC;


/* ============================================================================
   ТАБЛИЦА 4. Тип A — куда эталон девает то, что мы считаем флагом
   Показывает, что перераспределение из Таблицы 3 обязательно.
   ========================================================================= */
SELECT
      cur                                   AS our_flag_segment
    , afr                                   AS afr_segment
    , COUNT(*)                              AS contracts
    , ROUND(SUM(ead_n) / 1000000.0, 1)      AS ead_mln
FROM #conf_scored
WHERE cur IN ('DISASS','RELATE','CORINV','Individual loans')
  AND afr IS NOT NULL
GROUP BY cur, afr
ORDER BY cur, contracts DESC;


/* ============================================================================
   ТАБЛИЦА 5. Тип B — розница: что определяет сегмент, loan_obj или collateral
   Если эталон постоянен по loan_obj и «плавает» по collateral — критерий loan_obj.
   ========================================================================= */
SELECT
      loan_obj_n
    , COALESCE(collateral_n, -1)            AS collateral_n
    , afr                                   AS afr_segment
    , COUNT(*)                              AS contracts
    , ROUND(SUM(ead_n) / 1000000.0, 1)      AS ead_mln
FROM #conf_scored
WHERE COALESCE(debtor_type_n, 0) = 0
  AND COALESCE(debtor_se_n, 0)   = 0
  AND afr IS NOT NULL
GROUP BY loan_obj_n, COALESCE(collateral_n, -1), afr
HAVING COUNT(*) >= 10
ORDER BY loan_obj_n, collateral_n, contracts DESC;


/* ============================================================================
   ТАБЛИЦА 6. Тип C — ent_type против эталона (доля согласия по каждому коду)
   ========================================================================= */
SELECT
      ent_type_n
    , afr                                   AS afr_segment
    , COUNT(*)                              AS contracts
    , ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY ent_type_n), 1) AS pct_within_ent_type
    , ROUND(SUM(ead_n) / 1000000.0, 1)      AS ead_mln
FROM #conf_scored
WHERE afr IS NOT NULL
GROUP BY ent_type_n, afr
ORDER BY ent_type_n, contracts DESC;


/* ============================================================================
   ТАБЛИЦА 7. Тип D — работоспособность фильтра COREST по loan_purp
   Проверка утверждения «фильтр пропускает 99,5 % портфеля и ничего не отсекает».
   ========================================================================= */
SELECT
      loan_purp_n
    , COUNT(*)                              AS contracts
    , ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_portfolio
    , SUM(CASE WHEN loan_purp_n IN (1,2,3,4,5,8) THEN 1 ELSE 0 END) AS passes_corest_filter
FROM #conf_scored
GROUP BY loan_purp_n
ORDER BY contracts DESC;


/* ============================================================================
   ТАБЛИЦА 8. Цена снятого порога EAD 200 млн — сколько розницы его превышает
   ========================================================================= */
SELECT
      'розница сверх 200 млн' AS scope
    , COUNT(*)                              AS contracts
    , ROUND(SUM(ead_n) / 1000000.0, 1)      AS ead_mln
    , SUM(CASE WHEN cur = 'X' THEN 1 ELSE 0 END) AS ended_up_unclassified
FROM #conf_scored
WHERE COALESCE(debtor_type_n, 0) = 0
  AND COALESCE(debtor_se_n, 0)   = 0
  AND ead_n > @thr_ead;

DROP TABLE #conf_scored;
