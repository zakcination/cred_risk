/* =============================================================================
   RPT_D — разрешить четыре развилки справочника метрик (METRICS.md, §«Что
           остаётся за автором»), на которых стоят разделы 2-1, 2-3 и 3.

   ЧТО ИЗМЕРЯЕМ. Пригодность полей-кандидатов, а не сами метрики. По каждому
   кандидату: заполненность, конвертируемость и домен значений в разрезе
   источника. Заполненность отдельно от конвертируемости намеренно — l_rate
   заполнен и при этом содержит название продукта, а не ставку.

   В КАКОМ РАЗРЕЗЕ. Источник (S01 RS, S02 Cards, S03 CrediLogic, S17 Fenix).
   Поле, ведущее себя одинаково на четырёх источниках, и поле, живое на одном,
   в отчёт годятся по-разному.

   ЧТО СЧИТАЕТСЯ ИСХОДОМ.
     блок 1 — срок: кандидат, у которого заполненность и конвертируемость
              совпадают и домен правдоподобен (месяцы, не дни и не даты)
              на всех четырёх источниках. Если такого нет — срок по договору
              портфельной метрикой не является и считается по источникам.
     блок 2 — плановая дата: РЕШАЮЩИЙ. Эталон — S03 статус Z (закрыт досрочно,
              3 164 895) против статуса C (закрыт, 3 420 702). Верен тот
              кандидат, который на Z срабатывает почти всегда, а на C почти
              никогда. Кандидат, дающий близкие доли на Z и на C, опровергнут:
              он не отделяет досрочное погашение от срочного.
     блок 3 — сумма выдачи: кандидат, заполненный и ненулевой на всех четырёх.
              Если l_loan_amount пуст или нулевой по S02 — по возобновляемым
              выдача берётся иначе, и это вопрос владельцу витрины, а не выбор.
     блок 4 — ключ заёмщика: если l_borrower_id встречается более чем в одном
              источнике у заметного числа заёмщиков — COUNT(DISTINCT) по всему
              портфелю завышает или занижает число заёмщиков, и метрика 3 ③
              считается по источникам либо через сопоставление с borrower.
     блок 5 — глубина ряда: помесячный ряд выдач. Ровный ряд за 24 месяца —
              отчёт строится сразу. Провалы — период ограничивается фактом.

   ЧЕГО ЭТОТ СКРИПТ НЕ ДЕЛАЕТ. Не считает ни одной метрики отчёта. Выбор поля
   по §6 принадлежит автору; здесь только числа, на которых он делается.

   Read-only. PII не выводится: только агрегаты и домены величин.
   ============================================================================= */
SET NOCOUNT ON;

DECLARE @snap date = (SELECT MAX(l_report_date)
                      FROM [Dictionaries].[risk_analytics].[loans]);

SELECT @snap AS snapshot_date;

/* ─────────────────────────────────────────────────────────────────────────
   1. Срок по договору (2-1 ④) — три кандидата.
      term_filled ≠ term_numeric означает, что в поле лежит не число.
   ───────────────────────────────────────────────────────────────────────── */
SELECT    l.l_source
        , COUNT_BIG(*)                                                             AS loans_total

        , SUM(CASE WHEN l.l_term IS NOT NULL THEN 1 ELSE 0 END)                    AS term_filled
        , SUM(CASE WHEN TRY_CONVERT(int, l.l_term) IS NOT NULL THEN 1 ELSE 0 END)  AS term_numeric
        , MIN(TRY_CONVERT(int, l.l_term))                                          AS term_min
        , MAX(TRY_CONVERT(int, l.l_term))                                          AS term_max

        , SUM(CASE WHEN l.l_initial_term_months IS NOT NULL THEN 1 ELSE 0 END)     AS initterm_filled
        , SUM(CASE WHEN TRY_CONVERT(int, l.l_initial_term_months) IS NOT NULL
                   THEN 1 ELSE 0 END)                                              AS initterm_numeric
        , MIN(TRY_CONVERT(int, l.l_initial_term_months))                           AS initterm_min
        , MAX(TRY_CONVERT(int, l.l_initial_term_months))                           AS initterm_max

        , SUM(CASE WHEN l.l_current_term_months IS NOT NULL THEN 1 ELSE 0 END)     AS currterm_filled
        , SUM(CASE WHEN TRY_CONVERT(int, l.l_current_term_months) IS NOT NULL
                   THEN 1 ELSE 0 END)                                              AS currterm_numeric
        , MIN(TRY_CONVERT(int, l.l_current_term_months))                           AS currterm_min
        , MAX(TRY_CONVERT(int, l.l_current_term_months))                           AS currterm_max
FROM      [Dictionaries].[risk_analytics].[loans] AS l
GROUP BY  l.l_source
ORDER BY  l.l_source
OPTION (MAXDOP 1);

/* ─────────────────────────────────────────────────────────────────────────
   2а. Плановая дата погашения (2-3 ③) — заполненность трёх кандидатов.
   ───────────────────────────────────────────────────────────────────────── */
SELECT    l.l_source
        , COUNT_BIG(*)                                                                    AS loans_total
        , SUM(CASE WHEN l.l_scheduled_closure_date IS NOT NULL THEN 1 ELSE 0 END)         AS sched_filled
        , SUM(CASE WHEN l.l_loan_maturity_date     IS NOT NULL THEN 1 ELSE 0 END)         AS matur_filled
        , SUM(CASE WHEN l.l_end_date               IS NOT NULL THEN 1 ELSE 0 END)         AS enddt_filled
        , SUM(CASE WHEN l.l_actual_closure_date    IS NOT NULL THEN 1 ELSE 0 END)         AS actual_filled
FROM      [Dictionaries].[risk_analytics].[loans] AS l
GROUP BY  l.l_source
ORDER BY  l.l_source
OPTION (MAXDOP 1);

/* ─────────────────────────────────────────────────────────────────────────
   2б. РЕШАЮЩИЙ. Правило «досрочно» против эталона.
       Читать только строки S03 со статусами Z и C: Z — закрыт досрочно,
       C — закрыт. Верный кандидат даёт высокую долю на Z и низкую на C.
       Остальные источники выводятся для переноса правила, эталона там нет.
   ───────────────────────────────────────────────────────────────────────── */
SELECT    l.l_source
        , l.l_loan_status
        , COUNT_BIG(*)                                                                    AS closed_loans
        , SUM(CASE WHEN l.l_actual_closure_date < l.l_scheduled_closure_date
                   THEN 1 ELSE 0 END)                                                     AS early_by_sched
        , SUM(CASE WHEN l.l_actual_closure_date < l.l_loan_maturity_date
                   THEN 1 ELSE 0 END)                                                     AS early_by_matur
        , SUM(CASE WHEN l.l_actual_closure_date < l.l_end_date
                   THEN 1 ELSE 0 END)                                                     AS early_by_end
FROM      [Dictionaries].[risk_analytics].[loans] AS l
WHERE     l.l_actual_closure_date IS NOT NULL
GROUP BY  l.l_source, l.l_loan_status
HAVING    COUNT_BIG(*) >= 100
ORDER BY  l.l_source, closed_loans DESC
OPTION (MAXDOP 1);

/* ─────────────────────────────────────────────────────────────────────────
   3. Сумма выдачи (2-1 ①) — два кандидата.
      Ноль отделён от NULL намеренно: нулевая сумма выдачи — не пропуск,
      а утверждение, и по возобновляемым оно может быть верным.
   ───────────────────────────────────────────────────────────────────────── */
SELECT    l.l_source
        , COUNT_BIG(*)                                                                    AS loans_total
        , SUM(CASE WHEN l.l_loan_amount IS NULL THEN 1 ELSE 0 END)                        AS amount_null
        , SUM(CASE WHEN l.l_loan_amount = 0     THEN 1 ELSE 0 END)                        AS amount_zero
        , SUM(CASE WHEN l.l_loan_amount > 0     THEN 1 ELSE 0 END)                        AS amount_pos
        , SUM(CAST(ISNULL(l.l_loan_amount,0) AS decimal(38,2)))                           AS amount_sum
        , SUM(CASE WHEN l.l_limit IS NULL THEN 1 ELSE 0 END)                              AS limit_null
        , SUM(CASE WHEN l.l_limit = 0     THEN 1 ELSE 0 END)                              AS limit_zero
        , SUM(CASE WHEN l.l_limit > 0     THEN 1 ELSE 0 END)                              AS limit_pos
        , SUM(CAST(ISNULL(l.l_limit,0) AS decimal(38,2)))                                 AS limit_sum
        , SUM(CASE WHEN ISNULL(l.l_loan_amount,0) = ISNULL(l.l_limit,0)
                   THEN 1 ELSE 0 END)                                                     AS amount_eq_limit
FROM      [Dictionaries].[risk_analytics].[loans] AS l
GROUP BY  l.l_source
ORDER BY  l.l_source
OPTION (MAXDOP 1);

/* ─────────────────────────────────────────────────────────────────────────
   4а. Ключ заёмщика (3 ③) — заполненность и мощность по источнику.
   ───────────────────────────────────────────────────────────────────────── */
SELECT    l.l_source
        , COUNT_BIG(*)                                                                    AS loans_total
        , SUM(CASE WHEN l.l_borrower_id IS NOT NULL THEN 1 ELSE 0 END)                    AS bid_filled
        , COUNT(DISTINCT l.l_borrower_id)                                                 AS bid_distinct
FROM      [Dictionaries].[risk_analytics].[loans] AS l
GROUP BY  l.l_source
ORDER BY  l.l_source
OPTION (MAXDOP 1);

/* ─────────────────────────────────────────────────────────────────────────
   4б. Межисточниковые коллизии ключа заёмщика.
       У l_gid их 9 659 — проверяется, есть ли то же у l_borrower_id.
       Всё, что не в строке src_count = 1, при сквозном COUNT(DISTINCT)
       считается один раз вместо нескольких — либо наоборот, смотря
       кто эти заёмщики: один человек в двух системах или два разных.
   ───────────────────────────────────────────────────────────────────────── */
SELECT    t.src_count
        , COUNT_BIG(*)                                                                    AS borrowers
FROM      ( SELECT    l.l_borrower_id
                    , COUNT(DISTINCT l.l_source) AS src_count
            FROM      [Dictionaries].[risk_analytics].[loans] AS l
            WHERE     l.l_borrower_id IS NOT NULL
            GROUP BY  l.l_borrower_id ) AS t
GROUP BY  t.src_count
ORDER BY  t.src_count
OPTION (MAXDOP 1);

/* ─────────────────────────────────────────────────────────────────────────
   5. Глубина ряда выдач (2-1) — 24 месяца до даты среза.
      Показывает, за какой период отчёт вообще может быть построен.
   ───────────────────────────────────────────────────────────────────────── */
SELECT    l.l_source
        , DATEFROMPARTS(YEAR(l.l_funding_date), MONTH(l.l_funding_date), 1)               AS funding_month
        , COUNT_BIG(*)                                                                    AS issued_cnt
        , SUM(CAST(ISNULL(l.l_loan_amount,0) AS decimal(38,2)))                           AS issued_amount
FROM      [Dictionaries].[risk_analytics].[loans] AS l
WHERE     l.l_funding_date >= DATEADD(month, -24, @snap)
      AND l.l_funding_date <  @snap
GROUP BY  l.l_source
        , DATEFROMPARTS(YEAR(l.l_funding_date), MONTH(l.l_funding_date), 1)
ORDER BY  l.l_source, funding_month
OPTION (MAXDOP 1);
