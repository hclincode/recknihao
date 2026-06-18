# Judge Feedback — iter1084 (2026-06-18)

**Overall: 3.44 — FAIL** (threshold 3.5; overall average governs, no per-question veto — but two CRITICAL accuracy defects sank the average).

Stack: Trino 467 + Iceberg + Hive Metastore + MinIO + Spark + dbt-trino + OPA.
Verified BOTH directions vs RAW git-tag 467 source + WebSearch. Two source-verified defects (Q2 wrong-shape + factually-wrong dismissal; Q4 invalid GROUP-BY+window). Q1/Q3 clean.

| Q | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|
| Q1 | 4.9 | 4.8 | 4.8 | 4.9 | 4.85 |
| Q2 | 1.5 | 2.0 | 3.0 | 2.0 | 2.13 |
| Q3 | 4.7 | 4.2 | 4.7 | 4.7 | 4.58 |
| Q4 | 1.5 | 2.5 | 3.0 | 1.8 | 2.20 |
| **Overall** | | | | | **3.44** |

---

## Q1 — average resolution days PER ASSIGNEE (4.85, CLEAN — aggregate-intent handled correctly)
`SELECT assignee_id, AVG(date_diff('day', created_at, resolved_at)) AS avg_days_to_resolve FROM support_tickets WHERE resolved_at IS NOT NULL GROUP BY assignee_id;`

CORRECT. This time the responder WRAPPED in `AVG()` AND added `GROUP BY assignee_id`, returning exactly one average per assignee — directly closing the iter1083 Q1 missing-AVG completeness gap from a fresh angle. Verified vs RAW `functions/datetime.md`: `date_diff(unit, ts1, ts2)` returns "timestamp2 - timestamp1 expressed in terms of unit" as a whole-unit integer; 'day' is the right unit, the example `date_diff('day', DATE '2020-03-01', DATE '2020-03-02')` = 1 confirms day-count semantics. `WHERE resolved_at IS NOT NULL` correctly excludes open tickets. Aggregate-per-group intent fully handled. The aggregate-wrapping re-probe from iter1083 is CONFIRMED resolved.

## Q2 — position of 'onboarding' within each row's tags array (2.13, CRITICAL DEFECT — wrong shape + factually-wrong dismissal)
Responder: `... CROSS JOIN UNNEST(tags) WITH ORDINALITY AS t(tag, position) WHERE tag='onboarding'`, dismissing `array_position` as "NOT right here — returns only first match, duplicates collapse."

**The dismissal is FACTUALLY WRONG and the recommended query is the wrong shape.** Verified vs RAW `functions/array.md`: `array_position(x, element)` "Returns the position of the first occurrence of the `element` in array `x` (or 0 if not found)" — 1-based, ONE value per input row. For the question "for each row, what position does 'onboarding' appear at (3rd element → 3)," **`array_position(tags, 'onboarding')` IS the correct per-row answer.** First-occurrence position is precisely what "what position does it appear at" means.

The UNNEST WITH ORDINALITY + WHERE approach is valid SQL but answers a DIFFERENT question and produces a different result shape:
- It explodes each row's array into per-element rows, then `WHERE tag='onboarding'` DROPS every input row that does not contain 'onboarding' (the question asks for a value per row, including absent → 0).
- A row whose tags contain 'onboarding' twice yields TWO output rows instead of one.

CORRECT answer: `SELECT row_id, array_position(tags, 'onboarding') AS onboarding_position FROM events;` (0 when absent, first-occurrence position otherwise). The "duplicates collapse" objection is irrelevant — the question asks for the position it appears AT, which is the first occurrence. Over-engineered wrong-shape recommendation; accuracy scored LOW.

## Q3 — replace 'N/A' with 'No notes provided' (4.58, CLEAN, minor completeness note)
`SELECT replace(notes, 'N/A', 'No notes provided') AS cleaned_notes FROM customers;`

CORRECT. Verified vs RAW `functions/string.md`: `replace(string, search, replace) -> varchar` "Replaces all instances of `search` with `replace` in `string`." The responder's "replaces all occurrences" note is exact. The user explicitly asked for a "simple text substitution" function, so `replace` is the right literal answer.

Minor completeness note (NOT a defect): `replace` substitutes the substring ANYWHERE, so a notes value like "N/A items pending" becomes "No notes provided items pending." If the intent is to replace only the WHOLE-VALUE placeholder, `CASE WHEN notes = 'N/A' THEN 'No notes provided' ELSE notes END` or `COALESCE(NULLIF(notes,'N/A'),'No notes provided')` is more precise. Worth a one-line mention; does not invalidate the answer.

## Q4 — first AND most recent timestamp PER PAGE in one query (2.20, CRITICAL DEFECT — invalid GROUP-BY + window)
Responder: `SELECT page, first_value(timestamp) OVER (PARTITION BY page ORDER BY timestamp) AS first_timestamp, last_value(timestamp) OVER (PARTITION BY page ORDER BY timestamp ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS last_timestamp FROM page_views GROUP BY page;`

**INVALID — does not run.** With `GROUP BY page`, every SELECT expression must be either a grouping key or wrapped in an aggregate. The window functions reference the RAW `timestamp` column, which after GROUP BY is neither a grouping key nor aggregated. Window functions are evaluated AFTER GROUP BY/HAVING over the grouped relation, so `first_value(timestamp)`/`last_value(timestamp)` over the ungrouped raw column raises `'timestamp' must be an aggregate expression or appear in GROUP BY clause` (verified vs SELECT semantics — under GROUP BY, output expressions must be aggregates or grouping columns; window funcs run post-aggregation).

CORRECT and simplest answer — the pure aggregate, NO window functions, NO GROUP BY conflict:
```sql
SELECT page, MIN(timestamp) AS first_timestamp, MAX(timestamp) AS last_timestamp
FROM page_views
GROUP BY page;
```
The user even offered the right fork ("a window function ... or two aggregations?") — two aggregations (MIN/MAX) is the answer. The responder's standalone note that `last_value` needs the `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` full frame is correct in ISOLATION (default frame is RANGE ... CURRENT ROW, which would only reach the current row), but it is moot because the GROUP BY + window-over-raw-column combination is invalid. Accuracy scored LOW.

---

## Source-verified dialect notes
- `array_position(x, element)` — first occurrence, 1-based, 0 if absent, ONE value per row. RAW: https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/array.md  → **Q2: array_position(tags,'onboarding') is the correct per-row answer; the responder's dismissal was wrong; UNNEST WITH ORDINALITY + WHERE is a wrong-shape different-question answer.**
- `replace(string, search, replace)` replaces ALL instances of the substring. RAW: https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/string.md
- `date_diff('day', ts1, ts2)` = whole-day count, ts2 - ts1. RAW: https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/datetime.md
- **Q4: GROUP BY + window-over-raw-ungrouped-column is INVALID; the correct form is `MIN(timestamp)`/`MAX(timestamp)` with `GROUP BY page` (no window functions).** Verified vs SELECT/GROUP BY semantics (window funcs evaluate after GROUP BY over the grouped relation): https://trino.io/docs/current/sql/select.html

## Recommendation
FAIL at 3.44 (−0.06). Two distinct CRITICAL defects, both in the over-engineering/wrong-fork family but here they are the PRIMARY recommended answers, not asides:
- **Q2** is the more concerning: responder ACTIVELY DISMISSED the correct simple built-in (`array_position`) with a false rationale and substituted a wrong-shape UNNEST. This is the OPPOSITE of the usual "nails the lead, appends a broken alt" pattern — here the lead itself is wrong. Re-probe "position of an element within an array" from a 2nd angle (e.g. integer array, or explicitly "return 0 if not present") to check whether the responder reaches for `array_position`. If it recurs, have the teacher grep resources for any content that steers element-position questions toward UNNEST WITH ORDINALITY over array_position — this may be a findability/resource root cause, not a pure responder slip.
- **Q4** GROUP-BY + window-over-raw-column is a recurring confusion family (cf. iter1013 ORDER-BY-ungrouped). The MIN/MAX-vs-window fork was handed to the responder and it picked the wrong, non-running fork. Re-probe a "first AND last value per group" Q to confirm the responder reaches for MIN/MAX (or a clean window form in a subquery WITHOUT a conflicting GROUP BY).

MUST NOT bump state.json (teacher already did).
