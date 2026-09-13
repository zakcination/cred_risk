#!/usr/bin/env python3
"""Build machine-readable GPT catalogs from REGISTRY.md and CITED.md."""

from __future__ import annotations

import argparse
import csv
import io
import json
import re
from collections import Counter
from pathlib import Path


BASE = Path(__file__).resolve().parent
REGISTRY = BASE / "REGISTRY.md"
CITED = BASE / "CITED.md"
CATALOG = BASE / "catalog"
SOURCE_ID_RE = re.compile(
    r"^(?:KZ|IFRS|US|HK|SG|UK|RU|LTR|VND|NST)-[A-Z0-9-]+$"
)


def plain(value: str) -> str:
    value = re.sub(r"\[([^]]+)]\([^)]+\)", r"\1", value)
    value = value.replace("**", "").replace("`", "")
    return re.sub(r"\s+", " ", value).strip()


def official_url(value: str) -> str:
    match = re.search(r"\[[^]]+]\((https?://[^)]+)\)", value)
    return match.group(1) if match else ""


def split_row(line: str) -> list[str]:
    return [cell.strip() for cell in line.strip().strip("|").split("|")]


def is_separator(line: str) -> bool:
    cells = split_row(line)
    return bool(cells) and all(re.fullmatch(r":?-{3,}:?", cell) for cell in cells)


def tables(path: Path):
    lines = path.read_text(encoding="utf-8").splitlines()
    heading = ""
    index = 0
    while index < len(lines):
        line = lines[index]
        if line.startswith("## "):
            heading = plain(line[3:])
        if (
            line.startswith("|")
            and index + 1 < len(lines)
            and lines[index + 1].startswith("|")
            and is_separator(lines[index + 1])
        ):
            headers = [plain(cell) for cell in split_row(line)]
            rows = []
            row_index = index + 2
            while row_index < len(lines) and lines[row_index].startswith("|"):
                cells = split_row(lines[row_index])
                if len(cells) == len(headers):
                    rows.append((row_index + 1, cells))
                row_index += 1
            yield heading, headers, rows
            index = row_index
            continue
        index += 1


def source_kind(source_id: str) -> str:
    if source_id.startswith("VND-"):
        return "ВНД"
    if source_id.startswith("LTR-"):
        return "письмо регулятора"
    if source_id.startswith("NST-"):
        return "методические материалы регулятора"
    if source_id == "IFRS-9":
        return "международный стандарт"
    if source_id.startswith("KZ-"):
        return "НПА РК"
    return "зарубежный ориентир"


def parse_sources() -> list[dict[str, str]]:
    result = []
    seen = set()
    for heading, headers, rows in tables(REGISTRY):
        if not headers or headers[0].lower() != "id":
            continue
        for line_number, cells in rows:
            source_id = plain(cells[0])
            if not SOURCE_ID_RE.fullmatch(source_id):
                continue
            if source_id in seen:
                raise ValueError(f"duplicate source_id in REGISTRY.md: {source_id}")
            seen.add(source_id)
            mapped = dict(zip(headers, cells))
            title_raw = cells[1]
            status = plain(mapped.get("Статус", "не указан"))
            version = plain(
                mapped.get("Редакция", mapped.get("Редакция на дату прочтения", "не указана"))
            )
            analysis = plain(mapped.get("Где разбирается", ""))
            details = []
            for header, value in zip(headers[2:], cells[2:]):
                if header in {"Статус", "Редакция", "Редакция на дату прочтения", "Где разбирается"}:
                    continue
                details.append(f"{header}: {plain(value)}")
            result.append(
                {
                    "source_id": source_id,
                    "source_kind": source_kind(source_id),
                    "title": plain(title_raw),
                    "registry_group": heading,
                    "status": status,
                    "version": version,
                    "official_url": official_url(title_raw),
                    "analysis_refs": analysis,
                    "details": " | ".join(details),
                    "registry_locator": f"docs/analysis/npa_registry/REGISTRY.md:{line_number}",
                    "confidentiality": (
                        "internal_no_original_in_repository"
                        if source_id.startswith(("VND-", "LTR-", "NST-"))
                        else "public_or_licensed_reference"
                    ),
                }
            )
    return result


def heading_source_id(heading: str) -> str:
    candidate = heading.split(" — ", 1)[0].strip()
    return candidate if SOURCE_ID_RE.fullmatch(candidate) else ""


def parse_clauses() -> tuple[list[dict[str, str]], list[dict[str, str]]]:
    clauses = []
    questions = []
    keys = Counter()
    for heading, headers, rows in tables(CITED):
        normalized_headers = [header.lower() for header in headers]
        if heading == "Пункты, которые предстоит прочитать":
            for line_number, cells in rows:
                questions.append(
                    {
                        "source_or_document": plain(cells[0]),
                        "locator": plain(cells[1]),
                        "gap": plain(cells[2]),
                        "status": "ОТСУТСТВУЕТ",
                        "source_locator": f"docs/analysis/npa_registry/CITED.md:{line_number}",
                    }
                )
            continue

        fixed_source_id = heading_source_id(heading)
        foreign_table = normalized_headers[:2] == ["id", "пункт"]
        for line_number, cells in rows:
            if foreign_table:
                source_id = plain(cells[0])
                locator, statement, cited_at = map(plain, cells[1:4])
            else:
                source_id = fixed_source_id
                if len(cells) < 3:
                    continue
                locator, statement, cited_at = map(plain, cells[:3])
            if not SOURCE_ID_RE.fullmatch(source_id):
                continue
            base_key = f"{source_id}::{locator}"
            keys[base_key] += 1
            clause_id = base_key if keys[base_key] == 1 else f"{base_key}::{keys[base_key]}"
            clauses.append(
                {
                    "clause_id": clause_id,
                    "source_id": source_id,
                    "locator": locator,
                    "statement": statement,
                    "where_cited": cited_at,
                    "status": "ПОДТВЕРЖДЕНО",
                    "evidence_level": (
                        "registered_vnd_analysis"
                        if source_id.startswith("VND-")
                        else "verified_clause_index"
                    ),
                    "source_locator": f"docs/analysis/npa_registry/CITED.md:{line_number}",
                }
            )
    return clauses, questions


def csv_text(rows: list[dict[str, str]], fields: list[str]) -> str:
    output = io.StringIO(newline="")
    writer = csv.DictWriter(output, fieldnames=fields, delimiter=";", lineterminator="\n")
    writer.writeheader()
    writer.writerows(rows)
    return output.getvalue()


def build_outputs() -> dict[Path, str]:
    sources = parse_sources()
    clauses, questions = parse_clauses()
    known = {row["source_id"] for row in sources}
    unknown = sorted({row["source_id"] for row in clauses} - known)
    if unknown:
        raise ValueError(f"clauses reference unknown source_id: {', '.join(unknown)}")

    clause_counts = Counter(row["source_id"] for row in clauses)
    for source in sources:
        count = clause_counts[source["source_id"]]
        source["verified_clause_count"] = str(count)
        source["coverage_status"] = "CLAUSE_INDEXED" if count else "REGISTERED_ONLY"

    active_kz_without_url = [
        row["source_id"]
        for row in sources
        if row["source_kind"] == "НПА РК"
        and row["status"].lower() == "действует"
        and not row["official_url"]
        and row["source_id"] != "KZ-ZAKON-BANKI"
    ]
    vnd_without_clauses = [
        row["source_id"]
        for row in sources
        if row["source_kind"] == "ВНД" and not clause_counts[row["source_id"]]
    ]
    by_kind = Counter(row["source_kind"] for row in sources)
    coverage = [
        "# Покрытие единой базы знаний ВНД и НПА",
        "",
        "Сформировано `build_catalog.py` из `REGISTRY.md` и `CITED.md`. Ручная правка этого",
        "файла не допускается.",
        "",
        "## Итог",
        "",
        f"- Источников в реестре: **{len(sources)}**.",
        f"- Постатейных записей: **{len(clauses)}**.",
        f"- Открытых вопросов к чтению или подтверждению: **{len(questions)}**.",
        f"- Источников с постатейным покрытием: **{sum(1 for row in sources if clause_counts[row['source_id']])}**.",
        f"- Источников только с карточкой: **{sum(1 for row in sources if not clause_counts[row['source_id']])}**.",
        "",
        "## Состав по типам",
        "",
        "| Тип | Источников |",
        "|---|---:|",
    ]
    coverage.extend(f"| {kind} | {count} |" for kind, count in sorted(by_kind.items()))
    coverage.extend(
        [
            "",
            "## Контрольные пробелы",
            "",
            "**Действующие НПА РК без официальной ссылки:** "
            + (", ".join(f"`{item}`" for item in active_kz_without_url) or "нет"),
            "",
            "**ВНД без постатейной записи:** "
            + (", ".join(f"`{item}`" for item in vnd_without_clauses) or "нет"),
            "",
            "Полный перечень нерешённых пунктов находится в `catalog/open_questions.csv`.",
            "Статус `CLAUSE_INDEXED` означает наличие проверенной записи в `CITED.md`, но не",
            "означает утверждение владельцем Банка или полноту чтения всего документа.",
            "",
        ]
    )

    source_fields = [
        "source_id",
        "source_kind",
        "title",
        "registry_group",
        "status",
        "version",
        "official_url",
        "analysis_refs",
        "details",
        "verified_clause_count",
        "coverage_status",
        "registry_locator",
        "confidentiality",
    ]
    clause_fields = [
        "clause_id",
        "source_id",
        "locator",
        "statement",
        "where_cited",
        "status",
        "evidence_level",
        "source_locator",
    ]
    question_fields = ["source_or_document", "locator", "gap", "status", "source_locator"]
    return {
        CATALOG / "sources.csv": csv_text(sources, source_fields),
        CATALOG / "clauses.csv": csv_text(clauses, clause_fields),
        CATALOG / "open_questions.csv": csv_text(questions, question_fields),
        BASE / "COVERAGE.md": "\n".join(coverage),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="fail if generated files are stale")
    args = parser.parse_args()
    outputs = build_outputs()
    if args.check:
        stale = [str(path.relative_to(BASE)) for path, content in outputs.items() if not path.exists() or path.read_text(encoding="utf-8") != content]
        if stale:
            raise SystemExit("stale generated files: " + ", ".join(stale))
        print(f"OK: {len(outputs)} generated files are current")
        return 0
    CATALOG.mkdir(exist_ok=True)
    for path, content in outputs.items():
        path.write_text(content, encoding="utf-8")
    print(f"Wrote {len(outputs)} files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
