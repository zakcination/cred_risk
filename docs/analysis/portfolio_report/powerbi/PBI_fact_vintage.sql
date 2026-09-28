/* =============================================================================
   PBI_fact_vintage — таблица фактов ПОКОЛЕНИЙ для Power BI: накопленная доля
   договоров когорты выдач, вошедших в дефолт (и, как ранний сигнал, в просрочку)
   к возрасту k месяцев.

   Зерно: когорта × продукт × возраст k.

   Решения автора (DEFAULT_PLAN.md «Решения автора», VINTAGE_PLAN.md В-1…В-4,
   28.09.2026 — «по предложениям»):
     — единица — договор; когорта — месяц l_funding_date × product_key
       (ключ как в PBI_fact_flow.sql);
     — периметр — S01, S03, S17; S02 нет (дней по картам нет);
     — исход — НАКОПЛЕННЫЙ: «хоть раз в дефолте к возрасту k». Дефолт — то же
       правило, что в PBI_fact_default.sql: days_past_due_principal > 90 при
       la_account_1424 <> 0, на открытом счёте. Ранний сигнал — «хоть раз
       la_account_1424 <> 0»;
     — два веса: договоры и сумма выдачи (l_loan_amount);
     — шаг когорты — месяц; когорта меньше 300 договоров (месяц × продукт)
       сливается в квартал. Квартал собирает только малые месяцы: крупный месяц
       того же квартала остаётся своей когортой.

   Возраст k: срез 1-го числа месяца c + k для когорты месяца c. Договор,
   попавший на срез месяца выдачи (выдан 1-го числа), — возраст 1.

   Цензурирование (VINTAGE_PLAN.md §2):
     — слева: история loan_account с 01.2025, поэтому когорты с 12.2024;
     — справа: точка k строится, только если возраст k наблюдаем у САМОГО
       МОЛОДОГО месяца когорты (max_k). Дальше — строки нет, а не ноль;
     — договор без счёта на срезе (закрыт, списан, продан) остаётся в
       знаменателе; в числителе — только если дефолт был до выхода.
   Знаменатель — вся исходная когорта, включая досрочно погашенные.

   Контроль (Н22): Σ cohort_cnt по когортам = Σ issued_cnt из fact_flow по тем же
   месяцам и источникам S01, S03, S17 (фильтр «не договор» — строка в строку).

   ПРОИЗВОДИТЕЛЬНОСТЬ (редакция 28.09.2026 после прогона, который не дождались).
   Оба исхода требуют la_account_1424 <> 0, поэтому договоры когорт связываются
   только с просроченными строками loan_account, и первый дефолт / первая
   просрочка берутся одним MIN без агрегации по срезам. Накопление по возрасту —
   прямо в сетке «договор × наблюдаемый возраст» (~1,5 млн строк — дёшево).
   SQL Server не хранит CTE: каждое обращение — новый расчёт. Цепочка построена
   так, что связь с loan_account читается ровно один раз.

   Имена колонок — из живого аудита DEF_0 и фактов Power BI. Режим ИМПОРТ,
   один оператор. Read-only. На выходе только агрегаты.
   ============================================================================= */
WITH c AS (         /* договоры когорт: выданные, без «не договора» — как в PBI_fact_flow.sql */
    SELECT  l.l_gid
          , l.l_source
          , DATEFROMPARTS(YEAR(l.l_funding_date), MONTH(l.l_funding_date), 1)          AS cm
          , CAST(ISNULL(l.l_loan_amount, 0) AS decimal(38,2))                           AS amt
          , CASE
                WHEN l.l_source = 'S01' THEN N'S01|' + ISNULL(CONVERT(nvarchar(100), l.l_segment), N'—')
                ELSE CONVERT(nvarchar(10), l.l_source)
                     + N'|' + ISNULL(CONVERT(nvarchar(255), l.l_product_type),    N'—')
                     + N'|' + ISNULL(CONVERT(nvarchar(255), l.l_subproduct_type), N'—')
            END                                                                         AS product_key
    FROM    [Dictionaries].[risk_analytics].[loans] AS l
    WHERE   l.l_source IN ('S01', 'S03', 'S17')
      AND   NOT (l.l_source = 'S01' AND ISNULL(l.l_loan_status, '') = N'Ч')    /* CP1251 215 — не договор; NULL — «прочие», входит, как в fact_flow */
      AND   NOT (l.l_source = 'S03' AND ISNULL(l.l_loan_status, '') IN ('A', 'N'))   /* латиница — не договор */
      AND   l.l_funding_date >= '20241201'           /* когорты без наблюдаемого возраста 1 отпадут в сетке */
)
, f AS (            /* первый дефолт и первая просрочка. Оба исхода требуют 1424 <> 0 —
                       связь только с просроченными строками */
    SELECT  c.l_gid, c.l_source, c.cm, c.amt, c.product_key
          , MIN(CASE WHEN la.days_past_due_principal > 90 THEN la.la_reporting_date END) AS first_def
          , MIN(la.la_reporting_date)                                                   AS first_od
    FROM    c
    LEFT JOIN [Dictionaries].[risk_analytics].[loan_account] AS la
           ON  la.la_gid    = c.l_gid
           AND la.la_source = c.l_source
           AND la.la_status = N'Открыт'
           AND la.la_account_1424 <> 0
           AND la.la_reporting_date >= '20250101'
    GROUP BY c.l_gid, c.l_source, c.cm, c.amt, c.product_key
)
, f2 AS (           /* размер когорты месяц × продукт — окном, без второго обращения к f */
    SELECT  f.l_source, f.product_key, f.amt, f.cm, f.first_def, f.first_od
          , COUNT_BIG(*) OVER (PARTITION BY f.cm, f.product_key)                        AS n_month
    FROM    f
)
, f3 AS (
    SELECT  f2.l_source, f2.product_key, f2.amt, f2.cm
          , CASE WHEN f2.n_month < 300
                 THEN DATEFROMPARTS(YEAR(f2.cm), ((MONTH(f2.cm) - 1) / 3) * 3 + 1, 1)
                 ELSE f2.cm END                                                         AS cohort_start
          , CASE WHEN f2.n_month < 300 THEN N'квартал' ELSE N'месяц' END                AS cohort_type
          , CASE WHEN f2.first_def IS NULL THEN NULL
                 WHEN DATEDIFF(month, f2.cm, f2.first_def) < 1 THEN 1
                 ELSE DATEDIFF(month, f2.cm, f2.first_def) END                          AS k_def
          , CASE WHEN f2.first_od IS NULL THEN NULL
                 WHEN DATEDIFF(month, f2.cm, f2.first_od) < 1 THEN 1
                 ELSE DATEDIFF(month, f2.cm, f2.first_od) END                           AS k_od
          , DATEDIFF(month, f2.cm, x.last_slice)                                        AS age_obs
    FROM    f2
    CROSS JOIN (SELECT MAX(la_reporting_date) AS last_slice
                FROM   [Dictionaries].[risk_analytics].[loan_account]) AS x
)
, g AS (            /* договор × каждый наблюдаемый возраст; накопленный исход — сразу */
    SELECT  f3.l_source, f3.product_key, f3.cohort_start, f3.cohort_type, v.k
          , COUNT_BIG(*)                                                                AS obs_cnt
          , SUM(f3.amt)                                                                 AS obs_amt
          , MIN(f3.age_obs)                                                             AS min_age_obs
          , SUM(CASE WHEN f3.k_def <= v.k THEN 1      ELSE 0 END)                       AS ever_def_cnt
          , SUM(CASE WHEN f3.k_def <= v.k THEN f3.amt ELSE 0 END)                       AS ever_def_amount
          , SUM(CASE WHEN f3.k_od  <= v.k THEN 1      ELSE 0 END)                       AS ever_od_cnt
          , SUM(CASE WHEN f3.k_od  <= v.k THEN f3.amt ELSE 0 END)                       AS ever_od_amount
    FROM    f3
    JOIN   (VALUES (1),(2),(3),(4),(5),(6),(7),(8),(9),(10),(11),(12),
                   (13),(14),(15),(16),(17),(18),(19),(20),(21),(22),(23),(24)) AS v(k)
           ON v.k <= f3.age_obs
    GROUP BY f3.l_source, f3.product_key, f3.cohort_start, f3.cohort_type, v.k
)
, r AS (            /* размер когорты = наблюдённые на возрасте 1; max_k — по самому молодому месяцу */
    SELECT  g.l_source, g.product_key, g.cohort_start, g.cohort_type, g.k
          , g.ever_def_cnt, g.ever_def_amount, g.ever_od_cnt, g.ever_od_amount
          , MAX(g.obs_cnt)     OVER (PARTITION BY g.l_source, g.product_key, g.cohort_start, g.cohort_type) AS cohort_cnt
          , MAX(g.obs_amt)     OVER (PARTITION BY g.l_source, g.product_key, g.cohort_start, g.cohort_type) AS cohort_amount
          , MIN(g.min_age_obs) OVER (PARTITION BY g.l_source, g.product_key, g.cohort_start, g.cohort_type) AS max_k
    FROM    g
)
SELECT    r.cohort_start
        , r.cohort_type
        , CASE WHEN r.cohort_type = N'месяц'
               THEN CONVERT(nvarchar(7), r.cohort_start, 120)
               ELSE CONVERT(nvarchar(4), YEAR(r.cohort_start)) + N'-Q'
                    + CONVERT(nvarchar(1), (MONTH(r.cohort_start) + 2) / 3) END         AS cohort_label
        , r.l_source
        , r.product_key
        , r.k                                                                           AS age_k
        , r.max_k
        , r.cohort_cnt
        , r.cohort_amount
        , r.ever_def_cnt
        , r.ever_def_amount
        , r.ever_od_cnt
        , r.ever_od_amount
FROM      r
WHERE     r.k <= r.max_k                                       /* за наблюдаемым возрастом — строки нет, а не ноль */
OPTION (MAXDOP 1);
