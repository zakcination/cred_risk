/*==============================================================================
  DWH_PROBE_P10 — почему у S02 ноль договоров 90+, и работает ли исключение
  поручительства по S01.

  ПОВОД. H15 (09.08) дал непокрытую экспозицию по S01/S03/S17 и НИ ОДНОЙ строки
  по S02. Это не «мало» — это ноль, подтверждённый арифметикой: шаг 2 отобрал
  43 115 строк, сумма по трём источникам в результате — ровно 43 115. Источник
  с живым портфелем и нулём просрочки 90+ — не чистая книга, а признак того,
  что поле либо не заполнено, либо означает у S02 не то же самое.

  ГИПОТЕЗА A: `days_past_due` у S02 не заполнен (NULL) или тождественно 0.
  ГИПОТЕЗА B: поле заполнено, но обрезано сверху (например, максимум 90) —
    тогда просрочка есть, а признака 90+ по этому полю получить нельзя.
  ГИПОТЕЗА C: у S02 действительно нет 90+ на последнем срезе — тогда
    `delinquency_bucket` тоже должен показывать пусто в старших корзинах.
  Различаются они распределением, поэтому печатается именно оно, а не COUNT.

  P10c закрывает отдельную границу H15 (§16.5 п.4): исключение
  `c_collateral_type IN (N'Поручительство', N'Страховой полис')` сравнивает
  `nvarchar`-литерал с колонкой `varchar(100)`. Если совпадений ноль, исключение
  молча не работает. Проверяется фактическим перечнем значений, а не догадкой.

  Дёшево: только последний срез каждого источника, без истории.
  Правила: только SELECT, `#temp`, MAXDOP 1, без PII, трёхчастные имена.
==============================================================================*/

SET NOCOUNT ON;

DECLARE @Suite varchar(20) = 'P10';

/*------------------------------------------------------------------------------
  Последняя дата КАЖДОГО источника отдельно (T35): у S03 срез на месяц свежее.
------------------------------------------------------------------------------*/
IF OBJECT_ID('tempdb..#p10_srclast') IS NOT NULL DROP TABLE #p10_srclast;
SELECT la_source, MAX(la_reporting_date) AS last_date
INTO #p10_srclast
FROM [Dictionaries].[risk_analytics].[loan_account]
GROUP BY la_source
OPTION (MAXDOP 1);
CREATE CLUSTERED INDEX ix_p10_srclast ON #p10_srclast(la_source);

IF OBJECT_ID('tempdb..#p10_last') IS NOT NULL DROP TABLE #p10_last;
SELECT a.la_source, a.days_past_due, a.delinquency_bucket, a.total_balance_debt
INTO #p10_last
FROM [Dictionaries].[risk_analytics].[loan_account] a
JOIN #p10_srclast k
  ON  k.la_source = a.la_source
  AND k.last_date = a.la_reporting_date
OPTION (MAXDOP 1);

/*==============================================================================
  P10a — РАСПРЕДЕЛЕНИЕ `days_past_due`. NULL — отдельное состояние, не ноль
  (T14): именно смешение этих двух и превращает «нет данных» в «нет просрочки».
==============================================================================*/
SELECT @Suite AS suite, 'P10a_DPD_DISTRIBUTION' AS scenario,
       la_source AS source, dpd_state,
       COUNT_BIG(*) AS contracts,
       CAST(100.0 * COUNT_BIG(*) / SUM(COUNT_BIG(*)) OVER (PARTITION BY la_source)
            AS decimal(9,4)) AS pct_of_source,
       CAST(SUM(ISNULL(total_balance_debt, 0)) AS decimal(38,2)) AS exposure
FROM (
    SELECT la_source, total_balance_debt,
           CASE WHEN days_past_due IS NULL     THEN N'0_NULL (нет данных)'
                WHEN days_past_due <  0        THEN N'1_отрицательный'
                WHEN days_past_due =  0        THEN N'2_ноль'
                WHEN days_past_due <= 30       THEN N'3_1-30'
                WHEN days_past_due <= 60       THEN N'4_31-60'
                WHEN days_past_due <= 90       THEN N'5_61-90'
                WHEN days_past_due <= 180      THEN N'6_91-180'
                WHEN days_past_due <= 360      THEN N'7_181-360'
                ELSE                                N'8_360+'
           END AS dpd_state
    FROM #p10_last
) x
GROUP BY la_source, dpd_state
ORDER BY source, dpd_state
OPTION (MAXDOP 1);

/*==============================================================================
  P10b — ГРАНИЦЫ ПОЛЯ. Если у S02 максимум ровно 90 (или иное круглое число) —
  поле обрезано сверху, и признак 90+ из него не извлекается в принципе.
==============================================================================*/
SELECT @Suite AS suite, 'P10b_DPD_RANGE' AS scenario,
       la_source AS source,
       COUNT_BIG(*) AS contracts,
       SUM(CASE WHEN days_past_due IS NULL THEN 1 ELSE 0 END) AS dpd_null,
       MIN(days_past_due) AS dpd_min,
       MAX(days_past_due) AS dpd_max,
       COUNT(DISTINCT days_past_due) AS distinct_values
FROM #p10_last
GROUP BY la_source
ORDER BY source
OPTION (MAXDOP 1);

/*==============================================================================
  P10c — ЧТО ГОВОРИТ `delinquency_bucket` там, где `days_past_due` молчит.
  H02c уже показал, что эти два поля расходятся (S01: 3 119 договоров в
  корзине 1 при DPD-классе 90+). Здесь вопрос уже: даёт ли корзина по S02 то,
  чего не даёт DPD. Если да — регуляторный признак 90+ у источников строится
  по РАЗНЫМ полям, и это дефект, а не выбор методики.
==============================================================================*/
SELECT @Suite AS suite, 'P10c_BUCKET_VS_DPD' AS scenario,
       la_source AS source,
       ISNULL(CONVERT(varchar(20), delinquency_bucket), 'NULL') AS bucket,
       COUNT_BIG(*) AS contracts,
       SUM(CASE WHEN days_past_due IS NULL THEN 1 ELSE 0 END) AS with_dpd_null,
       SUM(CASE WHEN days_past_due > 90 THEN 1 ELSE 0 END)    AS with_dpd_over_90,
       MAX(days_past_due) AS dpd_max_in_bucket
FROM #p10_last
GROUP BY la_source, delinquency_bucket
ORDER BY source, bucket
OPTION (MAXDOP 1);

/*==============================================================================
  P10d — ФАКТИЧЕСКИЕ ЗНАЧЕНИЯ `c_collateral_type`. Закрывает границу §16.5 п.4:
  сработало ли исключение поручительства и страховки по S01, или сравнение
  `varchar` с `nvarchar`-литералом молча не нашло совпадений.
  Значения печатаются как есть, без нормализации — вопрос именно в том, что
  лежит в поле.
==============================================================================*/
SELECT @Suite AS suite, 'P10d_COLLATERAL_TYPES' AS scenario,
       c_source AS source, c_collateral_type,
       COUNT_BIG(*) AS rows_cnt,
       CAST(SUM(ISNULL(c_collateral_value, 0)) AS decimal(38,2)) AS value_sum,
       CASE WHEN c_collateral_type IN (N'Поручительство', N'Страховой полис')
            THEN N'ИСКЛЮЧАЕТСЯ в H15' ELSE N'' END AS h15_rule
FROM [Dictionaries].[risk_analytics].[pledges]
WHERE c_reporting_date = (SELECT MAX(c_reporting_date)
                          FROM [Dictionaries].[risk_analytics].[pledges])
GROUP BY c_source, c_collateral_type
ORDER BY source, rows_cnt DESC
OPTION (MAXDOP 1);

/*------------------------------------------------------------------------------
  УБОРКА — строго после последнего обращения к таблицам.
------------------------------------------------------------------------------*/
IF OBJECT_ID('tempdb..#p10_srclast') IS NOT NULL DROP TABLE #p10_srclast;
IF OBJECT_ID('tempdb..#p10_last')    IS NOT NULL DROP TABLE #p10_last;
