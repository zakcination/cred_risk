/*==============================================================================
  DWH_PROBE_H15_STANDALONE — H15 (достаточность обеспечения под 90+), автономно.

  ЗАЧЕМ ОТДЕЛЬНЫМ ФАЙЛОМ. 09.08 прогон L3B встал на H15 и не вернулся. Батчи
  до него (H13a/H13b/H14) отработали, то есть материализация была уже готова —
  значит дело в самом H15, а не в подготовке данных. Этот файл пересобирает
  ТОЛЬКО то, что нужно H15, под собственными именами `#h15_*`, чтобы его можно
  было запустить прямо сейчас, не переигрывая весь L3B.

  ДИАГНОЗ. H15 и H06 (L3A, отработал штатно) джойнят одно и то же — последний
  срез `loan_account` к агрегату `pledges` по `c_loan_gid = la_gid`. Разница
  ровно одна: в H15 между источником и фильтром стоит

      CROSS APPLY (VALUES (…), (…)) d(dpd_definition, is_90)
      WHERE d.is_90 = 1

  Конструктор VALUES ссылается на внешнюю колонку, поэтому предикат `is_90 = 1`
  вычисляется ПОСЛЕ размножения. План получается такой: прочитать весь
  последний срез (все четыре источника целиком), для КАЖДОЙ строки сходить
  вложенным циклом в `#pl_sum`, размножить результат вдвое — и только потом
  выбросить 99% как не-90+. Полезных строк здесь считанные проценты: работа
  делается над полным портфелем ради выборки просрочки.

  ЧТО ИЗМЕНЕНО. Фильтр поднят к источнику. Второе определение — строгий
  ПОДМНОЖЕСТВО первого (`dpd - 1 > 90` ⇔ `dpd > 91`), поэтому один предикат
  `days_past_due > @Dpd` отбирает обе выборки сразу, а различие между ними
  считается уже на отобранном (маленьком) наборе. Цифры от этого не меняются —
  меняется объём работы: залоги подтягиваются к 90+, а не портфель к залогам.

  ЧТО ЕЩЁ. `MAX(c_reporting_date)` вынесён в переменную: в исходнике он стоял
  подзапросом в WHERE, то есть `pledges` читались дважды.

  Проверяемая гипотеза: H15 висел из-за порядка «размножить → сджойнить →
  отфильтровать», а не из-за объёма `pledges` или типов ключей.
  Опровергается так: если батч 0 покажет РАЗНЫЕ типы `la_gid` и `c_loan_gid`,
  то настоящая причина — неявный CONVERT на индексной стороне джойна
  (non-sargable, класс ошибки L11.1/L4.1), и правка порядка не поможет.

  Правила: только SELECT, `#temp`, MAXDOP 1, без PII (только агрегаты),
  трёхчастные имена, пороги — параметрами.
==============================================================================*/

/*------------------------------------------------------------------------------
  БАТЧ 0 — ТИПЫ КЛЮЧЕЙ ДЖОЙНА. Обязателен перед выводами: если типы разошлись,
  все рассуждения про порядок операций не имеют значения.
  Имя БД в INFORMATION_SCHEMA обязательно — по умолчанию сессия сидит в
  CL_PORTFOLIO, и двухчастное имя вернёт 0 строк БЕЗ ошибки.
------------------------------------------------------------------------------*/
SELECT 'H15_KEY_TYPES' AS scenario,
       TABLE_NAME, COLUMN_NAME, DATA_TYPE,
       NUMERIC_PRECISION, NUMERIC_SCALE, CHARACTER_MAXIMUM_LENGTH
FROM [Dictionaries].INFORMATION_SCHEMA.COLUMNS
WHERE (TABLE_NAME = 'loan_account' AND COLUMN_NAME IN ('la_gid', 'la_source',
                                                       'days_past_due',
                                                       'total_balance_debt',
                                                       'la_reporting_date'))
   OR (TABLE_NAME = 'pledges'      AND COLUMN_NAME IN ('c_loan_gid', 'c_source',
                                                       'c_collateral_value',
                                                       'c_collateral_type',
                                                       'c_reporting_date'))
ORDER BY TABLE_NAME, COLUMN_NAME;
GO

/*==============================================================================
  БАТЧ 1 — H15.
==============================================================================*/
DECLARE @Suite varchar(20) = 'L3-H15';
DECLARE @Dpd   int = 90;          -- порог просрочки, не хардкод в теле
DECLARE @Rows  bigint;

/*------------------------------------------------------------------------------
  Шаг 1. Последняя дата КАЖДОГО источника отдельно (T35): у S03 срез на месяц
  свежее остальных, единая «максимальная дата» молча обнулила бы три источника.
------------------------------------------------------------------------------*/
IF OBJECT_ID('tempdb..#h15_srclast') IS NOT NULL DROP TABLE #h15_srclast;
SELECT la_source, MAX(la_reporting_date) AS last_date
INTO #h15_srclast
FROM [Dictionaries].[risk_analytics].[loan_account]
GROUP BY la_source
OPTION (MAXDOP 1);
SET @Rows = @@ROWCOUNT;
CREATE CLUSTERED INDEX ix_h15_srclast ON #h15_srclast(la_source);
SELECT @Suite AS suite, 'STEP1_SRC_LAST' AS step, @Rows AS rows_built;

SELECT @Suite AS suite, 'STEP1b_DATES' AS step, la_source, last_date
FROM #h15_srclast ORDER BY la_source;

/*------------------------------------------------------------------------------
  Шаг 2. ТОЛЬКО просрочка 90+ последнего среза. Здесь и была вся разница:
  фильтр применяется к источнику, до всякого размножения и джойна залогов.
  `days_past_due - 1 > @Dpd` — подмножество `days_past_due > @Dpd`, поэтому
  одного предиката достаточно для обоих определений.
------------------------------------------------------------------------------*/
IF OBJECT_ID('tempdb..#h15_90') IS NOT NULL DROP TABLE #h15_90;
SELECT a.la_source, a.la_gid, a.days_past_due,
       ISNULL(a.total_balance_debt, 0) AS exposure
INTO #h15_90
FROM [Dictionaries].[risk_analytics].[loan_account] a
JOIN #h15_srclast k
  ON  k.la_source = a.la_source
  AND k.last_date = a.la_reporting_date
WHERE a.days_past_due > @Dpd
OPTION (MAXDOP 1);
SET @Rows = @@ROWCOUNT;
CREATE CLUSTERED INDEX ix_h15_90 ON #h15_90(la_gid);
SELECT @Suite AS suite, 'STEP2_DPD90_ROWS' AS step, @Rows AS rows_built;

/*------------------------------------------------------------------------------
  Шаг 3. Залоги на последнюю дату. Дата — в переменную: подзапросом в WHERE
  таблица читалась бы дважды.

  По S01 из суммы исключены поручительство и страховой полис: это не залог
  имущества, и в непокрытой экспозиции им не место (D4.2/T6). Группировка по
  одному `c_loan_gid` — gid глобально уникален, префикс несёт источник, так что
  размножения строк при джойне не будет.
------------------------------------------------------------------------------*/
DECLARE @PledgeDate date =
        (SELECT MAX(c_reporting_date) FROM [Dictionaries].[risk_analytics].[pledges]);
SELECT @Suite AS suite, 'STEP3a_PLEDGE_DATE' AS step, @PledgeDate AS pledge_date;

IF OBJECT_ID('tempdb..#h15_pl') IS NOT NULL DROP TABLE #h15_pl;
SELECT c_loan_gid,
       SUM(CASE WHEN c_source = 'S01'
                 AND c_collateral_type IN (N'Поручительство', N'Страховой полис')
                THEN 0 ELSE ISNULL(c_collateral_value, 0) END) AS pledge_property_only
INTO #h15_pl
FROM [Dictionaries].[risk_analytics].[pledges]
WHERE c_reporting_date = @PledgeDate
GROUP BY c_loan_gid
OPTION (MAXDOP 1);
SET @Rows = @@ROWCOUNT;
CREATE CLUSTERED INDEX ix_h15_pl ON #h15_pl(c_loan_gid);
SELECT @Suite AS suite, 'STEP3b_PLEDGE_ROWS' AS step, @Rows AS rows_built;

/*------------------------------------------------------------------------------
  Шаг 4. Экспозиция и залог на отобранных 90+.
------------------------------------------------------------------------------*/
IF OBJECT_ID('tempdb..#h15_base') IS NOT NULL DROP TABLE #h15_base;
SELECT a.la_source, a.days_past_due, a.exposure,
       ISNULL(p.pledge_property_only, 0) AS pledge
INTO #h15_base
FROM #h15_90 a
LEFT JOIN #h15_pl p ON p.c_loan_gid = a.la_gid
OPTION (MAXDOP 1);
SET @Rows = @@ROWCOUNT;
SELECT @Suite AS suite, 'STEP4_BASE_ROWS' AS step, @Rows AS rows_built;

/*==============================================================================
  H15 — РЕЗУЛЬТАТ. Два определения 90+ рядом: T13 (off-by-one) двигает
  регуляторно значимую цифру напрямую, и расхождение между строками — это и
  есть цена вопроса. Размножение вдвое здесь безвредно: набор уже маленький.

  S01 помечен отдельно: по нему стоимость залога непригодна (D4.2), и число
  «непокрытой экспозиции» по S01 читать нельзя — оно попадает в вывод только
  чтобы отсутствие строки не приняли за отсутствие проблемы.
==============================================================================*/
SELECT @Suite AS suite, 'H15_UNCOVERED_EXPOSURE_90PLUS' AS scenario,
       source, dpd_definition,
       COUNT_BIG(*) AS contracts_90plus,
       CAST(SUM(exposure) AS decimal(38,2)) AS exposure_90plus,
       CAST(SUM(pledge)   AS decimal(38,2)) AS pledge_value,
       CAST(SUM(CASE WHEN exposure > pledge THEN exposure - pledge ELSE 0 END)
            AS decimal(38,2)) AS uncovered_exposure,
       SUM(CASE WHEN pledge = 0 THEN 1 ELSE 0 END) AS contracts_without_pledge,
       CASE WHEN source = 'S01' THEN N'НЕ ИСПОЛЬЗОВАТЬ — D4.2' ELSE N'' END AS trust_note
FROM (
    SELECT b.la_source AS source, d.dpd_definition, b.exposure, b.pledge
    FROM #h15_base b
    CROSS APPLY (VALUES
        (N'days_past_due > 90 (сырое поле)', CASE WHEN b.days_past_due     > @Dpd THEN 1 ELSE 0 END),
        (N'days_past_due - 1 > 90 (T13)',    CASE WHEN b.days_past_due - 1 > @Dpd THEN 1 ELSE 0 END)
    ) d(dpd_definition, is_90)
    WHERE d.is_90 = 1
) x
GROUP BY source, dpd_definition
ORDER BY source, dpd_definition
OPTION (MAXDOP 1);

/*------------------------------------------------------------------------------
  УБОРКА. Строго после последнего обращения к таблицам — 09.08 правка уборки
  попала в блок материализации и `#src_last` был удалён за семь строк до
  джойна по нему (Msg 208).
------------------------------------------------------------------------------*/
IF OBJECT_ID('tempdb..#h15_srclast') IS NOT NULL DROP TABLE #h15_srclast;
IF OBJECT_ID('tempdb..#h15_90')      IS NOT NULL DROP TABLE #h15_90;
IF OBJECT_ID('tempdb..#h15_pl')      IS NOT NULL DROP TABLE #h15_pl;
IF OBJECT_ID('tempdb..#h15_base')    IS NOT NULL DROP TABLE #h15_base;
