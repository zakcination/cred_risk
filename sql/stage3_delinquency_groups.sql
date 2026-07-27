/* =============================================================================
   ПРОСТЫМ ЯЗЫКОМ:
   Апгрейд помесячного отчёта по пулу Стадии 3. Для каждого займа:
   (1) DPD по месяцам + флаг «была ли просрочка» по месяцам (0/1);
   (2) «группа» — последовательность номеров месяцев, где была просрочка,
       например «@345» = просрочка была в 3-м, 4-м и 5-м наблюдаемых месяцах;
   (3) ВАЖНО про природу DPD: если займ просрочен ПОДРЯД несколько месяцев,
       raw dpd не «сбрасывается» — он растёт примерно на ~30/31 день за месяц,
       пока не заплатят. То есть dpd=63 на 3-м месяце подряд просрочки — это
       НЕ «очень серьёзный займ», а просто изначальный срыв в 5 дней, который
       никто не гасил 3 месяца. Поэтому raw MAX(dpd) вводит в заблуждение при
       сравнении займов с разной длиной «пробега» просрочки.
   Решение: разбиваем просрочку каждого займа на ЭПИЗОДЫ (непрерывные пробеги
   месяцев подряд). Для первого эпизода берём DPD НАЧАЛА эпизода —
   first_episode_start_dpd — это и есть настоящая «изначальная» просрочка, не
   раздутая накоплением дней. Отдельно храним длину самого длинного эпизода
   (сколько месяцев подряд не платили) — это отдельный сигнал хроничности.
   Потом по каждой «группе» (@345, @25, @CLEAN, …) считаем количество займов
   и квартили (q25/медиана/q75) ОБОИХ метрик — сырой (max_dpd_raw, раздутой) и
   исправленной (first_episode_start_dpd) — чтобы наглядно видеть завышение и
   осознанно выбирать порог n для смягчения правил оздоровления.
   -----------------------------------------------------------------------------
   Stage 3 delinquency-pattern groups — per-loan monthly flags + episode-aware
   severity, and per-group quantile distributions to inform the relax threshold.

   PREREQUISITE: run sql/stage3_cure_pool.sql first, IN THE SAME SESSION — this
   script reads the ##STAGE3_CURE_POOL_HEAD / ##STAGE3_CURE_POOL_DPD global temp
   tables it builds.

   Month numbering: month_no = month_idx + 1 (1-based, WINDOW-relative — "month 1"
   is the first observed calendar month, i.e. @MonthFrom from the pool build, not
   literally January). A group label like '@345' means "delinquent in the 3rd,
   4th and 5th observed months of the window" — read alongside default_date /
   cure_date for calendar context.

   Two result sets:
     (1) Per-loan report — dpd + flag per month, group label, episode metrics.
     (2) Per-group distribution — count, balance, q25/median/q75 of both the raw
         and the episode-corrected severity metric.
   T-SQL (Microsoft SQL Server 2017+ for STRING_AGG / PERCENTILE_CONT).
   ============================================================================= */

-------------------------------------------------------------------------------
-- 0. Per (contract, month) delinquency flag. NULL dpd -> NULL flag (no data;
--    excluded from both the group label and episode detection — a missing
--    snapshot is neither "clean" nor "delinquent", it's simply unobserved).
-------------------------------------------------------------------------------
;WITH flagged AS (
    SELECT
        d.contract_number,
        d.month_idx,
        d.month_idx + 1                                          AS month_no,   -- 1-based, window-relative
        d.[dpd],
        CASE WHEN d.[dpd] IS NULL THEN NULL
             WHEN d.[dpd] > 0 THEN 1 ELSE 0 END                   AS is_delinquent
    FROM ##STAGE3_CURE_POOL_DPD d
),

-------------------------------------------------------------------------------
-- 1. Group label per loan: concatenated month numbers where delinquent,
--    e.g. '345'. Loans with zero delinquent months get 'CLEAN' explicitly (a
--    LEFT JOIN keeps them — they must not silently disappear from the group
--    breakdown, they are the largest and most important group).
-------------------------------------------------------------------------------
delinquent_months AS (
    SELECT contract_number, month_no, [dpd]
    FROM flagged
    WHERE is_delinquent = 1
),
loan_group AS (
    SELECT
        h.contract_number,
        '@' + ISNULL(dm_agg.pattern, 'CLEAN')      AS delinquency_group,
        ISNULL(dm_agg.n_delinquent_months, 0)      AS delinquent_months_count,
        dm_agg.max_dpd_raw
    FROM ##STAGE3_CURE_POOL_HEAD h
    OUTER APPLY (
        SELECT
            STRING_AGG(CAST(month_no AS varchar(2)), '') WITHIN GROUP (ORDER BY month_no) AS pattern,
            COUNT(*)   AS n_delinquent_months,
            MAX([dpd]) AS max_dpd_raw
        FROM delinquent_months dm
        WHERE dm.contract_number = h.contract_number
    ) dm_agg
),

-------------------------------------------------------------------------------
-- 2. Episodes: consecutive-run islands of delinquent months per loan
--    (gaps-and-islands via month_no − ROW_NUMBER()). One row per episode.
-------------------------------------------------------------------------------
delinquent_runs AS (
    SELECT contract_number, month_no, [dpd],
           month_no - ROW_NUMBER() OVER (PARTITION BY contract_number ORDER BY month_no) AS grp
    FROM delinquent_months
),
episode_bounds AS (
    SELECT contract_number, grp,
           MIN(month_no) AS ep_start_no,
           MAX(month_no) AS ep_end_no,
           COUNT(*)      AS ep_len
    FROM delinquent_runs
    GROUP BY contract_number, grp
),
episodes AS (
    SELECT
        eb.contract_number, eb.grp, eb.ep_start_no, eb.ep_end_no, eb.ep_len,
        ds.[dpd] AS ep_start_dpd,
        de.[dpd] AS ep_end_dpd
    FROM episode_bounds eb
    JOIN delinquent_runs ds ON ds.contract_number = eb.contract_number AND ds.month_no = eb.ep_start_no
    JOIN delinquent_runs de ON de.contract_number = eb.contract_number AND de.month_no = eb.ep_end_no
),
episodes_ranked AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY contract_number ORDER BY ep_start_no)                AS rn_first,
        ROW_NUMBER() OVER (PARTITION BY contract_number ORDER BY ep_len DESC, ep_start_no)    AS rn_longest
    FROM episodes
),

-------------------------------------------------------------------------------
-- 3. Per-loan episode rollup: number of episodes, the FIRST episode's start
--    DPD (the corrected "true initial lateness" metric), and the LONGEST
--    episode's length + implied avg. monthly increment (sanity check: an
--    increment near 30-31 confirms "one continuous unpaid month, compounding",
--    not a genuinely worsening pattern).
-------------------------------------------------------------------------------
episode_stats AS (
    SELECT contract_number, COUNT(*) AS n_episodes
    FROM episodes GROUP BY contract_number
),
first_episode AS (
    SELECT contract_number, ep_start_dpd AS first_episode_start_dpd, ep_len AS first_episode_length
    FROM episodes_ranked WHERE rn_first = 1
),
longest_episode AS (
    SELECT contract_number, ep_len AS worst_episode_length, ep_start_dpd, ep_end_dpd
    FROM episodes_ranked WHERE rn_longest = 1
),
loan_severity AS (
    SELECT
        lg.contract_number,
        lg.delinquency_group,
        lg.delinquent_months_count,
        lg.max_dpd_raw,
        ISNULL(es.n_episodes, 0)                              AS n_episodes,
        fe.first_episode_start_dpd,
        ISNULL(le.worst_episode_length, 0)                    AS worst_episode_length,
        CASE WHEN le.worst_episode_length >= 2
             THEN (le.ep_end_dpd - le.ep_start_dpd) * 1.0 / (le.worst_episode_length - 1)
        END                                                   AS avg_monthly_increment_longest_episode
    FROM loan_group lg
    LEFT JOIN episode_stats  es ON es.contract_number = lg.contract_number
    LEFT JOIN first_episode  fe ON fe.contract_number = lg.contract_number
    LEFT JOIN longest_episode le ON le.contract_number = lg.contract_number
)

-------------------------------------------------------------------------------
-- (1) PER-LOAN REPORT — the upgraded version of the original pivot: dpd AND
--     delinquency-flag per month, plus the group label and episode metrics.
-------------------------------------------------------------------------------
SELECT
    d.contract_number,
    h.default_date,
    h.cure_date,
    h.balance,
    ls.delinquency_group,
    ls.delinquent_months_count,
    ls.max_dpd_raw,
    ls.n_episodes,
    ls.first_episode_start_dpd,             -- <- corrected severity metric (use THIS to set thresholds)
    ls.worst_episode_length,
    ls.avg_monthly_increment_longest_episode,
    -- raw DPD by month
    MAX(CASE WHEN d.month_idx = 0 THEN d.[dpd] END) AS [dpd_m1],
    MAX(CASE WHEN d.month_idx = 1 THEN d.[dpd] END) AS [dpd_m2],
    MAX(CASE WHEN d.month_idx = 2 THEN d.[dpd] END) AS [dpd_m3],
    MAX(CASE WHEN d.month_idx = 3 THEN d.[dpd] END) AS [dpd_m4],
    MAX(CASE WHEN d.month_idx = 4 THEN d.[dpd] END) AS [dpd_m5],
    MAX(CASE WHEN d.month_idx = 5 THEN d.[dpd] END) AS [dpd_m6],
    MAX(CASE WHEN d.month_idx = 6 THEN d.[dpd] END) AS [dpd_m7],
    -- delinquency flag by month (1 = dpd>0, 0 = dpd=0, NULL = no snapshot)
    MAX(CASE WHEN d.month_idx = 0 THEN CASE WHEN d.[dpd] IS NULL THEN NULL WHEN d.[dpd] > 0 THEN 1 ELSE 0 END END) AS [flag_m1],
    MAX(CASE WHEN d.month_idx = 1 THEN CASE WHEN d.[dpd] IS NULL THEN NULL WHEN d.[dpd] > 0 THEN 1 ELSE 0 END END) AS [flag_m2],
    MAX(CASE WHEN d.month_idx = 2 THEN CASE WHEN d.[dpd] IS NULL THEN NULL WHEN d.[dpd] > 0 THEN 1 ELSE 0 END END) AS [flag_m3],
    MAX(CASE WHEN d.month_idx = 3 THEN CASE WHEN d.[dpd] IS NULL THEN NULL WHEN d.[dpd] > 0 THEN 1 ELSE 0 END END) AS [flag_m4],
    MAX(CASE WHEN d.month_idx = 4 THEN CASE WHEN d.[dpd] IS NULL THEN NULL WHEN d.[dpd] > 0 THEN 1 ELSE 0 END END) AS [flag_m5],
    MAX(CASE WHEN d.month_idx = 5 THEN CASE WHEN d.[dpd] IS NULL THEN NULL WHEN d.[dpd] > 0 THEN 1 ELSE 0 END END) AS [flag_m6],
    MAX(CASE WHEN d.month_idx = 6 THEN CASE WHEN d.[dpd] IS NULL THEN NULL WHEN d.[dpd] > 0 THEN 1 ELSE 0 END END) AS [flag_m7]
FROM ##STAGE3_CURE_POOL_DPD d
JOIN ##STAGE3_CURE_POOL_HEAD h ON h.contract_number = d.contract_number
JOIN loan_severity ls          ON ls.contract_number = d.contract_number
GROUP BY d.contract_number, h.default_date, h.cure_date, h.balance,
         ls.delinquency_group, ls.delinquent_months_count, ls.max_dpd_raw,
         ls.n_episodes, ls.first_episode_start_dpd, ls.worst_episode_length,
         ls.avg_monthly_increment_longest_episode
ORDER BY h.balance DESC;


-------------------------------------------------------------------------------
-- (2) PER-GROUP DISTRIBUTION — count, balance, and quantiles of BOTH the raw
--     (inflated) and the episode-corrected severity metric, per pattern group.
--     Compare the two metrics per row: a big gap between raw and corrected
--     medians means the group's "severity" is mostly elapsed time, not
--     genuine badness — exactly what determines a sensible relax threshold.
-------------------------------------------------------------------------------
SELECT DISTINCT
    ls.delinquency_group,
    COUNT(*) OVER (PARTITION BY ls.delinquency_group)                                   AS loans_in_group,
    SUM(h.balance) OVER (PARTITION BY ls.delinquency_group)                             AS balance_in_group,
    -- raw (naive, inflated by run length)
    PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY ls.max_dpd_raw)
        OVER (PARTITION BY ls.delinquency_group)                                        AS raw_q25,
    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY ls.max_dpd_raw)
        OVER (PARTITION BY ls.delinquency_group)                                        AS raw_median,
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY ls.max_dpd_raw)
        OVER (PARTITION BY ls.delinquency_group)                                        AS raw_q75,
    -- episode-corrected (true initial lateness, first episode only)
    PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY ls.first_episode_start_dpd)
        OVER (PARTITION BY ls.delinquency_group)                                        AS corrected_q25,
    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY ls.first_episode_start_dpd)
        OVER (PARTITION BY ls.delinquency_group)                                        AS corrected_median,
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY ls.first_episode_start_dpd)
        OVER (PARTITION BY ls.delinquency_group)                                        AS corrected_q75,
    AVG(ls.worst_episode_length) OVER (PARTITION BY ls.delinquency_group)               AS avg_worst_episode_length
FROM loan_severity ls
JOIN ##STAGE3_CURE_POOL_HEAD h ON h.contract_number = ls.contract_number
ORDER BY loans_in_group DESC, delinquency_group;

-------------------------------------------------------------------------------
-- Notes
-------------------------------------------------------------------------------
-- * PREREQUISITE: run sql/stage3_cure_pool.sql first, in the SAME session (the
--   ## global temp tables only live while that session stays open).
-- * The +30/31 mechanic: dpd on a snapshot that is STILL unpaid since the prior
--   snapshot is (roughly) prior_dpd + days-between-snapshots — it is a running
--   day-count, not an independent monthly reading. So MAX(dpd) over a
--   multi-month consecutive run reports mostly ELAPSED TIME, not how bad the
--   original miss was. first_episode_start_dpd fixes this: it is the dpd value
--   at the FIRST month of the run, before any compounding.
-- * worst_episode_length is the complementary signal: HOW LONG they stayed
--   unpaid (chronicity), independent of how big the initial miss was. Use both
--   together — e.g. a good relax rule might require first_episode_start_dpd <=n
--   AND worst_episode_length <= a small cap (a long run, even from a tiny
--   start, means they never actually cured within the window).
-- * avg_monthly_increment_longest_episode near 30-31 CONFIRMS a continuous
--   unpaid run (matches the "+30/31 days" mechanic exactly); a value far from
--   that (much smaller, e.g. partial catch-up, or much larger) is a data-quality
--   or definition flag worth a manual look.
-- * Group label months are WINDOW-relative (month_no = month_idx+1, 1 = the
--   first observed month = @MonthFrom from the pool build), not calendar month
--   numbers — pair with default_date/cure_date for calendar context.
-- * NULL dpd (missing snapshot) is excluded from both the group label and
--   episode detection — it neither confirms nor breaks a run. A loan with gaps
--   can therefore show an artificially short/split episode if a snapshot is
--   missing mid-run; cross-check delinquent_months_count vs. months_observed
--   (section A of stage3_cure_pool.sql) if that matters for a specific loan.
-- * STRING_AGG / PERCENTILE_CONT require SQL Server 2017+. On older versions,
--   replace STRING_AGG with the classic FOR XML PATH('') trick, and compute
--   quantiles via PERCENT_RANK()/NTILE() or pull loan_severity into the client
--   (e.g. the CSV from scripts/stage3_dpd_chart.py) and quantile there instead.
