/* =============================================================================
   RPT_G — три скачка, которые в Power BI выглядят как события портфеля,
           а могут быть артефактом. Проверка до того, как отчёт уйдёт читателю.

   Исходные наблюдения — PBI_fact_stock, PBI_fact_flow, PBI_0_preflight
   от 24.09.2026.

   ЧТО СЧИТАЕТСЯ ИСХОДОМ — фиксируется до прогона.

   блок 1 — Р-4. S17, декабрь 2025: 35 679 договоров закрыто (обычно 3–4 тыс.),
            просроченных договоров −31 549, провизии −11,0 млрд. Списаний у S17
            нет в принципе (cl_registry CL-S17-02). Если закрытые в декабре
            на начало месяца были в основном просрочены и их даты закрытия
            собраны на одном-двух днях — это НЕ погашение, а выбытие портфелем
            (продажа или иное), записанное статусом «Закрыт». Тогда раздел 2-3
            по S17 за декабрь показывает ~30 тыс. «досрочных погашений»,
            которых не было. Если доля просроченных как в октябре и ноябре,
            а даты размазаны — это обычные погашения, и гипотеза снята.

   блок 2 — Р-5. S03, июнь 2026: провизии −33,9 млрд при обычном сокращении
            остатка (выдачи прекращены с апреля) и почти неизменной просрочке.
            Считаются ВСЕ колонки счетов la_account_* на 01.06 и 01.07.2026.
            Если какая-то колонка выросла примерно на столько, на сколько упали
            1428 + 1845 + 18771 — провизии переехали на другой счёт, и формула
            покрытия в POWERBI.md их теряет. Если ни одна не выросла — это
            реальное высвобождение (пересчёт модели, смена методики), и в
            отчёте это событие, а не дефект.

   блок 3 — открытые счета без договора в loans, по источникам на последнюю
            дату. Объясняет единственный несошедшийся контроль: у S17 открытых
            счетов 82 815, а ожидалось 76 531 — по DICT_D, который шёл от loans
            к счетам и счетов без договора не видел. Ожидается ~6 284 на S17
            с почти нулевым остатком.

   ИМЕНА КОЛОНОК В БЛОКЕ 2 не пишутся руками: список la_account_* берётся из
   INFORMATION_SCHEMA и собирается в запрос динамически. Урок l_term:
   ни одного имени по памяти.

   GO между блоками. Read-only: только SELECT, в том числе внутри sp_executesql.
   Только агрегаты.
   ============================================================================= */
SET NOCOUNT ON;
GO

/* ─────────────────────────────────────────────────────────────────────────
   1. Р-4. Состав закрытий S17 по месяцам, сентябрь 2025 — февраль 2026:
      сколько на начало месяца закрытия имели открытый счёт с просрочкой
      по счёту 1424, и насколько собраны даты закрытия.
   ───────────────────────────────────────────────────────────────────────── */
;WITH cl AS (
    SELECT  l.l_gid
          , l.l_actual_closure_date                                                      AS d
          , DATEFROMPARTS(YEAR(l.l_actual_closure_date), MONTH(l.l_actual_closure_date), 1) AS m
          , DATEDIFF(month, l.l_actual_closure_date, l.l_scheduled_closure_date)        AS months_before_plan
    FROM    [Dictionaries].[risk_analytics].[loans] AS l
    WHERE   l.l_source = 'S17'
      AND   l.l_loan_status = N'З'                                     /* CP1251 199 */
      AND   l.l_actual_closure_date >= '2025-09-01'
      AND   l.l_actual_closure_date <  '2026-03-01'
)
, by_day AS (
    SELECT m, d, COUNT_BIG(*) AS n FROM cl GROUP BY m, d
)
, top_day AS (
    SELECT m, MAX(n) AS top_n, COUNT_BIG(*) AS days FROM by_day GROUP BY m
)
SELECT    c.m                                                                          AS close_month
        , COUNT_BIG(*)                                                                 AS closed
        , SUM(CASE WHEN la.la_gid IS NOT NULL THEN 1 ELSE 0 END)                       AS open_acc_at_month_start
        , SUM(CASE WHEN ISNULL(la.la_account_1424, 0) <> 0 THEN 1 ELSE 0 END)          AS overdue_at_month_start
        , SUM(CAST(ISNULL(la.total_balance_debt, 0) AS decimal(38,2)))                 AS balance_at_month_start
        , AVG(CAST(c.months_before_plan AS decimal(18,2)))                             AS avg_months_before_plan
        , MAX(t.days)                                                                  AS distinct_days
        , CAST(MAX(t.top_n) AS decimal(18,4)) / NULLIF(COUNT_BIG(*), 0)                AS top_day_share
FROM      cl AS c
JOIN      top_day AS t ON t.m = c.m
LEFT JOIN [Dictionaries].[risk_analytics].[loan_account] AS la
       ON  la.la_gid            = c.l_gid
       AND la.la_source         = 'S17'
       AND la.la_status         = N'Открыт'
       AND la.la_reporting_date = c.m
GROUP BY  c.m
ORDER BY  c.m
OPTION (MAXDOP 1);
GO

/* ─────────────────────────────────────────────────────────────────────────
   2. Р-5. Все счета la_account_* по S03 на 01.06 и 01.07.2026 —
      отдельно открытые и все статусы. Колонки собираются из
      INFORMATION_SCHEMA. Сортировка — по модулю изменения у открытых:
      сверху то, что сдвинулось сильнее всего.
   ───────────────────────────────────────────────────────────────────────── */
DECLARE @cols nvarchar(max), @vals nvarchar(max), @sql nvarchar(max);

SELECT @cols = STUFF((
    SELECT N', la.' + QUOTENAME(c.COLUMN_NAME)
    FROM   [Dictionaries].[INFORMATION_SCHEMA].[COLUMNS] AS c
    WHERE  c.TABLE_SCHEMA = 'risk_analytics'
      AND  c.TABLE_NAME   = N'loan_account'
      AND  c.COLUMN_NAME LIKE N'la[_]account[_]%'
      AND  c.DATA_TYPE IN ('float', 'real', 'decimal', 'numeric', 'money', 'int', 'bigint')
    ORDER BY c.ORDINAL_POSITION
    FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

SELECT @vals = STUFF((
    SELECT N', (N''' + c.COLUMN_NAME + N''', CAST(ISNULL(f.' + QUOTENAME(c.COLUMN_NAME) + N', 0) AS decimal(38,2)))'
    FROM   [Dictionaries].[INFORMATION_SCHEMA].[COLUMNS] AS c
    WHERE  c.TABLE_SCHEMA = 'risk_analytics'
      AND  c.TABLE_NAME   = N'loan_account'
      AND  c.COLUMN_NAME LIKE N'la[_]account[_]%'
      AND  c.DATA_TYPE IN ('float', 'real', 'decimal', 'numeric', 'money', 'int', 'bigint')
    ORDER BY c.ORDINAL_POSITION
    FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

SET @sql = N'
SELECT    v.acc
        , SUM(CASE WHEN f.la_reporting_date = ''2026-06-01'' AND f.la_status = N''Открыт'' THEN v.val ELSE 0 END) AS open_0601
        , SUM(CASE WHEN f.la_reporting_date = ''2026-07-01'' AND f.la_status = N''Открыт'' THEN v.val ELSE 0 END) AS open_0701
        , SUM(CASE WHEN f.la_reporting_date = ''2026-06-01'' THEN v.val ELSE 0 END)                             AS all_0601
        , SUM(CASE WHEN f.la_reporting_date = ''2026-07-01'' THEN v.val ELSE 0 END)                             AS all_0701
FROM    ( SELECT la.la_reporting_date, la.la_status, ' + @cols + N'
          FROM   [Dictionaries].[risk_analytics].[loan_account] AS la
          WHERE  la.la_source = ''S03''
            AND  la.la_reporting_date IN (''2026-06-01'', ''2026-07-01'') ) AS f
CROSS APPLY (VALUES ' + @vals + N') AS v(acc, val)
GROUP BY  v.acc
HAVING    SUM(ABS(v.val)) <> 0
ORDER BY  ABS(SUM(CASE WHEN f.la_reporting_date = ''2026-07-01'' AND f.la_status = N''Открыт'' THEN v.val ELSE 0 END)
            - SUM(CASE WHEN f.la_reporting_date = ''2026-06-01'' AND f.la_status = N''Открыт'' THEN v.val ELSE 0 END)) DESC
OPTION (MAXDOP 1);';

EXEC sys.sp_executesql @sql;
GO

/* ─────────────────────────────────────────────────────────────────────────
   3. Открытые счета без договора в loans — по источникам, последняя дата.
   ───────────────────────────────────────────────────────────────────────── */
SELECT    la.la_source
        , COUNT_BIG(*)                                                                 AS open_accounts_without_loan
        , SUM(CASE WHEN ISNULL(la.total_balance_debt, 0) <> 0 THEN 1 ELSE 0 END)       AS with_balance
        , SUM(CAST(ISNULL(la.total_balance_debt, 0) AS decimal(38,2)))                 AS balance
FROM      [Dictionaries].[risk_analytics].[loan_account] AS la
WHERE     la.la_reporting_date = (SELECT MAX(x.la_reporting_date)
                                  FROM [Dictionaries].[risk_analytics].[loan_account] AS x)
      AND la.la_status = N'Открыт'
      AND NOT EXISTS ( SELECT 1
                       FROM   [Dictionaries].[risk_analytics].[loans] AS l
                       WHERE  l.l_gid    = la.la_gid
                         AND  l.l_source = la.la_source )
GROUP BY  la.la_source
ORDER BY  la.la_source
OPTION (MAXDOP 1);
GO
