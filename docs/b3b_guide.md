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
| `RS` | RS | Naumen Helpdesk — **see the ORIZ sub-zone in §7** |
| `EBCL` | Fenix | Naumen Helpdesk |
| — | ОУСА / KUSA | handled separately, with confirming screenshots |

> ⚠️ **Responsibility is not purely by source system.** Within a source system
> there can be a **sub-zone owned by a different team** (e.g. part of `RS` is
> **ORIZ's** responsibility). Whoever prepares a source-system slice **must**
> identify and hand off any sub-zone they do not own, and include that team on
> the distribution. This is exactly where the 2026 cycle broke — see §7.

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

**Root cause.** A communication/hand-off failure: the person preparing the RS
slice knew (or should have known) that part of RS is ORIZ's zone and **should
have flagged ORIZ's zone of responsibility and included ORIZ** on the
distribution. Responsibility was treated as purely per-source-system, but RS
contains an ORIZ sub-zone (see §2 warning).

**Impact.** 717 loans unfilled at the deadline; risk of an incomplete B3B
submission and regulator questions.

**Corrective measures (taken this cycle).**
1. **Forward the ORIZ slice to ORIZ now** and request them to fill the data
   (closing dates / write-off marks) for the 717 loans.
2. **Ask the regulator (АФР) to extend the deadline** to **tomorrow 18:00** to
   allow ORIZ to complete their zone.

**Prevention (next cycle).**
- Maintain an explicit **source-system → responsible-team RACI**, including
  **sub-zones** (RS is split between ОПАиРОЗ and **ORIZ**), so no zone is
  silently skipped.
- The initial distribution email **must include every responsible team**
  (ORIZ in recipients/cc) for their zone from the start.
- Add a **completeness check before the deadline**: reconcile the count assigned
  per team against the remainder breakdown by source, so an unassigned
  sub-population (like the 717) surfaces early — the reconciliation script in
  `sql/` is the tool for this (it flags loans with no filled outcome / no 2025
  activity per `source_system`).
- **Escalate deadline risk on discovery, not at the deadline.**

### 7.3 Operational notes (2026 cycle)
- Working folder: `R:\...\AQR_2026\B3B\<date>\Рабочая папка`; Fenix data recorded
  in `EUB_B3B_v0`.
- Reminder for fillers: **if you record a repayment or write-off, the date must
  be in 2025** (audited-year rule, §4).
