/* =============================================================================
   B3B AQR 2026 — closed-before-audited-year reconciliation
   =============================================================================
   Purpose
   -------
   B3B is the list of "special-case" contracts that were present at the start of
   a quarter and disappeared by its end (they affect the PD calculation). For CL
   / CrediLogic source-system loans the closing dates (dte_close) come from the
   system owner ("Гроз Б.М.Э."). Some of those closing dates fall BEFORE the
   audited year (2025), yet the loans still appear in the 2025 report. That
   contradiction is what the regulator questions ("closed before 2025 but
   reported in 2025").

   This script cross-checks each B3B loan against the objective portfolio
   time-series [CL_PORTFOLIO_2] and surfaces, per loan, its ACTUAL last presence
   and state — the evidence that either corroborates or contradicts a
   "closed-before-2025" claim. It implements the check behind §6 of the B3B
   guide ("Фильтр по аудируемому году").

   Tables
   ------
   base  : [CL_PORTFOLIO].[dbo].[FOR_B3B_AQR2026_16072026]   -- B3B scope, key = [LOAN_ID]
   ts    : [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2]              -- monthly/periodic snapshots,
                                                              --   key = (contract_number, [date])
   Join  : base.[LOAN_ID] = ts.contract_number

   Output (one row per base LOAN_ID; all base rows kept):
     - the latest snapshot values (date, od, balance, dpd, category, tag_1,
       status, balance_with_discount, provisions_total);
     - presence aggregates (first/last snapshot, last snapshot within the
       audited year, # of rows in the audited year);
     - reconciliation flags for the review.

   T-SQL (Microsoft SQL Server).
   ============================================================================= */

-------------------------------------------------------------------------------
-- 0. Parameters — the audited year window [start, end) as a half-open interval.
-------------------------------------------------------------------------------
DECLARE @AuditYearStart date = '20250101';   -- first day of the audited year
DECLARE @AuditYearEnd   date = '20260101';   -- first day of the NEXT year (exclusive)

-------------------------------------------------------------------------------
-- 1. Main reconciliation extract (READ-ONLY).
--    Latest snapshot per contract + audited-year presence, joined to the base.
-------------------------------------------------------------------------------
WITH p AS (
    SELECT
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
        -- pick the most recent snapshot deterministically (tie-break on balance)
        ROW_NUMBER() OVER (
            PARTITION BY t.contract_number
            ORDER BY t.[date] DESC, t.[balance] DESC
        ) AS rn_latest,
        -- per-contract presence aggregates (constant within the partition)
        MIN(t.[date]) OVER (PARTITION BY t.contract_number) AS first_snapshot_date,
        MAX(t.[date]) OVER (PARTITION BY t.contract_number) AS last_snapshot_date,
        MAX(CASE WHEN t.[date] >= @AuditYearStart AND t.[date] < @AuditYearEnd
                 THEN t.[date] END)
            OVER (PARTITION BY t.contract_number) AS last_snapshot_in_audit_year,
        SUM(CASE WHEN t.[date] >= @AuditYearStart AND t.[date] < @AuditYearEnd
                 THEN 1 ELSE 0 END)
            OVER (PARTITION BY t.contract_number) AS rows_in_audit_year
    FROM [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2] t
    -- restrict the time-series to B3B loans only (performance)
    INNER JOIN [CL_PORTFOLIO].[dbo].[FOR_B3B_AQR2026_16072026] b
        ON b.[LOAN_ID] = t.contract_number
)
SELECT
    b.[LOAN_ID],

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

    -- reconciliation flags -----------------------------------------------------
    -- loan is in the B3B scope but has NO snapshot at all in the time-series
    CASE WHEN p.contract_number IS NULL THEN 1 ELSE 0 END              AS missing_in_portfolio,
    -- loan has NO snapshot within the audited year → looks gone before 2025
    CASE WHEN p.contract_number IS NOT NULL AND p.rows_in_audit_year = 0
         THEN 1 ELSE 0 END                                            AS no_activity_in_audit_year,
    -- last-ever snapshot predates the audited year (strongest "closed before" signal)
    CASE WHEN p.last_snapshot_date < @AuditYearStart THEN 1 ELSE 0 END AS last_activity_before_audit_year,
    -- balance already zero at the last snapshot (consistent with a close/repay)
    CASE WHEN p.[balance] = 0 THEN 1 ELSE 0 END                        AS zero_balance_at_last,
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
      (Run this instead of section 1 when you just want the exceptions.)
   -----------------------------------------------------------------------------
   Wrap section 1 in a CTE `recon` and filter:

   ; WITH recon AS ( <the SELECT from section 1, without ORDER BY> )
   SELECT * FROM recon
   WHERE review_flag = 1
   ORDER BY missing_in_portfolio DESC, no_activity_in_audit_year DESC,
            last_activity_before_audit_year DESC, last_snapshot_date;
   ----------------------------------------------------------------------------- */


/* -----------------------------------------------------------------------------
   3. OPTIONAL — persist the result into a new table (non-destructive).
      Change section 1's `SELECT` to `SELECT ... INTO` and drop first if re-running:
   -----------------------------------------------------------------------------
   IF OBJECT_ID('[CL_PORTFOLIO].[dbo].[B3B_AQR2026_RECON_2025]', 'U') IS NOT NULL
       DROP TABLE [CL_PORTFOLIO].[dbo].[B3B_AQR2026_RECON_2025];
   -- then add:  INTO [CL_PORTFOLIO].[dbo].[B3B_AQR2026_RECON_2025]
   --            right before the FROM clause of section 1.
   ----------------------------------------------------------------------------- */


/* -----------------------------------------------------------------------------
   4. OPTIONAL — enrich the base table in place (DESTRUCTIVE: alters the base).
      Review carefully; take a backup of the base table first. This adds the
      latest-snapshot columns onto [FOR_B3B_AQR2026_16072026] and populates them.
   -----------------------------------------------------------------------------
   ALTER TABLE [CL_PORTFOLIO].[dbo].[FOR_B3B_AQR2026_16072026]
       ADD last_snapshot_date date,
           od_last              decimal(38,2),
           balance_last         decimal(38,2),
           dpd_last             int,
           category_last        nvarchar(255),
           tag_1_last           nvarchar(255),
           status_last          nvarchar(255),
           balance_with_discount_last decimal(38,2),
           provisions_total_last      decimal(38,2),
           rows_in_audit_year   int,
           review_flag          bit;
   GO
   -- then UPDATE base SET ... FROM the section-1 CTE joined on LOAN_ID = contract_number.
   ----------------------------------------------------------------------------- */

-------------------------------------------------------------------------------
-- Notes
-------------------------------------------------------------------------------
-- * "Latest snapshot" uses ROW_NUMBER() (not MAX(date)+self-join) so contracts
--   with two rows on the same max date do NOT duplicate; the tie-break is
--   date DESC, balance DESC. Adjust the tie-break if your grain differs.
-- * `no_activity_in_audit_year` / `last_activity_before_audit_year` are the
--   objective counter-evidence to a "closed before 2025" claim: if the loan has
--   real snapshots inside 2025, its presence in the 2025 report is defensible.
-- * `status` / `category` value matching for "closed" is left open because the
--   enum is source-specific; filter on the real values once confirmed.
-- * To reconcile against the CLAIMED close date and the sales/write-off marks,
--   LEFT JOIN the close-date source (CL/CrediLogic dte_close) and
--   [CL_PORTFOLIO].[dbo].[SOLD_PORTFOLIO_FOR_LGD] (nocont = LOAN_ID) and compare
--   the claimed close date against last_snapshot_date.
