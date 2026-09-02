/* =============================================================================
   D15-C. Проверка П3: снимочный DPD — это поведение или день платежа?
   =============================================================================
   ПРОСТЫМ ЯЗЫКОМ. Мы видим просрочку раз в месяц, 1-го числа. Если взнос
   был 25-го и не оплачен, на 1-е число просрочка покажет 6 дней — независимо
   от того, заплатит человек завтра или через три недели. А если взнос был
   5-го, та же непогашенность покажет 26 дней.

   Значит фильтр «DPD не выше 15» может отбирать не тех, кто мало опаздывает,
   а тех, у кого дата платежа во второй половине месяца. Этот скрипт проверяет,
   так ли это.

   ЧТО ИМЕННО ПРОВЕРЯЕТСЯ (П3 из METHOD.md):
       DPD_на_срезе  ≈  (дней в предыдущем месяце − день платежа) + 1

   Если верно, гистограмма DPD повторит гистограмму дней платежа, отражённую.
   Дни платежа в рознице кучкуются на 5, 10, 15, 20, 25 — значит в DPD должны
   быть ПИКИ на 26, 21, 16, 11, 6.

   Пики в этих точках доказывают П3 без платёжных таблиц. Ровная гистограмма
   без пиков — П3 не подтверждена, и тогда снимочный DPD несёт больше
   поведения, чем календаря.

   Read-only. Только SELECT, только #temp с префиксом файла.
   T-SQL (Microsoft SQL Server).
   ============================================================================= */

SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#d15c_snap') IS NOT NULL DROP TABLE #d15c_snap;

-------------------------------------------------------------------------------
-- 0. Параметры
-------------------------------------------------------------------------------
DECLARE @AsOf date = '2026-07-01';   -- один срез: гистограмма строится на нём

-- Сколько дней было в предыдущем месяце — база формулы П3
DECLARE @PrevMonthDays int =
    DATEDIFF(DAY, DATEADD(MONTH, -1, @AsOf), @AsOf);

-------------------------------------------------------------------------------
-- 1. Один срез по шести источникам
--    Ключ — пара (source_system, contract_number): по одному номеру
--    задокументировано 9 659 cross-source коллизий.
-------------------------------------------------------------------------------
SELECT
      src.source_system
    , src.contract_number
    , src.dpd
    , src.balance
    , src.stage_raw
INTO #d15c_snap
FROM (
    SELECT 'S03_Credilogic' AS source_system, contract_number,
           TRY_CAST([dpd] AS int)                AS dpd,
           TRY_CAST([balance] AS decimal(38,2))  AS balance,
           TRY_CAST([category] AS nvarchar(50))  AS stage_raw,
           TRY_CAST([date] AS date)              AS snap_date
    FROM [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2]
    UNION ALL
    SELECT 'S17_Fenix', contractnumber,
           TRY_CAST(overdue_days_principal AS int),
           TRY_CAST(Total_outstanding AS decimal(38,2)),
           TRY_CAST(Basket AS nvarchar(50)),
           TRY_CAST(actual_date AS date)
    FROM [CL_PORTFOLIO].[dbo].[PORTFOLIO_Fenix]
    UNION ALL
    SELECT 'S01_RS', contractnumber,
           TRY_CAST([dpd] AS int),
           TRY_CAST(Total_outstanding AS decimal(38,2)),
           TRY_CAST(Basket AS nvarchar(50)),
           TRY_CAST(actual_date AS date)
    FROM [CL_PORTFOLIO].[dbo].[PORTFOLIO_RS]
    UNION ALL
    SELECT 'S02_MIGR_WAY4', contract_number,
           TRY_CAST([dpd] AS int),
           TRY_CAST([balance] AS decimal(38,2)),
           TRY_CAST([category] AS nvarchar(50)),
           TRY_CAST([date] AS date)
    FROM [CL_PORTFOLIO].[dbo].[PORTFOLIO_CREDITCARDS_MIGR_WAY4]
    UNION ALL
    SELECT 'S02_SMART_CARD', contract_number,
           TRY_CAST([dpd] AS int),
           TRY_CAST([balance] AS decimal(38,2)),
           TRY_CAST([category] AS nvarchar(50)),
           TRY_CAST([date] AS date)
    FROM [CL_PORTFOLIO].[dbo].[PORTFOLIO_CREDITCARDS_SMART_CARD]
    UNION ALL
    SELECT 'S02_WAY4', contract_number,
           TRY_CAST([dpd] AS int),
           TRY_CAST([balance] AS decimal(38,2)),
           TRY_CAST([category] AS nvarchar(50)),
           TRY_CAST([date] AS date)
    FROM [CL_PORTFOLIO].[dbo].[PORTFOLIO_CREDITCARDS_WAY4]
) AS src
WHERE src.snap_date = @AsOf
OPTION (MAXDOP 1);

-------------------------------------------------------------------------------
-- §0. Контроль: срез существует и не пуст. Если ноль строк — дата снимка
--     не 1-е число в каком-то из источников (это В-DPD-12).
-------------------------------------------------------------------------------
SELECT source_system,
       COUNT(*)                                            AS rows_at_asof,
       SUM(CASE WHEN dpd IS NULL THEN 1 ELSE 0 END)        AS dpd_null,
       SUM(CASE WHEN stage_raw = '3' THEN 1 ELSE 0 END)    AS stage3
FROM #d15c_snap
GROUP BY source_system WITH ROLLUP
ORDER BY GROUPING(source_system), rows_at_asof DESC;

-------------------------------------------------------------------------------
-- §1. ГЛАВНАЯ ТАБЛИЦА. Гистограмма DPD по дням, 1..31, и подразумеваемый
--     день платежа. Смотреть на колонку contracts: есть ли пики на 6, 11,
--     16, 21, 26.
--
--     Доля нарастающим итогом показывает, какая часть пула отсекается порогом:
--     строка dpd = 15 даёт долю, попадающую в фильтр «не выше 15».
-------------------------------------------------------------------------------
SELECT
      s.dpd
    , d.implied_due_day
    , COUNT(*)                                                        AS contracts
    , SUM(s.balance) / 1e9                                            AS balance_bn
    , CAST(100.0 * COUNT(*)
           / SUM(COUNT(*)) OVER ()                AS decimal(6,2))    AS pct
    , CAST(100.0 * SUM(COUNT(*)) OVER (ORDER BY s.dpd)
           / SUM(COUNT(*)) OVER ()                AS decimal(6,2))    AS pct_cum
FROM #d15c_snap AS s
CROSS APPLY (VALUES (@PrevMonthDays - s.dpd + 1)) AS d(implied_due_day)
WHERE s.stage_raw = '3'
  AND s.dpd BETWEEN 1 AND 31
GROUP BY s.dpd, d.implied_due_day
ORDER BY s.dpd;

-------------------------------------------------------------------------------
-- §2. Тот же ряд, свёрнутый в «круглые дни платежа против остальных».
--     Если П3 верна, доля круглых будет заметно выше 5/30 = 17 %.
--     Это и есть числовой ответ, а не глазомер по гистограмме.
-------------------------------------------------------------------------------
SELECT
      g.grp
    , COUNT(*)                                                     AS contracts
    , SUM(s.balance) / 1e9                                         AS balance_bn
    , CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS decimal(6,2)) AS pct
FROM #d15c_snap AS s
CROSS APPLY (VALUES (@PrevMonthDays - s.dpd + 1)) AS d(implied_due_day)
CROSS APPLY (VALUES (
        CASE WHEN d.implied_due_day % 5 = 0 THEN 'день платежа кратен 5'
             ELSE                                 'прочие дни'
        END)) AS g(grp)
WHERE s.stage_raw = '3'
  AND s.dpd BETWEEN 1 AND 31
GROUP BY g.grp
ORDER BY contracts DESC;

-------------------------------------------------------------------------------
-- §3. Что отсекает порог. Первая половина месяца против второй.
--     Если пул «не выше 15» состоит почти целиком из второй половины —
--     фильтр отбирает по календарю, а не по риску (П4).
-------------------------------------------------------------------------------
SELECT
      h.half
    , SUM(CASE WHEN s.dpd BETWEEN 1 AND 15  THEN 1 ELSE 0 END)      AS dpd_1_15
    , SUM(CASE WHEN s.dpd BETWEEN 16 AND 31 THEN 1 ELSE 0 END)      AS dpd_16_31
    , SUM(CASE WHEN s.dpd BETWEEN 1 AND 15  THEN s.balance END)/1e9 AS bn_1_15
    , SUM(CASE WHEN s.dpd BETWEEN 16 AND 31 THEN s.balance END)/1e9 AS bn_16_31
FROM #d15c_snap AS s
CROSS APPLY (VALUES (@PrevMonthDays - s.dpd + 1)) AS d(implied_due_day)
CROSS APPLY (VALUES (
        CASE WHEN d.implied_due_day <= 15 THEN '1-15 число'
             ELSE                              '16-31 число'
        END)) AS h(half)
WHERE s.stage_raw = '3'
  AND s.dpd BETWEEN 1 AND 31
GROUP BY h.half
ORDER BY h.half;

-------------------------------------------------------------------------------
-- §4. Контроль П3 фактическим днём платежа — ЕСЛИ он нашёлся в блоке 4
--     скрипта D15_A_audit.sql. Раскомментировать, подставив имя колонки.
--
--     Это разрез с заранее известным ответом: если П3 верна, разность
--     implied_due_day и фактического дня платежа сосредоточится около нуля.
--     Формула, у которой нет такой проверки, при ошибке даёт не ошибку,
--     а уверенный неверный ответ.
--
--  SELECT diff.d, COUNT(*) AS contracts
--  FROM #d15c_snap AS s
--  JOIN [CL_PORTFOLIO].[dbo].[<таблица с днём платежа>] AS p
--         ON  p.contract_number = s.contract_number
--        AND  p.source_system   = s.source_system     -- если признака нет, см. Р-1
--  CROSS APPLY (VALUES (@PrevMonthDays - s.dpd + 1)) AS dd(implied_due_day)
--  CROSS APPLY (VALUES (dd.implied_due_day
--                       - TRY_CAST(p.<колонка_дня_платежа> AS int))) AS diff(d)
--  WHERE s.stage_raw = '3' AND s.dpd BETWEEN 1 AND 31
--  GROUP BY diff.d
--  ORDER BY diff.d;
-------------------------------------------------------------------------------

/* -----------------------------------------------------------------------------
   КАК ЧИТАТЬ

   §1  Ищем пики на dpd = 6, 11, 16, 21, 26 (день платежа 25, 20, 15, 10, 5).
       Пики есть -> П3 подтверждена, снимочный DPD это календарь.
       Ряд ровный -> П3 не подтверждена, и снимок несёт поведение.

   §2  Числовой вариант того же. Доля «кратных пяти» существенно выше 17 %
       (это 5 дней из 30) -> П3 подтверждена.

   §3  Прямой ответ по инициативе. Если пул «DPD 1-15» это почти целиком
       день платежа 16-31 — фильтр списка БРМ отбирает по календарю (П4),
       и обсуждать надо способ отбора, а не величину порога.

   §4  Единственная настоящая проверка: сверка с фактическим днём платежа.
       До неё §1-§3 — сильное косвенное свидетельство, не доказательство.

   ЧЕГО ЭТОТ СКРИПТ НЕ ДЕЛАЕТ

   Не отвечает на вопрос «сколько на самом деле опаздывает заёмщик». На это
   отвечает только слой 1 (взносы: план против факта), и он ждёт имён таблиц
   из D15_A_audit.sql.

   Определение `dpd` в витрине не проверено (В-DPD-11). Вся П3 строится
   на допущении, что это «дней с плановой даты старейшего непогашенного
   взноса». По `dpd` уже задокументированы off-by-one и NULL-heavy для S03 —
   значит поле точно требует не доверия, а проверки.
   ----------------------------------------------------------------------------- */
