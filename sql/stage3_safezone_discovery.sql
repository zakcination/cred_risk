/* =============================================================================
   ПРОСТЫМ ЯЗЫКОМ:
   Перед тем как строить 12-месячную симуляцию «безопасной зоны» DPD и считать
   re-default rate, нужно решить, ИЗ КАКОЙ таблицы брать «дата окончания
   реструктуры» на каждую из 12 отчётных дат. Ваш поиск по ключевым словам
   (0b в stage3_raw_extract.sql) нашёл НЕСКОЛЬКО кандидатов вместо одного:
     • KAN_20260601_for_LGD_Fenix          — уже используется (июнь 2026)
     • KAN_20250301_for_LGD_Fenix_DI_BI    — та же семья, март 2025 (другой суффикс!)
     • kan_0101_rus / kan_0106_rus         — Restructuring_End_Date, Max_Restructuring_Actual
     • Реструктуризация_RS$                — RS: журнал событий (FIELD_NAME/FIELD_VALUE)
     • AQR20xx_B1A/B1B/B3C_* (много копий)  — RESTR_DATE/RESTR_COUNT — это
       ЗАМОРОЖЕННЫЕ регуляторные выгрузки прошлых циклов AQR, часто с версиями
       (_v1, _V1_08042026) — НЕ использовать как «сырой» операционный источник:
       не факт, что совпадает по значениям с текущей CL_PORTFOLIO_2, и не месячные.
   Ни «период приостановки», ни «отмена реструктуризации» ни в одной таблице
   пока НЕ найдены. Этот скрипт не считает ничего — только профилирует
   кандидатов (сколько строк, сколько заполнено, диапазон дат) и ищет
   suspension/cancellation в RS-журнале событий, чтобы выбрать источник
   осознанно, а не наугад.
   -----------------------------------------------------------------------------
   Disambiguation discovery — profile the restructuring-end-date candidates
   surfaced by stage3_raw_extract.sql §0b before committing to one for the
   12-month DPD safe-zone / re-default simulation. No AQR quarterly exports —
   those are frozen regulatory snapshots, not a live monthly operational feed.
   T-SQL (Microsoft SQL Server).
   ============================================================================= */

-------------------------------------------------------------------------------
-- 1. Enumerate every KAN/kan-named table (both DBs) — is there really one per
--    month for a trailing 12-month window, or only the two we've spotted?
-------------------------------------------------------------------------------
SELECT t.name AS table_name, c.name AS column_name, ty.name AS data_type
FROM [IFRS9].sys.tables t
JOIN [IFRS9].sys.columns c ON c.object_id = t.object_id
JOIN [IFRS9].sys.types   ty ON ty.user_type_id = c.user_type_id
WHERE t.name LIKE 'KAN[_]%' OR t.name LIKE 'kan[_]%'
ORDER BY t.name, c.column_id;

SELECT t.name AS table_name, c.name AS column_name, ty.name AS data_type
FROM [CL_PORTFOLIO].sys.tables t
JOIN [CL_PORTFOLIO].sys.columns c ON c.object_id = t.object_id
JOIN [CL_PORTFOLIO].sys.types   ty ON ty.user_type_id = c.user_type_id
WHERE t.name LIKE 'KAN[_]%' OR t.name LIKE 'kan[_]%'
ORDER BY t.name, c.column_id;
/*
Вывод сохранён отдельно: docs/analysis/stage3_kan_table_inventory.md
  — полный перечень: 5 151 строка колонок, 311 таблиц в IFRS9 и 6 в
    CL_PORTFOLIO. Здесь оставлены только те строки, на которые опирается вывод
    Phase A, — иначе 5 154 строки дампа хоронят под собой ~140 строк
    собственно логики этого скрипта.

Что показал перечень (подробный разбор — в том же файле):
  • помесячного ряда не существует: таблицы датированы разрозненно, а не одна
    на отчётный месяц;
  • написание колонки с датой плавает внутри одного семейства («дата окончания
    реструктуры» / Restructuring_End_Date / date_restruk_end);
  • признака ОТМЕНЫ реструктуризации нет ни в одной из них — только дата
    окончания, то есть «отменена» и «истекла» неразличимы. Это и решило выбор
    в пользу [Dictionaries].restructuring_v2 (§4), у которого canc_date есть
    отдельным полем.

Колонки четырёх кандидатов (ключевые поля):

-- KAN_20260601_for_LGD_Fenix  (IFRS9) --
KAN_20260601_for_LGD_Fenix	account_number	nvarchar
KAN_20260601_for_LGD_Fenix	default_date	date
KAN_20260601_for_LGD_Fenix	default_date_old	date
KAN_20260601_for_LGD_Fenix	дата окончания реструктуры	date

-- KAN_20250301_for_LGD_Fenix_DI_BI  (CL_PORTFOLIO) --
KAN_20250301_for_LGD_Fenix_DI_BI	account_number	nvarchar
KAN_20250301_for_LGD_Fenix_DI_BI	default_date	date
KAN_20250301_for_LGD_Fenix_DI_BI	default_date_old	date
KAN_20250301_for_LGD_Fenix_DI_BI	дата окончания реструктуры	date

-- kan_0101_rus  (CL_PORTFOLIO) --
kan_0101_rus	Account_Number	nvarchar
kan_0101_rus	Default_Date	date
kan_0101_rus	Old_Default_Date	date
kan_0101_rus	Max_Restructuring_Actual	date
kan_0101_rus	Restructuring_End_Date	date

-- kan_0106_rus  (CL_PORTFOLIO) --
kan_0106_rus	Account_Number	nvarchar
kan_0106_rus	Default_Date	date
kan_0106_rus	Old_Default_Date	date
kan_0106_rus	Max_Restructuring_Actual	date
kan_0106_rus	Restructuring_End_Date	date

*/

-------------------------------------------------------------------------------
-- 2. Profile the 4 known candidates: row count, how many have a restructuring
--    end date at all, and the date's own range (sanity: does it look like a
--    real per-snapshot value, or a stale/frozen one?).
--    DB prefixes were originally a guess from the naming pattern (KAN_* → IFRS9,
--    kan_*_rus → CL_PORTFOLIO). §1's inventory settles them, and the guess was
--    wrong on one: KAN_20250301_for_LGD_Fenix_DI_BI lives in CL_PORTFOLIO
--    despite the KAN_ prefix — hence the Msg 208 in the recorded output below.
--    Prefix corrected here; the recorded output below predates the correction,
--    so that one row is still missing from it (noted under the results).
-------------------------------------------------------------------------------
SELECT 'KAN_20260601_for_LGD_Fenix' AS source_table,
       COUNT(*)                                       AS rows_total,
       COUNT([дата окончания реструктуры])             AS rows_with_restr_end_date,
       MIN([дата окончания реструктуры])                AS min_date,
       MAX([дата окончания реструктуры])                AS max_date
FROM [IFRS9].[dbo].[KAN_20260601_for_LGD_Fenix]
UNION ALL
SELECT 'KAN_20250301_for_LGD_Fenix_DI_BI',
       COUNT(*), COUNT([дата окончания реструктуры]),
       MIN([дата окончания реструктуры]), MAX([дата окончания реструктуры])
FROM [CL_PORTFOLIO].[dbo].[KAN_20250301_for_LGD_Fenix_DI_BI]
UNION ALL
SELECT 'kan_0101_rus',
       COUNT(*), COUNT([Restructuring_End_Date]),
       MIN([Restructuring_End_Date]), MAX([Restructuring_End_Date])
FROM [CL_PORTFOLIO].[dbo].[kan_0101_rus]
UNION ALL
SELECT 'kan_0106_rus',
       COUNT(*), COUNT([Restructuring_End_Date]),
       MIN([Restructuring_End_Date]), MAX([Restructuring_End_Date])
FROM [CL_PORTFOLIO].[dbo].[kan_0106_rus];

/*
Msg 208, Level 16, State 1, Line 1
Invalid object name 'IFRS9.dbo.KAN_20250301_for_LGD_Fenix_DI_BI'.


source_table	rows_total	rows_with_restr_end_date	min_date	max_date
KAN_20260601_for_LGD_Fenix	652169	192376	2015-10-01	2027-02-01
kan_0101_rus	600598	321120	1899-12-30	2027-11-01
kan_0106_rus	619822	177760	2015-10-01	2027-11-01

Три строки, не четыре: DI_BI отвалился по Msg 208 (префикс исправлен выше, но
этот вывод снят до правки и НЕ перезапускался). Профиль DI_BI остаётся
непроверенным — на выбор источника это не влияет: таблица датирована 03.2025,
то есть застывший снимок, а не помесячный ряд, и это видно уже по §1.

Что здесь важнее незакрытой строки: max_date уходит в 2027 год у всех трёх, а
kan_0101_rus отдаёт min_date = 1899-12-30 — нулевая дата Excel/OLE, то есть
пустое значение, приехавшее как дата, а не как NULL. Обе аномалии — про то,
что «дата окончания реструктуры» в этом семействе не валидируется на входе.
*/

-------------------------------------------------------------------------------
-- 3. Hunt for suspension-period / cancellation inside the RS restructuring
--    EVENT log (one row per field change — FIELD_NAME/FIELD_VALUE pairs).
--    If a "приостан.../suspens.../моратор.../отмен.../cancel..." value shows
--    up here, this table is the raw per-event source for §4 of
--    stage3_raw_extract.sql (RS-sourced loans only — Fenix/CL would need
--    their own equivalent, if one exists).
-------------------------------------------------------------------------------
SELECT DISTINCT [FIELD_NAME]
FROM [CL_PORTFOLIO].[dbo].[Реструктуризация_RS$]
ORDER BY [FIELD_NAME];

/*FIELD_NAME
Наличие реструктуризации*/
-------------------------------------------------------------------------------
-- 4. [Dictionaries] mart — only run if it appeared in §0c's sys.databases
--    list (stage3_raw_extract.sql). `restructuring_v2` is documented as an
--    EVENT table (one row per restructuring event) — exactly the shape
--    needed for "last restructurization" + "cancellation", covering all
--    source systems at once, if this login can actually reach it.
-------------------------------------------------------------------------------
SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE
FROM [Dictionaries].INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'restructuring_v2'
ORDER BY ORDINAL_POSITION;

/*
TABLE_NAME	COLUMN_NAME	DATA_TYPE
restructuring_v2	dlcr_gid	bigint
restructuring_v2	dlcr$source	nvarchar
restructuring_v2	loan_id	nvarchar
restructuring_v2	restructuring_date	date
restructuring_v2	new_interest_rate	float
restructuring_v2	days_past_due_at_restructuring	float
restructuring_v2	new_maturity_date	date
restructuring_v2	financial_deterioration_flag	nvarchar
restructuring_v2	payment_deferral	float
restructuring_v2	canc_date	date
restructuring_v2	grace_od_begin_date	date
restructuring_v2	grace_int_begin_date	date
restructuring_v2	grace_od_end_date	date
restructuring_v2	grace_int_end_date	date
restructuring_v2	report_date	date
*/
-------------------------------------------------------------------------------
-- Notes
-------------------------------------------------------------------------------
-- * Goal: pick ONE restructuring-end-date source with (a) full coverage across
--   the trailing 12 report months and (b) a low NULL rate, before the 12-month
--   safe-zone/re-default simulation is built on top of it. Whichever of §1-4
--   wins, the actual monthly loan-by-loan extract (mirroring stage3_
--   raw_extract.sql's pattern, one raw SELECT * per @AsOf) comes next.
-- * Nothing here computes a threshold or a re-default rate yet — that's
--   blocked on picking the source (this script) plus two methodology calls
--   (restructuring-covered clean months in/out of the safe-zone pool; re-default
--   monitoring horizon) that are the analyst's call, not a data question.
