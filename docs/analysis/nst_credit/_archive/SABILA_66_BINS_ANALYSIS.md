# Analysis: Sabila's 66 BINs vs Our Classification Logic

## What This Tests

**Sabila provided a consolidated list of 66 BINs** that should all be classified as "Individual loans" per the regulatory requirement.

Our script must:
1. ✅ Recognize all 66 BINs in the B1A/B1B database
2. ✅ Classify each as "Individual loans" (either via B2A join or 0.2% threshold)
3. ⚠️ Not misclassify any as business segments (CORLAR/CORMED/RETSML)

---

## SQL Query: `compare_sabila_66_bins_classification.sql`

**Loads all 66 BINs hardcoded** and runs 4 diagnostic queries:

### Query 1: Presence Check
```
Columns: row_num | bin | in_b1a (YES/NO) | contracts | total_ead | total_debt | borrower_name
```
**Shows**: Which BINs exist in B1A, how many contracts each has, total debt

**Success**: All 66 should have `in_b1a = YES`

### Query 2: Classification Results
```
Columns: row_num | bin | borrower_name | contracts | total_ead | our_classification
```
**Shows**: What segment our logic assigns to each BIN

**Expected**: All 66 → `'Individual loans (B2A)'` OR `'Individual loans (threshold)'`

**Anomalies to watch**: 
- `'CORLAR'`, `'CORMED'`, `'RETSML'` = business size misclassification ⚠️
- `'RETEST'`, `'RETCAR'`, `'RETCON'` = retail misclassification ⚠️
- `'X (unclassified)'` = not recognized ⚠️

### Query 3: Discrepancies Only
```
Columns: status | row_num | bin | borrower_name | our_result | in_b2a_list | total_ead | total_debt
```
**Shows**: Only BINs that are NOT classified as Individual loans (filtered list)

**Interpretation**:
- Row appears = BIN is misclassified by our logic
- Row count = how many errors
- `in_b2a_list = YES` but `our_result != 'Individual loans'` = join worked but other condition took priority

### Query 4: Summary
```
total_sabila_bins | found_in_b1a | not_in_b1a | in_b2a_join | classified_as_individual_loans
```
**Scorecard**: Pass/fail at a glance

**Success criteria**:
- `found_in_b1a` = 66 (all present)
- `in_b2a_join` ≈ 66 (or close, if some hit 0.2% threshold instead)
- `classified_as_individual_loans` = 66 (all correct)

---

## Expected Outcomes

### Scenario A: All 66 correct ✅
```
found_in_b1a = 66
classified_as_individual_loans = 66
→ No issues, proceed
```

### Scenario B: Some in B2A, rest by threshold ✅
```
found_in_b1a = 66
in_b2a_join = 40
classified_as_individual_loans = 66  (26 via threshold, 40 via B2A)
→ Normal case, both paths working
```

### Scenario C: Missing from B1A ⚠️
```
found_in_b1a = 62
not_in_b1a = 4
→ Investigate: why 4 BINs not in database?
  - Different table/schema?
  - Deleted (is_del='1')?
  - Data quality issue?
```

### Scenario D: Misclassified to business segments ❌
```
classified_as_individual_loans = 55
→ 11 BINs classified as CORLAR/CORMED/RETSML/COREST
→ Problem: ent_type field is wrong for these borrowers
→ Action: Fix ent_type mapping or add exception logic
```

### Scenario E: Unclassified ❌
```
classified_as_individual_loans = 64
→ 2 BINs classified as 'X' (don't match any segment)
→ Problem: Logic hole or data quality
→ Action: Debug and fill gap
```

---

## How to Use

1. **Run the query** against AQR2026_B1A_2025_Q4:
   ```bash
   -- Copy SQL, paste into SQL Server, execute
   -- Check all 4 result sets
   ```

2. **Analyze results in order**:
   - Table 1: If `in_b1a = NO`, stop and investigate data availability
   - Table 2: See full classification results
   - Table 3: See misclassified BINs (if any)
   - Table 4: Get pass/fail summary

3. **Take action based on findings**:
   - **All pass**: ✅ Proceed to next validation step
   - **Some fail**: ⚠️ Adjust script logic (ent_type mapping, threshold, etc.)
   - **All fail**: ❌ Review assumptions (capital, table names, B2A)

---

## Known Issues to Check

### Issue 1: Capital Value
- Query uses `@capital_nst2026 = 557,685,150,000` 
- If many BINs fail "threshold" path, may be capital mismatch
- Compare against Sabila's capital value (503.1B)

### Issue 2: B2A Join
- Query looks for `RA_NST_B2A_2026_04012026` table
- If 0 rows join, check table name / existence

### Issue 3: ent_type Misclassification
- If BINs classified as CORLAR/CORMED/RETSML:
  - Check if they truly have `ent_type` = 1/2/3
  - Or is ent_type incorrectly populated for these entities?
  - Note: debtor_type=0 (individuals) should not have ent_type populated

---

## File Structure

**Input**: 
- All 66 BINs from Sabila's "Список инд. заемщиков" hardcoded in @sabila_bins temp table

**Output**:
- 4 result sets (copy to Excel for analysis if needed)
- Summary row for pass/fail decision

---

## Next Steps After Query Results

| Finding | Action |
|---|---|
| All 66 classified correctly as Individual loans | ✅ Move to Tabl 3 AQR analysis validation |
| 1-10 misclassified | Review specific BINs, check ent_type/debtor_type |
| 11+ misclassified | Rethink segment branching order or field mapping |
| Not in B1A | Confirm table names, check is_del filter |
| B2A join returns 0 | Verify RA_NST_B2A table exists and has data |

---

## Design Notes

- **No external file read**: All 66 BINs hardcoded as VALUES (portable)
- **Uses same capital** as segmentation_nst2026.sql for consistency
- **Includes debtor_type/ent_type checks** to catch business misclassification
- **Summary row** allows at-a-glance pass/fail
