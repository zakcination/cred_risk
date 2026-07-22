# B3B Collection — Process Guide & Runbook

Practical runbook for assembling the **AQR B3B** form. It complements the
official *«Инструкция по AQR B3B.docx»* (which says *what* and *for whom*); this
file says *how* — the SQL, the source-system split, status logic, the
audited-year rule, escalation, and the **lessons learned / process gaps** to fix
before the next cycle.

> Companion: the reconciliation check in
> [`sql/b3b_reconciliation_2025.sql`](../sql/b3b_reconciliation_2025.sql) and its
> [README](../sql/README.md) — use it as the completeness safety-net (see §7).

---

## 1. What B3B is
B3B is the list of **special-case contracts**: loans that were present at the
start of a quarter and **disappeared by its end**. They affect the **PD**
calculation. The trigger is **АФР**, which sends the final special-cases list;
it is routed to **ОРИЗ / ОПАиРОЗ** to fill in closing dates and write-off marks.

The **source of truth is the АФР list**, not any preliminary self-built list. A
preliminary list (from the B1A tables) can be prepared in advance to cover most
of the population, but it never replaces reconciliation against the АФР list.

## 2. Source-system distribution (who owns what)
Each `loan_id` belongs to **one** source system. Split the АФР list by
`source_system` and route each slice to its owner:

| Source | System | Owner / where to request |
|---|---|---|
| `W` | Cards | Cards team |
| `CL` | CrediLogic | CrediLogic owner ("Гроз Б.М.Э.") |
| `RS` | RS | Naumen Helpdesk — **but see the ORIZ sub-zone below** |
| `EBCL` | Fenix | Naumen Helpdesk |
| — | ОУСА / KUSA | handled separately, with confirming screenshots |

**RS is split between two teams:**

| RS sub-zone | Owner |
|---|---|
| **Portfolio RS + Individual Loans (Индивидуальные Займы / INDLOANS)** | **ORIZ** |
| the remainder of RS | ОПАиРОЗ |

> ⚠️ **Responsibility is not purely by source system.** Within `RS`, the
> **Portfolio RS + Individual Loans (Индивидуальные Займы)** segment is
> **ORIZ's** responsibility; the rest is ОПАиРОЗ's. Whoever prepares the RS
> slice **must** split out the ORIZ segment, hand it to ORIZ, and include ORIZ
> on the distribution. This is exactly where the 2026 cycle broke — see §7.2.

## 3. Requesting data from owners
Request **closing dates** and **write-off marks** from each owner. Today these
are one-off emails / Naumen tickets; the Cards and CrediLogic close-date feeds
are candidates for a standing DWH task so the process is reproducible and
auditable.

## 4. Status mapping & the audited-year rule
From the returned data, set the dropdown status and the matching date:

| Condition | Status | Date field |
|---|---|---|
| `dte_close` (CrediLogic) / `DATE_EXPIRE` (cards) NOT NULL | fully repaid / closed | closing date |
| written off to loss | written off to loss | `dte_writeoff` |
| written off off-balance | written off off-balance | `dte_Tag11_last` |
| present in the sales DB | assignment of rights (cession) | selling date |

**Priority when several conditions match** (strong → weak): 1) sale/cession,
2) written off to loss, 3) written off off-balance, 4) repaid/closed. Fix this
order with methodology so the status does not drift between runs.

**§ Audited-year rule (critical).** Before mapping, **filter all dates to the
audited year only** — a repayment / write-off / close date you record **must
fall in 2025**. A date outside the audited year is the "closed before 2025 but
reported in 2025" contradiction the regulator challenges. Use the reconciliation
check (§7) to find loans whose actual last portfolio presence is **before 2025**.

> Take care with the sales/cession comment: "assignment of rights" is chosen
> because it is legally precise, **not** to avoid the word "sale". Confirm the
> same `loan_id` is treated as a sale consistently in LGD / B3D — a comment that
> hides the economic substance from the regulator is the same "bank not open in
> their positions" risk already raised on B3D.

## 5. Escalation of the unrecognized remainder
Whatever automatic mapping does not close is escalated to the nearest colleagues
in the risk department (**ОПАиРОЗ**) for manual entry. The consolidated version
is assembled only after the remainder is closed.

**2026 cycle remainder** (per the 15 Jul escalation): of **217 059** records,
**8 089** had no comment → **208 970** processed. Remainder by source:

| Source | Count |
|---|---|
| W (Cards) | 5 829 |
| CL | 852 |
| RS | 752 |
| EBCL | 655 |
| Заём ОУСА | 1 |
| **Total** | **8 089** |

> 📌 **Count discrepancy to reconcile.** The 15 Jul mail cites **217 059**
> total; the prior guide cited **271 059**. The remainder (8 089) matches in
> both, but the base differs by 54 000 — verify which total is correct before
> sign-off.

## 6. After acceptance
After АФР accepts the template it usually asks for the **sources of repayment**
as confirmation (request to the Operations Department and БЦБ). Final data go to
АФР. The finished B3B file is loaded to history (**RISKDWH → `CL_PORTFOLIO`**)
for later reconciliations.

### 6.1 «Комментарии/пояснения Банка» — sources-of-repayment comment template

The 2025-cycle submission (25 loans) established a **fixed comment style per
АБИС (source system)**, identifiable by the loan reference's own format — reuse
it verbatim rather than free-writing a new comment per loan:

| АБИС | Loan-ref format | Comment template |
|---|---|---|
| **РС-Банк** | `NNN/SO/N`, `F../../.../SO/N` | Full transaction narrative: source account, amount, payment purpose, counterparty (e.g. *"погашение с текущего счета клиента (поступление на сумму … с назначением — …)"*) — written per loan, not templated, since the underlying transaction differs each time. |
| **Кредилоджик** | `L21…` / `L22…` (10-digit, no `/SO/`) | *«вложены реестры входящих платежей и детальные выписки (развернутые графики платежей)»* — boilerplate; attach the incoming-payment registry + detailed statement instead of narrating the transaction. |
| **Way4 (Cards)** | `KZ…A…` (IBAN-style) | *«вложены выписки и скрин с АБИС»* — boilerplate; attach the statement + an АБИС screenshot. |
| *(cancelled agreement, any АБИС)* | — | *«ДБЗ [ref] был отменён [date] на основании выписки № [ref] от [date][, и поступившие входящие платежи на общую сумму … тенге были возвращены клиенту / Входящих платежей от клиента не было]»* — used instead of the above when the loan agreement itself was cancelled, not repaid. |

**2026 cycle:** supporting statements (`выписки`) for this year's confirmation
live at `R:\!!!!!!AQR_2026\B3B\на отправку\22.07.2026\выписки`. Classify this
year's population by loan-ref format (same rule as above) and apply the
matching template; [`sql/b3b_repayment_comment_template.sql`](../sql/b3b_repayment_comment_template.sql)
does the classification mechanically instead of eyeballing 200+ refs one by one.

> ⚠ **Misroute risk.** A loan whose ref is `L21…` (Кредилоджик format) but was
> asked of the wrong team will come back as "not in our system" instead of a
> real confirmation — this already happened once this cycle (loan
> `020206601187`, ref `L211204400204` — RS/УАБО correctly said *"не в
> компетенции УАБО (не относится к RSbank)"* because it's actually a
> Кредилоджик loan). Classify by ref format **before** routing the request,
> not after a department bounces it.

---

## 7. Process gaps & lessons learned

### 7.1 Recurring gaps (carry-over)
1. **Remainder concentrated in Cards.** ~72% of the unrecognized remainder
   (5 829 of 8 089) is `W` (Cards). Fix the card **close-date feed** as a
   standing DWH task instead of escalating the tail by hand every cycle.
2. **Pre-list ≠ final list.** The preliminary list is not a production step; it
   covers part of the population — reconciliation against the АФР list is always
   required.
3. **Sales comment consistency.** "Assignment of rights" must be consistent with
   LGD / B3D and never used to obscure a sale (§4).
4. **Status priority not fixed.** Agree the priority order with methodology (§4).
5. **Manual letters/escalations** for close dates are candidates for a standing
   DWH task / Naumen template.

### 7.2 2026 cycle — ORIZ responsibility zone omitted (communication gap) 🔴

**What happened.** While filling the **RS** source, the ОПАиРОЗ colleague
handling it **skipped the ORIZ zone of responsibility**, and the initial B3B
distribution message did **not include ORIZ** as a recipient or in copy. As a
result, of the ~8 089 remainder, **717 loans belonging to ORIZ were never
tasked to ORIZ** and — discovered at the deadline — were **left unfilled**.

**ORIZ's zone within RS.** **Portfolio RS + Individual Loans (Индивидуальные
Займы / INDLOANS)** are ORIZ's part of the RS source (see §2). The 717 unfilled
loans fall in this segment.

**Root cause.** A communication/hand-off failure: the person preparing the RS
slice knew (or should have known) that the Portfolio RS + Individual Loans
segment is ORIZ's zone and **should have flagged it and included ORIZ** on the
distribution. Responsibility was treated as purely per-source-system, but RS
contains an ORIZ sub-zone (see §2).

**Impact.** 717 loans unfilled at the deadline; risk of an incomplete B3B
submission and regulator questions.

**Corrective measures (taken this cycle).**
1. **Forward the ORIZ slice to ORIZ now** and request them to fill the data
   (closing dates / write-off marks) for the 717 loans.
2. **Ask the regulator (АФР) to extend the deadline** to **tomorrow 18:00** to
   allow ORIZ to complete their zone.

**Prevention (next cycle).**
- Maintain an explicit **source-system → responsible-team RACI**, including
  **sub-zones**: RS = **ORIZ** for *Portfolio RS + Individual Loans
  (Индивидуальные Займы)*, ОПАиРОЗ for the rest — so no zone is silently skipped.
  Encode the split as a filter (RS-source loans flagged as Individual Loans →
  ORIZ) so the ORIZ population can be extracted mechanically each cycle.
- The initial distribution email **must include every responsible team**
  (ORIZ in recipients/cc) for their zone from the start.
- Add a **completeness check before the deadline**: reconcile the count assigned
  per team against the remainder breakdown by source, so an unassigned
  sub-population (like the 717) surfaces early — the reconciliation script in
  `sql/` is the tool for this (it flags loans with no filled outcome / no 2025
  activity per `source_system`).
- **Escalate deadline risk on discovery, not at the deadline.**

### 7.3 2026 cycle — 20 loans mis-marked «полное погашение» found via write-off ledger cross-check 🔴

**What happened.** A manual read of the department comments provided to prove
the submitted statuses caught **4** loans (`680917300967`, `830301402913`,
`760513350200`, `501213400735`) whose comment explicitly said "written off to
loss" / "recognized bankrupt" — directly contradicting the submitted
**полное погашение** status. Cross-checking the same submission against
**`spis_v_ubytok_RS`** (the RS write-off-to-loss ledger in `CL_PORTFOLIO`)
found the real count is **20** — the manual comment read missed **16 of 20**
(80%) of the actual contradictions.

**Root cause.** Comment text is free-form and inconsistently worded (§8.3)
— reading it catches only the cases where the filler happened to say the
right words. A structural cross-check against the write-off ledger catches
every case where the two data sources disagree, regardless of wording.

**Corrective measures (this cycle).** The 20 loans are being corrected from
`полное погашение` to `списание` before submission.

**Prevention (next cycle) — standing QC gate.**
[`sql/b3b_writeoff_qc_check.sql`](../sql/b3b_writeoff_qc_check.sql) turns this
into a repeatable check: every loan submitted as `полное погашение` is joined
against the write-off ledger(s); any match is a contradiction to fix before
submission, not after. Run it straight after `b3b_comment_mapping.sql`, same
session, and treat a nonzero count as a submission blocker without a
documented override. `spis_v_ubytok_RS` only covers the **RS** source — check
whether CL / Fenix / Cards have an equivalent ledger (the script's §0b sweep
looks for `spis_v_ubytok_%` siblings) and repeat the cross-check per source
system found, the same way the six-source split already works in
`b3b_reconciliation_2025.sql`.

### 7.4 Operational notes (2026 cycle)
- Working folder: `R:\...\AQR_2026\B3B\<date>\Рабочая папка`; Fenix data recorded
  in `EUB_B3B_v0`.
- Reminder for fillers: **if you record a repayment or write-off, the date must
  be in 2025** (audited-year rule, §4).

---

## 8. Column E «Причина» — official reference & comment mapping

The NBRK B3B form («Список особых случаев», file `EUB_B3B_v0.xlsx`) requires, for
each loan that disappeared from B1A in 2025, a **reason in column E** taken from a
fixed dropdown, plus conditional columns. **Deadline: 18:00, 16.07.2026.**

### 8.1 Official column-E vocabulary (use these values exactly)
- `списание`
- `реструктуризация / модификация`
- `полное погашение`
- `проданный финансовый актив`
- `пролонгация путем выдачи нового займа`
- `иное`

### 8.2 Conditional columns
| If column E = | then fill |
|---|---|
| `проданный финансовый актив` | **H** — buyer type (коллекторское агентство / ЧСИ / организация по управлению стрессовыми активами / БВУ / …) |
| `реструктуризация / модификация` | **G** — the related ID in the other slice |
| `пролонгация путем выдачи нового займа` | **G** — the related ID |
| `иное` | **F** — free-form explanation |

### 8.3 Mapping of the observed raw comments → column E
Applied in bulk by [`sql/b3b_comment_mapping.sql`](../sql/b3b_comment_mapping.sql).
**⚠ = confirm before submission** (goes to the regulator).

Decisions taken **16.07.2026** (✅ = finalized, 🟡 = left open):

| Raw comment (as entered) | → Column E «Причина» | F / G / H | Status |
|---|---|---|---|
| `СПИСАННЫЕ НА ВНЕСИСТЕМНЫЙ УЧЕТ` | списание | — | ✅ off-balance write-off; date 2025 |
| `СПИСАННЫЕ В УБЫТОК` | списание | — | ✅ loss write-off; date 2025 |
| `Полное погашение` | полное погашение | — | ✅ exact |
| `продажа` | **иное** | F: «по данному займу была переуступка прав требования по кредиту в СФК (специальная финансовая компания)» | ✅ cession to SFK → иное (not «проданный финансовый актив») |
| `прощение` | **иное** | F: «по данному займу была процедура прощения» | ✅ |
| `Обратный выкуп, списан` | **иное** | F: «Данный займ был переуступлен, после переуступки обратно возвращён на баланс банка, далее был списан в убыток» | ✅ |
| `Отменен` | **иное** | F: «займ был выдан и отменен (аннулирован): по денежным займам — в течение 5 раб. дней без решения УО, по истечении 5 дней — на основании решения УО Банка; по автозаймам — в течение 14 раб. дней» | ✅ |
| `Баланс меньше 5000` | **иное** | F: «Порог отсечения менее 5000 тг» | ✅ |
| `0` | — | — | 🟡 open — unfilled, complete manually |
| `Открытый` | — | — | 🟡 open — loan still OPEN, should not be in B3B; investigate (reconciliation check) |
| *ОУСА block* (Парасат / Алиби / Алиби-Агро / Сайхинстройсервис) | **split per loan** | **H**: attach АБИС screenshots | 🟡 Парасат = полное погашение (Q2 2025); Алиби group = списание на внесистемный учет (Q4 2025) |

> **Transparency note (from §4).** `продажа` is recorded as **иное** with a
> cession-to-СФК explanation rather than «проданный финансовый актив». Keep this
> consistent with how the same `loan_id` is treated in LGD / B3D — the reason
> should reflect economic substance, not obscure a sale.

Two of the open values are **not** disposal reasons and need attention rather
than a straight map:
- **`Открытый`** — the loan is still active, so it should not be a "disappeared"
  special case. Run `sql/b3b_reconciliation_2025.sql`: if it has 2025 snapshots,
  its inclusion in B3B is the thing to challenge, not its reason.
- **`0`** — empty placeholder; these are unfilled and must be completed manually.

### 8.4 Consolidated reusable comment — zero-EAD explanation
Several written-off loans carried near-duplicate free-text explaining why EAD was
zero in some quarters and then rose (accumulated discount exceeded the loan's book
value; the discount is released by year-end). Column E for these stays **списание**;
use this **one general comment** as the supplementary explanation (column H /
notes) instead of the quarter-specific variants:

> Нулевое значение EAD в отдельных кварталах отчетного года обусловлено тем, что
> накопленный дисконт превышал балансовую задолженность займа, в связи с чем
> расчетное значение EAD принимало отрицательное значение. К концу отчетного года
> (01.01.2025) счета по дисконтам обнуляются, что привело к увеличению значения EAD.

It generalizes the per-quarter originals (Q3 / Q2 / Q1–3 → «в отдельных кварталах
отчетного года»; the per-date discount release → «к концу отчетного года
(01.01.2025) счета по дисконтам обнуляются»).
