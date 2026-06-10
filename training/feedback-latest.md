# Judge Feedback — iter891

**Verdict: PASS** — overall average **4.94 / 5**. All four answers correct and Trino-467-accurate. **The iter890 json_exists fix LANDED in Q1.**

Dialect facts verified against trino.io/docs/467 (NOT resources/): functions/json.html (JSON_EXISTS), functions/conversion.html (try_cast), functions/conditional.html (try), functions/window.html (row_number), functions/string.html (length), functions/math.html (abs).

---

## Q1 — Distinguish JSON key ABSENT vs PRESENT-but-null  (iter890 Q3 re-probe)

**Scores:** Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 — **avg 5.00**

**(a) FIX LANDED — CONFIRMED.** The responder now LEADS with `json_exists(settings, 'strict $.notifications')` as the key-existence test and gives the two split queries:
- key-present-but-null = `json_exists(...) = true AND json_extract_scalar(...) IS NULL`
- key-absent = `json_exists(...) = false`

It explicitly explains that `json_extract_scalar(...) IS NOT NULL` *conflates* both cases (the exact iter890 defect) and that strict mode makes `json_exists` return false for an absent key. This is no longer the conflating-only answer of iter890.

**Verified vs trino.io/docs/467 functions/json.html:**
- `JSON_EXISTS(json_input [FORMAT JSON ...], json_path [PASSING ...] [{TRUE|FALSE|UNKNOWN|ERROR} ON ERROR])` — "The returned value is `true` if the path returns a non-empty sequence, and `false` if the path returns an empty sequence."
- Default = **FALSE ON ERROR**.
- Strict mode: accessing a non-existent member is a **structural error** → path evaluation fails → with default FALSE ON ERROR → **false** for an absent key.
- A present key whose value is `null` yields a **non-empty sequence** (containing the JSON null) → **true**.

So `json_exists(json, 'strict $.key')` = present-even-null TRUE / absent FALSE — exactly what the responder said. No defect.

---

## Q2 — Validate text is a valid number before casting (skip "N/A"/empty)

**Scores:** Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 — **avg 5.00**

`try_cast(session_duration_text AS DECIMAL(10,2)) IS NOT NULL` to filter valid numbers; `try(CAST(...)/60)` for compound expressions; clean try_cast-vs-try distinction.

**Verified vs trino.io/docs/467:**
- conversion.html: `try_cast` — "Like `cast()`, but returns null if the cast fails." Returns NULL, does not error. Correct.
- conditional.html: `try()` — "Evaluate an expression and handle certain types of errors by returning `NULL`." Catches division by zero, invalid cast or function argument, numeric value out of range. The responder's framing (use `try_cast` for a plain cast, `try()` to wrap a larger expression that may div-by-zero / overflow) is accurate.

---

## Q3 — Return the actual longest subject TEXT per team

**Scores:** Accuracy 5 / Completeness 4 / Clarity 5 / Actionability 5 — **avg 4.75**

`ROW_NUMBER() OVER (PARTITION BY team_id ORDER BY LENGTH(subject) DESC) AS rn` in a subquery, outer `WHERE rn = 1`; returns the full row; tie-break `, ticket_id DESC`.

**Verified vs trino.io/docs/467:**
- window.html: `row_number() → bigint` — "Returns a unique, sequential number for each row ... according to the ordering of rows within the window partition." So `rn = 1` = longest-subject row per team. Correct.
- string.html: `length(string) → bigint` — "Returns the length of string in characters." Correct char-count metric.
- Window functions can't sit in WHERE in Trino 467 (no QUALIFY), so the subquery + outer `WHERE rn = 1` is the right shape. Correct.

Minor completeness nuance only (NOT a defect): `max_by(subject, length(subject))` GROUP BY team_id is a valid one-liner alternative that returns the text directly. ROW_NUMBER is fully correct and also returns the rest of the row, so this costs one completeness point at most.

---

## Q4 — Absolute dollar difference (always positive)

**Scores:** Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 — **avg 5.00**

`abs(current_month_rev - prior_month_rev)`; correctly notes operands must be numeric and to CAST to DECIMAL first if stored as text.

**Verified vs trino.io/docs/467 math.html:** `abs(x)` — "Returns the absolute value of `x`." Correct. The CAST caveat is a genuinely useful production note (revenue often lands as varchar from JSON/CSV).

---

## Overall

| Q | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|
| Q1 | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | 5 | 5 | 5 | 5 | 5.00 |
| Q3 | 5 | 4 | 5 | 5 | 4.75 |
| Q4 | 5 | 5 | 5 | 5 | 5.00 |

**Overall average = 4.94 — PASS** (threshold 3.5; overall average governs, no per-question veto).

No claim flagged as a defect (iter882 lesson observed — every responder claim verified correct against the authoritative source before any recommendation).

## iter892 recommendation: **DEFAULT NO-OP**

All four answers are clean and the json_exists fix from iter891 landed cleanly in Q1 (responder now leads with `json_exists(json,'strict $.key')` and no longer relies on the conflating `json_extract_scalar IS NOT NULL`). No FIX-A needed. Recommend a NO-OP durability sweep for iter892: re-probe the json_exists distinction from a second phrasing (e.g. a MAP/ROW key-existence variant, or a `lax` vs `strict` path-mode angle) plus 3 fresh adjacent probes. No escalation.
