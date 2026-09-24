/* =============================================================================
   PBI_fact_borrowers — заёмщики с остатком на уровне ИСТОЧНИКА (виток 2).

   Зачем отдельный факт. С витка 2 PBI_fact_stock имеет зерно «источник ×
   продукт», а заёмщики между продуктами не складываются: у одного человека
   бывает и POS, и зарплатный кредит. Сумма по продуктам завысит число людей.
   Здесь — число различных заёмщиков по источнику целиком.

   Между источниками по-прежнему не складывается: номер заёмщика системный.
   Итог банка — только через ИИН, это следующий шаг.

   Периметр и якорь месяца — как в PBI_fact_stock.sql. Импорт, один оператор.
   Read-only. На выходе только счётчики.
   ============================================================================= */
WITH w AS (
    SELECT  MAX(l.l_report_date) AS snap
    FROM    [Dictionaries].[risk_analytics].[loans] AS l
)
SELECT    DATEADD(month, -1, la.la_reporting_date)                                  AS month_start
        , la.la_source                                                              AS l_source
        , COUNT(DISTINCT l.l_borrower_id)                                           AS borrowers_with_balance
FROM      [Dictionaries].[risk_analytics].[loan_account] AS la
CROSS JOIN w
JOIN      [Dictionaries].[risk_analytics].[loans] AS l
       ON  l.l_gid    = la.la_gid
       AND l.l_source = la.la_source
WHERE     la.la_status = N'Открыт'
      AND ISNULL(la.total_balance_debt, 0) <> 0
      AND DAY(la.la_reporting_date) = 1
      AND la.la_reporting_date >  DATEADD(month, -24, w.snap)
      AND la.la_reporting_date <= w.snap
GROUP BY  DATEADD(month, -1, la.la_reporting_date), la.la_source
OPTION (MAXDOP 1);
