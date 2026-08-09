/*==============================================================================
  DWH_SCENARIOS_L2_FULL_BULK — ВЕСЬ УРОВЕНЬ 2 ОДНИМ ФАЙЛОМ (M01–M40)

  Сборка из `DWH_SCENARIOS_L2A_MEDIUM.sql` + `DWH_SCENARIOS_L2B_MEDIUM.sql`.
  Части остаются источником истины; этот файл — для запуска одним заходом.

  КАК ЗАПУСКАТЬ. Открыть целиком и выполнить весь файл (F5). НЕ выделять
  фрагменты: частичное выделение теряет `DECLARE` и даёт `Msg 137`. Файл
  разделён на батчи через `GO` намеренно — если один батч упадёт на неверном
  имени колонки, остальные отработают. Ожидаемых результатов ~50 наборов.

  ПОРЯДОК БАТЧЕЙ:
    1. L2A целиком (M01–M20) — своя материализация и своя уборка;
    2. L2B аудит схемы — печатает фактические имена колонок ratings /
       Guarantees / loan_account / borrower до того, как они понадобятся;
    3. L2B сценарии (M21–M40) — своя материализация и своя уборка.

  ЧТО СМОТРЕТЬ В ПЕРВУЮ ОЧЕРЕДЬ (это проверка исправлений, а не сценариев):
    • `00b_ACCOUNT_EFFECTIVE_DATES` — должно вернуть ЧЕТЫРЕ строки. Если одну
      (S03), значит правка по T26/T35 не применилась и балансовые сценарии
      снова считают по одному источнику.
    • `M07_RATE_BY_PROGRAMME` — должен вернуть строки. Прежняя версия давала
      гарантированно пустой результат (фильтр по `l_rate` как по числу).
    • `M07b_RATE_COVERAGE` — ожидание из P9e: S03 ~98,6%, S01 ~81,6%,
      S17 ~37,4%, S02 ~8,9%. Сильное расхождение = проблема ключа, не покрытия.
    • `M21b_RATINGS_KEY_COVERAGE` и `M23b_GUARANTEE_LINK_ATTEMPTS` — вердикт
      «НЕ РАБОТАЕТ» здесь ожидаем и является результатом, а не сбоем.

  Правила прежние: read-only, MAXDOP 1, PII не выводится.
  Сгенерировано из частей; правки вносить в части, не сюда.
==============================================================================*/

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
DECLARE @AsOf  date = (SELECT MAX(l_report_date) FROM [risk_analytics].[loans_active]);

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
FROM [risk_analytics].[loans_active]
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
INTO #src_last FROM [risk_analytics].[loan_account] GROUP BY la_source
OPTION (MAXDOP 1);
CREATE CLUSTERED INDEX ix_srclast ON #src_last(la_source);

IF OBJECT_ID('tempdb..#acct') IS NOT NULL DROP TABLE #acct;
IF OBJECT_ID('tempdb..#src_last') IS NOT NULL DROP TABLE #src_last;
IF OBJECT_ID('tempdb..#ir') IS NOT NULL DROP TABLE #ir;
SELECT a.la_source, a.la_gid, a.la_reporting_date,
       a.total_balance_debt, a.principal_balance_debt,
       a.days_past_due, a.delinquency_bucket
INTO #acct
FROM [risk_analytics].[loan_account] a
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
INTO #ir FROM [risk_analytics].[interest_rates] WHERE loan_id IS NOT NULL
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
FROM [risk_analytics].[pledges]
WHERE c_reporting_date = @AsOf
OPTION (MAXDOP 1);
CREATE CLUSTERED INDEX ix_pl_gid ON #pl(c_loan_gid);

IF OBJECT_ID('tempdb..#restr') IS NOT NULL DROP TABLE #restr;
SELECT [dlcr$source] AS r_source, dlcr_gid, restructuring_date, new_interest_rate,
       new_maturity_date, canc_date, payment_deferral,
       grace_od_begin_date, grace_od_end_date, grace_int_begin_date, grace_int_end_date
INTO #restr
FROM [risk_analytics].[restructuring_v2]
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
FROM [risk_analytics].[borrower] b
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
LEFT JOIN [risk_analytics].[ratings] r ON r.r_deal_gid = k.l_gid AND r.r_report_date = @AsOf
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
    LEFT JOIN [risk_analytics].[ratings] r ON r.r_deal_gid = k.l_gid AND r.r_report_date = @AsOf
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
    LEFT JOIN [risk_analytics].[borrower] b
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
LEFT JOIN [risk_analytics].[borrower] b
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
FROM [risk_analytics].[loans] WHERE l_report_date = @AsOf
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
INNER JOIN [risk_analytics].[borrower] b
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
FROM [risk_analytics].[repayment_schedule]
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
FROM [risk_analytics].[payments]
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
    FROM [risk_analytics].[repayment_schedule]
    GROUP BY rs_source, rs_loan_id, rs_repayment_date
) g
GROUP BY rs_source ORDER BY source OPTION (MAXDOP 1);

SELECT @Suite AS suite, 'M15b_PAYMENT_DUPLICATES_T23' AS scenario,
       source, COUNT_BIG(*) AS duplicated_signatures, SUM(n) - COUNT_BIG(*) AS excess_rows
FROM (
    SELECT p_source AS source, p_CREDIT_ACCOUNT, p_VALUE_DATE, p_total, COUNT_BIG(*) AS n
    FROM [risk_analytics].[payments]
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
    FROM [risk_analytics].[writeoff] w
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
FROM (SELECT DISTINCT b_dog_gid FROM [risk_analytics].[bankrupt] WHERE b_dog_gid IS NOT NULL) bk
LEFT JOIN #la k   ON k.l_gid  = bk.b_dog_gid
LEFT JOIN #acct a ON a.la_gid = bk.b_dog_gid
GROUP BY ISNULL(k.l_source, '(нет активного договора)')
ORDER BY source OPTION (MAXDOP 1);


DROP TABLE #cov;
DROP TABLE #restr;
DROP TABLE #pl;
DROP TABLE #acct;
DROP TABLE #la;

GO

/*==============================================================================
  DWH_SCENARIOS_L2B_MEDIUM — сценарии M21–M40 (уровень 2, часть B)

  Продолжение `DWH_SCENARIOS_L2A_MEDIUM.sql` (M01–M20). Уровень 2 проверяет
  КЛЮЧИ, КАРДИНАЛЬНОСТЬ и ЦЕЛОСТНОСТЬ связей.

  ЧТО ИЗМЕНЕНО ПОСЛЕ ПРОГОНА L1 (FINDINGS.md §10):
  - `loan_account` берётся НЕ по общему @AsOf, а по ПОСЛЕДНЕЙ ДАТЕ КАЖДОГО
    ИСТОЧНИКА. На 2026-08-01 общий фильтр вернул только S03 (T26), и все
    счётные сценарии молча схлопнулись бы до одного источника, выглядя как
    «данных нет». Эффективная дата печатается явно (M20b), чтобы разрыв
    сеток был виден, а не спрятан.
  - Ставка (`l_rate`) в расчётах НЕ используется: 0 конвертируемых строк из
    8 259 299 (T25). До пробы P2 любая арифметика по ставке бессмысленна.
  - `c_car_year` и прочие «числа в строке» сначала проходят аудит
    конвертируемости, потом считаются — ровно та же ловушка, что у l_rate.

  ПОЧЕМУ ЧЕРЕЗ #temp. Коррелированный подзапрос с CONVERT/CAST на внутренней
  стороне non-sargable → полный пересчёт на каждую внешнюю строку (дважды
  вешал прогон на 2+ часа: L11.1, L4.1). Ключ материализуется один раз в
  индексированный #temp, дальше сравниваются голые значения.

  PII. ИИН/БИН, ФИО клиента и ФИО сотрудника НЕ выводятся ни в одном
  результате — только агрегаты и счётчики (M27, M32, M40 построены так
  специально). gid/borrower_id — технические идентификаторы, допустимы.

  ЗАПУСКАТЬ ЦЕЛИКОМ ОТ ПЕРВОЙ СТРОКИ. Частичное выделение теряет DECLARE
  (Msg 137). Первый батч — аудит схемы, он отделён `GO` намеренно: если
  основной батч не скомпилируется из-за неверного имени колонки, аудит
  всё равно отработает и покажет фактические имена.
==============================================================================*/

USE [Dictionaries];
SET NOCOUNT ON;

/*==============================================================================
  БАТЧ 0 — АУДИТ СХЕМЫ (страховка от неверного имени колонки).
  Печатает фактические имена и типы полей, на которые опираются M21–M40.
==============================================================================*/
SELECT 'L2B_MEDIUM' AS suite, '00_SCHEMA_AUDIT' AS scenario,
       TABLE_NAME, COLUMN_NAME, DATA_TYPE,
       ISNULL(CONVERT(varchar(20), CHARACTER_MAXIMUM_LENGTH), '') AS max_len,
       IS_NULLABLE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'risk_analytics'
  AND (
       (TABLE_NAME = 'loan_account' AND COLUMN_NAME IN
          ('la_source','la_gid','la_reporting_date','total_balance_debt',
           'principal_balance_debt','provisions_total','provisions_calculated',
           'ifrs_balance','currency_exchange_rate','days_past_due',
           'delinquency_bucket','la_loan_id','la_dog_num'))
    OR (TABLE_NAME = 'borrower' AND COLUMN_NAME IN
          ('b_source','b_borrower_id','b_report_date','b_borrower_type',
           'b_individual_entrepreneur_flag','b_iin_bin','b_date_of_death',
           'b_date_of_imprisonment','b_status_change_date_prison',
           'b_active_loans_count','b_closed_loans_count','b_client_rating',
           'b_client_rating_date','b_dog_gid','b_dog_num'))
    OR (TABLE_NAME = 'ratings' AND COLUMN_NAME IN
          ('r_source','r_gid','r_deal_gid','r_dog_num','r_report_date',
           'r_client_rating','r_client_rating_date','r_loan_rating',
           'r_loan_rating_date'))
    OR (TABLE_NAME = 'Guarantees' AND COLUMN_NAME IN
          ('g_source','g_gid','g_clnt_gid','g_report_date','g_reserves_kzt',
           'g_reserves_currency','g_currency','g_guarantee_type',
           'g_agreement_amount_kzt','g_agreement_amount_currency'))
    OR (TABLE_NAME = 'pledges' AND COLUMN_NAME IN
          ('c_car_year','c_car_value','c_market_car_value',
           'c_collateral_value','c_market_collateral_value'))
    /* И `loans`, И `loans_active`: у вьюхи набор колонок УЖЕ, чем у таблицы,
       и 09.08 это уронило батч на `l_segment` / `l_financial_consultant`. */
    OR (TABLE_NAME IN ('loans','loans_active') AND COLUMN_NAME IN
          ('l_segment','l_entrepreneur_category','l_financial_consultant',
           'l_first_repayment_date','l_scheduled_closure_date',
           'l_actual_closure_date','l_currency_rate','l_loan_number',
           'l_funding_date','l_loan_open_date'))
  )
ORDER BY TABLE_NAME, COLUMN_NAME
OPTION (MAXDOP 1);

GO

/*==============================================================================
  БАТЧ 1 — СЦЕНАРИИ M21–M40
==============================================================================*/
SET NOCOUNT ON;

DECLARE @Suite     varchar(60) = 'L2B_MEDIUM';
DECLARE @AsOf      date = (SELECT MAX(l_report_date) FROM [risk_analytics].[loans_active]);
DECLARE @BAsOf     date = (SELECT MAX(b_report_date) FROM [risk_analytics].[borrower]);
DECLARE @ValueGap  decimal(18,4) = 10.0;   -- M33: порог расхождения оценок, «в разах»
DECLARE @OldCarYrs int = 15;               -- M34: возраст авто-залога, лет
DECLARE @TopN      int = 20;               -- ограничители детализации

SELECT @Suite AS suite, '00_SCOPE' AS scenario,
       @AsOf AS loans_asof, @BAsOf AS borrower_asof,
       @ValueGap AS value_gap_x, @OldCarYrs AS old_car_years
OPTION (MAXDOP 1);


/*------------------------------------------------------------------------------
  МАТЕРИАЛИЗАЦИЯ
------------------------------------------------------------------------------*/
IF OBJECT_ID('tempdb..#la') IS NOT NULL DROP TABLE #la;
/* ИСПРАВЛЕНО ПОСЛЕ ПРОГОНА 09.08 (Msg 207). `loans_active` НЕ содержит
   `l_segment` и `l_financial_consultant` — они есть только в `loans`.
   Батч 0 этого не поймал, потому что аудитировал их в `loans`, а не в
   `loans_active`: собственная слепота аудита, теперь закрыта. Атрибуты
   вынесены в отдельный батч, чтобы их отсутствие не роняло 18 сценариев. */
SELECT l_source, l_gid, l_borrower_id, l_loan_id, l_loan_number,
       l_loan_amount, l_currency, l_product_type,
       l_loan_open_date, l_funding_date, l_first_repayment_date,
       l_scheduled_closure_date, l_actual_closure_date
INTO #la
FROM [risk_analytics].[loans_active]
WHERE l_report_date = @AsOf
OPTION (MAXDOP 1);
CREATE CLUSTERED INDEX ix_la_gid ON #la(l_gid);
CREATE INDEX ix_la_borrower ON #la(l_borrower_id);

/* Последняя дата КАЖДОГО источника — см. шапку (T26). */
IF OBJECT_ID('tempdb..#la_last') IS NOT NULL DROP TABLE #la_last;
SELECT la_source, MAX(la_reporting_date) AS last_date
INTO #la_last
FROM [risk_analytics].[loan_account]
GROUP BY la_source
OPTION (MAXDOP 1);
CREATE CLUSTERED INDEX ix_lalast ON #la_last(la_source);

IF OBJECT_ID('tempdb..#acct') IS NOT NULL DROP TABLE #acct;
SELECT a.la_source, a.la_gid, a.la_reporting_date,
       a.total_balance_debt, a.principal_balance_debt,
       a.days_past_due, a.delinquency_bucket
INTO #acct
FROM [risk_analytics].[loan_account] a
JOIN #la_last k ON k.la_source = a.la_source
               AND k.last_date = a.la_reporting_date
OPTION (MAXDOP 1);
CREATE CLUSTERED INDEX ix_acct_gid ON #acct(la_gid);

/* #b содержит b_iin_bin — он нужен M27/M32 для группировки, но НИ В ОДНОМ
   результате не выводится: наружу идут только счётчики групп. */
IF OBJECT_ID('tempdb..#b') IS NOT NULL DROP TABLE #b;
SELECT b_source, b_borrower_id, b_borrower_type,
       b_individual_entrepreneur_flag, b_iin_bin,
       b_date_of_death, b_date_of_imprisonment, b_status_change_date_prison,
       b_active_loans_count, b_closed_loans_count,
       b_client_rating, b_client_rating_date
INTO #b
FROM [risk_analytics].[borrower]
WHERE b_report_date = @BAsOf
OPTION (MAXDOP 1);
CREATE CLUSTERED INDEX ix_b_id ON #b(b_borrower_id);

IF OBJECT_ID('tempdb..#pl') IS NOT NULL DROP TABLE #pl;
SELECT c_source, c_loan_gid, c_collateral_type, c_car_year,
       c_collateral_value, c_market_collateral_value,
       c_car_value, c_market_car_value
INTO #pl
FROM [risk_analytics].[pledges]
WHERE c_reporting_date = @AsOf
OPTION (MAXDOP 1);
CREATE CLUSTERED INDEX ix_pl_gid ON #pl(c_loan_gid);

/* Эффективные даты счётного слоя — печатаем ДО любых сумм по нему. */
SELECT @Suite AS suite, 'M20b_ACCOUNT_EFFECTIVE_DATES' AS scenario,
       k.la_source AS source, k.last_date AS effective_date,
       CASE WHEN k.last_date = @AsOf THEN 'СОВПАДАЕТ С loans'
            ELSE 'СЕТКА СДВИНУТА ОТНОСИТЕЛЬНО loans' END AS grid_state,
       COUNT_BIG(a.la_gid) AS accounts
FROM #la_last k
LEFT JOIN #acct a ON a.la_source = k.la_source
GROUP BY k.la_source, k.last_date,
       CASE WHEN k.last_date = @AsOf THEN 'СОВПАДАЕТ С loans'
            ELSE 'СЕТКА СДВИНУТА ОТНОСИТЕЛЬНО loans' END
ORDER BY source
OPTION (MAXDOP 1);


/*==============================================================================
  M21 — Рейтинг клиента против рейтинга сделки.
  T21: r_deal_gid только префикс 10 (S01). L1/E21: b_client_rating пуст у
  99,98% клиентов. Сценарий должен показать ГРАНИЦУ, а не «среднее».
==============================================================================*/
SELECT @Suite AS suite, 'M21a_RATINGS_KEY_SPACE' AS scenario,
       r_source AS source,
       LEFT(CONVERT(varchar(30), TRY_CONVERT(bigint, r_deal_gid)), 2) AS deal_gid_prefix,
       COUNT_BIG(*) AS rating_rows,
       SUM(CASE WHEN r_deal_gid IS NULL THEN 1 ELSE 0 END) AS deal_gid_null,
       SUM(CASE WHEN r_dog_num  IS NULL THEN 1 ELSE 0 END) AS dog_num_null
FROM [risk_analytics].[ratings]
GROUP BY r_source, LEFT(CONVERT(varchar(30), TRY_CONVERT(bigint, r_deal_gid)), 2)
ORDER BY source, rating_rows DESC
OPTION (MAXDOP 1);

/* Какой ключ реально соединяет ratings с loans: r_deal_gid или r_dog_num. */
SELECT @Suite AS suite, 'M21b_RATINGS_KEY_COVERAGE' AS scenario,
       key_tested, matched_rows, total_rows,
       CAST(100.0 * matched_rows / NULLIF(total_rows, 0) AS decimal(9,4)) AS match_pct
FROM (
    SELECT 'r_deal_gid -> l_gid' AS key_tested,
           SUM(CASE WHEN x.l_gid IS NOT NULL THEN 1 ELSE 0 END) AS matched_rows,
           COUNT_BIG(*) AS total_rows
    FROM [risk_analytics].[ratings] r
    LEFT JOIN #la x ON x.l_gid = r.r_deal_gid
    UNION ALL
    SELECT 'r_dog_num -> l_loan_number',
           SUM(CASE WHEN y.l_loan_number IS NOT NULL THEN 1 ELSE 0 END),
           COUNT_BIG(*)
    FROM [risk_analytics].[ratings] r
    LEFT JOIN (SELECT DISTINCT l_loan_number FROM #la) y
           ON y.l_loan_number = r.r_dog_num
) d
ORDER BY key_tested
OPTION (MAXDOP 1);

/* Расхождение клиентского и сделочного рейтинга — только там, где ЕСТЬ оба. */
SELECT @Suite AS suite, 'M21c_CLIENT_VS_DEAL_RATING' AS scenario,
       rating_state, borrowers_or_deals
FROM (
    SELECT CASE WHEN b.b_client_rating IS NULL AND r.r_loan_rating IS NULL
                     THEN 'НЕТ НИ ОДНОГО РЕЙТИНГА'
                WHEN b.b_client_rating IS NULL THEN 'ТОЛЬКО РЕЙТИНГ СДЕЛКИ'
                WHEN r.r_loan_rating  IS NULL  THEN 'ТОЛЬКО РЕЙТИНГ КЛИЕНТА'
                WHEN CONVERT(nvarchar(50), b.b_client_rating)
                   = CONVERT(nvarchar(50), r.r_loan_rating) THEN 'СОВПАДАЮТ'
                ELSE 'РАСХОДЯТСЯ' END AS rating_state,
           COUNT_BIG(*) AS borrowers_or_deals
    FROM #la l
    LEFT JOIN #b b ON b.b_borrower_id = l.l_borrower_id
    LEFT JOIN [risk_analytics].[ratings] r ON r.r_deal_gid = l.l_gid
    GROUP BY CASE WHEN b.b_client_rating IS NULL AND r.r_loan_rating IS NULL
                     THEN 'НЕТ НИ ОДНОГО РЕЙТИНГА'
                WHEN b.b_client_rating IS NULL THEN 'ТОЛЬКО РЕЙТИНГ СДЕЛКИ'
                WHEN r.r_loan_rating  IS NULL  THEN 'ТОЛЬКО РЕЙТИНГ КЛИЕНТА'
                WHEN CONVERT(nvarchar(50), b.b_client_rating)
                   = CONVERT(nvarchar(50), r.r_loan_rating) THEN 'СОВПАДАЮТ'
                ELSE 'РАСХОДЯТСЯ' END
) d
ORDER BY borrowers_or_deals DESC
OPTION (MAXDOP 1);


/*==============================================================================
  M22 — Гарантии: резерв в тенге против валютного. T22 ожидает ровно ×100.
  Проверяем ОТНОШЕНИЕ, а не разность: дефект множителя разностью не ловится.
==============================================================================*/
SELECT @Suite AS suite, 'M22_GUARANTEE_RESERVE_RATIO' AS scenario,
       g_source AS source, ratio_bucket,
       COUNT_BIG(*) AS guarantees,
       CAST(SUM(g_reserves_kzt) AS decimal(38,2)) AS sum_reserves_kzt,
       CAST(SUM(g_reserves_currency) AS decimal(38,2)) AS sum_reserves_currency
FROM (
    SELECT g_source, g_reserves_kzt, g_reserves_currency,
           CASE WHEN g_reserves_currency IS NULL OR g_reserves_kzt IS NULL
                     THEN 'NULL с одной из сторон'
                WHEN g_reserves_currency = 0 AND g_reserves_kzt = 0 THEN 'оба нуля'
                WHEN g_reserves_currency = 0 THEN 'валютный ноль при ненулевом ₸'
                WHEN ABS(g_reserves_kzt / NULLIF(g_reserves_currency, 0) - 100) < 0.01
                     THEN 'РОВНО x100 (дефект T22)'
                WHEN ABS(g_reserves_kzt / NULLIF(g_reserves_currency, 0) - 1) < 0.01
                     THEN 'x1 (совпадают)'
                ELSE 'иное отношение' END AS ratio_bucket
    FROM [risk_analytics].[Guarantees]
) d
GROUP BY g_source, ratio_bucket
ORDER BY source, guarantees DESC
OPTION (MAXDOP 1);


/*==============================================================================
  M23 — Договоры с гарантией И залогом одновременно.
  Известно: g_clnt_gid — ДРУГОЕ пространство идентификаторов. Не строим
  джойн вслепую, а сначала доказываем это цифрой (иначе получим тихий ноль).
==============================================================================*/
SELECT @Suite AS suite, 'M23a_GUARANTEE_GID_SPACE' AS scenario,
       g_source AS source,
       LEFT(CONVERT(varchar(30), TRY_CONVERT(bigint, g_clnt_gid)), 2) AS clnt_gid_prefix,
       COUNT_BIG(*) AS rows_cnt
FROM [risk_analytics].[Guarantees]
GROUP BY g_source, LEFT(CONVERT(varchar(30), TRY_CONVERT(bigint, g_clnt_gid)), 2)
ORDER BY source, rows_cnt DESC
OPTION (MAXDOP 1);

SELECT @Suite AS suite, 'M23b_GUARANTEE_LINK_ATTEMPTS' AS scenario,
       link_tested, matched_rows, total_rows,
       CAST(100.0 * matched_rows / NULLIF(total_rows, 0) AS decimal(9,4)) AS match_pct,
       CASE WHEN matched_rows = 0
            THEN 'СВЯЗЬ НЕ РАБОТАЕТ — не использовать'
            ELSE 'есть совпадения, проверить grain' END AS verdict
FROM (
    SELECT 'g_clnt_gid -> l_gid' AS link_tested,
           SUM(CASE WHEN x.l_gid IS NOT NULL THEN 1 ELSE 0 END) AS matched_rows,
           COUNT_BIG(*) AS total_rows
    FROM [risk_analytics].[Guarantees] g
    LEFT JOIN #la x ON x.l_gid = g.g_clnt_gid
    UNION ALL
    SELECT 'g_clnt_gid -> l_borrower_id',
           SUM(CASE WHEN y.l_borrower_id IS NOT NULL THEN 1 ELSE 0 END),
           COUNT_BIG(*)
    FROM [risk_analytics].[Guarantees] g
    LEFT JOIN (SELECT DISTINCT l_borrower_id FROM #la) y
           ON y.l_borrower_id = g.g_clnt_gid
) d
ORDER BY link_tested
OPTION (MAXDOP 1);


/*==============================================================================
  M24 — Доля обеспеченных договоров по продукту.
  T10: у S02 залогов нет ВООБЩЕ — это свойство продукта, не дефект.
  T9 (расширен L1): продукт NULL у S01/S02/S17, поэтому разрез по продукту
  осмыслен только внутри S03. Держим source в разрезе, чтобы не усреднить.
==============================================================================*/
SELECT @Suite AS suite, 'M24_COVERAGE_BY_PRODUCT' AS scenario,
       source, product_type,
       COUNT_BIG(*) AS loans,
       SUM(has_pledge) AS loans_with_pledge,
       CAST(100.0 * SUM(has_pledge) / NULLIF(COUNT_BIG(*), 0) AS decimal(9,4)) AS pledged_pct
FROM (
    SELECT l.l_source AS source,
           ISNULL(l.l_product_type, N'(NULL)') AS product_type,
           CASE WHEN p.c_loan_gid IS NULL THEN 0 ELSE 1 END AS has_pledge
    FROM #la l
    LEFT JOIN (SELECT DISTINCT c_loan_gid FROM #pl) p ON p.c_loan_gid = l.l_gid
) d
GROUP BY source, product_type
ORDER BY source, loans DESC
OPTION (MAXDOP 1);


/*==============================================================================
  M25 — Договоры 90+ и их обеспечение.
  T13: dpd = days_past_due − 1. Печатаем ОБА отбора рядом — граница «90+»
  сдвигается на целый бакет в зависимости от того, какое поле взято.
==============================================================================*/
SELECT @Suite AS suite, 'M25_DPD90_COLLATERAL' AS scenario,
       source, dpd_definition,
       COUNT_BIG(*) AS loans_90plus,
       SUM(has_pledge) AS with_pledge,
       CAST(SUM(bal) AS decimal(38,2)) AS sum_balance
FROM (
    SELECT a.la_source AS source, d.dpd_definition,
           CASE WHEN p.c_loan_gid IS NULL THEN 0 ELSE 1 END AS has_pledge,
           a.total_balance_debt AS bal
    FROM #acct a
    JOIN #la l ON l.l_gid = a.la_gid
    LEFT JOIN (SELECT DISTINCT c_loan_gid FROM #pl) p ON p.c_loan_gid = a.la_gid
    CROSS APPLY (VALUES
        ('days_past_due > 90 (сырое поле)', CASE WHEN a.days_past_due > 90 THEN 1 ELSE 0 END),
        ('dpd = days_past_due - 1 > 90 (T13)', CASE WHEN a.days_past_due - 1 > 90 THEN 1 ELSE 0 END)
    ) d(dpd_definition, is_90plus)
    WHERE d.is_90plus = 1
) x
GROUP BY source, dpd_definition
ORDER BY source, dpd_definition
OPTION (MAXDOP 1);


/*==============================================================================
  M27 — Клиенты-ИП: договоры как ФЛ и как ИП.
  PII: b_iin_bin НЕ выводится. Только счётчик идентификаторов, у которых
  встречаются обе роли. L1/E14 показал, что ie_flag стоит ТОЛЬКО на ЮЛ —
  сценарий проверяет, не порождает ли это раздвоение одного человека.

  Флаг сравнивается КАК СТРОКА, а не через CONVERT(int, ...): фактический тип
  поля не подтверждён, и жёсткий каст уронил бы весь батч на первом же 'Y'.
  Домен печатается сам — не нужно заранее знать, какое значение означает ИП.
==============================================================================*/
SELECT @Suite AS suite, 'M27_IE_DUAL_ROLE' AS scenario,
       roles_present,
       COUNT_BIG(*) AS distinct_identifiers,
       SUM(borrower_ids) AS borrower_id_rows
FROM (
    SELECT b_iin_bin,
           COUNT(DISTINCT b_borrower_id) AS borrower_ids,
           CASE WHEN MIN(ISNULL(CONVERT(nvarchar(20), b_individual_entrepreneur_flag), N'(NULL)'))
                  = MAX(ISNULL(CONVERT(nvarchar(20), b_individual_entrepreneur_flag), N'(NULL)'))
                THEN N'одно значение флага: '
                   + MIN(ISNULL(CONVERT(nvarchar(20), b_individual_entrepreneur_flag), N'(NULL)'))
                ELSE N'РАЗНЫЕ ЗНАЧЕНИЯ ФЛАГА НА ОДНОМ ИИН/БИН (раздвоение роли)'
           END AS roles_present
    FROM #b
    WHERE b_iin_bin IS NOT NULL AND LTRIM(RTRIM(b_iin_bin)) <> N''
    GROUP BY b_iin_bin
) d
GROUP BY roles_present
ORDER BY distinct_identifiers DESC
OPTION (MAXDOP 1);


/*==============================================================================
  M28 — Активные договоры умерших клиентов (операционный риск).
  L1/E20: 22 173 клиента с датой смерти, 3 — в будущем.
==============================================================================*/
SELECT @Suite AS suite, 'M28_DECEASED_ACTIVE_LOANS' AS scenario,
       l.l_source AS source,
       COUNT_BIG(*) AS active_loans_of_deceased,
       COUNT(DISTINCT l.l_borrower_id) AS deceased_borrowers,
       SUM(CASE WHEN b.b_date_of_death > @AsOf THEN 1 ELSE 0 END) AS death_date_future_ANOMALY,
       CAST(SUM(ISNULL(a.total_balance_debt, 0)) AS decimal(38,2)) AS sum_balance_where_known,
       SUM(CASE WHEN a.la_gid IS NULL THEN 1 ELSE 0 END) AS no_account_row
FROM #la l
JOIN #b b ON b.b_borrower_id = l.l_borrower_id
LEFT JOIN #acct a ON a.la_gid = l.l_gid
WHERE b.b_date_of_death IS NOT NULL
GROUP BY l.l_source
ORDER BY source
OPTION (MAXDOP 1);


/*==============================================================================
  M29 — Активные договоры клиентов в местах лишения свободы.
==============================================================================*/
SELECT @Suite AS suite, 'M29_IMPRISONED_ACTIVE_LOANS' AS scenario,
       l.l_source AS source,
       COUNT_BIG(*) AS active_loans,
       COUNT(DISTINCT l.l_borrower_id) AS borrowers,
       SUM(CASE WHEN b.b_status_change_date_prison IS NULL THEN 1 ELSE 0 END) AS no_status_change_date,
       SUM(CASE WHEN b.b_status_change_date_prison < b.b_date_of_imprisonment
                THEN 1 ELSE 0 END) AS status_before_imprisonment_ANOMALY
FROM #la l
JOIN #b b ON b.b_borrower_id = l.l_borrower_id
WHERE b.b_date_of_imprisonment IS NOT NULL
GROUP BY l.l_source
ORDER BY source
OPTION (MAXDOP 1);


/*==============================================================================
  M30 — b_active_loans_count против фактического счёта.
  Прямой тест внутренней согласованности справочника. Считаем ФАКТ по
  loans_active и сравниваем с денормализованным счётчиком.
==============================================================================*/
SELECT @Suite AS suite, 'M30_ACTIVE_COUNT_CONSISTENCY' AS scenario,
       diff_bucket,
       COUNT_BIG(*) AS borrowers,
       SUM(stored_cnt) AS sum_stored,
       SUM(actual_cnt) AS sum_actual
FROM (
    SELECT b.b_borrower_id,
           ISNULL(TRY_CONVERT(int, b.b_active_loans_count), 0) AS stored_cnt,
           ISNULL(f.actual_cnt, 0) AS actual_cnt,
           /* TRY_CONVERT, а не CONVERT: тип счётчика не подтверждён, а
              нечисловое значение — самостоятельная находка, не повод падать. */
           CASE WHEN b.b_active_loans_count IS NULL THEN 'СЧЁТЧИК NULL'
                WHEN TRY_CONVERT(int, b.b_active_loans_count) IS NULL
                     THEN 'СЧЁТЧИК НЕ ЧИСЛО'
                WHEN TRY_CONVERT(int, b.b_active_loans_count) = ISNULL(f.actual_cnt, 0)
                     THEN 'СОВПАДАЕТ'
                WHEN TRY_CONVERT(int, b.b_active_loans_count) > ISNULL(f.actual_cnt, 0)
                     THEN 'СЧЁТЧИК ЗАВЫШЕН'
                ELSE 'СЧЁТЧИК ЗАНИЖЕН' END AS diff_bucket
    FROM #b b
    LEFT JOIN (
        SELECT l_borrower_id, COUNT_BIG(*) AS actual_cnt
        FROM #la GROUP BY l_borrower_id
    ) f ON f.l_borrower_id = b.b_borrower_id
) d
GROUP BY diff_bucket
ORDER BY borrowers DESC
OPTION (MAXDOP 1);


/*==============================================================================
  M31 — l_loan_number не уникален (T18: 9 659 коллизий).
  Раскладываем: коллизия ВНУТРИ источника (дубль записи) или МЕЖДУ
  источниками (разные клиенты с одним номером). Это разные дефекты.
  Считаем на СЫРОМ уровне: SUM(размер группы), а не COUNT над сгруппированным
  (паразитный GROUP BY = тавтология, см. CLAUDE.md).
==============================================================================*/
SELECT @Suite AS suite, 'M31_LOAN_NUMBER_COLLISIONS' AS scenario,
       collision_type,
       COUNT_BIG(*) AS distinct_numbers,
       SUM(rows_in_group) AS rows_affected,
       SUM(rows_in_group) - COUNT_BIG(*) AS excess_rows
FROM (
    SELECT l_loan_number,
           COUNT_BIG(*) AS rows_in_group,
           COUNT(DISTINCT l_source) AS sources_in_group,
           CASE WHEN COUNT(DISTINCT l_source) > 1
                     THEN 'МЕЖДУ ИСТОЧНИКАМИ (разные клиенты)'
                ELSE 'ВНУТРИ ИСТОЧНИКА (дубль записи)' END AS collision_type
    FROM [risk_analytics].[loans]
    WHERE l_report_date = @AsOf AND l_loan_number IS NOT NULL
    GROUP BY l_loan_number
    HAVING COUNT_BIG(*) > 1
) d
GROUP BY collision_type
ORDER BY rows_affected DESC
OPTION (MAXDOP 1);


/*==============================================================================
  M32 — Один клиент, несколько borrower_id. PII: ИИН/БИН не выводится.
==============================================================================*/
SELECT @Suite AS suite, 'M32_DUPLICATE_CLIENT_IDS' AS scenario,
       ids_per_identifier_bucket,
       COUNT_BIG(*) AS distinct_identifiers,
       SUM(ids) AS borrower_id_rows
FROM (
    SELECT b_iin_bin, COUNT(DISTINCT b_borrower_id) AS ids,
           CASE WHEN COUNT(DISTINCT b_borrower_id) = 1 THEN '1 (норма)'
                WHEN COUNT(DISTINCT b_borrower_id) = 2 THEN '2'
                WHEN COUNT(DISTINCT b_borrower_id) <= 5 THEN '3-5'
                ELSE '6+' END AS ids_per_identifier_bucket
    FROM #b
    WHERE b_iin_bin IS NOT NULL AND LTRIM(RTRIM(b_iin_bin)) <> N''
    GROUP BY b_iin_bin
) d
GROUP BY ids_per_identifier_bucket
ORDER BY ids_per_identifier_bucket
OPTION (MAXDOP 1);


/*==============================================================================
  M33 — Залоги: рыночная против залоговой стоимости, расхождение > @ValueGap раз.
  Известно: 539 S01 / 42 S03 объекта. Воспроизводим.
==============================================================================*/
SELECT @Suite AS suite, 'M33_VALUATION_GAP' AS scenario,
       c_source AS source, gap_direction,
       COUNT_BIG(*) AS pledge_rows,
       CAST(MAX(gap_x) AS decimal(18,2)) AS max_gap_x
FROM (
    SELECT c_source,
           CASE WHEN c_market_collateral_value > c_collateral_value
                THEN 'РЫНОЧНАЯ выше залоговой'
                ELSE 'ЗАЛОГОВАЯ выше рыночной' END AS gap_direction,
           CASE WHEN c_market_collateral_value > c_collateral_value
                THEN c_market_collateral_value / NULLIF(c_collateral_value, 0)
                ELSE c_collateral_value / NULLIF(c_market_collateral_value, 0) END AS gap_x
    FROM #pl
    WHERE c_collateral_value > 0 AND c_market_collateral_value > 0
) d
WHERE gap_x >= @ValueGap
GROUP BY c_source, gap_direction
ORDER BY source, pledge_rows DESC
OPTION (MAXDOP 1);


/*==============================================================================
  M34 — Авто-залоги старше @OldCarYrs лет.
  c_car_year — СТРОКА. Урок l_rate (T25): сначала аудит конвертируемости,
  только потом арифметика. Иначе «нет старых авто» = молчаливый провал каста.
==============================================================================*/
SELECT @Suite AS suite, 'M34a_CAR_YEAR_TYPE_AUDIT' AS scenario,
       c_source AS source,
       COUNT_BIG(*) AS pledge_rows,
       SUM(CASE WHEN c_car_year IS NULL THEN 1 ELSE 0 END) AS year_null,
       SUM(CASE WHEN c_car_year IS NOT NULL
                 AND TRY_CONVERT(int, c_car_year) IS NULL THEN 1 ELSE 0 END) AS year_not_numeric,
       SUM(CASE WHEN TRY_CONVERT(int, c_car_year) NOT BETWEEN 1900 AND YEAR(@AsOf) + 1
                THEN 1 ELSE 0 END) AS year_out_of_range_ANOMALY
FROM #pl
GROUP BY c_source
ORDER BY source
OPTION (MAXDOP 1);

SELECT @Suite AS suite, 'M34b_OLD_CARS' AS scenario,
       c_source AS source,
       COUNT_BIG(*) AS old_car_pledges,
       MIN(TRY_CONVERT(int, c_car_year)) AS oldest_year,
       CAST(SUM(ISNULL(c_collateral_value, 0)) AS decimal(38,2)) AS sum_collateral_value
FROM #pl
WHERE TRY_CONVERT(int, c_car_year) BETWEEN 1900 AND YEAR(@AsOf) - @OldCarYrs
GROUP BY c_source
ORDER BY source
OPTION (MAXDOP 1);


/*==============================================================================
  M35 — Несколько записей в loan_account на один договор и одну дату (grain).
  Известно: 8 дублей у S02. Считаем на сыром уровне.
==============================================================================*/
SELECT @Suite AS suite, 'M35_ACCOUNT_GRAIN' AS scenario,
       la_source AS source, la_reporting_date AS effective_date,
       COUNT_BIG(*) AS distinct_gids_duplicated,
       SUM(rows_in_group) AS rows_affected,
       SUM(rows_in_group) - COUNT_BIG(*) AS excess_rows,
       MAX(rows_in_group) AS max_rows_per_gid
FROM (
    SELECT la_source, la_reporting_date, la_gid, COUNT_BIG(*) AS rows_in_group
    FROM #acct
    GROUP BY la_source, la_reporting_date, la_gid
    HAVING COUNT_BIG(*) > 1
) d
GROUP BY la_source, la_reporting_date
ORDER BY source
OPTION (MAXDOP 1);


/*==============================================================================
  M36 — Срок от выдачи до первого платежа.
  Отрицательный интервал = первый платёж раньше выдачи (аномалия).
==============================================================================*/
SELECT @Suite AS suite, 'M36_DAYS_TO_FIRST_PAYMENT' AS scenario,
       source, gap_bucket, loans
FROM (
    SELECT l_source AS source,
           CASE WHEN l_funding_date IS NULL OR l_first_repayment_date IS NULL
                     THEN '(НЕТ ОДНОЙ ИЗ ДАТ)'
                WHEN DATEDIFF(DAY, l_funding_date, l_first_repayment_date) < 0
                     THEN 'ОТРИЦАТЕЛЬНЫЙ (АНОМАЛИЯ)'
                WHEN DATEDIFF(DAY, l_funding_date, l_first_repayment_date) = 0 THEN '0 дней'
                WHEN DATEDIFF(DAY, l_funding_date, l_first_repayment_date) <= 31 THEN '1-31'
                WHEN DATEDIFF(DAY, l_funding_date, l_first_repayment_date) <= 62 THEN '32-62'
                WHEN DATEDIFF(DAY, l_funding_date, l_first_repayment_date) <= 365 THEN '63-365'
                ELSE '>365 (АНОМАЛИЯ)' END AS gap_bucket,
           COUNT_BIG(*) AS loans
    FROM #la
    GROUP BY l_source,
           CASE WHEN l_funding_date IS NULL OR l_first_repayment_date IS NULL
                     THEN '(НЕТ ОДНОЙ ИЗ ДАТ)'
                WHEN DATEDIFF(DAY, l_funding_date, l_first_repayment_date) < 0
                     THEN 'ОТРИЦАТЕЛЬНЫЙ (АНОМАЛИЯ)'
                WHEN DATEDIFF(DAY, l_funding_date, l_first_repayment_date) = 0 THEN '0 дней'
                WHEN DATEDIFF(DAY, l_funding_date, l_first_repayment_date) <= 31 THEN '1-31'
                WHEN DATEDIFF(DAY, l_funding_date, l_first_repayment_date) <= 62 THEN '32-62'
                WHEN DATEDIFF(DAY, l_funding_date, l_first_repayment_date) <= 365 THEN '63-365'
                ELSE '>365 (АНОМАЛИЯ)' END
) d
ORDER BY source, loans DESC
OPTION (MAXDOP 1);


/*==============================================================================
  M37 — Досрочное закрытие: факт раньше плана.
  Считаем по ВСЕЙ loans, а не по активным: у активных закрытия нет по
  определению, и сценарий вернул бы пустоту.
==============================================================================*/
SELECT @Suite AS suite, 'M37_EARLY_CLOSURE' AS scenario,
       source, closure_state, loans
FROM (
    SELECT l_source AS source,
           CASE WHEN l_actual_closure_date IS NULL THEN 'НЕ ЗАКРЫТ'
                WHEN l_scheduled_closure_date IS NULL THEN 'ЗАКРЫТ, ПЛАНА НЕТ'
                WHEN l_actual_closure_date <  l_scheduled_closure_date THEN 'ДОСРОЧНО'
                WHEN l_actual_closure_date =  l_scheduled_closure_date THEN 'В СРОК'
                ELSE 'С ПРОСРОЧКОЙ ЗАКРЫТИЯ' END AS closure_state,
           COUNT_BIG(*) AS loans
    FROM [risk_analytics].[loans]
    WHERE l_report_date = @AsOf
    GROUP BY l_source,
           CASE WHEN l_actual_closure_date IS NULL THEN 'НЕ ЗАКРЫТ'
                WHEN l_scheduled_closure_date IS NULL THEN 'ЗАКРЫТ, ПЛАНА НЕТ'
                WHEN l_actual_closure_date <  l_scheduled_closure_date THEN 'ДОСРОЧНО'
                WHEN l_actual_closure_date =  l_scheduled_closure_date THEN 'В СРОК'
                ELSE 'С ПРОСРОЧКОЙ ЗАКРЫТИЯ' END
) d
ORDER BY source, loans DESC
OPTION (MAXDOP 1);


/*==============================================================================
  M38 — Провизии против остатка по источникам.
  Формула провизий S03 верна КАК ФОРМУЛА, но сходится на 21,23% строк —
  «средний процент провизий» по такому набору не является показателем.
  Поэтому печатаем ЗАПОЛНЕННОСТЬ рядом с отношением, а не одно отношение.
==============================================================================*/
SELECT @Suite AS suite, 'M38_PROVISION_COVERAGE' AS scenario,
       a.la_source AS source, a.la_reporting_date AS effective_date,
       COUNT_BIG(*) AS accounts,
       SUM(CASE WHEN a.total_balance_debt IS NULL THEN 1 ELSE 0 END) AS balance_null,
       SUM(CASE WHEN a.total_balance_debt = 0 THEN 1 ELSE 0 END) AS balance_zero,
       CAST(SUM(ISNULL(a.total_balance_debt, 0)) AS decimal(38,2)) AS sum_balance,
       CAST(SUM(ISNULL(a.principal_balance_debt, 0)) AS decimal(38,2)) AS sum_principal,
       CAST(100.0 * SUM(CASE WHEN a.total_balance_debt IS NOT NULL THEN 1 ELSE 0 END)
            / NULLIF(COUNT_BIG(*), 0) AS decimal(9,4)) AS balance_fill_pct
FROM #acct a
GROUP BY a.la_source, a.la_reporting_date
ORDER BY source
OPTION (MAXDOP 1);


/*==============================================================================
  M39 — Валютные договоры: подготовка к проверке курса.

  ЧЕСТНАЯ ГРАНИЦА: сам вопрос «на какую дату курс» здесь НЕ отвечается.
  Наличие колонки `currency_exchange_rate` в `loan_account` не подтверждено —
  её проверяет батч 0. Пока имя не подтверждено, ссылаться на неё нельзя:
  неверное имя роняет компиляцию ВСЕГО батча, и 19 остальных сценариев не
  отработают. Здесь строится популяция (сколько валютных договоров, есть ли
  у них строка в счётном слое); сравнение курсов — отдельным запросом после
  батча 0. Это результат теста, а не пробел сценария.
==============================================================================*/
SELECT @Suite AS suite, 'M39_FX_POPULATION' AS scenario,
       l.l_source AS source, l.l_currency AS currency,
       COUNT_BIG(*) AS loans,
       SUM(CASE WHEN a.la_gid IS NULL THEN 1 ELSE 0 END) AS no_account_row,
       CAST(SUM(ISNULL(a.total_balance_debt, 0)) AS decimal(38,2)) AS sum_balance
FROM #la l
LEFT JOIN #acct a ON a.la_gid = l.l_gid
WHERE l.l_currency IS NOT NULL AND l.l_currency <> N'KZT'
GROUP BY l.l_source, l.l_currency
ORDER BY source, currency
OPTION (MAXDOP 1);



GO
/*==============================================================================
  БАТЧ 2 — M26 и M40: атрибуты, которых НЕТ в `loans_active`.

  Отделён `GO` НАМЕРЕННО. 09.08 прогон упал с `Msg 207 Invalid column name
  'l_segment'` / `'l_financial_consultant'`: эти поля живут в `loans`, но не
  во вьюхе `loans_active`, на которой строится `#la`. Одна неверная колонка
  уносила все 18 остальных сценариев батча.

  Здесь периметр по-прежнему задаёт `#la` (активные договоры), а атрибуты
  подтягиваются из `loans` по gid. Если их нет и там — умрёт только этот
  батч, а фактические имена уже напечатаны батчем 0.
  #temp переживают GO; заново объявляются только переменные (Msg 137).
==============================================================================*/
SET NOCOUNT ON;
DECLARE @Suite varchar(60) = 'L2B_MEDIUM';
DECLARE @AsOf  date = (SELECT MAX(l_report_date) FROM [risk_analytics].[loans]);
DECLARE @TopN  int  = 20;

IF OBJECT_ID('tempdb..#lattr') IS NOT NULL DROP TABLE #lattr;
SELECT l.l_gid, l.l_segment, l.l_entrepreneur_category, l.l_financial_consultant
INTO #lattr
FROM [risk_analytics].[loans] l
WHERE l.l_report_date = @AsOf
  AND EXISTS (SELECT 1 FROM #la k WHERE k.l_gid = l.l_gid)
OPTION (MAXDOP 1);
CREATE CLUSTERED INDEX ix_lattr ON #lattr(l_gid);

/*==============================================================================
  M26 — Согласованность сегмента, категории предпринимателя и типа заёмщика.
  Ищем комбинации, которые не должны существовать (ФЛ с корп-сегментом и т.п.).
==============================================================================*/
SELECT @Suite AS suite, 'M26_SEGMENT_CONSISTENCY' AS scenario,
       source, segment, entrepreneur_category, borrower_type, loans
FROM (
    SELECT l.l_source AS source,
           ISNULL(at.l_segment, N'(NULL)') AS segment,
           ISNULL(at.l_entrepreneur_category, N'(NULL)') AS entrepreneur_category,
           ISNULL(b.b_borrower_type, N'(НЕТ В borrower)') AS borrower_type,
           COUNT_BIG(*) AS loans,
           ROW_NUMBER() OVER (PARTITION BY l.l_source ORDER BY COUNT_BIG(*) DESC) AS rn
    FROM #la l
    LEFT JOIN #lattr at ON at.l_gid = l.l_gid
    LEFT JOIN #b b ON b.b_borrower_id = l.l_borrower_id
    GROUP BY l.l_source, ISNULL(at.l_segment, N'(NULL)'),
             ISNULL(at.l_entrepreneur_category, N'(NULL)'),
             ISNULL(b.b_borrower_type, N'(НЕТ В borrower)')
) d
WHERE rn <= @TopN
ORDER BY source, loans DESC
OPTION (MAXDOP 1);


/*==============================================================================
  M40 — Портфель по финансовому консультанту.
  PII: ФИО сотрудника НЕ выводится. Отдаём концентрацию и разброс —
  этого достаточно, чтобы понять, пригодно ли поле как измерение.
==============================================================================*/
SELECT @Suite AS suite, 'M40_CONSULTANT_CONCENTRATION' AS scenario,
       source,
       COUNT_BIG(*) AS distinct_consultants,
       SUM(loans) AS loans_attributed,
       MIN(loans) AS min_loans_per_consultant,
       MAX(loans) AS max_loans_per_consultant,
       CAST(AVG(1.0 * loans) AS decimal(18,2)) AS avg_loans_per_consultant
FROM (
    SELECT l_source AS source, at_l_financial_consultant, COUNT_BIG(*) AS loans
    FROM (SELECT k.l_source, at.l_financial_consultant AS at_l_financial_consultant
        FROM #la k JOIN #lattr at ON at.l_gid = k.l_gid) z
    WHERE at_l_financial_consultant IS NOT NULL
      AND LTRIM(RTRIM(at_l_financial_consultant)) <> N''
    GROUP BY l_source, at_l_financial_consultant
) d
GROUP BY source
ORDER BY source
OPTION (MAXDOP 1);

/* Сколько договоров вообще не привязано к консультанту — заполненность поля. */
SELECT @Suite AS suite, 'M40b_CONSULTANT_FILL_RATE' AS scenario,
       l_source AS source,
       COUNT_BIG(*) AS active_loans,
       SUM(CASE WHEN at_l_financial_consultant IS NULL
                  OR LTRIM(RTRIM(at_l_financial_consultant)) = N''
                THEN 1 ELSE 0 END) AS no_consultant
/* LEFT, а не INNER: это ЗАПОЛНЕННОСТЬ поля, и знаменатель обязан быть полным
   активным портфелем. INNER занизил бы active_loans на договоры без атрибута
   и превратил бы метрику пропусков в метрику наличия. */
FROM (SELECT k.l_source, at.l_financial_consultant AS at_l_financial_consultant
        FROM #la k LEFT JOIN #lattr at ON at.l_gid = k.l_gid) z
GROUP BY l_source
ORDER BY source
OPTION (MAXDOP 1);



/*------------------------------------------------------------------------------
  УБОРКА (немедленная — после переполнения tempdb 17.07)
------------------------------------------------------------------------------*/
IF OBJECT_ID('tempdb..#la')      IS NOT NULL DROP TABLE #la;
IF OBJECT_ID('tempdb..#lattr')   IS NOT NULL DROP TABLE #lattr;
IF OBJECT_ID('tempdb..#la_last') IS NOT NULL DROP TABLE #la_last;
IF OBJECT_ID('tempdb..#acct')    IS NOT NULL DROP TABLE #acct;
IF OBJECT_ID('tempdb..#b')       IS NOT NULL DROP TABLE #b;
IF OBJECT_ID('tempdb..#pl')      IS NOT NULL DROP TABLE #pl;
