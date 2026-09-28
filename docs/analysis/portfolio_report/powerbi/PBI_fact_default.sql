/* =============================================================================
   PBI_fact_default — таблица фактов ДЕФОЛТОВ для Power BI: новые дефолты
   (количество, объём), запас в дефолте, выздоровевшие.

   Зерно: месяц × источник × продукт (product_key как в PBI_fact_flow.sql).
   Месяц — по соглашению отчёта: срез 1-го числа описывает конец предыдущего
   месяца, month_start = срез − 1 месяц (как в fact_stock).

   Решения автора 28.09.2026 (DEFAULT_PLAN.md, «Решения автора»):
     — дефолт по правилу: days_past_due_principal > 90 ПРИ la_account_1424 <> 0,
       на открытых счетах (la_status = 'Открыт'), источники S01, S03, S17.
       «При 1424 <> 0» — поправка на смену смысла поля в 07.2026: с этого среза
       дни стоят ровно там, где есть 1424; весь ряд — на нынешнем смысле.
       S02 не входит: дней по картам нет (DEF_0, блок 1);
     — поле принято по доле пар «быстрее календаря» (DEF_0, блок 2); критерий
       заменён после прогона — записано в DEFAULT_PLAN.md;
     — единица — договор (счёт la_gid);
     — объём нового дефолта — остаток на срезе входа;
     — выход из дефолта — 6 срезов подряд без просрочки (la_account_1424 = 0),
       как Прил. 4 Методики МСФО. Вход в дефолт до выхода — продолжение прежнего,
       не новый. Второе условие Методики (погашение, снижающее ВБС) в витрине
       не проверяется.
   Это ДЕФОЛТ ПО ПРАВИЛУ, а не стадия Банка. Stage 3 + 4 — отдельный факт из
   CL_PORTFOLIO (после STG_0).

   Правила перехода между срезами:
     — «новый»: в дефолте на срезе t, НЕ в дефолте на предыдущем НАБЛЮДЁННОМ
       срезе счёта, и либо дефолта раньше в окне не было, либо после последнего
       дефолта был выход (6 чистых срезов подряд, без пропусков месяцев);
     — первый срез счёта в окне в дефолте — не новый: вход раньше окна или
       неизвестен (левое цензурирование);
     — пропуск среза счёта (в 02.2026 выпали строки S02, S03, S17 — FINDINGS)
       рвёт серию чистых срезов: «не наблюдён» ≠ «чистый».

   Окно: месяцы 01.2025 … (последний срез − 1 месяц). 12.2024 отрезан: на его
   начало среза нет, и «новых» за него не бывает по построению.

   Колонки:
     base_cnt, base_balance            — открытые счета S01/S03/S17 на конец месяца (знаменатель доли)
     in_def_cnt, in_def_balance        — из них в дефолте по правилу на конец месяца
     new_def_cnt, new_def_balance      — вошли в дефолт за месяц (новые)
     perf_start_cnt                    — не в дефолте на НАЧАЛО месяца (знаменатель уровня новых дефолтов)
     cured_cnt                         — вышли из дефолта в этом месяце (6-й чистый срез)

   Контроли — DEFAULT_PLAN.md, §5; первый: in_def_cnt ≤ счетов с 1424 <> 0
   в fact_stock того же месяца и источника (по построению).

   Имена колонок — из живого аудита DEF_0 (блок 0а, 28.09.2026). Режим ИМПОРТ,
   один оператор. Тяжёлый: оконные функции по ~10 млн строк — в Power BI
   задать «Время ожидания команды» 30 мин (Дополнительные параметры).
   Read-only. На выходе только агрегаты.
   ============================================================================= */
WITH a AS (         /* состояние счёта на срезе; GROUP BY — страховка от дублей счёта на срезе */
    SELECT  la.la_source
          , la.la_gid
          , la.la_reporting_date                                                        AS d
          , DATEDIFF(month, '20250101', la.la_reporting_date)                           AS m
          , SUM(CAST(ISNULL(la.total_balance_debt, 0) AS decimal(38,2)))                AS bal
          , MAX(CASE WHEN ISNULL(la.la_account_1424, 0) <> 0
                      AND la.days_past_due_principal > 90 THEN 1 ELSE 0 END)           AS dflt
          , MIN(CASE WHEN ISNULL(la.la_account_1424, 0) = 0 THEN 1 ELSE 0 END)          AS clean
    FROM    [Dictionaries].[risk_analytics].[loan_account] AS la
    WHERE   la.la_status = N'Открыт'
      AND   la.la_source IN ('S01', 'S03', 'S17')
    GROUP BY la.la_source, la.la_gid, la.la_reporting_date
)
, p AS (            /* предыдущий наблюдённый срез и последний дефолт до среза */
    SELECT  a.la_source, a.la_gid, a.d, a.m, a.bal, a.dflt, a.clean
          , LAG(a.dflt) OVER (PARTITION BY a.la_source, a.la_gid ORDER BY a.m)          AS dflt_prev
          , MAX(CASE WHEN a.dflt = 1 THEN a.m END)
                OVER (PARTITION BY a.la_source, a.la_gid ORDER BY a.m
                      ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)                 AS last_def_m
    FROM    a
)
, isl AS (          /* острова чистых срезов подряд; пропуск месяца рвёт остров */
    SELECT  la_source, la_gid, m, last_def_m
          , m - ROW_NUMBER() OVER (PARTITION BY la_source, la_gid ORDER BY m)           AS g
    FROM    p
    WHERE   clean = 1
)
, runs AS (         /* выход: 6+ чистых срезов подряд; def_before — был ли дефолт до острова */
    SELECT  la_source, la_gid, MIN(m) AS m_start, MAX(last_def_m) AS def_before
    FROM    isl
    GROUP BY la_source, la_gid, g
    HAVING  COUNT(*) >= 6
)
, ev AS (
    SELECT  p.la_source, p.la_gid, p.d, p.bal, p.dflt
          , CASE WHEN p.dflt = 1 AND p.dflt_prev = 0
                  AND (   p.last_def_m IS NULL
                       OR EXISTS (SELECT 1 FROM runs AS r
                                  WHERE r.la_source = p.la_source AND r.la_gid = p.la_gid
                                    AND r.m_start > p.last_def_m
                                    AND r.m_start + 5 < p.m) )
                 THEN 1 ELSE 0 END                                                      AS is_new
    FROM    p
)
, prod AS (         /* ключ продукта — строка в строку как в PBI_fact_flow.sql / PBI_fact_stock.sql */
    SELECT  l.l_gid, l.l_source
          , CASE
                WHEN l.l_source = 'S01' THEN N'S01|' + ISNULL(CONVERT(nvarchar(100), l.l_segment), N'—')
                ELSE CONVERT(nvarchar(10), l.l_source)
                     + N'|' + ISNULL(CONVERT(nvarchar(255), l.l_product_type),    N'—')
                     + N'|' + ISNULL(CONVERT(nvarchar(255), l.l_subproduct_type), N'—')
            END                                                                         AS product_key
    FROM    [Dictionaries].[risk_analytics].[loans] AS l
    WHERE   l.l_source IN ('S01', 'S03', 'S17')
)
, u AS (            /* срез t даёт конец месяца t−1 и начало месяца t */
    SELECT  DATEADD(month, -1, ev.d) AS month_start, ev.la_source, ev.la_gid
          , 1 AS base, ev.bal AS base_bal
          , ev.dflt AS in_def, CASE WHEN ev.dflt = 1 THEN ev.bal ELSE 0 END AS in_def_bal
          , ev.is_new AS new_def, CASE WHEN ev.is_new = 1 THEN ev.bal ELSE 0 END AS new_def_bal
          , 0 AS perf_start, 0 AS cured
    FROM    ev
    UNION ALL
    SELECT  ev.d, ev.la_source, ev.la_gid
          , 0, 0, 0, 0, 0, 0
          , CASE WHEN ev.dflt = 0 THEN 1 ELSE 0 END, 0
    FROM    ev
    UNION ALL
    SELECT  DATEADD(month, r.m_start + 4, CAST('20250101' AS date)), r.la_source, r.la_gid   /* 6-й чистый срез m_start+5 → месяц m_start+4 */
          , 0, 0, 0, 0, 0, 0, 0, 1
    FROM    runs AS r
    WHERE   r.def_before IS NOT NULL
)
, w AS (
    SELECT  MAX(la_reporting_date) AS last_slice
    FROM    [Dictionaries].[risk_analytics].[loan_account]
)
SELECT    u.month_start
        , u.la_source                                                                   AS l_source
        , ISNULL(pr.product_key, CONVERT(nvarchar(10), u.la_source) + N'|нет договора') AS product_key
        , SUM(u.base)                                                                   AS base_cnt
        , SUM(u.base_bal)                                                               AS base_balance
        , SUM(u.in_def)                                                                 AS in_def_cnt
        , SUM(u.in_def_bal)                                                             AS in_def_balance
        , SUM(u.new_def)                                                                AS new_def_cnt
        , SUM(u.new_def_bal)                                                            AS new_def_balance
        , SUM(u.perf_start)                                                             AS perf_start_cnt
        , SUM(u.cured)                                                                  AS cured_cnt
FROM      u
CROSS JOIN w
LEFT JOIN prod AS pr
       ON  pr.l_gid    = u.la_gid
       AND pr.l_source = u.la_source
WHERE     u.month_start >= '20250101'                        /* 12.2024: конец есть, начала нет — новые дефолты не наблюдаемы */
  AND     u.month_start <= DATEADD(month, -1, w.last_slice)  /* последний месяц с концом */
GROUP BY  u.month_start, u.la_source
        , ISNULL(pr.product_key, CONVERT(nvarchar(10), u.la_source) + N'|нет договора')
OPTION (MAXDOP 1);
