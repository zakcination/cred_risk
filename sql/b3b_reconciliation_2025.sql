/* =============================================================================
   B3B AQR 2026 — closed-before-audited-year reconciliation (all source systems)
   =============================================================================
   Purpose
   -------
   B3B is the list of "special-case" contracts that were present at the start of
   a quarter and disappeared by its end (they affect the PD calculation). Closing
   dates come from the source-system owners; some fall BEFORE the audited year
   (2025) yet the loans still appear in the 2025 report. That contradiction is
   what the regulator questions ("closed before 2025 but reported in 2025").

   This script cross-checks each B3B loan against the objective portfolio
   time-series and surfaces, per loan, its ACTUAL last presence and state — the
   evidence that corroborates or contradicts a "closed-before-2025" claim. It
   implements the check behind §6 of the B3B guide ("Фильтр по аудируемому году").

   Each loan_id belongs to ONE source system (B3B guide §2), so the time-series
   is the UNION of all source-system portfolio tables, not CL_PORTFOLIO_2 alone:

     source system              table
     -------------------------  ------------------------------------------------
     Credilogic (CL)            [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2]
     Fenix (EBCL)               [CL_PORTFOLIO].[dbo].[PORTFOLIO_Fenix]
     RS                         [CL_PORTFOLIO].[dbo].[PORTFOLIO_RS]
     Cards — MIGR_WAY4 (W)      [CL_PORTFOLIO].[dbo].[PORTFOLIO_CREDITCARDS_MIGR_WAY4]
     Cards — SMART_CARD (W)     [CL_PORTFOLIO].[dbo].[PORTFOLIO_CREDITCARDS_SMART_CARD]
     Cards — WAY4 (W)           [CL_PORTFOLIO].[dbo].[PORTFOLIO_CREDITCARDS_WAY4]

   base : [CL_PORTFOLIO].[dbo].[FOR_B3B_AQR2026_16072026]   -- B3B scope, key = [LOAN_ID]
   ts   : the UNION ALL of the six tables above             -- key = (contract_number, [date])
   Join : base.[LOAN_ID] = ts.contract_number

   Output (one row per base LOAN_ID; all base rows kept): the source system and
   latest-snapshot values, presence aggregates, and reconciliation flags.

   ASSUMPTION: every source table exposes the same columns used below
   (contract_number, [date], od, balance, dpd, category, tag_1, status,
   balance_with_discount, provisions_total) with compatible types. If a table
   names a column differently or lacks one, adjust THAT branch of the UNION —
   alias it, or substitute CAST(NULL AS <type>) AS <col>. Types must line up
   across branches (UNION ALL uses the first branch's types).

   T-SQL (Microsoft SQL Server).
   ============================================================================= */

-------------------------------------------------------------------------------
-- 0. Parameters — the audited year window [start, end) as a half-open interval.
-------------------------------------------------------------------------------
DECLARE @AuditYearStart date = '20250101';   -- first day of the audited year
DECLARE @AuditYearEnd   date = '20260101';   -- first day of the NEXT year (exclusive)

-------------------------------------------------------------------------------
-- 1. Main reconciliation extract (READ-ONLY).
--    Unified time-series across all source systems + latest snapshot per
--    contract + audited-year presence, joined to the base.
--
--    NOTE: the leading ';' before WITH is required. A CTE must be the first
--    statement in the batch or the previous statement must be terminated; the
--    ';' guarantees that. Without it SQL Server can misparse the CTE and try to
--    EXECUTE the next table name — the cause of "Msg 2809 ... is a table object".
-------------------------------------------------------------------------------
;WITH ts AS (
    -- one row per (source_system, contract_number, date). Keep the column list
    -- identical in every branch; edit a branch only if that table differs.
    SELECT 'Credilogic'            AS source_system, contract_number, [date], [od], [balance], [dpd], [category], [tag_1], [status], [balance_with_discount], [provisions_total] FROM [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2]
    UNION ALL
    SELECT 'Fenix'                 AS source_system, contract_number, [date], [od], [balance], [dpd], [category], [tag_1], [status], [balance_with_discount], [provisions_total] FROM [CL_PORTFOLIO].[dbo].[PORTFOLIO_Fenix]
    UNION ALL
    SELECT 'RS'                    AS source_system, contract_number, [date], [od], [balance], [dpd], [category], [tag_1], [status], [balance_with_discount], [provisions_total] FROM [CL_PORTFOLIO].[dbo].[PORTFOLIO_RS]
    UNION ALL
    SELECT 'CREDITCARDS_MIGR_WAY4' AS source_system, contract_number, [date], [od], [balance], [dpd], [category], [tag_1], [status], [balance_with_discount], [provisions_total] FROM [CL_PORTFOLIO].[dbo].[PORTFOLIO_CREDITCARDS_MIGR_WAY4]
    UNION ALL
    SELECT 'SMART_CARD'            AS source_system, contract_number, [date], [od], [balance], [dpd], [category], [tag_1], [status], [balance_with_discount], [provisions_total] FROM [CL_PORTFOLIO].[dbo].[PORTFOLIO_CREDITCARDS_SMART_CARD]
    UNION ALL
    SELECT 'CREDITCARDS_WAY4'      AS source_system, contract_number, [date], [od], [balance], [dpd], [category], [tag_1], [status], [balance_with_discount], [provisions_total] FROM [CL_PORTFOLIO].[dbo].[PORTFOLIO_CREDITCARDS_WAY4]
),
p AS (
    SELECT
        t.source_system,
        t.contract_number,
        t.[date],
        t.[od],
        t.[balance],
        t.[dpd],
        t.[category],
        t.[tag_1],
        t.[status],
        t.[balance_with_discount],
        t.[provisions_total],
        -- pick the most recent snapshot deterministically, across ALL systems
        -- (tie-break on balance, then source_system for stability)
        ROW_NUMBER() OVER (
            PARTITION BY t.contract_number
            ORDER BY t.[date] DESC, t.[balance] DESC, t.source_system
        ) AS rn_latest,
        -- per-contract presence aggregates (constant within the partition)
        MIN(t.[date]) OVER (PARTITION BY t.contract_number) AS first_snapshot_date,
        MAX(t.[date]) OVER (PARTITION BY t.contract_number) AS last_snapshot_date,
        MAX(CASE WHEN t.[date] >= @AuditYearStart AND t.[date] < @AuditYearEnd
                 THEN t.[date] END)
            OVER (PARTITION BY t.contract_number) AS last_snapshot_in_audit_year,
        SUM(CASE WHEN t.[date] >= @AuditYearStart AND t.[date] < @AuditYearEnd
                 THEN 1 ELSE 0 END)
            OVER (PARTITION BY t.contract_number) AS rows_in_audit_year,
        -- how many distinct source systems this contract appears in (should be 1)
        DENSE_RANK() OVER (PARTITION BY t.contract_number ORDER BY t.source_system)
          + DENSE_RANK() OVER (PARTITION BY t.contract_number ORDER BY t.source_system DESC)
          - 1                                            AS distinct_source_systems
    FROM ts t
    -- restrict the time-series to B3B loans only (performance)
    INNER JOIN [CL_PORTFOLIO].[dbo].[FOR_B3B_AQR2026_16072026] b
        ON b.[LOAN_ID] = t.contract_number
)
SELECT
    b.[LOAN_ID],
    p.source_system,                          -- system holding the latest snapshot

    -- latest snapshot (values are from the rn_latest = 1 row)
    p.last_snapshot_date,
    p.[od],
    p.[balance],
    p.[dpd],
    p.[category],
    p.[tag_1],
    p.[status],
    p.[balance_with_discount],
    p.[provisions_total],

    -- presence context
    p.first_snapshot_date,
    p.last_snapshot_in_audit_year,
    p.rows_in_audit_year,
    p.distinct_source_systems,

    -- reconciliation flags -----------------------------------------------------
    -- loan is in the B3B scope but has NO snapshot in ANY source system
    CASE WHEN p.contract_number IS NULL THEN 1 ELSE 0 END              AS missing_in_portfolio,
    -- loan has snapshots, but NONE within the audited year → looks gone before 2025
    CASE WHEN p.contract_number IS NOT NULL AND p.rows_in_audit_year = 0
         THEN 1 ELSE 0 END                                            AS no_activity_in_audit_year,
    -- last-ever snapshot predates the audited year (strongest "closed before" signal)
    CASE WHEN p.last_snapshot_date < @AuditYearStart THEN 1 ELSE 0 END AS last_activity_before_audit_year,
    -- balance already zero at the last snapshot (consistent with a close/repay)
    CASE WHEN p.[balance] = 0 THEN 1 ELSE 0 END                        AS zero_balance_at_last,
    -- data-quality: contract found in more than one source system
    CASE WHEN p.distinct_source_systems > 1 THEN 1 ELSE 0 END          AS multi_source_system,
    -- headline: needs manual review before defending inclusion in the 2025 report
    CASE WHEN p.contract_number IS NULL
              OR p.rows_in_audit_year = 0
              OR p.last_snapshot_date < @AuditYearStart
         THEN 1 ELSE 0 END                                            AS review_flag
FROM [CL_PORTFOLIO].[dbo].[FOR_B3B_AQR2026_16072026] b
LEFT JOIN p
    ON p.contract_number = b.[LOAN_ID]
   AND p.rn_latest = 1
ORDER BY review_flag DESC, no_activity_in_audit_year DESC, p.last_snapshot_date;


/* -----------------------------------------------------------------------------
   2. Problem list only — the loans a reviewer must look at.
      Wrap section 1 (the two CTEs + the SELECT, minus its ORDER BY) in one more
      CTE `recon` and filter:

      ; WITH ts AS (...), p AS (...), recon AS ( <the final SELECT, no ORDER BY> )
      SELECT * FROM recon
      WHERE review_flag = 1
      ORDER BY missing_in_portfolio DESC, no_activity_in_audit_year DESC,
               last_activity_before_audit_year DESC, last_snapshot_date;
   ----------------------------------------------------------------------------- */


/* -----------------------------------------------------------------------------
   3. OPTIONAL — persist the result into a new table (non-destructive).
      Add  INTO [CL_PORTFOLIO].[dbo].[B3B_AQR2026_RECON_2025]  before the final
      FROM, dropping first if re-running:

      IF OBJECT_ID('[CL_PORTFOLIO].[dbo].[B3B_AQR2026_RECON_2025]','U') IS NOT NULL
          DROP TABLE [CL_PORTFOLIO].[dbo].[B3B_AQR2026_RECON_2025];
   ----------------------------------------------------------------------------- */


/* -----------------------------------------------------------------------------
   4. OPTIONAL — enrich the base table in place (DESTRUCTIVE: alters the base).
      Review carefully; back up [FOR_B3B_AQR2026_16072026] first. Adds the
      source_system + latest-snapshot columns and populates them.

      ALTER TABLE [CL_PORTFOLIO].[dbo].[FOR_B3B_AQR2026_16072026]
          ADD source_system nvarchar(50), last_snapshot_date date,
              od_last decimal(38,2), balance_last decimal(38,2), dpd_last int,
              category_last nvarchar(255), tag_1_last nvarchar(255),
              status_last nvarchar(255), balance_with_discount_last decimal(38,2),
              provisions_total_last decimal(38,2), rows_in_audit_year int,
              review_flag bit;
      GO
      -- then UPDATE base SET ... FROM the section-1 CTEs joined on LOAN_ID.
   ----------------------------------------------------------------------------- */

-------------------------------------------------------------------------------
-- Notes
-------------------------------------------------------------------------------
-- * The time-series is the UNION ALL of all six source-system tables so a B3B
--   loan is found wherever it lives (CL / Fenix / RS / cards). `source_system`
--   reports where the latest snapshot came from.
-- * "Latest snapshot" uses ROW_NUMBER() (not MAX(date)+self-join) so a contract
--   with two rows on the same max date does NOT duplicate; tie-break is
--   date DESC, balance DESC, source_system.
-- * `distinct_source_systems` / `multi_source_system` flag the (unexpected) case
--   of a loan present in more than one system — a data-quality signal.
-- * `no_activity_in_audit_year` / `last_activity_before_audit_year` are the
--   objective counter-evidence to a "closed before 2025" claim: real snapshots
--   inside 2025 make the loan's presence in the 2025 report defensible.
-- * Performance: the INNER JOIN to the base pushes the B3B filter into each
--   UNION branch when contract_number is indexed. If plans scan whole tables,
--   add  WHERE contract_number IN (SELECT [LOAN_ID] FROM base)  to each branch.
-- * To reconcile against the CLAIMED close date and the sale/write-off marks,
--   LEFT JOIN the close-date source (e.g. CrediLogic dte_close / cards
--   DATE_EXPIRE) and [CL_PORTFOLIO].[dbo].[SOLD_PORTFOLIO_FOR_LGD]
--   (nocont = LOAN_ID), and compare the claimed date against last_snapshot_date.
