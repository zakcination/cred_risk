# Stage 3 "cure-under-relaxed-rules" sizing — methodology

**Ask (Damir, 17.07.2026):** many Stage 3 (IFRS 9 default) loans sit with low/zero
DPD — they defaulted once, repaid the overdue part, and keep paying, but the
strict cure rule keeps them in Stage 3. Retail Business (РБ) sized these at
**~12 bn ₸**. Risk must **confirm or refute** with our own data. Query:
[`sql/stage3_cure_candidates.sql`](../../sql/stage3_cure_candidates.sql).

## The two rules
| | Rule |
|---|---|
| **Strict (current)** | (1) fully repay all overdue, then (2) **6 consecutive months with DPD = 0** (no overdue at all). |
| **Relaxed (proposed to test)** | overdue repaid **and** DPD stayed within a small tolerance (`@DpdTolerance`, e.g. ≤ 5 days) over the window — minor slips allowed. |

## Candidate definition (what we count)
A loan is a **stuck-by-minor-slips** candidate when, over the last `@WindowMonths`
month-ends up to `@AsOf`, it is:
1. currently **Stage 3** at `@AsOf` (pluggable — see below);
2. **not materially overdue now**: `dpd_asof ≤ @CureEntryDpd` (overdue repaid);
3. **would cure under the relaxed rule**: `max DPD over window ≤ @DpdTolerance`;
4. **does not cure under the strict rule**: `max DPD over window ≥ 1` (had ≥1 overdue month — a minor slip, not a re-default).

So the target set is `max_dpd_window ∈ [1, @DpdTolerance]` with the overdue
currently cleared. We then **SUM(balance) at `@AsOf`** and compare to 12 bn ₸.

## Parameters (defaults reflect Damir's example)
| Param | Default | Meaning |
|---|---|---|
| `@AsOf` | `2026-07-01` | reporting date (Diana: start from 01.07.2026) |
| `@WindowMonths` | `6` | observation window (strict rule uses 6 clean months) |
| `@DpdTolerance` | `5` | relaxed slip tolerance in days (Damir's example ≈ 5) |
| `@CureEntryDpd` | `5` | max current DPD to treat the overdue as repaid |

**Sensitivity:** re-run for `@DpdTolerance ∈ {1, 5, 30}` and `@WindowMonths ∈ {3, 6}`
to bracket the number and find which relaxed rule reproduces РБ's 12 bn.

## Data approach
- Reuses the **six-source portfolio union** (S01 RS, S02 Cards ×3, S03 CrediLogic,
  S17 Fenix) — the same mapping as the B3B reconciliation — to build a per-contract
  **monthly DPD + balance** series, then aggregates over the window. This matches
  Magzhan's point that behaviour must be read across **several dates**, not one.
- `NULL` DPD is treated as **"no data"** (ignored), not as 0.

## Open decisions (blocking a final number)
1. **Stage-3 source.** `category`/`Basket` is the *delinquency bucket*, not the
   IFRS stage. Pick one: **(A)** РБ's contract list (Bereket asked РБ for it) →
   load into `#stage3`; **(B)** a stage column if one exists; **(C)** derive from
   default markers (ever-90+ / `collections` / `writeoff` / `bankrupt`). Default
   in the script is (A).
2. **DPD source & off-by-one.** Portfolio `dpd` is off-by-one (`= days_past_due − 1`)
   and NULL-heavy for S03. For the defensible number, drive off the mart
   `loan_account.days_past_due` or, best, **actual payments** (Diana: pull
   `repayment_schedule` vs `payments`/`payments_wiring`, days-late per installment).
   The DPD-snapshot version is the fast proxy; the payments version is the §PAYMENTS
   refinement in the script.
3. **Tolerance & window.** Confirm `@DpdTolerance = 5` and `@WindowMonths = 6`
   (or Magzhan's "last 3 months").

## To reconcile with РБ
Ask РБ for their contract list + methodology (tolerance, window, stage source).
Load their list into `#stage3`, run our query on it, and diff: same loans? same
balance? The gap tells us whether the 12 bn holds, and our sensitivity grid shows
which rule assumptions produce it.

## Review verification (21.07.2026)

Коллега прислал структурированную ревизию `sql/stage3_cure_candidates.sql` (7
сильных сторон + 10 критических ошибок + вопрос сопоставимости с "нашим
прежним показателем 37 379 млрд ₸"). Проверено построчно по фактическому коду
(не на слово), тем же методом, что и ревизии по БРМ-ветке. Статус: **все 10
пунктов подтверждены**, 7 сильных сторон — тоже, плюс одна самостоятельная
находка ниже.

### Сильные стороны — подтверждены
Все 7 пунктов рецензии точны: строгое/мягкое правило разделены явно (§0/§2
скрипта), `@AsOf`/`@WindowMonths`/`@DpdTolerance` параметризованы, `NULL dpd`
не приравнивается к 0 (`MAX(w.dpd)` игнорирует NULL по семантике SQL Server,
и в шапке скрипта это явно оговорено), `category`/`Basket` прямо названы
delinquency bucket, а не IFRS stage (см. открытый вопрос §1 выше и docstring
скрипта), sensitivity grid присутствует (§3, закомментирован), сверка с РБ
предложена (раздел "To reconcile" выше), и платёжный refinement
(`repayment_schedule` vs `payments`/`payments_wiring`) заложен как §PAYMENTS
в скрипте.

### Критические ошибки — все 10 подтверждены кодом

1. **Смешение источников по `contract_number` — подтверждено.** `per_contract`
   строится `GROUP BY w.contract_number` (без `source_system`), и `CROSS APPLY`
   ищет `asof_snap` тоже только по `w2.contract_number = w.contract_number`.
   9 659 cross-source коллизий — не выдумка рецензента, это задокументированный
   факт нашей же ветки (`credit_risk_knowledge_base.md`, `FINDINGS.md`,
   `risk_analytics_data_model.md`). `#stage3` тоже без источника. Ключ
   действительно должен быть `(source_system, contract_number)`.
2. **Окно 6 месяцев = 7 срезов — подтверждено.** `@WindowStart = DATEADD(MONTH,
   -6, @AsOf)` при `@AsOf='2026-07-01'` даёт `2026-01-01`; фильтр `snap_date
   BETWEEN @WindowStart AND @AsOf` включает янв-фев-мар-апр-май-июн-июл — семь
   месяц-концов, если снэпшоты ежемесячные. Комментарий скрипта обещает "the
   last @WindowMonths month-end snapshots" — реализация даёт на один больше.
3. **"На `@AsOf`" на деле = последний срез в окне — подтверждено.**
   `asof_snap = MAX(snap_date)` per-contract из `win`, не литерал `@AsOf`.
   Договор без июльского среза молча попадёт в вывод с июньским (или более
   старым) `balance_asof`/`dpd_asof`, и ничто в `WHERE`-фильтре §2 это не
   отсекает — `months_observed` считается, но не используется как условие.
4. **Нет проверки полноты DPD — подтверждено.** То же самое: `months_observed`
   и `months_overdue_in_window` вычислены, но не enforced в `WHERE`. Договор
   с одним `dpd=3` и пятью NULL месяцами пройдёт `max_dpd_window BETWEEN 1 AND
   5` как валидный кандидат.
5. **"Погашено" = DPD ≤ 5 — подтверждено как смысловая неточность.** Комментарий
   скрипта сам называет это "the overdue part is repaid", хотя DPD 1–5 означает
   непогашенную (просто малую) просрочку. Не вычислительный баг, а неточная
   формулировка, которая может ввести читателя в заблуждение насчёт того, что
   на самом деле измеряет цифра.
6. **Несопоставимость `balance` — подтверждено.** `ts` CTE аліасит четыре разных
   поля (`balance` ×3 источника, `Total_outstanding` ×2 источника) под одно имя
   `balance` без проверки, что это одна и та же база (principal vs gross
   carrying amount vs EAD). Ничего в скрипте эту эквивалентность не доказывает.
7. **Разная семантика DPD — подтверждено.** `dpd` (S01/S02×3/S03) и
   `overdue_days_principal` (S17) объединяются напрямую. Скрипт сам знает про
   off-by-one для S03 ("dpd = days_past_due - 1", шапка скрипта) — но нигде в
   теле запроса поправка `+1` не применяется.
8. **Нарушение правила конфиденциальности — подтверждено.** Активный (не
   закомментированный) `SELECT` в §2 — построчная выдача с `p.contract_number`
   первой колонкой. Агрегат §3 закомментирован, то есть выполняется НЕ он по
   умолчанию. Правило "PII не выводить: … номера договоров …" явно
   зафиксировано в `docs/analysis/risk_dwh_reconciliation/CLAUDE.md` и в духе
   README "commit only … de-identified/aggregate analysis" — применимо и здесь.
9. **Риск нагрузки — подтверждено.** `ts` объединяет шесть таблиц (одна из них,
   `CL_PORTFOLIO_2`, ранее у нас же подтверждена на ~7.1 млн строк) без
   date-фильтра внутри каждой ветки UNION; `win` фильтрует уже поверх
   TRY_CAST-колонки — non-sargable по той же причине, что задокументирована в
   CLAUDE.md для `UPPER(LTRIM(RTRIM()))`. В файле нет ни одного `OPTION
   (MAXDOP …)`.
10. **Sensitivity grid ищет параметры под 12 млрд — подтверждено дословно.**
    Комментарий скрипта: "re-run … to bracket the number and see which relaxed
    rule reproduces РБ's 12 bn" — это и есть definition of confirmation bias:
    подбор порога под известный ответ, а не независимое утверждение порога до
    расчёта.

### Самостоятельная находка: "37 379 млрд" не задокументировано нигде в репозитории
Проверено `git grep` по **всей** истории **всех** веток (`git grep ... $(git
rev-list --all)`) на "37379"/"37 379"/"37,379"/"37.379" — **ноль совпадений**.
Эта цифра не встречается ни в одном коммите ни на одной ветке этого
репозитория. Значит либо она из внешнего контекста (переписка/файл вне
репо), либо из памяти рецензента — в любом случае, прежде чем сравнивать её с
12 млрд РБ или с суммой из `stage3_cure_candidates.sql`, нужен явный источник
и определение метрики (провизии? ECL? непокрытая экспозиция Stage 3 без
90+?). Без этого сравнение "нашей" цифры с 12 млрд РБ не имеет опоры — сама
рецензия это в целом верно отмечает, но так же не даёт источника 37 379.

### Важный нюанс, которого нет в тексте рецензии: PR №16 уже частично самокорректировался
`sql/stage3_cure_candidates.sql` — не единственный и не последний скрипт в
PR №16. Позже в этом же PR добавлены `stage3_cure_funnel.sql`,
`stage3_cure_pool.sql`, `stage3_dpd_trajectory.sql` — и все три:
- скоуплены на **один источник** (`CL_PORTFOLIO_2` / S03), то есть пункты 1,
  6, 7 (cross-source смешение) для них не применимы по конструкции;
- `stage3_cure_funnel.sql` явно берёт `category = '3'` как IFRS stage и
  исключает `tag = '11'` (списано/off-balance) — то есть напрямую закрывает
  "Open decisions #1" из этого файла (Stage-3 source);
- шапка `stage3_cure_funnel.sql` дословно написано: *"Grounded on the
  reviewer's query (17.07.2026)"* — то есть автор PR уже учёл (как минимум
  частично) именно эту рецензию при написании следующих скриптов.

Из этого следует: `stage3_cure_candidates.sql` остаётся в репозитории со всеми
10 найденными проблемами непочиненным — это первый черновой скрипт, а не
финальная версия анализа. Кто будет опираться на числа из PR №16, должен
использовать `funnel`/`pool`/`trajectory`, а не `stage3_cure_candidates.sql`
напрямую, либо явно пофиксить перечисленные 10 пунктов в последнем.

### Безопасный вывод
Ревизия PR №16 (10 пунктов) технически точна на 10 из 10 при построчной
проверке — не общие слова, а конкретные конструкции кода. Число **12 млрд**
РБ этим скриптом ни подтверждено, ни опровергнуто: `stage3_cure_candidates.sql`
даёт методологический прототип с реальными дырами (составной ключ, окно,
"as-of", полнота истории, конфиденциальность, нагрузка, confirmation-bias
sensitivity), а более поздние скрипты того же PR (`funnel`/`pool`/`trajectory`)
уже сузились до одного источника и явного stage-предиката — это лучшая база
для защищаемой цифры, но их я ещё не проверял тем же методом (следующий шаг).
"37 379 млрд" как точка сравнения не имеет подтверждённого источника в
репозитории — использовать её нельзя, пока не найдена её origin и метрика.
