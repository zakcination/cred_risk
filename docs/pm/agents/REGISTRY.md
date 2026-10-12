# Реестр офиса агентов

Реквизиты, зависящие от аккаунта Claude (`PROTOCOL.md` §10). Живое состояние — на доске
(issue #161), здесь — идентификаторы.

## Routines (личный аккаунт, окружение `env_01VKKUaFe5SKrJYCdpjco7yc`)

| Routine | id | Расписание | Что делает |
|---|---|---|---|
| Секретарь: утренняя доска | `trig_015vUatVLwuTHazGqbYvy2bX` | пн–пт 07:45, Алматы | тело #161 + комментарий «Ждёт решения Мираса» |
| Пятница: Б4, Б7, метрики | `trig_01T13J2WT2WYLhYbydShLK6J` | пт 15:52, Алматы | недельная сводка в #161, сверка `HYPOTHESES.md` |

Обе стартуют свежей сессией на каждый прогон (`PROTOCOL.md` §2, Г-2) и ничего не мёрджат.

**Обе отключены 09.10.2026:** на пробном прогоне у routine не оказалось доступа к репозиторию (403).
Пересоздаются в claude.ai → Routines по текстам из `ROUTINES.md`; id здесь заменить после проверки.

## ПК-сессии

Рабочий ПК, `C:\project_mz`, Remote Control; локальный px (`127.0.0.1:3128`) → корпоративный
прокси по NTLM. После сна ПК px и сессии надо поднять заново; `claude --resume` + `/remote-control`
выдаёт сессии **новый** session_id — старый остаётся мёртвой записью и архивируется.

| Задача | session_id | Issue | Состояние на 12.10.2026 |
|---|---|---|---|
| Подбор моделей НСТ (перебор) | `session_016osiz4yvAMHtsZFi3zZxkJ` | #165 | работает; контекст > 400k — после раунда передаёт дела в `INVENTORY_models.md` |
| Разбор пакета НСТ-2025 | `session_014LTyoYC3XX8sxYgseuTsMr` | #168 | работает |

Новая ПК-сессия на другую задачу: `claude remote-control --name "<задача>"` в нужной папке.
Две ПК-сессии одновременно — только если одна из них не использует Excel через COM.

## Облачные сессии на issue

| Задача | session_id | Issue | Ветка / PR | Состояние |
|---|---|---|---|---|
| Track A, перенос на 01.09 | `session_01AQj9BiB7HKz4mrFHdDDEKZ` | #164 | `claude/provisions-track-a-ed2` / #166 | ждёт решений Мираса; дела переданы в `HANDOFF.md`; архивировать после ответа |

## Архив (12.10.2026)

| session_id | Что | Почему закрыта |
|---|---|---|
| `session_01JQepJKb6VEdoSczwRs8t3C` | Track A, ред. 2 | заменена сессией переноса на 01.09; всё в ветке PR #166 |
| `session_01AXHoM5VUUuD8viQSvFTTEk` | Risk Agent 3 | работа в PR #162, ждёт слияния Мирасом |
| `session_01KwkK15swH7PdXJcFZeUcLV` | ПК `nst_model_pick` | задача 09.10 выполнена |
| `session_01XbYqsHBWwdMKQNZuPotd81`, `session_01TeQiXnHtc1mYac9CBi4Y2Q` | ПК «Project_mz venv» | мёртвые записи после переподключения |

## Выводятся из работы (редакция 1)

Долгоживущие агенты редакции 1. Новых задач не получают; после дельты в `HANDOFF.md`
своего контура — архивируются Мирасом. Решения, которых они ждут, переносятся в issue.

| Агент | session_id | Ветка | Что ждёт решения на 09.10.2026 |
|---|---|---|---|
| Risk Agent 1 | `session_0114KTrN7DXPVMy55hfSdbmr` | `claude/cool-gates-bhjz01` | **не архивировать:** коммит `HANDOFF.md` заблокирован режимом auto — Мирасу снять auto в сессии либо закоммитить вручную (PR #159) |
| Risk Agent 2 | `session_01PYDbRXBp3RFzVc3uUkRjjc` | `claude/database-table-analysis-wxxgtv` | **не архивировать:** коммит `19fcb5d` (`dpd15_cure/HANDOFF.md`) не запушен — архив удалит его вместе с контейнером. Плюс решения: пороги X, Y; источник резерва Stage 2; критерий снижения долга; источник НЗ/СП |
| ~~Risk Agent 3~~ | `session_01AXHoM5VUUuD8viQSvFTTEk` | `claude/cred-risk-topic-classifier-1cjbtk` | **архивирована 12.10.2026**; PR #162 ждёт слияния; развилки Р-D1…Р-D6 — в PR |
| Оркестратор р.1 | `session_01LXH69gkK16RnDosggxSWWw` | `claude/determined-cerf-fljw05` | — |

Входящий триггер редакции 1 `trig_015KKGyXj3ZiQK8knqicSGH8` удалён 09.10.2026: канал
«агент → оркестратор» заменён протоколом хода в issue.
