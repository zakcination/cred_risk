# -*- coding: utf-8 -*-
"""
Перенос сегментации на новый отчётный год.

Задача: эталон АФР есть за прошлый год, за текущий его ещё нет. Нужно
разметить текущий год и честно сказать, какая часть разметки надёжна.

Два независимых механизма:
  1) ПЕРЕНОС ПО ДОГОВОРУ — заём был в прошлом году, его атрибуты не изменились,
     значит критерии Таблицы 4 дают тот же ответ. Самый надёжный источник.
  2) ПРАВИЛА — дерево, обученное на эталоне прошлого года, применяется
     к остальным договорам.

Признаки — только КАТЕГОРИАЛЬНЫЕ. Количественные бьются на интервалы,
границы которых взяты из методики (0,2 % капитала; 5 лет; 200 млн ₸), а не
подобраны по данным. Порог «срок > 14,3 года» живёт один цикл, порог
«срок >= 5 лет» переносится.

Запуск локальный: python apply_to_new_year.py
"""

# %% [markdown]
# ## 1. Конфигурация

# %%
CONFIG = {
    # прошлый год — с эталоном АФР
    "prior_path": r"B1A_FOR_TREE.csv",
    "prior_capital": 461_235_157_000,
    "prior_report_date": "2024-12-31",
    # текущий год — размечаем
    "new_path": r"B1A_2025.csv",
    "new_capital": 461_235_157_000,      # ЗАМЕНИТЬ на СК на 31.12.2025
    "new_report_date": "2025-12-31",

    "target": "segment_afr",
    "legacy": "segment_eub",
    "loan_key": "loan_id_kr",            # ключ переноса по договору
    "borrower_key": "iin_bin",

    "sep": None,
    "min_proba": 0.80,                   # ниже — «не определён», на ручную проверку
    "max_depth": 8,
    "min_samples_leaf": 20,
    "random_state": 0,
}

# ============================================================================
# Категориальные признаки: критерии Таблицы 4, как есть
# ============================================================================
CAT_FEATURES = ["entity", "debtor_type", "debtor_se", "ent_type", "lsboo",
                "f_inv", "loan_obj", "loan_purp", "loan_type", "collateral",
                "ind_sign", "cl_type"]

# ============================================================================
# Количественные -> интервалы. Границы С ОБОСНОВАНИЕМ.
# Где у методики есть число — берём его. Где нет — round-числа, а не квантили:
# квантиль пересчитается на новых данных и правило поедет.
# ============================================================================
import numpy as np

BINS = {
    "share_capital": {
        "edges": [-np.inf, 0.002, 0.01, 0.05, np.inf],
        "labels": ["<0,2%", "0,2-1%", "1-5%", ">5%"],
        "why": "0,2 % — порог индивидуальных займов, Таблица 4 (дословно)",
    },
    "srok_let": {
        "edges": [-np.inf, 1, 3, 5, 10, np.inf],
        "labels": ["<1г", "1-3г", "3-5г", "5-10л", ">10л"],
        "why": "5 лет — критерий инвестиционного займа, Таблица 4 (дословно)",
    },
    "ead": {
        "edges": [-np.inf, 10e6, 50e6, 200e6, np.inf],
        "labels": ["<10млн", "10-50млн", "50-200млн", ">200млн"],
        "why": "200 млн ₸ — отсечка розницы в действующем скрипте банка",
    },
    "contracts_of_borrower": {
        "edges": [-np.inf, 1, 5, 20, 100, np.inf],
        "labels": ["1", "2-5", "6-20", "21-100", ">100"],
        "why": "нормативной привязки нет — округлённые границы, а не квантили",
    },
}

# ============================================================================
# Что может измениться за год, а что нет.
# Методика оценивает критерии НА ОТЧЁТНУЮ ДАТУ (п. 36, п. 44), то есть
# автоматически наследовать сегмент нельзя. Но атрибут договора, зафиксированный
# при выдаче, за год не меняется — и критерий на нём даёт тот же ответ.
# ============================================================================
STABLE = {                      # атрибуты договора: фиксируются при выдаче
    "loan_obj":   "объект кредитования — задан договором",
    "loan_purp":  "цель кредитования — задана договором",
    "loan_type":  "вид займа — задан договором",
    "debtor_type": "юрлицо/физлицо — меняется только при смене заёмщика",
    "srok_let":   "срок — из дат договора",
}
VOLATILE = {                    # атрибуты заёмщика и статуса: меняются за год
    "ent_type":      "размер бизнеса: численность и доход считаются за год (ст. 24)",
    "debtor_se":     "признак ИП: регистрация и прекращение",
    "lsboo":         "реестр ЛСБОО обновляется",
    "entity":        "передача займа в ОУСА происходит в течение года",
    "collateral":    "залог освобождается и довносится",
    "share_capital": "меняется и задолженность заёмщика, и капитал банка",
    "ind_sign":      "признак значимости пересматривается",
}

# %% [markdown]
# ## 2. Загрузка и подготовка

# %%
import io
import warnings
import pandas as pd

warnings.filterwarnings("ignore")
pd.set_option("display.width", 200)
pd.set_option("display.max_columns", 60)

STUBS = {"1111111111111", "9999999999999", "1111111111111.0", "9999999999999.0"}
DEBT = ["od", "od_del", "interest", "interest_del", "disc_prem"]


def sniff(path, enc):
    with io.open(path, encoding=enc) as f:
        head = f.readline()
    return max((";", ",", "\t", "|"), key=lambda d: head.count(d))


def read_any(path, sep=None):
    if str(path).lower().endswith((".xlsx", ".xlsm", ".xls")):
        return pd.read_excel(path, dtype=str)
    for enc in ("utf-8-sig", "utf-8", "cp1251"):
        try:
            d = sep or sniff(path, enc)
            df_ = pd.read_csv(path, sep=d, dtype=str, encoding=enc, low_memory=False)
            df_.columns = [str(c).strip().lower() for c in df_.columns]
            return df_
        except UnicodeDecodeError:
            continue
    raise RuntimeError("не удалось прочитать %s" % path)


def to_num(s):
    x = s.astype(str).str.strip()
    x = x.where(~x.isin(STUBS))
    x = (x.str.replace(" ", "", regex=False).str.replace(" ", "", regex=False)
          .str.replace(",", ".", regex=False))
    return pd.to_numeric(x, errors="coerce")


def as_date(s):
    num = pd.to_numeric(s.astype(str).str.strip().str.replace(",", ".", regex=False),
                        errors="coerce")
    if num.between(20000, 60000).mean() > 0.5:          # Excel-сериал
        return pd.to_datetime(num, unit="D", origin="1899-12-30", errors="coerce")
    return pd.to_datetime(s, errors="coerce", dayfirst=True)


def build(path, capital, report_date, label):
    """Категориальная матрица признаков: критерии Таблицы 4 + интервалы."""
    src = read_any(path, CONFIG["sep"])
    print("\n=== %s: %d строк, %d колонок ===" % (label, len(src), src.shape[1]))
    out = pd.DataFrame(index=src.index)

    for c in CAT_FEATURES:
        out[c] = (src[c].astype(str).str.strip() if c in src.columns
                  else "<нет колонки>")

    have = [c for c in DEBT if c in src.columns]
    zadol = pd.concat([to_num(src[c]).fillna(0) for c in have], axis=1).sum(axis=1)
    bk = CONFIG["borrower_key"]
    grp = src[bk].astype(str)
    share = zadol.groupby(grp).transform("sum") / capital
    cnt = grp.map(grp.value_counts()).astype(float)
    srok = ((as_date(src["loan_end_date"]) - as_date(src["loan_start_date"]))
            .dt.days / 365.25)
    ead = to_num(src["ead"]) if "ead" in src.columns else pd.Series(np.nan, src.index)

    raw = {"share_capital": share, "srok_let": srok, "ead": ead,
           "contracts_of_borrower": cnt}
    for name, series in raw.items():
        b = BINS[name]
        out[name] = pd.cut(series, bins=b["edges"], labels=b["labels"],
                           right=True).astype(str).replace("nan", "<пусто>")

    keys = {"loan": src[CONFIG["loan_key"]].astype(str).str.strip()
            if CONFIG["loan_key"] in src.columns else None}
    for col in (CONFIG["target"], CONFIG["legacy"]):
        keys[col] = (src[col].astype(str).str.strip()
                     if col in src.columns else None)
    return out, keys, ead


print("Интервалы количественных признаков и обоснование границ:")
for k, b in BINS.items():
    print("  %-22s %s\n      %s" % (k, " | ".join(b["labels"]), b["why"]))

prior, pk, prior_ead = build(CONFIG["prior_path"], CONFIG["prior_capital"],
                             CONFIG["prior_report_date"], "прошлый год")
new, nk, new_ead = build(CONFIG["new_path"], CONFIG["new_capital"],
                         CONFIG["new_report_date"], "текущий год")

mask = pk[CONFIG["target"]].notna() & (pk[CONFIG["target"]] != "") \
    & (pk[CONFIG["target"]] != "nan")
prior, y_prior = prior[mask], pk[CONFIG["target"]][mask]
prior_key = pk["loan"][mask]
print("\nэталон прошлого года: %d строк, %d сегментов"
      % (len(y_prior), y_prior.nunique()))
print(y_prior.value_counts().to_frame("строк"))

# %% [markdown]
# ## 3. Дерево на категориальных признаках

# %%
from sklearn.tree import DecisionTreeClassifier
from sklearn.model_selection import train_test_split
from sklearn.metrics import classification_report

ALL_COLS = list(prior.columns)
enc = pd.get_dummies(pd.concat([prior[ALL_COLS], new[ALL_COLS]], axis=0),
                     columns=ALL_COLS, dtype=np.int8)
Xp, Xn = enc.iloc[:len(prior)], enc.iloc[len(prior):]
print("категориальных признаков после кодирования:", Xp.shape[1])

strat = y_prior if y_prior.value_counts().min() >= 2 else None
a, b_, ya, yb = train_test_split(Xp, y_prior, test_size=0.25,
                                 random_state=CONFIG["random_state"], stratify=strat)
clf = DecisionTreeClassifier(max_depth=CONFIG["max_depth"],
                             min_samples_leaf=CONFIG["min_samples_leaf"],
                             class_weight="balanced",
                             random_state=CONFIG["random_state"]).fit(a, ya)
print("точность на контроле прошлого года: %.5f" % clf.score(b_, yb))
print(classification_report(yb, clf.predict(b_), zero_division=0, digits=4))

clf_full = DecisionTreeClassifier(max_depth=CONFIG["max_depth"],
                                  min_samples_leaf=CONFIG["min_samples_leaf"],
                                  class_weight="balanced",
                                  random_state=CONFIG["random_state"]).fit(Xp, y_prior)
proba = clf_full.predict_proba(Xn)
pred = pd.Series(clf_full.classes_[proba.argmax(1)], index=new.index)
conf = pd.Series(proba.max(1), index=new.index)

# %% [markdown]
# ## 4. Перенос по договору и проверка изменившихся атрибутов

# %%
res = pd.DataFrame(index=new.index)
res["segment_rule"] = pred
res["confidence"] = conf.round(4)
res["segment_prior"] = pd.Series([None] * len(new), index=new.index,
                                 dtype=object)
res["changed"] = ""

if nk["loan"] is not None and prior_key is not None:
    prev = pd.DataFrame(prior[ALL_COLS])
    prev["__seg"] = y_prior.values
    prev["__key"] = prior_key.values
    prev = prev.drop_duplicates("__key").set_index("__key")

    cur_key = nk["loan"]
    matched = cur_key.isin(prev.index)
    print("договоров в текущем году      : %d" % len(new))
    print("из них были в прошлом году    : %d (%.1f%%)"
          % (matched.sum(), 100 * matched.mean()))

    idx = cur_key[matched]
    res.loc[matched, "segment_prior"] = prev.loc[idx, "__seg"].values

    changed = pd.Series("", index=new.index)
    for c in VOLATILE:
        if c not in ALL_COLS:
            continue
        diff = new.loc[matched, c].values != prev.loc[idx, c].values
        changed.loc[new.index[matched][diff]] += (c + ";")
    res["changed"] = changed
    print("\nиз перенесённых изменили атрибут заёмщика: %d (%.1f%% совпавших)"
          % ((changed[matched] != "").sum(),
             100 * (changed[matched] != "").mean()))
    top = (changed[matched][changed[matched] != ""].str.rstrip(";")
           .str.split(";").explode().value_counts())
    if len(top):
        print("какие именно:")
        print(top.to_frame("договоров"))
else:
    matched = pd.Series(False, index=new.index)
    print("!! ключа договора нет — перенос невозможен, только правила")

# %% [markdown]
# ## 5. Итоговая разметка и оценка надёжности

# %%
def classify(r):
    if isinstance(r["segment_prior"], str) and r["segment_prior"]:
        return "перенос" if not r["changed"] else "перенос+пересмотр"
    if r["confidence"] >= CONFIG["min_proba"]:
        return "правило"
    return "не определён"


res["источник"] = res.apply(classify, axis=1)
res["segment_final"] = np.where(res["источник"] == "перенос",
                                res["segment_prior"].astype(object),
                                res["segment_rule"].astype(object))
res["ead"] = new_ead.values

rep = res.groupby("источник").agg(
    договоров=("segment_final", "size"),
    ead_млрд=("ead", lambda s: round(s.sum() / 1e9, 2)))
rep["доля договоров, %"] = (100 * rep["договоров"] / len(res)).round(2)
rep["доля EAD, %"] = (100 * rep["ead_млрд"] / rep["ead_млрд"].sum()).round(2)
print("\n=== ЧЕМ РАЗМЕЧЕН ТЕКУЩИЙ ГОД ===\n")
print(rep.sort_values("договоров", ascending=False))

print("\n=== РАСПРЕДЕЛЕНИЕ ПО СЕГМЕНТАМ ===\n")
cmp = pd.DataFrame({
    "эталон прошлого года": y_prior.value_counts(),
    "разметка текущего": res["segment_final"].value_counts()}).fillna(0).astype(int)
cmp["изменение, %"] = ((100 * (cmp["разметка текущего"] /
                               cmp["эталон прошлого года"] - 1))
                       .replace([np.inf, -np.inf], np.nan).round(1))
print(cmp.sort_values("разметка текущего", ascending=False))

print("\n=== НАДЁЖНОСТЬ ПО СЕГМЕНТАМ ===\n")
qual = res.groupby("segment_final").agg(
    договоров=("источник", "size"),
    перенос=("источник", lambda s: (s == "перенос").sum()),
    правило=("источник", lambda s: (s == "правило").sum()),
    не_определён=("источник", lambda s: (s == "не определён").sum()),
    ср_уверенность=("confidence", lambda s: round(s.mean(), 3)))
qual["надёжно, %"] = (100 * qual["перенос"] / qual["договоров"]).round(1)
print(qual.sort_values("договоров", ascending=False))

low = res[res["источник"].isin(["не определён", "перенос+пересмотр"])]
print("\nТребуют ручной проверки: %d договоров, %.2f млрд ₸ (%.2f%% EAD)"
      % (len(low), low["ead"].sum() / 1e9,
         100 * low["ead"].sum() / max(res["ead"].sum(), 1)))

res.drop(columns=["ead"]).to_csv("segmentaciya_novyy_god.csv", sep=";",
                                 encoding="utf-8-sig", index=False)
rep.to_csv("otchet_pokrytiya.csv", sep=";", encoding="utf-8-sig")
print("\nсохранено: segmentaciya_novyy_god.csv, otchet_pokrytiya.csv")

# %% [markdown]
# ## 6. Что нельзя забыть при чтении результата

# %%
print("""
1. Методика оценивает критерии НА ОТЧЁТНУЮ ДАТУ. Перенос по договору
   допустим только потому, что атрибуты договора за год не меняются.
   Атрибуты заёмщика — меняются, и такие строки помечены «перенос+пересмотр».
2. Строки «правило» — это предсказание модели прошлого года. Для розницы
   (loan_obj 1/6/8) оно надёжно, для корпоративных сегментов — нет:
   на прошлом цикле точность CORMED была 0,39.
3. Сегменты CORGOV и CORINV в прошлом году пусты, правил для них нет.
   Если в текущем году появился заём госкорпорации, модель его НЕ найдёт.
4. Капитал в CONFIG задаётся отдельно для каждого года — порог 0,2 %
   считается от своего капитала, иначе индивидуальные займы поедут.
""")
