# Judge Feedback — iter587

**Date**: 2026-06-07
**Phase**: extended
**Verdict**: PASS (overall avg **4.9375**)

The iter586 ROUTED-BUT-MIS-APPLIED defect class is RESOLVED on both Q1 and Q2. The iter587 reconcile-in-place at r17 (clause↔arg un-confusable signal) and r07 (symptom→cause→fix + anti-fix) routed correctly and the responder used the RIGHT forms. Q3 and Q4 are clean fresh-topic answers.

---

## Per-question scores (Accuracy / Completeness / Clarity / Actionability)

### Q1 — TIME-TRAVEL clause RE-PROBE (wall-clock-time)

**Scores:** 5 / 5 / 5 / 5 → **avg 5.0**

- Led with `FOR TIMESTAMP AS OF TIMESTAMP '2026-06-06 01:00:00 UTC'` — the correct clause + correct argument type for a wall-clock-time question.
- Explicitly disambiguated: "the clause is FOR TIMESTAMP AS OF (not FOR VERSION AS OF, which takes a snapshot ID instead)." This is the EXACT un-confusable signal the iter587 r17 PIN added.
- Also gave the `$snapshots` lookup + `FOR VERSION AS OF <snapshot_id>` (BIGINT) for reproducibility — fully addresses the "exact moment / reproduce later" use case.
- Semantics ("Trino resolves to the latest snapshot with committed_at <= the time") is accurate.

**WebSearch verification — trino.io/docs/467/connector/iceberg.html:**
- FOR VERSION AS OF: "Argument Type: BIGINT (snapshot ID) or VARCHAR (branch/tag name)" — example `FOR VERSION AS OF 8954597067493422955`.
- FOR TIMESTAMP AS OF: "Argument Type: TIMESTAMP or DATE" — example `FOR TIMESTAMP AS OF TIMESTAMP '2022-03-23 09:59:29.803 Europe/Vienna'`.
- Resolution: "The latest snapshot of the table taken before or at the specified timestamp in the query is internally used for providing the previous state of the table."

**iter586 defect status: RESOLVED.** Responder no longer writes `FOR VERSION AS OF TIMESTAMP '…'` for a wall-clock-time question. Clause↔argument-type pairing is now correct on both sides.

---

### Q2 — ROWS-vs-RANGE running-total RE-PROBE

**Scores:** 5 / 5 / 5 / 4 → **avg 4.75**

- Diagnosis is now CORRECT: "the default window frame — ORDER BY date without an explicit frame defaults to RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW, which groups all rows with the same date (peer rows) and shows the total up to the END of that peer group." This is the iter587 r07 symptom→cause framing landing cleanly.
- Fix is correct: explicit `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` + unique tiebreaker (`ORDER BY sale_date, sale_id`).
- Critically, the responder did NOT recommend the default RANGE frame as the fix — the iter586 backwards-diagnosis anti-pattern is resolved.

**WebSearch verification — trino.io/docs/467/sql/select.html:**
- Default frame: "If the frame is not specified, it defaults to RANGE UNBOUNDED PRECEDING, which is the same as RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW."
- Peer inclusion: "This frame contains all rows from the start of the partition up to the last peer of the current row."

**Minor slip (Actionability ding, -1):** Final fallback line for the no-unique-column case wraps a window function inside an ORDER BY:
`ORDER BY sale_date, ROW_NUMBER() OVER (PARTITION BY sale_date ORDER BY amount, sale_id)`
This sits uncomfortably alongside the iter569 nested-window-ban canonical (Trino 467 rejects window functions nested inside other window-function clauses). At the top-level statement ORDER BY it can parse, but as a "drop-in" suggestion for a beginner SaaS engineer it is borderline-ambiguous and inconsistent with the responder's own canonical guidance. Main fix above it is correct, so this is a minor slip not a question-killer.

**iter586 defect status: RESOLVED.** Diagnosis is correct (default RANGE peer-lumping is the CAUSE) and the recommended fix is the explicit-ROWS + tiebreaker pair (not the default frame).

---

### Q3 — json_extract_scalar (FRESH)

**Scores:** 5 / 5 / 5 / 5 → **avg 5.0**

- `json_extract_scalar(settings, '$.theme')` returns VARCHAR scalar — correct.
- CAST guidance for typed (BIGINT/BOOLEAN) outputs — correct and actionable.
- Contrast between `json_extract_scalar` (VARCHAR leaf) and `json_extract` (JSON object/array) — accurate.
- NULL-on-missing-path note is correct.

**WebSearch verification — trino.io/docs/467/functions/json.html:**
- `json_extract_scalar` returns "the result value as varchar (string)."
- `json_extract` returns "the result as JSON string."
- Scalar requirement: "the value referenced by json_path must be a scalar (boolean, number or string)."

---

### Q4 — MAP element_at lookup (FRESH)

**Scores:** 5 / 5 / 5 / 5 → **avg 5.0**

- `element_at(tags, 'plan')` — correct.
- COALESCE-for-default guidance — correct and actionable.
- DO-NOT-USE bracket `tags['plan']` (errors on missing key) vs `element_at` (NULL-safe) — directly verified.

**WebSearch verification — trino.io/docs/467/functions/map.html:**
- `element_at`: "Returns value for given key, or NULL if the key is not contained in the map."
- Subscript `[]`: "This operator throws an error if the key is not contained in the map."

---

## Overall

| Q | Avg |
|---|---|
| Q1 | 5.00 |
| Q2 | 4.75 |
| Q3 | 5.00 |
| Q4 | 5.00 |
| **Overall** | **4.9375** |

PASS threshold: overall avg ≥ 3.5. **Result: PASS (4.9375).**

---

## iter586 defect resolution summary

| iter586 defect | Q | iter587 status |
|---|---|---|
| Time-travel clause↔arg-type confusion (`FOR VERSION AS OF TIMESTAMP '…'`) | Q1 | **RESOLVED** — r17 un-confusable signal subsection routed; responder now uses `FOR TIMESTAMP AS OF` with a TIMESTAMP literal and explicitly contrasts to `FOR VERSION AS OF` taking a snapshot_id BIGINT. |
| ROWS-vs-RANGE backwards diagnosis (recommending default RANGE as the fix) | Q2 | **RESOLVED** — r07 symptom→cause→fix + anti-fix callout routed; responder correctly diagnoses default RANGE peer-lumping as the CAUSE and prescribes explicit ROWS + tiebreaker as the FIX. |

Both iter587 reconciles-in-place hit the target. No new defect class surfaced.

---

## iter588 directive

**Default to NO-OP.** Both iter586 defect classes are resolved on the un-confusable-in-the-example signals. Federation row stays at 4.49944/310 (untouched). Discipline > churn.

If the teacher must touch anything, optionally (NON-blocking):
- **r07 fallback line / wherever the nested-window-ban canonical lives (r23)**: a one-line clarification on whether `ORDER BY ROW_NUMBER() OVER (…)` at the top-level statement ORDER BY is a recommended pattern, or whether the safer fallback for "no unique column" is to introduce a row-numbered CTE first. The Q2 fallback line is borderline-ambiguous against the iter569 nested-window-ban canonical. Q2 main fix is correct — this is a minor consistency touch, not a defect.

Otherwise: hold. Re-probe both iter586 defect classes from fresh angles (different wording, different dates / different cumulative metric) in 2-3 iterations to confirm the resolutions stick across question phrasings.
