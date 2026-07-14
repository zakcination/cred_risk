# Document-set analysis — July 2026 intake

Classification of the initial five documents by the topic classifier
(`python -m topic_classifier.cli data/`). Source files are held under `data/`
(git-ignored, confidential); this summary is de-identified — no borrower-level
data is reproduced.

| Document | Type | Primary topic | Other assigned topics |
|---|---|---|---|
| Supervisory Stress-Testing Report (НСТ) 2025 | Regulator, analytical | `credit_risk` | stress-testing, market_risk, AQR, provisions_ecl, capital_adequacy |
| Recommendatory Measure of Supervisory Response (RMNR) | Regulator, SREP measure | `srep` | corporate_governance, risk_appetite, operational_risk, prescription, mgmt-reporting |
| Written Prescription (Rules №188) | Regulator, enforcement | `icaap_ilaap` | prescription, srep, risk_appetite, budgeting_planning |
| Top-20 credit exposures register | Bank MIS | `top20_large_exposures` | credit_limits |
| Internal Audit Report №7 — Credit Risk | Bank SIA | `model_risk_validation` | internal_audit, mgmt-reporting, credit_risk, risk_appetite, ai_initiatives |

Every document lands on the expected primary topic, and the multi-label
assignments capture the cross-cutting subjects (e.g. the audit report is
primarily about **model risk / validation** but also flags internal-audit,
reporting-timeliness and risk-appetite issues).

## Cross-document themes (candidate work items)

Several topics recur across the regulator and internal-audit documents and are
the natural backlog for the credit-risk workstream:

1. **Risk appetite** — missing qualitative statement; missing "no-action" and
   "tolerable-but-corrective" levels; not calibrated with reverse stress tests;
   credit-risk levels not reviewed annually. *(Предписание, RMNR, Аудит КР)*
2. **Model risk & validation** — no comprehensive model-risk framework; no
   independent validation of credit-risk models; validation periodicity
   non-compliant. *(Аудит КР, RMNR, Предписание)*
3. **Stress testing** — mandatory scenarios not modelled (FX convertibility,
   settlement failures, liquidity-vs-funding); results not integrated into
   planning; no documented scenario rationale. *(Предписание, RMNR, Аудит КР)*
4. **ICAAP/ILAAP (ВПОДК/ВПОДЛ)** — Board report approved after the 30 April
   deadline; internal-control and risk-unit duties not defined in policy.
   *(Предписание)*
5. **Management reporting** — untimely tabling of credit-risk MIS to the
   authorised bodies. *(Аудит КР, RMNR)*
6. **Top-20 concentration / limits** — aggregate Top-20 exposure breached the
   internal limit (see below). *(TOP-20)*

## Top-20 concentration (aggregate, as of 13.07.2026 for 10.07.2026)

| Metric | Value |
|---|---|
| Top-20 total incl. contingent (гарантии/аккредитивы) | ≈ 479.29 bn ₸ |
| less cash collateral (заклад денег) | ≈ 35.64 bn ₸ |
| **Top-20 net exposure** | **≈ 443.66 bn ₸** |
| Own capital (СК) as of 01.07.2026 | ≈ 442.35 bn ₸ |
| **Top-20 share of own capital** | **100.30%** |
| Approved Top-20 limit | 95% |
| **Deviation from limit** | **+5.30 pp (breach)** |

The Top-20 aggregate exceeds the internal 95%-of-own-capital limit set by the
"Rules for establishing and revising credit-risk limits at AO Eurasian Bank"
(28.09.2020). This is a limit breach requiring escalation to the authorised
body and a remediation/come-into-compliance plan.
