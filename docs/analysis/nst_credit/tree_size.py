"""
Дерево решений: размер предпринимательства по эталону АФР.

Вход  : size_for_tree.csv (выгрузка Т1 из NST_CREDIT.md), 4 130 строк
Цель  : SEGMENT АФР — CORLAR / CORMED / RETSML / COREST
Задача: найти, чем заёмщики CORMED отличаются от RETSML там,
        где ent_type ошибается (1 227 договоров, 221 млрд EAD)

Дисциплина, из-за отсутствия которой прошлый прогон дал ложный результат:
  1. class_weight НЕ используется. В прошлый раз balanced дал вес 12 000 : 1
     и чистота 0,7 % печаталась как 98,8 %.
  2. Чистота считается по фактическим строкам листа, а не по tree_.value.
  3. Оценка только на отложенной выборке, сплит по ЗАЁМЩИКУ, не по договору:
     иначе займы одного заёмщика попадут и в train, и в test.
  4. Базовая линия печатается первой. Правило, не бьющее ent_type,
     не является находкой.
"""

import sys
import numpy as np
import pandas as pd
from sklearn.tree import DecisionTreeClassifier, export_text
from sklearn.model_selection import GroupShuffleSplit
from sklearn.metrics import classification_report, confusion_matrix

CSV = sys.argv[1] if len(sys.argv) > 1 else "size_for_tree.csv"
SEED = 42
MIN_LEAF = 25          # на 4 130 строках меньше — это подгонка
MAX_DEPTH = 5
MIN_PURITY = 0.80

# Утечка: метрики, калиброванные по сегменту, и прежние сегментации
LEAK = {"segment_afr", "segment_eub", "lgd", "prov_rate", "provisions",
        "rwa_total", "ccf", "target", "loan_id_kr", "borrower_id"}

df = pd.read_csv(CSV, sep=";", encoding="utf-8", low_memory=False)
print(f"строк {len(df)}, заёмщиков {df.borrower_id.nunique()}")
print("\nраспределение цели:")
print(df.target.value_counts().to_string())

# ---- базовая линия: что даёт ent_type сам по себе -----------------------
ENT_MAP = {1: "CORLAR", 2: "CORMED", 3: "RETSML"}
base = df.ent_type_n.map(ENT_MAP).fillna("X")
base_acc = (base == df.target).mean()
print(f"\nБАЗОВАЯ ЛИНИЯ ent_type: {base_acc:.4f}")
print("Дерево обязано её побить, иначе находки нет.\n")

# ---- признаки ------------------------------------------------------------
feat = [c for c in df.columns if c not in LEAK]
X = df[feat].copy()
for c in X.columns:
    if X[c].dtype == object:
        X[c] = X[c].astype("category").cat.codes      # -1 для NaN
X = X.fillna(-1)
y = df.target

# отсев признаков с заполненностью ниже 2 % — в прошлый раз ОКЭД дал шум
filled = (X != -1).mean()
dropped = filled[filled < 0.02].index.tolist()
if dropped:
    print(f"отброшены по заполненности <2 %: {dropped}")
    X = X.drop(columns=dropped)

# ---- сплит ПО ЗАЁМЩИКУ ---------------------------------------------------
gss = GroupShuffleSplit(n_splits=1, test_size=0.3, random_state=SEED)
tr, te = next(gss.split(X, y, groups=df.borrower_id))
print(f"train {len(tr)}, test {len(te)}, "
      f"заёмщики не пересекаются: "
      f"{set(df.borrower_id.iloc[tr]).isdisjoint(set(df.borrower_id.iloc[te]))}")

clf = DecisionTreeClassifier(
    max_depth=MAX_DEPTH, min_samples_leaf=MIN_LEAF,
    random_state=SEED)                                 # class_weight НЕ задан
clf.fit(X.iloc[tr], y.iloc[tr])

pred = clf.predict(X.iloc[te])
tree_acc = (pred == y.iloc[te]).mean()
base_te = (base.iloc[te] == y.iloc[te]).mean()

print(f"\n=== ОТЛОЖЕННАЯ ВЫБОРКА ===")
print(f"ent_type : {base_te:.4f}")
print(f"дерево   : {tree_acc:.4f}")
print(f"прирост  : {tree_acc - base_te:+.4f}")
print("\n" + classification_report(y.iloc[te], pred, zero_division=0))
print("матрица ошибок (строки — эталон, столбцы — предсказание):")
print(pd.DataFrame(confusion_matrix(y.iloc[te], pred,
                                    labels=sorted(y.unique())),
                   index=sorted(y.unique()), columns=sorted(y.unique())).to_string())

# ---- information gain ----------------------------------------------------
imp = pd.Series(clf.feature_importances_, index=X.columns)
imp = imp[imp > 0].sort_values(ascending=False)
print("\n=== ВКЛАД ПРИЗНАКОВ ===")
print(imp.to_string() if len(imp) else "ни один признак не использован")

# ---- правила с ФАКТИЧЕСКОЙ чистотой на отложенной выборке ----------------
print(f"\n=== ПРАВИЛА, чистота на test >= {MIN_PURITY:.0%}, лист >= {MIN_LEAF} ===")
leaf_te = clf.apply(X.iloc[te])
y_te = y.iloc[te].values
found = False
for lf in np.unique(leaf_te):
    m = leaf_te == lf
    n = int(m.sum())
    if n < MIN_LEAF:
        continue
    vals, cnts = np.unique(y_te[m], return_counts=True)
    top, cnt = vals[cnts.argmax()], cnts.max()
    purity = cnt / n
    if purity >= MIN_PURITY:
        found = True
        print(f"  лист {lf}: {top}  — строк {n}, из них сегмент {cnt} "
              f"({purity:.1%})")
if not found:
    print("  правил не выделено — сигнала в признаках нет")

print("\n=== ДЕРЕВО ===")
print(export_text(clf, feature_names=list(X.columns), max_depth=MAX_DEPTH))

# ---- отдельно: проверка на утечку ---------------------------------------
print("\n=== ПРОВЕРКА НА УТЕЧКУ ===")
print("Если признак в верхушке дерева — производная сегмента, точность")
print("будет высокой, а правило непереносимым. Проверить смысл каждого")
print("признака из верхних трёх строк вклада, прежде чем вносить в скрипт.")
