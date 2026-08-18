# =============================================================================
# ЯЧЕЙКА 7 — ПЕРЕСЧЁТ С ИСПРАВЛЕННОЙ ШКАЛОЙ И РАЗЛОЖЕНИЕМ
#
# Три исправления по результатам первого прогона:
#
# 1. Порог перевода в проценты был 1.5 — он разрезал ряд пополам. Значения
#    вида 1.09 превращались в 109 (верно), а 2.41 оставались 2.41 (неверно,
#    должно быть 241). Отсюда скачки ±106…123 пп в 2017-2018: это моменты
#    смены формата записи в файлах, а не движение показателя. Порог 10.
#
# 2. Контроль пересчёта брал валовую задолженность. Проверка на трёх точках
#    показала, что доля считается от задолженности ЗА ВЫЧЕТОМ денежного
#    обеспечения: (ИТОГО − обеспечение) / СК.
#
# 3. Добавлено разложение прироста доли на вклад числителя и знаменателя.
#    Разложение точное: Δ = (N1−N0)/E0 + N1·(E0−E1)/(E0·E1).
# =============================================================================
import pandas as pd, numpy as np, json

SCALE_THRESHOLD = 10.0        # < 10 считаем долей/кратностью и умножаем на 100
WINDOW_START    = "2019-01-01"  # окно для калибровки; None — весь ряд

def as_percent2(v):
    if pd.isna(v): return np.nan
    return v * 100 if abs(v) < SCALE_THRESHOLD else v

d2 = df.copy()
d2["ratio_pct"] = d2["ratio"].apply(as_percent2)
d2["limit_pct"] = d2["limit"].apply(as_percent2)
d2["net_amt"]   = d2["total_raw_amt"] - d2["cash_collateral_amt"]
d2["ratio_recalc"] = 100 * d2["net_amt"] / d2["equity_amt"]
d2["ratio_diff"]   = d2["ratio_pct"] - d2["ratio_recalc"]

print("=" * 78); print("КОНТРОЛЬ ФОРМУЛЫ: доля = (ИТОГО − обеспечение) / СК"); print("=" * 78)
ok = d2["ratio_diff"].abs() <= 0.5
print(f"Совпадает в пределах 0,5 пп: {int(ok.sum())} из {int(d2['ratio_diff'].notna().sum())}")
bad = d2[~ok].dropna(subset=["ratio_diff"])
if len(bad):
    print(f"Не совпадает: {len(bad)}. По годам:")
    print(bad.groupby(bad["Report Date"].dt.year).size().to_string())
    print("\nПервые 15:")
    print(bad[["Report Date","ratio_pct","ratio_recalc","ratio_diff","File Name"]].head(15).to_string(index=False))

print("\n" + "=" * 78); print("ИСТОРИЯ УРОВНЯ ПОСЛЕ ИСПРАВЛЕНИЯ ШКАЛЫ"); print("=" * 78)
lh = d2.dropna(subset=["limit_pct"]).copy(); lh["prev"] = lh["limit_pct"].shift(1)
print(lh.groupby("limit_pct").agg(файлов=("File Name","count"), с=("Report Date","min"),
                                  по=("Report Date","max")).to_string())
print("\nМоменты смены:")
print(lh[(lh["limit_pct"] != lh["prev"]) & lh["prev"].notna()][
      ["Report Date","prev","limit_pct","File Name"]].to_string(index=False))

print("\n" + "=" * 78); print("ДОЛЯ ПО ГОДАМ ПОСЛЕ ИСПРАВЛЕНИЯ"); print("=" * 78)
s2 = d2.dropna(subset=["ratio_pct"]).set_index("Report Date")["ratio_pct"].sort_index()
print(s2.groupby(s2.index.year).agg(["count","min","mean","max","std"]).round(2).to_string())

# ---- калибровка в окне ----
w = s2 if WINDOW_START is None else s2[s2.index >= WINDOW_START]
print("\n" + "=" * 78); print(f"КАЛИБРОВКА В ОКНЕ С {WINDOW_START}: {len(w)} набл."); print("=" * 78)
dw = w.diff().dropna()
print(f"σ приращений в окне: {dw.std():.3f} пп   |Δ| медиана: {dw.abs().median():.3f}   max: {dw.abs().max():.3f}")
print("σ по годам:"); print(dw.groupby(dw.index.year).std().round(3).to_string())

above = w > RA_LIMIT
grp = (above != above.shift()).cumsum()
eps = [{"начало": b.index.min().date(), "конец": b.index.max().date(), "наблюдений": len(b),
        "дней": (b.index.max()-b.index.min()).days + 1, "максимум": round(b.max(), 2)}
       for _, b in w.groupby(grp) if b.iloc[0] > RA_LIMIT]
print(f"\nЭпизоды выше {RA_LIMIT}% в окне: {len(eps)}")
if eps: print(pd.DataFrame(eps).to_string(index=False))

# Предупреждение считается отдельно для КАЖДОГО эпизода, а не по первому в ряде
print("\nКандидаты в сигнальный уровень (предупреждение — по каждому эпизоду):")
rows = []
for thr in [78, 80, 82, 84, 85, 86, 88, 90, 92]:
    hit = w > thr
    warns = []
    for e in eps:
        bstart = pd.Timestamp(e["начало"])
        prior = w[(w.index < bstart) & (w > thr)]
        # непрерывный отрезок сигнала непосредственно перед пробоем
        if len(prior):
            t = prior.index.max()
            run = t
            for ts in w[(w.index < bstart)].index[::-1]:
                if w[ts] > thr: run = ts
                else: break
            warns.append((bstart - run).days)
        else:
            warns.append(0)
    false_n = 0
    for t in w.index[hit]:
        fut = w[(w.index > t) & (w.index <= t + pd.Timedelta(days=180))]
        if len(fut) and fut.max() <= RA_LIMIT: false_n += 1
    rows.append({"уровень": thr, "срабатываний": int(hit.sum()),
                 "предупреждение по эпизодам, дней": warns,
                 "ложных": false_n,
                 "доля времени в жёлтой, %": round(100*((w > thr) & (w <= RA_LIMIT)).mean(), 1)})
cand2 = pd.DataFrame(rows); print(cand2.to_string(index=False))

# ---- разложение ----
print("\n" + "=" * 78); print("РАЗЛОЖЕНИЕ ПРИРОСТА ДОЛИ"); print("=" * 78)
q = d2.dropna(subset=["net_amt","equity_amt"]).set_index("Report Date").sort_index()
q = q.resample("QE").last()[["ratio_pct","net_amt","equity_amt","total_raw_amt","cash_collateral_amt"]]
q["N0"], q["E0"] = q["net_amt"].shift(1), q["equity_amt"].shift(1)
q["вклад портфеля, пп"] = 100*(q["net_amt"] - q["N0"]) / q["E0"]
q["вклад капитала, пп"] = 100*q["net_amt"]*(q["E0"] - q["equity_amt"]) / (q["E0"]*q["equity_amt"])
q["Δ доли, пп"] = q["ratio_pct"].diff()
q["Δ СК, %"] = 100*q["equity_amt"].pct_change()
print(q.tail(12)[["ratio_pct","Δ доли, пп","вклад портфеля, пп","вклад капитала, пп","Δ СК, %"]].round(2).to_string())

d2.to_csv(OUT_DIR / "06_series_rescaled.csv", index=False, encoding="utf-8-sig")
cand2.to_csv(OUT_DIR / "06_candidates_windowed.csv", index=False, encoding="utf-8-sig")
q.to_csv(OUT_DIR / "06_decomposition.csv", encoding="utf-8-sig")

summary2 = {
    "окно": WINDOW_START, "наблюдений в окне": len(w),
    "σ приращений в окне, пп": round(float(dw.std()), 3),
    "σ по годам": {int(k): round(float(v), 3) for k, v in dw.groupby(dw.index.year).std().items()},
    "эпизоды выше лимита": [{k: (str(v) if hasattr(v, "isoformat") else v) for k, v in e.items()} for e in eps],
    "уровни лимита после исправления": sorted(d2["limit_pct"].dropna().unique().tolist()),
    "контроль формулы: совпало": int(ok.sum()), "не совпало": int((~ok).sum()),
    "мин/медиана/макс доли в окне": [round(float(w.min()),2), round(float(w.median()),2), round(float(w.max()),2)],
}
(OUT_DIR / "06_summary2.json").write_text(json.dumps(summary2, ensure_ascii=False, indent=2), encoding="utf-8")
print("\n" + "=" * 78); print("СВОДКА 2"); print("=" * 78)
print(json.dumps(summary2, ensure_ascii=False, indent=2))
