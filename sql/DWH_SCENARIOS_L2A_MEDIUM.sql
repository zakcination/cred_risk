/*==============================================================================
  DWH_SCENARIOS_L2A_MEDIUM — сценарии M01–M20 (уровень 2, часть A)

  Исполняемая версия из `docs/analysis/risk_dwh_reconciliation/
  DWH_TEST_SCENARIOS.md`. Уровень 2 проверяет КЛЮЧИ, КАРДИНАЛЬНОСТЬ и
  ЦЕЛОСТНОСТЬ связей — то, чего уровень 1 не трогает.

  ПОЧЕМУ ЧЕРЕЗ #temp, А НЕ НАПРЯМУЮ. Коррелированный `NOT EXISTS`, у которого
  внутренняя (пересканируемая) сторона обёрнута в CONVERT/CAST, делает JOIN
  non-sargable и вызывает полный пересчёт на каждую внешнюю строку. В этом
  проекте это дважды приводило к зависанию прогона на 2+ часа (L11.1, L4.1).
  Здесь везде один и тот же безопасный паттерн: ключ материализуется в
  индексированный #temp ОДИН раз, дальше сравниваются голые значения.

  НА ЧЁМ СТОЯТ ДЖОЙНЫ (подтверждено живыми прогонами этой сессии):
  - `*_gid = l_gid` — канонический путь. `l_gid` глобально уникален: коллизий
    между source НЕТ (CASE_RUN_011 A1/A2), поэтому джойн только по gid
    безопасен, а source — избыточная, но безвредная страховка.
  - `borrower` НЕ имеет gid — только `borrower_id` (T16). При этом
    `loans_active.l_borrower_id` уже bigint, как и `b_borrower_id`, а вот
    `loans.l_borrower_id` — varchar (T3). Досье строится на `loans_active`
    именно поэтому: там приведение типов не нужно.
  - `l_collateral_id` → pledges ОПРОВЕРГНУТ (T1). Только `c_loan_gid`.

  Правила: read-only, MAXDOP 1, без PII (gid/borrower_id — технические
  идентификаторы; ИИН/ФИО/номера договоров/IBAN не выводятся). @AsOf — от факта.
==============================================================================*/

USE [Dictionaries];
SET NOCOUNT ON;

DECLARE @Suite varchar(60) = 'L2A_MEDIUM';
DECLARE @AsOf  date = (SELECT MAX(l_report_date) FROM [Dictionaries].[risk_analytics].[loans_active]);

/* M01: если NULL — тестовый клиент выбирается автоматически (см. M01a).
   Задайте вручную, чтобы построить досье по конкретному клиенту. */
DECLARE @TestBorrowerId bigint = NULL;

SELECT @Suite AS suite, '00_SCOPE' AS scenario, @AsOf AS resolved_asof OPTION (MAXDOP 1);


/*==============================================================================
  МАТЕРИАЛИЗАЦИЯ (один раз, переиспользуется всеми M01–M20)
==============================================================================*/
IF OBJECT_ID('tempdb..#la') IS NOT NULL DROP TABLE #la;
SELECT l_source, l_gid, l_borrower_id, l_loan_id, l_collateral_id,
       l_loan_amount, l_rate, l_initial_term_months, l_product_type,
       l_loan_status, l_currency, l_loan_open_date, l_loan_maturity_date
INTO #la
FROM [Dictionaries].[risk_analytics].[loans_active]
WHERE l_report_date = @AsOf
OPTION (MAXDOP 1);
CREATE CLUSTERED INDEX ix_la_gid ON #la(l_gid);
CREATE INDEX ix_la_borrower ON #la(l_borrower_id);
CREATE INDEX ix_la_loanid ON #la(l_loan_id);

/* ИСПРАВЛЕНО ПОСЛЕ ПРОБЫ P1 (T26/T35). Было `WHERE la_reporting_date = @AsOf`,
   и это ТИХО оставляло один S03: на 2026-08-01 остальные три источника в
   loan_account отсутствуют, потому что загружены на месяц раньше. Шесть
   сценариев (M01c, M01d, M05, M07, M11, M20) показали бы S01/S02/S17 как
   «нет баланса» — тот самый режим отказа, который проба и вскрыла.
   Берём последнюю дату КАЖДОГО источника и печатаем её явно. */
IF OBJECT_ID('tempdb..#src_last') IS NOT NULL DROP TABLE #src_last;
SELECT la_source, MAX(la_reporting_date) AS last_date
INTO #src_last FROM [Dictionaries].[risk_analytics].[loan_account] GROUP BY la_source
OPTION (MAXDOP 1);
CREATE CLUSTERED INDEX ix_srclast ON #src_last(la_source);

IF OBJECT_ID('tempdb..#acct') IS NOT NULL DROP TABLE #acct;
IF OBJECT_ID('tempdb..#src_last') IS NOT NULL DROP TABLE #src_last;
IF OBJECT_ID('tempdb..#ir') IS NOT NULL DROP TABLE #ir;
SELECT a.la_source, a.la_gid, a.la_reporting_date,
       a.total_balance_debt, a.principal_balance_debt,
       a.days_past_due, a.delinquency_bucket
INTO #acct
FROM [Dictionaries].[risk_analytics].[loan_account] a
JOIN #src_last k ON k.la_source = a.la_source AND k.last_date = a.la_reporting_date
OPTION (MAXDOP 1);
CREATE CLUSTERED INDEX ix_acct_gid ON #acct(la_gid);

SELECT @Suite AS suite, '00b_ACCOUNT_EFFECTIVE_DATES' AS scenario,
       la_source AS source, last_date AS effective_date,
       CASE WHEN last_date = @AsOf THEN 'совпадает с loans'
            ELSE 'СЕТКА СДВИНУТА относительно loans' END AS grid_state
FROM #src_last ORDER BY source OPTION (MAXDOP 1);

/* Ставка живёт НЕ в loans (P7a): `l_rate` — название кредитной программы.
   Настоящая ставка — в interest_rates, ключ `loan_id = l_gid` (100%, P9d). */
IF OBJECT_ID('tempdb..#ir') IS NOT NULL DROP TABLE #ir;
SELECT loan_id AS l_gid, interest_rate, effective_rate, initial_nominal_rate
INTO #ir FROM [Dictionaries].[risk_analytics].[interest_rates] WHERE loan_id IS NOT NULL
OPTION (MAXDOP 1);
CREATE CLUSTERED INDEX ix_ir ON #ir(l_gid);

IF OBJECT_ID('tempdb..#pl') IS NOT NULL DROP TABLE #pl;
SELECT c_source, c_loan_gid, c_collateral_id, c_bpm_object_id,
       c_collateral_value, c_market_collateral_value, last_appraisal_date,
       /* Идентичность объекта: bpm — надёжный (bigint), c_collateral_id —
          float и КОЛЛИЗИРУЕТ у S01 (T6). float приводится через bigint,
          иначе SQL Server рендерит его в научной нотации и разные ID
          схлопнутся в одну строку. */
       COALESCE(N'BPM:' + CAST(c_bpm_object_id AS nvarchar(30)),
                N'CID:' + CAST(CAST(c_collateral_id AS bigint) AS nvarchar(30))) AS object_key
INTO #pl
FROM [Dictionaries].[risk_analytics].[pledges]
WHERE c_reporting_date = @AsOf
OPTION (MAXDOP 1);
CREATE CLUSTERED INDEX ix_pl_gid ON #pl(c_loan_gid);

IF OBJECT_ID('tempdb..#restr') IS NOT NULL DROP TABLE #restr;
SELECT [dlcr$source] AS r_source, dlcr_gid, restructuring_date, new_interest_rate,
       new_maturity_date, canc_date, payment_deferral,
       grace_od_begin_date, grace_od_end_date, grace_int_begin_date, grace_int_end_date
INTO #restr
FROM [Dictionaries].[risk_analytics].[restructuring_v2]
WHERE dlcr_gid IS NOT NULL
OPTION (MAXDOP 1);
CREATE CLUSTERED INDEX ix_restr_gid ON #restr(dlcr_gid);


/*==============================================================================
  M01 — ПОЛНОЕ ДОСЬЕ ПО ОДНОМУ КЛИЕНТУ (флагманский сценарий)
  Задействует 5 таблиц через 3 разных паттерна ключа. Тест не в том, что
  запрос вернёт строки, а в том, ЧТО ИМЕННО не подтянется: рейтинг (T21 —
  только один источник), залог (T1 — не по l_collateral_id), баланс.
==============================================================================*/
IF @TestBorrowerId IS NULL
    SELECT TOP (1) @TestBorrowerId = k.l_borrower_id
    FROM #la k
    WHERE k.l_borrower_id IS NOT NULL
      AND EXISTS (SELECT 1 FROM #pl p WHERE p.c_loan_gid = k.l_gid)
    GROUP BY k.l_borrower_id
    ORDER BY COUNT(*) DESC, k.l_borrower_id;

SELECT @Suite AS suite, 'M01a_TEST_BORROWER_PICKED' AS scenario,
       @TestBorrowerId AS borrower_id,
       CASE WHEN @TestBorrowerId IS NULL
            THEN N'НЕ НАЙДЕН клиент с активным договором И залогом — сам по себе результат'
            ELSE N'клиент выбран: максимум активных договоров среди имеющих залог' END AS pick_rule
OPTION (MAXDOP 1);

SELECT @Suite AS suite, 'M01b_CLIENT_PROFILE' AS scenario,
       b.b_borrower_id, b.b_borrower_type, b.b_region, b.b_client_rating,
       b.b_client_rating_date, b.b_bankruptcy_flag, b.b_poci_flag,
       b.b_active_loans_count AS declared_active_loans,
       b.b_closed_loans_count AS declared_closed_loans
FROM [Dictionaries].[risk_analytics].[borrower] b
WHERE b.b_report_date = @AsOf AND b.b_borrower_id = @TestBorrowerId
OPTION (MAXDOP 1);

SELECT @Suite AS suite, 'M01c_CLIENT_LOANS' AS scenario,
       k.l_source, k.l_gid, k.l_product_type, k.l_loan_status, k.l_currency,
       CAST(k.l_loan_amount AS decimal(38,2)) AS loan_amount,
       /* ИСПРАВЛЕНО ПОСЛЕ P2c/P7a: `l_rate` — это НАЗВАНИЕ КРЕДИТНОЙ ПРОГРАММЫ,
          а не ставка (0 конвертируемых из 8 259 299). Отдаём его как программу,
          а ставку берём из interest_rates. Прежние колонки rate_numeric /
          rate_unparseable_raw были бы NULL и «мусор» на 100% строк. */
       k.l_rate AS programme,
       ir.interest_rate AS nominal_rate,
       ir.effective_rate AS effective_rate_gesv,
       CASE WHEN ir.l_gid IS NULL THEN N'СТАВКИ НЕТ (покрытие 48,9%, T45)'
            WHEN ir.interest_rate <= 1 THEN N'ШКАЛА (0;1] — доля? см. T40'
            ELSE N'шкала (1;100]' END AS rate_scale_note,
       k.l_initial_term_months, k.l_loan_open_date, k.l_loan_maturity_date,
       a.la_reporting_date AS balance_as_of,
       CAST(a.total_balance_debt AS decimal(38,2)) AS balance,
       a.days_past_due, a.delinquency_bucket,
       (SELECT COUNT_BIG(DISTINCT p.object_key) FROM #pl p WHERE p.c_loan_gid = k.l_gid) AS distinct_collateral_objects,
       (SELECT CAST(SUM(x.c_collateral_value) AS decimal(38,2))
          FROM (SELECT DISTINCT p2.object_key, p2.c_collateral_value
                  FROM #pl p2 WHERE p2.c_loan_gid = k.l_gid) x) AS collateral_value_dedup,
       r.r_loan_rating, r.r_client_rating
FROM #la k
LEFT JOIN #acct a ON a.la_gid = k.l_gid
LEFT JOIN #ir   ir ON ir.l_gid = k.l_gid
LEFT JOIN [Dictionaries].[risk_analytics].[ratings] r ON r.r_deal_gid = k.l_gid AND r.r_report_date = @AsOf
WHERE k.l_borrower_id = @TestBorrowerId
OPTION (MAXDOP 1);

/* Что из досье НЕ подтянулось — главный вывод M01 */
/* Флаги считаются в производной таблице t, агрегация — уже НАД
   материализованными столбцами. Коррелированный EXISTS в одной области
   видимости с голым COUNT_BIG(*) без GROUP BY даёт Msg 130 у этого движка. */
SELECT @Suite AS suite, 'M01d_DOSSIER_COVERAGE_GAPS' AS scenario,
       COUNT_BIG(*) AS client_loans,
       SUM(no_account)   AS loans_without_account_row,
       SUM(no_rating)    AS loans_without_rating_T21,
       SUM(no_pledge)    AS loans_without_pledge,
       SUM(null_coll_id) AS loans_with_null_collateral_id_T11
FROM (
    SELECT CASE WHEN a.la_gid IS NULL THEN 1 ELSE 0 END AS no_account,
           CASE WHEN r.r_deal_gid IS NULL THEN 1 ELSE 0 END AS no_rating,
           CASE WHEN EXISTS (SELECT 1 FROM #pl p WHERE p.c_loan_gid = k.l_gid)
                THEN 0 ELSE 1 END AS no_pledge,
           CASE WHEN k.l_collateral_id IS NULL THEN 1 ELSE 0 END AS null_coll_id
    FROM #la k
    LEFT JOIN #acct a ON a.la_gid = k.l_gid
    LEFT JOIN [Dictionaries].[risk_analytics].[ratings] r ON r.r_deal_gid = k.l_gid AND r.r_report_date = @AsOf
    WHERE k.l_borrower_id = @TestBorrowerId
) t
OPTION (MAXDOP 1);


/*==============================================================================
  M02 — Клиенты с более чем одной реструктуризацией
  Агрегация на уровне КЛИЕНТА, не договора: у одного клиента могут быть
  разные договоры, каждый со своей реструктуризацией.
==============================================================================*/
SELECT @Suite AS suite, 'M02_CLIENTS_MULTI_RESTRUCTURING' AS scenario,
       restr_bucket, COUNT_BIG(*) AS clients
FROM (
    SELECT k.l_borrower_id,
           CASE WHEN COUNT(*) = 1 THEN '1 реструктуризация'
                WHEN COUNT(*) BETWEEN 2 AND 3 THEN '2-3'
                WHEN COUNT(*) BETWEEN 4 AND 5 THEN '4-5'
                ELSE '6+' END AS restr_bucket
    FROM #la k
    INNER JOIN #restr r ON r.dlcr_gid = k.l_gid
    WHERE k.l_borrower_id IS NOT NULL
    GROUP BY k.l_borrower_id
) t
GROUP BY restr_bucket ORDER BY restr_bucket OPTION (MAXDOP 1);


/*==============================================================================
  M03 — Договоры с более чем одним залогом
  ДВА счёта намеренно рядом: по c_collateral_id и по object_key (bpm).
  Расхождение = мера коллизии T6, а не разные «мнения» о данных.
==============================================================================*/
SELECT @Suite AS suite, 'M03_LOANS_MULTI_COLLATERAL' AS scenario,
       c_source AS source,
       SUM(CASE WHEN by_cid  > 1 THEN 1 ELSE 0 END) AS loans_multi_by_collateral_id,
       SUM(CASE WHEN by_bpm  > 1 THEN 1 ELSE 0 END) AS loans_multi_by_bpm_object,
       SUM(CASE WHEN by_cid > 1 AND by_bpm = 1 THEN 1 ELSE 0 END) AS false_multi_ONLY_ID_DIFFERS,
       COUNT_BIG(*) AS loans_with_any_pledge
FROM (
    SELECT p.c_source, p.c_loan_gid,
           COUNT(DISTINCT p.c_collateral_id) AS by_cid,
           COUNT(DISTINCT p.c_bpm_object_id) AS by_bpm
    FROM #pl p
    WHERE EXISTS (SELECT 1 FROM #la k WHERE k.l_gid = p.c_loan_gid)
    GROUP BY p.c_source, p.c_loan_gid
) g
GROUP BY c_source ORDER BY source OPTION (MAXDOP 1);


/*==============================================================================
  M04 — Один залог под несколькими договорами (общее обеспечение)
  Легитимный паттерн ИЛИ та же коллизия в другой форме — различает bpm.
==============================================================================*/
SELECT @Suite AS suite, 'M04_SHARED_COLLATERAL' AS scenario,
       c_source AS source, verdict, COUNT_BIG(*) AS collateral_id_groups
FROM (
    SELECT p.c_source, p.c_collateral_id,
           CASE WHEN SUM(CASE WHEN p.c_bpm_object_id IS NULL THEN 1 ELSE 0 END) > 0
                     THEN 'BPM ПУСТ — ПРОВЕРИТЬ НЕЧЕМ (T7)'
                WHEN COUNT(DISTINCT p.c_bpm_object_id) = 1
                     THEN 'НАСТОЯЩЕЕ совместное обеспечение'
                ELSE 'КОЛЛИЗИЯ ID, не совместное обеспечение (T6)' END AS verdict
    FROM #pl p
    WHERE p.c_collateral_id IS NOT NULL
      AND EXISTS (SELECT 1 FROM #la k WHERE k.l_gid = p.c_loan_gid)
    GROUP BY p.c_source, p.c_collateral_id
    HAVING COUNT(DISTINCT p.c_loan_gid) > 1
) t
GROUP BY c_source, verdict ORDER BY source, verdict OPTION (MAXDOP 1);


/*==============================================================================
  M05 — Договоров на клиента + сверка с b_active_loans_count
  Прямой тест внутренней согласованности справочника.
==============================================================================*/
SELECT @Suite AS suite, 'M05_LOANS_PER_CLIENT_VS_DECLARED' AS scenario,
       agreement, COUNT_BIG(*) AS clients
FROM (
    SELECT k.l_borrower_id,
           CASE WHEN b.b_borrower_id IS NULL THEN 'КЛИЕНТА НЕТ В СПРАВОЧНИКЕ'
                WHEN b.b_active_loans_count IS NULL THEN 'СЧЁТЧИК NULL'
                WHEN b.b_active_loans_count = COUNT(*) THEN 'СХОДИТСЯ'
                WHEN b.b_active_loans_count > COUNT(*) THEN 'СПРАВОЧНИК ЗАВЫШАЕТ'
                ELSE 'СПРАВОЧНИК ЗАНИЖАЕТ' END AS agreement
    FROM #la k
    LEFT JOIN [Dictionaries].[risk_analytics].[borrower] b
           ON b.b_borrower_id = k.l_borrower_id AND b.b_report_date = @AsOf
    WHERE k.l_borrower_id IS NOT NULL
    GROUP BY k.l_borrower_id, b.b_borrower_id, b.b_active_loans_count
) t
GROUP BY agreement ORDER BY clients DESC OPTION (MAXDOP 1);


/*==============================================================================
  M06 — Портфель и остаток: регион × продукт (T9 + T15 одновременно)
==============================================================================*/
SELECT TOP (100) @Suite AS suite, 'M06_REGION_X_PRODUCT' AS scenario,
       ISNULL(b.b_region, N'(регион NULL)') AS region,
       ISNULL(k.l_product_type, N'(продукт NULL — T9)') AS product_type,
       k.l_source AS source,
       COUNT_BIG(*) AS loans,
       CAST(SUM(a.total_balance_debt) AS decimal(38,2)) AS balance_NOT_COMPARABLE_ACROSS_SOURCES_T15
FROM #la k
LEFT JOIN [Dictionaries].[risk_analytics].[borrower] b
       ON b.b_borrower_id = k.l_borrower_id AND b.b_report_date = @AsOf
LEFT JOIN #acct a ON a.la_gid = k.l_gid
GROUP BY ISNULL(b.b_region, N'(регион NULL)'),
         ISNULL(k.l_product_type, N'(продукт NULL — T9)'), k.l_source
ORDER BY loans DESC OPTION (MAXDOP 1);


/*==============================================================================
  M07 — Ставка по продукту. ПЕРЕПИСАН ПОСЛЕ ПРОБ P2/P7/P8/P9.

  ЧТО БЫЛО НЕ ТАК. Сценарий считал AVG и взвешенную среднюю по
  `TRY_CONVERT(decimal, l_rate)` с фильтром `... IS NOT NULL`. После P2b
  известно, что таких строк **ноль из 8 259 299** — запрос гарантированно
  возвращал пустой результат. Плюс продукт брался из `l_product_type`, который
  NULL у S01/S02/S17, тогда как продуктовое измерение лежит в `l_rate`.

  ЧТО ТЕПЕРЬ. Продукт = программа из `l_rate`; ставка = `interest_rates`
  по ключу `loan_id = l_gid`. Среднее НЕ считается по смешанному набору:
  T40 доказал две шкалы внутри одной программы (229 программ / 1 720 575
  договоров). Средние выводятся ОТДЕЛЬНО в каждой шкале — среднее внутри одной
  шкалы осмысленно, среднее по смеси занижено и бессмысленно.
==============================================================================*/
SELECT @Suite AS suite, 'M07_RATE_BY_PROGRAMME' AS scenario,
       source, rate_scale,
       COUNT_BIG(*) AS programmes,
       SUM(loans_priced) AS loans_priced,
       CAST(SUM(sum_rate) / NULLIF(SUM(loans_priced), 0) AS decimal(18,4)) AS simple_avg_rate,
       CAST(SUM(sum_rate_x_bal) / NULLIF(SUM(sum_bal), 0) AS decimal(18,4)) AS balance_weighted_rate
FROM (
    SELECT k.l_source AS source,
           k.l_rate AS programme,
           CASE WHEN ir.interest_rate <= 1 THEN N'(0;1] — доля?'
                ELSE N'(1;100] — проценты' END AS rate_scale,
           COUNT_BIG(*) AS loans_priced,
           SUM(ir.interest_rate) AS sum_rate,
           SUM(ir.interest_rate * a.total_balance_debt) AS sum_rate_x_bal,
           SUM(a.total_balance_debt) AS sum_bal
    FROM #la k
    INNER JOIN #ir   ir ON ir.l_gid = k.l_gid
    INNER JOIN #acct a  ON a.la_gid = k.l_gid
    WHERE ir.interest_rate IS NOT NULL AND ir.interest_rate > 0
      AND a.total_balance_debt > 0
    GROUP BY k.l_source, k.l_rate,
           CASE WHEN ir.interest_rate <= 1 THEN N'(0;1] — доля?'
                ELSE N'(1;100] — проценты' END
) d
GROUP BY source, rate_scale
ORDER BY source, rate_scale
OPTION (MAXDOP 1);

/* Сколько активных договоров вообще получат ставку — знаменатель к M07.
   Без него «средняя ставка» читается как «по портфелю», а она по 48,9%. */
SELECT @Suite AS suite, 'M07b_RATE_COVERAGE' AS scenario,
       k.l_source AS source,
       COUNT_BIG(*) AS active_loans,
       SUM(CASE WHEN ir.l_gid IS NOT NULL THEN 1 ELSE 0 END) AS with_rate,
       CAST(100.0 * SUM(CASE WHEN ir.l_gid IS NOT NULL THEN 1 ELSE 0 END)
            / NULLIF(COUNT_BIG(*), 0) AS decimal(9,4)) AS coverage_pct
FROM #la k
LEFT JOIN #ir ir ON ir.l_gid = k.l_gid
GROUP BY k.l_source ORDER BY source OPTION (MAXDOP 1);


/*==============================================================================
  M08 — Покрытие залогом (дедуп по объекту — иначе T6 надувает сумму)
==============================================================================*/
IF OBJECT_ID('tempdb..#cov') IS NOT NULL DROP TABLE #cov;
SELECT c_loan_gid, SUM(v) AS collateral_value_dedup
INTO #cov
FROM (
    SELECT DISTINCT p.c_loan_gid, p.object_key, p.c_collateral_value AS v
    FROM #pl p
    WHERE EXISTS (SELECT 1 FROM #la k WHERE k.l_gid = p.c_loan_gid)
) d
GROUP BY c_loan_gid
OPTION (MAXDOP 1);
CREATE CLUSTERED INDEX ix_cov ON #cov(c_loan_gid);

SELECT @Suite AS suite, 'M08_COLLATERAL_COVERAGE' AS scenario,
       k.l_source AS source,
       COUNT_BIG(*) AS loans,
       SUM(CASE WHEN c.c_loan_gid IS NOT NULL THEN 1 ELSE 0 END) AS loans_with_collateral,
       CAST(SUM(ISNULL(c.collateral_value_dedup,0)) AS decimal(38,2)) AS sum_collateral,
       CAST(SUM(k.l_loan_amount) AS decimal(38,2)) AS sum_loan_amount,
       CAST(100.0 * SUM(ISNULL(c.collateral_value_dedup,0))
            / NULLIF(SUM(k.l_loan_amount),0) AS decimal(10,2)) AS coverage_pct
FROM #la k
LEFT JOIN #cov c ON c.c_loan_gid = k.l_gid
GROUP BY k.l_source ORDER BY source OPTION (MAXDOP 1);


/*==============================================================================
  M09 — l_collateral_id заполнен, но строки в pledges нет (T1/T11)
==============================================================================*/
SELECT @Suite AS suite, 'M09_HAS_COLLATERAL_ID_NO_PLEDGE' AS scenario,
       source, id_state, pledge_state, COUNT_BIG(*) AS loans
FROM (
    SELECT k.l_source AS source,
           CASE WHEN k.l_collateral_id IS NOT NULL THEN 'ID ЕСТЬ' ELSE 'ID ПУСТ (T11)' END AS id_state,
           CASE WHEN EXISTS (SELECT 1 FROM #pl p WHERE p.c_loan_gid = k.l_gid)
                THEN 'ЗАЛОГ НАЙДЕН ПО GID' ELSE 'ЗАЛОГА НЕТ' END AS pledge_state
    FROM #la k
) t
GROUP BY source, id_state, pledge_state
ORDER BY source, id_state, pledge_state OPTION (MAXDOP 1);


/*==============================================================================
  M10 — Залоги без договора: «закрыт» vs истинный orphan
==============================================================================*/
IF OBJECT_ID('tempdb..#master_gid') IS NOT NULL DROP TABLE #master_gid;
SELECT DISTINCT l_gid INTO #master_gid
FROM [Dictionaries].[risk_analytics].[loans] WHERE l_report_date = @AsOf
OPTION (MAXDOP 1);
CREATE UNIQUE CLUSTERED INDEX ix_mg ON #master_gid(l_gid);

SELECT @Suite AS suite, 'M10_ORPHAN_PLEDGES' AS scenario,
       source, orphan_class, COUNT_BIG(*) AS pledge_rows
FROM (
    SELECT p.c_source AS source,
           CASE WHEN p.c_loan_gid IS NULL THEN 'КЛЮЧ NULL'
                WHEN EXISTS (SELECT 1 FROM #la k WHERE k.l_gid = p.c_loan_gid) THEN 'НАЙДЕН В АКТИВНЫХ'
                WHEN EXISTS (SELECT 1 FROM #master_gid m WHERE m.l_gid = p.c_loan_gid)
                     THEN 'ЕСТЬ В МАСТЕРЕ, НЕ АКТИВЕН (норма)'
                ELSE 'ИСТИННЫЙ ORPHAN' END AS orphan_class
    FROM #pl p
) t
GROUP BY source, orphan_class ORDER BY source, orphan_class OPTION (MAXDOP 1);

DROP TABLE #master_gid;


/*==============================================================================
  M11 — Клиенты с активными договорами в НЕСКОЛЬКИХ источниках
  T17: префикс gid = source, поэтому «мультиисточниковость» проверяема.
==============================================================================*/
SELECT @Suite AS suite, 'M11_CLIENTS_MULTI_SOURCE' AS scenario,
       source_count, COUNT_BIG(*) AS clients, SUM(loans) AS loans_total
FROM (
    SELECT l_borrower_id, COUNT(DISTINCT l_source) AS source_count, COUNT(*) AS loans
    FROM #la WHERE l_borrower_id IS NOT NULL
    GROUP BY l_borrower_id
) t
GROUP BY source_count ORDER BY source_count OPTION (MAXDOP 1);


/*==============================================================================
  M12 — Экспозиция по группе связанных заёмщиков
  b_group_affiliation имеет тип text — для группировки приводим к nvarchar(400).
  Усечение осознанное: длинные значения всё равно не годятся как ключ группы.
==============================================================================*/
SELECT TOP (50) @Suite AS suite, 'M12_GROUP_EXPOSURE' AS scenario,
       CONVERT(nvarchar(400), ISNULL(b.b_group_affiliation, N'(группа не указана)')) AS group_affiliation,
       COUNT_BIG(DISTINCT k.l_borrower_id) AS clients,
       COUNT_BIG(*) AS loans,
       CAST(SUM(a.total_balance_debt) AS decimal(38,2)) AS exposure_T15_CAVEAT
FROM #la k
INNER JOIN [Dictionaries].[risk_analytics].[borrower] b
        ON b.b_borrower_id = k.l_borrower_id AND b.b_report_date = @AsOf
LEFT JOIN #acct a ON a.la_gid = k.l_gid
WHERE b.b_group_affiliation IS NOT NULL
GROUP BY CONVERT(nvarchar(400), ISNULL(b.b_group_affiliation, N'(группа не указана)'))
ORDER BY exposure_T15_CAVEAT DESC OPTION (MAXDOP 1);


/*==============================================================================
  M13 — Договоры без графика погашения (T4)
  Ключ графика материализуется В ТОМ ЖЕ ТИПЕ, что l_loan_id, ОДИН раз.
  Именно отсутствие этого шага дало ложные «все 586 717» в прогоне №1.
==============================================================================*/
IF OBJECT_ID('tempdb..#rs_keys') IS NOT NULL DROP TABLE #rs_keys;
SELECT DISTINCT rs_source, CAST(rs_loan_id AS nvarchar(255)) AS rs_loan_id_txt
INTO #rs_keys
FROM [Dictionaries].[risk_analytics].[repayment_schedule]
WHERE rs_loan_id IS NOT NULL
OPTION (MAXDOP 1);
CREATE CLUSTERED INDEX ix_rs ON #rs_keys(rs_source, rs_loan_id_txt);

SELECT @Suite AS suite, 'M13_LOANS_WITHOUT_SCHEDULE' AS scenario,
       source, schedule_state, COUNT_BIG(*) AS loans
FROM (
    SELECT k.l_source AS source,
           CASE WHEN k.l_loan_id IS NULL THEN 'l_loan_id ПУСТ — СОПОСТАВИТЬ НЕЧЕМ'
                WHEN EXISTS (SELECT 1 FROM #rs_keys r
                             WHERE r.rs_source = k.l_source AND r.rs_loan_id_txt = k.l_loan_id)
                     THEN 'ГРАФИК ЕСТЬ'
                ELSE 'ГРАФИКА НЕТ' END AS schedule_state
    FROM #la k
) t
GROUP BY source, schedule_state ORDER BY source, schedule_state OPTION (MAXDOP 1);

DROP TABLE #rs_keys;


/*==============================================================================
  M14 — Договоры с графиком, но без платежей
  ЧЕСТНАЯ ГРАНИЦА: связь payments → договор НЕ подтверждена. У payments есть
  только p_CREDIT_ACCOUNT, которого нет ни в loans, ни в loan_account. Поэтому
  сценарий выполняется как ДИАГНОСТИКА сопоставимости, а не как ответ:
  показываем форму проблемы, а не выдаём выдуманный джойн за факт.
==============================================================================*/
SELECT @Suite AS suite, 'M14_PAYMENTS_LINKABILITY' AS scenario,
       p_source AS source,
       COUNT_BIG(*) AS payment_rows,
       COUNT_BIG(DISTINCT p_CREDIT_ACCOUNT) AS distinct_credit_accounts,
       MIN(LEN(p_CREDIT_ACCOUNT)) AS min_len,
       MAX(LEN(p_CREDIT_ACCOUNT)) AS max_len,
       SUM(CASE WHEN TRY_CONVERT(bigint, p_CREDIT_ACCOUNT) IS NULL THEN 1 ELSE 0 END) AS non_numeric_accounts
FROM [Dictionaries].[risk_analytics].[payments]
GROUP BY p_source ORDER BY source OPTION (MAXDOP 1);

SELECT @Suite AS suite, 'M14b_LINK_VERDICT' AS scenario,
       N'payments.p_CREDIT_ACCOUNT не сопоставлен ни с одним подтверждённым ключом марта. '
     + N'Пока связь не доказана покрытием, любой ответ на «договоры без платежей» будет артефактом ключа, а не фактом.' AS verdict
OPTION (MAXDOP 1);


/*==============================================================================
  M15 — План vs факт: тот же барьер, что M14 + T23/T24 (дубли с обеих сторон)
  Меряем то, что ИЗМЕРИМО без недоказанного ключа: масштаб дублей.
==============================================================================*/
SELECT @Suite AS suite, 'M15a_SCHEDULE_DUPLICATES_T24' AS scenario,
       rs_source AS source,
       COUNT_BIG(*) AS schedule_groups,
       SUM(rows_in_group) AS raw_rows,
       SUM(rows_in_group) - COUNT_BIG(*) AS excess_rows
FROM (
    SELECT rs_source, rs_loan_id, rs_repayment_date, COUNT_BIG(*) AS rows_in_group
    FROM [Dictionaries].[risk_analytics].[repayment_schedule]
    GROUP BY rs_source, rs_loan_id, rs_repayment_date
) g
GROUP BY rs_source ORDER BY source OPTION (MAXDOP 1);

SELECT @Suite AS suite, 'M15b_PAYMENT_DUPLICATES_T23' AS scenario,
       source, COUNT_BIG(*) AS duplicated_signatures, SUM(n) - COUNT_BIG(*) AS excess_rows
FROM (
    SELECT p_source AS source, p_CREDIT_ACCOUNT, p_VALUE_DATE, p_total, COUNT_BIG(*) AS n
    FROM [Dictionaries].[risk_analytics].[payments]
    GROUP BY p_source, p_CREDIT_ACCOUNT, p_VALUE_DATE, p_total
    HAVING COUNT_BIG(*) > 1
) d
GROUP BY source ORDER BY source OPTION (MAXDOP 1);


/*==============================================================================
  M16 — Реструктуризация: ставка до против после. ИСПРАВЛЕН ПОСЛЕ P2/P9.

  БЫЛО: `new_interest_rate` сравнивалась с `TRY_CONVERT(decimal, l_rate)`.
  Так как `l_rate` не конвертируется НИ НА ОДНОЙ строке, все три счётчика
  (decreased/increased/unchanged) были бы тождественным нулём, а
  `original_rate_unparseable` — 100%. Формально не ошибка, но содержательно
  запрос ничего бы не измерил.

  СТАЛО: сравнение с `interest_rates.interest_rate`. Дополнительно печатается
  совпадение ШКАЛ у двух полей: если ставка до и после записаны в разных
  шкалах (T40), сравнение «выросла/упала» бессмысленно, и это надо видеть,
  а не растворять в счётчиках.
==============================================================================*/
SELECT @Suite AS suite, 'M16_RATE_BEFORE_AFTER_RESTRUCTURING' AS scenario,
       k.l_source AS source,
       COUNT_BIG(*) AS restructured_loans,
       SUM(CASE WHEN ir.interest_rate IS NULL THEN 1 ELSE 0 END) AS no_rate_before,
       SUM(CASE WHEN r.new_interest_rate IS NULL THEN 1 ELSE 0 END) AS new_rate_null,
       /* Шкалы обоих полей должны совпадать, иначе сравнение не имеет смысла.
          Признак шкалы разворачивается через CASE, а НЕ как `(a<=1) <> (b<=1)`:
          в T-SQL нет булева типа, предикат нельзя сравнить с предикатом —
          это даёт `Msg 102 Incorrect syntax near '<'`. */
       SUM(CASE WHEN ir.interest_rate IS NOT NULL AND r.new_interest_rate IS NOT NULL
                 AND CASE WHEN ir.interest_rate <= 1 THEN 1 ELSE 0 END
                  <> CASE WHEN r.new_interest_rate <= 1 THEN 1 ELSE 0 END
                THEN 1 ELSE 0 END) AS scale_mismatch_NOT_COMPARABLE,
       SUM(CASE WHEN ir.interest_rate IS NOT NULL AND r.new_interest_rate IS NOT NULL
                 AND CASE WHEN ir.interest_rate <= 1 THEN 1 ELSE 0 END
                   = CASE WHEN r.new_interest_rate <= 1 THEN 1 ELSE 0 END
                 AND r.new_interest_rate < ir.interest_rate THEN 1 ELSE 0 END) AS rate_decreased,
       SUM(CASE WHEN ir.interest_rate IS NOT NULL AND r.new_interest_rate IS NOT NULL
                 AND CASE WHEN ir.interest_rate <= 1 THEN 1 ELSE 0 END
                   = CASE WHEN r.new_interest_rate <= 1 THEN 1 ELSE 0 END
                 AND r.new_interest_rate > ir.interest_rate THEN 1 ELSE 0 END) AS rate_increased,
       SUM(CASE WHEN ir.interest_rate IS NOT NULL AND r.new_interest_rate IS NOT NULL
                 AND CASE WHEN ir.interest_rate <= 1 THEN 1 ELSE 0 END
                   = CASE WHEN r.new_interest_rate <= 1 THEN 1 ELSE 0 END
                 AND r.new_interest_rate = ir.interest_rate THEN 1 ELSE 0 END) AS rate_unchanged
FROM #la k
INNER JOIN #restr r ON r.dlcr_gid = k.l_gid
LEFT JOIN #ir ir ON ir.l_gid = k.l_gid
GROUP BY k.l_source ORDER BY source OPTION (MAXDOP 1);


/*==============================================================================
  M17 — Дата нового погашения раньше даты реструктуризации (известно 184/4520)
==============================================================================*/
SELECT @Suite AS suite, 'M17_MATURITY_BEFORE_RESTRUCTURING' AS scenario,
       r_source AS source,
       COUNT_BIG(*) AS events_with_both_dates,
       SUM(CASE WHEN new_maturity_date < restructuring_date THEN 1 ELSE 0 END) AS maturity_before_restr_ANOMALY
FROM #restr
WHERE restructuring_date IS NOT NULL AND new_maturity_date IS NOT NULL
GROUP BY r_source ORDER BY source OPTION (MAXDOP 1);


/*==============================================================================
  M18 — Grace-период активен на @AsOf: ТРЁХЗНАЧНАЯ логика
  «Событие есть, но дат нет» НИКОГДА не схлопывается в «нет отсрочки» —
  это data-quality-показание, не риск-показание (locked methodology,
  stage3_safezone_plan.md).
==============================================================================*/
SELECT @Suite AS suite, 'M18_GRACE_STATE_AT_ASOF' AS scenario,
       source, grace_state, COUNT_BIG(*) AS loans
FROM (
    SELECT k.l_source AS source,
           CASE WHEN r.canc_date IS NOT NULL AND r.canc_date <= @AsOf THEN 'ОТМЕНЕНА'
                WHEN r.grace_od_begin_date IS NULL AND r.grace_od_end_date IS NULL
                 AND r.grace_int_begin_date IS NULL AND r.grace_int_end_date IS NULL
                     THEN 'UNKNOWN — событие есть, дат нет'
                WHEN (@AsOf BETWEEN r.grace_od_begin_date AND r.grace_od_end_date)
                  OR (@AsOf BETWEEN r.grace_int_begin_date AND r.grace_int_end_date)
                     THEN 'ACTIVE'
                ELSE 'NOT_ACTIVE' END AS grace_state
    FROM #la k
    INNER JOIN #restr r ON r.dlcr_gid = k.l_gid
) t
GROUP BY source, grace_state ORDER BY source, grace_state OPTION (MAXDOP 1);


/*==============================================================================
  M19 — Списания: grain не подтверждён (T20), поэтому считаем ОБА измерения
==============================================================================*/
/* Тот же фикс, что в M01d: EXISTS вынесен в производную таблицу. */
SELECT @Suite AS suite, 'M19_WRITEOFF_GRAIN_AND_LINK' AS scenario,
       COUNT_BIG(*) AS writeoff_rows,
       COUNT_BIG(DISTINCT gid) AS distinct_gids,
       SUM(in_active) AS still_in_active_perimeter,
       CASE WHEN COUNT_BIG(*) = COUNT_BIG(DISTINCT gid)
            THEN 'grain = 1 строка на договор'
            ELSE 'НЕСКОЛЬКО строк на договор — grain «случай», не «договор» (T20)' END AS grain_verdict
FROM (
    SELECT w.w_dlcrp_dlcr_gid AS gid,
           CASE WHEN EXISTS (SELECT 1 FROM #la k WHERE k.l_gid = w.w_dlcrp_dlcr_gid)
                THEN 1 ELSE 0 END AS in_active
    FROM [Dictionaries].[risk_analytics].[writeoff] w
    WHERE w.w_dlcrp_dlcr_gid IS NOT NULL
) t
OPTION (MAXDOP 1);


/*==============================================================================
  M20 — Банкроты: договоры и экспозиция (b_dog_gid подтверждён 4208/4208)
==============================================================================*/
SELECT @Suite AS suite, 'M20_BANKRUPT_EXPOSURE' AS scenario,
       ISNULL(k.l_source, '(нет активного договора)') AS source,
       COUNT_BIG(*) AS bankrupt_gids,
       SUM(CASE WHEN k.l_gid IS NOT NULL THEN 1 ELSE 0 END) AS matched_to_active_loan,
       CAST(SUM(a.total_balance_debt) AS decimal(38,2)) AS exposure_T15_CAVEAT
FROM (SELECT DISTINCT b_dog_gid FROM [Dictionaries].[risk_analytics].[bankrupt] WHERE b_dog_gid IS NOT NULL) bk
LEFT JOIN #la k   ON k.l_gid  = bk.b_dog_gid
LEFT JOIN #acct a ON a.la_gid = bk.b_dog_gid
GROUP BY ISNULL(k.l_source, '(нет активного договора)')
ORDER BY source OPTION (MAXDOP 1);


DROP TABLE #cov;
DROP TABLE #restr;
DROP TABLE #pl;
DROP TABLE #acct;
DROP TABLE #la;
