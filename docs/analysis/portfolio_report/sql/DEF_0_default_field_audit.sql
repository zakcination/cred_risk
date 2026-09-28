/* =============================================================================
   DEF_0 — разведка перед планом дефолтов (DEFAULT_PLAN.md). Метрик не считает.

   ВОПРОС. Можно ли на витрине определить дефолт помесячно. Стадий в витрине нет
   (README, «Ограничения»). Остаётся глубина просрочки — и два известных факта:
     — days_past_due заполнен на 16,9 %, delinquency_bucket смысла не имеет
       (README, отзыв 2) — оба отпали;
     — days_past_due_principal: по S17 заполнен ровно на 11 518 счетах, где
       la_account_1424 <> 0 (METRICS.md, 4-1); по S02 заполнен на 100 % и весь
       равен нулю. По S01 и S03 не проверялся.
   Если поле — настоящий счётчик дней, «90+» строится на нём, и дефолт по
   сроку просрочки становится измеримым. Если нет — дефолт на витрине строится
   только из событий (списание, реструктуризация), а глубина недоступна.

   ЧТО СЧИТАЕТСЯ ОТВЕТОМ — фиксируется до прогона.
     блок 1 — поле заполнено там и только там, где есть просрочка:
              mism_od_no_dpd и mism_dpd_no_od малы против od_accounts.
     блок 2 — САМОПРОВЕРКА СЧЁТЧИКА (Н22 nst_credit). Счёт в просрочке на двух
              соседних срезах: если старейший неоплаченный платёж не погашен,
              дни вырастают ровно на число дней между срезами. Доля пар
              «прирост = календарные дни» — мера того, что поле считает дни,
              а не хранит что-то другое. Порог приёмки — развилка ДФ-0
              в DEFAULT_PLAN.md, до прогона; здесь только числа.
              Прирост меньше — частичное погашение старейшего платежа (норма);
              прирост больше или отрицательный без выхода из просрочки —
              признак, что поле не счётчик.
     блок 3 — распределение глубины по корзинам 1–30 … 360+ по источнику
              на трёх срезах: есть ли вообще хвост 90+ и какого размера.
     блок 0 — поиск в витрине любых полей стадии, корзины, POCI, дефолта,
              обесценения. Нашлось — меняет план: стадия банка вместо конструкции.

   Имена: блок 0а перепроверяет каждое имя, на котором стоит скрипт.
   Поля дней берутся через TRY_CAST: в risk_dwh_layered_check.sql они
   приводятся так же — тип в витрине не числовой гарантированно.

   GO между блоками: неверное имя стоит одного блока. Read-only. Только агрегаты.
   ============================================================================= */
SET NOCOUNT ON;
GO

/* ─────────────────────────────────────────────────────────────────────────
   0а. Живой аудит имён. Ожидается 8 строк.
   ───────────────────────────────────────────────────────────────────────── */
SELECT    c.TABLE_NAME, c.COLUMN_NAME, c.DATA_TYPE
FROM      [Dictionaries].[INFORMATION_SCHEMA].[COLUMNS] AS c
WHERE     c.TABLE_SCHEMA = 'risk_analytics'
  AND     c.TABLE_NAME   = N'loan_account'
  AND     c.COLUMN_NAME IN (N'la_gid', N'la_source', N'la_reporting_date', N'la_status',
                            N'total_balance_debt', N'la_account_1424',
                            N'days_past_due_principal', N'days_past_due')
ORDER BY  c.ORDINAL_POSITION;
GO

/* ─────────────────────────────────────────────────────────────────────────
   0б. Поля стадии / дефолта во всей схеме risk_analytics — по маскам имён.
       Маски широкие намеренно: провизии в своё время нашлись только счетами,
       а не по имени (README, отзыв 1). Пусто — стадий в витрине нет.
   ───────────────────────────────────────────────────────────────────────── */
SELECT    c.TABLE_NAME, c.COLUMN_NAME, c.DATA_TYPE
FROM      [Dictionaries].[INFORMATION_SCHEMA].[COLUMNS] AS c
WHERE     c.TABLE_SCHEMA = 'risk_analytics'
  AND   ( c.COLUMN_NAME LIKE N'%stage%'   OR c.COLUMN_NAME LIKE N'%стади%'
       OR c.COLUMN_NAME LIKE N'%basket%'  OR c.COLUMN_NAME LIKE N'%корзин%'
       OR c.COLUMN_NAME LIKE N'%poci%'    OR c.COLUMN_NAME LIKE N'%default%'
       OR c.COLUMN_NAME LIKE N'%дефолт%'  OR c.COLUMN_NAME LIKE N'%impair%'
       OR c.COLUMN_NAME LIKE N'%обесцен%' OR c.COLUMN_NAME LIKE N'%npl%'
       OR c.COLUMN_NAME LIKE N'%past[_]due%' OR c.COLUMN_NAME LIKE N'%dpd%'
       OR c.COLUMN_NAME LIKE N'%overdue%' OR c.COLUMN_NAME LIKE N'%просроч%'
       OR c.COLUMN_NAME LIKE N'%bucket%'  OR c.COLUMN_NAME LIKE N'%class%'
       OR c.COLUMN_NAME LIKE N'%категор%' OR c.COLUMN_NAME LIKE N'%quality%' )
ORDER BY  c.TABLE_NAME, c.ORDINAL_POSITION;
GO

/* ─────────────────────────────────────────────────────────────────────────
   1. Заполненность против просрочки: источник × срез, открытые счета.
      mism_od_no_dpd  — есть 1424, а дней нет (NULL или 0);
      mism_dpd_no_od  — дни > 0, а 1424 = 0: просрочка только по процентам
                        либо поле не про основной долг.
   ───────────────────────────────────────────────────────────────────────── */
;WITH a AS (
    SELECT  la.la_source
          , la.la_reporting_date
          , CAST(ISNULL(la.la_account_1424, 0) AS decimal(38,2))            AS od
          , TRY_CAST(la.days_past_due_principal AS int)                     AS dpd_p
          , TRY_CAST(la.days_past_due AS int)                               AS dpd
          , la.days_past_due_principal                                      AS dpd_p_raw
    FROM    [Dictionaries].[risk_analytics].[loan_account] AS la
    WHERE   la.la_status = N'Открыт'
)
SELECT    la_source
        , la_reporting_date
        , COUNT_BIG(*)                                                              AS open_accounts
        , SUM(CASE WHEN od <> 0 THEN 1 ELSE 0 END)                                  AS od_accounts
        , SUM(CASE WHEN dpd_p_raw IS NULL THEN 1 ELSE 0 END)                        AS dpd_p_null
        , SUM(CASE WHEN dpd_p_raw IS NOT NULL AND dpd_p IS NULL THEN 1 ELSE 0 END)  AS dpd_p_not_int
        , SUM(CASE WHEN dpd_p > 0 THEN 1 ELSE 0 END)                                AS dpd_p_pos
        , SUM(CASE WHEN od <> 0 AND ISNULL(dpd_p, 0) = 0 THEN 1 ELSE 0 END)         AS mism_od_no_dpd
        , SUM(CASE WHEN od  = 0 AND dpd_p > 0 THEN 1 ELSE 0 END)                    AS mism_dpd_no_od
        , SUM(CASE WHEN dpd IS NOT NULL THEN 1 ELSE 0 END)                          AS dpd_filled
        , SUM(CASE WHEN dpd_p > 0 AND dpd IS NOT NULL AND dpd <> dpd_p THEN 1 ELSE 0 END) AS dpd_ne_dpd_p
        , MAX(dpd_p)                                                                AS dpd_p_max
FROM      a
GROUP BY  la_source, la_reporting_date
ORDER BY  la_source, la_reporting_date
OPTION (MAXDOP 1);
GO

/* ─────────────────────────────────────────────────────────────────────────
   2. Самопроверка счётчика: пары соседних срезов одного счёта, оба с дней > 0.
      delta = dpd(t+1) − dpd(t); days = календарные дни между срезами.
   ───────────────────────────────────────────────────────────────────────── */
;WITH a AS (
    SELECT  la.la_source
          , la.la_gid
          , la.la_reporting_date                                             AS d
          , TRY_CAST(la.days_past_due_principal AS int)                      AS dpd_p
    FROM    [Dictionaries].[risk_analytics].[loan_account] AS la
    WHERE   la.la_status = N'Открыт'
)
, p AS (
    SELECT  la_source
          , d
          , dpd_p
          , LEAD(dpd_p) OVER (PARTITION BY la_source, la_gid ORDER BY d)     AS dpd_next
          , LEAD(d)     OVER (PARTITION BY la_source, la_gid ORDER BY d)     AS d_next
    FROM    a
)
SELECT    la_source
        , COUNT_BIG(*)                                                                     AS pairs
        , SUM(CASE WHEN dpd_next - dpd_p =  DATEDIFF(day, d, d_next) THEN 1 ELSE 0 END)    AS delta_eq_days
        , SUM(CASE WHEN dpd_next - dpd_p <  DATEDIFF(day, d, d_next)
                    AND dpd_next - dpd_p >= 0                         THEN 1 ELSE 0 END)   AS delta_less
        , SUM(CASE WHEN dpd_next - dpd_p <  0                         THEN 1 ELSE 0 END)   AS delta_negative
        , SUM(CASE WHEN dpd_next - dpd_p >  DATEDIFF(day, d, d_next) THEN 1 ELSE 0 END)    AS delta_more
        , CAST(SUM(CASE WHEN dpd_next - dpd_p = DATEDIFF(day, d, d_next) THEN 1.0 ELSE 0 END)
               / NULLIF(COUNT_BIG(*), 0) AS decimal(6,4))                                  AS share_eq_days
FROM      p
WHERE     dpd_p > 0
  AND     dpd_next > 0
  AND     DATEDIFF(month, d, d_next) = 1          /* только соседние срезы, без пропусков */
GROUP BY  la_source
ORDER BY  la_source
OPTION (MAXDOP 1);
GO

/* ─────────────────────────────────────────────────────────────────────────
   3. Глубина: корзины дней по источнику на трёх срезах — первом, середине
      и последнем. Счётчики и остаток; идентификаторов нет.
   ───────────────────────────────────────────────────────────────────────── */
;WITH a AS (
    SELECT  la.la_source
          , la.la_reporting_date
          , TRY_CAST(la.days_past_due_principal AS int)                     AS dpd_p
          , CAST(ISNULL(la.total_balance_debt, 0) AS decimal(38,2))         AS bal
    FROM    [Dictionaries].[risk_analytics].[loan_account] AS la
    WHERE   la.la_status = N'Открыт'
      AND   la.la_reporting_date IN ('2025-01-01', '2025-10-01', '2026-09-01')
)
SELECT    la_source
        , la_reporting_date
        , CASE WHEN ISNULL(dpd_p, 0) <= 0 THEN N'0 / нет'
               WHEN dpd_p <=  30 THEN N'001–030'
               WHEN dpd_p <=  60 THEN N'031–060'
               WHEN dpd_p <=  90 THEN N'061–090'
               WHEN dpd_p <= 180 THEN N'091–180'
               WHEN dpd_p <= 360 THEN N'181–360'
               ELSE                   N'361+' END                           AS dpd_bucket
        , COUNT_BIG(*)                                                      AS accounts
        , CAST(SUM(bal) / 1000000 AS decimal(18,1))                         AS balance_mln
FROM      a
GROUP BY  la_source, la_reporting_date
        , CASE WHEN ISNULL(dpd_p, 0) <= 0 THEN N'0 / нет'
               WHEN dpd_p <=  30 THEN N'001–030'
               WHEN dpd_p <=  60 THEN N'031–060'
               WHEN dpd_p <=  90 THEN N'061–090'
               WHEN dpd_p <= 180 THEN N'091–180'
               WHEN dpd_p <= 360 THEN N'181–360'
               ELSE                   N'361+' END
ORDER BY  la_source, la_reporting_date, dpd_bucket
OPTION (MAXDOP 1);
GO
