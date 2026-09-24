/* =============================================================================
   RPT_E — установить, чем размечается СТРОКА отчёта.

   ЗАЧЕМ. Метрики отчёта — это столбцы, и половина из них готова. Строк нет
   ни одной: сегментация НСТ построена каскадом на полях CL_PORTFOLIO
   (debtor_type_n, loan_obj_n, ent_type_n), которых в витрине нет.
   Пока не установлено, чем размечается сегмент, таблица фактов
   сегмент × месяц × метрика не имеет ключа и не пишется.

   ЧТО ИЗМЕРЯЕМ. Домен, мощность и заполненность полей-кандидатов на разметку.
   Не семантику: §4 — имя колонки не равно семантике, поэтому домен выводится
   целиком, а не проверяется на совпадение с ожидаемым.

   В КАКОМ РАЗРЕЗЕ. Источник. Поле, живое на одном источнике, разметкой
   портфельного отчёта быть не может по построению.

   ЧТО СЧИТАЕТСЯ ИСХОДОМ.
     блок 1 — РЕШАЮЩИЙ. l_segment. Если домен — это узнаваемые коды
              сегментации (RETCAR, RETCON, CORLAR…) и поле заполнено на всех
              четырёх источниках, каскад НЕ переносится, а берётся готовым,
              и блоки 2-4 не нужны. Если домен — что угодно другое, поле
              носит имя сегмента, не будучи им, и дальше читаются блоки 2-4.
     блок 2 — l_entrepreneur_category: подтвердить, что это ФЛ/ЮЛ, и получить
              домен целиком. Первое условие каскада стоит на нём.
     блок 3 — шесть кандидатов на объект кредитования. Годится тот, у кого
              мощность домена мала (объект — справочник, а не свободный текст),
              заполненность высока на всех четырёх источниках, и значения
              повторяются между источниками. Поле с сотнями значений —
              свободный ввод, как l_branch_code с 17 названиями на код.
     блок 4 — размер предприятия: подтвердить отсутствие. Выводится домен
              всех кандидатов, у которых в имени есть признак размера.
              Пусто — три корпоративных сегмента не размечаются, и это
              фиксируется как предел отчёта, а не как незакрытая задача.

   ЧЕГО ЭТОТ СКРИПТ НЕ ДЕЛАЕТ. Не размечает ни одного договора и не выбирает
   поле. По §6 выбор разметки принадлежит автору — вариантов семь, и по
   результату не видно, какие отброшены, если выбрать молча.

   ПОЧЕМУ БЛОКИ РАЗДЕЛЕНЫ GO. Прогон RPT_D 24.09.2026 упал на несуществующем
   имени и унёс весь батч: ошибка привязки валит все блоки сразу. Здесь имён
   ещё больше, поэтому блок 0 берёт список колонок из INFORMATION_SCHEMA,
   а GO делает цену неверного имени равной одному блоку.

   Read-only. PII не выводится: только имена значений и счётчики.
   ============================================================================= */
SET NOCOUNT ON;
GO

/* ─────────────────────────────────────────────────────────────────────────
   0. ЖИВОЙ АУДИТ ИМЁН. Колонки loans, похожие на разметку.
      Читать первым. Кандидата нет в списке — блок под него не выполнять.
   ───────────────────────────────────────────────────────────────────────── */
SELECT    c.COLUMN_NAME
        , c.DATA_TYPE
        , c.CHARACTER_MAXIMUM_LENGTH
        , c.IS_NULLABLE
FROM      [Dictionaries].[INFORMATION_SCHEMA].[COLUMNS] AS c
WHERE     c.TABLE_SCHEMA = 'risk_analytics'
      AND c.TABLE_NAME   = N'loans'
      AND (   c.COLUMN_NAME LIKE '%segment%'  OR c.COLUMN_NAME LIKE '%object%'
           OR c.COLUMN_NAME LIKE '%purpose%'  OR c.COLUMN_NAME LIKE '%product%'
           OR c.COLUMN_NAME LIKE '%type%'     OR c.COLUMN_NAME LIKE '%categor%'
           OR c.COLUMN_NAME LIKE '%size%'     OR c.COLUMN_NAME LIKE '%entrepre%'
           OR c.COLUMN_NAME LIKE '%class%'    OR c.COLUMN_NAME LIKE '%tag%')
ORDER BY  c.COLUMN_NAME;
GO

/* ─────────────────────────────────────────────────────────────────────────
   1. РЕШАЮЩИЙ. l_segment — домен целиком.
      Узнаваемые коды сегментации на всех источниках → каскад берётся готовым.
      Что угодно другое → поле носит имя сегмента, не будучи им.
   ───────────────────────────────────────────────────────────────────────── */
SELECT    l.l_source
        , l.l_segment
        , COUNT_BIG(*)                                                       AS loans
FROM      [Dictionaries].[risk_analytics].[loans] AS l
GROUP BY  l.l_source, l.l_segment
ORDER BY  l.l_source, loans DESC
OPTION (MAXDOP 1);
GO

/* ─────────────────────────────────────────────────────────────────────────
   2. l_entrepreneur_category — первое условие каскада (ФЛ / ЮЛ).
   ───────────────────────────────────────────────────────────────────────── */
SELECT    l.l_source
        , l.l_entrepreneur_category
        , COUNT_BIG(*)                                                       AS loans
FROM      [Dictionaries].[risk_analytics].[loans] AS l
GROUP BY  l.l_source, l.l_entrepreneur_category
ORDER BY  l.l_source, loans DESC
OPTION (MAXDOP 1);
GO

/* ─────────────────────────────────────────────────────────────────────────
   3а. Мощность доменов шести кандидатов на объект кредитования.
       Сначала агрегат: сколько различных значений и сколько заполнено.
       Мощность в сотнях — свободный ввод, а не справочник; такое поле
       разметкой быть не может, и детализацию по нему смотреть незачем.
   ───────────────────────────────────────────────────────────────────────── */
SELECT    l.l_source
        , COUNT_BIG(*)                                                       AS loans_total
        , COUNT(DISTINCT l.l_credit_object)                                  AS d_credit_object
        , SUM(CASE WHEN l.l_credit_object   IS NOT NULL THEN 1 ELSE 0 END)   AS f_credit_object
        , COUNT(DISTINCT l.l_credit_purpose)                                 AS d_credit_purpose
        , SUM(CASE WHEN l.l_credit_purpose  IS NOT NULL THEN 1 ELSE 0 END)   AS f_credit_purpose
        , COUNT(DISTINCT l.l_loan_purpose)                                   AS d_loan_purpose
        , SUM(CASE WHEN l.l_loan_purpose    IS NOT NULL THEN 1 ELSE 0 END)   AS f_loan_purpose
        , COUNT(DISTINCT l.l_loan_type)                                      AS d_loan_type
        , SUM(CASE WHEN l.l_loan_type       IS NOT NULL THEN 1 ELSE 0 END)   AS f_loan_type
        , COUNT(DISTINCT l.l_product_type)                                   AS d_product_type
        , SUM(CASE WHEN l.l_product_type    IS NOT NULL THEN 1 ELSE 0 END)   AS f_product_type
        , COUNT(DISTINCT l.l_subproduct_type)                                AS d_subproduct_type
        , SUM(CASE WHEN l.l_subproduct_type IS NOT NULL THEN 1 ELSE 0 END)   AS f_subproduct_type
FROM      [Dictionaries].[risk_analytics].[loans] AS l
GROUP BY  l.l_source
ORDER BY  l.l_source
OPTION (MAXDOP 1);
GO

/* 3б. Детализация — только по l_credit_object, самому прямому по имени.
       Двадцать верхних значений: если их двадцать и они покрывают почти всё,
       поле справочное. Если двадцать верхних покрывают долю процента —
       это свободный ввод, и остальные кандидаты смотрятся так же. */
SELECT TOP (20)
          l.l_credit_object
        , COUNT_BIG(*)                                                       AS loans
        , COUNT(DISTINCT l.l_source)                                         AS sources
FROM      [Dictionaries].[risk_analytics].[loans] AS l
WHERE     l.l_credit_object IS NOT NULL
GROUP BY  l.l_credit_object
ORDER BY  loans DESC
OPTION (MAXDOP 1);
GO

/* ─────────────────────────────────────────────────────────────────────────
   4. Размер предприятия — подтвердить отсутствие.
      Пусто — CORLAR, CORMED, RETSML не размечаются, и это предел отчёта,
      а не незакрытая задача. Не пусто — каскад переносится целиком.
   ───────────────────────────────────────────────────────────────────────── */
SELECT    c.TABLE_NAME
        , c.COLUMN_NAME
        , c.DATA_TYPE
FROM      [Dictionaries].[INFORMATION_SCHEMA].[COLUMNS] AS c
WHERE     c.TABLE_SCHEMA = 'risk_analytics'
      AND (   c.COLUMN_NAME LIKE '%size%'      OR c.COLUMN_NAME LIKE '%ent_type%'
           OR c.COLUMN_NAME LIKE '%enterprise%' OR c.COLUMN_NAME LIKE '%headcount%'
           OR c.COLUMN_NAME LIKE '%employee%'  OR c.COLUMN_NAME LIKE '%revenue%'
           OR c.COLUMN_NAME LIKE '%turnover%'  OR c.COLUMN_NAME LIKE '%msb%'
           OR c.COLUMN_NAME LIKE '%sme%')
ORDER BY  c.TABLE_NAME, c.COLUMN_NAME;
GO
