/* ============================================================================
   RISK DWH RECONCILIATION — CONSOLIDATED SQL SCRIPT ARCHIVE
   ============================================================================

   Назначение: полная трассируемость КАЖДОГО SQL-запроса, прогнанного в этом
   расследовании — и со стороны Miras (ключи/grain/provisions/DPD по S02/S03/S17,
   интерактивная сессия), и со стороны коллеги (Sailau, письма + автономные
   proof/retest-скрипты DWH-01..16). Любое утверждение в FINDINGS.md или в
   реестре DWH-01..16 должно быть трассируемо до конкретного запроса ниже.

   Раздел A — запросы Miras (эта сессия, интерактивно, результаты уже в
              FINDINGS.md). Реконструированы по протоколу переписки; каждый —
              то, что реально исполнялось и вернуло цифры, вошедшие в §1-§7.
   Раздел B — скрипты Sailau, ВОСПРОИЗВЕДЕНЫ ДОСЛОВНО (не перефразированы) —
              для повторного запуска и независимой проверки его результатов.

   Все запросы read-only (SELECT + #temp), без вывода номеров договоров/ИИН/
   ФИО в агрегированные result set (см. правила CLAUDE.md).

   См. также: FINDINGS.md §9 — сверка с реестром DWH-01..16 (что подтверждает,
   что расширяет неисследованную территорию, что требует verify-or-deny).
   ============================================================================ */


/* ============================================================================
   ИНДЕКС

   A1  S02 — схема OLD (3 карточные таблицы) + NEW (loans/loan_account)
   A2  S02 — домен la_source + помесячная population (обрыв фев-2026)
   A3  S02 — grain-liveness трёх карточных таблиц на дату
   A4  S02 — overlap contract_number между тремя таблицами
   A5  S02 — ключ по покрытию: contract_number → l_loan_number
   A6  S02 — локализация ONLY_OLD (re-homing? gid в любом source?)
   A7  S02 — схема денежных/провизионных колонок OLD-карт
   A8  S02 — материальность ALL vs ONLY_OLD (zero/non-zero balance)
   A9  S03 — схема OLD (CL_PORTFOLIO_2)
   A10 S03 — grain-gate + периметр + bucket-сплит provisions (MATCHED/ONLY_OLD/ONLY_NEW × статус)
   A11 S03 — ONLY_NEW: разбивка по NEW-статусу (l_loan_status)
   A12 S03 — ONLY_NEW: провизии по статусу (где деньги)
   A13 S17 — схема OLD (PORTFOLIO_Fenix)
   A14 S17 — grain-gate + периметр + bucket-сплит provisions × Basket
   A15 S17 — DPD помесячный NULL-rate OLD vs NEW [ГИПОТЕЗА ОПРОВЕРГНУТА, см. B1]
   A16 S17 — DPD NULL-rate zero/non-zero balance [ГИПОТЕЗА ОПРОВЕРГНУТА, см. B1]
   A17 S17 — DPD incidence среди заполненных [ГИПОТЕЗА ОПРОВЕРГНУТА, см. B1]

   B1  DQ_PROOF_S17 — консолидированная доказательная сверка S17 (коллега)
       → здесь найдена настоящая DPD-метрика (match_pct((new-1),old) среди
         jointly non-null) и 4-way cross-pairing, закрывшие A15-A17.
   B2  DEVELOPER_PROOF_LOW_TEMPDB_20260701 — DWH-13..16 (borrower/ИИН/pledges)
   B3  Risk_DWH_Retest_Pack_20260716 (RETEST_01-06) — DWH-01..07 (периметр)
   B4  Risk_DWH_Retest_Pack_2_20260716 (RETEST_07-11) — DWH-08..12 (дубли/лимиты/суммы/статусы)
   ============================================================================ */


/* ============================================================================
   РАЗДЕЛ A — MIRAS / ASSISTANT (эта сессия)
   ============================================================================ */

-- ============================================================================
-- A1. S02 — схема OLD (3 карточные таблицы) + NEW (loans/loan_account)
-- Цель: ДО любого JOIN — ключ/дата/тип, не предполагать по имени.
-- Результат: contract_number varchar(20), одна collation во всех трёх; НЕТ
--            колонок ID/LOAN_ID_KR/loan_id вовсе. la_dog_num nvarchar(35),
--            l_loan_number varchar(255), la_gid/l_gid bigint.
-- ============================================================================
SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH, COLLATION_NAME
FROM CL_PORTFOLIO.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME IN ('PORTFOLIO_CREDITCARDS_WAY4',
                     'PORTFOLIO_CREDITCARDS_MIGR_WAY4',
                     'PORTFOLIO_CREDITCARDS_SMART_CARD')
  AND (COLUMN_NAME LIKE '%contract%' OR COLUMN_NAME LIKE '%loan%'
       OR COLUMN_NAME LIKE '%dog%'   OR COLUMN_NAME LIKE '%id%'
       OR COLUMN_NAME LIKE '%kr%'    OR COLUMN_NAME LIKE '%gid%'
       OR COLUMN_NAME LIKE '%date%')
ORDER BY TABLE_NAME, COLUMN_NAME;

SELECT TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH, COLLATION_NAME
FROM Dictionaries.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME IN ('loans','loan_account')
  AND (COLUMN_NAME LIKE '%loan_number%' OR COLUMN_NAME LIKE '%loan_id%'
       OR COLUMN_NAME LIKE '%dog%'  OR COLUMN_NAME LIKE '%gid%'
       OR COLUMN_NAME LIKE '%source%' OR COLUMN_NAME LIKE '%report%'
       OR COLUMN_NAME LIKE '%date%')
ORDER BY TABLE_NAME, COLUMN_NAME;
GO


-- ============================================================================
-- A2. S02 — домен la_source (population per source) + помесячная population S02
-- Цель: подтвердить S02 как код + локализовать обрыв.
-- Результат: S01=4838/S02=27824/S03=237386/S17=90597 rows_all=gids на 2026-07.
--            Помесячно S02: 185828(2026-01)→30973(02)→…→27824(07) — провал ровно
--            на 2026-02-01.
-- ============================================================================
DECLARE @dt date = '2026-07-01';
SELECT la_source, COUNT(*) AS rows_all, COUNT(DISTINCT la_gid) AS gids
FROM Dictionaries.risk_analytics.loan_account
WHERE la_reporting_date = @dt
GROUP BY la_source
ORDER BY la_source
OPTION (MAXDOP 1);

SELECT la_reporting_date, COUNT(*) AS rows_all, COUNT(DISTINCT la_gid) AS gids
FROM Dictionaries.risk_analytics.loan_account
WHERE la_source = 'S02' AND la_reporting_date >= '2025-07-01'
GROUP BY la_reporting_date
ORDER BY la_reporting_date
OPTION (MAXDOP 1);
GO


-- ============================================================================
-- A3. S02 — grain-liveness трёх карточных таблиц на @dt (+ до обрыва)
-- Результат: на 2026-07-01 непусты все три (WAY4 9073, MIGR_WAY4 85355,
--            SMART_CARD 57793 = 152 221) — OLD НЕ схлопывается.
-- ============================================================================
DECLARE @dt date='2026-07-01', @pre date='2026-01-01';
SELECT src, rows_pre, rows_cur, dist_cn_cur
FROM (
  SELECT 'WAY4' src,
     SUM(CASE WHEN [date]=@pre THEN 1 ELSE 0 END) rows_pre,
     SUM(CASE WHEN [date]=@dt  THEN 1 ELSE 0 END) rows_cur,
     COUNT(DISTINCT CASE WHEN [date]=@dt THEN contract_number END) dist_cn_cur
  FROM CL_PORTFOLIO.dbo.PORTFOLIO_CREDITCARDS_WAY4       WHERE [date] IN (@pre,@dt)
  UNION ALL SELECT 'MIGR_WAY4',
     SUM(CASE WHEN [date]=@pre THEN 1 ELSE 0 END),
     SUM(CASE WHEN [date]=@dt  THEN 1 ELSE 0 END),
     COUNT(DISTINCT CASE WHEN [date]=@dt THEN contract_number END)
  FROM CL_PORTFOLIO.dbo.PORTFOLIO_CREDITCARDS_MIGR_WAY4  WHERE [date] IN (@pre,@dt)
  UNION ALL SELECT 'SMART_CARD',
     SUM(CASE WHEN [date]=@pre THEN 1 ELSE 0 END),
     SUM(CASE WHEN [date]=@dt  THEN 1 ELSE 0 END),
     COUNT(DISTINCT CASE WHEN [date]=@dt THEN contract_number END)
  FROM CL_PORTFOLIO.dbo.PORTFOLIO_CREDITCARDS_SMART_CARD WHERE [date] IN (@pre,@dt)
) t
OPTION (MAXDOP 1);
GO


-- ============================================================================
-- A4. S02 — overlap contract_number между тремя таблицами на @dt
-- Результат: distinct_cn=152221, cn_in_2plus=0 — union безопасен, дедуп не нужен.
-- ============================================================================
DECLARE @dt date='2026-07-01';
;WITH u AS (
  SELECT contract_number,'W' t FROM CL_PORTFOLIO.dbo.PORTFOLIO_CREDITCARDS_WAY4       WHERE [date]=@dt
  UNION ALL SELECT contract_number,'M' FROM CL_PORTFOLIO.dbo.PORTFOLIO_CREDITCARDS_MIGR_WAY4  WHERE [date]=@dt
  UNION ALL SELECT contract_number,'S' FROM CL_PORTFOLIO.dbo.PORTFOLIO_CREDITCARDS_SMART_CARD WHERE [date]=@dt
)
SELECT COUNT(*) distinct_cn,
       SUM(CASE WHEN n_tab>=2 THEN 1 ELSE 0 END) cn_in_2plus
FROM (SELECT contract_number, COUNT(DISTINCT t) n_tab FROM u GROUP BY contract_number) g
OPTION (MAXDOP 1);
GO


-- ============================================================================
-- A5. S02 — ключ по покрытию: contract_number → l_loan_number vs → l_loan_id
-- Результат: old_distinct=152221, matched_lln=27257/27824 (97.96%),
--            matched_loanid=0 — loan_id не ключ, как и в S03.
-- ============================================================================
DECLARE @dt date='2026-07-01';
IF OBJECT_ID('tempdb..#old') IS NOT NULL DROP TABLE #old;
SELECT DISTINCT contract_number
INTO #old
FROM (
  SELECT contract_number FROM CL_PORTFOLIO.dbo.PORTFOLIO_CREDITCARDS_WAY4       WHERE [date]=@dt
  UNION ALL SELECT contract_number FROM CL_PORTFOLIO.dbo.PORTFOLIO_CREDITCARDS_MIGR_WAY4  WHERE [date]=@dt
  UNION ALL SELECT contract_number FROM CL_PORTFOLIO.dbo.PORTFOLIO_CREDITCARDS_SMART_CARD WHERE [date]=@dt
) u OPTION (MAXDOP 1);

IF OBJECT_ID('tempdb..#new') IS NOT NULL DROP TABLE #new;
SELECT l.l_loan_number, l.l_loan_id
INTO #new
FROM Dictionaries.risk_analytics.loan_account la
JOIN Dictionaries.risk_analytics.loans l ON l.l_gid = la.la_gid
WHERE la.la_source='S02' AND la.la_reporting_date=@dt
OPTION (MAXDOP 1);

SELECT
 (SELECT COUNT(*)                         FROM #old)                                             AS old_distinct,
 (SELECT COUNT(*)                         FROM #new)                                             AS new_rows,
 (SELECT COUNT(DISTINCT l_loan_number)    FROM #new)                                             AS new_distinct_lln,
 (SELECT COUNT(*) FROM #old o WHERE EXISTS (SELECT 1 FROM #new n WHERE n.l_loan_number=o.contract_number)) AS matched_lln,
 (SELECT COUNT(*) FROM #old o WHERE EXISTS (SELECT 1 FROM #new n WHERE n.l_loan_id    =o.contract_number)) AS matched_loanid,
 (SELECT COUNT(*) FROM #old o WHERE NOT EXISTS (SELECT 1 FROM #new n WHERE n.l_loan_number=o.contract_number)) AS only_old_lln
OPTION (MAXDOP 1);
GO


-- ============================================================================
-- A6. S02 — локализация ONLY_OLD (re-homing под другой source? gid в любом source?)
-- Результат: oldonly=124964, in_loans_any=124896, in_la_s02_pre=104283,
--            in_la_s02_anydate=110555, in_la_anysrc_cur=0 → re-homing DISPROVEN.
-- ============================================================================
DECLARE @dt date='2026-07-01', @pre date='2026-01-01';
IF OBJECT_ID('tempdb..#old') IS NOT NULL DROP TABLE #old;
SELECT DISTINCT contract_number INTO #old FROM (
  SELECT contract_number FROM CL_PORTFOLIO.dbo.PORTFOLIO_CREDITCARDS_WAY4       WHERE [date]=@dt
  UNION ALL SELECT contract_number FROM CL_PORTFOLIO.dbo.PORTFOLIO_CREDITCARDS_MIGR_WAY4  WHERE [date]=@dt
  UNION ALL SELECT contract_number FROM CL_PORTFOLIO.dbo.PORTFOLIO_CREDITCARDS_SMART_CARD WHERE [date]=@dt
) u OPTION (MAXDOP 1);
IF OBJECT_ID('tempdb..#new') IS NOT NULL DROP TABLE #new;
SELECT DISTINCT l.l_loan_number INTO #new
FROM Dictionaries.risk_analytics.loan_account la
JOIN Dictionaries.risk_analytics.loans l ON l.l_gid=la.la_gid
WHERE la.la_source='S02' AND la.la_reporting_date=@dt OPTION (MAXDOP 1);
IF OBJECT_ID('tempdb..#oldonly') IS NOT NULL DROP TABLE #oldonly;
SELECT o.contract_number INTO #oldonly
FROM #old o WHERE NOT EXISTS (SELECT 1 FROM #new n WHERE n.l_loan_number=o.contract_number);

SELECT
 (SELECT COUNT(*) FROM #oldonly) AS oldonly,
 (SELECT COUNT(*) FROM #oldonly o WHERE EXISTS
   (SELECT 1 FROM Dictionaries.risk_analytics.loans l
    WHERE l.l_loan_number=o.contract_number)) AS in_loans_any,
 (SELECT COUNT(*) FROM #oldonly o WHERE EXISTS
   (SELECT 1 FROM Dictionaries.risk_analytics.loan_account la
      JOIN Dictionaries.risk_analytics.loans l ON l.l_gid=la.la_gid
    WHERE l.l_loan_number=o.contract_number AND la.la_source='S02' AND la.la_reporting_date=@pre)) AS in_la_s02_pre,
 (SELECT COUNT(*) FROM #oldonly o WHERE EXISTS
   (SELECT 1 FROM Dictionaries.risk_analytics.loan_account la
      JOIN Dictionaries.risk_analytics.loans l ON l.l_gid=la.la_gid
    WHERE l.l_loan_number=o.contract_number AND la.la_source='S02')) AS in_la_s02_anydate,
 (SELECT COUNT(*) FROM #oldonly o WHERE EXISTS
   (SELECT 1 FROM Dictionaries.risk_analytics.loan_account la
      JOIN Dictionaries.risk_analytics.loans l ON l.l_gid=la.la_gid
    WHERE l.l_loan_number=o.contract_number AND la.la_reporting_date=@dt)) AS in_la_anysrc_cur
OPTION (MAXDOP 1);
GO


-- ============================================================================
-- A7. S02 — схема денежных/провизионных колонок трёх OLD-карт (для A8)
-- Результат: outstanding/od/balance/interest/penalties = float; ifrs/
--            provisions_calculated/IFRS1845/IFRS1877/ifrs18770_DEB/
--            ifrs18771_WTRAF_i_PENII = varchar (нужен TRY_CONVERT).
-- ============================================================================
SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE
FROM CL_PORTFOLIO.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME IN ('PORTFOLIO_CREDITCARDS_WAY4','PORTFOLIO_CREDITCARDS_MIGR_WAY4','PORTFOLIO_CREDITCARDS_SMART_CARD')
  AND (COLUMN_NAME LIKE '%outstanding%' OR COLUMN_NAME LIKE '%balance%'
       OR COLUMN_NAME LIKE '%overdue%'  OR COLUMN_NAME LIKE '%od%'
       OR COLUMN_NAME LIKE '%interest%' OR COLUMN_NAME LIKE '%ifrs%'
       OR COLUMN_NAME LIKE '%prov%'     OR COLUMN_NAME LIKE '%account%'
       OR COLUMN_NAME LIKE '%debt%'     OR COLUMN_NAME LIKE '%penal%')
ORDER BY TABLE_NAME, COLUMN_NAME;
GO


-- ============================================================================
-- A8. S02 — материальность: ALL vs ONLY_OLD (zero/non-zero balance)
-- Результат: ALL od_pos=21245/bal_pos=23290 (152221 всего); ONLY_OLD
--            od_pos=3855/bal_pos=3960, sum_od=366.3М, sum_balance=381.4М,
--            sum_overdue=84.47М — 99.3% всей overdue-суммы S02.
-- ============================================================================
DECLARE @dt date='2026-07-01';
IF OBJECT_ID('tempdb..#oldm') IS NOT NULL DROP TABLE #oldm;
SELECT contract_number, od, balance, outstanding_overdue,
       provisions_calculated AS prov_raw, TRY_CONVERT(float, provisions_calculated) AS prov
INTO #oldm
FROM (
  SELECT contract_number, od, balance, outstanding_overdue, provisions_calculated
    FROM CL_PORTFOLIO.dbo.PORTFOLIO_CREDITCARDS_WAY4       WHERE [date]=@dt
  UNION ALL SELECT contract_number, od, balance, outstanding_overdue, provisions_calculated
    FROM CL_PORTFOLIO.dbo.PORTFOLIO_CREDITCARDS_MIGR_WAY4  WHERE [date]=@dt
  UNION ALL SELECT contract_number, od, balance, outstanding_overdue, provisions_calculated
    FROM CL_PORTFOLIO.dbo.PORTFOLIO_CREDITCARDS_SMART_CARD WHERE [date]=@dt
) u OPTION (MAXDOP 1);

IF OBJECT_ID('tempdb..#new') IS NOT NULL DROP TABLE #new;
SELECT DISTINCT l.l_loan_number INTO #new
FROM Dictionaries.risk_analytics.loan_account la
JOIN Dictionaries.risk_analytics.loans l ON l.l_gid=la.la_gid
WHERE la.la_source='S02' AND la.la_reporting_date=@dt OPTION (MAXDOP 1);

SELECT scope, cnt, od_pos, bal_pos,
       CAST(sum_od AS decimal(38,2)) sum_od,
       CAST(sum_balance AS decimal(38,2)) sum_balance,
       CAST(sum_overdue AS decimal(38,2)) sum_overdue,
       CAST(sum_prov AS decimal(38,2)) sum_prov, prov_unparsed
FROM (
  SELECT 'ALL' scope, COUNT(*) cnt,
     SUM(CASE WHEN od>0 THEN 1 ELSE 0 END) od_pos,
     SUM(CASE WHEN balance>0 THEN 1 ELSE 0 END) bal_pos,
     SUM(od) sum_od, SUM(balance) sum_balance, SUM(outstanding_overdue) sum_overdue,
     SUM(prov) sum_prov,
     SUM(CASE WHEN prov IS NULL AND LTRIM(RTRIM(prov_raw))<>'' THEN 1 ELSE 0 END) prov_unparsed
  FROM #oldm
  UNION ALL
  SELECT 'ONLY_OLD', COUNT(*),
     SUM(CASE WHEN od>0 THEN 1 ELSE 0 END),
     SUM(CASE WHEN balance>0 THEN 1 ELSE 0 END),
     SUM(od), SUM(balance), SUM(outstanding_overdue), SUM(prov),
     SUM(CASE WHEN prov IS NULL AND LTRIM(RTRIM(prov_raw))<>'' THEN 1 ELSE 0 END)
  FROM #oldm m
  WHERE NOT EXISTS (SELECT 1 FROM #new n WHERE n.l_loan_number=m.contract_number)
) x OPTION (MAXDOP 1);
GO


-- ============================================================================
-- A9. S03 — схема OLD (CL_PORTFOLIO_2)
-- Результат: все провизионные numeric (не varchar, как у карт); status
--            varchar(100), contract_number varchar(30).
-- ============================================================================
SELECT COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH, COLLATION_NAME
FROM CL_PORTFOLIO.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'CL_PORTFOLIO_2'
  AND (COLUMN_NAME LIKE '%contract%' OR COLUMN_NAME LIKE '%status%'
       OR COLUMN_NAME LIKE '%ifrs%'   OR COLUMN_NAME LIKE '%1428%'
       OR COLUMN_NAME LIKE '%1845%'   OR COLUMN_NAME LIKE '%18770%'
       OR COLUMN_NAME LIKE '%18771%' OR COLUMN_NAME LIKE '%provision%'
       OR COLUMN_NAME LIKE '%balance%' OR COLUMN_NAME LIKE '%od%'
       OR COLUMN_NAME LIKE '%date%')
ORDER BY COLUMN_NAME
OPTION (MAXDOP 1);
GO


-- ============================================================================
-- A10. S03 — grain-gate + периметр + bucket-сплит provisions (MATCHED/ONLY_OLD/
--       ONLY_NEW × статус)
-- Результат: grain чист (237274=237274 / 237386=237386). MATCHED 234367,
--            ONLY_NEW 3019, ONLY_OLD 2907 — точно как в FINDINGS.
--            MATCHED Δ1428=+28.23М, Δ18771=+2.35М, доминанта "Открытый".
-- ============================================================================
DECLARE @dt date = '2026-07-01';

SELECT 'OLD' side, COUNT(*) rows_all, COUNT(DISTINCT contract_number) dist_cn
FROM CL_PORTFOLIO.dbo.CL_PORTFOLIO_2 WHERE [date] = @dt
UNION ALL
SELECT 'NEW', COUNT(*),
       COUNT(DISTINCT l.l_loan_number)
FROM Dictionaries.risk_analytics.loan_account la
JOIN Dictionaries.risk_analytics.loans l ON l.l_gid = la.la_gid
WHERE la.la_source = 'S03' AND la.la_reporting_date = @dt
OPTION (MAXDOP 1);

IF OBJECT_ID('tempdb..#old') IS NOT NULL DROP TABLE #old;
SELECT contract_number, status,
       ifrs AS old_1428, IFRS1845 AS old_1845, ifrs18771_WTRAF_i_PENII AS old_18771,
       provisions_total AS old_prov_total, balance AS old_balance
INTO #old
FROM CL_PORTFOLIO.dbo.CL_PORTFOLIO_2 WHERE [date] = @dt
OPTION (MAXDOP 1);

IF OBJECT_ID('tempdb..#new') IS NOT NULL DROP TABLE #new;
SELECT l.l_loan_number,
       la.la_account_1428 AS new_1428, la.la_account_1845 AS new_1845, la.la_account_18771 AS new_18771,
       (la.la_account_1428+la.la_account_1845+la.la_account_18771) AS new_prov_total,
       (la.la_account_1401+la.la_account_1403+la.la_account_1411+la.la_account_1417
        +la.la_account_1424+la.la_account_1740+la.la_account_1741
        +la.la_account_1879+la.la_account_1818+la.la_account_1838) AS new_balance
INTO #new
FROM Dictionaries.risk_analytics.loan_account la
JOIN Dictionaries.risk_analytics.loans l ON l.l_gid = la.la_gid
WHERE la.la_source = 'S03' AND la.la_reporting_date = @dt
OPTION (MAXDOP 1);

SELECT
  CASE WHEN o.contract_number IS NULL THEN 'ONLY_NEW'
       WHEN n.l_loan_number   IS NULL THEN 'ONLY_OLD'
       ELSE 'MATCHED' END AS bucket,
  ISNULL(o.status, 'n/a') AS old_status,
  COUNT(*) AS cnt,
  SUM(CASE WHEN ISNULL(n.new_balance,0)=0 AND ISNULL(o.old_balance,0)=0 THEN 1 ELSE 0 END) AS zero_balance_cnt,
  CAST(SUM(ISNULL(o.old_1428,0))       AS decimal(38,2)) AS sum_old_1428,
  CAST(SUM(ISNULL(n.new_1428,0))       AS decimal(38,2)) AS sum_new_1428,
  CAST(SUM(ISNULL(o.old_18771,0))      AS decimal(38,2)) AS sum_old_18771,
  CAST(SUM(ISNULL(n.new_18771,0))      AS decimal(38,2)) AS sum_new_18771,
  CAST(SUM(ISNULL(o.old_prov_total,0)) AS decimal(38,2)) AS sum_old_provtotal,
  CAST(SUM(ISNULL(n.new_prov_total,0)) AS decimal(38,2)) AS sum_new_provtotal
FROM #old o
FULL OUTER JOIN #new n ON n.l_loan_number = o.contract_number
GROUP BY
  CASE WHEN o.contract_number IS NULL THEN 'ONLY_NEW'
       WHEN n.l_loan_number   IS NULL THEN 'ONLY_OLD'
       ELSE 'MATCHED' END,
  ISNULL(o.status, 'n/a')
ORDER BY bucket, cnt DESC
OPTION (MAXDOP 1);
GO


-- ============================================================================
-- A11. S03 — ONLY_NEW: разбивка по NEW-статусу (l_loan_status)
-- Результат: V=1565(51.8%)/O=1249(41.4%)/C=147(4.9%)/I=58(1.9%) — плюрность V,
--            правит прежнюю формулировку "статус O".
-- ============================================================================
DECLARE @dt date = '2026-07-01';
SELECT l.l_loan_status, COUNT(*) cnt
FROM Dictionaries.risk_analytics.loan_account la
JOIN Dictionaries.risk_analytics.loans l ON l.l_gid = la.la_gid
WHERE la.la_source='S03' AND la.la_reporting_date=@dt
  AND NOT EXISTS (
    SELECT 1 FROM CL_PORTFOLIO.dbo.CL_PORTFOLIO_2 o
    WHERE o.contract_number = l.l_loan_number AND o.[date] = @dt)
GROUP BY l.l_loan_status
ORDER BY cnt DESC
OPTION (MAXDOP 1);
GO


-- ============================================================================
-- A12. S03 — ONLY_NEW: провизии по статусу
-- Результат: 18771 распределена ПРОПОРЦИОНАЛЬНО cnt по всем 4 статусам
--            (V 60.3%/O 36.5%/C 2.1%/I 1.2% денег vs 51.8/41.4/4.9/1.9% cnt)
--            → status-independent residual, не lifecycle-баг конкретного статуса.
-- ============================================================================
DECLARE @dt date = '2026-07-01';
SELECT l.l_loan_status,
       COUNT(*) cnt,
       CAST(SUM(la.la_account_1428)  AS decimal(38,2)) sum_1428,
       CAST(SUM(la.la_account_1845)  AS decimal(38,2)) sum_1845,
       CAST(SUM(la.la_account_18771) AS decimal(38,2)) sum_18771
FROM Dictionaries.risk_analytics.loan_account la
JOIN Dictionaries.risk_analytics.loans l ON l.l_gid = la.la_gid
WHERE la.la_source='S03' AND la.la_reporting_date=@dt
  AND NOT EXISTS (
    SELECT 1 FROM CL_PORTFOLIO.dbo.CL_PORTFOLIO_2 o
    WHERE o.contract_number = l.l_loan_number AND o.[date] = @dt)
GROUP BY l.l_loan_status
ORDER BY sum_18771 DESC
OPTION (MAXDOP 1);
GO


-- ============================================================================
-- A13. S17 — схема OLD (PORTFOLIO_Fenix)
-- Результат: contractnumber varchar(100); есть Basket, ifrs_1428, ifrs_1845,
--            ifrs_balance, `_1877` (изначально принят за "отсутствует" —
--            ОШИБКА, колонка есть, см. B1/A14); НЕТ status-колонки вовсе.
-- ============================================================================
SELECT COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH, COLLATION_NAME
FROM CL_PORTFOLIO.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'PORTFOLIO_Fenix'
ORDER BY COLUMN_NAME
OPTION (MAXDOP 1);
GO


-- ============================================================================
-- A14. S17 — grain-gate + периметр + bucket-сплит provisions × Basket
-- Результат: grain 1 коллизия dog_num/снимок (90597 rows vs 90596 distinct).
--            MATCHED 79617, ONLY_NEW 10980, ONLY_OLD 4 — совпадает с FINDINGS
--            (±1 от известной коллизии). 1428 почти идентичен (Δ базово шум),
--            18771 — вся дельта, доминанта Basket 3.
-- ============================================================================
DECLARE @dt date = '2026-07-01';

SELECT 'OLD' side, COUNT(*) rows_all, COUNT(DISTINCT contractnumber) dist_key
FROM CL_PORTFOLIO.dbo.PORTFOLIO_Fenix WHERE actual_date = @dt
UNION ALL
SELECT 'NEW', COUNT(*), COUNT(DISTINCT la_dog_num)
FROM Dictionaries.risk_analytics.loan_account
WHERE la_source='S17' AND la_reporting_date=@dt
OPTION (MAXDOP 1);

IF OBJECT_ID('tempdb..#old17') IS NOT NULL DROP TABLE #old17;
SELECT contractnumber, Basket AS old_basket,
       ifrs_1428 AS old_1428, ifrs_1845 AS old_1845, ifrs_balance AS old_balance
INTO #old17
FROM CL_PORTFOLIO.dbo.PORTFOLIO_Fenix WHERE actual_date = @dt
OPTION (MAXDOP 1);

IF OBJECT_ID('tempdb..#new17') IS NOT NULL DROP TABLE #new17;
SELECT la.la_dog_num, la.delinquency_bucket AS new_basket,
       la.la_account_1428 AS new_1428, la.la_account_1845 AS new_1845, la.la_account_18771 AS new_18771,
       (la.la_account_1401+la.la_account_1403+la.la_account_1411+la.la_account_1417
        +la.la_account_1424+la.la_account_1740+la.la_account_1741+la.la_account_1879) AS new_balance
INTO #new17
FROM Dictionaries.risk_analytics.loan_account la
WHERE la.la_source='S17' AND la.la_reporting_date=@dt
OPTION (MAXDOP 1);

SELECT
  CASE WHEN o.contractnumber IS NULL THEN 'ONLY_NEW'
       WHEN n.la_dog_num     IS NULL THEN 'ONLY_OLD'
       ELSE 'MATCHED' END AS bucket,
  ISNULL(o.old_basket,'n/a') AS old_basket,
  COUNT(*) cnt,
  SUM(CASE WHEN ISNULL(o.old_balance,0)=0 AND ISNULL(n.new_balance,0)=0 THEN 1 ELSE 0 END) zero_cnt,
  CAST(SUM(ISNULL(o.old_1428,0))   AS decimal(38,2)) sum_old_1428,
  CAST(SUM(ISNULL(n.new_1428,0))   AS decimal(38,2)) sum_new_1428,
  CAST(SUM(ISNULL(o.old_1845,0))   AS decimal(38,2)) sum_old_1845,
  CAST(SUM(ISNULL(n.new_1845,0))   AS decimal(38,2)) sum_new_1845,
  CAST(SUM(ISNULL(n.new_18771,0))  AS decimal(38,2)) sum_new_18771,
  CAST(SUM(ISNULL(o.old_balance,0)) AS decimal(38,2)) sum_old_balance,
  CAST(SUM(ISNULL(n.new_balance,0)) AS decimal(38,2)) sum_new_balance
FROM #old17 o
FULL OUTER JOIN #new17 n ON n.la_dog_num = o.contractnumber
GROUP BY
  CASE WHEN o.contractnumber IS NULL THEN 'ONLY_NEW'
       WHEN n.la_dog_num     IS NULL THEN 'ONLY_OLD'
       ELSE 'MATCHED' END,
  ISNULL(o.old_basket,'n/a')
ORDER BY bucket, cnt DESC
OPTION (MAXDOP 1);
GO


-- ============================================================================
-- A15. S17 — DPD помесячный NULL-rate OLD vs NEW (13 мес.)
-- [ГИПОТЕЗА ОПРОВЕРГНУТА] Ожидалось "июнь 0.036%→июль 78.92%" в NULL-rate —
-- реальность: NULL-rate стабильно 69-92% весь период, скачок на дек25→янв26
-- (68.55%→91.51%), не июнь→июль. Настоящая метрика найдена в B1 (Result 09).
-- ============================================================================
SELECT 'OLD' side, actual_date dt, COUNT(*) rows_all,
       SUM(CASE WHEN overdue_days_principal IS NULL THEN 1 ELSE 0 END) null_principal,
       SUM(CASE WHEN overdue_days_interest  IS NULL THEN 1 ELSE 0 END) null_interest,
       SUM(CASE WHEN max_overdue_days       IS NULL THEN 1 ELSE 0 END) null_max
FROM CL_PORTFOLIO.dbo.PORTFOLIO_Fenix
WHERE actual_date >= '2025-07-01'
GROUP BY actual_date
ORDER BY actual_date
OPTION (MAXDOP 1);

SELECT 'NEW' side, la_reporting_date dt, COUNT(*) rows_all,
       SUM(CASE WHEN days_past_due_principal              IS NULL THEN 1 ELSE 0 END) null_principal,
       SUM(CASE WHEN days_past_due_interest               IS NULL THEN 1 ELSE 0 END) null_interest,
       SUM(CASE WHEN max_days_past_due_principal_interest IS NULL THEN 1 ELSE 0 END) null_max
FROM Dictionaries.risk_analytics.loan_account
WHERE la_source='S17' AND la_reporting_date >= '2025-07-01'
GROUP BY la_reporting_date
ORDER BY la_reporting_date
OPTION (MAXDOP 1);
GO


-- ============================================================================
-- A16. S17 — DPD NULL-rate: zero vs non-zero balance, июнь+июль
-- [ГИПОТЕЗА ОПРОВЕРГНУТА] population-scope не объясняет разрыв: NONZERO
-- июнь 86.77% null, июль 86.45% null — тоже плоско.
-- ============================================================================
DECLARE @dt date='2026-07-01', @prev date='2026-06-01';
SELECT la_reporting_date dt,
       CASE WHEN (la_account_1401+la_account_1403+la_account_1411+la_account_1417
                  +la_account_1424+la_account_1740+la_account_1741+la_account_1879) = 0
            THEN 'ZERO' ELSE 'NONZERO' END AS balance_bucket,
       COUNT(*) cnt,
       SUM(CASE WHEN days_past_due_principal IS NULL THEN 1 ELSE 0 END) null_principal,
       SUM(CASE WHEN max_days_past_due_principal_interest IS NULL THEN 1 ELSE 0 END) null_max
FROM Dictionaries.risk_analytics.loan_account
WHERE la_source='S17' AND la_reporting_date IN (@prev, @dt)
GROUP BY la_reporting_date,
       CASE WHEN (la_account_1401+la_account_1403+la_account_1411+la_account_1417
                  +la_account_1424+la_account_1740+la_account_1741+la_account_1879) = 0
            THEN 'ZERO' ELSE 'NONZERO' END
ORDER BY dt, balance_bucket
OPTION (MAXDOP 1);
GO


-- ============================================================================
-- A17. S17 — DPD incidence среди заполненных значений, июнь vs июль
-- [ГИПОТЕЗА ОПРОВЕРГНУТА] среди заполненных 100% > 0 в ОБОИХ месяцах — не
-- варьируется, incidence вырожден. Настоящая метрика — см. B1 Result 09.
-- ============================================================================
DECLARE @dt date='2026-07-01', @prev date='2026-06-01';
SELECT la_reporting_date dt,
       COUNT(*) filled_cnt,
       SUM(CASE WHEN days_past_due_principal > 0 THEN 1 ELSE 0 END) gt0_cnt,
       SUM(CASE WHEN max_days_past_due_principal_interest > 0 THEN 1 ELSE 0 END) max_gt0_cnt
FROM Dictionaries.risk_analytics.loan_account
WHERE la_source='S17' AND la_reporting_date IN (@prev, @dt)
  AND days_past_due_principal IS NOT NULL
GROUP BY la_reporting_date
ORDER BY dt
OPTION (MAXDOP 1);
GO


/* ============================================================================
   РАЗДЕЛ B — КОЛЛЕГА (Sailau) — ДОСЛОВНО, КАК ПОЛУЧЕНО
   ============================================================================ */

-- ============================================================================
-- B1. DQ_PROOF_S17 — консолидированная доказательная сверка S17
-- Здесь найдена настоящая DPD-метрика (Result 09: match_pct((new_dpd-1),
-- old_dpd) среди jointly non-null) и 4-way cross-pairing, закрывшие июнь/
-- июль загадку (A15-A17 опровергнуты этим скриптом). Также: old_1877=0.00
-- на всех matched (Result 03/03_OLD_1877_VS_NEW_18771) — опровергло гипотезу
-- реклассификации, подтвердило "деньги genuinely новые" для 18771.
-- ============================================================================
/* ============================================================
   DQ_PROOF_S17
   КОНСОЛИДИРОВАННАЯ ДОКАЗАТЕЛЬНАЯ СВЕРКА S17

   OLD:
       [CL_PORTFOLIO].[dbo].[PORTFOLIO_Fenix]

   NEW:
       [Dictionaries].[risk_analytics].[loan_account]
       source = S17

   Основной межветочный ключ:
       contractnumber ↔ la_dog_num

   Контрольная дата:
       2026-07-01

   Дополнительная дата для проверки лага:
       2026-06-01

   Результаты:
       00_KEY_QUALITY
       01_POPULATION_BALANCE
       02_MATCHED_BALANCE
       03_PROVISION_METRICS
       04_FULL_PROVISION_CONTROL
       05_18771_LOCALIZATION
       06_DPD_SUMMARY
       07_90_PLUS
       08_BASKET
       09_TEMPORAL_DPD

   Постоянные таблицы не создаются.
   Номера договоров и идентификаторы не выводятся.
   ============================================================ */

SET NOCOUNT ON;

DECLARE @JulyDate date = '2026-07-01';
DECLARE @JuneDate date = '2026-06-01';
DECLARE @Source varchar(10) = 'S17';
DECLARE @AmountTolerance decimal(28,6) = 0.01;
DECLARE @RateTolerance decimal(28,6) = 0.0001;

DROP TABLE IF EXISTS #OldJuly;
DROP TABLE IF EXISTS #NewRawJuly;
DROP TABLE IF EXISTS #NewJuly;
DROP TABLE IF EXISTS #MatchedJuly;
DROP TABLE IF EXISTS #OldHistoryRaw;
DROP TABLE IF EXISTS #NewHistoryRaw;
DROP TABLE IF EXISTS #OldHistory;
DROP TABLE IF EXISTS #NewHistory;


/* ============================================================
   1. СТАРАЯ ВЕТКА — ИЮЛЬ
   ============================================================ */

SELECT
    CASE
        WHEN f.contractnumber IS NULL
          OR LTRIM(
                RTRIM(CONVERT(nvarchar(255), f.contractnumber))
             ) = ''
            THEN NULL
        ELSE
            UPPER(
                LTRIM(
                    RTRIM(CONVERT(nvarchar(255), f.contractnumber))
                )
            ) COLLATE DATABASE_DEFAULT
    END AS contract_key,

    TRY_CONVERT(decimal(28,6), f.ifrs_balance)
        AS old_balance,

    TRY_CONVERT(decimal(28,6), f.ifrs_1428)
        AS old_ifrs_1428,

    TRY_CONVERT(decimal(28,6), f.ifrs_1845)
        AS old_ifrs_1845,

    TRY_CONVERT(decimal(28,6), f.[_1877])
        AS old_ifrs_1877,

    TRY_CONVERT(decimal(28,6), f.ifrs_persent)
        AS old_reserve_percentage,

    TRY_CONVERT(decimal(28,6), f.overdue_days_principal)
        AS old_principal_dpd,

    TRY_CONVERT(decimal(28,6), f.overdue_days_interest)
        AS old_interest_dpd,

    TRY_CONVERT(decimal(28,6), f.max_overdue_days)
        AS old_max_dpd,

    TRY_CONVERT(decimal(28,6), f.[Basket])
        AS old_basket

INTO #OldJuly
FROM [CL_PORTFOLIO].[dbo].[PORTFOLIO_Fenix] f
WHERE f.actual_date >= @JulyDate
  AND f.actual_date < DATEADD(day, 1, @JulyDate);


/* ============================================================
   2. НОВАЯ ВЕТКА — ИЮЛЬ
   ============================================================ */

SELECT
    CASE
        WHEN la.la_dog_num IS NULL
          OR LTRIM(
                RTRIM(CONVERT(nvarchar(255), la.la_dog_num))
             ) = ''
            THEN NULL
        ELSE
            UPPER(
                LTRIM(
                    RTRIM(CONVERT(nvarchar(255), la.la_dog_num))
                )
            ) COLLATE DATABASE_DEFAULT
    END AS contract_key,

    TRY_CONVERT(decimal(38,0), la.la_loan_id)
        AS loan_id_key,

    CONVERT(nvarchar(255), la.la_status)
        AS new_status,

    TRY_CONVERT(decimal(28,6), la.total_balance_debt)
        AS new_balance,

    TRY_CONVERT(decimal(28,6), la.la_account_1428)
        AS new_ifrs_1428,

    TRY_CONVERT(decimal(28,6), la.la_account_1845)
        AS new_ifrs_1845,

    TRY_CONVERT(decimal(28,6), la.la_account_1877)
        AS new_ifrs_1877,

    TRY_CONVERT(decimal(28,6), la.la_account_18770)
        AS new_ifrs_18770,

    TRY_CONVERT(decimal(28,6), la.la_account_18771)
        AS new_ifrs_18771,

    TRY_CONVERT(decimal(28,6), la.currency_reserve_percentage)
        AS new_reserve_percentage,

    TRY_CONVERT(decimal(28,6), la.days_past_due_principal)
        AS new_principal_dpd,

    TRY_CONVERT(decimal(28,6), la.days_past_due_interest)
        AS new_interest_dpd,

    TRY_CONVERT(
        decimal(28,6),
        la.max_days_past_due_principal_interest
    ) AS new_max_dpd,

    TRY_CONVERT(decimal(28,6), la.delinquency_bucket)
        AS new_delinquency_bucket

INTO #NewRawJuly
FROM [Dictionaries].[risk_analytics].[loan_account] la
WHERE la.la_reporting_date = @JulyDate
  AND la.la_source = @Source;


/* ============================================================
   3. АГРЕГАЦИЯ НОВОЙ ВЕТКИ ПО НОМЕРУ ДОГОВОРА
   ============================================================ */

SELECT
    contract_key,

    COUNT_BIG(*) AS rows_per_contract,

    COUNT(DISTINCT loan_id_key)
        AS distinct_loan_ids,

    COUNT(DISTINCT new_status)
        AS distinct_statuses,

    MIN(new_status)
        AS new_status,

    SUM(new_balance)
        AS new_balance,

    SUM(new_ifrs_1428)
        AS new_ifrs_1428,

    SUM(new_ifrs_1845)
        AS new_ifrs_1845,

    SUM(new_ifrs_1877)
        AS new_ifrs_1877,

    SUM(new_ifrs_18770)
        AS new_ifrs_18770,

    SUM(new_ifrs_18771)
        AS new_ifrs_18771,

    MAX(new_reserve_percentage)
        AS new_reserve_percentage,

    MAX(new_principal_dpd)
        AS new_principal_dpd,

    MAX(new_interest_dpd)
        AS new_interest_dpd,

    MAX(new_max_dpd)
        AS new_max_dpd,

    MAX(new_delinquency_bucket)
        AS new_delinquency_bucket

INTO #NewJuly
FROM #NewRawJuly
WHERE contract_key IS NOT NULL
GROUP BY
    contract_key;


/* ============================================================
   RESULT 00
   КАЧЕСТВО КЛЮЧА
   ============================================================ */

SELECT
    '00_KEY_QUALITY' AS result_set,
    'OLD_PORTFOLIO_FENIX' AS branch_name,

    COUNT_BIG(*) AS raw_rows,

    SUM(
        CASE WHEN contract_key IS NULL
             THEN 1 ELSE 0 END
    ) AS missing_contract_number_count,

    COUNT(DISTINCT contract_key)
        AS distinct_contract_number_count,

    COUNT_BIG(*)
    - SUM(
        CASE WHEN contract_key IS NULL
             THEN 1 ELSE 0 END
      )
    - COUNT(DISTINCT contract_key)
        AS duplicate_extra_rows,

    CAST(NULL AS bigint)
        AS duplicated_distinct_contract_count,

    CAST(NULL AS decimal(28,6))
        AS duplicated_contract_balance_sum

FROM #OldJuly

UNION ALL

SELECT
    '00_KEY_QUALITY',
    'NEW_LOAN_ACCOUNT_S17',

    (SELECT COUNT_BIG(*) FROM #NewRawJuly),

    (
        SELECT COUNT_BIG(*)
        FROM #NewRawJuly
        WHERE contract_key IS NULL
    ),

    (SELECT COUNT_BIG(*) FROM #NewJuly),

    ISNULL(
        (
            SELECT SUM(rows_per_contract - 1)
            FROM #NewJuly
            WHERE rows_per_contract > 1
        ),
        0
    ),

    (
        SELECT COUNT_BIG(*)
        FROM #NewJuly
        WHERE rows_per_contract > 1
    ),

    (
        SELECT SUM(new_balance)
        FROM #NewJuly
        WHERE rows_per_contract > 1
    );


/* ============================================================
   RESULT 01
   ПЕРИМЕТР И ПОЛНЫЙ БАЛАНС
   ============================================================ */

;WITH population AS
(
    SELECT
        o.old_balance,
        n.new_balance,

        CASE
            WHEN o.contract_key IS NOT NULL
             AND n.contract_key IS NOT NULL
                THEN 'MATCHED'

            WHEN o.contract_key IS NOT NULL
             AND n.contract_key IS NULL
                THEN 'ONLY_OLD'

            ELSE 'ONLY_NEW'
        END AS population_class

    FROM #OldJuly o
    FULL OUTER JOIN #NewJuly n
        ON n.contract_key = o.contract_key
)
SELECT
    '01_POPULATION_BALANCE' AS result_set,
    @JulyDate AS report_date,
    @Source AS source_value,

    SUM(
        CASE WHEN population_class = 'MATCHED'
             THEN 1 ELSE 0 END
    ) AS matched_contract_count,

    SUM(
        CASE WHEN population_class = 'ONLY_OLD'
             THEN 1 ELSE 0 END
    ) AS only_old_contract_count,

    SUM(
        CASE WHEN population_class = 'ONLY_NEW'
             THEN 1 ELSE 0 END
    ) AS only_new_contract_count,

    SUM(old_balance)
        AS old_total_balance_sum,

    SUM(new_balance)
        AS new_total_balance_sum,

    SUM(
        CASE WHEN population_class = 'ONLY_OLD'
             THEN old_balance ELSE 0 END
    ) AS only_old_balance_sum,

    SUM(
        CASE WHEN population_class = 'ONLY_NEW'
             THEN new_balance ELSE 0 END
    ) AS only_new_balance_sum,

    SUM(new_balance) - SUM(old_balance)
        AS total_net_difference_new_minus_old

FROM population;


/* ============================================================
   4. СОВПАВШИЕ ДОГОВОРЫ
   ============================================================ */

SELECT
    o.contract_key,

    o.old_balance,
    n.new_balance,

    o.old_ifrs_1428,
    n.new_ifrs_1428,

    o.old_ifrs_1845,
    n.new_ifrs_1845,

    o.old_ifrs_1877,
    n.new_ifrs_1877,
    n.new_ifrs_18770,
    n.new_ifrs_18771,

    o.old_reserve_percentage,
    n.new_reserve_percentage,

    o.old_principal_dpd,
    n.new_principal_dpd,

    o.old_interest_dpd,
    n.new_interest_dpd,

    o.old_max_dpd,
    n.new_max_dpd,

    o.old_basket,
    n.new_delinquency_bucket,

    n.new_status

INTO #MatchedJuly
FROM #OldJuly o
INNER JOIN #NewJuly n
    ON n.contract_key = o.contract_key;


/* ============================================================
   RESULT 02
   БАЛАНС НА СОВПАВШЕМ ПЕРИМЕТРЕ
   ============================================================ */

SELECT
    '02_MATCHED_BALANCE' AS result_set,

    COUNT_BIG(*) AS matched_contract_count,

    SUM(
        CASE
            WHEN ABS(new_balance - old_balance)
                 <= @AmountTolerance
                THEN 1
            ELSE 0
        END
    ) AS matched_within_tolerance_count,

    SUM(
        CASE
            WHEN ABS(new_balance - old_balance)
                 > @AmountTolerance
                THEN 1
            ELSE 0
        END
    ) AS different_contract_count,

    SUM(old_balance)
        AS old_balance_sum,

    SUM(new_balance)
        AS new_balance_sum,

    SUM(new_balance - old_balance)
        AS net_difference_new_minus_old,

    SUM(ABS(new_balance - old_balance))
        AS absolute_difference_sum,

    MAX(ABS(new_balance - old_balance))
        AS maximum_contract_difference,

    CAST(
        100.0
        * SUM(
            CASE
                WHEN ABS(new_balance - old_balance)
                     <= @AmountTolerance
                    THEN 1
                ELSE 0
            END
        )
        / NULLIF(COUNT_BIG(*), 0)
        AS decimal(12,6)
    ) AS match_pct

FROM #MatchedJuly;


/* ============================================================
   RESULT 03
   ПРОВИЗИИ НА СОВПАВШЕМ ПЕРИМЕТРЕ
   ============================================================ */

;WITH provision_metrics AS
(
    SELECT
        v.metric_name,
        v.old_or_expected_value,
        v.new_or_actual_value

    FROM #MatchedJuly m

    CROSS APPLY
    (
        VALUES
        (
            '01_IFRS_1428',
            COALESCE(m.old_ifrs_1428, 0),
            COALESCE(m.new_ifrs_1428, 0)
        ),
        (
            '02_IFRS_1845',
            COALESCE(m.old_ifrs_1845, 0),
            COALESCE(m.new_ifrs_1845, 0)
        ),
        (
            '03_OLD_1877_VS_NEW_18771',
            COALESCE(m.old_ifrs_1877, 0),
            COALESCE(m.new_ifrs_18771, 0)
        ),
        (
            '04_TOTAL_PROVISIONS',

              COALESCE(m.old_ifrs_1428, 0)
            + COALESCE(m.old_ifrs_1845, 0)
            + COALESCE(m.old_ifrs_1877, 0),

              COALESCE(m.new_ifrs_1428, 0)
            + COALESCE(m.new_ifrs_1845, 0)
            + COALESCE(m.new_ifrs_18771, 0)
        ),
        (
            '05_NEW_1877_IDENTITY',

              COALESCE(m.new_ifrs_18770, 0)
            + COALESCE(m.new_ifrs_18771, 0),

            COALESCE(m.new_ifrs_1877, 0)
        )
    ) v
    (
        metric_name,
        old_or_expected_value,
        new_or_actual_value
    )
)
SELECT
    '03_PROVISION_METRICS' AS result_set,
    metric_name,

    COUNT_BIG(*) AS matched_contract_count,

    SUM(
        CASE
            WHEN ABS(
                    new_or_actual_value
                    - old_or_expected_value
                 ) <= @AmountTolerance
                THEN 1
            ELSE 0
        END
    ) AS matched_within_tolerance_count,

    SUM(
        CASE
            WHEN ABS(
                    new_or_actual_value
                    - old_or_expected_value
                 ) > @AmountTolerance
                THEN 1
            ELSE 0
        END
    ) AS different_count,

    SUM(old_or_expected_value)
        AS old_or_expected_sum,

    SUM(new_or_actual_value)
        AS new_or_actual_sum,

    SUM(
        new_or_actual_value - old_or_expected_value
    ) AS net_difference_new_minus_old,

    SUM(
        ABS(new_or_actual_value - old_or_expected_value)
    ) AS absolute_difference_sum,

    MAX(
        ABS(new_or_actual_value - old_or_expected_value)
    ) AS maximum_contract_difference,

    CAST(
        100.0
        * SUM(
            CASE
                WHEN ABS(
                        new_or_actual_value
                        - old_or_expected_value
                     ) <= @AmountTolerance
                    THEN 1
                ELSE 0
            END
        )
        / NULLIF(COUNT_BIG(*), 0)
        AS decimal(12,6)
    ) AS match_pct

FROM provision_metrics
GROUP BY
    metric_name
ORDER BY
    metric_name;


/* ============================================================
   RESULT 04
   ПОЛНЫЙ КОНТРОЛЬ ПРОВИЗИЙ
   ============================================================ */

;WITH old_total AS
(
    SELECT
        SUM(
              COALESCE(old_ifrs_1428, 0)
            + COALESCE(old_ifrs_1845, 0)
            + COALESCE(old_ifrs_1877, 0)
        ) AS old_total_provision
    FROM #OldJuly
),
new_total AS
(
    SELECT
        SUM(
              COALESCE(new_ifrs_1428, 0)
            + COALESCE(new_ifrs_1845, 0)
            + COALESCE(new_ifrs_18771, 0)
        ) AS new_total_provision
    FROM #NewJuly
)
SELECT
    '04_FULL_PROVISION_CONTROL' AS result_set,

    o.old_total_provision,
    n.new_total_provision,

    n.new_total_provision - o.old_total_provision
        AS net_difference_new_minus_old,

    CAST(
        100.0
        * (n.new_total_provision - o.old_total_provision)
        / NULLIF(ABS(o.old_total_provision), 0)
        AS decimal(18,6)
    ) AS difference_pct_of_old_provision

FROM old_total o
CROSS JOIN new_total n;


/* ============================================================
   RESULT 05
   ЛОКАЛИЗАЦИЯ 18771 И ПРОЦЕНТА РЕЗЕРВИРОВАНИЯ
   ============================================================ */

SELECT
    '05_18771_LOCALIZATION' AS result_set,

    SUM(
        CASE
            WHEN ABS(COALESCE(new_ifrs_18771, 0))
                 > @AmountTolerance
                THEN 1
            ELSE 0
        END
    ) AS matched_nonzero_18771_count,

    SUM(
        CASE
            WHEN ABS(COALESCE(new_ifrs_18771, 0))
                 > @AmountTolerance
                THEN new_ifrs_18771
            ELSE 0
        END
    ) AS matched_nonzero_18771_sum,

    SUM(
        CASE
            WHEN ABS(COALESCE(new_ifrs_18771, 0))
                   > @AmountTolerance
             AND ABS(COALESCE(old_balance, 0))
                   <= @AmountTolerance
                THEN 1
            ELSE 0
        END
    ) AS matched_zero_balance_nonzero_18771_count,

    SUM(
        CASE
            WHEN ABS(COALESCE(new_ifrs_18771, 0))
                   > @AmountTolerance
             AND ABS(COALESCE(old_balance, 0))
                   <= @AmountTolerance
                THEN new_ifrs_18771
            ELSE 0
        END
    ) AS matched_zero_balance_18771_sum,

    SUM(
        CASE
            WHEN old_reserve_percentage IS NOT NULL
             AND new_reserve_percentage IS NOT NULL
             AND ABS(
                    new_reserve_percentage
                    - old_reserve_percentage
                 ) > @RateTolerance
                THEN 1
            ELSE 0
        END
    ) AS reserve_percentage_difference_count,

    (
        SELECT COUNT_BIG(*)
        FROM #NewJuly n
        LEFT JOIN #OldJuly o
            ON o.contract_key = n.contract_key
        WHERE o.contract_key IS NULL
          AND ABS(
                COALESCE(n.new_ifrs_1428, 0)
                + COALESCE(n.new_ifrs_1845, 0)
                + COALESCE(n.new_ifrs_18771, 0)
              ) > @AmountTolerance
    ) AS only_new_nonzero_provision_count,

    (
        SELECT SUM(
              COALESCE(n.new_ifrs_1428, 0)
            + COALESCE(n.new_ifrs_1845, 0)
            + COALESCE(n.new_ifrs_18771, 0)
        )
        FROM #NewJuly n
        LEFT JOIN #OldJuly o
            ON o.contract_key = n.contract_key
        WHERE o.contract_key IS NULL
          AND ABS(
                COALESCE(n.new_ifrs_1428, 0)
                + COALESCE(n.new_ifrs_1845, 0)
                + COALESCE(n.new_ifrs_18771, 0)
              ) > @AmountTolerance
    ) AS only_new_nonzero_provision_sum

FROM #MatchedJuly;


/* ============================================================
   RESULT 06
   DPD: NULL, СОПОСТАВЛЕНИЕ И BASKET
   ============================================================ */

SELECT
    '06_DPD_SUMMARY' AS result_set,

    COUNT_BIG(*) AS matched_contract_count,

    SUM(
        CASE WHEN new_principal_dpd IS NULL
             THEN 1 ELSE 0 END
    ) AS new_principal_dpd_null_count,

    SUM(
        CASE WHEN new_interest_dpd IS NULL
             THEN 1 ELSE 0 END
    ) AS new_interest_dpd_null_count,

    SUM(
        CASE WHEN new_max_dpd IS NULL
             THEN 1 ELSE 0 END
    ) AS new_max_dpd_null_count,

    SUM(
        CASE
            WHEN new_interest_dpd IS NULL
             AND old_interest_dpd > 0
                THEN 1
            ELSE 0
        END
    ) AS old_positive_interest_new_null_count,

    SUM(
        CASE
            WHEN new_interest_dpd IS NULL
             AND old_interest_dpd > 0
                THEN old_balance
            ELSE 0
        END
    ) AS old_positive_interest_new_null_balance_sum,

    SUM(
        CASE
            WHEN new_interest_dpd IS NULL
             AND old_interest_dpd > 90
                THEN 1
            ELSE 0
        END
    ) AS old_interest_90plus_new_null_count,

    SUM(
        CASE
            WHEN new_interest_dpd IS NULL
             AND old_interest_dpd > 90
                THEN old_balance
            ELSE 0
        END
    ) AS old_interest_90plus_new_null_balance_sum,

    SUM(
        CASE
            WHEN new_principal_dpd IS NOT NULL
                THEN 1
            ELSE 0
        END
    ) AS principal_both_nonnull_count,

    SUM(
        CASE
            WHEN new_principal_dpd IS NOT NULL
             AND ABS(
                    (new_principal_dpd - 1)
                    - old_principal_dpd
                 ) <= @AmountTolerance
                THEN 1
            ELSE 0
        END
    ) AS principal_match_count,

    SUM(
        CASE
            WHEN new_principal_dpd IS NOT NULL
             AND ABS(
                    (new_principal_dpd - 1)
                    - old_principal_dpd
                 ) > @AmountTolerance
                THEN 1
            ELSE 0
        END
    ) AS principal_difference_count,

    SUM(
        CASE
            WHEN new_principal_dpd IS NOT NULL
             AND ABS(
                    (new_principal_dpd - 1)
                    - old_principal_dpd
                 ) > @AmountTolerance
                THEN old_balance
            ELSE 0
        END
    ) AS principal_difference_balance_sum,

    SUM(
        CASE
            WHEN new_max_dpd IS NOT NULL
                THEN 1
            ELSE 0
        END
    ) AS max_both_nonnull_count,

    SUM(
        CASE
            WHEN new_max_dpd IS NOT NULL
             AND ABS(
                    (new_max_dpd - 1)
                    - old_max_dpd
                 ) <= @AmountTolerance
                THEN 1
            ELSE 0
        END
    ) AS max_match_count,

    SUM(
        CASE
            WHEN new_max_dpd IS NOT NULL
             AND ABS(
                    (new_max_dpd - 1)
                    - old_max_dpd
                 ) > @AmountTolerance
                THEN 1
            ELSE 0
        END
    ) AS max_difference_count,

    SUM(
        CASE
            WHEN new_max_dpd IS NOT NULL
             AND ABS(
                    (new_max_dpd - 1)
                    - old_max_dpd
                 ) > @AmountTolerance
                THEN old_balance
            ELSE 0
        END
    ) AS max_difference_balance_sum,

    SUM(
        CASE
            WHEN old_basket = new_delinquency_bucket
                THEN 1
            ELSE 0
        END
    ) AS basket_match_count,

    SUM(
        CASE
            WHEN old_basket <> new_delinquency_bucket
                THEN 1
            ELSE 0
        END
    ) AS basket_difference_count,

    SUM(
        CASE
            WHEN old_basket <> new_delinquency_bucket
                THEN old_balance
            ELSE 0
        END
    ) AS basket_difference_balance_sum

FROM #MatchedJuly;


/* ============================================================
   RESULT 07
   ВЛИЯНИЕ НА 90+
   ============================================================ */

;WITH dpd_flags AS
(
    SELECT
        old_balance,
        old_max_dpd,
        new_max_dpd,

        CASE
            WHEN old_max_dpd > 90
             AND new_max_dpd - 1 > 90
                THEN '01_BOTH_90_PLUS'

            WHEN old_max_dpd > 90
             AND new_max_dpd IS NULL
                THEN '02_OLD_90_PLUS_NEW_NULL'

            WHEN old_max_dpd > 90
             AND new_max_dpd - 1 <= 90
                THEN '03_ONLY_OLD_90_PLUS'

            WHEN old_max_dpd <= 90
             AND new_max_dpd - 1 > 90
                THEN '04_ONLY_NEW_90_PLUS'

            ELSE '05_NEITHER_90_PLUS'
        END AS flag_relation

    FROM #MatchedJuly
)
SELECT
    '07_90_PLUS' AS result_set,
    flag_relation,

    COUNT_BIG(*) AS contract_count,
    SUM(old_balance) AS old_balance_sum,

    SUM(
        CASE WHEN new_max_dpd IS NULL
             THEN 1 ELSE 0 END
    ) AS new_max_dpd_null_count,

    MIN(old_max_dpd)
        AS minimum_old_max_dpd,

    MAX(old_max_dpd)
        AS maximum_old_max_dpd,

    MIN(new_max_dpd - 1)
        AS minimum_normalized_new_max_dpd,

    MAX(new_max_dpd - 1)
        AS maximum_normalized_new_max_dpd

FROM dpd_flags
GROUP BY
    flag_relation
ORDER BY
    flag_relation;


/* ============================================================
   RESULT 08
   BASKET
   ============================================================ */

SELECT
    '08_BASKET' AS result_set,

    COUNT_BIG(*) AS matched_contract_count,

    SUM(
        CASE
            WHEN old_basket = new_delinquency_bucket
                THEN 1
            ELSE 0
        END
    ) AS basket_match_count,

    SUM(
        CASE
            WHEN old_basket <> new_delinquency_bucket
                THEN 1
            ELSE 0
        END
    ) AS basket_difference_count,

    SUM(
        CASE
            WHEN old_basket <> new_delinquency_bucket
                THEN old_balance
            ELSE 0
        END
    ) AS basket_difference_balance_sum,

    CAST(
        100.0
        * SUM(
            CASE
                WHEN old_basket = new_delinquency_bucket
                    THEN 1
                ELSE 0
            END
        )
        / NULLIF(COUNT_BIG(*), 0)
        AS decimal(12,6)
    ) AS basket_match_pct

FROM #MatchedJuly;


/* ============================================================
   5. ИСТОРИЯ ДЛЯ ПРОВЕРКИ ЛАГА

   Используется LOOP JOIN и прямое равенство contractnumber,
   поэтому большой исторический HASH JOIN не создаётся.
   ============================================================ */

SELECT
    f.actual_date AS report_date,

    UPPER(
        LTRIM(
            RTRIM(CONVERT(nvarchar(255), f.contractnumber))
        )
    ) COLLATE DATABASE_DEFAULT AS contract_key,

    TRY_CONVERT(decimal(28,6), f.ifrs_balance)
        AS old_balance,

    TRY_CONVERT(decimal(28,6), f.overdue_days_principal)
        AS old_principal_dpd,

    TRY_CONVERT(decimal(28,6), f.max_overdue_days)
        AS old_max_dpd

INTO #OldHistoryRaw
FROM [CL_PORTFOLIO].[dbo].[PORTFOLIO_Fenix] f
WHERE f.actual_date IN (@JuneDate, @JulyDate);


SELECT
    la.la_reporting_date AS report_date,

    UPPER(
        LTRIM(
            RTRIM(CONVERT(nvarchar(255), la.la_dog_num))
        )
    ) COLLATE DATABASE_DEFAULT AS contract_key,

    TRY_CONVERT(decimal(28,6), la.total_balance_debt)
        AS new_balance,

    TRY_CONVERT(decimal(28,6), la.days_past_due_principal)
        AS new_principal_dpd,

    TRY_CONVERT(
        decimal(28,6),
        la.max_days_past_due_principal_interest
    ) AS new_max_dpd

INTO #NewHistoryRaw
FROM [Dictionaries].[risk_analytics].[loan_account] la
WHERE la.la_reporting_date IN (@JuneDate, @JulyDate)
  AND la.la_source = @Source;


/* ============================================================
   6. АГРЕГАЦИЯ ИСТОРИИ
   ============================================================ */

SELECT
    report_date,
    contract_key,

    SUM(old_balance)
        AS old_balance,

    MAX(old_principal_dpd)
        AS old_principal_dpd,

    MAX(old_max_dpd)
        AS old_max_dpd

INTO #OldHistory
FROM #OldHistoryRaw
WHERE contract_key IS NOT NULL
GROUP BY
    report_date,
    contract_key;


SELECT
    report_date,
    contract_key,

    SUM(new_balance)
        AS new_balance,

    MAX(new_principal_dpd)
        AS new_principal_dpd,

    MAX(new_max_dpd)
        AS new_max_dpd

INTO #NewHistory
FROM #NewHistoryRaw
WHERE contract_key IS NOT NULL
GROUP BY
    report_date,
    contract_key;


/* ============================================================
   RESULT 09
   ПРОВЕРКА МЕСЯЧНОГО ЛАГА
   ============================================================ */

;WITH pair_definitions AS
(
    SELECT *
    FROM
    (
        VALUES
        (
            '01_OLD_JULY_VS_NEW_JULY',
            @JulyDate,
            @JulyDate
        ),
        (
            '02_OLD_JUNE_VS_NEW_JUNE',
            @JuneDate,
            @JuneDate
        ),
        (
            '03_OLD_JUNE_VS_NEW_JULY',
            @JuneDate,
            @JulyDate
        ),
        (
            '04_OLD_JULY_VS_NEW_JUNE',
            @JulyDate,
            @JuneDate
        )
    ) p
    (
        pairing_code,
        old_report_date,
        new_report_date
    )
),
metric_values AS
(
    SELECT
        p.pairing_code,
        p.old_report_date,
        p.new_report_date,

        o.old_balance,

        v.metric_name,
        v.old_value,
        v.new_candidate_value

    FROM pair_definitions p

    INNER JOIN #OldHistory o
        ON o.report_date = p.old_report_date

    INNER JOIN #NewHistory n
        ON n.report_date = p.new_report_date
       AND n.contract_key = o.contract_key

    CROSS APPLY
    (
        VALUES
        (
            '01_PRINCIPAL_NEW_MINUS_1',
            o.old_principal_dpd,
            n.new_principal_dpd - 1
        ),
        (
            '02_MAX_NEW_MINUS_1',
            o.old_max_dpd,
            n.new_max_dpd - 1
        )
    ) v
    (
        metric_name,
        old_value,
        new_candidate_value
    )
)
SELECT
    '09_TEMPORAL_DPD' AS result_set,
    pairing_code,
    old_report_date,
    new_report_date,
    metric_name,

    COUNT_BIG(*) AS matched_contract_count,

    SUM(
        CASE WHEN new_candidate_value IS NULL
             THEN 1 ELSE 0 END
    ) AS new_null_count,

    SUM(
        CASE
            WHEN old_value IS NOT NULL
             AND new_candidate_value IS NOT NULL
                THEN 1
            ELSE 0
        END
    ) AS both_nonnull_count,

    SUM(
        CASE
            WHEN old_value IS NOT NULL
             AND new_candidate_value IS NOT NULL
             AND ABS(new_candidate_value - old_value)
                 <= @AmountTolerance
                THEN 1
            ELSE 0
        END
    ) AS matched_within_tolerance_count,

    SUM(
        CASE
            WHEN old_value IS NOT NULL
             AND new_candidate_value IS NOT NULL
             AND ABS(new_candidate_value - old_value)
                 > @AmountTolerance
                THEN 1
            ELSE 0
        END
    ) AS different_count,

    SUM(
        CASE
            WHEN old_value IS NOT NULL
             AND new_candidate_value IS NOT NULL
             AND ABS(new_candidate_value - old_value)
                 > @AmountTolerance
                THEN old_balance
            ELSE 0
        END
    ) AS different_contract_balance_sum,

    CAST(
        100.0
        * SUM(
            CASE
                WHEN old_value IS NOT NULL
                 AND new_candidate_value IS NOT NULL
                 AND ABS(new_candidate_value - old_value)
                     <= @AmountTolerance
                    THEN 1
                ELSE 0
            END
        )
        / NULLIF(
            SUM(
                CASE
                    WHEN old_value IS NOT NULL
                     AND new_candidate_value IS NOT NULL
                        THEN 1
                    ELSE 0
                END
            ),
            0
        )
        AS decimal(12,6)
    ) AS nonnull_match_pct

FROM metric_values
GROUP BY
    pairing_code,
    old_report_date,
    new_report_date,
    metric_name
ORDER BY
    pairing_code,
    metric_name;


/* ============================================================
   ОЧИСТКА
   ============================================================ */

DROP TABLE IF EXISTS #NewHistory;
DROP TABLE IF EXISTS #OldHistory;
DROP TABLE IF EXISTS #NewHistoryRaw;
DROP TABLE IF EXISTS #OldHistoryRaw;
DROP TABLE IF EXISTS #MatchedJuly;
DROP TABLE IF EXISTS #NewJuly;
DROP TABLE IF EXISTS #NewRawJuly;
DROP TABLE IF EXISTS #OldJuly;
GO


-- ============================================================================
-- B2. DEVELOPER_PROOF_LOW_TEMPDB_20260701 — DWH-13..16 (borrower/ИИН/pledges)
-- Письмо-сопровождение: DWH-13 (53 S02 borrower_id отсутствуют в borrower),
-- DWH-14 (7 S17 ИИН-расхождений), DWH-15 (49 S03 без pledges),
-- DWH-16 (l_collateral_id не универсален; c_source+c_loan_gid — канонический
-- ключ pledges→loans).
-- ============================================================================
/* ============================================================
   DEVELOPER_PROOF_LOW_TEMPDB_20260701

   Облегчённое доказательство:
   - минимальные временные таблицы;
   - без больших исторических HASH JOIN;
   - проверки выполняются последовательно;
   - идентификаторы в результат не выводятся.
   ============================================================ */

USE [Dictionaries];
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

DECLARE @ReportDate date = '2026-07-01';

/* Очистка на случай повторного запуска */
DROP TABLE IF EXISTS #MB53;
DROP TABLE IF EXISTS #M7;
DROP TABLE IF EXISTS #H7;
DROP TABLE IF EXISTS #T49;
DROP TABLE IF EXISTS #B49;
DROP TABLE IF EXISTS #P49;

/* ============================================================
   RESULT 1
   S02: borrower_id отсутствует в borrower
   ============================================================ */

SELECT DISTINCT
    CONVERT(nvarchar(510), a.l_loan_id) AS loan_id,
    a.l_borrower_id AS borrower_id,
    TRY_CONVERT(decimal(38,6), a.l_loan_amount) AS loan_amount,

    CASE WHEN EXISTS
    (
        SELECT 1
        FROM [risk_analytics].[loans] l
        WHERE l.l_report_date = @ReportDate
          AND l.l_source = 'S02'
          AND CONVERT(nvarchar(510), l.l_loan_id)
                = CONVERT(nvarchar(510), a.l_loan_id)
    )
    THEN 1 ELSE 0 END AS found_in_master,

    CASE WHEN EXISTS
    (
        SELECT 1
        FROM [risk_analytics].[loan_account] la
        WHERE la.la_reporting_date = @ReportDate
          AND la.la_source = N'S02'
          AND la.la_loan_id =
              CONVERT(nvarchar(510), a.l_loan_id)
    )
    THEN 1 ELSE 0 END AS found_in_current_loan_account
INTO #MB53
FROM [risk_analytics].[loans_active] a
WHERE a.l_report_date = @ReportDate
  AND a.l_source = 'S02'
  AND NOT EXISTS
  (
      SELECT 1
      FROM [risk_analytics].[borrower] b
      WHERE b.b_borrower_id = a.l_borrower_id
  )
OPTION (MAXDOP 1);

SELECT
    @ReportDate AS report_date,
    'S02' AS source_value,

    COUNT_BIG(*) AS missing_borrower_count,
    COUNT(DISTINCT borrower_id) AS distinct_missing_borrower_count,
    SUM(found_in_master) AS found_in_master_count,

    SUM(found_in_current_loan_account)
        AS found_in_current_loan_account_count,

    SUM(CASE
        WHEN loan_amount > 0 THEN 1 ELSE 0
    END) AS positive_loan_amount_count,

    SUM(CASE
        WHEN loan_amount > 0 THEN loan_amount ELSE 0
    END) AS positive_loan_amount_sum,

    CASE
        WHEN COUNT_BIG(*) = 0
            THEN 'PASSED'
        ELSE 'BORROWER_DIMENSION_OMISSION'
    END AS control_status
FROM #MB53;

DROP TABLE IF EXISTS #MB53;

/* ============================================================
   RESULT 2
   S17: текущие валидные 12-значные ИИН не совпадают
   ============================================================ */

SELECT DISTINCT
    CONVERT(varchar(100), f.contractnumber)
        AS contract_number,

    LTRIM(RTRIM(CONVERT(varchar(15), b.b_iin_bin)))
        AS linked_new_iin,

    LTRIM(RTRIM(CONVERT(varchar(20), f.iin)))
        AS current_old_iin,

    TRY_CONVERT(decimal(38,6), f.Total_outstanding)
        AS old_balance,

    CASE WHEN EXISTS
    (
        SELECT 1
        FROM [risk_analytics].[borrower] alt
        WHERE alt.b_borrower_id <> b.b_borrower_id
          AND LTRIM(RTRIM(CONVERT(varchar(15), alt.b_iin_bin)))
                = LTRIM(RTRIM(CONVERT(varchar(20), f.iin)))
    )
    THEN 1 ELSE 0 END AS old_iin_found_under_other_borrower
INTO #M7
FROM [risk_analytics].[loans_active] a
JOIN [risk_analytics].[borrower] b
  ON b.b_borrower_id = a.l_borrower_id
JOIN [CL_PORTFOLIO].[dbo].[PORTFOLIO_Fenix] f
  ON f.actual_date = @ReportDate
 AND f.contractnumber = a.l_loan_number
WHERE a.l_report_date = @ReportDate
  AND a.l_source = 'S17'

  AND LEN(LTRIM(RTRIM(CONVERT(varchar(20), f.iin)))) = 12
  AND LTRIM(RTRIM(CONVERT(varchar(20), f.iin)))
        NOT LIKE '%[^0-9]%'

  AND LEN(LTRIM(RTRIM(CONVERT(varchar(15), b.b_iin_bin)))) = 12
  AND LTRIM(RTRIM(CONVERT(varchar(15), b.b_iin_bin)))
        NOT LIKE '%[^0-9]%'

  AND LTRIM(RTRIM(CONVERT(varchar(20), f.iin)))
        <> LTRIM(RTRIM(CONVERT(varchar(15), b.b_iin_bin)))
OPTION (LOOP JOIN, MAXDOP 1);

SELECT
    @ReportDate AS report_date,
    'S17' AS source_value,

    COUNT_BIG(*) AS valid_iin_mismatch_count,

    SUM(old_iin_found_under_other_borrower)
        AS old_iin_found_under_other_borrower_count,

    SUM(COALESCE(old_balance, 0)) AS old_balance_sum,

    CASE
        WHEN COUNT_BIG(*) = 0
            THEN 'PASSED'
        ELSE 'VALID_IIN_MISMATCH'
    END AS control_status
FROM #M7;

/* ============================================================
   RESULT 3
   История только семи найденных договоров

   Используется LOOP JOIN и прямое равенство contractnumber,
   поэтому большой исторический HASH JOIN не создаётся.
   ============================================================ */

SELECT
    m.contract_number,

    history.old_history_row_count,
    history.distinct_historical_iin_count,
    history.ever_matching_linked_new_iin,
    history.first_old_date,
    history.last_old_date
INTO #H7
FROM #M7 m
OUTER APPLY
(
    SELECT
        COUNT_BIG(*) AS old_history_row_count,

        COUNT(DISTINCT NULLIF(
            LTRIM(RTRIM(CONVERT(varchar(20), h.iin))), ''
        )) AS distinct_historical_iin_count,

        MAX(CASE
            WHEN LTRIM(RTRIM(CONVERT(varchar(20), h.iin)))
                 = m.linked_new_iin
            THEN 1 ELSE 0
        END) AS ever_matching_linked_new_iin,

        MIN(h.actual_date) AS first_old_date,
        MAX(h.actual_date) AS last_old_date
    FROM [CL_PORTFOLIO].[dbo].[PORTFOLIO_Fenix] h
    WHERE h.contractnumber = m.contract_number
) history
OPTION (MAXDOP 1);

SELECT
    @ReportDate AS report_date,
    'S17' AS source_value,

    CASE
        WHEN h.ever_matching_linked_new_iin = 1
            THEN 'HISTORICAL_IIN_CHANGED_OR_MIXED'
        ELSE 'OLD_IIN_STABLE_NEVER_MATCHED_LINKED_BORROWER'
    END AS history_status,

    COUNT_BIG(*) AS contract_count,
    SUM(COALESCE(m.old_balance, 0)) AS old_balance_sum,

    MIN(h.first_old_date) AS first_old_date,
    MAX(h.last_old_date) AS last_old_date,

    CASE
        WHEN h.ever_matching_linked_new_iin = 1
            THEN 'CHECK_CURRENT_SOURCE_IIN'
        ELSE 'CHECK_BORROWER_LINK_AND_SOURCE_IIN'
    END AS control_status
FROM #M7 m
JOIN #H7 h
  ON h.contract_number = m.contract_number
GROUP BY
    CASE
        WHEN h.ever_matching_linked_new_iin = 1
            THEN 'HISTORICAL_IIN_CHANGED_OR_MIXED'
        ELSE 'OLD_IIN_STABLE_NEVER_MATCHED_LINKED_BORROWER'
    END,
    h.ever_matching_linked_new_iin
ORDER BY history_status;

DROP TABLE IF EXISTS #H7;
DROP TABLE IF EXISTS #M7;

/* ============================================================
   RESULT 4
   S03: заполненный l_collateral_id без текущего pledges
   ============================================================ */

SELECT DISTINCT
    a.l_gid,
    CONVERT(nvarchar(510), a.l_loan_id) AS loan_id,

    TRY_CONVERT(
        decimal(38,6),
        NULLIF(LTRIM(RTRIM(
            CONVERT(nvarchar(255), a.l_collateral_id)
        )), N'')
    ) AS collateral_id
INTO #T49
FROM [risk_analytics].[loans_active] a
WHERE a.l_report_date = @ReportDate
  AND a.l_source = 'S03'

  AND TRY_CONVERT(
        decimal(38,6),
        NULLIF(LTRIM(RTRIM(
            CONVERT(nvarchar(255), a.l_collateral_id)
        )), N'')
      ) IS NOT NULL

  AND NOT EXISTS
  (
      SELECT 1
      FROM [risk_analytics].[pledges] p
      WHERE p.c_reporting_date = @ReportDate
        AND p.c_source = N'S03'
        AND p.c_loan_gid = a.l_gid
  )
OPTION (LOOP JOIN, MAXDOP 1);

SELECT
    t.l_gid,

    COUNT_BIG(la.la_gid) AS current_loan_account_row_count,

    SUM(COALESCE(component.component_net, 0))
        AS current_component_net_sum,

    SUM(COALESCE(component.component_absolute, 0))
        AS current_component_absolute_sum
INTO #B49
FROM #T49 t
LEFT JOIN [risk_analytics].[loan_account] la
  ON la.la_reporting_date = @ReportDate
 AND la.la_source = N'S03'
 AND la.la_loan_id = t.loan_id
OUTER APPLY
(
    SELECT
        SUM(TRY_CONVERT(decimal(38,6), value.amount))
            AS component_net,

        SUM(ABS(TRY_CONVERT(decimal(38,6), value.amount)))
            AS component_absolute
    FROM
    (
        VALUES
            (la.la_account_1401),
            (la.la_account_1403),
            (la.la_account_1411),
            (la.la_account_1417),
            (la.la_account_1424),
            (la.la_account_1428),
            (la.la_account_1430),
            (la.la_account_1431),
            (la.la_account_1434),
            (la.la_account_1740),
            (la.la_account_1741),
            (la.la_account_2794),
            (la.la_account_1773),
            (la.la_account_1774),
            (la.la_account_1775),
            (la.la_account_1784),
            (la.la_account_1435),
            (la.la_account_1818),
            (la.la_account_1838),
            (la.la_account_1845),
            (la.la_account_1860),
            (la.la_account_1877),
            (la.la_account_18770),
            (la.la_account_18771),
            (la.la_account_1879)
    ) value(amount)
) component
GROUP BY t.l_gid
OPTION (LOOP JOIN, MAXDOP 1);

/* Исторические признаки рассчитываются только для 49 строк */
SELECT
    t.l_gid,

    CASE WHEN EXISTS
    (
        SELECT 1
        FROM [risk_analytics].[pledges] p
        WHERE p.c_source = N'S03'
          AND p.c_loan_gid = t.l_gid
    )
    THEN 1 ELSE 0 END AS historically_found_by_loan_gid,

    CASE WHEN EXISTS
    (
        SELECT 1
        FROM [risk_analytics].[pledges] p
        WHERE p.c_source = N'S03'
          AND p.c_loan_gid <> t.l_gid
          AND p.c_collateral_id =
              TRY_CONVERT(float, t.collateral_id)
    )
    THEN 1 ELSE 0 END AS collateral_found_under_other_loan,

    b.current_loan_account_row_count,
    b.current_component_net_sum,
    b.current_component_absolute_sum
INTO #P49
FROM #T49 t
JOIN #B49 b
  ON b.l_gid = t.l_gid
OPTION (LOOP JOIN, MAXDOP 1);

SELECT
    @ReportDate AS report_date,
    'S03' AS source_value,

    COUNT_BIG(*) AS active_missing_pledge_count,

    SUM(historically_found_by_loan_gid)
        AS historically_found_by_loan_gid_count,

    SUM(collateral_found_under_other_loan)
        AS collateral_found_under_other_loan_count,

    SUM(current_loan_account_row_count)
        AS current_loan_account_row_count,

    SUM(current_component_net_sum)
        AS current_component_net_sum,

    SUM(current_component_absolute_sum)
        AS current_component_absolute_sum,

    CASE
        WHEN COUNT_BIG(*) = 0
            THEN 'PLEDGE_REFERENCE_PASSED'

        WHEN SUM(current_component_absolute_sum) <> 0
            THEN 'ACTIVE_BALANCE_WITH_MISSING_PLEDGE_REFERENCE'

        ELSE 'MISSING_PLEDGE_WITHOUT_CURRENT_BALANCE'
    END AS control_status
FROM #P49;

DROP TABLE IF EXISTS #P49;
DROP TABLE IF EXISTS #B49;
DROP TABLE IF EXISTS #T49;

/* ============================================================
   RESULT 5
   l_collateral_id по S01/S03/S17

   Проверяются только активные договоры, для которых есть pledges.
   ============================================================ */

;WITH ActiveOneRow AS
(
    SELECT
        a.l_source AS source_value,
        a.l_gid,

        NULLIF(LTRIM(RTRIM(
            CONVERT(nvarchar(255), a.l_collateral_id)
        )), N'') AS collateral_raw,

        ROW_NUMBER() OVER
        (
            PARTITION BY a.l_source, a.l_gid
            ORDER BY CONVERT(nvarchar(510), a.l_loan_id)
        ) AS rn
    FROM [risk_analytics].[loans_active] a
    WHERE a.l_report_date = @ReportDate
      AND a.l_source IN ('S01', 'S03', 'S17')
),
PledgedActive AS
(
    SELECT
        a.source_value,
        a.l_gid,
        a.collateral_raw,

        TRY_CONVERT(decimal(38,6), a.collateral_raw)
            AS collateral_numeric,

        UPPER(a.collateral_raw) AS collateral_text
    FROM ActiveOneRow a
    WHERE a.rn = 1
      AND EXISTS
      (
          SELECT 1
          FROM [risk_analytics].[pledges] p
          WHERE p.c_reporting_date = @ReportDate
            AND p.c_source = a.source_value
            AND p.c_loan_gid = a.l_gid
      )
),
MappingFlags AS
(
    SELECT
        a.source_value,
        a.l_gid,

        CASE
            WHEN a.collateral_raw IS NULL
              OR a.collateral_numeric = 0
              OR a.collateral_text
                    IN (N'NULL', N'N/A', N'NA', N'НЕТ', N'NONE')
            THEN 1 ELSE 0
        END AS collateral_is_missing,

        CASE WHEN EXISTS
        (
            SELECT 1
            FROM [risk_analytics].[pledges] p
            WHERE p.c_reporting_date = @ReportDate
              AND p.c_source = a.source_value
              AND p.c_loan_gid = a.l_gid
              AND
              (
                  TRY_CONVERT(decimal(38,6), p.c_collateral_id)
                        = a.collateral_numeric
                  OR TRY_CONVERT(decimal(38,6), p.c_bpm_object_id)
                        = a.collateral_numeric
                  OR TRY_CONVERT(decimal(38,6), p.c_car_code)
                        = a.collateral_numeric
                  OR UPPER(NULLIF(LTRIM(RTRIM(
                         CONVERT(nvarchar(300), p.c_car_code)
                     )), N'')) = a.collateral_text
              )
        )
        THEN 1 ELSE 0 END AS identifier_matches
    FROM PledgedActive a
)
SELECT
    @ReportDate AS report_date,
    source_value,

    COUNT_BIG(*) AS active_loan_gids_with_pledge,

    SUM(collateral_is_missing)
        AS pledge_exists_but_l_collateral_missing_count,

    SUM(identifier_matches)
        AS matching_l_collateral_identifier_count,

    COUNT_BIG(*) - SUM(collateral_is_missing)
                 - SUM(identifier_matches)
        AS populated_but_identifier_differs_count,

    CASE
        WHEN source_value = 'S03'
         AND COUNT_BIG(*) = SUM(identifier_matches)
            THEN 'L_COLLATERAL_ID_MAPPING_PASSED'

        WHEN source_value = 'S17'
         AND COUNT_BIG(*) = SUM(collateral_is_missing)
            THEN 'L_COLLATERAL_ID_NOT_POPULATED'

        WHEN source_value = 'S01'
         AND SUM(identifier_matches) = 0
            THEN 'L_COLLATERAL_ID_HAS_DIFFERENT_SEMANTICS'

        ELSE 'REQUIRES_MAPPING_ANALYSIS'
    END AS control_status
FROM MappingFlags
GROUP BY source_value
ORDER BY source_value
OPTION (LOOP JOIN, MAXDOP 1);

/* ============================================================
   RESULT 6
   S01: отсутствие дублей и many-to-many связь
   ============================================================ */

;WITH Pairs AS
(
    SELECT
        p.c_loan_gid,
        p.c_collateral_id,
        COUNT_BIG(*) AS raw_pair_row_count
    FROM [risk_analytics].[pledges] p
    WHERE p.c_reporting_date = @ReportDate
      AND p.c_source = N'S01'
    GROUP BY
        p.c_loan_gid,
        p.c_collateral_id
),
Collateral AS
(
    SELECT
        c_collateral_id,
        COUNT_BIG(*) AS distinct_loan_gid_count,
        SUM(raw_pair_row_count) AS raw_row_count
    FROM Pairs
    GROUP BY c_collateral_id
)
SELECT
    @ReportDate AS report_date,
    'S01' AS source_value,

    SUM(raw_row_count) AS raw_row_count,
    SUM(distinct_loan_gid_count)
        AS distinct_loan_collateral_pair_count,

    SUM(raw_row_count) - SUM(distinct_loan_gid_count)
        AS duplicate_extra_row_count,

    COUNT_BIG(*) AS distinct_collateral_id_count,

    SUM(CASE
        WHEN distinct_loan_gid_count > 1 THEN 1 ELSE 0
    END) AS collateral_ids_linked_to_multiple_loans,

    SUM(CASE
        WHEN distinct_loan_gid_count > 1
        THEN distinct_loan_gid_count - 1 ELSE 0
    END) AS additional_loan_relationship_count,

    MAX(distinct_loan_gid_count)
        AS maximum_loans_per_collateral_id,

    CASE
        WHEN SUM(raw_row_count) =
             SUM(distinct_loan_gid_count)
        THEN 'NO_DUPLICATES_VALID_MANY_TO_MANY_RELATIONSHIP'
        ELSE 'DUPLICATE_RELATIONSHIPS_REQUIRE_ANALYSIS'
    END AS control_status
FROM Collateral
OPTION (MAXDOP 1);
GO


-- ============================================================================
-- B3. Risk_DWH_Retest_Pack_20260716 (RETEST_01-06) — DWH-01..07 (периметр)
-- Addendum-нарратив: DWH-01 (1 S02 актив без loan_account, 7.19М, рекуррентный
-- паттерн), DWH-02 (44 SMART_CARD нигде в NEW, 90.96М), DWH-03 (3909
-- неактивных ненулевых без actual_closure), DWH-04 (159 603 выпавших S02,
-- 152 810 нулевых/6 793 ненулевых на момент исчезновения, сумма abs=162.3М),
-- DWH-05 (S17: 7 неуникальных номеров / 14 loan_id, 7 найдены в loan_account,
-- 7 нет; ещё 276 loan_id-с-другим-номером), DWH-06 (1 технический дубль
-- loans_active S02), DWH-07 (1 остаток 1000.00 после закрытия).
-- ============================================================================
/* =====================================================================
   RISK DWH — ДОПОЛНИТЕЛЬНЫЙ РЕТЕСТ ПЕРИМЕТРА
   Дата подготовки: 2026-07-16
   Контрольный срез: 2026-07-01

   Только SELECT и временные таблицы.
   Идентификаторы договоров в результатах не выводятся.
   Каждый раздел самостоятельный и может запускаться отдельно.
   ===================================================================== */


/* =====================================================================
   RETEST_01. Активный S02 с ненулевым старым балансом,
              отсутствующий в loan_account по обоим ключам.

   Baseline: 1 договор / 7 192 116,63.
   Acceptance: 0 договоров / 0 баланс.
   ===================================================================== */

SET NOCOUNT ON;

DECLARE @ReportDate_01 date = '2026-07-01';
DECLARE @Tolerance_01 decimal(38,6) = 0.01;

DROP TABLE IF EXISTS #R1_A;
DROP TABLE IF EXISTS #R1_LI;
DROP TABLE IF EXISTS #R1_LC;
DROP TABLE IF EXISTS #R1_O;

SELECT DISTINCT
    LTRIM(RTRIM(CONVERT(nvarchar(255),l.l_loan_id)))
        COLLATE DATABASE_DEFAULT AS loan_id_key,
    LTRIM(RTRIM(CONVERT(nvarchar(255),l.l_loan_number)))
        COLLATE DATABASE_DEFAULT AS contract_key
INTO #R1_A
FROM [Dictionaries].[risk_analytics].[loans_active] l
WHERE l.l_report_date = @ReportDate_01
  AND l.l_source = 'S02';

SELECT DISTINCT
    LTRIM(RTRIM(CONVERT(nvarchar(255),la.la_loan_id)))
        COLLATE DATABASE_DEFAULT AS loan_id_key
INTO #R1_LI
FROM [Dictionaries].[risk_analytics].[loan_account] la
WHERE la.la_reporting_date = @ReportDate_01
  AND la.la_source = 'S02'
  AND la.la_loan_id IS NOT NULL;

SELECT DISTINCT
    LTRIM(RTRIM(CONVERT(nvarchar(255),la.la_dog_num)))
        COLLATE DATABASE_DEFAULT AS contract_key
INTO #R1_LC
FROM [Dictionaries].[risk_analytics].[loan_account] la
WHERE la.la_reporting_date = @ReportDate_01
  AND la.la_source = 'S02'
  AND la.la_dog_num IS NOT NULL;

SELECT
    LTRIM(RTRIM(CONVERT(nvarchar(255),p.contract_number)))
        COLLATE DATABASE_DEFAULT AS contract_key,
    CONVERT(decimal(38,6),COALESCE(p.outstanding,0.0)
        + COALESCE(p.outstanding_overdue,0.0)) AS principal_balance,
    CONVERT(decimal(38,6),COALESCE(p.balance,0.0)) AS stored_balance
INTO #R1_O
FROM [CL_PORTFOLIO].[dbo].[PORTFOLIO_CREDITCARDS_MIGR_WAY4] p
WHERE p.[date] = @ReportDate_01

UNION ALL

SELECT
    LTRIM(RTRIM(CONVERT(nvarchar(255),p.contract_number)))
        COLLATE DATABASE_DEFAULT,
    CONVERT(decimal(38,6),COALESCE(p.outstanding,0.0)
        + COALESCE(p.outstanding_overdue,0.0)),
    CONVERT(decimal(38,6),COALESCE(p.balance,0.0))
FROM [CL_PORTFOLIO].[dbo].[PORTFOLIO_CREDITCARDS_SMART_CARD] p
WHERE p.[date] = @ReportDate_01

UNION ALL

SELECT
    LTRIM(RTRIM(CONVERT(nvarchar(255),p.contract_number)))
        COLLATE DATABASE_DEFAULT,
    CONVERT(decimal(38,6),COALESCE(p.outstanding,0.0)
        + COALESCE(p.outstanding_overdue,0.0)),
    CONVERT(decimal(38,6),COALESCE(p.balance,0.0))
FROM [CL_PORTFOLIO].[dbo].[PORTFOLIO_CREDITCARDS_WAY4] p
WHERE p.[date] = @ReportDate_01;

SELECT
    @ReportDate_01 AS report_date,
    COUNT_BIG(*) AS active_old_nonzero_missing_count,
    COALESCE(SUM(o.principal_balance),0) AS principal_balance_sum,
    COALESCE(SUM(o.stored_balance),0) AS stored_balance_sum,
    CASE WHEN COUNT_BIG(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS control_status
FROM #R1_O o
INNER JOIN #R1_A a
    ON a.contract_key = o.contract_key
LEFT JOIN #R1_LI li
    ON li.loan_id_key = a.loan_id_key
LEFT JOIN #R1_LC lc
    ON lc.contract_key = a.contract_key
WHERE ABS(o.stored_balance) > @Tolerance_01
  AND li.loan_id_key IS NULL
  AND lc.contract_key IS NULL
OPTION (MAXDOP 2, RECOMPILE);
GO


/* =====================================================================
   RETEST_02. SMART_CARD с ненулевым балансом, отсутствующие
              в текущих loans и loan_account.

   Baseline: 44 договора / 90 960 726,55 balance.
   Acceptance: 0 необъяснённых договоров.
   ===================================================================== */

SET NOCOUNT ON;

DECLARE @ReportDate_02 date = '2026-07-01';
DECLARE @Tolerance_02 decimal(38,6) = 0.01;

DROP TABLE IF EXISTS #R2_M;
DROP TABLE IF EXISTS #R2_LA;

SELECT DISTINCT
    LTRIM(RTRIM(CONVERT(nvarchar(255),l.l_loan_number)))
        COLLATE DATABASE_DEFAULT AS contract_key
INTO #R2_M
FROM [Dictionaries].[risk_analytics].[loans] l
WHERE l.l_report_date = @ReportDate_02
  AND l.l_source = 'S02'
  AND l.l_loan_number IS NOT NULL;

SELECT DISTINCT
    LTRIM(RTRIM(CONVERT(nvarchar(255),la.la_dog_num)))
        COLLATE DATABASE_DEFAULT AS contract_key
INTO #R2_LA
FROM [Dictionaries].[risk_analytics].[loan_account] la
WHERE la.la_reporting_date = @ReportDate_02
  AND la.la_source = 'S02'
  AND la.la_dog_num IS NOT NULL;

SELECT
    @ReportDate_02 AS report_date,
    COUNT_BIG(*) AS smart_missing_master_and_balance_count,
    SUM(CONVERT(bigint,CASE
        WHEN LTRIM(RTRIM(COALESCE(p.[status],''))) = 'Account OK'
        THEN 1 ELSE 0 END)) AS account_ok_count,
    COALESCE(SUM(CONVERT(decimal(38,6),COALESCE(p.outstanding,0.0)
        + COALESCE(p.outstanding_overdue,0.0))),0) AS principal_balance_sum,
    COALESCE(SUM(CONVERT(decimal(38,6),COALESCE(p.balance,0.0))),0)
        AS stored_balance_sum,
    CASE WHEN COUNT_BIG(*) = 0 THEN 'PASS' ELSE 'FAIL_OR_REQUIRES_EXPLANATION'
         END AS control_status
FROM [CL_PORTFOLIO].[dbo].[PORTFOLIO_CREDITCARDS_SMART_CARD] p
LEFT JOIN #R2_M m
    ON m.contract_key = LTRIM(RTRIM(CONVERT(nvarchar(255),p.contract_number)))
        COLLATE DATABASE_DEFAULT
LEFT JOIN #R2_LA la
    ON la.contract_key = LTRIM(RTRIM(CONVERT(nvarchar(255),p.contract_number)))
        COLLATE DATABASE_DEFAULT
WHERE p.[date] = @ReportDate_02
  AND ABS(CONVERT(decimal(38,6),COALESCE(p.balance,0.0))) > @Tolerance_02
  AND m.contract_key IS NULL
  AND la.contract_key IS NULL
OPTION (MAXDOP 2, RECOMPILE);
GO


/* =====================================================================
   RETEST_03. Качество loans_active: ключи, дубли и жизненный цикл.

   Acceptance:
     - missing_* = 0;
     - duplicate_loan_id_extra_row_count = 0;
     - active_with_actual_closure_count = 0;
     - нарушения дат = 0;
     - повтор номера договора S17 должен быть устранён либо документирован.
   ===================================================================== */

SET NOCOUNT ON;

DECLARE @ReportDate_03 date = '2026-07-01';

WITH b AS
(
    SELECT
        NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(20),l.l_source))),N'') AS source_key,
        NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(255),l.l_loan_id))),N'') AS loan_id_key,
        NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(255),l.l_loan_number))),N'')
            AS contract_key,
        l.l_loan_open_date,
        l.l_funding_date,
        l.l_first_repayment_date,
        l.l_scheduled_closure_date,
        l.l_actual_closure_date
    FROM [Dictionaries].[risk_analytics].[loans_active] l
    WHERE l.l_report_date = @ReportDate_03
),
n AS
(
    SELECT *,
        ROW_NUMBER() OVER
            (PARTITION BY source_key,loan_id_key ORDER BY contract_key)
            AS rn_loan_id,
        ROW_NUMBER() OVER
            (PARTITION BY source_key,contract_key ORDER BY loan_id_key)
            AS rn_contract
    FROM b
)
SELECT
    @ReportDate_03 AS report_date,
    CASE WHEN GROUPING(source_key) = 1 THEN 'ALL_SOURCES'
         ELSE COALESCE(source_key,'NULL_SOURCE') END AS source_value,
    COUNT_BIG(*) AS active_row_count,
    SUM(CONVERT(bigint,CASE WHEN source_key IS NULL THEN 1 ELSE 0 END))
        AS missing_source_count,
    SUM(CONVERT(bigint,CASE WHEN loan_id_key IS NULL THEN 1 ELSE 0 END))
        AS missing_loan_id_count,
    SUM(CONVERT(bigint,CASE WHEN contract_key IS NULL THEN 1 ELSE 0 END))
        AS missing_contract_number_count,
    SUM(CONVERT(bigint,CASE WHEN loan_id_key IS NOT NULL AND rn_loan_id > 1
        THEN 1 ELSE 0 END)) AS duplicate_loan_id_extra_row_count,
    SUM(CONVERT(bigint,CASE WHEN contract_key IS NOT NULL AND rn_contract > 1
        THEN 1 ELSE 0 END)) AS duplicate_contract_extra_row_count,
    SUM(CONVERT(bigint,CASE WHEN l_loan_open_date IS NULL THEN 1 ELSE 0 END))
        AS missing_open_date_count,
    SUM(CONVERT(bigint,CASE WHEN l_funding_date IS NULL THEN 1 ELSE 0 END))
        AS missing_funding_date_count,
    SUM(CONVERT(bigint,CASE WHEN l_loan_open_date > @ReportDate_03
        THEN 1 ELSE 0 END)) AS open_after_report_date_count,
    SUM(CONVERT(bigint,CASE WHEN l_funding_date > @ReportDate_03
        THEN 1 ELSE 0 END)) AS funding_after_report_date_count,
    SUM(CONVERT(bigint,CASE WHEN l_loan_open_date IS NOT NULL
        AND l_funding_date IS NOT NULL
        AND l_funding_date < l_loan_open_date THEN 1 ELSE 0 END))
        AS funding_before_open_count,
    SUM(CONVERT(bigint,CASE WHEN l_first_repayment_date IS NOT NULL
        AND l_funding_date IS NOT NULL
        AND l_first_repayment_date < l_funding_date THEN 1 ELSE 0 END))
        AS repayment_before_funding_count,
    SUM(CONVERT(bigint,CASE WHEN l_scheduled_closure_date IS NOT NULL
        AND l_loan_open_date IS NOT NULL
        AND l_scheduled_closure_date < l_loan_open_date THEN 1 ELSE 0 END))
        AS scheduled_closure_before_open_count,
    SUM(CONVERT(bigint,CASE WHEN l_actual_closure_date IS NOT NULL
        THEN 1 ELSE 0 END)) AS active_with_actual_closure_count
FROM n
GROUP BY GROUPING SETS ((source_key),())
ORDER BY CASE WHEN GROUPING(source_key) = 1 THEN 2 ELSE 1 END, source_value
OPTION (MAXDOP 2, RECOMPILE);
GO


/* =====================================================================
   RETEST_04. Полнота loans_active -> loan_account.

   Baseline ALL_SOURCES:
     exact match                         346 124;
     loan_id with different contract         276;
     contract under another loan_id             5;
     missing by both keys                240 309.

   Результат оценивается по согласованному data contract, а не только
   по требованию missing = 0.
   ===================================================================== */

SET NOCOUNT ON;

DECLARE @ReportDate_04 date = '2026-07-01';

DROP TABLE IF EXISTS #R4_A;
DROP TABLE IF EXISTS #R4_L;
DROP TABLE IF EXISTS #R4_C;
DROP TABLE IF EXISTS #R4_X;

SELECT DISTINCT
    NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(20),l.l_source))),N'')
        COLLATE DATABASE_DEFAULT AS source_key,
    NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(255),l.l_loan_id))),N'')
        COLLATE DATABASE_DEFAULT AS loan_id_key,
    NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(255),l.l_loan_number))),N'')
        COLLATE DATABASE_DEFAULT AS contract_key
INTO #R4_A
FROM [Dictionaries].[risk_analytics].[loans_active] l
WHERE l.l_report_date = @ReportDate_04;

SELECT DISTINCT
    NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(20),la.la_source))),N'')
        COLLATE DATABASE_DEFAULT AS source_key,
    NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(255),la.la_loan_id))),N'')
        COLLATE DATABASE_DEFAULT AS loan_id_key,
    NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(255),la.la_dog_num))),N'')
        COLLATE DATABASE_DEFAULT AS contract_key
INTO #R4_L
FROM [Dictionaries].[risk_analytics].[loan_account] la
WHERE la.la_reporting_date = @ReportDate_04;

SELECT DISTINCT source_key,contract_key
INTO #R4_C
FROM #R4_L
WHERE source_key IS NOT NULL AND contract_key IS NOT NULL;

SELECT
    a.source_key,a.loan_id_key,a.contract_key,
    COUNT(l.loan_id_key) AS rows_by_loan_id,
    SUM(CONVERT(bigint,CASE WHEN l.loan_id_key IS NOT NULL
        AND l.contract_key = a.contract_key THEN 1 ELSE 0 END))
        AS same_contract_rows,
    MAX(CASE WHEN c.contract_key IS NOT NULL THEN 1 ELSE 0 END)
        AS contract_present
INTO #R4_X
FROM #R4_A a
LEFT JOIN #R4_L l
    ON l.source_key = a.source_key AND l.loan_id_key = a.loan_id_key
LEFT JOIN #R4_C c
    ON c.source_key = a.source_key AND c.contract_key = a.contract_key
GROUP BY a.source_key,a.loan_id_key,a.contract_key
OPTION (MAXDOP 2, RECOMPILE);

WITH classified AS
(
    SELECT source_key,
        CASE
            WHEN same_contract_rows > 0 THEN 'MATCHED_BY_LOAN_ID_AND_CONTRACT'
            WHEN rows_by_loan_id > 0 THEN 'LOAN_ID_FOUND_WITH_DIFFERENT_CONTRACT'
            WHEN contract_present = 1 THEN 'CONTRACT_PRESENT_UNDER_OTHER_LOAN_ID'
            ELSE 'MISSING_BY_BOTH_KEYS'
        END AS coverage_status
    FROM #R4_X
),
s AS
(
    SELECT source_key,coverage_status,COUNT_BIG(*) AS active_key_count
    FROM classified
    GROUP BY source_key,coverage_status
),
r AS
(
    SELECT source_key,coverage_status,active_key_count FROM s
    UNION ALL
    SELECT N'ALL_SOURCES',coverage_status,SUM(active_key_count)
    FROM s GROUP BY coverage_status
)
SELECT
    @ReportDate_04 AS report_date,
    source_key AS source_value,
    coverage_status,
    active_key_count,
    SUM(active_key_count) OVER (PARTITION BY source_key) AS total_active_key_count,
    CAST(100.0 * active_key_count /
        NULLIF(SUM(active_key_count) OVER (PARTITION BY source_key),0)
        AS decimal(18,2)) AS active_key_percent
FROM r
ORDER BY CASE WHEN source_key = N'ALL_SOURCES' THEN 2 ELSE 1 END,
         source_key,coverage_status
OPTION (MAXDOP 2);
GO


/* =====================================================================
   RETEST_05. Качество ключей S17.

   Baseline:
     duplicate contract groups                 7;
     active loan_id in duplicate groups       14;
     found in loan_account                     7;
     missing from loan_account                 7;
     loan_id with different contract         276.
   ===================================================================== */

SET NOCOUNT ON;

DECLARE @ReportDate_05 date = '2026-07-01';

DROP TABLE IF EXISTS #R5_A;
DROP TABLE IF EXISTS #R5_L;
DROP TABLE IF EXISTS #R5_D;
DROP TABLE IF EXISTS #R5_DR;
DROP TABLE IF EXISTS #R5_BY_LOAN;

SELECT DISTINCT
    LTRIM(RTRIM(CONVERT(nvarchar(255),l.l_loan_id)))
        COLLATE DATABASE_DEFAULT AS loan_id_key,
    LTRIM(RTRIM(CONVERT(nvarchar(255),l.l_loan_number)))
        COLLATE DATABASE_DEFAULT AS contract_key
INTO #R5_A
FROM [Dictionaries].[risk_analytics].[loans_active] l
WHERE l.l_report_date = @ReportDate_05
  AND l.l_source = 'S17';

SELECT DISTINCT
    LTRIM(RTRIM(CONVERT(nvarchar(255),la.la_loan_id)))
        COLLATE DATABASE_DEFAULT AS loan_id_key,
    LTRIM(RTRIM(CONVERT(nvarchar(255),la.la_dog_num)))
        COLLATE DATABASE_DEFAULT AS contract_key
INTO #R5_L
FROM [Dictionaries].[risk_analytics].[loan_account] la
WHERE la.la_reporting_date = @ReportDate_05
  AND la.la_source = 'S17';

SELECT contract_key
INTO #R5_D
FROM #R5_A
GROUP BY contract_key
HAVING COUNT(DISTINCT loan_id_key) > 1;

SELECT a.loan_id_key,a.contract_key
INTO #R5_DR
FROM #R5_A a
INNER JOIN #R5_D d ON d.contract_key = a.contract_key;

SELECT
    a.loan_id_key,a.contract_key,
    MAX(CASE WHEN l.loan_id_key IS NOT NULL THEN 1 ELSE 0 END) AS any_la_by_id,
    MAX(CASE WHEN l.loan_id_key IS NOT NULL
        AND l.contract_key = a.contract_key THEN 1 ELSE 0 END) AS same_contract_la
INTO #R5_BY_LOAN
FROM #R5_A a
LEFT JOIN #R5_L l ON l.loan_id_key = a.loan_id_key
GROUP BY a.loan_id_key,a.contract_key;

SELECT
    @ReportDate_05 AS report_date,
    (SELECT COUNT_BIG(*) FROM #R5_D) AS duplicate_contract_group_count,
    (SELECT COUNT_BIG(*) FROM #R5_DR) AS active_loan_id_in_duplicate_groups,
    (SELECT COUNT_BIG(*)
     FROM #R5_DR d
     WHERE EXISTS (SELECT 1 FROM #R5_L l WHERE l.loan_id_key = d.loan_id_key))
        AS duplicate_group_loan_ids_found_in_loan_account,
    (SELECT COUNT_BIG(*)
     FROM #R5_DR d
     WHERE NOT EXISTS (SELECT 1 FROM #R5_L l WHERE l.loan_id_key = d.loan_id_key))
        AS duplicate_group_loan_ids_missing_from_loan_account,
    (SELECT COUNT_BIG(*) FROM #R5_BY_LOAN
     WHERE any_la_by_id = 1 AND same_contract_la = 0)
        AS loan_id_with_different_contract_count,
    CASE
        WHEN (SELECT COUNT_BIG(*) FROM #R5_D) = 0
         AND (SELECT COUNT_BIG(*) FROM #R5_BY_LOAN
              WHERE any_la_by_id = 1 AND same_contract_la = 0) = 0
        THEN 'PASS'
        ELSE 'FAIL_OR_REQUIRES_DOCUMENTED_KEY_RULE'
    END AS control_status
OPTION (MAXDOP 2, RECOMPILE);
GO


/* =====================================================================
   RETEST_06. Динамика состава loan_account по source.

   Контроль используется для подтверждения причины изменения S02
   и проверки стабильности после исправления.
   ===================================================================== */

SET NOCOUNT ON;

DECLARE @DateFrom_06 date = '2025-12-01';
DECLARE @DateTo_06 date = '2026-07-01';

WITH c AS
(
    SELECT
        la.la_reporting_date AS report_date,
        la.la_source AS source_value,
        COUNT_BIG(*) AS row_count
    FROM [Dictionaries].[risk_analytics].[loan_account] la
    WHERE la.la_reporting_date BETWEEN @DateFrom_06 AND @DateTo_06
    GROUP BY la.la_reporting_date,la.la_source
),
d AS
(
    SELECT *,
        LAG(row_count) OVER
            (PARTITION BY source_value ORDER BY report_date) AS previous_row_count
    FROM c
)
SELECT
    report_date,source_value,row_count,previous_row_count,
    row_count - previous_row_count AS row_count_change,
    CAST(100.0 * (row_count - previous_row_count)
        / NULLIF(previous_row_count,0) AS decimal(18,2))
        AS row_count_change_percent,
    CASE
        WHEN previous_row_count IS NULL THEN 'BASE_PERIOD'
        WHEN ABS(100.0 * (row_count - previous_row_count)
             / NULLIF(previous_row_count,0)) >= 20.0
        THEN 'SIGNIFICANT_SCOPE_CHANGE'
        ELSE 'NO_MATERIAL_COUNT_CHANGE'
    END AS control_status
FROM d
ORDER BY report_date,source_value
OPTION (MAXDOP 2, RECOMPILE);
GO


-- ============================================================================
-- B4. Risk_DWH_Retest_Pack_2_20260716 (RETEST_07-11) — DWH-08..12
-- Addendum-нарратив: DWH-08 (70 дублей loan_id в master loans S01 → риск
-- удвоения JOIN 197.6М→395.2М на 13 активных ключах), DWH-09 (4707
-- SMART_CARD: старый лимит>0, новый l_loan_amount=0, 490.8М), DWH-10 (1176
-- необъяснённых S01 сумм, 272 с ненулевым Total_outstanding=351.68 млрд —
-- вероятно гарантии/овердрафты, требует продуктового правила), DWH-11
-- (заполненность классификаций по source — системные NULL up-stream, не
-- между loans_active/loans), DWH-12 (587 расхождений статуса S02).
-- ============================================================================
/* =====================================================================
   RISK DWH — РЕТЕСТ №2
   Дата подготовки: 2026-07-16
   Контрольный срез: 2026-07-01

   Проверки DWH-08–DWH-12 из второго addendum.
   Только SELECT и временные таблицы.
   loan_id и номера договоров в результаты не выводятся.
   ===================================================================== */

USE [CL_PORTFOLIO];
GO


/* =====================================================================
   RETEST_07. Полные дубли S01 в master loans.

   Baseline:
     duplicate_loan_id_group_count       70;
     duplicate_extra_row_count           70;
     affected_current_loan_account_ids   13.

   Acceptance: все три показателя равны 0.
   ===================================================================== */

SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

DECLARE @ReportDate_07 date = '2026-07-01';

DROP TABLE IF EXISTS #R7_D;
DROP TABLE IF EXISTS #R7_LA;

SELECT
    UPPER(LTRIM(RTRIM(CONVERT(nvarchar(4000),l.l_loan_id))))
        COLLATE DATABASE_DEFAULT AS loan_id_key,
    COUNT_BIG(*) AS master_row_count
INTO #R7_D
FROM [Dictionaries].[risk_analytics].[loans] l
WHERE l.l_report_date = @ReportDate_07
  AND l.l_source = 'S01'
  AND NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000),l.l_loan_id))),N'')
      IS NOT NULL
GROUP BY
    UPPER(LTRIM(RTRIM(CONVERT(nvarchar(4000),l.l_loan_id))))
        COLLATE DATABASE_DEFAULT
HAVING COUNT_BIG(*) > 1;

CREATE UNIQUE CLUSTERED INDEX IX_R7_D ON #R7_D(loan_id_key);

SELECT
    UPPER(LTRIM(RTRIM(CONVERT(nvarchar(4000),la.la_loan_id))))
        COLLATE DATABASE_DEFAULT AS loan_id_key,
    COUNT_BIG(*) AS loan_account_row_count
INTO #R7_LA
FROM [Dictionaries].[risk_analytics].[loan_account] la
INNER JOIN #R7_D d
    ON d.loan_id_key =
       UPPER(LTRIM(RTRIM(CONVERT(nvarchar(4000),la.la_loan_id))))
           COLLATE DATABASE_DEFAULT
WHERE la.la_reporting_date = @ReportDate_07
  AND la.la_source = 'S01'
GROUP BY
    UPPER(LTRIM(RTRIM(CONVERT(nvarchar(4000),la.la_loan_id))))
        COLLATE DATABASE_DEFAULT;

SELECT
    @ReportDate_07 AS report_date,
    'S01' AS source_value,
    COUNT_BIG(*) AS duplicate_loan_id_group_count,
    COALESCE(SUM(d.master_row_count),0) AS master_raw_row_count,
    COALESCE(SUM(d.master_row_count - 1),0) AS duplicate_extra_row_count,
    COALESCE(MAX(d.master_row_count),0) AS maximum_group_size,
    COALESCE(SUM(CONVERT(bigint,CASE WHEN la.loan_id_key IS NOT NULL
                                     THEN 1 ELSE 0 END)),0)
        AS affected_current_loan_account_ids,
    COALESCE(SUM(la.loan_account_row_count),0)
        AS affected_current_loan_account_rows,
    CASE
        WHEN COUNT_BIG(*) = 0 THEN 'PASS'
        ELSE 'FAIL_MASTER_DUPLICATES_PRESENT'
    END AS control_status
FROM #R7_D d
LEFT JOIN #R7_LA la
    ON la.loan_id_key = d.loan_id_key
OPTION (MAXDOP 2,RECOMPILE);
GO


/* =====================================================================
   RETEST_08. Полнота лимитов активных SMART_CARD.

   Baseline:
     OLD_POSITIVE_NEW_ZERO       4 707 / old limit 490 796 954,95;
     BOTH_POSITIVE_DIFFERENT         3 / old 2 750 000, new 6 500 000.

   Acceptance:
     0 необъяснённых OLD_POSITIVE_NEW_ZERO и
     0 необъяснённых BOTH_POSITIVE_DIFFERENT.
   ===================================================================== */

SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

DECLARE @ReportDate_08 date = '2026-07-01';
DECLARE @Tolerance_08 decimal(38,6) = 0.01;

DROP TABLE IF EXISTS #R8_A;
DROP TABLE IF EXISTS #R8_M;
DROP TABLE IF EXISTS #R8_X;

SELECT DISTINCT
    UPPER(LTRIM(RTRIM(CONVERT(nvarchar(4000),a.l_loan_id))))
        COLLATE DATABASE_DEFAULT AS loan_id_key,
    UPPER(LTRIM(RTRIM(CONVERT(nvarchar(4000),a.l_loan_number))))
        COLLATE DATABASE_DEFAULT AS contract_key
INTO #R8_A
FROM [Dictionaries].[risk_analytics].[loans_active] a
WHERE a.l_report_date = @ReportDate_08
  AND a.l_source = 'S02';

CREATE UNIQUE CLUSTERED INDEX IX_R8_A
    ON #R8_A(contract_key,loan_id_key);

SELECT
    UPPER(LTRIM(RTRIM(CONVERT(nvarchar(4000),m.l_loan_id))))
        COLLATE DATABASE_DEFAULT AS loan_id_key,
    MAX(TRY_CONVERT(decimal(38,6),m.l_loan_amount)) AS new_loan_amount,
    MAX(TRY_CONVERT(decimal(38,6),m.l_limit)) AS new_limit,
    MAX(TRY_CONVERT(decimal(38,6),m.l_unutilized_limit))
        AS new_unutilized_limit
INTO #R8_M
FROM [Dictionaries].[risk_analytics].[loans] m
INNER JOIN #R8_A a
    ON a.loan_id_key =
       UPPER(LTRIM(RTRIM(CONVERT(nvarchar(4000),m.l_loan_id))))
           COLLATE DATABASE_DEFAULT
WHERE m.l_report_date = @ReportDate_08
  AND m.l_source = 'S02'
GROUP BY
    UPPER(LTRIM(RTRIM(CONVERT(nvarchar(4000),m.l_loan_id))))
        COLLATE DATABASE_DEFAULT;

CREATE UNIQUE CLUSTERED INDEX IX_R8_M ON #R8_M(loan_id_key);

SELECT
    a.loan_id_key,
    TRY_CONVERT(decimal(38,6),p.[limit]) AS old_limit,
    TRY_CONVERT(decimal(38,6),p.unused_limit) AS old_unused_limit,
    TRY_CONVERT(decimal(38,6),p.balance) AS old_balance,
    m.new_loan_amount,
    m.new_limit,
    m.new_unutilized_limit,
    CASE
        WHEN COALESCE(TRY_CONVERT(decimal(38,6),p.[limit]),0) > 0
         AND COALESCE(m.new_loan_amount,0) = 0
            THEN 'OLD_POSITIVE_NEW_ZERO'
        WHEN COALESCE(TRY_CONVERT(decimal(38,6),p.[limit]),0) > 0
         AND COALESCE(m.new_loan_amount,0) > 0
         AND ABS(TRY_CONVERT(decimal(38,6),p.[limit])
                 - m.new_loan_amount) > @Tolerance_08
            THEN 'BOTH_POSITIVE_DIFFERENT'
        WHEN TRY_CONVERT(decimal(38,6),p.[limit]) IS NULL
            THEN 'OLD_LIMIT_NULL'
        ELSE 'MATCH_OR_NOT_APPLICABLE'
    END AS limit_status
INTO #R8_X
FROM [CL_PORTFOLIO].[dbo].[PORTFOLIO_CREDITCARDS_SMART_CARD] p
INNER JOIN #R8_A a
    ON a.contract_key =
       UPPER(LTRIM(RTRIM(CONVERT(nvarchar(4000),p.contract_number))))
           COLLATE DATABASE_DEFAULT
LEFT JOIN #R8_M m
    ON m.loan_id_key = a.loan_id_key
WHERE p.[date] = @ReportDate_08;

SELECT
    @ReportDate_08 AS report_date,
    'S02' AS source_value,
    'PORTFOLIO_CREDITCARDS_SMART_CARD' AS old_table,
    limit_status,
    COUNT_BIG(*) AS contract_count,
    SUM(CONVERT(bigint,CASE WHEN ABS(COALESCE(old_balance,0))
                                  > @Tolerance_08
                            THEN 1 ELSE 0 END))
        AS nonzero_old_balance_contract_count,
    COALESCE(SUM(old_limit),0) AS old_limit_sum,
    COALESCE(SUM(new_loan_amount),0) AS new_loan_amount_sum,
    COALESCE(SUM(old_balance),0) AS old_balance_sum,
    SUM(CONVERT(bigint,CASE WHEN new_unutilized_limit IS NULL
                            THEN 1 ELSE 0 END))
        AS new_unutilized_limit_null_count,
    CASE
        WHEN limit_status IN
             ('OLD_POSITIVE_NEW_ZERO','BOTH_POSITIVE_DIFFERENT')
            THEN 'FAIL_OR_REQUIRES_DOCUMENTED_MAPPING'
        ELSE 'PASS_OR_NOT_APPLICABLE'
    END AS control_status
FROM #R8_X
GROUP BY limit_status
ORDER BY contract_count DESC
OPTION (MAXDOP 2,RECOMPILE);
GO


/* =====================================================================
   RETEST_09. Активные S01 с необъяснённым l_loan_amount.

   Baseline:
     affected contract count                    1 176;
     nonzero Total_outstanding count               272;
     old Total_outstanding sum      351 680 163 809,78.

   Иностранная валюта с положительными обеими суммами здесь не
   помечается: она проверяется после FX conversion.

   Acceptance: 0 необъяснённых записей либо утверждённый перечень
   продуктовых исключений.
   ===================================================================== */

SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

DECLARE @ReportDate_09 date = '2026-07-01';
DECLARE @Tolerance_09 decimal(38,6) = 0.01;

DROP TABLE IF EXISTS #R9_A;
DROP TABLE IF EXISTS #R9_M;
DROP TABLE IF EXISTS #R9_X;

SELECT DISTINCT
    UPPER(LTRIM(RTRIM(CONVERT(nvarchar(4000),a.l_loan_id))))
        COLLATE DATABASE_DEFAULT AS loan_id_key,
    UPPER(LTRIM(RTRIM(CONVERT(nvarchar(4000),a.l_loan_number))))
        COLLATE DATABASE_DEFAULT AS contract_key
INTO #R9_A
FROM [Dictionaries].[risk_analytics].[loans_active] a
WHERE a.l_report_date = @ReportDate_09
  AND a.l_source = 'S01';

CREATE UNIQUE CLUSTERED INDEX IX_R9_A
    ON #R9_A(contract_key,loan_id_key);

SELECT
    UPPER(LTRIM(RTRIM(CONVERT(nvarchar(4000),m.l_loan_id))))
        COLLATE DATABASE_DEFAULT AS loan_id_key,
    MAX(TRY_CONVERT(decimal(38,6),m.l_loan_amount)) AS new_loan_amount,
    MAX(NULLIF(UPPER(LTRIM(RTRIM(CONVERT(nvarchar(100),m.l_currency)))),N''))
        AS new_currency
INTO #R9_M
FROM [Dictionaries].[risk_analytics].[loans] m
INNER JOIN #R9_A a
    ON a.loan_id_key =
       UPPER(LTRIM(RTRIM(CONVERT(nvarchar(4000),m.l_loan_id))))
           COLLATE DATABASE_DEFAULT
WHERE m.l_report_date = @ReportDate_09
  AND m.l_source = 'S01'
GROUP BY
    UPPER(LTRIM(RTRIM(CONVERT(nvarchar(4000),m.l_loan_id))))
        COLLATE DATABASE_DEFAULT;

CREATE UNIQUE CLUSTERED INDEX IX_R9_M ON #R9_M(loan_id_key);

SELECT
    UPPER(LTRIM(RTRIM(CONVERT(nvarchar(100),p.curr)))) AS old_currency,
    TRY_CONVERT(decimal(38,6),p.Creditamount) AS old_credit_amount,
    TRY_CONVERT(decimal(38,6),p.Total_outstanding) AS old_stored_balance,
    m.new_loan_amount,
    CASE
        WHEN COALESCE(TRY_CONVERT(decimal(38,6),p.Creditamount),0) > 0
         AND COALESCE(m.new_loan_amount,0) = 0
            THEN 'OLD_POSITIVE_NEW_ZERO'
        WHEN UPPER(LTRIM(RTRIM(CONVERT(nvarchar(100),p.curr)))) = 'KZT'
         AND COALESCE(TRY_CONVERT(decimal(38,6),p.Creditamount),0) > 0
         AND COALESCE(m.new_loan_amount,0) > 0
         AND ABS(TRY_CONVERT(decimal(38,6),p.Creditamount)
                 - m.new_loan_amount) > @Tolerance_09
            THEN 'KZT_BOTH_POSITIVE_DIFFERENT'
        ELSE 'PASS_OR_FX_CHECKED_SEPARATELY'
    END AS amount_status
INTO #R9_X
FROM [CL_PORTFOLIO].[dbo].[PORTFOLIO_RS] p
INNER JOIN #R9_A a
    ON a.contract_key =
       UPPER(LTRIM(RTRIM(CONVERT(nvarchar(4000),p.contractnumber))))
           COLLATE DATABASE_DEFAULT
LEFT JOIN #R9_M m
    ON m.loan_id_key = a.loan_id_key
WHERE p.actual_date = @ReportDate_09;

SELECT
    @ReportDate_09 AS report_date,
    'S01' AS source_value,
    amount_status,
    old_currency,
    COUNT_BIG(*) AS contract_count,
    SUM(CONVERT(bigint,CASE WHEN ABS(COALESCE(old_stored_balance,0))
                                  > @Tolerance_09
                            THEN 1 ELSE 0 END))
        AS nonzero_old_balance_contract_count,
    COALESCE(SUM(old_credit_amount),0) AS old_credit_amount_sum,
    COALESCE(SUM(new_loan_amount),0) AS new_loan_amount_sum,
    COALESCE(SUM(old_stored_balance),0) AS old_stored_balance_sum,
    CASE
        WHEN amount_status IN
             ('OLD_POSITIVE_NEW_ZERO','KZT_BOTH_POSITIVE_DIFFERENT')
            THEN 'FAIL_OR_REQUIRES_PRODUCT_RULE'
        ELSE 'PASS_OR_NOT_APPLICABLE'
    END AS control_status
FROM #R9_X
GROUP BY amount_status,old_currency
ORDER BY
    CASE WHEN amount_status = 'PASS_OR_FX_CHECKED_SEPARATELY'
         THEN 2 ELSE 1 END,
    contract_count DESC
OPTION (MAXDOP 2,RECOMPILE);
GO


/* =====================================================================
   RETEST_10. Заполненность классификаций loans_active.

   Acceptance определяется утверждённой матрицей обязательности
   полей по source. Текущие значения являются baseline.
   ===================================================================== */

SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

DECLARE @ReportDate_10 date = '2026-07-01';

WITH ActiveUnique AS
(
    SELECT
        a.l_source AS source_value,
        UPPER(LTRIM(RTRIM(CONVERT(nvarchar(4000),a.l_loan_id))))
            COLLATE DATABASE_DEFAULT AS loan_id_key,
        MAX(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(1000),a.l_loan_type))),N''))
            AS loan_type,
        MAX(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(1000),a.l_product_type))),N''))
            AS product_type,
        MAX(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(1000),a.l_subproduct_type))),N''))
            AS subproduct_type,
        MAX(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(1000),a.l_loan_purpose))),N''))
            AS loan_purpose,
        MAX(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(1000),a.l_credit_purpose))),N''))
            AS credit_purpose,
        MAX(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(1000),a.l_credit_object))),N''))
            AS credit_object,
        MAX(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(1000),a.l_entrepreneur_category))),N''))
            AS entrepreneur_category,
        MAX(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(1000),a.l_reward_rate_type))),N''))
            AS reward_rate_type
    FROM [Dictionaries].[risk_analytics].[loans_active] a
    WHERE a.l_report_date = @ReportDate_10
      AND a.l_source IN ('S01','S02','S03','S17')
    GROUP BY
        a.l_source,
        UPPER(LTRIM(RTRIM(CONVERT(nvarchar(4000),a.l_loan_id))))
            COLLATE DATABASE_DEFAULT
),
Unpivoted AS
(
    SELECT
        u.source_value,
        p.attribute_name,
        p.attribute_value
    FROM ActiveUnique u
    CROSS APPLY
    (
        VALUES
            ('LOAN_TYPE',u.loan_type),
            ('PRODUCT_TYPE',u.product_type),
            ('SUBPRODUCT_TYPE',u.subproduct_type),
            ('LOAN_PURPOSE',u.loan_purpose),
            ('CREDIT_PURPOSE',u.credit_purpose),
            ('CREDIT_OBJECT',u.credit_object),
            ('ENTREPRENEUR_CATEGORY',u.entrepreneur_category),
            ('REWARD_RATE_TYPE',u.reward_rate_type)
    ) p(attribute_name,attribute_value)
)
SELECT
    @ReportDate_10 AS report_date,
    source_value,
    attribute_name,
    COUNT_BIG(*) AS active_distinct_loan_id_count,
    SUM(CONVERT(bigint,CASE WHEN attribute_value IS NOT NULL
                            THEN 1 ELSE 0 END)) AS filled_count,
    SUM(CONVERT(bigint,CASE WHEN attribute_value IS NULL
                            THEN 1 ELSE 0 END)) AS null_count,
    CAST(100.0 * SUM(CONVERT(bigint,CASE WHEN attribute_value IS NOT NULL
                                         THEN 1 ELSE 0 END))
         / NULLIF(COUNT_BIG(*),0) AS decimal(10,2)) AS filled_percent,
    CASE
        WHEN SUM(CONVERT(bigint,CASE WHEN attribute_value IS NULL
                                     THEN 1 ELSE 0 END)) = 0
            THEN 'FULLY_FILLED'
        WHEN SUM(CONVERT(bigint,CASE WHEN attribute_value IS NOT NULL
                                     THEN 1 ELSE 0 END)) = 0
            THEN 'COMPLETELY_EMPTY_REQUIRES_MAPPING_RULE'
        ELSE 'PARTIALLY_FILLED_REQUIRES_THRESHOLD'
    END AS control_status
FROM Unpivoted
GROUP BY source_value,attribute_name
ORDER BY source_value,attribute_name
OPTION (MAXDOP 2,RECOMPILE);
GO


/* =====================================================================
   RETEST_11. Расхождения статусов S02.

   Baseline:
     STATUS_MISMATCH / ACTIVE       192 / balance 13 995 719,55;
     STATUS_MISMATCH / NOT_ACTIVE   395 / balance 22 390 250,64;
     NOT_FOUND_IN_MASTER             68 / balance 90 960 726,55.

   Acceptance: 0 необъяснённых расхождений либо утверждённое
   правило переходов статуса.
   ===================================================================== */

SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

DECLARE @ReportDate_11 date = '2026-07-01';
DECLARE @Tolerance_11 decimal(38,6) = 0.01;

DROP TABLE IF EXISTS #R11_O;
DROP TABLE IF EXISTS #R11_M;
DROP TABLE IF EXISTS #R11_A;

CREATE TABLE #R11_O
(
    old_table    varchar(100)   COLLATE DATABASE_DEFAULT NOT NULL,
    contract_key nvarchar(4000) COLLATE DATABASE_DEFAULT NOT NULL,
    old_status   nvarchar(1000) COLLATE DATABASE_DEFAULT NULL,
    old_balance  decimal(38,6)  NULL
);

INSERT INTO #R11_O(old_table,contract_key,old_status,old_balance)
SELECT
    'PORTFOLIO_CREDITCARDS_MIGR_WAY4',
    UPPER(LTRIM(RTRIM(CONVERT(nvarchar(4000),p.contract_number))))
        COLLATE DATABASE_DEFAULT,
    NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(1000),p.[status]))),N''),
    TRY_CONVERT(decimal(38,6),p.balance)
FROM [CL_PORTFOLIO].[dbo].[PORTFOLIO_CREDITCARDS_MIGR_WAY4] p
WHERE p.[date] = @ReportDate_11

UNION ALL

SELECT
    'PORTFOLIO_CREDITCARDS_SMART_CARD',
    UPPER(LTRIM(RTRIM(CONVERT(nvarchar(4000),p.contract_number))))
        COLLATE DATABASE_DEFAULT,
    NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(1000),p.[status]))),N''),
    TRY_CONVERT(decimal(38,6),p.balance)
FROM [CL_PORTFOLIO].[dbo].[PORTFOLIO_CREDITCARDS_SMART_CARD] p
WHERE p.[date] = @ReportDate_11

UNION ALL

SELECT
    'PORTFOLIO_CREDITCARDS_WAY4',
    UPPER(LTRIM(RTRIM(CONVERT(nvarchar(4000),p.contract_number))))
        COLLATE DATABASE_DEFAULT,
    NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(1000),p.[status]))),N''),
    TRY_CONVERT(decimal(38,6),p.balance)
FROM [CL_PORTFOLIO].[dbo].[PORTFOLIO_CREDITCARDS_WAY4] p
WHERE p.[date] = @ReportDate_11;

CREATE CLUSTERED INDEX IX_R11_O ON #R11_O(contract_key,old_table);

SELECT
    UPPER(LTRIM(RTRIM(CONVERT(nvarchar(4000),m.l_loan_number))))
        COLLATE DATABASE_DEFAULT AS contract_key,
    MAX(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(1000),m.l_loan_status))),N''))
        AS new_status
INTO #R11_M
FROM [Dictionaries].[risk_analytics].[loans] m
WHERE m.l_report_date = @ReportDate_11
  AND m.l_source = 'S02'
GROUP BY
    UPPER(LTRIM(RTRIM(CONVERT(nvarchar(4000),m.l_loan_number))))
        COLLATE DATABASE_DEFAULT;

CREATE UNIQUE CLUSTERED INDEX IX_R11_M ON #R11_M(contract_key);

SELECT DISTINCT
    UPPER(LTRIM(RTRIM(CONVERT(nvarchar(4000),a.l_loan_number))))
        COLLATE DATABASE_DEFAULT AS contract_key
INTO #R11_A
FROM [Dictionaries].[risk_analytics].[loans_active] a
WHERE a.l_report_date = @ReportDate_11
  AND a.l_source = 'S02';

CREATE UNIQUE CLUSTERED INDEX IX_R11_A ON #R11_A(contract_key);

WITH Classified AS
(
    SELECT
        o.old_table,
        o.old_balance,
        CASE WHEN a.contract_key IS NULL THEN 'NOT_ACTIVE'
             ELSE 'ACTIVE' END AS active_status,
        CASE
            WHEN m.contract_key IS NULL THEN 'NOT_FOUND_IN_MASTER'
            WHEN UPPER(COALESCE(o.old_status,N'')) <>
                 UPPER(COALESCE(m.new_status,N'')) THEN 'STATUS_MISMATCH'
            ELSE 'STATUS_MATCH'
        END AS status_control
    FROM #R11_O o
    LEFT JOIN #R11_M m ON m.contract_key = o.contract_key
    LEFT JOIN #R11_A a ON a.contract_key = o.contract_key
)
SELECT
    @ReportDate_11 AS report_date,
    status_control,
    active_status,
    COUNT_BIG(*) AS contract_count,
    SUM(CONVERT(bigint,CASE WHEN ABS(COALESCE(old_balance,0))
                                  > @Tolerance_11
                            THEN 1 ELSE 0 END))
        AS nonzero_old_balance_contract_count,
    COALESCE(SUM(old_balance),0) AS old_balance_sum,
    CASE
        WHEN status_control = 'STATUS_MATCH' THEN 'PASS'
        WHEN status_control = 'NOT_FOUND_IN_MASTER'
            THEN 'FAIL_MASTER_PERIMETER'
        ELSE 'FAIL_OR_REQUIRES_DOCUMENTED_STATUS_RULE'
    END AS control_status
FROM Classified
WHERE status_control <> 'STATUS_MATCH'
GROUP BY status_control,active_status
ORDER BY status_control,active_status
OPTION (MAXDOP 2,RECOMPILE);
GO


/* ============================================================================
   КОНЕЦ АРХИВА
   ============================================================================ */
