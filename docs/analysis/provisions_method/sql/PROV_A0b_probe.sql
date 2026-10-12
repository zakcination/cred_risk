/* =============================================================================
   PROV_A0b_probe.sql — Track A, шаг 0b: разведка по итогам прогона A0 (12.10.2026).
   ПРЕДЛОЖЕНИЕ, запускать по решению Мираса. Ничего не считает, кроме агрегатов.
   План — TRACK_A_PLAN.md §11. Все имена колонок — из §0 прогона A0 12.10.2026.

   Вопросы и что заранее считается ответом:
   §1 Из каких колонок собран provisions_total. Ожидание (FINDINGS §3: 1428+1845+18771):
      provisions_total = ifrs + IFRS1845 + ifrs18771_WTRAF_i_PENII. Подтверждено, если
      rows_identity_broken = 0 во всех категориях; иначе — смотреть, какая сумма сходится.
   §2 Есть ли признак индивидуальной оценки. Кандидаты по именам: attribute_marker,
      [fiziki/yuriki], status, tag_1, basket, product. Домен выводится ТОЛЬКО если различных
      значений ≤ 50 (иначе это может быть свободный текст — PII-риск, выводится только счётчик).
   §3 Какую базу V умножала старая система (TRACK_A_PLAN §9.2) и действуют ли параметры
      2021 г.: число различных ROUND(ifrs / V, 4) в категориях 1–2. База, у которой оно
      на порядок меньше, — та, что применялась. Плюс: сходится ли ifrs с percent × V.
   §4 Кто такие «только old» на 01.10.2026 (3 400 договоров, 18,16 млрд ₸ остатка):
      статус × категория × Σ остаток × Σ провизии. Ожидание по FINDINGS §5 (01.07):
      статус V (расторгнут). Если не V — это новая находка, а не повтор.

   Правила (§4 CLAUDE.md): только SELECT, #A0b_*, MAXDOP 1, трёхчастные имена,
   IIN не выбирается, номера договоров — только внутри COUNT и JOIN.
   ============================================================================= */

/* §1. Состав provisions_total по категориям.                                       */
DECLARE @AsOf date = '2026-10-01';

SELECT category,
       COUNT(*)                                                        AS rows_n,
       SUM(CAST(provisions_total        AS decimal(38,2)))             AS sum_provisions_total,
       SUM(CAST(provisions_calculated   AS decimal(38,2)))             AS sum_provisions_calculated,
       SUM(CAST(ifrs                    AS decimal(38,2)))             AS sum_ifrs,
       SUM(CAST(IFRS1845                AS decimal(38,2)))             AS sum_ifrs1845,
       SUM(CAST(ifrs18771_WTRAF_i_PENII AS decimal(38,2)))             AS sum_ifrs18771,
       SUM(CAST(ifrs18770_DEB           AS decimal(38,2)))             AS sum_ifrs18770,
       SUM(CAST(IFRS1877                AS decimal(38,2)))             AS sum_ifrs1877,
       SUM(CASE WHEN ABS(ISNULL(provisions_total,0)
                         - ISNULL(ifrs,0) - ISNULL(IFRS1845,0)
                         - ISNULL(ifrs18771_WTRAF_i_PENII,0)) > 0.01
                THEN 1 ELSE 0 END)                                     AS rows_identity_broken,
       SUM(CASE WHEN ABS(ISNULL(provisions_total,0)
                         - ISNULL(provisions_calculated,0)) > 0.01
                THEN 1 ELSE 0 END)                                     AS rows_total_ne_calculated,
       SUM(CASE WHEN provisions_total IS NULL THEN 1 ELSE 0 END)       AS rows_total_null
FROM [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2]
WHERE [date] = @AsOf
GROUP BY category
ORDER BY category
OPTION (MAXDOP 1);
GO

/* §2. Кандидаты в признак индивидуальной оценки / сегмента.
   2a. Мощность домена — всегда (счётчики не PII).                                   */
DECLARE @AsOf date = '2026-10-01';

IF OBJECT_ID('tempdb..#A0b_p') IS NOT NULL DROP TABLE #A0b_p;
SELECT category, status, tag_1, attribute_marker, [fiziki/yuriki] AS fy,
       basket, product, subproduct,
       CAST(balance          AS decimal(38,2)) AS v_bal,
       CAST(provisions_total AS decimal(38,2)) AS p_total
INTO #A0b_p
FROM [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2]
WHERE [date] = @AsOf
OPTION (MAXDOP 1);

SELECT COUNT(DISTINCT status)           AS d_status,
       COUNT(DISTINCT tag_1)            AS d_tag_1,
       COUNT(DISTINCT attribute_marker) AS d_attribute_marker,
       MAX(LEN(attribute_marker))       AS maxlen_attribute_marker,
       COUNT(DISTINCT fy)               AS d_fiziki_yuriki,
       COUNT(DISTINCT basket)           AS d_basket,
       COUNT(DISTINCT product)          AS d_product,
       COUNT(DISTINCT subproduct)       AS d_subproduct
FROM #A0b_p;

/* 2b. Домены с деньгами — по одному кандидату, только при ≤ 50 различных значений.
   Строка с attr = '(домен > 50, не выводится)' означает, что значения скрыты.        */
SELECT x.cand, x.category,
       CASE WHEN d.n_distinct <= 50 THEN x.val ELSE '(домен > 50, не выводится)' END AS attr,
       COUNT(*)      AS contracts,
       SUM(x.v_bal)  AS sum_balance,
       SUM(x.p_total) AS sum_provisions
FROM (SELECT 'status' AS cand, category, CAST(status AS nvarchar(100)) AS val, v_bal, p_total FROM #A0b_p
      UNION ALL SELECT 'tag_1',            category, CAST(tag_1 AS nvarchar(100)),            v_bal, p_total FROM #A0b_p
      UNION ALL SELECT 'attribute_marker', category, CAST(attribute_marker AS nvarchar(100)), v_bal, p_total FROM #A0b_p
      UNION ALL SELECT 'fiziki/yuriki',    category, CAST(fy AS nvarchar(100)),               v_bal, p_total FROM #A0b_p
      UNION ALL SELECT 'basket',           category, CAST(basket AS nvarchar(100)),           v_bal, p_total FROM #A0b_p
      UNION ALL SELECT 'product',          category, CAST(product AS nvarchar(100)),          v_bal, p_total FROM #A0b_p) x
JOIN (SELECT 'status' AS cand, COUNT(DISTINCT status) AS n_distinct FROM #A0b_p
      UNION ALL SELECT 'tag_1',            COUNT(DISTINCT tag_1)            FROM #A0b_p
      UNION ALL SELECT 'attribute_marker', COUNT(DISTINCT attribute_marker) FROM #A0b_p
      UNION ALL SELECT 'fiziki/yuriki',    COUNT(DISTINCT fy)               FROM #A0b_p
      UNION ALL SELECT 'basket',           COUNT(DISTINCT basket)           FROM #A0b_p
      UNION ALL SELECT 'product',          COUNT(DISTINCT product)          FROM #A0b_p) d
  ON d.cand = x.cand
GROUP BY x.cand, x.category,
         CASE WHEN d.n_distinct <= 50 THEN x.val ELSE '(домен > 50, не выводится)' END
ORDER BY x.cand, x.category, attr
OPTION (MAXDOP 1);
GO

/* §3. Какая база V и какие ставки. Только категории 1–2 (там провизия = ставка × V;
   в корзине 3 — по генерациям, README §2.5). Числитель — ifrs (кандидат 1428, §1),
   не provisions_total: 1845 и 18771 размазали бы отношение у обеих баз.              */
DECLARE @AsOf date = '2026-10-01';

SELECT category,
       COUNT(*)                                                         AS rows_n,
       SUM(CASE WHEN balance > 0 THEN 1 ELSE 0 END)                     AS rows_bal_pos,
       COUNT(DISTINCT CASE WHEN balance > 0
             THEN ROUND(CAST(ifrs AS decimal(38,6))
                        / CAST(balance AS decimal(38,6)), 4) END)        AS distinct_ratio_bal,
       SUM(CASE WHEN balance_with_discount > 0 THEN 1 ELSE 0 END)       AS rows_disc_pos,
       COUNT(DISTINCT CASE WHEN balance_with_discount > 0
             THEN ROUND(CAST(ifrs AS decimal(38,6))
                        / CAST(balance_with_discount AS decimal(38,6)), 4) END) AS distinct_ratio_disc,
       COUNT(DISTINCT [percent])                                        AS distinct_percent,
       MIN([percent]) AS min_percent, MAX([percent]) AS max_percent,
       SUM(CASE WHEN ABS(ISNULL(ifrs,0) - ROUND(ISNULL([percent],0) * balance, 2)) <= 1
                THEN 1 ELSE 0 END)                                      AS rows_ifrs_eq_pct_x_bal,
       SUM(CASE WHEN ABS(ISNULL(ifrs,0) - ROUND(ISNULL([percent],0) * balance_with_discount, 2)) <= 1
                THEN 1 ELSE 0 END)                                      AS rows_ifrs_eq_pct_x_disc,
       SUM(CASE WHEN ABS(ISNULL(ifrs,0) - ROUND(ISNULL([percent],0) / 100 * balance, 2)) <= 1
                THEN 1 ELSE 0 END)                                      AS rows_ifrs_eq_pct100_x_bal
FROM [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2]
WHERE [date] = @AsOf AND category IN (1, 2)
GROUP BY category
ORDER BY category
OPTION (MAXDOP 1);

/* 3b. Ставки, которые реально стоят в старой базе, против параметров KAN 2021 г.:
   продукт × категория × percent — только агрегаты (продукт и ставка — не PII).
   Сравнить глазами с выводом 1c прогона A0: совпадают ли percent с PD × LGD.        */
SELECT category, product, basket, [percent],
       COUNT(*) AS contracts,
       SUM(CAST(balance AS decimal(38,2))) AS sum_balance,
       SUM(CAST(ifrs    AS decimal(38,2))) AS sum_ifrs
FROM [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2]
WHERE [date] = @AsOf AND category IN (1, 2)
GROUP BY category, product, basket, [percent]
HAVING COUNT(*) >= 10                                   -- мелкие группы не выводятся
ORDER BY category, product, basket, contracts DESC
OPTION (MAXDOP 1);
GO

/* §4. «Только old» на 01.10.2026: кто они.                                          */
DECLARE @AsOf date = '2026-10-01';

IF OBJECT_ID('tempdb..#A0b_new') IS NOT NULL DROP TABLE #A0b_new;
SELECT DISTINCT l.l_loan_number AS contract_number
INTO #A0b_new
FROM [Dictionaries].[risk_analytics].[loan_account] la
JOIN [Dictionaries].[risk_analytics].[loans] l
  ON l.l_gid = la.la_gid AND l.l_source = la.la_source
WHERE la.la_source = 'S03' AND la.la_reporting_date = @AsOf
OPTION (MAXDOP 1);

SELECT o.category, o.status,
       COUNT(*)                                          AS contracts,
       SUM(CAST(o.balance          AS decimal(38,2)))    AS sum_balance,
       SUM(CAST(o.provisions_total AS decimal(38,2)))    AS sum_provisions_total,
       SUM(CAST(o.ifrs             AS decimal(38,2)))    AS sum_ifrs
FROM [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2] o
LEFT JOIN #A0b_new n ON n.contract_number = o.contract_number
WHERE o.[date] = @AsOf AND n.contract_number IS NULL
GROUP BY o.category, o.status
ORDER BY o.category, contracts DESC
OPTION (MAXDOP 1);
GO

IF OBJECT_ID('tempdb..#A0b_p')   IS NOT NULL DROP TABLE #A0b_p;
IF OBJECT_ID('tempdb..#A0b_new') IS NOT NULL DROP TABLE #A0b_new;
