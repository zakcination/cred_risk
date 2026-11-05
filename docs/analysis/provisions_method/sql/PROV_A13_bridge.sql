/* =============================================================================
   PROV_A13_bridge.sql — Track A, шаги 1 и 3: снимок S03 на 01.09.2026 обеих баз,
   расчёт A_old / A_new по правилу старой системы и разложение P_new − P_old.
   План — TRACK_A_PLAN.md §12, согласован Мирасом 12.10.2026. Issue #164.

   Р-10 (Мирас, 12.10.2026): отчётная дата — 01.09.2026 (срез проекта ECL Сайлау).
   Прогон 01.10.2026 — TRACK_A_PLAN §13 (история). Логика, формулы и критерии не
   менялись; E1 берёт границу из тех же данных вместо константы 01.10, места,
   опиравшиеся на свойство 01.10, помечены «[свойство 01.10]». Ожидания на 01.09 —
   TRACK_A_PLAN §14. Запуск — после A0…A0f, см. PROV_A_0901_run.sql.

   Как читать результат (замечания Сайлау, Методология ECL ред. 1.2, §М6 — в силе):
     • T2 = A_old − P_old при ставке percent = арифметика «ставка × база»,
       НЕ проверка Методики: ставка взята из той же старой системы (Р-1′ а).
     • ε = 0 — полнота моста (слагаемые исчерпывают P_new − P_old), НЕ валидация
       расчёта: ε = 0 по построению.

   Определения (§12.1):
     r      = percent / 100                         — ставка старой системы, одна для обеих баз
     V_old  = CL_PORTFOLIO_2.balance_with_discount
     V_new  = loan_account.discounted_balance_debt  (Д-A0f-1)
     A      = ROUND(r × V, 2)                       — правило 1428 старой системы (Д-A0c-1)
     P      = 1428 + 1845 + 18771 по счетам; эталон P_old = provisions_total (Р-6)

   Разложение (только 1428 моделируется; 1845 и 18771 переносятся как есть, §12.4):
     P_new − P_old = T1 + T2 + T3 + D18771 + D1845
       T1 = A_new − A_old                (эффект данных: база V и периметр)
       T2 = A_old − P_old_1428           (точность правила «ставка × база» в старой системе)
       T3 = P_new_1428 − A_new           (отличие 1428 новой системы от нашего расчёта)
       D18771, D1845 = P_new − P_old по счёту
     ε = (T1 + T2 + T3 + D18771 + D1845) − (P_new − P_old) = 0 по построению;
     ε ≠ 0 — ошибка скрипта, а не данных.

   Ожидания, зафиксированные ДО прогона (§12.3):
     E1  |Σ T1| на общих договорах ≤ B = Σ |V_new − V_old| × r (формула dp_abs_bound
         A0f §1, Д-A0f-2). Больше — ошибка скрипта. [свойство 01.10] на 01.10 B был
         константой 112 480,17 ₸; на 01.09 B считается здесь же и должен совпасть с
         Σ dp_abs_bound A0f §1 того же прогона. Это проверка согласованности скриптов,
         а не довод о данных.
     E2  «только new»: Σ A_new = 0 (остаток 0, Д-A0c-6); ненулевой V_new — находка.
         ok = 1 по построению (ставки у «только new» нет); смысл — в value = Σ V_new.
         [свойство 01.10] V_new = 0 у всех «только new» — установлено на 01.10.
     E3  «только old»: Σ A_old ≈ Σ 1428 этих договоров (Д-A0b-3), без порога.
         [свойство 01.10] на 01.10 — ≈ 9,1 млрд; на 01.09 величина другая.
     E4  Контроль: Σ P_old (§3a) = Σ sum_provisions A0 §2; Σ P_new (§3a) = Σ p_new
         A0c §3 + Σ p_new A0c §4 — всё на 01.09. [свойство 01.10] на 01.10 —
         82 516 552 205,55 и 75 752 796 270,90 (§11.8).
     E5  Категория 1: доля договоров с |T2_i| ≤ 1 ₸ ≥ 95 % (Д-A0c-1).
     E6  POCI (категория 4): r = 0, A = 0; P только по 18771.
         [свойство 01.10] percent = 0 у POCI установлено на 01.10 (Д-A0f-2); ненулевой
         percent на 01.09 — вопрос Р-4, а не ошибка скрипта.

   Шаг 1 = временные таблицы #A13_old / #A13_new / #A13_b (построчно, на ПК).
   Шаг 3 = §3a–§3e. Наружу — только агрегаты.

   Правила (§4 CLAUDE.md): только SELECT, #A13_*, MAXDOP 1, трёхчастные имена, IIN не
   выбирается, номера договоров — только внутри JOIN. Имена — из §0 A0 и §2 A0d.
   Запуск — целиком, в одном соединении (батчи разделены GO).
   ============================================================================= */

/* ШАГ 1. Снимок обеих баз на 01.09.2026.                                           */
DECLARE @AsOf date = '2026-09-01';

IF OBJECT_ID('tempdb..#A13_old') IS NOT NULL DROP TABLE #A13_old;
SELECT contract_number,
       category,
       product,
       subproduct,
       CASE WHEN [percent] IS NULL THEN 1 ELSE 0 END                         AS percent_null,
       CAST(ISNULL([percent], 0) AS decimal(18,6)) / 100                     AS r,
       CAST(ISNULL(balance_with_discount, 0)  AS decimal(38,2))              AS v_old,
       CAST(ISNULL(ifrs, 0)                    AS decimal(38,2))             AS p_old_1428,
       CAST(ISNULL(IFRS1845, 0)                AS decimal(38,2))             AS p_old_1845,
       CAST(ISNULL(ifrs18771_WTRAF_i_PENII, 0) AS decimal(38,2))             AS p_old_18771,
       CAST(ISNULL(provisions_total, 0)        AS decimal(38,2))             AS p_old_total
INTO #A13_old
FROM [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2]
WHERE [date] = @AsOf
OPTION (MAXDOP 1);

IF OBJECT_ID('tempdb..#A13_new') IS NOT NULL DROP TABLE #A13_new;
SELECT l.l_loan_number                                                AS contract_number,
       COUNT(*)                                                       AS rows_n,
       MIN(la.la_status)                                              AS la_status,
       SUM(CAST(ISNULL(la.discounted_balance_debt, 0) AS decimal(38,2))) AS v_new,
       SUM(CAST(ISNULL(la.la_account_1428,  0) AS decimal(38,2)))     AS p_new_1428,
       SUM(CAST(ISNULL(la.la_account_1845,  0) AS decimal(38,2)))     AS p_new_1845,
       SUM(CAST(ISNULL(la.la_account_18771, 0) AS decimal(38,2)))     AS p_new_18771
INTO #A13_new
FROM [Dictionaries].[risk_analytics].[loan_account] la
JOIN [Dictionaries].[risk_analytics].[loans] l
  ON l.l_gid = la.la_gid AND l.l_source = la.la_source
WHERE la.la_source = 'S03' AND la.la_reporting_date = @AsOf
GROUP BY l.l_loan_number
OPTION (MAXDOP 1);

-- Договор × обе базы × расчёт. Ставка — только из старой базы; у «только new» её нет:
-- A_new для них = 0, а случаи V_new ≠ 0 без ставки считаются отдельно (E2).
IF OBJECT_ID('tempdb..#A13_b') IS NOT NULL DROP TABLE #A13_b;
SELECT CASE WHEN o.contract_number IS NOT NULL AND n.contract_number IS NOT NULL THEN '1 old+new'
            WHEN o.contract_number IS NOT NULL THEN '2 только old'
            ELSE '3 только new' END                                           AS cover,
       COALESCE(CAST(CAST(o.category AS int) AS varchar(10)), '—')            AS category,
       COALESCE(o.product,    '—')                                           AS product,
       COALESCE(o.subproduct, '—')                                           AS subproduct,
       ISNULL(o.percent_null, 0)                                             AS percent_null,
       ISNULL(n.rows_n, 0)                                                   AS new_rows_n,
       o.r,
       ISNULL(o.v_old, 0)                                                    AS v_old,
       ISNULL(n.v_new, 0)                                                    AS v_new,
       CASE WHEN o.contract_number IS NULL THEN 0
            ELSE ROUND(o.r * o.v_old, 2) END                                 AS a_old,
       CASE WHEN n.contract_number IS NULL OR o.contract_number IS NULL THEN 0
            ELSE ROUND(o.r * n.v_new, 2) END                                 AS a_new,
       ISNULL(o.p_old_1428, 0)  AS p_old_1428,  ISNULL(n.p_new_1428, 0)  AS p_new_1428,
       ISNULL(o.p_old_1845, 0)  AS p_old_1845,  ISNULL(n.p_new_1845, 0)  AS p_new_1845,
       ISNULL(o.p_old_18771, 0) AS p_old_18771, ISNULL(n.p_new_18771, 0) AS p_new_18771,
       ISNULL(o.p_old_total, 0) AS p_old_total
INTO #A13_b
FROM #A13_old o
FULL JOIN #A13_new n ON n.contract_number = o.contract_number
OPTION (MAXDOP 1);
GO

/* §3a. Контроль снимка (E4) и целостность.                                         */
SELECT cover,
       COUNT(*)                                                    AS contracts,
       SUM(CASE WHEN new_rows_n > 1 THEN 1 ELSE 0 END)             AS new_multirow,
       SUM(percent_null)                                           AS percent_null,
       SUM(CASE WHEN cover = '3 только new' AND v_new <> 0 THEN 1 ELSE 0 END) AS only_new_v_ne0,
       SUM(p_old_total)                                            AS p_old_total,
       SUM(p_old_1428 + p_old_1845 + p_old_18771)                  AS p_old_by_accounts,
       SUM(p_new_1428 + p_new_1845 + p_new_18771)                  AS p_new,
       SUM(v_old)                                                  AS v_old,
       SUM(v_new)                                                  AS v_new
FROM #A13_b
GROUP BY ROLLUP (cover)
ORDER BY GROUPING(cover), cover
OPTION (MAXDOP 1);
GO

/* §3b. Главное разложение: покрытие × категория, с подытогами и итогом.            */
SELECT cover, category,
       GROUPING(cover) + GROUPING(category)                        AS total_level,
       COUNT(*)                                                    AS contracts,
       SUM(p_old_1428 + p_old_1845 + p_old_18771)                  AS p_old,
       SUM(p_new_1428 + p_new_1845 + p_new_18771)                  AS p_new,
       SUM(p_new_1428 + p_new_1845 + p_new_18771
         - p_old_1428 - p_old_1845 - p_old_18771)                  AS d_p,
       SUM(a_old)                                                  AS a_old,
       SUM(a_new)                                                  AS a_new,
       SUM(a_new - a_old)                                          AS t1_data,
       SUM(a_old - p_old_1428)                                     AS t2_rule_old,
       SUM(p_new_1428 - a_new)                                     AS t3_new_vs_calc,
       SUM(p_new_18771 - p_old_18771)                              AS d_18771,
       SUM(p_new_1845 - p_old_1845)                                AS d_1845,
       SUM((a_new - a_old) + (a_old - p_old_1428) + (p_new_1428 - a_new)
           + (p_new_18771 - p_old_18771) + (p_new_1845 - p_old_1845))
     - SUM(p_new_1428 + p_new_1845 + p_new_18771
         - p_old_1428 - p_old_1845 - p_old_18771)                  AS eps,
       SUM(ABS(a_new - a_old))                                     AS t1_abs,
       SUM(ABS(a_old - p_old_1428))                                AS t2_abs
FROM #A13_b
GROUP BY GROUPING SETS ((cover, category), (cover), ())
ORDER BY total_level, cover, category
OPTION (MAXDOP 1);
GO

/* §3c. Общие договоры: категория × продукт × субпродукт (Р-3″).                    */
SELECT category, product, subproduct,
       COUNT(*)                                AS contracts,
       SUM(v_old)                              AS v_old,
       SUM(p_old_1428)                         AS p_old_1428,
       SUM(a_old)                              AS a_old,
       SUM(a_new - a_old)                      AS t1_data,
       SUM(a_old - p_old_1428)                 AS t2_rule_old,
       SUM(ABS(a_old - p_old_1428))            AS t2_abs,
       SUM(CASE WHEN ABS(a_old - p_old_1428) <= 1 THEN 1 ELSE 0 END) AS t2_match_1,
       SUM(p_new_1428 - a_new)                 AS t3_new_vs_calc,
       SUM(p_new_18771 - p_old_18771)          AS d_18771
FROM #A13_b
WHERE cover = '1 old+new'
GROUP BY category, product, subproduct
ORDER BY category, product, subproduct
OPTION (MAXDOP 1);
GO

/* §3d. Бакеты величины по договору: T2 (точность правила, E5) и T1 (эффект данных).
   Худшие случаи — бакетом, не идентификатором (§4 CLAUDE.md).                      */
SELECT x.term, x.category, x.bucket,
       COUNT(*)        AS contracts,
       SUM(x.d)        AS sum_d,
       SUM(ABS(x.d))   AS sum_abs_d
FROM (SELECT 'T2 a_old - p_old_1428' AS term, category, a_old - p_old_1428 AS d FROM #A13_b WHERE cover <> '3 только new'
      UNION ALL
      SELECT 'T1 a_new - a_old',             category, a_new - a_old      AS d FROM #A13_b WHERE cover = '1 old+new') s
CROSS APPLY (SELECT s.term, s.category, s.d,
                    CASE WHEN ABS(s.d) <= 1         THEN '1 <= 1'
                         WHEN ABS(s.d) <= 1000      THEN '2 <= 1 тыс'
                         WHEN ABS(s.d) <= 100000    THEN '3 <= 100 тыс'
                         WHEN ABS(s.d) <= 10000000  THEN '4 <= 10 млн'
                         ELSE                            '5 > 10 млн' END AS bucket) x
GROUP BY x.term, x.category, x.bucket
ORDER BY x.term, x.category, x.bucket
OPTION (MAXDOP 1);
GO

/* §3e. Проверка ожиданий E1–E3, E5, E6 одной таблицей (1 = выполнено).              */
SELECT 'E1 |sum T1| common <= B' AS check_name,
       CASE WHEN ABS(SUM(a_new - a_old)) <= SUM(ABS(v_new - v_old) * r) THEN 1 ELSE 0 END AS ok,
       SUM(a_new - a_old) AS value
FROM #A13_b WHERE cover = '1 old+new'
UNION ALL
SELECT 'E1b B = sum |V_new - V_old| * r (= A0f dp_abs_bound)', NULL, SUM(ABS(v_new - v_old) * r)
FROM #A13_b WHERE cover = '1 old+new'
UNION ALL
SELECT 'E1c sum |T1_i| - B (rounding only)', NULL, SUM(ABS(a_new - a_old)) - SUM(ABS(v_new - v_old) * r)
FROM #A13_b WHERE cover = '1 old+new'
UNION ALL
SELECT 'E2 only new: sum A_new = 0', CASE WHEN SUM(a_new) = 0 THEN 1 ELSE 0 END, SUM(v_new)
FROM #A13_b WHERE cover = '3 только new'
UNION ALL
SELECT 'E3 only old: sum A_old vs sum 1428', NULL, SUM(a_old) - SUM(p_old_1428)
FROM #A13_b WHERE cover = '2 только old'
UNION ALL
SELECT 'E5 cat 1: share |T2| <= 1',
       CASE WHEN 1.0 * SUM(CASE WHEN ABS(a_old - p_old_1428) <= 1 THEN 1 ELSE 0 END) / COUNT(*) >= 0.95
            THEN 1 ELSE 0 END,
       1.0 * SUM(CASE WHEN ABS(a_old - p_old_1428) <= 1 THEN 1 ELSE 0 END) / COUNT(*)
FROM #A13_b WHERE category = '1' AND cover <> '3 только new'
UNION ALL
SELECT 'E6 POCI: sum A_old + A_new = 0', CASE WHEN SUM(a_old + a_new) = 0 THEN 1 ELSE 0 END, SUM(a_old + a_new)
FROM #A13_b WHERE category = '4'
OPTION (MAXDOP 1);
GO

IF OBJECT_ID('tempdb..#A13_old') IS NOT NULL DROP TABLE #A13_old;
IF OBJECT_ID('tempdb..#A13_new') IS NOT NULL DROP TABLE #A13_new;
IF OBJECT_ID('tempdb..#A13_b')   IS NOT NULL DROP TABLE #A13_b;
