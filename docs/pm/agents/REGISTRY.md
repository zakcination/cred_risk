# Реестр агентов

Снимок 07.10.2026 по `get_session` / `list_sessions`. Контекст и статус меняются каждый ход —
живое состояние смотреть на доске («Доска агентов», закреплённое issue), здесь —
реквизиты.

| Агент | session_id | Ветка | Режим | Контекст | Статус на снимке |
|---|---|---|---|---|---|
| Оркестратор | `session_01LXH69gkK16RnDosggxSWWw` | `claude/determined-cerf-fljw05` | auto | — | входящий триггер `trig_015KKGyXj3ZiQK8knqicSGH8` |
| Risk Agent 1 | `session_0114KTrN7DXPVMy55hfSdbmr` | `claude/cool-gates-bhjz01` | **default** → перевести в auto | 717 тыс. / 1 млн | готово: разбор оздоровления (DPD15/DPD30, Stage 3) |
| Risk Agent 2 | `session_01PYDbRXBp3RFzVc3uUkRjjc` | `claude/database-table-analysis-wxxgtv` | auto | 683 тыс. / 1 млн | ждёт автора: пороги X, Y; источник резерва Stage 2; критерий снижения долга; источник НЗ/СП |
| Risk Agent 3 | `session_01AXHoM5VUUuD8viQSvFTTEk` | `claude/cred-risk-topic-classifier-1cjbtk` | auto | 240 тыс. / 1 млн | готово: оздоровление, развилки Р-D1…Р-D6, шесть пробелов данных |

## Закрепление за контурами

**Не назначено — решение Мираса.** На снимке все три агента работают по одной теме —
оздоровление / DPD15 / Stage 3, — что нарушает правило 2 протокола (один контур — один агент).

## Наблюдения

- Agent 1 и Agent 2 — около 70 % окна: по правилу 6 протокола им пора писать `HANDOFF.md`.
- Ветки Agent 2 и Agent 3 живут с июля; по Б2/Б3 их следует пересоздать от `main`
  после посадки открытых PR.
