/* =============================================================================
   PROV_A0e_probe.sql — Track A, шаг 0e. ПРЕДЛОЖЕНИЕ, запускать по решению Мираса.
   Повод — Мирас, 12.10.2026: KAN_20260901_for_LGD_Fenix — база дефолтов,
   KAN_20260901_restructura — база реструктуризаций (TRACK_A_PLAN §11.10).

   Вопросы и критерии (до прогона):
   §0 Колонки KAN_20260901_restructura (только имена).
   §1 Объясняют ли две базы категории 2–3 старой базы. Обесценение по п. 5
      Приложения 4 — 90+ ИЛИ реструктуризация из-за ухудшения (README §2.6).
      Ожидание: категория 3 ⊂ (дефолт ∪ реструктуризация) почти полностью;
      категория 1 — почти вне обеих. Категория 3 вне обеих баз > 1 % —
      признак обесценения не из этих двух таблиц (смерть, банкротство и т. п.)
      либо иная логика посадки — вопрос ОПАиРоз.

   Правила (§4 CLAUDE.md): только SELECT, #A0e_*, MAXDOP 1, трёхчастные имена, IIN не
   выбирается, номера договоров — только внутри JOIN/COUNT.
   ============================================================================= */

/* §0. Живой аудит имён.                                                            */
SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE, ORDINAL_POSITION
FROM [IFRS9].INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'dbo' AND TABLE_NAME = 'KAN_20260901_restructura'
ORDER BY ORDINAL_POSITION;
GO

/* §1. Покрытие категорий старой базы двумя базами KAN.
   account_number в restructura — ПРОВЕРИТЬ ПО §0; если ключ назван иначе — заменить
   в одной строке ниже, остальное не трогать.                                       */
DECLARE @AsOf date = '2026-10-01';

IF OBJECT_ID('tempdb..#A0e_def') IS NOT NULL DROP TABLE #A0e_def;
SELECT DISTINCT account_number
INTO #A0e_def
FROM [IFRS9].[dbo].[KAN_20260901_for_LGD_Fenix]
OPTION (MAXDOP 1);

IF OBJECT_ID('tempdb..#A0e_res') IS NOT NULL DROP TABLE #A0e_res;
SELECT DISTINCT account_number                       -- ← проверить по §0
INTO #A0e_res
FROM [IFRS9].[dbo].[KAN_20260901_restructura]
OPTION (MAXDOP 1);

SELECT o.category,
       CASE WHEN d.account_number IS NOT NULL AND r.account_number IS NOT NULL THEN '1 дефолт + рестр.'
            WHEN d.account_number IS NOT NULL THEN '2 только дефолт'
            WHEN r.account_number IS NOT NULL THEN '3 только рестр.'
            ELSE '4 ни в одной' END                              AS kan_base,
       COUNT(*)                                                  AS contracts,
       SUM(CAST(o.balance_with_discount AS decimal(38,2)))       AS sum_bwd,
       SUM(CAST(o.provisions_total      AS decimal(38,2)))       AS sum_p_old,
       SUM(CASE WHEN o.dpd >= 91 THEN 1 ELSE 0 END)              AS contracts_dpd_91
FROM [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2] o
LEFT JOIN #A0e_def d ON d.account_number = o.contract_number
LEFT JOIN #A0e_res r ON r.account_number = o.contract_number
WHERE o.[date] = @AsOf
GROUP BY o.category,
       CASE WHEN d.account_number IS NOT NULL AND r.account_number IS NOT NULL THEN '1 дефолт + рестр.'
            WHEN d.account_number IS NOT NULL THEN '2 только дефолт'
            WHEN r.account_number IS NOT NULL THEN '3 только рестр.'
            ELSE '4 ни в одной' END
ORDER BY o.category, kan_base
OPTION (MAXDOP 1);
GO

IF OBJECT_ID('tempdb..#A0e_def') IS NOT NULL DROP TABLE #A0e_def;
IF OBJECT_ID('tempdb..#A0e_res') IS NOT NULL DROP TABLE #A0e_res;
