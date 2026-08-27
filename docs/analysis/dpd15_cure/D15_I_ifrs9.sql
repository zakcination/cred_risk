/* =============================================================================
   D15-I. Аудит [IFRS9].[dbo].[KAN_20260601_for_LGD_Fenix] — источника PD и LGD.

   ЧТО О НЕЙ ИЗВЕСТНО НА СЕЙЧАС. Четыре колонки, и те из чужого скрипта
   (sql/stage3_cure_pool.sql): account_number, default_date, health_date2,
   [дата окончания реструктуры]. Состав, зернистость, охват и актуальность
   НЕ ПРОВЕРЕНЫ НИ РАЗУ. Поэтому здесь аудит, а не расчёт.

   ДВЕ ПРИЧИНЫ, ПО КОТОРЫМ ЭТА ТАБЛИЦА ВАЖНЕЕ ОСТАЛЬНЫХ ДЛЯ КОНТУРА.

   Первая. Модели PD строятся по сегментам, значит поле продукта или сегмента
   здесь почти наверняка есть — а в CL_PORTFOLIO_2 его нет. Разрезы, которые
   нужны (продуктовое деление AQR и сегментация НСТ), строятся отсюда.

   Вторая, и она весомее. В таблице лежит СВОЯ default_date. Если она
   расходится с датой из HISTORY_DEFAULT_ACCOUNT, значит определение дефолта
   в модели PD и в учёте провизий разное. Это Н5 и Н8 контура, и требование
   единого определения прямое: МСФО 9 п. B5.5.37 и Правила № 86 в части
   методологии PD-модели. Расхождение — не наша находка про оздоровление,
   а самостоятельный дефект, который всплывёт при первой валидации модели.

   РИСК, КОТОРЫЙ НАДО ДЕРЖАТЬ В ГОЛОВЕ. Имя «KAN_20260601_for_LGD_Fenix»
   читается как разовая рабочая выгрузка под конкретный расчёт LGD на 01.06.2026,
   а не как поддерживаемый источник. Строить на ней постоянную отчётность
   нельзя, пока не подтверждено, что она пересобирается. § 1 это проверяет.

   Read-only. Только SELECT. #temp с префиксом D15I_. MAXDOP 1.
   T-SQL (Microsoft SQL Server).
   ============================================================================= */

SET NOCOUNT ON;

/* =============================================================================
   § 0. СОСТАВ И ЗЕРНИСТОСТЬ. Прогнать первым, прочитать глазами.
   ============================================================================= */

-- 0a. Все колонки. Ожидается, что среди них найдутся сегмент, продукт,
--     возмещения и обеспечение — то, ради чего таблица существует.
SELECT COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH, IS_NULLABLE, ORDINAL_POSITION
FROM [IFRS9].INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'KAN_20260601_for_LGD_Fenix'
ORDER BY ORDINAL_POSITION;

-- 0b. ЗЕРНИСТОСТЬ. Не проверялась ни разу, а от неё зависит, можно ли
--     соединять напрямую. Если строк на счёт больше одной — любое соединение
--     без свёртки размножит наши 31 тыс. оздоровлённых.
SELECT
      SUM(CAST(rows_per_account AS bigint))       AS rows_total
    , COUNT(*)                                    AS accounts
    , MAX(rows_per_account)                       AS max_rows_per_account
    , SUM(CASE WHEN rows_per_account > 1 THEN 1 ELSE 0 END) AS accounts_with_many
FROM (
    SELECT account_number, COUNT(*) AS rows_per_account
    FROM [IFRS9].[dbo].[KAN_20260601_for_LGD_Fenix]
    GROUP BY account_number
) g
OPTION (MAXDOP 1);

-- 0c. Если строк на счёт больше одной — что их различает. Смотрим руками
--     на счета с максимальным числом строк, ДО того как строить свёртку.
SELECT TOP 50 *
FROM [IFRS9].[dbo].[KAN_20260601_for_LGD_Fenix]
WHERE account_number IN (
    SELECT TOP 5 account_number
    FROM [IFRS9].[dbo].[KAN_20260601_for_LGD_Fenix]
    GROUP BY account_number
    HAVING COUNT(*) > 1
    ORDER BY COUNT(*) DESC
)
ORDER BY account_number;


/* =============================================================================
   § 1. АКТУАЛЬНОСТЬ. Разовая выгрузка или поддерживаемый источник.

        Если максимальная дата в таблице упирается в 01.06.2026 из её имени —
        это снимок, и на нём нельзя строить ничего, что должно обновляться.
        Тогда нужен вопрос владельцу: пересобирается ли она и под каким именем.
   ============================================================================= */

SELECT
      MIN(default_date)                           AS default_date_min
    , MAX(default_date)                           AS default_date_max
    , MIN(health_date2)                           AS health2_min
    , MAX(health_date2)                           AS health2_max
    , MIN([дата окончания реструктуры])           AS restr_end_min
    , MAX([дата окончания реструктуры])           AS restr_end_max
    , COUNT(*)                                    AS rows_total
FROM [IFRS9].[dbo].[KAN_20260601_for_LGD_Fenix]
OPTION (MAXDOP 1);

-- Есть ли рядом более свежие однотипные таблицы: KAN_%_for_LGD_% и подобные.
SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE
FROM [IFRS9].INFORMATION_SCHEMA.TABLES
WHERE TABLE_NAME LIKE 'KAN%' OR TABLE_NAME LIKE '%LGD%' OR TABLE_NAME LIKE '%PD%'
ORDER BY TABLE_NAME;


/* =============================================================================
   § 2. ОХВАТ. Накрывает ли таблица нашу популяцию.
        Если оздоровлённых в ней сильно меньше 31 тысячи — разрезы по продукту
        будут строиться на подвыборке, и это надо знать заранее, а не потом.
   ============================================================================= */

IF OBJECT_ID('tempdb..#D15I_cured') IS NOT NULL DROP TABLE #D15I_cured;

SELECT account_number, default_date, health_date, new_default_date, new_health_date
INTO #D15I_cured
FROM [CL_PORTFOLIO].[dbo].[HISTORY_DEFAULT_ACCOUNT]
WHERE health_date IS NOT NULL
OPTION (MAXDOP 1);

CREATE UNIQUE CLUSTERED INDEX ix_D15I_cured ON #D15I_cured(account_number);

SELECT
      COUNT(*)                                                    AS cured_in_base
    , SUM(CASE WHEN f.account_number IS NOT NULL THEN 1 ELSE 0 END) AS matched_in_ifrs9
    , CAST(100.0 * SUM(CASE WHEN f.account_number IS NOT NULL THEN 1 ELSE 0 END)
           / NULLIF(COUNT(*),0) AS decimal(5,2))                  AS coverage_pct
FROM #D15I_cured c
LEFT JOIN (
    SELECT DISTINCT account_number FROM [IFRS9].[dbo].[KAN_20260601_for_LGD_Fenix]
) f ON f.account_number = c.account_number
OPTION (MAXDOP 1);


/* =============================================================================
   § 3. ЕДИНОЕ ОПРЕДЕЛЕНИЕ ДЕФОЛТА. Н5 и Н8 контура.

        МСФО 9 п. B5.5.37 требует, чтобы определение дефолта было согласованным
        и совпадало с применяемым во внутреннем управлении кредитным риском.
        Правила № 86 требуют того же от методологии PD-модели.

        Здесь это проверяется в одну строку: совпадает ли дата дефолта
        в PD/LGD-источнике с датой в базе дефолтов.
   ============================================================================= */

SELECT
      COUNT(*)                                                          AS matched_accounts
    , SUM(CASE WHEN f.default_date = c.default_date THEN 1 ELSE 0 END)  AS date_equal
    , SUM(CASE WHEN f.default_date <> c.default_date THEN 1 ELSE 0 END) AS date_differ
    , SUM(CASE WHEN f.default_date IS NULL AND c.default_date IS NOT NULL THEN 1 ELSE 0 END) AS ifrs9_null_only
    , SUM(CASE WHEN f.default_date IS NOT NULL AND c.default_date IS NULL THEN 1 ELSE 0 END) AS base_null_only
    , MIN(DATEDIFF(DAY, c.default_date, f.default_date))                AS diff_days_min
    , MAX(DATEDIFF(DAY, c.default_date, f.default_date))                AS diff_days_max
FROM #D15I_cured c
INNER JOIN (
    SELECT account_number, MIN(default_date) AS default_date, MIN(health_date2) AS health_date2
    FROM [IFRS9].[dbo].[KAN_20260601_for_LGD_Fenix]
    GROUP BY account_number      -- свёртка до проверки зернистости § 0b
) f ON f.account_number = c.account_number
OPTION (MAXDOP 1);

-- 3a. Если расхождения есть — их распределение по величине. Сдвиг на один
--     месяц у всех означает разное правило округления даты; разнобой
--     означает разные определения события.
SELECT
      CASE WHEN DATEDIFF(DAY, c.default_date, f.default_date) = 0 THEN '0  совпадает'
           WHEN ABS(DATEDIFF(DAY, c.default_date, f.default_date)) <= 31  THEN 'до месяца'
           WHEN ABS(DATEDIFF(DAY, c.default_date, f.default_date)) <= 93  THEN '1-3 месяца'
           WHEN ABS(DATEDIFF(DAY, c.default_date, f.default_date)) <= 366 THEN '3-12 месяцев'
           ELSE 'более года' END                  AS diff_bucket
    , COUNT(*)                                    AS accounts
FROM #D15I_cured c
INNER JOIN (
    SELECT account_number, MIN(default_date) AS default_date
    FROM [IFRS9].[dbo].[KAN_20260601_for_LGD_Fenix] GROUP BY account_number
) f ON f.account_number = c.account_number
WHERE c.default_date IS NOT NULL AND f.default_date IS NOT NULL
GROUP BY
      CASE WHEN DATEDIFF(DAY, c.default_date, f.default_date) = 0 THEN '0  совпадает'
           WHEN ABS(DATEDIFF(DAY, c.default_date, f.default_date)) <= 31  THEN 'до месяца'
           WHEN ABS(DATEDIFF(DAY, c.default_date, f.default_date)) <= 93  THEN '1-3 месяца'
           WHEN ABS(DATEDIFF(DAY, c.default_date, f.default_date)) <= 366 THEN '3-12 месяцев'
           ELSE 'более года' END
ORDER BY accounts DESC
OPTION (MAXDOP 1);

-- 3b. То же по датам выхода: health_date2 против health_date.
--     Расхождение здесь означает, что оздоровление в модели и в учёте
--     наступает в разные моменты — при том, что это одно и то же событие.
SELECT
      CASE WHEN f.health_date2 = c.health_date THEN 'совпадает'
           WHEN f.health_date2 IS NULL         THEN 'в IFRS9 пусто'
           WHEN c.health_date  IS NULL         THEN 'в базе пусто'
           ELSE 'расходится' END                  AS health_match
    , COUNT(*)                                    AS accounts
FROM #D15I_cured c
INNER JOIN (
    SELECT account_number, MIN(health_date2) AS health_date2
    FROM [IFRS9].[dbo].[KAN_20260601_for_LGD_Fenix] GROUP BY account_number
) f ON f.account_number = c.account_number
GROUP BY
      CASE WHEN f.health_date2 = c.health_date THEN 'совпадает'
           WHEN f.health_date2 IS NULL         THEN 'в IFRS9 пусто'
           WHEN c.health_date  IS NULL         THEN 'в базе пусто'
           ELSE 'расходится' END
ORDER BY accounts DESC
OPTION (MAXDOP 1);


/* =============================================================================
   § 4. ПОЛЯ ПРОДУКТА, СЕГМЕНТА И LGD.
        Модели PD строятся по сегментам, значит поле сегмента здесь должно быть.
        Это и есть источник разрезов, которых нет в CL_PORTFOLIO_2.
   ============================================================================= */

SELECT COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH
FROM [IFRS9].INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'KAN_20260601_for_LGD_Fenix'
  AND ( COLUMN_NAME LIKE N'%product%'   OR COLUMN_NAME LIKE N'%продукт%'
     OR COLUMN_NAME LIKE N'%segment%'   OR COLUMN_NAME LIKE N'%сегмент%'
     OR COLUMN_NAME LIKE N'%portfolio%' OR COLUMN_NAME LIKE N'%портфел%'
     OR COLUMN_NAME LIKE N'%pool%'      OR COLUMN_NAME LIKE N'%тип%'
     OR COLUMN_NAME LIKE N'%lgd%'       OR COLUMN_NAME LIKE N'%pd%'
     OR COLUMN_NAME LIKE N'%recover%'   OR COLUMN_NAME LIKE N'%возврат%'
     OR COLUMN_NAME LIKE N'%collat%'    OR COLUMN_NAME LIKE N'%залог%'
     OR COLUMN_NAME LIKE N'%ead%'       OR COLUMN_NAME LIKE N'%exposure%' )
ORDER BY ORDINAL_POSITION;

-- 4a. ШАБЛОН распределения по найденному полю. Подставить имя вместо <СЕГМЕНТ>
--     и раскомментировать. Даёт список значений и их вес — из него станет
--     видно, соответствует ли поле продуктовому делению AQR или сегментации НСТ,
--     либо это третья, своя классификация.
--
-- SELECT <СЕГМЕНТ> AS segment, COUNT(*) AS rows_cnt,
--        COUNT(DISTINCT account_number) AS accounts
-- FROM [IFRS9].[dbo].[KAN_20260601_for_LGD_Fenix]
-- GROUP BY <СЕГМЕНТ>
-- ORDER BY accounts DESC;


/* =============================================================================
   § 5. ЧТО ДЕЛАТЬ ПОСЛЕ АУДИТА — порядок, а не код.

     1. § 0b показал зернистость. Если строк на счёт больше одной — до любого
        соединения построить свёртку и записать правило свёртки в контур.
        Соединять таблицу с неизвестной зернистостью нельзя: в этом репозитории
        уже была отозванная находка ровно по этой причине (PR #14 -> #15).

     2. § 1 показал актуальность. Если это снимок на 01.06.2026 — задать
        владельцу два вопроса: пересобирается ли выгрузка и под каким именем
        лежит текущая. До ответа таблица годится для разового исследования
        и не годится для регулярного расчёта.

     3. § 3 дал ответ по единству определения дефолта. Если расхождение
        значимо — это ОТДЕЛЬНАЯ находка контура, не связанная с оздоровлением,
        и она сильнее нашей: МСФО 9 B5.5.37 и № 86 требуют единого определения
        прямо. Оформлять её надо отдельно и не смешивать с запиской по правке.

     4. § 4 дал поле сегмента. Разрезы «продукт × порог 0…30» строятся
        в § 5 D15_H_controls.sql подстановкой этого поля, с правилом
        минимальной клетки в 100 займов, утверждённым ДО расчёта.
   ============================================================================= */
