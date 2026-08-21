# -*- coding: utf-8 -*-
"""
Восстановление правил сегментации по финальному распределению регулятора.

Вход  : таблица нашей отчётности + колонка с финальным сегментом от регулятора.
Выход : правила отнесения к каждому сегменту, перечень значимых колонок,
        минимальный набор колонок, справочник значений, сверка с нашей сегментацией.

Запускается одинаково в Google Colab и локально. Ячейки размечены `# %%`.

ПДн: iin_bin нужен только для расчёта агрегата по заёмщику. Сразу после расчёта
он и остальные прямые идентификаторы удаляются (см. ячейку 3). Ничего, кроме
агрегатов и правил, дальше по конвейеру не идёт.
"""

# %% [markdown]
# ## 1. Конфигурация
#
# Единственная ячейка, которую нужно править. Имена колонок — из выгрузки B1A.

# %%
CONFIG = {
    # --- файл ---
    "path": "report.xlsx",          # csv / xlsx с нашей отчётностью
    "sheet": 0,                     # для xlsx: имя или номер листа
    "sep": ";",                     # для csv
    # --- целевые колонки ---
    "target": "segment_regulator",  # финальное распределение регулятора (ответ)
    "our_segment": "segment_afr",   # наша сегментация для сверки; None если нет
    # --- параметры расчёта ---
    "capital": 461_235_157_000,     # собственный капитал на отчётную дату
    "report_date": "2024-12-31",
    "individual_threshold": 0.002,  # 0,2 % капитала
    # --- колонки, которые нельзя подавать в модель ---
    "pii_cols": ["name", "contract_number", "account_no"],
    "id_cols": ["n_o", "id", "loan_id", "loan_id_kr", "credit_line_id",
                "ef_batches_int_id", "ef_contract_id", "creditor_no"],
    "borrower_key": "iin_bin",      # удаляется после расчёта агрегатов
    # --- модель ---
    "max_depth": 12,                # 8 мало: правила вложенные, F1 падает с 0,97 до 0,88
    "min_samples_leaf": 20,
    "selection_eps": 0.001,         # порог прироста в жадном отборе
    "selection_patience": 3,        # сколько шагов продолжать после выхода на плато
    "test_size": 0.25,
    "random_state": 0,
    "onehot_max_card": 50,          # выше этого — топ-N значений + прочее
    "onehot_top_n": 30,
    "subsample_for_selection": 150_000,
}

STUBS = {"1111111111111", "9999999999999", "1111111111111.0", "9999999999999.0"}

# базы задолженности: методика — без пеней; скрипт банка — с пенями
DEBT_BASE_METOD = ["od", "od_del", "interest", "interest_del", "disc_prem"]
DEBT_BASE_SCRIPT = DEBT_BASE_METOD + ["correction", "penalty"]

# %% [markdown]
# ## 2. Загрузка

# %%
import warnings
import numpy as np
import pandas as pd

warnings.filterwarnings("ignore")
pd.set_option("display.width", 200)
pd.set_option("display.max_columns", 80)


def read_any(path, sheet=0, sep=";"):
    low = str(path).lower()
    if low.endswith((".xlsx", ".xlsm", ".xls")):
        return pd.read_excel(path, sheet_name=sheet, dtype=str)
    for enc in ("utf-8-sig", "utf-8", "cp1251"):
        try:
            return pd.read_csv(path, sep=sep, dtype=str, encoding=enc,
                               low_memory=False)
        except UnicodeDecodeError:
            continue
    raise RuntimeError("не удалось определить кодировку файла")


df = read_any(CONFIG["path"], CONFIG["sheet"], CONFIG["sep"])
df.columns = [c.strip().lower() for c in df.columns]
print("загружено:", df.shape[0], "строк,", df.shape[1], "колонок")

TARGET = CONFIG["target"].lower()
assert TARGET in df.columns, (
    "колонки '%s' нет в файле. Имеющиеся: %s" % (TARGET, list(df.columns)[:40]))

df = df[df[TARGET].notna() & (df[TARGET].astype(str).str.strip() != "")]
print("строк с известным ответом регулятора:", len(df))
print("\nраспределение регулятора:")
print(df[TARGET].value_counts().to_frame("строк").assign(
    доля=lambda x: (100 * x["строк"] / len(df)).round(2)))

# %% [markdown]
# ## 3. Признаки: числа, заглушки, агрегаты по заёмщику
#
# Три признака дерево не найдёт само, поэтому считаются здесь:
# сумма задолженности по заёмщику, доля от капитала, срок займа в годах.

# %%
def to_num(s):
    """Текст -> число. Заглушки и мусор -> NaN. Учитывает запятую и пробелы."""
    x = s.astype(str).str.strip()
    x = x.where(~x.isin(STUBS))
    x = (x.str.replace(" ", "", regex=False)
          .str.replace(" ", "", regex=False)
          .str.replace(",", ".", regex=False))
    return pd.to_numeric(x, errors="coerce")


def numeric_share(s, n=5000):
    smp = s.dropna().head(n)
    if len(smp) == 0:
        return 0.0
    return to_num(smp).notna().mean()


service = set(CONFIG["pii_cols"] + CONFIG["id_cols"] +
              [TARGET, CONFIG["borrower_key"]])
if CONFIG["our_segment"]:
    service.add(CONFIG["our_segment"].lower())

num_cols, cat_cols = [], []
for c in df.columns:
    if c in service:
        continue
    if numeric_share(df[c]) > 0.95 and df[c].nunique(dropna=True) > 10:
        num_cols.append(c)
    else:
        cat_cols.append(c)

print("числовых колонок:", len(num_cols), "| категориальных:", len(cat_cols))

feat = pd.DataFrame(index=df.index)
for c in num_cols:
    feat[c] = to_num(df[c])
for c in cat_cols:
    feat[c] = df[c].astype(str).str.strip().replace(
        {"nan": np.nan, "": np.nan, "None": np.nan})

# --- инженерные признаки ---
bk = CONFIG["borrower_key"]

def debt_sum(cols):
    have = [c for c in cols if c in df.columns]
    if not have:
        return None
    return pd.concat([to_num(df[c]).fillna(0) for c in have], axis=1).sum(axis=1)

d_met = debt_sum(DEBT_BASE_METOD)
d_scr = debt_sum(DEBT_BASE_SCRIPT)
if d_met is not None:
    feat["eng_zadol_metod"] = d_met
if d_scr is not None:
    feat["eng_zadol_script"] = d_scr

if bk in df.columns and d_scr is not None:
    grp = df[bk].astype(str)
    feat["eng_zadol_borrower"] = d_scr.groupby(grp).transform("sum")
    feat["eng_share_capital"] = feat["eng_zadol_borrower"] / CONFIG["capital"]
    feat["eng_over_02pct"] = (
        feat["eng_share_capital"] > CONFIG["individual_threshold"]).astype(int)
    feat["eng_contracts_of_borrower"] = grp.map(grp.value_counts()).astype(float)
    print("агрегаты по заёмщику посчитаны, заёмщиков:", grp.nunique())

if {"loan_start_date", "loan_end_date"} <= set(df.columns):
    ds = pd.to_datetime(df["loan_start_date"], errors="coerce", dayfirst=True)
    de = pd.to_datetime(df["loan_end_date"], errors="coerce", dayfirst=True)
    rep = pd.Timestamp(CONFIG["report_date"])
    feat["eng_srok_let"] = (de - ds).dt.days / 365.25
    feat["eng_srok_ost_let"] = (de - rep).dt.days / 365.25
    feat["eng_srok_ge_5let"] = (feat["eng_srok_let"] >= 5).astype(float)
    print("срок займа посчитан")

y = df[TARGET].astype(str).str.strip()
our = df[CONFIG["our_segment"].lower()].astype(str).str.strip() \
    if CONFIG["our_segment"] and CONFIG["our_segment"].lower() in df.columns else None

# ПДн больше не нужны
df = df[[c for c in df.columns if c not in set(CONFIG["pii_cols"]) | {bk}]]
print("PII и ключ заёмщика удалены из рабочей таблицы")

# %% [markdown]
# ## 4. Кодирование
#
# Категориальные — в one-hot, чтобы правила читались как `ent_type == 3`,
# а не как бессмысленное `ent_type <= 1.5`. Пропуски — отдельным индикатором.

# %%
FEATURE_META = {}   # имя признака -> (колонка, значение | None)
blocks = []

for c in feat.columns:
    s = feat[c]
    if s.dtype.kind in "fiu":
        col = s.astype(float)
        if col.isna().any():
            ind = col.isna().astype(np.int8).rename(c + "__пропуск")
            blocks.append(ind)
            FEATURE_META[ind.name] = (c, "пропуск")
        col = col.fillna(-9.99e14).rename(c)
        blocks.append(col)
        FEATURE_META[c] = (c, None)
    else:
        vc = s.value_counts(dropna=True)
        vals = list(vc.index[:CONFIG["onehot_top_n"]]) \
            if len(vc) > CONFIG["onehot_max_card"] else list(vc.index)
        for v in vals:
            name = "%s == %s" % (c, v)
            blocks.append((s == v).astype(np.int8).rename(name))
            FEATURE_META[name] = (c, v)
        if len(vc) > len(vals):
            name = "%s == <прочее>" % c
            blocks.append((~s.isin(vals) & s.notna()).astype(np.int8).rename(name))
            FEATURE_META[name] = (c, "<прочее>")

X = pd.concat(blocks, axis=1)
X = X.loc[:, ~X.columns.duplicated()]
print("матрица признаков:", X.shape)

rare = y.value_counts()
rare = rare[rare < 30]
if len(rare):
    print("\nВНИМАНИЕ: сегменты с малым числом наблюдений — правила по ним ненадёжны:")
    print(rare.to_frame("строк"))

# %% [markdown]
# ## 5. Дерево решений и качество

# %%
from sklearn.tree import DecisionTreeClassifier, export_text
from sklearn.model_selection import train_test_split
from sklearn.metrics import classification_report, confusion_matrix

strat = y if y.value_counts().min() >= 2 else None
X_tr, X_te, y_tr, y_te = train_test_split(
    X, y, test_size=CONFIG["test_size"],
    random_state=CONFIG["random_state"], stratify=strat)

clf = DecisionTreeClassifier(
    max_depth=CONFIG["max_depth"],
    min_samples_leaf=CONFIG["min_samples_leaf"],
    class_weight="balanced",
    random_state=CONFIG["random_state"])
clf.fit(X_tr, y_tr)

print("точность на обучении :", round(clf.score(X_tr, y_tr), 5))
print("точность на контроле :", round(clf.score(X_te, y_te), 5))
print("\nПо сегментам (контрольная выборка):")
print(classification_report(y_te, clf.predict(X_te), zero_division=0, digits=4))

# %% [markdown]
# ## 6. Значимые колонки
#
# Важность собирается с уровня one-hot обратно на уровень исходной колонки —
# именно она нужна для справочника.

# %%
imp = pd.Series(clf.feature_importances_, index=X.columns)
by_col = {}
for f, v in imp.items():
    col = FEATURE_META.get(f, (f, None))[0]
    by_col[col] = by_col.get(col, 0.0) + v

importance = (pd.Series(by_col).sort_values(ascending=False)
              .to_frame("важность"))
importance["важность"] = (100 * importance["важность"]).round(3)
importance = importance[importance["важность"] > 0]
print("Колонки, которые регулятор фактически использует:\n")
print(importance)

# %% [markdown]
# ## 7. Правила по каждому сегменту
#
# Отдельное неглубокое дерево «сегмент против всех» — читается гораздо лучше,
# чем одно большое дерево на все классы.

# %%
def decode(fname, threshold, go_left):
    col, val = FEATURE_META.get(fname, (fname, None))
    if val is None:
        return "%s %s %.6g" % (col, "<=" if go_left else ">", threshold)
    if val == "пропуск":
        return "%s %s" % (col, "заполнено" if go_left else "НЕ заполнено")
    return "%s %s '%s'" % (col, "!=" if go_left else "==", val)


def tree_rules(model, feature_names, positive_label="ДА", min_samples=1):
    t = model.tree_
    out = []

    def walk(node, conds):
        if t.feature[node] != -2:
            f = feature_names[t.feature[node]]
            thr = t.threshold[node]
            walk(t.children_left[node], conds + [decode(f, thr, True)])
            walk(t.children_right[node], conds + [decode(f, thr, False)])
            return
        counts = t.value[node][0]
        n = int(t.n_node_samples[node])
        pred = int(np.argmax(counts))
        purity = counts[pred] / counts.sum() if counts.sum() else 0.0
        if pred == 1 and n >= min_samples:
            out.append({"условия": conds, "строк": n, "чистота": round(purity, 4)})

    walk(0, [])
    return sorted(out, key=lambda r: -r["строк"])


rules_report = []
for seg in y.value_counts().index:
    tgt = (y == seg).astype(int)
    if tgt.sum() < 30:
        rules_report.append("### %s — %d строк, для правила мало\n" % (seg, tgt.sum()))
        continue
    m = DecisionTreeClassifier(max_depth=4, min_samples_leaf=10,
                              class_weight="balanced",
                              random_state=CONFIG["random_state"]).fit(X, tgt)
    rules = tree_rules(m, list(X.columns))
    covered = sum(r["строк"] for r in rules)
    # веса классов выровнены, поэтому в лист может попасть больше строк,
    # чем сегмент содержит; смотреть на чистоту, а не на охват
    head = "### %s — в сегменте %d строк, в листья правил попало %d\n" % (
        seg, tgt.sum(), covered)
    body = ""
    for i, r in enumerate(rules[:6], 1):
        body += "%d) ЕСЛИ %s\n   ТО %s   (строк %d, чистота %.1f%%)\n" % (
            i, "\n      И ".join(r["условия"]), seg, r["строк"], 100 * r["чистота"])
    rules_report.append(head + (body or "правил не выделено\n"))

print("\n\n".join(rules_report))

# %% [markdown]
# ## 8. Минимальный набор колонок
#
# Жадный отбор: добавляем колонку, дающую наибольший прирост, пока прирост
# заметен. Отвечает на вопрос «какие поля обязательно нужны в отчёте».

# %%
from sklearn.metrics import f1_score

cands = list(importance.index[:20])
n = min(CONFIG["subsample_for_selection"], len(X))
idx = X.sample(n, random_state=CONFIG["random_state"]).index
Xs, ys = X.loc[idx], y.loc[idx]
cols_of = {}
for f in X.columns:
    cols_of.setdefault(FEATURE_META.get(f, (f, None))[0], []).append(f)

chosen, best, history = [], 0.0, []
plateau, cut_at = 0, None
while cands:
    scores = []
    for c in cands:
        feats = sum([cols_of[k] for k in chosen + [c]], [])
        a, b, ya, yb = train_test_split(Xs[feats], ys, test_size=0.3,
                                        random_state=CONFIG["random_state"])
        mm = DecisionTreeClassifier(max_depth=CONFIG["max_depth"],
                                    min_samples_leaf=CONFIG["min_samples_leaf"],
                                    class_weight="balanced",
                                    random_state=CONFIG["random_state"]).fit(a, ya)
        scores.append((f1_score(yb, mm.predict(b), average="macro",
                                zero_division=0), c))
    scores.sort(reverse=True)
    gain, col = scores[0][0] - best, scores[0][1]
    if gain < CONFIG["selection_eps"] and chosen:
        plateau += 1
        if cut_at is None:
            cut_at = len(chosen)          # рекомендуемая отсечка
        if plateau > CONFIG["selection_patience"]:
            break
    else:
        plateau = 0
    best = scores[0][0]
    chosen.append(col)
    cands.remove(col)
    history.append({"шаг": len(chosen), "колонка": col,
                    "macro-F1": round(best, 4), "прирост": round(gain, 4)})

hist = pd.DataFrame(history)
hist["решение"] = ["нужна" if r["шаг"] <= (cut_at or len(hist))
                   else "ниже отсечки" for _, r in hist.iterrows()]
print("Жадный отбор колонок (несколько шагов после плато показаны намеренно):\n")
print(hist.to_string(index=False))

chosen = [h["колонка"] for h in history[:cut_at]] if cut_at else chosen
print("\nМинимальный набор — %d колонок:" % len(chosen))
print(chosen)

# %% [markdown]
# ## 9. Справочник значений — то, что запрашивается у ассистентов

# %%
spravochnik = []
for col in importance.index:
    if col not in feat.columns or col.startswith("eng_"):
        continue
    s = feat[col]
    if s.dtype.kind in "fiu":
        spravochnik.append({
            "колонка": col, "тип": "числовая", "значение": "min..max",
            "строк": int(s.notna().sum()),
            "комментарий": "%.6g .. %.6g" % (s.min(), s.max())})
        continue
    vc = s.value_counts(dropna=False).head(40)
    for val, cnt in vc.items():
        mask = s.isna() if pd.isna(val) else (s == val)
        top = y[mask].value_counts()
        spravochnik.append({
            "колонка": col, "тип": "категориальная",
            "значение": "<пусто>" if pd.isna(val) else str(val),
            "строк": int(cnt),
            "комментарий": "; ".join(
                "%s %.0f%%" % (k, 100 * v / mask.sum())
                for k, v in top.head(3).items())})

sprav = pd.DataFrame(spravochnik)
sprav.to_csv("spravochnik_znacheniy.csv", index=False, sep=";", encoding="utf-8-sig")
print(sprav.head(60).to_string(index=False))
print("\nсохранено: spravochnik_znacheniy.csv")

# %% [markdown]
# ## 10. Сверка с нашей сегментацией
#
# Где мы расходимся с регулятором и на скольких договорах.

# %%
if our is not None:
    cmp = pd.crosstab(our, y, rownames=["наш"], colnames=["регулятор"])
    print("Матрица расхождений:\n")
    print(cmp)
    same = (our.values == y.values).sum()
    print("\nсовпало: %d из %d (%.2f%%)" % (same, len(y), 100 * same / len(y)))

    diff = (pd.DataFrame({"наш": our, "регулятор": y})
            .query("наш != регулятор")
            .groupby(["наш", "регулятор"]).size()
            .sort_values(ascending=False).to_frame("строк"))
    print("\nТоп расхождений:\n")
    print(diff.head(25))
    diff.to_csv("rashozhdeniya.csv", sep=";", encoding="utf-8-sig")
    print("\nсохранено: rashozhdeniya.csv")
else:
    print("наша сегментация не подана — сверка пропущена")

# %% [markdown]
# ## 11. Выгрузка результатов

# %%
with open("pravila_segmentacii.txt", "w", encoding="utf-8") as f:
    f.write("ПРАВИЛА СЕГМЕНТАЦИИ, ВОССТАНОВЛЕННЫЕ ПО РАСПРЕДЕЛЕНИЮ РЕГУЛЯТОРА\n")
    f.write("=" * 70 + "\n\n")
    f.write("Точность модели на контроле: %.5f\n\n" % clf.score(X_te, y_te))
    f.write("ЗНАЧИМЫЕ КОЛОНКИ\n" + importance.to_string() + "\n\n")
    f.write("МИНИМАЛЬНЫЙ НАБОР: " + ", ".join(chosen) + "\n\n")
    f.write("\n\n".join(rules_report))
    f.write("\n\nПОЛНОЕ ДЕРЕВО\n")
    f.write(export_text(clf, feature_names=list(X.columns), max_depth=6))

importance.to_csv("znachimye_kolonki.csv", sep=";", encoding="utf-8-sig")
print("сохранено: pravila_segmentacii.txt, znachimye_kolonki.csv")

try:
    from google.colab import files
    for fn in ["pravila_segmentacii.txt", "znachimye_kolonki.csv",
               "spravochnik_znacheniy.csv"]:
        files.download(fn)
except Exception:
    print("не Colab — файлы лежат рядом со скриптом")
