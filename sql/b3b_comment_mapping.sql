/* =============================================================================
   B3B column E «Причина» — normalize raw filler comments to the NBRK reference
   =============================================================================
   The NBRK B3B form («Список особых случаев») requires, for every loan that
   disappeared from B1A in 2025, a REASON in column E from a fixed dropdown, plus
   conditional columns F/G/H. Fillers entered free text; this script maps that
   free text to the controlled vocabulary and flags what still needs manual
   review before submission (file: EUB_B3B_v0.xlsx, due 18:00 16.07.2026).

   Official column-E vocabulary (use EXACTLY these values):
     • списание
     • реструктуризация / модификация
     • полное погашение
     • проданный финансовый актив
     • пролонгация путем выдачи нового займа
     • иное

   Conditional columns:
     E = «проданный финансовый актив»                         -> fill H: buyer type
                                                                 (коллектор / ЧСИ / ОУСА / БВУ / …)
     E = «реструктуризация / модификация»                     -> fill G: related ID in the other slice
     E = «пролонгация путем выдачи нового займа»              -> fill G: related ID
     E = «иное»                                               -> fill F: free-form explanation

   Audited-year rule: any close / repayment / write-off DATE must fall in 2025.

   Set @src below to the table that holds the raw column-E text (LOAN_ID + comment).
   T-SQL (Microsoft SQL Server).
   ============================================================================= */

-------------------------------------------------------------------------------
-- 0. Reference map for the OBSERVED raw comments. Edit freely; this is the
--    single place the human mapping decisions live. reason_E = NULL means
--    "no valid reason — must be handled manually".
-------------------------------------------------------------------------------
;WITH map_ref (raw_norm, reason_E, note_F, needs_review, review_note) AS (
    SELECT * FROM (VALUES
      -- raw (normalised, lower)          reason_E (column E)  note_F (column F)                                                                        rev  review_note
      -- Decisions taken 16.07.2026:
      (N'списанные на внесистемный учет', N'списание',         NULL,                                                                                    0,  N'off-balance write-off; date must be 2025'),
      (N'списанные в убыток',             N'списание',         NULL,                                                                                    0,  N'loss write-off; date must be 2025'),
      (N'полное погашение',               N'полное погашение', NULL,                                                                                    0,  NULL),
      (N'продажа',                        N'иное',             N'по данному займу была переуступка прав требования по кредиту в СФК (специальная финансовая компания)', 0, N'decision 16.07: cession to SFK -> иное (not проданный фин.актив)'),
      (N'прощение',                       N'иное',             N'по данному займу была процедура прощения',                                             0,  N'decision 16.07: -> иное + comment'),
      (N'обратный выкуп, списан',         N'иное',             N'данный займ был переуступлен, далее возвращен на баланс банка, далее списан в убыток',  0,  N'decision 16.07: -> иное + comment'),
      -- Left OPEN for now (decision pending):
      (N'баланс меньше 5000',             NULL,                NULL,                                                                                    1,  N'OPEN - decision pending'),
      (N'отменен',                        NULL,                NULL,                                                                                    1,  N'OPEN - decision pending'),
      (N'открытый',                       NULL,                NULL,                                                                                    1,  N'OPEN - loan still active; should not be in B3B - investigate (b3b_reconciliation_2025.sql)'),
      (N'0',                              NULL,                NULL,                                                                                    1,  N'OPEN - no reason provided; fill manually')
    ) v(raw_norm, reason_E, note_F, needs_review, review_note)
),
src AS (
    -- >>> set this to the table/column holding the raw column-E text <<<
    SELECT [LOAN_ID],
           [comment]                                        AS raw_comment,
           LOWER(LTRIM(RTRIM([comment])))                   AS c
    FROM [CL_PORTFOLIO].[dbo].[FOR_B3B_AQR2026_16072026]    -- adjust if comments live elsewhere
),
mapped AS (
    SELECT s.[LOAN_ID], s.raw_comment,
           -- exact reference match first, else a keyword fallback for unseen text
           COALESCE(r.reason_E, fb.reason_E)     AS reason_E,
           COALESCE(r.note_F,   fb.note_F)       AS note_F,
           CASE WHEN r.raw_norm IS NOT NULL THEN r.needs_review ELSE fb.needs_review END AS needs_review,
           COALESCE(r.review_note, fb.review_note) AS review_note,
           CASE WHEN r.raw_norm IS NOT NULL THEN 0 ELSE 1 END AS matched_by_fallback
    FROM src s
    LEFT JOIN map_ref r
           ON r.raw_norm = s.c
    CROSS APPLY (
        -- Fallback keyword normaliser (order = priority). Only used when the
        -- comment is not an exact reference value above.
        SELECT TOP 1 reason_E, note_F, needs_review, review_note
        FROM (VALUES
          (1, CASE WHEN s.c LIKE N'%внесистемн%' OR s.c LIKE N'%оуса%'
                    THEN 1 ELSE 0 END, N'списание',                    NULL,                                                                                    1, N'ОУСА / off-balance special case - split per loan (e.g. Парасат=полное погашение; Алиби/Алиби-Агро/Сайхинстройсервис=списание) and attach АБИС screenshots (column H)'),
          (2, CASE WHEN s.c LIKE N'%прощени%'
                    THEN 1 ELSE 0 END, N'иное',                        N'по данному займу была процедура прощения',                                             1, N'иное - verify F text'),
          (3, CASE WHEN s.c LIKE N'%выкуп%'
                    THEN 1 ELSE 0 END, N'иное',                        N'данный займ был переуступлен, далее возвращен на баланс банка, далее списан в убыток',  1, N'иное - verify F text'),
          (4, CASE WHEN s.c LIKE N'%переуступ%' OR s.c LIKE N'%цесси%' OR s.c LIKE N'%сфк%'
                    THEN 1 ELSE 0 END, N'иное',                        N'переуступка прав требования по кредиту в СФК (специальная финансовая компания)',       1, N'иное - verify F text'),
          (5, CASE WHEN s.c LIKE N'%продаж%' OR s.c LIKE N'%проданн%'
                    THEN 1 ELSE 0 END, N'иное',                        N'переуступка прав требования по кредиту в СФК (специальная финансовая компания)',       1, N'verify: cession-to-SFK (иное) vs проданный финансовый актив (+H buyer type)'),
          (6, CASE WHEN s.c LIKE N'%в убыток%' OR s.c LIKE N'%внебаланс%' OR s.c LIKE N'%списан%'
                    THEN 1 ELSE 0 END, N'списание',                    NULL,                                                                                    1, N'write-off (verify sub-type & 2025 date)'),
          (7, CASE WHEN s.c LIKE N'%полное погашен%' OR s.c LIKE N'%погасил%' OR s.c LIKE N'%погашен%'
                    THEN 1 ELSE 0 END, N'полное погашение',            NULL,                                                                                    0, NULL),
          (8, CASE WHEN s.c LIKE N'%реструктур%' OR s.c LIKE N'%модификац%'
                    THEN 1 ELSE 0 END, N'реструктуризация / модификация', NULL,                                                                                 1, N'fill G: related ID in the other slice'),
          (9, CASE WHEN s.c LIKE N'%пролонгац%' OR s.c LIKE N'%нового займа%'
                    THEN 1 ELSE 0 END, N'пролонгация путем выдачи нового займа', NULL,                                                                          1, N'fill G: related ID in the other slice'),
          (10, CASE WHEN s.c LIKE N'%баланс%5000%' OR s.c LIKE N'%отмен%' OR s.c LIKE N'%иное%'
                    THEN 1 ELSE 0 END, N'иное',                        N'уточнить в свободной форме',                                                           1, N'иное - fill F free-form'),
          (99, 1,                                                     NULL,                              NULL,                                                    1, N'UNMAPPED - no reason recognised; fill manually')
        ) f(pri, hit, reason_E, note_F, needs_review, review_note)
        WHERE f.hit = 1
        ORDER BY f.pri
    ) fb
)
SELECT
    m.[LOAN_ID],
    m.raw_comment,
    m.reason_E                                   AS [E_Причина],
    m.note_F                                     AS [F_Иное_свободная_форма],
    -- which conditional column the chosen reason requires
    CASE m.reason_E
        WHEN N'проданный финансовый актив'            THEN N'H: тип покупателя'
        WHEN N'реструктуризация / модификация'        THEN N'G: связанный ID'
        WHEN N'пролонгация путем выдачи нового займа' THEN N'G: связанный ID'
        WHEN N'иное'                                  THEN N'F: свободная форма'
        ELSE NULL
    END                                          AS required_extra_column,
    m.needs_review,
    m.matched_by_fallback,
    m.review_note
FROM mapped m
ORDER BY m.needs_review DESC, m.reason_E, m.[LOAN_ID];

/* -----------------------------------------------------------------------------
   Consolidation summary — counts per official reason (for the submission).
   Run separately (swap the final SELECT above for this, or wrap `mapped` again):

     SELECT COALESCE(reason_E, N'(UNMAPPED / review)') AS [E_Причина],
            COUNT(*) AS loans, SUM(needs_review) AS needs_review
     FROM mapped
     GROUP BY reason_E
     ORDER BY loans DESC;
   ----------------------------------------------------------------------------- */
