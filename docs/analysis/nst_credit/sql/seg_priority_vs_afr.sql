/* ============================================================================
   Есть ли у АФР приоритет между RELATE и «индивидуальными» — проверка на 2024.

   ВОПРОС
   ---------------------------------------------------------------------------
   В прежних правилах RELATE стоял выше индивидуальных займов: договор, у которого
   lsboo = 1 и заёмщик в перечне, получал сегмент RELATE. Вопрос — как расставляет
   приоритет АФР.

   ПРЕДПОСЫЛКА ВОПРОСА НЕ ПОДТВЕРЖДАЕТСЯ
   ---------------------------------------------------------------------------
   В эталоне АФР ровно семь значений сегмента: RETCON, RETCAR, RETSML, CORMED,
   RETEST, CORLAR, COREST. Ни Individual loans, ни RELATE в нём нет ни одной
   строкой из 729 787. Приоритета между ними у АФР не существует, потому что
   в сегмент не попадает ни то, ни другое.

   Пообъектно это уже видно: договоры F06/73…76-КБ/2016/SO/1 помечены у нас
   как «B2A+порог» — заёмщик и в перечне, и выше порога, — а АФР относит их
   в RETSML, малый бизнес.

   ЧТО ТОГДА ПРОВЕРЯЕТ ЭТОТ СКРИПТ
   ---------------------------------------------------------------------------
   Не приоритет, а более сильное утверждение: ВЛИЯЮТ ли признаки на сегмент АФР
   вообще. Договоры делятся на четыре группы по паре признаков, и для каждой
   строится распределение сегментов эталона. Если распределение внутри группы
   повторяет портфельное — признак на классификацию не влияет, и переносить его
   в колонку сегмента нечем обосновать. Если отличается — отличие надо объяснить,
   и вот тогда разговор о приоритете имеет смысл.

   Read-only: только SELECT. Один #temp с префиксом файла. MAXDOP 1.
   § 2: агрегаты; в детализации только номер договора, без реквизитов заёмщика.
   ========================================================================= */

SET NOCOUNT ON;

DECLARE @capital  float = 461235157000;   -- балансовый СК на 01.01.2025 (период эталона)
DECLARE @thr_ind  float = 0.002;

IF OBJECT_ID('tempdb..#segpri') IS NOT NULL DROP TABLE #segpri;

WITH src AS (
    SELECT
          b.loan_id_kr
        , b.iin_bin
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
          loan_id_kr, iin_bin, lsboo, afr, ead_n, zadol, in_b2a
        , SUM(zadol) OVER (PARTITION BY iin_bin)                      AS zadol_borrower
    FROM src
)
SELECT
      loan_id_kr
    , iin_bin
    , afr
    , ead_n
    , CASE WHEN lsboo = 1 THEN 1 ELSE 0 END                           AS is_relate
    , CASE WHEN in_b2a = 1 OR zadol_borrower > @capital * @thr_ind
           THEN 1 ELSE 0 END                                          AS is_individual
    , CASE
        WHEN lsboo = 1 AND (in_b2a = 1 OR zadol_borrower > @capital * @thr_ind)
                                                                 THEN 'оба признака'
        WHEN lsboo = 1                                           THEN 'только RELATE'
        WHEN in_b2a = 1 OR zadol_borrower > @capital * @thr_ind  THEN 'только индивидуальный'
        ELSE                                                          'ни одного'
      END                                                             AS grp
INTO #segpri
FROM agg
OPTION (MAXDOP 1);


/* ============================================================================
   ВЫВОД 1. Размер каждой группы
   ========================================================================= */
SELECT
      grp
    , COUNT(*)                                                        AS contracts
    , COUNT(DISTINCT iin_bin)                                         AS borrowers
    , SUM(ead_n)                                                      AS ead_total
    , SUM(CASE WHEN afr IS NULL THEN 1 ELSE 0 END)                    AS without_afr
FROM #segpri
GROUP BY grp
ORDER BY ead_total DESC;

/* ============================================================================
   ВЫВОД 2. ГЛАВНЫЙ. Распределение сегментов АФР внутри каждой группы против
            портфельного. Колонка delta_pp — насколько доля сегмента в группе
            отличается от его доли во всём портфеле.

            Читается так: если delta_pp близка к нулю по всем строкам группы,
            признак на классификацию АФР не влияет вовсе.
   ========================================================================= */
WITH total AS (
    SELECT afr, 100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS pct_all
    FROM #segpri WHERE afr IS NOT NULL GROUP BY afr
),
bygrp AS (
    SELECT grp, afr, COUNT(*) AS contracts, SUM(ead_n) AS ead_total
         , 100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY grp) AS pct_in_grp
    FROM #segpri WHERE afr IS NOT NULL GROUP BY grp, afr
)
SELECT
      g.grp
    , g.afr                                                           AS afr_segment
    , g.contracts
    , g.ead_total
    , CAST(g.pct_in_grp AS decimal(6,2))                              AS pct_in_group
    , CAST(t.pct_all    AS decimal(6,2))                              AS pct_in_portfolio
    , CAST(g.pct_in_grp - t.pct_all AS decimal(6,2))                  AS delta_pp
FROM      bygrp g
LEFT JOIN total t ON t.afr = g.afr
ORDER BY g.grp, g.ead_total DESC;

/* ============================================================================
   ВЫВОД 3. Группа «оба признака» — та, ради которой задавался вопрос
            о приоритете. Что реально стоит у АФР.
   ========================================================================= */
SELECT
      afr                                                             AS afr_segment
    , COUNT(*)                                                        AS contracts
    , COUNT(DISTINCT iin_bin)                                         AS borrowers
    , SUM(ead_n)                                                      AS ead_total
FROM #segpri
WHERE grp = 'оба признака'
GROUP BY afr
ORDER BY ead_total DESC;

/* ============================================================================
   ВЫВОД 4. Двадцать крупнейших договоров группы «оба признака».
            Прежние правила поставили бы каждому RELATE. Колонка afr_segment
            показывает, что стоит у эталона.
   ========================================================================= */
SELECT TOP 20
      loan_id_kr
    , afr                                                             AS afr_segment
    , 'RELATE'                                                        AS old_rule_would_give
    , ead_n
FROM #segpri
WHERE grp = 'оба признака' AND afr IS NOT NULL
ORDER BY ead_n DESC;

/* ============================================================================
   ВЫВОД 5. Контроль: значений сегмента у эталона по-прежнему семь и среди них
            нет ни RELATE, ни Individual loans. Если появятся — весь вывод
            этого скрипта надо пересматривать.
   ========================================================================= */
SELECT afr AS afr_segment_value, COUNT(*) AS contracts, SUM(ead_n) AS ead_total
FROM #segpri
WHERE afr IS NOT NULL
GROUP BY afr
ORDER BY contracts DESC;

/* ============================================================================
   ВЫВОД 6. Покрытие: сколько договоров каждой группы эталон не содержит вовсе.
            Без этого доли выводов 2 и 3 читаются неверно.
   ========================================================================= */
SELECT
      grp
    , SUM(CASE WHEN afr IS NULL THEN 1 ELSE 0 END)                    AS without_afr
    , SUM(CASE WHEN afr IS NULL THEN ead_n ELSE 0 END)                AS ead_without_afr
    , COUNT(*)                                                        AS contracts_total
    , CAST(100.0 * SUM(CASE WHEN afr IS NULL THEN 1 ELSE 0 END)
           / NULLIF(COUNT(*), 0) AS decimal(6,2))                     AS pct_without_afr
FROM #segpri
GROUP BY grp
ORDER BY without_afr DESC;

DROP TABLE #segpri;
