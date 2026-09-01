/* ============================================================================
   НСТ / сегментация AQR-2025: контрольные запросы ПЕРЕД правкой скрипта.

   Назначение: измерить масштаб каждого замечания из SQL_REVIEW.md, чтобы
   правки вносились по фактам, а не по предположениям.

   Правила: только SELECT, ничего не создаётся и не меняется. PII не выводится —
   только агрегаты. Имена колонок берутся из живого аудита (Q0), а не из памяти.
   Тяжёлые запросы — с MAXDOP 1.

   Порядок: Q0 выполнить первым. Если колонка из запроса отсутствует в аудите —
   запрос не запускать, а сверить имя.

   Результаты присылать целиком: по ним правится скрипт.
   ============================================================================ */


/* --- Q0. АУДИТ КОЛОНОК. Выполнять первым -----------------------------------
   Что смотрим: реально существующие имена и типы колонок в источниках.
   Зачем: все дальнейшие запросы опираются на эти имена.                     */

SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH
FROM [CL_PORTFOLIO].[INFORMATION_SCHEMA].[COLUMNS]
WHERE TABLE_NAME IN ('AQR2025_B1A_2024_Q4', 'AQR2025_B1B_2024_Q4')
ORDER BY TABLE_NAME, ORDINAL_POSITION;

SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE
FROM [personal_tables].[INFORMATION_SCHEMA].[COLUMNS]
WHERE TABLE_NAME IN ('RA_NST_segment_AQR2025',
                     'RA_NST_segment_AQR2025_B1B',
                     'RA_NST_B2A_AQR2025_11082025')
ORDER BY TABLE_NAME, ORDINAL_POSITION;


/* --- Q1. РАСПРЕДЕЛЕНИЕ СТАДИЙ (замечание 10) --------------------------------
   Что смотрим: сколько записей и какой объём приходится на stage_b = 4
   и на заглушку '1111111111111', которые мы приводим к стадиям 3 и 1.
   Что делать: если доля заглушки заметна, приведение к стадии 1 занижает
   риск и должно быть описано в пояснительной записке отдельно.            */

SELECT 'B1A' AS shablon, n.stage_b,
       COUNT(*)                                   AS cnt,
       SUM(TRY_CAST(n.ead AS FLOAT)) / 1e9        AS ead_mlrd,
       CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,2)) AS share_cnt_pct
FROM [CL_PORTFOLIO].[dbo].[AQR2025_B1A_2024_Q4] n
WHERE n.is_del = '0'
GROUP BY n.stage_b
UNION ALL
SELECT 'B1B', d.stage_b, COUNT(*), SUM(TRY_CAST(d.ead AS FLOAT)) / 1e9,
       CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,2))
FROM [CL_PORTFOLIO].[dbo].[AQR2025_B1B_2024_Q4] d
WHERE d.is_del = '0'
GROUP BY d.stage_b
ORDER BY shablon, cnt DESC
OPTION (MAXDOP 1);


/* --- Q2. ДОЛЯ ЗАГЛУШЕК ПО МЕТРИКАМ (замечание 1) ----------------------------
   Что смотрим: какая доля EAD приходится на займы с заглушкой в каждой
   метрике. Это одновременно метрика заполняемости, за которую отвечает БРМ.
   Что делать: доля больше нескольких процентов означает, что действующее
   обнуление заметно занижает средневзвешенные по сегменту.                */

WITH src AS (
    SELECT n.stage_b, n.ccf, n.lgd, n.pd_c12, n.pd_cl, n.pd_ol,
           TRY_CAST(n.ead AS FLOAT)    AS ead,
           TRY_CAST(n.offbal AS FLOAT) AS offbal
    FROM [CL_PORTFOLIO].[dbo].[AQR2025_B1A_2024_Q4] n
    WHERE n.is_del = '0'
)
SELECT m.metric,
       SUM(CASE WHEN m.is_stub = 1 THEN 1 ELSE 0 END)                       AS stub_cnt,
       CAST(100.0 * SUM(CASE WHEN m.is_stub = 1 THEN 1 ELSE 0 END)
            / NULLIF(COUNT(*), 0) AS DECIMAL(5,2))                          AS stub_share_cnt_pct,
       SUM(CASE WHEN m.is_stub = 1 THEN m.w ELSE 0 END) / 1e9               AS stub_weight_mlrd,
       CAST(100.0 * SUM(CASE WHEN m.is_stub = 1 THEN m.w ELSE 0 END)
            / NULLIF(SUM(m.w), 0) AS DECIMAL(5,2))                          AS stub_share_weight_pct
FROM src
CROSS APPLY (VALUES
    ('ccf',    CASE WHEN src.ccf    IN ('1111111111111','9999999999999') THEN 1 ELSE 0 END, src.offbal),
    ('lgd',    CASE WHEN src.lgd    IN ('1111111111111','9999999999999') THEN 1 ELSE 0 END, src.ead),
    ('pd_c12', CASE WHEN src.pd_c12 IN ('1111111111111','9999999999999') THEN 1 ELSE 0 END, src.ead),
    ('pd_cl',  CASE WHEN src.pd_cl  IN ('1111111111111','9999999999999') THEN 1 ELSE 0 END, src.ead),
    ('pd_ol',  CASE WHEN src.pd_ol  IN ('1111111111111','9999999999999') THEN 1 ELSE 0 END, src.ead)
) AS m(metric, is_stub, w)
GROUP BY m.metric
ORDER BY stub_share_weight_pct DESC
OPTION (MAXDOP 1);


/* --- Q3. ЭФФЕКТ ОБНУЛЕНИЯ ЗАГЛУШЕК В ЦИФРАХ (замечание 1) -------------------
   Что смотрим: средневзвешенная LGD по сегменту и стадии, посчитанная
   действующим способом (заглушка = 0) и корректным (заглушка исключена
   из весов). Разница — величина занижения.
   Что делать: если расхождение существенно, правка обязательна до расчёта. */

WITH d AS (
    SELECT fg.segment_afr,
           CASE WHEN TRY_CAST(n.stage_b AS FLOAT) = 4 THEN 3
                WHEN n.stage_b = '1111111111111'     THEN 1
                ELSE TRY_CAST(n.stage_b AS FLOAT) END        AS stage_new,
           CASE WHEN n.lgd IN ('1111111111111','9999999999999') THEN NULL
                ELSE TRY_CAST(n.lgd AS FLOAT) END            AS lgd_known,
           TRY_CAST(n.ead AS FLOAT)                          AS ead
    FROM [CL_PORTFOLIO].[dbo].[AQR2025_B1A_2024_Q4] n
    LEFT JOIN [personal_tables].[dbo].[RA_NST_segment_AQR2025] fg
           ON n.loan_id_kr = fg.loan_id_kr
    WHERE n.is_del = '0'
)
SELECT segment_afr, stage_new,
       SUM(COALESCE(lgd_known, 0) * ead) / NULLIF(SUM(ead), 0)              AS lgd_now,
       SUM(CASE WHEN lgd_known IS NOT NULL THEN lgd_known * ead END)
           / NULLIF(SUM(CASE WHEN lgd_known IS NOT NULL THEN ead END), 0)   AS lgd_fixed,
       CAST(100.0 * SUM(CASE WHEN lgd_known IS NULL THEN ead ELSE 0 END)
            / NULLIF(SUM(ead), 0) AS DECIMAL(5,2))                          AS stub_weight_pct
FROM d
GROUP BY segment_afr, stage_new
ORDER BY stub_weight_pct DESC
OPTION (MAXDOP 1);


/* --- Q4. НЕСОПОСТАВЛЕННЫЕ СЕГМЕНТЫ И 'X' (замечание 3) ----------------------
   Что смотрим: сколько займов не получили сегмент при джойне и сколько
   попали в 'X'.
   Что делать: расчёт не запускать, пока обе величины не объяснены.        */

SELECT 'B1A' AS shablon,
       COUNT(*)                                                              AS rows_total,
       SUM(CASE WHEN fg.segment_afr IS NULL THEN 1 ELSE 0 END)              AS no_segment,
       SUM(CASE WHEN fg.segment_afr = 'X'   THEN 1 ELSE 0 END)              AS segment_x,
       SUM(CASE WHEN fg.segment_afr IS NULL THEN TRY_CAST(n.ead AS FLOAT) ELSE 0 END) / 1e9 AS no_segment_ead_mlrd
FROM [CL_PORTFOLIO].[dbo].[AQR2025_B1A_2024_Q4] n
LEFT JOIN [personal_tables].[dbo].[RA_NST_segment_AQR2025] fg
       ON n.loan_id_kr = fg.loan_id_kr
WHERE n.is_del = '0'
UNION ALL
SELECT 'B1B', COUNT(*),
       SUM(CASE WHEN sd.segment_afr IS NULL THEN 1 ELSE 0 END),
       SUM(CASE WHEN sd.segment_afr = 'X'   THEN 1 ELSE 0 END),
       SUM(CASE WHEN sd.segment_afr IS NULL THEN TRY_CAST(d.ead AS FLOAT) ELSE 0 END) / 1e9
FROM [CL_PORTFOLIO].[dbo].[AQR2025_B1B_2024_Q4] d
LEFT JOIN [personal_tables].[dbo].[RA_NST_segment_AQR2025_B1B] sd
       ON d.loan_id_kr = sd.loan_id_kr
WHERE d.is_del = '0'
OPTION (MAXDOP 1);


/* --- Q5. УТЕЧКА РОЗНИЦЫ В КОРПОРАТИВНЫЕ СЕГМЕНТЫ (замечание 4) --------------
   Что смотрим: есть ли физические лица (debtor_type = 0), у которых заполнен
   ent_type. В действующем порядке ветвления они уходят в CORLAR / CORMED /
   RETSML раньше, чем проверяются признаки розницы.
   Что делать: если строки есть — менять порядок ветвления, сначала отделять
   физических лиц.                                                          */

SELECT n.ent_type,
       n.debtor_se,
       COUNT(*)                            AS cnt,
       SUM(TRY_CAST(n.ead AS FLOAT)) / 1e9 AS ead_mlrd
FROM [CL_PORTFOLIO].[dbo].[AQR2025_B1A_2024_Q4] n
WHERE n.is_del = '0'
  AND TRY_CAST(n.debtor_type AS FLOAT) = 0
  AND TRY_CAST(n.ent_type AS FLOAT) IN (1, 2, 3)
GROUP BY n.ent_type, n.debtor_se
ORDER BY cnt DESC
OPTION (MAXDOP 1);


/* --- Q6. ОБЪЁМ ПЕРЕРАСПРЕДЕЛЯЕМЫХ ПОРТФЕЛЕЙ (замечание 5) -------------------
   Что смотрим: сколько задолженности сидит в Individual loans и DISASS —
   их для кредитного риска НСТ нужно разложить по продуктовым портфелям.
   Что делать: оценить трудоёмкость правила перераспределения.             */

SELECT fg.segment_afr,
       COUNT(*)                                  AS cnt,
       SUM(TRY_CAST(n.ead AS FLOAT)) / 1e9       AS ead_mlrd,
       SUM(TRY_CAST(n.provisions AS FLOAT)) / 1e9 AS prov_mlrd
FROM [CL_PORTFOLIO].[dbo].[AQR2025_B1A_2024_Q4] n
LEFT JOIN [personal_tables].[dbo].[RA_NST_segment_AQR2025] fg
       ON n.loan_id_kr = fg.loan_id_kr
WHERE n.is_del = '0'
GROUP BY fg.segment_afr
ORDER BY ead_mlrd DESC
OPTION (MAXDOP 1);


/* --- Q7. КРИТЕРИЙ RETEST: метка продукта против обеспечения (замечание 7) ---
   Что смотрим: совпадает ли portfolio = 'Mortgage' с наличием обеспечения.
   Портфель НСТ называется «займы, обеспеченные жилой недвижимостью».
   Что делать: если совпадение неполное — решить, что является определяющим. */

SELECT n.portfolio,
       TRY_CAST(n.collateral AS FLOAT)     AS collateral,
       COUNT(*)                            AS cnt,
       SUM(TRY_CAST(n.ead AS FLOAT)) / 1e9 AS ead_mlrd
FROM [CL_PORTFOLIO].[dbo].[AQR2025_B1A_2024_Q4] n
WHERE n.is_del = '0'
  AND TRY_CAST(n.debtor_type AS FLOAT) = 0
  AND TRY_CAST(n.debtor_se AS FLOAT) = 0
  AND (n.portfolio = 'Mortgage' OR TRY_CAST(n.collateral AS FLOAT) = 1)
GROUP BY n.portfolio, TRY_CAST(n.collateral AS FLOAT)
ORDER BY ead_mlrd DESC
OPTION (MAXDOP 1);


/* --- Q8. ПОРОГ ИНДИВИДУАЛЬНОЙ ЗНАЧИМОСТИ (замечание 6) ----------------------
   Что смотрим: сколько заёмщиков проходят порог 0,2 % капитала при значении,
   зашитом в скрипте, и сколько прошли бы при капитале на текущую отчётную дату.
   Подставить актуальный капитал вместо @capital_now.
   Что делать: вынести порог в параметр.                                    */

DECLARE @capital_script FLOAT = 461235157000.0;   -- зашито в скрипте, на 01.01.2025
DECLARE @capital_now    FLOAT = 461235157000.0;   -- ПОДСТАВИТЬ капитал на отчётную дату

-- iin_bin используется только для группировки внутри CTE;
-- наружу возвращаются исключительно агрегаты, идентификаторы не выводятся.
WITH by_borrower AS (
    SELECT n.iin_bin,
           SUM(COALESCE(TRY_CAST(n.od AS FLOAT), 0)
             + COALESCE(TRY_CAST(n.od_del AS FLOAT), 0)
             + COALESCE(TRY_CAST(n.interest AS FLOAT), 0)
             + COALESCE(TRY_CAST(n.interest_del AS FLOAT), 0)
             + COALESCE(TRY_CAST(n.correction AS FLOAT), 0)
             + COALESCE(TRY_CAST(n.disc_prem AS FLOAT), 0)
             + COALESCE(TRY_CAST(n.penalty AS FLOAT), 0)) AS amount
    FROM [CL_PORTFOLIO].[dbo].[AQR2025_B1A_2024_Q4] n
    WHERE n.is_del = '0'
    GROUP BY n.iin_bin
)
SELECT SUM(CASE WHEN amount >= @capital_script * 0.002 THEN 1 ELSE 0 END) AS borrowers_by_script,
       SUM(CASE WHEN amount >= @capital_now    * 0.002 THEN 1 ELSE 0 END) AS borrowers_by_now,
       SUM(CASE WHEN amount >= @capital_script * 0.002 THEN amount ELSE 0 END) / 1e9 AS amount_by_script_mlrd,
       SUM(CASE WHEN amount >= @capital_now    * 0.002 THEN amount ELSE 0 END) / 1e9 AS amount_by_now_mlrd
FROM by_borrower
OPTION (MAXDOP 1);


/* --- Q9. ПОРТФЕЛИ ВНЕ ПЕРИМЕТРА КРЕДИТНОГО РИСКА (замечание 11) -------------
   Что смотрим: попадают ли в расчёт займы финансовым институтам и
   государственным структурам — по Таблице 3 они в кредитном риске
   не анализируются.
   Что делать: при наличии — исключать из расчёта метрик кредитного риска.  */

SELECT n.portfolio,
       COUNT(*)                            AS cnt,
       SUM(TRY_CAST(n.ead AS FLOAT)) / 1e9 AS ead_mlrd
FROM [CL_PORTFOLIO].[dbo].[AQR2025_B1A_2024_Q4] n
WHERE n.is_del = '0'
GROUP BY n.portfolio
ORDER BY ead_mlrd DESC
OPTION (MAXDOP 1);


/* --- Q10. СВЕРКА С ФАЙЛОМ СЕГМЕНТАЦИИ ---------------------------------------
   Что смотрим: совпадает ли число сегментированных займов в таблице
   с присланной выгрузкой (729 787 строк, семь кодов сегментов).
   Что делать: расхождение означает, что выгрузка сделана по другому
   периметру или другой версией скрипта.                                    */

SELECT fg.segment_afr, COUNT(*) AS cnt
FROM [personal_tables].[dbo].[RA_NST_segment_AQR2025] fg
GROUP BY fg.segment_afr
ORDER BY cnt DESC;
