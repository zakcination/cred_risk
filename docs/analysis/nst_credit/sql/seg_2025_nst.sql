/* ============================================================================
   НСТ: сегментация кредитного портфеля за отчётный 2025 год (на 31.12.2025).

   ЧТО ЗДЕСЬ ГЛАВНОЕ
   ---------------------------------------------------------------------------
   Колонка сегмента несёт ТОЛЬКО продуктовый сегмент Таблицы 4.
   Индивидуальность, связанность, отчуждаемые активы и инвестиционный признак
   в неё не попадают — они идут отдельными колонками-флагами и сосуществуют
   с сегментом. Основание — решение Р1 контура: у эталона АФР значений
   Individual loans / RELATE / DISASS нет вовсе, Таблица 3 требует распределить
   такие займы по продуктовым портфелям.

   Практический смысл: заём индивидуального заёмщика остаётся, например,
   CORLAR и участвует в матрицах перехода своего сегмента, а признак
   индивидуальности доступен отдельно — для ЧПД и для контроля периметра.

   ПОРЯДОК ВЫВОДА (§ 4: сначала агрегат, потом детализация)
   ---------------------------------------------------------------------------
     1. Сводка по сегментам: договоров, задолженность, EAD, доля
     2. Сегмент × стадия
     3. Флаги: сколько договоров и сколько EAD несёт каждый признак
     4. Пересечение сегмента и флага индивидуальности
     5. Контроли: нераспознанные, дубли ключа, расхождение сумм
     6. Строчная выгрузка — последней, для материализации

   Read-only: только SELECT. Один #temp с префиксом файла. MAXDOP 1.
   PII не выводится: агрегаты, в строчной выгрузке — только ключ договора.
   ========================================================================= */

SET NOCOUNT ON;

/* ---------------------------------------------------------------------------
   ПАРАМЕТРЫ. Первый требует решения до прогона.
   ---------------------------------------------------------------------------
   Порог индивидуальности — 0,2 % собственного капитала (Таблица 4). Вопрос
   в том, КАКОГО капитала. В прогоне за 2024 год использован БАЛАНСОВЫЙ
   капитал на 01.01.2025 (461 235 157 000), в прогоне за 2025 — РЕГУЛЯТОРНЫЙ
   на 01.01.2026 (503 086 114 000). База перевернулась между периодами.

     регуляторный на 01.01.2026 : 503 086 114 000  ->  порог 1 006 172 228
     балансовый   на 01.01.2026 : 439 961 267 000  ->  порог   879 922 534

   Разница порога 126 249 694 ₸: на балансовом капитале индивидуальными
   становится БОЛЬШЕ заёмщиков. Значение ниже оставлено прежним (согласовано
   ранее); менять — сознательным решением, а не молча.
   ------------------------------------------------------------------------ */
DECLARE @capital  float = 503086114000;   -- регуляторный СК на 01.01.2026
DECLARE @thr_ind  float = 0.002;          -- 0,2 % СК, Таблица 4
DECLARE @thr_ead  float = 200000000;      -- Р4: порог розницы 200 млн сохранён.
                                          -- На этих данных розничных договоров
                                          -- свыше 200 млн нет, условие ничего
                                          -- не меняет; нужно для ЧПД.

IF OBJECT_ID('tempdb..#seg25_rows') IS NOT NULL DROP TABLE #seg25_rows;

/* ============================================================================
   1. База: B1A (амортизированная стоимость) и B1B (справедливая стоимость).
      Колонки перечислены явно — SELECT * запрещён § 4.
      TRY_CAST везде: колонки сумм приходят nvarchar с нечисловым мусором.
   ========================================================================= */
WITH src AS (
    SELECT
          'B1A'                                                       AS book
        , n.loan_id_kr
        , n.iin_bin
        , n.entity
        , n.lsboo
        , n.stage_b
        , COALESCE(TRY_CAST(n.ead AS float), 0)                       AS ead_n
        -- задолженность по п. 44 Методруководства: без пеней и корректировки
        , COALESCE(TRY_CAST(n.od           AS float), 0)
        + COALESCE(TRY_CAST(n.od_del       AS float), 0)
        + COALESCE(TRY_CAST(n.interest     AS float), 0)
        + COALESCE(TRY_CAST(n.interest_del AS float), 0)
        + COALESCE(TRY_CAST(n.disc_prem    AS float), 0)              AS amount
        -- база порога 0,2 %: как считает действующий расчёт AQR, со всеми
        -- составляющими. Расхождение с п. 44 зафиксировано в ASSUMPTIONS.
        , COALESCE(TRY_CAST(n.od           AS float), 0)
        + COALESCE(TRY_CAST(n.od_del       AS float), 0)
        + COALESCE(TRY_CAST(n.interest     AS float), 0)
        + COALESCE(TRY_CAST(n.interest_del AS float), 0)
        + COALESCE(TRY_CAST(n.correction   AS float), 0)
        + COALESCE(TRY_CAST(n.disc_prem    AS float), 0)
        + COALESCE(TRY_CAST(n.penalty      AS float), 0)              AS zadol
        , TRY_CAST(n.debtor_type AS int)                              AS debtor_type_n
        , TRY_CAST(n.debtor_se   AS int)                              AS debtor_se_n
        , TRY_CAST(n.ent_type    AS int)                              AS ent_type_n
        , TRY_CAST(n.loan_obj    AS int)                              AS loan_obj_n
        , TRY_CAST(n.f_inv       AS int)                              AS f_inv_n
        , CASE WHEN a.bin IS NOT NULL THEN 1 ELSE 0 END               AS in_b2a
    FROM       [CL_PORTFOLIO].[dbo].[AQR2026_B1A_2025_Q4]             AS n
    LEFT JOIN  [personal_tables].[dbo].[RA_NST_B2A_2026_04012026]     AS a
           ON  a.bin = n.iin_bin
    WHERE n.is_del = '0'

    UNION ALL

    SELECT
          'B1B'
        , n.loan_id_kr
        , n.iin_bin
        , n.entity
        , n.lsboo
        , n.stage_b
        , COALESCE(TRY_CAST(n.ead AS float), 0)
        -- B1B: база сумм — изменения справедливой стоимости, не амортизированная
        , COALESCE(TRY_CAST(n.correction AS float), 0)
        + COALESCE(TRY_CAST(n.penalty    AS float), 0)
        + COALESCE(TRY_CAST(n.disc_prem  AS float), 0)
        , COALESCE(TRY_CAST(n.correction AS float), 0)
        + COALESCE(TRY_CAST(n.penalty    AS float), 0)
        + COALESCE(TRY_CAST(n.disc_prem  AS float), 0)
        , TRY_CAST(n.debtor_type AS int)
        , TRY_CAST(n.debtor_se   AS int)
        , TRY_CAST(n.ent_type    AS int)
        , TRY_CAST(n.loan_obj    AS int)
        , TRY_CAST(n.f_inv       AS int)
        , CASE WHEN a.bin IS NOT NULL THEN 1 ELSE 0 END
    FROM       [CL_PORTFOLIO].[dbo].[AQR2026_B1B_2025_Q4]             AS n
    LEFT JOIN  [personal_tables].[dbo].[RA_NST_B2A_2026_04012026]     AS a
           ON  a.bin = n.iin_bin
    WHERE n.is_del = '0'
),
agg AS (
    -- задолженность заёмщика считается по всем его договорам обеих книг
    SELECT
          book, loan_id_kr, iin_bin, entity, lsboo, stage_b
        , ead_n, amount, zadol
        , debtor_type_n, debtor_se_n, ent_type_n, loan_obj_n, f_inv_n, in_b2a
        , SUM(zadol) OVER (PARTITION BY iin_bin)                      AS zadol_borrower
    FROM src
)
SELECT
      book
    , loan_id_kr
    , iin_bin
    , ead_n
    , amount
    , zadol
    , zadol_borrower

    /* ---- стадия -------------------------------------------------------- */
    , CASE
        WHEN stage_b = '4'             THEN '3'   -- стадии 4 в НСТ нет, сводим к 3
        WHEN stage_b = '1111111111111' THEN '1'   -- заглушка источника
        ELSE stage_b
      END                                                    AS stage

    /* ---- СЕГМЕНТ. Только продукт Таблицы 4. Флаги его не подменяют. ----- */
    , CASE
        -- Розница: физлицо, не ИП. Делится по объекту кредитования.
        -- Доказано на данных: loan_obj=8 -> RETCON, 6 -> RETCAR, 1 -> RETEST.
        WHEN COALESCE(debtor_type_n, 0) = 0 AND COALESCE(debtor_se_n, 0) = 0
             AND ead_n <= @thr_ead                        -- Р4, на этих данных no-op
          THEN CASE loan_obj_n
                 WHEN 1 THEN 'RETEST'
                 WHEN 6 THEN 'RETCAR'
                 ELSE        'RETCON'
               END
        -- Недвижимость выше размера бизнеса (оговорка Таблицы 4)
        WHEN loan_obj_n IN (1, 2, 3)                         THEN 'COREST'
        -- Размер бизнеса. ent_type согласуется с эталоном лишь на 57-72 % (Р3).
        WHEN ent_type_n = 1                                  THEN 'CORLAR'
        WHEN ent_type_n = 2                                  THEN 'CORMED'
        WHEN ent_type_n = 3                                  THEN 'RETSML'
        ELSE 'X'                                             -- не распознано
      END                                                    AS segment

    /* ---- ФЛАГИ. Отдельные колонки, не значения сегмента (Р1). ---------- */
    , CASE WHEN entity = 'EUB1'          THEN 1 ELSE 0 END   AS flag_disass
    , CASE WHEN lsboo  = 1               THEN 1 ELSE 0 END   AS flag_relate
    , CASE WHEN COALESCE(f_inv_n, 0) = 1 THEN 1 ELSE 0 END   AS flag_corinv
    , CASE WHEN in_b2a = 1
             OR zadol_borrower > @capital * @thr_ind
           THEN 1 ELSE 0 END                                 AS flag_individual
    -- основание индивидуальности нужно раздельно: список выходит за критерий
    -- Таблицы 4 и требует отдельного обоснования перед Агентством
    , CASE
        WHEN in_b2a = 1                           THEN 'B2A'
        WHEN zadol_borrower > @capital * @thr_ind THEN 'threshold'
        ELSE NULL
      END                                                    AS individual_basis
INTO #seg25_rows
FROM agg
OPTION (MAXDOP 1);


/* ============================================================================
   ВЫВОД 1. Сводка по сегментам
   ========================================================================= */
SELECT
      segment
    , COUNT(*)                                               AS contracts
    , SUM(amount)                                            AS amount_total
    , SUM(ead_n)                                             AS ead_total
    , CAST(100.0 * COUNT(*)     / SUM(COUNT(*))     OVER () AS decimal(6,2)) AS pct_contracts
    , CAST(100.0 * SUM(ead_n)   / NULLIF(SUM(SUM(ead_n)) OVER (), 0) AS decimal(6,2)) AS pct_ead
FROM #seg25_rows
GROUP BY segment
ORDER BY ead_total DESC;

/* ============================================================================
   ВЫВОД 2. Сегмент x стадия — вход в матрицы перехода
   ========================================================================= */
SELECT segment, stage, COUNT(*) AS contracts, SUM(amount) AS amount_total, SUM(ead_n) AS ead_total
FROM #seg25_rows
GROUP BY segment, stage
ORDER BY segment, stage;

/* ============================================================================
   ВЫВОД 3. Флаги — сколько несёт каждый признак, НЕ выводя его из сегмента
   ========================================================================= */
SELECT 'flag_individual' AS flag, flag_individual AS val, COUNT(*) AS contracts, SUM(ead_n) AS ead_total
FROM #seg25_rows GROUP BY flag_individual
UNION ALL SELECT 'flag_relate', flag_relate, COUNT(*), SUM(ead_n) FROM #seg25_rows GROUP BY flag_relate
UNION ALL SELECT 'flag_disass', flag_disass, COUNT(*), SUM(ead_n) FROM #seg25_rows GROUP BY flag_disass
UNION ALL SELECT 'flag_corinv', flag_corinv, COUNT(*), SUM(ead_n) FROM #seg25_rows GROUP BY flag_corinv
ORDER BY flag, val;

/* ============================================================================
   ВЫВОД 4. Где именно сидят индивидуальные — главная проверка правки.
            Раньше эти договоры уходили из своих сегментов; теперь остаются.
   ========================================================================= */
SELECT
      segment
    , individual_basis
    , COUNT(*)                        AS contracts
    , COUNT(DISTINCT iin_bin)         AS borrowers
    , SUM(ead_n)                      AS ead_total
FROM #seg25_rows
WHERE flag_individual = 1
GROUP BY segment, individual_basis
ORDER BY ead_total DESC;

/* ============================================================================
   ВЫВОД 5. Контроли
   ========================================================================= */
SELECT 'нераспознанный сегмент X'          AS control, COUNT(*) AS n, SUM(ead_n) AS ead FROM #seg25_rows WHERE segment = 'X'
UNION ALL
SELECT 'дубли ключа loan_id_kr',           COUNT(*), NULL FROM (SELECT loan_id_kr FROM #seg25_rows GROUP BY loan_id_kr HAVING COUNT(*) > 1) d
UNION ALL
SELECT 'индивидуальных заёмщиков всего',   COUNT(DISTINCT iin_bin), NULL FROM #seg25_rows WHERE flag_individual = 1
UNION ALL
SELECT 'из них по списку B2A',             COUNT(DISTINCT iin_bin), NULL FROM #seg25_rows WHERE individual_basis = 'B2A'
UNION ALL
SELECT 'из них по порогу 0,2 % СК',        COUNT(DISTINCT iin_bin), NULL FROM #seg25_rows WHERE individual_basis = 'threshold'
UNION ALL
SELECT 'договоров всего',                  COUNT(*), SUM(ead_n) FROM #seg25_rows;

/* ============================================================================
   ВЫВОД 6. Строчная выгрузка — для материализации в свою таблицу.
            Только ключ и признаки: PII не выводится (§ 2).
   ========================================================================= */
SELECT
      book
    , loan_id_kr
    , segment
    , stage
    , ead_n                AS ead
    , amount
    , flag_individual
    , individual_basis
    , flag_relate
    , flag_disass
    , flag_corinv
FROM #seg25_rows
ORDER BY segment, stage, loan_id_kr
OPTION (MAXDOP 1);

DROP TABLE #seg25_rows;
