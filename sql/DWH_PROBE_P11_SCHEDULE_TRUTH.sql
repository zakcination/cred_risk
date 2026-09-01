/*==============================================================================
  DWH_PROBE_P11 — график погашения: что там на самом деле.

  ПОВОД — две МОИ ошибки в прогоне 09.08, обе давшие правдоподобные, но ложные
  числа (FINDINGS §18.1, §18.2):

  1. M13 отрапортовал «ГРАФИКА НЕТ» у 100% активных договоров ВСЕХ четырёх
     источников. Джойн шёл по `l_loan_id`. H11 в том же прогоне измерил ключ
     прямо: `rs_loan_id → l_gid` = 100,0000%, `rs_loan_id → l_loan_id` =
     0,0000%. То есть 100% были артефактом ключа.
  2. H13a дал покрытие 3,20% у S03. Знаменателем были ВСЕ договоры `loans`
     (7 099 915), включая закрытые, а колонка называлась `active_loans`.
     Активных у S03 220 589 при 226 973 договорах с графиком — то есть график
     покрывает практически весь активный портфель, а не 3%.

  Оба раза цифра выглядела как находка. Ни разу не выглядела как ошибка.
  Поэтому здесь ЛЮБОЕ покрытие печатается с ОБОИМИ знаменателями сразу:
  расхождение между ними видно в самой строке, а не в голове читающего.

  ЧТО ПРОВЕРЯЕТСЯ:
  - P11a: инвентарь таблицы по источникам + ГОРИЗОНТ ДАТ. Гипотеза: график
    содержит только БУДУЩИЕ платежи (H13b начался ровно с текущего месяца).
    Если так — H14 (план против факта на прошлых месяцах) неприменим в
    принципе, и «нет плана на месяц» при факте 47–94 млрд ₸ не дефект витрины.
  - P11b: есть ли в графике S02 хоть одна строка. M15a перечислил только
    S01/S03/S17 — похоже, источника нет совсем, и тогда «0% покрытия» у S02
    (H13a) — это отсутствие данных, а не отсутствие графиков.
  - P11c: покрытие активного портфеля — настоящий ответ на вопрос M13.
  - P11d: ведёт ли витрина график по ЗАКРЫТЫМ договорам. Это и есть разница
    между двумя знаменателями; заодно объясняет, почему у S17 строк графика
    больше, чем активных договоров.
  - P11e: строки графика, чей `rs_loan_id` не находится в `loans` ВООБЩЕ —
    сироты. H11 мерил покрытие только по трём источникам и только сверху.

  Правила: только SELECT, `#temp`, MAXDOP 1, без PII, трёхчастные имена,
  пороги параметрами. ЗАПУСКАТЬ ЦЕЛИКОМ ОТ ПЕРВОЙ СТРОКИ (Msg 137).
==============================================================================*/

SET NOCOUNT ON;

DECLARE @Suite     varchar(20) = 'P11';
DECLARE @LoansAsOf date = (SELECT MAX(l_report_date) FROM [Dictionaries].[risk_analytics].[loans]);

SELECT @Suite AS suite, '00_SCOPE' AS scenario, @LoansAsOf AS loans_asof;

/*------------------------------------------------------------------------------
  МАТЕРИАЛИЗАЦИЯ. Два периметра РАЗДЕЛЬНО — в этом весь смысл пробы.
  `loans_active` — вьюха УЖЕ `loans` (§15), поэтому оба строятся независимо,
  а не фильтром одного из другого.
------------------------------------------------------------------------------*/
IF OBJECT_ID('tempdb..#p11_act') IS NOT NULL DROP TABLE #p11_act;
SELECT l_source, l_gid
INTO #p11_act
FROM [Dictionaries].[risk_analytics].[loans_active]
WHERE l_report_date = @LoansAsOf
OPTION (MAXDOP 1);
CREATE CLUSTERED INDEX ix_p11_act ON #p11_act(l_gid);

IF OBJECT_ID('tempdb..#p11_all') IS NOT NULL DROP TABLE #p11_all;
SELECT l_source, l_gid
INTO #p11_all
FROM [Dictionaries].[risk_analytics].[loans]
WHERE l_report_date = @LoansAsOf
OPTION (MAXDOP 1);
CREATE CLUSTERED INDEX ix_p11_all ON #p11_all(l_gid);

/* Ключ графика — ОДНА колонка, bigint, как доказал H11. Никаких CAST на
   стороне джойна: приведение типа на индексной стороне делает джойн
   non-sargable и вешает запрос (класс L11.1/L4.1). */
IF OBJECT_ID('tempdb..#p11_sched') IS NOT NULL DROP TABLE #p11_sched;
SELECT rs_source, rs_loan_id,
       COUNT_BIG(*)          AS installments,
       MIN(rs_repayment_date) AS first_due,
       MAX(rs_repayment_date) AS last_due
INTO #p11_sched
FROM [Dictionaries].[risk_analytics].[repayment_schedule]
WHERE rs_loan_id IS NOT NULL
GROUP BY rs_source, rs_loan_id
OPTION (MAXDOP 1);
CREATE CLUSTERED INDEX ix_p11_sched ON #p11_sched(rs_loan_id);

/*==============================================================================
  P11a — ИНВЕНТАРЬ И ГОРИЗОНТ. Есть ли в графике прошлое?
==============================================================================*/
SELECT @Suite AS suite, 'P11a_SCHEDULE_INVENTORY' AS scenario,
       rs_source AS source,
       COUNT_BIG(*) AS schedule_rows,
       COUNT_BIG(DISTINCT rs_loan_id) AS distinct_loans,
       MIN(rs_repayment_date) AS earliest_due,
       MAX(rs_repayment_date) AS latest_due,
       SUM(CASE WHEN rs_repayment_date <= @LoansAsOf THEN 1 ELSE 0 END) AS rows_in_the_past,
       CAST(100.0 * SUM(CASE WHEN rs_repayment_date <= @LoansAsOf THEN 1 ELSE 0 END)
            / NULLIF(COUNT_BIG(*), 0) AS decimal(9,4)) AS past_pct
FROM [Dictionaries].[risk_analytics].[repayment_schedule]
GROUP BY rs_source
ORDER BY source
OPTION (MAXDOP 1);

/*==============================================================================
  P11b — ЕСТЬ ЛИ S02 В ТАБЛИЦЕ ВООБЩЕ. Отдельным запросом, потому что
  отсутствие источника в P11a легко прочитать как «строк мало», а не «нет ни
  одной»: пустая группа не печатает строку и потому невидима.
==============================================================================*/
SELECT @Suite AS suite, 'P11b_SOURCE_PRESENCE' AS scenario,
       s.src AS source,
       ISNULL(r.rows_cnt, 0) AS schedule_rows,
       CASE WHEN ISNULL(r.rows_cnt, 0) = 0
            THEN N'ИСТОЧНИКА НЕТ В ТАБЛИЦЕ — 0% покрытия означает нет данных'
            ELSE N'' END AS verdict
FROM (VALUES ('S01'), ('S02'), ('S03'), ('S17')) s(src)
LEFT JOIN (SELECT rs_source, COUNT_BIG(*) AS rows_cnt
           FROM [Dictionaries].[risk_analytics].[repayment_schedule]
           GROUP BY rs_source) r ON r.rs_source = s.src
ORDER BY source
OPTION (MAXDOP 1);

/*==============================================================================
  P11c — ПОКРЫТИЕ ГРАФИКОМ. Настоящий ответ на вопрос M13.

  Оба знаменателя в одной строке. Если они расходятся — расхождение и есть
  результат, а не повод выбрать удобный.
==============================================================================*/
SELECT @Suite AS suite, 'P11c_COVERAGE_BOTH_DENOMINATORS' AS scenario,
       a.l_source AS source,
       a.active_loans, a.active_with_schedule,
       CAST(100.0 * a.active_with_schedule / NULLIF(a.active_loans, 0) AS decimal(9,4)) AS coverage_of_ACTIVE_pct,
       t.all_loans, t.all_with_schedule,
       CAST(100.0 * t.all_with_schedule / NULLIF(t.all_loans, 0) AS decimal(9,4)) AS coverage_of_ALL_pct
FROM (
    SELECT l.l_source, COUNT_BIG(*) AS active_loans,
           SUM(CASE WHEN s.rs_loan_id IS NOT NULL THEN 1 ELSE 0 END) AS active_with_schedule
    FROM #p11_act l
    LEFT JOIN (SELECT DISTINCT rs_loan_id FROM #p11_sched) s ON s.rs_loan_id = l.l_gid
    GROUP BY l.l_source
) a
FULL OUTER JOIN (
    SELECT l.l_source, COUNT_BIG(*) AS all_loans,
           SUM(CASE WHEN s.rs_loan_id IS NOT NULL THEN 1 ELSE 0 END) AS all_with_schedule
    FROM #p11_all l
    LEFT JOIN (SELECT DISTINCT rs_loan_id FROM #p11_sched) s ON s.rs_loan_id = l.l_gid
    GROUP BY l.l_source
) t ON t.l_source = a.l_source
ORDER BY source
OPTION (MAXDOP 1);

/*==============================================================================
  P11d — ГРАФИК У ЗАКРЫТЫХ ДОГОВОРОВ. Это и есть разница между знаменателями.
  Если витрина ведёт график по закрытым — прогноз денежного потока обязан
  фильтровать периметр, иначе он посчитает поступления по погашенным кредитам.
==============================================================================*/
SELECT @Suite AS suite, 'P11d_SCHEDULE_ON_CLOSED_LOANS' AS scenario,
       t.l_source AS source,
       COUNT_BIG(*) AS loans_with_schedule_not_active,
       SUM(sc.installments) AS installments,
       SUM(CASE WHEN sc.last_due > @LoansAsOf THEN 1 ELSE 0 END) AS still_have_FUTURE_installments
FROM #p11_all t
JOIN #p11_sched sc ON sc.rs_loan_id = t.l_gid
LEFT JOIN #p11_act a ON a.l_gid = t.l_gid
WHERE a.l_gid IS NULL
GROUP BY t.l_source
ORDER BY source
OPTION (MAXDOP 1);

/*==============================================================================
  P11e — СИРОТЫ: строки графика, чей ключ не находится в `loans` ни в каком
  статусе. H11 мерил покрытие сверху и по трём источникам; здесь — снизу и по
  всем. Сироты означают, что прогноз потока считается по договорам, которых в
  портфеле нет.
==============================================================================*/
SELECT @Suite AS suite, 'P11e_ORPHAN_SCHEDULES' AS scenario,
       sc.rs_source AS source,
       COUNT_BIG(*) AS orphan_loans,
       SUM(sc.installments) AS orphan_installments,
       MIN(sc.first_due) AS earliest_due,
       MAX(sc.last_due)  AS latest_due
FROM #p11_sched sc
LEFT JOIN #p11_all l ON l.l_gid = sc.rs_loan_id
WHERE l.l_gid IS NULL
GROUP BY sc.rs_source
ORDER BY source
OPTION (MAXDOP 1);

/*------------------------------------------------------------------------------
  УБОРКА — строго после последнего обращения к таблицам (09.08 правка уборки
  попала в блок материализации и дала Msg 208).
------------------------------------------------------------------------------*/
IF OBJECT_ID('tempdb..#p11_act')   IS NOT NULL DROP TABLE #p11_act;
IF OBJECT_ID('tempdb..#p11_all')   IS NOT NULL DROP TABLE #p11_all;
IF OBJECT_ID('tempdb..#p11_sched') IS NOT NULL DROP TABLE #p11_sched;
