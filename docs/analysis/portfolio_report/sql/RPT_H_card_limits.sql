/* =============================================================================
   RPT_H — Р-8: почему средний лимит на новую карту S02 упал в 80 раз.

   НАБЛЮДЕНИЕ (Power BI, страница 1, 24.09.2026). «Лимиты по картам» ÷
   «Количество выдач» по месяцу выдачи: 103 тыс. ₸ (09.2025), 60–97 тыс.
   (10.2025–02.2026), 12–36 тыс. (03–07.2026), 1,2 тыс. (08.2026).
   Лимит — l_loan_amount S02 (совпадает с l_limit в 99,9 %, RPT_D), взятый
   из loans — ОДНОГО снимка на 01.09.2026. Это текущий лимит, а не лимит
   при выдаче.

   ЕДИНИЦА — карта (договор S02). Периметр — как в fact_flow: выдачи по
   месяцу l_funding_date за 24 месяца до снимка, без отказных (Account
   Decline, Account Decline SC). Исход — лимит на снимке: 0 или > 0.

   КОНКУРИРУЮЩИЕ ОБЪЯСНЕНИЯ И ЧТО ИХ РАЗЛИЧАЕТ — фиксируется до прогона.
   Средний лимит на карту = доля карт с лимитом > 0 × средний лимит среди них.
   Блок 1 раскладывает падение на эти два множителя.

     (а) лаг установки лимита — новым картам лимит ставится позже выдачи.
         Доля нулевых высока только в последних 1–3 месяцах и убывает
         с возрастом карты; средний лимит среди > 0 ровный; нулевые карты
         не имели остатка ни на одном срезе (блок 2).
     (б) смена продукта — с месяца X карты выдаются без кредитного лимита.
         Доля нулевых скачком растёт в X и дальше ровная, а не убывает
         с возрастом; средний лимит среди > 0 ровный; нулевые без остатка.
     (в) обнуление — лимит снимается при закрытии или блокировке. Нулевые
         сосредоточены в статусах «закрыт» и «прочие», у действующих карт
         доля нулевых близка к нулю; нулевые карты ИМЕЛИ остаток (блок 2).
     (г) снижение лимитов — доля нулевых ровная, падает средний лимит
         среди > 0.

   Объяснения не исключают друг друга. Ведущим считается множитель, чьё
   отношение 08.2026 к 09.2025 дальше от 1 (блок 1, итоговая строка).

   САМОПРОВЕРКА (Н22 nst_credit, известный ответ). Блок 1 обязан повторить
   Power BI: карт 760 и лимитов 78,6 млн ₸ в 09.2025; 228 и 0,28 млн в
   08.2026. Не повторил — периметр разошёлся с fact_flow, дальше не читать.

   ОГОВОРКА К БЛОКУ 2. С февраля 2026 у S02 в loan_account выпали счета без
   остатка (CL-S02-03, cl_registry): 185 тыс. → 31 тыс. Поэтому «есть счёт»
   по S02 не измеряется, а «был остаток хоть на одном срезе» — измеряется:
   счета с остатком не выпадали.

   Имена колонок — из прогнанных RPT_D, RPT_F, RPT_G и фактов Power BI;
   блок 0 перепроверяет их и ищет в витрине историю лимита. GO между
   блоками. Read-only. Только агрегаты.
   ============================================================================= */
SET NOCOUNT ON;
GO

/* ─────────────────────────────────────────────────────────────────────────
   0а. Живой аудит: колонки, на которых стоит скрипт. Ожидается 13 строк.
       Меньше — блок, использующий пропавшее имя, упадёт; его и чинить.
   ───────────────────────────────────────────────────────────────────────── */
SELECT    c.TABLE_NAME, c.COLUMN_NAME, c.DATA_TYPE
FROM      [Dictionaries].[INFORMATION_SCHEMA].[COLUMNS] AS c
WHERE     c.TABLE_SCHEMA = 'risk_analytics'
  AND   ( (c.TABLE_NAME = N'loans'        AND c.COLUMN_NAME IN (N'l_gid', N'l_source', N'l_funding_date',
                                                                N'l_loan_amount', N'l_limit', N'l_loan_status',
                                                                N'l_actual_closure_date', N'l_report_date'))
       OR (c.TABLE_NAME = N'loan_account' AND c.COLUMN_NAME IN (N'la_gid', N'la_source', N'la_reporting_date',
                                                                N'la_status', N'total_balance_debt')) )
ORDER BY  c.TABLE_NAME, c.ORDINAL_POSITION;
GO

/* ─────────────────────────────────────────────────────────────────────────
   0б. Есть ли в витрине ИСТОРИЯ лимита. Кандидаты по имени: всё, где есть
       limit / lim / лимит, и внебалансовые счета класса 6 (условные
       обязательства — туда по плану счетов ложится неиспользованный лимит).
       По каждому числовому кандидату loan_account — S02 на последнем срезе:
       сколько ненулевых и сумма. Колонки собираются из INFORMATION_SCHEMA
       динамически, руками не пишутся.
       Нашлась колонка с ненулевыми значениями у S02 — появляется прямая
       проверка (а): лимит карты на срезе месяца выдачи против снимка.
       Это отдельный следующий шаг, здесь только поиск.
   ───────────────────────────────────────────────────────────────────────── */
SELECT    c.TABLE_NAME, c.COLUMN_NAME, c.DATA_TYPE
FROM      [Dictionaries].[INFORMATION_SCHEMA].[COLUMNS] AS c
WHERE     c.TABLE_SCHEMA = 'risk_analytics'
  AND     c.TABLE_NAME IN (N'loans', N'loan_account', N'borrower')
  AND   ( c.COLUMN_NAME LIKE N'%limit%' OR c.COLUMN_NAME LIKE N'%lim[_]%'
       OR c.COLUMN_NAME LIKE N'%лимит%' OR c.COLUMN_NAME LIKE N'la[_]account[_]6%' )
ORDER BY  c.TABLE_NAME, c.ORDINAL_POSITION;

DECLARE @cols nvarchar(max), @vals nvarchar(max), @sql nvarchar(max);

SELECT @cols = STUFF((
    SELECT N', la.' + QUOTENAME(c.COLUMN_NAME)
    FROM   [Dictionaries].[INFORMATION_SCHEMA].[COLUMNS] AS c
    WHERE  c.TABLE_SCHEMA = 'risk_analytics'
      AND  c.TABLE_NAME   = N'loan_account'
      AND  c.DATA_TYPE IN ('float', 'real', 'decimal', 'numeric', 'money', 'int', 'bigint')
      AND ( c.COLUMN_NAME LIKE N'%limit%' OR c.COLUMN_NAME LIKE N'%lim[_]%'
         OR c.COLUMN_NAME LIKE N'%лимит%' OR c.COLUMN_NAME LIKE N'la[_]account[_]6%' )
    ORDER BY c.ORDINAL_POSITION
    FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

SELECT @vals = STUFF((
    SELECT N', (N''' + c.COLUMN_NAME + N''', CAST(s.' + QUOTENAME(c.COLUMN_NAME) + N' AS decimal(38,2)))'
    FROM   [Dictionaries].[INFORMATION_SCHEMA].[COLUMNS] AS c
    WHERE  c.TABLE_SCHEMA = 'risk_analytics'
      AND  c.TABLE_NAME   = N'loan_account'
      AND  c.DATA_TYPE IN ('float', 'real', 'decimal', 'numeric', 'money', 'int', 'bigint')
      AND ( c.COLUMN_NAME LIKE N'%limit%' OR c.COLUMN_NAME LIKE N'%lim[_]%'
         OR c.COLUMN_NAME LIKE N'%лимит%' OR c.COLUMN_NAME LIKE N'la[_]account[_]6%' )
    ORDER BY c.ORDINAL_POSITION
    FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

IF @vals IS NULL
    SELECT N'кандидатов в loan_account нет — истории лимита в витрине нет, (а) проверяется только блоками 1–2' AS note;
ELSE
BEGIN
    SET @sql = N'
    SELECT    v.col
            , COUNT_BIG(*)                                          AS s02_rows
            , SUM(CASE WHEN ISNULL(v.val, 0) <> 0 THEN 1 ELSE 0 END) AS nonzero_rows
            , SUM(ISNULL(v.val, 0))                                 AS total
    FROM (
        SELECT ' + @cols + N'
        FROM   [Dictionaries].[risk_analytics].[loan_account] AS la
        WHERE  la.la_source = ''S02''
          AND  la.la_reporting_date = (SELECT MAX(x.la_reporting_date)
                                       FROM [Dictionaries].[risk_analytics].[loan_account] AS x)
    ) AS s
    CROSS APPLY (VALUES ' + @vals + N') AS v(col, val)
    GROUP BY  v.col
    ORDER BY  v.col
    OPTION (MAXDOP 1);';
    EXEC sys.sp_executesql @sql;
END
GO

/* ─────────────────────────────────────────────────────────────────────────
   1. Разложение по месяцу выдачи: доля карт с лимитом > 0 и средний лимит
      среди них; нулевые — по статусу карты на снимке; распределение
      ненулевых лимитов корзинами. Последняя строка — отношения
      08.2026 к 09.2025 для правила «ведущий множитель».
   ───────────────────────────────────────────────────────────────────────── */
DECLARE @snap date = (SELECT MAX(l_report_date) FROM [Dictionaries].[risk_analytics].[loans]);

;WITH c AS (
    SELECT  DATEFROMPARTS(YEAR(l.l_funding_date), MONTH(l.l_funding_date), 1)          AS m
          , CAST(ISNULL(l.l_loan_amount, 0) AS decimal(38,2))                           AS lim
          , CASE
                WHEN l.l_loan_status IN ('Account OK', N'Активен')                        THEN N'действующий'
                WHEN l.l_loan_status IN ('Account Closed', N'Закрыт', 'Auto-Closed')      THEN N'закрыт'
                ELSE N'прочие'
            END                                                                         AS st
    FROM    [Dictionaries].[risk_analytics].[loans] AS l
    WHERE   l.l_source = 'S02'
      AND   ISNULL(l.l_loan_status, N'') NOT IN ('Account Decline', 'Account Decline SC')   /* NULL — «прочие», как в fact_flow */
      AND   l.l_funding_date >= DATEADD(month, -24, @snap)
      AND   l.l_funding_date <  @snap
)
, agg AS (
    SELECT  m
          , COUNT_BIG(*)                                                   AS cards
          , CAST(SUM(lim) / 1000000 AS decimal(18,2))                      AS limit_mln
          , SUM(CASE WHEN lim > 0 THEN 1 ELSE 0 END)                       AS limit_pos
          , CAST(SUM(CASE WHEN lim > 0 THEN 1.0 ELSE 0 END) / COUNT_BIG(*) AS decimal(6,4)) AS share_pos
          , CAST(SUM(lim) / NULLIF(SUM(CASE WHEN lim > 0 THEN 1 ELSE 0 END), 0)
                 AS decimal(18,0))                                         AS avg_pos
          , CAST(SUM(lim) / COUNT_BIG(*) AS decimal(18,0))                 AS avg_per_card
          , SUM(CASE WHEN st = N'действующий' THEN 1 ELSE 0 END)           AS active
          , SUM(CASE WHEN st = N'действующий' AND lim = 0 THEN 1 ELSE 0 END) AS active_zero
          , SUM(CASE WHEN st = N'закрыт' THEN 1 ELSE 0 END)                AS closed
          , SUM(CASE WHEN st = N'закрыт' AND lim = 0 THEN 1 ELSE 0 END)    AS closed_zero
          , SUM(CASE WHEN st = N'прочие' THEN 1 ELSE 0 END)                AS other
          , SUM(CASE WHEN st = N'прочие' AND lim = 0 THEN 1 ELSE 0 END)    AS other_zero
          , SUM(CASE WHEN lim > 0       AND lim <=  100000 THEN 1 ELSE 0 END) AS pos_le_100k
          , SUM(CASE WHEN lim >  100000 AND lim <=  300000 THEN 1 ELSE 0 END) AS pos_100k_300k
          , SUM(CASE WHEN lim >  300000 AND lim <= 1000000 THEN 1 ELSE 0 END) AS pos_300k_1m
          , SUM(CASE WHEN lim > 1000000                    THEN 1 ELSE 0 END) AS pos_gt_1m
    FROM    c
    GROUP BY m
)
SELECT    CONVERT(nvarchar(10), m, 120) AS month_issued
        , cards, limit_mln, limit_pos, share_pos, avg_pos, avg_per_card
        , active, active_zero, closed, closed_zero, other, other_zero
        , pos_le_100k, pos_100k_300k, pos_300k_1m, pos_gt_1m
FROM      agg
UNION ALL
SELECT    N'отн 08/09'
        , NULL, NULL, NULL
        , CAST(a.share_pos    / NULLIF(b.share_pos,    0) AS decimal(10,4))
        , CAST(a.avg_pos      / NULLIF(b.avg_pos,      0) AS decimal(18,4))
        , CAST(a.avg_per_card / NULLIF(b.avg_per_card, 0) AS decimal(18,4))
        , NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
FROM      agg AS a
JOIN      agg AS b ON b.m = '2025-09-01'
WHERE     a.m = '2026-08-01'
ORDER BY  month_issued
OPTION (MAXDOP 1);
GO

/* ─────────────────────────────────────────────────────────────────────────
   2. Пользовались ли картами с нулевым лимитом: был ли остаток хоть на
      одном срезе loan_account. Разрез — месяц выдачи × лимит 0 / > 0.
      Нулевые с остатком — довод за (в): лимит был и снят. Нулевые без
      остатка при тех же долях у > 0 — довод за (а) или (б).
      Сравнивать with_balance_share нулевых с тем же у > 0 одного месяца,
      а не абсолют: свежим картам остаток набрать некогда.
   ───────────────────────────────────────────────────────────────────────── */
DECLARE @snap2 date = (SELECT MAX(l_report_date) FROM [Dictionaries].[risk_analytics].[loans]);

;WITH c AS (
    SELECT  l.l_gid
          , DATEFROMPARTS(YEAR(l.l_funding_date), MONTH(l.l_funding_date), 1)          AS m
          , CASE WHEN ISNULL(l.l_loan_amount, 0) > 0 THEN N'> 0' ELSE N'0' END          AS lim_cls
    FROM    [Dictionaries].[risk_analytics].[loans] AS l
    WHERE   l.l_source = 'S02'
      AND   ISNULL(l.l_loan_status, N'') NOT IN ('Account Decline', 'Account Decline SC')   /* NULL — «прочие», как в fact_flow */
      AND   l.l_funding_date >= DATEADD(month, -24, @snap2)
      AND   l.l_funding_date <  @snap2
)
, used AS (
    SELECT  DISTINCT la.la_gid
    FROM    [Dictionaries].[risk_analytics].[loan_account] AS la
    WHERE   la.la_source = 'S02'
      AND   ISNULL(la.total_balance_debt, 0) <> 0
)
SELECT    CONVERT(nvarchar(10), c.m, 120)                                         AS month_issued
        , c.lim_cls
        , COUNT_BIG(*)                                                            AS cards
        , SUM(CASE WHEN u.la_gid IS NOT NULL THEN 1 ELSE 0 END)                   AS with_balance
        , CAST(SUM(CASE WHEN u.la_gid IS NOT NULL THEN 1.0 ELSE 0 END)
               / COUNT_BIG(*) AS decimal(6,4))                                    AS with_balance_share
FROM      c
LEFT JOIN used AS u ON u.la_gid = c.l_gid
GROUP BY  c.m, c.lim_cls
ORDER BY  c.m, c.lim_cls
OPTION (MAXDOP 1);
GO
