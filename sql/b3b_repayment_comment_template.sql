/* =============================================================================
   ПРОСТЫМ ЯЗЫКОМ:
   Не нужно разных шаблонов на каждую АБИС — один универсальный комментарий на
   все займы: «Документы и запрошенные выписки вложены в папке «выписки»».
   Выписки за этот год лежат в
   R:\!!!!!!AQR_2026\B3B\на отправку\22.07.2026\выписки. Займы, которые на
   самом деле НЕ погашены (отменённый ДБЗ / реально списаны в убыток — см.
   §7.3 гайда), этот универсальный комментарий не получают — для них нужен
   отдельный, содержательный комментарий, а не ссылка на выписки о погашении.
   -----------------------------------------------------------------------------
   One universal «Комментарии/пояснения Банка» comment for this cycle's B3B
   loans — "documents and requested statements are attached in the «выписки»
   folder" — instead of the source-system-specific templates from the 2025
   cycle. Loans already known NOT to be genuine repayments (cancelled
   agreements, actual write-offs per b3b_writeoff_qc_check.sql) are excluded —
   see docs/b3b_guide.md §6.1.
   T-SQL (Microsoft SQL Server).
   ============================================================================= */

-- ⚠ ОБНОВЛЯТЬ КАЖДЫЙ ЦИКЛ. Дата в пути — это дата отправки конкретной партии
--   (22.07.2026), а не константа: со следующей партией папка будет другая, а
--   комментарий уйдёт аудитору с ссылкой на несуществующий каталог. Здесь же
--   меняется и таблица-источник в блоке src ниже (FOR_B3B_AQR2026_16072026 —
--   тоже с датой в имени).
DECLARE @StatementsFolder nvarchar(200) =
    N'R:\!!!!!!AQR_2026\B3B\на отправку\22.07.2026\выписки';

;WITH src AS (
    -- >>> same source used by b3b_comment_mapping.sql <<<
    SELECT [LOAN_ID], [comment] AS existing_comment
    FROM [CL_PORTFOLIO].[dbo].[FOR_B3B_AQR2026_16072026]
),
flagged AS (
    SELECT
        s.[LOAN_ID],
        s.existing_comment,
        -- cancelled agreement (ДБЗ отменён) — not a repayment, keep its own comment
        CASE WHEN LOWER(s.existing_comment) LIKE N'%отменён%' OR LOWER(s.existing_comment) LIKE N'%отменен%'
             THEN 1 ELSE 0 END AS is_cancelled,
        -- actual write-off per the RS ledger cross-check (b3b_writeoff_qc_check.sql)
        CASE WHEN EXISTS (
                SELECT 1 FROM [CL_PORTFOLIO].[dbo].[spis_v_ubytok_RS] w
                WHERE w.[contractnumber] = s.[LOAN_ID]   -- ⚠ confirm real join key, see b3b_writeoff_qc_check.sql §0a
             ) THEN 1 ELSE 0 END AS is_writeoff
    FROM src s
)
SELECT
    f.[LOAN_ID],
    CASE
        WHEN f.is_cancelled = 1 THEN N'SKIP — cancelled agreement, use the ДБЗ-cancellation comment instead (§6.1)'
        WHEN f.is_writeoff  = 1 THEN N'SKIP — actually written off (spis_v_ubytok_RS), fix reason to списание first (§7.3)'
        ELSE N'Документы и запрошенные выписки вложены в папке «выписки»'
    END                                          AS [Комментарии/пояснения Банка],
    @StatementsFolder                            AS statements_folder,
    f.existing_comment
FROM flagged f
ORDER BY f.[LOAN_ID];

-------------------------------------------------------------------------------
-- Notes
-------------------------------------------------------------------------------
-- * Universal comment applies to every loan except the two known exceptions
--   above — no per-АБИС branching.
-- * is_writeoff depends on spis_v_ubytok_RS's real join key (placeholder,
--   same caveat as b3b_writeoff_qc_check.sql) — confirm before trusting the
--   SKIP flag.
