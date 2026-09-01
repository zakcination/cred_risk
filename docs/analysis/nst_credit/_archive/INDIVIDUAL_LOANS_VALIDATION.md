# Individual Loans: Validation против списка Sabila

## Что получено от Sabila

### File 1: Consolidated Individual Loans List
- **Источник**: "Список инд. заемщиков" (consolidated across banks)
- **Размер**: 66 BINs
- **Структура**: Bank code (EUB for Евразийский) + № + БИН + Name
- **Назначение**: Ground truth для Individual loans classification
- **Статус**: Это то, что НСТ одобрил как правильное разделение

### File 2: AQR2026 Individual Loans Analysis
- **Источник**: "список индивидуалов AQR" (detailed analysis)
- **Размер**: 24 borrower profiles analyzed
- **Структура**: 
  - IIN_BIN + Name
  - "Кредиты" (Loans, amortized cost)
  - "КЛ" (Revolving limit?)
  - "УО" (Other obligations?)
  - "Зад-сть с учетом всех обяз-в" (Total debt)
  - "Список ИА" — marked as "Индив" or "Не Индив"
  - Comments explaining classification
  
**Примеры меток**:
```
<БИН-1> — Не Индив (менее 0,2% от СК)          [debt < threshold]
<БИН-2> — Индив (имеется в списке ИА)          [in consolidated list]
<БИН-3> — Не Индив (менее 0,2% от СК)          [ИП, debt < threshold]
```

---

## 🚨 Critical Issues Found

### Issue 1: Capital Value Discrepancy

| Source | Value | Date | Used For |
|---|---|---|---|
| User provided | 557,685,150,000 ₸ | 31.12.2025 | segmentation_nst2026.sql |
| Sabila's file | 503,086,114,000 ₸ | 01.01.26 | Individual loans threshold |
| **Difference** | **54.6 billion ₸** (10.9%) | — | **Changes classification** |

**Impact on Individual loans threshold (0.2% capital)**:
```
NST-2026 script:  0.2% × 557.685B = 1,153,370,300 ₸
Sabila's analysis: 0.2% × 503.086B = 1,006,172,228 ₸
Swing per BIN:     147,198,072 ₸ (causes reclassifications)
```

**Decision needed**: Which capital should be used?
- Option A: **557.7B** (regulatory on 31.12.2025) — more recent, conservative
- Option B: **503.1B** (from Sabila's analysis) — aligns with her calculations
- **Recommendation**: Ask БРМ which capital value goes into the НСТ template. Sabila's and our calculations must match the same reference date.

---

### Issue 2: Two-Source Individual Loans Logic

Current script has TWO conditions (either = Individual loans):

**Condition 1: B2A List Join**
```sql
WHEN a.bin IS NOT NULL THEN 'Individual loans'  -- Sabila's 66-BIN list
```
Status: ✅ Clear (use Sabila's consolidated list)

**Condition 2: 0.2% Threshold**
```sql
WHEN SUM(debt) OVER (PARTITION BY iin_bin) > @capital * 0.002 THEN 'Individual loans'
```
Status: ⚠️ Capital mismatch (NST-2026 vs Sabila value)

---

## Validation Tasks

### Task 1: Run Diagnostic Query
```sql
-- File: validate_individual_loans_sabila.sql
-- Shows classification under both capital values
-- Identifies BINs on the threshold boundary
```

**Expected output**:
- How many BINs switch classification (NST-2026 capital vs Sabila)?
- Which BINs are "boundary cases" (near 0.2% threshold)?
- Are there BINs in our B1A not in Sabila's 66-list?

### Task 2: Match Against File 2 Markings
Sabila's File 2 shows per-BIN analysis with final "Список ИА" marking:
- "Индив" = classified as Individual loans
- "Не Индив" = NOT individual loans

**Check**: Do our script results match her markings?
```
Compare (for 24 rows in File 2):
  Our classification (by script logic)
  vs Sabila's classification (her "Список ИА" column)
```

### Task 3: Reconcile the 66-BIN vs 24-row Discrepancy
- File 1 has 66 consolidated BINs
- File 2 analyzes only 24 BINs
- Why 42 BINs missing from File 2? (They are below threshold? Not EUB?)

---

## Current Script Status

**segmentation_nst2026.sql** uses:
- Capital: 557,685,150,000 ₸ (NST-2026, 31.12.2025)
- B2A table: `RA_NST_B2A_2026_04012026` (requires joining with File 1's 66 BINs)
- Threshold: > 0.2% (strict inequality)

**To sync with Sabila**:
1. ✅ Confirm B2A table contains her 66-BIN list
2. ⚠️ **Decide on capital value** (affects threshold cases)
3. ⚠️ **Verify threshold comparison** (she uses > or ≥?)
4. ✅ Test against File 2 markings (24 sample cases)

---

## Decision Tree

```
IF capital_value = 557.7B (NST-2026) THEN
  • Uses most recent regulatory capital
  • May classify MORE BINs as Individual loans (lower threshold)
  • Need to check: Does this match regulatory template requirement?
ELSE IF capital_value = 503.1B (Sabila's) THEN
  • Aligns with her analysis and calculations
  • May classify FEWER BINs as Individual loans (higher threshold)
  • Simpler to reconcile her validation
ENDIF

→ **ACTION**: Ask БРМ for clarification before finalizing
```

---

## Files Provided by Sabila

| File | Sheet | Content | Size |
|---|---|---|---|
| `4053a2dd-*.xlsx` | Список инд. заемщиков | 66 consolidated BINs | 66 rows |
| | Справочник | Bank code reference | 27 rows |
| `ef864791-*AQR2026.xlsx` | список индивидуалов AQR | 24 analyzed profiles | 24 rows |

**Next step**: Run `validate_individual_loans_sabila.sql` diagnostic to identify reclassifications due to capital difference, then reconcile with Sabila's File 2 markings.
