# Judge Feedback — iter756 (FIX-A verification: mode re-probe + IF/to_iso8601 bulletproof + variable-shape reformat)

All four dialect claims verified against trino.io/docs/467 (aggregate.html, conditional.html, datetime.html, string.html) on 2026-06-09. No docs-correct form penalized.

## Per-question scores

### Q1 — MODE RE-PROBE: most common event_type per session
Answer: `WITH event_counts AS (SELECT session_id, event_type, COUNT(*) AS cnt FROM events GROUP BY session_id, event_type) SELECT session_id, max_by(event_type, cnt) AS most_common_event FROM event_counts GROUP BY session_id`. Explained max_by picks the event_type at the highest count = the mode; noted arbitrary()/MAX() would NOT give most-frequent.

- DOCS VERIFY: aggregate.html — `max_by(x, y)` "Returns the value of x associated with the maximum value of y over all input values." The count-subquery + `max_by(event_type, cnt)` GROUP BY session_id idiom is the correct exact mode-per-group pattern in Trino 467. Runs correctly. Responder used the NEW canonical (NOT approx_most_frequent-as-scalar) and correctly contrasted arbitrary/MAX.
- Accuracy 5 | Completeness 5 | Clarity 5 | Actionability 5 → **avg 5.00**
- This is the 1st post-fix datapoint on mode and it is fully clean. The iter755 RESOURCE-DEFECT (r23:879 routing "most common value per group" → approx_most_frequent with no MAP-not-scalar note, no mode canonical) is closed in practice: the responder now reaches the max_by-over-COUNT(*) canonical and does NOT reproduce the approx_most_frequent-as-scalar error. Tie-break is arbitrary (acceptable; deterministic ROW(...) tiebreaker is a documented nuance, not required by the question).

### Q2 — IF RE-PROBE: 'trending' if score >= 75 else 'standard'
Answer: `IF(score >= 75, 'trending', 'standard') AS category`. Explained IF(cond, true, false) = compact CASE; IF for two outcomes, CASE for 3+.

- DOCS VERIFY: conditional.html — `if(condition, true_value, false_value)` "Evaluates and returns true_value if condition is true, otherwise evaluates and returns false_value." Native, CASE-equivalent. Correct.
- Accuracy 5 | Completeness 5 | Clarity 5 | Actionability 5 → **avg 5.00**
- 2nd consecutive clean IF() datapoint (after iter755 Q1). No `::`-cast slip. IF()/CASE two-way-vs-multi-branch routing correct.

### Q3 — to_iso8601/from_iso8601 RE-PROBE: parse "2026-06-09T08:45:00Z" and filter to past 30 days
Answer: `WHERE from_iso8601_timestamp(shipment_timestamp) > current_timestamp - INTERVAL '30' DAY`. Explained from_iso8601_timestamp parses ISO-8601 → timestamp-with-tz, then compares to current_timestamp - INTERVAL.

- DOCS VERIFY: datetime.html — `from_iso8601_timestamp(string)` → `timestamp(3) with time zone`, parses "...Z" correctly; `current_timestamp` is also `timestamp(3) with time zone`, so the INTERVAL '30' DAY comparison is type-compatible. Correct and runs.
- Accuracy 5 | Completeness 5 | Clarity 5 | Actionability 5 → **avg 5.00**
- 2nd consecutive clean from_iso8601/to_iso8601 datapoint (after iter755 Q2). The parse-back direction is now exercised cleanly.

### Q4 — REFORMAT RE-PROBE (variable-shape): "LastName, FirstName" → "FirstName LastName"
Answer: `split_part(full_name, ',', 2) || ' ' || split_part(full_name, ',', 1) AS flipped_name`, with `format('%s %s', TRIM(...), TRIM(...))` alternative. Explained split_part(...,1)=before comma, (...,2)=after, TRIM removes the space, || rejoins. Did NOT use regexp_replace capture-group.

- DOCS VERIFY: string.html — `split_part(string, delimiter, index)` → varchar, 1-based, returns the nth field; `||` valid for varchar. `split_part(full_name,',',2)` returns " John" (leading space from ", ") and `split_part(full_name,',',1)` returns "Smith", so the BARE `||` form yields " John Smith" (leading space). The `format('%s %s', TRIM(...), TRIM(...))` variant the responder also supplied is fully correct and clean.
- JUDGMENT: split_part is a CORRECT, idiomatic answer for a single-delimiter flip — arguably cleaner than regexp_replace here. NOT a miss; it is a valid alternative tool. The leading-space nuance IS addressed by the responder's TRIM'd format() variant, which is the fully-correct primary-quality option.
- Minor ding: the bare `||` form is presented alongside the TRIM form without explicitly calling out that the bare form leaves a leading space on the first name — a reader who copies the first line gets " John Smith". The TRIM variant fixes it, but the contrast is implicit rather than stated.
- Accuracy 5 | Completeness 4.5 | Clarity 4.5 | Actionability 4.5 → **avg 4.625**

## Overall

| Q | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|
| Q1 | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | 5 | 5 | 5 | 5 | 5.00 |
| Q3 | 5 | 5 | 5 | 5 | 5.00 |
| Q4 | 5 | 4.5 | 4.5 | 4.5 | 4.625 |

**Overall avg = (5.00 + 5.00 + 5.00 + 4.625) / 4 = 4.906 → 4.91 PASS** (threshold 3.5; overall governs, no single-Q veto).

## Capability status

- **mode — CLOSED.** 1st clean post-fix datapoint (Q1). The iter755 RESOURCE-DEFECT is resolved; responder reaches the max_by-over-COUNT(*) canonical and correctly avoids approx_most_frequent-as-scalar. Re-probe once more in iter757 from a different phrasing to declare BULLETPROOFED (per "two angles" rule — only one clean datapoint so far).
- **IF() — BULLETPROOFED.** 2nd consecutive clean datapoint (iter755 Q1 + iter756 Q2), different phrasings (in-stock/sold-out vs trending/standard). No `::` slip. Closed and durable.
- **to_iso8601 / from_iso8601_timestamp — BULLETPROOFED.** 2nd consecutive clean datapoint (iter755 Q2 to_iso8601 serialize + iter756 Q3 from_iso8601 parse-back). Both directions exercised. Closed and durable.
- **string-reformat — COVERED / effectively BULLETPROOFED.** Capability proven across tools and shapes: iter754 Q1 regexp_replace `$N` capture-group (5.00, order# shape), iter753/755 substr+|| (fixed-width), iter756 split_part (single-delimiter variable-shape). All correct, all dialect-clean. split_part is a legitimate (arguably cleaner) answer for a single-delimiter flip, so Q4 is NOT a regex miss.

## Flag for iter757

No new gap or defect surfaced. Designation: **DEFAULT NO-OP / durability-breadth re-probe.**
- Re-probe **mode** ONCE more (different phrasing, e.g. "most-ordered product per customer" or "most-used feature per user") to convert CLOSED → BULLETPROOFED (2nd angle, per two-angles rule).
- One dedicated **regexp_replace multi-capture REORDER** re-probe that split_part/substr CANNOT cleanly do — e.g. "ERR:404:timeout" → "timeout (404)" (reorder groups, drop a piece, add literals). Forces the `$N`-capture-group path specifically. iter754 already demonstrated the `$N` form cleanly (5.00), so this is confirmation-of-coverage, not gap-closure — low priority.
- 2 fresh durability-breadth picks from the standing inventory.
- Do NOT re-edit r23 §3.1D mode canonical, r23 §3.1E IF, r27 §4.2 to_iso8601, or r27 §4.3A reformat (clean/perfect — iter693 churn-risk).

Minor (Q4, optional, non-blocking): co-locate one line at the split_part/reformat resource noting that the BARE `||` flip of "Last, First" leaves a LEADING SPACE on the first name (from ", "), so TRIM (or the format()+TRIM variant) is the safe default. Pure additive; do NOT rewrite the working split_part/format canonical.
