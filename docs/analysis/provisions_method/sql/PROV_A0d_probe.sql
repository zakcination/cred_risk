/* =============================================================================
   PROV_A0d_probe.sql — Track A, шаг 0d. ПРЕДЛОЖЕНИЕ, запускать по решению Мираса.
   Повод — A0c §1 (12.10.2026): старая система умножает ставку на
   balance_with_discount (категория 1: 97,2 % строк), а V_new = total_balance_debt
   совпадает с balance. Для моста нужна bwd и в новой базе (TRACK_A_PLAN §11.7).

   Вопросы и критерии (до прогона):
   §1 Формула bwd в старой базе. Документ (SCHETA_DQ.md, из описания витрины):
        bwd = balance − (1434 + 1773 + 1774 + 1784) − (−1435 + 1775)
      Знак 1435 в данных не проверен (DQ-7). Проверяются три варианта; верный —
      тот, что сходится до 0,01 ₸ у ≥ 99 % строк. Ни один — вопрос ОПАиРоз.
   §2 Аудит колонок 17xx в loan_account (§0 A0 смотрел только 14xx/18xx).
   §3 ШАБЛОН ΔV на базе bwd — запускать после §1–§2, вписав подтверждённые имена.

   Правила (§4 CLAUDE.md): только SELECT, MAXDOP 1, трёхчастные имена, IIN не
   выбирается, номера договоров — только внутри JOIN/COUNT.
   ============================================================================= */

/* §1. Формула bwd в старой базе, по категориям.                                    */
DECLARE @AsOf date = '2026-10-01';

SELECT category,
       COUNT(*)                                                         AS rows_n,
       SUM(CAST(balance - balance_with_discount AS decimal(38,2)))      AS sum_gap,
       SUM(CAST(ISNULL(discount_1434,0) AS decimal(38,2)))              AS s_1434,
       SUM(CAST(ISNULL(discount_1435,0) AS decimal(38,2)))              AS s_1435,
       SUM(CAST(ISNULL(discount_1773,0) AS decimal(38,2)))              AS s_1773,
       SUM(CAST(ISNULL(discount_1774,0) AS decimal(38,2)))              AS s_1774,
       SUM(CAST(ISNULL(discount_1775,0) AS decimal(38,2)))              AS s_1775,
       SUM(CAST(ISNULL(discount_1784,0) AS decimal(38,2)))              AS s_1784,
       SUM(CAST(ISNULL(DISCOUNT_1484,0) AS decimal(38,2)))              AS s_1484,
       SUM(CAST(ISNULL(DISCOUNT_1485,0) AS decimal(38,2)))              AS s_1485,
       -- А: как в документе: gap = 1434+1773+1774+1784 − 1435 + 1775
       SUM(CASE WHEN ABS((balance - balance_with_discount)
             - (ISNULL(discount_1434,0) + ISNULL(discount_1773,0) + ISNULL(discount_1774,0)
                + ISNULL(discount_1784,0) - ISNULL(discount_1435,0) + ISNULL(discount_1775,0))) <= 0.01
                THEN 1 ELSE 0 END)                                      AS match_A_doc,
       -- Б: 1435 со знаком «+»
       SUM(CASE WHEN ABS((balance - balance_with_discount)
             - (ISNULL(discount_1434,0) + ISNULL(discount_1773,0) + ISNULL(discount_1774,0)
                + ISNULL(discount_1784,0) + ISNULL(discount_1435,0) + ISNULL(discount_1775,0))) <= 0.01
                THEN 1 ELSE 0 END)                                      AS match_B_1435_plus,
       -- В: только 14xx (1434 − 1435)
       SUM(CASE WHEN ABS((balance - balance_with_discount)
             - (ISNULL(discount_1434,0) - ISNULL(discount_1435,0))) <= 0.01
                THEN 1 ELSE 0 END)                                      AS match_C_14xx_only,
       SUM(CASE WHEN ABS(balance - balance_with_discount) <= 0.01
                THEN 1 ELSE 0 END)                                      AS rows_no_gap
FROM [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2]
WHERE [date] = @AsOf
GROUP BY category
ORDER BY category
OPTION (MAXDOP 1);
GO

/* §2. Аудит колонок 17xx и прочих счетов дисконта в loan_account.                   */
SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE, ORDINAL_POSITION
FROM [Dictionaries].INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'risk_analytics' AND TABLE_NAME = 'loan_account'
  AND (COLUMN_NAME LIKE 'la[_]account[_]17%' OR COLUMN_NAME LIKE '%disc%')
ORDER BY ORDINAL_POSITION;
GO

/* §3. ШАБЛОН, НЕ ЗАПУСКАТЬ до §1–§2. ΔV на базе bwd на общих договорах.
   <BWD_NEW> — выражение из подтверждённых §2 колонок по формуле, победившей в §1,
   например: la.total_balance_debt - (la.la_account_1434 + <17xx…>) + la.la_account_1435
DECLARE @AsOf date = '2026-10-01';
SELECT o.category,
       COUNT(*)                                                          AS contracts,
       SUM(CAST(o.balance_with_discount AS decimal(38,2)))               AS sum_bwd_old,
       SUM(n.bwd_new)                                                    AS sum_bwd_new,
       SUM(n.bwd_new - o.balance_with_discount)                          AS dv_bwd,
       SUM(ABS(n.bwd_new - o.balance_with_discount))                     AS dv_abs_bwd,
       SUM(ABS(n.bwd_new - o.balance_with_discount) * o.[percent] / 100) AS dp_abs_bound
FROM [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2] o
JOIN (SELECT l.l_loan_number AS contract_number, SUM(<BWD_NEW>) AS bwd_new
      FROM [Dictionaries].[risk_analytics].[loan_account] la
      JOIN [Dictionaries].[risk_analytics].[loans] l
        ON l.l_gid = la.la_gid AND l.l_source = la.la_source
      WHERE la.la_source = 'S03' AND la.la_reporting_date = @AsOf
      GROUP BY l.l_loan_number) n
  ON n.contract_number = o.contract_number
WHERE o.[date] = @AsOf
GROUP BY o.category
ORDER BY o.category
OPTION (MAXDOP 1);
*/
