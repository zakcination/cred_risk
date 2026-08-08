/*==============================================================================
  DWH_PROBE_P7_REAL_RATE_COLUMN — где лежит настоящая ставка

  ЗАЧЕМ. Проба P2 показала, что `l_rate` содержит НАЗВАНИЕ КРЕДИТНОЙ ПРОГРАММЫ,
  а не ставку («021 Просто Ипотека (приобретение)», «POS MIDDLE»,
  «Installment with grace»). Ни одна нормализация не даёт ни одной числовой
  строки (P2b: 0 из 8 259 299 по всем четырём вариантам каста). Значит ставки
  в этом поле нет и не было — искать её надо в других колонках.

  МЕТОД. Два батча, разделённых `GO`, намеренно:
    Батч 0 — берёт из INFORMATION_SCHEMA ВСЕ колонки `loans`, похожие на ставку,
             и печатает их фактические имена и типы. Ничего не предполагает.
    Батч 1 — тестирует конвертируемость и диапазон КОНКРЕТНЫХ кандидатов.
  Если имя кандидата не существует, батч 1 не скомпилируется — но батч 0 уже
  отработает и даст верные имена для правки. Порядок именно такой, потому что
  список кандидатов взят из канваса схемы и не подтверждён на этой БД.

  ЧЕГО НЕ ДЕЛАЕМ. Не берём среднюю ставку до аудита конвертируемости — ровно эта
  ошибка сделала E07b пустым и стоила одного прогона (FINDINGS §10.1).

  Правила: только SELECT, MAXDOP 1, без PII. ЗАПУСКАТЬ ЦЕЛИКОМ ОТ ПЕРВОЙ СТРОКИ.
==============================================================================*/

USE [Dictionaries];
SET NOCOUNT ON;

/*==============================================================================
  БАТЧ 0 — ЧТО ВООБЩЕ ЕСТЬ ПОХОЖЕГО НА СТАВКУ (ничего не предполагаем)
==============================================================================*/
SELECT 'L1_PROBES' AS suite, 'P7a_RATE_LIKE_COLUMNS' AS scenario,
       TABLE_NAME, COLUMN_NAME, DATA_TYPE,
       ISNULL(CONVERT(varchar(20), CHARACTER_MAXIMUM_LENGTH), '') AS max_len,
       ISNULL(CONVERT(varchar(20), NUMERIC_PRECISION), '') AS num_precision,
       ISNULL(CONVERT(varchar(20), NUMERIC_SCALE), '') AS num_scale
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'risk_analytics'
  AND TABLE_NAME IN ('loans', 'loans_active', 'loan_account', 'interest_rates')
  AND (COLUMN_NAME LIKE '%rate%'
    OR COLUMN_NAME LIKE '%stavka%'
    OR COLUMN_NAME LIKE '%percent%'
    OR COLUMN_NAME LIKE '%pct%'
    OR COLUMN_NAME LIKE '%aier%'
    OR COLUMN_NAME LIKE '%gesv%'
    OR COLUMN_NAME LIKE '%margin%'
    OR COLUMN_NAME LIKE '%reward%')
ORDER BY TABLE_NAME, COLUMN_NAME
OPTION (MAXDOP 1);

GO

/*==============================================================================
  БАТЧ 1 — КОНВЕРТИРУЕМОСТЬ И ДИАПАЗОН КАНДИДАТОВ

  ЕСЛИ ЭТОТ БАТЧ УПАЛ на «Invalid column name» — возьмите фактические имена из
  вывода батча 0 и поправьте список ниже. Это ожидаемый режим работы пробы,
  а не сбой: список кандидатов не подтверждён на этой базе.
==============================================================================*/
SET NOCOUNT ON;

DECLARE @Suite varchar(60) = 'L1_PROBES';
DECLARE @AsOf  date = (SELECT MAX(l_report_date) FROM [risk_analytics].[loans]);
DECLARE @RateLo decimal(18,6) = 0.0;     -- нижняя граница правдоподобной ставки, %
DECLARE @RateHi decimal(18,6) = 100.0;   -- верхняя граница правдоподобной ставки, %

SELECT @Suite AS suite, '00_SCOPE' AS scenario, @AsOf AS resolved_asof,
       @RateLo AS plausible_low, @RateHi AS plausible_high
OPTION (MAXDOP 1);

/* Заполненность и конвертируемость каждого кандидата — по источникам.
   Кандидат считается «рабочим», если numeric_ok > 0 И значения попадают
   в правдоподобный диапазон. Заполненность без правдоподобия — не ответ:
   поле может быть заполнено кодами. */
SELECT @Suite AS suite, 'P7b_RATE_CANDIDATE_FILL' AS scenario,
       l_source AS source, candidate,
       COUNT_BIG(*) AS rows_total,
       SUM(CASE WHEN raw IS NULL THEN 1 ELSE 0 END) AS is_null,
       SUM(CASE WHEN raw IS NOT NULL AND num IS NULL THEN 1 ELSE 0 END) AS not_numeric,
       SUM(CASE WHEN num IS NOT NULL THEN 1 ELSE 0 END) AS numeric_ok,
       SUM(CASE WHEN num > @RateLo AND num <= @RateHi THEN 1 ELSE 0 END) AS in_plausible_range,
       CAST(MIN(num) AS decimal(18,4)) AS min_val,
       CAST(AVG(num) AS decimal(18,4)) AS avg_val,
       CAST(MAX(num) AS decimal(18,4)) AS max_val
FROM (
    SELECT l.l_source, c.candidate, c.raw,
           TRY_CONVERT(decimal(18,6), c.raw) AS num
    FROM [risk_analytics].[loans] l
    CROSS APPLY (VALUES
        ('l_rate',                CONVERT(nvarchar(255), l.l_rate)),
        ('l_nominal_rate',        CONVERT(nvarchar(255), l.l_nominal_rate)),
        ('l_effective_rate',      CONVERT(nvarchar(255), l.l_effective_rate)),
        ('l_eff_rate',            CONVERT(nvarchar(255), l.l_eff_rate)),
        ('l_reward_rate',         CONVERT(nvarchar(255), l.l_reward_rate))
    ) c(candidate, raw)
    WHERE l.l_report_date = @AsOf
) d
GROUP BY l_source, candidate
ORDER BY candidate, source
OPTION (MAXDOP 1);

/* Вердикт по кандидату: одна строка на поле, чтобы не читать таблицу глазами. */
SELECT @Suite AS suite, 'P7c_RATE_CANDIDATE_VERDICT' AS scenario,
       candidate,
       SUM(rows_total)  AS rows_total,
       SUM(numeric_ok)  AS numeric_ok,
       SUM(in_range)    AS in_plausible_range,
       CAST(100.0 * SUM(in_range) / NULLIF(SUM(rows_total), 0) AS decimal(9,4)) AS usable_pct,
       CASE WHEN SUM(numeric_ok) = 0
                 THEN N'НЕ ЧИСЛО НИ НА ОДНОЙ СТРОКЕ — не ставка'
            WHEN SUM(in_range) = 0
                 THEN N'ЧИСЛО, НО ВНЕ ДИАПАЗОНА СТАВКИ — проверить единицу измерения'
            WHEN 100.0 * SUM(in_range) / NULLIF(SUM(rows_total), 0) >= 90.0
                 THEN N'КАНДИДАТ РАБОЧИЙ — заполнен и правдоподобен'
            ELSE N'ЧАСТИЧНО ЗАПОЛНЕН — годен только на своём подмножестве'
       END AS verdict
FROM (
    SELECT c.candidate,
           COUNT_BIG(*) AS rows_total,
           SUM(CASE WHEN TRY_CONVERT(decimal(18,6), c.raw) IS NOT NULL THEN 1 ELSE 0 END) AS numeric_ok,
           SUM(CASE WHEN TRY_CONVERT(decimal(18,6), c.raw) > @RateLo
                     AND TRY_CONVERT(decimal(18,6), c.raw) <= @RateHi THEN 1 ELSE 0 END) AS in_range
    FROM [risk_analytics].[loans] l
    CROSS APPLY (VALUES
        ('l_rate',                CONVERT(nvarchar(255), l.l_rate)),
        ('l_nominal_rate',        CONVERT(nvarchar(255), l.l_nominal_rate)),
        ('l_effective_rate',      CONVERT(nvarchar(255), l.l_effective_rate)),
        ('l_eff_rate',            CONVERT(nvarchar(255), l.l_eff_rate)),
        ('l_reward_rate',         CONVERT(nvarchar(255), l.l_reward_rate))
    ) c(candidate, raw)
    WHERE l.l_report_date = @AsOf
    GROUP BY c.candidate
) d
GROUP BY candidate
ORDER BY usable_pct DESC
OPTION (MAXDOP 1);

/*==============================================================================
  P7d — ПОБОЧНЫЙ ВЫИГРЫШ ОТ P2: `l_rate` как ПРОДУКТОВОЕ ИЗМЕРЕНИЕ.

  Поле названо неверно, но содержимое ценно: это единственный источник продукта
  для S01/S02/S17 (`l_product_type` у них NULL — бывший T9). Считаем мощность
  измерения: сколько программ у источника и как распределён портфель.
==============================================================================*/
SELECT @Suite AS suite, 'P7d_PRODUCT_DIMENSION_IN_L_RATE' AS scenario,
       l_source AS source,
       COUNT(DISTINCT l_rate) AS distinct_programmes,
       COUNT_BIG(*) AS loans,
       SUM(CASE WHEN l_rate IS NULL THEN 1 ELSE 0 END) AS programme_null,
       SUM(CASE WHEN l_product_type IS NOT NULL THEN 1 ELSE 0 END) AS product_type_filled
FROM [risk_analytics].[loans]
WHERE l_report_date = @AsOf
GROUP BY l_source
ORDER BY source
OPTION (MAXDOP 1);

/* Согласованы ли два измерения там, где заполнены ОБА (только S03).
   Если одна программа ложится строго в один product_type — измерения
   иерархичны, и продукт для остальных источников выводится из программы. */
SELECT @Suite AS suite, 'P7e_PROGRAMME_VS_PRODUCT_TYPE' AS scenario,
       consistency,
       COUNT_BIG(*) AS programmes,
       SUM(loans) AS loans
FROM (
    SELECT l_rate,
           COUNT_BIG(*) AS loans,
           CASE WHEN COUNT(DISTINCT l_product_type) <= 1
                THEN N'программа -> один product_type (иерархия)'
                ELSE N'программа -> НЕСКОЛЬКО product_type (не иерархия)'
           END AS consistency
    FROM [risk_analytics].[loans]
    WHERE l_report_date = @AsOf
      AND l_source = 'S03' AND l_rate IS NOT NULL AND l_product_type IS NOT NULL
    GROUP BY l_rate
) d
GROUP BY consistency
ORDER BY programmes DESC
OPTION (MAXDOP 1);
