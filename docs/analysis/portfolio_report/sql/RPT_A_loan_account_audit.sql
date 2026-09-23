/* =============================================================================
   RPT_A — аудит loan_account: последняя неаудированная таблица слоя «запас».

   Зачем. Слой «поток» закрыт: loans несёт l_funding_date на 100 % по всем
   источникам. Слой «риск» закрыт: delinquency_bucket заполнен на 97,9 %.
   Слой «запас» требует остатка задолженности, а какими полями loan_account
   его несёт — не установлено. §4 запрещает брать имена из памяти.

   Read-only. Только INFORMATION_SCHEMA и агрегаты.
   Продолжает DICT_A/DICT_B/DICT_C контура dict_registry.
   ============================================================================= */
SET NOCOUNT ON;

/* ─────────────────────────────────────────────────────────────────────────
   1. loan_account целиком: имена, типы, порядок.
      Без масок — угадывать имена дороже, чем прочитать список.
   ───────────────────────────────────────────────────────────────────────── */
SELECT    c.ORDINAL_POSITION, c.COLUMN_NAME, c.DATA_TYPE
        , c.CHARACTER_MAXIMUM_LENGTH, c.NUMERIC_PRECISION, c.NUMERIC_SCALE
        , c.IS_NULLABLE
FROM      [Dictionaries].[INFORMATION_SCHEMA].[COLUMNS] AS c
WHERE     c.TABLE_SCHEMA = 'risk_analytics'
  AND     c.TABLE_NAME   = 'loan_account'
ORDER BY  c.ORDINAL_POSITION;

/* ─────────────────────────────────────────────────────────────────────────
   2. Зерно и покрытие на последнюю дату среза.
      Вопрос: строка loan_account — договор или счёт. Связь с loans:
      la_gid = l_gid AND la_source = l_source (objects.csv).
   ───────────────────────────────────────────────────────────────────────── */
DECLARE @dt date = (SELECT MAX(la_reporting_date)
                    FROM [Dictionaries].[risk_analytics].[loan_account]);

SELECT    la.la_source
        , @dt                                              AS reporting_date
        , COUNT_BIG(*)                                     AS rows_on_date
        , COUNT(DISTINCT la.la_gid)                        AS gid_distinct
        , CAST(1.0 * COUNT_BIG(*) / NULLIF(COUNT(DISTINCT la.la_gid), 0)
               AS decimal(10,4))                           AS rows_per_gid
FROM      [Dictionaries].[risk_analytics].[loan_account] AS la
WHERE     la.la_reporting_date = @dt
GROUP BY  la.la_source
ORDER BY  la.la_source
OPTION (MAXDOP 1);

/* ─────────────────────────────────────────────────────────────────────────
   3. Покрытие действующих договоров счетами.
      Отбор действующих — dict_registry/status_map.csv. Условие по источнику
      обязательно: латинская O (79) и кириллическая О (206) неразличимы.
   ───────────────────────────────────────────────────────────────────────── */
SELECT    l.l_source
        , COUNT_BIG(*)                                                   AS live_loans
        , SUM(CASE WHEN la.la_gid IS NULL THEN 0 ELSE 1 END)             AS with_account
        , SUM(CASE WHEN la.la_gid IS NULL THEN 1 ELSE 0 END)             AS without_account
FROM      [Dictionaries].[risk_analytics].[loans] AS l
LEFT JOIN [Dictionaries].[risk_analytics].[loan_account] AS la
       ON la.la_gid    = l.l_gid
      AND la.la_source = l.l_source
      AND la.la_reporting_date = @dt
WHERE   ( (l.l_source = 'S01' AND l.l_loan_status = N'О')
       OR (l.l_source = 'S02' AND l.l_loan_status = 'Account OK')
       OR (l.l_source = 'S03' AND l.l_loan_status = 'O')
       OR (l.l_source = 'S17' AND l.l_loan_status = N'О') )
  AND     l.l_actual_closure_date IS NULL
GROUP BY  l.l_source
ORDER BY  l.l_source
OPTION (MAXDOP 1);

/* ─────────────────────────────────────────────────────────────────────────
   4. delinquency_bucket: домен значений по источникам.
      Поле выбрано как основное измерение просрочки — заполнено на 97,9 %
      против 16,9 % у days_past_due. Но что означают сами коды, не проверено.
   ───────────────────────────────────────────────────────────────────────── */
SELECT    la.la_source
        , la.delinquency_bucket
        , COUNT_BIG(*)                                                   AS cnt
        , MIN(la.days_past_due)                                          AS dpd_min
        , MAX(la.days_past_due)                                          AS dpd_max
        , SUM(CASE WHEN la.days_past_due IS NULL THEN 1 ELSE 0 END)      AS dpd_null
FROM      [Dictionaries].[risk_analytics].[loan_account] AS la
WHERE     la.la_reporting_date = @dt
GROUP BY  la.la_source, la.delinquency_bucket
ORDER BY  la.la_source, la.delinquency_bucket
OPTION (MAXDOP 1);

/* Блок 4 отвечает на вопрос, который придётся задать первым на любой защите:
   на каком основании bucket = N трактуется как «просрочка свыше N дней».
   Диапазон days_past_due внутри каждого bucket — это и есть основание,
   либо доказательство, что его нет. */
