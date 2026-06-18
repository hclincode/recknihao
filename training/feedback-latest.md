# Judge Feedback — iter1048

**Mode:** extended / DEFAULT-NO-OP durability-breadth sweep. Verified BOTH directions against RAW git-tag 467 source (raw.githubusercontent.com/trinodb/trino/467/docs/...), NOT resources/. No federation probe (hard-locked). Production stack (Trino 467 + Iceberg + Hive Metastore on-prem) — all four answers are plain Trino SQL, stack-compatible.

## Verified-source citations
- **array.md (467):** `all_match(array(T), function(T,boolean)) -> boolean` — true if all match (empty array → true); `array_except(x, y) -> array` — elements in x not in y, dedup. CONFIRMED.
- **datetime.md (467):** `day_of_week()` ranges `1` (Monday) to `7` (Sunday). NO `dayname()` function exists. `format_datetime(timestamp, format)` formats per JodaTime DateTimeFormat. CONFIRMED.
- **JodaTime / docs:** `'EEEE'` = full day-of-week name ("Monday"). CONFIRMED.
- **json.md (467):** NO Postgres `->`/`->>` arrow operators. `json_extract_scalar(json, '$.a.b')` supports nested JSONPath, returns varchar scalar. CONFIRMED.
- **language/types.md (467) — DISPOSITIVE on the Q1 nuance:** "Exact numeric values can be expressed as numeric literals such as `1.1`, and are supported by the `DECIMAL` data type." "Floating-point ... using scientific notation such as `1.03e1` and are cast as `DOUBLE`." → An unsuffixed decimal-point literal like **`100.0` is DECIMAL, NOT DOUBLE.** Only scientific-notation (`100.0e0`) is DOUBLE.

---

## Q1 — price_cents/100 integer-division vs precision
**Scores: Accuracy 4.75 / Completeness 4.875 / Clarity 4.875 / Actionability 4.875 → 4.84375**

Responder: `price_cents/100` is integer division (1999/100=19, toward zero) — CORRECT. Offers `price_cents / 100.0` ("decimal division", "exact decimal precision") and `CAST(price_cents AS decimal(10,2)) / 100`.

**Q1 PRECISION-FRAMING FINDING (directive prior REFUTED by source):** The run-directive flagged the `/100.0` "exact decimal" label as *slightly inaccurate*, asserting `100.0` is a DOUBLE in Trino. **RAW 467 types.md refutes that prior:** an unsuffixed decimal-point literal `100.0` is a **DECIMAL** literal (only scientific-notation `1.03e1` is DOUBLE). Therefore `integer / DECIMAL(4,1)` → DECIMAL division = **exact**, and the responder's "decimal division / exact decimal precision" label is **CORRECT, not a mislabel.** No accuracy deduction for the framing. This is another imported-prior self-error in the directive (same family as GREATEST-NULL, div-by-zero, TIMESTAMP-TZ coercion in MEMORY) — verify-first prevented a false ding. Both `/100.0` and the explicit `CAST(... AS decimal(10,2))/100` are exact and display 19.99. Sound, near-ceiling.

## Q2 — every tag non-empty, no unnest
**Scores: Accuracy 4.875 / Completeness 4.8125 / Clarity 4.8125 / Actionability 4.8125 → 4.828125**

`WHERE all_match(tags, x -> length(x) > 0)` — exact: all_match over the array, lambda tests non-empty, no UNNEST. Alt `cardinality(array_except(tags, ARRAY[''])) = cardinality(tags)` is logically sound (removes empty strings; if none removed, cardinalities match). Minor nuance: array_except dedups, so the cardinality equality could mismatch if `tags` itself contains duplicate non-empty values (dedup shrinks LHS) — the all_match lead is the robust canonical and is what the responder LED with, so this is shading-only on a secondary, not a defect. Sound.

## Q3 — day-of-week NAME distribution
**Scores: Accuracy 4.8125 / Completeness 4.8125 / Clarity 4.875 / Actionability 4.8125 → 4.828125**

`format_datetime(CAST(session_date AS timestamp), 'EEEE')` → full weekday name; correctly notes `day_of_week()` returns 1-7 (Mon-Sun ISO), NO `dayname()` in Trino, the CAST date→timestamp needed for format_datetime, GROUP BY repeats the expression (valid), and sorting by `day_of_week()` number for calendar order. All verified against datetime.md. The "sort by day_of_week() number for calendar order" tip is genuinely useful (alphabetical name sort would be wrong). Sound.

## Q4 — nested JSON $.device.os, arrows, GROUP-BY expression
**Scores: Accuracy 4.9375 / Completeness 4.875 / Clarity 4.875 / Actionability 4.9375 → 4.90625**

Correctly states Trino has NO `->>`/`->` arrows; uses `json_extract_scalar(properties, '$.device.os')` nested path; GROUP BY repeats the expression; CAST-to-int variant for numeric leaf. **Q4 WATCH (r) DURABILITY FINDING:** the responder PROACTIVELY taught that **Trino GROUP BY accepts expressions, not SELECT aliases** — i.e., you must REPEAT the expression in SELECT and GROUP BY. This is exactly the #16533 alias-prohibition behavior, surfaced proactively and accurately on a novel JSON domain. 3rd+ consecutive durability-positive on the JSON GROUP-BY-expression surface (iter1045/1046/1047 lineage) — the iter1044 r13 L3366 LIGHT FIX-A is durably reaching the responder. Watch (r) remains CLOSED / passive-monitor; no recurrence of the alias error or ungrouped-column shape. Near-ceiling.

---

## Overall
| Q | Acc | Comp | Clar | Act | Avg |
|---|---|---|---|---|---|
| Q1 | 4.75 | 4.875 | 4.875 | 4.875 | 4.84375 |
| Q2 | 4.875 | 4.8125 | 4.8125 | 4.8125 | 4.828125 |
| Q3 | 4.8125 | 4.8125 | 4.875 | 4.8125 | 4.828125 |
| Q4 | 4.9375 | 4.875 | 4.875 | 4.9375 | 4.90625 |

**Overall average = 4.8515625 → PASS** (margin +1.35).

Hygiene clean across all 4: `::` cast absent; no QUALIFY / false-semi-join / fabricated-fn / regex-backslash / INTERVAL-quarter-week / OFFSET-before-LIMIT / over-warning / broken-secondary.

## Recommendation
**DEFAULT NO-OP.** No source-verified resource defect; no 2-in-2 same-shape slip. Two findings, both source-resolved and both favorable to the responder:
1. **Q1 precision-framing:** `100.0` is DECIMAL (not DOUBLE) per RAW 467 types.md — responder's "exact decimal" label is CORRECT; directive prior was an imported-prior self-error, no ding applied.
2. **Q4 watch (r):** proactive GROUP-BY-expression-not-alias teaching, durable; keep passive-monitor.

NO resource edit; NO commit; MUST NOT bump state.json (already 1048).
