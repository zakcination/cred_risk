/* =============================================================================
   D15-E. Устойчивый DPD по пулу из БАЗЫ ДЕФОЛТОВ.

   ПРОСТЫМ ЯЗЫКОМ. Есть запрос, который на пуле «3-я корзина на 01.08.2026»
   искал займы с почти одинаковой просрочкой шесть месяцев подряд — это находка
   Дианы про ~1300 договоров, которые платят каждый месяц с устойчивым лагом.
   Здесь то же самое, но пул берётся не из портфеля на одну дату, а из
   [CL_PORTFOLIO].[dbo].[HISTORY_DEFAULT_ACCOUNT] — базы дефолтов. Плюс
   исправлены четыре дефекта исходного запроса, из-за которых он завышал
   «количество месяцев с похожим DPD» и пропускал часть целевой популяции.

   ЧТО ИСПРАВЛЕНО ПРОТИВ ИСХОДНОГО ЗАПРОСА
     [Р-1] COUNT(*) по самосоединению считал ПАРЫ строк, а не месяцы. Для займа
           с DPD 6,6,7,7,6,7 он выдавал 18 при окне в шесть месяцев. Хуже того,
           завышение тем сильнее, чем стабильнее DPD, то есть ровно на той
           популяции, ради которой запрос написан. Порог >= 3 при этом
           пропускал займы всего с ДВУМЯ похожими месяцами: 2 x 2 = 4 >= 3.
           Здесь COUNT(DISTINCT month) по кандидатам из различных значений DPD.
     [Р-2] tag <> '11' молча выбрасывает строки с tag IS NULL: сравнение с NULL
           даёт UNKNOWN. В соседнем stage3_cure_pool.sql это уже сделано верно
           через ISNULL(tag,''). Здесь так же.
     [Р-3] Полоса +/- 2 УЖЕ календарного шума. При неизменном дне платежа
           снимочный DPD гуляет вместе с длиной месяца: для дня платежа 25 ряд
           по срезам мар-авг 2026 равен 4, 7, 6, 7, 6, 7 — размах 3, а не 0.
           Полоса по умолчанию расширена до +/- 3 и вынесена в параметр.
     [Р-4] Не проверялась подряд идущесть. Правило Методики говорит «6 месяцев
           ПОДРЯД», а исходный запрос считал «сколько-то месяцев где-то внутри
           окна». Здесь считаются обе величины отдельно: months_in_band и
           longest_run.

   ЧТО НЕ ИСПРАВЛЕНО, А ВЫНЕСЕНО В ПАРАМЕТР И ТРЕБУЕТ РЕШЕНИЯ
     * @Cap = 30 отсекает сверху. Это отсекает и устойчивый перекат на ДВА
       платежа (DPD ~35), и займы с ранним днём платежа: при дне платежа 1-2
       снимочный DPD равен 30-31 и в выборку не попадает вовсе. То есть верхняя
       граница — скрытый фильтр по дню платежа, это П3.
     * @Cap = 30 не совпадает с порогом инициативы 15. Найденный здесь пул шире
       того, который оздоровился бы по мягкому правилу.

   ГЛАВНОЕ ОГРАНИЧЕНИЕ, КОТОРОЕ НЕ СНИМАЕТСЯ НИКАКОЙ ПРАВКОЙ ЗАПРОСА
     Снимок даёт нижнюю границу эпизода, а не его величину (П2). Устойчивый
     DPD = 6 на срезах означает фактическую просрочку 6-36 дней. Отличить
     перекат от замороженного поля по одному DPD нельзя — для этого нужен
     календарный остаток, § 6, и день планового платежа из repayment_schedule.

   Источники, имена колонок из живого аудита контура:
     [CL_PORTFOLIO].[dbo].[HISTORY_DEFAULT_ACCOUNT]  account_number, default_date
     [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2]           contract_number, date, dpd,
                                                     category, tag, balance,
                                                     provisions_total
   Состав HISTORY_DEFAULT_ACCOUNT сверх двух колонок НЕ подтверждён — § 0.

   Read-only. Только SELECT. Только #temp с префиксом D15E_. MAXDOP 1.
   В репозиторий кладутся агрегаты § 5, не выдача § 7.
   T-SQL (Microsoft SQL Server).
   ============================================================================= */

SET NOCOUNT ON;

DECLARE @AsOf      date = '2026-08-01';  -- последний срез окна
DECLARE @Months    int  = 6;             -- длина окна наблюдения, месяцев
DECLARE @Band      int  = 3;             -- полоса «похожести» DPD, +/- дней   [Р-3]
DECLARE @Cap       int  = 30;            -- верхняя отсечка DPD (см. оговорку)
DECLARE @MinMonths int  = 3;             -- минимум месяцев в полосе для выдачи

DECLARE @From date = DATEADD(MONTH, -(@Months - 1), @AsOf);


/* =============================================================================
   § 0. АУДИТ. Прогнать ПЕРВЫМ и прочитать глазами. Дальше не идти, пока
        не ответите на два вопроса: какая у базы дефолтов зернистость и
        совпадает ли ключ с contract_number портфеля.
   ============================================================================= */

-- 0a. Состав базы дефолтов. Колонок сверх account_number/default_date мы не знаем.
SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH, ORDINAL_POSITION
FROM [CL_PORTFOLIO].INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'HISTORY_DEFAULT_ACCOUNT'
ORDER BY ORDINAL_POSITION;

-- 0b. ЗЕРНИСТОСТЬ. Таблица называется HISTORY — почти наверняка несколько строк
--     на счёт. Если max_rows_per_account > 1, любое соединение без свёртки
--     размножает строки портфеля. В этом репозитории уже была отозванная
--     находка ровно по зернистости (PR #14 -> #15), повторять не будем.
SELECT
      SUM(CAST(rows_per_account AS bigint))       AS rows_total
    , COUNT(*)                                    AS accounts
    , MAX(rows_per_account)                       AS max_rows_per_account
    , SUM(CASE WHEN rows_per_account > 1 THEN 1 ELSE 0 END) AS accounts_with_many
FROM (
    SELECT account_number, COUNT(*) AS rows_per_account
    FROM [CL_PORTFOLIO].[dbo].[HISTORY_DEFAULT_ACCOUNT]
    GROUP BY account_number
) g
OPTION (MAXDOP 1);

-- 0c. Глубина истории дефолтов и доля непарсящихся дат.
SELECT
      MIN(TRY_CAST(default_date AS date))         AS default_date_min
    , MAX(TRY_CAST(default_date AS date))         AS default_date_max
    , COUNT(*)                                    AS rows_total
    , SUM(CASE WHEN default_date IS NULL THEN 1 ELSE 0 END)                  AS date_null
    , SUM(CASE WHEN default_date IS NOT NULL
                AND TRY_CAST(default_date AS date) IS NULL THEN 1 ELSE 0 END) AS date_unparsable
FROM [CL_PORTFOLIO].[dbo].[HISTORY_DEFAULT_ACCOUNT]
OPTION (MAXDOP 1);

-- 0d. Стыкуется ли ключ базы дефолтов с ключом портфеля.
--     Если пересечение мало — ключи разные, и весь скрипт ниже бессмыслен.
SELECT
      COUNT(DISTINCT d.account_number)            AS accounts_in_defaults
    , COUNT(DISTINCT p.contract_number)           AS matched_in_portfolio
FROM [CL_PORTFOLIO].[dbo].[HISTORY_DEFAULT_ACCOUNT] d
LEFT JOIN (
    SELECT DISTINCT contract_number
    FROM [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2]
    WHERE [date] BETWEEN @From AND @AsOf
) p ON p.contract_number = d.account_number
OPTION (MAXDOP 1);

-- 0e. Тип DPD и даты в портфеле. Если date — datetime со временем,
--     сравнение с '2026-08-01' потеряет строки; если dpd лежит строкой,
--     арифметика в полосе даст неявное преобразование.
SELECT COLUMN_NAME, DATA_TYPE
FROM [CL_PORTFOLIO].INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'CL_PORTFOLIO_2'
  AND COLUMN_NAME IN ('contract_number','date','dpd','category','tag')
ORDER BY ORDINAL_POSITION;


/* =============================================================================
   § 1. ПУЛ ИЗ БАЗЫ ДЕФОЛТОВ. Одна строка на счёт — свёртка по [Р-1]/§ 0b.
        Побочно получаем default_events: сколько раз счёт дефолтил.
        Это и есть default exposure count из разбора бэк-теста.
   ============================================================================= */

IF OBJECT_ID('tempdb..#D15E_pool') IS NOT NULL DROP TABLE #D15E_pool;

SELECT
      d.account_number
    , COUNT(*)                                    AS default_events
    , MIN(TRY_CAST(d.default_date AS date))       AS default_date_first
    , MAX(TRY_CAST(d.default_date AS date))       AS default_date_last
INTO #D15E_pool
FROM [CL_PORTFOLIO].[dbo].[HISTORY_DEFAULT_ACCOUNT] d
WHERE TRY_CAST(d.default_date AS date) IS NOT NULL
GROUP BY d.account_number
OPTION (MAXDOP 1);

CREATE UNIQUE CLUSTERED INDEX ix_D15E_pool ON #D15E_pool(account_number);


/* =============================================================================
   § 2. ПОМЕСЯЧНАЯ ПАНЕЛЬ DPD по пулу за окно @From … @AsOf.
        Пул из базы дефолтов, просрочка из портфеля.
   ============================================================================= */

IF OBJECT_ID('tempdb..#D15E_panel') IS NOT NULL DROP TABLE #D15E_panel;

SELECT
      a.account_number
    , TRY_CAST(p.[date] AS date)                              AS snap_date
    , DATEDIFF(MONTH, @From, TRY_CAST(p.[date] AS date))      AS month_idx
    , TRY_CAST(p.[dpd] AS int)                                AS dpd
    , p.[category]
    , p.[balance]
    , p.[provisions_total]
INTO #D15E_panel
FROM #D15E_pool a
INNER JOIN [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2] p
        ON p.contract_number = a.account_number
WHERE TRY_CAST(p.[date] AS date) BETWEEN @From AND @AsOf
  AND ISNULL(p.[tag], '') <> '11'          -- [Р-2] NULL-tag не выбрасываем
OPTION (MAXDOP 1);

CREATE CLUSTERED INDEX ix_D15E_panel ON #D15E_panel(account_number, month_idx);

-- Контроль зернистости панели: должно быть не больше одной строки
-- на счёт x месяц. Если больше — MAX(CASE …) в исходном запросе молча
-- прятал дубли, и всё дальнейшее считается по произвольной строке.
SELECT
      COUNT(*)                                  AS panel_rows
    , COUNT(DISTINCT account_number)            AS accounts
    , MAX(rows_per_key)                         AS max_rows_per_account_month
FROM (
    SELECT account_number, month_idx, COUNT(*) AS rows_per_key
    FROM #D15E_panel
    GROUP BY account_number, month_idx
) g
OPTION (MAXDOP 1);


/* =============================================================================
   § 3. КАНДИДАТЫ И ЛУЧШАЯ ПОЛОСА.
        Для каждого счёта берём каждое НАБЛЮДЁННОЕ значение DPD как центр
        полосы и считаем, сколько РАЗЛИЧНЫХ месяцев в неё попадает.   [Р-1]
   ============================================================================= */

IF OBJECT_ID('tempdb..#D15E_obs') IS NOT NULL DROP TABLE #D15E_obs;

SELECT account_number, month_idx, dpd
INTO #D15E_obs
FROM #D15E_panel
WHERE dpd IS NOT NULL
  AND dpd > 0
  AND dpd < @Cap;

CREATE CLUSTERED INDEX ix_D15E_obs ON #D15E_obs(account_number, dpd);

IF OBJECT_ID('tempdb..#D15E_cand') IS NOT NULL DROP TABLE #D15E_cand;

SELECT
      c.account_number
    , c.base_dpd
    , COUNT(DISTINCT o.month_idx)   AS months_in_band
    , MIN(o.dpd)                    AS band_min_dpd
    , MAX(o.dpd)                    AS band_max_dpd
INTO #D15E_cand
FROM (SELECT DISTINCT account_number, dpd AS base_dpd FROM #D15E_obs) c
INNER JOIN #D15E_obs o
        ON o.account_number = c.account_number
       AND o.dpd BETWEEN c.base_dpd - @Band AND c.base_dpd + @Band
GROUP BY c.account_number, c.base_dpd
OPTION (MAXDOP 1);

-- Лучшая полоса на счёт: больше месяцев, при равенстве — меньший центр.
IF OBJECT_ID('tempdb..#D15E_best') IS NOT NULL DROP TABLE #D15E_best;

SELECT account_number, base_dpd, months_in_band, band_min_dpd, band_max_dpd
INTO #D15E_best
FROM (
    SELECT c.*,
           ROW_NUMBER() OVER (PARTITION BY c.account_number
                              ORDER BY c.months_in_band DESC, c.base_dpd ASC) AS rn
    FROM #D15E_cand c
) x
WHERE rn = 1;

CREATE UNIQUE CLUSTERED INDEX ix_D15E_best ON #D15E_best(account_number);


/* =============================================================================
   § 4. ПОДРЯД ИДУЩИЕ МЕСЯЦЫ в лучшей полосе — gaps and islands.   [Р-4]
        months_in_band отвечает на «сколько похожих месяцев вообще»,
        longest_run — на «сколько ПОДРЯД», а Методика требует именно подряд.
   ============================================================================= */

IF OBJECT_ID('tempdb..#D15E_run') IS NOT NULL DROP TABLE #D15E_run;

SELECT account_number, MAX(run_len) AS longest_run
INTO #D15E_run
FROM (
    SELECT account_number, grp, COUNT(*) AS run_len
    FROM (
        SELECT
              p.account_number
            , p.month_idx
            , p.month_idx - ROW_NUMBER() OVER (PARTITION BY p.account_number
                                               ORDER BY p.month_idx) AS grp
        FROM #D15E_panel p
        INNER JOIN #D15E_best b ON b.account_number = p.account_number
        WHERE p.dpd IS NOT NULL
          AND p.dpd BETWEEN b.base_dpd - @Band AND b.base_dpd + @Band
    ) islands
    GROUP BY account_number, grp
) runs
GROUP BY account_number
OPTION (MAXDOP 1);


/* =============================================================================
   § 5. АГРЕГАТЫ. Это то, что идёт в отчёт и в репозиторий.
   ============================================================================= */

-- 5a. Воронка: сколько теряется на каждом шаге и где именно.
SELECT
      (SELECT COUNT(*) FROM #D15E_pool)                                   AS pool_accounts_in_defaults
    , (SELECT COUNT(DISTINCT account_number) FROM #D15E_panel)            AS with_portfolio_rows_in_window
    , (SELECT COUNT(DISTINCT account_number) FROM #D15E_obs)              AS with_dpd_between_0_and_cap
    , (SELECT COUNT(*) FROM #D15E_best WHERE months_in_band >= @MinMonths) AS passing_min_months
OPTION (MAXDOP 1);

-- 5b. Распределение по числу похожих месяцев и по подряд идущим.
--     Диагональ таблицы = займы, у которых все похожие месяцы идут подряд.
SELECT
      b.months_in_band
    , r.longest_run
    , COUNT(*)                                  AS accounts
    , SUM(CAST(h.default_events AS bigint))     AS default_events_total
FROM #D15E_best b
INNER JOIN #D15E_run  r ON r.account_number = b.account_number
INNER JOIN #D15E_pool h ON h.account_number = b.account_number
GROUP BY b.months_in_band, r.longest_run
ORDER BY b.months_in_band DESC, r.longest_run DESC
OPTION (MAXDOP 1);

-- 5c. Размах DPD внутри лучшей полосы — бакетами, без идентификаторов.
--     Размах 0 при окне в несколько месяцев АРИФМЕТИЧЕСКИ НЕВОЗМОЖЕН, если
--     день платежа не менялся: месяцы разной длины дают разброс до 3 дней.
--     Строка spread = 0 — это подозрение на замороженное поле или
--     приостановленное начисление, а не на дисциплинированного заёмщика.
SELECT
      CASE WHEN b.band_max_dpd - b.band_min_dpd = 0 THEN '0  (проверить: невозможно при живом начислении)'
           WHEN b.band_max_dpd - b.band_min_dpd <= 3 THEN '1-3  (совпадает с календарным шумом)'
           WHEN b.band_max_dpd - b.band_min_dpd <= 6 THEN '4-6'
           ELSE '7+' END                        AS dpd_spread_bucket
    , r.longest_run
    , COUNT(*)                                  AS accounts
FROM #D15E_best b
INNER JOIN #D15E_run r ON r.account_number = b.account_number
WHERE b.months_in_band >= @MinMonths
GROUP BY
      CASE WHEN b.band_max_dpd - b.band_min_dpd = 0 THEN '0  (проверить: невозможно при живом начислении)'
           WHEN b.band_max_dpd - b.band_min_dpd <= 3 THEN '1-3  (совпадает с календарным шумом)'
           WHEN b.band_max_dpd - b.band_min_dpd <= 6 THEN '4-6'
           ELSE '7+' END
    , r.longest_run
ORDER BY dpd_spread_bucket, r.longest_run DESC
OPTION (MAXDOP 1);

-- 5d. Повторность дефолтов по найденной популяции.
--     Отвечает на «сколько раз счёт дефолтил» из разбора бэк-теста.
SELECT
      CASE WHEN h.default_events = 1 THEN '1'
           WHEN h.default_events = 2 THEN '2'
           WHEN h.default_events BETWEEN 3 AND 4 THEN '3-4'
           ELSE '5+' END                        AS default_events_bucket
    , COUNT(*)                                  AS accounts
    , AVG(CAST(r.longest_run AS float))         AS avg_longest_run
FROM #D15E_pool h
INNER JOIN #D15E_best b ON b.account_number = h.account_number
INNER JOIN #D15E_run  r ON r.account_number = h.account_number
WHERE b.months_in_band >= @MinMonths
GROUP BY
      CASE WHEN h.default_events = 1 THEN '1'
           WHEN h.default_events = 2 THEN '2'
           WHEN h.default_events BETWEEN 3 AND 4 THEN '3-4'
           ELSE '5+' END
ORDER BY default_events_bucket
OPTION (MAXDOP 1);


/* =============================================================================
   § 6. КАЛЕНДАРНЫЙ ОСТАТОК — заполняется после § 0 в D15_D_payday.sql.
        БЕЗ ЭТОГО БЛОКА отличить перекат от замороженного поля нельзя.

        остаток(t) = dpd(t) − (дней в месяце t−1 − день планового платежа + 1)

        Заготовка ниже опирается на [Dictionaries].[risk_analytics].[repayment_schedule]
        (rs_loan_id / rs_dog_num, rs_repayment_date, rs_report_date). НЕ ЗАПУСКАТЬ,
        пока § 0 D15_D не ответит: что является ключом договора, сколько версий
        графика лежит в rs_report_date и надо ли брать одну.

        Раскомментировать и подставить подтверждённый ключ:

        SELECT
              p.account_number
            , p.snap_date
            , p.dpd
            , DAY(sch.pay_day_date)                                      AS pay_day
            , DAY(EOMONTH(DATEADD(MONTH,-1,p.snap_date)))
              - DAY(sch.pay_day_date) + 1                                AS dpd_calendar
            , p.dpd - (DAY(EOMONTH(DATEADD(MONTH,-1,p.snap_date)))
                       - DAY(sch.pay_day_date) + 1)                      AS residual
        FROM #D15E_panel p
        INNER JOIN (…подтверждённый график…) sch
                ON sch.<ключ> = p.account_number;

        Чтение результата:
          residual ~ 0 на всех срезах         -> чистый перекат, П3 подтверждена
          residual > 0 и растёт               -> поверх переката реальные эпизоды
          дисперсия dpd = 0, дисперсия
          dpd_calendar > 0                    -> данные, а не заёмщик
   ============================================================================= */


/* =============================================================================
   § 7. ПОИМЁННАЯ ВЫДАЧА. Рабочий список для распределения по подразделениям.
        РЕЗУЛЬТАТ ЭТОЙ СЕКЦИИ В РЕПОЗИТОРИЙ НЕ КЛАДЁТСЯ — номера договоров
        относятся к персональным данным по правилам репозитория.
        В отчёт идут § 5, здесь — только рабочая выгрузка.
   ============================================================================= */

SELECT
      b.account_number
    , h.default_events
    , h.default_date_first
    , h.default_date_last
    , b.base_dpd
    , b.band_min_dpd
    , b.band_max_dpd
    , b.band_max_dpd - b.band_min_dpd            AS dpd_spread
    , b.months_in_band
    , r.longest_run
    , (SELECT COUNT(*) FROM #D15E_panel p
        WHERE p.account_number = b.account_number)          AS months_observed
FROM #D15E_best b
INNER JOIN #D15E_run  r ON r.account_number = b.account_number
INNER JOIN #D15E_pool h ON h.account_number = b.account_number
WHERE b.months_in_band >= @MinMonths
ORDER BY r.longest_run DESC, b.months_in_band DESC, b.dpd_spread ASC
OPTION (MAXDOP 1);
