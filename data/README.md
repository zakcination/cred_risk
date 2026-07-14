# `data/` — local document store (not versioned)

Place the documents to be classified here (PDF / DOCX / XLSX / TXT / MD).

**Do not commit real documents.** Everything in this folder except this README
is git-ignored, because the credit-risk documents (Top-20 borrower registers,
internal audit reports, regulator correspondence) contain **confidential and
personal data**.

## Usage

```bash
# classify every supported file in this folder
python -m topic_classifier.cli data/

# machine-readable output
python -m topic_classifier.cli data/ --json --out results.json
```

The classifier reads files here and prints/exports the topics it detects; it
never writes back into the source documents.
