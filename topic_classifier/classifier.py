"""Rule-based multi-label topic classifier.

Scoring model
-------------
For each topic we count how many times each signal term occurs in the document
and weight it by the term's tier (strong/medium/weak). To keep long documents
from dominating purely by length, term frequency is dampened with a logarithm:

    contribution(term) = weight(tier) * (1 + ln(count))       for count >= 1

A topic's raw score is the sum of contributions of its matched terms. The score
is reported both raw and normalised (share of the total score across topics),
together with the exact terms that fired — so every assignment is auditable.

A topic is considered *assigned* when its raw score reaches ``min_score`` and it
is among the ``top_k`` highest-scoring topics (both configurable).
"""

from __future__ import annotations

import math
import re
import unicodedata
from dataclasses import dataclass, field
from typing import Dict, List

from .taxonomy import Taxonomy, load_taxonomy


def normalise(text: str) -> str:
    """Lower-case, NFKC-normalise and collapse whitespace.

    ``ё`` is folded to ``е`` so terms match regardless of the yo/ye spelling.
    """
    text = unicodedata.normalize("NFKC", text).lower().replace("ё", "е")
    return re.sub(r"\s+", " ", text)


def _compile(term: str) -> re.Pattern:
    """Compile a term into a boundary-aware, whitespace-tolerant pattern.

    Runs of whitespace in a multi-word term match any whitespace in the text.
    Word boundaries use lookarounds over letters/digits so that, e.g., ``AQR``
    does not match inside ``AQRX`` while hyphenated terms like ``ТОП-20`` and
    ``риск-аппетит`` still match.

    A trailing ``*`` marks a **stem (prefix) match**: the term may be followed by
    any word characters. This handles Russian morphology — e.g.
    ``стресс-тестировани*`` matches ``стресс-тестирование``, ``…ния``, ``…нию`` —
    without listing every inflected form. Use it only where the stem is
    unambiguous, to avoid over-matching.
    """
    stem = term.endswith("*")
    if stem:
        term = term[:-1]
    parts = [re.escape(tok) for tok in term.split()]
    body = r"\s+".join(parts)
    tail = r"[^\W_]*" if stem else r"(?![^\W_])"
    return re.compile(rf"(?<![^\W_]){body}{tail}", re.IGNORECASE | re.UNICODE)


@dataclass
class TopicMatch:
    """Score and evidence for one topic against one document."""

    topic_id: str
    name_ru: str
    name_en: str
    score: float
    normalized: float
    matched_terms: Dict[str, int] = field(default_factory=dict)  # term -> count

    @property
    def evidence(self) -> List[str]:
        return sorted(self.matched_terms, key=lambda t: -self.matched_terms[t])


@dataclass
class Classification:
    """Full result of classifying one document."""

    matches: List[TopicMatch]           # every topic with score > 0, desc order
    assigned: List[TopicMatch]          # topics passing the assignment threshold
    total_score: float
    char_count: int

    @property
    def primary(self) -> TopicMatch | None:
        return self.assigned[0] if self.assigned else (
            self.matches[0] if self.matches else None
        )

    def labels(self) -> List[str]:
        return [m.topic_id for m in self.assigned]


class TopicClassifier:
    def __init__(
        self,
        taxonomy: Taxonomy | None = None,
        min_score: float = 3.0,
        top_k: int = 6,
    ):
        self.taxonomy = taxonomy or load_taxonomy()
        self.min_score = min_score
        self.top_k = top_k
        # Pre-compile every term once: topic_id -> list of (pattern, tier, term)
        self._patterns: Dict[str, List[tuple[re.Pattern, str, str]]] = {}
        for topic in self.taxonomy.topics:
            compiled = []
            for term, tier in topic.terms():
                compiled.append((_compile(normalise(term)), tier, term))
            self._patterns[topic.id] = compiled

    def classify(self, text: str) -> Classification:
        norm = normalise(text)
        weights = self.taxonomy.weights

        matches: List[TopicMatch] = []
        for topic in self.taxonomy.topics:
            score = 0.0
            matched: Dict[str, int] = {}
            for pattern, tier, term in self._patterns[topic.id]:
                count = len(pattern.findall(norm))
                if count:
                    matched[term] = count
                    score += weights.get(tier, 0.0) * (1.0 + math.log(count))
            if score > 0:
                matches.append(
                    TopicMatch(
                        topic_id=topic.id,
                        name_ru=topic.name_ru,
                        name_en=topic.name_en,
                        score=round(score, 3),
                        normalized=0.0,
                        matched_terms=matched,
                    )
                )

        matches.sort(key=lambda m: -m.score)
        total = sum(m.score for m in matches)
        for m in matches:
            m.normalized = round(m.score / total, 4) if total else 0.0

        assigned = [
            m for m in matches[: self.top_k] if m.score >= self.min_score
        ]
        return Classification(
            matches=matches,
            assigned=assigned,
            total_score=round(total, 3),
            char_count=len(text),
        )
