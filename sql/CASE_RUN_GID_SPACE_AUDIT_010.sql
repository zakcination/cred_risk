/*==============================================================================
  CASE_RUN_GID_SPACE_AUDIT_010

  Kadirzhan: gid-пространства различаются по префиксу. Этот скрипт проверяет
  это ЭМПИРИЧЕСКИ, на значениях, не на именах колонок (CLAUDE.md: "имя
  колонки ≠ семантика" — уже стоило времени: la_loan_id, l_collateral_id).

  RESULT 01 — базовая статистика (диапазон, длина в цифрах) по каждой
              gid-колонке схемы.
  RESULT 02 — coverage-тест: для каждой колонки, предполагаемой (по имени
              или схемной аннотации) FK-ссылкой на loans.l_gid, — реальный
              % совпадения distinct-значений с ПОЛНЫМ множеством loans.l_gid
              (все report_date, не один срез — те же основания, что в L12.3:
              проверяемые таблицы событийные/исторические).
  RESULT 03 — распределение по 2-значному префиксу, прямой ответ на вопрос
              Кадиржана.

  Инвентарь gid-колонок (bi_canvas TABLES[], schema_introspection 30.07.2026):
    loans.l_gid               — эталонное пространство ("глобальный ключ")
    loans.dlcr_dprt_gid       — НЕ проверялось; "dprt" похоже на департамент,
                                не на договор — ожидаемо другое пространство
    loan_account.la_gid       — CONFIRMED (FINDINGS.md §1)
    pledges.c_loan_gid        — CONFIRMED (Sailau, "100%", письмо №5)
    restructuring_v2.dlcr_gid — предполагалось по схемной аннотации (L12.3),
                                этот скрипт — первая живая проверка именно
                                этого предположения
    writeoff.w_dlcrp_dlcr_gid — НЕ проверялось
    bankrupt.b_dog_gid        — НЕ проверялось
    ratings.r_deal_gid        — НЕ проверялось
    Guarantees.g_gid          — собственный ключ Guarantees, не FK на loans
    Guarantees.g_clnt_gid     — предположительно клиентское пространство;
                                кандидата-таблицы для проверки нет: borrower
                                не имеет отдельной gid-колонки, только
                                b_borrower_id (bigint), см. L0.2/L4.1.
                                Всё равно включён в coverage-тест — низкий
                                % совпадения с loans.l_gid будет подтверждением
                                отдельного пространства, а не пробелом теста.

  Read-only, MAXDOP 1, без PII (gid — технический идентификатор, не ФИО/
  ИИН/номер договора/IBAN).
==============================================================================*/

USE [Dictionaries];
SET NOCOUNT ON;

DECLARE @CaseRun varchar(120) = 'CASE_RUN_GID_SPACE_AUDIT_010';


/*==============================================================================
  RESULT 01 — Базовая статистика по каждой gid-колонке
==============================================================================*/
SELECT @CaseRun AS case_run, '01_GID_COLUMN_STATS' AS result_set, x.* FROM (
    SELECT 'loans' AS table_name, 'l_gid' AS gid_column,
           COUNT_BIG(*) AS row_count, COUNT_BIG(DISTINCT l_gid) AS distinct_count,
           MIN(l_gid) AS min_val, MAX(l_gid) AS max_val,
           MIN(LEN(CAST(l_gid AS varchar(20)))) AS min_digit_len,
           MAX(LEN(CAST(l_gid AS varchar(20)))) AS max_digit_len
    FROM [Dictionaries].[risk_analytics].[loans]

    UNION ALL
    SELECT 'loans', 'dlcr_dprt_gid',
           COUNT_BIG(*), COUNT_BIG(DISTINCT dlcr_dprt_gid),
           MIN(dlcr_dprt_gid), MAX(dlcr_dprt_gid),
           MIN(LEN(CAST(dlcr_dprt_gid AS varchar(20)))), MAX(LEN(CAST(dlcr_dprt_gid AS varchar(20))))
    FROM [Dictionaries].[risk_analytics].[loans] WHERE dlcr_dprt_gid IS NOT NULL

    UNION ALL
    SELECT 'loan_account', 'la_gid',
           COUNT_BIG(*), COUNT_BIG(DISTINCT la_gid),
           MIN(la_gid), MAX(la_gid),
           MIN(LEN(CAST(la_gid AS varchar(20)))), MAX(LEN(CAST(la_gid AS varchar(20))))
    FROM [Dictionaries].[risk_analytics].[loan_account]

    UNION ALL
    SELECT 'pledges', 'c_loan_gid',
           COUNT_BIG(*), COUNT_BIG(DISTINCT c_loan_gid),
           MIN(c_loan_gid), MAX(c_loan_gid),
           MIN(LEN(CAST(c_loan_gid AS varchar(20)))), MAX(LEN(CAST(c_loan_gid AS varchar(20))))
    FROM [Dictionaries].[risk_analytics].[pledges] WHERE c_loan_gid IS NOT NULL

    UNION ALL
    SELECT 'restructuring_v2', 'dlcr_gid',
           COUNT_BIG(*), COUNT_BIG(DISTINCT dlcr_gid),
           MIN(dlcr_gid), MAX(dlcr_gid),
           MIN(LEN(CAST(dlcr_gid AS varchar(20)))), MAX(LEN(CAST(dlcr_gid AS varchar(20))))
    FROM [Dictionaries].[risk_analytics].[restructuring_v2] WHERE dlcr_gid IS NOT NULL

    UNION ALL
    SELECT 'writeoff', 'w_dlcrp_dlcr_gid',
           COUNT_BIG(*), COUNT_BIG(DISTINCT w_dlcrp_dlcr_gid),
           MIN(w_dlcrp_dlcr_gid), MAX(w_dlcrp_dlcr_gid),
           MIN(LEN(CAST(w_dlcrp_dlcr_gid AS varchar(20)))), MAX(LEN(CAST(w_dlcrp_dlcr_gid AS varchar(20))))
    FROM [Dictionaries].[risk_analytics].[writeoff] WHERE w_dlcrp_dlcr_gid IS NOT NULL

    UNION ALL
    SELECT 'bankrupt', 'b_dog_gid',
           COUNT_BIG(*), COUNT_BIG(DISTINCT b_dog_gid),
           MIN(b_dog_gid), MAX(b_dog_gid),
           MIN(LEN(CAST(b_dog_gid AS varchar(20)))), MAX(LEN(CAST(b_dog_gid AS varchar(20))))
    FROM [Dictionaries].[risk_analytics].[bankrupt] WHERE b_dog_gid IS NOT NULL

    UNION ALL
    SELECT 'ratings', 'r_deal_gid',
           COUNT_BIG(*), COUNT_BIG(DISTINCT r_deal_gid),
           MIN(r_deal_gid), MAX(r_deal_gid),
           MIN(LEN(CAST(r_deal_gid AS varchar(20)))), MAX(LEN(CAST(r_deal_gid AS varchar(20))))
    FROM [Dictionaries].[risk_analytics].[ratings] WHERE r_deal_gid IS NOT NULL

    UNION ALL
    SELECT 'Guarantees', 'g_gid',
           COUNT_BIG(*), COUNT_BIG(DISTINCT g_gid),
           MIN(g_gid), MAX(g_gid),
           MIN(LEN(CAST(g_gid AS varchar(20)))), MAX(LEN(CAST(g_gid AS varchar(20))))
    FROM [Dictionaries].[risk_analytics].[Guarantees]

    UNION ALL
    SELECT 'Guarantees', 'g_clnt_gid',
           COUNT_BIG(*), COUNT_BIG(DISTINCT g_clnt_gid),
           MIN(g_clnt_gid), MAX(g_clnt_gid),
           MIN(LEN(CAST(g_clnt_gid AS varchar(20)))), MAX(LEN(CAST(g_clnt_gid AS varchar(20))))
    FROM [Dictionaries].[risk_analytics].[Guarantees] WHERE g_clnt_gid IS NOT NULL
) x
OPTION (MAXDOP 1);


/*==============================================================================
  RESULT 02 — Coverage-тест против loans.l_gid (полное множество, все даты)
==============================================================================*/
IF OBJECT_ID('tempdb..#loans_gid') IS NOT NULL DROP TABLE #loans_gid;
SELECT DISTINCT l_gid
INTO #loans_gid
FROM [Dictionaries].[risk_analytics].[loans]
OPTION (MAXDOP 1);
CREATE UNIQUE CLUSTERED INDEX ix_loans_gid ON #loans_gid(l_gid);

;WITH Candidates AS (
    SELECT 'loans' AS table_name, 'dlcr_dprt_gid' AS gid_column, dlcr_dprt_gid AS gid_value
        FROM [Dictionaries].[risk_analytics].[loans] WHERE dlcr_dprt_gid IS NOT NULL
    UNION ALL
    SELECT 'loan_account', 'la_gid', la_gid
        FROM [Dictionaries].[risk_analytics].[loan_account]
    UNION ALL
    SELECT 'pledges', 'c_loan_gid', c_loan_gid
        FROM [Dictionaries].[risk_analytics].[pledges] WHERE c_loan_gid IS NOT NULL
    UNION ALL
    SELECT 'restructuring_v2', 'dlcr_gid', dlcr_gid
        FROM [Dictionaries].[risk_analytics].[restructuring_v2] WHERE dlcr_gid IS NOT NULL
    UNION ALL
    SELECT 'writeoff', 'w_dlcrp_dlcr_gid', w_dlcrp_dlcr_gid
        FROM [Dictionaries].[risk_analytics].[writeoff] WHERE w_dlcrp_dlcr_gid IS NOT NULL
    UNION ALL
    SELECT 'bankrupt', 'b_dog_gid', b_dog_gid
        FROM [Dictionaries].[risk_analytics].[bankrupt] WHERE b_dog_gid IS NOT NULL
    UNION ALL
    SELECT 'ratings', 'r_deal_gid', r_deal_gid
        FROM [Dictionaries].[risk_analytics].[ratings] WHERE r_deal_gid IS NOT NULL
    UNION ALL
    SELECT 'Guarantees', 'g_clnt_gid', g_clnt_gid
        FROM [Dictionaries].[risk_analytics].[Guarantees] WHERE g_clnt_gid IS NOT NULL
),
Distinct_Candidates AS (
    SELECT DISTINCT table_name, gid_column, gid_value FROM Candidates
)
SELECT
    @CaseRun AS case_run,
    '02_FK_COVERAGE_VS_LOANS_L_GID' AS result_set,
    dc.table_name,
    dc.gid_column,
    COUNT_BIG(*) AS distinct_child_values,
    SUM(CASE WHEN lg.l_gid IS NOT NULL THEN 1 ELSE 0 END) AS matched_in_loans_l_gid,
    CAST(100.0 * SUM(CASE WHEN lg.l_gid IS NOT NULL THEN 1 ELSE 0 END)
        / NULLIF(COUNT_BIG(*), 0) AS decimal(6,2)) AS match_pct,
    CASE
        WHEN 100.0 * SUM(CASE WHEN lg.l_gid IS NOT NULL THEN 1 ELSE 0 END)
             / NULLIF(COUNT_BIG(*), 0) >= 95.0
            THEN 'SAME_SPACE_AS_LOANS'
        WHEN 100.0 * SUM(CASE WHEN lg.l_gid IS NOT NULL THEN 1 ELSE 0 END)
             / NULLIF(COUNT_BIG(*), 0) <= 5.0
            THEN 'DIFFERENT_SPACE'
        ELSE 'AMBIGUOUS_REVIEW_REQUIRED'
    END AS verdict
FROM Distinct_Candidates dc
LEFT JOIN #loans_gid lg ON lg.l_gid = dc.gid_value
GROUP BY dc.table_name, dc.gid_column
ORDER BY match_pct ASC
OPTION (MAXDOP 1);

DROP TABLE #loans_gid;


/*==============================================================================
  RESULT 03 — Распределение по 2-значному префиксу (прямой ответ на вопрос
  Кадиржана: "пространства различаются по префиксу")
==============================================================================*/
SELECT
    @CaseRun AS case_run,
    '03_PREFIX_DISTRIBUTION' AS result_set,
    y.table_name, y.gid_column, y.gid_prefix_2,
    COUNT_BIG(*) AS distinct_values_with_this_prefix
FROM (
    SELECT DISTINCT 'loans' AS table_name, 'l_gid' AS gid_column,
        LEFT(CAST(l_gid AS varchar(20)), 2) AS gid_prefix_2, l_gid AS gid_value
    FROM [Dictionaries].[risk_analytics].[loans]

    UNION ALL
    SELECT DISTINCT 'loan_account', 'la_gid', LEFT(CAST(la_gid AS varchar(20)), 2), la_gid
    FROM [Dictionaries].[risk_analytics].[loan_account]

    UNION ALL
    SELECT DISTINCT 'pledges', 'c_loan_gid', LEFT(CAST(c_loan_gid AS varchar(20)), 2), c_loan_gid
    FROM [Dictionaries].[risk_analytics].[pledges] WHERE c_loan_gid IS NOT NULL

    UNION ALL
    SELECT DISTINCT 'restructuring_v2', 'dlcr_gid', LEFT(CAST(dlcr_gid AS varchar(20)), 2), dlcr_gid
    FROM [Dictionaries].[risk_analytics].[restructuring_v2] WHERE dlcr_gid IS NOT NULL

    UNION ALL
    SELECT DISTINCT 'writeoff', 'w_dlcrp_dlcr_gid', LEFT(CAST(w_dlcrp_dlcr_gid AS varchar(20)), 2), w_dlcrp_dlcr_gid
    FROM [Dictionaries].[risk_analytics].[writeoff] WHERE w_dlcrp_dlcr_gid IS NOT NULL

    UNION ALL
    SELECT DISTINCT 'bankrupt', 'b_dog_gid', LEFT(CAST(b_dog_gid AS varchar(20)), 2), b_dog_gid
    FROM [Dictionaries].[risk_analytics].[bankrupt] WHERE b_dog_gid IS NOT NULL

    UNION ALL
    SELECT DISTINCT 'ratings', 'r_deal_gid', LEFT(CAST(r_deal_gid AS varchar(20)), 2), r_deal_gid
    FROM [Dictionaries].[risk_analytics].[ratings] WHERE r_deal_gid IS NOT NULL

    UNION ALL
    SELECT DISTINCT 'Guarantees', 'g_gid', LEFT(CAST(g_gid AS varchar(20)), 2), g_gid
    FROM [Dictionaries].[risk_analytics].[Guarantees]

    UNION ALL
    SELECT DISTINCT 'Guarantees', 'g_clnt_gid', LEFT(CAST(g_clnt_gid AS varchar(20)), 2), g_clnt_gid
    FROM [Dictionaries].[risk_analytics].[Guarantees] WHERE g_clnt_gid IS NOT NULL
) y
GROUP BY y.table_name, y.gid_column, y.gid_prefix_2
ORDER BY y.table_name, y.gid_column, distinct_values_with_this_prefix DESC
OPTION (MAXDOP 1);


/*==============================================================================
  RESULT 04 — [ДОБАВЛЕНО 06.08.2026, по факту живого прогона] Прямая проверка:
  что кодирует 2-значный префикс? RESULT 03 показал ровно 4 префикса
  (10/11/12/27) в loans.l_gid — ровно столько же, сколько известных source
  (S01/S02/S03/S17). Гипотеза: префикс = source, а не "таблица/сущность"
  (заявленное Кадиржаном "пространства различаются по префиксу" относилось,
  похоже, не к разным ТАБЛИЦАМ — все они по RESULT 02 делят одно пространство
  loans.l_gid — а к разным ИСТОЧНИКАМ внутри этого общего пространства).
  Проверяется здесь напрямую, не предполагается.
==============================================================================*/
SELECT
    @CaseRun AS case_run,
    '04_PREFIX_VS_SOURCE' AS result_set,
    LEFT(CAST(l_gid AS varchar(20)), 2) AS gid_prefix_2,
    l_source,
    COUNT_BIG(DISTINCT l_gid) AS distinct_gid_count
FROM [Dictionaries].[risk_analytics].[loans]
GROUP BY LEFT(CAST(l_gid AS varchar(20)), 2), l_source
ORDER BY gid_prefix_2, distinct_gid_count DESC
OPTION (MAXDOP 1);
-- Чистая 1:1 (каждый префикс -> ровно один source) подтвердит гипотезу
-- "префикс = source". Смешение (один префикс -> несколько source, или
-- наоборот) её опровергнет — тогда префикс кодирует что-то ещё (филиал/
-- регион/дата миграции) и это отдельный вопрос на выяснение.
