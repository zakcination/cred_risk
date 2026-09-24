/* =============================================================================
   RPT_F — были ли у CrediLogic (S03) списания в «пустые» месяцы.

   ЗАЧЕМ. stage3_safezone_plan.md фиксирует: в 09·2025, 11·2025, 01, 02, 03 и
   07·2026 в архиве CrediLogic нет файлов списаний, и 27.07.2026 было УСТНО
   подтверждено, что списания в эти месяцы не проводились. Это слова, а не
   данные. Автор 24.09.2026 в них сомневается: проблемный портфель большой.
   От ответа зависят два вывода:
     — оценочный уровень потерь (4-1 ⑤ METRICS.md): рваный ряд или ровный;
     — re-default rate в stage3_safezone_plan: точное число или нижняя граница.
   Витрина — источник, НЕЗАВИСИМЫЙ от архива CrediLogic.

   ЧТО ИЗМЕРЯЕМ. Месяц списания S03 двумя независимыми способами:
     блок 1 — по дате закрытия договоров в статусе I (списан);
     блок 2 — по истории счёта: счёт был 'Открыт' на срезе t и перестал быть
              им на срезе t+1, а договор сейчас в статусе I. Даёт ещё и остаток
              на момент выхода — числитель будущего уровня потерь.

   ЧТО СЧИТАЕТСЯ ИСХОДОМ — фиксируется до прогона.
     — оба способа дают ноль в шести месяцах    → устное подтверждение
       устояло на данных; из «слов» переходит в «доказано»;
     — оба способа дают списания в этих месяцах → подтверждение опровергнуто;
       по правилу самого stage3_safezone_plan месяцы возвращаются в
       «НЕ ПОДТВЕРЖДЕНО», а re-default rate — в нижнюю границу;
     — способы расходятся                       → дата закрытия у I — не дата
       списания (или статус счёта отстаёт). Вывода нет, вопрос о смысле поля.

   САМОПРОВЕРКА ПОЛЯ (Н22 nst_credit). Списания идут пачками. Если дата закрытия
   у I — действительно дата списания, внутри месяца она сосредоточена на одном-
   двух днях (top_day_share близко к 1). Даты, размазанные по всем дням месяца,
   означают, что поле фиксирует что-то другое, и блок 1 не читается как ответ.

   Флаг claimed_no_writeoff = 1 стоит на шести месяцах из устного подтверждения —
   чтобы ответ читался сразу, без сверки списков.

   Блок 2 предполагает, что открытые счета S03 помечены 'Открыт'. Проверяется
   powerbi/PBI_0_preflight.sql блок 2: другое написание — заменить в блоке 2.

   GO между блоками. Read-only. Только агрегаты.
   ============================================================================= */
SET NOCOUNT ON;
GO

/* ─────────────────────────────────────────────────────────────────────────
   1. Способ 1: дата закрытия договоров S03 в статусе I, по месяцам.
      distinct_days и top_day_share — самопроверка: пачка или размазано.
   ───────────────────────────────────────────────────────────────────────── */
DECLARE @snap date = (SELECT MAX(l_report_date) FROM [Dictionaries].[risk_analytics].[loans]);

;WITH wo AS (
    SELECT  DATEFROMPARTS(YEAR(l.l_actual_closure_date), MONTH(l.l_actual_closure_date), 1) AS m
          , l.l_actual_closure_date                                                        AS d
    FROM    [Dictionaries].[risk_analytics].[loans] AS l
    WHERE   l.l_source = 'S03'
      AND   l.l_loan_status = 'I'                                   /* латиница 73 */
      AND   l.l_actual_closure_date >= DATEADD(month, -24, @snap)
      AND   l.l_actual_closure_date <  @snap
)
, by_day AS (
    SELECT m, d, COUNT_BIG(*) AS n FROM wo GROUP BY m, d
)
SELECT    b.m                                                                   AS month_start
        , CASE WHEN b.m IN ('2025-09-01','2025-11-01','2026-01-01',
                            '2026-02-01','2026-03-01','2026-07-01')
               THEN 1 ELSE 0 END                                                AS claimed_no_writeoff
        , SUM(b.n)                                                              AS writeoff_cnt
        , COUNT_BIG(*)                                                          AS distinct_days
        , MAX(b.n)                                                              AS top_day_cnt
        , CAST(MAX(b.n) AS decimal(18,4)) / NULLIF(SUM(b.n), 0)                 AS top_day_share
FROM      by_day AS b
GROUP BY  b.m
ORDER BY  b.m
OPTION (MAXDOP 1);
GO

/* ─────────────────────────────────────────────────────────────────────────
   2. Способ 2: выход счёта из статуса 'Открыт' между соседними срезами,
      у договоров, которые сейчас в статусе I. Остаток — на срезе t,
      последнем, где счёт ещё был открыт.
   ───────────────────────────────────────────────────────────────────────── */
DECLARE @snap2 date = (SELECT MAX(l_report_date) FROM [Dictionaries].[risk_analytics].[loans]);

;WITH snaps AS (
    SELECT DISTINCT la.la_reporting_date AS d
    FROM   [Dictionaries].[risk_analytics].[loan_account] AS la
    WHERE  la.la_source = 'S03'
      AND  DAY(la.la_reporting_date) = 1
      AND  la.la_reporting_date >= DATEADD(month, -25, @snap2)
      AND  la.la_reporting_date <= @snap2
)
, nxt AS (
    SELECT d, LEAD(d) OVER (ORDER BY d) AS d_next FROM snaps
)
, o AS (
    SELECT  la.la_gid
          , la.la_reporting_date                                         AS d
          , CAST(ISNULL(la.total_balance_debt, 0) AS decimal(38,2))      AS bal
    FROM    [Dictionaries].[risk_analytics].[loan_account] AS la
    JOIN    [Dictionaries].[risk_analytics].[loans]        AS l
           ON  l.l_gid = la.la_gid
          AND  l.l_source = 'S03'
          AND  l.l_loan_status = 'I'
    WHERE   la.la_source = 'S03'
      AND   la.la_status = N'Открыт'
      AND   la.la_reporting_date >= DATEADD(month, -25, @snap2)
)
SELECT    n.d                                                            AS last_open_snapshot
        , n.d_next                                                       AS first_not_open_snapshot
        , CASE WHEN n.d IN ('2025-09-01','2025-11-01','2026-01-01',
                            '2026-02-01','2026-03-01','2026-07-01')
               THEN 1 ELSE 0 END                                         AS claimed_no_writeoff
        , COUNT_BIG(*)                                                   AS exits_to_writeoff
        , SUM(o.bal)                                                     AS balance_at_exit
FROM      o
JOIN      nxt AS n ON n.d = o.d
WHERE     n.d_next IS NOT NULL
  AND     NOT EXISTS ( SELECT 1
                       FROM   [Dictionaries].[risk_analytics].[loan_account] AS x
                       WHERE  x.la_source = 'S03'
                         AND  x.la_gid    = o.la_gid
                         AND  x.la_reporting_date = n.d_next
                         AND  x.la_status = N'Открыт' )
GROUP BY  n.d, n.d_next
ORDER BY  n.d
OPTION (MAXDOP 1);
GO
