/* =============================================================================
   STG_0 — разведка источника Stage 3 + 4 перед PBI_fact_stage.sql.

   РЕШЕНИЕ АВТОРА 28.09.2026 (DEFAULT_PLAN.md, ДФ-5). Стадия берётся из
   CL_PORTFOLIO: CrediLogic (S03) и карты (S02) — колонка category; Fenix (S17)
   и RS (S01) — колонка Basket. Контур впервые выходит за «только витрину» —
   поэтому шаги 0–4 порядка из risk_dwh_reconciliation/CLAUDE.md до любого факта:
   схема, покрытие срезов, grain, ключ по покрытию, выравнивание дат.

   Таблицы и ключи — из risk_dwh_reconciliation/FINDINGS.md §0–1, §2:
     S03  CL_PORTFOLIO_2                         contract_number → loans.l_loan_number
     S01  PORTFOLIO_RS                           contract_id     → loans.l_loan_id
     S17  PORTFOLIO_Fenix                        contractnumber  → loan_account.la_dog_num
     S02  PORTFOLIO_CREDITCARDS_WAY4 / _MIGR_WAY4 / _SMART_CARD
                                                 contract_number → loans.l_loan_number (97,96 %)
   Даты: month-start в обеих ветках, пары «месяц в месяц», лаг исключён (FINDINGS §2, §6).
   Имена колонок дат и стадии — из sql/stage3_cure_candidates.sql (прогонялся);
   блок 0 перепроверяет каждое.

   ЧТО СЧИТАЕТСЯ ОТВЕТОМ — фиксируется до прогона.
     блок 1 — у каждой таблицы есть month-start срезы на все месяцы окна
              01.2025 … 09.2026; дыра — месяц, где Stage 3 + 4 не строится.
     блок 2 — домен колонки стадии: какие значения, что из них «3» и «4».
     блок 3 — grain: строк больше, чем ключей на дату, — дубли; стадия
              дубля выбирается правилом, которое фиксирует автор.
     блок 4 — доля открытых счетов витрины, нашедших стадию: количество и
              остаток. Это потолок точности ряда Stage 3 + 4.
     блок 5 — КОНТРАРГУМЕНТ К РЕШЕНИЮ (§5). FINDINGS §S01, §S17: delinquency_bucket
              совпадает с Basket на 99,93 % и 99,98 %. Если совпадение держится
              и сейчас, стадия из CL_PORTFOLIO и корзина витрины — одно и то же
              число, и Р-9 закрыта не данными, а определением. Блок только
              измеряет: кросс-таблица корзина × стадия на связанных счетах.

   Правила контура сверки: трёхчастные имена, INFORMATION_SCHEMA — своей базы,
   ключ без нормализации (сырой = нормализованный, FINDINGS M), TRY_CAST на
   старых колонках — тип даты у них не гарантирован. Номера договоров не
   выводятся. GO между блоками. Read-only. MAXDOP 1.
   ============================================================================= */
SET NOCOUNT ON;
GO

/* ─────────────────────────────────────────────────────────────────────────
   0а. Схема старых таблиц: ключи, даты, стадия, остаток, признак списания.
       INFORMATION_SCHEMA — именно CL_PORTFOLIO: в чужой базе вернёт 0 строк
       без ошибки (risk_dwh_reconciliation/CLAUDE.md).
   ───────────────────────────────────────────────────────────────────────── */
SELECT    c.TABLE_NAME, c.COLUMN_NAME, c.DATA_TYPE
FROM      [CL_PORTFOLIO].INFORMATION_SCHEMA.COLUMNS AS c
WHERE     c.TABLE_SCHEMA = 'dbo'
  AND     c.TABLE_NAME IN (N'CL_PORTFOLIO_2', N'PORTFOLIO_RS', N'PORTFOLIO_Fenix',
                           N'PORTFOLIO_CREDITCARDS_WAY4', N'PORTFOLIO_CREDITCARDS_MIGR_WAY4',
                           N'PORTFOLIO_CREDITCARDS_SMART_CARD')
  AND   ( c.COLUMN_NAME IN (N'contract_number', N'contract_id', N'contractnumber',
                            N'date', N'actual_date', N'category', N'Basket', N'tag',
                            N'balance', N'Total_outstanding')
       OR c.COLUMN_NAME LIKE N'%stage%' OR c.COLUMN_NAME LIKE N'%poci%'
       OR c.COLUMN_NAME LIKE N'%basket%' OR c.COLUMN_NAME LIKE N'%categ%' )
ORDER BY  c.TABLE_NAME, c.ORDINAL_POSITION;
GO

/* ─────────────────────────────────────────────────────────────────────────
   0б. Ключи на стороне витрины. Ожидается 3 строки.
   ───────────────────────────────────────────────────────────────────────── */
SELECT    c.TABLE_NAME, c.COLUMN_NAME, c.DATA_TYPE
FROM      [Dictionaries].INFORMATION_SCHEMA.COLUMNS AS c
WHERE     c.TABLE_SCHEMA = 'risk_analytics'
  AND   ( (c.TABLE_NAME = N'loans'        AND c.COLUMN_NAME IN (N'l_loan_number', N'l_loan_id'))
       OR (c.TABLE_NAME = N'loan_account' AND c.COLUMN_NAME =  N'la_dog_num') )
ORDER BY  c.TABLE_NAME, c.COLUMN_NAME;
GO

/* ─────────────────────────────────────────────────────────────────────────
   1–3. Покрытие срезов, домен стадии, grain — одним проходом по каждой
        таблице. Только month-start даты окна. Строка = таблица × срез ×
        значение стадии.
   ───────────────────────────────────────────────────────────────────────── */
;WITH u AS (
    SELECT  N'S03 CL_PORTFOLIO_2' AS src
          , TRY_CAST(o.[date] AS date)                      AS d
          , CONVERT(nvarchar(100), o.contract_number)        AS k
          , CONVERT(nvarchar(100), o.[category])             AS stage
    FROM    [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2] AS o
    UNION ALL
    SELECT  N'S01 PORTFOLIO_RS', TRY_CAST(o.actual_date AS date),
            CONVERT(nvarchar(100), o.contract_id), CONVERT(nvarchar(100), o.Basket)
    FROM    [CL_PORTFOLIO].[dbo].[PORTFOLIO_RS] AS o
    UNION ALL
    SELECT  N'S17 PORTFOLIO_Fenix', TRY_CAST(o.actual_date AS date),
            CONVERT(nvarchar(100), o.contractnumber), CONVERT(nvarchar(100), o.Basket)
    FROM    [CL_PORTFOLIO].[dbo].[PORTFOLIO_Fenix] AS o
    UNION ALL
    SELECT  N'S02 WAY4', TRY_CAST(o.[date] AS date),
            CONVERT(nvarchar(100), o.contract_number), CONVERT(nvarchar(100), o.[category])
    FROM    [CL_PORTFOLIO].[dbo].[PORTFOLIO_CREDITCARDS_WAY4] AS o
    UNION ALL
    SELECT  N'S02 MIGR_WAY4', TRY_CAST(o.[date] AS date),
            CONVERT(nvarchar(100), o.contract_number), CONVERT(nvarchar(100), o.[category])
    FROM    [CL_PORTFOLIO].[dbo].[PORTFOLIO_CREDITCARDS_MIGR_WAY4] AS o
    UNION ALL
    SELECT  N'S02 SMART_CARD', TRY_CAST(o.[date] AS date),
            CONVERT(nvarchar(100), o.contract_number), CONVERT(nvarchar(100), o.[category])
    FROM    [CL_PORTFOLIO].[dbo].[PORTFOLIO_CREDITCARDS_SMART_CARD] AS o
)
, w AS (
    SELECT src, d, k, ISNULL(stage, N'NULL') AS stage_l
    FROM   u
    WHERE  d >= '2025-01-01' AND d <= '2026-09-01' AND DAY(d) = 1
)
SELECT    src
        , d
        , CASE WHEN GROUPING(stage_l) = 1 THEN N'ВСЕГО' ELSE stage_l END  AS stage
        , COUNT_BIG(*)                                      AS rows_cnt
        , COUNT(DISTINCT k)                                 AS keys_cnt     /* ВСЕГО: rows > keys — дубли */
FROM      w
GROUP BY  GROUPING SETS ((src, d, stage_l), (src, d))
ORDER BY  src, d, GROUPING(stage_l) DESC, stage_l
OPTION (MAXDOP 1);
GO

/* ─────────────────────────────────────────────────────────────────────────
   4–5. Связь с витриной на трёх срезах: открытые счета, сколько нашли
        стадию (по количеству и остатку), и корзина витрины × стадия.
        Дубли старой стороны схлопываются MAX(stage) — только для разведки;
        правило для факта — по результату блока 3.
   ───────────────────────────────────────────────────────────────────────── */
;WITH la AS (
    SELECT  a.la_source
          , a.la_reporting_date                                        AS d
          , CONVERT(nvarchar(100), a.la_dog_num)                        AS dog_num
          , CONVERT(nvarchar(100), l.l_loan_number)                     AS loan_number
          , CONVERT(nvarchar(100), l.l_loan_id)                         AS loan_id
          , ISNULL(CONVERT(nvarchar(10), a.delinquency_bucket), N'NULL') AS bucket
          , CAST(ISNULL(a.total_balance_debt, 0) AS decimal(38,2))     AS bal
    FROM    [Dictionaries].[risk_analytics].[loan_account] AS a
    LEFT JOIN [Dictionaries].[risk_analytics].[loans]      AS l
           ON l.l_gid = a.la_gid AND l.l_source = a.la_source
    WHERE   a.la_status = N'Открыт'
      AND   a.la_reporting_date IN ('2025-01-01', '2025-10-01', '2026-08-01')
)
, o AS (
    SELECT  N'S03' AS src, TRY_CAST(x.[date] AS date) AS d,
            CONVERT(nvarchar(100), x.contract_number) AS k, MAX(CONVERT(nvarchar(100), x.[category])) AS stage
    FROM    [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2] AS x
    WHERE   TRY_CAST(x.[date] AS date) IN ('2025-01-01', '2025-10-01', '2026-08-01')
    GROUP BY TRY_CAST(x.[date] AS date), CONVERT(nvarchar(100), x.contract_number)
    UNION ALL
    SELECT  N'S01', TRY_CAST(x.actual_date AS date),
            CONVERT(nvarchar(100), x.contract_id), MAX(CONVERT(nvarchar(100), x.Basket))
    FROM    [CL_PORTFOLIO].[dbo].[PORTFOLIO_RS] AS x
    WHERE   TRY_CAST(x.actual_date AS date) IN ('2025-01-01', '2025-10-01', '2026-08-01')
    GROUP BY TRY_CAST(x.actual_date AS date), CONVERT(nvarchar(100), x.contract_id)
    UNION ALL
    SELECT  N'S17', TRY_CAST(x.actual_date AS date),
            CONVERT(nvarchar(100), x.contractnumber), MAX(CONVERT(nvarchar(100), x.Basket))
    FROM    [CL_PORTFOLIO].[dbo].[PORTFOLIO_Fenix] AS x
    WHERE   TRY_CAST(x.actual_date AS date) IN ('2025-01-01', '2025-10-01', '2026-08-01')
    GROUP BY TRY_CAST(x.actual_date AS date), CONVERT(nvarchar(100), x.contractnumber)
    UNION ALL
    SELECT  N'S02', c.d, c.k, MAX(c.stage)
    FROM (
        SELECT TRY_CAST(x.[date] AS date) AS d, CONVERT(nvarchar(100), x.contract_number) AS k,
               CONVERT(nvarchar(100), x.[category]) AS stage
        FROM   [CL_PORTFOLIO].[dbo].[PORTFOLIO_CREDITCARDS_WAY4] AS x
        UNION ALL
        SELECT TRY_CAST(x.[date] AS date), CONVERT(nvarchar(100), x.contract_number),
               CONVERT(nvarchar(100), x.[category])
        FROM   [CL_PORTFOLIO].[dbo].[PORTFOLIO_CREDITCARDS_MIGR_WAY4] AS x
        UNION ALL
        SELECT TRY_CAST(x.[date] AS date), CONVERT(nvarchar(100), x.contract_number),
               CONVERT(nvarchar(100), x.[category])
        FROM   [CL_PORTFOLIO].[dbo].[PORTFOLIO_CREDITCARDS_SMART_CARD] AS x
    ) AS c
    WHERE   c.d IN ('2025-01-01', '2025-10-01', '2026-08-01')
    GROUP BY c.d, c.k
)
, j AS (
    SELECT  la.la_source, la.d, la.bucket, la.bal
          , o.stage
          , CASE WHEN o.k IS NULL THEN 0 ELSE 1 END                     AS matched
    FROM    la
    LEFT JOIN o
           ON  o.d   = la.d
           AND o.src = la.la_source
           AND o.k   = CASE la.la_source WHEN 'S03' THEN la.loan_number
                                         WHEN 'S02' THEN la.loan_number
                                         WHEN 'S01' THEN la.loan_id
                                         WHEN 'S17' THEN la.dog_num END
)
SELECT    la_source
        , d
        , bucket
        , ISNULL(stage, CASE WHEN matched = 1 THEN N'NULL' ELSE N'— не связан' END) AS stage
        , COUNT_BIG(*)                                                  AS accounts
        , CAST(SUM(bal) / 1000000 AS decimal(18,1))                     AS balance_mln
FROM      j
GROUP BY  la_source, d, bucket
        , ISNULL(stage, CASE WHEN matched = 1 THEN N'NULL' ELSE N'— не связан' END)
ORDER BY  la_source, d, bucket, stage
OPTION (MAXDOP 1);
GO
