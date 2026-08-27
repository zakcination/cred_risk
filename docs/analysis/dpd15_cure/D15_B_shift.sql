/* =============================================================================
   D15-B. Г-DPD-1: просрочка систематическая или рваная?
   =============================================================================
   ПРОСТЫМ ЯЗЫКОМ. Есть заёмщики, которые после дефолта платят, но каждый месяц
   опаздывают. Вопрос: они опаздывают ОДИНАКОВО (значит дата платежа не совпадает
   с датой зарплаты — лечится переносом даты) или ПО-РАЗНОМУ (значит это настоящее
   ухудшение, и допуск 15 дней поглощает риск, а не удобство).

   Признак — не величина просрочки, а её РАЗБРОС.
     стабильные 5 дней каждый месяц  -> проблема графика  -> маршрут C
     2, потом 9, потом 14            -> проблема заёмщика -> маршрут B или A

   Что этот скрипт НЕ делает: он работает на месячных снимках, а не на фактических
   датах платежей. Снимок видит просрочку только на 1-е число, поэтому заёмщик,
   опаздывающий на 5 дней внутри месяца и платящий до 1-го, здесь невидим — и он
   в кандидаты не попадает вовсе. Полный ответ даёт слой 2 по платёжным таблицам;
   их имена сначала выясняет D15_A_audit.sql.

   ---------------------------------------------------------------------------
   ИСПРАВЛЕНЫ ШЕСТЬ ДЕФЕКТОВ stage3_cure_candidates.sql, подтверждённых
   ревизией 21.07.2026. Каждый помечен по месту: [Р-1] … [Р-6].
   ---------------------------------------------------------------------------
   Read-only. Только SELECT, только #temp с префиксом файла.
   T-SQL (Microsoft SQL Server).
   ============================================================================= */

SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#d15b_win')      IS NOT NULL DROP TABLE #d15b_win;
IF OBJECT_ID('tempdb..#d15b_contract') IS NOT NULL DROP TABLE #d15b_contract;

-------------------------------------------------------------------------------
-- 0. Параметры
-------------------------------------------------------------------------------
DECLARE @AsOf         date  = '2026-07-01'; -- отчётная дата
DECLARE @WindowMonths int   = 6;            -- окно наблюдения строгого правила
DECLARE @StabilityDays float = 2.0;         -- порог «систематичности»: стандартное
                                            -- отклонение просрочки не выше N дней
DECLARE @GrowthDays   int   = 5;            -- «растущая»: DPD на конец выше начала на N

-- [Р-2] Окно: строгое «>» даёт РОВНО @WindowMonths срезов.
-- Прежняя версия брала BETWEEN DATEADD(-6) AND @AsOf и получала семь.
DECLARE @WindowStart  date = DATEADD(MONTH, -@WindowMonths, @AsOf);
DECLARE @WindowFirst  date;                 -- первый фактический срез окна

-------------------------------------------------------------------------------
-- 1. Единый месячный ряд по шести источникам, окно наблюдения
--
-- [Р-1] Ключ договора — ПАРА (source_system, contract_number), не номер.
--       Cross-source коллизий по одному номеру задокументировано 9 659.
-- [Р-6] `balance` в источниках — разные поля (balance / Total_outstanding).
--       Складывать их между источниками нельзя без доказательства
--       эквивалентности базы, поэтому все итоги ниже даются В РАЗРЕЗЕ источника.
--
-- `stage_raw`: для S03 и карт это `category`, для RS и Fenix — `Basket`.
-- 27.07.2026 зафиксировано, что `category` и есть стадия IFRS. Это
-- методологическое решение, внешнего подтверждения владельца витрины
-- на файле НЕТ, и равенство `Basket` той же семантике не доказано —
-- см. предупреждение в конце файла.
-------------------------------------------------------------------------------
SELECT
      src.source_system
    , src.contract_number
    , src.snap_date
    , src.balance
    , src.dpd
    , src.stage_raw
INTO #d15b_win
FROM (
    SELECT 'S03_Credilogic' AS source_system, contract_number,
           TRY_CAST([date] AS date)                  AS snap_date,
           TRY_CAST([balance] AS decimal(38,2))      AS balance,
           TRY_CAST([dpd] AS int)                    AS dpd,
           TRY_CAST([category] AS nvarchar(50))      AS stage_raw
    FROM [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2]
    UNION ALL
    SELECT 'S17_Fenix', contractnumber,
           TRY_CAST(actual_date AS date),
           TRY_CAST(Total_outstanding AS decimal(38,2)),
           TRY_CAST(overdue_days_principal AS int),
           TRY_CAST(Basket AS nvarchar(50))
    FROM [CL_PORTFOLIO].[dbo].[PORTFOLIO_Fenix]
    UNION ALL
    SELECT 'S01_RS', contractnumber,
           TRY_CAST(actual_date AS date),
           TRY_CAST(Total_outstanding AS decimal(38,2)),
           TRY_CAST([dpd] AS int),
           TRY_CAST(Basket AS nvarchar(50))
    FROM [CL_PORTFOLIO].[dbo].[PORTFOLIO_RS]
    UNION ALL
    SELECT 'S02_MIGR_WAY4', contract_number,
           TRY_CAST([date] AS date),
           TRY_CAST([balance] AS decimal(38,2)),
           TRY_CAST([dpd] AS int),
           TRY_CAST([category] AS nvarchar(50))
    FROM [CL_PORTFOLIO].[dbo].[PORTFOLIO_CREDITCARDS_MIGR_WAY4]
    UNION ALL
    SELECT 'S02_SMART_CARD', contract_number,
           TRY_CAST([date] AS date),
           TRY_CAST([balance] AS decimal(38,2)),
           TRY_CAST([dpd] AS int),
           TRY_CAST([category] AS nvarchar(50))
    FROM [CL_PORTFOLIO].[dbo].[PORTFOLIO_CREDITCARDS_SMART_CARD]
    UNION ALL
    SELECT 'S02_WAY4', contract_number,
           TRY_CAST([date] AS date),
           TRY_CAST([balance] AS decimal(38,2)),
           TRY_CAST([dpd] AS int),
           TRY_CAST([category] AS nvarchar(50))
    FROM [CL_PORTFOLIO].[dbo].[PORTFOLIO_CREDITCARDS_WAY4]
) AS src
WHERE src.snap_date >  @WindowStart
  AND src.snap_date <= @AsOf
OPTION (MAXDOP 1);

CREATE CLUSTERED INDEX ix_d15b_win ON #d15b_win (source_system, contract_number, snap_date);

SELECT @WindowFirst = MIN(snap_date) FROM #d15b_win;

-------------------------------------------------------------------------------
-- §0. Контроль окна: срезов должно быть РОВНО @WindowMonths.
--     Печатается первым — если их семь, [Р-2] не сработала и дальше не читаем.
-------------------------------------------------------------------------------
SELECT COUNT(DISTINCT snap_date) AS snapshots_in_window,
       MIN(snap_date)            AS first_snap,
       MAX(snap_date)            AS last_snap
FROM #d15b_win;

-------------------------------------------------------------------------------
-- 2. Метрики по договору
--
-- [Р-3] «На @AsOf» — это ровно @AsOf, а не последний срез в окне. Прежняя
--       версия брала MAX(snap_date) по договору, и договор без июльского среза
--       молча выводился с июньским остатком.
-- [Р-4] Полнота DPD проверяется, а не просто считается: договор с одним
--       заполненным месяцем и пятью NULL проходил прежний фильтр как валидный.
-- [Р-5] Колонка названа dpd_asof, а не «просрочка погашена»: DPD 1-5 означает
--       непогашенную просрочку, просто малую.
-------------------------------------------------------------------------------
SELECT
      w.source_system
    , w.contract_number
    , COUNT(*)                                                    AS months_total
    , SUM(CASE WHEN w.dpd IS NOT NULL THEN 1 ELSE 0 END)          AS months_with_dpd
    , SUM(CASE WHEN w.dpd > 0         THEN 1 ELSE 0 END)          AS months_overdue
    , MAX(w.dpd)                                                  AS dpd_max
    , MIN(w.dpd)                                                  AS dpd_min
    , AVG(CAST(w.dpd AS float))                                   AS dpd_avg
    , STDEV(CAST(w.dpd AS float))                                 AS dpd_sd
    , MAX(CASE WHEN w.snap_date = @AsOf        THEN w.dpd END)    AS dpd_asof
    , MAX(CASE WHEN w.snap_date = @AsOf        THEN w.balance END) AS balance_asof
    , MAX(CASE WHEN w.snap_date = @AsOf        THEN w.stage_raw END) AS stage_asof
    , MAX(CASE WHEN w.snap_date = @WindowFirst THEN w.dpd END)    AS dpd_first
    , MAX(CASE WHEN w.snap_date = @AsOf        THEN 1 ELSE 0 END) AS has_asof_snap
INTO #d15b_contract
FROM #d15b_win AS w
GROUP BY w.source_system, w.contract_number
OPTION (MAXDOP 1);

-------------------------------------------------------------------------------
-- §1. Периметр: сколько договоров и почему отсеяно.
--     Отсев без объяснения — половина дефектов ревизии 21.07.
-------------------------------------------------------------------------------
SELECT
      c.source_system
    , COUNT(*)                                                           AS contracts_all
    , SUM(CASE WHEN c.stage_asof = '3' THEN 1 ELSE 0 END)                AS stage3_at_asof
    , SUM(CASE WHEN c.has_asof_snap = 0 THEN 1 ELSE 0 END)               AS no_snap_at_asof     -- [Р-3]
    , SUM(CASE WHEN c.months_with_dpd < @WindowMonths THEN 1 ELSE 0 END) AS dpd_incomplete      -- [Р-4]
    , SUM(CASE WHEN c.stage_asof = '3'
                AND c.has_asof_snap = 1
                AND c.months_with_dpd = @WindowMonths THEN 1 ELSE 0 END) AS contracts_usable
FROM #d15b_contract AS c
GROUP BY c.source_system WITH ROLLUP
ORDER BY GROUPING(c.source_system), contracts_all DESC;

-------------------------------------------------------------------------------
-- §2. Сетка допусков ЦЕЛИКОМ.
--
-- Печатается вся, а не только выбранное значение. Пункт 10 ревизии 21.07
-- зафиксировал, что прежняя сетка искала параметр под готовый ответ (12 млрд).
-- Показывать один допуск — тот же дефект.
--
-- GROUPING SETS, а не WITH ROLLUP по двум измерениям: иначе появится строка
-- «сумма по всем допускам», где один и тот же договор посчитан семь раз.
-- CROSS APPLY (VALUES …) стоит ПОСЛЕ фильтра.
-------------------------------------------------------------------------------
SELECT
      g.tolerance_days
    , c.source_system
    , COUNT(*)                                   AS contracts
    , SUM(c.balance_asof)                        AS balance_asof_total
    , SUM(c.balance_asof) / 1e9                  AS balance_bn
    , AVG(c.dpd_avg)                             AS dpd_avg_pool
    , AVG(c.dpd_sd)                              AS dpd_sd_pool
FROM #d15b_contract AS c
CROSS APPLY (VALUES (0), (1), (3), (5), (10), (15), (30)) AS g(tolerance_days)
WHERE c.stage_asof      = '3'
  AND c.has_asof_snap   = 1
  AND c.months_with_dpd = @WindowMonths
  AND c.dpd_max        >= 1                     -- строгое правило не проходит
  AND c.dpd_max        <= g.tolerance_days
GROUP BY GROUPING SETS ((g.tolerance_days, c.source_system), (g.tolerance_days))
ORDER BY g.tolerance_days, GROUPING(c.source_system), balance_asof_total DESC;

-------------------------------------------------------------------------------
-- §3. Г-DPD-1. Разброс просрочки внутри пула кандидатов при допуске 15.
--     ЭТО ГЛАВНАЯ ТАБЛИЦА. Масса в бакетах «0» и «до 1 дня» — просрочка
--     систематическая, работает маршрут C (перенос даты платежа).
--     Размазано по верхним бакетам — допуск поглощает риск.
-------------------------------------------------------------------------------
SELECT
      b.sd_bucket
    , COUNT(*)                                   AS contracts
    , SUM(c.balance_asof) / 1e9                  AS balance_bn
    , AVG(c.dpd_avg)                             AS dpd_avg_pool
    , MIN(c.dpd_max)                             AS dpd_max_min
    , MAX(c.dpd_max)                             AS dpd_max_max
    , SUM(CASE WHEN c.months_overdue = @WindowMonths THEN 1 ELSE 0 END) AS late_every_month
FROM #d15b_contract AS c
CROSS APPLY (VALUES (
        CASE WHEN c.dpd_sd IS NULL THEN '7 — не считается'
             WHEN c.dpd_sd  = 0    THEN '1 — просрочка одна и та же'
             WHEN c.dpd_sd <= 1    THEN '2 — до 1 дня'
             WHEN c.dpd_sd <= 2    THEN '3 — 1-2 дня'
             WHEN c.dpd_sd <= 4    THEN '4 — 2-4 дня'
             WHEN c.dpd_sd <= 8    THEN '5 — 4-8 дней'
             ELSE                       '6 — больше 8 дней'
        END)) AS b(sd_bucket)
WHERE c.stage_asof      = '3'
  AND c.has_asof_snap   = 1
  AND c.months_with_dpd = @WindowMonths
  AND c.dpd_max BETWEEN 1 AND 15
GROUP BY b.sd_bucket
ORDER BY b.sd_bucket;

-------------------------------------------------------------------------------
-- §4. Классификация пула: что лечится переносом даты, а что нет.
--     «Растущие» выделены отдельно: у них смягчение порога не откладывает
--     проблему, а прячет её.
-------------------------------------------------------------------------------
SELECT
      k.class
    , c.source_system
    , COUNT(*)                                   AS contracts
    , SUM(c.balance_asof) / 1e9                  AS balance_bn
    , AVG(c.dpd_avg)                             AS dpd_avg_pool
    , AVG(c.dpd_sd)                              AS dpd_sd_pool
FROM #d15b_contract AS c
CROSS APPLY (VALUES (
        CASE WHEN c.dpd_first IS NOT NULL
                  AND c.dpd_asof - c.dpd_first >= @GrowthDays THEN 'D. растущая — риск'
             WHEN c.dpd_sd <= @StabilityDays
                  AND c.months_overdue >= @WindowMonths - 1   THEN 'A. систематическая — маршрут C'
             WHEN c.dpd_sd <= @StabilityDays                  THEN 'B. стабильная, но не каждый месяц'
             ELSE                                                  'C. рваная — риск'
        END)) AS k(class)
WHERE c.stage_asof      = '3'
  AND c.has_asof_snap   = 1
  AND c.months_with_dpd = @WindowMonths
  AND c.dpd_max BETWEEN 1 AND 15
GROUP BY GROUPING SETS ((k.class, c.source_system), (k.class))
ORDER BY k.class, GROUPING(c.source_system), balance_bn DESC;

/* -----------------------------------------------------------------------------
   §5. ДЕТАЛИЗАЦИЯ — НЕ ВЫКЛАДЫВАЕТСЯ В РЕПОЗИТОРИЙ.
       Номера договоров отнесены к ПДн разделом 2 корневого CLAUDE.md.
       Раскомментировать только для передачи взысканию, файлом, не через git.

   SELECT c.source_system, c.contract_number, c.balance_asof,
          c.dpd_asof, c.dpd_avg, c.dpd_sd, c.dpd_max, c.months_overdue
   FROM #d15b_contract AS c
   WHERE c.stage_asof = '3' AND c.has_asof_snap = 1
     AND c.months_with_dpd = @WindowMonths
     AND c.dpd_max BETWEEN 1 AND 15
     AND c.dpd_sd <= @StabilityDays
   ORDER BY c.balance_asof DESC
   OPTION (MAXDOP 1);
   -----------------------------------------------------------------------------

   ЧТО ЧИТАТЬ В РЕЗУЛЬТАТЕ

   §0  Срезов ровно шесть. Семь — [Р-2] не сработала, дальше не читаем.

   §1  Сколько отсеяно и по какой причине. Большой no_snap_at_asof означает,
       что снимки есть не на все даты — тогда любой прежний расчёт «на @AsOf»
       молча брал чужой месяц.

   §2  Строка tolerance_days = 0 обязана дать НОЛЬ договоров: при нулевом
       допуске кандидатов «застрявших из-за срывов» не бывает по определению
       (dpd_max >= 1). Не ноль — ошибка в фильтре, и результат недействителен.
       Это контроль запроса, а не данных: разрез с заранее известным ответом.

   §3  Главная. Доля пула в бакетах 1 и 2 — размер маршрута C. Колонка
       late_every_month усиливает: опаздывать каждый месяц на одну и ту же
       величину — почерк графика, а не заёмщика.

   §4  Классы A и B — верхняя оценка маршрута C. Классы C и D — то, на чём
       допуск 15 дней действительно работает, и именно их поведение меряет
       ретро-тест Р1-Р8 из GO_NOGO.md.

   ЧЕГО ЭТОТ СКРИПТ НЕ ДОКАЗЫВАЕТ

   1. Разброс на месячных снимках — прокси систематичности, а не она сама.
      Шесть точек на договор; одна пропущенная дата платежа сдвигает картину
      сильнее реального поведения. «Просрочка техническая» доказывается слоем 2:
      сдвигом «факт минус план» по каждому взносу. Здесь получается
      ПРИОРИТИЗАЦИЯ и порядок величины — в этом качестве и предъявляется.

   2. Стадия взята как stage_raw = '3'. Для S03 и карт это `category`,
      и решение от 27.07.2026 гласит, что `category` и есть стадия IFRS —
      но внешнего подтверждения владельца витрины на файле НЕТ.
      Для RS и Fenix это `Basket`, и равенство его семантики `category`
      не доказано вовсе. Если у РБ есть список договоров — правильнее
      подставить его: он и был вариантом (A) в прежнем скрипте, и он же
      закрывает сверку § 7.4 GO_NOGO.md.

   3. Отсечение приостановленных и реструктуризации с приостановкой
      (шаги конвейера § 3 GO_NOGO.md) здесь НЕ сделано — признака отсрочки
      в перечисленных таблицах нет. Пул § 3 и § 4 поэтому шире целевого,
      и это завышение, а не занижение.
   ----------------------------------------------------------------------------- */
