/* =============================================================================
   D15-J. Разрезы по продуктам и порогу; определение дефолта в PD/LGD-модели.

   ЧТО ДАЛ АУДИТ D15-I 27.08.2026 И ЧТО ИЗ ЭТОГО СЛЕДУЕТ.

   1. ТАБЛИЦА ПЕРЕСОБИРАЕТСЯ ЕЖЕМЕСЯЧНО. В IFRS9 лежит полный ряд
      KAN_YYYYMMDD_for_LGD_Fenix с парным KAN_YYYYMMDD_restructura, и самая
      свежая — KAN_20260801_for_LGD_Fenix. Мы работали на снимке двухмесячной
      давности. Риск «разовая выгрузка» снят, но актуальную таблицу надо брать
      по имени, а не фиксировать в коде — см. @Snap ниже.

   2. ПОЛЕ ПРОДУКТА НАЙДЕНО: subproduct nvarchar(50), пример значения «POS».
      Есть и более дробный TARIFF («POS Soft Grace 36-60»). Рядом лежат
      KAN_PD_LGD_Product_Basket и KAN_contract_basket — вероятная привязка
      продукта к корзине AQR, § 0b проверяет.

   3. FIRST_PAYMENT_DATE ЗАКРЫВАЕТ ДЫРУ D15-F § 3. День планового платежа
      выводится как DAY(FIRST_PAYMENT_DATE) для ВСЕХ договоров, включая
      непросроченные. Значит знаменатель для «доли просроченных по дню платежа»
      есть, и repayment_schedule для этого больше не нужен.

   4. TRIGGER-КОЛОНКИ — ЭТО И ЕСТЬ ОПРЕДЕЛЕНИЕ ДЕФОЛТА В МОДЕЛИ:
      trigger_первый, trigger_последующий, [trigger на тек дату],
      значения вида «91+», «POCI». Сравнивать надо их с нашим признаком
      обесценения, а не даты. Это прямее и однозначнее.

   5. ПОЧЕМУ РАСХОЖДЕНИЕ ДАТ ЕЩЁ НЕ ЯВЛЯЕТСЯ НАХОДКОЙ. § 3 D15-I дал: совпало
      5 857, разошлось 6 331, пусто в IFRS9 17 077 из 29 265. Но в таблице есть
      ОТДЕЛЬНАЯ колонка default_date_old — значит default_date перезаписывается
      либо очищается, а прежнее значение сохраняется. Наиболее вероятное
      объяснение 58 % пустот: дата очищается при выходе из дефолта, ровно как
      в базе дефолтов. ДО проверки § 1c объявлять рассинхрон определения дефолта
      НЕЛЬЗЯ — это была бы вторая находка, отозванная контролем.

   ВНИМАНИЕ: в таблице есть колонка IIN — персональные данные.
   SELECT * по ней запрещён, колонки перечисляются явно.

   Read-only. Только SELECT. #temp с префиксом D15J_. MAXDOP 1.
   § 3 требует выполненного D15_H_controls.sql В ТОМ ЖЕ ОКНЕ: используются
   #D15H_class и #D15H_cured, они локальные.
   T-SQL (Microsoft SQL Server).
   ============================================================================= */

SET NOCOUNT ON;

/* Актуальный снимок. Проверить по § 0a и обновить перед прогоном. */
-- KAN_20260801_for_LGD_Fenix — самая свежая на 27.08.2026


/* =============================================================================
   § 0. ПРОДУКТОВЫЕ СПРАВОЧНИКИ.
   ============================================================================= */

-- 0a. Убедиться, что более свежей таблицы не появилось.
SELECT TOP 5 TABLE_NAME
FROM [IFRS9].INFORMATION_SCHEMA.TABLES
WHERE TABLE_NAME LIKE 'KAN_2%_for_LGD_Fenix'
ORDER BY TABLE_NAME DESC;

-- 0b. Привязка продукта к корзине AQR. Состав неизвестен — смотрим.
SELECT 'KAN_PD_LGD_Product_Basket' AS tbl, COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH
FROM [IFRS9].INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'KAN_PD_LGD_Product_Basket'
UNION ALL
SELECT 'KAN_contract_basket', COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH
FROM [IFRS9].INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'KAN_contract_basket'
ORDER BY tbl, COLUMN_NAME;

-- 0c. Словарь продуктов: что вообще бывает и каков вес.
SELECT
      subproduct
    , COUNT(*)                                    AS rows_cnt
    , COUNT(DISTINCT account_number)              AS accounts
    , COUNT(DISTINCT TARIFF)                      AS tariffs
FROM [IFRS9].[dbo].[KAN_20260801_for_LGD_Fenix]
GROUP BY subproduct
ORDER BY accounts DESC
OPTION (MAXDOP 1);


/* =============================================================================
   § 1. ОПРЕДЕЛЕНИЕ ДЕФОЛТА В МОДЕЛИ. Н5 и Н8 контура, сделано правильно.
   ============================================================================= */

-- 1a. Какие вообще бывают триггеры. Это и есть перечень событий дефолта
--     в модели PD/LGD. Сопоставлять надо с Приложением 4 п. 5 Методики:
--     просрочка более 90 дней, вынужденная реструктуризация, смерть,
--     места лишения свободы, банкротство.
SELECT
      trigger_первый
    , trigger_последующий
    , [trigger на тек дату]
    , COUNT(*)                                    AS accounts
FROM [IFRS9].[dbo].[KAN_20260801_for_LGD_Fenix]
GROUP BY trigger_первый, trigger_последующий, [trigger на тек дату]
ORDER BY accounts DESC
OPTION (MAXDOP 1);

-- 1b. Заполненность полей, которые соответствуют признакам Методики.
--     Если признак есть в Методике, но поле под него пустое — модель его
--     не применяет, и это расхождение по существу, а не по датам.
SELECT
      COUNT(*)                                                      AS rows_total
    , SUM(CASE WHEN dead_convict   IS NOT NULL THEN 1 ELSE 0 END)   AS with_dead_convict
    , SUM(CASE WHEN bankrupt_date  IS NOT NULL THEN 1 ELSE 0 END)   AS with_bankrupt
    , SUM(CASE WHEN poci_date      IS NOT NULL THEN 1 ELSE 0 END)   AS with_poci
    , SUM(CASE WHEN [дата окончания реструктуры] IS NOT NULL THEN 1 ELSE 0 END) AS with_restr
FROM [IFRS9].[dbo].[KAN_20260801_for_LGD_Fenix]
OPTION (MAXDOP 1);

-- 1c. КОНТРОЛЬ, БЕЗ КОТОРОГО РАСХОЖДЕНИЕ ДАТ НЕЛЬЗЯ НАЗЫВАТЬ НАХОДКОЙ.
--     Гипотеза: default_date очищается при выходе, прежнее значение уходит
--     в default_date_old. Тогда 58 % пустот — не рассинхрон, а тот же механизм,
--     что в базе дефолтов. Сравниваем ОБА поля.
SELECT
      SUM(CASE WHEN f.default_date IS NULL AND f.default_date_old IS NOT NULL
               THEN 1 ELSE 0 END)                               AS cleared_to_old
    , SUM(CASE WHEN f.default_date IS NULL AND f.default_date_old IS NULL
               THEN 1 ELSE 0 END)                               AS both_null
    , SUM(CASE WHEN COALESCE(f.default_date, f.default_date_old) = c.default_date
               THEN 1 ELSE 0 END)                               AS match_after_coalesce
    , SUM(CASE WHEN COALESCE(f.default_date, f.default_date_old) <> c.default_date
               THEN 1 ELSE 0 END)                               AS differ_after_coalesce
    , COUNT(*)                                                  AS matched_accounts
FROM (
    SELECT account_number, default_date, health_date, new_default_date
    FROM [CL_PORTFOLIO].[dbo].[HISTORY_DEFAULT_ACCOUNT]
    WHERE health_date IS NOT NULL
) c
INNER JOIN (
    SELECT account_number
         , MIN(default_date)     AS default_date
         , MIN(default_date_old) AS default_date_old
    FROM [IFRS9].[dbo].[KAN_20260801_for_LGD_Fenix]
    GROUP BY account_number
) f ON f.account_number = c.account_number
OPTION (MAXDOP 1);

-- Читать так: если cleared_to_old велик, а match_after_coalesce близок
-- к matched_accounts — рассинхрона определения НЕТ, есть разная механика
-- хранения. Если и после COALESCE расхождение остаётся значимым — тогда
-- это находка Н5/Н8, и оформлять её надо ОТДЕЛЬНО от записки по правке.


/* -----------------------------------------------------------------------------
   § 1d. ЧТО ПОКАЗАЛ ПРОГОН § 1 И ЧТО ОСТАЛОСЬ ПРОВЕРИТЬ.

   ТРИГГЕРЫ СОВПАДАЮТ С МЕТОДИКОЙ ПО СУЩЕСТВУ. Перечень событий дефолта
   в модели PD/LGD:
       91+                                   -> Прил. 4 п. 5 пп. 1, просрочка > 90
       реструктуризация с фин. ухудшением    -> пп. 2
       смерть заемщика                       -> пп. 3
       тюремщик                              -> пп. 4, места лишения свободы
       банкротство                           -> пп. 5
   Все пять признаков Методики присутствуют, шестого нет. POCI — отдельная
   категория МСФО 9, а не дополнительный триггер.
   Значит рассинхрона ОПРЕДЕЛЕНИЯ между моделью и учётом НЕТ.

   ТРИ ДЕФЕКТА ДАННЫХ, КОТОРЫЕ ПРИ ЭТОМ ВИДНЫ:
     * 58 130 счетов имеют ПУСТОЙ первый и последующий триггер при заполненном
       текущем (56 128 + 1 576 + 424 + 2). Модель не хранит причину первого
       дефолта по этим счетам;
     * poci_date заполнена у НУЛЯ счетов при 2 833 счетах с триггером POCI —
       признак есть, даты под него нет;
     * регистр значений не нормализован: «тюремщик» и «Тюремщик»,
       «с фин. ухудшением» и «с фин. Ухудшением» — разные строки. Группировка
       без UPPER/TRIM дробит категории. § 1e считает нормализованно.

   ГЕЙТ § 1c ЗАКРЫЛСЯ НАПОЛОВИНУ. После COALESCE(default_date, default_date_old)
   совпадений стало 19 444 из 29 265 (66,4 %) против 5 857 до; расхождений
   9 821 (33,6 %). Гипотеза про очистку даты подтвердилась (17 421 счёт),
   но треть расхождений осталась.

   ОБЪЯВЛЯТЬ Н5/Н8 ВСЁ ЕЩЁ НЕЛЬЗЯ. Вероятная причина остатка — РАЗНЫЕ ЭПИЗОДЫ:
   база дефолтов хранит ПЕРВЫЙ дефолт в default_date, а IFRS9 может хранить
   ПОСЛЕДНИЙ. Тогда у счёта с несколькими эпизодами даты обязаны различаться,
   и это не дефект, а разная адресация. Различия до 2 222 дней в § 3 D15-I
   на это и указывают. Проверяет § 1f.
   ----------------------------------------------------------------------------- */

-- 1e. Триггеры нормализованно: свести регистр и пробелы.
SELECT
      UPPER(LTRIM(RTRIM(ISNULL([trigger на тек дату], N'<пусто>')))) AS trigger_now
    , COUNT(*)                                    AS accounts
FROM [IFRS9].[dbo].[KAN_20260801_for_LGD_Fenix]
GROUP BY UPPER(LTRIM(RTRIM(ISNULL([trigger на тек дату], N'<пусто>'))))
ORDER BY accounts DESC
OPTION (MAXDOP 1);

-- 1f. ПОСЛЕДНИЙ ГЕЙТ ПЕРЕД ОБЪЯВЛЕНИЕМ Н5/Н8.
--     Если оставшиеся 9 821 расхождения сидят в счетах с НЕСКОЛЬКИМИ эпизодами,
--     то сравнивались разные события, и находки нет. Если расхождения ровно
--     так же распределены среди одноэпизодных — тогда это находка.
SELECT
      CASE WHEN c.new_default_date IS NOT NULL OR c.new_health_date IS NOT NULL
           THEN 'несколько эпизодов' ELSE 'один эпизод' END          AS episodes
    , COUNT(*)                                                       AS accounts
    , SUM(CASE WHEN COALESCE(f.default_date, f.default_date_old) = c.default_date
               THEN 1 ELSE 0 END)                                    AS match_vs_first
    , SUM(CASE WHEN COALESCE(f.default_date, f.default_date_old) = c.new_default_date
               THEN 1 ELSE 0 END)                                    AS match_vs_last
    , CAST(100.0 * SUM(CASE WHEN COALESCE(f.default_date, f.default_date_old) = c.default_date
               THEN 1 ELSE 0 END) / NULLIF(COUNT(*),0) AS decimal(5,2)) AS match_first_pct
FROM (
    SELECT account_number, default_date, health_date, new_default_date, new_health_date
    FROM [CL_PORTFOLIO].[dbo].[HISTORY_DEFAULT_ACCOUNT]
    WHERE health_date IS NOT NULL
) c
INNER JOIN (
    SELECT account_number, MIN(default_date) AS default_date,
           MIN(default_date_old) AS default_date_old
    FROM [IFRS9].[dbo].[KAN_20260801_for_LGD_Fenix] GROUP BY account_number
) f ON f.account_number = c.account_number
GROUP BY CASE WHEN c.new_default_date IS NOT NULL OR c.new_health_date IS NOT NULL
              THEN 'несколько эпизодов' ELSE 'один эпизод' END
OPTION (MAXDOP 1);

-- Читать так: если у одноэпизодных match_first_pct близок к 100 — расхождение
-- объясняется адресацией эпизодов, Н5/Н8 закрывается как «не подтверждено».
-- Если и у одноэпизодных треть расходится — это находка, и оформлять её надо
-- ОТДЕЛЬНЫМ материалом, не в записке по правке.


/* =============================================================================
   § 2. ПРОДУКТ ПО НАШЕЙ ПОПУЛЯЦИИ. Сколько оздоровлённых в каждом продукте
        и хватит ли их на разрез. Проверка мощности ДО расчёта ставок.
   ============================================================================= */

IF OBJECT_ID('tempdb..#D15J_prod') IS NOT NULL DROP TABLE #D15J_prod;

SELECT
      f.account_number
    , MAX(f.subproduct)                           AS subproduct
    , MAX(f.TARIFF)                               AS tariff
    , MAX(f.FIRST_PAYMENT_DATE)                   AS first_payment_date
    , MAX(f.[status])                             AS status
INTO #D15J_prod
FROM [IFRS9].[dbo].[KAN_20260801_for_LGD_Fenix] f
GROUP BY f.account_number        -- свёртка: max 2 строки на счёт, различаются poci_date
OPTION (MAXDOP 1);

CREATE UNIQUE CLUSTERED INDEX ix_D15J_prod ON #D15J_prod(account_number);

SELECT
      p.subproduct
    , COUNT(*)                                    AS cured_accounts
    , CASE WHEN COUNT(*) >= 100 THEN 'разрез допустим'
           ELSE 'МАЛО — укрупнять' END            AS power_check
FROM #D15J_prod p
INNER JOIN (
    SELECT account_number FROM [CL_PORTFOLIO].[dbo].[HISTORY_DEFAULT_ACCOUNT]
    WHERE health_date IS NOT NULL
) c ON c.account_number = p.account_number
GROUP BY p.subproduct
ORDER BY cured_accounts DESC
OPTION (MAXDOP 1);


/* -----------------------------------------------------------------------------
   § 2a. ЧТО ПОКАЗАЛ ПРОГОН § 2, И ЭТО ВАЖНЕЕ ПРОВЕРКИ МОЩНОСТИ.

   Сумма по продуктам — 29 265, ровно охват § 2 D15-I. Потерь при соединении нет.

   Семь продуктов проходят порог в 100 займов: Payroll 8 068, UnCL 6 324,
   Loyalty 4 957, NCL 4 320, POS 3 908, UCL 1 000, DSL online 599.
   KAZPOST 74 и четыре мелких (5, 5, 3, 2) укрупняются.

   НО ГЛАВНОЕ НЕ ЭТО. Таблица IFRS9 содержит ДЕФОЛТНУЮ популяцию: триггер
   заполнен практически у всех 656 тыс. строк. Значит «оздоровлено / всего»
   по продукту есть ДОЛЯ ВЫХОДА ИЗ ДЕФОЛТА, и она различается кратно:

       продукт      дефолтов   оздоровлено   доля выхода
       NCL            41 905      4 320        10,31 %
       DSL online      7 532        599         7,95 %
       Payroll       105 552      8 068         7,64 %
       UCL            13 379      1 000         7,47 %
       UnCL          118 183      6 324         5,35 %
       Loyalty        93 366      4 957         5,31 %
       KAZPOST         1 764         74         4,19 %
       POS           273 593      3 908         1,43 %

   POS выходит из дефолта в СЕМЬ РАЗ реже, чем NCL, и вчетверо реже среднего.
   При этом POS — 42 % дефолтной популяции и лишь 13 % оздоровлений.

   ЧТО ЭТО ЗНАЧИТ ДЛЯ ИНИЦИАТИВЫ. Объём смягчения придёт не оттуда, где больше
   всего дефолтов. Он придёт из Payroll, UnCL, Loyalty и NCL. Оценка эффекта
   «в среднем по портфелю» будет неверной; считать надо по продуктам.

   ЧЕГО ЭТА ЦИФРА ЕЩЁ НЕ ДОКАЗЫВАЕТ — два конфаундера, оба проверяются § 2b:
     * ЗРЕЛОСТЬ. Оздоровление требует минимум семи месяцев от дефолта.
       Если дефолты POS в среднем свежее, низкая доля выхода частично
       объясняется тем, что срок не вышел, а не поведением заёмщиков.
     * АЛЬТЕРНАТИВНЫЙ ИСХОД. Мелкий короткий POS дешевле списать или продать,
       чем вести до оздоровления. Тогда низкая доля выхода означает иную
       практику работы с долгом, а не худшего заёмщика.
   ----------------------------------------------------------------------------- */

-- 2b. Контроль обоих конфаундеров сразу: зрелость дефолта и исход.
SELECT
      p.subproduct
    , COUNT(*)                                                     AS defaulted
    , CAST(AVG(CAST(DATEDIFF(MONTH, c.default_date, '2026-08-01') AS float))
           AS decimal(7,1))                                        AS avg_months_since_default
    , SUM(CASE WHEN DATEDIFF(MONTH, c.default_date, '2026-08-01') < 7
               THEN 1 ELSE 0 END)                                  AS too_young_to_cure
    , SUM(CASE WHEN c.health_date IS NOT NULL THEN 1 ELSE 0 END)   AS cured
    , SUM(CASE WHEN c.fact_close_date IS NOT NULL AND c.health_date IS NULL
               THEN 1 ELSE 0 END)                                  AS closed_without_cure
    , CAST(100.0 * SUM(CASE WHEN c.health_date IS NOT NULL THEN 1 ELSE 0 END)
           / NULLIF(SUM(CASE WHEN DATEDIFF(MONTH, c.default_date, '2026-08-01') >= 7
                             THEN 1 ELSE 0 END),0) AS decimal(5,2))
                                                                   AS cure_rate_mature_pct
FROM #D15J_prod p
INNER JOIN [CL_PORTFOLIO].[dbo].[HISTORY_DEFAULT_ACCOUNT] c
        ON c.account_number = p.account_number
WHERE c.default_date IS NOT NULL OR c.health_date IS NOT NULL
GROUP BY p.subproduct
HAVING COUNT(*) >= 100
ORDER BY cure_rate_mature_pct DESC
OPTION (MAXDOP 1);

-- Читать так: cure_rate_mature_pct считает долю выхода ТОЛЬКО по дефолтам,
-- у которых прошло не менее семи месяцев. Если разрыв POS против NCL
-- сохраняется — зрелость ни при чём. Столбец closed_without_cure показывает,
-- уходит ли POS в закрытие вместо оздоровления.


/* =============================================================================
   § 3. ГЛАВНАЯ ТАБЛИЦА: ПРОДУКТ x ПОРОГ 0…30.

        ТРЕБУЕТ D15_H_controls.sql, ВЫПОЛНЕННОГО В ТОМ ЖЕ ОКНЕ, — и с уже
        выставленным @Offset по его § 1а. Иначе классификация снова уедет.

        Правило минимальной клетки — 100 займов, утверждено ДО расчёта.
        Клетки меньше в выдачу не попадают, а не «интерпретируются осторожно».
   ============================================================================= */

SELECT
      pr.subproduct
    , t.thr                                       AS soft_threshold
    , SUM(CASE WHEN k.dpd_max <= t.thr THEN 1 ELSE 0 END)                 AS cured_pass
    , SUM(CASE WHEN k.dpd_max <= t.thr THEN c.redefaulted ELSE 0 END)     AS redefaulted
    , CAST(100.0 * SUM(CASE WHEN k.dpd_max <= t.thr THEN c.redefaulted ELSE 0 END)
           / NULLIF(SUM(CASE WHEN k.dpd_max <= t.thr THEN 1 ELSE 0 END),0)
           AS decimal(5,2))                                               AS rd_rate_pct
FROM #D15H_class k
INNER JOIN #D15H_cured c ON c.account_number = k.account_number
INNER JOIN #D15J_prod  pr ON pr.account_number = k.account_number
CROSS JOIN (VALUES (0),(5),(10),(15),(20),(25),(30)) t(thr)
WHERE k.months_obs >= 6
GROUP BY pr.subproduct, t.thr
HAVING SUM(CASE WHEN k.dpd_max <= t.thr THEN 1 ELSE 0 END) >= 100
ORDER BY pr.subproduct, t.thr
OPTION (MAXDOP 1);

-- 3a. Тот же разрез по TARIFF — дробнее. Клеток мало, правило то же.
SELECT
      pr.tariff
    , t.thr                                       AS soft_threshold
    , SUM(CASE WHEN k.dpd_max <= t.thr THEN 1 ELSE 0 END)                 AS cured_pass
    , CAST(100.0 * SUM(CASE WHEN k.dpd_max <= t.thr THEN c.redefaulted ELSE 0 END)
           / NULLIF(SUM(CASE WHEN k.dpd_max <= t.thr THEN 1 ELSE 0 END),0)
           AS decimal(5,2))                                               AS rd_rate_pct
FROM #D15H_class k
INNER JOIN #D15H_cured c ON c.account_number = k.account_number
INNER JOIN #D15J_prod  pr ON pr.account_number = k.account_number
CROSS JOIN (VALUES (0),(10),(15),(20),(30)) t(thr)
WHERE k.months_obs >= 6
GROUP BY pr.tariff, t.thr
HAVING SUM(CASE WHEN k.dpd_max <= t.thr THEN 1 ELSE 0 END) >= 100
ORDER BY pr.tariff, t.thr
OPTION (MAXDOP 1);


/* =============================================================================
   § 4. ДЕНЬ ПЛАТЕЖА ПО ВСЕМУ ПОРТФЕЛЮ — то, чего не хватало D15-F § 3.

        FIRST_PAYMENT_DATE даёт день платежа для КАЖДОГО договора, а не только
        для просроченного. Значит появляется знаменатель, и вопрос «на какое
        число переносить» получает эмпирический ответ.

        Читать по возрастанию delinquency_pct: верхние строки — рабочие даты
        портфеля. Они же косвенно показывают, когда приходит доход,
        без запроса зарплатных данных.
   ============================================================================= */

SELECT
      DAY(pr.first_payment_date)                  AS pay_day
    , COUNT(*)                                    AS loans
    , SUM(CASE WHEN p.dpd > 0  THEN 1 ELSE 0 END) AS delinquent
    , CAST(100.0 * SUM(CASE WHEN p.dpd > 0 THEN 1 ELSE 0 END)
           / NULLIF(COUNT(*),0) AS decimal(5,2))  AS delinquency_pct
    , CAST(AVG(CASE WHEN p.dpd > 0 THEN CAST(p.dpd AS float) END) AS decimal(7,1)) AS avg_dpd_if_late
FROM #D15J_prod pr
INNER JOIN [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2] p
        ON p.contract_number = pr.account_number
       AND p.[date] = '2026-08-01'
WHERE pr.first_payment_date IS NOT NULL
  AND ISNULL(p.[tag],'') <> '11'
GROUP BY DAY(pr.first_payment_date)
HAVING COUNT(*) >= 100
ORDER BY delinquency_pct ASC
OPTION (MAXDOP 1);

-- 4a. То же в разрезе продукта: рабочая дата может отличаться по продуктам,
--     и тогда рекомендация переноса должна быть разной.
SELECT
      pr.subproduct
    , DAY(pr.first_payment_date)                  AS pay_day
    , COUNT(*)                                    AS loans
    , CAST(100.0 * SUM(CASE WHEN p.dpd > 0 THEN 1 ELSE 0 END)
           / NULLIF(COUNT(*),0) AS decimal(5,2))  AS delinquency_pct
FROM #D15J_prod pr
INNER JOIN [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2] p
        ON p.contract_number = pr.account_number
       AND p.[date] = '2026-08-01'
WHERE pr.first_payment_date IS NOT NULL
  AND ISNULL(p.[tag],'') <> '11'
GROUP BY pr.subproduct, DAY(pr.first_payment_date)
HAVING COUNT(*) >= 100
ORDER BY pr.subproduct, delinquency_pct ASC
OPTION (MAXDOP 1);
