"""Tests for the topic classifier.

Uses short synthetic snippets (no confidential data) that mimic the phrasing of
real credit-risk / supervisory documents.
"""

import math

import pytest

from topic_classifier import TopicClassifier, load_taxonomy
from topic_classifier.classifier import normalise, _compile


@pytest.fixture(scope="module")
def clf():
    return TopicClassifier()


def test_taxonomy_loads_and_ids_unique():
    tax = load_taxonomy()
    ids = [t.id for t in tax.topics]
    assert len(ids) == len(set(ids))
    assert len(tax) >= 20
    # ids the product explicitly relies on must exist
    for required in ("aqr", "top20_large_exposures", "credit_limits",
                     "risk_appetite", "ai_initiatives", "capital_adequacy"):
        assert required in ids


def test_normalise_folds_yo_and_whitespace():
    assert normalise("Риск-Аппетит\n\tБанка") == "риск-аппетит банка"
    assert normalise("объём") == "объем"


def test_word_boundary_no_partial_match():
    # 'AQR' must not match inside another token
    pat = _compile(normalise("AQR"))
    assert pat.search("отчет aqr 2025")
    assert not pat.search("aqrx test")


def test_hyphenated_terms_match():
    pat = _compile(normalise("ТОП-20"))
    assert pat.search("заемщики топ-20 банка")


def test_top20_snippet(clf):
    text = (
        "Топ 20 кредитных обязательств. Группа связанности, наименование клиента, "
        "задолженность по основному долгу. Доля ТОР 20 к СК. Утвержденный лимит по "
        "ТОР 20 составляет 95%. Отклонение факта от плана."
    )
    result = clf.classify(text)
    assert result.primary.topic_id == "top20_large_exposures"
    assert "credit_limits" in result.labels()


def test_risk_appetite_snippet(clf):
    text = (
        "Заявление риск-аппетита не содержит заявления качественного характера. "
        "Уровни риск-аппетита требуют корректирующих мер. Риск-аппетит калибруется."
    )
    result = clf.classify(text)
    assert result.primary.topic_id == "risk_appetite"


def test_stress_testing_snippet(clf):
    text = (
        "Надзорное стресс-тестирование НСТ 2025. Стрессовый сценарий и базовый "
        "сценарий на горизонт 12 кварталов. Стресс-тест достаточности капитала."
    )
    result = clf.classify(text)
    assert result.primary.topic_id == "supervisory_stress_testing"


def test_capital_snippet(clf):
    text = (
        "Собственный капитал банка и достаточность капитала k1. Основной капитал, "
        "уставный капитал и нераспределенная прибыль формируют капитал."
    )
    result = clf.classify(text)
    assert result.primary.topic_id == "capital_adequacy"


def test_empty_document_has_no_matches(clf):
    result = clf.classify("Погода сегодня хорошая, солнечно и тепло.")
    assert result.assigned == []


def test_scores_are_frequency_dampened(clf):
    # 'AQR' is a strong term that is not a substring of any other taxonomy term,
    # so the score reflects exactly one term firing N times.
    once = clf.classify("AQR")
    twice = clf.classify("AQR AQR")
    s1 = once.matches[0].score
    s2 = twice.matches[0].score
    # log-dampened: doubling occurrences must not double the score
    assert s2 > s1
    assert s2 < 2 * s1
    # scores are rounded to 3 decimals, so compare with matching abs tolerance
    assert s1 == pytest.approx(3.0, abs=1e-3)
    assert s2 == pytest.approx(3.0 * (1 + math.log(2)), abs=1e-3)


def test_multilabel_and_normalized_shares(clf):
    text = (
        "Кредитный риск и рыночный риск. Валидация моделей оценки кредитного риска. "
        "Внутренний аудит службы внутреннего аудита."
    )
    result = clf.classify(text)
    assert len(result.labels()) >= 2
    total_share = sum(m.normalized for m in result.matches)
    assert total_share == pytest.approx(1.0, abs=1e-3)
