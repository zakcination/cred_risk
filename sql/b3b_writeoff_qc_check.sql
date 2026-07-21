/* =============================================================================
   ПРОСТЫМ ЯЗЫКОМ:
   Мы вручную нашли 4 займа, где комментарий отдела противоречит поданному
   статусу «Полное погашение» (на самом деле — списание/банкротство). Сверка с
   таблицей spis_v_ubytok_RS (реестр списанных в убыток займов) показала, что
   таких займов не 4, а 20 — ручное чтение комментариев пропустило 16 из них.
   Этот скрипт превращает разовую находку в ПОВТОРЯЕМУЮ проверку: берём все
   займы, поданные в B3B с причиной «полное погашение», и ищем их в реестре
   списания. Если займ есть в обоих местах — это противоречие, и не нужно
   вычитывать комментарии глазами, чтобы это заметить.
   -----------------------------------------------------------------------------
   QC gate: cross-check B3B submissions marked «полное погашение» against the
   write-off-to-loss ledger(s). Any loan in BOTH is a contradiction — the
   submitted status says "repaid", the ledger says "written off". Generalizes
   the 4-loan manual catch (comment-reading) that spis_v_ubytok_RS cross-check
   expanded to 20.

   Run §0 first (schema discovery — real columns of spis_v_ubytok_RS, plus a
   sweep for sibling write-off ledgers per source system: B3B spans all six —
   CL/Fenix/RS/3×Cards — spis_v_ubytok_RS only covers RS).
   T-SQL (Microsoft SQL Server).
   ============================================================================= */

-------------------------------------------------------------------------------
-- 0a. Real columns of spis_v_ubytok_RS — confirm the join key (guessing
--     contractnumber, matching RS's naming elsewhere in this repo) and the
--     write-off date column before trusting §1's join.
-------------------------------------------------------------------------------
SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH, ORDINAL_POSITION
FROM [CL_PORTFOLIO].INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'spis_v_ubytok_RS'
ORDER BY ORDINAL_POSITION;

-------------------------------------------------------------------------------
-- 0b. Sibling write-off ledgers — B3B covers 6 source systems, this table is
--     RS-only. If CL/Fenix/Cards have equivalents (spis_v_ubytok_CL,
--     _Fenix/_EBCL, _Cards/_W4...), the same contradiction can exist there too.
-------------------------------------------------------------------------------
SELECT t.name AS table_name, c.name AS column_name, ty.name AS data_type
FROM [CL_PORTFOLIO].sys.tables t
JOIN [CL_PORTFOLIO].sys.columns c ON c.object_id = t.object_id
JOIN [CL_PORTFOLIO].sys.types   ty ON ty.user_type_id = c.user_type_id
WHERE t.name LIKE 'spis_v_ubytok%'
ORDER BY t.name, c.column_id;

/* =============================================================================
   1. THE CHECK — B3B loans marked «полное погашение» that also appear in the
   write-off ledger. Reads the B3B raw source directly (LOAN_ID + comment) and
   applies the same reference map as b3b_comment_mapping.sql so this stays
   consistent with the official submission logic — copy that script's
   `map_ref` CTE here if the mapping decisions have moved on since 16.07.2026.
   ⚠ ADJUST: [contractnumber] below is a GUESS — replace with whatever §0a
   shows as the real key/date columns on spis_v_ubytok_RS.
   ============================================================================= */
;WITH b3b_repaid AS (
    SELECT [LOAN_ID], [comment] AS raw_comment
    FROM [CL_PORTFOLIO].[dbo].[FOR_B3B_AQR2026_16072026]
    WHERE LOWER(LTRIM(RTRIM([comment]))) IN (N'полное погашение', N'погашен', N'погашение')
       OR LOWER(LTRIM(RTRIM([comment]))) LIKE N'%погашен%'   -- widen/narrow to match the mapped reason_E='полное погашение' set exactly
)
SELECT
    b.[LOAN_ID],
    b.raw_comment                       AS submitted_comment,
    w.[contractnumber]                  AS writeoff_ledger_match,   -- ⚠ confirm real column name (§0a)
    N'полное погашение'                 AS submitted_reason_E,
    N'списание (spis_v_ubytok_RS)'      AS contradicts_with
FROM b3b_repaid b
JOIN [CL_PORTFOLIO].[dbo].[spis_v_ubytok_RS] w
    ON w.[contractnumber] = b.[LOAN_ID]     -- ⚠ confirm join key (§0a)
ORDER BY b.[LOAN_ID];

-------------------------------------------------------------------------------
-- 2. Count check — should equal 20 against the current spis_v_ubytok_RS
--    snapshot; re-run after each cycle's data refresh to catch drift.
-------------------------------------------------------------------------------
;WITH b3b_repaid AS (
    SELECT [LOAN_ID]
    FROM [CL_PORTFOLIO].[dbo].[FOR_B3B_AQR2026_16072026]
    WHERE LOWER(LTRIM(RTRIM([comment]))) LIKE N'%погашен%'
)
SELECT COUNT(DISTINCT b.[LOAN_ID]) AS contradicting_loans
FROM b3b_repaid b
JOIN [CL_PORTFOLIO].[dbo].[spis_v_ubytok_RS] w ON w.[contractnumber] = b.[LOAN_ID];

-------------------------------------------------------------------------------
-- Notes
-------------------------------------------------------------------------------
-- * This is the RS slice only (§0b tells you if CL/Fenix/Cards have their own
--   write-off ledger to repeat this against — B3B is not RS-only).
-- * The fix belongs in the SUBMISSION (column E → списание for these 20), not
--   in this script — this is a detector, re-run it before every submission.
-- * Candidate standing QC gate for future cycles: run this straight after
--   b3b_comment_mapping.sql, same session, and block submission if the count
--   in §2 is nonzero without a documented override.
