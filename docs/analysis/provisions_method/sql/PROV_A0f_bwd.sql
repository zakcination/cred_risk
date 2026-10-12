/* =============================================================================
   PROV_A0f_bwd.sql — Track A, шаг 0f: ΔV на базе balance_with_discount.
   ПРЕДЛОЖЕНИЕ, запускать по решению Мираса. План — TRACK_A_PLAN.md §11.11.
   Р-10: @AsOf = 01.09.2026 (было 01.10.2026); логика и критерии без изменений,
   ожидания на 01.09 — TRACK_A_PLAN.md §14. Порядок запуска — PROV_A_0901_run.sql.

   Повод — A0d (12.10.2026): ни одна формула bwd из документа не сходится построчно
   (3–13 % строк), зато в loan_account нашлась готовая колонка
   discounted_balance_debt (§2 A0d). Проверяем её напрямую, формулу не собираем.

   Вопросы и критерии (до прогона):
   §1 discounted_balance_debt (new) = balance_with_discount (old) на общих договорах?
      Совпадение: |Δ| ≤ 0,01 у ≥ 99 % договоров каждой категории → V_new для моста =
      discounted_balance_debt. Меньше — колонка не та, вопрос по составу (§2).
      Точная оценка эффекта на провизии: Σ |ΔV_i| × percent_i / 100.
   §2 Состав разницы balance − bwd в старой базе с субсчетами DISCOUNT_14341/14342/
      17731/17732 (в A0d не участвовали). Только суммы по категориям — для письма
      ОПАиРоз и FINDINGS, на мост не влияет, если §1 сошёлся.

   Правила (§4 CLAUDE.md): только SELECT, #A0f_*, MAXDOP 1, трёхчастные имена, IIN не
   выбирается, номера договоров — только внутри JOIN/COUNT. Имена — из §0 A0 и §2 A0d.
   ============================================================================= */

/* §1. ΔV на bwd: discounted_balance_debt против balance_with_discount.
   [свойство 01.10] Д-A0f-2 (Σ dp_abs_bound = 112 480,17 ₸) — число 01.10. На 01.09
   граница пересчитывается этим же разделом; в A13 E1 она вычисляется той же формулой.   */
DECLARE @AsOf date = '2026-09-01';

IF OBJECT_ID('tempdb..#A0f_new') IS NOT NULL DROP TABLE #A0f_new;
SELECT l.l_loan_number                                         AS contract_number,
       COUNT(*)                                                AS rows_n,
       SUM(CAST(la.discounted_balance_debt AS decimal(38,2)))  AS bwd_new,
       SUM(CAST(la.total_balance_debt      AS decimal(38,2)))  AS v_new
INTO #A0f_new
FROM [Dictionaries].[risk_analytics].[loan_account] la
JOIN [Dictionaries].[risk_analytics].[loans] l
  ON l.l_gid = la.la_gid AND l.l_source = la.la_source
WHERE la.la_source = 'S03' AND la.la_reporting_date = @AsOf
GROUP BY l.l_loan_number
OPTION (MAXDOP 1);

SELECT o.category,
       COUNT(*)                                                                 AS contracts,
       SUM(CASE WHEN n.bwd_new IS NULL THEN 1 ELSE 0 END)                       AS bwd_new_null,
       SUM(CAST(o.balance_with_discount AS decimal(38,2)))                      AS sum_bwd_old,
       SUM(n.bwd_new)                                                           AS sum_bwd_new,
       SUM(n.bwd_new - o.balance_with_discount)                                 AS dv_bwd,
       SUM(ABS(n.bwd_new - o.balance_with_discount))                            AS dv_abs_bwd,
       SUM(CASE WHEN ABS(n.bwd_new - o.balance_with_discount) <= 0.01
                THEN 1 ELSE 0 END)                                              AS match_001,
       SUM(ABS(n.bwd_new - o.balance_with_discount) * o.[percent] / 100)        AS dp_abs_bound,
       SUM(CASE WHEN ABS(n.bwd_new - n.v_new) <= 0.01 THEN 1 ELSE 0 END)        AS new_bwd_eq_v
FROM [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2] o
JOIN #A0f_new n ON n.contract_number = o.contract_number
WHERE o.[date] = @AsOf
GROUP BY o.category
ORDER BY o.category
OPTION (MAXDOP 1);

-- 1b. Бакеты |ΔV_bwd| — где сосредоточено расхождение, без идентификаторов.
SELECT b.bucket,
       COUNT(*)            AS contracts,
       SUM(b.dv)           AS dv_bwd,
       SUM(ABS(b.dv))      AS dv_abs_bwd,
       SUM(b.dp)           AS dp_abs_bound
FROM (SELECT n.bwd_new - o.balance_with_discount                          AS dv,
             ABS(n.bwd_new - o.balance_with_discount) * o.[percent] / 100 AS dp,
             CASE WHEN n.bwd_new IS NULL OR o.balance_with_discount IS NULL THEN '0 NULL'
                  WHEN ABS(n.bwd_new - o.balance_with_discount) <= 0.01      THEN '1 <= 0,01'
                  WHEN ABS(n.bwd_new - o.balance_with_discount) <= 1000      THEN '2 <= 1 тыс'
                  WHEN ABS(n.bwd_new - o.balance_with_discount) <= 100000    THEN '3 <= 100 тыс'
                  WHEN ABS(n.bwd_new - o.balance_with_discount) <= 10000000  THEN '4 <= 10 млн'
                  ELSE                                                            '5 > 10 млн' END AS bucket
      FROM [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2] o
      JOIN #A0f_new n ON n.contract_number = o.contract_number
      WHERE o.[date] = @AsOf) b
GROUP BY b.bucket
ORDER BY b.bucket
OPTION (MAXDOP 1);
GO

/* §2. Субсчета дисконта в старой базе — суммы по категориям.                       */
DECLARE @AsOf date = '2026-09-01';

SELECT category,
       SUM(CAST(balance - balance_with_discount AS decimal(38,2)))  AS sum_gap,
       SUM(CAST(ISNULL(DISCOUNT_14341,0) AS decimal(38,2)))         AS s_14341,
       SUM(CAST(ISNULL(DISCOUNT_14342,0) AS decimal(38,2)))         AS s_14342,
       SUM(CAST(ISNULL(DISCOUNT_17731,0) AS decimal(38,2)))         AS s_17731,
       SUM(CAST(ISNULL(DISCOUNT_17732,0) AS decimal(38,2)))         AS s_17732,
       SUM(CAST(ISNULL(fees_1860,0)      AS decimal(38,2)))         AS s_1860
FROM [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2]
WHERE [date] = @AsOf
GROUP BY category
ORDER BY category
OPTION (MAXDOP 1);
GO

IF OBJECT_ID('tempdb..#A0f_new') IS NOT NULL DROP TABLE #A0f_new;
