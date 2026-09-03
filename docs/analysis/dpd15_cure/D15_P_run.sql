/* =============================================================================
   D15-P (редакция 2, 02.09.2026). Повторный тест «длина подтверждения против
   высоты порога»: сетка правил k = 6…9 чистых месяцев, просрочка на шести
   месяцах после выхода, три порога исхода, флаг реструктуризации.
   -----------------------------------------------------------------------------
   ПОРЯДОК ПО §6 CLAUDE.md. Структура согласована автором 02.09.2026 — шесть
   решений С1–С6 из PR #69; в этой редакции реализованы ВЫБРАННЫЕ варианты:

     С1  ветви — не одна B7, а СЕТКА k = 6, 7, 8, 9 чистых месяцев
         (k = 6 — действующее правило, оно же база D15-O);
     С2  окно исхода не фиксируется: экспортируется просрочка на t+1 … t+6,
         любое окно — t+2/t+3, t+3/t+4, t+4/t+5 — собирается в сводной;
     С3  порогов исхода три — DPD > 30, > 60, > 90 — плюс флаг повторного
         дефолта из реестра (f_redef_reg);
     С4  когорта ПОЛНАЯ, как в D15-O: строка есть, если наблюдаемы t+2 и t+3;
         более поздние месяцы — NULL там, где сетка кончилась; obs_lead
         говорит, сколько месяцев после выхода наблюдаемо;
     С5  реструктуризация — [дата окончания реструктуры] IS NOT NULL, любая
         дата; сама дата экспортируется, вариант «между дефолтом и выходом»
         пересчитывается в сводной;
     С6  баланса нет — поле ждём из mart, соединение с CL_PORTFOLIO_2 снято.

   ВЗАИМОДЕЙСТВИЕ С2 × С3, названо прямо. У займа с DPD = 0 на выходе t
   просрочка на t+2 не превышает ≈ 62 дней, на t+3 ≈ 93 — столько
   календарных дней не прошло (это тест Г-N3 из RESULTS_D15O.md). Поэтому:
     порог > 30 и > 60 — считать на окне t+2/t+3 (out_max_23);
     порог > 90 — ТОЛЬКО на окне t+4/t+5 (out_max_45) и позже;
     f90 на окне t+2/t+3 арифметически невозможен, и его тут нет.

   ЧТО ЭТО РАЗВОДИТ. Для k = 6 на одной когорте: out_max_23 — базовая ставка
   (ожидание 29,04 %); out_max_34 и out_max_45 — тот же заём, окно позже:
   дрейф окна. Для k = 7…9 — правило «ещё k − 6 месяцев», исход на своём
   t'+2/t'+3. Эффект подтверждения = ставка k на out_max_23 против ставки
   k = 6 на окне, сдвинутом на k − 6 месяцев. Это и есть цифра вместо −17,96.

   ЧТО ПЕРЕСОБИРАЕТСЯ В EXCEL (сводная поверх выгрузки):
     фильтр k=6, tau=0, строки exit_month           → ранние против поздних
     строки k, значения СРЗНАЧ(f30_23), СРЗНАЧ(f60_23), СРЗНАЧ(f90_45)
     строки k, фильтр obs_lead>=5, СРЗНАЧ по out_max_34 / out_max_45 > 30
     фильтр tau=0, строки k, столбцы f_restr         → доля реструктурированных
     строки vintage_year / subproduct                → контроли, как в D15-O

   ГРАНИЦЫ:
     * когорта — дефолты 2019-01 … 2025-10, сетка снимков по 2026-08;
     * окно ищется до 36-го месяца от дефолта; t+6 ищется до 42-го;
     * сравнивать ветви k только на займах с наблюдаемым нужным окном —
       фильтр по obs_lead, иначе ветви стоят на разных знаменателях;
     * [дата окончания реструктуры] — срез KAN_20260801: реструктуризация
       после этой даты флага не получит;
     * приостановка начисления не выделяется — поля нет.

   Источники:
     [CL_PORTFOLIO].[dbo].[HISTORY_DEFAULT_ACCOUNT]  займы, даты, сетка DPD
     [IFRS9].[dbo].[KAN_20260801_for_LGD_Fenix]      продукт, дата окончания
                                                     реструктуры; SELECT *
                                                     запрещён — там ИИН

   КОНФИДЕНЦИАЛЬНОСТЬ. Выгрузка содержит номера договоров и В РЕПОЗИТОРИЙ
   НЕ КОММИТИТСЯ, за периметр банка не выносится. Если файл нужно кому-то
   передать — сначала удалить колонку account_number.

   Read-only. Только SELECT. Без временных таблиц. MAXDOP 1.
   ОБЪЁМ: четыре ветви × восемь tau — порядка 450 тыс. строк. Лист Excel
   держит 1 048 576; если тяжело — оставить в последнем WHERE tau IN (0, 15)
   (комментарий помечен) — объём упадёт до ≈ 115 тыс.

   ГЕЙТ объявлен ДО прогона — блок проверок в конце файла.
   ============================================================================= */

SET NOCOUNT ON;


/* ---------------------------------------------------------------------------
   § 0. ПРЯМОЙ ЗАМЕР по четырём ветвям — одним запросом, до выгрузки.
   Строка k = 6 / out_max_23 обязана дать 20 953 займа и 29,04 %.
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
      AND CAST(v.snap AS date) <= DATEADD(MONTH, 42, h.default_date)
),
w AS (
    SELECT
          account_number, m, dpd
        , COUNT(dpd) OVER (PARTITION BY account_number ORDER BY m ROWS BETWEEN 5 PRECEDING AND CURRENT ROW) AS obs6
        , MAX(dpd)   OVER (PARTITION BY account_number ORDER BY m ROWS BETWEEN 5 PRECEDING AND CURRENT ROW) AS wmax6
        , COUNT(dpd) OVER (PARTITION BY account_number ORDER BY m ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS obs7
        , MAX(dpd)   OVER (PARTITION BY account_number ORDER BY m ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS wmax7
        , COUNT(dpd) OVER (PARTITION BY account_number ORDER BY m ROWS BETWEEN 7 PRECEDING AND CURRENT ROW) AS obs8
        , MAX(dpd)   OVER (PARTITION BY account_number ORDER BY m ROWS BETWEEN 7 PRECEDING AND CURRENT ROW) AS wmax8
        , COUNT(dpd) OVER (PARTITION BY account_number ORDER BY m ROWS BETWEEN 8 PRECEDING AND CURRENT ROW) AS obs9
        , MAX(dpd)   OVER (PARTITION BY account_number ORDER BY m ROWS BETWEEN 8 PRECEDING AND CURRENT ROW) AS wmax9
        , LEAD(dpd, 1) OVER (PARTITION BY account_number ORDER BY m) AS d1
        , LEAD(dpd, 2) OVER (PARTITION BY account_number ORDER BY m) AS d2
        , LEAD(dpd, 3) OVER (PARTITION BY account_number ORDER BY m) AS d3
        , LEAD(dpd, 4) OVER (PARTITION BY account_number ORDER BY m) AS d4
        , LEAD(dpd, 5) OVER (PARTITION BY account_number ORDER BY m) AS d5
    FROM panel
),
firstk AS (
    SELECT 6 AS k, account_number, m, d1, d2, d3, d4, d5
         , ROW_NUMBER() OVER (PARTITION BY account_number ORDER BY m) AS rn
    FROM w WHERE obs6 = 6 AND wmax6 = 0 AND m <= 36
    UNION ALL
    SELECT 7, account_number, m, d1, d2, d3, d4, d5
         , ROW_NUMBER() OVER (PARTITION BY account_number ORDER BY m)
    FROM w WHERE obs7 = 7 AND wmax7 = 0 AND m <= 36
    UNION ALL
    SELECT 8, account_number, m, d1, d2, d3, d4, d5
         , ROW_NUMBER() OVER (PARTITION BY account_number ORDER BY m)
    FROM w WHERE obs8 = 8 AND wmax8 = 0 AND m <= 36
    UNION ALL
    SELECT 9, account_number, m, d1, d2, d3, d4, d5
         , ROW_NUMBER() OVER (PARTITION BY account_number ORDER BY m)
    FROM w WHERE obs9 = 9 AND wmax9 = 0 AND m <= 36
)
SELECT k                                                          AS чистых_месяцев
     , COUNT(*)                                                   AS займов
     , CAST(100.0 * AVG(CASE WHEN (CASE WHEN d2 >= d3 THEN d2 ELSE d3 END) > 30 THEN 1.0 ELSE 0 END)
            AS decimal(5,2))                                      AS ставка30_t23_pct
     , CAST(100.0 * AVG(CASE WHEN (CASE WHEN d2 >= d3 THEN d2 ELSE d3 END) > 60 THEN 1.0 ELSE 0 END)
            AS decimal(5,2))                                      AS ставка60_t23_pct
     , SUM(CASE WHEN d4 IS NOT NULL AND d5 IS NOT NULL THEN 1 ELSE 0 END) AS займов_с_t45
     , CAST(100.0 * SUM(CASE WHEN (CASE WHEN d4 >= d5 THEN d4 ELSE d5 END) > 30 THEN 1 ELSE 0 END)
            / NULLIF(SUM(CASE WHEN d4 IS NOT NULL AND d5 IS NOT NULL THEN 1 ELSE 0 END), 0)
            AS decimal(5,2))                                      AS ставка30_t45_pct
     , CAST(100.0 * SUM(CASE WHEN (CASE WHEN d4 >= d5 THEN d4 ELSE d5 END) > 90 THEN 1 ELSE 0 END)
            / NULLIF(SUM(CASE WHEN d4 IS NOT NULL AND d5 IS NOT NULL THEN 1 ELSE 0 END), 0)
            AS decimal(5,2))                                      AS ставка90_t45_pct
FROM firstk
WHERE rn = 1 AND d2 IS NOT NULL AND d3 IS NOT NULL
GROUP BY k
ORDER BY k
OPTION (MAXDOP 1);


/* ---------------------------------------------------------------------------
   § 1. САМА ВЫГРУЗКА. Одна строка = заём × k × tau. Выгружать в Excel как есть.
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
      AND CAST(v.snap AS date) <= DATEADD(MONTH, 42, h.default_date)
),
w AS (
    SELECT
          account_number, default_date, health_date, redef, snap, m, dpd
        , COUNT(dpd) OVER (PARTITION BY account_number ORDER BY m ROWS BETWEEN 5 PRECEDING AND CURRENT ROW) AS obs6
        , MAX(dpd)   OVER (PARTITION BY account_number ORDER BY m ROWS BETWEEN 5 PRECEDING AND CURRENT ROW) AS wmax6
        , COUNT(dpd) OVER (PARTITION BY account_number ORDER BY m ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS obs7
        , MAX(dpd)   OVER (PARTITION BY account_number ORDER BY m ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS wmax7
        , COUNT(dpd) OVER (PARTITION BY account_number ORDER BY m ROWS BETWEEN 7 PRECEDING AND CURRENT ROW) AS obs8
        , MAX(dpd)   OVER (PARTITION BY account_number ORDER BY m ROWS BETWEEN 7 PRECEDING AND CURRENT ROW) AS wmax8
        , COUNT(dpd) OVER (PARTITION BY account_number ORDER BY m ROWS BETWEEN 8 PRECEDING AND CURRENT ROW) AS obs9
        , MAX(dpd)   OVER (PARTITION BY account_number ORDER BY m ROWS BETWEEN 8 PRECEDING AND CURRENT ROW) AS wmax9
        /* окно как оно есть: просрочка на t−8 … t, без пересборки под k */
        , LAG (dpd, 8) OVER (PARTITION BY account_number ORDER BY m) AS m8
        , LAG (dpd, 7) OVER (PARTITION BY account_number ORDER BY m) AS m7
        , LAG (dpd, 6) OVER (PARTITION BY account_number ORDER BY m) AS m6
        , LAG (dpd, 5) OVER (PARTITION BY account_number ORDER BY m) AS m5
        , LAG (dpd, 4) OVER (PARTITION BY account_number ORDER BY m) AS m4
        , LAG (dpd, 3) OVER (PARTITION BY account_number ORDER BY m) AS m3
        , LAG (dpd, 2) OVER (PARTITION BY account_number ORDER BY m) AS m2
        , LAG (dpd, 1) OVER (PARTITION BY account_number ORDER BY m) AS m1
        /* шесть месяцев после выхода */
        , LEAD(dpd, 1) OVER (PARTITION BY account_number ORDER BY m) AS d1
        , LEAD(dpd, 2) OVER (PARTITION BY account_number ORDER BY m) AS d2
        , LEAD(dpd, 3) OVER (PARTITION BY account_number ORDER BY m) AS d3
        , LEAD(dpd, 4) OVER (PARTITION BY account_number ORDER BY m) AS d4
        , LEAD(dpd, 5) OVER (PARTITION BY account_number ORDER BY m) AS d5
        , LEAD(dpd, 6) OVER (PARTITION BY account_number ORDER BY m) AS d6
    FROM panel
),
tau AS ( SELECT tau FROM ( VALUES (0),(3),(5),(10),(15),(20),(25),(30) ) t(tau) ),
cand AS (
    SELECT 6 AS k, t.tau, w.account_number, w.default_date, w.health_date, w.redef, w.snap, w.m, w.dpd
         , w.wmax6 AS wmax, w.m8, w.m7, w.m6, w.m5, w.m4, w.m3, w.m2, w.m1
         , w.d1, w.d2, w.d3, w.d4, w.d5, w.d6
         , ROW_NUMBER() OVER (PARTITION BY w.account_number, t.tau ORDER BY w.m) AS rn
    FROM w CROSS JOIN tau t
    WHERE w.obs6 = 6 AND w.wmax6 <= t.tau AND w.m <= 36
    UNION ALL
    SELECT 7, t.tau, w.account_number, w.default_date, w.health_date, w.redef, w.snap, w.m, w.dpd
         , w.wmax7, w.m8, w.m7, w.m6, w.m5, w.m4, w.m3, w.m2, w.m1
         , w.d1, w.d2, w.d3, w.d4, w.d5, w.d6
         , ROW_NUMBER() OVER (PARTITION BY w.account_number, t.tau ORDER BY w.m)
    FROM w CROSS JOIN tau t
    WHERE w.obs7 = 7 AND w.wmax7 <= t.tau AND w.m <= 36
    UNION ALL
    SELECT 8, t.tau, w.account_number, w.default_date, w.health_date, w.redef, w.snap, w.m, w.dpd
         , w.wmax8, w.m8, w.m7, w.m6, w.m5, w.m4, w.m3, w.m2, w.m1
         , w.d1, w.d2, w.d3, w.d4, w.d5, w.d6
         , ROW_NUMBER() OVER (PARTITION BY w.account_number, t.tau ORDER BY w.m)
    FROM w CROSS JOIN tau t
    WHERE w.obs8 = 8 AND w.wmax8 <= t.tau AND w.m <= 36
    UNION ALL
    SELECT 9, t.tau, w.account_number, w.default_date, w.health_date, w.redef, w.snap, w.m, w.dpd
         , w.wmax9, w.m8, w.m7, w.m6, w.m5, w.m4, w.m3, w.m2, w.m1
         , w.d1, w.d2, w.d3, w.d4, w.d5, w.d6
         , ROW_NUMBER() OVER (PARTITION BY w.account_number, t.tau ORDER BY w.m)
    FROM w CROSS JOIN tau t
    WHERE w.obs9 = 9 AND w.wmax9 <= t.tau AND w.m <= 36
)
SELECT
      c.account_number
    , c.default_date
    , YEAR(c.default_date)                                        AS vintage_year
    , CAST(YEAR(c.default_date) AS varchar(4)) + '-Q'
      + CAST(DATEPART(QUARTER, c.default_date) AS varchar(1))     AS vintage_qtr
    , p.subproduct
    , c.k                                                         AS k_clean_months
    , c.tau
    , c.m                                                         AS exit_month
    , c.snap                                                      AS exit_snap
    , CASE WHEN c.wmax = 0 THEN 'STRICT' ELSE 'SOFT-ONLY' END     AS grp
    /* окно наблюдения: просрочка на t−8 … t. Для ветви k значимы t−(k−1) … t;
       что левее — справочно (NULL, если сетка не началась) */
    , c.m8 AS dpd_m8, c.m7 AS dpd_m7, c.m6 AS dpd_m6, c.m5 AS dpd_m5
    , c.m4 AS dpd_m4, c.m3 AS dpd_m3, c.m2 AS dpd_m2, c.m1 AS dpd_m1
    , c.dpd                                                       AS dpd_m0
    /* шесть месяцев после выхода; NULL — сетка кончилась */
    , c.d1 AS dpd_p1, c.d2 AS dpd_p2, c.d3 AS dpd_p3
    , c.d4 AS dpd_p4, c.d5 AS dpd_p5, c.d6 AS dpd_p6
    , (CASE WHEN c.d1 IS NULL THEN 0 ELSE 1 END) + (CASE WHEN c.d2 IS NULL THEN 0 ELSE 1 END)
    + (CASE WHEN c.d3 IS NULL THEN 0 ELSE 1 END) + (CASE WHEN c.d4 IS NULL THEN 0 ELSE 1 END)
    + (CASE WHEN c.d5 IS NULL THEN 0 ELSE 1 END) + (CASE WHEN c.d6 IS NULL THEN 0 ELSE 1 END)
                                                                  AS obs_lead
    /* окна исхода — максимум по паре месяцев; флаги считаются из них */
    , CASE WHEN c.d2 >= c.d3 THEN c.d2 ELSE c.d3 END              AS out_max_23
    , CASE WHEN c.d4 IS NULL THEN NULL
           WHEN c.d3 >= c.d4 THEN c.d3 ELSE c.d4 END              AS out_max_34
    , CASE WHEN c.d4 IS NULL OR c.d5 IS NULL THEN NULL
           WHEN c.d4 >= c.d5 THEN c.d4 ELSE c.d5 END              AS out_max_45
    , CASE WHEN (CASE WHEN c.d2 >= c.d3 THEN c.d2 ELSE c.d3 END) > 30 THEN 1 ELSE 0 END AS f30_23
    , CASE WHEN (CASE WHEN c.d2 >= c.d3 THEN c.d2 ELSE c.d3 END) > 60 THEN 1 ELSE 0 END AS f60_23
    , CASE WHEN c.d4 IS NULL OR c.d5 IS NULL THEN NULL
           WHEN (CASE WHEN c.d4 >= c.d5 THEN c.d4 ELSE c.d5 END) > 90 THEN 1 ELSE 0 END AS f90_45
    , CASE WHEN (CASE WHEN c.d2 >= c.d3 THEN c.d2 ELSE c.d3 END)
                - c.dpd >= 30 THEN 1 ELSE 0 END                   AS f_delta30
    , CASE WHEN c.health_date IS NOT NULL THEN 1 ELSE 0 END       AS f_cured_fact
    , c.redef                                                     AS f_redef_reg
    /* С5: реструктуризация — любая дата; сама дата рядом, чтобы пересчитать иначе */
    , p.restr_end
    , CASE WHEN p.restr_end IS NOT NULL THEN 1 ELSE 0 END         AS f_restr
FROM cand c
LEFT JOIN (
    SELECT account_number
         , MAX(subproduct)                                     AS subproduct
         , MAX(TRY_CAST([дата окончания реструктуры] AS date)) AS restr_end
    FROM [IFRS9].[dbo].[KAN_20260801_for_LGD_Fenix]
    GROUP BY account_number
) p ON p.account_number = c.account_number
WHERE c.rn = 1
  AND c.d2 IS NOT NULL
  AND c.d3 IS NOT NULL
  -- AND c.tau IN (0, 15)          -- раскомментировать, если Excel не держит объём
ORDER BY c.account_number, c.k, c.tau
OPTION (MAXDOP 1);


/* ---------------------------------------------------------------------------
   ГЕЙТ — проверки, объявленные до прогона. Ожидания — из D15-O на полной
   когорте (С4), поэтому цифры те же, что уже прошли гейт 01.09.

   1. Строк k = 6 при tau = 0 обязано быть 20 953.
   2. СРЗНАЧ(f30_23) при k = 6, tau = 0 обязан дать 29,04 %.
   3. При k = 6, tau = 0: exit_month = 7 → 47,41 % на 9 368 займах;
      exit_month >= 8 → 14,18 % на 11 585. Расхождение больше 0,05 п.п. —
      дефект скрипта, не находка.
   4. У всех строк с grp = 'STRICT' значения dpd_m(k−1) … dpd_m0 — нули.
   5. exit_month не меньше k + 1: у k = 6 — от 7, у k = 9 — от 10.
   6. Вложенность: при tau = 0 строк k = 7 не больше, чем строк k = 6
      с dpd_p1 = 0 (на когорте D15-O их 15 083); аналогично k = 8 против
      k = 7 с dpd_p1 = 0, k = 9 против k = 8.
   7. f90_45 при k = 6 не пуст: доля строк с obs_lead >= 5 должна быть
      порядка 96–98 % (сдвиг на один месяц отсекал 1,75 % по расчёту 01.09;
      здесь сдвиг на два — ожидаемая потеря примерно вдвое больше).
   8. f90_45 обязан быть NULL ровно там, где dpd_p4 или dpd_p5 NULL —
      ноль вместо NULL здесь означал бы «не сорвался» про ненаблюдаемое.

   Что считается результатом, а не гейтом:
      k = 6, out_max_34 / out_max_45 против out_max_23 — дрейф окна;
      k = 7…9 на out_max_23 против k = 6 на окне, сдвинутом на k − 6 —
      эффект подтверждения за вычетом дрейфа. Это цифра вместо −17,96.

   Любая непройденная проверка 1–6 и 8 означает, что выгрузка не
   соответствует D15-O, и сравнивать ветви нельзя, пока причина не найдена.
   --------------------------------------------------------------------------- */
