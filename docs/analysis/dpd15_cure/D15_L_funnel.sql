/* =============================================================================
   D15-L. ВОРОНКА. Простая версия главного расчёта — шесть шагов, один проход.

   ОТВЕТ НА «CAN WE TRY THIS WAY» (когорты до 2025, MaxObs 12, горизонт 6).
   Да, и эти параметры ДЕЛАЮТ расчёт проще, если принять их следствие честно:

     при @MaxObs = 12 и горизонте 6 полное наблюдение исхода есть только
     у выхода на м6 (6 + 6 = 12). Значит правило проверяется РОВНО ОДИН РАЗ —
     на шестом месяце после дефолта. Это первый месяц, когда банк вообще
     проверяет заём по механизму «дефолтнул 7 месяцев назад». Никаких
     скользящих окон, никакого «первого прошедшего месяца» — одна контрольная
     точка на счёт. Полная версия с любым месяцем выхода остаётся в D15-K.

   ДВЕ ОГОВОРКИ, КОТОРЫЕ ПАРАМЕТРЫ НЕ ОТМЕНЯЮТ:
     * хвост 2025 незрелый: сетка DPD реально заполнена по 01.08.2026,
       поэтому дефолты после 2025-08 не имеют полного горизонта — шаг 5
       их отсеивает и воронка показывает сколько;
     * горизонт 6 ловит только быстрые срывы: по прогону D15-K это примерно
       две трети срывов первого года (21,6 из 32,0 у SOFT-ONLY). Ставки будут
       НИЖЕ 12-месячных — сравнивать можно только внутри этого прогона.

   ВОРОНКА. Каждый шаг — одна временная таблица и одна контрольная цифра.

     ШАГ 1  ЗАЙМЫ        база — loan id из БАЗЫ ДЕФОЛТОВ: дефолты 2019–2025
     ШАГ 2  ПРОСРОЧКА    181 месячная колонка той же таблицы -> длинная панель
     ШАГ 3  ОКНО         м1..м6 после дефолта: сколько наблюдений, max DPD
     ШАГ 4  ГРУППА       STRICT (все 6 нулей) / SOFT-ONLY (все 6 <= 15) / NEVER
     ШАГ 5  ИСХОД        max DPD в м7..м12; полнота наблюдения обязательна
     ШАГ 6  СТАВКИ       воронка одним списком + ставки по группам и продуктам

   Источники (подтверждены аудитом, детали в DATA_LINEAGE.md):
     [CL_PORTFOLIO].[dbo].[HISTORY_DEFAULT_ACCOUNT] — займы, даты, сетка DPD
     [IFRS9].[dbo].[KAN_20260801_for_LGD_Fenix]     — продукт (subproduct)

   Read-only. Только SELECT. #temp с префиксом D15L_. MAXDOP 1. Одно окно.
   ============================================================================= */

SET NOCOUNT ON;

DECLARE @From   date = '2019-01-01';   -- когорта дефолтов: с
DECLARE @To     date = '2025-12-31';   -- по
DECLARE @Soft   int  = 15;             -- мягкий порог
DECLARE @DefThr int  = 90;             -- исход: DPD выше этого = дефолт заново
DECLARE @LastReal date = '2026-08-01'; -- последний реально заполненный срез сетки


/* ---------------------------------------------------------------------------
   ШАГ 1. ЗАЙМЫ. Одна строка на счёт, только нужные даты.
   --------------------------------------------------------------------------- */
IF OBJECT_ID('tempdb..#D15L_loans') IS NOT NULL DROP TABLE #D15L_loans;

SELECT account_number, default_date, health_date
INTO #D15L_loans
FROM [CL_PORTFOLIO].[dbo].[HISTORY_DEFAULT_ACCOUNT]
WHERE default_date BETWEEN @From AND @To
OPTION (MAXDOP 1);

CREATE UNIQUE CLUSTERED INDEX ix1 ON #D15L_loans(account_number);

SELECT 'ШАГ 1  займы в когорте' AS step, COUNT(*) AS n FROM #D15L_loans;


/* ---------------------------------------------------------------------------
   ШАГ 2. ПРОСРОЧКА. Сетка -> длинная панель, только месяцы 1..12 от дефолта.
   (181 строка VALUES — та же, что в D15-K § 2; вставить блок оттуда.)
   --------------------------------------------------------------------------- */
IF OBJECT_ID('tempdb..#D15L_dpd') IS NOT NULL DROP TABLE #D15L_dpd;

SELECT
      l.account_number
    , DATEDIFF(MONTH, l.default_date, CAST(v.snap_date AS date)) AS m
    , TRY_CAST(v.dpd_raw AS int)                                 AS dpd
INTO #D15L_dpd
FROM #D15L_loans l
INNER JOIN [CL_PORTFOLIO].[dbo].[HISTORY_DEFAULT_ACCOUNT] h
        ON h.account_number = l.account_number
CROSS APPLY ( VALUES
     /* === ВСТАВИТЬ 181 СТРОКУ ('дата', h.['колонка']) ИЗ D15-K § 2 === */
     ('2026-08-01', h.['01.08.2026'])
) v(snap_date, dpd_raw)
WHERE DATEDIFF(MONTH, l.default_date, CAST(v.snap_date AS date)) BETWEEN 1 AND 12
  AND CAST(v.snap_date AS date) <= @LastReal        -- незаполненное будущее не берём
OPTION (MAXDOP 1);

CREATE CLUSTERED INDEX ix2 ON #D15L_dpd(account_number, m);

SELECT 'ШАГ 2  строк панели DPD' AS step, COUNT(*) AS n FROM #D15L_dpd;


/* ---------------------------------------------------------------------------
   ШАГ 3 + 4. ОКНО м1..м6 И ГРУППА. Один GROUP BY вместо оконных функций.
   --------------------------------------------------------------------------- */
IF OBJECT_ID('tempdb..#D15L_grp') IS NOT NULL DROP TABLE #D15L_grp;

SELECT
      account_number
    , COUNT(CASE WHEN m BETWEEN 1 AND 6  THEN dpd END)  AS win_obs
    , MAX  (CASE WHEN m BETWEEN 1 AND 6  THEN dpd END)  AS win_max
    , COUNT(CASE WHEN m BETWEEN 7 AND 12 THEN dpd END)  AS hor_obs
    , MAX  (CASE WHEN m BETWEEN 7 AND 12 THEN dpd END)  AS hor_max
INTO #D15L_grp
FROM #D15L_dpd
GROUP BY account_number
OPTION (MAXDOP 1);

SELECT 'ШАГ 3  окно наблюдаемо полностью (6 из 6)' AS step,
       SUM(CASE WHEN win_obs = 6 THEN 1 ELSE 0 END) AS n,
       SUM(CASE WHEN win_obs < 6 THEN 1 ELSE 0 END) AS cut_incomplete_window
FROM #D15L_grp;

SELECT 'ШАГ 4  группа' AS step,
       CASE WHEN win_obs < 6        THEN '- отсев: окно неполное'
            WHEN win_max = 0        THEN 'STRICT: шесть нулей — вышел бы и сейчас'
            WHEN win_max <= @Soft   THEN 'SOFT-ONLY: все шесть <= 15 — прирост'
            ELSE                         'NEVER: правило не выполнено' END AS grp,
       COUNT(*) AS n
FROM #D15L_grp
GROUP BY CASE WHEN win_obs < 6      THEN '- отсев: окно неполное'
            WHEN win_max = 0        THEN 'STRICT: шесть нулей — вышел бы и сейчас'
            WHEN win_max <= @Soft   THEN 'SOFT-ONLY: все шесть <= 15 — прирост'
            ELSE                         'NEVER: правило не выполнено' END
ORDER BY n DESC;


/* ---------------------------------------------------------------------------
   ШАГ 5 + 6. ИСХОД И СТАВКИ. Только полное наблюдение горизонта (6 из 6).
   --------------------------------------------------------------------------- */
SELECT
      CASE WHEN g.win_max = 0      THEN 'STRICT'
           WHEN g.win_max <= @Soft THEN 'SOFT-ONLY' END        AS grp
    , COUNT(*)                                                 AS n_full_obs
    , SUM(CASE WHEN g.hor_obs < 6 THEN 1 ELSE 0 END)           AS cut_incomplete_horizon
    , SUM(CASE WHEN g.hor_obs = 6 AND g.hor_max > @DefThr THEN 1 ELSE 0 END) AS defaulted
    , CAST(100.0 * SUM(CASE WHEN g.hor_obs = 6 AND g.hor_max > @DefThr THEN 1 ELSE 0 END)
           / NULLIF(SUM(CASE WHEN g.hor_obs = 6 THEN 1 ELSE 0 END),0)
           AS decimal(5,2))                                    AS default_rate_6m_pct
FROM #D15L_grp g
WHERE g.win_obs = 6 AND g.win_max <= @Soft
GROUP BY CASE WHEN g.win_max = 0      THEN 'STRICT'
              WHEN g.win_max <= @Soft THEN 'SOFT-ONLY' END
ORDER BY grp
OPTION (MAXDOP 1);

-- ШАГ 6а. То же по продуктам. Клетка меньше 100 займов не публикуется.
SELECT
      p.subproduct
    , CASE WHEN g.win_max = 0 THEN 'STRICT' ELSE 'SOFT-ONLY' END AS grp
    , COUNT(*)                                                   AS n
    , CAST(100.0 * SUM(CASE WHEN g.hor_max > @DefThr THEN 1 ELSE 0 END)
           / NULLIF(COUNT(*),0) AS decimal(5,2))                 AS default_rate_6m_pct
FROM #D15L_grp g
INNER JOIN (
    SELECT account_number, MAX(subproduct) AS subproduct
    FROM [IFRS9].[dbo].[KAN_20260801_for_LGD_Fenix]
    GROUP BY account_number
) p ON p.account_number = g.account_number
WHERE g.win_obs = 6 AND g.win_max <= @Soft AND g.hor_obs = 6
GROUP BY p.subproduct, CASE WHEN g.win_max = 0 THEN 'STRICT' ELSE 'SOFT-ONLY' END
HAVING COUNT(*) >= 100
ORDER BY p.subproduct, grp
OPTION (MAXDOP 1);

-- ШАГ 6б. Чистый прирост против ускорения: был ли счёт вылечен фактически.
SELECT
      CASE WHEN l.health_date IS NOT NULL THEN 'ускорение: вылечен и фактически'
           ELSE 'ЧИСТЫЙ ПРИРОСТ: фактически не вылечен' END      AS kind
    , COUNT(*)                                                   AS n
    , CAST(100.0 * SUM(CASE WHEN g.hor_max > @DefThr THEN 1 ELSE 0 END)
           / NULLIF(COUNT(*),0) AS decimal(5,2))                 AS default_rate_6m_pct
FROM #D15L_grp g
INNER JOIN #D15L_loans l ON l.account_number = g.account_number
WHERE g.win_obs = 6 AND g.win_max > 0 AND g.win_max <= @Soft AND g.hor_obs = 6
GROUP BY CASE WHEN l.health_date IS NOT NULL THEN 'ускорение: вылечен и фактически'
              ELSE 'ЧИСТЫЙ ПРИРОСТ: фактически не вылечен' END
OPTION (MAXDOP 1);
