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
   начало среза нет, и «новых» за него не бывает по построению. Выздоровевшие
   могут попасть в месяц за окном — отсекаются связью с dim_month.

   Колонки:
     in_def_cnt, in_def_balance        — открытые счета в дефолте по правилу на конец месяца
     new_def_cnt, new_def_balance      — вошли в дефолт за месяц (новые), остаток на срезе входа
     cured_cnt                         — вышли из дефолта в этом месяце (6-й чистый срез)
   Знаменатели — из fact_stock (счета и остаток S01/S03/S17), в DAX:
     доля в дефолте              = in_def_balance / остаток;
     уровень новых дефолтов (мес) = new_def_cnt(M) / (открытые счета(M−1) − in_def_cnt(M−1)).

   ПРОИЗВОДИТЕЛЬНОСТЬ (редакция 28.09.2026 после прогона, который не дождались).
   Дефолт возможен только у счёта, хоть раз бывшего в 90+ при 1424 <> 0. Первым
   проходом выбираются такие счета (dd), вторым — только их история; оконные
   функции идут по ней, а не по ~10 млн строк всего портфеля. Знаменатели из
   факта убраны — они уже есть в fact_stock.
   SQL Server не хранит CTE: каждое обращение — новый расчёт. Поэтому цепочка
   построена так, что каждое звено читается ровно один раз: выход из дефолта и
   «новый» считаются оконными функциями, без повторного обращения и без EXISTS.

   Контроли — DEFAULT_PLAN.md, §5; первый: in_def_cnt ≤ счетов с 1424 <> 0
   в fact_stock того же месяца и источника (по построению).

   Имена колонок — из живого аудита DEF_0 (блок 0а, 28.09.2026). Режим ИМПОРТ,
   один оператор. В Power BI — «Время ожидания команды» 30 мин
   (Дополнительные параметры), до замера в SSMS.
   Read-only. На выходе только агрегаты.
   ============================================================================= */
WITH dd AS (        /* счета, хоть раз в дефолте по правилу в окне — только у них события */
    SELECT DISTINCT la.la_source, la.la_gid
    FROM   [Dictionaries].[risk_analytics].[loan_account] AS la
    WHERE  la.la_status = N'Открыт'
      AND  la.la_source IN ('S01', 'S03', 'S17')
      AND  la.la_account_1424 <> 0
      AND  la.days_past_due_principal > 90
)
, a AS (            /* вся история этих счетов; GROUP BY — страховка от дублей счёта на срезе */
    SELECT  la.la_source
          , la.la_gid
          , la.la_reporting_date                                                        AS d
          , DATEDIFF(month, '20250101', la.la_reporting_date)                           AS m
          , SUM(CAST(ISNULL(la.total_balance_debt, 0) AS decimal(38,2)))                AS bal
          , MAX(CASE WHEN ISNULL(la.la_account_1424, 0) <> 0
                      AND la.days_past_due_principal > 90 THEN 1 ELSE 0 END)           AS dflt
          , MIN(CASE WHEN ISNULL(la.la_account_1424, 0) = 0 THEN 1 ELSE 0 END)          AS clean
    FROM    [Dictionaries].[risk_analytics].[loan_account] AS la
    JOIN    dd
           ON  dd.la_gid    = la.la_gid
           AND dd.la_source = la.la_source
    WHERE   la.la_status = N'Открыт'
    GROUP BY la.la_source, la.la_gid, la.la_reporting_date
)
, p1 AS (           /* предыдущий наблюдённый срез, последний дефолт до среза, номер острова */
    SELECT  a.la_source, a.la_gid, a.d, a.m, a.bal, a.dflt, a.clean
          , LAG(a.dflt) OVER (PARTITION BY a.la_source, a.la_gid ORDER BY a.m)          AS dflt_prev
          , MAX(CASE WHEN a.dflt = 1 THEN a.m END)
                OVER (PARTITION BY a.la_source, a.la_gid ORDER BY a.m
                      ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)                 AS last_def_m
          , a.m - ROW_NUMBER() OVER (PARTITION BY a.la_source, a.la_gid, a.clean
                                     ORDER BY a.m)                                      AS grp
    FROM    a
)
, p2 AS (           /* длина серии чистых срезов подряд до текущего; пропуск месяца рвёт серию */
    SELECT  p1.la_source, p1.la_gid, p1.d, p1.m, p1.bal, p1.dflt, p1.dflt_prev, p1.last_def_m
          , CASE WHEN p1.clean = 1
                  AND p1.last_def_m IS NOT NULL
                  AND ROW_NUMBER() OVER (PARTITION BY p1.la_source, p1.la_gid, p1.clean, p1.grp
                                         ORDER BY p1.m) = 6
                 THEN 1 ELSE 0 END                                                      AS cured          /* 6-й чистый срез после дефолта */
    FROM    p1
)
, p3 AS (           /* последний выход до среза */
    SELECT  p2.la_source, p2.la_gid, p2.d, p2.bal, p2.dflt, p2.dflt_prev, p2.last_def_m, p2.cured
          , MAX(CASE WHEN p2.cured = 1 THEN p2.m END)
                OVER (PARTITION BY p2.la_source, p2.la_gid ORDER BY p2.m
                      ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)                 AS last_cure_m
    FROM    p2
)
, ev AS (           /* новый: вход из «не в дефолте»; раньше дефолта не было или после него был выход */
    SELECT  p3.la_source, p3.la_gid
          , DATEADD(month, -1, p3.d)                                                    AS month_start      /* срез t → месяц t−1 */
          , p3.dflt
          , CASE WHEN p3.dflt = 1 THEN p3.bal ELSE 0 END                                AS in_def_bal
          , CASE WHEN p3.dflt = 1 AND p3.dflt_prev = 0
                  AND (p3.last_def_m IS NULL OR p3.last_cure_m > p3.last_def_m)
                 THEN 1 ELSE 0 END                                                      AS is_new
          , p3.cured
    FROM    p3
    WHERE   p3.dflt = 1 OR p3.cured = 1
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
SELECT    ev.month_start
        , ev.la_source                                                                  AS l_source
        , ISNULL(pr.product_key, CONVERT(nvarchar(10), ev.la_source) + N'|нет договора') AS product_key
        , SUM(ev.dflt)                                                                  AS in_def_cnt
        , SUM(ev.in_def_bal)                                                            AS in_def_balance
        , SUM(ev.is_new)                                                                AS new_def_cnt
        , SUM(CASE WHEN ev.is_new = 1 THEN ev.in_def_bal ELSE 0 END)                    AS new_def_balance
        , SUM(ev.cured)                                                                 AS cured_cnt
FROM      ev
LEFT JOIN prod AS pr
       ON  pr.l_gid    = ev.la_gid
       AND pr.l_source = ev.la_source
WHERE     ev.month_start >= '20250101'                         /* 12.2024: новых дефолтов не наблюдаемо — начала месяца нет */
GROUP BY  ev.month_start, ev.la_source
        , ISNULL(pr.product_key, CONVERT(nvarchar(10), ev.la_source) + N'|нет договора')
OPTION (MAXDOP 1);
