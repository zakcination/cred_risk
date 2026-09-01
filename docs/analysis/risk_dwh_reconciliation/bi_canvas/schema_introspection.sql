/* ============================================================================
   DWH_SCHEMA_INTROSPECTION_20260730
   Назначение: закрыть пробел "таблица известна из инвентаря (credit_risk_
   knowledge_base.md), но колонки не каталогизированы" для BI-холста процессов.

   Правила CLAUDE.md (risk_dwh_reconciliation), соблюдены построчно:
     - Только SELECT. Ни одного INSERT/UPDATE/DELETE/MERGE/DROP/ALTER.
     - MAXDOP 1 на каждом запросе.
     - Без PII в выводе: здесь только имена/типы столбцов (метаданные схемы),
       ни одной строки данных не запрашивается.
     - Cross-db (CL_PORTFOLIO ↔ Dictionaries) работает только на одном
       инстансе — блоки разделены по USE, запускайте оба на своём инстансе;
       если cross-db ошибка — это тоже находка (нужен linked server).

   Как использовать результат: пришлите мне вывод обоих блоков (или просто
   вставьте текстом) — я заполню "columns: не каталогизировано" реальными
   списками столбцов, типами и PK/FK на схеме.
   ============================================================================ */


/* ============================================================================
   БЛОК 1 — Dictionaries.risk_analytics: все 19 таблиц марта
   (5 из них уже частично каталогизированы по draft SQL — здесь их тоже
   перепроверяем, остальные 14 закрываем впервые)
   ============================================================================ */
USE [Dictionaries];

SELECT
    t.TABLE_SCHEMA,
    t.TABLE_NAME,
    c.COLUMN_NAME,
    c.ORDINAL_POSITION,
    c.DATA_TYPE,
    c.CHARACTER_MAXIMUM_LENGTH,
    c.NUMERIC_PRECISION,
    c.NUMERIC_SCALE,
    c.IS_NULLABLE
FROM INFORMATION_SCHEMA.TABLES t
JOIN INFORMATION_SCHEMA.COLUMNS c
    ON c.TABLE_SCHEMA = t.TABLE_SCHEMA
   AND c.TABLE_NAME   = t.TABLE_NAME
WHERE t.TABLE_SCHEMA = 'risk_analytics'
  AND t.TABLE_NAME IN (
      N'borrower', N'loans', N'loan_account', N'repayment_schedule',
      N'payments', N'payments_wiring', N'pledges', N'ratings',
      N'restructuring_v2', N'writeoff', N'collections', N'bankrupt',
      N'interest_rates', N'offbalance', N'guarantees', N'credit_lines',
      N'refinance', N'loans_active', N'brm_all_data'
  )
ORDER BY t.TABLE_NAME, c.ORDINAL_POSITION
OPTION (MAXDOP 1);

-- заявленные в БД первичные/уникальные/внешние ключи (если объявлены —
-- часто в такого рода мартах их нет физически, тогда результат пуст,
-- это тоже находка: ключи только логические, см. Issue #8)
SELECT
    tc.TABLE_NAME,
    tc.CONSTRAINT_TYPE,
    kcu.COLUMN_NAME,
    kcu.ORDINAL_POSITION
FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc
JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu
    ON kcu.CONSTRAINT_NAME   = tc.CONSTRAINT_NAME
   AND kcu.TABLE_SCHEMA      = tc.TABLE_SCHEMA
WHERE tc.TABLE_SCHEMA = 'risk_analytics'
  AND tc.CONSTRAINT_TYPE IN (N'PRIMARY KEY', N'UNIQUE', N'FOREIGN KEY')
ORDER BY tc.TABLE_NAME, tc.CONSTRAINT_TYPE, kcu.ORDINAL_POSITION
OPTION (MAXDOP 1);

-- какие таблицы в схеме вообще существуют под этими или похожими именами
-- (страховка: если реальное имя чуть отличается от инвентаря, увидим здесь)
SELECT TABLE_SCHEMA, TABLE_NAME
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA = 'risk_analytics'
ORDER BY TABLE_NAME
OPTION (MAXDOP 1);


/* ============================================================================
   БЛОК 2 — CL_PORTFOLIO.dbo: старые PORTFOLIO_*/spis_v_ubytok_* таблицы
   (4 уже частично каталогизированы по тестовым SQL из переписки — здесь
   тоже перепроверяем, остальные 6 закрываем впервые)
   ============================================================================ */
USE [CL_PORTFOLIO];

SELECT
    t.TABLE_SCHEMA,
    t.TABLE_NAME,
    c.COLUMN_NAME,
    c.ORDINAL_POSITION,
    c.DATA_TYPE,
    c.CHARACTER_MAXIMUM_LENGTH,
    c.NUMERIC_PRECISION,
    c.NUMERIC_SCALE,
    c.IS_NULLABLE
FROM INFORMATION_SCHEMA.TABLES t
JOIN INFORMATION_SCHEMA.COLUMNS c
    ON c.TABLE_SCHEMA = t.TABLE_SCHEMA
   AND c.TABLE_NAME   = t.TABLE_NAME
WHERE t.TABLE_SCHEMA = 'dbo'
  AND t.TABLE_NAME IN (
      N'PORTFOLIO_RS', N'CL_PORTFOLIO_2', N'PORTFOLIO_Fenix',
      N'PORTFOLIO_CREDITCARDS_WAY4', N'PORTFOLIO_CREDITCARDS_MIGR_WAY4',
      N'PORTFOLIO_CREDITCARDS_SMART_CARD', N'PORTFOLIO_OFF_BALANCE',
      N'PORTFOLIO_RS_7130', N'spis_v_ubytok_CL', N'spis_v_ubytok_RS'
  )
ORDER BY t.TABLE_NAME, c.ORDINAL_POSITION
OPTION (MAXDOP 1);

-- страховка на случай, что точное имя в этой базе отличается от инвентаря
-- (например суффикс/версия) — ищем всё похожее
SELECT TABLE_SCHEMA, TABLE_NAME
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_NAME LIKE 'PORTFOLIO%'
   OR TABLE_NAME LIKE 'CL_PORTFOLIO%'
   OR TABLE_NAME LIKE 'spis_v_ubytok%'
ORDER BY TABLE_NAME
OPTION (MAXDOP 1);
