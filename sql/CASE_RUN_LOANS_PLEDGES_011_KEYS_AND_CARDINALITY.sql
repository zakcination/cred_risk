/*==============================================================================
  CASE_RUN_LOANS_PLEDGES_011_KEYS_AND_CARDINALITY

  Задача (Miras, 06.08.2026): протестировать DWH `loans`/`loans_active` и
  `pledges` живьём — (А) подтвердить рабочие ключевые колонки и проверить,
  нужен ли составной ключ (source+gid), вместо доверия имени колонки/схемной
  аннотации (CLAUDE.md: "имя колонки ≠ семантика" — уже стоило времени на
  la_loan_id, l_collateral_id); (Б) категоризировать активные договоры
  с/без залога; (В) построить полную карту кардинальности loan↔pledge:
  1 залог → N договоров, 1 договор → N залогов, 1-1, и прочие/пограничные
  случаи — статистика, не построчный вывод.

  ИСХОДНАЯ БАЗА (уже подтверждено ранее, здесь ПЕРЕПРОВЕРЯЕТСЯ живьём, не
  берётся на веру):
    - v8 (bi_canvas): pledges.c_source+c_loan_gid = loans.l_source+l_gid —
      ЕДИНСТВЕННЫЙ подтверждённый путь loans↔pledges (100%).
    - d8 (bi_canvas) / DWH-16 (#4): l_collateral_id как прямой FK на pledges
      — ОПРОВЕРГНУТО, ненадёжен для join.
    - L9.4 (risk_dwh_layered_check.sql): "1 объект залога → N договоров" уже
      отмечено как ЛЕГИТИМНОЕ many-to-many, не дубль. ЧАСТЬ C здесь расширяет
      L9.4 до полной гистограммы кардинальности в ОБЕ стороны + 1-1 срез.
    - FINDINGS §2/§9.6 (#8): `loans` содержит 70 дублей по логическому ключу
      (l_gid,l_loan_number), 0 ограничений БД. grain `loans` НЕ чист.
    - bi_canvas #29/DWH-06: grain `loans_active` НИКОГДА независимо не
      проверялся (только `loans`) — ЧАСТЬ A1 ниже закрывает этот пробел.
    - Kadirzhan (относится к тому же вопросу): gid-пространства различаются
      по префиксу — ЧАСТЬ A2 проверяет это конкретно для loans/pledges
      (дополняет CASE_RUN_GID_SPACE_AUDIT_010, который проверял остальные
      таблицы, но не саму связку loans↔pledges).

  ЧАСТИ:
    A0. Схема+типы ключевых кандидатов (Шаг 0 спирали).
    A1. Grain/уникальность: raw_rows vs distinct(gid) vs distinct(source+gid)
        на срезе @AsOf, для loans (мастер), loans_active (периметр), pledges.
    A2. Коллизии l_gid между source — нужен ли source в составном ключе.
    A3. Coverage-тест кандидатов ключа pledges→loans_active (подтверждённый
        c_source+c_loan_gid, против c_loan_gid без source, c_loan_id, номер).
    B1. Категоризация loans_active: с залогом / без (крест l_collateral_id
        populated × найден-в-pledges по подтверждённому ключу).
    C1–C3. Кардинальность на MATCHED-популяции: loan→collaterals,
        collateral→loans, полная 4-квадрантная матрица связей.
    D1–D4. Пограничные случаи: orphan pledges (закрыт vs реально не найден),
        NULL-ключи, точные дубли пар (loan,collateral).

  Read-only, MAXDOP 1, без PII (номера договоров/gid — технические
  идентификаторы, не выводятся вместе с ФИО/ИИН/IBAN). Сначала агрегат,
  не SELECT *. Все #temp — с явным DROP.

  ВНИМАНИЕ: c_collateral_id имеет тип float (аномалия, найдена в прогоне
  №1, 31.07.2026) — группировка по float как по идентификатору залога
  теоретически подвержена ошибкам сравнения плавающей точки. Здесь это
  единственный доступный идентификатор объекта залога в данных, поэтому
  используется как есть, с явной пометкой в выводе.
==============================================================================*/

USE [Dictionaries];
SET NOCOUNT ON;

DECLARE @CaseRun varchar(120) = 'CASE_RUN_LOANS_PLEDGES_011_KEYS_AND_CARDINALITY';
-- Фикс 06.08.2026: жёсткая дата '2026-07-01' на живом прогоне дала 0 строк
-- везде (loans/loans_active/pledges) — снимок с этой датой в таблице больше
-- не существует (l_report_date — маркер ТЕКУЩЕГО состояния, не хранимая
-- история, см. CLAUDE.md). @AsOf теперь резолвится от факта, не хардкодится.
DECLARE @AsOf date = (SELECT MAX(l_report_date) FROM [Dictionaries].[risk_analytics].[loans_active]);


/*==============================================================================
  00 — Scope control: какая дата реально резолвилась, совпадают ли "последние"
       даты во всех трёх таблицах (если нет — это само по себе находка)
==============================================================================*/
SELECT @CaseRun AS case_run, '00_SCOPE_CONTROL' AS result_set,
       @AsOf AS resolved_AsOf_from_loans_active,
       (SELECT MAX(l_report_date) FROM [Dictionaries].[risk_analytics].[loans]) AS max_l_report_date_in_loans_master,
       (SELECT MAX(c_reporting_date) FROM [Dictionaries].[risk_analytics].[pledges]) AS max_c_reporting_date_in_pledges,
       (SELECT COUNT_BIG(*) FROM [Dictionaries].[risk_analytics].[loans_active] WHERE l_report_date = @AsOf) AS loans_active_rows_at_resolved_date
OPTION (MAXDOP 1);


/*==============================================================================
  A0 — Схема: типы и nullability ключевых кандидатов
==============================================================================*/
SELECT @CaseRun AS case_run, 'A0_SCHEMA_KEY_CANDIDATES' AS result_set,
       TABLE_NAME, COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH,
       NUMERIC_PRECISION, IS_NULLABLE
FROM [Dictionaries].INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'risk_analytics'
  AND (
       (TABLE_NAME = 'loans'        AND COLUMN_NAME IN ('l_gid','l_source','l_report_date','l_loan_number','l_loan_id','l_collateral_id'))
    OR (TABLE_NAME = 'loans_active' AND COLUMN_NAME IN ('l_gid','l_source','l_report_date','l_loan_number','l_loan_id','l_collateral_id'))
    OR (TABLE_NAME = 'pledges'      AND COLUMN_NAME IN ('c_loan_gid','c_source','c_reporting_date','c_collateral_id','c_loan_id','c_contract_number'))
  )
ORDER BY TABLE_NAME, COLUMN_NAME
OPTION (MAXDOP 1);


/*==============================================================================
  A1 — Grain/уникальность на срезе @AsOf, по source
       raw_rows > distinct_source_gid  ⇒  дубли по (source,gid) внутри даты
==============================================================================*/
SELECT @CaseRun AS case_run, 'A1_GRAIN_TEST' AS result_set, x.* FROM (
    SELECT 'loans' AS table_name, l_source AS source,
           COUNT_BIG(*) AS raw_rows,
           COUNT_BIG(DISTINCT l_gid) AS distinct_gid,
           COUNT_BIG(DISTINCT CONCAT(l_source, N'|', l_gid)) AS distinct_source_gid,
           COUNT_BIG(DISTINCT l_loan_number) AS distinct_loan_number
    FROM [Dictionaries].[risk_analytics].[loans]
    WHERE l_report_date = @AsOf
    GROUP BY l_source

    UNION ALL
    SELECT 'loans_active', l_source,
           COUNT_BIG(*),
           COUNT_BIG(DISTINCT l_gid),
           COUNT_BIG(DISTINCT CONCAT(l_source, N'|', l_gid)),
           COUNT_BIG(DISTINCT l_loan_number)
    FROM [Dictionaries].[risk_analytics].[loans_active]
    WHERE l_report_date = @AsOf
    GROUP BY l_source

    UNION ALL
    SELECT 'pledges', c_source,
           COUNT_BIG(*),
           COUNT_BIG(DISTINCT c_loan_gid),
           COUNT_BIG(DISTINCT CONCAT(c_source, N'|', c_loan_gid)),
           NULL
    FROM [Dictionaries].[risk_analytics].[pledges]
    WHERE c_reporting_date = @AsOf
    GROUP BY c_source
) x
ORDER BY table_name, source
OPTION (MAXDOP 1);


/*==============================================================================
  A2 — Коллизии l_gid между source: обязателен ли source в составном ключе,
       или l_gid уже глобально уникален сам по себе (проверка утверждения
       Кадиржана конкретно для loans/loans_active)
==============================================================================*/
SELECT @CaseRun AS case_run, 'A2_GID_CROSS_SOURCE_COLLISION' AS result_set, z.* FROM (
    SELECT 'loans' AS table_name,
           COUNT_BIG(*) AS distinct_gid_values_tested,
           SUM(CASE WHEN src_count > 1 THEN 1 ELSE 0 END) AS gid_values_in_multiple_sources,
           CAST(100.0 * SUM(CASE WHEN src_count > 1 THEN 1 ELSE 0 END)
                / NULLIF(COUNT_BIG(*), 0) AS decimal(6,2)) AS pct_colliding,
           CASE WHEN COUNT_BIG(*) = 0
                THEN 'НЕТ ДАННЫХ на резолвленный @AsOf — см. 00_SCOPE_CONTROL'
                WHEN ISNULL(SUM(CASE WHEN src_count > 1 THEN 1 ELSE 0 END), 0) = 0
                THEN 'l_gid ALONE ДОСТАТОЧЕН — source в составном ключе избыточен (но безвреден)'
                ELSE 'l_gid КОЛЛИЗИРУЕТ БЕЗ source — составной ключ (source,l_gid) ОБЯЗАТЕЛЕН'
           END AS verdict
    FROM (
        SELECT l_gid, COUNT(DISTINCT l_source) AS src_count
        FROM [Dictionaries].[risk_analytics].[loans]
        WHERE l_report_date = @AsOf
        GROUP BY l_gid
    ) g

    UNION ALL
    SELECT 'loans_active',
           COUNT_BIG(*),
           SUM(CASE WHEN src_count > 1 THEN 1 ELSE 0 END),
           CAST(100.0 * SUM(CASE WHEN src_count > 1 THEN 1 ELSE 0 END)
                / NULLIF(COUNT_BIG(*), 0) AS decimal(6,2)),
           CASE WHEN COUNT_BIG(*) = 0
                THEN 'НЕТ ДАННЫХ на резолвленный @AsOf — см. 00_SCOPE_CONTROL'
                WHEN ISNULL(SUM(CASE WHEN src_count > 1 THEN 1 ELSE 0 END), 0) = 0
                THEN 'l_gid ALONE ДОСТАТОЧЕН — source в составном ключе избыточен (но безвреден)'
                ELSE 'l_gid КОЛЛИЗИРУЕТ БЕЗ source — составной ключ (source,l_gid) ОБЯЗАТЕЛЕН'
           END
    FROM (
        SELECT l_gid, COUNT(DISTINCT l_source) AS src_count
        FROM [Dictionaries].[risk_analytics].[loans_active]
        WHERE l_report_date = @AsOf
        GROUP BY l_gid
    ) g
) z
OPTION (MAXDOP 1);


/*==============================================================================
  Материализация рабочих срезов (ОДИН раз, дальше — переиспользование;
  урок L11.1/L4.1: JOIN на #temp с индексом, не на сырых таблицах напрямую)
==============================================================================*/
IF OBJECT_ID('tempdb..#loans_active_keys') IS NOT NULL DROP TABLE #loans_active_keys;
SELECT l_source, l_gid, l_loan_number, l_loan_id, l_collateral_id
INTO #loans_active_keys
FROM [Dictionaries].[risk_analytics].[loans_active]
WHERE l_report_date = @AsOf
OPTION (MAXDOP 1);
CREATE CLUSTERED INDEX ix_lak_source_gid ON #loans_active_keys(l_source, l_gid);
CREATE INDEX ix_lak_gid ON #loans_active_keys(l_gid);
CREATE INDEX ix_lak_loan_number ON #loans_active_keys(l_loan_number);
CREATE INDEX ix_lak_loan_id ON #loans_active_keys(l_loan_id);

IF OBJECT_ID('tempdb..#pledges_slice') IS NOT NULL DROP TABLE #pledges_slice;
SELECT c_source, c_loan_gid, c_loan_id, c_contract_number, c_collateral_id
INTO #pledges_slice
FROM [Dictionaries].[risk_analytics].[pledges]
WHERE c_reporting_date = @AsOf
OPTION (MAXDOP 1);
CREATE CLUSTERED INDEX ix_ps_source_gid ON #pledges_slice(c_source, c_loan_gid);


/*==============================================================================
  A3 — Coverage-тест кандидатов ключа pledges → loans_active
==============================================================================*/
SELECT @CaseRun AS case_run, 'A3_KEY_CANDIDATE_COVERAGE' AS result_set, y.* FROM (
    SELECT 'c_source+c_loan_gid (ПОДТВЕРЖДЁННЫЙ, v8)' AS candidate_key,
           COUNT_BIG(*) AS pledges_rows,
           SUM(t.is_matched) AS matched
    FROM (
        SELECT CASE WHEN EXISTS (SELECT 1 FROM #loans_active_keys k
                                  WHERE k.l_source = p.c_source AND k.l_gid = p.c_loan_gid)
                    THEN 1 ELSE 0 END AS is_matched
        FROM #pledges_slice p
    ) t

    UNION ALL
    SELECT 'c_loan_gid один, без source',
           COUNT_BIG(*),
           SUM(t.is_matched)
    FROM (
        SELECT CASE WHEN EXISTS (SELECT 1 FROM #loans_active_keys k WHERE k.l_gid = p.c_loan_gid)
                    THEN 1 ELSE 0 END AS is_matched
        FROM #pledges_slice p
    ) t

    UNION ALL
    SELECT 'c_loan_id (ошибочный ключ DWH-15, для контраста)',
           COUNT_BIG(*),
           SUM(t.is_matched)
    FROM (
        SELECT CASE WHEN EXISTS (SELECT 1 FROM #loans_active_keys k
                                  WHERE k.l_loan_id = CAST(p.c_loan_id AS varchar(255)))
                    THEN 1 ELSE 0 END AS is_matched
        FROM #pledges_slice p
    ) t

    UNION ALL
    SELECT 'c_contract_number vs l_loan_number',
           COUNT_BIG(*),
           SUM(t.is_matched)
    FROM (
        SELECT CASE WHEN EXISTS (SELECT 1 FROM #loans_active_keys k WHERE k.l_loan_number = p.c_contract_number)
                    THEN 1 ELSE 0 END AS is_matched
        FROM #pledges_slice p
    ) t
) y
OPTION (MAXDOP 1);
-- match_pct считается на стороне клиента/BI из pledges_rows и matched, чтобы избежать
-- деления в UNION ALL по разным CASE-веткам одной колонки.
-- Фикс 06.08.2026: SUM(CASE WHEN EXISTS(...) ...) в одной area с COUNT_BIG(*) без
-- GROUP BY ловит Msg 130 у движка ("aggregate function on expression containing an
-- aggregate or a subquery") — вынесено вычисление флага в производную таблицу t,
-- агрегация — уже НАД материализованным столбцом, без коррелированного предиката
-- в той же области видимости, что и сам SUM.


/*==============================================================================
  B1 — Категоризация loans_active: с залогом / без
       (крест l_collateral_id populated × найден-в-pledges по v8-ключу)
==============================================================================*/
SELECT @CaseRun AS case_run, 'B1_COLLATERAL_CATEGORY' AS result_set,
       source, l_collateral_id_state, pledges_state,
       COUNT_BIG(*) AS active_loans
FROM (
    SELECT k.l_source AS source,
           CASE WHEN k.l_collateral_id IS NOT NULL THEN 'HAS_COLLATERAL_ID' ELSE 'NO_COLLATERAL_ID' END AS l_collateral_id_state,
           CASE WHEN EXISTS (SELECT 1 FROM #pledges_slice p WHERE p.c_source = k.l_source AND p.c_loan_gid = k.l_gid)
                THEN 'FOUND_IN_PLEDGES' ELSE 'NOT_IN_PLEDGES' END AS pledges_state
    FROM #loans_active_keys k
) t
GROUP BY source, l_collateral_id_state, pledges_state
ORDER BY source, l_collateral_id_state, pledges_state
OPTION (MAXDOP 1);
-- Фикс 06.08.2026: та же схема, что A3 — флаги считаются в производной таблице t,
-- GROUP BY снаружи работает уже над материализованными столбцами, не над
-- CASE WHEN EXISTS(...) напрямую (см. Msg 130/156 в истории прогонов).
/* Ожидаемые категории:
     HAS_ID + FOUND     — чисто, как и должно быть
     HAS_ID + NOT_FOUND — известный разрыв (DWH-15/#3: было 49 S03 на старом
                          ключе, 94 732 S03 / 3 566 S01 на верном — письмо 04.08.2026)
     NO_ID  + FOUND     — неожиданность: залог есть, а l_collateral_id пуст — заслуживает вопроса
     NO_ID  + NOT_FOUND — обычный необеспеченный продукт, ожидаемо              */


/*==============================================================================
  Материализация MATCHED-моста loan↔collateral (дедуп по (source,gid,collateral)
  с raw_row_count — источник для D4 "точные дубли пары")
==============================================================================*/
IF OBJECT_ID('tempdb..#bridge') IS NOT NULL DROP TABLE #bridge;
SELECT c_source, c_loan_gid, c_collateral_id, COUNT_BIG(*) AS raw_row_count
INTO #bridge
FROM (
    SELECT p.c_source, p.c_loan_gid, p.c_collateral_id
    FROM #pledges_slice p
    WHERE EXISTS (SELECT 1 FROM #loans_active_keys k WHERE k.l_source = p.c_source AND k.l_gid = p.c_loan_gid)
) m
GROUP BY c_source, c_loan_gid, c_collateral_id
OPTION (MAXDOP 1);
CREATE CLUSTERED INDEX ix_bridge_loan ON #bridge(c_source, c_loan_gid, c_collateral_id);

IF OBJECT_ID('tempdb..#loan_mult') IS NOT NULL DROP TABLE #loan_mult;
SELECT c_source, c_loan_gid,
       COUNT(DISTINCT c_collateral_id) AS distinct_collaterals,
       SUM(CASE WHEN c_collateral_id IS NULL THEN 1 ELSE 0 END) AS null_collateral_rows,
       COUNT(*) AS total_relationship_rows
INTO #loan_mult
FROM #bridge
GROUP BY c_source, c_loan_gid
OPTION (MAXDOP 1);
CREATE CLUSTERED INDEX ix_loan_mult ON #loan_mult(c_source, c_loan_gid);

IF OBJECT_ID('tempdb..#collateral_mult') IS NOT NULL DROP TABLE #collateral_mult;
SELECT c_source, c_collateral_id, COUNT(DISTINCT c_loan_gid) AS distinct_loans
INTO #collateral_mult
FROM #bridge
WHERE c_collateral_id IS NOT NULL
GROUP BY c_source, c_collateral_id
OPTION (MAXDOP 1);
CREATE CLUSTERED INDEX ix_collateral_mult ON #collateral_mult(c_source, c_collateral_id);


/*==============================================================================
  C1 — Кардинальность "1 договор → N залогов" (гистограмма по distinct
       c_collateral_id на договор, MATCHED-популяция)
==============================================================================*/
SELECT @CaseRun AS case_run, 'C1_LOAN_TO_COLLATERAL_CARDINALITY' AS result_set,
       c_source AS source,
       CASE WHEN distinct_collaterals = 0 THEN '0_COLLATERALS (только NULL-строки, см. D3)'
            WHEN distinct_collaterals = 1 THEN '1_COLLATERAL'
            WHEN distinct_collaterals BETWEEN 2 AND 3 THEN '2-3_COLLATERALS'
            WHEN distinct_collaterals BETWEEN 4 AND 10 THEN '4-10_COLLATERALS'
            ELSE '11+_COLLATERALS' END AS bucket,
       COUNT_BIG(*) AS loans_in_bucket
FROM #loan_mult
GROUP BY c_source,
       CASE WHEN distinct_collaterals = 0 THEN '0_COLLATERALS (только NULL-строки, см. D3)'
            WHEN distinct_collaterals = 1 THEN '1_COLLATERAL'
            WHEN distinct_collaterals BETWEEN 2 AND 3 THEN '2-3_COLLATERALS'
            WHEN distinct_collaterals BETWEEN 4 AND 10 THEN '4-10_COLLATERALS'
            ELSE '11+_COLLATERALS' END
ORDER BY source, bucket
OPTION (MAXDOP 1);


/*==============================================================================
  C2 — Кардинальность "1 залог → N договоров" (гистограмма, расширяет L9.4)
==============================================================================*/
SELECT @CaseRun AS case_run, 'C2_COLLATERAL_TO_LOAN_CARDINALITY' AS result_set,
       c_source AS source,
       CASE WHEN distinct_loans = 1 THEN '1_LOAN'
            WHEN distinct_loans BETWEEN 2 AND 3 THEN '2-3_LOANS'
            WHEN distinct_loans BETWEEN 4 AND 10 THEN '4-10_LOANS'
            ELSE '11+_LOANS' END AS bucket,
       COUNT_BIG(*) AS collateral_objects_in_bucket
FROM #collateral_mult
GROUP BY c_source,
       CASE WHEN distinct_loans = 1 THEN '1_LOAN'
            WHEN distinct_loans BETWEEN 2 AND 3 THEN '2-3_LOANS'
            WHEN distinct_loans BETWEEN 4 AND 10 THEN '4-10_LOANS'
            ELSE '11+_LOANS' END
ORDER BY source, bucket
OPTION (MAXDOP 1);


/*==============================================================================
  C3 — Полная 4-квадрантная матрица связей (loan,collateral) — включает
       чистую 1-1 и обе N-стороны раздельно + NULL-ветку
==============================================================================*/
SELECT @CaseRun AS case_run, 'C3_FULL_RELATIONSHIP_MATRIX' AS result_set,
       b.c_source AS source,
       CASE
           WHEN b.c_collateral_id IS NULL THEN 'NULL_COLLATERAL_ID (см. D3)'
           WHEN lm.distinct_collaterals = 1 AND cm.distinct_loans = 1 THEN 'ONE_TO_ONE'
           WHEN lm.distinct_collaterals > 1 AND cm.distinct_loans = 1 THEN 'LOAN_HAS_OTHER_COLLATERALS (этот залог — только этот договор)'
           WHEN lm.distinct_collaterals = 1 AND cm.distinct_loans > 1 THEN 'COLLATERAL_SHARED_ACROSS_LOANS (у договора — только этот залог)'
           WHEN lm.distinct_collaterals > 1 AND cm.distinct_loans > 1 THEN 'MANY_TO_MANY'
           ELSE 'UNCLASSIFIED'
       END AS relationship_type,
       COUNT_BIG(*) AS loan_collateral_pairs
FROM #bridge b
LEFT JOIN #loan_mult lm ON lm.c_source = b.c_source AND lm.c_loan_gid = b.c_loan_gid
LEFT JOIN #collateral_mult cm ON cm.c_source = b.c_source AND cm.c_collateral_id = b.c_collateral_id
GROUP BY b.c_source,
       CASE
           WHEN b.c_collateral_id IS NULL THEN 'NULL_COLLATERAL_ID (см. D3)'
           WHEN lm.distinct_collaterals = 1 AND cm.distinct_loans = 1 THEN 'ONE_TO_ONE'
           WHEN lm.distinct_collaterals > 1 AND cm.distinct_loans = 1 THEN 'LOAN_HAS_OTHER_COLLATERALS (этот залог — только этот договор)'
           WHEN lm.distinct_collaterals = 1 AND cm.distinct_loans > 1 THEN 'COLLATERAL_SHARED_ACROSS_LOANS (у договора — только этот залог)'
           WHEN lm.distinct_collaterals > 1 AND cm.distinct_loans > 1 THEN 'MANY_TO_MANY'
           ELSE 'UNCLASSIFIED'
       END
ORDER BY source, relationship_type
OPTION (MAXDOP 1);


/*==============================================================================
  D3 — NULL c_collateral_id в MATCHED-популяции (не участвует в C2/C3-группировке
       по залогу — исключение из COUNT DISTINCT, не 0; правило CLAUDE.md "NULL ≠ 0")
==============================================================================*/
SELECT @CaseRun AS case_run, 'D3_NULL_COLLATERAL_ID_IN_MATCHED' AS result_set,
       c_source AS source,
       SUM(null_collateral_rows) AS null_collateral_id_rows,
       SUM(total_relationship_rows) AS total_relationship_rows,
       CAST(100.0 * SUM(null_collateral_rows) / NULLIF(SUM(total_relationship_rows),0) AS decimal(6,2)) AS pct_null
FROM #loan_mult
GROUP BY c_source
ORDER BY source
OPTION (MAXDOP 1);


/*==============================================================================
  D4 — Точные дубли пары (loan,collateral): одна и та же связь встречается
       > 1 раз сырыми строками pledges — потенциальное задвоение
==============================================================================*/
SELECT @CaseRun AS case_run, 'D4_DUPLICATE_LOAN_COLLATERAL_ROWS' AS result_set,
       c_source AS source,
       COUNT_BIG(*) AS duplicated_pairs,
       SUM(raw_row_count) AS total_raw_rows_involved,
       SUM(raw_row_count - 1) AS excess_rows
FROM #bridge
WHERE raw_row_count > 1
GROUP BY c_source
ORDER BY source
OPTION (MAXDOP 1);

DROP TABLE #bridge;
DROP TABLE #loan_mult;
DROP TABLE #collateral_mult;


/*==============================================================================
  D1 — Классификация "бесхозных" pledges: c_loan_gid не найден в loans_active —
       различить "договор закрыт/неактивен" (не аномалия) от "реально не найден"
==============================================================================*/
IF OBJECT_ID('tempdb..#loans_master_keys') IS NOT NULL DROP TABLE #loans_master_keys;
SELECT DISTINCT l_source, l_gid
INTO #loans_master_keys
FROM [Dictionaries].[risk_analytics].[loans]
WHERE l_report_date = @AsOf
OPTION (MAXDOP 1);
CREATE CLUSTERED INDEX ix_lmk ON #loans_master_keys(l_source, l_gid);

SELECT @CaseRun AS case_run, 'D1_ORPHAN_PLEDGES_CLASSIFICATION' AS result_set,
       source, orphan_class,
       COUNT_BIG(*) AS pledges_rows
FROM (
    SELECT p.c_source AS source,
           CASE
               WHEN p.c_loan_gid IS NULL OR p.c_source IS NULL THEN 'NULL_KEY_CANNOT_JOIN (см. D2)'
               WHEN EXISTS (SELECT 1 FROM #loans_active_keys k WHERE k.l_source = p.c_source AND k.l_gid = p.c_loan_gid)
                   THEN 'FOUND_IN_ACTIVE (не orphan)'
               WHEN EXISTS (SELECT 1 FROM #loans_master_keys m WHERE m.l_source = p.c_source AND m.l_gid = p.c_loan_gid)
                   THEN 'FOUND_IN_LOANS_MASTER_НЕ_ACTIVE (закрыт/неактивен — не аномалия)'
               ELSE 'TRUE_ORPHAN_NOT_FOUND_ANYWHERE'
           END AS orphan_class
    FROM #pledges_slice p
) t
GROUP BY source, orphan_class
ORDER BY source, orphan_class
OPTION (MAXDOP 1);
-- Фикс 06.08.2026: та же схема, что A3/B1 — CASE считается в производной
-- таблице t, GROUP BY снаружи — над материализованным столбцом.


/*==============================================================================
  D2 — pledges-строки, где ключ вообще NULL (не могут участвовать ни в одном
       из join-тестов выше — отдельный явный подсчёт, не растворять в D1)
==============================================================================*/
SELECT @CaseRun AS case_run, 'D2_NULL_JOIN_KEY_IN_PLEDGES' AS result_set,
       COALESCE(c_source, N'(NULL source)') AS source,
       SUM(CASE WHEN c_loan_gid IS NULL THEN 1 ELSE 0 END) AS null_loan_gid_rows,
       SUM(CASE WHEN c_source IS NULL THEN 1 ELSE 0 END) AS null_source_rows,
       COUNT_BIG(*) AS rows_in_group
FROM #pledges_slice
WHERE c_loan_gid IS NULL OR c_source IS NULL
GROUP BY COALESCE(c_source, N'(NULL source)')
OPTION (MAXDOP 1);

DROP TABLE #loans_master_keys;
DROP TABLE #pledges_slice;
DROP TABLE #loans_active_keys;
