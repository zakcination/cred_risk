"""Credit-risk document topic classifier.

A transparent, rule-based multi-label classifier that scans prudential /
credit-risk documents (Russian/Kazakh/English) and assigns them to topics
from a maintained taxonomy (``topics/taxonomy.yaml``).

Rule-based scoring is used deliberately: in a regulated banking context the
assignment must be explainable and reproducible offline, without dependence on
an external model. Every topic score can be traced back to the exact terms that
triggered it.
"""

from .taxonomy import Taxonomy, Topic, load_taxonomy
from .classifier import TopicClassifier, TopicMatch, Classification

__all__ = [
    "Taxonomy",
    "Topic",
    "load_taxonomy",
    "TopicClassifier",
    "TopicMatch",
    "Classification",
]

__version__ = "0.1.0"
