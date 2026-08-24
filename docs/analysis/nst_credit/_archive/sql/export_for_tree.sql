/* ============================================================================
   Выгрузка для восстановления правил сегментации деревом решений.

   Назначение : подготовить один файл для colab/segment_rules_colab.py
   Read-only  : только SELECT, постоянные объекты не меняются
   Результат  : одна строка на договор B1A + две колонки сегментации

   ВАЖНО, что сюда НЕ включено и почему:
     - метрики AQR (lgd, pd_*, provisions, prov_rate, rwa_*, ccf) —
       они калиброваны ПО СЕГМЕНТУ, и дерево выучило бы «lgd = 0,695 -> CORLAR»,
       показав фиктивную точность вместо настоящих правил;
     - name, contract_number, account_no — ПДн, для задачи не нужны;
     - stage, ead_n, amount — производные того же скрипта сегментации.

   Скрипт на стороне Python исключает эти же колонки повторно (leak_cols),
   так что двойная защита. Но выгружать их всё равно не нужно.
   ========================================================================= */

SET NOCOUNT ON;

/* ---- параметры отчётной даты ------------------------------------------- */
DECLARE @capital     float    = 461235157000;   -- СК на отчётную дату, ЗАМЕНИТЬ
DECLARE @report_date date     = '2024-12-31';   -- отчётная дата НСТ

SELECT
    /* --- две сегментации: эталон и прежние правила --------------------- */
      s.segment_afr                       AS segment_afr      -- эталон АФР
    , s.segment_eub                       AS segment_eub      -- как делил банк

    /* --- ключ заёмщика ------------------------------------------------- */
    /* Запуск локальный, поэтому ИИН/БИН можно оставить как есть.
       Если файл когда-нибудь понадобится передать вовне — заменить строку на
         , DENSE_RANK() OVER (ORDER BY b.iin_bin) AS iin_bin
       агрегаты по заёмщику от этого не пострадают, ПДн уйдут.               */
    , b.iin_bin                           AS iin_bin

    /* --- признаки заёмщика --------------------------------------------- */
    , b.entity, b.residency, b.debtor_type, b.debtor_se, b.ent_type
    , b.oked, b.lsboo, b.ind_sign, b.kdn

    /* --- признаки договора --------------------------------------------- */
    , b.loan_type, b.f_inv, b.curr, b.cl_type, b.ccf_cat
    , b.loan_start_date, b.loan_end_date
    , b.loan_obj, b.loan_purp, b.rate_type
    , b.collateral, b.ltv, b.portfolio

    /* --- суммы: нужны для порога 0,2 % и для отсечки 200 млн ------------ */
    , b.loan_amount, b.od, b.od_del, b.interest, b.interest_del
    , b.correction, b.disc_prem, b.penalty, b.offbal, b.ead

    /* --- поведение ------------------------------------------------------ */
    , b.dpd, b.restr_count, b.restr_d, b.wo

    /* --- стадия: не метрика, а классификация ---------------------------- */
    , b.stage_b

    /* --- флаг присутствия в списке B2A ---------------------------------- */
    /* Без него «Индивидуальные займы», попавшие туда по списку, а не по
       порогу, выглядят как шум, и дерево выдаст по ним мусорные условия.   */
    , CASE WHEN a.bin IS NOT NULL THEN 1 ELSE 0 END AS in_b2a

    /* --- две базы задолженности рядом ----------------------------------- */
    /* metod  — по п. 44 Методруководства: без пеней и без корректировки.
       script — как считает действующий скрипт: с ними обеими.
       Дерево само покажет, какая из них соответствует эталону.             */
    , TRY_CAST(b.od AS float)           + TRY_CAST(b.od_del AS float)
    + TRY_CAST(b.interest AS float)     + TRY_CAST(b.interest_del AS float)
    + TRY_CAST(b.disc_prem AS float)                       AS zadol_metod
    , TRY_CAST(b.od AS float)           + TRY_CAST(b.od_del AS float)
    + TRY_CAST(b.interest AS float)     + TRY_CAST(b.interest_del AS float)
    + TRY_CAST(b.disc_prem AS float)    + TRY_CAST(b.correction AS float)
    + TRY_CAST(b.penalty AS float)                         AS zadol_script

FROM       [CL_PORTFOLIO].[dbo].[AQR2025_B1A_2024_Q4]        AS b
LEFT JOIN  [personal_tables].[dbo].[RA_NST_segment_AQR2025]  AS s
       ON  s.loan_id_kr = b.loan_id_kr
LEFT JOIN  [personal_tables].[dbo].[RA_NST_B2A_AQR2025_11082025] AS a
       ON  a.bin = b.iin_bin
WHERE  b.is_del = '0'
OPTION (MAXDOP 1);

/* ============================================================================
   Выгрузить результат в CSV:
     - разделитель  ;
     - кодировка    UTF-8
     - имя файла    b1a_for_tree.csv

   CSV, не xlsx: 731 тыс. строк в Excel открываются, но файл раздувается
   и читается втрое дольше.

   Контроль перед запуском модели — число строк обязано совпасть с B1A:
     SELECT COUNT(*) FROM [CL_PORTFOLIO].[dbo].[AQR2025_B1A_2024_Q4]
     WHERE is_del = '0';                                  -- ожидается 731 159

   И проверить, что обе колонки сегментации заполнены:
     SELECT SUM(CASE WHEN segment_afr IS NULL THEN 1 ELSE 0 END) AS no_afr
          , SUM(CASE WHEN segment_eub IS NULL THEN 1 ELSE 0 END) AS no_eub
     FROM ...;
   ========================================================================= */
