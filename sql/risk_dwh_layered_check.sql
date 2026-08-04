/* =============================================================================
   ПРОСТЫМ ЯЗЫКОМ:
   Большой послойный тест нового DWH (`Dictionaries.risk_analytics`) против
   старой ветки (`CL_PORTFOLIO.dbo`). Слои идут в жёстком порядке: сначала то,
   на чём стоит всё остальное (схема → мастер-таблица → активный периметр →
   деньги), и только потом риск-параметры и витрины. Если нижний слой не прошёл,
   верхние всё равно считаются, НО в отчёте помечаются «доверять нельзя» —
   потому что сумма, посчитанная поверх размноженного JOIN, выглядит как число,
   но числом не является.
   -----------------------------------------------------------------------------
   RISK_DWH_LAYERED_CHECK — dependency-ordered verification of the new mart
   =============================================================================

   ПОЧЕМУ ИМЕННО ТАКОЙ ПОРЯДОК (это главное в этом файле, а не сами запросы)
   -----------------------------------------------------------------------------
   Порядок слоёв продиктован НАЗНАЧЕНИЕМ таблиц и тем, что из чего следует.
   Каждый слой отвечает на вопрос, без ответа на который следующий слой
   бессмысленен:

     L0  СХЕМА/ДОМЕНЫ    Можно ли вообще джойнить? Типы ключей, домен source,
                         выравнивание отчётных дат. До первого JOIN.
                         → без этого любой JOIN — лотерея (l_borrower_id
                           varchar(255) против b_borrower_id bigint).

     L1  loans           МАСТЕР-хребет. Всё остальное висит на нём. Здесь и
                         только здесь решается grain и уникальность ключа.
                         → дубли тут = размножение сумм ВЕЗДЕ ниже (DWH-08:
                           70 дублей S01 удваивали 197,6 млн ₸).

     L2  loans_active    Что вообще считается «живым договором». Бизнес
                         подтвердил: это полный перечень активных.
                         → определяет периметр обязательств для L3+: чего
                           обязано хватать в деньгах, залогах, графике.

     L3  loan_account    ДЕНЬГИ на отчётную дату (25 счетов ГК).
                         → сюда приходят все балансовые вопросы; но считать
                           их можно только после L1/L2, иначе «пропажа»
                           неотличима от выбитого ключа.

     L4  borrower        КЛИЕНТ: ИИН/БИН, атрибуты, без которых нет ни
                         регуляторной отчётности, ни группы связанных.
                         → ссылочная целостность loans → borrower.

     L5  ПЕРИМЕТР old↔new  Собственно вопрос миграции: кто потерялся.
                         Ключ РАЗНЫЙ по источникам — это доказано, не выбор
                         вкуса (S17 contract_id опровергнут: до 33 договоров
                         на один id).
                         → до L5 мы проверяли новую ветку саму по себе;
                           с L5 начинается сравнение с эталоном.

     L6  БАЛАНС на MATCHED  Сходятся ли деньги там, где договор есть с обеих
                         сторон. Отдельно от L5: «нет договора» и «есть
                         договор, но сумма другая» — разные дефекты с разными
                         адресатами.

     L7  ПРОВИЗИИ       Регуляторная цифра. 1428/1845/18770/18771/1877.
                         → только после L6: расхождение провизий при
                           расходящемся балансе неинтерпретируемо.

     L8  DPD и 90+      Стадирование IFRS 9 и NPL. Самая дефектная зона.
                         → после L7, потому что 90+ двигает и провизии;
                           разбирать их одновременно — терять причинность.

     L9  ЗАЛОГИ         LGD. Связь только через c_source+c_loan_gid
                         (l_collateral_id опровергнут как универсальный FK).

     L10 РЕЗОЛЮШН       writeoff/collections/offbalance/bankrupt — выходы из
                         портфеля. Домен структурно ограничен S01/S03.
                         → идёт после периметра: «нет строки» здесь легитимно
                           для S02/S17, и путать это с дефектом нельзя.

     L11 ГРАФИК/ПЛАТЕЖИ repayment_schedule + payments — поведенческая
                         альтернатива сломанному DPD (единственный путь
                         посчитать просрочку, не доверяя days_past_due).

     L12 ПЕРИФЕРИЯ      ratings, interest_rates, guarantees, credit_lines,
                         refinance, restructuring_v2 — не блокируют go-live
                         балансового контура, поэтому в конце.

     L13 brm_all_data   Финальная витрина. Проверяется последней, потому что
                         она — следствие всего вышеперечисленного.

   ПРАВИЛО ПЕРЕХОДА (CLAUDE.md): не углубляться, пока предыдущий виток не
   закрыт ПРИЧИНОЙ, а не числом. Скрипт это не может заставить, поэтому он
   делает следующее лучшее: считает всё, но в итоговом отчёте столбец
   TRUST_LEVEL показывает, опирается ли результат на непройденный слой.

   СОБЛЮДЕНИЕ ПРАВИЛ CLAUDE.md
   -----------------------------------------------------------------------------
     * Только SELECT. Ни одного INSERT/UPDATE/DELETE в постоянные объекты —
       пишем ТОЛЬКО в ## temp.
     * MAXDOP 1 на каждом тяжёлом запросе.
     * PII не выводится: ни одного номера договора, ИИН, IBAN, ФИО. Только
       COUNT/SUM и бакеты по величине. Там, где нужен «худший случай», он
       показан как бакет магнитуды, а не как идентификатор.
     * tolerance / даты / source — параметры в §0, не хардкод в теле.
     * Нормализация НЕ вшита в JOIN (доказано: сырой ключ = нормализованный,
       259 905 = 259 905; UPPER/LTRIM на обеих сторонах делает JOIN
       non-sargable). Нормализация — отдельной проверкой L0.6, разово.
     * LOW_TEMPDB: блоки последовательные, каждый ## temp удаляется сразу
       после использования. Причина — на объединённом proof-скрипте 17.07
       TEMPDB был заполнен тяжёлым историческим JOIN.
     * Дубли считаются на СЫРОМ уровне. Промежуточный GROUP BY (source,key)
       перед COUNT(*)=COUNT(DISTINCT key) — тавтология, проверка гарантированно
       проходит КОНСТРУКЦИЕЙ запроса. Стоило времени 17.07 (PR #14 отозван).

   ОПТИМИЗАЦИЯ ПЕРЕД ПРОГОНОМ №2 (04.08.2026)
   -----------------------------------------------------------------------------
     Найдено и исправлено ДО прогона, не по результатам прогона №1 — правки
     не меняют ни один verdict, только число сканов и время выполнения:
     * L7.3 и L8.1 сканировали loan_account ЧЕТЫРЕ раза каждый (по разу на
       счёт/поле, склеенные UNION ALL) вместо одного прохода с несколькими
       агрегатами. Схлопнуто в 1 скан на проверку через CROSS APPLY VALUES.
     * #act (L2) и #la (L3) — локальные #temp, не #act/#la ##-глобальные —
       не удалялись явно после использования, в отличие от #l1 (L1), и
       переживали остаток прогона в tempdb без необходимости. Добавлен
       DROP TABLE сразу после последнего использования — тот же паттерн,
       что уже был в L1, и то же обоснование, что и LOW_TEMPDB выше.

   ПРОГРЕСС-БАННЕРЫ: ДВЕ ПРАВКИ ПОСЛЕ ПЕРВОГО ДОБАВЛЕНИЯ (04.08.2026)
   -----------------------------------------------------------------------------
     1. Первая версия клала подсчёт строк прямо в PRINT: PRINT ... +
        CONVERT(nvarchar(10),(SELECT COUNT(*) FROM ##RDW_RESULTS)) — падало
        с Msg 1046 «Subqueries are not allowed in this context», потому что
        PRINT не принимает подзапрос в выражении. Исправлено: подзапрос
        вынесен в отдельный DECLARE @RowsSoFar int = (SELECT COUNT(*) ...),
        в PRINT остаётся только переменная.
     2. После исправления (1) баннеры не падали, но и не показывались —
        PRINT не гарантирует немедленную доставку клиенту, буферизуется
        сервером до конца батча (GO) или заполнения буфера, а весь смысл
        баннера — видеть его ДО того, как слой закончится. Заменено на
        RAISERROR(msg, 0, 1) WITH NOWAIT: severity 0 — не ошибка, WITH
        NOWAIT — форсирует немедленную отправку.

   КАК ЗАПУСКАТЬ
   -----------------------------------------------------------------------------
     1. Целиком — если tempdb позволяет. Иначе по слоям: каждый слой
        самодостаточен, общий накопитель ##RDW_RESULTS переживает GO.
     2. Один источник за раз: @SourceFilter = N'S02' (самый тяжёлый).
     3. Итог — §REPORT в конце: по слоям, с TRUST_LEVEL и списком блокеров.
     4. Результаты переносить на BI-холст (bi_canvas/dwh_schema_explorer.html)
        как status процесса: verified / proven / hypothesis / refuted.
     5. Прогресс — вкладка Messages (SSMS), не grid: RAISERROR(...,0,1) WITH
        NOWAIT в начале каждого слоя (время, +секунд от старта, накоплено
        строк в ##RDW_RESULTS) — по нему видно, что скрипт считает L8, а не
        завис. Не PRINT: PRINT не гарантирует немедленную доставку клиенту
        (буферизуется до конца батча/GO), WITH NOWAIT — гарантирует.

   Cross-db (CL_PORTFOLIO ↔ Dictionaries) работает только на одном инстансе.
   Если падает — это находка, а не ошибка скрипта (нужен linked server).

   T-SQL (Microsoft SQL Server).
   ============================================================================= */


/* =============================================================================
   §0. ПАРАМЕТРЫ И НАКОПИТЕЛЬ РЕЗУЛЬТАТОВ
   ============================================================================= */
SET NOCOUNT ON;

DECLARE @AsOf           date          = '2026-07-01';   -- отчётная дата среза
DECLARE @PrevAsOf       date          = '2026-06-01';   -- предыдущая (для лаг-тестов)
DECLARE @Tolerance      decimal(18,2) = 0.01;           -- допуск сверки сумм, ₸
DECLARE @SourceFilter   nvarchar(10)  = NULL;           -- NULL = все; иначе 'S01'/'S02'/'S03'/'S17'
DECLARE @MinBase        int           = 30;             -- ниже этой базы доля — шум, не метрика
DECLARE @DpdOffByOne    int           = 1;              -- документированная off-by-one: old = new − 1
DECLARE @NinetyPlus     int           = 90;             -- граница 90+
DECLARE @ValueRatioFlag decimal(18,4) = 10.0;           -- во сколько раз расхождение оценки залога считается аномалией

/* Накопитель. ## (глобальный) — чтобы пережить GO и запуск по слоям.
   Это temp-объект, не постоянный: правило read-only не нарушено. */
IF OBJECT_ID('tempdb..##RDW_RESULTS') IS NOT NULL DROP TABLE ##RDW_RESULTS;
CREATE TABLE ##RDW_RESULTS (
    layer_no        int            NOT NULL,   -- L0..L13
    layer_name      nvarchar(60)   NOT NULL,
    check_id        nvarchar(30)   NOT NULL,   -- L1.3 и т.п.
    target_object   nvarchar(120)  NOT NULL,   -- какая таблица/связь проверяется
    check_name      nvarchar(300)  NOT NULL,
    source_system   nvarchar(10)   NULL,       -- NULL = все источники
    metric_name     nvarchar(80)   NOT NULL,
    metric_value    decimal(38,4)  NULL,
    expected_value  nvarchar(80)   NULL,       -- что считается «пройдено»
    verdict         nvarchar(12)   NOT NULL,   -- PASS / FAIL / WARN / NO_BASE / INFO
    is_gate         bit            NOT NULL,   -- блокирует ли доверие к следующим слоям
    note            nvarchar(600)  NULL
);

/* Единая точка записи: почему verdict именно такой, видно рядом с метрикой. */
IF OBJECT_ID('tempdb..##RDW_PARAMS') IS NOT NULL DROP TABLE ##RDW_PARAMS;
CREATE TABLE ##RDW_PARAMS (name nvarchar(40) PRIMARY KEY, value nvarchar(60));
INSERT INTO ##RDW_PARAMS(name,value) VALUES
    (N'AsOf', CONVERT(nvarchar(10),@AsOf,120)),
    (N'PrevAsOf', CONVERT(nvarchar(10),@PrevAsOf,120)),
    (N'Tolerance', CONVERT(nvarchar(30),@Tolerance)),
    (N'SourceFilter', ISNULL(@SourceFilter,N'(все)')),
    (N'MinBase', CONVERT(nvarchar(30),@MinBase)),
    (N'NinetyPlus', CONVERT(nvarchar(30),@NinetyPlus)),
    /* RunStart в ##RDW_PARAMS, а не в локальной @-переменной: локальные
       переменные не переживают GO, а этот прогон может идти по слоям
       (см. КАК ЗАПУСКАТЬ выше) — тогда RAISERROR-баннеры в каждом слое
       обязаны читать ОДНО И ТО ЖЕ время старта, а не своё собственное. */
    (N'RunStart', CONVERT(nvarchar(30),GETDATE(),121));

/* ПРОГРЕСС 04.08.2026: RAISERROR(...,0,1) WITH NOWAIT в начале каждого слоя —
   время, сколько секунд от старта, и сколько строк уже накоплено в
   ##RDW_RESULTS. Без этого скрипт на 14 слоях и нескольких cross-db JOIN
   молчит от запуска до самого конца: отличить «ещё считает L8» от «завис»
   никак нельзя, пока не увидишь либо результат, либо таймаут.
   Не PRINT: PRINT буферизуется сервером и может не дойти до клиента,
   пока не заполнится буфер или не закончится батч (GO) — на батче в
   14 слоёв это означает «тишина до самого конца», то есть ту же проблему,
   которую эта секция должна решать. WITH NOWAIT форсирует немедленную
   отправку сообщения клиенту. Каждое сообщение — в Messages, а не в grid,
   поэтому отчётам (§REPORT) не мешает. */
RAISERROR(N'=== RISK_DWH_LAYERED_CHECK начат: ' + CONVERT(nvarchar(19),GETDATE(),120)
    + N' | AsOf=' + CONVERT(nvarchar(10),@AsOf,120)
    + N' | SourceFilter=' + ISNULL(@SourceFilter,N'(все)') + N' ===', 0, 1) WITH NOWAIT;


/* =============================================================================
   L0. СХЕМА И ДОМЕНЫ — ДО ЛЮБОГО JOIN
   -----------------------------------------------------------------------------
   Назначение слоя: доказать, что джойнить вообще можно. Несовпадение типов
   ключей — это не «мелочь стиля»: неявное приведение делает JOIN
   non-sargable и меняет семантику сравнения (varchar '007' ≠ bigint 7).
   ============================================================================= */

DECLARE @RunStart datetime = (SELECT CONVERT(datetime,value,121) FROM ##RDW_PARAMS WHERE name=N'RunStart');
DECLARE @RowsSoFar int = (SELECT COUNT(*) FROM ##RDW_RESULTS);
RAISERROR(N'[L0 схема и домены] начало -- ' + CONVERT(nvarchar(19),GETDATE(),120)
    + N' (+' + CONVERT(nvarchar(10),DATEDIFF(SECOND,@RunStart,GETDATE())) + N' с от старта), строк в отчёте: '
    + CONVERT(nvarchar(10),@RowsSoFar), 0, 1) WITH NOWAIT;

-- L0.1 Существуют ли все ожидаемые таблицы (инвентарь 19 + 10)
IF OBJECT_ID('tempdb..#exp') IS NOT NULL DROP TABLE #exp;
CREATE TABLE #exp (db_name sysname, schema_name sysname, table_name sysname, expected_role nvarchar(60));
INSERT INTO #exp VALUES
 (N'Dictionaries',N'risk_analytics',N'loans',              N'L1 мастер'),
 (N'Dictionaries',N'risk_analytics',N'loans_active',       N'L2 активный периметр'),
 (N'Dictionaries',N'risk_analytics',N'loan_account',       N'L3 деньги'),
 (N'Dictionaries',N'risk_analytics',N'borrower',           N'L4 клиент'),
 (N'Dictionaries',N'risk_analytics',N'pledges',            N'L9 залоги'),
 (N'Dictionaries',N'risk_analytics',N'writeoff',           N'L10 резолюшн'),
 (N'Dictionaries',N'risk_analytics',N'collections',        N'L10 резолюшн'),
 (N'Dictionaries',N'risk_analytics',N'offbalance',         N'L10 резолюшн'),
 (N'Dictionaries',N'risk_analytics',N'bankrupt',           N'L10 резолюшн'),
 (N'Dictionaries',N'risk_analytics',N'repayment_schedule', N'L11 график'),
 (N'Dictionaries',N'risk_analytics',N'payments',           N'L11 платежи'),
 (N'Dictionaries',N'risk_analytics',N'payments_wiring',    N'L11 платежи'),
 (N'Dictionaries',N'risk_analytics',N'restructuring_v2',   N'L12 периферия'),
 (N'Dictionaries',N'risk_analytics',N'ratings',            N'L12 периферия'),
 (N'Dictionaries',N'risk_analytics',N'interest_rates',     N'L12 периферия'),
 (N'Dictionaries',N'risk_analytics',N'guarantees',         N'L12 периферия'),
 (N'Dictionaries',N'risk_analytics',N'credit_lines',       N'L12 периферия'),
 (N'Dictionaries',N'risk_analytics',N'refinance',          N'L12 периферия'),
 (N'Dictionaries',N'risk_analytics',N'brm_all_data',       N'L13 витрина'),
 (N'CL_PORTFOLIO', N'dbo',          N'PORTFOLIO_RS',                      N'эталон S01'),
 (N'CL_PORTFOLIO', N'dbo',          N'PORTFOLIO_RS_7130',                 N'эталон S01 (меморандум)'),
 (N'CL_PORTFOLIO', N'dbo',          N'CL_PORTFOLIO_2',                    N'эталон S03'),
 (N'CL_PORTFOLIO', N'dbo',          N'PORTFOLIO_Fenix',                   N'эталон S17'),
 (N'CL_PORTFOLIO', N'dbo',          N'PORTFOLIO_CREDITCARDS_WAY4',        N'эталон S02'),
 (N'CL_PORTFOLIO', N'dbo',          N'PORTFOLIO_CREDITCARDS_MIGR_WAY4',   N'эталон S02'),
 (N'CL_PORTFOLIO', N'dbo',          N'PORTFOLIO_CREDITCARDS_SMART_CARD',  N'эталон S02'),
 (N'CL_PORTFOLIO', N'dbo',          N'PORTFOLIO_OFF_BALANCE',             N'эталон забаланс'),
 (N'CL_PORTFOLIO', N'dbo',          N'spis_v_ubytok_CL',                  N'эталон списаний S03'),
 (N'CL_PORTFOLIO', N'dbo',          N'spis_v_ubytok_RS',                  N'эталон списаний S01');

INSERT INTO ##RDW_RESULTS
SELECT 0, N'L0 схема и домены', N'L0.1', e.db_name+N'.'+e.schema_name+N'.'+e.table_name,
       N'Таблица существует и доступна ('+e.expected_role+N')', NULL,
       N'exists', CASE WHEN t.TABLE_NAME IS NULL THEN 0 ELSE 1 END, N'1',
       CASE WHEN t.TABLE_NAME IS NULL THEN N'FAIL' ELSE N'PASS' END,
       1,
       CASE WHEN t.TABLE_NAME IS NULL
            THEN N'Таблицы нет ИЛИ нет прав ИЛИ cross-db недоступен. Это разные причины — различить до выводов.'
            ELSE NULL END
FROM #exp e
LEFT JOIN (
    SELECT N'Dictionaries' AS db_name, TABLE_SCHEMA, TABLE_NAME FROM [Dictionaries].INFORMATION_SCHEMA.TABLES
    UNION ALL
    SELECT N'CL_PORTFOLIO',            TABLE_SCHEMA, TABLE_NAME FROM [CL_PORTFOLIO].INFORMATION_SCHEMA.TABLES
) t ON t.db_name = e.db_name AND t.TABLE_SCHEMA = e.schema_name AND t.TABLE_NAME = e.table_name
OPTION (MAXDOP 1);
DROP TABLE #exp;

-- L0.2 Типы ключевых колонок: несовпадение = скрытое приведение в JOIN
IF OBJECT_ID('tempdb..#keytypes') IS NOT NULL DROP TABLE #keytypes;
SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH, NUMERIC_PRECISION
INTO #keytypes
FROM [Dictionaries].INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = N'risk_analytics'
  AND COLUMN_NAME IN (N'l_loan_id', N'la_loan_id', N'l_gid', N'la_gid', N'l_borrower_id',
                      N'b_borrower_id', N'rs_borrower_id', N'l_collateral_id', N'c_collateral_id',
                      N'c_loan_gid', N'c_loan_id', N'l_loan_number', N'la_dog_num', N'rs_loan_id')
OPTION (MAXDOP 1);

/* Пары, которые реально джойнятся. Сравниваем типы попарно. */
INSERT INTO ##RDW_RESULTS
SELECT 0, N'L0 схема и домены', N'L0.2', p.pair_name,
       N'Совместимость типов ключа: '+ISNULL(a.DATA_TYPE,N'?')+N' ↔ '+ISNULL(b.DATA_TYPE,N'?'), NULL,
       N'types_match', CASE WHEN a.DATA_TYPE = b.DATA_TYPE THEN 1 ELSE 0 END, N'1',
       CASE WHEN a.DATA_TYPE IS NULL OR b.DATA_TYPE IS NULL THEN N'WARN'
            WHEN a.DATA_TYPE = b.DATA_TYPE THEN N'PASS' ELSE N'FAIL' END,
       1,
       CASE WHEN a.DATA_TYPE <> b.DATA_TYPE
            THEN N'Разные типы ⇒ неявное приведение: JOIN становится non-sargable, а сравнение меняет семантику (varchar «007» ≠ bigint 7). Джойнить можно, доверять — нет.'
            ELSE NULL END
FROM (VALUES
        (N'loans.l_loan_id ↔ loan_account.la_loan_id',   N'loans',N'l_loan_id',      N'loan_account',N'la_loan_id'),
        (N'loans.l_gid ↔ loan_account.la_gid',           N'loans',N'l_gid',          N'loan_account',N'la_gid'),
        (N'loans.l_borrower_id ↔ borrower.b_borrower_id',N'loans',N'l_borrower_id',  N'borrower',    N'b_borrower_id'),
        (N'loans.l_gid ↔ pledges.c_loan_gid',            N'loans',N'l_gid',          N'pledges',     N'c_loan_gid'),
        (N'loans.l_collateral_id ↔ pledges.c_collateral_id', N'loans',N'l_collateral_id',N'pledges', N'c_collateral_id'),
        (N'loans.l_loan_number ↔ loan_account.la_dog_num',N'loans',N'l_loan_number',  N'loan_account',N'la_dog_num'),
        (N'loans.l_loan_id ↔ repayment_schedule.rs_loan_id', N'loans',N'l_loan_id',   N'repayment_schedule',N'rs_loan_id')
     ) p(pair_name, ta, ca, tb, cb)
LEFT JOIN #keytypes a ON a.TABLE_NAME = p.ta AND a.COLUMN_NAME = p.ca
LEFT JOIN #keytypes b ON b.TABLE_NAME = p.tb AND b.COLUMN_NAME = p.cb
OPTION (MAXDOP 1);
DROP TABLE #keytypes;

-- L0.3 Объявленные ограничения PK/UNIQUE/FK. Пусто = все ключи логические (Issue #8)
INSERT INTO ##RDW_RESULTS
SELECT 0, N'L0 схема и домены', N'L0.3', N'Dictionaries.risk_analytics (вся схема)',
       N'Объявленных PK/UNIQUE/FK в БД', NULL,
       N'constraint_count', COUNT_BIG(*), N'>0 желательно',
       CASE WHEN COUNT_BIG(*) = 0 THEN N'WARN' ELSE N'INFO' END, 0,
       N'0 ограничений = БД НЕ защищает уникальность; дубли L1 физически возможны и должны проверяться данными каждый прогон. Это подтверждение Issue #8, а не новость.'
FROM [Dictionaries].INFORMATION_SCHEMA.TABLE_CONSTRAINTS
WHERE TABLE_SCHEMA = N'risk_analytics' AND CONSTRAINT_TYPE IN (N'PRIMARY KEY',N'UNIQUE',N'FOREIGN KEY')
OPTION (MAXDOP 1);

-- L0.4 Домен source: один ли словарь во всех таблицах новой ветки
IF OBJECT_ID('tempdb..#srcdom') IS NOT NULL DROP TABLE #srcdom;
CREATE TABLE #srcdom (tbl nvarchar(40), src nvarchar(20), n bigint);
INSERT INTO #srcdom SELECT N'loans',        l_source,  COUNT_BIG(*) FROM [Dictionaries].[risk_analytics].[loans]        WHERE l_report_date  = @AsOf GROUP BY l_source;
INSERT INTO #srcdom SELECT N'loans_active', l_source,  COUNT_BIG(*) FROM [Dictionaries].[risk_analytics].[loans_active] WHERE l_report_date  = @AsOf GROUP BY l_source;
INSERT INTO #srcdom SELECT N'loan_account', la_source, COUNT_BIG(*) FROM [Dictionaries].[risk_analytics].[loan_account] WHERE la_reporting_date = @AsOf GROUP BY la_source;
INSERT INTO #srcdom SELECT N'pledges',      c_source,  COUNT_BIG(*) FROM [Dictionaries].[risk_analytics].[pledges]      WHERE c_reporting_date = @AsOf GROUP BY c_source;
INSERT INTO #srcdom SELECT N'borrower',     b_source,  COUNT_BIG(*) FROM [Dictionaries].[risk_analytics].[borrower]     WHERE b_report_date  = @AsOf GROUP BY b_source;

INSERT INTO ##RDW_RESULTS
SELECT 0, N'L0 схема и домены', N'L0.4', N'домен source по таблицам',
       N'Значений source вне ожидаемого словаря {S01,S02,S03,S17}', s.src,
       N'rows_with_unexpected_source', SUM(s.n), N'0',
       CASE WHEN SUM(s.n) > 0 THEN N'WARN' ELSE N'PASS' END, 0,
       N'Незнакомый source ломает ЛЮБУЮ пер-сорсную сверку ниже: строки просто выпадут из группировок и будут выглядеть как отсутствие данных.'
FROM #srcdom s
WHERE s.src NOT IN (N'S01',N'S02',N'S03',N'S17')
GROUP BY s.src
HAVING SUM(s.n) > 0
OPTION (MAXDOP 1);

-- Явный PASS, если исключений нет (иначе строка просто не появится и это читается как «не проверяли»)
IF NOT EXISTS (SELECT 1 FROM #srcdom WHERE src NOT IN (N'S01',N'S02',N'S03',N'S17'))
    INSERT INTO ##RDW_RESULTS VALUES
    (0, N'L0 схема и домены', N'L0.4', N'домен source по таблицам',
     N'Значений source вне словаря {S01,S02,S03,S17}', NULL,
     N'rows_with_unexpected_source', 0, N'0', N'PASS', 0,
     N'Домен source единый во всех проверенных таблицах — подтверждает предпосылку всех пер-сорсных сверок ниже.');
DROP TABLE #srcdom;

-- L0.5 Выравнивание отчётных дат: month-start или нет
IF OBJECT_ID('tempdb..#dates') IS NOT NULL DROP TABLE #dates;
CREATE TABLE #dates (tbl nvarchar(40), non_month_start bigint, total bigint, min_d date, max_d date);
INSERT INTO #dates
SELECT N'loans', SUM(CASE WHEN DAY(l_report_date) <> 1 THEN 1 ELSE 0 END), COUNT_BIG(*), MIN(l_report_date), MAX(l_report_date)
FROM [Dictionaries].[risk_analytics].[loans];
INSERT INTO #dates
SELECT N'loan_account', SUM(CASE WHEN DAY(la_reporting_date) <> 1 THEN 1 ELSE 0 END), COUNT_BIG(*), MIN(la_reporting_date), MAX(la_reporting_date)
FROM [Dictionaries].[risk_analytics].[loan_account];

INSERT INTO ##RDW_RESULTS
SELECT 0, N'L0 схема и домены', N'L0.5', N'Dictionaries.'+tbl,
       N'Отчётные даты не выровнены на начало месяца', NULL,
       N'rows_not_month_start', non_month_start, N'0',
       CASE WHEN non_month_start > 0 THEN N'FAIL' ELSE N'PASS' END, 1,
       N'Невыровненная дата = срез не сматчится с эталоном по дате, и разница периметра будет ложной. Диапазон: '
       + CONVERT(nvarchar(10),min_d,120) + N' … ' + CONVERT(nvarchar(10),max_d,120)
FROM #dates
OPTION (MAXDOP 1);
DROP TABLE #dates;

-- L0.6 Нужна ли нормализация ключа (разово, НЕ в JOIN — иначе non-sargable)
INSERT INTO ##RDW_RESULTS
SELECT 0, N'L0 схема и домены', N'L0.6', N'loans.l_loan_number',
       N'Изменила бы нормализация ключа число уникальных значений', NULL,
       N'raw_distinct_minus_normalized_distinct',
       COUNT(DISTINCT l_loan_number) - COUNT(DISTINCT UPPER(LTRIM(RTRIM(l_loan_number)))), N'0',
       CASE WHEN COUNT(DISTINCT l_loan_number) = COUNT(DISTINCT UPPER(LTRIM(RTRIM(l_loan_number))))
            THEN N'PASS' ELSE N'WARN' END, 0,
       N'Разово. Если 0 — нормализацию в JOIN вшивать НЕЛЬЗЯ (доказано: 259 905 = 259 905, а UPPER/LTRIM на обеих сторонах вешает запрос).'
FROM [Dictionaries].[risk_analytics].[loans]
WHERE l_report_date = @AsOf
OPTION (MAXDOP 1);
GO


/* =============================================================================
   L1. МАСТЕР-ХРЕБЕТ `loans`
   -----------------------------------------------------------------------------
   Назначение таблицы: единственный мастер договоров. Источник l_borrower_id,
   l_collateral_id, продуктовых атрибутов и самого факта существования договора.
   Бизнес-смысл слоя: если здесь дубль — размножается ВСЁ, что джойнится к
   loans, и любая сумма ниже завышена кратно. Поэтому это первый слой после
   схемы и главный гейт скрипта.
   ============================================================================= */

DECLARE @RunStart datetime = (SELECT CONVERT(datetime,value,121) FROM ##RDW_PARAMS WHERE name=N'RunStart');
DECLARE @RowsSoFar int = (SELECT COUNT(*) FROM ##RDW_RESULTS);
RAISERROR(N'[L1 мастер loans] начало -- ' + CONVERT(nvarchar(19),GETDATE(),120)
    + N' (+' + CONVERT(nvarchar(10),DATEDIFF(SECOND,@RunStart,GETDATE())) + N' с от старта), строк в отчёте: '
    + CONVERT(nvarchar(10),@RowsSoFar), 0, 1) WITH NOWAIT;
DECLARE @AsOf date = (SELECT CONVERT(date,value) FROM ##RDW_PARAMS WHERE name=N'AsOf');
DECLARE @SourceFilter nvarchar(10) = NULLIF((SELECT value FROM ##RDW_PARAMS WHERE name=N'SourceFilter'), N'(все)');

/* L1.1 Grain. ВАЖНО: дубли считаются на СЫРОМ уровне.
   Антипаттерн, которого здесь нет: сгруппировать по (source,key), а потом
   сравнить COUNT(*) с COUNT(DISTINCT key) — такой тест проходит ВСЕГДА,
   потому что подзапрос физически не может вернуть больше строки на ключ. */
IF OBJECT_ID('tempdb..#l1') IS NOT NULL DROP TABLE #l1;
SELECT l_source, l_gid, l_loan_id, l_loan_number, COUNT_BIG(*) AS rows_in_group
INTO #l1
FROM [Dictionaries].[risk_analytics].[loans]
WHERE l_report_date = @AsOf
  AND (@SourceFilter IS NULL OR l_source = @SourceFilter)
GROUP BY l_source, l_gid, l_loan_id, l_loan_number
OPTION (MAXDOP 1);

INSERT INTO ##RDW_RESULTS
SELECT 1, N'L1 мастер loans', N'L1.1', N'loans (source,gid,loan_id,loan_number)',
       N'Полные дубли: лишних СЫРЫХ строк сверх одной на ключ', l_source,
       N'excess_raw_rows', SUM(rows_in_group) - COUNT_BIG(*), N'0',
       CASE WHEN SUM(rows_in_group) - COUNT_BIG(*) > 0 THEN N'FAIL' ELSE N'PASS' END, 1,
       N'Считано как SUM(строк в группе) − число групп, т.е. на сыром уровне. DWH-08: 70 лишних строк S01 удваивали 197 602 096,26 ₸ при прямом JOIN к loan_account.'
FROM #l1 GROUP BY l_source
OPTION (MAXDOP 1);

/* L1.2 Выбор ключа ПО ПОКРЫТИЮ, а не по названию колонки.
   Проверяем каждого кандидата на уникальность отдельно. */
INSERT INTO ##RDW_RESULTS
SELECT 1, N'L1 мастер loans', N'L1.2', N'loans — кандидат ключа '+k.key_name,
       N'Договоров на одно значение ключа (максимум)', NULL,
       N'max_rows_per_key', k.max_per_key, N'1',
       CASE WHEN k.max_per_key = 1 THEN N'PASS' ELSE N'FAIL' END, 0,
       N'Имя колонки ≠ семантика. Ключ выбирается по покрытию и уникальности, а не потому что называется id.'
FROM (
    SELECT N'(l_source,l_gid)' AS key_name,
           (SELECT MAX(c) FROM (SELECT COUNT_BIG(*) c FROM #l1 GROUP BY l_source,l_gid) x) AS max_per_key
    UNION ALL
    SELECT N'(l_source,l_loan_id)',
           (SELECT MAX(c) FROM (SELECT COUNT_BIG(*) c FROM #l1 GROUP BY l_source,l_loan_id) x)
    UNION ALL
    SELECT N'(l_source,l_loan_number)',
           (SELECT MAX(c) FROM (SELECT COUNT_BIG(*) c FROM #l1 GROUP BY l_source,l_loan_number) x)
    UNION ALL
    SELECT N'l_loan_number БЕЗ source (заведомо плохой — контроль)',
           (SELECT MAX(c) FROM (SELECT COUNT_BIG(*) c FROM #l1 GROUP BY l_loan_number) x)
) k
OPTION (MAXDOP 1);

/* L1.3 Коллизии номера договора МЕЖДУ источниками — почему source обязателен в ключе */
INSERT INTO ##RDW_RESULTS
SELECT 1, N'L1 мастер loans', N'L1.3', N'loans.l_loan_number',
       N'Номеров договора, встречающихся более чем в одном source', NULL,
       N'cross_source_collisions', COUNT_BIG(*), N'справочно (ожидается ~9 659)',
       N'INFO', 0,
       N'Это НЕ дефект — это причина, по которой любой JOIN обязан включать source. Скрипт, джойнящий по contract_number в одиночку, склеит несвязанные займы.'
FROM (
    SELECT l_loan_number FROM #l1 GROUP BY l_loan_number HAVING COUNT(DISTINCT l_source) > 1
) c
OPTION (MAXDOP 1);

/* L1.4 Пустые ключи — строка без ключа не найдётся ничем и выглядит как «пропажа» */
INSERT INTO ##RDW_RESULTS
SELECT 1, N'L1 мастер loans', N'L1.4', N'loans (ключевые поля)',
       N'Строк с пустым source / gid / loan_id / loan_number', NULL,
       N'rows_with_null_key',
       SUM(CASE WHEN l_source IS NULL OR l_gid IS NULL OR l_loan_id IS NULL
                  OR l_loan_number IS NULL OR LTRIM(RTRIM(l_loan_number)) = N'' THEN rows_in_group ELSE 0 END),
       N'0',
       CASE WHEN SUM(CASE WHEN l_source IS NULL OR l_gid IS NULL OR l_loan_id IS NULL
                            OR l_loan_number IS NULL OR LTRIM(RTRIM(l_loan_number)) = N'' THEN rows_in_group ELSE 0 END) > 0
            THEN N'FAIL' ELSE N'PASS' END, 1,
       N'Строка без ключа не находится ни одним JOIN — в отчёте она неотличима от «договор отсутствует».'
FROM #l1
OPTION (MAXDOP 1);
DROP TABLE #l1;
GO


/* =============================================================================
   L2. АКТИВНЫЙ ПЕРИМЕТР `loans_active`
   -----------------------------------------------------------------------------
   Назначение таблицы: бизнесом ПОДТВЕРЖДЁН как полный перечень действующих
   договоров. Именно он определяет, чего обязано хватать во всех слоях ниже:
   деньги, залог, график, платежи — всё меряется относительно этого периметра.
   Бизнес-смысл слоя: пока не доказано loans_active ⊆ loans, «пропажа» в L3
   неотличима от того, что договора нет в мастере вовсе.
   ============================================================================= */

DECLARE @RunStart datetime = (SELECT CONVERT(datetime,value,121) FROM ##RDW_PARAMS WHERE name=N'RunStart');
DECLARE @RowsSoFar int = (SELECT COUNT(*) FROM ##RDW_RESULTS);
RAISERROR(N'[L2 активный периметр] начало -- ' + CONVERT(nvarchar(19),GETDATE(),120)
    + N' (+' + CONVERT(nvarchar(10),DATEDIFF(SECOND,@RunStart,GETDATE())) + N' с от старта), строк в отчёте: '
    + CONVERT(nvarchar(10),@RowsSoFar), 0, 1) WITH NOWAIT;
DECLARE @AsOf date = (SELECT CONVERT(date,value) FROM ##RDW_PARAMS WHERE name=N'AsOf');
DECLARE @SourceFilter nvarchar(10) = NULLIF((SELECT value FROM ##RDW_PARAMS WHERE name=N'SourceFilter'), N'(все)');

IF OBJECT_ID('tempdb..#act') IS NOT NULL DROP TABLE #act;
SELECT l_source, l_loan_id, l_gid, l_loan_number,
       MAX(l_loan_status)        AS l_loan_status,
       MAX(l_actual_closure_date) AS l_actual_closure_date,
       MAX(l_loan_open_date)      AS l_loan_open_date,
       MAX(l_funding_date)        AS l_funding_date,
       COUNT_BIG(*)               AS rows_in_group
INTO #act
FROM [Dictionaries].[risk_analytics].[loans_active]
WHERE l_report_date = @AsOf
  AND (@SourceFilter IS NULL OR l_source = @SourceFilter)
GROUP BY l_source, l_loan_id, l_gid, l_loan_number
OPTION (MAXDOP 1);

-- L2.1 Дубли активного слоя (сырой уровень)
INSERT INTO ##RDW_RESULTS
SELECT 2, N'L2 активный периметр', N'L2.1', N'loans_active',
       N'Лишних сырых строк сверх одной на (source,loan_id,gid,номер)', l_source,
       N'excess_raw_rows', SUM(rows_in_group) - COUNT_BIG(*), N'0',
       CASE WHEN SUM(rows_in_group) - COUNT_BIG(*) > 0 THEN N'FAIL' ELSE N'PASS' END, 1,
       N'DWH-06: один полный технический дубль S02 уже находили. Завышает активный периметр и каждую долю, посчитанную от него.'
FROM #act GROUP BY l_source
OPTION (MAXDOP 1);

-- L2.2 Ссылочная целостность: активный ⊆ мастер (регрессия «586 714 из 586 714»)
INSERT INTO ##RDW_RESULTS
SELECT 2, N'L2 активный периметр', N'L2.2', N'loans_active → loans',
       N'Активных договоров, отсутствующих в мастере loans', a.l_source,
       N'active_not_in_master', COUNT_BIG(*), N'0',
       CASE WHEN COUNT_BIG(*) > 0 THEN N'FAIL' ELSE N'PASS' END, 1,
       N'Ранее подтверждено: все 586 714 активных loan_id найдены в мастере. Это регрессия — если цифра сдвинулась, потери возникли ДО master/active слоя.'
FROM #act a
WHERE NOT EXISTS (
    SELECT 1 FROM [Dictionaries].[risk_analytics].[loans] m
    WHERE m.l_report_date = @AsOf AND m.l_source = a.l_source AND m.l_loan_id = a.l_loan_id)
GROUP BY a.l_source
OPTION (MAXDOP 1);

INSERT INTO ##RDW_RESULTS
SELECT 2, N'L2 активный периметр', N'L2.2b', N'loans_active → loans',
       N'Всего активных договоров в периметре (база для всех долей ниже)', NULL,
       N'active_total', COUNT_BIG(*), N'справочно', N'INFO', 0,
       N'Знаменатель для L3/L9/L11. Печатается явно, чтобы доля «сверено» ниже не читалась в отрыве от базы.'
FROM #act
OPTION (MAXDOP 1);

-- L2.3 Противоречие: активный договор с проставленной датой фактического закрытия
INSERT INTO ##RDW_RESULTS
SELECT 2, N'L2 активный периметр', N'L2.3', N'loans_active.l_actual_closure_date',
       N'Активных договоров с заполненной датой фактического закрытия', l_source,
       N'active_with_closure_date', COUNT_BIG(*), N'0',
       CASE WHEN COUNT_BIG(*) > 0 THEN N'WARN' ELSE N'PASS' END, 0,
       N'Внутреннее противоречие слоя: договор одновременно «активен» и «закрыт». DWH-07: один такой с остатком 1 000,00 ₸ уже находили.'
FROM #act WHERE l_actual_closure_date IS NOT NULL
GROUP BY l_source
OPTION (MAXDOP 1);

-- L2.4 Хронология дат
INSERT INTO ##RDW_RESULTS
SELECT 2, N'L2 активный периметр', N'L2.4', N'loans_active (даты)',
       N'Нарушений хронологии: открытие > фондирование, либо даты позже отчётной', l_source,
       N'date_chronology_violations',
       SUM(CASE WHEN (l_loan_open_date IS NOT NULL AND l_funding_date IS NOT NULL AND l_loan_open_date > l_funding_date)
                  OR l_loan_open_date > @AsOf OR l_funding_date > @AsOf THEN 1 ELSE 0 END),
       N'0',
       CASE WHEN SUM(CASE WHEN (l_loan_open_date IS NOT NULL AND l_funding_date IS NOT NULL AND l_loan_open_date > l_funding_date)
                            OR l_loan_open_date > @AsOf OR l_funding_date > @AsOf THEN 1 ELSE 0 END) > 0
            THEN N'FAIL' ELSE N'PASS' END, 0,
       N'Ранее нарушений не было — регрессионный контроль.'
FROM #act GROUP BY l_source
OPTION (MAXDOP 1);
DROP TABLE #act;
GO


/* =============================================================================
   L3. ДЕНЬГИ `loan_account`
   -----------------------------------------------------------------------------
   Назначение таблицы: текущий финансовый слой — 25 счетов ГК, баланс,
   провизии, DPD, бакет. Всё, что двигает регуляторную цифру, живёт здесь.
   Подтверждённая связь с мастером: report_date + source + loan_id.
   Бизнес-смысл слоя: здесь впервые появляется сумма в тенге, поэтому все
   дефекты L1/L2 отсюда начинают стоить денег.
   ВНИМАНИЕ: формула баланса РАЗНАЯ по источникам — S17 использует 8 счетов
   (без 1818/1838), S03 — больше. Единой формулы «на всё» нет, и попытка
   применить одну — самостоятельный источник ложных расхождений.
   ============================================================================= */

DECLARE @RunStart datetime = (SELECT CONVERT(datetime,value,121) FROM ##RDW_PARAMS WHERE name=N'RunStart');
DECLARE @RowsSoFar int = (SELECT COUNT(*) FROM ##RDW_RESULTS);
RAISERROR(N'[L3 деньги loan_account] начало -- ' + CONVERT(nvarchar(19),GETDATE(),120)
    + N' (+' + CONVERT(nvarchar(10),DATEDIFF(SECOND,@RunStart,GETDATE())) + N' с от старта), строк в отчёте: '
    + CONVERT(nvarchar(10),@RowsSoFar), 0, 1) WITH NOWAIT;
DECLARE @AsOf date = (SELECT CONVERT(date,value) FROM ##RDW_PARAMS WHERE name=N'AsOf');
DECLARE @Tolerance decimal(18,2) = (SELECT CONVERT(decimal(18,2),value) FROM ##RDW_PARAMS WHERE name=N'Tolerance');
DECLARE @SourceFilter nvarchar(10) = NULLIF((SELECT value FROM ##RDW_PARAMS WHERE name=N'SourceFilter'), N'(все)');

IF OBJECT_ID('tempdb..#la') IS NOT NULL DROP TABLE #la;
SELECT la_source, la_loan_id, la_gid, la_dog_num,
       SUM(TRY_CAST(total_balance_debt     AS decimal(38,2))) AS total_balance_debt,
       SUM(TRY_CAST(principal_balance_debt AS decimal(38,2))) AS principal_balance_debt,
       SUM(TRY_CAST(la_account_1428  AS decimal(38,2)))       AS acc_1428,
       SUM(TRY_CAST(la_account_1845  AS decimal(38,2)))       AS acc_1845,
       SUM(TRY_CAST(la_account_1877  AS decimal(38,2)))       AS acc_1877,
       SUM(TRY_CAST(la_account_18770 AS decimal(38,2)))       AS acc_18770,
       SUM(TRY_CAST(la_account_18771 AS decimal(38,2)))       AS acc_18771,
       MAX(TRY_CAST(days_past_due AS int))                                     AS days_past_due,
       MAX(TRY_CAST(max_days_past_due_principal_interest AS int))              AS max_dpd,
       MAX(TRY_CAST(days_past_due_principal AS int))                           AS dpd_principal,
       MAX(TRY_CAST(days_past_due_interest  AS int))                           AS dpd_interest,
       MAX(TRY_CAST(delinquency_bucket AS nvarchar(50)))                       AS delinquency_bucket,
       COUNT_BIG(*)                                                            AS rows_in_group
INTO #la
FROM [Dictionaries].[risk_analytics].[loan_account]
WHERE la_reporting_date = @AsOf
  AND (@SourceFilter IS NULL OR la_source = @SourceFilter)
GROUP BY la_source, la_loan_id, la_gid, la_dog_num
OPTION (MAXDOP 1);

-- L3.1 Grain финансового слоя (сырой уровень)
INSERT INTO ##RDW_RESULTS
SELECT 3, N'L3 деньги loan_account', N'L3.1', N'loan_account',
       N'Лишних сырых строк сверх одной на (source,loan_id,gid,номер)', la_source,
       N'excess_raw_rows', SUM(rows_in_group) - COUNT_BIG(*), N'0',
       CASE WHEN SUM(rows_in_group) - COUNT_BIG(*) > 0 THEN N'FAIL' ELSE N'PASS' END, 1,
       N'Дубль ЗДЕСЬ завышает баланс напрямую, без всякого JOIN. Отличать от DWH-08, где дубль в loans, а loan_account чист.'
FROM #la GROUP BY la_source
OPTION (MAXDOP 1);

-- L3.2 Покрытие активного периметра деньгами: главный вопрос слоя
INSERT INTO ##RDW_RESULTS
SELECT 3, N'L3 деньги loan_account', N'L3.2', N'loans_active → loan_account',
       N'Активных договоров БЕЗ строки в loan_account', a.l_source,
       N'active_without_money_row', COUNT_BIG(*), N'0',
       CASE WHEN COUNT_BIG(*) > 0 THEN N'FAIL' ELSE N'PASS' END, 1,
       N'НЕ признавать это автоматически потерей баланса: часть таких договоров имеет нулевой остаток в старой ветке. Сумму даёт L5.4, где сверяется с эталоном. Ранее из 240 309 подтверждён ОДИН реальный пропуск на 7 192 116,63 ₸ (DWH-01).'
FROM (SELECT l_source, l_loan_id FROM [Dictionaries].[risk_analytics].[loans_active]
      WHERE l_report_date = @AsOf AND (@SourceFilter IS NULL OR l_source = @SourceFilter)
      GROUP BY l_source, l_loan_id) a
WHERE NOT EXISTS (SELECT 1 FROM #la m WHERE m.la_source = a.l_source AND m.la_loan_id = a.l_loan_id)
GROUP BY a.l_source
OPTION (MAXDOP 1);

-- L3.3 Обратное направление: деньги без мастера (осиротевший финансовый факт)
INSERT INTO ##RDW_RESULTS
SELECT 3, N'L3 деньги loan_account', N'L3.3', N'loan_account → loans',
       N'Строк loan_account без соответствия в мастере loans', m.la_source,
       N'money_row_without_master', COUNT_BIG(*), N'0',
       CASE WHEN COUNT_BIG(*) > 0 THEN N'FAIL' ELSE N'PASS' END, 1,
       N'Финансовый факт, не привязанный к договору, невозможно ни атрибутировать клиенту, ни списать. Хуже отсутствия строки.'
FROM #la m
WHERE NOT EXISTS (
    SELECT 1 FROM [Dictionaries].[risk_analytics].[loans] l
    WHERE l.l_report_date = @AsOf AND l.l_source = m.la_source AND l.l_loan_id = m.la_loan_id)
GROUP BY m.la_source
OPTION (MAXDOP 1);

-- L3.4 GL-тождество 1877 = 18770 + 18771 (подтверждено на S01, проверяем везде)
INSERT INTO ##RDW_RESULTS
SELECT 3, N'L3 деньги loan_account', N'L3.4', N'loan_account: 1877 = 18770 + 18771',
       N'Договоров, нарушающих тождество сверх допуска', la_source,
       N'identity_violations',
       SUM(CASE WHEN ABS(ISNULL(acc_1877,0) - (ISNULL(acc_18770,0) + ISNULL(acc_18771,0))) > @Tolerance THEN 1 ELSE 0 END),
       N'0',
       CASE WHEN SUM(CASE WHEN ABS(ISNULL(acc_1877,0) - (ISNULL(acc_18770,0) + ISNULL(acc_18771,0))) > @Tolerance THEN 1 ELSE 0 END) > 0
            THEN N'FAIL' ELSE N'PASS' END, 0,
       N'Тождество ВНУТРИ новой ветки — не требует эталона, поэтому дешёвое и сильное. Подтверждено на S01 (18770=0 на срезе). Нарушение = состав провизий собран иначе, чем задокументировано.'
FROM #la GROUP BY la_source
OPTION (MAXDOP 1);

-- L3.5 NULL против нуля в деньгах: разные вещи, считаем раздельно
INSERT INTO ##RDW_RESULTS
SELECT 3, N'L3 деньги loan_account', N'L3.5', N'loan_account.total_balance_debt',
       N'Договоров с NULL в балансе (не с нулём — именно NULL)', la_source,
       N'balance_is_null', SUM(CASE WHEN total_balance_debt IS NULL THEN 1 ELSE 0 END), N'0',
       CASE WHEN SUM(CASE WHEN total_balance_debt IS NULL THEN 1 ELSE 0 END) > 0 THEN N'WARN' ELSE N'PASS' END, 0,
       N'NULL ≠ 0. SUM() молча игнорирует NULL, и «счёт отсутствует» превращается в «остаток нулевой». Число нулей — отдельной строкой ниже.'
FROM #la GROUP BY la_source
OPTION (MAXDOP 1);

INSERT INTO ##RDW_RESULTS
SELECT 3, N'L3 деньги loan_account', N'L3.5b', N'loan_account.total_balance_debt',
       N'Договоров с РОВНО нулевым балансом (для контраста с NULL выше)', la_source,
       N'balance_is_zero', SUM(CASE WHEN total_balance_debt = 0 THEN 1 ELSE 0 END), N'справочно',
       N'INFO', 0,
       N'Нулевой остаток легитимен (закрытый/выбранный лимит). Смысл строки — не дать слить его с NULL из L3.5.'
FROM #la GROUP BY la_source
OPTION (MAXDOP 1);

-- L3.6 Провизии на договорах с нулевым балансом (S17/WAY4 находили именно так)
INSERT INTO ##RDW_RESULTS
SELECT 3, N'L3 деньги loan_account', N'L3.6', N'loan_account: провизии при нулевом балансе',
       N'Договоров с нулевым остатком и ненулевыми провизиями', la_source,
       N'zero_balance_with_provisions',
       SUM(CASE WHEN ISNULL(total_balance_debt,0) = 0
                 AND ABS(ISNULL(acc_1428,0)+ISNULL(acc_1845,0)+ISNULL(acc_18771,0)) > @Tolerance
                THEN 1 ELSE 0 END),
       N'0 либо объяснено',
       CASE WHEN SUM(CASE WHEN ISNULL(total_balance_debt,0) = 0
                           AND ABS(ISNULL(acc_1428,0)+ISNULL(acc_1845,0)+ISNULL(acc_18771,0)) > @Tolerance
                          THEN 1 ELSE 0 END) > 0 THEN N'WARN' ELSE N'PASS' END, 0,
       N'Резерв под нулевую экспозицию экономического смысла не имеет. По S17 так набрано 1 448 093,75 ₸ на 372 договорах, по WAY4 — 9 268 139,52 ₸ на 590. Вопрос к S2T, не автоматический дефект.'
FROM #la GROUP BY la_source
OPTION (MAXDOP 1);

-- L3.7 Сумма баланса по источникам — база для L5/L6
INSERT INTO ##RDW_RESULTS
SELECT 3, N'L3 деньги loan_account', N'L3.7', N'loan_account (итог по source)',
       N'Совокупный баланс новой ветки', la_source,
       N'sum_total_balance_debt', SUM(ISNULL(total_balance_debt,0)), N'справочно', N'INFO', 0,
       N'Опорная цифра для сверки с эталоном в L6.'
FROM #la GROUP BY la_source
OPTION (MAXDOP 1);
DROP TABLE #la;
GO


/* =============================================================================
   L4. КЛИЕНТ `borrower`
   -----------------------------------------------------------------------------
   Назначение таблицы: ИИН/БИН, тип, резидентность, признаки банкротства и POCI.
   Бизнес-смысл слоя: без клиента нет ни регуляторной отчётности, ни группы
   связанных заёмщиков, ни LGD-сегментации. Идёт после L3, потому что дефект
   тут не двигает баланс напрямую — но блокирует всё, что агрегируется по
   клиенту.
   ============================================================================= */

DECLARE @RunStart datetime = (SELECT CONVERT(datetime,value,121) FROM ##RDW_PARAMS WHERE name=N'RunStart');
DECLARE @RowsSoFar int = (SELECT COUNT(*) FROM ##RDW_RESULTS);
RAISERROR(N'[L4 клиент borrower] начало -- ' + CONVERT(nvarchar(19),GETDATE(),120)
    + N' (+' + CONVERT(nvarchar(10),DATEDIFF(SECOND,@RunStart,GETDATE())) + N' с от старта), строк в отчёте: '
    + CONVERT(nvarchar(10),@RowsSoFar), 0, 1) WITH NOWAIT;
DECLARE @AsOf date = (SELECT CONVERT(date,value) FROM ##RDW_PARAMS WHERE name=N'AsOf');
DECLARE @SourceFilter nvarchar(10) = NULLIF((SELECT value FROM ##RDW_PARAMS WHERE name=N'SourceFilter'), N'(все)');

-- L4.1 Ссылочная целостность loans → borrower (регрессия DWH-13: 53 договора S02)
INSERT INTO ##RDW_RESULTS
SELECT 4, N'L4 клиент borrower', N'L4.1', N'loans.l_borrower_id → borrower.b_borrower_id',
       N'Активных договоров, чей borrower_id не найден в справочнике', a.l_source,
       N'active_loans_without_borrower', COUNT_BIG(*), N'0',
       CASE WHEN COUNT_BIG(*) > 0 THEN N'FAIL' ELSE N'PASS' END, 0,
       N'DWH-13: 53 договора S02. JOIN идёт по приведённому типу — l_borrower_id varchar(255) против b_borrower_id bigint (см. L0.2); часть «пропаж» может оказаться артефактом приведения, а не отсутствием клиента. Проверять оба объяснения.'
FROM (SELECT DISTINCT l_source, l_borrower_id
      FROM [Dictionaries].[risk_analytics].[loans_active]
      WHERE l_report_date = @AsOf AND l_borrower_id IS NOT NULL
        AND (@SourceFilter IS NULL OR l_source = @SourceFilter)) a
WHERE NOT EXISTS (
    SELECT 1 FROM [Dictionaries].[risk_analytics].[borrower] b
    WHERE b.b_report_date = @AsOf
      AND TRY_CAST(b.b_borrower_id AS nvarchar(255)) = TRY_CAST(a.l_borrower_id AS nvarchar(255)))
GROUP BY a.l_source
OPTION (MAXDOP 1);

-- L4.2 Активные договоры вообще без borrower_id
INSERT INTO ##RDW_RESULTS
SELECT 4, N'L4 клиент borrower', N'L4.2', N'loans_active.l_borrower_id',
       N'Активных договоров с пустым borrower_id', l_source,
       N'active_loans_null_borrower', COUNT_BIG(*), N'0',
       CASE WHEN COUNT_BIG(*) > 0 THEN N'FAIL' ELSE N'PASS' END, 0,
       N'Отличать от L4.1: тут ссылки нет вовсе, там она есть но не разрешается. Причины и адресаты разные.'
FROM [Dictionaries].[risk_analytics].[loans_active]
WHERE l_report_date = @AsOf AND l_borrower_id IS NULL
  AND (@SourceFilter IS NULL OR l_source = @SourceFilter)
GROUP BY l_source
OPTION (MAXDOP 1);

-- L4.3 Grain справочника клиентов
INSERT INTO ##RDW_RESULTS
SELECT 4, N'L4 клиент borrower', N'L4.3', N'borrower',
       N'Лишних сырых строк сверх одной на b_borrower_id', NULL,
       N'excess_raw_rows', SUM(c) - COUNT_BIG(*), N'0',
       CASE WHEN SUM(c) - COUNT_BIG(*) > 0 THEN N'FAIL' ELSE N'PASS' END, 0,
       N'Дубль клиента размножает договоры при агрегации по клиенту — прямой риск для группы связанных заёмщиков и лимитов концентрации.'
FROM (SELECT b_borrower_id, COUNT_BIG(*) c
      FROM [Dictionaries].[risk_analytics].[borrower]
      WHERE b_report_date = @AsOf GROUP BY b_borrower_id) x
OPTION (MAXDOP 1);

-- L4.4 Формат ИИН/БИН: 12 знаков. Ведущие нули — известное объяснение, НЕ дефект
INSERT INTO ##RDW_RESULTS
SELECT 4, N'L4 клиент borrower', N'L4.4', N'borrower.b_iin_bin',
       N'Клиентов с ИИН/БИН не 12 знаков после нормализации длины', NULL,
       N'iin_bad_length',
       SUM(CASE WHEN b_iin_bin IS NULL THEN 0
                WHEN LEN(LTRIM(RTRIM(b_iin_bin))) <> 12 THEN 1 ELSE 0 END),
       N'0',
       CASE WHEN SUM(CASE WHEN b_iin_bin IS NULL THEN 0
                          WHEN LEN(LTRIM(RTRIM(b_iin_bin))) <> 12 THEN 1 ELSE 0 END) > 0
            THEN N'WARN' ELSE N'PASS' END, 0,
       N'Массовые «несовпадения ИИН» S02/S03 уже объяснены ведущими нулями — это НЕ ошибка клиента. Здесь ловим настоящий брак длины, а не эффект типа.'
FROM [Dictionaries].[risk_analytics].[borrower]
WHERE b_report_date = @AsOf
OPTION (MAXDOP 1);

INSERT INTO ##RDW_RESULTS
SELECT 4, N'L4 клиент borrower', N'L4.5', N'borrower.b_iin_bin',
       N'Клиентов без ИИН/БИН вовсе', NULL,
       N'iin_null', COUNT_BIG(*), N'0',
       CASE WHEN COUNT_BIG(*) > 0 THEN N'WARN' ELSE N'PASS' END, 0,
       N'Без ИИН клиент не сопоставим ни с одним внешним реестром (банкротство, ГКБ, налоговая).'
FROM [Dictionaries].[risk_analytics].[borrower]
WHERE b_report_date = @AsOf AND (b_iin_bin IS NULL OR LTRIM(RTRIM(b_iin_bin)) = N'')
OPTION (MAXDOP 1);
GO


/* =============================================================================
   L5. ПЕРИМЕТР old ↔ new — СОБСТВЕННО ВОПРОС МИГРАЦИИ
   -----------------------------------------------------------------------------
   До этого слоя мы проверяли новую ветку саму по себе (внутренняя
   непротиворечивость). Здесь впервые появляется ЭТАЛОН — старая ветка.
   КЛЮЧ РАЗНЫЙ ПО ИСТОЧНИКАМ. Это доказано данными, а не выбрано:
     S01  PORTFOLIO_RS.contract_id      → loans.l_loan_id        (работает)
     S03  CL_PORTFOLIO_2.contract_number→ loans.l_loan_number    (l_loan_id даёт 0)
     S17  PORTFOLIO_Fenix.contractnumber→ loan_account.la_dog_num
          (contract_id ОПРОВЕРГНУТ: 5 128 значений неуникальны, до 33 договоров на id)
     S02  UNION(WAY4,MIGR_WAY4,SMART_CARD).contract_number → loans.l_loan_number
   Применение «одного универсального ключа» здесь — самостоятельный источник
   ложных пропаж. Мост строится по источникам и складывается.
   ============================================================================= */

DECLARE @RunStart datetime = (SELECT CONVERT(datetime,value,121) FROM ##RDW_PARAMS WHERE name=N'RunStart');
DECLARE @RowsSoFar int = (SELECT COUNT(*) FROM ##RDW_RESULTS);
RAISERROR(N'[L5 периметр old<->new] начало -- ' + CONVERT(nvarchar(19),GETDATE(),120)
    + N' (+' + CONVERT(nvarchar(10),DATEDIFF(SECOND,@RunStart,GETDATE())) + N' с от старта), строк в отчёте: '
    + CONVERT(nvarchar(10),@RowsSoFar), 0, 1) WITH NOWAIT;
DECLARE @AsOf date = (SELECT CONVERT(date,value) FROM ##RDW_PARAMS WHERE name=N'AsOf');
DECLARE @SourceFilter nvarchar(10) = NULLIF((SELECT value FROM ##RDW_PARAMS WHERE name=N'SourceFilter'), N'(все)');

/* Эталон: старая ветка, приведённая к одной форме (source, ключ, деньги, статус).
   Ключ в этом мосте — ТОТ, что подтверждён для источника (см. шапку слоя). */
IF OBJECT_ID('tempdb..##RDW_OLD') IS NOT NULL DROP TABLE ##RDW_OLD;
CREATE TABLE ##RDW_OLD (
    source_system nvarchar(10)  NOT NULL,
    join_key      nvarchar(255) NOT NULL,   -- значение подтверждённого ключа
    key_kind      nvarchar(30)  NOT NULL,   -- какой это ключ (для трассируемости)
    old_balance   decimal(38,2) NULL,
    old_prov      decimal(38,2) NULL,
    old_dpd_max   int           NULL,
    old_bucket    nvarchar(50)  NULL,
    old_status    nvarchar(100) NULL
);

-- S01: ключ contract_id → l_loan_id
IF @SourceFilter IS NULL OR @SourceFilter = N'S01'
INSERT INTO ##RDW_OLD
SELECT N'S01', CONVERT(nvarchar(255), contract_id), N'contract_id→l_loan_id',
       /* ifrs_balance, НЕ Total_outstanding: подтверждённая сверка S01 (16.07) сходится
          именно по нему — 622 540 880 344,08 против 622 540 880 344,06 (Δ −0,02 ₸).
          Total_outstanding давал фальшивую дельту +41,86 млрд. */
       TRY_CAST([ifrs_balance] AS decimal(38,2)),
       TRY_CAST([ifrs_1428] AS decimal(38,2)) + TRY_CAST([ifrs_1845] AS decimal(38,2))
         + TRY_CAST([deb_1877_prov] AS decimal(38,2)) + TRY_CAST([_1877] AS decimal(38,2)),
       TRY_CAST([max_overdue_days] AS int), TRY_CAST([Basket] AS nvarchar(50)), NULL
FROM [CL_PORTFOLIO].[dbo].[PORTFOLIO_RS]
WHERE TRY_CAST(actual_date AS date) = @AsOf AND contract_id IS NOT NULL
OPTION (MAXDOP 1);

-- S03: ключ contract_number → l_loan_number
IF @SourceFilter IS NULL OR @SourceFilter = N'S03'
INSERT INTO ##RDW_OLD
SELECT N'S03', CONVERT(nvarchar(255), contract_number), N'contract_number→l_loan_number',
       TRY_CAST([balance] AS decimal(38,2)),
       TRY_CAST([provisions_total] AS decimal(38,2)),
       TRY_CAST([maxDPD] AS int), TRY_CAST([category] AS nvarchar(50)), TRY_CAST([status] AS nvarchar(100))
FROM [CL_PORTFOLIO].[dbo].[CL_PORTFOLIO_2]
WHERE TRY_CAST([date] AS date) = @AsOf AND contract_number IS NOT NULL
OPTION (MAXDOP 1);

-- S17: ключ contractnumber → la_dog_num (contract_id НЕПРИГОДЕН — см. шапку)
IF @SourceFilter IS NULL OR @SourceFilter = N'S17'
INSERT INTO ##RDW_OLD
SELECT N'S17', CONVERT(nvarchar(255), contractnumber), N'contractnumber→la_dog_num',
       /* ifrs_balance — подтверждённая формула S17 (outstanding + outstanding_overdue
          + interest + overdue_interest + penalties); сверка 16.07 даёт
          121 251 084 593,62 против 121 245 516 880,01 (Δ −5 567 713,61 ₸). */
       TRY_CAST([ifrs_balance] AS decimal(38,2)),
       TRY_CAST([ifrs_1428] AS decimal(38,2)) + TRY_CAST([ifrs_1845] AS decimal(38,2))
         + TRY_CAST([_1877] AS decimal(38,2)),
       TRY_CAST([max_overdue_days] AS int), TRY_CAST([Basket] AS nvarchar(50)), NULL
FROM [CL_PORTFOLIO].[dbo].[PORTFOLIO_Fenix]
WHERE TRY_CAST(actual_date AS date) = @AsOf AND contractnumber IS NOT NULL
OPTION (MAXDOP 1);

-- S02: UNION трёх карточных таблиц. SOLAR исключён осознанно: данные кончаются 01.07.2023.
IF @SourceFilter IS NULL OR @SourceFilter = N'S02'
INSERT INTO ##RDW_OLD
SELECT N'S02', CONVERT(nvarchar(255), contract_number), N'contract_number→l_loan_number',
       TRY_CAST([balance] AS decimal(38,2)),
       TRY_CAST([ifrs] AS decimal(38,2)) + TRY_CAST([IFRS1845] AS decimal(38,2))
         + TRY_CAST([ifrs18771_WTRAF_i_PENII] AS decimal(38,2)),
       TRY_CAST([maxDPD] AS int), TRY_CAST([category] AS nvarchar(50)), TRY_CAST([status] AS nvarchar(100))
FROM (
    SELECT contract_number, [date], [balance], [ifrs], [IFRS1845], [ifrs18771_WTRAF_i_PENII], [maxDPD], [category], [status]
      FROM [CL_PORTFOLIO].[dbo].[PORTFOLIO_CREDITCARDS_WAY4]
    UNION ALL
    SELECT contract_number, [date], [balance], [ifrs], [IFRS1845], [ifrs18771_WTRAF_i_PENII], [maxDPD], [category], [status]
      FROM [CL_PORTFOLIO].[dbo].[PORTFOLIO_CREDITCARDS_MIGR_WAY4]
    UNION ALL
    SELECT contract_number, [date], [balance], [ifrs], [IFRS1845], [ifrs18771_WTRAF_i_PENII], [maxDPD], [category], [status]
      FROM [CL_PORTFOLIO].[dbo].[PORTFOLIO_CREDITCARDS_SMART_CARD]
) s02
WHERE TRY_CAST([date] AS date) = @AsOf AND contract_number IS NOT NULL
OPTION (MAXDOP 1);

/* L5.0 Grain ЭТАЛОНА — старая ветка тоже может дублить, и тогда «пропажа»
   в новой ветке будет ложной. Проверяется до сравнения, не после. */
INSERT INTO ##RDW_RESULTS
SELECT 5, N'L5 периметр old↔new', N'L5.0', N'старая ветка (мост ##RDW_OLD)',
       N'Лишних сырых строк эталона сверх одной на (source,ключ)', source_system,
       N'excess_raw_rows_old', SUM(c) - COUNT_BIG(*), N'0',
       CASE WHEN SUM(c) - COUNT_BIG(*) > 0 THEN N'WARN' ELSE N'PASS' END, 0,
       N'S01 отдельно: 633 договора живут ОДНОВРЕМЕННО в PORTFOLIO_RS и PORTFOLIO_RS_7130 — простое объединение без дедупликации завышает эталонный периметр. Здесь RS_7130 намеренно НЕ подмешан.'
FROM (SELECT source_system, join_key, COUNT_BIG(*) c FROM ##RDW_OLD GROUP BY source_system, join_key) x
GROUP BY source_system
OPTION (MAXDOP 1);

/* Новая ветка, приведённая к тому же ключу — по правилам источника */
IF OBJECT_ID('tempdb..##RDW_NEW') IS NOT NULL DROP TABLE ##RDW_NEW;
/* ВНИМАНИЕ, ЯВНОЕ ДОПУЩЕНИЕ: для S02/S03/S17 ключом взят loan_account.la_dog_num,
   тогда как подтверждённая цепочка идёт old.contract_number → loans.l_loan_number.
   Равенство la_dog_num = l_loan_number задокументировано как КОНТРОЛЬ, а не как
   доказанное тождество. Если L5 покажет неожиданный ONLY_OLD — первым делом
   проверять это допущение, а не искать пропажу договоров. */
SELECT la.la_source AS source_system,
       CASE WHEN la.la_source = N'S01' THEN CONVERT(nvarchar(255), la.la_loan_id)
            ELSE CONVERT(nvarchar(255), la.la_dog_num) END AS join_key,
       SUM(TRY_CAST(la.total_balance_debt AS decimal(38,2)))                         AS new_balance,
       SUM(TRY_CAST(la.la_account_1428 AS decimal(38,2))
         + TRY_CAST(la.la_account_1845 AS decimal(38,2))
         + TRY_CAST(la.la_account_18771 AS decimal(38,2)))                            AS new_prov,
       MAX(TRY_CAST(la.max_days_past_due_principal_interest AS int))                  AS new_dpd_max,
       MAX(TRY_CAST(la.days_past_due AS int))                                         AS new_dpd,
       MAX(TRY_CAST(la.days_past_due_interest AS int))                                AS new_dpd_interest,
       MAX(TRY_CAST(la.delinquency_bucket AS nvarchar(50)))                           AS new_bucket
INTO ##RDW_NEW
FROM [Dictionaries].[risk_analytics].[loan_account] la
WHERE la.la_reporting_date = @AsOf
  AND (@SourceFilter IS NULL OR la.la_source = @SourceFilter)
GROUP BY la.la_source,
         CASE WHEN la.la_source = N'S01' THEN CONVERT(nvarchar(255), la.la_loan_id)
              ELSE CONVERT(nvarchar(255), la.la_dog_num) END
OPTION (MAXDOP 1);

/* L5.1 Бакеты периметра: MATCHED / ONLY_OLD / ONLY_NEW — FULL OUTER, не INNER.
   INNER JOIN здесь слеп ровно к тому, что мы ищем. */
IF OBJECT_ID('tempdb..##RDW_XB') IS NOT NULL DROP TABLE ##RDW_XB;
SELECT ISNULL(o.source_system, n.source_system) AS source_system,
       CASE WHEN o.join_key IS NOT NULL AND n.join_key IS NOT NULL THEN N'MATCHED'
            WHEN o.join_key IS NOT NULL THEN N'ONLY_OLD' ELSE N'ONLY_NEW' END AS bucket,
       ISNULL(o.old_balance,0) AS old_balance, ISNULL(n.new_balance,0) AS new_balance,
       ISNULL(o.old_prov,0)    AS old_prov,    ISNULL(n.new_prov,0)    AS new_prov,
       o.old_dpd_max, n.new_dpd_max, n.new_dpd, n.new_dpd_interest,
       o.old_bucket, n.new_bucket, o.old_status
INTO ##RDW_XB
FROM (SELECT source_system, join_key,
             SUM(old_balance) AS old_balance, SUM(old_prov) AS old_prov,
             MAX(old_dpd_max) AS old_dpd_max, MAX(old_bucket) AS old_bucket, MAX(old_status) AS old_status
      FROM ##RDW_OLD GROUP BY source_system, join_key) o
FULL OUTER JOIN ##RDW_NEW n
  ON n.source_system = o.source_system AND n.join_key = o.join_key
OPTION (MAXDOP 1);

INSERT INTO ##RDW_RESULTS
SELECT 5, N'L5 периметр old↔new', N'L5.1', N'старая ↔ loan_account',
       N'Договоров в бакете '+bucket, source_system,
       N'contracts_'+bucket, COUNT_BIG(*), N'ONLY_* → 0 либо объяснено',
       CASE WHEN bucket = N'MATCHED' THEN N'INFO'
            WHEN COUNT_BIG(*) = 0 THEN N'PASS' ELSE N'WARN' END, 0,
       N'Количество без суммы ничего не решает — денежный вес тех же бакетов в L5.2. Пустой бакет ONLY_* тоже печатается, чтобы «ноль» отличался от «не проверяли».'
FROM ##RDW_XB GROUP BY source_system, bucket
OPTION (MAXDOP 1);

/* L5.2 Денежный вес бакетов — здесь «пропажа» превращается в тенге.
   ONLY_OLD с ненулевым остатком = кандидат в реальную потерю периметра. */
INSERT INTO ##RDW_RESULTS
SELECT 5, N'L5 периметр old↔new', N'L5.2', N'ONLY_OLD с ненулевым остатком',
       N'Договоров только в старой ветке И с остатком > допуска', source_system,
       N'only_old_nonzero_contracts', COUNT_BIG(*), N'0',
       CASE WHEN COUNT_BIG(*) > 0 THEN N'FAIL' ELSE N'PASS' END, 0,
       N'Регрессия известных: S02 3 955 дог. / 381 375 405,28 ₸; S03 2 907 дог. / 17 199 371 554,56 ₸; S17 4 дог. / 117 713,61 ₸; S01 5 дог. с нулём (влияния нет).'
FROM ##RDW_XB WHERE bucket = N'ONLY_OLD' AND ABS(old_balance) > 0.01
GROUP BY source_system
OPTION (MAXDOP 1);

INSERT INTO ##RDW_RESULTS
SELECT 5, N'L5 периметр old↔new', N'L5.2b', N'ONLY_OLD с ненулевым остатком',
       N'Сумма остатка, отсутствующего в новой ветке', source_system,
       N'only_old_nonzero_balance', SUM(old_balance), N'0',
       CASE WHEN SUM(old_balance) > 0 THEN N'FAIL' ELSE N'PASS' END, 0,
       N'НЕ складывать с другими суммами отчёта: пропажа периметра, завышение JOIN и отсутствие залоговой ссылки — разной экономической природы.'
FROM ##RDW_XB WHERE bucket = N'ONLY_OLD' AND ABS(old_balance) > 0.01
GROUP BY source_system
OPTION (MAXDOP 1);

INSERT INTO ##RDW_RESULTS
SELECT 5, N'L5 периметр old↔new', N'L5.3', N'ONLY_NEW с ненулевым остатком',
       N'Договоров только в новой ветке И с остатком > допуска', source_system,
       N'only_new_nonzero_contracts', COUNT_BIG(*), N'0 либо объяснено',
       CASE WHEN COUNT_BIG(*) > 0 THEN N'WARN' ELSE N'PASS' END, 0,
       N'Обратное направление и оно тоже дефект: S02 — 42 договора на 76 796 663,82 ₸, которых НЕТ в истории старых таблиц с 01.01.2025, у двух текущий баланс превышает сумму договора.'
FROM ##RDW_XB WHERE bucket = N'ONLY_NEW' AND ABS(new_balance) > 0.01
GROUP BY source_system
OPTION (MAXDOP 1);

/* L5.4 Presence-in-table ≠ живой договор: разбивка ONLY_OLD по статусу.
   Без этого 2 907 договоров S03 читаются как «потеряно 17,2 млрд», хотя
   значительная часть — расторгнутые (статус V), которые старая ветка
   над-удерживает. Направление ошибки в этом случае ОБРАТНОЕ. */
INSERT INTO ##RDW_RESULTS
SELECT 5, N'L5 периметр old↔new', N'L5.4', N'ONLY_OLD в разрезе статуса старой ветки',
       N'Договоров ONLY_OLD со статусом '+ISNULL(old_status,N'(нет статуса)'), source_system,
       N'only_old_by_status', COUNT_BIG(*), N'разбор, не порог', N'INFO', 0,
       N'Ключевая развилка: «нет в новой ветке» и «потеряно» — не одно и то же. Расторгнутый договор с остатком в старой ветке = над-удержание СТАРОЙ, а не потеря НОВОЙ.'
FROM ##RDW_XB WHERE bucket = N'ONLY_OLD'
GROUP BY source_system, old_status
HAVING COUNT_BIG(*) > 0
OPTION (MAXDOP 1);

DROP TABLE ##RDW_OLD;
DROP TABLE ##RDW_NEW;
GO


/* =============================================================================
   L6. БАЛАНС НА MATCHED
   -----------------------------------------------------------------------------
   Назначение слоя: там, где договор есть с обеих сторон, сходятся ли деньги.
   Отделено от L5 сознательно: «договора нет» и «договор есть, сумма другая» —
   разные дефекты, разные причины и разные адресаты. Смешение их в одну цифру
   — самый частый способ получить неинтерпретируемое расхождение.
   ============================================================================= */

DECLARE @RunStart datetime = (SELECT CONVERT(datetime,value,121) FROM ##RDW_PARAMS WHERE name=N'RunStart');
DECLARE @RowsSoFar int = (SELECT COUNT(*) FROM ##RDW_RESULTS);
RAISERROR(N'[L6 баланс на MATCHED] начало -- ' + CONVERT(nvarchar(19),GETDATE(),120)
    + N' (+' + CONVERT(nvarchar(10),DATEDIFF(SECOND,@RunStart,GETDATE())) + N' с от старта), строк в отчёте: '
    + CONVERT(nvarchar(10),@RowsSoFar), 0, 1) WITH NOWAIT;
DECLARE @Tolerance decimal(18,2) = (SELECT CONVERT(decimal(18,2),value) FROM ##RDW_PARAMS WHERE name=N'Tolerance');

/* L6.0 ОГОВОРКА, которую нельзя прятать: на новой стороне для ВСЕХ источников взят
   total_balance_debt, а это подтверждённая формула S17 (8 счетов, БЕЗ 1818/1838).
   Для S03 документированный balance включает 1818/1838, то есть сравнение S03
   потенциально сравнивает разные величины. Шапка скрипта прямо предупреждает
   «формула баланса РАЗНАЯ по источникам» — и здесь это допущение нарушено сознательно,
   пока не подтверждён корректный столбец новой стороны для S03/S02. */
INSERT INTO ##RDW_RESULTS VALUES
(6, N'L6 баланс на MATCHED', N'L6.0', N'состав баланса новой стороны',
 N'Для всех источников взят total_balance_debt (формула S17, без 1818/1838)', NULL,
 N'assumption_flag', 1, N'подтвердить у S2T', N'WARN', 0,
 N'S03 по документации использует balance с 1818/1838. До подтверждения столбца дельта L6.2/L6.3 по S03 и S02 может измерять разницу СОСТАВА, а не расхождение данных. S01/S17 сверены по ifrs_balance и этой оговоркой не затронуты.');

INSERT INTO ##RDW_RESULTS
SELECT 6, N'L6 баланс на MATCHED', N'L6.1', N'MATCHED: старая vs новая',
       N'Договоров, сошедшихся в пределах допуска', source_system,
       N'matched_within_tolerance', SUM(CASE WHEN ABS(old_balance - new_balance) <= @Tolerance THEN 1 ELSE 0 END),
       N'= число MATCHED',
       CASE WHEN SUM(CASE WHEN ABS(old_balance - new_balance) > @Tolerance THEN 1 ELSE 0 END) = 0
            THEN N'PASS' ELSE N'WARN' END, 0,
       N'Доля читается только вместе со знаменателем (число MATCHED в L5.1). S01 сошёлся с Δ −0,02 ₸ на всём периметре; S02 — 27 058 из 27 257 (99,27%).'
FROM ##RDW_XB WHERE bucket = N'MATCHED'
GROUP BY source_system
OPTION (MAXDOP 1);

INSERT INTO ##RDW_RESULTS
SELECT 6, N'L6 баланс на MATCHED', N'L6.2', N'MATCHED: чистое расхождение',
       N'Новая минус старая по сошедшемуся периметру, ₸', source_system,
       N'net_balance_delta', SUM(new_balance - old_balance), N'0 ± допуск',
       CASE WHEN ABS(SUM(new_balance - old_balance)) <= @Tolerance THEN N'PASS' ELSE N'WARN' END, 0,
       N'ЧИСТОЕ расхождение может быть мало при больших встречных отклонениях — поэтому рядом обязательна валовая сумма модулей (L6.3).'
FROM ##RDW_XB WHERE bucket = N'MATCHED'
GROUP BY source_system
OPTION (MAXDOP 1);

INSERT INTO ##RDW_RESULTS
SELECT 6, N'L6 баланс на MATCHED', N'L6.3', N'MATCHED: валовое расхождение',
       N'Сумма модулей отклонений, ₸ (взаимозачёт не скрывает)', source_system,
       N'gross_abs_delta', SUM(ABS(new_balance - old_balance)), N'0 ± допуск',
       CASE WHEN SUM(ABS(new_balance - old_balance)) <= @Tolerance THEN N'PASS' ELSE N'WARN' END, 0,
       N'Валовая цифра — честнее чистой: два договора с +1 млрд и −1 млрд дают чистый ноль и валовые 2 млрд.'
FROM ##RDW_XB WHERE bucket = N'MATCHED'
GROUP BY source_system
OPTION (MAXDOP 1);

/* L6.4 Худшие расхождения — БЕЗ PII, бакетами по магнитуде.
   Так виден «один договор на 108 млн» (S02, la_account_1403 при сумме
   договора 150 000 ₸), но ни одного номера договора в выводе нет. */
INSERT INTO ##RDW_RESULTS
SELECT 6, N'L6 баланс на MATCHED', N'L6.4', N'MATCHED: расхождения по магнитуде',
       N'Договоров с отклонением в бакете '+mag_bucket, source_system,
       N'contracts_in_magnitude_bucket', COUNT_BIG(*), N'справочно', N'INFO', 0,
       N'Локализация без PII: если весь вес сидит в одном договоре верхнего бакета — это точечный дефект, а не системный сдвиг, и лечится иначе.'
FROM (
    SELECT source_system,
           CASE WHEN ABS(new_balance-old_balance) <= 0.01              THEN N'0 (сошлось)'
                WHEN ABS(new_balance-old_balance) < 1000               THEN N'< 1 тыс'
                WHEN ABS(new_balance-old_balance) < 1000000            THEN N'1 тыс – 1 млн'
                WHEN ABS(new_balance-old_balance) < 100000000          THEN N'1 млн – 100 млн'
                ELSE N'> 100 млн' END AS mag_bucket
    FROM ##RDW_XB WHERE bucket = N'MATCHED'
) m
GROUP BY source_system, mag_bucket
OPTION (MAXDOP 1);
GO


/* =============================================================================
   L7. ПРОВИЗИИ
   -----------------------------------------------------------------------------
   Назначение слоя: регуляторная цифра. Идёт ПОСЛЕ баланса, потому что
   расхождение резервов при расходящемся балансе неинтерпретируемо — непонятно,
   двигается ли резерв или база, на которую он начислен.
   ВАЖНО (валентность): «новая выше» ≠ «новая неправа». Без эталона —
   бухгалтерского или утверждённого IFRS 9 — вину присваивать нельзя.
   ============================================================================= */

DECLARE @RunStart datetime = (SELECT CONVERT(datetime,value,121) FROM ##RDW_PARAMS WHERE name=N'RunStart');
DECLARE @RowsSoFar int = (SELECT COUNT(*) FROM ##RDW_RESULTS);
RAISERROR(N'[L7 провизии] начало -- ' + CONVERT(nvarchar(19),GETDATE(),120)
    + N' (+' + CONVERT(nvarchar(10),DATEDIFF(SECOND,@RunStart,GETDATE())) + N' с от старта), строк в отчёте: '
    + CONVERT(nvarchar(10),@RowsSoFar), 0, 1) WITH NOWAIT;
DECLARE @Tolerance decimal(18,2) = (SELECT CONVERT(decimal(18,2),value) FROM ##RDW_PARAMS WHERE name=N'Tolerance');

INSERT INTO ##RDW_RESULTS
SELECT 7, N'L7 провизии', N'L7.1', N'MATCHED: провизии старая vs новая',
       N'Договоров, где провизии сошлись в пределах допуска', source_system,
       N'prov_matched', SUM(CASE WHEN ABS(old_prov - new_prov) <= @Tolerance THEN 1 ELSE 0 END),
       N'= число MATCHED',
       CASE WHEN SUM(CASE WHEN ABS(old_prov - new_prov) > @Tolerance THEN 1 ELSE 0 END) = 0
            THEN N'PASS' ELSE N'FAIL' END, 0,
       N'Регрессия: S01 сошёлся 4 380/4 380 (100%); S03 — только 50 371/237 269 (21,23%) и ретест 21.07 НЕ устранил; S02 — 26 390/27 257 (96,82%).'
FROM ##RDW_XB WHERE bucket = N'MATCHED'
GROUP BY source_system
OPTION (MAXDOP 1);

INSERT INTO ##RDW_RESULTS
SELECT 7, N'L7 провизии', N'L7.2', N'MATCHED: чистое расхождение провизий',
       N'Новая минус старая, ₸', source_system,
       N'net_prov_delta', SUM(new_prov - old_prov), N'0 ± допуск',
       CASE WHEN ABS(SUM(new_prov - old_prov)) <= @Tolerance THEN N'PASS' ELSE N'FAIL' END, 0,
       N'Валентность: положительная дельта НЕ доказывает ошибку новой ветки — старая может недорезервировать. Присваивать вину только против бух./IFRS 9 эталона.'
FROM ##RDW_XB WHERE bucket = N'MATCHED'
GROUP BY source_system
OPTION (MAXDOP 1);

/* L7.3 Компонентный разрез: какой счёт формирует расхождение.
   Именно так было локализовано S03: 1428 → 30,47 млрд, 18771 → 3,02 млрд.
   ОПТИМИЗАЦИЯ 04.08.2026: было 4x UNION ALL одного и того же loan_account
   с одним и тем же фильтром (по разу на счёт) — четыре скана таблицы вместо
   одного. Суммы всех четырёх счетов считаются за один проход, раскладка по
   строкам — через CROSS APPLY VALUES; форма отчёта не меняется. */
DECLARE @AsOf7 date = (SELECT CONVERT(date,value) FROM ##RDW_PARAMS WHERE name=N'AsOf');
INSERT INTO ##RDW_RESULTS
SELECT 7, N'L7 провизии', N'L7.3', N'Компоненты провизий новой ветки',
       N'Сумма счёта '+acc_name+N' по источнику', la_source,
       N'sum_'+acc_name, acc_sum, N'справочно', N'INFO', 0,
       N'Разложение делает расхождение адресным: «провизии не сходятся» ничего не даёт разработчику, «1428 выше на N» — даёт.'
FROM (
    SELECT la_source,
           SUM(TRY_CAST(la_account_1428  AS decimal(38,2))) AS s_1428,
           SUM(TRY_CAST(la_account_1845  AS decimal(38,2))) AS s_1845,
           SUM(TRY_CAST(la_account_18770 AS decimal(38,2))) AS s_18770,
           SUM(TRY_CAST(la_account_18771 AS decimal(38,2))) AS s_18771
    FROM [Dictionaries].[risk_analytics].[loan_account]
    WHERE la_reporting_date = @AsOf7
    GROUP BY la_source
) g
CROSS APPLY (VALUES (N'1428',s_1428), (N'1845',s_1845), (N'18770',s_18770), (N'18771',s_18771)) c(acc_name, acc_sum)
OPTION (MAXDOP 1);
GO


/* =============================================================================
   L8. DPD и 90+ — САМАЯ ДЕФЕКТНАЯ ЗОНА
   -----------------------------------------------------------------------------
   Назначение слоя: стадирование IFRS 9 и NPL-отчётность. Идёт после провизий,
   потому что 90+ двигает и резервы тоже; разбирать одновременно — потерять
   причинность.
   ГЛАВНОЕ ПРАВИЛО СЛОЯ: NULL ≠ 0. Заявление «пусто значит нет просрочки»
   (разработчик, 21–22.07) опровергнуто данными и здесь проверяется каждый
   прогон — L8.2 меряет ровно тот контрпример.
   ЛОВУШКА, КОТОРУЮ ЛЕГКО НЕ ЗАМЕТИТЬ: SQL-сравнение с NULL даёт UNKNOWN, а не
   FALSE. Поэтому переход «в старой NULL → в новой 90+» НЕ попадает ни в
   ONLY_NEW_90, ни в ONLY_OLD_90, а молча уходит в NEITHER. Считаем его явно
   (L8.5), иначе «ложных 90+ ноль» — артефакт трёхзначной логики, а не факт.
   ============================================================================= */

DECLARE @RunStart datetime = (SELECT CONVERT(datetime,value,121) FROM ##RDW_PARAMS WHERE name=N'RunStart');
DECLARE @RowsSoFar int = (SELECT COUNT(*) FROM ##RDW_RESULTS);
RAISERROR(N'[L8 DPD и 90+] начало -- ' + CONVERT(nvarchar(19),GETDATE(),120)
    + N' (+' + CONVERT(nvarchar(10),DATEDIFF(SECOND,@RunStart,GETDATE())) + N' с от старта), строк в отчёте: '
    + CONVERT(nvarchar(10),@RowsSoFar), 0, 1) WITH NOWAIT;
DECLARE @NinetyPlus int = (SELECT CONVERT(int,value) FROM ##RDW_PARAMS WHERE name=N'NinetyPlus');
DECLARE @MinBase    int = (SELECT CONVERT(int,value) FROM ##RDW_PARAMS WHERE name=N'MinBase');
DECLARE @AsOf8 date = (SELECT CONVERT(date,value) FROM ##RDW_PARAMS WHERE name=N'AsOf');

/* L8.1 Заполненность DPD-полей: сколько вообще есть чем считать.
   ОПТИМИЗАЦИЯ 04.08.2026: было 4x UNION ALL одного и того же loan_account с
   одним и тем же фильтром (по разу на поле) — четыре скана вместо одного.
   total и nulls по всем четырём полям считаются за один проход и раскладываются
   по строкам через CROSS APPLY VALUES; форма отчёта не меняется — total
   по-прежнему одинаков для всех полей одного source (тот же COUNT_BIG(*)). */
INSERT INTO ##RDW_RESULTS
SELECT 8, N'L8 DPD и 90+', N'L8.1', N'loan_account.'+fld,
       N'Доля NULL по полю '+fld+N', % от периметра источника', la_source,
       N'null_rate_pct', CASE WHEN total = 0 THEN NULL ELSE 100.0*nulls/total END, N'0%',
       CASE WHEN total = 0 THEN N'NO_BASE'
            WHEN nulls = 0 THEN N'PASS'
            WHEN 100.0*nulls/total >= 50 THEN N'FAIL' ELSE N'WARN' END, 0,
       N'Регрессия: S17 days_past_due_interest = 100% NULL; S03 days_past_due — 87,90%; S02 — 99,30%. Это не «нет просрочки», это отсутствие измерения.'
FROM (
    SELECT la_source, COUNT_BIG(*) AS total,
           SUM(CASE WHEN days_past_due IS NULL THEN 1 ELSE 0 END)                        AS n_dpd,
           SUM(CASE WHEN days_past_due_principal IS NULL THEN 1 ELSE 0 END)              AS n_dpd_principal,
           SUM(CASE WHEN days_past_due_interest IS NULL THEN 1 ELSE 0 END)               AS n_dpd_interest,
           SUM(CASE WHEN max_days_past_due_principal_interest IS NULL THEN 1 ELSE 0 END) AS n_dpd_max
    FROM [Dictionaries].[risk_analytics].[loan_account]
    WHERE la_reporting_date = @AsOf8
    GROUP BY la_source
) g
CROSS APPLY (VALUES
    (N'days_past_due', n_dpd),
    (N'days_past_due_principal', n_dpd_principal),
    (N'days_past_due_interest', n_dpd_interest),
    (N'max_days_past_due_principal_interest', n_dpd_max)
) f(fld, nulls)
OPTION (MAXDOP 1);

/* L8.2 КОНТРПРИМЕР К «NULL = 0». Это не мнение — это счётчик.
   Договоры, где новая ветка молчит, а старая показывает просрочку. */
INSERT INTO ##RDW_RESULTS
SELECT 8, N'L8 DPD и 90+', N'L8.2', N'NULL в новой при просрочке в старой',
       N'Договоров: новый DPD = NULL, старый DPD > 0', source_system,
       N'null_new_but_overdue_old', COUNT_BIG(*), N'0 (иначе NULL≠0 доказано)',
       CASE WHEN COUNT_BIG(*) > 0 THEN N'FAIL' ELSE N'PASS' END, 0,
       N'Каждая такая строка ОПРОВЕРГАЕТ «пусто значит ноль». Регрессия: S17 9 815 дог. (3 872 218 577,36 ₸), из них 5 965 свыше 90 дней; S01 5 дог. (203 814 236,94 ₸) с просрочкой 1–8 дней.'
FROM ##RDW_XB
WHERE bucket = N'MATCHED' AND new_dpd_max IS NULL AND old_dpd_max > 0
GROUP BY source_system
OPTION (MAXDOP 1);

INSERT INTO ##RDW_RESULTS
SELECT 8, N'L8 DPD и 90+', N'L8.2b', N'NULL в новой при просрочке в старой',
       N'Остаток по этим договорам, ₸', source_system,
       N'null_new_but_overdue_old_balance', SUM(old_balance), N'0',
       CASE WHEN SUM(old_balance) > 0 THEN N'FAIL' ELSE N'PASS' END, 0,
       N'Денежный вес контрпримера — то, что делает его вопросом к S2T, а не придиркой.'
FROM ##RDW_XB
WHERE bucket = N'MATCHED' AND new_dpd_max IS NULL AND old_dpd_max > 0
GROUP BY source_system
OPTION (MAXDOP 1);

/* L8.3 Off-by-one: правило old = new − 1 существует, но НЕ универсально.
   Меряем процент совпадения ПО ИСТОЧНИКУ на ЗАПОЛНЕННОМ периметре. */
INSERT INTO ##RDW_RESULTS
SELECT 8, N'L8 DPD и 90+', N'L8.3', N'Правило old_maxDPD = new_maxDPD − 1',
       N'Совпадение на заполненном периметре, %', source_system,
       N'off_by_one_match_pct',
       CASE WHEN COUNT_BIG(*) = 0 THEN NULL
            ELSE 100.0*SUM(CASE WHEN old_dpd_max = new_dpd_max - 1 THEN 1 ELSE 0 END)/COUNT_BIG(*) END,
       N'100%',
       CASE WHEN COUNT_BIG(*) < @MinBase THEN N'NO_BASE'
            WHEN SUM(CASE WHEN old_dpd_max = new_dpd_max - 1 THEN 0 ELSE 1 END) = 0 THEN N'PASS'
            ELSE N'WARN' END, 0,
       N'Регрессия: S01 61,02%; S17 max 66,98% / principal 78,92%; S02 MIGR+SMART 99,48%; S03 — правило на актуальных данных не подтвердилось. Разброс 61–99% означает: единого правила НЕТ, и брать его как универсальное нельзя.'
FROM ##RDW_XB
WHERE bucket = N'MATCHED' AND new_dpd_max IS NOT NULL AND old_dpd_max IS NOT NULL
GROUP BY source_system
OPTION (MAXDOP 1);

/* L8.3b ДИАГНОСТИКА. Прогон 31.07 дал совпадение off-by-one 0,13% (S01) при
   документированных 61,02% — расхождение слишком велико, чтобы быть находкой:
   так выглядит либо другое поле, либо другой формат. Поэтому не утверждаем
   правило, а печатаем фактическое распределение (old − new). Если пик стоит
   не на −1, значит правило сформулировано не про эти два поля. */
INSERT INTO ##RDW_RESULTS
SELECT 8, N'L8 DPD и 90+', N'L8.3b', N'Фактическая разница old_maxDPD − new_maxDPD',
       N'Договоров с разницей '+delta_bucket, source_system,
       N'contracts_by_dpd_delta', COUNT_BIG(*), N'пик ожидается на −1', N'INFO', 0,
       N'Диагностика к L8.3. Пик НЕ на −1 означает, что сравниваются разные величины (например max по основному долгу против max по всему), и правило нужно переформулировать, а не считать нарушенным.'
FROM (
    SELECT source_system,
           CASE WHEN old_dpd_max - new_dpd_max = -1 THEN N'ровно −1 (правило)'
                WHEN old_dpd_max - new_dpd_max = 0  THEN N'0 (равны)'
                WHEN old_dpd_max - new_dpd_max BETWEEN -10 AND -2 THEN N'от −10 до −2'
                WHEN old_dpd_max - new_dpd_max BETWEEN 1 AND 10   THEN N'от +1 до +10'
                WHEN old_dpd_max - new_dpd_max < -10 THEN N'меньше −10'
                ELSE N'больше +10' END AS delta_bucket
    FROM ##RDW_XB
    WHERE bucket = N'MATCHED' AND new_dpd_max IS NOT NULL AND old_dpd_max IS NOT NULL
) d
GROUP BY source_system, delta_bucket
OPTION (MAXDOP 1);

/* L8.4 Матрица 90+: обе стороны, ЯВНО включая NULL как отдельное состояние */
INSERT INTO ##RDW_RESULTS
SELECT 8, N'L8 DPD и 90+', N'L8.4', N'Матрица признака 90+',
       N'Договоров: '+state_old+N' → '+state_new, source_system,
       N'contracts_90plus_transition', COUNT_BIG(*), N'разбор, не порог', N'INFO', 0,
       N'Все девять состояний печатаются явно, включая NULL-строки. Отчёт «0 ложных 90+» без NULL-строк — артефакт, а не результат.'
FROM (
    SELECT source_system,
           CASE WHEN old_dpd_max IS NULL THEN N'old:NULL'
                WHEN old_dpd_max > @NinetyPlus THEN N'old:90+' ELSE N'old:≤90' END AS state_old,
           CASE WHEN new_dpd_max IS NULL THEN N'new:NULL'
                WHEN new_dpd_max > @NinetyPlus THEN N'new:90+' ELSE N'new:≤90' END AS state_new
    FROM ##RDW_XB WHERE bucket = N'MATCHED'
) t
GROUP BY source_system, state_old, state_new
OPTION (MAXDOP 1);

/* L8.5 Потеря признака 90+ — прямое регуляторное последствие */
INSERT INTO ##RDW_RESULTS
SELECT 8, N'L8 DPD и 90+', N'L8.5', N'Потеря 90+ при переходе в новую ветку',
       N'Договоров: старая 90+, новая НЕ 90+ (вкл. NULL)', source_system,
       N'lost_90plus_contracts', COUNT_BIG(*), N'0',
       CASE WHEN COUNT_BIG(*) > 0 THEN N'FAIL' ELSE N'PASS' END, 0,
       N'Регрессия S17: 932 договора / 273 000 212,61 ₸ (247 обнулены в NULL + 685 понижены ≤90). Прямо уменьшает NPL и Stage 3.'
FROM ##RDW_XB
WHERE bucket = N'MATCHED' AND old_dpd_max > @NinetyPlus
  AND (new_dpd_max IS NULL OR new_dpd_max <= @NinetyPlus)
GROUP BY source_system
OPTION (MAXDOP 1);

INSERT INTO ##RDW_RESULTS
SELECT 8, N'L8 DPD и 90+', N'L8.5b', N'Потеря 90+ при переходе в новую ветку',
       N'Остаток по потерявшим 90+, ₸', source_system,
       N'lost_90plus_balance', SUM(old_balance), N'0',
       CASE WHEN SUM(old_balance) > 0 THEN N'FAIL' ELSE N'PASS' END, 0,
       N'Это тот самый объём, который «исчезает» из NPL-отчётности при переключении на новую ветку без исправления DPD.'
FROM ##RDW_XB
WHERE bucket = N'MATCHED' AND old_dpd_max > @NinetyPlus
  AND (new_dpd_max IS NULL OR new_dpd_max <= @NinetyPlus)
GROUP BY source_system
OPTION (MAXDOP 1);

/* L8.6 Обратное: новая ветка ПРИБАВЛЯЕТ 90+ там, где старая молчала.
   Ловим и подслучай old:NULL → new:90+, который прячется в NEITHER. */
INSERT INTO ##RDW_RESULTS
SELECT 8, N'L8 DPD и 90+', N'L8.6', N'Появление 90+ только в новой ветке',
       N'Договоров: новая 90+, старая нет ('+
       CASE WHEN old_is_null = 1 THEN N'старая NULL — скрытый случай' ELSE N'старая ≤90' END+N')', source_system,
       N'new_only_90plus', COUNT_BIG(*), N'0 либо объяснено',
       CASE WHEN COUNT_BIG(*) > 0 THEN N'WARN' ELSE N'PASS' END, 0,
       N'Подслучай «старая NULL» отделён намеренно: при сравнении old>90 он даёт UNKNOWN и не попадает никуда. Именно из-за этого прошлый вывод «0 ложных 90+» был переоценкой.'
FROM (
    SELECT source_system, CASE WHEN old_dpd_max IS NULL THEN 1 ELSE 0 END AS old_is_null
    FROM ##RDW_XB
    WHERE bucket = N'MATCHED' AND new_dpd_max > @NinetyPlus
      AND (old_dpd_max IS NULL OR old_dpd_max <= @NinetyPlus)
) t
GROUP BY source_system, old_is_null
OPTION (MAXDOP 1);

/* L8.7 Материальность границы: >90 против >=90 — сколько сидит ровно на 90 */
INSERT INTO ##RDW_RESULTS
SELECT 8, N'L8 DPD и 90+', N'L8.7', N'Граница 90+: договоров ровно на DPD = 90',
       N'Договоров с новым max DPD ровно 90', source_system,
       N'contracts_at_exactly_90', COUNT_BIG(*), N'справочно', N'INFO', 0,
       N'Решает, материален ли спор «>90 или ≥90». Если здесь ноль — спор схоластический и его можно закрыть; если нет — определение обязано быть зафиксировано письменно.'
FROM ##RDW_XB WHERE bucket = N'MATCHED' AND new_dpd_max = @NinetyPlus
GROUP BY source_system
OPTION (MAXDOP 1);

/* L8.8 Независим ли бакет от DPD. Если бакет сходится ~100% при разъезжающемся
   DPD — значит бакет считается НЕ из этих полей, и вопрос «что нормативно
   для 90+» становится обязательным к ответу, а не факультативным. */
INSERT INTO ##RDW_RESULTS
SELECT 8, N'L8 DPD и 90+', N'L8.8', N'delinquency_bucket vs старый бакет',
       N'Совпадение бакета, %', source_system,
       N'bucket_match_pct',
       /* Сравнение ЧИСЛОВОЕ, а не строковое: документировано «category соответствует
          delinquency_bucket ПОСЛЕ приведения к числовому типу». Строковое сравнение
          давало S01 0,00% и S03 0,00% там, где на деле 99,93% — это был баг проверки,
          а не расхождение данных. TRY_CAST спасает от нечисловых значений. */
       CASE WHEN COUNT_BIG(*) = 0 THEN NULL
            ELSE 100.0*SUM(CASE WHEN TRY_CAST(new_bucket AS decimal(18,4)) IS NOT NULL
                                      AND TRY_CAST(old_bucket AS decimal(18,4)) IS NOT NULL
                                      AND TRY_CAST(new_bucket AS decimal(18,4)) = TRY_CAST(old_bucket AS decimal(18,4))
                                     THEN 1
                                WHEN new_bucket IS NULL AND old_bucket IS NULL THEN 1
                                ELSE 0 END)/COUNT_BIG(*) END,
       N'100%',
       CASE WHEN COUNT_BIG(*) < @MinBase THEN N'NO_BASE'
            WHEN SUM(CASE WHEN TRY_CAST(new_bucket AS decimal(18,4)) IS NOT NULL
                               AND TRY_CAST(old_bucket AS decimal(18,4)) IS NOT NULL
                               AND TRY_CAST(new_bucket AS decimal(18,4)) = TRY_CAST(old_bucket AS decimal(18,4))
                              THEN 0
                         WHEN new_bucket IS NULL AND old_bucket IS NULL THEN 0
                         ELSE 1 END) = 0
            THEN N'PASS' ELSE N'WARN' END, 0,
       N'Регрессия: S01 99,93%, S17 99,9837%, S02 MIGR+SMART 100% — при DPD, расходящемся на 20–40%. Такой контраст = бакет формируется независимо от проверяемых DPD-полей. Для WAY4 бакет NULL целиком.'
FROM ##RDW_XB WHERE bucket = N'MATCHED'
GROUP BY source_system
OPTION (MAXDOP 1);
GO


/* =============================================================================
   L9. ЗАЛОГИ `pledges`
   -----------------------------------------------------------------------------
   Назначение таблицы: обеспечение → напрямую LGD и покрытие.
   ПОДТВЕРЖДЁННАЯ связь ровно одна: c_source + c_loan_gid → l_source + l_gid.
   l_collateral_id как универсальный FK ОПРОВЕРГНУТ: для S03 работает
   (99,95%), для S17 не заполнен при наличии залогов (15 646 договоров),
   для S01 не совпадает ни с одним кандидатом (2 190 договоров).
   ============================================================================= */

DECLARE @RunStart datetime = (SELECT CONVERT(datetime,value,121) FROM ##RDW_PARAMS WHERE name=N'RunStart');
DECLARE @RowsSoFar int = (SELECT COUNT(*) FROM ##RDW_RESULTS);
RAISERROR(N'[L9 залоги] начало -- ' + CONVERT(nvarchar(19),GETDATE(),120)
    + N' (+' + CONVERT(nvarchar(10),DATEDIFF(SECOND,@RunStart,GETDATE())) + N' с от старта), строк в отчёте: '
    + CONVERT(nvarchar(10),@RowsSoFar), 0, 1) WITH NOWAIT;
DECLARE @AsOf9 date = (SELECT CONVERT(date,value) FROM ##RDW_PARAMS WHERE name=N'AsOf');
DECLARE @ValueRatioFlag decimal(18,4) = 10.0;

-- L9.1 Подтверждённая связь: доля залогов, находящих договор
INSERT INTO ##RDW_RESULTS
SELECT 9, N'L9 залоги', N'L9.1', N'pledges.c_source+c_loan_gid → loans.l_source+l_gid',
       N'Залогов, не нашедших договор по подтверждённому ключу', p.c_source,
       N'pledges_without_loan', COUNT_BIG(*), N'0',
       CASE WHEN COUNT_BIG(*) > 0 THEN N'FAIL' ELSE N'PASS' END, 0,
       N'Ранее проходило 100%. Это ЕДИНСТВЕННЫЙ подтверждённый путь loans↔pledges; если он поехал — переставать доверять всей залоговой аналитике, а не искать обход.'
FROM [Dictionaries].[risk_analytics].[pledges] p
WHERE p.c_reporting_date = @AsOf9
  AND NOT EXISTS (SELECT 1 FROM [Dictionaries].[risk_analytics].[loans] l
                  WHERE l.l_report_date = @AsOf9 AND l.l_source = p.c_source AND l.l_gid = p.c_loan_gid)
GROUP BY p.c_source
OPTION (MAXDOP 1);

-- L9.2 Активные договоры с ссылкой на залог, но без самого залога (DWH-15)
INSERT INTO ##RDW_RESULTS
SELECT 9, N'L9 залоги', N'L9.2', N'loans_active → pledges (по подтверждённому ключу)',
       N'Активных договоров с l_collateral_id, но без строки в pledges', a.l_source,
       N'active_with_collateral_id_but_no_pledge', COUNT_BIG(*), N'0',
       CASE WHEN COUNT_BIG(*) > 0 THEN N'FAIL' ELSE N'PASS' END, 0,
       N'DWH-15 давал 49 договоров S03 / 367 700 497,14 ₸, НО тот прогон джойнил по c_loan_id, а не по c_source+c_loan_gid. Здесь ключ верный — цифра может измениться, и это главный смысл проверки.'
FROM [Dictionaries].[risk_analytics].[loans_active] a
WHERE a.l_report_date = @AsOf9 AND a.l_collateral_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM [Dictionaries].[risk_analytics].[pledges] p
                  WHERE p.c_reporting_date = @AsOf9 AND p.c_source = a.l_source AND p.c_loan_gid = a.l_gid)
GROUP BY a.l_source
OPTION (MAXDOP 1);

-- L9.3 Пригодность l_collateral_id по источникам (почему универсальный FK опровергнут)
INSERT INTO ##RDW_RESULTS
SELECT 9, N'L9 залоги', N'L9.3', N'loans_active.l_collateral_id',
       N'Активных договоров с залогом, но с ПУСТЫМ l_collateral_id', a.l_source,
       N'has_pledge_but_null_collateral_id', COUNT_BIG(*), N'разбор по источнику', N'INFO', 0,
       N'Семантика поля РАЗНАЯ по источникам: S17 — залоги есть, поле пусто (15 646); S01 — заполнено, но не совпадает ни с c_collateral_id, ни с c_bpm_object_id, ни с c_car_code (2 190). Кадиржан 22.07 заявил правку — это её ретест.'
FROM [Dictionaries].[risk_analytics].[loans_active] a
WHERE a.l_report_date = @AsOf9 AND a.l_collateral_id IS NULL
  AND EXISTS (SELECT 1 FROM [Dictionaries].[risk_analytics].[pledges] p
              WHERE p.c_reporting_date = @AsOf9 AND p.c_source = a.l_source AND p.c_loan_gid = a.l_gid)
GROUP BY a.l_source
OPTION (MAXDOP 1);

-- L9.4 many-to-many легитимна: один объект под несколько договоров — НЕ дубль
INSERT INTO ##RDW_RESULTS
SELECT 9, N'L9 залоги', N'L9.4', N'pledges: общий залог под несколькими договорами',
       N'Объектов залога, обеспечивающих > 1 договора', c_source,
       N'shared_collateral_objects', COUNT_BIG(*), N'справочно (норма)', N'INFO', 0,
       N'Снятая гипотеза: это НЕ дубли. По S01 ранее 1 437 объектов, максимум 22 договора на объект, характеристики между договорами не расходятся.'
FROM (
    SELECT c_source, c_collateral_id
    FROM [Dictionaries].[risk_analytics].[pledges]
    WHERE c_reporting_date = @AsOf9 AND c_collateral_id IS NOT NULL
    GROUP BY c_source, c_collateral_id
    HAVING COUNT(DISTINCT c_loan_gid) > 1
) s
GROUP BY c_source
OPTION (MAXDOP 1);

/* L9.5 Санитарная проверка ОЦЕНКИ: расхождение оценочной и залоговой стоимости
   на порядок. Именно так найден объект 16315 — 332 299 200 ₸ против 3 585 300 ₸
   в BPM (прицеп 2013 г.в.), разница почти в 100 раз. Вывод БЕЗ идентификаторов. */
INSERT INTO ##RDW_RESULTS
SELECT 9, N'L9 залоги', N'L9.5', N'pledges: оценка vs залоговая стоимость',
       N'Объектов с расхождением более чем в '+CONVERT(nvarchar(10),@ValueRatioFlag)+N' раз', c_source,
       N'valuation_outliers', COUNT_BIG(*), N'0',
       CASE WHEN COUNT_BIG(*) > 0 THEN N'FAIL' ELSE N'PASS' END, 0,
       N'Расхождение на порядок — почти всегда ошибка единиц/множителя, а не переоценка. Прямое влияние на LGD и покрытие. Источник находки — Управление оценки залогового обеспечения (30.06 и 20.07), нашей веткой не перепроверялось.'
FROM (
    SELECT c_source,
           TRY_CAST(nok_last_appraised_value AS decimal(38,2)) AS nok_val,
           TRY_CAST(c_collateral_value       AS decimal(38,2)) AS col_val
    FROM [Dictionaries].[risk_analytics].[pledges]
    WHERE c_reporting_date = @AsOf9
) v
WHERE nok_val IS NOT NULL AND col_val IS NOT NULL AND col_val > 0 AND nok_val > 0
  AND (nok_val / col_val > @ValueRatioFlag OR col_val / nok_val > @ValueRatioFlag)
GROUP BY c_source
OPTION (MAXDOP 1);
GO


/* =============================================================================
   L10. РЕЗОЛЮШН-ПАЙПЛАЙН: writeoff / collections / offbalance / bankrupt
   -----------------------------------------------------------------------------
   Назначение слоя: выходы из портфеля. Идёт ПОСЛЕ периметра сознательно:
   отсутствие строки здесь для S02/S17 — СТРУКТУРНОЕ свойство (домен этих
   таблиц ограничен S01/S03), а не дефект ключа. Ровно этот случай раньше
   принимали за «выбитый ключ» — «тройной ноль по трём таблицам».
   ============================================================================= */

DECLARE @RunStart datetime = (SELECT CONVERT(datetime,value,121) FROM ##RDW_PARAMS WHERE name=N'RunStart');
DECLARE @RowsSoFar int = (SELECT COUNT(*) FROM ##RDW_RESULTS);
RAISERROR(N'[L10 резолюшн] начало -- ' + CONVERT(nvarchar(19),GETDATE(),120)
    + N' (+' + CONVERT(nvarchar(10),DATEDIFF(SECOND,@RunStart,GETDATE())) + N' с от старта), строк в отчёте: '
    + CONVERT(nvarchar(10),@RowsSoFar), 0, 1) WITH NOWAIT;
DECLARE @AsOf10 date = (SELECT CONVERT(date,value) FROM ##RDW_PARAMS WHERE name=N'AsOf');

-- L10.1 Домен source по каждой таблице резолюшна — доказывает структурность
INSERT INTO ##RDW_RESULTS
SELECT 10, N'L10 резолюшн', N'L10.1', N'Dictionaries.'+tbl,
       N'Источников в домене таблицы: '+ISNULL(src,N'(NULL)'), src,
       N'rows', n, N'справочно', N'INFO', 0,
       N'Если S02/S17 здесь отсутствуют — «нет строки списания по карте» ЛЕГИТИМНО и не является дефектом ключа. Проверять это ДО того, как писать «договор потерян».'
FROM (
    SELECT N'writeoff'    AS tbl, [w_dlcr$source] AS src, COUNT_BIG(*) AS n
      FROM [Dictionaries].[risk_analytics].[writeoff]    GROUP BY [w_dlcr$source]
    UNION ALL
    SELECT N'offbalance', o_source, COUNT_BIG(*)
      FROM [Dictionaries].[risk_analytics].[offbalance]  GROUP BY o_source
    UNION ALL
    SELECT N'bankrupt',   b_source, COUNT_BIG(*)
      FROM [Dictionaries].[risk_analytics].[bankrupt]    GROUP BY b_source
) d
OPTION (MAXDOP 1);

-- L10.2 Гранулярность writeoff: строка = событие или строка = договор
INSERT INTO ##RDW_RESULTS
SELECT 10, N'L10 резолюшн', N'L10.2', N'writeoff',
       N'Строк на один договор (максимум)', NULL,
       N'max_rows_per_contract', MAX(c), N'1 = договор; >1 = событие',
       N'INFO', 0,
       N'Открытый вопрос S2T: «одна строка = один договор» или «= один факт списания». От ответа зависит, можно ли суммировать w_dlcrp_write_off_amount без дедупликации.'
FROM (SELECT w_dlcr_dog_num, COUNT_BIG(*) c
      FROM [Dictionaries].[risk_analytics].[writeoff]
      GROUP BY w_dlcr_dog_num) x
OPTION (MAXDOP 1);

-- L10.3 Сверка списаний с эталоном (регрессия: 73/73 точно, 138 741 177,22 ₸)
INSERT INTO ##RDW_RESULTS
SELECT 10, N'L10 резолюшн', N'L10.3', N'spis_v_ubytok_CL → writeoff',
       N'Событий списания старой ветки, не найденных в новой', NULL,
       N'writeoff_events_missing_in_new', COUNT_BIG(*), N'0',
       CASE WHEN COUNT_BIG(*) > 0 THEN N'FAIL' ELSE N'PASS' END, 0,
       N'Регрессия: ранее 73/73 совпали точно по суммам. Обратное направление (события только в новой) — отдельной строкой ниже, их было 4 на 11,6 млн ₸.'
FROM [CL_PORTFOLIO].[dbo].[spis_v_ubytok_CL] s
/* Скоуп по дате обязателен: spis_v_ubytok_CL — полная история (135 тыс. строк),
   writeoff — срез. Без фильтра проверка сравнивала историю со снимком и давала
   135 146 «пропавших событий», что было артефактом, а не находкой. */
WHERE TRY_CAST(s.[date] AS date) = @AsOf10
  AND NOT EXISTS (
    SELECT 1 FROM [Dictionaries].[risk_analytics].[writeoff] w
    WHERE CONVERT(nvarchar(255), w.w_dlcr_dog_num) = CONVERT(nvarchar(255), s.contract_number))
OPTION (MAXDOP 1);

INSERT INTO ##RDW_RESULTS
SELECT 10, N'L10 резолюшн', N'L10.4', N'writeoff → spis_v_ubytok_CL',
       N'Событий списания только в новой ветке', NULL,
       N'writeoff_events_only_new', COUNT_BIG(*), N'0 либо объяснено',
       CASE WHEN COUNT_BIG(*) > 0 THEN N'WARN' ELSE N'PASS' END, 0,
       N'Регрессия: 4 события / 11,6 млн ₸. Может быть легитимным (новая ветка полнее) — но должно быть объяснено, а не принято молча.'
FROM [Dictionaries].[risk_analytics].[writeoff] w
WHERE NOT EXISTS (
    SELECT 1 FROM [CL_PORTFOLIO].[dbo].[spis_v_ubytok_CL] s
    WHERE CONVERT(nvarchar(255), s.contract_number) = CONVERT(nvarchar(255), w.w_dlcr_dog_num))
OPTION (MAXDOP 1);
GO


/* =============================================================================
   L11. ГРАФИК И ПЛАТЕЖИ — поведенческая альтернатива сломанному DPD
   -----------------------------------------------------------------------------
   Назначение слоя: repayment_schedule (что должны) + payments (что заплатили)
   дают ЕДИНСТВЕННЫЙ способ посчитать просрочку, не доверяя days_past_due.
   Учитывая состояние L8, это не «приятное дополнение», а запасной контур
   для стадирования. Поэтому проверяется отдельно и явно.
   ============================================================================= */

DECLARE @RunStart datetime = (SELECT CONVERT(datetime,value,121) FROM ##RDW_PARAMS WHERE name=N'RunStart');
DECLARE @RowsSoFar int = (SELECT COUNT(*) FROM ##RDW_RESULTS);
RAISERROR(N'[L11 график и платежи] начало -- ' + CONVERT(nvarchar(19),GETDATE(),120)
    + N' (+' + CONVERT(nvarchar(10),DATEDIFF(SECOND,@RunStart,GETDATE())) + N' с от старта), строк в отчёте: '
    + CONVERT(nvarchar(10),@RowsSoFar), 0, 1) WITH NOWAIT;
DECLARE @AsOf11 date = (SELECT CONVERT(date,value) FROM ##RDW_PARAMS WHERE name=N'AsOf');

INSERT INTO ##RDW_RESULTS
SELECT 11, N'L11 график и платежи', N'L11.1', N'loans_active → repayment_schedule',
       N'Активных договоров без единой строки графика', a.l_source,
       N'active_without_schedule', COUNT_BIG(*), N'0 для аннуитетных',
       CASE WHEN COUNT_BIG(*) > 0 THEN N'WARN' ELSE N'PASS' END, 0,
       N'Для карт/овердрафтов график может законно отсутствовать — разбирать по продукту, а не считать дефектом целиком. Но без графика поведенческий DPD по этим договорам посчитать нельзя, и это ограничение запасного контура.'
FROM (SELECT DISTINCT l_source, l_loan_id FROM [Dictionaries].[risk_analytics].[loans_active]
      WHERE l_report_date = @AsOf11) a
/* Явное приведение обеих сторон к nvarchar: l_loan_id nvarchar против rs_loan_id
   bigint (см. L0.2). Без него JOIN не матчил ничего, и проверка рапортовала, что
   графика нет у ВСЕХ 586 717 активных договоров — это был артефакт типа. */
WHERE NOT EXISTS (SELECT 1 FROM [Dictionaries].[risk_analytics].[repayment_schedule] r
                  WHERE r.rs_source = a.l_source
                    AND CONVERT(nvarchar(255), r.rs_loan_id) = CONVERT(nvarchar(255), a.l_loan_id))
GROUP BY a.l_source
OPTION (MAXDOP 1);

INSERT INTO ##RDW_RESULTS
SELECT 11, N'L11 график и платежи', N'L11.2', N'repayment_schedule',
       N'Строк графика с пустой датой или пустой суммой', rs_source,
       N'schedule_rows_incomplete', COUNT_BIG(*), N'0',
       CASE WHEN COUNT_BIG(*) > 0 THEN N'WARN' ELSE N'PASS' END, 0,
       N'Строка графика без даты не участвует в расчёте просрочки и молча занижает её.'
FROM [Dictionaries].[risk_analytics].[repayment_schedule]
WHERE rs_repayment_date IS NULL
   OR (rs_principal_repayment_amount IS NULL AND rs_interest_repayment_amount IS NULL)
GROUP BY rs_source
OPTION (MAXDOP 1);

INSERT INTO ##RDW_RESULTS
SELECT 11, N'L11 график и платежи', N'L11.3', N'payments',
       N'Платежей с пустым счётом или пустой датой', p_source,
       N'payments_unusable', COUNT_BIG(*), N'0',
       CASE WHEN COUNT_BIG(*) > 0 THEN N'WARN' ELSE N'PASS' END, 0,
       N'Платёж без даты нельзя сопоставить с графиком ⇒ он не уменьшит расчётную просрочку, и поведенческий DPD будет завышен.'
FROM [Dictionaries].[risk_analytics].[payments]
WHERE p_CREDIT_ACCOUNT IS NULL OR p_VALUE_DATE IS NULL
GROUP BY p_source
OPTION (MAXDOP 1);
GO


/* =============================================================================
   L12. ПЕРИФЕРИЯ — restructuring_v2 / ratings / interest_rates и пр.
   -----------------------------------------------------------------------------
   Назначение слоя: не блокирует балансовый контур go-live, поэтому в конце.
   Но restructuring_v2 особая: это единственный источник периода приостановки
   (grace_*) и ОТМЕНЫ реструктуризации (canc_date) — без него не считается
   ни cure-правило, ни разрез Stage 3 по реструктуризации.
   ============================================================================= */

DECLARE @RunStart datetime = (SELECT CONVERT(datetime,value,121) FROM ##RDW_PARAMS WHERE name=N'RunStart');
DECLARE @RowsSoFar int = (SELECT COUNT(*) FROM ##RDW_RESULTS);
RAISERROR(N'[L12 периферия] начало -- ' + CONVERT(nvarchar(19),GETDATE(),120)
    + N' (+' + CONVERT(nvarchar(10),DATEDIFF(SECOND,@RunStart,GETDATE())) + N' с от старта), строк в отчёте: '
    + CONVERT(nvarchar(10),@RowsSoFar), 0, 1) WITH NOWAIT;
INSERT INTO ##RDW_RESULTS
SELECT 12, N'L12 периферия', N'L12.1', N'restructuring_v2',
       N'Событий с датой погашения РАНЬШЕ даты реструктуризации', [dlcr$source],
       N'maturity_before_restructuring', COUNT_BIG(*), N'0',
       CASE WHEN COUNT_BIG(*) > 0 THEN N'FAIL' ELSE N'PASS' END, 0,
       N'Логически невозможное событие. Регрессия: 184 из 4 520. Реструктуризация, «удлиняющая» срок в прошлое, ломает и cure-правило, и признак ухудшения.'
FROM [Dictionaries].[risk_analytics].[restructuring_v2]
WHERE new_maturity_date IS NOT NULL AND restructuring_date IS NOT NULL
  AND new_maturity_date < restructuring_date
GROUP BY [dlcr$source]
OPTION (MAXDOP 1);

INSERT INTO ##RDW_RESULTS
SELECT 12, N'L12 периферия', N'L12.2', N'restructuring_v2 (grace-даты)',
       N'Событий БЕЗ полностью заполненной пары grace-дат', [dlcr$source],
       N'events_without_usable_grace', COUNT_BIG(*), N'0',
       CASE WHEN COUNT_BIG(*) > 0 THEN N'WARN' ELSE N'PASS' END, 0,
       N'Полупустая пара непригодна: окно без конца проверить нельзя. Прямо ограничивает разрез Stage 3 «реструктурированные vs нет» — при высокой доле такой разрез перестаёт быть свидетельством.'
FROM [Dictionaries].[risk_analytics].[restructuring_v2]
WHERE NOT ((grace_od_begin_date  IS NOT NULL AND grace_od_end_date  IS NOT NULL)
        OR (grace_int_begin_date IS NOT NULL AND grace_int_end_date IS NOT NULL))
GROUP BY [dlcr$source]
OPTION (MAXDOP 1);

INSERT INTO ##RDW_RESULTS
SELECT 12, N'L12 периферия', N'L12.3', N'restructuring_v2 → loans',
       N'Событий реструктуризации без соответствующего договора', [dlcr$source],
       N'restructuring_without_loan', COUNT_BIG(*), N'0',
       CASE WHEN COUNT_BIG(*) > 0 THEN N'WARN' ELSE N'PASS' END, 0,
       N'Регрессия: 12 несопоставленных строк. Джойн по loan_id — предположение, применяемое во всём репозитории; если цифра велика, под вопросом сам ключ, а не данные.'
FROM [Dictionaries].[risk_analytics].[restructuring_v2] r
/* restructuring_v2 — журнал СОБЫТИЙ за всю историю, loans — срез на дату. Событие по
   договору, закрытому до @AsOf, законно не найдёт строку в срезе. Поэтому ищем договор
   в мастере БЕЗ фильтра даты (любой срез), иначе цифра меряет ротацию портфеля,
   а не целостность ключа. */
WHERE NOT EXISTS (SELECT 1 FROM [Dictionaries].[risk_analytics].[loans] l
                  WHERE l.l_source = r.[dlcr$source]
                    AND CONVERT(nvarchar(255),l.l_loan_id) = CONVERT(nvarchar(255),r.loan_id))
GROUP BY [dlcr$source]
OPTION (MAXDOP 1);
GO


/* =============================================================================
   L13. ФИНАЛЬНАЯ ВИТРИНА brm_all_data
   -----------------------------------------------------------------------------
   Проверяется последней, потому что является следствием всего вышеперечисленного.
   По интроспекции у неё видно всего 3 столбца — сам этот факт требует
   подтверждения S2T (витрина или заготовка?).
   ============================================================================= */

DECLARE @RunStart datetime = (SELECT CONVERT(datetime,value,121) FROM ##RDW_PARAMS WHERE name=N'RunStart');
DECLARE @RowsSoFar int = (SELECT COUNT(*) FROM ##RDW_RESULTS);
RAISERROR(N'[L13 витрина brm_all_data] начало -- ' + CONVERT(nvarchar(19),GETDATE(),120)
    + N' (+' + CONVERT(nvarchar(10),DATEDIFF(SECOND,@RunStart,GETDATE())) + N' с от старта), строк в отчёте: '
    + CONVERT(nvarchar(10),@RowsSoFar), 0, 1) WITH NOWAIT;
DECLARE @AsOf13 date = (SELECT CONVERT(date,value) FROM ##RDW_PARAMS WHERE name=N'AsOf');

INSERT INTO ##RDW_RESULTS
SELECT 13, N'L13 витрина brm_all_data', N'L13.1', N'brm_all_data',
       N'Столбцов в витрине', NULL,
       N'column_count', COUNT_BIG(*), N'ожидается > 3',
       CASE WHEN COUNT_BIG(*) <= 3 THEN N'WARN' ELSE N'INFO' END, 0,
       N'Если действительно 3 столбца — это не «финальная сводная витрина», и вопрос к S2T: подтягивается ли остальное на лету или витрина не достроена.'
FROM [Dictionaries].INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = N'risk_analytics' AND TABLE_NAME = N'brm_all_data'
OPTION (MAXDOP 1);

INSERT INTO ##RDW_RESULTS
SELECT 13, N'L13 витрина brm_all_data', N'L13.2', N'brm_all_data → loans',
       N'Строк витрины без договора в мастере', [source],
       N'brm_rows_without_loan', COUNT_BIG(*), N'0',
       CASE WHEN COUNT_BIG(*) > 0 THEN N'WARN' ELSE N'PASS' END, 0,
       N'Витрина, содержащая договоры вне мастера, не может быть согласована с балансом ни при каком раскладе.'
FROM [Dictionaries].[risk_analytics].[brm_all_data] b
WHERE TRY_CAST(b.actual_date AS date) = @AsOf13
  AND NOT EXISTS (SELECT 1 FROM [Dictionaries].[risk_analytics].[loans] l
                  WHERE l.l_report_date = @AsOf13 AND l.l_source = b.[source]
                    AND CONVERT(nvarchar(255),l.l_loan_number) = CONVERT(nvarchar(255),b.contract_number))
GROUP BY b.[source]
OPTION (MAXDOP 1);
GO


/* =============================================================================
   §REPORT — ИТОГ С УРОВНЕМ ДОВЕРИЯ
   -----------------------------------------------------------------------------
   TRUST_LEVEL — главное, что отличает этот отчёт от списка цифр. Результат
   слоя N не заслуживает доверия, если провален GATE любого слоя < N: сумма,
   посчитанная поверх размноженного JOIN, выглядит как число, но им не является.
   ============================================================================= */

DECLARE @RunStart datetime = (SELECT CONVERT(datetime,value,121) FROM ##RDW_PARAMS WHERE name=N'RunStart');
DECLARE @RowsSoFar int = (SELECT COUNT(*) FROM ##RDW_RESULTS);
RAISERROR(N'=== ВСЕ 14 СЛОЁВ ЗАВЕРШЕНЫ -- ' + CONVERT(nvarchar(19),GETDATE(),120)
    + N' (' + CONVERT(nvarchar(10),DATEDIFF(SECOND,@RunStart,GETDATE())) + N' с всего), строк в отчёте: '
    + CONVERT(nvarchar(10),@RowsSoFar) + N' ===', 0, 1) WITH NOWAIT;

-- Отчёт 1: сводка по слоям + до какого слоя вообще можно доверять
IF OBJECT_ID('tempdb..#gatefail') IS NOT NULL DROP TABLE #gatefail;
SELECT MIN(layer_no) AS first_failed_gate_layer
INTO #gatefail
FROM ##RDW_RESULTS
WHERE is_gate = 1 AND verdict = N'FAIL';

SELECT r.layer_no, r.layer_name,
       SUM(CASE WHEN r.verdict = N'PASS'    THEN 1 ELSE 0 END) AS pass_n,
       SUM(CASE WHEN r.verdict = N'FAIL'    THEN 1 ELSE 0 END) AS fail_n,
       SUM(CASE WHEN r.verdict = N'WARN'    THEN 1 ELSE 0 END) AS warn_n,
       SUM(CASE WHEN r.verdict = N'NO_BASE' THEN 1 ELSE 0 END) AS no_base_n,
       SUM(CASE WHEN r.verdict = N'INFO'    THEN 1 ELSE 0 END) AS info_n,
       SUM(CASE WHEN r.is_gate = 1 AND r.verdict = N'FAIL' THEN 1 ELSE 0 END) AS failed_gates,
       CASE WHEN g.first_failed_gate_layer IS NULL THEN N'ДОВЕРЯТЬ МОЖНО'
            WHEN r.layer_no < g.first_failed_gate_layer THEN N'ДОВЕРЯТЬ МОЖНО'
            WHEN r.layer_no = g.first_failed_gate_layer THEN N'СЛОЙ САМ ПРОВАЛЕН — чинить здесь'
            ELSE N'ДОВЕРЯТЬ НЕЛЬЗЯ — провален гейт L'
                 + CONVERT(nvarchar(3), g.first_failed_gate_layer) END AS trust_level
FROM ##RDW_RESULTS r CROSS JOIN #gatefail g
GROUP BY r.layer_no, r.layer_name, g.first_failed_gate_layer
ORDER BY r.layer_no
OPTION (MAXDOP 1);

-- Отчёт 2: блокеры — что чинить до перехода к следующему слою
SELECT layer_no, check_id, target_object, source_system, check_name,
       metric_name, metric_value, expected_value, note
FROM ##RDW_RESULTS
WHERE verdict = N'FAIL' AND is_gate = 1
ORDER BY layer_no, check_id, source_system
OPTION (MAXDOP 1);

-- Отчёт 3: полная детализация (перенос на BI-холст)
SELECT layer_no, layer_name, check_id, target_object, source_system, check_name,
       metric_name, metric_value, expected_value, verdict, is_gate, note
FROM ##RDW_RESULTS
ORDER BY layer_no, check_id, source_system
OPTION (MAXDOP 1);

-- Отчёт 4: параметры прогона — без них цифры невоспроизводимы
SELECT name, value FROM ##RDW_PARAMS ORDER BY name;

DROP TABLE #gatefail;

/* Уборка мостов. ##RDW_RESULTS НЕ удаляем — из него переносятся статусы
   на BI-холст. Удалить вручную: DROP TABLE ##RDW_RESULTS; */
IF OBJECT_ID('tempdb..##RDW_XB') IS NOT NULL DROP TABLE ##RDW_XB;
GO
