/* =============================================================================
   RPT_C — привести цифру витрины к сопоставимому виду и разложить остаток
           расхождения с результатами AQR.

   ЧТО ИЗМЕРЯЕМ. Задолженность и провизии портфеля на дату среза.
   Провизии — сумма счетов: 1428 + 1845 + 18771 (формула зарегистрирована
   в risk_analytics_data_model.md).

   В КАКОМ РАЗРЕЗЕ. Статус счёта la_status × источник; отдельно — портфель
   по карте статусов dict_registry/status_map.csv.

   ЧТО СЧИТАЕТСЯ ИСХОДОМ. Ряд по 21 дате среза. Если на дату, близкую
   к отчётной дате цикла AQR, витрина даёт величину порядка 1 719 млрд ₸
   задолженности и 185 млрд ₸ провизий — расхождение объясняется датой,
   и разлагать больше нечего. Если не даёт — остаток расхождения реален
   и разбирается блоками 1-3.

   ЗАЧЕМ. В RPT_A блок 3 сумма бралась по ВСЕМ счетам на дату, без фильтра
   по статусу: внутри были закрытые, расторгнутые, списанные и отказные.
   Полученные 1 523,5 млрд ₸ портфелем не являются. Ошибка исправляется здесь.

   Read-only.
   ============================================================================= */
SET NOCOUNT ON;

DECLARE @dt date = (SELECT MAX(la_reporting_date)
                    FROM [Dictionaries].[risk_analytics].[loan_account]);

/* ─────────────────────────────────────────────────────────────────────────
   1. Что лежит в сумме по статусам счёта.
      Показывает цену ошибки RPT_A: сколько попало не из портфеля.
   ───────────────────────────────────────────────────────────────────────── */
SELECT    la.la_source
        , la.la_status
        , COUNT_BIG(*)                                                       AS accounts
        , SUM(CAST(ISNULL(la.total_balance_debt,0) AS decimal(38,2)))        AS balance
        , SUM(CAST(ISNULL(la.la_account_1428,0) + ISNULL(la.la_account_1845,0)
                 + ISNULL(la.la_account_18771,0) AS decimal(38,2)))          AS provisions
        , SUM(CASE WHEN ISNULL(la.la_account_1424,0) <> 0 THEN 1 ELSE 0 END) AS overdue_acc
FROM      [Dictionaries].[risk_analytics].[loan_account] AS la
WHERE     la.la_reporting_date = @dt
GROUP BY  la.la_source, la.la_status
ORDER BY  la.la_source, balance DESC
OPTION (MAXDOP 1);

/* ─────────────────────────────────────────────────────────────────────────
   2. Портфель: только действующие договоры по карте статусов.
      Условие по источнику обязательно — латинская O (79) и кириллическая О
      (206) неразличимы на экране.
   ───────────────────────────────────────────────────────────────────────── */
SELECT    l.l_source
        , COUNT_BIG(*)                                                       AS accounts
        , SUM(CAST(ISNULL(la.total_balance_debt,0)     AS decimal(38,2)))    AS balance
        , SUM(CAST(ISNULL(la.principal_balance_debt,0) AS decimal(38,2)))    AS principal
        , SUM(CAST(ISNULL(la.la_account_1428,0) + ISNULL(la.la_account_1845,0)
                 + ISNULL(la.la_account_18771,0) AS decimal(38,2)))          AS provisions
        , SUM(CAST(ISNULL(la.la_account_1424,0) AS decimal(38,2)))           AS overdue_principal
        , SUM(CASE WHEN ISNULL(la.la_account_1424,0) <> 0 THEN 1 ELSE 0 END) AS overdue_acc
FROM      [Dictionaries].[risk_analytics].[loans] AS l
JOIN      [Dictionaries].[risk_analytics].[loan_account] AS la
       ON la.la_gid    = l.l_gid
      AND la.la_source = l.l_source
      AND la.la_reporting_date = @dt
WHERE   ( (l.l_source = 'S01' AND l.l_loan_status = N'О')
       OR (l.l_source = 'S02' AND l.l_loan_status = 'Account OK')
       OR (l.l_source = 'S03' AND l.l_loan_status = 'O')
       OR (l.l_source = 'S17' AND l.l_loan_status = N'О') )
  AND     l.l_actual_closure_date IS NULL
GROUP BY  l.l_source
ORDER BY  l.l_source
OPTION (MAXDOP 1);

/* ─────────────────────────────────────────────────────────────────────────
   3. Счета-сироты: есть счёт, договора в loans нет.
      Если сумма заметная — часть портфеля не размечается сегментацией
      вообще, потому что сегментация строится на полях loans и borrower.
   ───────────────────────────────────────────────────────────────────────── */
SELECT    la.la_source
        , COUNT_BIG(*)                                                       AS orphan_accounts
        , SUM(CAST(ISNULL(la.total_balance_debt,0) AS decimal(38,2)))        AS orphan_balance
        , SUM(CAST(ISNULL(la.la_account_1428,0) + ISNULL(la.la_account_1845,0)
                 + ISNULL(la.la_account_18771,0) AS decimal(38,2)))          AS orphan_provisions
FROM      [Dictionaries].[risk_analytics].[loan_account] AS la
LEFT JOIN [Dictionaries].[risk_analytics].[loans] AS l
       ON l.l_gid    = la.la_gid
      AND l.l_source = la.la_source
WHERE     la.la_reporting_date = @dt
  AND     l.l_gid IS NULL
GROUP BY  la.la_source
ORDER BY  la.la_source
OPTION (MAXDOP 1);

/* ─────────────────────────────────────────────────────────────────────────
   4. РЕШАЮЩИЙ БЛОК. Ряд по всем 21 дате среза.
      Отвечает, на какую дату витрина даёт величину порядка результатов AQR.
      Фильтр — только статус счёта: связь с loans здесь не нужна, а l_loan_status
      относится к единственному снимку 01.09.2026 и к прошлым датам неприменим.
   ───────────────────────────────────────────────────────────────────────── */
SELECT    la.la_reporting_date
        , COUNT_BIG(*)                                                       AS accounts
        , SUM(CAST(ISNULL(la.total_balance_debt,0) AS decimal(38,2)))        AS balance
        , SUM(CAST(ISNULL(la.la_account_1428,0) + ISNULL(la.la_account_1845,0)
                 + ISNULL(la.la_account_18771,0) AS decimal(38,2)))          AS provisions
        , CAST(100.0 * SUM(CAST(ISNULL(la.la_account_1428,0)
                             + ISNULL(la.la_account_1845,0)
                             + ISNULL(la.la_account_18771,0) AS decimal(38,2)))
             / NULLIF(SUM(CAST(ISNULL(la.total_balance_debt,0)
                               AS decimal(38,2))), 0) AS decimal(9,4))       AS coverage_pct
FROM      [Dictionaries].[risk_analytics].[loan_account] AS la
WHERE     ISNULL(la.la_status, N'') = N'Открыт'
GROUP BY  la.la_reporting_date
ORDER BY  la.la_reporting_date
OPTION (MAXDOP 1);

/* Как читать блок 4.
   Витрина на 01.09.2026 дала покрытие 7,44 % при 113,3 млрд ₸ провизий.
   Результаты AQR: 185,2 млрд ₸ провизий до корректировки и 210,6 млрд после,
   покрытие 10,78 % и 12,25 % при задолженности 1 718,8 млрд ₸.
   Если ряд подходит к этим величинам на какой-то из 21 даты — расхождение
   объясняется датой. Если ряд ровный и нигде к ним не подходит — причина
   в периметре: в AQR входят ОУСА (9,1 млрд задолженности при 9,1 млрд
   провизий), гарантии и условные обязательства, которых в loan_account нет. */
