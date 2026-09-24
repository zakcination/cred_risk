/* =============================================================================
   TREE_0 — разведка перед деревом разметки: можно ли перенести утверждённый
            АФР сегмент на витрину, и по какому ключу.

   План процедуры — portfolio_report/SEGMENT_TREE_PLAN.md. Этот скрипт — шаг 0:
   §6 корневого CLAUDE.md разрешает разведочный прогон (ключ, покрытие, домен)
   до согласования структуры. Дерево здесь НЕ обучается.

   ЧТО ИЗМЕРЯЕМ. Покрытие связи «метка АФР → договор витрины» по каждому
   кандидату ключа и по каждому источнику отдельно; состав сегментов у нашедших
   и не нашедших пару; происхождение l_segment.

   ЗАЧЕМ. Цепочка _ot_AFR.LOAN_ID_KR → AQR2025_B1A_2024_Q4 доказана (Д5–Д7,
   1:1), но звено «→ витрина» не проверялось ни разу: ни один исполнявшийся
   скрипт nst_credit не соединял метки с Dictionaries.

   ЧТО СЧИТАЕТСЯ ИСХОДОМ.
     блок 1 — КОНТРОЛЬ С ИЗВЕСТНЫМ ОТВЕТОМ (Н22 nst_credit). В _ot_AFR 729 787
              строк, LOAN_ID_KR уникален. Другое число — временная таблица
              собрана неверно, дальше не читать.
     блок 2 — РЕШАЮЩИЙ. Ключ, давший наибольшее покрытие на источнике, и есть
              ключ связи для этого источника. Ожидание по cl_registry/links.csv:
              S01 — через l_loan_id, S02 и S03 — через l_loan_number. Покрытие
              ниже половины на источнике — дерево для него не строится.
              pairs > matched_keys — один ключ нашёл несколько договоров:
              номер неуникален, и связь для этого источника требует l_source.
     блок 3 — связь корпоратива по заёмщику. Для CORLAR/CORMED/RETSML/COREST
              единица — заёмщик (Н19), и естественный ключ — ИИН/БИН.
     блок 4 — представительность. Сегмент, у которого доля нашедших пару
              заметно ниже прочих, дерево выучит хуже — и это будет выглядеть
              свойством витрины, а не дырой в связи.
     блок 5 — происхождение l_segment (Н13а, О16 nst_credit). Если домен
              segment_eub — это РБ/МБ/КБ/ПБ, то l_segment витрины и segment_eub —
              одна классификация, и автор решает, брать ли её признаком (Д-5).

   ЛОВУШКИ, ЗАЛОЖЕННЫЕ В СКРИПТ.
     — ключи приводятся к строке и обрезаются; поле, хранимое как float, даёт
       '1.23e+012' и молча не совпадает ни с чем. Блок 1 считает такие значения;
     — ИИН/БИН сравниваются дополненными до 12 знаков нулями слева: потеря
       ведущего нуля — ровно дефект ТР20;
     — COLLATE DATABASE_DEFAULT: соединение идёт между базами CL_PORTFOLIO
       и Dictionaries, умолчания сортировки у них могут различаться;
     — ID в _ot_AFR уникален и может оказаться номером строки файла АФР.
       Тогда его совпадения с витриной — случайные. Блок 1 показывает длину
       и числовость каждого ключа: сплошь короткие числа — это не ключ.

   GO между блоками: одно неверное имя стоит одного блока (урок RPT_D).
   Временные таблицы #tree0_* переживают GO — они живут до конца сессии.

   Read-only. PII не выводится: только агрегаты. ИИН/БИН участвуют только
   в соединении.
   ============================================================================= */
SET NOCOUNT ON;
GO

/* ─────────────────────────────────────────────────────────────────────────
   0. ЖИВОЙ АУДИТ ИМЁН. Колонки-идентификаторы трёх таблиц.
      Если имени, на которое ссылается блок, здесь нет, — блок не выполнять.
   ───────────────────────────────────────────────────────────────────────── */
SELECT    c.TABLE_NAME
        , c.COLUMN_NAME
        , c.DATA_TYPE
        , c.CHARACTER_MAXIMUM_LENGTH
FROM      [CL_PORTFOLIO].[INFORMATION_SCHEMA].[COLUMNS] AS c
WHERE     c.TABLE_NAME IN (N'RA_NST_segment_AQR2025_ot_AFR', N'AQR2025_B1A_2024_Q4')
      AND (   c.COLUMN_NAME LIKE '%id%'     OR c.COLUMN_NAME LIKE '%iin%'
           OR c.COLUMN_NAME LIKE '%num%'    OR c.COLUMN_NAME LIKE '%dog%'
           OR c.COLUMN_NAME LIKE '%contract%' OR c.COLUMN_NAME LIKE '%source%'
           OR c.COLUMN_NAME LIKE '%segment%' OR c.COLUMN_NAME = 'is_del')
ORDER BY  c.TABLE_NAME, c.COLUMN_NAME;

SELECT    c.COLUMN_NAME
        , c.DATA_TYPE
        , c.CHARACTER_MAXIMUM_LENGTH
FROM      [Dictionaries].[INFORMATION_SCHEMA].[COLUMNS] AS c
WHERE     c.TABLE_SCHEMA = 'risk_analytics'
      AND c.TABLE_NAME   = N'borrower'
      AND (   c.COLUMN_NAME LIKE '%iin%' OR c.COLUMN_NAME LIKE '%bin%'
           OR c.COLUMN_NAME LIKE '%borrower_id%' OR c.COLUMN_NAME LIKE '%source%')
ORDER BY  c.COLUMN_NAME;
GO

/* ─────────────────────────────────────────────────────────────────────────
   1. Метки и КОНТРОЛЬ С ИЗВЕСТНЫМ ОТВЕТОМ.
      Имена LOAN_ID_KR, LOAN_ID, ID, SEGMENT — живой аудит NST_CREDIT.md §3я.0.
   ───────────────────────────────────────────────────────────────────────── */
IF OBJECT_ID('tempdb..#tree0_lab') IS NOT NULL DROP TABLE #tree0_lab;

SELECT    LTRIM(RTRIM(CONVERT(nvarchar(255), s.LOAN_ID_KR))) COLLATE DATABASE_DEFAULT AS k_kr
        , LTRIM(RTRIM(CONVERT(nvarchar(255), s.LOAN_ID)))    COLLATE DATABASE_DEFAULT AS k_loan_id
        , LTRIM(RTRIM(CONVERT(nvarchar(255), s.ID)))         COLLATE DATABASE_DEFAULT AS k_id
        , s.SEGMENT
INTO      #tree0_lab
FROM      [CL_PORTFOLIO].[dbo].[RA_NST_segment_AQR2025_ot_AFR] AS s;

/* 1а. Контроль: ожидается 729 787 строк и 729 787 уникальных k_kr. */
SELECT    COUNT_BIG(*)              AS lab_rows
        , COUNT(DISTINCT k_kr)      AS uq_kr
        , COUNT(DISTINCT k_loan_id) AS uq_loan_id
        , COUNT(DISTINCT k_id)      AS uq_id
FROM      #tree0_lab;

/* 1б. Профиль ключей: длина, числовость, следы float.
       Сплошь короткие числа у ID — номер строки файла, а не ключ. */
SELECT    c.key_name
        , MIN(LEN(c.k))                                                          AS len_min
        , MAX(LEN(c.k))                                                          AS len_max
        , SUM(CASE WHEN TRY_CONVERT(decimal(38,0), c.k) IS NOT NULL THEN 1 ELSE 0 END) AS numeric_cnt
        , SUM(CASE WHEN c.k LIKE '%e+%' OR c.k LIKE '%E+%' THEN 1 ELSE 0 END)   AS float_trace_cnt
        , SUM(CASE WHEN c.k IS NULL OR c.k = N'' THEN 1 ELSE 0 END)             AS empty_cnt
FROM      #tree0_lab AS t
CROSS APPLY (VALUES (N'LOAN_ID_KR', t.k_kr), (N'LOAN_ID', t.k_loan_id), (N'ID', t.k_id)) AS c(key_name, k)
GROUP BY  c.key_name
ORDER BY  c.key_name;

/* 1в. Состав меток — список классов для дерева. */
SELECT    t.SEGMENT
        , COUNT_BIG(*) AS lab_rows
FROM      #tree0_lab AS t
GROUP BY  t.SEGMENT
ORDER BY  lab_rows DESC;
GO

/* ─────────────────────────────────────────────────────────────────────────
   2. РЕШАЮЩИЙ. Покрытие связи: 3 ключа меток × 2 ключа витрины × источник.
      Совпадения материализуются в #tree0_hit — блок 4 их переиспользует.
   ───────────────────────────────────────────────────────────────────────── */
IF OBJECT_ID('tempdb..#tree0_hit') IS NOT NULL DROP TABLE #tree0_hit;

SELECT    c.key_name
        , N'l_loan_id'      AS mart_key
        , c.k
        , l.l_source
        , COUNT_BIG(*)      AS n_mart
INTO      #tree0_hit
FROM      #tree0_lab AS t
CROSS APPLY (VALUES (N'LOAN_ID_KR', t.k_kr), (N'LOAN_ID', t.k_loan_id), (N'ID', t.k_id)) AS c(key_name, k)
JOIN      [Dictionaries].[risk_analytics].[loans] AS l
       ON LTRIM(RTRIM(l.l_loan_id)) COLLATE DATABASE_DEFAULT = c.k
WHERE     c.k IS NOT NULL AND c.k <> N''
GROUP BY  c.key_name, c.k, l.l_source
OPTION (MAXDOP 1);

INSERT INTO #tree0_hit (key_name, mart_key, k, l_source, n_mart)
SELECT    c.key_name
        , N'l_loan_number'
        , c.k
        , l.l_source
        , COUNT_BIG(*)
FROM      #tree0_lab AS t
CROSS APPLY (VALUES (N'LOAN_ID_KR', t.k_kr), (N'LOAN_ID', t.k_loan_id), (N'ID', t.k_id)) AS c(key_name, k)
JOIN      [Dictionaries].[risk_analytics].[loans] AS l
       ON LTRIM(RTRIM(l.l_loan_number)) COLLATE DATABASE_DEFAULT = c.k
WHERE     c.k IS NOT NULL AND c.k <> N''
GROUP BY  c.key_name, c.k, l.l_source
OPTION (MAXDOP 1);

/* 2а. Покрытие. matched_keys из 729 787 — доля меток, нашедших договор.
       multi_keys — ключ нашёл больше одного договора в источнике. */
SELECT    h.l_source
        , h.key_name
        , h.mart_key
        , COUNT_BIG(*)                                            AS matched_keys
        , SUM(h.n_mart)                                           AS pairs
        , SUM(CASE WHEN h.n_mart > 1 THEN 1 ELSE 0 END)           AS multi_keys
FROM      #tree0_hit AS h
GROUP BY  h.l_source, h.key_name, h.mart_key
ORDER BY  h.l_source, matched_keys DESC;

/* 2б. Один ключ метки — в нескольких источниках сразу.
       Не ноль — номер неуникален между системами (у l_gid таких 9 659),
       и связь без l_source даёт ложные пары. */
SELECT    x.key_name
        , x.mart_key
        , x.sources
        , COUNT_BIG(*) AS keys
FROM      ( SELECT h.key_name, h.mart_key, h.k, COUNT(DISTINCT h.l_source) AS sources
            FROM   #tree0_hit AS h
            GROUP BY h.key_name, h.mart_key, h.k ) AS x
GROUP BY  x.key_name, x.mart_key, x.sources
ORDER BY  x.key_name, x.mart_key, x.sources;
GO

/* ─────────────────────────────────────────────────────────────────────────
   3. Корпоратив: связь по заёмщику через ИИН/БИН.
      Имена b.iin_bin, b.loan_id_kr, b.is_del — из исполнявшихся скриптов
      nst_credit. Имя br.b_iin_bin — ПРОВЕРИТЬ по блоку 0; нет — блок пропустить.
      Оба конца дополняются нулями слева до 12 знаков: потеря ведущего нуля —
      дефект ТР20, и без этого совпадение занижается молча.
   ───────────────────────────────────────────────────────────────────────── */
;WITH corp AS (
    SELECT DISTINCT
           RIGHT(N'000000000000' + LTRIM(RTRIM(CONVERT(nvarchar(20), b.iin_bin))), 12)
               COLLATE DATABASE_DEFAULT AS iin
         , t.SEGMENT
    FROM   #tree0_lab AS t
    JOIN   [CL_PORTFOLIO].[dbo].[AQR2025_B1A_2024_Q4] AS b
           ON LTRIM(RTRIM(CONVERT(nvarchar(255), b.loan_id_kr))) COLLATE DATABASE_DEFAULT = t.k_kr
          AND b.is_del = '0'
    WHERE  t.SEGMENT IN (N'CORLAR', N'CORMED', N'RETSML', N'COREST')
), mart AS (
    SELECT DISTINCT
           RIGHT(N'000000000000' + LTRIM(RTRIM(CONVERT(nvarchar(20), br.b_iin_bin))), 12)
               COLLATE DATABASE_DEFAULT AS iin
    FROM   [Dictionaries].[risk_analytics].[borrower] AS br
    WHERE  br.b_iin_bin IS NOT NULL
)
SELECT    c.SEGMENT
        , COUNT_BIG(*)                                         AS b1a_borrowers
        , SUM(CASE WHEN m.iin IS NOT NULL THEN 1 ELSE 0 END)   AS found_in_mart
FROM      corp AS c
LEFT JOIN mart AS m ON m.iin = c.iin
GROUP BY  c.SEGMENT
ORDER BY  b1a_borrowers DESC
OPTION (MAXDOP 1);
GO

/* ─────────────────────────────────────────────────────────────────────────
   4. Представительность: доля нашедших пару — по сегментам и по каждому
      ключу меток (к любому из двух ключей витрины).
      Сегмент с долей заметно ниже прочих дерево выучит хуже.
   ───────────────────────────────────────────────────────────────────────── */
;WITH hit_kr  AS (SELECT DISTINCT k FROM #tree0_hit WHERE key_name = N'LOAN_ID_KR')
    , hit_lid AS (SELECT DISTINCT k FROM #tree0_hit WHERE key_name = N'LOAN_ID')
    , hit_id  AS (SELECT DISTINCT k FROM #tree0_hit WHERE key_name = N'ID')
SELECT    t.SEGMENT
        , COUNT_BIG(*)                                              AS lab_rows
        , SUM(CASE WHEN a.k IS NOT NULL THEN 1 ELSE 0 END)          AS matched_by_kr
        , SUM(CASE WHEN b.k IS NOT NULL THEN 1 ELSE 0 END)          AS matched_by_loan_id
        , SUM(CASE WHEN c.k IS NOT NULL THEN 1 ELSE 0 END)          AS matched_by_id
FROM      #tree0_lab AS t
LEFT JOIN hit_kr  AS a ON a.k = t.k_kr
LEFT JOIN hit_lid AS b ON b.k = t.k_loan_id
LEFT JOIN hit_id  AS c ON c.k = t.k_id
GROUP BY  t.SEGMENT
ORDER BY  lab_rows DESC;
GO

/* ─────────────────────────────────────────────────────────────────────────
   5. Происхождение l_segment (Н13а, О16 nst_credit): домен segment_eub.
      РБ / МБ / КБ / ПБ — та же классификация, что l_segment витрины.
      Не читать как эталон: segment_eub — внутренняя разметка банка.
   ───────────────────────────────────────────────────────────────────────── */
SELECT    p.segment_eub
        , COUNT_BIG(*) AS rows_cnt
FROM      [personal_tables].[dbo].[RA_NST_segment_AQR2025] AS p
GROUP BY  p.segment_eub
ORDER BY  rows_cnt DESC;
GO

IF OBJECT_ID('tempdb..#tree0_hit') IS NOT NULL DROP TABLE #tree0_hit;
IF OBJECT_ID('tempdb..#tree0_lab') IS NOT NULL DROP TABLE #tree0_lab;
GO
