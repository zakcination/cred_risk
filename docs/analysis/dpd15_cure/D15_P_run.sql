/* =============================================================================
   D15-P. Повторный тест «длина подтверждения против высоты порога»
   со сдвинутым окном исхода, флагом реструктуризации и балансом на выходе.
   -----------------------------------------------------------------------------
   ЗАЧЕМ. Оценка Г-O1 из RESULTS_D15O.md (ещё один чистый месяц снимает
   до −17,96 п.п. срывов) получена при НЕСДВИНУТОМ окне исхода и является
   оценкой сверху: заём, просроченный на паузе t+1 и не заплативший дальше,
   автоматически окажется у 60 дней к t+2. Этот прогон разводит три вещи,
   которые в D15-O были склеены:

     (a) сдвиг окна   — тот же заём, тот же выход t, исход на t+3 / t+4
                        вместо t+2 / t+3. Если ставка падает уже здесь,
                        это дрейф окна, а не эффект подтверждения;
     (b) подтверждение — выход по правилу «7 чистых месяцев» (ветвь B),
                        исход на t'+2 / t'+3. Это и есть «ещё один месяц»;
     (c) отбор         — разница между (a) и (b) на одной когорте
                        показывает, сколько даёт требование чистого 7-го
                        месяца само по себе.

   Плюс два поля, которых в D15-O не было:
     * f_restr    — Г-N3′: заём реструктурирован до выхода
                    ([дата окончания реструктуры] из IFRS9);
     * bal_exit   — баланс на дату выхода из CL_PORTFOLIO_2 (только S03),
                    чтобы взвесить ставку срыва по экспозиции — вход в EL.

   ОДНА КОГОРТА ДЛЯ ВСЕХ ВЕТВЕЙ. Строка ветви A появляется, только если
   наблюдаемы четыре месяца после выхода (t+1 … t+4). Это отсекает ≈1,75 %
   когорты D15-O (самая поздняя дата выхода становится 2026-04 вместо
   2026-05); ожидаемая усечённая база при tau = 0 — 20 586 займов.

   ДВЕ ВЕТВИ В ОДНОЙ ВЫГРУЗКЕ, колонка arm:
     A6  действующее правило: 6 чистых месяцев, первое достижимое окно,
         пауза t+1, исход t+2 / t+3 (out_max) и сдвинутый t+3 / t+4
         (out_max_shift);
     B7  продлённое правило: 7 чистых месяцев, первое достижимое окно t',
         пауза t'+1, исход t'+2 / t'+3 (out_max).
   B7 ⊆ A6 по займам; при t' = t + 1 календарные месяцы исхода B7
   совпадают со сдвинутым исходом A6. Сравнивать в сводной:
     A6/out_max   → базовая ставка (ожидание ≈ 29,48 %);
     A6/out_max_shift → тот же заём, окно позже;
     B7/out_max   → правило «ещё один месяц».

   ЧТО ПЕРЕСОБИРАЕТСЯ В EXCEL (сводная поверх выгрузки):
     фильтр arm=A6, tau=0, строки exit_month    → ранние против поздних
     фильтр arm, tau; значение СРЗНАЧ(f_return30) и СРЗНАЧ(f_return30_shift)
     фильтр tau=0, строки arm, столбцы f_restr  → доля реструктурированных
     фильтр f_bal_match=1; СУММ(bal_exit) по f_return30 → ставка в деньгах

   ГРАНИЦЫ, названы прямо:
     * когорта — дефолты 2019-01 … 2025-10, сетка снимков по 2026-08;
     * окно ищется до 36-го месяца от дефолта;
     * баланс есть только для счетов, найденных в CL_PORTFOLIO_2 (S03);
       f_bal_match = 0 не означает нулевой баланс — означает «не найден»;
     * [дата окончания реструктуры] берётся из среза KAN_20260801: заём,
       реструктурированный ПОСЛЕ этой даты, флага не получит;
     * приостановка начисления по-прежнему не выделяется — поля нет.

   Источники:
     [CL_PORTFOLIO].[dbo].[HISTORY_DEFAULT_ACCOUNT]  займы, даты, сетка DPD
     [IFRS9].[dbo].[KAN_20260801_for_LGD_Fenix]      продукт, дата окончания
                                                     реструктуры; SELECT *
                                                     запрещён — там ИИН
     [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2]           баланс на дату, S03

   КОНФИДЕНЦИАЛЬНОСТЬ. Выгрузка содержит номера договоров и В РЕПОЗИТОРИЙ
   НЕ КОММИТИТСЯ, за периметр банка не выносится. Если файл нужно кому-то
   передать — сначала удалить колонку account_number.

   Read-only. Только SELECT. Без временных таблиц. MAXDOP 1.
   Ожидаемый объём: A6 ≈ 197 тыс. строк, B7 ≈ 140 тыс. — около 340 тыс.,
   помещается в лист Excel; при нехватке памяти выгружать ветви по отдельности
   (фильтр по arm в последнем WHERE).

   ГЕЙТ, объявлен ДО прогона — см. блок проверок в конце файла.
   ============================================================================= */

SET NOCOUNT ON;


/* ---------------------------------------------------------------------------
   § 0. ПРЯМОЙ ЗАМЕР на усечённой когорте — три ставки одним запросом.
   Гнать первым: если A6/out_max не даст ≈ 29,48 %, выгрузке не верить.
   --------------------------------------------------------------------------- */
WITH panel AS (
    SELECT
          h.account_number
        , DATEDIFF(MONTH, h.default_date, CAST(v.snap AS date)) AS m
        , TRY_CAST(v.dpd AS int)                                AS dpd
    FROM [CL_PORTFOLIO].[dbo].[HISTORY_DEFAULT_ACCOUNT] h
    CROSS APPLY ( VALUES
      ('2019-02-01', h.['01.02.2019']),('2019-03-01', h.['01.03.2019'])
     ,('2019-04-01', h.['01.04.2019']),('2019-05-01', h.['01.05.2019'])
     ,('2019-06-01', h.['01.06.2019']),('2019-07-01', h.['01.07.2019'])
     ,('2019-08-01', h.['01.08.2019']),('2019-09-01', h.['01.09.2019'])
     ,('2019-10-01', h.['01.10.2019']),('2019-11-01', h.['01.11.2019'])
     ,('2019-12-01', h.['01.12.2019']),('2020-01-01', h.['01.01.2020'])
     ,('2020-02-01', h.['01.02.2020']),('2020-03-01', h.['01.03.2020'])
     ,('2020-04-01', h.['01.04.2020']),('2020-05-01', h.['01.05.2020'])
     ,('2020-06-01', h.['01.06.2020']),('2020-07-01', h.['01.07.2020'])
     ,('2020-08-01', h.['01.08.2020']),('2020-09-01', h.['01.09.2020'])
     ,('2020-10-01', h.['01.10.2020']),('2020-11-01', h.['01.11.2020'])
     ,('2020-12-01', h.['01.12.2020']),('2021-01-01', h.['01.01.2021'])
     ,('2021-02-01', h.['01.02.2021']),('2021-03-01', h.['01.03.2021'])
     ,('2021-04-01', h.['01.04.2021']),('2021-05-01', h.['01.05.2021'])
     ,('2021-06-01', h.['01.06.2021']),('2021-07-01', h.['01.07.2021'])
     ,('2021-08-01', h.['01.08.2021']),('2021-09-01', h.['01.09.2021'])
     ,('2021-10-01', h.['01.10.2021']),('2021-11-01', h.['01.11.2021'])
     ,('2021-12-01', h.['01.12.2021']),('2022-01-01', h.['01.01.2022'])
     ,('2022-02-01', h.['01.02.2022']),('2022-03-01', h.['01.03.2022'])
     ,('2022-04-01', h.['01.04.2022']),('2022-05-01', h.['01.05.2022'])
     ,('2022-06-01', h.['01.06.2022']),('2022-07-01', h.['01.07.2022'])
     ,('2022-08-01', h.['01.08.2022']),('2022-09-01', h.['01.09.2022'])
     ,('2022-10-01', h.['01.10.2022']),('2022-11-01', h.['01.11.2022'])
     ,('2022-12-01', h.['01.12.2022']),('2023-01-01', h.['01.01.2023'])
     ,('2023-02-01', h.['01.02.2023']),('2023-03-01', h.['01.03.2023'])
     ,('2023-04-01', h.['01.04.2023']),('2023-05-01', h.['01.05.2023'])
     ,('2023-06-01', h.['01.06.2023']),('2023-07-01', h.['01.07.2023'])
     ,('2023-08-01', h.['01.08.2023']),('2023-09-01', h.['01.09.2023'])
     ,('2023-10-01', h.['01.10.2023']),('2023-11-01', h.['01.11.2023'])
     ,('2023-12-01', h.['01.12.2023']),('2024-01-01', h.['01.01.2024'])
     ,('2024-02-01', h.['01.02.2024']),('2024-03-01', h.['01.03.2024'])
     ,('2024-04-01', h.['01.04.2024']),('2024-05-01', h.['01.05.2024'])
     ,('2024-06-01', h.['01.06.2024']),('2024-07-01', h.['01.07.2024'])
     ,('2024-08-01', h.['01.08.2024']),('2024-09-01', h.['01.09.2024'])
     ,('2024-10-01', h.['01.10.2024']),('2024-11-01', h.['01.11.2024'])
     ,('2024-12-01', h.['01.12.2024']),('2025-01-01', h.['01.01.2025'])
     ,('2025-02-01', h.['01.02.2025']),('2025-03-01', h.['01.03.2025'])
     ,('2025-04-01', h.['01.04.2025']),('2025-05-01', h.['01.05.2025'])
     ,('2025-06-01', h.['01.06.2025']),('2025-07-01', h.['01.07.2025'])
     ,('2025-08-01', h.['01.08.2025']),('2025-09-01', h.['01.09.2025'])
     ,('2025-10-01', h.['01.10.2025']),('2025-11-01', h.['01.11.2025'])
     ,('2025-12-01', h.['01.12.2025']),('2026-01-01', h.['01.01.2026'])
     ,('2026-02-01', h.['01.02.2026']),('2026-03-01', h.['01.03.2026'])
     ,('2026-04-01', h.['01.04.2026']),('2026-05-01', h.['01.05.2026'])
     ,('2026-06-01', h.['01.06.2026']),('2026-07-01', h.['01.07.2026'])
     ,('2026-08-01', h.['01.08.2026'])
    ) v(snap, dpd)
    WHERE h.default_date >= '2019-01-01'
      AND h.default_date <= '2025-10-01'
      AND CAST(v.snap AS date) >  h.default_date
      AND CAST(v.snap AS date) <= DATEADD(MONTH, 40, h.default_date)
),
w AS (
    SELECT
          account_number, m, dpd
        , COUNT(dpd) OVER (PARTITION BY account_number ORDER BY m
                           ROWS BETWEEN 5 PRECEDING AND CURRENT ROW) AS obs6
        , MAX(dpd)   OVER (PARTITION BY account_number ORDER BY m
                           ROWS BETWEEN 5 PRECEDING AND CURRENT ROW) AS wmax6
        , COUNT(dpd) OVER (PARTITION BY account_number ORDER BY m
                           ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS obs7
        , MAX(dpd)   OVER (PARTITION BY account_number ORDER BY m
                           ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS wmax7
        , LEAD(dpd, 2) OVER (PARTITION BY account_number ORDER BY m) AS d2
        , LEAD(dpd, 3) OVER (PARTITION BY account_number ORDER BY m) AS d3
        , LEAD(dpd, 4) OVER (PARTITION BY account_number ORDER BY m) AS d4
    FROM panel
),
a6 AS (
    SELECT account_number, m, d2, d3, d4
         , ROW_NUMBER() OVER (PARTITION BY account_number ORDER BY m) AS rn
    FROM w WHERE obs6 = 6 AND wmax6 = 0 AND m <= 36
),
b7 AS (
    SELECT account_number, m, d2, d3
         , ROW_NUMBER() OVER (PARTITION BY account_number ORDER BY m) AS rn
    FROM w WHERE obs7 = 7 AND wmax7 = 0 AND m <= 36
),
coh AS (   -- усечённая когорта: у A6 наблюдаем t+4
    SELECT account_number FROM a6
    WHERE rn = 1 AND d2 IS NOT NULL AND d3 IS NOT NULL AND d4 IS NOT NULL
)
SELECT N'A6 / когорта D15-O (t+3 наблюдаем)' AS ветвь, COUNT(*) AS займов
     , SUM(CASE WHEN (CASE WHEN d2 >= d3 THEN d2 ELSE d3 END) > 30 THEN 1 ELSE 0 END) AS вернулись_30plus
     , CAST(100.0 * SUM(CASE WHEN (CASE WHEN d2 >= d3 THEN d2 ELSE d3 END) > 30 THEN 1 ELSE 0 END)
            / COUNT(*) AS decimal(5,2)) AS ставка_pct
FROM a6 WHERE rn = 1 AND d2 IS NOT NULL AND d3 IS NOT NULL      -- ожидание: 20 953 / 29,04 %
UNION ALL
SELECT N'A6 / усечённая (t+4 наблюдаем), исход t+2,t+3', COUNT(*)
     , SUM(CASE WHEN (CASE WHEN d2 >= d3 THEN d2 ELSE d3 END) > 30 THEN 1 ELSE 0 END)
     , CAST(100.0 * SUM(CASE WHEN (CASE WHEN d2 >= d3 THEN d2 ELSE d3 END) > 30 THEN 1 ELSE 0 END)
            / COUNT(*) AS decimal(5,2))
FROM a6 WHERE rn = 1 AND account_number IN (SELECT account_number FROM coh)   -- ожидание: ≈ 20 586 / 29,48 %
UNION ALL
SELECT N'A6 / сдвиг t+3,t+4', COUNT(*)
     , SUM(CASE WHEN (CASE WHEN d3 >= d4 THEN d3 ELSE d4 END) > 30 THEN 1 ELSE 0 END)
     , CAST(100.0 * SUM(CASE WHEN (CASE WHEN d3 >= d4 THEN d3 ELSE d4 END) > 30 THEN 1 ELSE 0 END)
            / COUNT(*) AS decimal(5,2))
FROM a6 WHERE rn = 1 AND account_number IN (SELECT account_number FROM coh)
UNION ALL
SELECT N'B7 / исход t''+2,t''+3', COUNT(*)
     , SUM(CASE WHEN (CASE WHEN d2 >= d3 THEN d2 ELSE d3 END) > 30 THEN 1 ELSE 0 END)
     , CAST(100.0 * SUM(CASE WHEN (CASE WHEN d2 >= d3 THEN d2 ELSE d3 END) > 30 THEN 1 ELSE 0 END)
            / COUNT(*) AS decimal(5,2))
FROM b7 WHERE rn = 1 AND d2 IS NOT NULL AND d3 IS NOT NULL
  AND account_number IN (SELECT account_number FROM coh)
OPTION (MAXDOP 1);


/* ---------------------------------------------------------------------------
   § 1. САМА ВЫГРУЗКА. Выгружать в Excel как есть, сводную строить поверх.
   --------------------------------------------------------------------------- */
WITH panel AS (
    SELECT
          h.account_number
        , h.default_date
        , h.health_date
        , CASE WHEN h.new_default_date > h.health_date
                 OR h.new_health_date  > h.health_date THEN 1 ELSE 0 END AS redef
        , CAST(v.snap AS date)                                           AS snap
        , DATEDIFF(MONTH, h.default_date, CAST(v.snap AS date))          AS m
        , TRY_CAST(v.dpd AS int)                                         AS dpd
    FROM [CL_PORTFOLIO].[dbo].[HISTORY_DEFAULT_ACCOUNT] h
    CROSS APPLY ( VALUES
      ('2019-02-01', h.['01.02.2019']),('2019-03-01', h.['01.03.2019'])
     ,('2019-04-01', h.['01.04.2019']),('2019-05-01', h.['01.05.2019'])
     ,('2019-06-01', h.['01.06.2019']),('2019-07-01', h.['01.07.2019'])
     ,('2019-08-01', h.['01.08.2019']),('2019-09-01', h.['01.09.2019'])
     ,('2019-10-01', h.['01.10.2019']),('2019-11-01', h.['01.11.2019'])
     ,('2019-12-01', h.['01.12.2019']),('2020-01-01', h.['01.01.2020'])
     ,('2020-02-01', h.['01.02.2020']),('2020-03-01', h.['01.03.2020'])
     ,('2020-04-01', h.['01.04.2020']),('2020-05-01', h.['01.05.2020'])
     ,('2020-06-01', h.['01.06.2020']),('2020-07-01', h.['01.07.2020'])
     ,('2020-08-01', h.['01.08.2020']),('2020-09-01', h.['01.09.2020'])
     ,('2020-10-01', h.['01.10.2020']),('2020-11-01', h.['01.11.2020'])
     ,('2020-12-01', h.['01.12.2020']),('2021-01-01', h.['01.01.2021'])
     ,('2021-02-01', h.['01.02.2021']),('2021-03-01', h.['01.03.2021'])
     ,('2021-04-01', h.['01.04.2021']),('2021-05-01', h.['01.05.2021'])
     ,('2021-06-01', h.['01.06.2021']),('2021-07-01', h.['01.07.2021'])
     ,('2021-08-01', h.['01.08.2021']),('2021-09-01', h.['01.09.2021'])
     ,('2021-10-01', h.['01.10.2021']),('2021-11-01', h.['01.11.2021'])
     ,('2021-12-01', h.['01.12.2021']),('2022-01-01', h.['01.01.2022'])
     ,('2022-02-01', h.['01.02.2022']),('2022-03-01', h.['01.03.2022'])
     ,('2022-04-01', h.['01.04.2022']),('2022-05-01', h.['01.05.2022'])
     ,('2022-06-01', h.['01.06.2022']),('2022-07-01', h.['01.07.2022'])
     ,('2022-08-01', h.['01.08.2022']),('2022-09-01', h.['01.09.2022'])
     ,('2022-10-01', h.['01.10.2022']),('2022-11-01', h.['01.11.2022'])
     ,('2022-12-01', h.['01.12.2022']),('2023-01-01', h.['01.01.2023'])
     ,('2023-02-01', h.['01.02.2023']),('2023-03-01', h.['01.03.2023'])
     ,('2023-04-01', h.['01.04.2023']),('2023-05-01', h.['01.05.2023'])
     ,('2023-06-01', h.['01.06.2023']),('2023-07-01', h.['01.07.2023'])
     ,('2023-08-01', h.['01.08.2023']),('2023-09-01', h.['01.09.2023'])
     ,('2023-10-01', h.['01.10.2023']),('2023-11-01', h.['01.11.2023'])
     ,('2023-12-01', h.['01.12.2023']),('2024-01-01', h.['01.01.2024'])
     ,('2024-02-01', h.['01.02.2024']),('2024-03-01', h.['01.03.2024'])
     ,('2024-04-01', h.['01.04.2024']),('2024-05-01', h.['01.05.2024'])
     ,('2024-06-01', h.['01.06.2024']),('2024-07-01', h.['01.07.2024'])
     ,('2024-08-01', h.['01.08.2024']),('2024-09-01', h.['01.09.2024'])
     ,('2024-10-01', h.['01.10.2024']),('2024-11-01', h.['01.11.2024'])
     ,('2024-12-01', h.['01.12.2024']),('2025-01-01', h.['01.01.2025'])
     ,('2025-02-01', h.['01.02.2025']),('2025-03-01', h.['01.03.2025'])
     ,('2025-04-01', h.['01.04.2025']),('2025-05-01', h.['01.05.2025'])
     ,('2025-06-01', h.['01.06.2025']),('2025-07-01', h.['01.07.2025'])
     ,('2025-08-01', h.['01.08.2025']),('2025-09-01', h.['01.09.2025'])
     ,('2025-10-01', h.['01.10.2025']),('2025-11-01', h.['01.11.2025'])
     ,('2025-12-01', h.['01.12.2025']),('2026-01-01', h.['01.01.2026'])
     ,('2026-02-01', h.['01.02.2026']),('2026-03-01', h.['01.03.2026'])
     ,('2026-04-01', h.['01.04.2026']),('2026-05-01', h.['01.05.2026'])
     ,('2026-06-01', h.['01.06.2026']),('2026-07-01', h.['01.07.2026'])
     ,('2026-08-01', h.['01.08.2026'])
    ) v(snap, dpd)
    WHERE h.default_date >= '2019-01-01'
      AND h.default_date <= '2025-10-01'
      AND CAST(v.snap AS date) >  h.default_date
      AND CAST(v.snap AS date) <= DATEADD(MONTH, 40, h.default_date)
),
w AS (
    SELECT
          account_number, default_date, health_date, redef, snap, m, dpd
        , COUNT(dpd) OVER (PARTITION BY account_number ORDER BY m
                           ROWS BETWEEN 5 PRECEDING AND CURRENT ROW) AS obs6
        , MAX(dpd)   OVER (PARTITION BY account_number ORDER BY m
                           ROWS BETWEEN 5 PRECEDING AND CURRENT ROW) AS wmax6
        , COUNT(dpd) OVER (PARTITION BY account_number ORDER BY m
                           ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS obs7
        , MAX(dpd)   OVER (PARTITION BY account_number ORDER BY m
                           ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS wmax7
        , LAG (dpd, 6) OVER (PARTITION BY account_number ORDER BY m) AS l6
        , LAG (dpd, 5) OVER (PARTITION BY account_number ORDER BY m) AS l5
        , LAG (dpd, 4) OVER (PARTITION BY account_number ORDER BY m) AS l4
        , LAG (dpd, 3) OVER (PARTITION BY account_number ORDER BY m) AS l3
        , LAG (dpd, 2) OVER (PARTITION BY account_number ORDER BY m) AS l2
        , LAG (dpd, 1) OVER (PARTITION BY account_number ORDER BY m) AS l1
        , LEAD(dpd, 1) OVER (PARTITION BY account_number ORDER BY m) AS d1
        , LEAD(dpd, 2) OVER (PARTITION BY account_number ORDER BY m) AS d2
        , LEAD(dpd, 3) OVER (PARTITION BY account_number ORDER BY m) AS d3
        , LEAD(dpd, 4) OVER (PARTITION BY account_number ORDER BY m) AS d4
    FROM panel
),
tau AS ( SELECT tau FROM ( VALUES (0),(3),(5),(10),(15),(20),(25),(30) ) t(tau) ),
candA AS (
    SELECT 'A6' AS arm, t.tau, w.*
         , ROW_NUMBER() OVER (PARTITION BY w.account_number, t.tau ORDER BY w.m) AS rn
    FROM w CROSS JOIN tau t
    WHERE w.obs6 = 6 AND w.wmax6 <= t.tau AND w.m <= 36
),
candB AS (
    SELECT 'B7' AS arm, t.tau, w.*
         , ROW_NUMBER() OVER (PARTITION BY w.account_number, t.tau ORDER BY w.m) AS rn
    FROM w CROSS JOIN tau t
    WHERE w.obs7 = 7 AND w.wmax7 <= t.tau AND w.m <= 36
),
coh AS (   -- усечённая когорта: у A6 при tau = 0 наблюдаем t+4
    SELECT account_number FROM candA
    WHERE tau = 0 AND rn = 1 AND d2 IS NOT NULL AND d3 IS NOT NULL AND d4 IS NOT NULL
),
cand AS (
    SELECT arm, tau, account_number, default_date, health_date, redef, snap, m, dpd
         , wmax6, wmax7, l6, l5, l4, l3, l2, l1, d1, d2, d3, d4
    FROM candA WHERE rn = 1 AND d2 IS NOT NULL AND d3 IS NOT NULL AND d4 IS NOT NULL
    UNION ALL
    SELECT arm, tau, account_number, default_date, health_date, redef, snap, m, dpd
         , wmax6, wmax7, l6, l5, l4, l3, l2, l1, d1, d2, d3, d4
    FROM candB WHERE rn = 1 AND d2 IS NOT NULL AND d3 IS NOT NULL
)
SELECT
      c.account_number
    , c.default_date
    , YEAR(c.default_date)                                        AS vintage_year
    , CAST(YEAR(c.default_date) AS varchar(4)) + '-Q'
      + CAST(DATEPART(QUARTER, c.default_date) AS varchar(1))     AS vintage_qtr
    , p.subproduct
    , c.arm
    , c.tau
    , c.m                                                         AS exit_month
    , c.snap                                                      AS exit_snap
    , CASE WHEN (c.arm = 'A6' AND c.wmax6 = 0)
             OR (c.arm = 'B7' AND c.wmax7 = 0) THEN 'STRICT'
           ELSE 'SOFT-ONLY' END                                   AS grp
    /* окно: для A6 — w1…w6 = l5…l1, текущий; для B7 — w1…w7 = l6…l1, текущий */
    , CASE WHEN c.arm = 'B7' THEN c.l6 ELSE c.l5 END              AS w1
    , CASE WHEN c.arm = 'B7' THEN c.l5 ELSE c.l4 END              AS w2
    , CASE WHEN c.arm = 'B7' THEN c.l4 ELSE c.l3 END              AS w3
    , CASE WHEN c.arm = 'B7' THEN c.l3 ELSE c.l2 END              AS w4
    , CASE WHEN c.arm = 'B7' THEN c.l2 ELSE c.l1 END              AS w5
    , CASE WHEN c.arm = 'B7' THEN c.l1 ELSE c.dpd END             AS w6
    , CASE WHEN c.arm = 'B7' THEN c.dpd ELSE NULL END             AS w7
    , c.d1                                                        AS dpd_pause
    , c.d2                                                        AS dpd_out1
    , c.d3                                                        AS dpd_out2
    , c.d4                                                        AS dpd_out3
    , CASE WHEN c.d2 >= c.d3 THEN c.d2 ELSE c.d3 END              AS out_max
    , CASE WHEN c.d4 IS NULL THEN NULL
           WHEN c.d3 >= c.d4 THEN c.d3 ELSE c.d4 END              AS out_max_shift
    /* флаги: определение видно целиком, пересчитывается из соседних колонок */
    , CASE WHEN (CASE WHEN c.d2 >= c.d3 THEN c.d2 ELSE c.d3 END) > 30
           THEN 1 ELSE 0 END                                      AS f_return30
    , CASE WHEN c.d4 IS NULL THEN NULL
           WHEN (CASE WHEN c.d3 >= c.d4 THEN c.d3 ELSE c.d4 END) > 30
           THEN 1 ELSE 0 END                                      AS f_return30_shift
    , CASE WHEN (CASE WHEN c.d2 >= c.d3 THEN c.d2 ELSE c.d3 END)
                - c.dpd >= 30 THEN 1 ELSE 0 END                   AS f_delta30
    , CASE WHEN c.health_date IS NOT NULL THEN 1 ELSE 0 END       AS f_cured_fact
    , c.redef                                                     AS f_redef_reg
    /* Г-N3′: реструктуризация закончилась между дефолтом и выходом */
    , p.restr_end
    , CASE WHEN p.restr_end IS NOT NULL
            AND p.restr_end >  c.default_date
            AND p.restr_end <= c.snap THEN 1 ELSE 0 END           AS f_restr
    /* вход в EL: баланс на дату выхода, только S03 */
    , b.bal_exit
    , CASE WHEN b.bal_exit IS NOT NULL THEN 1 ELSE 0 END          AS f_bal_match
FROM cand c
LEFT JOIN (
    SELECT account_number
         , MAX(subproduct)                                     AS subproduct
         , MAX(TRY_CAST([дата окончания реструктуры] AS date)) AS restr_end
    FROM [IFRS9].[dbo].[KAN_20260801_for_LGD_Fenix]
    GROUP BY account_number
) p ON p.account_number = c.account_number
LEFT JOIN (
    SELECT contract_number, [date]
         , SUM(TRY_CAST(balance AS decimal(18,2))) AS bal_exit
    FROM [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2]
    GROUP BY contract_number, [date]
) b ON b.contract_number = c.account_number AND b.[date] = c.snap
WHERE c.account_number IN (SELECT account_number FROM coh)
ORDER BY c.account_number, c.arm, c.tau
OPTION (MAXDOP 1);


/* ---------------------------------------------------------------------------
   ГЕЙТ — проверки, объявленные до прогона. Ожидания взяты из построчной
   выгрузки D15-O, усечённой до займов с наблюдаемым t+4 (o_scope.py, 01.09).

   1. Строк arm = A6 при tau = 0 обязано быть 20 586 (усечённая когорта).
   2. СРЗНАЧ(f_return30) при arm = A6, tau = 0 обязан дать 29,48 %.
   3. При arm = A6, tau = 0: exit_month = 7 → 47,61 % на 9 316 займах;
      exit_month >= 8 → 14,50 % на 11 270. Это разложение D15-O на той же
      когорте; расхождение больше 0,05 п.п. — дефект скрипта, не находка.
   4. У всех строк с grp = 'STRICT' окно (w1…w6, для B7 — w1…w7) — нули.
   5. exit_month у A6 не меньше 7, у B7 — не меньше 8.
   6. При tau = 0 строк B7 не больше, чем строк A6 с dpd_pause = 0:
      заём с 7 чистыми месяцами обязан иметь чистую паузу в шестимесячной
      постановке (на полной когорте таких было 15 083).
   7. f_bal_match — только справочно, гейтом не является: баланс есть
      у счетов S03. Долю совпадения записать в отчёт, а не объяснять.

   Что считается результатом, а не гейтом:
      A6/out_max_shift против A6/out_max — дрейф окна;
      B7/out_max против A6/out_max_shift — эффект подтверждения за вычетом
      дрейфа; это и есть цифра, которую можно предъявлять вместо −17,96.

   Любая непройденная проверка 1–6 означает, что выгрузка не соответствует
   расчёту D15-O, и сравнивать ветви нельзя, пока причина не найдена.
   --------------------------------------------------------------------------- */
