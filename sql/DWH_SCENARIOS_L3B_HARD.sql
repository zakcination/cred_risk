/*==============================================================================
  DWH_SCENARIOS_L3B_HARD — сценарии H13–H25 (уровень 3, часть B)

  Завершает набор из 100 сценариев. Здесь сосредоточены сценарии, которые
  упираются в НЕПРОВЕРЕННЫЕ таблицы (`collections`, `offbalance`, `writeoff`,
  `brm_all_data`) и в межбазовую сверку. Для них главный результат теста —
  не число, а установленная граница: что именно нельзя посчитать и почему.
  Сценарий, честно вернувший «невыполнимо, вот причина», для приёмки DWH
  ценнее, чем сценарий, вернувший правдоподобное число из битого ключа.

  ЧТО ИЗМЕНИЛОСЬ ПОСЛЕ ПРОБ (FINDINGS §10–§14) И УЧТЕНО ЗДЕСЬ:
  - `loan_account` историзован (19–20 срезов) — H18 строит настоящий тренд DPD,
    а не отбивается ловушкой T8. Но `pledges` историзации НЕ имеет, поэтому
    «падение оценки залога» в том же H18 невыполнимо — граница проходит ВНУТРИ
    одного сценария, и это печатается явно.
  - Сетка дат разная по источникам (T35) — везде последняя дата КАЖДОГО.
  - `days_past_due` NULL ≠ 0 (T14): отдельное состояние.
  - `writeoff` покрывает только S01/S03 (домен `w_dlcr$source`), то есть
    резолюшн-пайплайн H21 физически не может быть полным для S02/S17.
  - `payments_wiring` ключуется по `CREDIT_ACCOUNT` — общего идентификатора
    платежа с графиком нет, поэтому H14 считает НЕТТО и ВАЛОВОЕ отклонение
    раздельно: встречные отклонения гасят друг друга и нетто врёт.

  Правила: read-only, MAXDOP 1, без PII (номера договоров, ИИН, ФИО и названия
  коллекторских компаний не выводятся — только агрегаты).
  ЗАПУСКАТЬ ЦЕЛИКОМ ОТ ПЕРВОЙ СТРОКИ (Msg 137).
==============================================================================*/

USE [Dictionaries];
SET NOCOUNT ON;

/*==============================================================================
  БАТЧ 0 — АУДИТ СХЕМЫ непроверенных таблиц, отделён `GO` НАМЕРЕННО.

  `collections`, `offbalance`, `credit_lines`, `brm_all_data` ни разу не
  проверялись в этом проекте — в DWH_TEST_SCENARIOS.md они прямо числятся в
  разделе «что набор НЕ покрывает». Имена колонок взяты из канваса и на этой
  БД не подтверждены. Если батч 1 упадёт на `Msg 207 Invalid column name` —
  это ожидаемый режим: возьмите фактические имена отсюда и поправьте.
==============================================================================*/
SELECT 'L3B_HARD' AS suite, '00_SCHEMA_AUDIT' AS scenario,
       TABLE_NAME, COLUMN_NAME, DATA_TYPE,
       ISNULL(CONVERT(varchar(20), CHARACTER_MAXIMUM_LENGTH), '') AS max_len
FROM [Dictionaries].INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'risk_analytics'
  AND TABLE_NAME IN ('collections','offbalance','writeoff','brm_all_data',
                     'credit_lines','payments','payments_wiring',
                     'repayment_schedule','loan_account','borrower')
  AND (COLUMN_NAME LIKE '%source%' OR COLUMN_NAME LIKE '%gid%'
    OR COLUMN_NAME LIKE '%loan_id%' OR COLUMN_NAME LIKE '%dog_num%'
    OR COLUMN_NAME LIKE '%date%'    OR COLUMN_NAME LIKE '%amount%'
    OR COLUMN_NAME LIKE '%group%'   OR COLUMN_NAME LIKE '%contract%'
    OR COLUMN_NAME LIKE '%total%'   OR COLUMN_NAME LIKE '%balance%')
ORDER BY TABLE_NAME, COLUMN_NAME
OPTION (MAXDOP 1);

GO

/*==============================================================================
  БАТЧ 1 — СЦЕНАРИИ H13–H25
==============================================================================*/
SET NOCOUNT ON;

DECLARE @Suite       varchar(60) = 'L3B_HARD';
DECLARE @LoansAsOf   date = (SELECT MAX(l_report_date) FROM [Dictionaries].[risk_analytics].[loans]);
DECLARE @ForecastMon int = 12;    -- H13: горизонт прогноза денежного потока
DECLARE @GapTolPct   decimal(9,4) = 5.0;   -- H14: допуск отклонения план/факт, %
DECLARE @TrendMonths int = 6;     -- H18: окно тренда DPD
DECLARE @Dpd90       int = 90;    -- H15: порог просрочки, не хардкод в теле
DECLARE @PledgeDate  date = (SELECT MAX(c_reporting_date) FROM [Dictionaries].[risk_analytics].[pledges]);

SELECT @Suite AS suite, '00_SCOPE' AS scenario, @LoansAsOf AS loans_asof,
       @ForecastMon AS forecast_months, @GapTolPct AS gap_tolerance_pct,
       @TrendMonths AS trend_months
OPTION (MAXDOP 1);


/*------------------------------------------------------------------------------
  МАТЕРИАЛИЗАЦИЯ. Последняя дата КАЖДОГО источника (T35).
------------------------------------------------------------------------------*/
IF OBJECT_ID('tempdb..#hb_srclast') IS NOT NULL DROP TABLE #hb_srclast;
SELECT la_source, MAX(la_reporting_date) AS last_date
INTO #hb_srclast FROM [Dictionaries].[risk_analytics].[loan_account] GROUP BY la_source
OPTION (MAXDOP 1);
CREATE CLUSTERED INDEX ix_srclast ON #hb_srclast(la_source);

IF OBJECT_ID('tempdb..#hb_acct') IS NOT NULL DROP TABLE #hb_acct;
SELECT a.la_source, a.la_gid, a.la_reporting_date, a.days_past_due,
       a.delinquency_bucket, a.total_balance_debt
INTO #hb_acct
FROM [Dictionaries].[risk_analytics].[loan_account] a
JOIN #hb_srclast k ON k.la_source = a.la_source
WHERE a.la_reporting_date > DATEADD(MONTH, -@TrendMonths, k.last_date)
  AND a.la_reporting_date <= k.last_date
OPTION (MAXDOP 1);
CREATE CLUSTERED INDEX ix_acct ON #hb_acct(la_gid, la_reporting_date);

/* Только ПОСЛЕДНИЙ снимок каждого источника. Отдельная таблица нужна потому,
   что LEFT JOIN к #hb_acct без этого фильтра даёт до @TrendMonths строк на договор
   и молча множит любые COUNT/SUM по портфелю. */
IF OBJECT_ID('tempdb..#hb_acctlast') IS NOT NULL DROP TABLE #hb_acctlast;
SELECT a.la_source, a.la_gid, a.la_reporting_date, a.days_past_due,
       a.delinquency_bucket, a.total_balance_debt
INTO #hb_acctlast
FROM #hb_acct a
JOIN #hb_srclast k ON k.la_source = a.la_source AND k.last_date = a.la_reporting_date
OPTION (MAXDOP 1);
CREATE CLUSTERED INDEX ix_acctlast ON #hb_acctlast(la_gid);

IF OBJECT_ID('tempdb..#hb_ln') IS NOT NULL DROP TABLE #hb_ln;
SELECT l_source, l_gid, l_loan_id, l_loan_number, l_borrower_id,
       l_loan_amount, l_actual_closure_date
INTO #hb_ln FROM [Dictionaries].[risk_analytics].[loans] WHERE l_report_date = @LoansAsOf
OPTION (MAXDOP 1);
CREATE CLUSTERED INDEX ix_ln ON #hb_ln(l_gid);
CREATE INDEX ix_ln_num ON #hb_ln(l_source, l_loan_number);


/*==============================================================================
  H13 — ПРОГНОЗ ДЕНЕЖНОГО ПОТОКА на @ForecastMon месяцев.

  ГЛАВНАЯ ЛОВУШКА сценария не в самой сумме, а в том, что договоры БЕЗ графика
  выпадут из прогноза МОЛЧА. Поэтому сначала печатается покрытие графиком, и
  только потом — сам поток. Прогноз без знаменателя не является прогнозом.
==============================================================================*/
IF OBJECT_ID('tempdb..#hb_sched') IS NOT NULL DROP TABLE #hb_sched;
SELECT DISTINCT rs_source, rs_loan_id
INTO #hb_sched FROM [Dictionaries].[risk_analytics].[repayment_schedule]
WHERE rs_loan_id IS NOT NULL
OPTION (MAXDOP 1);
CREATE CLUSTERED INDEX ix_sk ON #hb_sched(rs_loan_id);

/* Покрытие графиком проверяем по ОБЕИМ гипотезам ключа: rs_loan_id как
   loan_id (T4) и как gid (по прецеденту interest_rates, P9d). */
SELECT @Suite AS suite, 'H13a_SCHEDULE_COVERAGE' AS scenario,
       key_hypothesis, source, active_loans, loans_with_schedule,
       CAST(100.0 * loans_with_schedule / NULLIF(active_loans, 0) AS decimal(9,4)) AS coverage_pct
FROM (
    SELECT 'rs_loan_id = l_loan_id (bigint)' AS key_hypothesis,
           l.l_source AS source, COUNT_BIG(*) AS active_loans,
           SUM(CASE WHEN s.rs_loan_id IS NOT NULL THEN 1 ELSE 0 END) AS loans_with_schedule
    FROM (SELECT l_source, TRY_CONVERT(bigint, l_loan_id) AS k FROM #hb_ln) l
    LEFT JOIN (SELECT DISTINCT rs_loan_id FROM #hb_sched) s ON s.rs_loan_id = l.k
    GROUP BY l.l_source
    UNION ALL
    SELECT 'rs_loan_id = l_gid', l.l_source, COUNT_BIG(*),
           SUM(CASE WHEN s.rs_loan_id IS NOT NULL THEN 1 ELSE 0 END)
    FROM #hb_ln l
    LEFT JOIN (SELECT DISTINCT rs_loan_id FROM #hb_sched) s ON s.rs_loan_id = l.l_gid
    GROUP BY l.l_source
) d
ORDER BY key_hypothesis, source
OPTION (MAXDOP 1);

/* Сам поток. Ключ НЕ фиксируем — печатаем сумму по источнику графика, без
   джойна к портфелю: пока H13a не назовёт рабочий ключ, привязка к портфелю
   была бы вымышленной. */
SELECT @Suite AS suite, 'H13b_SCHEDULED_CASHFLOW' AS scenario,
       rs_source AS source,
       CONVERT(char(7), rs_repayment_date, 126) AS repayment_month,
       COUNT_BIG(*) AS installments,
       CAST(SUM(ISNULL(rs_principal_repayment_amount, 0)) AS decimal(38,2)) AS principal_due,
       CAST(SUM(ISNULL(rs_interest_repayment_amount, 0))  AS decimal(38,2)) AS interest_due
FROM [Dictionaries].[risk_analytics].[repayment_schedule]
WHERE rs_repayment_date >  @LoansAsOf
  AND rs_repayment_date <= DATEADD(MONTH, @ForecastMon, @LoansAsOf)
GROUP BY rs_source, CONVERT(char(7), rs_repayment_date, 126)
ORDER BY source, repayment_month
OPTION (MAXDOP 1);


/*==============================================================================
  H14 — РАЗРЫВ ПЛАН/ФАКТ на уровне портфеля.

  НЕТТО и ВАЛОВОЕ отклонение считаются РАЗДЕЛЬНО и намеренно. Нетто-разрыв
  близкий к нулю не означает, что план исполняется: недоплата по одним
  договорам гасит переплату по другим. Только валовая величина показывает
  реальный масштаб расхождения.
==============================================================================*/
SELECT @Suite AS suite, 'H14_PLAN_VS_FACT_BY_MONTH' AS scenario,
       ym AS month, source,
       CAST(planned AS decimal(38,2)) AS planned_amount,
       CAST(actual  AS decimal(38,2)) AS actual_amount,
       CAST(actual - planned AS decimal(38,2)) AS net_gap,
       CAST(ABS(actual - planned) AS decimal(38,2)) AS gross_gap,
       CAST(100.0 * (actual - planned) / NULLIF(planned, 0) AS decimal(9,4)) AS net_gap_pct,
       CASE WHEN planned = 0 THEN N'нет плана на месяц'
            WHEN ABS(100.0 * (actual - planned) / NULLIF(planned, 0)) <= @GapTolPct
                 THEN N'в допуске'
            ELSE N'ВНЕ ДОПУСКА' END AS verdict
FROM (
    SELECT COALESCE(p.ym, f.ym) AS ym, COALESCE(p.src, f.src) AS source,
           ISNULL(p.planned, 0) AS planned, ISNULL(f.actual, 0) AS actual
    FROM (
        SELECT rs_source AS src, CONVERT(char(7), rs_repayment_date, 126) AS ym,
               SUM(ISNULL(rs_principal_repayment_amount, 0)
                 + ISNULL(rs_interest_repayment_amount, 0)) AS planned
        FROM [Dictionaries].[risk_analytics].[repayment_schedule]
        WHERE rs_repayment_date >  DATEADD(MONTH, -@ForecastMon, @LoansAsOf)
          AND rs_repayment_date <= @LoansAsOf
        GROUP BY rs_source, CONVERT(char(7), rs_repayment_date, 126)
    ) p
    FULL OUTER JOIN (
        SELECT p_source AS src, CONVERT(char(7), p_VALUE_DATE, 126) AS ym,
               SUM(ISNULL(p_TOTAL, 0)) AS actual
        FROM [Dictionaries].[risk_analytics].[payments]
        WHERE p_VALUE_DATE >  DATEADD(MONTH, -@ForecastMon, @LoansAsOf)
          AND p_VALUE_DATE <= @LoansAsOf
        GROUP BY p_source, CONVERT(char(7), p_VALUE_DATE, 126)
    ) f ON f.src = p.src AND f.ym = p.ym
) d
ORDER BY source, month
OPTION (MAXDOP 1);


/*==============================================================================
  H15 — ДОСТАТОЧНОСТЬ ОБЕСПЕЧЕНИЯ ПОД 90+. Регуляторно значимая цифра.

  T13 (off-by-one) здесь двигает результат напрямую, поэтому 90+ отбирается
  ПО ОБОИМ определениям рядом. S01 отделён (D4.2): по нему цифра непригодна.

  ПОРЯДОК ОПЕРАЦИЙ — не стиль, а причина зависания. В первой редакции
  `CROSS APPLY (VALUES …)` стоял ДО фильтра `is_90 = 1`. Конструктор VALUES
  ссылается на внешнюю колонку, поэтому предикат вычисляется уже после
  размножения: план читал весь последний срез портфеля целиком, для каждой
  строки ходил в `#hb_plsum`, удваивал результат — и только потом выбрасывал
  почти всё как не-90+. 09.08 прогон на этом месте не вернулся.

  Фильтр поднят к источнику. Второе определение — строгое ПОДМНОЖЕСТВО
  первого (`dpd - 1 > 90` ⇔ `dpd > 91`), поэтому одного предиката
  `days_past_due > @Dpd90` достаточно для обеих выборок, а различие между ними
  считается уже на отобранном наборе. Цифры прежние, объём работы — нет.
==============================================================================*/
IF OBJECT_ID('tempdb..#hb_plsum') IS NOT NULL DROP TABLE #hb_plsum;
SELECT c_loan_gid,
       SUM(CASE WHEN c_source = 'S01'
                 AND c_collateral_type IN (N'Поручительство', N'Страховой полис')
                THEN 0 ELSE ISNULL(c_collateral_value, 0) END) AS pledge_property_only
INTO #hb_plsum
FROM [Dictionaries].[risk_analytics].[pledges]
WHERE c_reporting_date = @PledgeDate
GROUP BY c_loan_gid
OPTION (MAXDOP 1);
CREATE CLUSTERED INDEX ix_plsum ON #hb_plsum(c_loan_gid);

SELECT @Suite AS suite, 'H15_UNCOVERED_EXPOSURE_90PLUS' AS scenario,
       source, dpd_definition,
       COUNT_BIG(*) AS contracts_90plus,
       CAST(SUM(exposure) AS decimal(38,2)) AS exposure_90plus,
       CAST(SUM(pledge) AS decimal(38,2)) AS pledge_value,
       CAST(SUM(CASE WHEN exposure > pledge THEN exposure - pledge ELSE 0 END)
            AS decimal(38,2)) AS uncovered_exposure,
       SUM(CASE WHEN pledge = 0 THEN 1 ELSE 0 END) AS contracts_without_pledge,
       CASE WHEN source = 'S01' THEN N'НЕ ИСПОЛЬЗОВАТЬ — D4.2' ELSE N'' END AS trust_note
FROM (
    SELECT b.source, d.dpd_definition, b.exposure, b.pledge
    FROM (
        SELECT a.la_source AS source, a.days_past_due,
               ISNULL(a.total_balance_debt, 0) AS exposure,
               ISNULL(p.pledge_property_only, 0) AS pledge
        FROM #hb_acctlast a
        LEFT JOIN #hb_plsum p ON p.c_loan_gid = a.la_gid
        WHERE a.days_past_due > @Dpd90        -- отбор ДО размножения
    ) b
    CROSS APPLY (VALUES
        (N'days_past_due > 90 (сырое поле)', CASE WHEN b.days_past_due     > @Dpd90 THEN 1 ELSE 0 END),
        (N'days_past_due - 1 > 90 (T13)',    CASE WHEN b.days_past_due - 1 > @Dpd90 THEN 1 ELSE 0 END)
    ) d(dpd_definition, is_90)
    WHERE d.is_90 = 1
) x
GROUP BY source, dpd_definition
ORDER BY source, dpd_definition
OPTION (MAXDOP 1);


/*==============================================================================
  H16 — РЕЗЕРВЫ: фактические против расчётных от стоимости залога.

  ГРАНИЦА: P3 показала, что `la_account_1401` тождественно нулевой у всех
  четырёх источников, а 1818/1838 нулевые у S03/S17 — то есть состав
  «фактического резерва» по источникам РАЗНЫЙ (T15). Строим не сравнение
  «факт против расчёта», а карту доступных слагаемых: без неё сравнение
  измеряло бы разницу состава, а не разницу резервов.
==============================================================================*/
SELECT @Suite AS suite, 'H16_PROVISION_COMPONENTS_MAP' AS scenario,
       a.la_source AS source, k.last_date AS effective_date, gl_account,
       COUNT_BIG(*) AS accounts,
       SUM(CASE WHEN v IS NULL THEN 1 ELSE 0 END) AS is_null,
       SUM(CASE WHEN v = 0 THEN 1 ELSE 0 END) AS is_zero,
       SUM(CASE WHEN v <> 0 THEN 1 ELSE 0 END) AS is_nonzero,
       CAST(SUM(ISNULL(v, 0)) AS decimal(38,2)) AS sum_value
FROM (
    SELECT a.la_source, a.la_reporting_date, g.gl_account,
           CASE g.gl_account WHEN '1428'  THEN a.la_account_1428
                             WHEN '18771' THEN a.la_account_18771
                             WHEN '1818'  THEN a.la_account_1818
                             ELSE              a.la_account_1838 END AS v
    FROM [Dictionaries].[risk_analytics].[loan_account] a
    JOIN #hb_srclast k0 ON k0.la_source = a.la_source
                     AND k0.last_date = a.la_reporting_date   -- фильтр ДО размножения
    CROSS JOIN (VALUES ('1428'),('18771'),('1818'),('1838')) g(gl_account)
) a
JOIN #hb_srclast k ON k.la_source = a.la_source AND k.last_date = a.la_reporting_date
GROUP BY a.la_source, k.last_date, gl_account
ORDER BY source, gl_account
OPTION (MAXDOP 1);


/*==============================================================================
  H17 — ГРУППЫ СВЯЗАННЫХ ЛИЦ.

  ГРАНИЦА: `b_group_affiliation` имеет тип `text`, формат не документирован.
  Парсить неизвестный формат = придумывать данные. Поэтому сценарий отвечает
  на предшествующий вопрос: пригодно ли поле как измерение вообще —
  заполненность, мощность, длина. Ответ «нет» здесь тоже результат.
==============================================================================*/
SELECT @Suite AS suite, 'H17_GROUP_AFFILIATION_USABILITY' AS scenario,
       field_state,
       COUNT_BIG(*) AS borrowers,
       MIN(val_len) AS min_len, MAX(val_len) AS max_len
FROM (
    SELECT CASE WHEN b_group_affiliation IS NULL THEN N'NULL'
                WHEN LEN(CONVERT(nvarchar(4000), b_group_affiliation)) = 0
                     THEN N'ПУСТАЯ СТРОКА'
                WHEN CONVERT(nvarchar(4000), b_group_affiliation) LIKE N'%[,;|]%'
                     THEN N'СПИСОК С РАЗДЕЛИТЕЛЕМ (формат не документирован)'
                ELSE N'одиночное значение' END AS field_state,
           LEN(CONVERT(nvarchar(4000), b_group_affiliation)) AS val_len
    FROM [Dictionaries].[risk_analytics].[borrower]
    WHERE b_report_date = (SELECT MAX(b_report_date) FROM [Dictionaries].[risk_analytics].[borrower])
) d
GROUP BY field_state
ORDER BY borrowers DESC
OPTION (MAXDOP 1);


/*==============================================================================
  H18 — EARLY WARNING: рост DPD + реструктуризация + падение оценки залога.

  ГРАНИЦА ПРОХОДИТ ВНУТРИ СЦЕНАРИЯ. Два из трёх сигналов выполнимы:
  тренд DPD — по истории `loan_account` (@TrendMonths срезов), факт
  реструктуризации — по `restructuring_v2`. Третий, «падение оценки залога»,
  НЕВЫПОЛНИМ: у `pledges` одна отчётная дата, сравнивать не с чем.
  Поэтому третий сигнал заменён на статический признак «оценка устарела/
  отсутствует» (T33) и помечен как НЕ тренд.
==============================================================================*/
SELECT @Suite AS suite, 'H18_EARLY_WARNING_SIGNALS' AS scenario,
       source, signals_count, dpd_worsening, has_restructuring, stale_appraisal,
       COUNT_BIG(*) AS contracts,
       CAST(SUM(exposure) AS decimal(38,2)) AS sum_exposure
FROM (
    SELECT cur.la_source AS source,
           ISNULL(cur.total_balance_debt, 0) AS exposure,
           CASE WHEN cur.days_past_due IS NOT NULL AND old.days_past_due IS NOT NULL
                 AND cur.days_past_due > old.days_past_due THEN 1 ELSE 0 END AS dpd_worsening,
           CASE WHEN rs.dlcr_gid IS NOT NULL THEN 1 ELSE 0 END AS has_restructuring,
           CASE WHEN pl.no_appraisal = 1 THEN 1 ELSE 0 END AS stale_appraisal,
           CASE WHEN cur.days_past_due IS NOT NULL AND old.days_past_due IS NOT NULL
                 AND cur.days_past_due > old.days_past_due THEN 1 ELSE 0 END
         + CASE WHEN rs.dlcr_gid IS NOT NULL THEN 1 ELSE 0 END
         + CASE WHEN pl.no_appraisal = 1 THEN 1 ELSE 0 END AS signals_count
    FROM #hb_acctlast cur
    LEFT JOIN #hb_acct old ON old.la_gid = cur.la_gid
                       AND old.la_reporting_date = DATEADD(MONTH, -@TrendMonths + 1, cur.la_reporting_date)
    OUTER APPLY (
        SELECT TOP 1 r.dlcr_gid FROM [Dictionaries].[risk_analytics].[restructuring_v2] r
        WHERE r.dlcr_gid = cur.la_gid
          AND r.restructuring_date > DATEADD(MONTH, -@TrendMonths, cur.la_reporting_date)
    ) rs
    OUTER APPLY (
        SELECT MAX(CASE WHEN p.last_appraisal_date IS NULL THEN 1 ELSE 0 END) AS no_appraisal
        FROM [Dictionaries].[risk_analytics].[pledges] p
        WHERE p.c_loan_gid = cur.la_gid
          AND p.c_reporting_date = (SELECT MAX(c_reporting_date) FROM [Dictionaries].[risk_analytics].[pledges])
    ) pl
) d
GROUP BY source, signals_count, dpd_worsening, has_restructuring, stale_appraisal
ORDER BY source, signals_count DESC, contracts DESC
OPTION (MAXDOP 1);


/*==============================================================================
  H19 — РИСК-ПРОФИЛЬ КАНАЛОВ ВЫДАЧИ.

  СМЕЩЕНИЕ ВЫБОРКИ названо явно: разные каналы продают разные продукты, и
  разница в дефолтности может быть продуктовой, а не «качеством канала».
  Поэтому рядом с дефолтностью печатается число программ на канал — без него
  сравнение каналов некорректно.
  PII: ФИО консультанта не выводится, только счётчики.
==============================================================================*/
SELECT @Suite AS suite, 'H19_CHANNEL_RISK_PROFILE' AS scenario,
       source, channel_size_bucket,
       COUNT_BIG(*) AS channels,
       SUM(loans) AS loans,
       SUM(defaulted) AS defaulted,
       CAST(100.0 * SUM(defaulted) / NULLIF(SUM(loans), 0) AS decimal(9,4)) AS default_rate_pct,
       CAST(AVG(1.0 * programmes) AS decimal(18,2)) AS avg_programmes_per_channel
FROM (
    SELECT l.l_source AS source, l.l_financial_consultant,
           COUNT_BIG(*) AS loans,
           COUNT(DISTINCT l.l_rate) AS programmes,
           SUM(CASE WHEN a.days_past_due > 90 THEN 1 ELSE 0 END) AS defaulted,
           CASE WHEN COUNT_BIG(*) < 10 THEN N'1_<10 договоров'
                WHEN COUNT_BIG(*) < 100 THEN N'2_10-99'
                WHEN COUNT_BIG(*) < 1000 THEN N'3_100-999'
                ELSE N'4_1000+' END AS channel_size_bucket
    FROM [Dictionaries].[risk_analytics].[loans] l
    LEFT JOIN #hb_acctlast a ON a.la_gid = l.l_gid   -- ровно один снимок на договор
    WHERE l.l_report_date = @LoansAsOf
      AND l.l_financial_consultant IS NOT NULL
      AND LTRIM(RTRIM(l.l_financial_consultant)) <> N''
    GROUP BY l.l_source, l.l_financial_consultant
) d
GROUP BY source, channel_size_bucket
ORDER BY source, channel_size_bucket
OPTION (MAXDOP 1);


/*==============================================================================
  H20 — ВЛИЯНИЕ ОТСРОЧКИ на исход договора.

  ЕДИНИЦА `payment_deferral` НЕ ДОКУМЕНТИРОВАНА (L1/E35: диапазон 0–14 у S03,
  0–6 у S01, 100% NULL у S02). Считать «месяцы» или «платежи» — догадка,
  поэтому величина используется КАК БАКЕТ, без интерпретации единицы, и это
  сказано в выводе.
==============================================================================*/
SELECT @Suite AS suite, 'H20_DEFERRAL_VS_OUTCOME' AS scenario,
       source, deferral_bucket, outcome_state,
       COUNT_BIG(*) AS events
FROM (
    SELECT r.[dlcr$source] AS source,
           CASE WHEN r.payment_deferral IS NULL THEN N'(NULL)'
                WHEN r.payment_deferral = 0 THEN N'0'
                WHEN r.payment_deferral <= 3 THEN N'1-3 (единица не документирована)'
                WHEN r.payment_deferral <= 6 THEN N'4-6'
                ELSE N'7+' END AS deferral_bucket,
           ISNULL(cur.dpd_state, N'НЕТ В СЧЁТНОМ СЛОЕ') AS outcome_state
    FROM [Dictionaries].[risk_analytics].[restructuring_v2] r
    OUTER APPLY (
        SELECT TOP 1
               CASE WHEN a.days_past_due IS NULL THEN N'0_НЕТ ДАННЫХ'
                    WHEN a.days_past_due <= 0    THEN N'1_БЕЗ ПРОСРОЧКИ'
                    WHEN a.days_past_due <= 90   THEN N'2_1-90'
                    ELSE                              N'3_90+ (ДЕФОЛТ)' END AS dpd_state
        FROM #hb_acctlast a
        WHERE a.la_gid = r.dlcr_gid
    ) cur
    WHERE r.dlcr_gid IS NOT NULL
) d
GROUP BY source, deferral_bucket, outcome_state
ORDER BY source, deferral_bucket, events DESC
OPTION (MAXDOP 1);



GO
/*==============================================================================
  БАТЧ 2 — H21–H22 (writeoff / collections).

  Отделён `GO` НАМЕРЕННО: `writeoff` и `collections` не проверялись
  в проекте ни разу — они прямо числятся в разделе «что набор НЕ покрывает».
  Имена там взяты из канваса и на этой БД не подтверждены, а неверное имя
  роняет ВЕСЬ батч. Отдельный батч ограничивает потери одним блоком вместо
  тринадцати сценариев. #temp живут в пределах сессии и переживают GO,
  поэтому материализация выше переиспользуется; заново объявляются только
  переменные (их область видимости — батч, Msg 137).
==============================================================================*/
SET NOCOUNT ON;
DECLARE @Suite varchar(60) = 'L3B_HARD';
DECLARE @LoansAsOf date = (SELECT MAX(l_report_date) FROM [Dictionaries].[risk_analytics].[loans]);

/*==============================================================================
  H21 — РЕЗОЛЮШН-ПАЙПЛАЙН: активный → 90+ → collections → writeoff → offbalance.

  ГРАНИЦА ИЗВЕСТНА ЗАРАНЕЕ и печатается как результат: домен `w_dlcr$source`
  у `writeoff` — только S01/S03, то есть пайплайн физически не покрывает
  S02/S17. Плюс `writeoff` — 84 строки на весь банк при неподтверждённом grain
  (T20), а `collections`/`offbalance` не проверялись ни разу.
  Поэтому здесь строится ПАСПОРТ каждой ступени (объём, домен source, даты),
  а не сквозная воронка: воронка по непроверенным ключам дала бы красивое
  число ни о чём.
==============================================================================*/
SELECT @Suite AS suite, 'H21_RESOLUTION_STAGE_INVENTORY' AS scenario,
       stage, source, rows_cnt, min_date, max_date
FROM (
    SELECT '1_writeoff' AS stage, [w_dlcr$source] AS source, COUNT_BIG(*) AS rows_cnt,
           MIN([w_dm_z10$report_date]) AS min_date, MAX([w_dm_z10$report_date]) AS max_date
    FROM [Dictionaries].[risk_analytics].[writeoff] GROUP BY [w_dlcr$source]
    UNION ALL
    SELECT '2_collections', N'(в таблице нет колонки source)', COUNT_BIG(*),
           MIN(c_sale_date), MAX(c_sale_date)
    FROM [Dictionaries].[risk_analytics].[collections]
) d
ORDER BY stage, source
OPTION (MAXDOP 1);

/* Сколько 90+ вообще доходит до списания — по ЕДИНСТВЕННОМУ ключу writeoff,
   который есть (gid). Отдельно печатаем источники, где ступень отсутствует. */
SELECT @Suite AS suite, 'H21b_90PLUS_TO_WRITEOFF' AS scenario,
       a.la_source AS source,
       COUNT_BIG(*) AS contracts_90plus,
       SUM(CASE WHEN w.w_dlcrp_dlcr_gid IS NOT NULL THEN 1 ELSE 0 END) AS reached_writeoff,
       CASE WHEN a.la_source IN ('S02','S17')
            THEN N'СТУПЕНЬ ОТСУТСТВУЕТ — writeoff не покрывает этот источник'
            ELSE N'' END AS coverage_note
FROM #hb_acctlast a
LEFT JOIN (SELECT DISTINCT w_dlcrp_dlcr_gid FROM [Dictionaries].[risk_analytics].[writeoff]
           WHERE w_dlcrp_dlcr_gid IS NOT NULL) w
       ON w.w_dlcrp_dlcr_gid = a.la_gid
WHERE a.days_past_due > 90
GROUP BY a.la_source
ORDER BY source
OPTION (MAXDOP 1);


/*==============================================================================
  H22 — RECOVERY RATE по списанным договорам.
  Вопрос сводится к проверяемому: попадают ли поступления ПОСЛЕ даты списания
  в `payments`. Если нет — recovery по витрине не считается в принципе.
==============================================================================*/
SELECT @Suite AS suite, 'H22_POST_WRITEOFF_RECOVERY' AS scenario,
       w.[w_dlcr$source] AS source,
       COUNT_BIG(*) AS writeoff_records,
       SUM(CASE WHEN pay.payments_after IS NULL OR pay.payments_after = 0
                THEN 1 ELSE 0 END) AS no_payments_after_writeoff,
       SUM(ISNULL(pay.payments_after, 0)) AS payment_rows_after,
       CAST(SUM(ISNULL(pay.amount_after, 0)) AS decimal(38,2)) AS recovered_amount,
       CAST(SUM(ISNULL(w.w_dlcrp_write_off_amount, 0)) AS decimal(38,2)) AS written_off_amount
FROM [Dictionaries].[risk_analytics].[writeoff] w
LEFT JOIN #hb_ln l ON l.l_gid = w.w_dlcrp_dlcr_gid
OUTER APPLY (
    SELECT COUNT_BIG(*) AS payments_after, SUM(ISNULL(p.p_TOTAL, 0)) AS amount_after
    FROM [Dictionaries].[risk_analytics].[payments] p
    WHERE p.p_source = w.[w_dlcr$source]
      AND p.p_VALUE_DATE > w.[w_dlcrp_operation_is_write_off]
      AND l.l_loan_number IS NOT NULL
      AND p.p_dog_num = l.l_loan_number
) pay
GROUP BY w.[w_dlcr$source]
ORDER BY source
OPTION (MAXDOP 1);



GO
/*==============================================================================
  БАТЧ 3 — H23 (витрина brm_all_data).

  Отделён `GO` НАМЕРЕННО: на срезе схемы у `brm_all_data` видно всего
  три колонки (FINDINGS §11 п.7) — остальные имена неизвестны.
  Имена там взяты из канваса и на этой БД не подтверждены, а неверное имя
  роняет ВЕСЬ батч. Отдельный батч ограничивает потери одним блоком вместо
  тринадцати сценариев. #temp живут в пределах сессии и переживают GO,
  поэтому материализация выше переиспользуется; заново объявляются только
  переменные (их область видимости — батч, Msg 137).
==============================================================================*/
SET NOCOUNT ON;
DECLARE @Suite varchar(60) = 'L3B_HARD';
DECLARE @LoansAsOf date = (SELECT MAX(l_report_date) FROM [Dictionaries].[risk_analytics].[loans]);

/*==============================================================================
  H23 — СВЕРКА ВИТРИНЫ `brm_all_data` С ИСХОДНЫМИ ТАБЛИЦАМИ.
  На срезе схемы видно всего 3 колонки (FINDINGS §11 п.7) — значит сверять
  суммы нечем. Проверяем то, что проверяемо: периметр и грануляцию.
==============================================================================*/
SELECT @Suite AS suite, 'H23a_MART_GRAIN' AS scenario,
       source, actual_date,
       COUNT_BIG(*) AS rows_cnt,
       COUNT(DISTINCT contract_number) AS distinct_contracts,
       COUNT_BIG(*) - COUNT(DISTINCT contract_number) AS excess_rows
FROM [Dictionaries].[risk_analytics].[brm_all_data]
GROUP BY source, actual_date
ORDER BY source, actual_date DESC
OPTION (MAXDOP 1);

/* Периметр витрины против `loans` по номеру договора — В ПАРЕ С SOURCE (T18). */
SELECT @Suite AS suite, 'H23b_MART_VS_LOANS_PERIMETER' AS scenario,
       bucket, source, contracts
FROM (
    SELECT N'ЕСТЬ В ВИТРИНЕ, НЕТ В loans' AS bucket, m.source,
           COUNT(DISTINCT m.contract_number) AS contracts
    FROM [Dictionaries].[risk_analytics].[brm_all_data] m
    LEFT JOIN #hb_ln l ON l.l_source = m.source AND l.l_loan_number = m.contract_number
    WHERE l.l_gid IS NULL
    GROUP BY m.source
    UNION ALL
    SELECT N'ЕСТЬ В loans, НЕТ В ВИТРИНЕ', l.l_source,
           COUNT(DISTINCT l.l_loan_number)
    FROM #hb_ln l
    LEFT JOIN (SELECT DISTINCT source, contract_number FROM [Dictionaries].[risk_analytics].[brm_all_data]) m
           ON m.source = l.l_source AND m.contract_number = l.l_loan_number
    WHERE m.contract_number IS NULL AND l.l_loan_number IS NOT NULL
    GROUP BY l.l_source
) d
ORDER BY bucket, source
OPTION (MAXDOP 1);



GO
/*==============================================================================
  БАТЧ 4 — H24–H25 (borrower / cross-db).

  Отделён `GO` НАМЕРЕННО: предыдущие два батча опираются на непроверенные
  таблицы, и их падение не должно уносить с собой эти два сценария.
  Имена там взяты из канваса и на этой БД не подтверждены, а неверное имя
  роняет ВЕСЬ батч. Отдельный батч ограничивает потери одним блоком вместо
  тринадцати сценариев. #temp живут в пределах сессии и переживают GO,
  поэтому материализация выше переиспользуется; заново объявляются только
  переменные (их область видимости — батч, Msg 137).
==============================================================================*/
SET NOCOUNT ON;
DECLARE @Suite varchar(60) = 'L3B_HARD';
DECLARE @LoansAsOf date = (SELECT MAX(l_report_date) FROM [Dictionaries].[risk_analytics].[loans]);

/*==============================================================================
  H24 — СОГЛАСОВАННОСТЬ АТРИБУТОВ ОДНОГО КЛИЕНТА.

  ТОЧНАЯ ФОРМУЛИРОВКА: тест ловит расхождение между ЗАПИСЯМИ одного ИИН/БИН.
  Назвать это «расхождением между источниками» было бы переоценкой: несколько
  записей на один ИИН могут принадлежать и одному источнику (M32 показал такие
  дубли). Поэтому рядом печатается число источников на клиента — только оно
  отделяет межисточниковое расхождение от внутриисточникового.
  PII: ИИН/БИН только для группировки, наружу идут счётчики (правило CLAUDE.md).
==============================================================================*/
SELECT @Suite AS suite, 'H24_CLIENT_ATTRIBUTE_CONSISTENCY' AS scenario,
       attribute, consistency_state,
       COUNT_BIG(*) AS distinct_clients
FROM (
    SELECT N'b_borrower_type' AS attribute,
           CASE WHEN COUNT(DISTINCT ISNULL(b_borrower_type, N'∅')) > 1
                THEN N'РАСХОДИТСЯ МЕЖДУ ЗАПИСЯМИ ОДНОГО ИИН/БИН' ELSE N'согласован' END AS consistency_state,
           b_iin_bin
    FROM [Dictionaries].[risk_analytics].[borrower]
    WHERE b_report_date = (SELECT MAX(b_report_date) FROM [Dictionaries].[risk_analytics].[borrower])
      AND b_iin_bin IS NOT NULL AND LTRIM(RTRIM(b_iin_bin)) <> N''
    GROUP BY b_iin_bin
    UNION ALL
    SELECT N'b_region',
           CASE WHEN COUNT(DISTINCT ISNULL(b_region, N'∅')) > 1
                THEN N'РАСХОДИТСЯ МЕЖДУ ЗАПИСЯМИ ОДНОГО ИИН/БИН' ELSE N'согласован' END,
           b_iin_bin
    FROM [Dictionaries].[risk_analytics].[borrower]
    WHERE b_report_date = (SELECT MAX(b_report_date) FROM [Dictionaries].[risk_analytics].[borrower])
      AND b_iin_bin IS NOT NULL AND LTRIM(RTRIM(b_iin_bin)) <> N''
    GROUP BY b_iin_bin
    UNION ALL
    SELECT N'b_date_of_birth',
           CASE WHEN COUNT(DISTINCT b_date_of_birth) > 1
                THEN N'РАСХОДИТСЯ МЕЖДУ ЗАПИСЯМИ ОДНОГО ИИН/БИН' ELSE N'согласован' END,
           b_iin_bin
    FROM [Dictionaries].[risk_analytics].[borrower]
    WHERE b_report_date = (SELECT MAX(b_report_date) FROM [Dictionaries].[risk_analytics].[borrower])
      AND b_iin_bin IS NOT NULL AND LTRIM(RTRIM(b_iin_bin)) <> N''
    GROUP BY b_iin_bin
) d
GROUP BY attribute, consistency_state
ORDER BY attribute, distinct_clients DESC
OPTION (MAXDOP 1);


/*==============================================================================
  H25 — ПОЛНОТА DWH ПРОТИВ СТАРОЙ ВЕТКИ `CL_PORTFOLIO`.

  ГРАНИЦА, установленная заранее (CLAUDE.md → «Подключение»): cross-db работает
  только в пределах одного инстанса. Если запрос ниже упадёт с ошибкой доступа
  к `CL_PORTFOLIO` — это НАХОДКА, а не сбой скрипта: значит сверка требует
  linked server или two-pass выгрузки, и это надо закладывать в план миграции.
  Раскомментируйте блок, только если обе БД на одном инстансе.
==============================================================================*/
SELECT @Suite AS suite, 'H25_CROSS_DB_FEASIBILITY' AS scenario,
       DB_NAME() AS current_db,
       CASE WHEN DB_ID('CL_PORTFOLIO') IS NULL
            THEN N'CL_PORTFOLIO НЕ ВИДНА С ЭТОГО ИНСТАНСА — нужен linked server / two-pass'
            ELSE N'обе БД на одном инстансе — сверка выполнима одним запросом'
       END AS verdict,
       @@SERVERNAME AS server_name
OPTION (MAXDOP 1);

/*  Раскомментировать ТОЛЬКО если H25 выше вернул «выполнима»:

SELECT @Suite AS suite, 'H25b_PERIMETER_OLD_VS_NEW' AS scenario,
       bucket, contracts
FROM (
    SELECT N'ONLY_NEW (нет в старой ветке)' AS bucket, COUNT_BIG(*) AS contracts
    FROM #hb_ln l
    WHERE NOT EXISTS (SELECT 1 FROM [CL_PORTFOLIO].[dbo].[<таблица>] o
                      WHERE o.<номер> = l.l_loan_number)
) d
OPTION (MAXDOP 1);
*/


/*------------------------------------------------------------------------------
  УБОРКА — немедленно
------------------------------------------------------------------------------*/
IF OBJECT_ID('tempdb..#hb_acct')       IS NOT NULL DROP TABLE #hb_acct;
IF OBJECT_ID('tempdb..#hb_acctlast')  IS NOT NULL DROP TABLE #hb_acctlast;
IF OBJECT_ID('tempdb..#hb_ln')         IS NOT NULL DROP TABLE #hb_ln;
IF OBJECT_ID('tempdb..#hb_srclast')   IS NOT NULL DROP TABLE #hb_srclast;
IF OBJECT_ID('tempdb..#hb_sched') IS NOT NULL DROP TABLE #hb_sched;
IF OBJECT_ID('tempdb..#hb_plsum')     IS NOT NULL DROP TABLE #hb_plsum;
