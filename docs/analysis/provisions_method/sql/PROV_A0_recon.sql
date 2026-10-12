/* =============================================================================
   PROV_A0_recon.sql — Track A, шаг 0: разведка. Ничего не считает, только проверяет,
   хватает ли данных для расчёта провизий S03 на 01.10.2026 по старым параметрам.
   План — docs/analysis/provisions_method/TRACK_A_PLAN.md (ред. 2), issue #164.

   Согласовано Мирасом 12.10.2026: PD/LGD — KAN; корзины — HISTORY_DEFAULT_ACCOUNT;
   DPD — как есть; отчётная дата 01.10.2026; источник S03; эталон — CL_PORTFOLIO_2.

   Правила (§4 корневого CLAUDE.md): только SELECT, #temp с префиксом A0_, MAXDOP 1,
   трёхчастные имена. PII не выводится: IIN не выбирается, номера договоров — только
   внутри COUNT и JOIN. Наружу (в issue) — только выводы §0–§5 как есть: это агрегаты.

   ПОРЯДОК: сначала §0 (отдельный батч). Если какой-либо колонки из списка «ожидаем»
   нет — остановиться и прислать вывод §0, остальное не запускать.

   БАТЧИ. Разделы разделены GO: SQL Server связывает имена колонок постоянных таблиц
   при компиляции батча, поэтому одна несуществующая колонка роняет весь батч целиком,
   а не одну строку. GO — разделитель SSMS/sqlcmd; при запуске через scripts/db.py
   (pyodbc) текст делить по строкам «GO» и выполнять по частям в ОДНОМ соединении —
   #A0_* живут до конца сессии. @AsOf объявляется в каждом батче заново.

   Редакция 2 (12.10.2026) против текста в теле #164:
     + §0  — полный список колонок CL_PORTFOLIO_2 (было и раньше) + §0b кандидаты
             в признак индивидуальной оценки / исключения; аудит колонок снимка KAN
             и счетов провизий loan_account;
     + §2  — шаблоны (закомментированы): §2b — разбивка эталона по признаку индивидуальной
             оценки; §2c — какую базу V применяла старая система (TRACK_A_PLAN §9.2);
     + §5  — ΔV на общих договорах: Σ(V_new − V_old) и Σ|V_new − V_old| по category,
             бакеты |ΔV| — без построчного вывода;
     ~ GO между разделами.
   ============================================================================= */

/* §0. Живой аудит имён. Ожидаем:
   IFRS9.KAN_PD_LGD_Product_Basket: Product, Basket, PD, LGD, [LGD+TV], Date
   IFRS9.KAN_<YYYYMMDD>_for_LGD_Fenix: account_number, subproduct
   CL_PORTFOLIO.CL_PORTFOLIO_2: contract_number, date, dpd, category, tag, balance,
                                balance_with_discount, provisions_total — и ВСЕ прочие
                                колонки (ищем признак индивидуальной оценки, §0b)
   CL_PORTFOLIO.HISTORY_DEFAULT_ACCOUNT: account_number, default_date, health_date,
                                new_default_date, колонки ['01.08.2026'] ['01.09.2026'] ['01.10.2026']
   Dictionaries.loans: l_gid, l_source, l_loan_number
   Dictionaries.loan_account: la_gid, la_source, la_reporting_date, la_status,
                                total_balance_debt, days_past_due,
                                la_account_1428 / la_account_1845 / la_account_18771 (P_new)  */
SELECT 'IFRS9' AS db, TABLE_NAME, COLUMN_NAME, DATA_TYPE, ORDINAL_POSITION
FROM [IFRS9].INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'dbo'
  AND (TABLE_NAME = 'KAN_PD_LGD_Product_Basket'
    OR (TABLE_NAME LIKE 'KAN[_]2026%[_]for[_]LGD[_]Fenix'
        AND COLUMN_NAME IN ('account_number','subproduct')))
UNION ALL
SELECT 'CL_PORTFOLIO', TABLE_NAME, COLUMN_NAME, DATA_TYPE, ORDINAL_POSITION
FROM [CL_PORTFOLIO].INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'dbo'
  AND (TABLE_NAME = 'CL_PORTFOLIO_2'                       -- все колонки, без фильтра
    OR (TABLE_NAME = 'HISTORY_DEFAULT_ACCOUNT'
        AND (ORDINAL_POSITION <= 10 OR COLUMN_NAME LIKE '%2026%' OR COLUMN_NAME LIKE '%2027%')))
UNION ALL
SELECT 'Dictionaries', TABLE_NAME, COLUMN_NAME, DATA_TYPE, ORDINAL_POSITION
FROM [Dictionaries].INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'risk_analytics'
  AND ((TABLE_NAME = 'loans' AND COLUMN_NAME IN ('l_gid','l_source','l_loan_number'))
    OR (TABLE_NAME = 'loan_account' AND (COLUMN_NAME IN
        ('la_gid','la_source','la_reporting_date','la_status','total_balance_debt','days_past_due')
         OR COLUMN_NAME LIKE 'la[_]account[_]14%'
         OR COLUMN_NAME LIKE 'la[_]account[_]18%')))
ORDER BY db, TABLE_NAME, ORDINAL_POSITION;

/* §0b. Кандидаты в признак индивидуальной оценки / исключения из коллективной основы
   в CL_PORTFOLIO_2 (ревью Сайлау, п. 4; TRACK_A_PLAN §6). Это подсказка по именам,
   а не вывод: полный список — в §0, смотреть его целиком. Имя ≠ семантика —
   домен значений кандидата проверяется §2b только после выбора колонки автором.   */
SELECT COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH, ORDINAL_POSITION
FROM [CL_PORTFOLIO].INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'dbo' AND TABLE_NAME = 'CL_PORTFOLIO_2'
  AND (COLUMN_NAME LIKE '%ind%'    OR COLUMN_NAME LIKE '%assess%' OR COLUMN_NAME LIKE '%method%'
    OR COLUMN_NAME LIKE '%type%'   OR COLUMN_NAME LIKE '%flag%'   OR COLUMN_NAME LIKE '%excl%'
    OR COLUMN_NAME LIKE '%signif%' OR COLUMN_NAME LIKE '%basis%'  OR COLUMN_NAME LIKE '%stage%'
    OR COLUMN_NAME LIKE '%prov%'   OR COLUMN_NAME LIKE '%инд%'    OR COLUMN_NAME LIKE '%основ%')
ORDER BY ORDINAL_POSITION;
GO

/* §1. Параметры KAN.
   1a. Снимки KAN_*_for_LGD_Fenix за 2026 год — какой брать на 01.10.2026.        */
DECLARE @AsOf date = '2026-10-01';

SELECT name AS kan_table, create_date, modify_date
FROM [IFRS9].sys.tables
WHERE name LIKE 'KAN[_]2026%[_]for[_]LGD[_]Fenix%'
ORDER BY name;

/* 1b. Таблица параметров: сколько дат, продуктов, корзин; последняя дата ≤ @AsOf.
   PD, LGD, [LGD+TV] — nvarchar (§0 прогона 12.10.2026): в расчётах только TRY_CAST.  */
SELECT [Date], COUNT(*) AS rows_n, COUNT(DISTINCT Product) AS products,
       COUNT(DISTINCT Basket) AS baskets,
       SUM(CASE WHEN PD IS NULL OR LGD IS NULL THEN 1 ELSE 0 END) AS rows_pd_or_lgd_null
FROM [IFRS9].[dbo].[KAN_PD_LGD_Product_Basket]
GROUP BY [Date]
ORDER BY [Date];

/* 1c. Параметры на последнюю дату ≤ @AsOf целиком (продукт × корзина — не PII).    */
SELECT Product, Basket, PD, LGD, [LGD+TV], [Date]
FROM [IFRS9].[dbo].[KAN_PD_LGD_Product_Basket]
WHERE [Date] = (SELECT MAX([Date]) FROM [IFRS9].[dbo].[KAN_PD_LGD_Product_Basket]
                WHERE [Date] <= @AsOf)
ORDER BY Product, Basket;
GO

/* §2. Эталон: старый результат на 01.10.2026.                                    */
DECLARE @AsOf date = '2026-10-01';

SELECT category, CASE WHEN tag = '11' THEN 'списан' ELSE 'на балансе' END AS tag_grp,
       COUNT(*)                                         AS rows_n,
       COUNT(DISTINCT contract_number)                  AS contracts,
       SUM(CAST(balance AS decimal(38,2)))              AS sum_balance,
       SUM(CAST(balance_with_discount AS decimal(38,2))) AS sum_balance_disc,
       SUM(CAST(provisions_total AS decimal(38,2)))     AS sum_provisions
FROM [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2]
WHERE [date] = @AsOf
GROUP BY category, CASE WHEN tag = '11' THEN 'списан' ELSE 'на балансе' END
ORDER BY category, tag_grp
OPTION (MAXDOP 1);

/* §2b. ШАБЛОН, НЕ ЗАПУСКАТЬ до выбора колонки по §0/§0b.
   Периметр эталона: какая часть provisions_total — индивидуальная оценка
   (TRACK_A_PLAN §6, P_old = колл + инд + прочее). <IND_FLAG> — проверить по §0.
SELECT category, <IND_FLAG> AS ind_flag,
       COUNT(*) AS contracts,
       SUM(CAST(balance AS decimal(38,2)))          AS sum_balance,
       SUM(CAST(provisions_total AS decimal(38,2))) AS sum_provisions
FROM [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2]
WHERE [date] = @AsOf
GROUP BY category, <IND_FLAG>
ORDER BY category, ind_flag
OPTION (MAXDOP 1);
*/

/* §2c. ШАБЛОН, запускать по решению Мираса (TRACK_A_PLAN §9.2).
   Какую базу V умножала старая система: balance или balance_with_discount.
   В корзине 1 провизия = ROUND(PD_12 × LGD, 4) × V (README §2.5), поэтому у
   «правильной» базы отношение provisions_total / V даёт мало различных значений
   (≈ число пар продукт × корзина), у «неправильной» — размазано.
   Критерий до прогона: у какой базы distinct_ratio в категории 1 на порядок меньше.
   Колонки — из списка «ожидаем» §0; выводятся только счётчики и суммы.
SELECT category,
       COUNT(*) AS rows_n,
       SUM(CASE WHEN balance > 0 THEN 1 ELSE 0 END)               AS rows_bal_pos,
       COUNT(DISTINCT CASE WHEN balance > 0
             THEN ROUND(CAST(provisions_total AS decimal(38,6))
                        / CAST(balance AS decimal(38,6)), 4) END)  AS distinct_ratio_bal,
       SUM(CASE WHEN balance_with_discount > 0 THEN 1 ELSE 0 END) AS rows_disc_pos,
       COUNT(DISTINCT CASE WHEN balance_with_discount > 0
             THEN ROUND(CAST(provisions_total AS decimal(38,6))
                        / CAST(balance_with_discount AS decimal(38,6)), 4) END) AS distinct_ratio_disc,
       SUM(CASE WHEN balance <> balance_with_discount THEN 1 ELSE 0 END) AS rows_bal_ne_disc
FROM [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2]
WHERE [date] = @AsOf AND ISNULL(tag, '') <> '11'
GROUP BY category
ORDER BY category
OPTION (MAXDOP 1);
*/
GO

/* §3. HISTORY: корзины по DPD за три месяца на портфеле 01.10.2026.
   DPD в сетке — nvarchar; кавычки входят в имя колонки (D15_E_defaultbase.sql).
   Если §0 не показал ['01.10.2026'] — убрать эту колонку и прислать как есть.
   #A0_port создаётся здесь и используется в §4 и §5.                              */
DECLARE @AsOf date = '2026-10-01';

IF OBJECT_ID('tempdb..#A0_port') IS NOT NULL DROP TABLE #A0_port;
SELECT DISTINCT contract_number, category
INTO #A0_port
FROM [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2]
WHERE [date] = @AsOf
OPTION (MAXDOP 1);

SELECT m.mon, p.category,
       CASE WHEN h.account_number IS NULL            THEN '0 нет в HISTORY'
            WHEN m.v IS NULL                         THEN '1 NULL'
            WHEN TRY_CAST(m.v AS int) IS NULL        THEN '2 не число'
            WHEN TRY_CAST(m.v AS int) BETWEEN 0 AND 29  THEN '3 0–29'
            WHEN TRY_CAST(m.v AS int) BETWEEN 30 AND 90 THEN '4 30–90'
            WHEN TRY_CAST(m.v AS int) >= 91          THEN '5 91+'
            ELSE '6 отрицательный' END               AS dpd_bucket,
       COUNT(*) AS contracts
FROM #A0_port p
LEFT JOIN [CL_PORTFOLIO].[dbo].[HISTORY_DEFAULT_ACCOUNT] h
       ON h.account_number = p.contract_number
CROSS APPLY (VALUES ('2026-08', h.['01.08.2026']),
                    ('2026-09', h.['01.09.2026']),
                    ('2026-10', h.['01.10.2026'])) m(mon, v)
GROUP BY m.mon, p.category,
       CASE WHEN h.account_number IS NULL            THEN '0 нет в HISTORY'
            WHEN m.v IS NULL                         THEN '1 NULL'
            WHEN TRY_CAST(m.v AS int) IS NULL        THEN '2 не число'
            WHEN TRY_CAST(m.v AS int) BETWEEN 0 AND 29  THEN '3 0–29'
            WHEN TRY_CAST(m.v AS int) BETWEEN 30 AND 90 THEN '4 30–90'
            WHEN TRY_CAST(m.v AS int) >= 91          THEN '5 91+'
            ELSE '6 отрицательный' END
ORDER BY m.mon, p.category, dpd_bucket
OPTION (MAXDOP 1);
GO

/* §4. Покрытие ключом на 01.10.2026: старая база ↔ KAN ↔ новая база S03.
   Ключ S03 old↔new: contract_number → loans.l_loan_number, затем
   loans (l_gid, l_source) → loan_account (la_gid, la_source) — FINDINGS.md §1.
   KAN: account_number = contract_number (DATA_LINEAGE.md dpd15_cure).
   Снимок KAN: прогон 12.10.2026 (1a) показал последний KAN_20260901_for_LGD_Fenix
   (создан 25.09.2026); KAN_20261001 ещё нет — §4 первого прогона упал на Msg 208.
   Продукт по договору меняется редко, поэтому для покрытия берётся 20260901.
   Если §3 упал, сначала создать #A0_port его первым запросом.                     */
DECLARE @AsOf date = '2026-10-01';

IF OBJECT_ID('tempdb..#A0_new') IS NOT NULL DROP TABLE #A0_new;
SELECT DISTINCT l.l_loan_number AS contract_number, la.la_status
INTO #A0_new
FROM [Dictionaries].[risk_analytics].[loan_account] la
JOIN [Dictionaries].[risk_analytics].[loans] l
  ON l.l_gid = la.la_gid AND l.l_source = la.la_source
WHERE la.la_source = 'S03' AND la.la_reporting_date = @AsOf
OPTION (MAXDOP 1);

IF OBJECT_ID('tempdb..#A0_kan') IS NOT NULL DROP TABLE #A0_kan;
SELECT DISTINCT account_number
INTO #A0_kan
FROM [IFRS9].[dbo].[KAN_20260901_for_LGD_Fenix]      -- последний на 12.10.2026, см. 1a
OPTION (MAXDOP 1);

-- 4a. Дубли ключа в новой базе (один номер — несколько gid/статусов).
SELECT COUNT(*) AS rows_n, COUNT(DISTINCT contract_number) AS contracts
FROM #A0_new;

-- 4b. Матрица покрытия.
SELECT CASE WHEN o.contract_number IS NOT NULL AND n.contract_number IS NOT NULL THEN '1 old+new'
            WHEN o.contract_number IS NOT NULL THEN '2 только old'
            ELSE '3 только new' END                       AS cover,
       CASE WHEN k.account_number IS NOT NULL THEN 'есть в KAN' ELSE 'нет в KAN' END AS kan,
       COALESCE(n.la_status, '—')                         AS new_status,
       COUNT(*)                                           AS contracts
FROM #A0_port o
FULL JOIN (SELECT contract_number, MIN(la_status) AS la_status
           FROM #A0_new GROUP BY contract_number) n
       ON n.contract_number = o.contract_number
LEFT JOIN #A0_kan k
       ON k.account_number = COALESCE(o.contract_number, n.contract_number)
GROUP BY CASE WHEN o.contract_number IS NOT NULL AND n.contract_number IS NOT NULL THEN '1 old+new'
              WHEN o.contract_number IS NOT NULL THEN '2 только old'
              ELSE '3 только new' END,
         CASE WHEN k.account_number IS NOT NULL THEN 'есть в KAN' ELSE 'нет в KAN' END,
         COALESCE(n.la_status, '—')
ORDER BY cover, kan, new_status
OPTION (MAXDOP 1);
GO

/* §5. ΔV на общих договорах (old+new) — TRACK_A_PLAN §4, отзыв Г-TA-1.
   V_new = total_balance_debt; V_old — в двух вариантах (balance и
   balance_with_discount), выбор за автором (TRACK_A_PLAN §9 п. 4).
   Σ(ΔV) и Σ|ΔV| считаются по договору, затем агрегируются: построчного вывода нет.
   Сумма Σ ΔV мала ≠ ΔV мал: смотреть dV_abs_*, именно он ограничивает эффект на
   провизии (|ΔP| ≤ max(r) · Σ|ΔV|).
   Строк в новой базе на номер может быть больше одной (4a) — V_new суммируется,
   число таких договоров выводится отдельно, чтобы дубль не прятался в ΔV.        */
DECLARE @AsOf date = '2026-10-01';

IF OBJECT_ID('tempdb..#A0_vold') IS NOT NULL DROP TABLE #A0_vold;
SELECT contract_number,
       MIN(category)                                     AS category,
       MAX(CASE WHEN tag = '11' THEN 1 ELSE 0 END)       AS is_written_off,
       COUNT(*)                                          AS rows_n,
       SUM(CAST(balance AS decimal(38,2)))               AS v_old_bal,
       SUM(CAST(balance_with_discount AS decimal(38,2))) AS v_old_disc
INTO #A0_vold
FROM [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2]
WHERE [date] = @AsOf
GROUP BY contract_number
OPTION (MAXDOP 1);

IF OBJECT_ID('tempdb..#A0_vnew') IS NOT NULL DROP TABLE #A0_vnew;
SELECT l.l_loan_number                                   AS contract_number,
       COUNT(*)                                          AS rows_n,
       SUM(CAST(la.total_balance_debt AS decimal(38,2))) AS v_new
INTO #A0_vnew
FROM [Dictionaries].[risk_analytics].[loan_account] la
JOIN [Dictionaries].[risk_analytics].[loans] l
  ON l.l_gid = la.la_gid AND l.l_source = la.la_source
WHERE la.la_source = 'S03' AND la.la_reporting_date = @AsOf
GROUP BY l.l_loan_number
OPTION (MAXDOP 1);

-- 5a. ΔV по category × списан/на балансе + итог (строка с category = NULL, is_total = 1).
SELECT o.category,
       CASE WHEN o.is_written_off = 1 THEN 'списан' ELSE 'на балансе' END AS tag_grp,
       GROUPING(o.category)                                               AS is_total,
       COUNT(*)                                                           AS contracts,
       SUM(CASE WHEN n.rows_n > 1 OR o.rows_n > 1 THEN 1 ELSE 0 END)     AS contracts_multirow,
       SUM(CASE WHEN n.v_new IS NULL THEN 1 ELSE 0 END)                   AS v_new_null,
       SUM(CASE WHEN o.v_old_bal IS NULL THEN 1 ELSE 0 END)               AS v_old_bal_null,
       SUM(o.v_old_bal)                                                   AS sum_v_old_bal,
       SUM(o.v_old_disc)                                                  AS sum_v_old_disc,
       SUM(n.v_new)                                                       AS sum_v_new,
       SUM(n.v_new - o.v_old_bal)                                         AS dv_bal,
       SUM(ABS(n.v_new - o.v_old_bal))                                    AS dv_abs_bal,
       SUM(n.v_new - o.v_old_disc)                                        AS dv_disc,
       SUM(ABS(n.v_new - o.v_old_disc))                                   AS dv_abs_disc,
       SUM(CASE WHEN ABS(n.v_new - o.v_old_bal) > 0.01 THEN 1 ELSE 0 END) AS contracts_dv_bal_ne0
FROM #A0_vold o
JOIN #A0_vnew n ON n.contract_number = o.contract_number
GROUP BY GROUPING SETS ((o.category,
                         CASE WHEN o.is_written_off = 1 THEN 'списан' ELSE 'на балансе' END),
                        ())
ORDER BY is_total, o.category, tag_grp
OPTION (MAXDOP 1);

-- 5b. Бакеты величины |V_new − V_old(balance)|: сколько договоров и сколько денег
--     в каждом. Худшие случаи — бакетом, не идентификатором (§4 CLAUDE.md).
SELECT b.bucket,
       COUNT(*)                         AS contracts,
       SUM(b.dv)                        AS dv_bal,
       SUM(ABS(b.dv))                   AS dv_abs_bal
FROM (SELECT n.v_new - o.v_old_bal AS dv,
             CASE WHEN n.v_new IS NULL OR o.v_old_bal IS NULL      THEN '0 NULL с одной из сторон'
                  WHEN ABS(n.v_new - o.v_old_bal) <= 0.01          THEN '1 <= 0,01'
                  WHEN ABS(n.v_new - o.v_old_bal) <= 1000          THEN '2 <= 1 тыс'
                  WHEN ABS(n.v_new - o.v_old_bal) <= 100000        THEN '3 <= 100 тыс'
                  WHEN ABS(n.v_new - o.v_old_bal) <= 10000000      THEN '4 <= 10 млн'
                  ELSE                                                  '5 > 10 млн' END AS bucket
      FROM #A0_vold o
      JOIN #A0_vnew n ON n.contract_number = o.contract_number) b
GROUP BY b.bucket
ORDER BY b.bucket
OPTION (MAXDOP 1);

/* 5c. ШАБЛОН, НЕ ЗАПУСКАТЬ до подтверждения имён по §0.
   P_new по категориям старой базы на общих договорах — для формы TRACK_A_PLAN §3.
   la_account_1428 / la_account_1845 / la_account_18771 — проверить по §0.
SELECT o.category,
       SUM(CAST(la.la_account_1428  AS decimal(38,2))) AS p_new_1428,
       SUM(CAST(la.la_account_1845  AS decimal(38,2))) AS p_new_1845,
       SUM(CAST(la.la_account_18771 AS decimal(38,2))) AS p_new_18771
FROM [Dictionaries].[risk_analytics].[loan_account] la
JOIN [Dictionaries].[risk_analytics].[loans] l
  ON l.l_gid = la.la_gid AND l.l_source = la.la_source
JOIN #A0_vold o ON o.contract_number = l.l_loan_number
WHERE la.la_source = 'S03' AND la.la_reporting_date = @AsOf
GROUP BY o.category
ORDER BY o.category
OPTION (MAXDOP 1);
*/
GO

IF OBJECT_ID('tempdb..#A0_port') IS NOT NULL DROP TABLE #A0_port;
IF OBJECT_ID('tempdb..#A0_new')  IS NOT NULL DROP TABLE #A0_new;
IF OBJECT_ID('tempdb..#A0_kan')  IS NOT NULL DROP TABLE #A0_kan;
IF OBJECT_ID('tempdb..#A0_vold') IS NOT NULL DROP TABLE #A0_vold;
IF OBJECT_ID('tempdb..#A0_vnew') IS NOT NULL DROP TABLE #A0_vnew;
