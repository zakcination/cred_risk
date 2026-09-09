/* ============================================================================
   Проверка правил сегментации на 2024 Q4 против оригинальной сегментации AQR.

   ЗАЧЕМ
   ---------------------------------------------------------------------------
   2024 Q4 — единственный период, где есть эталон АФР (RA_NST_segment_AQR2025,
   колонка segment_afr). Прогон тех же правил, которыми считается 2025 год,
   на периоде с эталоном показывает, сколько правила ошибаются — и где именно.
   Без этого точность сегментации 2025 года ничем не подтверждена.

   ВАЖНО ПРО СРАВНЕНИЕ
   ---------------------------------------------------------------------------
   Эталон АФР не содержит значений Individual loans / RELATE / DISASS / CORINV
   вовсе — Таблица 3 требует распределять такие займы по продуктовым портфелям.
   Поэтому сравнение честное: наш сегмент тоже несёт только продукт (Р1),
   а признаки идут флагами и в сравнении сегментов не участвуют.

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
