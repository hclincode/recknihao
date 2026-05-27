# Iter 74 Q2 — Judge Score

**Question**: Postgres `TEXT[]` and `INT[]` array columns being synced to Iceberg. Does Parquet support arrays natively or must they be stringified? How to represent in Iceberg schema? How to query in Trino for array membership (is `ANY(tags)` like Postgres valid, or different syntax)?

**Answer file**: /Users/hclin/github/recknihao/training/answers/iter74-q2.md

---

## Scoring

| Dimension | Score | Reasoning |
|---|---|---|
| **Completeness** | 5 | All five required points hit: (1) Parquet/Iceberg native array support, (2) Spark ingest parsing of Postgres `{}` string via `regexp_replace`+`split` and `from_json`, (3) `contains()` is correct (not `= ANY`), (4) `UNNEST` expands rows vs `contains` for filtering, (5) performance — no per-element Parquet stats, selective-flattening recommendation. Comparison table summarizes well. |
| **Accuracy** | 4 | Verified against Trino docs: `contains(array, element)` is correct, `ARRAY(VARCHAR)` DDL syntax is correct in Trino. Minor issues: (a) Prose says `ARRAY<element_type>` (Spark/Hive notation) while DDL example uses `ARRAY(VARCHAR)` (Trino notation) — inconsistent but each is correct in its own context. (b) Comment "Find rows where any score exceeds a threshold" with `WHERE contains(scores, 100)` is mislabeled — `contains` is exact equality, not "exceeds"; the follow-up UNNEST example is correct. (c) "Parquet statistics are maintained at the array level" is slightly hand-wavy but partially redeemed in the Performance section. None of these is a major correctness failure. |
| **Clarity** | 5 | Strong structure: question framing, native-support claim, Iceberg schema, Trino querying, performance, summary table. Code examples are runnable and well-commented. Explicit "Postgres `= ANY` does NOT work in Trino" answers the SaaS engineer's exact question. JSONB analogy in performance section is helpful for a SaaS engineer. |
| **No-hallucination** | 5 | No fabricated functions or syntax. `contains`, `cardinality`, `UNNEST`, `from_json`, `regexp_replace`, `split` all exist as documented. `ARRAY(VARCHAR)` and `ARRAY(INTEGER)` are valid Trino types. Iceberg partitioning syntax `ARRAY['day(event_date)']` is correct. JDBC fetchsize property exists. |

**Average**: (5 + 4 + 5 + 5) / 4 = **4.75**

**Pass threshold (>= 3.5)**: PASSED

---

## Verification notes (WebSearch)

- Confirmed Trino `contains(array, element) -> boolean` is the standard array membership function ([Trino array functions](https://trino.io/docs/current/functions/array.html)).
- Confirmed Trino Iceberg DDL syntax `ARRAY(VARCHAR)` matches official examples ([Trino Iceberg connector](https://trino.io/docs/current/connector/iceberg.html)).
- Confirmed Spark `regexp_replace` + `split` is a valid (if not the only) approach for parsing Postgres `{a,b,c}` array-as-string output via JDBC.

## Production environment fit

- Stack matches: Spark ingestion -> Iceberg on MinIO -> Trino 467 query.
- No cloud-only services recommended.
- Trino 467 supports `contains`, `UNNEST`, `cardinality`, `ARRAY(VARCHAR)` DDL — all current.

## Feedback for teacher

The Postgres-arrays-to-Iceberg topic is well-covered. Two small nits to consider adding to resources for future questions:

1. Clarify when prose should use Spark/Hive `ARRAY<T>` notation vs Trino `ARRAY(T)` notation — engineers will see both and may copy the wrong one into the wrong tool.
2. The "any score exceeds a threshold" snippet conflates membership with comparison; future resources could explicitly contrast `contains` (equality) vs `any_match(array, x -> x > 100)` for predicate-on-elements.

No urgent resource gap. Topic continues to PASS comfortably.
