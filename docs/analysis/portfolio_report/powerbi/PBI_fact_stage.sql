/* =============================================================================
   PBI_fact_stage — таблица фактов STAGE 3 + 4 для Power BI.

   Зерно: месяц × источник × продукт (product_key как в PBI_fact_stock.sql).
   Месяц — срез 1-го числа − 1 месяц, как у запаса.

   Решение автора 28.09.2026 (DEFAULT_PLAN.md, ДФ-5): стадия — из CL_PORTFOLIO.
     S03 CrediLogic  CL_PORTFOLIO_2                     category   contract_number → loans.l_loan_number
     S02 карты       PORTFOLIO_CREDITCARDS_WAY4 /       category   contract_number → loans.l_loan_number
                     _MIGR_WAY4 / _SMART_CARD
     S01 RS          PORTFOLIO_RS                       Basket     contract_id     → loans.l_loan_id
     S17 Fenix       PORTFOLIO_Fenix                    Basket     contractnumber  → loan_account.la_dog_num
   Только стадия: деньги (total_balance_debt) и продукт — из витрины, по открытым
   счетам (la_status = 'Открыт'). Так списанные и закрытые, которые CL_PORTFOLIO
   ещё держит (у S03 — tag '11'), в Stage 3 + 4 не попадают: периметр тот же,
   что у остатка отчёта.

   Разведка STG_0 (28.09.2026):
     — все шесть таблиц имеют все 21 срез 01.2025 … 09.2026, строк = ключей:
       дублей нет. Карта может встретиться в двух карточных таблицах одного
       месяца (миграция) — схлопывается MAX(стадия);
     — формат стадии плавает: '1' → '1.00' у RS с 08.2025, '1.0' у WAY4 в
       05.2025, у S03 — numeric 1.0000. Приведение через decimal;
     — связь: весь ненулевой остаток S01, S03, S17 находит стадию; у S02 без
       стадии 33,6–104,5 млн ₸ на срез;
     — стадия 4 у S02 не встречается; у S17 в витрине её нет (корзина 3), в
       CL_PORTFOLIO — 12–33 счёта.

   Контроль (Н22), месяц 2026-07 (срез 01.08.2026) — повтор STG_0 блоков 4–5,
   stage3_balance + poci_balance, млн ₸: S03 105 479,8; S01 47 276,0;
   S17 3 770,3; S02 16,5.

   Сначала отбираются строки стадий 3 и 4 старой ветки (десятки тысяч на срез),
   потом — связь с витриной. Ветки UNION ALL в st помечены константой src:
   условие src = … в следующих звеньях отсекает лишние таблицы при компиляции. Ключи — сырые, без нормализации в JOIN
   (risk_dwh_reconciliation/CLAUDE.md). Имена колонок — из живого аудита STG_0
   (блок 0а). Режим ИМПОРТ, один оператор. Read-only. На выходе только агрегаты.
   ============================================================================= */
WITH st AS (        /* стадии 3 и 4 старой ветки: источник × срез × ключ */
    SELECT  'S03' AS src, x.[date] AS d
          , CONVERT(varchar(100), x.contract_number)                                     AS k
          , CAST(x.[category] AS int)                                                    AS stage
    FROM    [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2] AS x
    WHERE   x.[date] >= '20250101' AND DAY(x.[date]) = 1
      AND   x.[category] IN (3, 4)
    UNION ALL
    SELECT  'S01', x.actual_date
          , CONVERT(varchar(100), x.contract_id)
          , CAST(TRY_CAST(x.Basket AS decimal(9,4)) AS int)
    FROM    [CL_PORTFOLIO].[dbo].[PORTFOLIO_RS] AS x
    WHERE   x.actual_date >= '20250101' AND DAY(x.actual_date) = 1
      AND   TRY_CAST(x.Basket AS decimal(9,4)) IN (3, 4)
    UNION ALL
    SELECT  'S17', x.actual_date
          , CONVERT(varchar(100), x.contractnumber)
          , CAST(TRY_CAST(x.Basket AS decimal(9,4)) AS int)
    FROM    [CL_PORTFOLIO].[dbo].[PORTFOLIO_Fenix] AS x
    WHERE   x.actual_date >= '20250101' AND DAY(x.actual_date) = 1
      AND   TRY_CAST(x.Basket AS decimal(9,4)) IN (3, 4)
    UNION ALL
    SELECT  'S02', c.d, c.k, MAX(c.stage)
    FROM (
        SELECT x.[date] AS d, CONVERT(varchar(100), x.contract_number) AS k
             , CAST(TRY_CAST(x.[category] AS decimal(9,4)) AS int) AS stage
        FROM   [CL_PORTFOLIO].[dbo].[PORTFOLIO_CREDITCARDS_WAY4] AS x
        WHERE  x.[date] >= '20250101' AND DAY(x.[date]) = 1
          AND  TRY_CAST(x.[category] AS decimal(9,4)) IN (3, 4)
        UNION ALL
        SELECT x.[date], CONVERT(varchar(100), x.contract_number)
             , CAST(TRY_CAST(x.[category] AS decimal(9,4)) AS int)
        FROM   [CL_PORTFOLIO].[dbo].[PORTFOLIO_CREDITCARDS_MIGR_WAY4] AS x
        WHERE  x.[date] >= '20250101' AND DAY(x.[date]) = 1
          AND  TRY_CAST(x.[category] AS decimal(9,4)) IN (3, 4)
        UNION ALL
        SELECT x.[date], CONVERT(varchar(100), x.contract_number)
             , CAST(TRY_CAST(x.[category] AS decimal(9,4)) AS int)
        FROM   [CL_PORTFOLIO].[dbo].[PORTFOLIO_CREDITCARDS_SMART_CARD] AS x
        WHERE  x.[date] >= '20250101' AND DAY(x.[date]) = 1
          AND  TRY_CAST(x.[category] AS decimal(9,4)) IN (3, 4)
    ) AS c
    GROUP BY c.d, c.k
)
, gk AS (           /* ключ старой ветки → договор витрины. Две ветки вместо OR в ON:
                       с OR hash join невозможен, и 8 млн строк loans перебираются циклом */
    SELECT  st.src, st.d, st.stage, l.l_gid, l.l_source, l.l_segment, l.l_product_type, l.l_subproduct_type
    FROM    st
    JOIN    [Dictionaries].[risk_analytics].[loans] AS l
           ON  l.l_source      = st.src
           AND l.l_loan_number = st.k
    WHERE   st.src IN ('S02', 'S03')
    UNION ALL
    SELECT  st.src, st.d, st.stage, l.l_gid, l.l_source, l.l_segment, l.l_product_type, l.l_subproduct_type
    FROM    st
    JOIN    [Dictionaries].[risk_analytics].[loans] AS l
           ON  l.l_source  = 'S01'
           AND l.l_loan_id = CONVERT(nvarchar(100), st.k)
    WHERE   st.src = 'S01'
)
, a AS (            /* открытые счета витрины со стадией 3 / 4 на том же срезе */
    SELECT  gk.src, gk.d, gk.stage
          , CASE
                WHEN gk.l_source = 'S01' THEN N'S01|' + ISNULL(CONVERT(nvarchar(100), gk.l_segment), N'—')
                WHEN gk.l_source = 'S02' THEN N'S02|CARD'
                ELSE CONVERT(nvarchar(10), gk.l_source)
                     + N'|' + ISNULL(CONVERT(nvarchar(255), gk.l_product_type),    N'—')
                     + N'|' + ISNULL(CONVERT(nvarchar(255), gk.l_subproduct_type), N'—')
            END                                                                          AS product_key
          , CAST(ISNULL(la.total_balance_debt, 0) AS decimal(38,2))                      AS bal
    FROM    gk
    JOIN    [Dictionaries].[risk_analytics].[loan_account] AS la
           ON  la.la_gid            = gk.l_gid
           AND la.la_source         = gk.src
           AND la.la_reporting_date = gk.d
           AND la.la_status         = N'Открыт'
    UNION ALL
    SELECT  st.src, st.d, st.stage
          , ISNULL(CONVERT(nvarchar(10), l.l_source)
                   + N'|' + ISNULL(CONVERT(nvarchar(255), l.l_product_type),    N'—')
                   + N'|' + ISNULL(CONVERT(nvarchar(255), l.l_subproduct_type), N'—'),
                   N'S17|нет договора')
          , CAST(ISNULL(la.total_balance_debt, 0) AS decimal(38,2))
    FROM    st
    JOIN    [Dictionaries].[risk_analytics].[loan_account] AS la
           ON  la.la_dog_num        = CONVERT(nvarchar(100), st.k)
           AND la.la_source         = 'S17'
           AND la.la_reporting_date = st.d
           AND la.la_status         = N'Открыт'
    LEFT JOIN [Dictionaries].[risk_analytics].[loans] AS l
           ON  l.l_gid    = la.la_gid
           AND l.l_source = la.la_source
    WHERE   st.src = 'S17'
)
SELECT    DATEADD(month, -1, a.d)                                                        AS month_start
        , CONVERT(nvarchar(10), a.src)                                                   AS l_source
        , a.product_key
        , SUM(CASE WHEN a.stage = 3 THEN 1     ELSE 0 END)                               AS stage3_cnt
        , SUM(CASE WHEN a.stage = 3 THEN a.bal ELSE 0 END)                               AS stage3_balance
        , SUM(CASE WHEN a.stage = 4 THEN 1     ELSE 0 END)                               AS poci_cnt
        , SUM(CASE WHEN a.stage = 4 THEN a.bal ELSE 0 END)                               AS poci_balance
FROM      a
GROUP BY  DATEADD(month, -1, a.d), a.src, a.product_key
OPTION (MAXDOP 1);
