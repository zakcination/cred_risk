/* =============================================================================
   PBI_fact_flow — таблица фактов ПОТОКА для Power BI (разделы 2-1 и 2-3).

   Зерно: месяц × источник × продукт (product_key, виток 2). Окно: 24 полных
   месяца до даты снимка loans —
   12 на экран и ещё 12 для сравнения «год к году».

   Как подключить: Power BI → Получить данные → SQL Server → база Dictionaries
   → Дополнительные параметры → Инструкция SQL → вставить файл целиком.
   Режим ИМПОРТ. DirectQuery не поддерживается: CTE и OPTION он не принимает.

   Один оператор, без #temp и без GO — так требует Power BI.

   Определения — docs/analysis/portfolio_report/METRICS.md. Класс статуса —
   строка в строку по dict_registry/status_map.csv (Н18: порядок и состав веток
   не упрощать). Принятое по умолчанию и меняющееся одной строкой:
     — «не договор» (черновики, отказы, отмены) в выдачи не входит;
     — объём по S02 — установленные лимиты, отдельной колонкой: по картам
       l_loan_amount = l_limit в 99,9 % строк, выдачи в витрине нет;
     — по S02 — ещё число карт с лимитом > 0, card_limit_pos_cnt (К-1, вариант Б,
       решение автора 24.09.2026): 71–99 % выданных карт без лимита (RPT_H), и
       «выдано карт» без этой строки читается как выдача кредитных карт;
     — средняя сумма считается по договорам с ненулевой суммой;
     — S17 Т (смысл неизвестен) в погашения не входит, идёт своей колонкой;
     — доля досрочных считается только там, где есть плановая дата: у S02 её нет.

   Р-4 (RPT_G, 24.09.2026): у S17 в декабре 2025 «закрыто» 35 679 договоров, из
   них 86,2 % были просрочены на начало месяца (обычно 8–10 %), и 55 % закрыто
   одним днём. Это выбытие портфелем, записанное статусом «Закрыт», а не
   погашение. Статус его не отличает — поэтому закрытия делятся по признаку:
   был ли у договора на 1-е число месяца закрытия открытый счёт с просрочкой
   по 1424. Колонки closed_overdue_* — эта часть; «чистые» погашения = все
   минус она. Признак есть с 01.2025: раньше срезов loan_account нет, и
   закрытия 09–12.2024 все попадают в «чистые».

   product_key (виток 2): S03 и S17 — l_product_type|l_subproduct_type,
   S01 — l_segment (бизнес-линия), S02 — карты целиком. Расшифровка ключа —
   таблица dim_product в POWERBI.md.

   Read-only. На выходе только агрегаты — PII в модель Power BI не попадает.
   ============================================================================= */
WITH w AS (
    SELECT  MAX(l.l_report_date) AS snap
    FROM    [Dictionaries].[risk_analytics].[loans] AS l
)
, base AS (
    SELECT  l.l_gid
          , l.l_source
          , l.l_funding_date
          , l.l_actual_closure_date
          , l.l_scheduled_closure_date
          , CAST(ISNULL(l.l_loan_amount, 0) AS decimal(38,2))           AS amt
          , l.l_initial_term_months                                     AS term
          , CASE
                WHEN l.l_source = 'S01' THEN N'S01|' + ISNULL(CONVERT(nvarchar(100), l.l_segment), N'—')
                WHEN l.l_source = 'S02' THEN N'S02|CARD'
                ELSE CONVERT(nvarchar(10), l.l_source)
                     + N'|' + ISNULL(CONVERT(nvarchar(255), l.l_product_type),    N'—')
                     + N'|' + ISNULL(CONVERT(nvarchar(255), l.l_subproduct_type), N'—')
            END                                                         AS product_key
          , CASE
                WHEN l.l_source = 'S01' AND l.l_loan_status = N'З'  THEN N'закрыт'      /* CP1251 199 */
                WHEN l.l_source = 'S01' AND l.l_loan_status = N'Ч'  THEN N'не договор'  /* CP1251 215 */
                WHEN l.l_source = 'S02' AND l.l_loan_status IN ('Account Closed', 'Auto-Closed', N'Закрыт')
                                                                    THEN N'закрыт'
                WHEN l.l_source = 'S02' AND l.l_loan_status IN ('Account Decline', 'Account Decline SC')
                                                                    THEN N'не договор'
                WHEN l.l_source = 'S03' AND l.l_loan_status IN ('C', 'Z', 'Y')  THEN N'закрыт'      /* латиница */
                WHEN l.l_source = 'S03' AND l.l_loan_status IN ('A', 'N')       THEN N'не договор'
                WHEN l.l_source = 'S03' AND l.l_loan_status = 'I'               THEN N'списан'
                WHEN l.l_source = 'S03' AND l.l_loan_status = 'V'               THEN N'расторгнут'
                WHEN l.l_source = 'S17' AND l.l_loan_status = N'З'  THEN N'закрыт'      /* CP1251 199 */
                WHEN l.l_source = 'S17' AND l.l_loan_status = N'Т'  THEN N'S17 Т'       /* CP1251 210 */
                ELSE N'прочие'
            END                                                         AS cls
    FROM    [Dictionaries].[risk_analytics].[loans] AS l
)
, od AS (           /* открытые счета с просрочкой по 1424 на 1-е число месяца — для Р-4 */
    SELECT DISTINCT
            la.la_source
          , la.la_gid
          , la.la_reporting_date
    FROM    [Dictionaries].[risk_analytics].[loan_account] AS la
    CROSS JOIN w
    WHERE   la.la_status = N'Открыт'
      AND   ISNULL(la.la_account_1424, 0) <> 0
      AND   la.la_reporting_date >= DATEADD(month, -24, w.snap)
      AND   la.la_reporting_date <  w.snap
)
, iss AS (          /* 2-1: выдачи по месяцу l_funding_date */
    SELECT  DATEFROMPARTS(YEAR(b.l_funding_date), MONTH(b.l_funding_date), 1)                AS month_start
          , b.l_source
          , b.product_key
          , COUNT_BIG(*)                                                                      AS issued_cnt
          , SUM(CASE WHEN b.l_source <> 'S02' AND b.amt > 0 THEN 1 ELSE 0 END)                AS issued_cnt_amount_pos
          , SUM(CASE WHEN b.l_source <> 'S02' THEN b.amt ELSE 0 END)                          AS issued_amount
          , SUM(CASE WHEN b.l_source =  'S02' THEN b.amt ELSE 0 END)                          AS card_limit_amount
          , SUM(CASE WHEN b.l_source =  'S02' AND b.amt > 0 THEN 1 ELSE 0 END)                AS card_limit_pos_cnt
          , SUM(CASE WHEN b.term > 0 THEN CAST(b.term AS bigint) ELSE 0 END)                  AS term_sum
          , SUM(CASE WHEN b.term > 0 THEN 1 ELSE 0 END)                                       AS term_cnt
    FROM    base AS b
    CROSS JOIN w
    WHERE   b.cls <> N'не договор'
      AND   b.l_funding_date >= DATEADD(month, -24, w.snap)
      AND   b.l_funding_date <  w.snap
    GROUP BY DATEFROMPARTS(YEAR(b.l_funding_date), MONTH(b.l_funding_date), 1), b.l_source, b.product_key
)
, cl AS (           /* 2-3: закрытия по месяцу l_actual_closure_date */
    SELECT  DATEFROMPARTS(YEAR(b.l_actual_closure_date), MONTH(b.l_actual_closure_date), 1)  AS month_start
          , b.l_source
          , b.product_key
          , SUM(CASE WHEN b.cls = N'закрыт' THEN 1 ELSE 0 END)                                AS closed_cnt
          , SUM(CASE WHEN b.cls = N'закрыт' AND b.l_scheduled_closure_date IS NOT NULL
                     THEN 1 ELSE 0 END)                                                       AS closed_cnt_sched
          , SUM(CASE WHEN b.cls = N'закрыт' AND b.l_actual_closure_date < b.l_scheduled_closure_date
                     THEN 1 ELSE 0 END)                                                       AS closed_early_cnt
          , SUM(CASE WHEN b.cls = N'закрыт' AND b.l_actual_closure_date >= b.l_funding_date
                     THEN CAST(DATEDIFF(day, b.l_funding_date, b.l_actual_closure_date) AS bigint)
                     ELSE 0 END)                                                              AS closed_days_sum
          , SUM(CASE WHEN b.cls = N'закрыт' AND b.l_actual_closure_date >= b.l_funding_date
                     THEN 1 ELSE 0 END)                                                       AS closed_days_cnt
          , SUM(CASE WHEN b.cls = N'закрыт' AND o.la_gid IS NOT NULL THEN 1 ELSE 0 END)      AS closed_overdue_cnt
          , SUM(CASE WHEN b.cls = N'закрыт' AND o.la_gid IS NOT NULL
                          AND b.l_scheduled_closure_date IS NOT NULL THEN 1 ELSE 0 END)      AS closed_overdue_sched_cnt
          , SUM(CASE WHEN b.cls = N'закрыт' AND o.la_gid IS NOT NULL
                          AND b.l_actual_closure_date < b.l_scheduled_closure_date
                     THEN 1 ELSE 0 END)                                                       AS closed_overdue_early_cnt
          , SUM(CASE WHEN b.cls = N'закрыт' AND o.la_gid IS NOT NULL
                          AND b.l_actual_closure_date >= b.l_funding_date
                     THEN CAST(DATEDIFF(day, b.l_funding_date, b.l_actual_closure_date) AS bigint)
                     ELSE 0 END)                                                              AS closed_overdue_days_sum
          , SUM(CASE WHEN b.cls = N'закрыт' AND o.la_gid IS NOT NULL
                          AND b.l_actual_closure_date >= b.l_funding_date
                     THEN 1 ELSE 0 END)                                                       AS closed_overdue_days_cnt
          , SUM(CASE WHEN b.cls = N'S17 Т'      THEN 1 ELSE 0 END)                           AS closed_t_cnt
          , SUM(CASE WHEN b.cls = N'списан'     THEN 1 ELSE 0 END)                           AS writeoff_cnt
          , SUM(CASE WHEN b.cls = N'расторгнут' THEN 1 ELSE 0 END)                           AS terminated_cnt
    FROM    base AS b
    CROSS JOIN w
    LEFT JOIN od AS o
           ON  o.la_gid            = b.l_gid
           AND o.la_source         = b.l_source
           AND o.la_reporting_date = DATEFROMPARTS(YEAR(b.l_actual_closure_date), MONTH(b.l_actual_closure_date), 1)
    WHERE   b.l_actual_closure_date >= DATEADD(month, -24, w.snap)
      AND   b.l_actual_closure_date <  w.snap
    GROUP BY DATEFROMPARTS(YEAR(b.l_actual_closure_date), MONTH(b.l_actual_closure_date), 1), b.l_source, b.product_key
)
, k AS (
    SELECT month_start, l_source, product_key FROM iss
    UNION
    SELECT month_start, l_source, product_key FROM cl
)
SELECT    k.month_start
        , k.l_source
        , k.product_key
        , ISNULL(i.issued_cnt, 0)              AS issued_cnt
        , ISNULL(i.issued_cnt_amount_pos, 0)   AS issued_cnt_amount_pos
        , ISNULL(i.issued_amount, 0)           AS issued_amount
        , ISNULL(i.card_limit_amount, 0)       AS card_limit_amount
        , ISNULL(i.card_limit_pos_cnt, 0)      AS card_limit_pos_cnt
        , ISNULL(i.term_sum, 0)                AS term_sum
        , ISNULL(i.term_cnt, 0)                AS term_cnt
        , ISNULL(c.closed_cnt, 0)              AS closed_cnt
        , ISNULL(c.closed_cnt_sched, 0)        AS closed_cnt_sched
        , ISNULL(c.closed_early_cnt, 0)        AS closed_early_cnt
        , ISNULL(c.closed_days_sum, 0)         AS closed_days_sum
        , ISNULL(c.closed_days_cnt, 0)         AS closed_days_cnt
        , ISNULL(c.closed_overdue_cnt, 0)       AS closed_overdue_cnt
        , ISNULL(c.closed_overdue_sched_cnt, 0) AS closed_overdue_sched_cnt
        , ISNULL(c.closed_overdue_early_cnt, 0) AS closed_overdue_early_cnt
        , ISNULL(c.closed_overdue_days_sum, 0)  AS closed_overdue_days_sum
        , ISNULL(c.closed_overdue_days_cnt, 0)  AS closed_overdue_days_cnt
        , ISNULL(c.closed_t_cnt, 0)            AS closed_t_cnt
        , ISNULL(c.writeoff_cnt, 0)            AS writeoff_cnt
        , ISNULL(c.terminated_cnt, 0)          AS terminated_cnt
FROM      k
LEFT JOIN iss AS i ON i.month_start = k.month_start AND i.l_source = k.l_source AND i.product_key = k.product_key
LEFT JOIN cl  AS c ON c.month_start = k.month_start AND c.l_source = k.l_source AND c.product_key = k.product_key
OPTION (MAXDOP 1);
