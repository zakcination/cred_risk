/*==============================================================================
  DWH_SCENARIOS_L3A_HARD — сценарии H00–H12 (уровень 3, часть A)

  Уровень 3 проверяет пригодность DWH для риск-моделирования и регуляторной
  отчётности: временные ряды, миграции состояний, cure/re-default, LTV,
  концентрация.

  ГЛАВНОЕ ИЗМЕНЕНИЕ ПОСЛЕ ПРОБ P1/P4 (FINDINGS §11.2, §11.4).
  Шапка уровня 3 в DWH_TEST_SCENARIOS.md гласила: «Общая ловушка для всего
  уровня — T8: истории нет. Любой сценарий "динамика во времени" невыполним».
  ЭТО ОКАЗАЛОСЬ НЕВЕРНО для счётного слоя:
      loan_account      — 19–20 МЕСЯЧНЫХ СРЕЗОВ с 2025-01-01;
      restructuring_v2  — события с 2006 года.
  Истории нет только у `loans`, `borrower`, `pledges`, `interest_rates`
  (по одной дате). Поэтому H01 (vintage) и H02 (roll-rate) здесь считаются
  ПО-НАСТОЯЩЕМУ, а не отбиваются как «невыполнимо». Граница другая и она
  честно печатается: наблюдаемое окно ограничено январём 2025.

  ЧТО ЕЩЁ УЧТЕНО ИЗ ПРОГОНОВ:
  - Сетка дат РАЗНАЯ по источникам (T35): S03 на месяц впереди. Ряд строится
    от последней даты КАЖДОГО источника, а не от общего @AsOf, иначе S01/S02/S17
    выпадут целиком и это будет выглядеть как «данных нет» (T26).
  - `days_past_due` NULL на 79% строк (T14/L1-E23). NULL — ОТДЕЛЬНОЕ состояние
    «НЕТ ДАННЫХ», никогда не 0. Иначе доля 90+ меняется в 4,8 раза.
  - `delinquency_bucket` заполнен на 100%, но формируется НЕЗАВИСИМО от DPD
    (T19). Поэтому все матрицы строятся ПО ОБОИМ измерениям рядом — расхождение
    между ними и есть результат теста.
  - Ставка (`interest_rates`) в расчётах НЕ агрегируется: две шкалы внутри одной
    программы на 1 720 575 договорах (T40). Используется только как признак
    наличия, не как число.
  - S03 прекратил выдачи с апреля 2026 (T37) — когорты после марта 2026 пустые
    по построению, а не по дефекту витрины.

  Правила: read-only, MAXDOP 1, без PII. ЗАПУСКАТЬ ЦЕЛИКОМ ОТ ПЕРВОЙ СТРОКИ.
  ТЯЖЁЛЫЙ СКРИПТ: история — 11,3 млн строк. Окно ограничено @HistMonths.
==============================================================================*/

USE [Dictionaries];
SET NOCOUNT ON;

/*==============================================================================
  БАТЧ 0 — АУДИТ СХЕМЫ, отделён `GO` НАМЕРЕННО.

  Часть колонок ниже взята из канваса и на этой БД не подтверждена
  (`restructuring_v2.dlcr_gid`, `repayment_schedule.rs_source`,
  `ratings.r_report_date`, `loans.l_scheduled_closure_date`). Неверное имя
  роняет компиляцию ВСЕГО батча — тогда не отработает ни один из 13 сценариев.
  Отдельный батч гарантирует, что фактические имена будут напечатаны в любом
  случае. Ровно так это уже сработало в P7: батч 1 упал, батч 0 дал ответ.
==============================================================================*/
SELECT 'L3A_HARD' AS suite, '00_SCHEMA_AUDIT' AS scenario,
       TABLE_NAME, COLUMN_NAME, DATA_TYPE,
       ISNULL(CONVERT(varchar(20), CHARACTER_MAXIMUM_LENGTH), '') AS max_len
FROM [Dictionaries].INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'risk_analytics'
  AND (
       (TABLE_NAME = 'restructuring_v2' AND COLUMN_NAME IN
          ('dlcr_gid','dlcr$source','loan_id','restructuring_date','canc_date',
           'days_past_due_at_restructuring','payment_deferral','report_date'))
    OR (TABLE_NAME = 'repayment_schedule' AND COLUMN_NAME IN
          ('rs_loan_id','rs_source','rs_dog_num','rs_repayment_date',
           'rs_principal_repayment_amount','rs_interest_repayment_amount','rs_report_date'))
    OR (TABLE_NAME = 'ratings' AND COLUMN_NAME IN
          ('r_source','r_report_date','r_loan_rating','r_loan_rating_date',
           'r_client_rating','r_client_rating_date','r_deal_gid','r_dog_num'))
    OR (TABLE_NAME = 'loans' AND COLUMN_NAME IN
          ('l_scheduled_closure_date','l_actual_closure_date','l_loan_open_date',
           'l_loan_amount','l_borrower_id','l_rate','l_product_type'))
    OR (TABLE_NAME = 'pledges' AND COLUMN_NAME IN
          ('c_loan_gid','c_source','c_collateral_type','c_collateral_value','c_reporting_date'))
    OR (TABLE_NAME = 'borrower' AND COLUMN_NAME IN ('b_region','b_report_date'))
  )
ORDER BY TABLE_NAME, COLUMN_NAME
OPTION (MAXDOP 1);

GO

/*==============================================================================
  БАТЧ 1 — СЦЕНАРИИ H00–H12
==============================================================================*/
SET NOCOUNT ON;

DECLARE @Suite      varchar(60) = 'L3A_HARD';
DECLARE @HistMonths int  = 12;   -- глубина ряда; 19-20 доступно, 12 хватает и дешевле
DECLARE @DefaultDPD int  = 90;   -- порог дефолта, дней
DECLARE @CureMonths int  = 3;    -- горизонт «вышел из дефолта»
DECLARE @RedefMonths int = 6;    -- окно повторного дефолта после излечения
DECLARE @HaircutPct decimal(9,4) = 30.0;  -- H08: стресс падения стоимости залога
DECLARE @TopN       int  = 20;   -- H07: размер топа концентрации
DECLARE @MinCohort  int  = 50;   -- H01: минимальный размер когорты для чтения кривой

SELECT @Suite AS suite, '00_SCOPE' AS scenario,
       @HistMonths AS hist_months, @DefaultDPD AS default_dpd,
       @CureMonths AS cure_months, @RedefMonths AS redefault_months,
       @HaircutPct AS haircut_pct, @MinCohort AS min_cohort_size
OPTION (MAXDOP 1);


/*==============================================================================
  H00 — ГЕЙТ. Ключ restructuring_v2 → loans, ПО ПОКРЫТИЮ.

  От него зависят H03/H04/H05. Канвас помечает `dlcr_gid` как FK к `l_gid`,
  но пометка в канвасе — это не проверка. Прецедент свежий: `interest_rates.
  loan_id` по имени выглядел как loan_id, а оказался gid (P9d), и обратная
  ошибка стоила мне неверного вывода. Поэтому проверяем ОБА кандидата и
  печатаем покрытие, а не верим схеме.
==============================================================================*/
IF OBJECT_ID('tempdb..#lgid') IS NOT NULL DROP TABLE #lgid;
SELECT l_source, l_gid, l_loan_id, l_loan_open_date, l_loan_amount,
       l_rate AS programme, l_borrower_id, l_currency, l_product_type
INTO #lgid
FROM [Dictionaries].[risk_analytics].[loans]
WHERE l_report_date = (SELECT MAX(l_report_date) FROM [Dictionaries].[risk_analytics].[loans])
OPTION (MAXDOP 1);
CREATE CLUSTERED INDEX ix_lgid ON #lgid(l_gid);
CREATE INDEX ix_lgid_open ON #lgid(l_loan_open_date);

SELECT @Suite AS suite, 'H00_RESTR_KEY_COVERAGE' AS scenario,
       key_tested, source, restr_rows, matched_rows,
       CAST(100.0 * matched_rows / NULLIF(restr_rows, 0) AS decimal(9,4)) AS match_pct,
       CASE WHEN matched_rows = 0 THEN N'НЕ РАБОТАЕТ'
            WHEN 100.0 * matched_rows / NULLIF(restr_rows, 0) >= 95.0 THEN N'РАБОЧИЙ КЛЮЧ'
            ELSE N'ЧАСТИЧНЫЙ' END AS verdict
FROM (
    SELECT 'dlcr_gid -> l_gid' AS key_tested, r.[dlcr$source] AS source,
           COUNT_BIG(*) AS restr_rows,
           SUM(CASE WHEN g.l_gid IS NOT NULL THEN 1 ELSE 0 END) AS matched_rows
    FROM [Dictionaries].[risk_analytics].[restructuring_v2] r
    LEFT JOIN (SELECT DISTINCT l_gid FROM #lgid) g ON g.l_gid = r.dlcr_gid
    GROUP BY r.[dlcr$source]
    UNION ALL
    SELECT 'loan_id -> l_loan_id', r.[dlcr$source],
           COUNT_BIG(*),
           SUM(CASE WHEN n.l_loan_id IS NOT NULL THEN 1 ELSE 0 END)
    FROM [Dictionaries].[risk_analytics].[restructuring_v2] r
    LEFT JOIN (SELECT DISTINCT l_loan_id FROM #lgid WHERE l_loan_id IS NOT NULL) n
           ON n.l_loan_id = r.loan_id
    GROUP BY r.[dlcr$source]
) d
ORDER BY key_tested, source
OPTION (MAXDOP 1);


/*==============================================================================
  МАТЕРИАЛИЗАЦИЯ ИСТОРИИ. Окно — @HistMonths от ПОСЛЕДНЕЙ ДАТЫ КАЖДОГО
  ИСТОЧНИКА (T35: S03 опережает остальные на месяц).
==============================================================================*/
IF OBJECT_ID('tempdb..#src_last') IS NOT NULL DROP TABLE #src_last;
SELECT la_source, MAX(la_reporting_date) AS last_date
INTO #src_last
FROM [Dictionaries].[risk_analytics].[loan_account]
GROUP BY la_source
OPTION (MAXDOP 1);
CREATE CLUSTERED INDEX ix_srclast ON #src_last(la_source);

SELECT @Suite AS suite, 'H00b_HISTORY_WINDOW' AS scenario,
       la_source AS source, last_date AS latest_snapshot,
       DATEADD(MONTH, -@HistMonths, last_date) AS window_start
FROM #src_last ORDER BY source OPTION (MAXDOP 1);

IF OBJECT_ID('tempdb..#hist') IS NOT NULL DROP TABLE #hist;
SELECT a.la_source, a.la_gid, a.la_reporting_date,
       a.days_past_due, a.delinquency_bucket, a.total_balance_debt,
       /* Состояние по DPD. NULL — САМОСТОЯТЕЛЬНОЕ состояние, не ноль (T14). */
       CASE WHEN a.days_past_due IS NULL        THEN N'0_НЕТ ДАННЫХ'
            WHEN a.days_past_due <= 0           THEN N'1_БЕЗ ПРОСРОЧКИ'
            WHEN a.days_past_due <= 30          THEN N'2_1-30'
            WHEN a.days_past_due <= 60          THEN N'3_31-60'
            WHEN a.days_past_due <= @DefaultDPD THEN N'4_61-90'
            ELSE                                     N'5_90+ (ДЕФОЛТ)'
       END AS dpd_state,
       CASE WHEN a.days_past_due > @DefaultDPD THEN 1 ELSE 0 END AS is_default
INTO #hist
FROM [Dictionaries].[risk_analytics].[loan_account] a
JOIN #src_last k ON k.la_source = a.la_source
WHERE a.la_reporting_date >  DATEADD(MONTH, -@HistMonths, k.last_date)
  AND a.la_reporting_date <= k.last_date
OPTION (MAXDOP 1);
CREATE CLUSTERED INDEX ix_hist ON #hist(la_gid, la_reporting_date);
CREATE INDEX ix_hist_dt ON #hist(la_reporting_date, la_source);

/* Контроль объёма ДО тяжёлых джойнов — чтобы «пусто» не читалось как «чисто». */
SELECT @Suite AS suite, 'H00c_HISTORY_VOLUME' AS scenario,
       la_source AS source,
       COUNT_BIG(*) AS rows_in_window,
       COUNT(DISTINCT la_reporting_date) AS snapshots,
       COUNT(DISTINCT la_gid) AS distinct_contracts,
       SUM(CASE WHEN days_past_due IS NULL THEN 1 ELSE 0 END) AS dpd_null_rows
FROM #hist GROUP BY la_source ORDER BY source OPTION (MAXDOP 1);


/*==============================================================================
  H01 — VINTAGE. Когорта = месяц выдачи, возраст = месяцев на книге.

  ВЫПОЛНИМО (вопреки прежней пометке T8): когорта — статический атрибут
  `l_loan_open_date`, поведение — ряд `loan_account`. Границы печатаются:
  наблюдаемое окно упирается в @HistMonths, а когорты S03 после марта 2026
  пусты по бизнес-причине (T37), не по дефекту.
==============================================================================*/
SELECT @Suite AS suite, 'H01_VINTAGE_DEFAULT_CURVE' AS scenario,
       source, cohort_month, months_on_book,
       contracts,
       defaulted,
       CAST(100.0 * defaulted / NULLIF(contracts, 0) AS decimal(9,4)) AS default_rate_pct,
       dpd_unknown,
       CAST(100.0 * dpd_unknown / NULLIF(contracts, 0) AS decimal(9,4)) AS unknown_pct
FROM (
    SELECT h.la_source AS source,
           CONVERT(char(7), l.l_loan_open_date, 126) AS cohort_month,
           DATEDIFF(MONTH, l.l_loan_open_date, h.la_reporting_date) AS months_on_book,
           COUNT_BIG(*) AS contracts,
           SUM(h.is_default) AS defaulted,
           SUM(CASE WHEN h.days_past_due IS NULL THEN 1 ELSE 0 END) AS dpd_unknown
    FROM #hist h
    JOIN #lgid l ON l.l_gid = h.la_gid
    WHERE l.l_loan_open_date IS NOT NULL
      AND l.l_loan_open_date >= DATEADD(MONTH, -@HistMonths, h.la_reporting_date)
      AND DATEDIFF(MONTH, l.l_loan_open_date, h.la_reporting_date) BETWEEN 0 AND @HistMonths
    GROUP BY h.la_source, CONVERT(char(7), l.l_loan_open_date, 126),
             DATEDIFF(MONTH, l.l_loan_open_date, h.la_reporting_date)
) d
WHERE contracts >= @MinCohort   -- мелкие когорты статистически не читаются
ORDER BY source, cohort_month, months_on_book
OPTION (MAXDOP 1);


/*==============================================================================
  H02 — ROLL-RATE МАТРИЦА. Переходы месяц к месяцу.

  Строится ПО ДВУМ независимым измерениям — DPD-состояние и
  `delinquency_bucket`. T19 утверждает, что бакет формируется независимо от
  DPD; если это так, две матрицы разойдутся, и расхождение — результат теста,
  а не побочный эффект. Одна матрица здесь была бы недоказуемой.
==============================================================================*/
SELECT @Suite AS suite, 'H02a_ROLLRATE_BY_DPD' AS scenario,
       h0.la_source AS source,
       h0.la_reporting_date AS from_date,
       h0.dpd_state AS state_from,
       h1.dpd_state AS state_to,
       COUNT_BIG(*) AS contracts
FROM #hist h0
JOIN #hist h1 ON h1.la_gid = h0.la_gid
             AND h1.la_reporting_date = DATEADD(MONTH, 1, h0.la_reporting_date)
GROUP BY h0.la_source, h0.la_reporting_date, h0.dpd_state, h1.dpd_state
ORDER BY source, from_date, state_from, state_to
OPTION (MAXDOP 1);

SELECT @Suite AS suite, 'H02b_ROLLRATE_BY_BUCKET' AS scenario,
       h0.la_source AS source,
       h0.la_reporting_date AS from_date,
       ISNULL(CONVERT(varchar(20), h0.delinquency_bucket), '(NULL)') AS bucket_from,
       ISNULL(CONVERT(varchar(20), h1.delinquency_bucket), '(NULL)') AS bucket_to,
       COUNT_BIG(*) AS contracts
FROM #hist h0
JOIN #hist h1 ON h1.la_gid = h0.la_gid
             AND h1.la_reporting_date = DATEADD(MONTH, 1, h0.la_reporting_date)
GROUP BY h0.la_source, h0.la_reporting_date,
         ISNULL(CONVERT(varchar(20), h0.delinquency_bucket), '(NULL)'),
         ISNULL(CONVERT(varchar(20), h1.delinquency_bucket), '(NULL)')
ORDER BY source, from_date, bucket_from, bucket_to
OPTION (MAXDOP 1);

/* Прямая проверка T19: согласуются ли два измерения на ОДНОЙ строке. */
SELECT @Suite AS suite, 'H02c_DPD_VS_BUCKET_AGREEMENT' AS scenario,
       la_source AS source, dpd_state,
       ISNULL(CONVERT(varchar(20), delinquency_bucket), '(NULL)') AS delinquency_bucket,
       COUNT_BIG(*) AS rows_cnt
FROM #hist
GROUP BY la_source, dpd_state, ISNULL(CONVERT(varchar(20), delinquency_bucket), '(NULL)')
ORDER BY source, dpd_state, rows_cnt DESC
OPTION (MAXDOP 1);

/* Исчезновение из ряда — НЕ «вышел из просрочки». Считаем отдельно, иначе
   roll-rate тихо припишет выбывшие договоры к улучшению. */
SELECT @Suite AS suite, 'H02d_DISAPPEARED_FROM_SERIES' AS scenario,
       h0.la_source AS source, h0.la_reporting_date AS from_date,
       h0.dpd_state AS state_from,
       COUNT_BIG(*) AS contracts_without_next_month
FROM #hist h0
JOIN #src_last k ON k.la_source = h0.la_source
LEFT JOIN #hist h1 ON h1.la_gid = h0.la_gid
                  AND h1.la_reporting_date = DATEADD(MONTH, 1, h0.la_reporting_date)
WHERE h1.la_gid IS NULL
  AND h0.la_reporting_date < k.last_date     -- у последнего среза «следующего» нет по определению
GROUP BY h0.la_source, h0.la_reporting_date, h0.dpd_state
ORDER BY source, from_date, state_from
OPTION (MAXDOP 1);


/*==============================================================================
  H03 — CURE-RATE. Доля вышедших из 90+ БЕЗ реструктуризации.
  Прямая связь с задачей Дамира (stage3_safezone_plan.md).

  ВАЖНО: `canc_date` не заполняется нигде (T28), поэтому «реструктуризация
  отменена» учесть нельзя — любое событие считается состоявшимся.
==============================================================================*/
IF OBJECT_ID('tempdb..#restr') IS NOT NULL DROP TABLE #restr;
SELECT dlcr_gid, [dlcr$source] AS src, restructuring_date,
       days_past_due_at_restructuring, payment_deferral
INTO #restr
FROM [Dictionaries].[risk_analytics].[restructuring_v2]
WHERE dlcr_gid IS NOT NULL AND restructuring_date IS NOT NULL
OPTION (MAXDOP 1);
CREATE CLUSTERED INDEX ix_restr ON #restr(dlcr_gid, restructuring_date);

SELECT @Suite AS suite, 'H03_CURE_RATE' AS scenario,
       source, outcome,
       COUNT_BIG(*) AS contracts,
       CAST(SUM(bal) AS decimal(38,2)) AS sum_balance_at_default
FROM (
    SELECT d.la_source AS source, d.la_gid, d.total_balance_debt AS bal,
           CASE WHEN nxt.la_gid IS NULL THEN N'ВЫБЫЛ ИЗ РЯДА (не считать излечением)'
                WHEN nxt.still_default = 1 THEN N'ОСТАЛСЯ В ДЕФОЛТЕ'
                WHEN rs.dlcr_gid IS NOT NULL THEN N'ВЫШЕЛ, НО ЧЕРЕЗ РЕСТРУКТУРИЗАЦИЮ'
                ELSE N'ИЗЛЕЧИЛСЯ БЕЗ РЕСТРУКТУРИЗАЦИИ (cure)'
           END AS outcome
    FROM #hist d
    /* состояние через @CureMonths месяцев */
    OUTER APPLY (
        SELECT TOP 1 h.la_gid, h.is_default AS still_default
        FROM #hist h
        WHERE h.la_gid = d.la_gid
          AND h.la_reporting_date = DATEADD(MONTH, @CureMonths, d.la_reporting_date)
    ) nxt
    /* была ли реструктуризация в окне излечения */
    OUTER APPLY (
        SELECT TOP 1 r.dlcr_gid
        FROM #restr r
        WHERE r.dlcr_gid = d.la_gid
          AND r.restructuring_date >  d.la_reporting_date
          AND r.restructuring_date <= DATEADD(MONTH, @CureMonths, d.la_reporting_date)
    ) rs
    WHERE d.is_default = 1
) x
GROUP BY source, outcome
ORDER BY source, contracts DESC
OPTION (MAXDOP 1);


/*==============================================================================
  H04 — RE-DEFAULT после излечения, окно @RedefMonths.

  Цензурирование сделано явно: договор, пропавший из ряда, НЕ считается
  выжившим — у него отдельный исход. Именно на этом ломается наивный расчёт
  re-default (см. stage3_safezone_plan.md).
==============================================================================*/
SELECT @Suite AS suite, 'H04_REDEFAULT_AFTER_CURE' AS scenario,
       source, outcome,
       COUNT_BIG(*) AS contracts,
       CAST(100.0 * COUNT_BIG(*) / NULLIF(SUM(COUNT_BIG(*)) OVER (PARTITION BY source), 0)
            AS decimal(9,4)) AS share_pct
FROM (
    SELECT c.la_source AS source,
           CASE WHEN obs.months_observed IS NULL OR obs.months_observed < @RedefMonths
                     THEN N'ЦЕНЗУРИРОВАН (окно не наблюдалось целиком)'
                WHEN rd.la_gid IS NOT NULL THEN N'ПОВТОРНЫЙ ДЕФОЛТ'
                ELSE N'УДЕРЖАЛСЯ' END AS outcome
    FROM (
        /* момент излечения: был дефолт, через @CureMonths — нет */
        SELECT d.la_source, d.la_gid,
               DATEADD(MONTH, @CureMonths, d.la_reporting_date) AS cure_date
        FROM #hist d
        JOIN #hist n ON n.la_gid = d.la_gid
                    AND n.la_reporting_date = DATEADD(MONTH, @CureMonths, d.la_reporting_date)
                    AND n.is_default = 0
        WHERE d.is_default = 1
    ) c
    /* сколько месяцев после излечения вообще наблюдаемо */
    OUTER APPLY (
        SELECT DATEDIFF(MONTH, c.cure_date, k.last_date) AS months_observed
        FROM #src_last k WHERE k.la_source = c.la_source
    ) obs
    OUTER APPLY (
        SELECT TOP 1 h.la_gid
        FROM #hist h
        WHERE h.la_gid = c.la_gid
          AND h.la_reporting_date >  c.cure_date
          AND h.la_reporting_date <= DATEADD(MONTH, @RedefMonths, c.cure_date)
          AND h.is_default = 1
    ) rd
) x
GROUP BY source, outcome
ORDER BY source, contracts DESC
OPTION (MAXDOP 1);


/*==============================================================================
  H05 — ЭФФЕКТИВНОСТЬ РЕСТРУКТУРИЗАЦИИ: DPD до против DPD через 6/12 мес.

  Дополнительно сверяем `days_past_due_at_restructuring` из события с
  фактическим DPD из `loan_account` на ближайший срез — два независимых
  источника одной величины.
==============================================================================*/
SELECT @Suite AS suite, 'H05_RESTRUCTURING_EFFECT' AS scenario,
       source, horizon_months, dpd_state_after,
       COUNT_BIG(*) AS events,
       SUM(CASE WHEN self_reported_matches = 1 THEN 1 ELSE 0 END) AS dpd_field_agrees,
       SUM(CASE WHEN self_reported_matches = 0 THEN 1 ELSE 0 END) AS dpd_field_disagrees,
       SUM(CASE WHEN self_reported_matches IS NULL THEN 1 ELSE 0 END) AS cannot_compare
FROM (
    SELECT r.src AS source, hz.horizon_months,
           ISNULL(aft.dpd_state, N'НЕТ СРЕЗА НА ГОРИЗОНТЕ') AS dpd_state_after,
           CASE WHEN r.days_past_due_at_restructuring IS NULL OR bef.days_past_due IS NULL
                     THEN NULL
                WHEN ABS(CONVERT(decimal(18,4), r.days_past_due_at_restructuring)
                       - bef.days_past_due) <= 1 THEN 1
                ELSE 0 END AS self_reported_matches
    FROM #restr r
    CROSS APPLY (VALUES (6), (12)) hz(horizon_months)
    OUTER APPLY (
        SELECT TOP 1 h.days_past_due
        FROM #hist h
        WHERE h.la_gid = r.dlcr_gid AND h.la_reporting_date <= r.restructuring_date
        ORDER BY h.la_reporting_date DESC
    ) bef
    OUTER APPLY (
        SELECT TOP 1 h.dpd_state
        FROM #hist h
        WHERE h.la_gid = r.dlcr_gid
          AND h.la_reporting_date >= DATEADD(MONTH, hz.horizon_months, r.restructuring_date)
        ORDER BY h.la_reporting_date ASC
    ) aft
) x
GROUP BY source, horizon_months, dpd_state_after
ORDER BY source, horizon_months, events DESC
OPTION (MAXDOP 1);


/*==============================================================================
  H06 — LTV-РАСПРЕДЕЛЕНИЕ и доля LTV > 100%.

  ГРАНИЦА (D4.2, T6/T32): по S01 значение НЕ ИСПОЛЬЗУЕТСЯ. `c_collateral_id`
  коллизирует между разными объектами, агрегатное покрытие 533%, и 22% строк
  S01 — вообще не залог имущества (поручительство/страховка). Поэтому S01
  печатается ОТДЕЛЬНОЙ строкой-предупреждением, а не в общем распределении:
  иначе испорченный источник растворится в среднем по банку.
==============================================================================*/
IF OBJECT_ID('tempdb..#pl_sum') IS NOT NULL DROP TABLE #pl_sum;
SELECT c_source, c_loan_gid,
       SUM(CASE WHEN c_source = 'S01'
                 AND c_collateral_type IN (N'Поручительство', N'Страховой полис')
                THEN 0 ELSE ISNULL(c_collateral_value, 0) END) AS pledge_value_property_only,
       SUM(ISNULL(c_collateral_value, 0)) AS pledge_value_all_types
INTO #pl_sum
FROM [Dictionaries].[risk_analytics].[pledges]
WHERE c_reporting_date = (SELECT MAX(c_reporting_date) FROM [Dictionaries].[risk_analytics].[pledges])
GROUP BY c_source, c_loan_gid
OPTION (MAXDOP 1);
CREATE CLUSTERED INDEX ix_plsum ON #pl_sum(c_loan_gid);

SELECT @Suite AS suite, 'H06_LTV_DISTRIBUTION' AS scenario,
       source, ltv_bucket,
       COUNT_BIG(*) AS contracts,
       CAST(SUM(exposure) AS decimal(38,2)) AS sum_exposure,
       trust_note
FROM (
    SELECT a.la_source AS source,
           a.total_balance_debt AS exposure,
           CASE WHEN a.la_source = 'S01'
                THEN N'НЕ ИСПОЛЬЗОВАТЬ — D4.2 (коллизия c_collateral_id, покрытие 533%)'
                ELSE N'' END AS trust_note,
           CASE WHEN p.c_loan_gid IS NULL THEN N'БЕЗ ЗАЛОГА'
                WHEN p.pledge_value_property_only <= 0 THEN N'ЗАЛОГ С НУЛЕВОЙ СТОИМОСТЬЮ'
                WHEN a.total_balance_debt <= 0 THEN N'НЕТ ЭКСПОЗИЦИИ'
                WHEN 100.0 * a.total_balance_debt / p.pledge_value_property_only <= 50  THEN N'1_LTV <= 50%'
                WHEN 100.0 * a.total_balance_debt / p.pledge_value_property_only <= 80  THEN N'2_50-80%'
                WHEN 100.0 * a.total_balance_debt / p.pledge_value_property_only <= 100 THEN N'3_80-100%'
                ELSE N'4_LTV > 100% (НЕДООБЕСПЕЧЕН)'
           END AS ltv_bucket
    FROM #hist a
    JOIN #src_last k ON k.la_source = a.la_source AND k.last_date = a.la_reporting_date
    LEFT JOIN #pl_sum p ON p.c_loan_gid = a.la_gid
) d
GROUP BY source, ltv_bucket, trust_note
ORDER BY source, ltv_bucket
OPTION (MAXDOP 1);


/*==============================================================================
  H07 — КОНЦЕНТРАЦИЯ: доля ТОП-N заёмщиков.

  T15: `total_balance_debt` собирается из РАЗНЫХ доступных слагаемых
  (1818/1838 тождественно нулевые у S03/S17, P3). Поэтому концентрация
  считается ВНУТРИ источника, без межисточникового суммирования.
  PII: borrower_id не выводится — только ранг и доля.
==============================================================================*/
SELECT @Suite AS suite, 'H07_TOP_BORROWER_CONCENTRATION' AS scenario,
       source,
       COUNT_BIG(*) AS top_borrowers,
       CAST(SUM(borrower_exposure) AS decimal(38,2)) AS top_exposure,
       CAST(MAX(portfolio_total) AS decimal(38,2)) AS portfolio_total,
       CAST(100.0 * SUM(borrower_exposure) / NULLIF(MAX(portfolio_total), 0) AS decimal(9,4)) AS top_share_pct
FROM (
    SELECT b.source, b.borrower_exposure, t.portfolio_total,
           ROW_NUMBER() OVER (PARTITION BY b.source ORDER BY b.borrower_exposure DESC) AS rnk
    FROM (
        SELECT a.la_source AS source, l.l_borrower_id,
               SUM(a.total_balance_debt) AS borrower_exposure
        FROM #hist a
        JOIN #src_last k ON k.la_source = a.la_source AND k.last_date = a.la_reporting_date
        JOIN #lgid l ON l.l_gid = a.la_gid
        WHERE l.l_borrower_id IS NOT NULL
        GROUP BY a.la_source, l.l_borrower_id
    ) b
    JOIN (
        SELECT a.la_source AS source, SUM(a.total_balance_debt) AS portfolio_total
        FROM #hist a
        JOIN #src_last k ON k.la_source = a.la_source AND k.last_date = a.la_reporting_date
        GROUP BY a.la_source
    ) t ON t.source = b.source
) d
WHERE rnk <= @TopN
GROUP BY source
ORDER BY source
OPTION (MAXDOP 1);


/*==============================================================================
  H08 — СТРЕСС-ТЕСТ: падение стоимости залога на @HaircutPct.
  S01 снова отделён (D4.2): стресс по испорченной базе даст испорченный ответ.
==============================================================================*/
SELECT @Suite AS suite, 'H08_COLLATERAL_HAIRCUT_STRESS' AS scenario,
       source,
       COUNT_BIG(*) AS secured_contracts,
       CAST(SUM(exposure) AS decimal(38,2)) AS sum_exposure,
       CAST(SUM(pledge_now) AS decimal(38,2)) AS sum_pledge_now,
       CAST(SUM(pledge_stressed) AS decimal(38,2)) AS sum_pledge_stressed,
       SUM(CASE WHEN exposure > pledge_now      THEN 1 ELSE 0 END) AS uncovered_now,
       SUM(CASE WHEN exposure > pledge_stressed THEN 1 ELSE 0 END) AS uncovered_after_stress,
       CAST(SUM(CASE WHEN exposure > pledge_stressed
                     THEN exposure - pledge_stressed ELSE 0 END) AS decimal(38,2)) AS uncovered_amount_after,
       CASE WHEN source = 'S01' THEN N'НЕ ИСПОЛЬЗОВАТЬ — D4.2' ELSE N'' END AS trust_note
FROM (
    SELECT a.la_source AS source, a.total_balance_debt AS exposure,
           p.pledge_value_property_only AS pledge_now,
           p.pledge_value_property_only * (1.0 - @HaircutPct / 100.0) AS pledge_stressed
    FROM #hist a
    JOIN #src_last k ON k.la_source = a.la_source AND k.last_date = a.la_reporting_date
    JOIN #pl_sum p ON p.c_loan_gid = a.la_gid
    WHERE a.total_balance_debt > 0 AND p.pledge_value_property_only > 0
) d
GROUP BY source
ORDER BY source
OPTION (MAXDOP 1);


/*==============================================================================
  H09 — КОНЦЕНТРАЦИЯ регион × продукт × срок.

  ДВЕ ловушки сразу: продукт у S01/S02/S17 лежит НЕ в `l_product_type`, а в
  `l_rate` (бывший T9, опровергнут P2c), и регион — свободный текст с 1 087
  значениями и мохибейком (T31). Поэтому продукт берётся из обоих полей, а
  регион НЕ агрегируется как измерение — печатается только заполненность.
==============================================================================*/
SELECT @Suite AS suite, 'H09_PRODUCT_DIMENSION_SOURCE' AS scenario,
       l.l_source AS source,
       SUM(CASE WHEN l.l_product_type IS NOT NULL THEN 1 ELSE 0 END) AS from_product_type,
       SUM(CASE WHEN l.l_product_type IS NULL AND l.programme IS NOT NULL
                THEN 1 ELSE 0 END) AS from_l_rate_programme,
       SUM(CASE WHEN l.l_product_type IS NULL AND l.programme IS NULL
                THEN 1 ELSE 0 END) AS no_product_at_all,
       COUNT(DISTINCT l.programme) AS distinct_programmes,
       COUNT_BIG(*) AS loans
FROM #lgid l
GROUP BY l.l_source
ORDER BY source
OPTION (MAXDOP 1);

SELECT @Suite AS suite, 'H09b_REGION_USABILITY' AS scenario,
       region_state, borrowers
FROM (
    SELECT CASE WHEN b_region IS NULL THEN N'NULL'
                WHEN LTRIM(RTRIM(b_region)) = N'' THEN N'ПУСТАЯ СТРОКА'
                WHEN b_region LIKE N'%[?]%' THEN N'МОХИБЕЙК (потеря кодировки)'
                WHEN b_region NOT LIKE N'%[А-Яа-яA-Za-z]%' THEN N'ЧИСЛОВОЙ КОД'
                ELSE N'текстовое значение' END AS region_state,
           COUNT_BIG(*) AS borrowers
    FROM [Dictionaries].[risk_analytics].[borrower]
    WHERE b_report_date = (SELECT MAX(b_report_date) FROM [Dictionaries].[risk_analytics].[borrower])
    GROUP BY CASE WHEN b_region IS NULL THEN N'NULL'
                WHEN LTRIM(RTRIM(b_region)) = N'' THEN N'ПУСТАЯ СТРОКА'
                WHEN b_region LIKE N'%[?]%' THEN N'МОХИБЕЙК (потеря кодировки)'
                WHEN b_region NOT LIKE N'%[А-Яа-яA-Za-z]%' THEN N'ЧИСЛОВОЙ КОД'
                ELSE N'текстовое значение' END
) d
ORDER BY borrowers DESC
OPTION (MAXDOP 1);


/*==============================================================================
  H10 — МИГРАЦИЯ РЕЙТИНГОВ. Сначала — есть ли вообще история и покрытие.
  T21: рейтинги только у одного источника; L1/E21: актуальных рейтингов 559
  на 15,6 млн клиентов. Сценарий обязан показать границу до любых матриц.
==============================================================================*/
SELECT @Suite AS suite, 'H10_RATINGS_FEASIBILITY' AS scenario,
       r_source AS source,
       COUNT_BIG(*) AS rating_rows,
       COUNT(DISTINCT r_report_date) AS distinct_report_dates,
       MIN(r_report_date) AS min_date,
       MAX(r_report_date) AS max_date,
       COUNT(DISTINCT r_loan_rating_date) AS distinct_loan_rating_dates,
       SUM(CASE WHEN r_loan_rating IS NULL THEN 1 ELSE 0 END) AS loan_rating_null,
       CASE WHEN COUNT(DISTINCT r_report_date) <= 1
            THEN N'МИГРАЦИЯ НЕВЫПОЛНИМА — один срез'
            ELSE N'ряд есть, матрица строится' END AS verdict
FROM [Dictionaries].[risk_analytics].[ratings]
GROUP BY r_source
ORDER BY source
OPTION (MAXDOP 1);


/*==============================================================================
  H11 — ПЛАТЁЖНАЯ ДИСЦИПЛИНА. Сначала гейт ключа графика (T4).
  `rs_loan_id` bigint против `l_loan_id` nvarchar: JOIN без CAST дал ложные
  586 717 (L11.1). Приведение — один раз в #temp, не в условии джойна.
  Прецедент interest_rates: проверяем и gid-гипотезу тоже.
==============================================================================*/
IF OBJECT_ID('tempdb..#lid') IS NOT NULL DROP TABLE #lid;
SELECT l_source, l_gid, TRY_CONVERT(bigint, l_loan_id) AS loan_id_bigint
INTO #lid FROM #lgid
OPTION (MAXDOP 1);
CREATE CLUSTERED INDEX ix_lid ON #lid(loan_id_bigint);
CREATE INDEX ix_lid_gid ON #lid(l_gid);

SELECT @Suite AS suite, 'H11_SCHEDULE_KEY_GATE' AS scenario,
       key_tested, source, schedule_rows, matched_rows,
       CAST(100.0 * matched_rows / NULLIF(schedule_rows, 0) AS decimal(9,4)) AS match_pct
FROM (
    SELECT 'rs_loan_id -> l_loan_id (bigint)' AS key_tested, s.rs_source AS source,
           COUNT_BIG(*) AS schedule_rows,
           SUM(CASE WHEN k.loan_id_bigint IS NOT NULL THEN 1 ELSE 0 END) AS matched_rows
    FROM [Dictionaries].[risk_analytics].[repayment_schedule] s
    LEFT JOIN (SELECT DISTINCT loan_id_bigint FROM #lid WHERE loan_id_bigint IS NOT NULL) k
           ON k.loan_id_bigint = s.rs_loan_id
    GROUP BY s.rs_source
    UNION ALL
    SELECT 'rs_loan_id -> l_gid (гипотеза по аналогии с interest_rates)', s.rs_source,
           COUNT_BIG(*),
           SUM(CASE WHEN g.l_gid IS NOT NULL THEN 1 ELSE 0 END)
    FROM [Dictionaries].[risk_analytics].[repayment_schedule] s
    LEFT JOIN (SELECT DISTINCT l_gid FROM #lid) g ON g.l_gid = s.rs_loan_id
    GROUP BY s.rs_source
) d
ORDER BY key_tested, source
OPTION (MAXDOP 1);


/*==============================================================================
  H12 — ДОСРОЧНОЕ ПОГАШЕНИЕ. Граница названа явно.

  Отличить досрочное погашение от планового по суммам НЕЛЬЗЯ без сопоставления
  платежа с конкретной строкой графика, а такого ключа в витрине нет:
  `payments_wiring` ключуется по CREDIT_ACCOUNT, `repayment_schedule` — по
  rs_loan_id/rs_dog_num, общего идентификатора платежа нет. Поэтому здесь
  считается ВЕРХНЯЯ ГРАНИЦА — договоры, закрытые раньше плановой даты,
  и это честный ответ, а не суррогат.
==============================================================================*/
SELECT @Suite AS suite, 'H12_EARLY_CLOSURE_UPPER_BOUND' AS scenario,
       l_source AS source, closure_state,
       COUNT_BIG(*) AS loans,
       CAST(SUM(l_loan_amount) AS decimal(38,2)) AS sum_original_amount
FROM (
    SELECT l_source, l_loan_amount,
           CASE WHEN l_actual_closure_date IS NULL THEN N'не закрыт'
                WHEN l_scheduled_closure_date IS NULL THEN N'закрыт, плана нет'
                WHEN l_actual_closure_date < DATEADD(DAY, -30, l_scheduled_closure_date)
                     THEN N'ДОСРОЧНО (>30 дней раньше плана)'
                WHEN l_actual_closure_date < l_scheduled_closure_date
                     THEN N'раньше плана в пределах 30 дней'
                ELSE N'в срок или позже' END AS closure_state
    FROM [Dictionaries].[risk_analytics].[loans]
    WHERE l_report_date = (SELECT MAX(l_report_date) FROM [Dictionaries].[risk_analytics].[loans])
) d
GROUP BY l_source, closure_state
ORDER BY source, loans DESC
OPTION (MAXDOP 1);


/*------------------------------------------------------------------------------
  УБОРКА — немедленно (после переполнения tempdb 17.07)
------------------------------------------------------------------------------*/
IF OBJECT_ID('tempdb..#hist')     IS NOT NULL DROP TABLE #hist;
IF OBJECT_ID('tempdb..#lgid')     IS NOT NULL DROP TABLE #lgid;
IF OBJECT_ID('tempdb..#lid')      IS NOT NULL DROP TABLE #lid;
IF OBJECT_ID('tempdb..#restr')    IS NOT NULL DROP TABLE #restr;
IF OBJECT_ID('tempdb..#pl_sum')   IS NOT NULL DROP TABLE #pl_sum;
IF OBJECT_ID('tempdb..#src_last') IS NOT NULL DROP TABLE #src_last;
