/* =============================================================================
   D15-H. Контроли, исправление окна и разрезы по продуктам.

   ПОЧЕМУ ЭТОТ СКРИПТ СУЩЕСТВУЕТ. Результаты D15-G отозваны: окно наблюдения
   было смещено на месяц. Механизм таблицы, сообщённый владельцем процесса:
   ежемесячно берутся займы, дефолтнувшие семь месяцев назад, проверяется DPD,
   и при шести чистых месяцах подряд дата дефолта обнуляется с проставлением
   health_date. Значит чистый прогон ЗАКАНЧИВАЕТСЯ health_date, а окно D15-G
   [health_date−6; health_date−1] захватывало последний ДЕФОЛТНЫЙ месяц.

   Арифметика отзыва: панель 184 006 строк, нулей 153 874 = 83,6 %, что равно
   5/6. У каждого счёта ровно один ненулевой месяц из шести.

   ЗДЕСЬ: § 1 измеряет сдвиг вместо того, чтобы его угадывать. § 2 пересчитывает
   классификацию на измеренном смещении. § 3 закрывает конфаундеры (закрытие,
   реструктуризация, приостановка). § 4 находит поле продукта. § 5 даёт разрезы.

   Read-only. Только SELECT. #temp с префиксом D15H_. MAXDOP 1.
   Все секции — в одном окне подряд: временные таблицы локальные.
   T-SQL (Microsoft SQL Server).
   ============================================================================= */

SET NOCOUNT ON;

DECLARE @Window int = 6;
DECLARE @Offset int = 0;   -- сдвиг окна в месяцах; § 1 показывает верное значение

/* =============================================================================
   § 0. ПОПУЛЯЦИЯ. Проверка определения до всех расчётов.

        Владелец процесса сказал: при оздоровлении дата дефолта ОБНУЛЯЕТСЯ.
        Если так, счёт с health_date может иметь default_date = NULL, и фильтр
        D15-G «default_date IS NOT NULL AND health_date IS NOT NULL» отбирал
        не всех оздоровлённых, а лишь тех, у кого дата дефолта уцелела.
        От ответа зависит знаменатель ВСЕХ ставок.
   ============================================================================= */

SELECT
      SUM(CASE WHEN default_date IS NOT NULL AND health_date IS NOT NULL THEN 1 ELSE 0 END) AS def_yes_health_yes
    , SUM(CASE WHEN default_date IS     NULL AND health_date IS NOT NULL THEN 1 ELSE 0 END) AS def_no_health_yes
    , SUM(CASE WHEN default_date IS NOT NULL AND health_date IS     NULL THEN 1 ELSE 0 END) AS def_yes_health_no
    , SUM(CASE WHEN new_default_date IS NOT NULL THEN 1 ELSE 0 END)                         AS has_new_default
    , SUM(CASE WHEN new_health_date  IS NOT NULL THEN 1 ELSE 0 END)                         AS has_new_health
    , SUM(CASE WHEN fact_close_date  IS NOT NULL THEN 1 ELSE 0 END)                         AS has_close_date
FROM [CL_PORTFOLIO].[dbo].[HISTORY_DEFAULT_ACCOUNT]
OPTION (MAXDOP 1);

-- Что лежит в type: возможно, именно он различает оздоровление и списание.
SELECT [type], COUNT(*) AS accounts
    , SUM(CASE WHEN health_date IS NOT NULL THEN 1 ELSE 0 END) AS with_health
    , SUM(CASE WHEN fact_close_date IS NOT NULL THEN 1 ELSE 0 END) AS with_close
FROM [CL_PORTFOLIO].[dbo].[HISTORY_DEFAULT_ACCOUNT]
GROUP BY [type]
ORDER BY accounts DESC
OPTION (MAXDOP 1);


/* =============================================================================
   § 1. ИЗМЕРЕНИЕ СДВИГА ОКНА. Главный контроль.

        Строим профиль DPD по месяцам ОТНОСИТЕЛЬНО health_date: k = 0 это сама
        health_date, k = 1 — месяц до неё, и так далее. Смотрим, с какого k доля
        нулей падает. Граница чистого прогона видна глазами, гадать не нужно.
   ============================================================================= */

IF OBJECT_ID('tempdb..#D15H_cured') IS NOT NULL DROP TABLE #D15H_cured;

SELECT account_number, default_date, health_date, new_default_date, fact_close_date, [type]
     -- СЕМАНТИКА ДАТ, подтверждена владельцем 27.08.2026:
     --   default_date / health_date         — САМЫЙ ПЕРВЫЙ дефолт и выход
     --   new_default_date / new_health_date — ПОСЛЕДНИЕ доступные; при выходе
     --   new_default_date ОБНУЛЯЕТСЯ и проставляется new_health_date.
     -- Отсюда «new_default_date > health_date» означает «в дефолте СЕЙЧАС»,
     -- а не «срывался когда-либо». Заём, сорвавшийся и снова вышедший, имеет
     -- new_default_date = NULL и new_health_date позже health_date.
     -- Признак срыва — движение ЛЮБОГО из двух указателей за первый выход.
     , CASE WHEN new_default_date > health_date
              OR new_health_date  > health_date THEN 1 ELSE 0 END AS redefaulted
     , CASE WHEN new_default_date > health_date THEN 1 ELSE 0 END AS in_default_now
     , CASE WHEN new_default_date > health_date
            THEN DATEDIFF(MONTH, health_date, new_default_date) END AS months_to_rd
INTO #D15H_cured
FROM [CL_PORTFOLIO].[dbo].[HISTORY_DEFAULT_ACCOUNT]
WHERE health_date IS NOT NULL      -- см. § 0: НЕ требуем непустую default_date
OPTION (MAXDOP 1);

CREATE UNIQUE CLUSTERED INDEX ix_D15H_cured ON #D15H_cured(account_number);

IF OBJECT_ID('tempdb..#D15H_prof') IS NOT NULL DROP TABLE #D15H_prof;

SELECT
      c.account_number
    , DATEDIFF(MONTH, CAST(v.snap_date AS date), c.health_date) AS k
    , TRY_CAST(v.dpd_raw AS int)                                AS dpd
INTO #D15H_prof
FROM #D15H_cured c
INNER JOIN [CL_PORTFOLIO].[dbo].[HISTORY_DEFAULT_ACCOUNT] h
        ON h.account_number = c.account_number
CROSS APPLY (VALUES
        ('2012-02-01', h.['01.02.2012']), ('2012-03-01', h.['01.03.2012']),
        ('2012-04-01', h.['01.04.2012']), ('2012-05-01', h.['01.05.2012']),
        ('2012-06-01', h.['01.06.2012']), ('2012-07-01', h.['01.07.2012']),
        ('2012-08-01', h.['01.08.2012']), ('2012-09-01', h.['01.09.2012']),
        ('2012-10-01', h.['01.10.2012']), ('2012-11-01', h.['01.11.2012']),
        ('2012-12-01', h.['01.12.2012']), ('2013-01-01', h.['01.01.2013']),
        ('2013-02-01', h.['01.02.2013']), ('2013-03-01', h.['01.03.2013']),
        ('2013-04-01', h.['01.04.2013']), ('2013-05-01', h.['01.05.2013']),
        ('2013-06-01', h.['01.06.2013']), ('2013-07-01', h.['01.07.2013']),
        ('2013-08-01', h.['01.08.2013']), ('2013-09-01', h.['01.09.2013']),
        ('2013-10-01', h.['01.10.2013']), ('2013-11-01', h.['01.11.2013']),
        ('2013-12-01', h.['01.12.2013']), ('2014-01-01', h.['01.01.2014']),
        ('2014-02-01', h.['01.02.2014']), ('2014-03-01', h.['01.03.2014']),
        ('2014-04-01', h.['01.04.2014']), ('2014-05-01', h.['01.05.2014']),
        ('2014-06-01', h.['01.06.2014']), ('2014-07-01', h.['01.07.2014']),
        ('2014-08-01', h.['01.08.2014']), ('2014-09-01', h.['01.09.2014']),
        ('2014-10-01', h.['01.10.2014']), ('2014-11-01', h.['01.11.2014']),
        ('2014-12-01', h.['01.12.2014']), ('2015-01-01', h.['01.01.2015']),
        ('2015-02-01', h.['01.02.2015']), ('2015-03-01', h.['01.03.2015']),
        ('2015-04-01', h.['01.04.2015']), ('2015-05-01', h.['01.05.2015']),
        ('2015-06-01', h.['01.06.2015']), ('2015-07-01', h.['01.07.2015']),
        ('2015-08-01', h.['01.08.2015']), ('2015-09-01', h.['01.09.2015']),
        ('2015-10-01', h.['01.10.2015']), ('2015-11-01', h.['01.11.2015']),
        ('2015-12-01', h.['01.12.2015']), ('2016-01-01', h.['01.01.2016']),
        ('2016-02-01', h.['01.02.2016']), ('2016-03-01', h.['01.03.2016']),
        ('2016-04-01', h.['01.04.2016']), ('2016-05-01', h.['01.05.2016']),
        ('2016-06-01', h.['01.06.2016']), ('2016-07-01', h.['01.07.2016']),
        ('2016-08-01', h.['01.08.2016']), ('2016-09-01', h.['01.09.2016']),
        ('2016-10-01', h.['01.10.2016']), ('2016-11-01', h.['01.11.2016']),
        ('2016-12-01', h.['01.12.2016']), ('2017-01-01', h.['01.01.2017']),
        ('2017-02-01', h.['01.02.2017']), ('2017-03-01', h.['01.03.2017']),
        ('2017-04-01', h.['01.04.2017']), ('2017-05-01', h.['01.05.2017']),
        ('2017-06-01', h.['01.06.2017']), ('2017-07-01', h.['01.07.2017']),
        ('2017-08-01', h.['01.08.2017']), ('2017-09-01', h.['01.09.2017']),
        ('2017-10-01', h.['01.10.2017']), ('2017-11-01', h.['01.11.2017']),
        ('2017-12-01', h.['01.12.2017']), ('2018-01-01', h.['01.01.2018']),
        ('2018-02-01', h.['01.02.2018']), ('2018-03-01', h.['01.03.2018']),
        ('2018-04-01', h.['01.04.2018']), ('2018-05-01', h.['01.05.2018']),
        ('2018-06-01', h.['01.06.2018']), ('2018-07-01', h.['01.07.2018']),
        ('2018-08-01', h.['01.08.2018']), ('2018-09-01', h.['01.09.2018']),
        ('2018-10-01', h.['01.10.2018']), ('2018-11-01', h.['01.11.2018']),
        ('2018-12-01', h.['01.12.2018']), ('2019-01-01', h.['01.01.2019']),
        ('2019-02-01', h.['01.02.2019']), ('2019-03-01', h.['01.03.2019']),
        ('2019-04-01', h.['01.04.2019']), ('2019-05-01', h.['01.05.2019']),
        ('2019-06-01', h.['01.06.2019']), ('2019-07-01', h.['01.07.2019']),
        ('2019-08-01', h.['01.08.2019']), ('2019-09-01', h.['01.09.2019']),
        ('2019-10-01', h.['01.10.2019']), ('2019-11-01', h.['01.11.2019']),
        ('2019-12-01', h.['01.12.2019']), ('2020-01-01', h.['01.01.2020']),
        ('2020-02-01', h.['01.02.2020']), ('2020-03-01', h.['01.03.2020']),
        ('2020-04-01', h.['01.04.2020']), ('2020-05-01', h.['01.05.2020']),
        ('2020-06-01', h.['01.06.2020']), ('2020-07-01', h.['01.07.2020']),
        ('2020-08-01', h.['01.08.2020']), ('2020-09-01', h.['01.09.2020']),
        ('2020-10-01', h.['01.10.2020']), ('2020-11-01', h.['01.11.2020']),
        ('2020-12-01', h.['01.12.2020']), ('2021-01-01', h.['01.01.2021']),
        ('2021-02-01', h.['01.02.2021']), ('2021-03-01', h.['01.03.2021']),
        ('2021-04-01', h.['01.04.2021']), ('2021-05-01', h.['01.05.2021']),
        ('2021-06-01', h.['01.06.2021']), ('2021-07-01', h.['01.07.2021']),
        ('2021-08-01', h.['01.08.2021']), ('2021-09-01', h.['01.09.2021']),
        ('2021-10-01', h.['01.10.2021']), ('2021-11-01', h.['01.11.2021']),
        ('2021-12-01', h.['01.12.2021']), ('2022-01-01', h.['01.01.2022']),
        ('2022-02-01', h.['01.02.2022']), ('2022-03-01', h.['01.03.2022']),
        ('2022-04-01', h.['01.04.2022']), ('2022-05-01', h.['01.05.2022']),
        ('2022-06-01', h.['01.06.2022']), ('2022-07-01', h.['01.07.2022']),
        ('2022-08-01', h.['01.08.2022']), ('2022-09-01', h.['01.09.2022']),
        ('2022-10-01', h.['01.10.2022']), ('2022-11-01', h.['01.11.2022']),
        ('2022-12-01', h.['01.12.2022']), ('2023-01-01', h.['01.01.2023']),
        ('2023-02-01', h.['01.02.2023']), ('2023-03-01', h.['01.03.2023']),
        ('2023-04-01', h.['01.04.2023']), ('2023-05-01', h.['01.05.2023']),
        ('2023-06-01', h.['01.06.2023']), ('2023-07-01', h.['01.07.2023']),
        ('2023-08-01', h.['01.08.2023']), ('2023-09-01', h.['01.09.2023']),
        ('2023-10-01', h.['01.10.2023']), ('2023-11-01', h.['01.11.2023']),
        ('2023-12-01', h.['01.12.2023']), ('2024-01-01', h.['01.01.2024']),
        ('2024-02-01', h.['01.02.2024']), ('2024-03-01', h.['01.03.2024']),
        ('2024-04-01', h.['01.04.2024']), ('2024-05-01', h.['01.05.2024']),
        ('2024-06-01', h.['01.06.2024']), ('2024-07-01', h.['01.07.2024']),
        ('2024-08-01', h.['01.08.2024']), ('2024-09-01', h.['01.09.2024']),
        ('2024-10-01', h.['01.10.2024']), ('2024-11-01', h.['01.11.2024']),
        ('2024-12-01', h.['01.12.2024']), ('2025-01-01', h.['01.01.2025']),
        ('2025-02-01', h.['01.02.2025']), ('2025-03-01', h.['01.03.2025']),
        ('2025-04-01', h.['01.04.2025']), ('2025-05-01', h.['01.05.2025']),
        ('2025-06-01', h.['01.06.2025']), ('2025-07-01', h.['01.07.2025']),
        ('2025-08-01', h.['01.08.2025']), ('2025-09-01', h.['01.09.2025']),
        ('2025-10-01', h.['01.10.2025']), ('2025-11-01', h.['01.11.2025']),
        ('2025-12-01', h.['01.12.2025']), ('2026-01-01', h.['01.01.2026']),
        ('2026-02-01', h.['01.02.2026']), ('2026-03-01', h.['01.03.2026']),
        ('2026-04-01', h.['01.04.2026']), ('2026-05-01', h.['01.05.2026']),
        ('2026-06-01', h.['01.06.2026']), ('2026-07-01', h.['01.07.2026']),
        ('2026-08-01', h.['01.08.2026'])
) v(snap_date, dpd_raw)
WHERE DATEDIFF(MONTH, CAST(v.snap_date AS date), c.health_date) BETWEEN -2 AND 9
  AND v.dpd_raw IS NOT NULL
OPTION (MAXDOP 1);

CREATE CLUSTERED INDEX ix_D15H_prof ON #D15H_prof(account_number, k);

-- 1a. ПРОФИЛЬ. Читать сверху вниз: k = 0 это сама health_date.
--     Чистый прогон — те k, где доля нулей близка к единице.
--     Первый k с заметной долей ненулевых и есть граница окна.
SELECT
      k
    , COUNT(*)                                                     AS rows_cnt
    , SUM(CASE WHEN dpd = 0 THEN 1 ELSE 0 END)                     AS zero_rows
    , CAST(100.0 * SUM(CASE WHEN dpd = 0 THEN 1 ELSE 0 END)
           / NULLIF(COUNT(*),0) AS decimal(5,2))                   AS zero_pct
    , CAST(AVG(CAST(dpd AS float)) AS decimal(9,1))                AS avg_dpd
    , MAX(dpd)                                                     AS max_dpd
FROM #D15H_prof
GROUP BY k
ORDER BY k
OPTION (MAXDOP 1);


/* =============================================================================
   § 2. КЛАССИФИКАЦИЯ НА ИЗМЕРЕННОМ ОКНЕ.
        @Offset выставить по § 1а. Если чистый прогон это k = 0…5, то @Offset = 0
        и окно k BETWEEN @Offset AND @Offset + @Window − 1.
   ============================================================================= */

IF OBJECT_ID('tempdb..#D15H_class') IS NOT NULL DROP TABLE #D15H_class;

SELECT
      p.account_number
    , COUNT(*)                                   AS months_obs
    , MAX(p.dpd)                                 AS dpd_max
INTO #D15H_class
FROM #D15H_prof p
WHERE p.k BETWEEN @Offset AND @Offset + @Window - 1
GROUP BY p.account_number
OPTION (MAXDOP 1);

CREATE UNIQUE CLUSTERED INDEX ix_D15H_class ON #D15H_class(account_number);

-- 2a. Контроль: теперь группа strict должна быть НЕПУСТОЙ. Если снова пуста —
--     смещение выбрано неверно, вернуться к § 1а.
SELECT
      CASE WHEN months_obs < @Window THEN 'incomplete'
           WHEN dpd_max = 0         THEN 'strict'
           WHEN dpd_max <= 15       THEN 'soft'
           ELSE                          'neither' END AS rule_group
    , COUNT(*)                                         AS accounts
    , MIN(dpd_max)                                     AS min_of_max
    , CAST(AVG(CAST(dpd_max AS float)) AS decimal(9,1)) AS avg_dpd_max
FROM #D15H_class
GROUP BY
      CASE WHEN months_obs < @Window THEN 'incomplete'
           WHEN dpd_max = 0         THEN 'strict'
           WHEN dpd_max <= 15       THEN 'soft'
           ELSE                          'neither' END
ORDER BY rule_group
OPTION (MAXDOP 1);


/* =============================================================================
   § 3. КОНФАУНДЕРЫ. Закрытые, реструктурированные, приостановленные.

        Приостановленный заём показывает DPD = 0 всё время приостановки и
        проходит любой критерий чистоты, не платя ничего. Это прямая угроза
        всему расчёту: такие счета надо не «учесть», а ИСКЛЮЧИТЬ.
   ============================================================================= */

-- 3a. Закрытие. fact_close_date есть в самой базе дефолтов.
--     Заём, закрытый ВНУТРИ окна наблюдения, оздоровлением не является.
SELECT
      CASE WHEN c.fact_close_date IS NULL THEN 'открыт'
           WHEN c.fact_close_date <  c.health_date THEN 'закрыт ДО оздоровления'
           WHEN c.fact_close_date <= DATEADD(MONTH, 12, c.health_date)
                THEN 'закрыт в течение 12 мес. после'
           ELSE 'закрыт позже' END               AS close_status
    , COUNT(*)                                   AS accounts
    , SUM(c.redefaulted)                         AS redefaulted
FROM #D15H_cured c
GROUP BY
      CASE WHEN c.fact_close_date IS NULL THEN 'открыт'
           WHEN c.fact_close_date <  c.health_date THEN 'закрыт ДО оздоровления'
           WHEN c.fact_close_date <= DATEADD(MONTH, 12, c.health_date)
                THEN 'закрыт в течение 12 мес. после'
           ELSE 'закрыт позже' END
ORDER BY accounts DESC
OPTION (MAXDOP 1);

-- 3b. Реструктуризация. Источник — [IFRS9].[dbo].[KAN_20260601_for_LGD_Fenix],
--     колонка [дата окончания реструктуры] (подтверждена sql/stage3_cure_pool.sql).
SELECT
      CASE WHEN r.[дата окончания реструктуры] IS NULL THEN 'без реструктуризации'
           ELSE 'реструктурирован' END           AS restr_status
    , COUNT(*)                                   AS accounts
    , SUM(c.redefaulted)                         AS redefaulted
FROM #D15H_cured c
LEFT JOIN [IFRS9].[dbo].[KAN_20260601_for_LGD_Fenix] r
       ON r.account_number = c.account_number
GROUP BY CASE WHEN r.[дата окончания реструктуры] IS NULL THEN 'без реструктуризации'
              ELSE 'реструктурирован' END
OPTION (MAXDOP 1);

-- 3c. ПРИОСТАНОВКА. Поле не найдено ни в одном скрипте репозитория
--     (sql/stage3_raw_extract.sql § 4 фиксирует это как открытый пункт).
--     Поиск по обеим базам. Пока поле не найдено, приостановленные счета
--     из расчёта НЕ исключены, и об этом надо говорить прямо.
SELECT 'CL_PORTFOLIO' AS db, TABLE_NAME, COLUMN_NAME, DATA_TYPE
FROM [CL_PORTFOLIO].INFORMATION_SCHEMA.COLUMNS
WHERE COLUMN_NAME LIKE N'%приостан%' OR COLUMN_NAME LIKE N'%suspend%'
   OR COLUMN_NAME LIKE N'%моратор%'  OR COLUMN_NAME LIKE N'%morator%'
   OR COLUMN_NAME LIKE N'%freeze%'   OR COLUMN_NAME LIKE N'%заморож%'
UNION ALL
SELECT 'IFRS9', TABLE_NAME, COLUMN_NAME, DATA_TYPE
FROM [IFRS9].INFORMATION_SCHEMA.COLUMNS
WHERE COLUMN_NAME LIKE N'%приостан%' OR COLUMN_NAME LIKE N'%suspend%'
   OR COLUMN_NAME LIKE N'%моратор%'  OR COLUMN_NAME LIKE N'%morator%'
ORDER BY db, TABLE_NAME, COLUMN_NAME;

-- 3d. Косвенный признак приостановки, работающий БЕЗ поля.
--     У платящего заёмщика баланс убывает. У приостановленного DPD = 0
--     при неизменном балансе. Считаем счета с чистым окном и НУЛЕВЫМ
--     изменением баланса за период — это кандидаты в приостановленные.
SELECT
      CASE WHEN b.bal_first IS NULL OR b.bal_last IS NULL THEN 'нет данных баланса'
           WHEN b.bal_first = b.bal_last                  THEN 'баланс НЕ менялся — подозрение на приостановку'
           WHEN b.bal_last < b.bal_first                  THEN 'баланс убывал — платежи шли'
           ELSE 'баланс рос' END                AS balance_behaviour
    , COUNT(*)                                  AS accounts
FROM #D15H_class k
CROSS APPLY (
    SELECT
          MIN(CASE WHEN rn_first = 1 THEN balance END) AS bal_first
        , MIN(CASE WHEN rn_last  = 1 THEN balance END) AS bal_last
    FROM (
        SELECT p.[balance]
             , ROW_NUMBER() OVER (ORDER BY p.[date] ASC)  AS rn_first
             , ROW_NUMBER() OVER (ORDER BY p.[date] DESC) AS rn_last
        FROM [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2] p
        INNER JOIN #D15H_cured c2 ON c2.account_number = k.account_number
        WHERE p.contract_number = k.account_number
          AND p.[date] BETWEEN DATEADD(MONTH, -(@Window-1), c2.health_date) AND c2.health_date
    ) x
) b
WHERE k.dpd_max = 0
GROUP BY
      CASE WHEN b.bal_first IS NULL OR b.bal_last IS NULL THEN 'нет данных баланса'
           WHEN b.bal_first = b.bal_last                  THEN 'баланс НЕ менялся — подозрение на приостановку'
           WHEN b.bal_last < b.bal_first                  THEN 'баланс убывал — платежи шли'
           ELSE 'баланс рос' END
OPTION (MAXDOP 1);


/* =============================================================================
   § 4. ПОИСК ПОЛЯ ПРОДУКТА. Разрезы без него построить нельзя.
        В контуре risk_dwh_reconciliation встречались l_product_type
        и l_subproduct_type, но в ДРУГОЙ базе. В CL_PORTFOLIO_2 состав
        подтверждён только по шести колонкам. Ищем.
   ============================================================================= */

SELECT COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH
FROM [CL_PORTFOLIO].INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'CL_PORTFOLIO_2'
ORDER BY ORDINAL_POSITION;

-- Ключевые слова по обеим базам: продукт, портфель, сегмент, тип займа.
SELECT 'CL_PORTFOLIO' AS db, TABLE_NAME, COLUMN_NAME, DATA_TYPE
FROM [CL_PORTFOLIO].INFORMATION_SCHEMA.COLUMNS
WHERE COLUMN_NAME LIKE N'%product%'   OR COLUMN_NAME LIKE N'%продукт%'
   OR COLUMN_NAME LIKE N'%portfolio%' OR COLUMN_NAME LIKE N'%портфел%'
   OR COLUMN_NAME LIKE N'%segment%'   OR COLUMN_NAME LIKE N'%сегмент%'
   OR COLUMN_NAME LIKE N'%loan_type%' OR COLUMN_NAME LIKE N'%тип%'
UNION ALL
SELECT 'IFRS9', TABLE_NAME, COLUMN_NAME, DATA_TYPE
FROM [IFRS9].INFORMATION_SCHEMA.COLUMNS
WHERE COLUMN_NAME LIKE N'%product%'   OR COLUMN_NAME LIKE N'%продукт%'
   OR COLUMN_NAME LIKE N'%portfolio%' OR COLUMN_NAME LIKE N'%портфел%'
   OR COLUMN_NAME LIKE N'%segment%'   OR COLUMN_NAME LIKE N'%сегмент%'
ORDER BY db, TABLE_NAME, COLUMN_NAME;


/* =============================================================================
   § 5. РАЗРЕЗЫ ПО ПРОДУКТУ И ПОРОГУ. Запускать ПОСЛЕ § 4.

        Подставить найденное поле вместо <ПРОДУКТ> в двух местах. Даёт матрицу
        «продукт × порог 0…30» — сколько займов проходит и какова ставка срыва.
        Из неё видно, одинаков ли порог для всех продуктов или его надо
        дифференцировать.

        Второй прогон — по сегментации НСТ: вместо <ПРОДУКТ> подставляется
        сегмент из контура nst_credit. Соединение по договору; правила
        сегментации — RULES в docs/analysis/nst_credit/nst_fill_2026.py.

SELECT
      pr.<ПРОДУКТ>                               AS product
    , t.thr                                      AS soft_threshold
    , SUM(CASE WHEN k.dpd_max <= t.thr THEN 1 ELSE 0 END)               AS cured_pass
    , SUM(CASE WHEN k.dpd_max <= t.thr THEN c.redefaulted ELSE 0 END)   AS redefaulted
    , CAST(100.0 * SUM(CASE WHEN k.dpd_max <= t.thr THEN c.redefaulted ELSE 0 END)
           / NULLIF(SUM(CASE WHEN k.dpd_max <= t.thr THEN 1 ELSE 0 END),0)
           AS decimal(5,2))                                             AS rd_rate_pct
FROM #D15H_class k
INNER JOIN #D15H_cured c ON c.account_number = k.account_number
INNER JOIN (
    SELECT DISTINCT contract_number, <ПРОДУКТ>
    FROM [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2]
) pr ON pr.contract_number = k.account_number
CROSS JOIN (VALUES (0),(5),(10),(15),(20),(25),(30)) t(thr)
WHERE k.months_obs >= @Window
GROUP BY pr.<ПРОДУКТ>, t.thr
HAVING SUM(CASE WHEN k.dpd_max <= t.thr THEN 1 ELSE 0 END) >= 100   -- клетки меньше 100 не публикуются
ORDER BY product, soft_threshold;

        ПРАВИЛО, УТВЕРЖДАЕМОЕ ДО РАСЧЁТА: клетка с числом займов менее 100
        не публикуется, а укрупняется. Иначе разрез по продуктам произведёт
        десяток «находок» на выборках по двадцать договоров.
   ============================================================================= */
