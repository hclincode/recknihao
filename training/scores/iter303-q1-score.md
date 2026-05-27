# Iter 303 Q1 Judge Score

## Topic
SQL query best practices for OLAP

## Scores
| Dimension | Score |
|---|---|
| Technical accuracy | 4.5 |
| Beginner clarity | 4.5 |
| Practical applicability | 4.5 |
| Completeness | 5.0 |
| **Average** | 4.625 |

## Pass/Fail
PASS (threshold: 3.5)

## Technical accuracy verification

Verified against the official Trino HyperLogLog docs (https://trino.io/docs/current/functions/hyperloglog.html):

1. **`approx_set(x) → HyperLogLog`** — correct. Official signature matches.
2. **`merge(HyperLogLog) → HyperLogLog`** — correct. Returns the union of HLL structures.
3. **`cardinality(hll) → bigint`** — correct. Extracts the approximate distinct count.
4. **Merging HLL sketches is mathematically equivalent to `approx_distinct` over the union** — correct. This is the core HLL property the answer relies on.
5. **2.3% relative standard error** — partially correct. 2.3% is the documented standard error for `approx_distinct()`. The HLL functions page does not explicitly publish a per-function error, and some third-party sources note `approx_set` uses 4096 buckets (~1.6%) vs `approx_distinct`'s 2048 buckets (~2.3%). The answer's 2.3% claim is the commonly-cited conservative value and is a safe approximation, but is technically the `approx_distinct` figure. Minor inaccuracy, not misleading for the use case.
6. **Storage in Iceberg** — minor gap. In practice, persisting HLL sketches into an Iceberg table typically requires a `CAST(approx_set(user_id) AS varbinary)` because Iceberg doesn't natively know the `HyperLogLog` type. The answer skips this cast and asserts "stored as a binary column in Iceberg" — `CREATE TABLE ... AS SELECT approx_set(...)` may fail or behave inconsistently against the Iceberg connector. Likewise, reading back requires `CAST(... AS HyperLogLog)` before merging. The official Trino example shown in docs uses the explicit varbinary roundtrip.
7. **Trino INTERVAL date arithmetic syntax** (`event_date - INTERVAL '6' DAY`) — valid Trino syntax.
8. **`approx_distinct(user_id)` in validation query** — valid.

## What worked

- Clear explanation of the underlying problem (shuffle and dedup cost) before jumping to the solution.
- Three-function breakdown (`approx_set`, `merge`, `cardinality`) names the roles cleanly — exactly the conceptual model a beginner needs.
- Concrete nightly build + query-time merge code, with both a self-join window pattern and a single-pass CASE pattern.
- Quantified the benefit with bytes-read / latency table — shows the engineer why this matters.
- Honest accuracy trade-off section: internal ops OK, customer-facing billing not, plus a validation query.
- "Verify the optimization landed" with EXPLAIN ANALYZE — closes the loop.
- Mentions the "today's incomplete data" gotcha and the union-with-fresh-events workaround.
- Fits the production stack (Trino 467 + Iceberg + Hive Metastore on-prem) without recommending anything off-stack.

## What was wrong or missing

- **Missing `CAST AS varbinary` for Iceberg storage.** This is the most likely real-world stumble for the engineer following the recipe verbatim. The CREATE TABLE statement should cast `approx_set(user_id) AS varbinary` and the merge query should cast back `AS HyperLogLog`. Without this, the engineer may get a type error against the Iceberg connector.
- **2.3% error figure is the `approx_distinct` value, not `approx_set`'s actual precision.** Conservative and safe for decision-making, but not strictly accurate.
- The "68% within ±2.3%, 95% within ±4.6%" framing is a reasonable normal-approximation gloss but slightly overstates the formality of HLL's error distribution. Acceptable simplification.
- No mention of incremental sketch updates for *late-arriving* events (only "today's incomplete data" is covered). A nice-to-have for completeness, not a gap that fails the answer.

## Suggested topic score update
Old: 4.636 / 12 questions
New avg if this scores 4.625: (4.636 * 12 + 4.625) / 13 = **4.635 / 13 questions**
