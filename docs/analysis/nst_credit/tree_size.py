"""
Поиск ЗАЁМЩИКОВ, у которых ent_type расходится с эталоном АФР.

Вход  : выгрузка Т1 из NST_CREDIT.md (4 070 строк x 48 колонок).
Задача: НЕ «предскажи сегмент», а «найди, где ent_type врёт».

Единица наблюдения — ЗАЁМЩИК, не договор. Основание — контрольный запрос Т1:
внутри четырёх корпоративных сегментов АФР ровно 1 заёмщик из 1 216 имеет
договоры в разных сегментах. Сегмент АФР здесь — свойство заёмщика, и
1 291 ошибочный договор сводится к 156 ошибочным заёмщикам. Считать в
договорах — значит дать заёмщику со 145 договорами вес 145 голосов;
на этом мерился 32,1 % ошибок вместо фактических 12,8 %.

Дисциплина (каждый пункт — против конкретной ошибки прошлых прогонов):
  1. class_weight не задан: balanced давал вес 12 000 : 1 и чистоту 0,7 %
     печатал как 98,8 %
  2. чистота листа считается по фактическим строкам через apply()
  3. единица — заёмщик; договорный прогон остаётся только как диагностика
  4. базовая линия печатается первой
  5. метрики считаются и в заёмщиках, и в EAD: 26 договоров стоят 0,03 млрд,
     а 111 договоров — 52 млрд
  6. сентинел 1111111111111 вычищается ДО обучения: 457 ставок и 847 LTV
     заполнены им, первый сплит уходил бы на него
"""

import sys
import numpy as np
import pandas as pd
from sklearn.tree import DecisionTreeClassifier, export_text
from sklearn.model_selection import train_test_split
from sklearn.metrics import precision_recall_fscore_support

CSV       = sys.argv[1] if len(sys.argv) > 1 else "size_for_tree.tsv"
SEED      = 42
MAX_DEPTH = 4
MIN_LEAF  = 15
MIN_PREC  = 0.85          # ниже — правило вносит регресс, а не чинит

CORP  = ["CORLAR", "CORMED", "RETSML", "COREST"]
LEAK  = {"segment_afr", "segment_eub", "lgd", "prov_rate", "provisions",
         "rwa_total", "ccf", "target", "loan_id_kr", "borrower_id",
         "our_seg", "is_wrong", "seg", "our", "wrong"}

# природные границы: ставка в процентах, LTV в процентах.
# всё, что выше, — не значение, а заглушка источника
BOUND = {"nom_rate_n": 200, "ltv_n": 1000,
         "b_avg_rate": 200, "b_min_rate": 200, "kdn_n": 1000}


def load(path):
    sep = "\t" if "\t" in open(path, encoding="utf-8").readline() else ";"
    df = pd.read_csv(path, sep=sep, na_values=["NULL", "N/", "NA", ""],
                     low_memory=False)
    scrub = 0
    for c, hi in BOUND.items():
        if c in df.columns:
            bad = df[c].abs() > hi
            scrub += int(bad.sum())
            df.loc[bad, c] = np.nan
    print(f"вычищено заглушек (значение вне природных границ): {scrub}")
    return df


def seg_c1(r):
    """Тот же каскад, что в С1 (раздел 10 NST_CREDIT.md), строка в строку.

    Базовая линия — ДЕЙСТВУЮЩИЙ скрипт, а не ent_type сам по себе.
    Наивная карта {1:CORLAR,2:CORMED,3:RETSML} обходит ветку COREST,
    которая стоит первой, и записывает в ошибки 21 заёмщика, отнесённого
    производственным правилом ВЕРНО."""
    dt = 0 if pd.isna(r.debtor_type_n) else r.debtor_type_n
    ds = 0 if pd.isna(r.debtor_se_n) else r.debtor_se_n
    et, lo, lp = r.ent_type_n, r.loan_obj_n, r.loan_purp_n
    if ((dt == 1 or (dt == 0 and ds == 1)) and et in (1, 2, 3)
            and lo in (1, 2, 3) and lp in (1, 2, 3, 4, 5, 8)):
        return "COREST"
    if et == 1:
        return "CORLAR"
    if et == 2:
        return "CORMED"
    if et == 3:
        return "RETSML"
    if dt == 0 and ds == 0 and (0 if pd.isna(r.ead_n) else r.ead_n) <= 200_000_000:
        if lo == 1:
            return "RETEST"
        return "RETCAR" if r.collateral_n == 1 else "RETCON"
    return "X"


def to_borrower(c):
    """Договоры -> заёмщики. Постоянные внутри заёмщика поля берутся как есть,
    переменные сворачиваются явно: что именно свернули — видно в имени."""
    g = c.groupby("borrower_id")
    const = [col for col in c.columns
             if col not in ("borrower_id", "loan_id_kr")
             and (g[col].nunique(dropna=False) > 1).sum() == 0]
    b = g[const].first()
    for col in ("target", "our_seg"):   # смешанные заёмщики — по большинству
        if col not in b.columns:
            b[col] = g[col].apply(lambda s: s.mode().iat[0])
    b["n_contracts"] = g.size()
    b["ead_sum"]     = g.ead_n.sum()
    b["ead_max"]     = g.ead_n.max()
    b["loan_max"]    = g.loan_amount_n.max()
    b["loan_sum"]    = g.loan_amount_n.sum()
    b["offbal_sum"]  = g.offbal_n.sum()
    b["rate_min"]    = g.nom_rate_n.min()
    b["rate_max"]    = g.nom_rate_n.max()
    b["ltv_mean"]    = g.ltv_n.mean()
    b["srok_max"]    = g.srok_let.max()
    b["vozrast_max"] = g.vozrast_let.max()
    b["dpd_max"]     = g.dpd_n.max()
    b["n_obj"]       = g.loan_obj_n.nunique()
    b["n_purp"]      = g.loan_purp_n.nunique()
    b["n_katvz"]     = g.kateg_vzveshivania.nunique()
    b["n_orgform"]   = g.org_form.nunique()
    b["has_coll"]    = g.collateral_n.max()
    b["all_coll"]    = g.collateral_n.min()
    b["name_len_max"] = g.name_len.max()
    for col, vals in (("org_form", ["AO", "TOO", "IP", "PK_KH", "FILIAL"]),
                      ("source_system", ["RS", "CL", "W", "EBCL"]),
                      ("loan_obj_n", [1, 5, 6, 8, 11]),
                      ("loan_purp_n", [1, 2, 3, 4, 5, 8, 11])):
        for v in vals:
            b[f"any_{col}_{v}"] = g[col].apply(lambda s, v=v: int((s == v).any()))
    b["katvz_mode"] = g.kateg_vzveshivania.apply(
        lambda s: s.mode().iat[0] if len(s.mode()) else np.nan)
    return b.reset_index()


def prep(sub):
    feat = [c for c in sub.columns if c not in LEAK]
    X = sub[feat].copy()
    for c in X.columns:
        if X[c].dtype == object or str(X[c].dtype) == "str":
            X[c] = X[c].astype("category").cat.codes
    X = X.fillna(-1)
    keep = [c for c in X.columns if X[c].nunique() > 1]
    return X[keep]


def report(name, X, y, ead, note=""):
    print("=" * 72)
    print(f"ПОДЗАДАЧА: {name}")
    print(f"  наблюдений {len(y)}, ошибок {int(y.sum())} ({y.mean():.1%}), "
          f"EAD ошибок {ead[y == 1].sum()/1e9:.1f} из {ead.sum()/1e9:.1f} млрд")
    if note:
        print(f"  {note}")
    if y.sum() < 30 or len(y) < 60:
        print("  --> слишком мало наблюдений для обучения, пропуск\n")
        return None

    Xtr, Xte, ytr, yte, _, eadte = train_test_split(
        X, y, ead, test_size=0.3, random_state=SEED, stratify=y)
    clf = DecisionTreeClassifier(max_depth=MAX_DEPTH, min_samples_leaf=MIN_LEAF,
                                 random_state=SEED)      # class_weight НЕ задан
    clf.fit(Xtr, ytr)
    pred = clf.predict(Xte)
    yte, eadte = np.asarray(yte), np.asarray(eadte)

    print(f"\n  БАЗОВАЯ ЛИНИЯ (ничего не править): точность "
          f"{1 - yte.mean():.4f}, ошибок пропущено {int(yte.sum())}")
    p, r, f, _ = precision_recall_fscore_support(yte, pred, average="binary",
                                                 zero_division=0)
    caught = (pred == 1) & (yte == 1)
    ead_rec = eadte[caught].sum() / max(eadte[yte == 1].sum(), 1)
    print(f"  ДЕРЕВО: точность {p:.3f}, полнота {r:.3f}, F1 {f:.3f}")
    print(f"          полнота по EAD {ead_rec:.3f} "
          f"({eadte[caught].sum()/1e9:.2f} из {eadte[yte == 1].sum()/1e9:.2f} млрд)")
    print(f"          ложных срабатываний {int(((pred == 1) & (yte == 0)).sum())}"
          f" — это регресс, если внести правило")
    print(f"  --> {'точность годная, правило можно рассматривать' if p >= MIN_PREC else f'точность ниже {MIN_PREC:.0%}: правило внесёт больше ошибок, чем починит'}")

    imp = pd.Series(clf.feature_importances_, index=X.columns)
    imp = imp[imp > 0].sort_values(ascending=False).head(8)
    print("\n  ВКЛАД ПРИЗНАКОВ:")
    print("    " + (imp.to_string().replace("\n", "\n    ")
                    if len(imp) else "ни один не использован"))

    print(f"\n  ЛИСТЬЯ с фактической чистотой на test >= {MIN_PREC:.0%}:")
    leaf, found = clf.apply(Xte), False
    for lf in np.unique(leaf):
        m = leaf == lf
        if m.sum() < 10:
            continue
        share = yte[m].mean()
        if share >= MIN_PREC:
            found = True
            print(f"    лист {lf}: ОШИБКА — наблюдений {int(m.sum())}, "
                  f"ошибочных {int(yte[m].sum())} ({share:.1%}), "
                  f"EAD {eadte[m].sum()/1e9:.2f} млрд")
    if not found:
        print("    --> ни одного чистого листа с ошибками: сигнала нет")
    print(f"\n  ДЕРЕВО:\n{export_text(clf, feature_names=list(X.columns))}")
    return clf


df = load(CSV)
c = df[df.target.isin(CORP)].copy()
c["our_seg"] = c.apply(seg_c1, axis=1)
c["is_wrong"] = (c.our_seg != c.target).astype(int)

b = to_borrower(c)
b["is_wrong"] = (b.our_seg != b.target).astype(int)

print(f"договоров {len(c)}, ошибок {c.is_wrong.sum()} ({c.is_wrong.mean():.1%}), "
      f"EAD {c.loc[c.is_wrong == 1, 'ead_n'].sum()/1e9:.1f} млрд")
print(f"заёмщиков {len(b)}, ошибочных {b.is_wrong.sum()} ({b.is_wrong.mean():.1%}), "
      f"EAD {b.loc[b.is_wrong == 1, 'ead_sum'].sum()/1e9:.1f} млрд")
print("\nматрица С1 -> АФР, ЗАЁМЩИКИ:")
print(pd.crosstab(b.our_seg, b.target))
print()

# 1. общий прогон: где вообще С1 расходится с АФР
report("все заёмщики — расходится ли С1 с АФР", prep(b), b.is_wrong,
       b.ead_sum.values, note="our_seg подан признаком")

# 2. подзадачи по нашему сегменту
for seg in ["RETSML", "CORMED", "CORLAR"]:
    sub = b[b.our_seg == seg]
    report(f"наш {seg} — где АФР правит", prep(sub), sub.is_wrong,
           sub.ead_sum.values,
           note=f"куда правит АФР: "
                f"{sub.loc[sub.is_wrong == 1, 'target'].value_counts().to_dict()}")

# 3. проверка конкретных правил-кандидатов, а не только дерева
print("=" * 72)
print("ПРАВИЛА-КАНДИДАТЫ (на всей выборке, без разбиения — это не модель,")
print("а проверка того, что дерево нашло или не нашло)")
cands = {
    "ent_type отсутствует (0/NULL)": b.ent_type_n.fillna(0) == 0,
    "наш RETSML и ead_sum > 200 млн": (b.our_seg == "RETSML") & (b.ead_sum > 2e8),
    "наш RETSML и ead_sum > 500 млн": (b.our_seg == "RETSML") & (b.ead_sum > 5e8),
    "наш RETSML и ead_sum > 1 млрд":  (b.our_seg == "RETSML") & (b.ead_sum > 1e9),
}
for nm, m in cands.items():
    if m.sum() == 0:
        continue
    hit = b.loc[m]
    prec = hit.is_wrong.mean()
    print(f"  {nm}: заёмщиков {int(m.sum())}, из них ошибочных "
          f"{int(hit.is_wrong.sum())} — точность {prec:.1%}, "
          f"ложных {int((~hit.is_wrong.astype(bool)).sum())}, "
          f"EAD пойманных {hit.loc[hit.is_wrong == 1, 'ead_sum'].sum()/1e9:.1f} млрд")
    print(f"      куда правит АФР: "
          f"{hit.loc[hit.is_wrong == 1, 'target'].value_counts().to_dict()}")
print()

print("=" * 72)
print("ИТОГ")
print("Правило вносить только если точность >= 85 % И оно объяснимо.")
print("Необъяснимое правило на неинтерпретированном коде — это loan_obj = 11,")
print("две строки разреза и регресс на 1 051 договоре.")
