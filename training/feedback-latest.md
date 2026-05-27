# Feedback — Iter 287 (Extended phase)

Date: 2026-05-27
Topic: Trino federation — Postgres unsupported type handling (Q1 PASS) + Postgres array column mapping (Q2 PASS)

## Results summary

| Question | Topic angle | Score | Pass/Fail |
|---|---|---|---|
| Q1 | Postgres unsupported type handling: IGNORE default silently drops; ENUMs map natively to VARCHAR; CONVERT_TO_VARCHAR fix; JDBC debug logging diagnostic | **4.96** | PASS |
| Q2 | Postgres array mapping: DISABLED default silently drops; AS_ARRAY → ARRAY<T>; AS_JSON for multi-dim; CONTAINS/ANY_MATCH; no pushdown; system.query() @> for GIN index | **4.93** | PASS |

**Iter 287 average: 4.945 — PASS** ✓ Both passed with high scores!

**Topic update**: Trino federation: 4.504/247 → **4.507/249** (PASSED — solidly above threshold)

---

## What worked

### Q1 — Unsupported type handling (4.96)
1. `postgresql.unsupported-type-handling=IGNORE` is the default — verified correct
2. Critical nuance: custom ENUMs map natively to VARCHAR (not via unsupported-type-handling) — correct and important
3. The culprit is likely a DIFFERENT column with hstore/range/composite type — correct reframing
4. `CONVERT_TO_VARCHAR` fix — verified correct value
5. Session property syntax: `app_pg.unsupported_type_handling` (underscore, catalog prefix) — verified correct
6. JDBC debug logging diagnostic (`io.trino.plugin.jdbc=DEBUG`) — verified correct logger name
7. DESCRIBE vs `\d` comparison for finding missing columns — sound diagnostic

### Q2 — Array column mapping (4.93)
1. `postgresql.array-mapping=DISABLED` default — verified correct
2. `AS_ARRAY` → `ARRAY<VARCHAR>` for `TEXT[]` — verified correct
3. `AS_JSON` for multi-dimensional arrays — correct (Trino ARRAY is flat; Postgres arrays aren't)
4. `CONTAINS()` and `ANY_MATCH()` Trino array functions with examples — correct
5. Array predicates do NOT push down to Postgres — verified correct
6. `system.query()` with native `@>` operator for GIN index — correct
7. Session property `app_pg.array_mapping = 'AS_ARRAY'` (underscore, catalog prefix) — correct
8. Iceberg denormalization as long-term pattern for heavy analytics — correct

---

## Errors / gaps (minor — did not block pass)

### Q1
- No mention that `CONVERT_TO_VARCHAR` only works per-column (doesn't solve multi-column unsupported type issues at query level)
- No mention that some types (e.g., `hstore`) need Postgres extensions to be installed

### Q2
- No mention that multi-dimensional arrays (`TEXT[][]`) with `AS_ARRAY` may fail — only safe for 1D arrays; use `AS_JSON` for 2D+

---

## Resource fixes

None needed. Resource 22 covers all these topics correctly.

---

## Suggested iter288 angles (topic PASSED at 4.507/249 — continue solidifying)

1. **Broadcast join hint for CBO override** — when Trino's CBO guesses wrong build/probe side for an Iceberg × Postgres join; `join_distribution_type='BROADCAST'` forces broadcast of the smaller side; when to override vs trust CBO

2. **JDBC connection URL parameters for Postgres federation** — `socketTimeout`, `connectTimeout`, `defaultRowFetchSize`; importance for on-prem federation where network latency exists; how to configure in catalog properties

3. **Trino Postgres catalog: SSL/TLS configuration** — `sslmode=verify-full`, `sslrootcert`, `ssl=true` in JDBC URL; important for on-prem Kubernetes where internal TLS is common

4. **Federation performance: JDBC fetch size impact** — `defaultRowFetchSize=1000` default; increasing for large table scans; tradeoff with memory pressure on Trino workers

5. **Re-test: federate vs ingest with a 5M-row table** — between the "clearly federate" (<10M) and "clearly ingest" (>50M) zones; decision factors (query frequency, staleness tolerance, Postgres replica load)
