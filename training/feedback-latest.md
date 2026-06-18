# Judge Feedback — iter1085 (2026-06-18)

**Overall: 4.83 / 5 — PASS** (threshold 3.5; overall average governs, no per-question veto)

Stack: Trino 467 + Iceberg + Hive Metastore + MinIO + Spark + dbt-trino + OPA.

Verified BOTH directions against RAW git-tag 467 source:
- functions/array.md — https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/array.md
- functions/aggregate.md — https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/aggregate.md
- functions/window.md — https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/window.md

Clean sweep this iteration. The two CRITICAL iter1084 defects did NOT recur. No dialect defects found.

---

## Q1 — position of 'shipped' in status_history array — **5.00**

`SELECT order_id, array_position(status_history, 'shipped') AS position_of_shipped FROM orders`

**FIX-A REACHED / iter1084-Q2 RE-PROBE CONFIRMED RESOLVED.** array.md VERIFIED `array_position(x, element) -> bigint` "Returns the position of the first occurrence of the `element` in array `x` (or 0 if not found)" — 1-based, ONE value per input row, no explosion. Exactly the right tool for "what position does 'shipped' show up at, one number per order."

Contrast iter1084 Q2, which WRONGLY dismissed `array_position` ("returns only first match, duplicates collapse") and reached for `CROSS JOIN UNNEST(...) WITH ORDINALITY ... WHERE`. This iteration the responder used `array_position` directly AND correctly stated the 1-based / 0-if-absent / one-row-per-row semantics, AND did NOT reach for UNNEST WITH ORDINALITY. The r07 L156/L158/L176/L186 array_position-vs-WITH-ORDINALITY disambiguator added in iter1084 is doing its job. Accuracy 5, Completeness 5, Clarity 5, Actionability 5.

## Q2 — first AND most recent login per user, one row — **4.50**

```sql
SELECT DISTINCT user_id,
  FIRST_VALUE(login_at) OVER (PARTITION BY user_id ORDER BY login_at
    ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS first_login,
  LAST_VALUE(login_at) OVER (PARTITION BY user_id ORDER BY login_at
    ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS most_recent_login
FROM logins
```

**VALID — iter1084-Q4 INVALID PATTERN DID NOT RECUR.** The iter1084 Q4 failure was window functions MIXED WITH a `GROUP BY` (analyzer error: raw column "must be an aggregate or appear in GROUP BY"). This query has NO GROUP BY — window functions evaluate per row over the full partition, then `SELECT DISTINCT` collapses the identical per-user rows. No analyzer error; returns the correct earliest/latest login per user. window.md VERIFIED first_value/last_value exist; the explicit full frame `UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` correctly forces first_value=earliest and (critically) last_value=latest — the explicit full frame is exactly what defeats last_value's default-frame trap.

NOT a defect. Minor Completeness/optimality note only: the cleaner canonical is `SELECT user_id, MIN(login_at) AS first_login, MAX(login_at) AS most_recent_login FROM logins GROUP BY user_id` — one pass, no window, no DISTINCT. The window+DISTINCT form is correct but more verbose and does two window sorts + a distinct. Accuracy 5, Completeness 4 (didn't surface the simpler MIN/MAX GROUP BY fork), Clarity 4.5, Actionability 4.5.

## Q3 — running cumulative revenue total — **4.94**

`SUM(total_revenue) OVER (ORDER BY report_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative_revenue`

Textbook-correct running total. window.md VERIFIED SUM is usable as a window function; the explicit `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` frame produces a cumulative total up to and including each row (and correctly avoids the RANGE-frame tie-lumping trap, matching the r07 L1796 ROWS-vs-RANGE guard). Outer ORDER BY report_date for stable display. Clean. Accuracy 5, Completeness 5, Clarity 5, Actionability 4.75.

## Q4 — comma-separated assignee names per team — **4.88**

`listagg(assignee_name, ', ') WITHIN GROUP (ORDER BY assignee_name) AS assignees ... GROUP BY team_id`

aggregate.md VERIFIED `LISTAGG(expression [, separator]) WITHIN GROUP (ORDER BY ...)` exists in 467, "returns the concatenated input values, separated by the separator string." WITHIN GROUP (ORDER BY) is the required/correct syntax. The responder did NOT use DISTINCT — correct, since listagg has NO DISTINCT support (a `DISTINCT` would parse-error; dedup would require `array_join(array_agg(DISTINCT ...), ', ')`). Clean. Accuracy 5, Completeness 4.75 (could have noted the dedup fork if duplicates per team are expected), Clarity 5, Actionability 5.

---

## Verdict

Overall 4.83 PASS, margin +1.33. Both critical iter1084 re-probes confirmed clean: Q1 array_position FIX-A reached, Q2 window+DISTINCT confirmed VALID (no GROUP-BY-mixing analyzer error). No `::`/QUALIFY/false-semi-join/fabricated-fn/regex-backslash/INTERVAL-quarter-week/OFFSET-before-LIMIT/over-warning/broken-secondary patterns. RECOMMENDATION = DEFAULT NO-OP; no resource edit; no commit beyond the score line. MUST NOT bump state.json (already 1085).
