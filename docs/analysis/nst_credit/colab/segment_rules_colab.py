# -*- coding: utf-8 -*-
"""
Сегментация: восстановление правил эталона и разбор прежних правил банка.

Вход : таблица B1A с двумя колонками сегментации —
       segment_afr  — эталон (сегментация АФР),
       segment_eub  — как банк делил раньше.

Выход: 1) правила эталона по каждому сегменту;
       2) готовый SQL CASE, восстановленный из эталона;
       3) разбор расхождений: где прежние правила ошибались и на каком объёме;
       4) справочник значений ключевых колонок.

Запускается одинаково в Google Colab и локально. Ячейки размечены `# %%`.

ПДн: iin_bin нужен только для агрегата по заёмщику и удаляется сразу после
расчёта вместе с остальными прямыми идентификаторами (ячейка 3).
"""

# %% [markdown]
# ## 1. Конфигурация
#
# Единственная ячейка, которую нужно править.

# %%
CONFIG = {
    # --- файл ---
    "path": "b1a.xlsx",
    "sheet": 0,
    "sep": ";",
    # --- две сегментации ---
    "target": "segment_afr",        # ЭТАЛОН: сегментация АФР
    "legacy": "segment_eub",        # ПРЕЖНЯЯ: как делил банк
    # --- параметры расчёта ---
    "capital": 461_235_157_000,     # собственный капитал на отчётную дату
    "report_date": "2024-12-31",
    "individual_threshold": 0.002,  # 0,2 % капитала
    # --- колонки, которые нельзя подавать в модель ---
    "pii_cols": ["name", "contract_number", "account_no"],
    "id_cols": ["n_o", "id", "loan_id", "loan_id_kr", "credit_line_id",
                "ef_batches_int_id", "ef_contract_id", "creditor_no"],
    "leak_cols": ["stage", "ead_n", "amount"],   # производные того же скрипта
    "borrower_key": "iin_bin",
    # --- модель ---
    "max_depth": 12,
    "min_samples_leaf": 20,
    "test_size": 0.25,
    "random_state": 0,
    "onehot_max_card": 50,
    "onehot_top_n": 30,
    "subsample_for_selection": 150_000,
    "selection_eps": 0.001,
    "selection_patience": 3,
    "rule_depth": 4,                # глубина деревьев «сегмент против всех»
}

STUBS = {"1111111111111", "9999999999999", "1111111111111.0", "9999999999999.0"}
DEBT_BASE_METOD = ["od", "od_del", "interest", "interest_del", "disc_prem"]
DEBT_BASE_SCRIPT = DEBT_BASE_METOD + ["correction", "penalty"]

# колонки, которые перечислены в ветках действующего скрипта сегментации —
# нужны для проверки на тавтологию (см. ячейку 6)
SCRIPT_COLS = {"entity", "lsboo", "f_inv", "debtor_type", "debtor_se", "ent_type",
               "loan_obj", "loan_purp", "ead", "collateral", "portfolio"}

# как инженерные признаки выражаются в SQL (для генерации CASE)
SQL_EXPR = {
    "eng_share_capital":
        "SUM(zadol) OVER (PARTITION BY iin_bin) / @capital",
    "eng_zadol_borrower":
        "SUM(zadol) OVER (PARTITION BY iin_bin)",
    "eng_over_02pct":
        "CASE WHEN SUM(zadol) OVER (PARTITION BY iin_bin) > @capital*0.002 THEN 1 ELSE 0 END",
    "eng_srok_let":
        "DATEDIFF(day, loan_start_date, loan_end_date) / 365.25",
    "eng_srok_ost_let":
        "DATEDIFF(day, @report_date, loan_end_date) / 365.25",
    "eng_srok_ge_5let":
        "CASE WHEN DATEDIFF(day, loan_start_date, loan_end_date) >= 5*365 THEN 1 ELSE 0 END",
    "eng_contracts_of_borrower":
        "COUNT(*) OVER (PARTITION BY iin_bin)",
    "eng_zadol_metod": "zadol_metod",
    "eng_zadol_script": "zadol_script",
}

# индикаторы 0/1: сравнение с 0.5 разворачивается в читаемое условие
BOOL_SQL = {
    "eng_over_02pct": ("SUM(zadol) OVER (PARTITION BY iin_bin) > @capital*0.002",
                       "SUM(zadol) OVER (PARTITION BY iin_bin) <= @capital*0.002"),
    "eng_srok_ge_5let": ("DATEDIFF(day, loan_start_date, loan_end_date) >= 5*365",
                         "DATEDIFF(day, loan_start_date, loan_end_date) < 5*365"),
}

# порядок веток в итоговом CASE. Это НАШЕ решение: Таблица 4 задаёт лишь
# частичный порядок (`GROUND_TRUTH_SEGMENTS.md`, раздел 3), а CASE требует полный.
PRIORITY = ["DISASS", "RELATE", "CORGOV", "CORINV", "Individual loans", "COREST",
            "CORLAR", "CORMED", "RETSML", "RETEST", "RETCAR", "RETCON"]

# %% [markdown]
# ## 2. Загрузка и первый взгляд на две сегментации

# %%
import warnings
import numpy as np
import pandas as pd

warnings.filterwarnings("ignore")
pd.set_option("display.width", 220)
pd.set_option("display.max_columns", 90)


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
df.columns = [str(c).strip().lower() for c in df.columns]
print("загружено:", df.shape[0], "строк,", df.shape[1], "колонок")

TARGET, LEGACY = CONFIG["target"].lower(), CONFIG["legacy"].lower()
assert TARGET in df.columns, "нет колонки эталона '%s'" % TARGET
has_legacy = LEGACY in df.columns
if not has_legacy:
    print("ВНИМАНИЕ: колонки '%s' нет — разбор расхождений пропускается" % LEGACY)

df = df[df[TARGET].notna() & (df[TARGET].astype(str).str.strip() != "")]
y = df[TARGET].astype(str).str.strip()
legacy = df[LEGACY].astype(str).str.strip() if has_legacy else None
print("строк с известным эталоном:", len(df))

if has_legacy:
    cmp_tbl = pd.DataFrame({
        "эталон (АФР)": y.value_counts(),
        "прежняя (ЕАБ)": legacy.value_counts()}).fillna(0).astype(int)
    cmp_tbl["разница"] = cmp_tbl["прежняя (ЕАБ)"] - cmp_tbl["эталон (АФР)"]
    print("\nДва распределения рядом:")
    print(cmp_tbl.sort_values("эталон (АФР)", ascending=False))
    agree = (y.values == legacy.values).sum()
    print("\nсовпало: %d из %d (%.2f%%), расходится %d" %
          (agree, len(y), 100 * agree / len(y), len(y) - agree))
else:
    print(y.value_counts())

# %% [markdown]
# ## 3. Признаки: числа, заглушки, агрегаты по заёмщику
#
# Три вещи дерево не найдёт само: агрегат задолженности по заёмщику,
# долю от капитала и срок займа. Без них `Individual loans` и `CORINV`
# не восстанавливаются в принципе.

# %%
def to_num(s):
    x = s.astype(str).str.strip()
    x = x.where(~x.isin(STUBS))
    x = (x.str.replace(" ", "", regex=False)
          .str.replace(" ", "", regex=False)
          .str.replace(",", ".", regex=False))
    return pd.to_numeric(x, errors="coerce")


def numeric_share(s, n=5000):
    smp = s.dropna().head(n)
    return 0.0 if len(smp) == 0 else to_num(smp).notna().mean()


service = set(CONFIG["pii_cols"] + CONFIG["id_cols"] + CONFIG["leak_cols"] +
              [TARGET, LEGACY, CONFIG["borrower_key"]])

num_cols, cat_cols = [], []
for c in df.columns:
    if c in service:
        continue
    if numeric_share(df[c]) > 0.95 and df[c].nunique(dropna=True) > 10:
        num_cols.append(c)
    else:
        cat_cols.append(c)
print("числовых:", len(num_cols), "| категориальных:", len(cat_cols))

feat = pd.DataFrame(index=df.index)
for c in num_cols:
    feat[c] = to_num(df[c])
for c in cat_cols:
    feat[c] = df[c].astype(str).str.strip().replace(
        {"nan": np.nan, "": np.nan, "None": np.nan})

bk = CONFIG["borrower_key"]


def debt_sum(cols):
    have = [c for c in cols if c in df.columns]
    if not have:
        return None
    return pd.concat([to_num(df[c]).fillna(0) for c in have], axis=1).sum(axis=1)


d_met, d_scr = debt_sum(DEBT_BASE_METOD), debt_sum(DEBT_BASE_SCRIPT)
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

df = df[[c for c in df.columns if c not in set(CONFIG["pii_cols"]) | {bk}]]
print("PII и ключ заёмщика удалены")

# %% [markdown]
# ## 4. Кодирование
#
# Категориальные — в one-hot, чтобы правило читалось как `ent_type == '3'`,
# а не как бессмысленное `ent_type <= 1.5`.

# %%
FEATURE_META = {}
blocks = []
for c in feat.columns:
    s = feat[c]
    if s.dtype.kind in "fiu":
        col = s.astype(float)
        if col.isna().any():
            ind = col.isna().astype(np.int8).rename(c + "__пропуск")
            blocks.append(ind)
            FEATURE_META[ind.name] = (c, "пропуск")
        blocks.append(col.fillna(-9.99e14).rename(c))
        FEATURE_META[c] = (c, None)
    else:
        vc = s.value_counts(dropna=True)
        vals = (list(vc.index[:CONFIG["onehot_top_n"]])
                if len(vc) > CONFIG["onehot_max_card"] else list(vc.index))
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
    print("\nСегменты с малым числом наблюдений — правила по ним ненадёжны:")
    print(rare.to_frame("строк"))

# %% [markdown]
# ## 5. Модель на эталоне

# %%
from sklearn.tree import DecisionTreeClassifier, export_text
from sklearn.model_selection import train_test_split
from sklearn.metrics import classification_report, f1_score

strat = y if y.value_counts().min() >= 2 else None
X_tr, X_te, y_tr, y_te = train_test_split(
    X, y, test_size=CONFIG["test_size"],
    random_state=CONFIG["random_state"], stratify=strat)

clf = DecisionTreeClassifier(
    max_depth=CONFIG["max_depth"], min_samples_leaf=CONFIG["min_samples_leaf"],
    class_weight="balanced", random_state=CONFIG["random_state"]).fit(X_tr, y_tr)

acc = clf.score(X_te, y_te)
print("точность на обучении :", round(clf.score(X_tr, y_tr), 5))
print("точность на контроле :", round(acc, 5))
print("\nПо сегментам (контроль):")
print(classification_report(y_te, clf.predict(X_te), zero_division=0, digits=4))

# %% [markdown]
# ## 6. Значимые колонки и проверка на тавтологию
#
# Если «эталон» на самом деле выход нашего же скрипта, дерево просто выучит
# наш `CASE` и покажет почти идеальное качество на тех же колонках.
# Это не подтверждение правил, а тавтология — проверяем явно.

# %%
imp = pd.Series(clf.feature_importances_, index=X.columns)
by_col = {}
for f, v in imp.items():
    by_col[FEATURE_META.get(f, (f, None))[0]] = \
        by_col.get(FEATURE_META.get(f, (f, None))[0], 0.0) + v
importance = pd.Series(by_col).sort_values(ascending=False).to_frame("важность")
importance["важность"] = (100 * importance["важность"]).round(3)
importance = importance[importance["важность"] > 0]
print("Колонки, определяющие эталон:\n")
print(importance)

used = set(importance.index)
outside = {c for c in used if not c.startswith("eng_")} - SCRIPT_COLS
print("\n--- проверка на тавтологию ---")
print("точность                       : %.5f" % acc)
print("колонок вне веток скрипта      : %d %s" % (len(outside), sorted(outside)))
if acc > 0.999 and not outside:
    print("ВЫВОД: эталон воспроизводится нашими же колонками почти идеально.")
    print("       Вероятно, это выход нашего скрипта, а не независимый ответ АФР.")
    print("       Правила ниже подтверждают код, но не методику. Уточнить источник.")
else:
    print("ВЫВОД: эталон отличается от простого пересказа нашего CASE —")
    print("       есть колонки/пороги вне текущих веток. Разбор осмыслен.")

# %% [markdown]
# ## 7. Правила эталона по каждому сегменту

# %%
def decode(fname, threshold, go_left):
    col, val = FEATURE_META.get(fname, (fname, None))
    if val is None:
        return ("num", col, "<=" if go_left else ">", threshold)
    if val == "пропуск":
        return ("isna", col, "заполнено" if go_left else "НЕ заполнено", None)
    return ("cat", col, "!=" if go_left else "==", val)


def human(cond):
    kind, col, op, val = cond
    if kind == "num":
        return "%s %s %.6g" % (col, op, val)
    if kind == "isna":
        return "%s %s" % (col, op)
    return "%s %s '%s'" % (col, op, val)


def tree_rules(model, feature_names, min_samples=1):
    t, out = model.tree_, []

    def walk(node, conds):
        if t.feature[node] != -2:
            f, thr = feature_names[t.feature[node]], t.threshold[node]
            walk(t.children_left[node], conds + [decode(f, thr, True)])
            walk(t.children_right[node], conds + [decode(f, thr, False)])
            return
        counts = t.value[node][0]
        n, pred = int(t.n_node_samples[node]), int(np.argmax(counts))
        purity = counts[pred] / counts.sum() if counts.sum() else 0.0
        if pred == 1 and n >= min_samples:
            out.append({"conds": conds, "строк": n, "чистота": round(purity, 4)})

    walk(0, [])
    return sorted(out, key=lambda r: (-r["чистота"], -r["строк"]))


rules_by_seg, report = {}, []
for seg in y.value_counts().index:
    tgt = (y == seg).astype(int)
    if tgt.sum() < 30:
        report.append("### %s — %d строк, для правила мало\n" % (seg, tgt.sum()))
        continue
    m = DecisionTreeClassifier(max_depth=CONFIG["rule_depth"], min_samples_leaf=10,
                               class_weight="balanced",
                               random_state=CONFIG["random_state"]).fit(X, tgt)
    rules = tree_rules(m, list(X.columns))
    rules_by_seg[seg] = rules
    head = "### %s — в сегменте %d строк\n" % (seg, tgt.sum())
    body = ""
    for i, r in enumerate(rules[:6], 1):
        body += "%d) ЕСЛИ %s\n   ТО %s   (строк %d, чистота %.1f%%)\n" % (
            i, "\n      И ".join(human(c) for c in r["conds"]),
            seg, r["строк"], 100 * r["чистота"])
    report.append(head + (body or "правил не выделено\n"))

print("\n\n".join(report))

# %% [markdown]
# ## 8. Генерация SQL CASE из эталона
#
# Ветки упорядочены по чистоте и охвату. **Порядок и сами условия обязательно
# сверяются с `GROUND_TRUTH_SEGMENTS.md`** — дерево находит корреляцию,
# а не норму.

# %%
def to_sql(cond):
    kind, col, op, val = cond
    if kind == "num":
        if col in BOOL_SQL and abs(val - 0.5) < 1e-9:
            pos, neg = BOOL_SQL[col]
            return neg if op == "<=" else pos
        if col in SQL_EXPR:
            return "%s %s %.6g" % (SQL_EXPR[col], op, val)
        return "TRY_CAST(%s AS float) %s %.6g" % (col, op, val)
    if kind == "isna":
        return "%s IS %sNULL" % (col, "NOT " if op == "заполнено" else "")
    return "%s %s '%s'" % (col, "<>" if op == "!=" else "=", val)


MIN_PURITY, MIN_ROWS = 0.90, 30
branches = []
for seg, rules in rules_by_seg.items():
    for r in rules:
        if r["чистота"] >= MIN_PURITY and r["строк"] >= MIN_ROWS:
            branches.append((r["чистота"], r["строк"], seg, r["conds"]))
# сначала по смысловому приоритету сегмента, внутри сегмента — по чистоте
branches.sort(key=lambda b: (PRIORITY.index(b[2]) if b[2] in PRIORITY else 99,
                             -b[0], -b[1]))

sql = [
    "-- Сегментация, восстановленная из эталона АФР деревом решений.",
    "-- ТРЕБУЕТ СВЕРКИ с Таблицей 4 Методруководства (GROUND_TRUTH_SEGMENTS.md)",
    "-- перед применением: дерево находит корреляцию, а не норму.",
    "--",
    "-- Порядок веток задан списком PRIORITY, а не данными: Таблица 4 определяет",
    "-- лишь частичный порядок, а CASE требует полного. Порядок — наше решение.",
    "--",
    "-- Требуется предварительный расчёт (пример):",
    "--   zadol = od + od_del + interest + interest_del + disc_prem   (без пеней,",
    "--           база по п. 44 Методруководства)",
    "--   @capital     — собственный капитал на отчётную дату",
    "--   @report_date — отчётная дата",
    "-- Оконные функции удобнее вынести в CTE, а не считать в самом CASE.",
    "CASE"]
for purity, n, seg, conds in branches:
    sql.append("  WHEN %s" % ("\n       AND ".join(to_sql(c) for c in conds)))
    sql.append("       THEN '%s'   -- строк %d, чистота %.1f%%" %
               (seg, n, 100 * purity))
sql += ["  ELSE 'X'   -- доля X обязана предъявляться явно, а не молчать",
        "END AS segment_new"]
sql_text = "\n".join(sql)
print(sql_text[:4000])
open("segmentation_case.sql", "w", encoding="utf-8").write(sql_text)
print("\n... сохранено полностью: segmentation_case.sql (веток %d)" % len(branches))

# %% [markdown]
# ## 9. Где прежние правила банка расходятся с эталоном
#
# Три среза: объём расхождений, что их характеризует, и разбор
# каждого крупного перехода «было → стало».

# %%
if has_legacy:
    pair = pd.DataFrame({"было (ЕАБ)": legacy, "стало (АФР)": y})
    print("Матрица переходов:\n")
    print(pd.crosstab(pair["было (ЕАБ)"], pair["стало (АФР)"]))

    moves = (pair[pair["было (ЕАБ)"] != pair["стало (АФР)"]]
             .groupby(["было (ЕАБ)", "стало (АФР)"]).size()
             .sort_values(ascending=False).to_frame("строк"))
    moves["доля расхождений, %"] = (
        100 * moves["строк"] / moves["строк"].sum()).round(2)
    print("\nПереходы, отсортированные по объёму:\n")
    print(moves.head(25))
    moves.to_csv("perehody.csv", sep=";", encoding="utf-8-sig")

    # что характеризует расхождение в целом
    mism = (legacy.values != y.values).astype(int)
    print("\n--- Что отличает строки, где прежние правила ошиблись ---\n")
    mm = DecisionTreeClassifier(max_depth=CONFIG["rule_depth"], min_samples_leaf=20,
                                class_weight="balanced",
                                random_state=CONFIG["random_state"]).fit(X, mism)
    for i, r in enumerate(tree_rules(mm, list(X.columns))[:8], 1):
        print("%d) ЕСЛИ %s\n   -> прежние правила расходятся с эталоном"
              "   (строк %d, доля ошибок %.1f%%)\n" %
              (i, "\n      И ".join(human(c) for c in r["conds"]),
               r["строк"], 100 * r["чистота"]))
else:
    print("прежняя сегментация не подана")

# %% [markdown]
# ## 10. Разбор каждого крупного перехода
#
# Для перехода «было A → стало B»: внутри строк, которым банк присвоил A,
# ищем, что отличает те, которые эталон относит к B.

# %%
if has_legacy:
    top_moves = moves.head(8).index.tolist()
    for was, became in top_moves:
        sub = legacy.values == was
        if sub.sum() < 50:
            continue
        tgt = ((y.values == became) & sub).astype(int)[sub]
        if tgt.sum() < 20 or tgt.sum() == sub.sum():
            continue
        mt = DecisionTreeClassifier(max_depth=3, min_samples_leaf=10,
                                    class_weight="balanced",
                                    random_state=CONFIG["random_state"]).fit(
            X[sub], tgt)
        rr = tree_rules(mt, list(X.columns))
        print("=== было '%s' -> эталон '%s'  (%d строк) ===" %
              (was, became, int(moves.loc[(was, became), "строк"])))
        for r in rr[:3]:
            print("   ЕСЛИ %s   (строк %d, чистота %.1f%%)" %
                  ("\n        И ".join(human(c) for c in r["conds"]),
                   r["строк"], 100 * r["чистота"]))
        print()

# %% [markdown]
# ## 11. Минимальный набор колонок

# %%
cands = list(importance.index[:20])
n = min(CONFIG["subsample_for_selection"], len(X))
idx = X.sample(n, random_state=CONFIG["random_state"]).index
Xs, ys = X.loc[idx], y.loc[idx]
cols_of = {}
for f in X.columns:
    cols_of.setdefault(FEATURE_META.get(f, (f, None))[0], []).append(f)

chosen, best, history, plateau, cut_at = [], 0.0, [], 0, None
while cands:
    scores = []
    for c in cands:
        feats = sum([cols_of[k] for k in chosen + [c]], [])
        a, b, ya, yb = train_test_split(Xs[feats], ys, test_size=0.3,
                                        random_state=CONFIG["random_state"])
        mm2 = DecisionTreeClassifier(
            max_depth=CONFIG["max_depth"],
            min_samples_leaf=CONFIG["min_samples_leaf"],
            class_weight="balanced",
            random_state=CONFIG["random_state"]).fit(a, ya)
        scores.append((f1_score(yb, mm2.predict(b), average="macro",
                                zero_division=0), c))
    scores.sort(reverse=True)
    gain, col = scores[0][0] - best, scores[0][1]
    if gain < CONFIG["selection_eps"] and chosen:
        plateau += 1
        if cut_at is None:
            cut_at = len(chosen)
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
hist["решение"] = ["нужна" if s <= (cut_at or len(hist)) else "ниже отсечки"
                   for s in hist["шаг"]]
print("Жадный отбор (шаги после плато показаны намеренно):\n")
print(hist.to_string(index=False))
chosen = [h["колонка"] for h in history[:cut_at]] if cut_at else chosen
print("\nМинимальный набор — %d колонок:\n%s" % (len(chosen), chosen))

# %% [markdown]
# ## 12. Справочник значений ключевых колонок

# %%
rows = []
for col in importance.index:
    if col not in feat.columns or col.startswith("eng_"):
        continue
    s = feat[col]
    if s.dtype.kind in "fiu":
        rows.append({"колонка": col, "тип": "числовая", "значение": "min..max",
                     "строк": int(s.notna().sum()),
                     "куда ведёт": "%.6g .. %.6g" % (s.min(), s.max())})
        continue
    for val, cnt in s.value_counts(dropna=False).head(40).items():
        mask = s.isna() if pd.isna(val) else (s == val)
        top = y[mask].value_counts()
        rows.append({"колонка": col, "тип": "категориальная",
                     "значение": "<пусто>" if pd.isna(val) else str(val),
                     "строк": int(cnt),
                     "куда ведёт": "; ".join("%s %.0f%%" % (k, 100 * v / mask.sum())
                                             for k, v in top.head(3).items())})
sprav = pd.DataFrame(rows)
sprav.to_csv("spravochnik_znacheniy.csv", index=False, sep=";",
             encoding="utf-8-sig")
print(sprav.head(50).to_string(index=False))
print("\nсохранено: spravochnik_znacheniy.csv")

# %% [markdown]
# ## 13. Выгрузка

# %%
with open("pravila_segmentacii.txt", "w", encoding="utf-8") as f:
    f.write("ПРАВИЛА СЕГМЕНТАЦИИ, ВОССТАНОВЛЕННЫЕ ПО ЭТАЛОНУ АФР\n")
    f.write("=" * 70 + "\n\n")
    f.write("Точность на контроле: %.5f\n" % acc)
    f.write("Колонок вне веток действующего скрипта: %d %s\n\n"
            % (len(outside), sorted(outside)))
    f.write("ЗНАЧИМЫЕ КОЛОНКИ\n" + importance.to_string() + "\n\n")
    f.write("МИНИМАЛЬНЫЙ НАБОР: " + ", ".join(chosen) + "\n\n")
    f.write("\n\n".join(report))
    f.write("\n\nПОЛНОЕ ДЕРЕВО\n")
    f.write(export_text(clf, feature_names=list(X.columns), max_depth=6))
importance.to_csv("znachimye_kolonki.csv", sep=";", encoding="utf-8-sig")
print("сохранено: pravila_segmentacii.txt, znachimye_kolonki.csv, "
      "segmentation_case.sql")

try:
    from google.colab import files
    for fn in ["pravila_segmentacii.txt", "segmentation_case.sql",
               "znachimye_kolonki.csv", "spravochnik_znacheniy.csv",
               "perehody.csv"]:
        try:
            files.download(fn)
        except Exception:
            pass
except Exception:
    print("не Colab — файлы лежат рядом со скриптом")
