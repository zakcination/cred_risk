/* =============================================================================
   PBI_fact_stock — таблица фактов ЗАПАСА и РИСКА для Power BI
                    (разделы 3, 4-1 ③, 5 и покрытие провизиями).

   Зерно: месяц × источник. Строка месяца M — срез loan_account на первое число
   месяца M+1, то есть запас на КОНЕЦ месяца M. Так запас включает выдачи месяца,
   и поток с запасом в одной строке отчёта сходятся (REPORT_STRUCTURE.md).

   Периметр — счета со статусом la_status = 'Открыт' на дату среза. Статус
   договора в loans для истории не годится: loans историзована на одну дату,
   а la_status — на каждую. Перенос статуса счёта на договор однозначен:
   DICT_D 24.09.2026, ни одного договора с двумя разными la_status.

   Как подключить — как PBI_fact_flow.sql: Импорт, Инструкция SQL, файл целиком.

   Заёмщиков с остатком — НЕ складываются между источниками: один человек в
   двух системах имеет два разных l_borrower_id. В модели мера показывает их
   только на уровне одного источника (см. POWERBI.md).

   Провизии: la_account_1428 + la_account_1845 + la_account_18771
   (risk_analytics_data_model.md). Просрочка — остаток счёта 1424, не дни:
   delinquency_bucket и days_past_due для этого непригодны (README контура).

   Read-only. На выходе только агрегаты.
   ============================================================================= */
WITH w AS (
    SELECT  MAX(l.l_report_date) AS snap
    FROM    [Dictionaries].[risk_analytics].[loans] AS l
)
, acc AS (
    SELECT  DATEADD(month, -1, la.la_reporting_date)                                   AS month_start
          , la.la_reporting_date                                                       AS snapshot_date
          , la.la_source                                                               AS l_source
          , la.la_gid
          , CAST(ISNULL(la.total_balance_debt, 0) AS decimal(38,2))                    AS bal
          , CAST(ISNULL(la.la_account_1424, 0)    AS decimal(38,2))                    AS od1424
          , CAST(ISNULL(la.la_account_1428, 0) + ISNULL(la.la_account_1845, 0)
               + ISNULL(la.la_account_18771, 0)   AS decimal(38,2))                    AS prov
    FROM    [Dictionaries].[risk_analytics].[loan_account] AS la
    CROSS JOIN w
    WHERE   la.la_status = N'Открыт'
      AND   DAY(la.la_reporting_date) = 1
      AND   la.la_reporting_date >  DATEADD(month, -24, w.snap)
      AND   la.la_reporting_date <= w.snap
)
SELECT    a.month_start
        , a.snapshot_date
        , a.l_source
        , COUNT_BIG(*)                                                                 AS accounts_open
        , COUNT(DISTINCT CASE WHEN a.bal <> 0 THEN a.la_gid END)                       AS contracts_with_balance
        , SUM(a.bal)                                                                   AS balance
        , SUM(a.od1424)                                                                AS overdue_principal
        , COUNT(DISTINCT CASE WHEN a.od1424 <> 0 THEN a.la_gid END)                    AS overdue_contracts
        , SUM(CASE WHEN a.od1424 <> 0 THEN a.bal ELSE 0 END)                           AS balance_of_overdue
        , SUM(a.prov)                                                                  AS provisions
        , COUNT(DISTINCT CASE WHEN a.bal <> 0 THEN l.l_borrower_id END)                AS borrowers_with_balance
FROM      acc AS a
LEFT JOIN [Dictionaries].[risk_analytics].[loans] AS l
       ON  l.l_gid    = a.la_gid
       AND l.l_source = a.l_source
GROUP BY  a.month_start, a.snapshot_date, a.l_source
OPTION (MAXDOP 1);
