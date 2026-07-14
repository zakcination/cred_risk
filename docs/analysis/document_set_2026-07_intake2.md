# Document-set analysis — July 2026, intake 2

Second batch: the **internal-audit working papers (checklists)** behind Audit
Report №7, plus the coordinating email. Classified with the topic classifier;
de-identified (no borrower-level data, findings summarised not reproduced).

## Files and classification

| Document | Type | Primary topic | Other assigned topics |
|---|---|---|---|
| `Чек-лист_SREP_Кред.риски_2025` | Audit working paper | `internal_audit` | model_risk_validation, supervisory_stress_testing, srep, risk_appetite, credit_risk |
| `Чек-лист_Модели_Кред.риски_2026` | Audit working paper (models) | `model_risk_validation` | internal_audit, credit_risk, provisions_ecl, mgmt-reporting, ai_initiatives |
| `Чек-лист стресс-тестирования` | Audit working paper (ST) | `supervisory_stress_testing` | credit_risk, internal_audit, provisions_ecl, icaap_ilaap, mgmt-reporting |
| `Чек-лист кредитного риска` | Audit working paper (CR process) | `risk_appetite` | internal_audit, model_risk_validation, corporate_governance, credit_risk, top20 |
| `FW: результаты НСТ` (email `.msg`) | Internal coordination email | `supervisory_stress_testing` | — |

These are the granular findings behind the "Requires improvement" credit-risk
audit rating: each checklist records the tested questions, findings by risk
grade (high/medium), the responsible units (БРМ / УКиРР / УРР / ОУРР / ОПАиРОЗ /
УНОКЗ / УОЗО), the units' responses, and Internal-Audit (СВА) comments.

## What the email adds (`FW: результаты НСТ`)

Internal risk-management coordination on the NST-2025 results and SREP
remediation. Task lines extracted:
- **RM Strategy (ДК_Стратегия_БРМ):** build a model / model-risk management
  **framework**; full methodology set for credit-risk models (development,
  corporate & retail **validation**, model **life-cycle**, regular validation
  procedure); improve **stress-testing**; carve out a dedicated **model-risk
  function** + **model catalog**; annual **rating/scoring model monitoring**;
  staff training.
- **2026 plan (УКиРР):** address **credit-portfolio concentration**
  (auto-loans); fix a **Resolution №188 п.42 violation** — missing
  **collateral-type limits** for the *Private Banking* product → amend the
  approved **limit schedule (лимитная ведомость)**.
- Deadline note: work through all SREP comments and reply by letter before
  **01.07.2026**.

## Taxonomy / tooling changes this intake drove

The stress-test checklist exposed a **Russian-morphology gap** and the batch
introduced new concepts, so the classifier was extended:

1. **Stem matching (`*`)** added to the scoring engine — `стресс-тестировани*`
   now matches all inflected forms. Before the fix the stress-test checklist
   ranked `supervisory_stress_testing` 7th (unassigned); after, it is the
   primary topic.
2. **`.msg` extraction** added (`olefile` + optional `compressed-rtf`) so
   Outlook emails classify like any other document.
3. **New taxonomy terms:** back-testing / Gini / discriminatory power / model
   framework / life-cycle / recalibration (→ `model_risk_validation`); portfolio
   diversification & concentration, limit schedule, collateral-type limits
   (→ `credit_limits`); audit-working-paper signals — чек-лист, "степенью
   риска", "пояснение подразделения" (→ `internal_audit`); the `НТС` typo and
   inflected `сценари*` (→ `supervisory_stress_testing`).

## Reinforced cross-document themes (backlog)

These recur across the regulator letters, the audit report and now the working
papers — the credit-risk workstream's core open items:

1. **Model risk & validation** — no framework, no independent validation, no
   back-testing discipline, model registry/catalog missing. *(highest-frequency
   theme across the whole corpus)*
2. **Stress testing** — outdated scenarios/assumptions (methodology approved
   2015), calculation errors, reporting completeness.
3. **Risk appetite** — recalibration of credit-risk risk-appetite levels due by
   30.09.2026.
4. **Concentration / limits** — auto-loan concentration; missing collateral
   limits (Private Banking); Top-20 breach (intake 1).
5. **Management reporting** — timeliness/correctness of credit-risk MIS.

> Note on "primary topic": it reflects **subject-matter dominance**, not
> document type. Enforcement/measure documents (предписание, РМНР) discuss many
> subjects, so their type appears in the *assigned* set rather than always as
> the primary label. Route on the full label set, not the primary alone.
