# -*- coding: utf-8 -*-
"""Витрина риск-метрик: расчёт динамики и рендер полочек.

Читает registry/*.csv (реестр метрик, полочек, последствий) и
data/observations.csv (факты: code;period;value) и считает по каждой
метрике: зону, утилизацию, запас, скорость приближения за отчётный
период / квартал / год, срок до пробоя при текущей скорости, расстояние
в сигмах, состояние счётчиков длительности (6 месяцев подряд, 3 из 6
и т. п.), время в зоне и повторяемость за 12 периодов.

Запуск:  python3 build/showcase.py                 — сводка + HTML
         python3 build/showcase.py --selftest      — самопроверка
Данных банка в репозитории нет: observations.csv в .gitignore.
"""

import csv
import os
import statistics as st
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

FREQ_ORDER = {"E": 0, "D": 1, "W": 2, "M": 3, "Q": 4, "Y": 5}
FREQ_RU = {"E": "по событию", "D": "ежедневно", "W": "еженедельно",
           "M": "ежемесячно", "Q": "ежеквартально", "Y": "ежегодно"}
CONTOUR_RU = {"оперативный": "Оперативный монитор",
              "управленческий": "Управленческий отчёт",
              "РА-квартальный": "Отчёт об уровнях РА",
              "стресс": "Стресс-тест"}


def read(name):
    path = os.path.join(ROOT, name)
    with open(path, encoding="utf-8-sig") as fh:
        rows = [r for r in csv.DictReader(
            (ln for ln in fh if not ln.lstrip().startswith("#")), delimiter=";")]
    # разделитель внутри значения сдвигает все колонки — ловим сразу
    bad = [r for r in rows if None in r or any(v is None for v in r.values())]
    if bad:
        key = bad[0].get("code") or bad[0].get("shelf") or "?"
        raise SystemExit(
            f"РАЗБОР ОСТАНОВЛЕН — в {name} строка «{key}» содержит лишние "
            f"разделители ';' внутри значений либо пропущенные колонки")
    return rows


def num(v):
    """'12,5' -> 12.5; пустое -> None."""
    v = (v or "").replace(" ", "").replace(" ", "").replace(",", ".").strip()
    if not v:
        return None
    try:
        return float(v)
    except ValueError:
        return None


def ru(x, digits=2):
    if x is None:
        return "—"
    return f"{x:,.{digits}f}".replace(",", " ").replace(".", ",")


# ------------------------------------------------------------- зоны -----
def zone_of(value, m):
    """green / yellow / red / na. Жёлтая — между сигнальным и лимитом."""
    lim, sig, d = num(m["limit"]), num(m["signal"]), m["direction"]
    if value is None or lim is None:
        return "na"
    if d == "up_bad":
        if value >= lim:
            return "red"
        if sig is not None and value >= sig:
            return "yellow"
        return "green"
    if d == "down_bad":
        if value <= lim:
            return "red"
        if sig is not None and value <= sig:
            return "yellow"
        return "green"
    return "na"


def breached(value, m):
    return zone_of(value, m) == "red"


# --------------------------------------------------------- счётчики -----
def counter_state(series, m):
    """Возвращает (текст, сколько, из скольких, сработал ли).

    series — значения по возрастанию периодов.
    """
    kind = m["counter"] or "single"
    vals = [v for v in series if v is not None]
    if not vals:
        return ("нет данных", 0, 0, False)

    if kind == "single":
        fired = breached(vals[-1], m)
        return ("разовое событие", 1 if fired else 0, 1, fired)

    if kind == "6M_consec":
        n = 0
        for v in reversed(vals):
            if breached(v, m):
                n += 1
            else:
                break
        return (f"{n} из 6 месяцев подряд", n, 6, n >= 6)

    if kind in ("3of6M", "2of6M"):
        need = 3 if kind == "3of6M" else 2
        window = vals[-6:]
        n = sum(1 for v in window if breached(v, m))
        return (f"{n} из 6 месяцев (порог {need})", n, need, n >= need)

    if kind == "2Q_consec":
        n = 0
        for v in reversed(vals):
            if breached(v, m):
                n += 1
            else:
                break
        return (f"{n} квартала подряд (порог 2)", n, 2, n >= 2)

    if kind == "7M_monotonic":
        # строгий рост семи последовательных точек либо прирост >= 5 %
        w = vals[-7:]
        mono = len(w) == 7 and all(w[i + 1] > w[i] for i in range(6))
        rel = ((w[-1] - w[0]) / w[0] * 100) if len(w) >= 2 and w[0] else 0.0
        n = 1
        for i in range(len(vals) - 1, 0, -1):
            if vals[i] > vals[i - 1]:
                n += 1
            else:
                break
        fired = mono or rel >= 5
        txt = f"рост {n} точек подряд; прирост {ru(rel, 1)} %"
        return (txt, n, 7, fired)

    return (kind, 0, 0, False)


# --------------------------------------------------------- динамика -----
def dynamics(series, m):
    """Скорость, ETA, сигмы, время в зоне, повторяемость."""
    vals = [v for v in series if v is not None]
    out = {"last": vals[-1] if vals else None, "speed_p": None, "speed_q": None,
           "speed_y": None, "eta": None, "sigma": None, "sigma_dist": None,
           "in_zone": 0, "over_limit": 0, "breaches_12": 0, "trend": ""}
    if not vals:
        return out
    lim, d = num(m["limit"]), m["direction"]
    last = vals[-1]

    def delta(k):
        if len(vals) > k:
            return (last - vals[-1 - k]) / k
        return None

    out["speed_p"] = delta(1)
    out["speed_q"] = delta(3)
    out["speed_y"] = delta(12)

    diffs = [vals[i + 1] - vals[i] for i in range(len(vals) - 1)]
    if len(diffs) >= 2:
        out["sigma"] = st.stdev(diffs)

    if lim is not None:
        head = (lim - last) if d == "up_bad" else (last - lim)
        out["head"] = head
        if out["sigma"]:
            out["sigma_dist"] = head / out["sigma"] if out["sigma"] else None
        sp = out["speed_q"] if out["speed_q"] is not None else out["speed_p"]
        if sp:
            # движение к лимиту: рост при up_bad, падение при down_bad
            toward = sp > 0 if d == "up_bad" else sp < 0
            if toward and head > 0:
                out["eta"] = abs(head / sp)
        out["in_zone"] = 0
        for v in reversed(vals):
            if zone_of(v, m) in ("yellow", "red"):
                out["in_zone"] += 1
            else:
                break
        for v in reversed(vals):
            if breached(v, m):
                out["over_limit"] += 1
            else:
                break
        out["breaches_12"] = sum(1 for v in vals[-12:] if breached(v, m))

    if out["speed_q"] is not None:
        out["trend"] = "растёт" if out["speed_q"] > 0 else (
            "снижается" if out["speed_q"] < 0 else "без изменений")
    return out


def utilization(value, m):
    lim, d = num(m["limit"]), m["direction"]
    if value is None or not lim:
        return None
    return (value / lim * 100) if d == "up_bad" else (lim / value * 100)


# ------------------------------------------------------------- сбор -----
def collect(metrics, obs):
    by_code = {}
    for r in obs:
        by_code.setdefault(r["code"], []).append((r["period"], num(r["value"])))
    result = []
    for m in metrics:
        series_pairs = sorted(by_code.get(m["code"], []))
        series = [v for _, v in series_pairs]
        periods = [p for p, _ in series_pairs]
        dyn = dynamics(series, m)
        ctext, cnow, cneed, cfired = counter_state(series, m)
        z = zone_of(dyn["last"], m)
        mismatch = (FREQ_ORDER.get(m["monitor_freq"], 9)
                    > FREQ_ORDER.get(m["data_freq"], 9))
        result.append({**m, "series": series, "periods": periods, "dyn": dyn,
                       "zone": z if not cfired else ("red" if cfired else z),
                       "counter_text": ctext, "counter_now": cnow,
                       "counter_need": cneed, "counter_fired": cfired,
                       "util": utilization(dyn["last"], m),
                       "freq_mismatch": mismatch,
                       "last_period": periods[-1] if periods else ""})
    return result


# ------------------------------------------------------------ сводка ----
def summary(rows, out=print):
    order = {"red": 0, "yellow": 1, "green": 2, "na": 3}
    hot = sorted(rows, key=lambda r: (order[r["zone"]], -(r["util"] or 0)))
    out(f"{'код':<9}{'метрика':<40}{'факт':>9}{'лимит':>8}"
        f"{'утил.%':>8}{'зона':>8}{'мес.>лим':>9}  счётчик")
    for r in hot:
        if r["zone"] == "na":
            continue
        out(f"{r['code']:<9}{r['name'][:38]:<40}{ru(r['dyn']['last']):>9}"
            f"{r['limit']:>8}{ru(r['util'], 1):>8}{r['zone']:>8}"
            f"{r['dyn']['over_limit']:>9}  {r['counter_text']}")
    n_red = sum(1 for r in rows if r["zone"] == "red")
    n_yel = sum(1 for r in rows if r["zone"] == "yellow")
    n_na = sum(1 for r in rows if r["zone"] == "na")
    out(f"\nкрасных: {n_red}  жёлтых: {n_yel}  без данных: {n_na}  "
        f"всего метрик: {len(rows)}")
    mism = [r["code"] for r in rows if r["freq_mismatch"]]
    if mism:
        out(f"контроль реже данных (правило нарушено): {', '.join(mism)}")


# --------------------------------------------------------- фикстура ----
def selftest_rows():
    """Строит витрину на демонстрационных значениях."""
    metrics = read("registry/metrics.csv")
    idx = {m["code"]: m for m in metrics}

    # 98-3: доля выше 10 % пять месяцев подряд, растёт
    s983 = [9.4, 9.8, 10.2, 10.5, 10.8, 11.1]
    obs = [{"code": "98-3", "period": f"2026-{i+3:02d}", "value": str(v).replace(".", ",")}
           for i, v in enumerate(s983)]
    # 119-9 та же доля (ДС3), но КПП высокий -> в реестре условие текстом,
    # счётчик считаем по значению: 4 месяца подряд выше 10
    obs += [{"code": "119-9", "period": f"2026-{i+3:02d}", "value": str(v).replace(".", ",")}
            for i, v in enumerate(s983)]
    # k2: снижается, но выше лимита
    for i, v in enumerate([27.6, 27.0, 24.9, 22.1, 22.9, 22.4]):
        obs.append({"code": "k2", "period": f"2026-{i+3:02d}", "value": str(v).replace(".", ",")})
    # RA-01 топ-20: пробой лимита 95
    for i, v in enumerate([75.6, 77.0, 76.2, 92.6, 101.5]):
        obs.append({"code": "RA-01", "period": f"2026-{i+4:02d}", "value": str(v).replace(".", ",")})

    rows = collect(metrics, obs)
    by = {r["code"]: r for r in rows}

    assert by["98-3"]["zone"] == "red", "98-3 должен быть в красной зоне"
    assert by["98-3"]["counter_fired"], "98-3: разовый триггер сработал"
    assert by["98-3"]["dyn"]["over_limit"] == 4, \
        f"98-3: 4 месяца подряд выше лимита, получено {by['98-3']['dyn']['over_limit']}"
    assert by["98-3"]["dyn"]["in_zone"] == 6, \
        f"98-3: 6 месяцев подряд не в зелёной зоне, получено {by['98-3']['dyn']['in_zone']}"
    assert by["119-9"]["counter_now"] == 4 and not by["119-9"]["counter_fired"], \
        "119-9: 4 из 6 месяцев, счётчик ещё не закрыт"
    assert by["k2"]["zone"] == "green", "k2 22,4 % при лимите 10,5 % — зелёная"
    assert by["k2"]["dyn"]["trend"] == "снижается", "k2 снижается"
    assert by["RA-01"]["zone"] == "red", "топ-20 101,5 при лимите 95 — красная"
    u = by["RA-01"]["util"]
    assert abs(u - 106.8) < 0.1, f"утилизация топ-20: ожидалось 106,8, получено {u}"
    # ETA: 98-3 растёт ~0,3 п.п. в месяц, лимит уже пробит -> eta None
    assert by["98-3"]["dyn"]["eta"] is None, "лимит пробит — ETA не считается"
    # проверка ETA на метрике с запасом: k2 down_bad, запас есть
    assert by["k2"]["dyn"]["eta"] is not None, "k2 снижается — ETA должен считаться"
    return rows, metrics


def selftest():
    rows, _ = selftest_rows()
    print("самопроверка пройдена: 10 утверждений\n")
    summary(rows)
    return rows


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
    else:
        metrics = read("registry/metrics.csv")
        obs_path = os.path.join(ROOT, "data", "observations.csv")
        obs = read("data/observations.csv") if os.path.exists(obs_path) else []
        if not obs:
            raise SystemExit(
                "нет data/observations.csv — заполните по шаблону "
                "data/observations_template.csv (code;period;value)")
        rows = collect(metrics, obs)
        summary(rows)
