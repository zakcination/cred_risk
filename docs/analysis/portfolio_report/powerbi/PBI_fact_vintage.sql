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

   Имена колонок — из живого аудита DEF_0 и фактов Power BI. Режим ИМПОРТ,
   один оператор. Read-only. На выходе только агрегаты.
   ============================================================================= */
WITH w AS (
    SELECT  MAX(la_reporting_date) AS last_slice
    FROM    [Dictionaries].[risk_analytics].[loan_account]
)
, c AS (            /* договоры когорт: выданные, без «не договора» — как в PBI_fact_flow.sql */
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
    CROSS JOIN w
    WHERE   l.l_source IN ('S01', 'S03', 'S17')
      AND   NOT (l.l_source = 'S01' AND ISNULL(l.l_loan_status, '') = N'Ч')    /* CP1251 215 — не договор; NULL — «прочие», входит, как в fact_flow */
      AND   NOT (l.l_source = 'S03' AND ISNULL(l.l_loan_status, '') IN ('A', 'N'))   /* латиница — не договор */
      AND   l.l_funding_date >= '20241201'
      AND   l.l_funding_date <  w.last_slice                                    /* у когорты есть возраст 1: срез месяца c + 1 */
)
, s AS (            /* состояние на срезе: дефолт по правилу и просрочка */
    SELECT  la.la_source
          , la.la_gid
          , la.la_reporting_date                                                        AS d
          , MAX(CASE WHEN ISNULL(la.la_account_1424, 0) <> 0
                      AND la.days_past_due_principal > 90 THEN 1 ELSE 0 END)           AS dflt
          , MAX(CASE WHEN ISNULL(la.la_account_1424, 0) <> 0 THEN 1 ELSE 0 END)         AS od
    FROM    [Dictionaries].[risk_analytics].[loan_account] AS la
    WHERE   la.la_status = N'Открыт'
      AND   la.la_source IN ('S01', 'S03', 'S17')
      AND   la.la_reporting_date >= '20250101'
    GROUP BY la.la_source, la.la_gid, la.la_reporting_date
)
, f AS (            /* первый дефолт и первая просрочка договора */
    SELECT  c.l_gid, c.l_source, c.cm, c.amt, c.product_key
          , MIN(CASE WHEN s.dflt = 1 THEN s.d END)                                      AS first_def
          , MIN(CASE WHEN s.od   = 1 THEN s.d END)                                      AS first_od
    FROM    c
    LEFT JOIN s
           ON  s.la_gid    = c.l_gid
           AND s.la_source = c.l_source
    GROUP BY c.l_gid, c.l_source, c.cm, c.amt, c.product_key
)
, sz AS (           /* размер когорты месяц × продукт — для слияния в квартал */
    SELECT  cm, product_key, COUNT_BIG(*) AS n
    FROM    f
    GROUP BY cm, product_key
)
, f2 AS (
    SELECT  f.l_source, f.product_key, f.amt, f.cm
          , CASE WHEN sz.n < 300
                 THEN DATEFROMPARTS(YEAR(f.cm), ((MONTH(f.cm) - 1) / 3) * 3 + 1, 1)
                 ELSE f.cm END                                                          AS cohort_start
          , CASE WHEN sz.n < 300 THEN N'квартал' ELSE N'месяц' END                      AS cohort_type
          , CASE WHEN f.first_def IS NULL THEN NULL
                 WHEN DATEDIFF(month, f.cm, f.first_def) < 1 THEN 1
                 ELSE DATEDIFF(month, f.cm, f.first_def) END                            AS k_def
          , CASE WHEN f.first_od IS NULL THEN NULL
                 WHEN DATEDIFF(month, f.cm, f.first_od) < 1 THEN 1
                 ELSE DATEDIFF(month, f.cm, f.first_od) END                             AS k_od
    FROM    f
    JOIN    sz ON sz.cm = f.cm AND sz.product_key = f.product_key
)
, coh AS (          /* когорта: размер, сумма, наблюдаемый возраст — по самому молодому месяцу */
    SELECT  f2.l_source, f2.product_key, f2.cohort_start, f2.cohort_type
          , COUNT_BIG(*)                                                                AS cohort_cnt
          , SUM(f2.amt)                                                                 AS cohort_amount
          , MIN(DATEDIFF(month, f2.cm, w.last_slice))                                   AS max_k
    FROM    f2
    CROSS JOIN w
    GROUP BY f2.l_source, f2.product_key, f2.cohort_start, f2.cohort_type
)
, ages AS (
    SELECT  k
    FROM    (VALUES (1),(2),(3),(4),(5),(6),(7),(8),(9),(10),(11),(12),
                    (13),(14),(15),(16),(17),(18),(19),(20),(21),(22),(23),(24)) AS v(k)
)
, g AS (            /* сетка когорта × возраст — после отбора наблюдаемых возрастов */
    SELECT  coh.l_source, coh.product_key, coh.cohort_start, coh.cohort_type
          , coh.cohort_cnt, coh.cohort_amount, coh.max_k, ages.k
    FROM    coh
    JOIN    ages ON ages.k <= coh.max_k
)
SELECT    g.cohort_start
        , g.cohort_type
        , CASE WHEN g.cohort_type = N'месяц'
               THEN CONVERT(nvarchar(7), g.cohort_start, 120)
               ELSE CONVERT(nvarchar(4), YEAR(g.cohort_start)) + N'-Q'
                    + CONVERT(nvarchar(1), (MONTH(g.cohort_start) + 2) / 3) END         AS cohort_label
        , g.l_source
        , g.product_key
        , g.k                                                                           AS age_k
        , g.max_k
        , g.cohort_cnt
        , g.cohort_amount
        , SUM(CASE WHEN f2.k_def <= g.k THEN 1      ELSE 0 END)                         AS ever_def_cnt
        , SUM(CASE WHEN f2.k_def <= g.k THEN f2.amt ELSE 0 END)                         AS ever_def_amount
        , SUM(CASE WHEN f2.k_od  <= g.k THEN 1      ELSE 0 END)                         AS ever_od_cnt
        , SUM(CASE WHEN f2.k_od  <= g.k THEN f2.amt ELSE 0 END)                         AS ever_od_amount
FROM      g
JOIN      f2
       ON  f2.l_source     = g.l_source
       AND f2.product_key  = g.product_key
       AND f2.cohort_start = g.cohort_start
       AND f2.cohort_type  = g.cohort_type
GROUP BY  g.cohort_start, g.cohort_type, g.l_source, g.product_key, g.k, g.max_k
        , g.cohort_cnt, g.cohort_amount
OPTION (MAXDOP 1);
