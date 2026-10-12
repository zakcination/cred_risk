/* =============================================================================
   PROV_A0c_probe.sql — Track A, шаг 0c. ПРЕДЛОЖЕНИЕ, запускать по решению Мираса.
   Повод — прогон A0b 12.10.2026 (TRACK_A_PLAN.md §11.4). Имена колонок — из §0 A0.

   Вопросы и критерии (зафиксированы до прогона):
   §1 База V старой системы. В A0b §3 пропущен вариант percent/100 × balance_with_discount
      (ошибка скрипта A0b, не данных). Критерий: база, при которой
      |ifrs − ROUND(percent/100 × V, 2)| ≤ 1 у ≥ 95 % строк категорий 1–2 с V > 0.
      Ни одна не проходит — правило не «ставка × база», вопрос ОПАиРоз.
   §2 provisions_calculated против provisions_total (Σ calculated выше на 15,79 млрд ₸,
      из них 15,29 — категория 3). Разрез по категории × basket: где и в какую сторону.
   §3 P_new по счетам провизий новой базы на общих договорах — для главной формы
      TRACK_A_PLAN §3. Имена la_account_1428/1845/18771 подтверждены §0 A0.
   §4 «Только new» (1 934): статус, Σ total_balance_debt, Σ провизий новой базы.
      Ожидание по FINDINGS §4 (01.07): остаток ≈ 0. Ненулевой остаток — находка.
   §5 Скрининг индивидуальной значимости без ИИН: договоры с balance > 50 млн ₸ —
      нижняя граница порога индивидуальности (README §1: «не менее 50 млн ₸»).
      и 180 млн ₸ (README §3, «п. 14 методики»). Порог 0,2 % СК не применён: величина СК
      на 01.10 не подтверждена. Оценка снизу: порог — по заёмщику, не по договору.

   Правила (§4 CLAUDE.md): только SELECT, #A0c_*, MAXDOP 1, трёхчастные имена, IIN не
   выбирается, номера договоров — только внутри JOIN/COUNT.
   ============================================================================= */

/* §1. База V: доля точных совпадений ставка × база, категории 1–3.               */
DECLARE @AsOf date = '2026-10-01';

SELECT category,
       SUM(CASE WHEN balance > 0 THEN 1 ELSE 0 END)                       AS rows_bal_pos,
       SUM(CASE WHEN balance > 0
                 AND ABS(ISNULL(ifrs,0) - ROUND([percent] / 100 * balance, 2)) <= 1
                THEN 1 ELSE 0 END)                                        AS match_pct100_bal,
       SUM(CASE WHEN balance_with_discount > 0 THEN 1 ELSE 0 END)         AS rows_disc_pos,
       SUM(CASE WHEN balance_with_discount > 0
                 AND ABS(ISNULL(ifrs,0) - ROUND([percent] / 100 * balance_with_discount, 2)) <= 1
                THEN 1 ELSE 0 END)                                        AS match_pct100_disc,
       SUM(CAST(ifrs AS decimal(38,2)))                                   AS sum_ifrs,
       SUM(CAST([percent] / 100 * balance               AS decimal(38,2))) AS sum_pct_x_bal,
       SUM(CAST([percent] / 100 * balance_with_discount AS decimal(38,2))) AS sum_pct_x_disc,
       SUM(CASE WHEN [percent] IS NULL THEN 1 ELSE 0 END)                 AS rows_percent_null
FROM [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2]
WHERE [date] = @AsOf AND category IN (1, 2, 3)
GROUP BY category
ORDER BY category
OPTION (MAXDOP 1);
GO

/* §2. provisions_calculated против provisions_total.                              */
DECLARE @AsOf date = '2026-10-01';

SELECT category, basket,
       COUNT(*)                                                        AS rows_n,
       SUM(CASE WHEN provisions_calculated > provisions_total + 0.01 THEN 1 ELSE 0 END) AS rows_calc_gt_total,
       SUM(CASE WHEN provisions_calculated < provisions_total - 0.01 THEN 1 ELSE 0 END) AS rows_calc_lt_total,
       SUM(CAST(provisions_calculated AS decimal(38,2)))               AS sum_calculated,
       SUM(CAST(provisions_total      AS decimal(38,2)))               AS sum_total,
       SUM(CAST(balance               AS decimal(38,2)))               AS sum_balance,
       SUM(CASE WHEN provisions_calculated > balance + 0.01 THEN 1 ELSE 0 END) AS rows_calc_gt_balance
FROM [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2]
WHERE [date] = @AsOf
GROUP BY category, basket
ORDER BY category, basket
OPTION (MAXDOP 1);
GO

/* §3–§4. Новая база: общие и «только new».                                         */
DECLARE @AsOf date = '2026-10-01';

IF OBJECT_ID('tempdb..#A0c_new') IS NOT NULL DROP TABLE #A0c_new;
SELECT l.l_loan_number                                         AS contract_number,
       MIN(la.la_status)                                       AS la_status,
       SUM(CAST(la.total_balance_debt AS decimal(38,2)))       AS v_new,
       SUM(CAST(la.la_account_1428  AS decimal(38,2)))         AS p_1428,
       SUM(CAST(la.la_account_1845  AS decimal(38,2)))         AS p_1845,
       SUM(CAST(la.la_account_18771 AS decimal(38,2)))         AS p_18771
INTO #A0c_new
FROM [Dictionaries].[risk_analytics].[loan_account] la
JOIN [Dictionaries].[risk_analytics].[loans] l
  ON l.l_gid = la.la_gid AND l.l_source = la.la_source
WHERE la.la_source = 'S03' AND la.la_reporting_date = @AsOf
GROUP BY l.l_loan_number
OPTION (MAXDOP 1);

-- §3. P_new против P_old на общих договорах, по категории старой базы.
SELECT o.category,
       COUNT(*)                                           AS contracts,
       SUM(CAST(o.provisions_total AS decimal(38,2)))     AS p_old,
       SUM(CAST(o.ifrs             AS decimal(38,2)))     AS p_old_1428,
       SUM(CAST(o.ifrs18771_WTRAF_i_PENII AS decimal(38,2))) AS p_old_18771,
       SUM(n.p_1428 + n.p_1845 + n.p_18771)               AS p_new,
       SUM(n.p_1428)                                      AS p_new_1428,
       SUM(n.p_1845)                                      AS p_new_1845,
       SUM(n.p_18771)                                     AS p_new_18771,
       SUM(CASE WHEN n.p_1428 IS NULL OR n.p_1845 IS NULL OR n.p_18771 IS NULL
                THEN 1 ELSE 0 END)                        AS rows_p_new_any_null,
       SUM(ABS(ISNULL(n.p_1428,0) - ISNULL(o.ifrs,0)))    AS abs_d_1428
FROM [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2] o
JOIN #A0c_new n ON n.contract_number = o.contract_number
WHERE o.[date] = @AsOf
GROUP BY o.category
ORDER BY o.category
OPTION (MAXDOP 1);

-- §4. «Только new».
SELECT n.la_status,
       COUNT(*)                                   AS contracts,
       SUM(CASE WHEN ABS(ISNULL(n.v_new,0)) > 0.01 THEN 1 ELSE 0 END) AS contracts_v_ne0,
       SUM(n.v_new)                               AS sum_v_new,
       SUM(n.p_1428 + n.p_1845 + n.p_18771)       AS p_new,
       SUM(n.p_18771)                             AS p_new_18771
FROM #A0c_new n
LEFT JOIN (SELECT contract_number FROM [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2]
           WHERE [date] = @AsOf) o
       ON o.contract_number = n.contract_number
WHERE o.contract_number IS NULL
GROUP BY n.la_status
ORDER BY contracts DESC
OPTION (MAXDOP 1);
GO

/* §5. Скрининг индивидуальной значимости по договору (оценка снизу, без ИИН).        */
DECLARE @AsOf date = '2026-10-01';

SELECT category,
       CASE WHEN balance > 180000000 THEN '2 > 180 млн'
            WHEN balance >  50000000 THEN '1 50–180 млн'
            ELSE                          '0 <= 50 млн' END            AS size_bucket,
       COUNT(*)                                                         AS contracts,
       SUM(CAST(balance          AS decimal(38,2)))                     AS sum_balance,
       SUM(CAST(provisions_total AS decimal(38,2)))                     AS sum_provisions
FROM [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2]
WHERE [date] = @AsOf
GROUP BY category,
       CASE WHEN balance > 180000000 THEN '2 > 180 млн'
            WHEN balance >  50000000 THEN '1 50–180 млн'
            ELSE                          '0 <= 50 млн' END
ORDER BY category, size_bucket
OPTION (MAXDOP 1);
GO

IF OBJECT_ID('tempdb..#A0c_new') IS NOT NULL DROP TABLE #A0c_new;
