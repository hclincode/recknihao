# Judge Feedback — iter1079 (2026-06-18)

Stack: Trino 467 + Iceberg + Hive Metastore + MinIO + Spark + dbt-trino + OPA.
Verified BOTH directions against RAW git-tag 467 source (dispositive over rendered HTML).

## Overall: 4.30 PASS (overall average governs; no per-question veto)

One source-verified DIALECT DEFECT in Q1 (Spark-spillover `DESCRIBE TABLE`). Q2/Q3/Q4 clean.

---

## Q1 — check a column's actual data type before querying — **2.69**

**Responder answer:** `DESCRIBE TABLE iceberg.schema.users;` … "works whether you're running in Spark SQL or Trino 467."

**VERDICT: `DESCRIBE TABLE <name>` is NOT valid Trino 467 — Spark-spillover dialect defect.**

Source-verified:
- `sql/describe.md` synopsis is exactly **`DESCRIBE table_name`** — NO `TABLE` keyword. The doc states DESCRIBE "is an alias for SHOW COLUMNS."
  - https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/sql/describe.md
- `language/reserved.md`: **`TABLE` is a reserved keyword** (reserved in SQL:2016 and SQL-92). Because TABLE is reserved and the DESCRIBE grammar takes a qualified name directly, `DESCRIBE TABLE iceberg.schema.users` parse-errors (`mismatched input 'TABLE'`).
  - https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/language/reserved.md
- `DESCRIBE TABLE <name>` is the **Spark SQL / Hive** form. The responder's claim that it "works whether you're running in Spark SQL or Trino 467" is wrong for the Trino half — exactly the Spark-spillover trap.

**Correct Trino 467 forms** (any of):
- `DESCRIBE iceberg.schema.users` (no TABLE keyword)
- `SHOW COLUMNS FROM iceberg.schema.users` (synopsis `SHOW COLUMNS FROM table [ LIKE pattern ]`; returns Column/Type/Extra/Comment — verified in `sql/show-columns.md`)
- `SELECT column_name, data_type FROM iceberg.information_schema.columns WHERE table_schema='schema' AND table_name='users'`
- Per-value: `typeof(signup_date)` returns the runtime type of the value (useful to confirm whether it materialized as varchar vs date).

The shape of the answer (read the data_type column) and the underlying intent are right, and the result columns described match SHOW COLUMNS output. But the headline statement parse-errors in Trino, so Accuracy is heavily docked and Actionability suffers (engineer who copy-pastes gets a parse error). Mitigant: information_schema / DESCRIBE-without-TABLE is well covered elsewhere; this is a per-instance Spark-spillover slip, not a known resource gap.

- Accuracy 2 · Completeness 3 · Clarity 3 · Actionability 2.75 → **2.69**

---

## Q2 — dedupe an array without unnesting — **4.81**

`array_distinct(tags) AS unique_tags` + `cardinality(array_distinct(tags))` for the count.

Verified `functions/array.md`: `array_distinct(x) -> array` "Remove duplicate values from the array x"; `cardinality(x) -> bigint` returns the array size. Result stays an array, no UNNEST/re-aggregate — exactly the ask. "Preserves first-occurrence order" is the documented/observed behavior. Clean.

- Accuracy 5 · Completeness 4.75 · Clarity 4.75 · Actionability 4.75 → **4.81**

## Q3 — events in even-numbered hours — **4.81**

`WHERE EXTRACT(HOUR FROM event_timestamp) % 2 = 0`.

Verified `functions/datetime.md`: EXTRACT supports HOUR (mapped to `hour`), and `hour(x)` "Returns the hour of the day from x. The value ranges from 0 to 23." The `%` modulo operator works on the resulting bigint; `% 2 = 0` → even, `% 2 = 1` → odd, correctly stated. `hour(event_timestamp) % 2 = 0` is an equivalent shorthand (optional). No giant CASE needed. Clean.

- Accuracy 5 · Completeness 4.75 · Clarity 4.75 · Actionability 4.75 → **4.81**

## Q4 — "Smith, John" display name — **4.88**

`concat_ws(', ', last_name, first_name)`.

Verified `functions/string.md`: `concat_ws(string0, string1, ..., stringN) -> varchar` "concatenation … using string0 as a separator"; "Any null values provided in the arguments after the separator are skipped." So a NULL first_name/last_name yields no dangling comma — responder's NULL-skip note is exactly correct. Note (not docked): if `string0` (the separator) itself is null the whole result is null — not relevant here. Cleaner than `||`/concat as asked. Clean.

- Accuracy 5 · Completeness 4.75 · Clarity 5 · Actionability 4.75 → **4.88**

---

## Source-verified defect log
- **Q1: `DESCRIBE TABLE <name>` invalid in Trino 467 (Spark-spillover).** Trino form is `DESCRIBE <name>` / `SHOW COLUMNS FROM <name>` / `information_schema.columns` / `typeof()`. TABLE is reserved → parse error. The "works in Spark SQL or Trino 467" cross-engine claim is the root error.

## Imported-prior / regression checks (none tripped)
No `::`/QUALIFY/false-semi-join/fabricated-fn/regex-backslash/INTERVAL-quarter-week/OFFSET-before-LIMIT/over-warning/broken-secondary patterns. Q2/Q3/Q4 functions all verified to EXIST and behave as claimed.

## Recommendation
PASS at 4.30 (margin +0.80). The only defect is the Q1 `DESCRIBE TABLE` Spark-spillover — a dialect slip on the SQL keyword, not an absent canonical (DESCRIBE/SHOW COLUMNS/information_schema are covered). Treat as a per-instance re-probe candidate: re-ask "how to check a column type in Trino" from a 2nd angle to confirm whether the responder reliably drops the TABLE keyword, before considering any defang. Do NOT churn resources on a single slip. MUST NOT bump state.json (already 1079).
