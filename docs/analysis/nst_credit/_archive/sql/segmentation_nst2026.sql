/* ============================================================================
   НСТ-2026: сегментация кредитного портфеля на 31.12.2025.

   Правила восстановлены по эталону АФР (RA_NST_segment_AQR2025) на периоде
   2024 Q4 — см. TREE_RUN_2.md и confusion_vs_afr_2024q4.sql.
   Разбор расхождений и обоснование каждой правки — MISCLASSIFICATION_ANALYSIS.md.

   Read-only: только SELECT.

   ЧТО ИЗМЕНЕНО ОТНОСИТЕЛЬНО ВЕРСИИ ОТ 24.08.2026
   ---------------------------------------------------------------------------
   1. DISASS / RELATE / CORINV / Individual loans больше НЕ значения сегмента.
      В эталоне АФР этих значений нет вовсе — Таблица 3 требует распределить их
      по продуктовым портфелям. Они вынесены в отдельные колонки-флаги, заём
      классифицируется по продукту независимо от них.
   2. Розница делится по loan_obj, а не по collateral / portfolio.
      Доказано на данных: loan_obj=8 → RETCON (619 638 строк, 100 %),
      loan_obj=6 → RETCAR (103 341, 100 %), loan_obj=1 → RETEST (799, 99 %).
      Прежнее условие portfolio IN ('Mortgage') AND collateral=1 эталону
      не соответствует.
   3. Из фильтра COREST убраны loan_purp 4 и 5 — в данных их не существует;
      снято требование заполненного ent_type (иначе заём на недвижимость
      физлицу не-ИП не попадёт в COREST никогда).
   4. Снят порог EAD ≤ 200 млн в рознице — в Таблице 4 его нет, это была
      конструкция скрипта.
   5. TRY_CAST вместо CAST. Колонки сумм — nvarchar с нечисловым мусором,
      обычный CAST падает с "Error converting data type nvarchar to float".

   ЧТО НЕ ИСПРАВЛЕНО И ПОЧЕМУ
   ---------------------------------------------------------------------------
   - Размер бизнеса (CORLAR / CORMED / RETSML) по-прежнему через ent_type.
     Согласие с эталоном 57-72 %: каждый третий-четвёртый корпоративный договор
     эталон относит не туда. Статья 24 Предпринимательского кодекса требует
     численность работников и годовой доход — этих полей в выгрузке нет.
     Закрывается только запросом снимка РСП, не правкой скрипта.
   - CORGOV не реализован: нужен справочник БИН трёх госхолдингов и двух
     уровней дочерности с госучастием > 50 %.
   - Признак господдержки (п. 242) не реализован: нужен перечень программ.
   ========================================================================= */

SET NOCOUNT ON;

/* ---- Параметры отчётной даты 31.12.2025 --------------------------------
   @capital : собственный капитал на 01.01.2026, согласован с расчётом Сайлау
   @mrp     : МРП по закону о республиканском бюджете на 1 января отчётного года
   ----------------------------------------------------------------------- */
DECLARE @capital  float = 503086114000;
DECLARE @mrp      float = 3932;
DECLARE @thr_ind  float = 0.002;          -- 0,2 % СК, Таблица 4

-- Пороги статьи 24 Предпринимательского кодекса. Пока справочно:
-- ent_type приходит готовым, эти значения нужны для сверки его происхождения.
DECLARE @income_large float = @mrp * 3000000;   -- крупный:  > 3 000 000 МРП
DECLARE @income_small float = @mrp *  300000;   -- малый  : <= 300 000 МРП


/* ============================================================================
   B1A — договоры по амортизированной стоимости
   ========================================================================= */
WITH b1a_base AS (
    SELECT
          n.*
        , COALESCE(TRY_CAST(n.ead AS float), 0)                      AS ead_n
        -- задолженность по п. 44 Методруководства: без пеней и корректировки
        , COALESCE(TRY_CAST(n.od           AS float), 0)
        + COALESCE(TRY_CAST(n.od_del       AS float), 0)
        + COALESCE(TRY_CAST(n.interest     AS float), 0)
        + COALESCE(TRY_CAST(n.interest_del AS float), 0)
        + COALESCE(TRY_CAST(n.disc_prem    AS float), 0)              AS amount
        -- база порога 0,2 %: как считает действующий расчёт AQR, со всеми
        -- составляющими. Расхождение с п. 44 зафиксировано в ASSUMPTIONS.md.
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
        , TRY_CAST(n.loan_purp   AS int)                              AS loan_purp_n
        , TRY_CAST(n.f_inv       AS int)                              AS f_inv_n
        , CASE WHEN a.bin IS NOT NULL THEN 1 ELSE 0 END               AS in_b2a
    FROM       [CL_PORTFOLIO].[dbo].[AQR2026_B1A_2025_Q4]             AS n
    LEFT JOIN  [personal_tables].[dbo].[RA_NST_B2A_2026_04012026]     AS a
           ON  a.bin = n.iin_bin
    WHERE n.is_del = '0'
),
b1a_agg AS (
    SELECT *, SUM(zadol) OVER (PARTITION BY iin_bin) AS zadol_borrower
    FROM b1a_base
)
SELECT
      *
    /* ---- стадия ------------------------------------------------------- */
    , CASE
        WHEN stage_b = '4'             THEN '3'   -- stage 4 не определён, сводим к 3
        WHEN stage_b = '1111111111111' THEN '1'   -- заглушка источника
        ELSE stage_b
      END                                                    AS stage

    /* ---- ПРОДУКТОВЫЙ СЕГМЕНТ (Таблица 4) ------------------------------
       Единственное значение сегмента. Флаги ниже его не подменяют.        */
    , CASE
        -- Розница: физлицо, не ИП. Делится по объекту кредитования.
        WHEN COALESCE(debtor_type_n, 0) = 0 AND COALESCE(debtor_se_n, 0) = 0
          THEN CASE loan_obj_n
                 WHEN 1 THEN 'RETEST'   -- жилая недвижимость
                 WHEN 6 THEN 'RETCAR'   -- автомобильный транспорт
                 ELSE        'RETCON'   -- потребительские и прочие
               END
        -- Недвижимость выше размера бизнеса (оговорка Таблицы 4)
        WHEN loan_obj_n IN (1, 2, 3)                         THEN 'COREST'
        -- Размер бизнеса. ent_type согласуется с эталоном лишь на 57-72 %.
        WHEN ent_type_n = 1                                  THEN 'CORLAR'
        WHEN ent_type_n = 2                                  THEN 'CORMED'
        WHEN ent_type_n = 3                                  THEN 'RETSML'
        ELSE 'X'
      END                                                    AS segment_afr

    /* ---- ФЛАГИ: сосуществуют с сегментом, а не заменяют его ------------
       Таблица 3: «распределены по другим портфелям». Для кредитного риска
       они не сегмент; для ЧПД и для контроля периметра — нужны отдельно.  */
    , CASE WHEN entity = 'EUB1'         THEN 1 ELSE 0 END    AS flag_disass
    , CASE WHEN lsboo = 1               THEN 1 ELSE 0 END    AS flag_relate
    , CASE WHEN COALESCE(f_inv_n, 0) = 1 THEN 1 ELSE 0 END   AS flag_corinv
    , CASE WHEN in_b2a = 1
             OR zadol_borrower > @capital * @thr_ind
           THEN 1 ELSE 0 END                                 AS flag_individual
    -- основание индивидуальности: список B2A или порог — нужны раздельно,
    -- список выходит за критерий Таблицы 4 и требует обоснования
    , CASE
        WHEN in_b2a = 1                                THEN 'B2A'
        WHEN zadol_borrower > @capital * @thr_ind      THEN 'threshold'
        ELSE NULL
      END                                                    AS individual_basis
FROM b1a_agg
OPTION (MAXDOP 1);


/* ============================================================================
   B1B — договоры по справедливой стоимости (переводные)
   Отличие только в базе сумм: изменения, а не амортизированная стоимость.
   ========================================================================= */
WITH b1b_base AS (
    SELECT
          n.*
        , COALESCE(TRY_CAST(n.ead AS float), 0)                      AS ead_n
        , COALESCE(TRY_CAST(n.correction AS float), 0)
        + COALESCE(TRY_CAST(n.penalty    AS float), 0)
        + COALESCE(TRY_CAST(n.disc_prem  AS float), 0)                AS amount
        , COALESCE(TRY_CAST(n.correction AS float), 0)
        + COALESCE(TRY_CAST(n.penalty    AS float), 0)
        + COALESCE(TRY_CAST(n.disc_prem  AS float), 0)                AS zadol
        , TRY_CAST(n.debtor_type AS int)                              AS debtor_type_n
        , TRY_CAST(n.debtor_se   AS int)                              AS debtor_se_n
        , TRY_CAST(n.ent_type    AS int)                              AS ent_type_n
        , TRY_CAST(n.loan_obj    AS int)                              AS loan_obj_n
        , TRY_CAST(n.loan_purp   AS int)                              AS loan_purp_n
        , TRY_CAST(n.f_inv       AS int)                              AS f_inv_n
        , CASE WHEN a.bin IS NOT NULL THEN 1 ELSE 0 END               AS in_b2a
    FROM       [CL_PORTFOLIO].[dbo].[AQR2026_B1B_2025_Q4]             AS n
    LEFT JOIN  [personal_tables].[dbo].[RA_NST_B2A_2026_04012026]     AS a
           ON  a.bin = n.iin_bin
    WHERE n.is_del = '0'
),
b1b_agg AS (
    SELECT *, SUM(zadol) OVER (PARTITION BY iin_bin) AS zadol_borrower
    FROM b1b_base
)
SELECT
      *
    , CASE
        WHEN stage_b = '4'             THEN '3'
        WHEN stage_b = '1111111111111' THEN '1'
        ELSE stage_b
      END                                                    AS stage
    , CASE
        WHEN COALESCE(debtor_type_n, 0) = 0 AND COALESCE(debtor_se_n, 0) = 0
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
      END                                                    AS segment_afr
    , CASE WHEN entity = 'EUB1'         THEN 1 ELSE 0 END    AS flag_disass
    , CASE WHEN lsboo = 1               THEN 1 ELSE 0 END    AS flag_relate
    , CASE WHEN COALESCE(f_inv_n, 0) = 1 THEN 1 ELSE 0 END   AS flag_corinv
    , CASE WHEN in_b2a = 1
             OR zadol_borrower > @capital * @thr_ind
           THEN 1 ELSE 0 END                                 AS flag_individual
    , CASE
        WHEN in_b2a = 1                                THEN 'B2A'
        WHEN zadol_borrower > @capital * @thr_ind      THEN 'threshold'
        ELSE NULL
      END                                                    AS individual_basis
FROM b1b_agg
OPTION (MAXDOP 1);
