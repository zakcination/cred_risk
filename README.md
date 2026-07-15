# cred_risk — Credit-Risk Document Topic Classifier

Tooling for the credit-risk / prudential-supervision workstream of **AO
"Eurasian Bank"**. This repository starts with **Task #1: a topic classifier**
that scans incoming documents (regulator letters, stress-test reports, internal
audit reports, MIS registers) and assigns them to a maintained **taxonomy of
topics** — AQR, stress testing, RMNR, written prescriptions, risk appetite,
Top-20 / limits & pre-limits, capital adequacy, model validation, AI
initiatives, and more.

The classifier is **rule-based and fully auditable**: every topic score can be
traced to the exact terms that triggered it. In a regulated banking context
that explainability matters more than a black-box model, and it runs offline
with no external dependencies for Office files.

## Why a topic classifier

Documents in this domain each span several subjects and arrive from multiple
sources (regulator, internal audit, MIS). Routing, filing and tracking them —
"which supervisory findings relate to risk appetite?", "which files touch the
Top-20 limit?" — needs consistent, machine-readable topic labels. The taxonomy
in [`topics/taxonomy.yaml`](topics/taxonomy.yaml) is the shared vocabulary;
[`docs/topics_reference.md`](docs/topics_reference.md) explains each topic.

## Layout

```
topics/taxonomy.yaml         # the topic taxonomy (24 topics) — the core asset
topic_classifier/
  taxonomy.py                # load & validate the taxonomy
  extract.py                 # text extraction: PDF (pymupdf), DOCX/XLSX (stdlib), MSG (olefile), TXT/MD
  classifier.py              # weighted, frequency-dampened, multi-label scoring
  cli.py                     # command-line interface
docs/
  topics_reference.md        # reference for every topic (+ note: own capital / собственный капитал)
  analysis/                  # document-set classification summaries + data-model reference
                             #   credit_risk_knowledge_base.md  — end-to-end loan data architecture (branches→mart→reports, ~19-table inventory, IFRS 9 map)
                             #   risk_analytics_data_model.md   — column-level schema of the 5 draft-SQL tables
tests/                       # pytest suite (synthetic snippets, no confidential data)
data/                        # local document store — git-ignored (confidential)
examples/                    # non-confidential example artifacts
```

## Install

```bash
pip install -r requirements.txt   # PyYAML (required), pymupdf (PDF), pytest (dev)
```
DOCX and XLSX need no third-party packages (parsed via the standard library).
PDF extraction uses PyMuPDF when available.

## Usage

```bash
# List the taxonomy
python -m topic_classifier.cli --list-topics

# Classify a folder of documents (human-readable, with evidence)
python -m topic_classifier.cli data/

# Classify one file as JSON, written to results.json
python -m topic_classifier.cli data/NST2025.pdf --json --out results.json

# Tune assignment: raise the score threshold, cap labels per document
python -m topic_classifier.cli data/ --min-score 4 --top-k 4
```

Programmatic use:

```python
from topic_classifier import TopicClassifier
from topic_classifier.extract import extract_text

clf = TopicClassifier()
result = clf.classify(extract_text("data/AuditReport.docx"))
print(result.primary.topic_id)          # e.g. "model_risk_validation"
print(result.labels())                  # multi-label assignment
for m in result.matches[:5]:
    print(m.topic_id, m.score, m.evidence)
```

## How scoring works

For each topic the classifier counts occurrences of its signal terms, weights
them by tier (`strong=3.0`, `medium=1.5`, `weak=0.5`) and dampens term
frequency logarithmically so long documents don't win on length alone:

```
score(topic) = Σ  weight(tier) · (1 + ln(count))     over matched terms
```

Topics are ranked by raw score and normalised to shares; a topic is *assigned*
when it clears `--min-score` and is within the top-`k`. Matching is
case-insensitive, Unicode-aware (RU/KK/EN), folds `ё→е`, and respects
word/hyphen boundaries (so `AQR` ≠ `AQRX`, but `ТОП-20` and `риск-аппетит`
match).

**Russian morphology:** a trailing `*` on a taxonomy term is a **stem match** —
`стресс-тестировани*` matches `стресс-тестирование`, `…ния`, `…нию`, so
inflected forms don't need to be listed individually. Use it only where the stem
is unambiguous.

Validated against the initial document set — each document lands on the correct
primary topic (see [`docs/analysis/`](docs/analysis)).

## Extending the taxonomy

Edit `topics/taxonomy.yaml`: add a topic (stable `id`, `name_ru`/`name_en`,
`description`, and `strong`/`medium`/`weak` term lists) or add terms to an
existing one. Loading validates ids are unique. Add a matching reference entry
in `docs/topics_reference.md` and, ideally, a test snippet in
`tests/test_classifier.py`.

## Confidentiality

Real documents contain confidential and personal data (borrower names,
exposures). They live under `data/` and are **git-ignored**. Never commit source
documents; commit only code, taxonomy, and de-identified/aggregate analysis.
