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
    # Windows-путь писать через r"..." либо прямыми слэшами, иначе \n и \t
    # будут прочитаны как управляющие символы:
    #   r"R:\!!!!!НСТ2026\FIXING_SEGMENTATION\B1A_FOR_TREE.csv"
    "path": r"B1A_FOR_TREE.csv",
    "sheet": 0,
    "sep": None,                    # None = определить разделитель автоматически
    "usecols": None,                # None = все; список — если не хватает памяти
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
    # Утечка. Две группы, обе обязаны быть исключены:
    #  1) производные того же скрипта сегментации;
    #  2) РЕЗУЛЬТАТЫ AQR — они калиброваны ПО СЕГМЕНТУ, поэтому дерево
    #     выучит «lgd = 0.695 -> CORLAR» и покажет фиктивную точность.
    "leak_cols": [
        "stage", "ead_n", "amount", "segment_nst_credit",
        "lgd", "lgd_", "pd_c12", "pd_cl", "pd_ol",
        "pd0_12m", "pd0_srok", "pd_12m", "pd_srok",
        "provisions", "provisions_1000", "prov_rate", "nps_prov",
        "privedennaya_st", "obezcenenia", "uvelich_kr_riska", "stadia_kr_riska",
        "trebovania_k_def_zaimu", "vn_reiting", "kateg_vzveshivania",
        "ccf", "ccf_rwa", "koef_konverciy",
        "rwa_base_1", "rwa_base_2", "rwa_base_3", "rwa_group", "rwa_subgroup",
        "rwa_group_off", "rwa_d1", "rwa_d2", "rwa_d3",
        "rwa1", "rwa2", "rwa3", "rwa_total",
    ],
    # Технические поля загрузки и учёта. Коррелируют с продуктом, но правилами
    # сегментации не являются: дерево на них выдаёт условия вида
    # «source_system = 'CL'», которые нельзя внести ни в один регламент.
    "tech_cols": [
        "source_system", "datatype", "kod_podrazdelenia", "fil_code",
        "doc_type_nb_id", "operation_date", "is_del", "ef_batches_int_id",
        "ef_contract_id", "nps_1400", "nps_1424", "nps_1740", "nps_1741",
        "nps_6000", "nps_6000_dop", "nps_1430", "nps_1434", "nps_1434_dop",
    ],
    # Колонки с датами. Принимаются и как даты, и как Excel-сериалы.
    "date_cols": ["loan_start_date", "loan_end_date", "od_del_date",
                  "interest_del_date", "wo_date", "restr_date", "date_kdn",
                  "grace_od_date", "grace_int_date", "grace_principal",
                  "grace_pay"],

    # ---- РЕЖИМ ОТБОРА ПРИЗНАКОВ -------------------------------------------
    #  "strict"  — только критерии, допустимые Таблицей 4 Методруководства.
    #              Правила получаются переносимыми на следующий год.
    #  "explore" — все колонки. Годится для разведки, НЕ для регламента:
    #              дерево найдёт условия вроде «ltv <> 47.5» — запоминание
    #              конкретной когорты, которой в следующем году не будет.
    "mode": "strict",
    "compare_modes": True,          # показать, сколько теряется на дисциплине

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
    "rule_depth": 4,             # глубина деревьев «сегмент против всех»
    "min_rule_purity": 0.80,     # ФАКТИЧЕСКАЯ доля сегмента в листе
    "min_fill": 0.02,            # признак с заполненностью ниже — выбросить
}

STUBS = {"1111111111111", "9999999999999", "1111111111111.0", "9999999999999.0"}

# ============================================================================
# Признаки, допустимые как КРИТЕРИИ сегментации.
# Основание — Таблица 4 Методруководства; расшифровка — GROUND_TRUTH_SEGMENTS.md.
# Каждая строка: признак -> какой критерий он обслуживает.
# ============================================================================
ALLOWED = {
    "entity":        "ОУСА: «все займы на балансе ОУСА»",
    "lsboo":         "ЛСБОО: «согласно требованиям регуляторной отчётности»",
    "f_inv":         "инвестиционные: флаг по трём признакам ПП",
    "debtor_type":   "юрлицо/физлицо — входит в критерии размера и розницы",
    "debtor_se":     "ИП: субъект малого предпринимательства по ст. 24",
    "ent_type":      "размер бизнеса по ст. 24 Предпринимательского кодекса",
    "loan_obj":      "объект кредитования — справочник АФР",
    "loan_purp":     "цель кредитования — справочник АФР",
    "loan_type":     "вид займа/условного обязательства — периметр Таблицы 3",
    "cl_type":       "тип кредитной линии — отзывность",
    "collateral":    "наличие обеспечения — розничные портфели",
    "in_b2a":        "список индивидуальных займов B2A",
    "ind_sign":      "индивидуально значимый / однородный актив",
    "eng_share_capital":        "порог 0,2 % капитала (ДОЛЯ, не сумма)",
    "eng_over_02pct":           "тот же порог индикатором",
    "eng_contracts_of_borrower":"число договоров заёмщика",
    "eng_srok_let":             "срок займа: критерий «5 и более лет»",
    "eng_srok_ge_5let":         "тот же критерий индикатором",
    "eng_oked_razdel":          "отраслевой раздел ОКЭД (не сам код)",
    "ead":           "порог 200 млн ₸ в рознице — соглашение банка, не Таблица 4",
    "portfolio":     "внутренний продукт — прокси, нестабилен между годами",
}

# Признаки, непригодные для ПЕРЕНОСА на следующий год, даже если работают.
# Порог в тенге устаревает вместе с капиталом и инфляцией; конкретная дата —
# это точка, а не правило.
UNSTABLE = {
    "eng_zadol_borrower": "абсолютная сумма в ₸ — заменяется на eng_share_capital",
    "eng_zadol_metod":    "абсолютная сумма в ₸",
    "eng_zadol_script":   "абсолютная сумма в ₸",
    "ead":                "абсолютный порог 200 млн ₸ не индексируется",
    "portfolio":          "перечень продуктов банка меняется между циклами",
}
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
import io
import warnings
import numpy as np
import pandas as pd

warnings.filterwarnings("ignore")
pd.set_option("display.width", 220)
pd.set_option("display.max_columns", 90)


def sniff(path, enc):
    """Разделитель по первой строке: побеждает тот, что даёт больше колонок."""
    with io.open(path, encoding=enc, errors="strict") as f:
        head = f.readline()
    best = max((";", ",", "\t", "|"), key=lambda d: head.count(d))
    if head.count(best) == 0:
        raise RuntimeError("в первой строке нет ни одного из ; , tab |")
    print("разделитель определён: %r (колонок в шапке: %d)"
          % (best, head.count(best) + 1))
    return best


def read_any(path, sheet=0, sep=None, usecols=None):
    if str(path).lower().endswith((".xlsx", ".xlsm", ".xls")):
        return pd.read_excel(path, sheet_name=sheet, dtype=str, usecols=usecols)
    last = None
    for enc in ("utf-8-sig", "utf-8", "cp1251"):
        try:
            d = sep or sniff(path, enc)
            df_ = pd.read_csv(path, sep=d, dtype=str, encoding=enc,
                              usecols=usecols, low_memory=False)
            print("кодировка: %s" % enc)
            if df_.shape[1] < 5:
                raise RuntimeError(
                    "прочитано всего %d колонок — почти наверняка не тот "
                    "разделитель. Задать вручную CONFIG['sep']." % df_.shape[1])
            return df_
        except UnicodeDecodeError as e:
            last = e
            continue
    raise RuntimeError("не удалось прочитать файл: %s" % last)


df = read_any(CONFIG["path"], CONFIG["sheet"], CONFIG["sep"], CONFIG["usecols"])
df.columns = [str(c).strip().lower() for c in df.columns]
print("загружено:", df.shape[0], "строк,", df.shape[1], "колонок")
print("память под таблицу: %.2f ГБ" % (df.memory_usage(deep=True).sum() / 2**30))

dropped_leak = [c for c in CONFIG["leak_cols"] if c in df.columns]
if dropped_leak:
    print("исключены как утечка (%d): %s" % (len(dropped_leak), dropped_leak))

TARGET, LEGACY = CONFIG["target"].lower(), CONFIG["legacy"].lower()
assert TARGET in df.columns, "нет колонки эталона '%s'" % TARGET
has_legacy = LEGACY in df.columns
if not has_legacy:
    print("ВНИМАНИЕ: колонки '%s' нет — разбор расхождений пропускается" % LEGACY)

n_raw = len(df)
df = df[df[TARGET].notna() & (df[TARGET].astype(str).str.strip() != "")]
if n_raw - len(df):
    print("!! отброшено %d строк без эталона (%.1f%% файла)."
          % (n_raw - len(df), 100 * (n_raw - len(df)) / n_raw))
    print("   Объяснить до того, как принимать правила: пустые строки Excel,")
    print("   несопоставленные договоры или лишний блок в выгрузке — разные вещи.")
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
    """Доля чисел СРЕДИ НЕ-ЗАГЛУШЕК.

    Считать заглушки нечисловыми нельзя: колонка вроде `ltv`, где 85 % строк —
    '1111111111111', иначе уезжает в категориальные, и дерево начинает
    запоминать отдельные значения LTV вместо порогов.
    """
    smp = s.dropna().astype(str).str.strip()
    smp = smp[~smp.isin(STUBS)].head(n)
    return 0.0 if len(smp) == 0 else to_num(smp).notna().mean()


def as_date(s):
    """Дата из строки ИЛИ из Excel-сериала (origin 1899-12-30)."""
    num = pd.to_numeric(s.astype(str).str.strip().str.replace(",", ".",
                                                              regex=False),
                        errors="coerce")
    looks_serial = num.between(20000, 60000).mean() > 0.5
    if looks_serial:
        return pd.to_datetime(num, unit="D", origin="1899-12-30",
                              errors="coerce"), "Excel-сериал"
    return pd.to_datetime(s, errors="coerce", dayfirst=True), "строка"


service = set(CONFIG["pii_cols"] + CONFIG["id_cols"] + CONFIG["leak_cols"] +
              CONFIG["tech_cols"] + CONFIG["date_cols"] +
              [TARGET, LEGACY, CONFIG["borrower_key"], "oked"])

num_cols, cat_cols = [], []
for c in df.columns:
    if c in service:
        continue
    if numeric_share(df[c]) > 0.95 and df[c].nunique(dropna=True) > 10:
        num_cols.append(c)
    else:
        cat_cols.append(c)
print("числовых:", len(num_cols), "| категориальных:", len(cat_cols))
print("исключены как технические:",
      [c for c in CONFIG["tech_cols"] if c in df.columns])

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
    ds, fmt_s = as_date(df["loan_start_date"])
    de, fmt_e = as_date(df["loan_end_date"])
    bad = (ds.isna() | de.isna()).mean()
    print("даты: формат '%s' / '%s'; не распознано %.2f%% строк"
          % (fmt_s, fmt_e, 100 * bad))
    if bad <= 0.5:
        print("  диапазон выдачи: %s .. %s" % (ds.min().date(), ds.max().date()))
    else:
        print("  !! даты не читаются, пример: %r / %r" %
              (df["loan_start_date"].dropna().iloc[0],
               df["loan_end_date"].dropna().iloc[0]))
    rep = pd.Timestamp(CONFIG["report_date"])
    feat["eng_srok_let"] = (de - ds).dt.days / 365.25
    feat["eng_srok_ost_let"] = (de - rep).dt.days / 365.25
    feat["eng_srok_ge_5let"] = (feat["eng_srok_let"] >= 5).astype(float)

# ОКЭД: как число он бессмыслен (порог «oked <= 46426» неинтерпретируем).
# Берём двузначный раздел — это отраслевая группировка, и признак заполненности.
if "oked" in df.columns:
    ok = df["oked"].astype(str).str.strip().str.replace(r"\D", "", regex=True)
    feat["eng_oked_razdel"] = ok.str[:2].replace("", np.nan)
    feat["eng_oked_zapolnen"] = ok.ne("").astype(float)
    print("ОКЭД: разделов %d, заполнен у %.1f%% строк"
          % (feat["eng_oked_razdel"].nunique(), 100 * feat["eng_oked_zapolnen"].mean()))

# --- контроль: инженерные признаки не должны оказаться пустыми молча -------
ENG_CRITICAL = {
    "eng_share_capital": "порог 0,2 % -> Individual loans",
    "eng_srok_let": "срок >= 5 лет -> CORINV",
    "eng_zadol_script": "база задолженности",
}
print("\n--- контроль инженерных признаков ---")
for c, why in ENG_CRITICAL.items():
    if c not in feat.columns:
        print("  ОТСУТСТВУЕТ %-22s (%s) — не хватило исходных колонок" % (c, why))
    elif feat[c].notna().sum() == 0:
        print("  ПУСТ       %-22s (%s) — правило не восстановится" % (c, why))
    else:
        print("  ок         %-22s заполнен на %.1f%%"
              % (c, 100 * feat[c].notna().mean()))

df = df[[c for c in df.columns if c not in set(CONFIG["pii_cols"]) | {bk}]]
print("\nPII и ключ заёмщика удалены")

# --- отбор признаков по методологической допустимости ----------------------
feat_all = feat.copy()                       # сохраняем для режима explore
if CONFIG["mode"] == "strict":
    keep = [c for c in feat.columns if c in ALLOWED]
    drop = [c for c in feat.columns if c not in ALLOWED]
    print("\n--- режим strict: только критерии Таблицы 4 ---")
    print("оставлено %d признаков:" % len(keep))
    for c in keep:
        mark = "  (нестабилен между годами)" if c in UNSTABLE else ""
        print("   %-26s %s%s" % (c, ALLOWED[c], mark))
    print("отброшено %d: %s" % (len(drop), sorted(drop)))
    print("\nОтброшенные — это характеристики риска и техника учёта, а не"
          "\nкритерии отнесения. Правило вида «ltv <> 47.5» описывает конкретную"
          "\nкогорту этого года и на следующий цикл не переносится.")
    feat = feat[keep]

# --- почти пустые признаки: условия по ним ничего не значат ----------------
thin = [c for c in feat.columns
        if feat[c].notna().mean() < CONFIG["min_fill"]]
if thin:
    print("\nвыброшены как почти пустые (заполнено < %.0f%%):"
          % (100 * CONFIG["min_fill"]))
    for c in thin:
        print("   %-26s заполнен на %.2f%%" % (c, 100 * feat[c].notna().mean()))
    print("   Условие по такому признаку истинно почти для всех строк"
          "\n   и в правило попадает как шум.")
    feat = feat.drop(columns=thin)
else:
    print("\n--- режим explore: все признаки, для регламента НЕ применять ---")

# %% [markdown]
# ## 4. Кодирование
#
# Категориальные — в one-hot, чтобы правило читалось как `ent_type == '3'`,
# а не как бессмысленное `ent_type <= 1.5`.

# %%
def encode(frame):
    meta, blocks = {}, []
    for c in frame.columns:
        s = frame[c]
        if s.dtype.kind in "fiu":
            col = s.astype(float)
            if col.isna().any():
                ind = col.isna().astype(np.int8).rename(c + "__пропуск")
                blocks.append(ind)
                meta[ind.name] = (c, "пропуск")
            blocks.append(col.fillna(-9.99e14).rename(c))
            meta[c] = (c, None)
        else:
            vc = s.value_counts(dropna=True)
            vals = (list(vc.index[:CONFIG["onehot_top_n"]])
                    if len(vc) > CONFIG["onehot_max_card"] else list(vc.index))
            for v in vals:
                name = "%s == %s" % (c, v)
                blocks.append((s == v).astype(np.int8).rename(name))
                meta[name] = (c, v)
            if len(vc) > len(vals):
                name = "%s == <прочее>" % c
                blocks.append((~s.isin(vals) & s.notna()).astype(np.int8)
                              .rename(name))
                meta[name] = (c, "<прочее>")
    M = pd.concat(blocks, axis=1)
    M = M.loc[:, ~M.columns.duplicated()]
    return M, meta


X, FEATURE_META = encode(feat)
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

# --- сколько стоит дисциплина: strict против explore -----------------------
if CONFIG["compare_modes"] and CONFIG["mode"] == "strict":
    Xa, _ = encode(feat_all)
    Xa_tr, Xa_te = Xa.loc[X_tr.index], Xa.loc[X_te.index]
    clf_a = DecisionTreeClassifier(
        max_depth=CONFIG["max_depth"],
        min_samples_leaf=CONFIG["min_samples_leaf"], class_weight="balanced",
        random_state=CONFIG["random_state"]).fit(Xa_tr, y_tr)
    acc_a = clf_a.score(Xa_te, y_te)
    print("--- цена дисциплины ---")
    print("strict  (только критерии Таблицы 4) : %.5f  признаков %d"
          % (acc, X.shape[1]))
    print("explore (все колонки)               : %.5f  признаков %d"
          % (acc_a, Xa.shape[1]))
    print("разница                             : %+.5f" % (acc - acc_a))
    print("Если разница мала — переносимые правила почти ничего не теряют,")
    print("и брать нужно strict. Если велика — эталон опирается на что-то,")
    print("чего в критериях Таблицы 4 нет; это отдельная находка, а не повод")
    print("переключаться на explore.")

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
# Решающий признак — не точность, а состав значений эталона: наш скрипт выдаёт
# DISASS / RELATE / Individual loans конечными значениями. Если их в эталоне нет,
# он точно не является выходом нашего скрипта.
ours_only = {"DISASS", "RELATE", "Individual loans", "CORINV", "CORGOV"}
absent = sorted(ours_only - set(y.unique()))
present_legacy = sorted(ours_only & set(legacy.unique())) if has_legacy else []
print("сегменты нашего скрипта, которых НЕТ в эталоне: %s" % (absent or "нет"))
if has_legacy:
    print("из них присутствуют в прежней сегментации     : %s"
          % (present_legacy or "нет"))
if present_legacy and set(present_legacy) <= set(absent):
    print("ВЫВОД: эталон НЕ является выходом нашего скрипта — он перераспределяет")
    print("       сегменты, которые наш CASE оставляет конечными. Разбор осмыслен.")
elif not outside:
    print("ВЫВОД: эталон воспроизводится ТОЛЬКО нашими же колонками.")
    print("       Возможна тавтология: уточнить, откуда взялся segment_afr.")
else:
    print("ВЫВОД: в решении участвуют колонки вне текущих веток — разбор осмыслен.")

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


def tree_rules(model, feature_names, Xr, y_bin, min_samples=1, min_purity=0.0):
    """Правила из дерева с ФАКТИЧЕСКОЙ чистотой листа.

    `tree_.value` при class_weight='balanced' хранит ВЗВЕШЕННЫЕ доли. Для
    редкого сегмента вес доходит до 12 000 : 1, и лист, где 5 строк из 753
    относятся к сегменту, показывает «чистоту 98,8 %» вместо настоящих 0,7 %.
    Поэтому долю считаем по факту: раскладываем строки по листьям через
    apply() и берём обычные доли.
    """
    t, out = model.tree_, []
    leaf_of = model.apply(Xr)
    stat = (pd.DataFrame({"leaf": leaf_of, "y": np.asarray(y_bin)})
            .groupby("leaf")["y"].agg(n="size", pos="sum"))

    def walk(node, conds):
        if t.feature[node] != -2:
            f, thr = feature_names[t.feature[node]], t.threshold[node]
            walk(t.children_left[node], conds + [decode(f, thr, True)])
            walk(t.children_right[node], conds + [decode(f, thr, False)])
            return
        if node not in stat.index:
            return
        n, pos = int(stat.at[node, "n"]), int(stat.at[node, "pos"])
        purity = pos / n if n else 0.0
        if pos >= min_samples and purity >= min_purity:
            out.append({"conds": conds, "строк": n, "из них сегмент": pos,
                        "чистота": round(purity, 4)})

    walk(0, [])
    return sorted(out, key=lambda r: (-r["чистота"], -r["из них сегмент"]))


rules_by_seg, report = {}, []
for seg in y.value_counts().index:
    tgt = (y == seg).astype(int)
    if tgt.sum() < 30:
        report.append("### %s — %d строк, для правила мало\n" % (seg, tgt.sum()))
        continue
    m = DecisionTreeClassifier(max_depth=CONFIG["rule_depth"], min_samples_leaf=10,
                               class_weight="balanced",
                               random_state=CONFIG["random_state"]).fit(X, tgt)
    rules = tree_rules(m, list(X.columns), X, tgt,
                       min_samples=10, min_purity=CONFIG["min_rule_purity"])
    rules_by_seg[seg] = rules
    covered = sum(r["из них сегмент"] for r in rules)
    head = ("### %s — в сегменте %d строк, правилами покрыто %d (%.1f%%)\n"
            % (seg, tgt.sum(), covered, 100 * covered / max(tgt.sum(), 1)))
    body = ""
    for i, r in enumerate(rules[:6], 1):
        body += ("%d) ЕСЛИ %s\n   ТО %s   (строк в листе %d, из них %s — %d, "
                 "чистота %.1f%%)\n" % (
                     i, "\n      И ".join(human(c) for c in r["conds"]), seg,
                     r["строк"], seg, r["из них сегмент"], 100 * r["чистота"]))
    report.append(head + (body or
                          "правил с чистотой >= %.0f%% не выделено\n"
                          % (100 * CONFIG["min_rule_purity"])))

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


MIN_PURITY, MIN_ROWS = CONFIG["min_rule_purity"], 10
branches = []
for seg, rules in rules_by_seg.items():
    for r in rules:
        if r["чистота"] >= MIN_PURITY and r["из них сегмент"] >= MIN_ROWS:
            branches.append((r["чистота"], r["из них сегмент"], seg,
                             r["conds"]))
# сначала по смысловому приоритету сегмента, внутри сегмента — по чистоте
branches.sort(key=lambda b: (PRIORITY.index(b[2]) if b[2] in PRIORITY else 99,
                             -b[0], -b[1]))

unstable_used = sorted({c[1] for _, _, _, cs in branches for c in cs
                        if c[1] in UNSTABLE})
sql = [
    "-- Сегментация, восстановленная из эталона АФР деревом решений.",
    "-- Режим отбора признаков: %s" % CONFIG["mode"],
] + (["-- ВНИМАНИЕ: использованы признаки, непереносимые на следующий год:"] +
     ["--   %-22s %s" % (c, UNSTABLE[c]) for c in unstable_used]
     if unstable_used else ["-- Все использованные признаки переносимы между циклами."]) + [
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
    sql.append("       THEN '%s'   -- сегмента в листе %d, чистота %.1f%%"
               % (seg, n, 100 * purity))
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
    for i, r in enumerate(tree_rules(mm, list(X.columns), X, mism,
                                     min_samples=10,
                                     min_purity=CONFIG["min_rule_purity"])[:8], 1):
        print("%d) ЕСЛИ %s\n   -> расхождение с эталоном"
              "   (строк %d, из них расходятся %d — %.1f%%)\n" %
              (i, "\n      И ".join(human(c) for c in r["conds"]),
               r["строк"], r["из них сегмент"], 100 * r["чистота"]))
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
        rr = tree_rules(mt, list(X.columns), X[sub], tgt,
                        min_samples=5, min_purity=0.5)
        print("=== было '%s' -> эталон '%s'  (%d строк) ===" %
              (was, became, int(moves.loc[(was, became), "строк"])))
        for r in rr[:3]:
            print("   ЕСЛИ %s   (строк %d, из них перешли %d — %.1f%%)" %
                  ("\n        И ".join(human(c) for c in r["conds"]),
                   r["строк"], r["из них сегмент"], 100 * r["чистота"]))
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
