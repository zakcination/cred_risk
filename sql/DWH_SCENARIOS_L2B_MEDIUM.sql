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
    OR (TABLE_NAME = 'loans' AND COLUMN_NAME IN
          ('l_segment','l_entrepreneur_category','l_financial_consultant',
           'l_first_repayment_date','l_scheduled_closure_date',
           'l_actual_closure_date','l_currency_rate'))
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
SELECT l_source, l_gid, l_borrower_id, l_loan_id, l_loan_number,
       l_loan_amount, l_currency, l_product_type, l_segment,
       l_entrepreneur_category, l_financial_consultant,
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
  M26 — Согласованность сегмента, категории предпринимателя и типа заёмщика.
  Ищем комбинации, которые не должны существовать (ФЛ с корп-сегментом и т.п.).
==============================================================================*/
SELECT @Suite AS suite, 'M26_SEGMENT_CONSISTENCY' AS scenario,
       source, segment, entrepreneur_category, borrower_type, loans
FROM (
    SELECT l.l_source AS source,
           ISNULL(l.l_segment, N'(NULL)') AS segment,
           ISNULL(l.l_entrepreneur_category, N'(NULL)') AS entrepreneur_category,
           ISNULL(b.b_borrower_type, N'(НЕТ В borrower)') AS borrower_type,
           COUNT_BIG(*) AS loans,
           ROW_NUMBER() OVER (PARTITION BY l.l_source ORDER BY COUNT_BIG(*) DESC) AS rn
    FROM #la l
    LEFT JOIN #b b ON b.b_borrower_id = l.l_borrower_id
    GROUP BY l.l_source, ISNULL(l.l_segment, N'(NULL)'),
             ISNULL(l.l_entrepreneur_category, N'(NULL)'),
             ISNULL(b.b_borrower_type, N'(НЕТ В borrower)')
) d
WHERE rn <= @TopN
ORDER BY source, loans DESC
OPTION (MAXDOP 1);


/*==============================================================================
  M27 — Клиенты-ИП: договоры как ФЛ и как ИП.
  PII: b_iin_bin НЕ выводится. Только счётчик идентификаторов, у которых
  встречаются обе роли. L1/E14 показал, что ie_flag стоит ТОЛЬКО на ЮЛ —
  сценарий проверяет, не порождает ли это раздвоение одного человека.
==============================================================================*/
   Флаг сравнивается КАК СТРОКА, а не через CONVERT(int, ...): фактический тип
   поля не подтверждён, и жёсткий каст уронил бы весь батч на первом же 'Y'.
   Домен печатается сам — не нужно заранее знать, какое значение означает ИП. */
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
    SELECT l_source AS source, l_financial_consultant, COUNT_BIG(*) AS loans
    FROM #la
    WHERE l_financial_consultant IS NOT NULL
      AND LTRIM(RTRIM(l_financial_consultant)) <> N''
    GROUP BY l_source, l_financial_consultant
) d
GROUP BY source
ORDER BY source
OPTION (MAXDOP 1);

/* Сколько договоров вообще не привязано к консультанту — заполненность поля. */
SELECT @Suite AS suite, 'M40b_CONSULTANT_FILL_RATE' AS scenario,
       l_source AS source,
       COUNT_BIG(*) AS active_loans,
       SUM(CASE WHEN l_financial_consultant IS NULL
                  OR LTRIM(RTRIM(l_financial_consultant)) = N''
                THEN 1 ELSE 0 END) AS no_consultant
FROM #la
GROUP BY l_source
ORDER BY source
OPTION (MAXDOP 1);


/*------------------------------------------------------------------------------
  УБОРКА (немедленная — после переполнения tempdb 17.07)
------------------------------------------------------------------------------*/
IF OBJECT_ID('tempdb..#la')      IS NOT NULL DROP TABLE #la;
IF OBJECT_ID('tempdb..#la_last') IS NOT NULL DROP TABLE #la_last;
IF OBJECT_ID('tempdb..#acct')    IS NOT NULL DROP TABLE #acct;
IF OBJECT_ID('tempdb..#b')       IS NOT NULL DROP TABLE #b;
IF OBJECT_ID('tempdb..#pl')      IS NOT NULL DROP TABLE #pl;
