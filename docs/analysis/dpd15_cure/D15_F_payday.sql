/* =============================================================================
   D15-F. День платежа: восстановление, диагноз, целевая дата для переноса.

   ЗАЧЕМ. По пулу устойчивого DPD (D15-E) нужно решить, на какое число
   переносить платёж. Для этого надо знать три вещи:
     1) какой день платежа у заёмщика сейчас;
     2) какие числа месяца в портфеле дают наименьшую просрочку;
     3) укладывается ли перенос в исключение № 61 определения 12.

   КЛЮЧЕВОЕ СООТНОШЕНИЕ, ПОДТВЕРЖДЁННОЕ ПРОГОНОМ 27.08.2026.
   При непогашенном взносе снимочный DPD однозначно определяется днём платежа:

        DPD(срез) = дней_в_предыдущем_месяце − день_платежа + 1
        день_платежа = дней_в_предыдущем_месяце − DPD(срез) + 1

   Проверено на фактических группах из выдачи D15-E — совпадение точное:

     наблюдённый диапазон DPD | восстановленный день платежа
        4 … 7                 |  25
        6 … 9                 |  23
        7 … 10                |  22
        8 … 11                |  21
        9 … 12                |  20
       11 … 14                |  18
       14 … 17                |  15
       21 … 24                |   8

   Разброс 1-3 внутри группы — это НЕ разброс поведения заёмщика. Это одна
   и та же платёжная дата, наблюдаемая после месяцев разной длины: февраль
   даёт минимум диапазона, 31-дневные месяцы — максимум. Разброс 1 вместо 3
   означает, что февральский срез в окно не попал.

   СЛЕДСТВИЕ ДЛЯ ЗАДАЧИ. Уровень DPD в этом пуле измеряет день платежа,
   а не глубину проблемы. Заёмщик с DPD 4-7 и заёмщик с DPD 14-17 опаздывают
   ОДИНАКОВО — просто у первого платёж 25-го, у второго 15-го.

   Read-only. Только SELECT. #temp с префиксом D15F_. MAXDOP 1.
   Требует выполненного D15-E в том же окне (используются #D15E_panel, #D15E_best).
   T-SQL (Microsoft SQL Server).
   ============================================================================= */

SET NOCOUNT ON;

DECLARE @AsOf    date = '2026-08-01';
DECLARE @Months  int  = 6;
DECLARE @MaxMove int  = 29;   -- № 61 опр. 12: перенос МЕНЕЕ 30 календарных дней

DECLARE @From date = DATEADD(MONTH, -(@Months - 1), @AsOf);


/* =============================================================================
   § 1. ВОССТАНОВЛЕНИЕ ДНЯ ПЛАТЕЖА ПО КАЖДОМУ СРЕЗУ.
        Если заёмщик в чистом перекате, восстановленный день ОДИНАКОВ на всех
        срезах. Разброс восстановленного дня — вот это уже поведение.
   ============================================================================= */

IF OBJECT_ID('tempdb..#D15F_payday') IS NOT NULL DROP TABLE #D15F_payday;

SELECT
      p.account_number
    , p.snap_date
    , p.dpd
    , DAY(EOMONTH(DATEADD(MONTH, -1, p.snap_date))) AS days_in_prev_month
    , DAY(EOMONTH(DATEADD(MONTH, -1, p.snap_date))) - p.dpd + 1 AS pay_day_est
INTO #D15F_payday
FROM #D15E_panel p
WHERE p.dpd IS NOT NULL
  AND p.dpd > 0
  AND p.dpd < 30
OPTION (MAXDOP 1);

CREATE CLUSTERED INDEX ix_D15F_payday ON #D15F_payday(account_number, snap_date);


/* =============================================================================
   § 2. ДИАГНОЗ ПО КАЖДОМУ ДОГОВОРУ.
        pay_day_spread — вот настоящая дисперсия поведения.
        0  = день платежа не менялся, заёмщик стабильно опаздывает на один цикл
        >0 = поверх переката есть реальные эпизоды либо график менялся
   ============================================================================= */

IF OBJECT_ID('tempdb..#D15F_diag') IS NOT NULL DROP TABLE #D15F_diag;

SELECT
      f.account_number
    , COUNT(*)                                    AS months_obs
    , MIN(f.pay_day_est)                          AS pay_day_min
    , MAX(f.pay_day_est)                          AS pay_day_max
    , MAX(f.pay_day_est) - MIN(f.pay_day_est)     AS pay_day_spread
    , MIN(f.dpd)                                  AS dpd_min
    , MAX(f.dpd)                                  AS dpd_max
INTO #D15F_diag
FROM #D15F_payday f
GROUP BY f.account_number
OPTION (MAXDOP 1);

-- 2a. Сводка диагнозов. Ожидание: подавляющая часть пула D15-E имеет
--     pay_day_spread = 0, и это доказывает перекат поимённо.
SELECT
      CASE WHEN pay_day_spread = 0 THEN '0  чистый перекат, дата не менялась'
           WHEN pay_day_spread <= 2 THEN '1-2  перекат с шумом округления'
           WHEN pay_day_spread <= 5 THEN '3-5  есть реальные эпизоды'
           ELSE '6+  нестабильно, переносом даты не лечится' END AS diagnosis
    , COUNT(*)                                    AS accounts
    , MIN(months_obs)                             AS min_months_obs
FROM #D15F_diag
GROUP BY
      CASE WHEN pay_day_spread = 0 THEN '0  чистый перекат, дата не менялась'
           WHEN pay_day_spread <= 2 THEN '1-2  перекат с шумом округления'
           WHEN pay_day_spread <= 5 THEN '3-5  есть реальные эпизоды'
           ELSE '6+  нестабильно, переносом даты не лечится' END
ORDER BY diagnosis
OPTION (MAXDOP 1);

-- 2b. Какие числа месяца дают проблемный пул. Это «откуда» переносим.
SELECT
      pay_day_min                                 AS pay_day
    , COUNT(*)                                    AS accounts
    , SUM(CASE WHEN pay_day_spread = 0 THEN 1 ELSE 0 END) AS pure_roll
FROM #D15F_diag
GROUP BY pay_day_min
ORDER BY accounts DESC
OPTION (MAXDOP 1);


/* =============================================================================
   § 3. КУДА ПЕРЕНОСИТЬ. Эмпирический ответ, а не догадка о зарплате.
        Считаем по ВСЕМУ портфелю долю договоров с просрочкой в разрезе дня
        платежа. Числа с наименьшей долей и есть кандидаты.

        ОГРАНИЧЕНИЕ, КОТОРОЕ НАДО НАЗВАТЬ: § 1 восстанавливает день платежа
        только у ПРОСРОЧЕННЫХ. У договора с DPD = 0 день платежа из просрочки
        не выводится. Значит знаменатель отсюда взять нельзя, и § 3 требует
        [Dictionaries].[risk_analytics].[repayment_schedule].

        Запускать ПОСЛЕ § 0 в D15_D_payday.sql — там выясняется, что является
        ключом договора (rs_loan_id или rs_dog_num) и сколько версий графика
        лежит в rs_report_date.

        Заготовка, подставить подтверждённый ключ:

        SELECT
              DAY(TRY_CAST(sch.rs_repayment_date AS date))        AS pay_day
            , COUNT(*)                                            AS loans
            , SUM(CASE WHEN p.dpd > 0 THEN 1 ELSE 0 END)          AS delinquent
            , CAST(100.0 * SUM(CASE WHEN p.dpd > 0 THEN 1 ELSE 0 END)
                   / NULLIF(COUNT(*),0) AS decimal(5,2))          AS delinquency_pct
        FROM [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2] p
        INNER JOIN (…подтверждённый график…) sch
                ON sch.<ключ> = p.contract_number
        WHERE p.[date] = @AsOf
          AND ISNULL(p.[tag],'') <> '11'
        GROUP BY DAY(TRY_CAST(sch.rs_repayment_date AS date))
        ORDER BY delinquency_pct ASC;

        Читать так: числа с минимальной delinquency_pct — рабочие даты
        портфеля. Они же косвенно показывают, когда в среднем приходит доход,
        без запроса зарплатных данных.
   ============================================================================= */


/* =============================================================================
   § 4. ЦЕЛЕВАЯ ДАТА С УЧЁТОМ ОГРАНИЧЕНИЯ НОРМЫ.
        № 61 определение 12 выводит из реструктуризации перенос даты платежа
        «в рамках того же месяца менее чем на 30 календарных дней, если это
        предусмотрено условиями договора».

        Два условия проверяются здесь. Третье — оговорка договора, В-DPD-9,
        блокирующий, и данными не проверяется вовсе.

        @TargetDay подставляется из § 3 после его прогона. До этого § 4
        показывает только допустимость сдвига, не его целесообразность.
   ============================================================================= */

DECLARE @TargetDay int = 5;   -- ЗАГЛУШКА. Заменить результатом § 3.

SELECT
      d.pay_day_min                               AS pay_day_now
    , @TargetDay                                  AS pay_day_target
    , ABS(@TargetDay - d.pay_day_min)             AS move_days
    , CASE WHEN ABS(@TargetDay - d.pay_day_min) < 30
           THEN 'в исключение укладывается по сроку'
           ELSE 'СДВИГ 30+ ДНЕЙ — реструктуризация со всеми последствиями' END AS norm_check
    , COUNT(*)                                    AS accounts
FROM #D15F_diag d
WHERE d.pay_day_spread = 0        -- переносом лечится только чистый перекат
GROUP BY d.pay_day_min
ORDER BY accounts DESC
OPTION (MAXDOP 1);


/* =============================================================================
   § 5. ПОДТВЕРЖДЕНИЕ СОДЕРЖИМОГО ПОМЕСЯЧНОЙ СЕТКИ БАЗЫ ДЕФОЛТОВ.

        § 0f в D15-E сверял колонку с category и дал неоднозначную картину:
        значение 0 стоит и при category 1, и при 3; значения 7, 9, 37 — тоже.
        Это поведение НЕ категории, а величины. Сверка с dpd решает вопрос
        однозначно и делается одним запросом.

        Если совпадение высокое — сетка есть помесячный DPD за 181 месяц,
        и выгрузка В1 из DATA_REQUEST.md по просрочке НЕ НУЖНА: история
        глубиной 15 лет уже лежит в базе.
   ============================================================================= */

SELECT
      COUNT(*)                                                        AS matched_rows
    , SUM(CASE WHEN TRY_CAST(h.['01.08.2026'] AS int) = p.dpd
               THEN 1 ELSE 0 END)                                     AS equal_to_dpd
    , SUM(CASE WHEN TRY_CAST(h.['01.08.2026'] AS int) = p.category
               THEN 1 ELSE 0 END)                                     AS equal_to_category
    , SUM(CASE WHEN h.['01.08.2026'] IS NULL THEN 1 ELSE 0 END)       AS base_null
    , SUM(CASE WHEN h.['01.08.2026'] IS NOT NULL
                AND TRY_CAST(h.['01.08.2026'] AS int) IS NULL
               THEN 1 ELSE 0 END)                                     AS base_unparsable
FROM [CL_PORTFOLIO].[dbo].[HISTORY_DEFAULT_ACCOUNT] h
INNER JOIN [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2] p
        ON p.contract_number = h.account_number
       AND p.[date] = '2026-08-01'
OPTION (MAXDOP 1);

-- Контроль на второй дате: одно совпадение может быть случайным.
SELECT
      COUNT(*)                                                        AS matched_rows
    , SUM(CASE WHEN TRY_CAST(h.['01.05.2026'] AS int) = p.dpd
               THEN 1 ELSE 0 END)                                     AS equal_to_dpd
FROM [CL_PORTFOLIO].[dbo].[HISTORY_DEFAULT_ACCOUNT] h
INNER JOIN [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2] p
        ON p.contract_number = h.account_number
       AND p.[date] = '2026-05-01'
OPTION (MAXDOP 1);
