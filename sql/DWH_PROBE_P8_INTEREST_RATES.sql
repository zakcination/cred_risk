/*==============================================================================
  DWH_PROBE_P8_INTEREST_RATES — паспорт таблицы ставок

  ЗАЧЕМ. P7a закрыл вопрос «где ставка»: в `loans` числовой ставки НЕТ ВООБЩЕ.
  Из полей, похожих на ставку, там только `l_rate` varchar(255) (= название
  программы, P2c) и `l_reward_rate_type` varchar(255). Настоящие ставки живут
  в отдельной таблице `risk_analytics.interest_rates`:

      report_date            date
      dlcr_dog_num           nvarchar(35)   -- ключ
      [dlcr$source]          nvarchar(3)
      loan_id                bigint         -- fk
      interest_rate          numeric(17,2)
      initial_nominal_rate   numeric(17,2)
      effective_rate         numeric(18,9)  -- ГЭСВ/APR (то, что аналитики зовут AIER)
      initial_effective_rate numeric(17,2)

  ПОЧЕМУ ЭТО НЕ «ПРОСТО ВЗЯТЬ СТАВКУ». Таблица до сих пор числилась в разделе
  «что набор НЕ покрывает» (DWH_TEST_SCENARIOS.md): у неё нет ни дубль-чека,
  ни проверки покрытия. Ставку нельзя присоединять к портфелю, пока не доказаны
  четыре вещи — их и проверяет проба:
    A. населённость и СЕТКА ДАТ по источникам (урок P1: общий @AsOf оставил
       один S03 и это выглядело как «данных нет»);
    B. grain — одна ли строка на договор, или ставка размножит суммы при JOIN;
    C. рабочий ключ ПО ПОКРЫТИЮ. Gid-колонки у таблицы НЕТ, то есть канонический
       путь `*_gid = l_gid` недоступен. Кандидаты — `loan_id` (bigint) и
       `dlcr_dog_num` (nvarchar). Имени колонки не верим: `la_loan_id` тоже
       звучал как ключ и дал 0 совпадений по S03 (T2);
    D. ЕДИНИЦА ИЗМЕРЕНИЯ. `effective_rate` объявлен numeric(18,9), а три
       остальных — (17,2). Разная шкала — сигнал, что одно поле хранит долю
       (0.185), а другие проценты (18.50). Смешать их в одном отчёте = ошибка
       в 100 раз.

  БЕЗОПАСНОСТЬ ДЖОЙНА. `loan_id` bigint ↔ `l_loan_id` nvarchar (T4). Приведение
  типа делается ОДИН РАЗ в индексированный #temp, дальше сравниваются голые
  bigint. Обратный порядок (CAST на внутренней стороне коррелированного
  подзапроса) дважды вешал прогон на 2+ часа — L11.1 и L4.1.

  Правила: только SELECT, MAXDOP 1, без PII (номера договоров не выводятся —
  только счётчики). ЗАПУСКАТЬ ЦЕЛИКОМ ОТ ПЕРВОЙ СТРОКИ.
==============================================================================*/

USE [Dictionaries];
SET NOCOUNT ON;

DECLARE @Suite varchar(60) = 'L1_PROBES';
DECLARE @AsOf  date = (SELECT MAX(l_report_date) FROM [risk_analytics].[loans]);
/* Границы правдоподобия НЕ хардкодим в теле — параметры (CLAUDE.md). */
DECLARE @PctLo decimal(18,9) = 0.5;    -- ниже этого «процент» неправдоподобен
DECLARE @PctHi decimal(18,9) = 100.0;  -- выше — либо доля*10000, либо мусор

SELECT @Suite AS suite, '00_SCOPE' AS scenario, @AsOf AS loans_asof,
       @PctLo AS pct_low, @PctHi AS pct_high
OPTION (MAXDOP 1);


/*==============================================================================
  A — НАСЕЛЁННОСТЬ И СЕТКА ДАТ. Первым делом, до любых джойнов (урок P1).
==============================================================================*/
SELECT @Suite AS suite, 'P8a_RATES_DATE_SPACE' AS scenario,
       [dlcr$source] AS source,
       COUNT_BIG(*) AS rows_total,
       COUNT(DISTINCT report_date) AS distinct_dates,
       MIN(report_date) AS min_date,
       MAX(report_date) AS max_date,
       SUM(CASE WHEN report_date = @AsOf THEN 1 ELSE 0 END) AS rows_at_loans_asof
FROM [risk_analytics].[interest_rates]
GROUP BY [dlcr$source]
ORDER BY source
OPTION (MAXDOP 1);


/*==============================================================================
  B — GRAIN. Сколько строк на один договор в пределах одной даты.

  Считаем на СЫРОМ уровне: число групп против суммы размеров групп. Внешний
  COUNT над уже сгруппированным набором был бы тавтологией — подзапрос
  физически не может вернуть больше одной строки на ключ (CLAUDE.md, PR #14).
==============================================================================*/
SELECT @Suite AS suite, 'P8b_RATES_GRAIN' AS scenario,
       source, report_date, key_used,
       COUNT_BIG(*) AS keys_duplicated,
       SUM(rows_in_group) AS rows_affected,
       SUM(rows_in_group) - COUNT_BIG(*) AS excess_rows,
       MAX(rows_in_group) AS max_rows_per_key
FROM (
    SELECT [dlcr$source] AS source, report_date, 'loan_id' AS key_used,
           COUNT_BIG(*) AS rows_in_group
    FROM [risk_analytics].[interest_rates]
    WHERE loan_id IS NOT NULL
    GROUP BY [dlcr$source], report_date, loan_id
    HAVING COUNT_BIG(*) > 1
    UNION ALL
    SELECT [dlcr$source], report_date, 'dlcr_dog_num',
           COUNT_BIG(*)
    FROM [risk_analytics].[interest_rates]
    WHERE dlcr_dog_num IS NOT NULL
    GROUP BY [dlcr$source], report_date, dlcr_dog_num
    HAVING COUNT_BIG(*) > 1
) d
GROUP BY source, report_date, key_used
ORDER BY key_used, source, report_date DESC
OPTION (MAXDOP 1);


/*==============================================================================
  C — РАБОЧИЙ КЛЮЧ ПО ПОКРЫТИЮ. Имени колонки не верим.

  Приведение типов — один раз в #temp, дальше голые сравнения.
==============================================================================*/
IF OBJECT_ID('tempdb..#loan_keys') IS NOT NULL DROP TABLE #loan_keys;
SELECT l_source, l_gid,
       TRY_CONVERT(bigint, l_loan_id) AS loan_id_bigint,
       l_loan_number
INTO #loan_keys
FROM [risk_analytics].[loans]
WHERE l_report_date = @AsOf
OPTION (MAXDOP 1);
CREATE CLUSTERED INDEX ix_lk_loanid ON #loan_keys(loan_id_bigint);
CREATE INDEX ix_lk_num ON #loan_keys(l_loan_number);

/* Сначала — сколько вообще l_loan_id приводится к bigint. Если мало,
   нулевое покрытие ниже будет означать сбой каста, а не отсутствие связи. */
SELECT @Suite AS suite, 'P8c_LOAN_ID_CASTABILITY' AS scenario,
       l_source AS source,
       COUNT_BIG(*) AS loans_total,
       SUM(CASE WHEN loan_id_bigint IS NULL THEN 1 ELSE 0 END) AS cast_failed_or_null
FROM #loan_keys
GROUP BY l_source
ORDER BY source
OPTION (MAXDOP 1);

/* Покрытие каждого кандидата — в разрезе источника, не усреднённо: у S03
   именно посточниковый разрез вскрыл нулевой матч по la_loan_id (T2). */
SELECT @Suite AS suite, 'P8d_RATES_KEY_COVERAGE' AS scenario,
       key_tested, source, rate_rows, matched_rows,
       CAST(100.0 * matched_rows / NULLIF(rate_rows, 0) AS decimal(9,4)) AS match_pct,
       CASE WHEN matched_rows = 0 THEN N'НЕ РАБОТАЕТ — связь не строить'
            WHEN 100.0 * matched_rows / NULLIF(rate_rows, 0) >= 95.0
                 THEN N'РАБОЧИЙ КЛЮЧ'
            ELSE N'ЧАСТИЧНЫЙ — годен только на подмножестве' END AS verdict
FROM (
    SELECT 'loan_id -> l_loan_id' AS key_tested,
           r.[dlcr$source] AS source,
           COUNT_BIG(*) AS rate_rows,
           SUM(CASE WHEN k.loan_id_bigint IS NOT NULL THEN 1 ELSE 0 END) AS matched_rows
    FROM [risk_analytics].[interest_rates] r
    LEFT JOIN (SELECT DISTINCT loan_id_bigint FROM #loan_keys
               WHERE loan_id_bigint IS NOT NULL) k
           ON k.loan_id_bigint = r.loan_id
    GROUP BY r.[dlcr$source]
    UNION ALL
    SELECT 'dlcr_dog_num -> l_loan_number',
           r.[dlcr$source],
           COUNT_BIG(*),
           SUM(CASE WHEN n.l_loan_number IS NOT NULL THEN 1 ELSE 0 END)
    FROM [risk_analytics].[interest_rates] r
    LEFT JOIN (SELECT DISTINCT l_loan_number FROM #loan_keys
               WHERE l_loan_number IS NOT NULL) n
           ON n.l_loan_number = r.dlcr_dog_num
    GROUP BY r.[dlcr$source]
) d
ORDER BY key_tested, source
OPTION (MAXDOP 1);


/*==============================================================================
  D — ЕДИНИЦА ИЗМЕРЕНИЯ. Главный вопрос: доля или процент.

  Раскладываем каждое из четырёх полей по диапазонам. Поле, у которого масса
  сидит в «<= 1», хранит ДОЛЮ; в «0.5–100» — ПРОЦЕНТ. Смешение = ошибка ×100.
==============================================================================*/
SELECT @Suite AS suite, 'P8e_RATE_UNIT_AUDIT' AS scenario,
       source, rate_field, value_bucket, rows_cnt
FROM (
    SELECT r.[dlcr$source] AS source, c.rate_field,
           CASE WHEN c.v IS NULL          THEN N'(NULL)'
                WHEN c.v < 0              THEN N'ОТРИЦАТЕЛЬНАЯ (АНОМАЛИЯ)'
                WHEN c.v = 0              THEN N'0'
                WHEN c.v <= 1             THEN N'(0;1] — похоже на ДОЛЮ'
                WHEN c.v < @PctLo         THEN N'(1;порог) — неоднозначно'
                WHEN c.v <= @PctHi        THEN N'[порог;100] — похоже на ПРОЦЕНТ'
                ELSE                           N'>100 (АНОМАЛИЯ ИЛИ ДРУГАЯ ШКАЛА)'
           END AS value_bucket,
           COUNT_BIG(*) AS rows_cnt
    FROM [risk_analytics].[interest_rates] r
    CROSS APPLY (VALUES
        ('interest_rate',          CONVERT(decimal(18,9), r.interest_rate)),
        ('initial_nominal_rate',   CONVERT(decimal(18,9), r.initial_nominal_rate)),
        ('effective_rate',         CONVERT(decimal(18,9), r.effective_rate)),
        ('initial_effective_rate', CONVERT(decimal(18,9), r.initial_effective_rate))
    ) c(rate_field, v)
    GROUP BY r.[dlcr$source], c.rate_field,
           CASE WHEN c.v IS NULL          THEN N'(NULL)'
                WHEN c.v < 0              THEN N'ОТРИЦАТЕЛЬНАЯ (АНОМАЛИЯ)'
                WHEN c.v = 0              THEN N'0'
                WHEN c.v <= 1             THEN N'(0;1] — похоже на ДОЛЮ'
                WHEN c.v < @PctLo         THEN N'(1;порог) — неоднозначно'
                WHEN c.v <= @PctHi        THEN N'[порог;100] — похоже на ПРОЦЕНТ'
                ELSE                           N'>100 (АНОМАЛИЯ ИЛИ ДРУГАЯ ШКАЛА)'
           END
) d
ORDER BY rate_field, source, rows_cnt DESC
OPTION (MAXDOP 1);

/* Диапазоны рядом — чтобы шкала читалась одним взглядом, а не по бакетам. */
SELECT @Suite AS suite, 'P8f_RATE_RANGES' AS scenario,
       [dlcr$source] AS source,
       COUNT_BIG(*) AS rows_total,
       CAST(MIN(interest_rate) AS decimal(18,4))          AS ir_min,
       CAST(AVG(interest_rate) AS decimal(18,4))          AS ir_avg,
       CAST(MAX(interest_rate) AS decimal(18,4))          AS ir_max,
       CAST(MIN(effective_rate) AS decimal(18,6))         AS eff_min,
       CAST(AVG(effective_rate) AS decimal(18,6))         AS eff_avg,
       CAST(MAX(effective_rate) AS decimal(18,6))         AS eff_max,
       CAST(MIN(initial_nominal_rate) AS decimal(18,4))   AS init_nom_min,
       CAST(MAX(initial_nominal_rate) AS decimal(18,4))   AS init_nom_max,
       CAST(MIN(initial_effective_rate) AS decimal(18,4)) AS init_eff_min,
       CAST(MAX(initial_effective_rate) AS decimal(18,4)) AS init_eff_max
FROM [risk_analytics].[interest_rates]
GROUP BY [dlcr$source]
ORDER BY source
OPTION (MAXDOP 1);

/* Внутренняя когерентность: ГЭСВ (APR) должен быть НЕ НИЖЕ номинальной ставки,
   потому что включает комиссии. Нарушение — либо разные шкалы, либо дефект. */
SELECT @Suite AS suite, 'P8g_EFFECTIVE_VS_NOMINAL' AS scenario,
       source, relation, rows_cnt
FROM (
    SELECT [dlcr$source] AS source,
           CASE WHEN effective_rate IS NULL OR interest_rate IS NULL
                     THEN N'нет одной из ставок'
                WHEN effective_rate >= interest_rate THEN N'ГЭСВ >= номинальной (ожидаемо)'
                ELSE N'ГЭСВ НИЖЕ номинальной (шкалы разные либо дефект)'
           END AS relation,
           COUNT_BIG(*) AS rows_cnt
    FROM [risk_analytics].[interest_rates]
    GROUP BY [dlcr$source],
           CASE WHEN effective_rate IS NULL OR interest_rate IS NULL
                     THEN N'нет одной из ставок'
                WHEN effective_rate >= interest_rate THEN N'ГЭСВ >= номинальной (ожидаемо)'
                ELSE N'ГЭСВ НИЖЕ номинальной (шкалы разные либо дефект)'
           END
) d
ORDER BY source, rows_cnt DESC
OPTION (MAXDOP 1);


/*==============================================================================
  E — ПОКРЫТИЕ ПОРТФЕЛЯ. Сколько АКТИВНЫХ договоров получат ставку.
  Джойн по тому ключу, который окажется рабочим в P8d — здесь считаем по
  loan_id; если P8d покажет, что рабочий ключ другой, повторить с ним.
==============================================================================*/
SELECT @Suite AS suite, 'P8h_ACTIVE_PORTFOLIO_RATE_COVERAGE' AS scenario,
       l.l_source AS source,
       COUNT_BIG(*) AS active_loans,
       SUM(CASE WHEN r.loan_id IS NOT NULL THEN 1 ELSE 0 END) AS loans_with_rate,
       CAST(100.0 * SUM(CASE WHEN r.loan_id IS NOT NULL THEN 1 ELSE 0 END)
            / NULLIF(COUNT_BIG(*), 0) AS decimal(9,4)) AS rate_coverage_pct
FROM (
    SELECT l_source, TRY_CONVERT(bigint, l_loan_id) AS loan_id_bigint
    FROM [risk_analytics].[loans_active]
    WHERE l_report_date = @AsOf
) l
LEFT JOIN (
    SELECT DISTINCT loan_id FROM [risk_analytics].[interest_rates]
    WHERE loan_id IS NOT NULL
) r ON r.loan_id = l.loan_id_bigint
GROUP BY l.l_source
ORDER BY source
OPTION (MAXDOP 1);

IF OBJECT_ID('tempdb..#loan_keys') IS NOT NULL DROP TABLE #loan_keys;
