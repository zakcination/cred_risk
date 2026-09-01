/*==============================================================================
  DWH_SCENARIOS_L1_FOLLOWUP_PROBES — P1..P6
  ------------------------------------------------------------------------------
  Назначение: прогон L1 (E01–E35, 08.08.2026) дал шесть результатов, которые
  НЕЛЬЗЯ трактовать без дополнительной пробы. Каждая проба разводит ровно две
  гипотезы и рассчитана на один короткий прогон. Разбор — FINDINGS.md §10.9.

  Правила (CLAUDE.md): только SELECT, MAXDOP 1, без PII, даты/пороги — параметры.
  ЗАПУСКАТЬ ЦЕЛИКОМ ОТ ПЕРВОЙ СТРОКИ: частичное выделение теряет DECLARE (Msg 137).
==============================================================================*/

SET NOCOUNT ON;

DECLARE @Suite   sysname = N'L1_PROBES';
DECLARE @AsOf    date    = (SELECT MAX(l_report_date) FROM [Dictionaries].[risk_analytics].[loans]);
DECLARE @MinCnt  bigint  = 100;    -- P2: не показывать значения реже этого (шум/уникаты)
DECLARE @BigAmt  decimal(38,2) = 1000000000.00;  -- P6: порог «крупная сумма», 1 млрд ₸

SELECT @Suite AS suite, '00_SCOPE' AS scenario, @AsOf AS resolved_asof,
       @MinCnt AS min_value_count, @BigAmt AS big_amount_threshold
OPTION (MAXDOP 1);


/*==============================================================================
  P1 — Календарь loan_account по источникам.
  Гипотеза A: у источников РАЗНЫЕ сетки la_reporting_date (тогда «только S03»
              на 2026-08-01 — артефакт даты, как было с 2026-07-01).
  Гипотеза B: S01/S02/S17 в таблице отсутствуют вовсе.
  Разводится: если у источника есть хоть одна дата — верна A.
==============================================================================*/
SELECT @Suite AS suite, 'P1a_LOAN_ACCOUNT_DATE_SPACE' AS scenario,
       la_source AS source,
       COUNT_BIG(*)                        AS rows_total,
       COUNT(DISTINCT la_reporting_date)   AS distinct_dates,
       MIN(la_reporting_date)              AS min_date,
       MAX(la_reporting_date)              AS max_date,
       SUM(CASE WHEN la_reporting_date = @AsOf THEN 1 ELSE 0 END) AS rows_at_asof
FROM [Dictionaries].[risk_analytics].[loan_account]
GROUP BY la_source
ORDER BY source
OPTION (MAXDOP 1);

/* Верхние 12 дат по каждому источнику — видно, сдвинута сетка или оборвана. */
SELECT @Suite AS suite, 'P1b_LOAN_ACCOUNT_TOP_DATES' AS scenario,
       source, la_reporting_date, accounts
FROM (
    SELECT la_source AS source, la_reporting_date, COUNT_BIG(*) AS accounts,
           ROW_NUMBER() OVER (PARTITION BY la_source ORDER BY la_reporting_date DESC) AS rn
    FROM [Dictionaries].[risk_analytics].[loan_account]
    GROUP BY la_source, la_reporting_date
) d
WHERE rn <= 12
ORDER BY source, la_reporting_date DESC
OPTION (MAXDOP 1);


/*==============================================================================
  P2 — Фактический формат l_rate.
  Гипотеза A: единый нечисловой формат (запятая / %% / пробел / NBSP) → чинится
              одним REPLACE, дефект ТИПА колонки, а не данных.
  Гипотеза B: значения содержательно не числа (диапазоны, коды, текст).
  Разводится: сколько строк становится числом после нормализации.
==============================================================================*/
SELECT @Suite AS suite, 'P2a_RATE_SHAPE' AS scenario,
       l_source AS source,
       CASE WHEN l_rate IS NULL                 THEN N'(NULL)'
            WHEN LTRIM(RTRIM(l_rate)) = N''     THEN N'(ПУСТАЯ СТРОКА)'
            ELSE
                 CASE WHEN CHARINDEX(N',', l_rate) > 0 THEN N'зпт ' ELSE N'' END
               + CASE WHEN CHARINDEX(N'.', l_rate) > 0 THEN N'точк ' ELSE N'' END
               + CASE WHEN CHARINDEX(N'%', l_rate) > 0 THEN N'проц ' ELSE N'' END
               + CASE WHEN CHARINDEX(N' ', LTRIM(RTRIM(l_rate))) > 0 THEN N'пробел ' ELSE N'' END
               + CASE WHEN CHARINDEX(NCHAR(160), l_rate) > 0 THEN N'NBSP ' ELSE N'' END
               + CASE WHEN l_rate LIKE N'%[A-Za-zА-Яа-я]%' THEN N'буквы ' ELSE N'' END
               + CASE WHEN l_rate LIKE N'%[0-9]%' THEN N'цифры ' ELSE N'НЕТ_ЦИФР ' END
       END AS rate_shape,
       MIN(LEN(l_rate)) AS min_len,
       MAX(LEN(l_rate)) AS max_len,
       COUNT_BIG(*)     AS rows_cnt
FROM [Dictionaries].[risk_analytics].[loans]
WHERE l_report_date = @AsOf
GROUP BY l_source,
       CASE WHEN l_rate IS NULL                 THEN N'(NULL)'
            WHEN LTRIM(RTRIM(l_rate)) = N''     THEN N'(ПУСТАЯ СТРОКА)'
            ELSE
                 CASE WHEN CHARINDEX(N',', l_rate) > 0 THEN N'зпт ' ELSE N'' END
               + CASE WHEN CHARINDEX(N'.', l_rate) > 0 THEN N'точк ' ELSE N'' END
               + CASE WHEN CHARINDEX(N'%', l_rate) > 0 THEN N'проц ' ELSE N'' END
               + CASE WHEN CHARINDEX(N' ', LTRIM(RTRIM(l_rate))) > 0 THEN N'пробел ' ELSE N'' END
               + CASE WHEN CHARINDEX(NCHAR(160), l_rate) > 0 THEN N'NBSP ' ELSE N'' END
               + CASE WHEN l_rate LIKE N'%[A-Za-zА-Яа-я]%' THEN N'буквы ' ELSE N'' END
               + CASE WHEN l_rate LIKE N'%[0-9]%' THEN N'цифры ' ELSE N'НЕТ_ЦИФР ' END
       END
ORDER BY source, rows_cnt DESC
OPTION (MAXDOP 1);

/* Что даёт нормализация. Если normalized_ok резко больше raw_ok — верна гипотеза A. */
SELECT @Suite AS suite, 'P2b_RATE_CONVERTIBILITY' AS scenario,
       l_source AS source,
       COUNT_BIG(*) AS rows_total,
       SUM(CASE WHEN TRY_CONVERT(decimal(18,6), l_rate) IS NOT NULL
                THEN 1 ELSE 0 END) AS raw_ok,
       SUM(CASE WHEN TRY_CONVERT(float, l_rate) IS NOT NULL
                THEN 1 ELSE 0 END) AS float_ok,
       SUM(CASE WHEN TRY_CONVERT(decimal(18,6),
                 REPLACE(l_rate, N',', N'.')) IS NOT NULL
                THEN 1 ELSE 0 END) AS comma_swapped_ok,
       SUM(CASE WHEN TRY_CONVERT(decimal(18,6),
                 REPLACE(REPLACE(REPLACE(REPLACE(
                   l_rate, N'%', N''), NCHAR(160), N''), N' ', N''), N',', N'.')
                 ) IS NOT NULL
                THEN 1 ELSE 0 END) AS fully_normalized_ok
FROM [Dictionaries].[risk_analytics].[loans]
WHERE l_report_date = @AsOf
GROUP BY l_source
ORDER BY source
OPTION (MAXDOP 1);

/* Сами значения — только массовые (>= @MinCnt), поштучные не показываем. */
SELECT @Suite AS suite, 'P2c_RATE_TOP_VALUES' AS scenario,
       source, rate_value, rows_cnt
FROM (
    SELECT l_source AS source, l_rate AS rate_value, COUNT_BIG(*) AS rows_cnt,
           ROW_NUMBER() OVER (PARTITION BY l_source ORDER BY COUNT_BIG(*) DESC) AS rn
    FROM [Dictionaries].[risk_analytics].[loans]
    WHERE l_report_date = @AsOf AND l_rate IS NOT NULL
    GROUP BY l_source, l_rate
    HAVING COUNT_BIG(*) >= @MinCnt
) d
WHERE rn <= 15
ORDER BY source, rows_cnt DESC
OPTION (MAXDOP 1);


/*==============================================================================
  P3 — la_account_*: NULL против нуля.
  Сценарий E25 написан через `<> 0`, а `NULL <> 0` = UNKNOWN → «0 ненулевых»
  по 1401/1818/1838 может означать «все NULL». Собственная слепота сценария,
  прямое нарушение правила «NULL ≠ 0» (CLAUDE.md). Здесь считаем все три исхода.

  Дату НЕ берём из @AsOf: если P1 покажет разные сетки, жёсткая дата снова оставит
  один S03. Берём последнюю дату КАЖДОГО источника — тогда проба отвечает по всем.
==============================================================================*/
IF OBJECT_ID('tempdb..#la_last') IS NOT NULL DROP TABLE #la_last;
CREATE TABLE #la_last (la_source varchar(10) NOT NULL PRIMARY KEY, last_date date NOT NULL);

INSERT INTO #la_last (la_source, last_date)
SELECT la_source, MAX(la_reporting_date)
FROM [Dictionaries].[risk_analytics].[loan_account]
GROUP BY la_source
OPTION (MAXDOP 1);

SELECT @Suite AS suite, 'P3_GL_NULL_VS_ZERO' AS scenario,
       source, effective_date, gl_account,
       COUNT_BIG(*) AS accounts,
       SUM(CASE WHEN v IS NULL THEN 1 ELSE 0 END) AS is_null,
       SUM(CASE WHEN v = 0     THEN 1 ELSE 0 END) AS is_zero,
       SUM(CASE WHEN v <> 0    THEN 1 ELSE 0 END) AS is_nonzero
FROM (
    SELECT a.la_source AS source, k.last_date AS effective_date, g.gl_account,
           CASE g.gl_account
                WHEN '1401'  THEN a.la_account_1401
                WHEN '1428'  THEN a.la_account_1428
                WHEN '18771' THEN a.la_account_18771
                WHEN '1818'  THEN a.la_account_1818
                ELSE              a.la_account_1838
           END AS v
    FROM [Dictionaries].[risk_analytics].[loan_account] a
    JOIN #la_last k
      ON k.la_source = a.la_source AND k.last_date = a.la_reporting_date
    CROSS JOIN (VALUES ('1401'),('1428'),('18771'),('1818'),('1838')) g(gl_account)
) u
GROUP BY source, effective_date, gl_account
ORDER BY source, gl_account
OPTION (MAXDOP 1);


/*==============================================================================
  P4 — Разрыв E33 (окно 24 мес) против E34 (вся таблица).
  S01 попал в окно на 1,2%, S17 — на 82,9%. Гипотеза A: события старше окна.
  Гипотеза B: restructuring_date NULL. Считаем оба исхода на одном наборе.
==============================================================================*/
SELECT @Suite AS suite, 'P4_RESTR_DATE_COVERAGE' AS scenario,
       [dlcr$source] AS source,
       COUNT_BIG(*) AS events_total,
       SUM(CASE WHEN restructuring_date IS NULL THEN 1 ELSE 0 END) AS date_null,
       SUM(CASE WHEN restructuring_date <  DATEADD(MONTH, -24, @AsOf) THEN 1 ELSE 0 END) AS older_than_24m,
       SUM(CASE WHEN restructuring_date >  @AsOf THEN 1 ELSE 0 END) AS in_future_ANOMALY,
       SUM(CASE WHEN restructuring_date >= DATEADD(MONTH, -24, @AsOf)
                 AND restructuring_date <= @AsOf THEN 1 ELSE 0 END) AS inside_window,
       MIN(restructuring_date) AS min_date,
       MAX(restructuring_date) AS max_date
FROM [Dictionaries].[risk_analytics].[restructuring_v2]
GROUP BY [dlcr$source]
ORDER BY source
OPTION (MAXDOP 1);


/*==============================================================================
  P5 — Обвал выдач S03: 5 392 (2026-03) -> 523 -> 13 -> 17 -> 15.
  Гипотеза A: продукт остановлен (тогда платежи по старым договорам идут ровно).
  Гипотеза B: обрыв загрузки (тогда просядут и платежи, и хвост дат).
  Смотрим два независимых свидетеля: край дат в loans и активность в payments.
==============================================================================*/
SELECT @Suite AS suite, 'P5a_OPEN_DATE_EDGE' AS scenario,
       l_source AS source,
       MAX(l_loan_open_date)   AS max_open_date,
       MAX(l_funding_date)     AS max_funding_date,
       MAX(l_loan_maturity_date) AS max_maturity_date,
       SUM(CASE WHEN l_loan_open_date > @AsOf THEN 1 ELSE 0 END) AS opened_after_asof_ANOMALY
FROM [Dictionaries].[risk_analytics].[loans]
WHERE l_report_date = @AsOf
GROUP BY l_source
ORDER BY source
OPTION (MAXDOP 1);

/* Выдачи и платежи S03 по одним и тем же месяцам, бок о бок. */
SELECT @Suite AS suite, 'P5b_S03_ORIGINATION_VS_PAYMENTS' AS scenario,
       m.ym AS month,
       o.loans_opened,
       p.payment_rows,
       p.payment_sum
FROM (
    SELECT DISTINCT CONVERT(char(7), DATEADD(MONTH, -n, @AsOf), 126) AS ym
    FROM (VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9),(10),(11)) v(n)
) m
LEFT JOIN (
    SELECT CONVERT(char(7), l_loan_open_date, 126) AS ym, COUNT_BIG(*) AS loans_opened
    FROM [Dictionaries].[risk_analytics].[loans]
    WHERE l_report_date = @AsOf AND l_source = 'S03'
      AND l_loan_open_date >= DATEADD(MONTH, -12, @AsOf)
    GROUP BY CONVERT(char(7), l_loan_open_date, 126)
) o ON o.ym = m.ym
LEFT JOIN (
    SELECT CONVERT(char(7), p_VALUE_DATE, 126) AS ym, COUNT_BIG(*) AS payment_rows,
           CAST(SUM(p_TOTAL) AS decimal(38,2)) AS payment_sum
    FROM [Dictionaries].[risk_analytics].[payments]
    WHERE p_source = 'S03' AND p_VALUE_DATE >= DATEADD(MONTH, -12, @AsOf)
      AND p_VALUE_DATE <= @AsOf
    GROUP BY CONVERT(char(7), p_VALUE_DATE, 126)
) p ON p.ym = m.ym
ORDER BY month
OPTION (MAXDOP 1);


/*==============================================================================
  P6 — Хвост суммы: максимум 76 248 550 715 ₸ при средней 10-й децили 34,4 млн.
  Гипотеза A: валютный договор без пересчёта в ₸.
  Гипотеза B: единица измерения / ошибка ввода в KZT.
  Разводится: если крупные суммы сидят в KZT — верна B.
==============================================================================*/
SELECT @Suite AS suite, 'P6_BIG_AMOUNT_BY_CURRENCY' AS scenario,
       l_source AS source,
       ISNULL(l_currency, N'(NULL)') AS currency,
       COUNT_BIG(*) AS loans_over_threshold,
       CAST(MIN(l_loan_amount) AS decimal(38,2)) AS min_amount,
       CAST(MAX(l_loan_amount) AS decimal(38,2)) AS max_amount,
       CAST(SUM(l_loan_amount) AS decimal(38,2)) AS sum_amount
FROM [Dictionaries].[risk_analytics].[loans_active]
WHERE l_report_date = @AsOf AND l_loan_amount >= @BigAmt
GROUP BY l_source, ISNULL(l_currency, N'(NULL)')
ORDER BY source, currency
OPTION (MAXDOP 1);
