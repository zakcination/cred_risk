# -*- coding: utf-8 -*-
"""Калькулятор лимитов главы 11 Нормативов № 85 (пп. 98, 104, 105, 107).

Считает по помесячному ряду банка:
  98-1  рост займов 90+           — п. 107 пп. 1: строгий рост 7 точек ИЛИ прирост >= 5 %
  98-2  рост займов 61-90         — п. 107 пп. 2: те же конструкции
  98-3  НЗ/СП                     — п. 107 пп. 3: >= 10 %
  98-7  потребзаймы 90+ / потреб  — п. 107 пп. 7: >= 10 % (если колонки заполнены)
  98-8  заёмщики 90+ / заёмщики   — п. 107 пп. 8: >= 10 % (если колонки заполнены)
  п.105 проекции «негативного влияния» для 98-1 и 98-2 (экстраполяция 6 мес -> 12 мес)

Вход: CSV с колонками month;ZP90;ZP61_90;NZ;SP[;NPL_cons;S_cons;N_borr90;N_borr]
(суммы в млн тенге, gross по периметру п. 98; строки с # игнорируются).
Берутся последние 7 месячных точек (индексы 0..6 в терминах формул).

Запуск:  python3 limits98.py <файл.csv>
Самопроверка на синтетической фикстуре:  python3 limits98.py --selftest
"""

import csv
import sys

LIMIT_NPL = 10.0   # п. 104 пп. 2, п. 107 пп. 3
LIMIT_GROWTH = 5.0  # п. 107 пп. 1 и 2, %


def read_series(path):
    rows = []
    with open(path, encoding="utf-8-sig") as fh:
        head = fh.readline()
        delim = ";" if head.count(";") > head.count(",") else ","
        fh.seek(0)
        for r in csv.DictReader(
                (ln for ln in fh if not ln.lstrip().startswith("#")),
                delimiter=delim):
            if r.get("month", "").strip():
                rows.append(r)
    rows.sort(key=lambda r: r["month"])
    if len(rows) < 7:
        raise SystemExit(
            f"нужно минимум 7 месячных точек (индексы 0..6 формул), в файле {len(rows)}")
    if len({r["month"] for r in rows}) != len(rows):
        raise SystemExit("дубли месяцев в ряду — исправить входной файл")
    return rows[-7:]


def num(row, key):
    v = (row.get(key) or "").replace(" ", "").replace(",", ".").strip()
    return float(v) if v else None


def growth_trigger(vals, label):
    """П. 107 пп. 1/2: строгая монотонность семи точек либо прирост >= 5 %."""
    monotonic = all(vals[i + 1] > vals[i] for i in range(6))
    rel = (vals[6] - vals[0]) / vals[0] * 100 if vals[0] else float("inf")
    fired = monotonic or rel >= LIMIT_GROWTH
    kind = ("строгий рост 7 точек" if monotonic
            else f"прирост {rel:+.1f} % {'≥' if rel >= LIMIT_GROWTH else '<'} {LIMIT_GROWTH:.0f} %")
    return fired, rel, f"{label}: {'СРАБОТАЛ' if fired else 'не сработал'} ({kind})"


def project_105(zp0, zp6, sp0, sp6, nz6, zp90_6=None):
    """П. 105: экстраполяция полугодовой динамики на 12 месяцев.

    Для 98-1 передать ряд ЗП90 (zp90_6 не нужен):
        [ЗП90_12 + (НЗ_6 - ЗП90_6)] / СП_12
    Для 98-2 передать ряд ЗП61-90 и отдельно zp90_6:
        (ЗП90_6 + ЗП61-90_12) / СП_12
    """
    zp12 = (zp6 - zp0) * 2 + zp6
    sp12 = (sp6 - sp0) * 2 + sp6
    if sp12 <= 0:
        return None, zp12, sp12
    if zp90_6 is None:                      # вариант 98-1
        ratio = (zp12 + (nz6 - zp6)) / sp12 * 100
    else:                                   # вариант 98-2
        ratio = (zp90_6 + zp12) / sp12 * 100
    return ratio, zp12, sp12


def run(rows, out=print):
    months = [r["month"] for r in rows]
    zp90 = [num(r, "ZP90") for r in rows]
    zp6190 = [num(r, "ZP61_90") for r in rows]
    nz = [num(r, "NZ") for r in rows]
    sp = [num(r, "SP") for r in rows]
    for name, series in (("ZP90", zp90), ("ZP61_90", zp6190),
                         ("NZ", nz), ("SP", sp)):
        if any(v is None for v in series):
            raise SystemExit(f"колонка {name} заполнена не во всех 7 точках")

    out(f"окно: {months[0]} … {months[6]}  (точки 0..6 формул)")
    results = {}

    # 98-3 — главный лимит
    npl = nz[6] / sp[6] * 100
    results["98-3"] = npl >= LIMIT_NPL
    out(f"98-3 НЗ/СП = {nz[6]:,.0f} / {sp[6]:,.0f} = {npl:.2f} % "
        f"{'≥' if results['98-3'] else '<'} {LIMIT_NPL:.0f} % — "
        f"{'СРАБОТАЛ' if results['98-3'] else 'не сработал'}")
    if results["98-3"]:
        need_nz = nz[6] - LIMIT_NPL / 100 * sp[6]
        out(f"     до цели п. 104 пп. 2 (< 10 %): снизить НЗ на {need_nz:,.0f} млн ₸ "
            f"при неизменном СП (или эквивалентная комбинация)")

    # 98-1 и 98-2 — триггеры роста
    for code, series, label in (("98-1", zp90, "98-1 займы 90+"),
                                ("98-2", zp6190, "98-2 займы 61-90")):
        fired, rel, msg = growth_trigger(series, label)
        results[code] = fired
        out(msg)

    # п. 105 — проекции
    p1, zp12, sp12 = project_105(zp90[0], zp90[6], sp[0], sp[6], nz[6])
    out(f"п.105/98-1: ЗП90_12 = {zp12:,.0f}, СП_12 = {sp12:,.0f}, "
        f"проекция НЗ/СП = {p1:.2f} % — "
        f"{'негативное влияние ЕСТЬ' if p1 is not None and p1 >= LIMIT_NPL else 'негативного влияния нет'}")
    p2, zp12b, _ = project_105(zp6190[0], zp6190[6], sp[0], sp[6], nz[6],
                               zp90_6=zp90[6])
    out(f"п.105/98-2: ЗП61-90_12 = {zp12b:,.0f}, "
        f"проекция (ЗП90_6+ЗП61-90_12)/СП_12 = {p2:.2f} % — "
        f"{'негативное влияние ЕСТЬ' if p2 is not None and p2 >= LIMIT_NPL else 'негативного влияния нет'}")
    results["105-1"], results["105-2"] = (p1 is not None and p1 >= LIMIT_NPL,
                                          p2 is not None and p2 >= LIMIT_NPL)

    # 98-7 / 98-8 — потребительский срез, если данные есть
    last = rows[6]
    npl_c, s_c = num(last, "NPL_cons"), num(last, "S_cons")
    if npl_c is not None and s_c:
        k = npl_c / s_c * 100
        results["98-7"] = k >= LIMIT_NPL
        out(f"98-7 потреб-90+/потреб = {k:.2f} % — "
            f"{'СРАБОТАЛ' if results['98-7'] else 'не сработал'}")
    nb90, nb = num(last, "N_borr90"), num(last, "N_borr")
    if nb90 is not None and nb:
        k = nb90 / nb * 100
        results["98-8"] = k >= LIMIT_NPL
        out(f"98-8 заёмщики-90+/заёмщики = {k:.2f} % — "
            f"{'СРАБОТАЛ' if results['98-8'] else 'не сработал'}")

    # следствие п. 103 пп. 1
    if results["98-3"] and (results["98-1"] or results["98-2"]):
        out("п.103 пп.1: 98-3 сработал — отдельные планы по 98-1/98-2 "
            "не представляются, всё в одном плане по 98-3")
    return results


# ------------------------------------------------------------ фикстура ---
def selftest():
    # синтетический ряд: НЗ/СП пробивает 10 %, ЗП90 растёт монотонно,
    # ЗП61-90 растёт на 4 % (ниже порога и без монотонности)
    fix = []
    sp = 1_000_000.0
    zp90 = [80_000 + 2_000 * i for i in range(7)]            # строгий рост
    zp6190 = [50_000, 50_500, 50_200, 51_000, 50_800, 51_500, 52_000]  # +4 %
    nz = [95_000 + 3_000 * i for i in range(7)]              # 9.5 % -> 11.3 %
    for i in range(7):
        fix.append({"month": f"2026-{i+2:02d}", "ZP90": str(zp90[i]),
                    "ZP61_90": str(zp6190[i]), "NZ": str(nz[i]),
                    "SP": str(sp), "NPL_cons": "9000", "S_cons": "100000",
                    "N_borr90": "12000", "N_borr": "100000"})
    res = run(fix, out=lambda *a: None)
    assert res["98-3"] is True,  "фикстура: 98-3 должен сработать (11,3 %)"
    assert res["98-1"] is True,  "фикстура: 98-1 монотонный рост"
    assert res["98-2"] is False, "фикстура: 98-2 прирост 4 % < 5 %"
    assert res["98-7"] is False, "фикстура: 9 % < 10 %"
    assert res["98-8"] is True,  "фикстура: 12 % >= 10 %"
    # проекция 98-1 вручную: ЗП90_12 = 12000*2+92000 = 116000;
    # НЗ_6-ЗП90_6 = 113000-92000 = 21000; (116000+21000)/1000000 = 13.7 %
    p1, _, _ = project_105(80_000, 92_000, sp, sp, 113_000)
    assert abs(p1 - 13.7) < 0.01, f"проекция 98-1: ожидалось 13.7, получено {p1}"
    print("самопроверка пройдена: 6 утверждений")
    run(fix)  # показать вывод на фикстуре


if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] == "--selftest":
        selftest()
    else:
        run(read_series(sys.argv[1]))
