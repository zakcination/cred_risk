/*==============================================================================
  DWH_PROBE_P12 — какие срезы вообще есть в марте и куда делись прошлые месяцы.

  ПОВОД. Три независимых наблюдения, каждое про пропавшие данные за прошлые
  периоды, но ни одного полного перечня срезов:
  - `loan_account` историзован, но у S02 из ряда одномоментно исчезают
    **163 936 договоров на 2026-01-01** при фоне 1,5–4,9 тыс./мес (H02d), а в
    феврале 2026 счета S02 падают 185 828 → 30 973 (P1).
  - `repayment_schedule` истории не имеет вовсе: самая ранняя дата платежа у
    ВСЕХ трёх присутствующих источников совпадает до дня — 2026-07-06 (P11a).
    Прошлые платежи удаляются при перезагрузке.
  - `pledges`, `interest_rates`, `ratings` — по одному срезу (H10, §13, §16.5).

  Прежде чем спрашивать «куда делись данные», нужно знать, за какие периоды они
  вообще должны быть. Этот скрипт печатает ПОЛНЫЙ ряд срезов по каждой таблице
  и источнику с числом строк — чтобы обрыв был виден как обрыв ряда, а не как
  наше предположение.

  РАЗЛИЧАЕМЫЕ ГИПОТЕЗЫ:
  A. Срез есть, но строк в нём меньше — данные ушли ВНУТРИ существующего среза
     (выбытие договоров или неполная загрузка).
  B. Среза нет вообще — пропущена загрузка за период.
  C. Ряд начинается позже, чем у соседних источников — разная глубина хранения.
  D. Ряд один — таблица перестраивается целиком, истории не предусмотрено.
  Они дают разный вопрос владельцу и разного адресата, поэтому разделены.

  ГРАНИЦА. Имена колонок отчётной даты берутся ТОЛЬКО из живого аудита. Батч 0
  печатает все такие колонки по схеме; батч 1 покрывает шесть подтверждённых
  (`l_report_date`, `la_reporting_date`, `b_report_date`, `c_reporting_date`,
  `g_report_date`, `r_report_date`). Если батч 0 покажет отчётную колонку у
  таблицы, которой нет в батче 1 (кандидаты — `interest_rates`, `payments`,
  `writeoff`, `collections`, `offbalance`), её надо добавить тем же блоком
  UNION ALL — шаблон виден по любому из существующих.

  Правила: только SELECT, MAXDOP 1, без PII, трёхчастные имена.
  ЗАПУСКАТЬ ЦЕЛИКОМ ОТ ПЕРВОЙ СТРОКИ (Msg 137).
==============================================================================*/

/*------------------------------------------------------------------------------
  БАТЧ 0 — какие таблицы вообще имеют отчётную дату. Отделён `GO`: он
  отработает, даже если батч 1 упадёт на неверном имени.
  Имя БД обязательно — двухчастный INFORMATION_SCHEMA вернёт 0 строк БЕЗ ошибки.
------------------------------------------------------------------------------*/
SELECT 'P12' AS suite, '00_DATE_COLUMNS' AS scenario,
       TABLE_NAME, COLUMN_NAME, DATA_TYPE
FROM [Dictionaries].INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'risk_analytics'
  AND (COLUMN_NAME LIKE '%report_date%' OR COLUMN_NAME LIKE '%reporting_date%')
ORDER BY TABLE_NAME, COLUMN_NAME
OPTION (MAXDOP 1);
GO

/*==============================================================================
  БАТЧ 1 — РЯД СРЕЗОВ ПО КАЖДОЙ ТАБЛИЦЕ И ИСТОЧНИКУ.
==============================================================================*/
SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#p12') IS NOT NULL DROP TABLE #p12;
CREATE TABLE #p12 (tbl varchar(40), src nvarchar(10), snap date, rows_cnt bigint);

INSERT INTO #p12 (tbl, src, snap, rows_cnt)
SELECT 'loans', l_source, l_report_date, COUNT_BIG(*)
FROM [Dictionaries].[risk_analytics].[loans]
GROUP BY l_source, l_report_date
OPTION (MAXDOP 1);

INSERT INTO #p12 (tbl, src, snap, rows_cnt)
SELECT 'loans_active', l_source, l_report_date, COUNT_BIG(*)
FROM [Dictionaries].[risk_analytics].[loans_active]
GROUP BY l_source, l_report_date
OPTION (MAXDOP 1);

INSERT INTO #p12 (tbl, src, snap, rows_cnt)
SELECT 'loan_account', la_source, la_reporting_date, COUNT_BIG(*)
FROM [Dictionaries].[risk_analytics].[loan_account]
GROUP BY la_source, la_reporting_date
OPTION (MAXDOP 1);

INSERT INTO #p12 (tbl, src, snap, rows_cnt)
SELECT 'pledges', c_source, c_reporting_date, COUNT_BIG(*)
FROM [Dictionaries].[risk_analytics].[pledges]
GROUP BY c_source, c_reporting_date
OPTION (MAXDOP 1);

/* `borrower` — клиентское измерение, источника в нём нет: группируем только
   по дате, иначе появится фиктивный разрез. */
INSERT INTO #p12 (tbl, src, snap, rows_cnt)
SELECT 'borrower', N'(все)', b_report_date, COUNT_BIG(*)
FROM [Dictionaries].[risk_analytics].[borrower]
GROUP BY b_report_date
OPTION (MAXDOP 1);

INSERT INTO #p12 (tbl, src, snap, rows_cnt)
SELECT 'guarantees', N'(все)', g_report_date, COUNT_BIG(*)
FROM [Dictionaries].[risk_analytics].[guarantees]
GROUP BY g_report_date
OPTION (MAXDOP 1);

INSERT INTO #p12 (tbl, src, snap, rows_cnt)
SELECT 'ratings', N'(все)', r_report_date, COUNT_BIG(*)
FROM [Dictionaries].[risk_analytics].[ratings]
GROUP BY r_report_date
OPTION (MAXDOP 1);

/*------------------------------------------------------------------------------
  P12a — ПАСПОРТ ГЛУБИНЫ. Одна строка на таблицу+источник: сколько срезов, за
  какой период, есть ли пропущенные месяцы внутри периода.
  Пропуск считается как разница между числом месяцев в интервале и числом
  фактических срезов — это ловит гипотезу B (среза нет вовсе).
------------------------------------------------------------------------------*/
SELECT 'P12' AS suite, 'P12a_HISTORY_DEPTH' AS scenario,
       tbl AS table_name, src AS source,
       COUNT_BIG(*) AS snapshots,
       MIN(snap) AS first_snapshot,
       MAX(snap) AS last_snapshot,
       DATEDIFF(MONTH, MIN(snap), MAX(snap)) + 1 AS months_in_range,
       DATEDIFF(MONTH, MIN(snap), MAX(snap)) + 1 - COUNT_BIG(*) AS missing_snapshots,
       CASE WHEN COUNT_BIG(*) = 1 THEN N'ОДИН СРЕЗ — истории нет'
            WHEN DATEDIFF(MONTH, MIN(snap), MAX(snap)) + 1 - COUNT_BIG(*) > 0
                 THEN N'ЕСТЬ ПРОПУЩЕННЫЕ ПЕРИОДЫ'
            ELSE N'ряд непрерывный' END AS verdict
FROM #p12
GROUP BY tbl, src
ORDER BY table_name, source
OPTION (MAXDOP 1);

/*------------------------------------------------------------------------------
  P12b — РЯД ЦЕЛИКОМ с изменением к предыдущему срезу. Обрыв внутри
  существующего среза (гипотеза A) виден только так: сам срез на месте, а строк
  в нём кратно меньше. Печатается и абсолютное, и процентное изменение —
  процент один скрывает масштаб, абсолют один скрывает резкость.
------------------------------------------------------------------------------*/
SELECT 'P12' AS suite, 'P12b_ROWS_BY_SNAPSHOT' AS scenario,
       tbl AS table_name, src AS source, snap AS snapshot, rows_cnt,
       rows_cnt - LAG(rows_cnt) OVER (PARTITION BY tbl, src ORDER BY snap) AS delta_rows,
       CAST(100.0 * (rows_cnt - LAG(rows_cnt) OVER (PARTITION BY tbl, src ORDER BY snap))
            / NULLIF(LAG(rows_cnt) OVER (PARTITION BY tbl, src ORDER BY snap), 0)
            AS decimal(9,2)) AS delta_pct
FROM #p12
ORDER BY table_name, source, snapshot
OPTION (MAXDOP 1);

/*------------------------------------------------------------------------------
  P12c — ГДЕ РЯД ОБОРВАЛСЯ. Отдельным запросом, потому что в полном ряде выше
  обрыв тонет среди сотни строк. Порог — параметр, не константа в теле.
------------------------------------------------------------------------------*/
DECLARE @DropPct decimal(9,2) = -20.00;   -- падение резче этого считаем обрывом

SELECT 'P12' AS suite, 'P12c_SERIES_BREAKS' AS scenario, *
FROM (
    SELECT tbl AS table_name, src AS source, snap AS snapshot, rows_cnt,
           rows_cnt - LAG(rows_cnt) OVER (PARTITION BY tbl, src ORDER BY snap) AS delta_rows,
           CAST(100.0 * (rows_cnt - LAG(rows_cnt) OVER (PARTITION BY tbl, src ORDER BY snap))
                / NULLIF(LAG(rows_cnt) OVER (PARTITION BY tbl, src ORDER BY snap), 0)
                AS decimal(9,2)) AS delta_pct
    FROM #p12
) d
WHERE delta_pct <= @DropPct
ORDER BY table_name, source, snapshot
OPTION (MAXDOP 1);

/*------------------------------------------------------------------------------
  P12d — СЕТКА ДАТ МЕЖДУ ТАБЛИЦАМИ на последний срез. T35 в одном месте: какая
  таблица на какой день актуальна. Это же — блок «срез данных» для писем.
------------------------------------------------------------------------------*/
SELECT 'P12' AS suite, 'P12d_LATEST_GRID' AS scenario,
       table_name, source, last_snapshot, rows_at_last
FROM (
    SELECT tbl AS table_name, src AS source, snap AS last_snapshot, rows_cnt AS rows_at_last,
           ROW_NUMBER() OVER (PARTITION BY tbl, src ORDER BY snap DESC) AS rn
    FROM #p12
) d
WHERE rn = 1
ORDER BY table_name, source
OPTION (MAXDOP 1);

IF OBJECT_ID('tempdb..#p12') IS NOT NULL DROP TABLE #p12;
