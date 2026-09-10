/* ============================================================================
   Проверка правил сегментации на 2024 Q4 против оригинальной сегментации AQR.

   ЗАЧЕМ
   ---------------------------------------------------------------------------
   2024 Q4 — единственный период, где есть эталон АФР (RA_NST_segment_AQR2025,
   колонка segment_afr). Прогон тех же правил, которыми считается 2025 год,
   на периоде с эталоном показывает, сколько правила ошибаются — и где именно.
   Без этого точность сегментации 2025 года ничем не подтверждена.

   ЧТО СЧИТАТЬ ЭТАЛОНОМ
   ---------------------------------------------------------------------------
   Эталон — файл АФР `EUB_SEGMENTS` (лист с колонками LOAN_ID, LOAN_ID_KR, ID,
   CREDIT_LINE_ID, SEGMENT), а не какая-либо его копия в базе. Копия могла быть
   загружена частично или по другому ключу, поэтому вывод 0 сверяет таблицу
   в базе с распределением самого файла. Пока вывод 0 не сошёлся, остальные
   выводы читать нельзя.

   Профиль файла, снятый 09.09.2026 (729 787 строк):
     RETCON 621 462 · RETCAR 103 401 · RETSML 2 227 · CORMED 1 249
     RETEST    794  · CORLAR    605  · COREST    49
   Ключ LOAN_ID_KR уникален полностью: 729 787 значений, дублей и пустых нет.

   КЛЮЧ СОЕДИНЕНИЯ — ТОЛЬКО LOAN_ID_KR.
   Колонки идентификатора не взаимозаменяемы: LOAN_ID расходится с LOAN_ID_KR
   в 225 328 строках (30,9 %), ID — в 222 620. Ключ строковый, 729 325 значений
   нечисловые, длины двух семейств: 13 знаков (501 155) и 20 знаков (222 822).
   Приводить обе стороны к одному типу и не обрезать ведущие нули.

   ЗАГРУЗКА ЭТАЛОНА
   ---------------------------------------------------------------------------
   Файл приходит зашифрованным, openpyxl его не открывает. Распаковка —
   afr_seg_load.py в этой же папке; он же печатает профиль для сверки с выводом 0.

   ПОЧЕМУ СРАВНЕНИЕ ЧЕСТНОЕ
   ---------------------------------------------------------------------------
   В эталоне ровно семь значений сегмента, и среди них нет ни Individual loans,
   ни RELATE, ни DISASS, ни CORINV. Это не наша интерпретация Таблицы 3,
   а свойство файла — решение Р1 подтверждено на оригинале. Наш сегмент тоже
   несёт только продукт, признаки идут флагами и в сравнении не участвуют.

   ПОРЯДОК ВЫВОДА (§ 4: сначала агрегат, потом детализация)
   ---------------------------------------------------------------------------
     1. Общая точность — по договорам и по EAD
     2. Матрица ошибок: наш сегмент x эталон
     3. Полнота по каждому сегменту эталона (сколько его договоров мы нашли)
     4. Точность по каждому нашему сегменту (сколько наших верны)
     5. Куда утекает EAD: пары «наш -> эталон» по убыванию расхождения
     6. Флаги против эталона: попадают ли помеченные нами в отдельные сегменты
     7. Контроли покрытия

   Read-only: только SELECT. Один #temp с префиксом файла. MAXDOP 1.
   PII не выводится: агрегаты, худшие случаи — бакетами, не именами.
   ========================================================================= */

SET NOCOUNT ON;

/* ---------------------------------------------------------------------------
   ПАРАМЕТРЫ.
   Капитал 461 235 157 000 — это БАЛАНСОВЫЙ капитал на 01.01.2025. В прогоне
   за 2025 год порог считается от РЕГУЛЯТОРНОГО (503 086 114 000). База порога
   между периодами перевёрнута; вопрос вынесен отдельно и здесь не решается —
   значение оставлено таким, каким считался период эталона, иначе сравнение
   перестанет быть сравнением.
   ------------------------------------------------------------------------ */
DECLARE @capital  float = 461235157000;   -- балансовый СК на 01.01.2025
DECLARE @thr_ind  float = 0.002;
DECLARE @thr_ead  float = 200000000;      -- Р4

IF OBJECT_ID('tempdb..#seg24_cmp') IS NOT NULL DROP TABLE #seg24_cmp;


/* ============================================================================
   ВЫВОД 0. ТОТ ЛИ ЭТАЛОН В БАЗЕ.
   Сверка таблицы эталона с распределением файла АФР. Расхождение хотя бы
   в одной строке означает, что таблица — не оригинал: либо загружена частью,
   либо по другому ключу, либо это наша прежняя реконструкция. В этом случае
   остальные выводы измеряют не то, и загружать эталон надо заново
   (afr_seg_load.py, затем BULK INSERT).
   ========================================================================= */
WITH afr_file(segment, contracts) AS (
    SELECT v.segment, v.contracts
    FROM (VALUES
          ('RETCON', 621462)
        , ('RETCAR', 103401)
        , ('RETSML',   2227)
        , ('CORMED',   1249)
        , ('RETEST',    794)
        , ('CORLAR',    605)
        , ('COREST',     49)
    ) AS v(segment, contracts)
),
afr_db AS (
    SELECT segment_afr AS segment, COUNT(*) AS contracts
    FROM [personal_tables].[dbo].[RA_NST_segment_AQR2025]
    GROUP BY segment_afr
)
SELECT
      COALESCE(f.segment, d.segment)                                  AS segment
    , f.contracts                                                     AS in_afr_file
    , d.contracts                                                     AS in_db_table
    , COALESCE(d.contracts, 0) - COALESCE(f.contracts, 0)             AS diff
    , CASE
        WHEN f.segment IS NULL THEN 'значения нет в файле АФР'
        WHEN d.segment IS NULL THEN 'значения нет в таблице базы'
        WHEN d.contracts = f.contracts THEN 'сошлось'
        ELSE 'расхождение'
      END                                                             AS verdict
FROM      afr_file f
FULL JOIN afr_db   d ON d.segment = f.segment
ORDER BY COALESCE(f.contracts, d.contracts) DESC;

-- контроль объёма и ключа: в файле 729 787 строк и столько же уникальных ключей
SELECT
      COUNT(*)                        AS rows_in_db_table
    , COUNT(DISTINCT loan_id_kr)      AS distinct_keys
    , 729787                          AS rows_in_afr_file
    , COUNT(*) - 729787               AS diff_rows
FROM [personal_tables].[dbo].[RA_NST_segment_AQR2025];

/* ============================================================================
   База: договоры 2024 Q4 + эталон АФР по ключу договора
   ========================================================================= */
WITH src AS (
    SELECT
          b.loan_id_kr
        , b.iin_bin
        , b.entity
        , b.lsboo
        , s.segment_afr                                               AS afr
        , COALESCE(TRY_CAST(b.ead AS float), 0)                       AS ead_n
        , COALESCE(TRY_CAST(b.od           AS float), 0)
        + COALESCE(TRY_CAST(b.od_del       AS float), 0)
        + COALESCE(TRY_CAST(b.interest     AS float), 0)
        + COALESCE(TRY_CAST(b.interest_del AS float), 0)
        + COALESCE(TRY_CAST(b.correction   AS float), 0)
        + COALESCE(TRY_CAST(b.disc_prem    AS float), 0)
        + COALESCE(TRY_CAST(b.penalty      AS float), 0)              AS zadol
        , TRY_CAST(b.debtor_type AS int)                              AS debtor_type_n
        , TRY_CAST(b.debtor_se   AS int)                              AS debtor_se_n
        , TRY_CAST(b.ent_type    AS int)                              AS ent_type_n
        , TRY_CAST(b.loan_obj    AS int)                              AS loan_obj_n
        , TRY_CAST(b.f_inv       AS int)                              AS f_inv_n
        , CASE WHEN a.bin IS NOT NULL THEN 1 ELSE 0 END               AS in_b2a
    FROM       [CL_PORTFOLIO].[dbo].[AQR2025_B1A_2024_Q4]             AS b
    LEFT JOIN  [personal_tables].[dbo].[RA_NST_segment_AQR2025]       AS s
           ON  s.loan_id_kr = b.loan_id_kr
    LEFT JOIN  [personal_tables].[dbo].[RA_NST_B2A_AQR2025_11082025]  AS a
           ON  a.bin = b.iin_bin
    WHERE b.is_del = '0'
),
agg AS (
    SELECT
          loan_id_kr, iin_bin, entity, lsboo, afr, ead_n, zadol
        , debtor_type_n, debtor_se_n, ent_type_n, loan_obj_n, f_inv_n, in_b2a
        , SUM(zadol) OVER (PARTITION BY iin_bin)                      AS zadol_borrower
    FROM src
)
SELECT
      loan_id_kr
    , iin_bin
    , afr
    , ead_n
    /* ---- те же правила, что и в прогоне за 2025 год -------------------- */
    , CASE
        WHEN COALESCE(debtor_type_n, 0) = 0 AND COALESCE(debtor_se_n, 0) = 0
             AND ead_n <= @thr_ead
          THEN CASE loan_obj_n
                 WHEN 1 THEN 'RETEST'
                 WHEN 6 THEN 'RETCAR'
                 ELSE        'RETCON'
               END
        WHEN loan_obj_n IN (1, 2, 3)                         THEN 'COREST'
        WHEN ent_type_n = 1                                  THEN 'CORLAR'
        WHEN ent_type_n = 2                                  THEN 'CORMED'
        WHEN ent_type_n = 3                                  THEN 'RETSML'
        ELSE 'X'
      END                                                    AS ours
    , CASE WHEN entity = 'EUB1'          THEN 1 ELSE 0 END   AS flag_disass
    , CASE WHEN lsboo  = 1               THEN 1 ELSE 0 END   AS flag_relate
    , CASE WHEN COALESCE(f_inv_n, 0) = 1 THEN 1 ELSE 0 END   AS flag_corinv
    , CASE WHEN in_b2a = 1
             OR zadol_borrower > @capital * @thr_ind
           THEN 1 ELSE 0 END                                 AS flag_individual
    , CASE WHEN in_b2a = 1 THEN 1 ELSE 0 END                 AS ind_by_list
    , CASE WHEN zadol_borrower > @capital * @thr_ind
           THEN 1 ELSE 0 END                                 AS ind_by_threshold
INTO #seg24_cmp
FROM agg
OPTION (MAXDOP 1);


/* ============================================================================
   ВЫВОД 1. Общая точность. Договоры без эталона исключены из знаменателя —
            они не «ошибка», а отсутствие сравнения (см. вывод 7).
   ========================================================================= */
SELECT
      COUNT(*)                                                        AS contracts_compared
    , SUM(CASE WHEN ours = afr THEN 1 ELSE 0 END)                     AS matched
    , CAST(100.0 * SUM(CASE WHEN ours = afr THEN 1 ELSE 0 END)
           / NULLIF(COUNT(*), 0) AS decimal(6,2))                     AS accuracy_by_count
    , SUM(ead_n)                                                      AS ead_compared
    , SUM(CASE WHEN ours = afr THEN ead_n ELSE 0 END)                 AS ead_matched
    , CAST(100.0 * SUM(CASE WHEN ours = afr THEN ead_n ELSE 0 END)
           / NULLIF(SUM(ead_n), 0) AS decimal(6,2))                   AS accuracy_by_ead
FROM #seg24_cmp
WHERE afr IS NOT NULL;

/* ============================================================================
   ВЫВОД 2. Матрица ошибок: строки — наш сегмент, столбцы — эталон
   ========================================================================= */
SELECT
      ours
    , afr
    , COUNT(*)                                               AS contracts
    , SUM(ead_n)                                             AS ead_total
    , CASE WHEN ours = afr THEN 'совпало' ELSE 'расхождение' END AS verdict
FROM #seg24_cmp
WHERE afr IS NOT NULL
GROUP BY ours, afr
ORDER BY CASE WHEN ours = afr THEN 1 ELSE 0 END, ead_total DESC;

/* ============================================================================
   ВЫВОД 3. Полнота по сегментам эталона: какую долю каждого сегмента АФР
            наши правила находят
   ========================================================================= */
SELECT
      afr                                                             AS afr_segment
    , COUNT(*)                                                        AS afr_contracts
    , SUM(CASE WHEN ours = afr THEN 1 ELSE 0 END)                     AS found
    , CAST(100.0 * SUM(CASE WHEN ours = afr THEN 1 ELSE 0 END)
           / NULLIF(COUNT(*), 0) AS decimal(6,2))                     AS recall_by_count
    , SUM(ead_n)                                                      AS afr_ead
    , CAST(100.0 * SUM(CASE WHEN ours = afr THEN ead_n ELSE 0 END)
           / NULLIF(SUM(ead_n), 0) AS decimal(6,2))                   AS recall_by_ead
FROM #seg24_cmp
WHERE afr IS NOT NULL
GROUP BY afr
ORDER BY afr_ead DESC;

/* ============================================================================
   ВЫВОД 4. Точность по нашим сегментам: какая доля того, что мы отнесли
            в сегмент, действительно ему принадлежит
   ========================================================================= */
SELECT
      ours                                                            AS our_segment
    , COUNT(*)                                                        AS our_contracts
    , SUM(CASE WHEN ours = afr THEN 1 ELSE 0 END)                     AS correct
    , CAST(100.0 * SUM(CASE WHEN ours = afr THEN 1 ELSE 0 END)
           / NULLIF(COUNT(*), 0) AS decimal(6,2))                     AS precision_by_count
    , SUM(ead_n)                                                      AS our_ead
    , CAST(100.0 * SUM(CASE WHEN ours = afr THEN ead_n ELSE 0 END)
           / NULLIF(SUM(ead_n), 0) AS decimal(6,2))                   AS precision_by_ead
FROM #seg24_cmp
WHERE afr IS NOT NULL
GROUP BY ours
ORDER BY our_ead DESC;

/* ============================================================================
   ВЫВОД 5. Куда утекает EAD: двадцать худших пар расхождения
   ========================================================================= */
SELECT TOP 20
      ours                                                            AS our_segment
    , afr                                                             AS afr_segment
    , COUNT(*)                                                        AS contracts
    , SUM(ead_n)                                                      AS ead_total
    , CAST(100.0 * SUM(ead_n) / NULLIF(SUM(SUM(ead_n)) OVER (), 0) AS decimal(6,2)) AS pct_of_mismatch_ead
FROM #seg24_cmp
WHERE afr IS NOT NULL AND ours <> afr
GROUP BY ours, afr
ORDER BY ead_total DESC;

/* ============================================================================
   ВЫВОД 6. Проверка Р1 на данных с эталоном.
            Если бы признаки были значениями сегмента, эти договоры ушли бы
            из продуктовых сегментов. Здесь видно, куда их относит АФР.
   ========================================================================= */
SELECT
      'flag_individual' AS flag, afr AS afr_segment
    , COUNT(*) AS contracts, SUM(ead_n) AS ead_total
    , CAST(100.0 * SUM(CASE WHEN ours = afr THEN 1 ELSE 0 END)
           / NULLIF(COUNT(*), 0) AS decimal(6,2)) AS our_accuracy
FROM #seg24_cmp WHERE flag_individual = 1 AND afr IS NOT NULL GROUP BY afr
UNION ALL
SELECT 'flag_relate', afr, COUNT(*), SUM(ead_n)
    , CAST(100.0 * SUM(CASE WHEN ours = afr THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0) AS decimal(6,2))
FROM #seg24_cmp WHERE flag_relate = 1 AND afr IS NOT NULL GROUP BY afr
UNION ALL
SELECT 'flag_disass', afr, COUNT(*), SUM(ead_n)
    , CAST(100.0 * SUM(CASE WHEN ours = afr THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0) AS decimal(6,2))
FROM #seg24_cmp WHERE flag_disass = 1 AND afr IS NOT NULL GROUP BY afr
ORDER BY flag, ead_total DESC;

/* ============================================================================
   ВЫВОД 7. Контроли покрытия — без них точность выше 1 читается неверно
   ========================================================================= */
SELECT 'договоров всего'                     AS control, COUNT(*) AS n, SUM(ead_n) AS ead FROM #seg24_cmp
UNION ALL
SELECT 'из них с эталоном',                  COUNT(*), SUM(ead_n) FROM #seg24_cmp WHERE afr IS NOT NULL
UNION ALL
SELECT 'БЕЗ эталона — вне сравнения',        COUNT(*), SUM(ead_n) FROM #seg24_cmp WHERE afr IS NULL
UNION ALL
SELECT 'наш сегмент не распознан (X)',       COUNT(*), SUM(ead_n) FROM #seg24_cmp WHERE ours = 'X'
UNION ALL
SELECT 'значений сегмента у эталона',        COUNT(DISTINCT afr), NULL FROM #seg24_cmp WHERE afr IS NOT NULL
UNION ALL
SELECT 'дубли ключа loan_id_kr',             COUNT(*), NULL
FROM (SELECT loan_id_kr FROM #seg24_cmp GROUP BY loan_id_kr HAVING COUNT(*) > 1) d;

/* ============================================================================
   ВЫВОД 8. Список значений эталона — контроль Р1.
            Если здесь появятся Individual loans / RELATE / DISASS, вывод 3я.1
            контура придётся пересматривать.
   ========================================================================= */
SELECT afr AS afr_segment_value, COUNT(*) AS contracts, SUM(ead_n) AS ead_total
FROM #seg24_cmp
WHERE afr IS NOT NULL
GROUP BY afr
ORDER BY contracts DESC;

DROP TABLE #seg24_cmp;
