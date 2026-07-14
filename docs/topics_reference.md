# Topic Reference — Credit-Risk Document Taxonomy

Reference notes for every topic in `topics/taxonomy.yaml`. The taxonomy was
built by scanning the initial document set for the bank (AO "Eurasian Bank")
and identifying the recurring subject areas ("key concepts") in prudential
supervision and credit-risk management. Topics are **multi-label**: one document
usually touches several.

Legend for the source documents referenced below:
- **НСТ‑2025** — Supervisory Stress-Testing Report of banks 2025 (regulator)
- **RMNR** — Recommendatory Measure of Supervisory Response (regulator, SREP‑2025)
- **Предписание** — Written Prescription re Rules №188 (regulator)
- **TOP‑20** — Top-20 credit exposures register (bank, MIS)
- **Аудит КР** — Internal Audit Report №7 on credit-risk management (bank, SIA)

---

## 1. AQR — Asset Quality Review (`aqr`)
Independent review of asset quality and provisioning adequacy that sets the
starting point (EAD by stage, PD/LGD/TR) for stress testing. In НСТ‑2025 the AQR
perimeter covered 11 banks (86% of sector assets). *Sources: НСТ‑2025.*

## 2. Supervisory Stress Testing — НСТ (`supervisory_stress_testing`)
The Agency's annual macro stress test over 12 quarters under a baseline and a
stress scenario, measuring the resilience of capital adequacy (k1). НСТ‑2025:
k1 fell 1.6 pp to 16.1% in the worst quarter, well above the 5.5% floor.
*Sources: НСТ‑2025; Предписание & RMNR (stress-testing findings).*

## 3. SREP — Supervisory Review and Evaluation Process (`srep`)
The risk-based annual supervisory assessment; the origin of the findings,
ratings (СОР) and the two follow-up measures below. *Sources: RMNR, Предписание.*

## 4. RMNR — Recommendatory Measure of Supervisory Response (`supervisory_response_recommendatory`)
A "soft" measure (Art. 79 of the Banking Law) listing deficiencies/risks that do
not materially threaten stability, recommending remediation. *Sources: RMNR.*

## 5. Written Prescription (`supervisory_response_prescription`)
A binding enforcement act (Rules №272) ordering remediation of specific rule
violations by a deadline (revised Action Plan due 15 Jul 2026). *Sources: Предписание.*

## 6. Risk Appetite (`risk_appetite`)
The risk-appetite statement and its quantitative/qualitative levels, calibration
and integration into planning. A recurring finding: missing qualitative
statement and missing "no-action" / "tolerable but corrective" levels.
*Sources: Предписание, RMNR, Аудит КР.*

## 7. ICAAP / ILAAP — ВПОДК / ВПОДЛ (`icaap_ilaap`)
Internal Capital / Liquidity Adequacy Assessment Processes and the Board's
report on their observance (deadline 30 April). *Sources: Предписание.*

## 8. Top-20 Large Exposures / Concentration (`top20_large_exposures`)
Register and monitoring of the 20 largest borrower groups and their
concentration relative to own capital. *Sources: TOP‑20.*

## 9. Credit-Risk Limits and Pre-limits (`credit_limits`)
Establishment, revision and monitoring of credit-risk limits and **pre-limits**
(предлимиты), including breaches. In TOP‑20 the actual Top-20 share reached
**100.30% of own capital vs the approved 95% limit** — a **+5.30 pp breach**.
*Sources: TOP‑20; "Rules for establishing and revising credit-risk limits,
28.09.2020".*

## 10. Capital Adequacy (k1) and Own Capital (`capital_adequacy`)
Own funds, core/Tier-1 capital and the k1 adequacy ratio; buffers derived from
stress testing. See the dedicated note on **own capital composition** below.
*Sources: НСТ‑2025, TOP‑20, Предписание.*

## 11. Credit Risk (`credit_risk`)
Loan-portfolio credit risk: PD/LGD/EAD/ECL, IFRS-9 staging, coverage and
segments (INDLOANS, RETCON, RETCAR, CORCOR, RETSML, RETEST, FINFIN).
*Sources: НСТ‑2025, Аудит КР.*

## 12. Market Risk (`market_risk`)
Revaluation risk of rate-, price- and FX-sensitive instruments (bonds,
equities, derivatives, real estate). *Sources: НСТ‑2025.*

## 13. Currency (FX) Risk (`currency_risk`)
FX-rate risk and currency structure of the balance sheet; a mandatory stress
scenario dimension. *Sources: НСТ‑2025, Предписание.*

## 14. Liquidity Risk and Funding (`liquidity_risk`)
Liquidity adequacy, funding plan, market-liquidity-vs-funding linkage.
*Sources: Предписание, Аудит КР.*

## 15. Operational Risk (`operational_risk`)
Loss database, scenario and reverse stress testing of operational risk.
*Sources: RMNR, Предписание.*

## 16. Model Risk and Model Validation (`model_risk_validation`)
Model governance, independent validation, monitoring and the model registry.
The single most material credit-risk audit finding: no comprehensive model-risk
framework, no independent validation of credit-risk models. *Sources: Аудит КР, RMNR, Предписание.*

## 17. Provisions / ECL — IFRS 9 (`provisions_ecl`)
Expected credit loss provisioning, provision coverage and the provisioning
methodology agreed with the regulator (Methodology №130-05 vs NBK Resolution №52).
*Sources: НСТ‑2025, Аудит КР.*

## 18. Internal Audit (`internal_audit`)
Independent internal audit activity, findings and audit ratings. Аудит КР
rated the credit-risk process **"Requires improvement"**. *Sources: Аудит КР, RMNR.*

## 19. Management Reporting (`management_reporting`)
Timeliness, completeness and correctness of MIS to the authorised bodies and the
Board. Recurring finding: untimely tabling of credit-risk reporting.
*Sources: Аудит КР, RMNR, Предписание.*

## 20. Corporate Governance (`corporate_governance`)
Board, independent directors, committees, remuneration, strategic oversight.
*Sources: RMNR.*

## 21. Dividend Policy (`dividend_policy`)
Board-approved dividend policy and its link to capital planning. *Sources: RMNR.*

## 22. AI Initiatives and Automation (`ai_initiatives`)
Automation, ML/AI initiatives in risk and reporting; a cross-cutting theme
(automation gaps drive human-factor errors in credit-risk reporting). Included
proactively as a strategic topic even where current documents mention only
automation. *Sources: Аудит КР (automation gaps); strategic backlog.*

## 23. Human Resources / People Risk (`hr_risk`)
Risk of managing human resources, staffing of control functions, competencies.
*Sources: RMNR.*

## 24. Budgeting and Planning (`budgeting_planning`)
Budget process and integration of risk-appetite and stress-test results into
strategic/financial planning. *Sources: RMNR, Предписание.*

---

# Note: Own capital of the bank (собственный капитал банка) — what it consists of

"Собственный капитал" (regulatory own funds) is the denominator used for the
Top-20 concentration limit and the basis of the k1 adequacy ratio. Under the
Kazakhstan prudential framework (ARDFM/NBK rules on capital-adequacy norms for
second-tier banks, Basel III–aligned), own capital is:

```
Собственный капитал (Own funds)
= Основной капитал (Tier 1)  +  Дополнительный капитал (Tier 2)
```

**I. Основной капитал / Tier 1**

*I.a. Основной капитал первого уровня — Common Equity Tier 1 (CET1):*
- Оплаченный уставный капитал по простым акциям (paid-in common shares) minus
  выкупленные собственные простые акции (treasury shares);
- Эмиссионный доход / премии по акциям (share premium);
- Резервный капитал и фонды, сформированные за счёт прибыли (reserves);
- Нераспределённая прибыль прошлых лет и (подтверждённая) прибыль текущего года
  (retained earnings);
- Накопленный прочий совокупный доход — резервы переоценки (accumulated OCI);
- **минус регуляторные вычеты (deductions):** нематериальные активы и гудвил,
  отложенные налоговые активы, инвестиции в собственные акции, существенные
  вложения в капитал финансовых организаций, и т.п.

*I.b. Добавочный капитал первого уровня — Additional Tier 1 (AT1):*
- Бессрочные (perpetual) субординированные инструменты и привилегированные
  акции, удовлетворяющие критериям поглощения убытков.

**II. Дополнительный капитал / Tier 2**
- Субординированный долг с первоначальным сроком ≥ 5 лет (амортизируется в
  последние 5 лет до погашения);
- Часть провизий/резервов, включаемая в капитал в установленных пределах.

**Adequacy ratios** (own capital / risk-weighted assets, RWA):
- **k1** — коэффициент достаточности **основного капитала (Tier 1)** — the metric
  used throughout НСТ‑2025 (stress result 16.1% vs 5.5% minimum before buffers);
- **k1‑2 / k2** — коэффициенты с учётом добавочного и совокупного капитала.

**Why it matters for the Top-20 file:** the internal limit caps the aggregate
Top-20 exposure at **95% of own capital (СК)**. In the TOP‑20 register, СК as of
01.07.2026 = **442.35 bn ₸**, and the Top-20 net exposure (443.66 bn ₸) equals
**100.30%** of it — breaching the limit by **+5.30 pp**.
