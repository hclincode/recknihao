# iter672 — Judge feedback

Iteration: 672
Phase: extended
Mode: end-of-iteration (4 Qs, one summary feedback)

## Verification baseline (Trino 467 docs, WebFetch 2026-06-08)

- `json_extract_scalar(json, json_path) -> varchar` — accepts a VARCHAR string containing JSON directly; returns the leaf scalar as VARCHAR. Confirmed at trino.io/docs/467/functions/json.html.
- `try_cast(x AS type)` — "Like cast(), but returns null if the cast fails." Confirmed at trino.io/docs/467/functions/conversion.html. `try(CAST(...))` is the general-purpose form that wraps any expression (covers the larger sub-expression rather than only the cast), so the responder's "equivalent" claim is fair for the single-cast case the question asks about.
- `contains(x, element) -> boolean` — IS the Trino array-membership function; "There is no separate array_contains() function in Trino" (docs verbatim). Confirmed at trino.io/docs/467/functions/array.html.
- `transform(array(T), function(T, U)) -> array(U)` — HOF, applies lambda per element. The case-insensitive idiom `contains(transform(roles, x -> lower(x)), lower('admin'))` is valid Trino 467.
- `approx_distinct(x) -> bigint` — default standard error 2.3%; 2-arg form bounds `[0.0040625, 0.26000]`. Confirmed at trino.io/docs/467/functions/aggregate.html.

All four answers are dialect-correct.

---

## Per-question scores (Accuracy / Completeness / Clarity / Actionability, 1-5)

### Q1 — JSON field extraction + count (plan_type from raw_payload)

Answer: `SELECT json_extract_scalar(raw_payload, '$.plan_type') AS plan_type, COUNT(*) AS event_count FROM events GROUP BY json_extract_scalar(raw_payload, '$.plan_type') ORDER BY event_count DESC;`

- Accuracy: 5 — Correct Trino 467 function, correct JSONPath, correct return-type (VARCHAR). Direct VARCHAR-column input is valid per docs. GROUP BY repeats the same scalar expression (Trino does not allow SELECT-alias in GROUP BY for the aliased expression — repeating the expression is the right form).
- Completeness: 5 — Covers extraction, aggregation, grouping, ordering; nested-path note `$.user.id` is a useful extension.
- Clarity: 5 — Clean single statement, explanation matches the SQL.
- Actionability: 5 — Engineer can paste-and-run on their `events` table immediately.
- Q1 average: 5.00

### Q2 — try_cast over dirty VARCHAR (SUM only valid numbers, 'N/A' must not error)

Answer: `SELECT SUM(try_cast(user_input_amount AS DECIMAL(10,2))) AS total_amount FROM user_input WHERE user_input_amount IS NOT NULL;`

- Accuracy: 5 — try_cast returns NULL on failure, SUM skips NULL. Behaves as advertised on 'N/A' rows. `try(CAST(...))` equivalence note is accurate for this single-cast shape.
- Completeness: 5 — Handles real NULLs (`IS NOT NULL`) AND junk strings (try_cast). Notes the try() alternative.
- Clarity: 5 — Tight, single statement; the WHY of each piece is stated.
- Actionability: 5 — Drop-in for the engineer's exact column.
- Q2 average: 5.00

Minor nit (not score-affecting): the `WHERE user_input_amount IS NOT NULL` filter is technically redundant because try_cast(NULL AS DECIMAL) is NULL and SUM already ignores NULL. Including it is harmless and arguably clearer; some teams prefer to drop the predicate for full-scan simplicity. No accuracy impact either way.

### Q3 — Array membership (`roles` contains 'admin')

Answer: `SELECT user_id FROM users WHERE contains(roles, 'admin');`

- Accuracy: 5 — `contains(array, element) -> boolean` is the canonical Trino 467 idiom. Explicit inoculation that array_contains is NOT a Trino function (Spark/Hive form) matches docs.
- Completeness: 5 — Notes exact + case-sensitive default and a case-insensitive variant `contains(transform(roles, x -> lower(x)), lower('admin'))`. Avoids the UNNEST anti-pattern.
- Clarity: 5 — One-liner core, clean reasoning.
- Actionability: 5 — Engineer knows exactly which function and how to switch to case-insensitive.
- Q3 average: 5.00

### Q4 — approx_distinct per day

Answer: `SELECT event_date, approx_distinct(visitor_id) AS approx_dau FROM events GROUP BY event_date ORDER BY event_date;`

- Accuracy: 5 — Correct function, correct return type (bigint), correct default standard error (~2.3% — exact docs figure). The 10-50x speedup claim is order-of-magnitude correct for HLL vs exact distinct on huge cardinalities (workload-dependent, presented as a directional claim rather than a guarantee).
- Completeness: 5 — Covers the per-day group, the HLL mechanism, and the determinism caveat (dashboards OK, billing/customer-facing requires exact COUNT(DISTINCT)).
- Clarity: 5 — Single statement, clean trade-off framing.
- Actionability: 5 — Engineer can run on a huge events table; knows when NOT to use it.
- Q4 average: 5.00

---

## Overall

- Q1: 5.00
- Q2: 5.00
- Q3: 5.00
- Q4: 5.00
- Overall average: 5.00 — STRONG PASS (>= 3.5)

No weak answers to flag. All four answers are dialect-correct against trino.io/docs/467, complete, clear, and immediately runnable in the prod stack (Trino 467 + Iceberg, Hive Metastore, MinIO).

## Teacher feedback

iter672 was a CLEAN NO-OP iteration and the four-Q dialect probes confirm the no-edit decision was correct: array `contains`, JSON `json_extract_scalar`, `try_cast` / try(), and `approx_distinct` are all canonically present, findable, and dialect-accurate in resources/. No false-claim defects surfaced, no Spark/Hive forms leaked into Trino contexts.

Recommendation for iter673: **DEFAULT NO-OP / durability-breadth**. Continue the additive-only posture — keep r22 federation HARD LOCK, keep the iter671 ts-diff FIX-A banner and Pattern B-Session at r23:1221+ / r07:1860 untouched, and keep the MoR-vs-CoW / DML-surface / rollback-CALL-467-form / DataSize-unit-suffix / ROWS-vs-RANGE / day_of_week-name locks holding. If iter673 grep-verifies four fresh adjacent areas with NO verified-false claims, repeat the NO-OP pattern; do not manufacture churn. The federation topic is the only remaining gate (4.49944 vs 4.5 threshold, 310 datapoints) — only probe federation with bulletproofed angles per the project_all_topics_passed memory.
