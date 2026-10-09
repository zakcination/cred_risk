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

## ПК-сессия

| Имя | session_id | Где | Как держится |
|---|---|---|---|
| `nst_model_pick` | `session_01KwkK15swH7PdXJcFZeUcLV` | рабочий ПК, `C:\project_mz`, Remote Control | локальный px (`127.0.0.1:3128`) → корпоративный прокси по NTLM; окно px и окно Claude не закрывать |

Новая ПК-сессия на другую задачу: `claude remote-control --name "<задача>"` в нужной папке.

## Выводятся из работы (редакция 1)

Долгоживущие агенты редакции 1. Новых задач не получают; после дельты в `HANDOFF.md`
своего контура — архивируются Мирасом. Решения, которых они ждут, переносятся в issue.

| Агент | session_id | Ветка | Что ждёт решения на 09.10.2026 |
|---|---|---|---|
| Risk Agent 1 | `session_0114KTrN7DXPVMy55hfSdbmr` | `claude/cool-gates-bhjz01` | — |
| Risk Agent 2 | `session_01PYDbRXBp3RFzVc3uUkRjjc` | `claude/database-table-analysis-wxxgtv` | пороги X, Y; источник резерва Stage 2; критерий снижения долга; источник НЗ/СП |
| Risk Agent 3 | `session_01AXHoM5VUUuD8viQSvFTTEk` | `claude/cred-risk-topic-classifier-1cjbtk` | развилки Р-D1…Р-D6, шесть пробелов данных |
| Оркестратор р.1 | `session_01LXH69gkK16RnDosggxSWWw` | `claude/determined-cerf-fljw05` | — |

Входящий триггер редакции 1 `trig_015KKGyXj3ZiQK8knqicSGH8` удалён 09.10.2026: канал
«агент → оркестратор» заменён протоколом хода в issue.
