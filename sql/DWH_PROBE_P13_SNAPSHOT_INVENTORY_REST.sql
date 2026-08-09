/*==============================================================================
  DWH_PROBE_P13 — дополнение к P12: срезы остальных семи таблиц.

  ПОВОД. Батч 0 в P12 напечатал 15 колонок отчётной даты, а батч 1 покрыл
  шесть. Непокрытыми остались семь таблиц, и среди них та, про которую я уже
  успел написать вывод:

  **`repayment_schedule` ИМЕЕТ `rs_report_date`.** В §19.3 записано «срезов
  нет» — вывод сделан по датам ПЛАТЕЖЕЙ (`rs_repayment_date`), а колонка
  отчётной даты в таблице есть, и я её не проверил. Утверждение «истории нет»
  до этой пробы не обосновано: возможно, срезов несколько, и тогда прошлые
  платежи никуда не удалялись — они лежат в прошлых срезах.

  Разница принципиальная. Если срез один — таблица перестраивается и
  ретроспектива невозможна (как записано). Если срезов несколько — ретроспектива
  ЕСТЬ, а H14 просто читал не ту дату, и это снова моя ошибка, а не дефект
  витрины. Черновик 8 отправлять до ответа на этот вопрос нельзя.

  ОСТАЛЬНЫЕ ШЕСТЬ: `interest_rates`, `restructuring_v2`, `collections`,
  `credit_lines`, `Offbalance`, `writeoff`.

  ЗАМЕЧАНИЯ ПО ИМЕНАМ (из батча 0 P12, не из догадок):
  - `writeoff` — колонка `w_dm_z10$report_date`, символ `$` требует скобок.
  - `Guarantees` и `Offbalance` — с заглавной буквы. На регистронезависимой
    сортировке это безразлично, но в скриптах лучше писать как в схеме.
  - `credit_lines.cl_basket_report_date` имеет тип **int**, а не date — ещё
    одна дата, хранимая числом. Здесь не трогаем, но в реестр это идёт.
  - Группировка только по дате, без источника: колонки источника у этих таблиц
    не подтверждены живым аудитом. Исключение — `repayment_schedule`, где
    `rs_source` подтверждён (P11).

  Правила: только SELECT, MAXDOP 1, без PII, трёхчастные имена.
==============================================================================*/

SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#p13') IS NOT NULL DROP TABLE #p13;
CREATE TABLE #p13 (tbl varchar(40), src nvarchar(10), snap date, rows_cnt bigint);

/* Главный вопрос пробы — идёт первым. */
INSERT INTO #p13 (tbl, src, snap, rows_cnt)
SELECT 'repayment_schedule', rs_source, rs_report_date, COUNT_BIG(*)
FROM [Dictionaries].[risk_analytics].[repayment_schedule]
GROUP BY rs_source, rs_report_date
OPTION (MAXDOP 1);

INSERT INTO #p13 (tbl, src, snap, rows_cnt)
SELECT 'interest_rates', N'(все)', report_date, COUNT_BIG(*)
FROM [Dictionaries].[risk_analytics].[interest_rates]
GROUP BY report_date
OPTION (MAXDOP 1);

INSERT INTO #p13 (tbl, src, snap, rows_cnt)
SELECT 'restructuring_v2', N'(все)', report_date, COUNT_BIG(*)
FROM [Dictionaries].[risk_analytics].[restructuring_v2]
GROUP BY report_date
OPTION (MAXDOP 1);

INSERT INTO #p13 (tbl, src, snap, rows_cnt)
SELECT 'collections', N'(все)', c_reporting_date, COUNT_BIG(*)
FROM [Dictionaries].[risk_analytics].[collections]
GROUP BY c_reporting_date
OPTION (MAXDOP 1);

INSERT INTO #p13 (tbl, src, snap, rows_cnt)
SELECT 'credit_lines', N'(все)', cl_report_date, COUNT_BIG(*)
FROM [Dictionaries].[risk_analytics].[credit_lines]
GROUP BY cl_report_date
OPTION (MAXDOP 1);

INSERT INTO #p13 (tbl, src, snap, rows_cnt)
SELECT 'Offbalance', N'(все)', o_reporting_date, COUNT_BIG(*)
FROM [Dictionaries].[risk_analytics].[Offbalance]
GROUP BY o_reporting_date
OPTION (MAXDOP 1);

INSERT INTO #p13 (tbl, src, snap, rows_cnt)
SELECT 'writeoff', N'(все)', [w_dm_z10$report_date], COUNT_BIG(*)
FROM [Dictionaries].[risk_analytics].[writeoff]
GROUP BY [w_dm_z10$report_date]
OPTION (MAXDOP 1);

/*------------------------------------------------------------------------------
  P13a — ГЛУБИНА. Та же форма, что P12a, чтобы результаты складывались в одну
  таблицу без пересчёта.
------------------------------------------------------------------------------*/
SELECT 'P13' AS suite, 'P13a_HISTORY_DEPTH' AS scenario,
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
FROM #p13
GROUP BY tbl, src
ORDER BY table_name, source
OPTION (MAXDOP 1);

/*------------------------------------------------------------------------------
  P13b — РЯД ЦЕЛИКОМ с изменением к предыдущему срезу.
------------------------------------------------------------------------------*/
SELECT 'P13' AS suite, 'P13b_ROWS_BY_SNAPSHOT' AS scenario,
       tbl AS table_name, src AS source, snap AS snapshot, rows_cnt,
       rows_cnt - LAG(rows_cnt) OVER (PARTITION BY tbl, src ORDER BY snap) AS delta_rows,
       CAST(100.0 * (rows_cnt - LAG(rows_cnt) OVER (PARTITION BY tbl, src ORDER BY snap))
            / NULLIF(LAG(rows_cnt) OVER (PARTITION BY tbl, src ORDER BY snap), 0)
            AS decimal(9,2)) AS delta_pct
FROM #p13
ORDER BY table_name, source, snapshot
OPTION (MAXDOP 1);

/*------------------------------------------------------------------------------
  P13c — ЕСЛИ У ГРАФИКА НЕСКОЛЬКО СРЕЗОВ: лежат ли в прошлых срезах прошлые
  платежи. Это прямой ответ на вопрос «удаляются ли прошедшие платежи».
  Если срез один — запрос вернёт одну строку, и вывод §19.3 остаётся в силе.
------------------------------------------------------------------------------*/
SELECT 'P13' AS suite, 'P13c_SCHEDULE_PAST_BY_SNAPSHOT' AS scenario,
       rs_source AS source,
       rs_report_date AS snapshot,
       COUNT_BIG(*) AS rows_cnt,
       MIN(rs_repayment_date) AS earliest_due,
       MAX(rs_repayment_date) AS latest_due,
       SUM(CASE WHEN rs_repayment_date < rs_report_date THEN 1 ELSE 0 END) AS due_before_snapshot,
       CAST(100.0 * SUM(CASE WHEN rs_repayment_date < rs_report_date THEN 1 ELSE 0 END)
            / NULLIF(COUNT_BIG(*), 0) AS decimal(9,4)) AS past_pct
FROM [Dictionaries].[risk_analytics].[repayment_schedule]
GROUP BY rs_source, rs_report_date
ORDER BY source, snapshot
OPTION (MAXDOP 1);

IF OBJECT_ID('tempdb..#p13') IS NOT NULL DROP TABLE #p13;
