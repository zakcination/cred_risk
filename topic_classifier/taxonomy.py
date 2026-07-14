"""Loading and representation of the topic taxonomy."""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List

import yaml

# Default weights per signal tier. Kept here (not in YAML) so the taxonomy file
# stays focused on domain terms; override via ``load_taxonomy(weights=...)``.
DEFAULT_WEIGHTS: Dict[str, float] = {"strong": 3.0, "medium": 1.5, "weak": 0.5}

_REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_TAXONOMY_PATH = _REPO_ROOT / "topics" / "taxonomy.yaml"


@dataclass
class Topic:
    """A single classifiable subject area."""

    id: str
    name_ru: str
    name_en: str
    description: str
    strong: List[str] = field(default_factory=list)
    medium: List[str] = field(default_factory=list)
    weak: List[str] = field(default_factory=list)

    def terms(self) -> List[tuple[str, str]]:
        """Yield ``(term, tier)`` pairs for every signal term of the topic."""
        pairs: List[tuple[str, str]] = []
        for tier in ("strong", "medium", "weak"):
            for term in getattr(self, tier):
                pairs.append((term, tier))
        return pairs


@dataclass
class Taxonomy:
    """A collection of topics plus the weight table used for scoring."""

    topics: List[Topic]
    weights: Dict[str, float] = field(default_factory=lambda: dict(DEFAULT_WEIGHTS))
    version: int = 1
    language: List[str] = field(default_factory=list)

    def by_id(self, topic_id: str) -> Topic:
        for t in self.topics:
            if t.id == topic_id:
                return t
        raise KeyError(topic_id)

    def __len__(self) -> int:
        return len(self.topics)


def load_taxonomy(
    path: str | Path | None = None,
    weights: Dict[str, float] | None = None,
) -> Taxonomy:
    """Load the taxonomy from a YAML file.

    Raises ``ValueError`` on duplicate ids or missing required fields so that
    taxonomy edits fail loudly rather than silently degrading classification.
    """
    path = Path(path) if path is not None else DEFAULT_TAXONOMY_PATH
    with open(path, "r", encoding="utf-8") as fh:
        raw = yaml.safe_load(fh)

    if not raw or "topics" not in raw:
        raise ValueError(f"Taxonomy file {path} has no 'topics' section")

    topics: List[Topic] = []
    seen: set[str] = set()
    for entry in raw["topics"]:
        tid = entry.get("id")
        if not tid:
            raise ValueError(f"Topic entry without an id: {entry!r}")
        if tid in seen:
            raise ValueError(f"Duplicate topic id: {tid}")
        seen.add(tid)
        topics.append(
            Topic(
                id=tid,
                name_ru=entry.get("name_ru", tid),
                name_en=entry.get("name_en", tid),
                description=(entry.get("description") or "").strip(),
                strong=list(entry.get("strong", [])),
                medium=list(entry.get("medium", [])),
                weak=list(entry.get("weak", [])),
            )
        )

    return Taxonomy(
        topics=topics,
        weights=dict(weights or DEFAULT_WEIGHTS),
        version=int(raw.get("version", 1)),
        language=list(raw.get("language", [])),
    )
