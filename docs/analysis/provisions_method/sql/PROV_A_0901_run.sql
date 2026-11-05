/* =============================================================================
   PROV_A_0901_run.sql — Track A, прогонный пакет на 01.09.2026 (решение Р-10).
   Issue #164, план — TRACK_A_PLAN.md §14. Запускает Мирас на рабочем ПК.

   Что в этом файле:
     §0  — выполняемая проверка готовности. Запустить ПЕРВЫМ и отдельно.
           Если в итоговой строке §0e go_no_go = 'STOP', дальше не идти: прислать
           вывод §0 целиком.
     §1  — порядок запуска остальных скриптов (текстом, ниже) и что прислать.
   Остальные скрипты не вставлены сюда копией: один текст на скрипт, иначе две версии
   разойдутся. Все — в этой же папке, @AsOf = 2026-09-01 уже стоит в каждом батче.

   Правила (§4 корневого CLAUDE.md): только SELECT, #temp с префиксом файла
   (#RUN_*), MAXDOP 1, трёхчастные имена, IIN не выбирается. Наружу — только
   агрегаты, как в прогоне 01.10.
   ============================================================================= */

/* §0a. Срез новой базы: loan_account S03 на 2026-09-01 существует?
   Соседние даты выводятся, чтобы при пустом 01.09 было видно, под какой датой
   лежит месяц (например, 2026-08-31). Ожидание: строк на 2026-09-01 > 0, порядок
   величины — как на 01.10 (212 774 номера S03, Д-A0-6).                         */
SELECT la_reporting_date,
       COUNT(*)                AS rows_n,
       COUNT(DISTINCT la_gid)  AS gids
FROM [Dictionaries].[risk_analytics].[loan_account]
WHERE la_source = 'S03'
  AND la_reporting_date BETWEEN '2026-08-01' AND '2026-10-01'
GROUP BY la_reporting_date
ORDER BY la_reporting_date
OPTION (MAXDOP 1);
GO

/* §0b. Срез старой базы: CL_PORTFOLIO_2 на 2026-09-01 существует?
   Ожидание: строк > 0; на 01.10 было 214 240 (строка = договор, Д-A0-1).         */
SELECT [date],
       COUNT(*)                         AS rows_n,
       COUNT(DISTINCT contract_number)  AS contracts
FROM [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2]
WHERE [date] BETWEEN '2026-08-01' AND '2026-10-01'
GROUP BY [date]
ORDER BY [date]
OPTION (MAXDOP 1);
GO

/* §0c. Объекты: снимки KAN отчётной даты.                                         */
SELECT name AS kan_table, create_date, modify_date
FROM [IFRS9].sys.tables
WHERE name IN ('KAN_20260901_for_LGD_Fenix', 'KAN_20260901_restructura')
ORDER BY name;
GO

/* §0d. Все имена колонок, на которые опираются A0…A0f и A13, — против живого
   INFORMATION_SCHEMA. Выводятся только отсутствующие. Пустой вывод = всё на месте.
   Колонки HISTORY — с кавычками в имени (h.['01.09.2026']). Сравнение имён —
   с COLLATE DATABASE_DEFAULT: #temp живёт в tempdb, его сортировка может отличаться.  */
IF OBJECT_ID('tempdb..#RUN_need') IS NOT NULL DROP TABLE #RUN_need;
CREATE TABLE #RUN_need (db sysname, tbl sysname, col sysname);
INSERT INTO #RUN_need (db, tbl, col)
SELECT 'CL_PORTFOLIO', 'CL_PORTFOLIO_2', c FROM (VALUES
  ('contract_number'),('date'),('dpd'),('category'),('tag'),('balance'),
  ('balance_with_discount'),('provisions_total'),('provisions_calculated'),('ifrs'),
  ('IFRS1845'),('ifrs18771_WTRAF_i_PENII'),('ifrs18770_DEB'),('IFRS1877'),('status'),
  ('tag_1'),('attribute_marker'),('fiziki/yuriki'),('basket'),('product'),('subproduct'),
  ('percent'),('discount_1434'),('discount_1435'),('discount_1773'),('discount_1774'),
  ('discount_1775'),('discount_1784'),('DISCOUNT_1484'),('DISCOUNT_1485'),
  ('DISCOUNT_14341'),('DISCOUNT_14342'),('DISCOUNT_17731'),('DISCOUNT_17732'),('fees_1860')
) v(c)
UNION ALL
SELECT 'CL_PORTFOLIO', 'HISTORY_DEFAULT_ACCOUNT', c FROM (VALUES
  ('account_number'),('''01.07.2026'''),('''01.08.2026'''),('''01.09.2026''')
) v(c)
UNION ALL
SELECT 'Dictionaries', 'loan_account', c FROM (VALUES
  ('la_gid'),('la_source'),('la_reporting_date'),('la_status'),('total_balance_debt'),
  ('days_past_due'),('discounted_balance_debt'),
  ('la_account_1428'),('la_account_1845'),('la_account_18771')
) v(c)
UNION ALL
SELECT 'Dictionaries', 'loans', c FROM (VALUES
  ('l_gid'),('l_source'),('l_loan_number')
) v(c)
UNION ALL
SELECT 'IFRS9', 'KAN_20260901_for_LGD_Fenix', c FROM (VALUES
  ('account_number'),('subproduct')
) v(c)
UNION ALL
SELECT 'IFRS9', 'KAN_PD_LGD_Product_Basket', c FROM (VALUES
  ('Product'),('Basket'),('PD'),('LGD'),('LGD+TV'),('Date')
) v(c);

IF OBJECT_ID('tempdb..#RUN_have') IS NOT NULL DROP TABLE #RUN_have;
SELECT 'CL_PORTFOLIO' AS db, TABLE_NAME AS tbl, COLUMN_NAME AS col
INTO #RUN_have
FROM [CL_PORTFOLIO].INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'dbo' AND TABLE_NAME IN ('CL_PORTFOLIO_2', 'HISTORY_DEFAULT_ACCOUNT')
UNION ALL
SELECT 'Dictionaries', TABLE_NAME, COLUMN_NAME
FROM [Dictionaries].INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'risk_analytics' AND TABLE_NAME IN ('loan_account', 'loans')
UNION ALL
SELECT 'IFRS9', TABLE_NAME, COLUMN_NAME
FROM [IFRS9].INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'dbo'
  AND TABLE_NAME IN ('KAN_20260901_for_LGD_Fenix', 'KAN_PD_LGD_Product_Basket');

SELECT r.db, r.tbl, r.col AS missing_column
FROM #RUN_need r
LEFT JOIN #RUN_have h ON h.db  = r.db  COLLATE DATABASE_DEFAULT
                     AND h.tbl = r.tbl COLLATE DATABASE_DEFAULT
                     AND h.col = r.col COLLATE DATABASE_DEFAULT
WHERE h.col IS NULL
ORDER BY r.db, r.tbl, r.col;
GO

/* §0e. Итог: одна строка. go_no_go = 'GO' только если все пять условий выполнены.
   hist_0901_* — заполненность колонки отчётного месяца на портфеле 01.09: критерий
   шага 0 (#164) — «нет в HISTORY» + NULL + «не число» ≤ 1 % договоров. Это условие
   Р-10: решение держится на том, что колонка 01.09 заполнена (Д-A0-3).             */
DECLARE @AsOf date = '2026-09-01';

DECLARE @la_rows   bigint = (SELECT COUNT(*) FROM [Dictionaries].[risk_analytics].[loan_account]
                             WHERE la_source = 'S03' AND la_reporting_date = @AsOf);
DECLARE @old_rows  bigint = (SELECT COUNT(*) FROM [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2]
                             WHERE [date] = @AsOf);
DECLARE @kan_n     int    = (SELECT COUNT(*) FROM [IFRS9].sys.tables
                             WHERE name IN ('KAN_20260901_for_LGD_Fenix', 'KAN_20260901_restructura'));
DECLARE @missing_n int    = (SELECT COUNT(*) FROM #RUN_need r
                             LEFT JOIN #RUN_have h ON h.db  = r.db  COLLATE DATABASE_DEFAULT
                                                  AND h.tbl = r.tbl COLLATE DATABASE_DEFAULT
                                                  AND h.col = r.col COLLATE DATABASE_DEFAULT
                             WHERE h.col IS NULL);

IF OBJECT_ID('tempdb..#RUN_hist') IS NOT NULL DROP TABLE #RUN_hist;
CREATE TABLE #RUN_hist (contracts bigint, hist_absent bigint, hist_null bigint, hist_not_int bigint);

-- Колонка ['01.09.2026'] связывается при компиляции: если её нет, этот батч упал бы
-- целиком. Поэтому запрос — динамический и только при наличии колонки (§0d).
IF NOT EXISTS (SELECT 1 FROM #RUN_need r
               LEFT JOIN #RUN_have h ON h.db  = r.db  COLLATE DATABASE_DEFAULT
                                    AND h.tbl = r.tbl COLLATE DATABASE_DEFAULT
                                    AND h.col = r.col COLLATE DATABASE_DEFAULT
               WHERE h.col IS NULL AND r.tbl = 'HISTORY_DEFAULT_ACCOUNT')
  EXEC sp_executesql N'
    INSERT INTO #RUN_hist
    SELECT COUNT(*),
           SUM(CASE WHEN h.account_number IS NULL THEN 1 ELSE 0 END),
           SUM(CASE WHEN h.account_number IS NOT NULL AND h.[''01.09.2026''] IS NULL THEN 1 ELSE 0 END),
           SUM(CASE WHEN h.[''01.09.2026''] IS NOT NULL
                     AND TRY_CAST(h.[''01.09.2026''] AS int) IS NULL THEN 1 ELSE 0 END)
    FROM (SELECT DISTINCT contract_number FROM [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2]
          WHERE [date] = @d) p
    LEFT JOIN [CL_PORTFOLIO].[dbo].[HISTORY_DEFAULT_ACCOUNT] h
           ON h.account_number = p.contract_number
    OPTION (MAXDOP 1);', N'@d date', @d = @AsOf;

SELECT @la_rows   AS la_s03_rows_0901,
       @old_rows  AS cl2_rows_0901,
       @kan_n     AS kan_tables_found,          -- ожидается 2
       @missing_n AS missing_columns,           -- ожидается 0
       h.contracts, h.hist_absent, h.hist_null, h.hist_not_int,
       CAST(100.0 * (h.hist_absent + h.hist_null + h.hist_not_int)
            / NULLIF(h.contracts, 0) AS decimal(9,4)) AS hist_gap_pct,
       CASE WHEN @la_rows > 0 AND @old_rows > 0 AND @kan_n = 2 AND @missing_n = 0
             AND h.contracts > 0
             AND 1.0 * (h.hist_absent + h.hist_null + h.hist_not_int) / h.contracts <= 0.01
            THEN 'GO' ELSE 'STOP' END                 AS go_no_go
FROM (SELECT 1 AS one) x
LEFT JOIN #RUN_hist h ON 1 = 1;
GO

IF OBJECT_ID('tempdb..#RUN_need') IS NOT NULL DROP TABLE #RUN_need;
IF OBJECT_ID('tempdb..#RUN_have') IS NOT NULL DROP TABLE #RUN_have;
IF OBJECT_ID('tempdb..#RUN_hist') IS NOT NULL DROP TABLE #RUN_hist;
GO

/* =============================================================================
   §1. ПОРЯДОК ЗАПУСКА (только после go_no_go = 'GO')

   Каждый скрипт — целиком, в ОДНОМ соединении (батчи разделены GO; при запуске
   через scripts/db.py текст делить по строкам «GO» вручную — #temp живут до конца
   сессии). Между скриптами соединение можно менять. Результат — CSV на ПК; в #164
   (или в чат сессии) — выводы ниже, как есть: все они агрегаты.

   №  Скрипт                 Разделы → что прислать                      Стоп-условие
   -- ---------------------- ------------------------------------------- ------------------------------
   1  PROV_A0_recon.sql      §0 (полный список колонок), §1a, §1b,         §2: строки tag = '11' есть →
                             §2, §3, §4a, §4b, §5a, §5b.                   решение §9 п. 5 до A13.
                             §1c — только если §1b показал дату,           §4a: rows_n > contracts → дубли
                             отличную от 2020-12-01 / 2021-01-01.          ключа, разбирать до A13.
   2  PROV_A0b_probe.sql     §1, §2a, §2b, §3, §3b, §4.                    §1: rows_identity_broken > 0 →
                                                                           состав P_old изменился, A13
                                                                           не запускать.
   3  PROV_A0c_probe.sql     §1, §2, §3, §4, §5, §6.                       §1: категория 1 — доля
                                                                           match_pct100_disc < 95 % →
                                                                           правило ставка × bwd не
                                                                           держится, A13 не запускать.
   4  PROV_A0d_probe.sql     §1, §2.                                       — (диагностика)
   5  PROV_A0f_bwd.sql       §1, §1b, §2.                                  §1: match_001 < 99 % договоров
                                                                           в категориях 1–3 → V_new для
                                                                           моста не подтверждена,
                                                                           A13 не запускать.
   6  PROV_A13_bridge.sql    §3a, §3b, §3c, §3d, §3e.                      §3b: eps ≠ 0 → ошибка скрипта.
   7  PROV_A0e_probe.sql     §0, §1. НЕОБЯЗАТЕЛЬНО: это первый скрипт      §0: ключ restructura назван не
                             шага 2 (воспроизведение категорий), не         account_number → поправить
                             моста; запускать по решению Мираса.            одну строку §1 и перезапустить.

   Почему такой порядок: стоп-условия 1–3 и 5 — предпосылки A13 (состав P_old,
   правило «ставка × bwd», база V_new). Если хоть одно не выполнено, A13 на 01.09
   посчитает разложение, но его слагаемые будут значить не то, что на 01.10.
   A0d стоит до A0f, как в прогоне 01.10; на мост A0d не влияет.

   Что сверить сразу после прогона (контроли E4 A13, без новой логики):
     Σ p_old_total A13 §3a  = Σ sum_provisions   A0 §2   (01.09)
     Σ p_new       A13 §3a  = Σ p_new A0c §3 + Σ p_new A0c §4
     E1b A13 §3e            = Σ dp_abs_bound A0f §1  (до копейки)

   Ожидания по каждой находке 01.10 и что будет означать расхождение —
   TRACK_A_PLAN.md §14.3. Они зафиксированы до этого прогона.

   Как формулировать результат моста (замечания Сайлау, §М6, в силе):
     • «A_old − P_old при ставке percent = арифметика, не проверка Методики»;
     • «ε = 0 — полнота моста, не валидация».
   ============================================================================= */
