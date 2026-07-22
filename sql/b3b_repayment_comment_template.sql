/* =============================================================================
   ПРОСТЫМ ЯЗЫКОМ:
   В прошлом (2025) цикле для колонки «Комментарии/пояснения Банка» (источники
   погашения — просят после утверждения формы, см. §6 гайда) использовали
   ФИКСИРОВАННЫЙ шаблон текста в зависимости от АБИС, определяемой по ФОРМАТУ
   номера займа — не писали каждый раз новый текст руками для Кредилоджик/Way4:
     • номер вида NNN/SO/N или F../.../SO/N              -> РС-Банк — узкая
       транзакционная история пишется вручную (у каждой она своя).
     • номер вида L21######## / L22######## (без /SO/)   -> Кредилоджик —
       шаблон «вложены реестры входящих платежей и детальные выписки…»
     • номер вида KZ..A.. (IBAN)                          -> Way4 (карты) —
       шаблон «вложены выписки и скрин с АБИС»
   Этот скрипт классифицирует займы этого года по тому же правилу и сразу
   подставляет нужный шаблон, оставляя РС-Банк и нераспознанные номера (напр.
   вида F../..._conv без /SO/) на ручное заполнение. Выписки за этот год лежат
   в R:\!!!!!!AQR_2026\B3B\на отправку\22.07.2026\выписки.
   -----------------------------------------------------------------------------
   Classify this cycle's B3B loans by loan-ref FORMAT (not a lookup table —
   the ref format itself encodes the АБИС, per the 2025-cycle precedent) and
   apply the matching «Комментарии/пояснения Банка» template. See
   docs/b3b_guide.md §6.1 for the full template table and the misroute note.
   T-SQL (Microsoft SQL Server).
   ============================================================================= */

;WITH src AS (
    -- >>> same source used by b3b_comment_mapping.sql — adjust if this year's
    -- ref lives in a different column (e.g. ID / LOAN_ID_KR, not LOAN_ID) <<<
    SELECT [LOAN_ID], [comment] AS existing_comment
    FROM [CL_PORTFOLIO].[dbo].[FOR_B3B_AQR2026_16072026]
),
classified AS (
    SELECT
        s.[LOAN_ID],
        s.existing_comment,
        CASE
            WHEN s.[LOAN_ID] LIKE '%/SO/%'                              THEN N'РС-Банк'
            WHEN s.[LOAN_ID] LIKE 'L2[0-9][0-9]%' AND s.[LOAN_ID] NOT LIKE '%/%' THEN N'Кредилоджик'
            WHEN s.[LOAN_ID] LIKE 'KZ%'                                 THEN N'Way4'
            ELSE N'UNRECOGNISED FORMAT'
        END AS abis_source,
        -- was this loan's agreement CANCELLED rather than repaid? (existing
        -- comment already says so) — overrides the template below either way.
        CASE WHEN LOWER(s.existing_comment) LIKE N'%отменён%' OR LOWER(s.existing_comment) LIKE N'%отменен%'
             THEN 1 ELSE 0 END AS is_cancelled
    FROM src s
)
SELECT
    c.[LOAN_ID],
    c.abis_source                                          AS [АБИС],
    CASE
        WHEN c.is_cancelled = 1
            THEN N'MANUAL (ДБЗ cancellation formula) — «ДБЗ [ref] был отменён [дата] на основании выписки № [ref] от [дата][, входящие платежи возвращены клиенту / входящих платежей не было]»'
        WHEN c.abis_source = N'Кредилоджик'
            THEN N'вложены реестры входящих платежей и детальные выписки (развернутые графики платежей)'
        WHEN c.abis_source = N'Way4'
            THEN N'вложены выписки и скрин с АБИС'
        WHEN c.abis_source = N'РС-Банк'
            THEN N'MANUAL — full transaction narrative required (see выписки for this loan)'
        ELSE N'MANUAL — unrecognised ref format, classify by hand before requesting statements'
    END                                                     AS [Комментарии/пояснения Банка],
    c.existing_comment,
    -- flag the misroute pattern from §6.1: Кредилоджик-format ref whose
    -- existing comment says "not our system" (asked of the wrong team).
    CASE WHEN c.abis_source = N'Кредилоджик'
              AND (LOWER(c.existing_comment) LIKE N'%не в компетенции%'
                   OR LOWER(c.existing_comment) LIKE N'%не относится%')
         THEN 1 ELSE 0 END                                  AS likely_misrouted
FROM classified c
ORDER BY c.abis_source, c.[LOAN_ID];

-------------------------------------------------------------------------------
-- Summary — how many fall into each bucket (sanity-check before requesting
-- statements from R:\!!!!!!AQR_2026\B3B\на отправку\22.07.2026\выписки).
-------------------------------------------------------------------------------
;WITH src AS (
    SELECT [LOAN_ID], [comment] AS existing_comment
    FROM [CL_PORTFOLIO].[dbo].[FOR_B3B_AQR2026_16072026]
),
classified AS (
    SELECT
        CASE
            WHEN s.[LOAN_ID] LIKE '%/SO/%'                              THEN N'РС-Банк'
            WHEN s.[LOAN_ID] LIKE 'L2[0-9][0-9]%' AND s.[LOAN_ID] NOT LIKE '%/%' THEN N'Кредилоджик'
            WHEN s.[LOAN_ID] LIKE 'KZ%'                                 THEN N'Way4'
            ELSE N'UNRECOGNISED FORMAT'
        END AS abis_source
    FROM src s
)
SELECT abis_source, COUNT(*) AS loans
FROM classified
GROUP BY abis_source
ORDER BY loans DESC;

-------------------------------------------------------------------------------
-- Notes
-------------------------------------------------------------------------------
-- * Ref-format classification, not a source_system lookup — matches how the
--   2025-cycle table's own АБИС column lined up 1:1 with the ref format.
--   Cross-check against the six-source union in b3b_reconciliation_2025.sql
--   if any row looks misclassified.
-- * UNRECOGNISED FORMAT will catch refs like `F05/35/17-703_conv` (no /SO/,
--   `_conv` suffix) seen this cycle — these don't match any of the three
--   2025-cycle patterns; confirm their real АБИС by hand before templating.
-- * Templates are boilerplate text ONLY — actually attaching the registry/
--   statement/screenshot from the выписки folder is a separate manual step.
