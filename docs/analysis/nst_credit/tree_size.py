"""
Поиск договоров, где ent_type расходится с эталоном АФР.

Вход  : size_for_tree.csv (выгрузка Т1 из NST_CREDIT.md), ~4 150 строк
Задача: НЕ «предскажи сегмент», а «найди, где ent_type врёт» —
        1 227 договоров, 221 млрд EAD, 12,9 % портфеля.

Три подзадачи по нашему сегменту. Классы в них балансируются сами,
искусственная балансировка ЗАПРЕЩЕНА: правило пойдёт в производственный
скрипт, и цена ложного срабатывания — перенос ВЕРНОГО договора в неверный
сегмент. Балансировка задирает полноту за счёт точности, а нужна точность.

Дисциплина (каждый пункт — против конкретной ошибки прошлых прогонов):
  1. class_weight не задан: balanced давал вес 12 000 : 1 и чистоту 0,7 %
     печатал как 98,8 %
  2. чистота листа считается по фактическим строкам через apply()
  3. сплит по ЗАЁМЩИКУ: размер бизнеса — свойство заёмщика
  4. базовая линия печатается первой
  5. метрики считаются и в договорах, и в EAD: 26 договоров стоят 0,03 млрд,
     а 111 договоров — 52 млрд
"""

import sys
import numpy as np
import pandas as pd
from sklearn.tree import DecisionTreeClassifier, export_text
from sklearn.model_selection import GroupShuffleSplit
from sklearn.metrics import precision_recall_fscore_support

CSV       = sys.argv[1] if len(sys.argv) > 1 else "size_for_tree.csv"
SEED      = 42
MAX_DEPTH = 4
MIN_LEAF  = 20
MIN_PREC  = 0.85          # ниже — правило вносит регресс, а не чинит

LEAK = {"segment_afr", "segment_eub", "lgd", "prov_rate", "provisions",
        "rwa_total", "ccf", "target", "loan_id_kr", "borrower_id",
        "our_seg", "is_wrong", "afr_dir"}

df = pd.read_csv(CSV, sep=";", encoding="utf-8", low_memory=False)

# наш сегмент по действующему правилу
df["our_seg"] = df.ent_type_n.map({1: "CORLAR", 2: "CORMED", 3: "RETSML"})
df = df[df.our_seg.notna()].copy()
df["is_wrong"] = (df.our_seg != df.target).astype(int)

print(f"строк {len(df)}, заёмщиков {df.borrower_id.nunique()}")
print(f"ошибок ent_type: {df.is_wrong.sum()} "
      f"({df.is_wrong.mean():.1%}), EAD {df.loc[df.is_wrong==1,'ead_n'].sum()/1e9:.1f} млрд\n")


def prep(sub):
    feat = [c for c in sub.columns if c not in LEAK]
    X = sub[feat].copy()
    for c in X.columns:
        if X[c].dtype == object:
            X[c] = X[c].astype("category").cat.codes
    X = X.fillna(-1)
    filled = (X != -1).mean()
    X = X.drop(columns=filled[filled < 0.02].index.tolist())
    return X


def run(name, sub):
    print("=" * 68)
    print(f"ПОДЗАДАЧА: {name}")
    print(f"  строк {len(sub)}, заёмщиков {sub.borrower_id.nunique()}, "
          f"ошибок {sub.is_wrong.sum()} ({sub.is_wrong.mean():.1%})")
    print(f"  EAD ошибок {sub.loc[sub.is_wrong==1,'ead_n'].sum()/1e9:.2f} млрд "
          f"из {sub.ead_n.sum()/1e9:.2f}")
    print(f"  куда правит АФР: "
          f"{sub.loc[sub.is_wrong==1,'target'].value_counts().to_dict()}")

    if sub.is_wrong.sum() < 40 or sub.borrower_id.nunique() < 40:
        print("  --> слишком мало для обучения, пропуск\n")
        return None

    X, y = prep(sub), sub.is_wrong
    gss = GroupShuffleSplit(n_splits=1, test_size=0.3, random_state=SEED)
    tr, te = next(gss.split(X, y, groups=sub.borrower_id))

    clf = DecisionTreeClassifier(max_depth=MAX_DEPTH, min_samples_leaf=MIN_LEAF,
                                 random_state=SEED)      # class_weight НЕ задан
    clf.fit(X.iloc[tr], y.iloc[tr])
    pred  = clf.predict(X.iloc[te])
    yte   = y.iloc[te].values
    eadte = sub.ead_n.iloc[te].values

    print(f"\n  БАЗОВАЯ ЛИНИЯ (ничего не править): "
          f"точность {1 - yte.mean():.4f}, ошибок пропущено {yte.sum()}")

    p, r, f, _ = precision_recall_fscore_support(yte, pred, average="binary",
                                                 zero_division=0)
    caught = ((pred == 1) & (yte == 1))
    ead_rec = eadte[caught].sum() / max(eadte[yte == 1].sum(), 1)
    print(f"  ДЕРЕВО: точность {p:.3f}, полнота {r:.3f}, F1 {f:.3f}")
    print(f"          полнота по EAD {ead_rec:.3f} "
          f"({eadte[caught].sum()/1e9:.2f} из "
          f"{eadte[yte==1].sum()/1e9:.2f} млрд)")
    print(f"          ложных срабатываний {int(((pred==1)&(yte==0)).sum())} "
          f"— это регресс, если внести правило")

    if p < MIN_PREC:
        print(f"  --> точность ниже {MIN_PREC:.0%}: правило внесёт больше "
              f"ошибок, чем починит\n")
    else:
        print(f"  --> точность годная, правило можно рассматривать\n")

    imp = pd.Series(clf.feature_importances_, index=X.columns)
    imp = imp[imp > 0].sort_values(ascending=False).head(10)
    print("  ВКЛАД ПРИЗНАКОВ:")
    print("    " + (imp.to_string().replace("\n", "\n    ")
                    if len(imp) else "ни один не использован"))

    print(f"\n  ЛИСТЬЯ с фактической чистотой на test >= {MIN_PREC:.0%}:")
    leaf = clf.apply(X.iloc[te])
    found = False
    for lf in np.unique(leaf):
        m = leaf == lf
        if m.sum() < MIN_LEAF:
            continue
        share = yte[m].mean()
        if share >= MIN_PREC:
            found = True
            print(f"    лист {lf}: ОШИБКА — строк {int(m.sum())}, "
                  f"из них ошибочных {int(yte[m].sum())} ({share:.1%}), "
                  f"EAD {eadte[m].sum()/1e9:.2f} млрд")
        elif (1 - share) >= MIN_PREC and m.sum() >= MIN_LEAF:
            print(f"    лист {lf}: верно — строк {int(m.sum())}, "
                  f"чистота {1-share:.1%}")
    if not found:
        print("    --> ни одного чистого листа с ошибками: сигнала нет")

    print(f"\n  ДЕРЕВО:\n{export_text(clf, feature_names=list(X.columns))}")
    return clf


for seg in ["RETSML", "CORLAR", "CORMED"]:
    run(f"наш {seg} — где АФР правит", df[df.our_seg == seg].copy())

print("=" * 68)
print("ИТОГ")
print("Правило вносить только если точность >= 85 % И оно объяснимо.")
print("Необъяснимое правило на неинтерпретированном коде — это loan_obj = 11,")
print("две строки разреза и регресс на 1 051 договоре.")
