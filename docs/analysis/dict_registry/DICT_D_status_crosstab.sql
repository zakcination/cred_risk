/* =============================================================================
   DICT_D — перевести расшифровки статусов S02 и S17 из вывода в факт.

   ЗАЧЕМ. В status_map.csv расшифровки по S02 и S17 помечены «вывод, не
   справочник»: они получены сопоставлением ПО СМЫСЛУ с доменом статуса счёта
   loan_account.la_status, а не измеренной кросс-таблицей. Пока кросс-таблицы
   нет, «Account Expenses Blocked = Договор заблокирован по расходным
   операциям» — правдоподобный перевод, а не установленное соответствие.

   ЧТО ИЗМЕРЯЕМ. Совместное распределение статуса ДОГОВОРА (loans.l_loan_status)
   и статуса СЧЁТА (loan_account.la_status) на дату среза.

   В КАКОМ РАЗРЕЗЕ. Источник; отдельно — S17 статус Т крупным планом.

   ЧТО СЧИТАЕТСЯ ИСХОДОМ.
     блок 1 — соответствие доказано, если каждому статусу договора отвечает
              ровно один статус счёта с подавляющей долей. Размазанная строка
              означает, что статусы измеряют разное, и перевод опровергнут.
     блок 2 — сопоставление однозначно только если договоров с более чем одним
              различным la_status пренебрежимо мало. Иначе «статус счёта»
              свойством договора не является, и переносить его нельзя.
     блок 3 — РЕШАЮЩИЙ для портфеля. S17 статус Т, 23 786 договоров, все с
              датой закрытия. Если у них есть открытые счета с ненулевым
              остатком — Т не «закрыт», и периметр S17 занижен на треть.
              Если счетов нет или остатки нулевые — Т в портфель не входит
              и вопрос закрывается в пользу текущего отбора.

   ЛОВУШКА ДАТЫ. loan_account историзована, и глубина у источников разная:
   по S01 строк на 2026-08-01 нет вовсе (objects.csv). Поэтому дата берётся
   СВОЯ на каждый источник, а не общий MAX — иначе источник без строк на
   общую дату молча превращается в «счетов нет».

   Read-only. PII не выводится: только агрегаты и суммы.
   ============================================================================= */
SET NOCOUNT ON;

DECLARE @lsnap date = (SELECT MAX(l_report_date)
                       FROM [Dictionaries].[risk_analytics].[loans]);

/* Последняя дата среза счетов — отдельно по каждому источнику. */
IF OBJECT_ID('tempdb..#dictd_lastdate') IS NOT NULL DROP TABLE #dictd_lastdate;
SELECT    la.la_source
        , MAX(la.la_reporting_date) AS last_dt
INTO      #dictd_lastdate
FROM      [Dictionaries].[risk_analytics].[loan_account] AS la
GROUP BY  la.la_source
OPTION (MAXDOP 1);

SELECT @lsnap AS loans_snapshot;
SELECT la_source, last_dt FROM #dictd_lastdate ORDER BY la_source;

/* ─────────────────────────────────────────────────────────────────────────
   1. Кросс-таблица: статус договора × статус счёта.
      la_status IS NULL означает «счёта на дату нет» — это не пропуск,
      а содержательный исход: по картам счёт есть у меньшинства договоров.
   ───────────────────────────────────────────────────────────────────────── */
SELECT    l.l_source
        , l.l_loan_status
        , ISNULL(la.la_status, N'(счёта нет)')                               AS la_status
        , COUNT(DISTINCT l.l_gid)                                            AS loans_distinct
        , COUNT_BIG(*)                                                       AS rows_joined
FROM      [Dictionaries].[risk_analytics].[loans] AS l
LEFT JOIN #dictd_lastdate AS d
       ON d.la_source = l.l_source
LEFT JOIN [Dictionaries].[risk_analytics].[loan_account] AS la
       ON  la.la_gid            = l.l_gid
       AND la.la_source         = l.l_source
       AND la.la_reporting_date = d.last_dt
WHERE     l.l_source IN ('S02', 'S17')
GROUP BY  l.l_source, l.l_loan_status, ISNULL(la.la_status, N'(счёта нет)')
ORDER BY  l.l_source, l.l_loan_status, loans_distinct DESC
OPTION (MAXDOP 1);

/* ─────────────────────────────────────────────────────────────────────────
   2. Однозначность: сколько различных la_status приходится на один договор.
      Строка statuses_per_loan > 1 с заметным числом договоров опровергает
      саму возможность переносить статус счёта на договор.
   ───────────────────────────────────────────────────────────────────────── */
SELECT    t.l_source
        , t.statuses_per_loan
        , COUNT_BIG(*)                                                       AS loans
FROM      ( SELECT    l.l_source
                    , l.l_gid
                    , COUNT(DISTINCT la.la_status) AS statuses_per_loan
            FROM      [Dictionaries].[risk_analytics].[loans] AS l
            JOIN      #dictd_lastdate AS d
                   ON d.la_source = l.l_source
            JOIN      [Dictionaries].[risk_analytics].[loan_account] AS la
                   ON  la.la_gid            = l.l_gid
                   AND la.la_source         = l.l_source
                   AND la.la_reporting_date = d.last_dt
            GROUP BY  l.l_source, l.l_gid ) AS t
GROUP BY  t.l_source, t.statuses_per_loan
ORDER BY  t.l_source, t.statuses_per_loan
OPTION (MAXDOP 1);

/* ─────────────────────────────────────────────────────────────────────────
   3. РЕШАЮЩИЙ. S17 статус Т — 23 786 договоров неизвестного смысла.
      Сравнивается с О (действующий) и З (закрыт) на одних и тех же
      величинах: есть ли счёт, открыт ли он, есть ли остаток и просрочка.
      Т, ведущий себя как О, — действующий договор вне периметра.
      Т, ведущий себя как З, — закрытый, и текущий отбор верен.
   ───────────────────────────────────────────────────────────────────────── */
SELECT    l.l_loan_status
        , COUNT(DISTINCT l.l_gid)                                            AS loans_distinct
        , SUM(CASE WHEN la.la_gid IS NOT NULL THEN 1 ELSE 0 END)             AS with_account
        , SUM(CASE WHEN la.la_status = N'Открыт' THEN 1 ELSE 0 END)          AS acc_open
        , SUM(CAST(ISNULL(la.total_balance_debt,0) AS decimal(38,2)))        AS balance
        , SUM(CAST(ISNULL(la.la_account_1424,0)    AS decimal(38,2)))        AS overdue_principal
        , SUM(CAST(ISNULL(la.la_account_1428,0) + ISNULL(la.la_account_1845,0)
                 + ISNULL(la.la_account_18771,0) AS decimal(38,2)))          AS provisions
FROM      [Dictionaries].[risk_analytics].[loans] AS l
LEFT JOIN #dictd_lastdate AS d
       ON d.la_source = l.l_source
LEFT JOIN [Dictionaries].[risk_analytics].[loan_account] AS la
       ON  la.la_gid            = l.l_gid
       AND la.la_source         = l.l_source
       AND la.la_reporting_date = d.last_dt
WHERE     l.l_source = 'S17'
GROUP BY  l.l_loan_status
ORDER BY  loans_distinct DESC
OPTION (MAXDOP 1);

DROP TABLE #dictd_lastdate;
