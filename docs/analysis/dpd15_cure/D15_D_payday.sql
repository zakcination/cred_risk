/* =============================================================================
   D15-D. Распределение дней платежа по графику
   =============================================================================
   ПРОСТЫМ ЯЗЫКОМ. Проверяем, в какие числа месяца заёмщики должны платить.
   Если дни кучкуются на 5, 10, 15, 20, 25 — а на срезах 1-го числа просрочка
   почти однозначно равна (дней в месяце − день платежа) + 1, — то фильтр
   «DPD не выше 15» отбирает по календарю, а не по риску.

   Источник: [Dictionaries].[risk_analytics].[repayment_schedule].
   Колонки взяты из живой выборки пользователя 27.08.2026 (Н16):
     rs_loan_id, rs_borrower_id, rs_currency, rs_repayment_date,
     rs_principal_repayment_amount, rs_interest_repayment_amount,
     rs_source, rs_dog_num, rs_report_date

   ЧТО ЗДЕСЬ ЕЩЁ НЕ ПРОВЕРЕНО и проверяется § 0:
     * типы колонок (даты могут лежать строками) — везде TRY_CAST;
     * сколько версий графика (rs_report_date) и надо ли брать одну;
     * покрывает ли таблица все шесть источников (rs_source);
     * что является ключом договора — rs_loan_id или rs_dog_num.

   Read-only. Только SELECT, только #temp с префиксом файла.
   T-SQL (Microsoft SQL Server).
   ============================================================================= */

SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#d15d_sched') IS NOT NULL DROP TABLE #d15d_sched;
IF OBJECT_ID('tempdb..#d15d_loan')  IS NOT NULL DROP TABLE #d15d_loan;

-------------------------------------------------------------------------------
-- 0. Параметры
-------------------------------------------------------------------------------
DECLARE @ReportDate date = NULL;   -- версия графика; NULL = взять последнюю
DECLARE @FromDate   date = '2025-07-01';  -- какие взносы смотрим: с этой даты
DECLARE @ToDate     date = '2026-07-01';  -- по эту

-------------------------------------------------------------------------------
-- §0. ПЕРИМЕТР. Прогнать первым и посмотреть глазами до всего остального.
--     Здесь выясняется, сколько версий графика и надо ли фиксировать одну.
-------------------------------------------------------------------------------
SELECT
      TRY_CAST(rs_report_date AS date)                    AS report_date
    , COUNT(*)                                            AS rows_cnt
    , COUNT(DISTINCT rs_loan_id)                          AS loans
    , COUNT(DISTINCT rs_dog_num)                          AS dog_nums
    , MIN(TRY_CAST(rs_repayment_date AS date))            AS min_repay
    , MAX(TRY_CAST(rs_repayment_date AS date))            AS max_repay
    , SUM(CASE WHEN TRY_CAST(rs_repayment_date AS date) IS NULL
               THEN 1 ELSE 0 END)                         AS repay_date_bad
FROM [Dictionaries].[risk_analytics].[repayment_schedule]
GROUP BY TRY_CAST(rs_report_date AS date)
ORDER BY report_date DESC;

-- Источники: покрыты ли все шесть
SELECT rs_source,
       COUNT(*)                     AS rows_cnt,
       COUNT(DISTINCT rs_loan_id)   AS loans,
       COUNT(DISTINCT rs_dog_num)   AS dog_nums
FROM [Dictionaries].[risk_analytics].[repayment_schedule]
GROUP BY rs_source
ORDER BY rows_cnt DESC;

-- Что является ключом: сколько loan_id на dog_num и наоборот.
-- Если оба не 1:1 — соединять с портфелем придётся с оговоркой.
SELECT
      MAX(loans_per_dog)  AS max_loan_id_per_dog_num
    , MAX(dogs_per_loan)  AS max_dog_num_per_loan_id
FROM (
    SELECT COUNT(DISTINCT rs_loan_id) AS loans_per_dog,
           CAST(NULL AS int)            AS dogs_per_loan
    FROM [Dictionaries].[risk_analytics].[repayment_schedule]
    GROUP BY rs_dog_num
    UNION ALL
    SELECT CAST(NULL AS int), COUNT(DISTINCT rs_dog_num)
    FROM [Dictionaries].[risk_analytics].[repayment_schedule]
    GROUP BY rs_loan_id
) AS k;

-------------------------------------------------------------------------------
-- 1. Рабочая выборка: одна версия графика, взносы в окне
-------------------------------------------------------------------------------
IF @ReportDate IS NULL
    SELECT @ReportDate = MAX(TRY_CAST(rs_report_date AS date))
    FROM [Dictionaries].[risk_analytics].[repayment_schedule];

SELECT
      s.rs_source                                          AS src
    , s.rs_loan_id                                         AS loan_id
    , s.rs_dog_num                                         AS dog_num
    , TRY_CAST(s.rs_repayment_date AS date)                AS repay_date
    , DAY(TRY_CAST(s.rs_repayment_date AS date))           AS pay_day
    , COALESCE(TRY_CAST(s.rs_principal_repayment_amount AS decimal(38,2)), 0)
    + COALESCE(TRY_CAST(s.rs_interest_repayment_amount  AS decimal(38,2)), 0)
                                                           AS instal_amount
INTO #d15d_sched
FROM [Dictionaries].[risk_analytics].[repayment_schedule] AS s
WHERE TRY_CAST(s.rs_report_date AS date) = @ReportDate
  AND TRY_CAST(s.rs_repayment_date AS date) >= @FromDate
  AND TRY_CAST(s.rs_repayment_date AS date) <  @ToDate
OPTION (MAXDOP 1);

CREATE CLUSTERED INDEX ix_d15d_sched ON #d15d_sched (loan_id, repay_date);

-------------------------------------------------------------------------------
-- §1. ГЛАВНАЯ ТАБЛИЦА. Гистограмма дня платежа по строкам графика.
--     Ищем пики на 5, 10, 15, 20, 25.
--
--     dpd_if_unpaid — что покажет срез 1-го числа, если взнос не оплачен.
--     Считано для 30-дневного месяца: это иллюстрация связи, а не расчёт.
-------------------------------------------------------------------------------
SELECT
      s.pay_day
    , x.dpd_if_unpaid
    , COUNT(*)                                                        AS instalments
    , COUNT(DISTINCT s.loan_id)                                       AS loans
    , CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS decimal(6,2))  AS pct
    , CASE WHEN x.dpd_if_unpaid BETWEEN 1 AND 15
           THEN 'проходит фильтр <=15' ELSE '' END                    AS passes_filter
FROM #d15d_sched AS s
CROSS APPLY (VALUES (30 - s.pay_day + 1)) AS x(dpd_if_unpaid)
WHERE s.pay_day IS NOT NULL
GROUP BY s.pay_day, x.dpd_if_unpaid
ORDER BY s.pay_day;

-------------------------------------------------------------------------------
-- §2. День платежа на уровне ДОГОВОРА, а не взноса.
--     Берём самый частый день по договору: последний взнос часто выпадает
--     из ритма, и по строкам графика это размывает картину.
-------------------------------------------------------------------------------
SELECT
      d.src
    , d.loan_id
    , d.pay_day_mode
    , d.distinct_days
    , d.instalments
INTO #d15d_loan
FROM (
    -- COUNT(DISTINCT ...) OVER (...) SQL Server НЕ поддерживает — контур
    -- уже спотыкался об это в Т1. Обход: после GROUP BY по (src, loan_id,
    -- pay_day) обычный COUNT(*) OVER (PARTITION BY src, loan_id) считает
    -- число ГРУПП, то есть ровно число различных дней платежа.
    SELECT
          s.src
        , s.loan_id
        , s.pay_day                                             AS pay_day_mode
        , COUNT(*)                                              AS instalments
        , COUNT(*) OVER (PARTITION BY s.src, s.loan_id)         AS distinct_days
        , DENSE_RANK() OVER (PARTITION BY s.src, s.loan_id
                             ORDER BY COUNT(*) DESC, s.pay_day) AS rn
    FROM #d15d_sched AS s
    WHERE s.pay_day IS NOT NULL
    GROUP BY s.src, s.loan_id, s.pay_day
) AS d
WHERE d.rn = 1
OPTION (MAXDOP 1);

SELECT
      l.pay_day_mode                                                  AS pay_day
    , y.dpd_if_unpaid
    , COUNT(*)                                                        AS loans
    , CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS decimal(6,2))  AS pct
    , CAST(100.0 * SUM(COUNT(*)) OVER (ORDER BY l.pay_day_mode)
           / SUM(COUNT(*)) OVER ()                  AS decimal(6,2))  AS pct_cum
FROM #d15d_loan AS l
CROSS APPLY (VALUES (30 - l.pay_day_mode + 1)) AS y(dpd_if_unpaid)
GROUP BY l.pay_day_mode, y.dpd_if_unpaid
ORDER BY l.pay_day_mode;

-------------------------------------------------------------------------------
-- §3. Числовой ответ вместо глазомера: доля «круглых» дней.
--     Если дни платежа распределены равномерно, кратные пяти дадут
--     6 из 30 = 20 %. Существенно больше — кучкование подтверждено.
-------------------------------------------------------------------------------
SELECT
      g.grp
    , COUNT(*)                                                        AS loans
    , CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS decimal(6,2))  AS pct
FROM #d15d_loan AS l
CROSS APPLY (VALUES (
        CASE WHEN l.pay_day_mode % 5 = 0 THEN 'кратен 5'
             ELSE                              'прочие'
        END)) AS g(grp)
GROUP BY g.grp
ORDER BY loans DESC;

-------------------------------------------------------------------------------
-- §4. ПРЯМОЙ ОТВЕТ ПО ИНИЦИАТИВЕ.
--     Сколько договоров при непогашенном взносе попадёт в фильтр «DPD <= 15»
--     просто потому, что день платежа во второй половине месяца.
-------------------------------------------------------------------------------
SELECT
      z.band
    , COUNT(*)                                                        AS loans
    , CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS decimal(6,2))  AS pct
FROM #d15d_loan AS l
CROSS APPLY (VALUES (
        CASE WHEN l.pay_day_mode >= 16 THEN 'день платежа 16-31 -> DPD на срезе 1-15  -> ПРОХОДИТ'
             ELSE                           'день платежа 1-15  -> DPD на срезе 16-31 -> не проходит'
        END)) AS z(band)
GROUP BY z.band
ORDER BY loans DESC;

-------------------------------------------------------------------------------
-- §5. Постоянен ли день платежа внутри договора.
--     Если у большинства он один — формула П3 применима.
--     Много разных дней — график плавающий, и связь слабее.
-------------------------------------------------------------------------------
SELECT
      CASE WHEN l.distinct_days = 1 THEN '1 — день платежа постоянен'
           WHEN l.distinct_days = 2 THEN '2 — два разных дня'
           WHEN l.distinct_days <= 4 THEN '3 — до четырёх'
           ELSE                           '4 — плавающий график'
      END                                                             AS stability
    , COUNT(*)                                                        AS loans
    , CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS decimal(6,2))  AS pct
FROM #d15d_loan AS l
GROUP BY CASE WHEN l.distinct_days = 1 THEN '1 — день платежа постоянен'
              WHEN l.distinct_days = 2 THEN '2 — два разных дня'
              WHEN l.distinct_days <= 4 THEN '3 — до четырёх'
              ELSE                           '4 — плавающий график'
         END
ORDER BY stability;

-------------------------------------------------------------------------------
-- §6. Разрез по источникам: одинаково ли устроены графики.
--     Если у карт дня платежа нет или он другой — П3 к ним неприменима,
--     и их надо считать отдельно.
-------------------------------------------------------------------------------
SELECT
      l.src
    , COUNT(*)                                                       AS loans
    , AVG(CAST(l.pay_day_mode AS float))                             AS pay_day_avg
    , SUM(CASE WHEN l.pay_day_mode >= 16 THEN 1 ELSE 0 END)          AS day_16_31
    , CAST(100.0 * SUM(CASE WHEN l.pay_day_mode >= 16 THEN 1 ELSE 0 END)
           / COUNT(*)                              AS decimal(6,2))  AS pct_16_31
    , SUM(CASE WHEN l.distinct_days = 1 THEN 1 ELSE 0 END)           AS day_constant
FROM #d15d_loan AS l
GROUP BY l.src
ORDER BY loans DESC;

/* -----------------------------------------------------------------------------
   КАК ЧИТАТЬ

   §0  Сколько версий графика. Если rs_report_date много — § 1 считается
       по одной, иначе один договор попадёт в выборку столько раз, сколько
       версий, и гистограмма исказится в пользу долгоживущих договоров.
       Там же: покрывает ли таблица все шесть источников и что за ключ.

   §1  Пики на 5, 10, 15, 20, 25. Есть — кучкование подтверждено.
       Колонка passes_filter показывает, какие дни платежа при непогашенном
       взносе дадут снимочный DPD в диапазоне 1-15.

   §2  То же на уровне договора. Это правильная база для выводов:
       по строкам графика длинные договоры весят больше коротких.

   §3  Доля кратных пяти против ожидаемых 20 %.

   §4  ПРЯМОЙ ОТВЕТ. Доля договоров с днём платежа 16-31 — это верхняя
       оценка того, какую часть портфеля фильтр «DPD <= 15» пропускает
       по календарной причине.

   §5  Постоянство дня. Формула П3 верна при постоянном дне; при плавающем
       графике связь слабее, и это надо знать до выводов.

   §6  По источникам. Карты могут быть устроены иначе — у револьверного
       продукта дня платежа в этом смысле может не быть вовсе.

   ЧЕГО ЭТОТ СКРИПТ НЕ ДОКАЗЫВАЕТ

   Он показывает распределение дней платежа, но не связывает его с фактическим
   снимочным DPD по тем же договорам. Связка — следующий шаг: соединить
   #d15d_loan с портфельным срезом и построить пары (день платежа, DPD).
   Соединение упирается в ключ: rs_loan_id против contract_number
   в портфельных таблицах. Что с чем соединяется, показывает § 0.

   Формула dpd_if_unpaid посчитана для 30-дневного месяца. Это иллюстрация
   связи, а не расчёт: в феврале и в 31-дневных месяцах смещение другое.
   На выводы § 4 это не влияет — граница 16-го числа от длины месяца
   почти не зависит.
   ----------------------------------------------------------------------------- */
