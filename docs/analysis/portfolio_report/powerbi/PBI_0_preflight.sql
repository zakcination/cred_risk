/* =============================================================================
   PBI_0_preflight — один раз перед подключением Power BI. В модель не идёт.

   ЗАЧЕМ. Итог банка, у которого в каком-то месяце молча пропал источник,
   выглядит как падение портфеля, и отличить одно от другого на графике нельзя.
   Этот скрипт показывает сетку «месяц × источник» ДО того, как цифры попадут
   в визуал.

   ЧТО СЧИТАЕТСЯ ИСХОДОМ.
     блок 1 — у каждого источника есть срез на первое число каждого месяца окна.
              Пустая клетка — в Power BI этот месяц у источника будет нулём,
              а итог банка — заниженным. Такой месяц помечается в отчёте.
     блок 2 — на каждом источнике открытые счета помечены именно 'Открыт'.
              Если у источника другое написание — PBI_fact_stock его потеряет
              целиком, и итог упадёт на весь его портфель.
     блок 3 — для витка 2: домен продуктовых полей. Иерархия «обеспеченный /
              необеспеченный → денежный / товарный → продукт» строится из них.

   GO между блоками: неверное имя стоит одного блока.
   Read-only. Только агрегаты.
   ============================================================================= */
SET NOCOUNT ON;
GO

/* 1. Сетка срезов: месяц × источник за 24 месяца. */
DECLARE @snap date = (SELECT MAX(l_report_date) FROM [Dictionaries].[risk_analytics].[loans]);

SELECT    la.la_reporting_date
        , la.la_source
        , COUNT_BIG(*)                                                              AS accounts_all
        , SUM(CASE WHEN la.la_status = N'Открыт' THEN 1 ELSE 0 END)                 AS accounts_open
        , SUM(CASE WHEN la.la_status = N'Открыт'
                   THEN CAST(ISNULL(la.total_balance_debt, 0) AS decimal(38,2))
                   ELSE 0 END)                                                      AS balance_open
FROM      [Dictionaries].[risk_analytics].[loan_account] AS la
WHERE     la.la_reporting_date >  DATEADD(month, -24, @snap)
      AND la.la_reporting_date <= @snap
GROUP BY  la.la_reporting_date, la.la_source
ORDER BY  la.la_reporting_date, la.la_source
OPTION (MAXDOP 1);
GO

/* 2. Домен la_status по источникам на последнюю дату. */
SELECT    la.la_source
        , la.la_status
        , COUNT_BIG(*)                                                              AS accounts
        , SUM(CAST(ISNULL(la.total_balance_debt, 0) AS decimal(38,2)))              AS balance
FROM      [Dictionaries].[risk_analytics].[loan_account] AS la
WHERE     la.la_reporting_date = (SELECT MAX(x.la_reporting_date)
                                  FROM [Dictionaries].[risk_analytics].[loan_account] AS x)
GROUP BY  la.la_source, la.la_status
ORDER BY  la.la_source, accounts DESC
OPTION (MAXDOP 1);
GO

/* 3. Для витка 2: продуктовые поля. На S03 — 4 × 8 значений, на S17 — по одному,
      на S01 и S02 — пусто (RPT_E). */
SELECT    l.l_source
        , l.l_product_type
        , l.l_subproduct_type
        , l.l_credit_object
        , COUNT_BIG(*)                                                              AS loans
        , SUM(CAST(ISNULL(l.l_loan_amount, 0) AS decimal(38,2)))                    AS amount
FROM      [Dictionaries].[risk_analytics].[loans] AS l
WHERE     l.l_source IN ('S03', 'S17')
GROUP BY  l.l_source, l.l_product_type, l.l_subproduct_type, l.l_credit_object
ORDER BY  l.l_source, loans DESC
OPTION (MAXDOP 1);
GO
