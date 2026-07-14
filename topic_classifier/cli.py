"""Command-line interface for the credit-risk topic classifier.

Examples
--------
Classify a single document (human-readable)::

    python -m topic_classifier.cli data/NST2025.pdf

Classify a whole folder and emit JSON::

    python -m topic_classifier.cli data/ --json --out results.json

List the topics in the taxonomy::

    python -m topic_classifier.cli --list-topics
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import List

from .classifier import Classification, TopicClassifier
from .extract import SUPPORTED_EXTENSIONS, extract_text
from .taxonomy import load_taxonomy


def _iter_input_files(paths: List[str]) -> List[Path]:
    files: List[Path] = []
    for p in paths:
        path = Path(p)
        if path.is_dir():
            for f in sorted(path.rglob("*")):
                if f.is_file() and f.suffix.lower() in SUPPORTED_EXTENSIONS:
                    files.append(f)
        elif path.is_file():
            files.append(path)
        else:
            print(f"warning: skipping missing path {p}", file=sys.stderr)
    return files


def _result_dict(path: Path, result: Classification) -> dict:
    return {
        "file": str(path),
        "char_count": result.char_count,
        "primary_topic": result.primary.topic_id if result.primary else None,
        "assigned_topics": result.labels(),
        "topics": [
            {
                "id": m.topic_id,
                "name_ru": m.name_ru,
                "name_en": m.name_en,
                "score": m.score,
                "share": m.normalized,
                "assigned": m in result.assigned,
                "evidence": {t: m.matched_terms[t] for t in m.evidence},
            }
            for m in result.matches
        ],
    }


def _print_human(path: Path, result: Classification) -> None:
    print(f"\n=== {path} ===")
    print(f"  characters: {result.char_count}")
    if not result.matches:
        print("  no topics matched")
        return
    primary = result.primary
    print(f"  primary: {primary.topic_id} ({primary.name_ru})")
    print(f"  assigned: {', '.join(result.labels()) or '(none above threshold)'}")
    print("  ranking:")
    for m in result.matches:
        flag = "*" if m in result.assigned else " "
        top_terms = ", ".join(
            f"{t}×{m.matched_terms[t]}" for t in m.evidence[:5]
        )
        print(
            f"   {flag} {m.score:6.2f} {m.normalized*100:5.1f}%  "
            f"{m.topic_id:<34} [{top_terms}]"
        )


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="topic_classifier",
        description="Classify credit-risk documents into taxonomy topics.",
    )
    p.add_argument("inputs", nargs="*", help="files or folders to classify")
    p.add_argument("--taxonomy", help="path to a taxonomy YAML (default: topics/taxonomy.yaml)")
    p.add_argument("--min-score", type=float, default=3.0, help="assignment threshold (default 3.0)")
    p.add_argument("--top-k", type=int, default=6, help="max topics assigned per document (default 6)")
    p.add_argument("--json", action="store_true", help="emit JSON instead of human-readable output")
    p.add_argument("--out", help="write output to this file instead of stdout")
    p.add_argument("--list-topics", action="store_true", help="print the taxonomy and exit")
    return p


def main(argv: List[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    taxonomy = load_taxonomy(args.taxonomy)

    if args.list_topics:
        for t in taxonomy.topics:
            print(f"{t.id:<34} {t.name_ru}")
        print(f"\n{len(taxonomy)} topics")
        return 0

    if not args.inputs:
        build_parser().print_help()
        return 1

    clf = TopicClassifier(taxonomy=taxonomy, min_score=args.min_score, top_k=args.top_k)
    files = _iter_input_files(args.inputs)
    if not files:
        print("no supported input files found", file=sys.stderr)
        return 1

    results = []
    for path in files:
        try:
            text = extract_text(path)
        except Exception as exc:  # noqa: BLE001 - report and continue
            print(f"error: failed to read {path}: {exc}", file=sys.stderr)
            continue
        result = clf.classify(text)
        results.append((path, result))

    if args.json:
        payload = [_result_dict(p, r) for p, r in results]
        text_out = json.dumps(payload, ensure_ascii=False, indent=2)
        if args.out:
            Path(args.out).write_text(text_out, encoding="utf-8")
            print(f"wrote {args.out} ({len(results)} documents)")
        else:
            print(text_out)
    else:
        stream_lines = []
        for path, result in results:
            _print_human(path, result)
        if args.out:
            # Re-render to file without ANSI, simple approach: capture again.
            with open(args.out, "w", encoding="utf-8") as fh:
                for path, result in results:
                    fh.write(f"=== {path} ===\n")
                    fh.write(f"primary: {result.primary.topic_id if result.primary else None}\n")
                    fh.write(f"assigned: {', '.join(result.labels())}\n\n")
            print(f"wrote {args.out}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
