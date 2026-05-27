# Feedback — Iter 284 (Extended phase)

Date: 2026-05-27
Topic: Trino federation — EXPLAIN ANALYZE predicate pushdown verification (Q1 PASS) + system.query() JSONB passthrough (Q2 PASS)

## Results summary

| Question | Topic angle | Score | Pass/Fail |
|---|---|---|---|
| Q1 | EXPLAIN ANALYZE for pushdown verification: ScanFilterProject vs TableScan, constraint annotation, dynamicFilterSplitsProcessed, Postgres slow query log | **4.80** | PASS |
| Q2 | system.query() for JSONB GIN index filtering: verbatim SQL, no outer pushdown, ORDER BY not preserved, Iceberg JOIN works, OPA bypass concern | **4.78** | PASS |

**Iter 284 average: 4.79 — PASS** ✓ Both passed!

**Topic update**: Trino federation: 4.498/241 → **4.500/243** (PASSED — at threshold! True value 4.4998, gap < 0.0002)

---

## What worked

### Q1 — EXPLAIN ANALYZE predicate pushdown (4.80)
1. ScanFilterProject above TableScan = pushdown FAILED — canonical signal, verified
2. constraint annotation under TableScan = pushdown SUCCEEDED — verified
3. `EXPLAIN (TYPE DISTRIBUTED)` first (no cost), then EXPLAIN ANALYZE for runtime row counts — correct approach
4. `Input: N rows` on Postgres TableScan as runtime proof — correct and concrete
5. `dynamicFilterSplitsProcessed > 0` as DF confirmation metric — verified (PR #3217)
6. Postgres slow query log (`log_min_duration_statement=0`) as ground-truth fallback — excellent practical tip
7. Common pushdown blockers: function wrapping, type mismatch, OR across tables, ILIKE without collate — all correct

### Q2 — system.query() JSONB passthrough (4.78)
1. JSONB json_extract_scalar/json_extract run on Trino workers (GIN index ignored) — correct
2. `<catalog>.system.query(query => '...')` syntax — verified against official docs
3. Single-quote doubling (`''`) inside query string — correct
4. No outer predicate pushdown — WHERE outside the function runs in Trino memory — critical and correct
5. ORDER BY inside query string not preserved in Trino output — verified
6. JOIN with Iceberg works, dynamic filtering applies on Iceberg side — correct
7. OPA row filters / column masks do NOT apply to system.query() results — verified, correct security callout
8. Try EXPLAIN first before reaching for system.query() (simple equality may push down) — good advice

---

## Errors / gaps (did not block pass)

### Q1 (minor)
- `EXPLAIN (TYPE IO)` not mentioned (shows object storage I/O predictions in addition to plan)
- No mention of partial vs full pushdown (some predicates push, others stay in Trino)

### Q2 (minor)
- Single-split execution model not mentioned: system.query() result comes via a single JDBC connection — no parallelism
- JSONB → VARCHAR type coercion edge case not mentioned: if system.query() returns a JSONB column, Trino may display it as VARCHAR
- system.query() is read-only — cannot INSERT/UPDATE/DELETE via passthrough — not mentioned

---

## Resource fixes before iter285

None urgent. Resource 22 covers all material correctly.

### Nice-to-have
1. **Add system.query() read-only note** (resource 22, system.query() section): clarify that system.query() only supports SELECT — no DML passthrough

---

## Next steps

Topic is at 4.500/243, essentially at the ≥ 4.5 threshold. The true computed value is 4.4998 (gap < 0.0002). Continue one or two more iterations with high-quality coverage to solidify the PASSED status beyond any rounding ambiguity.

## Suggested iter285 angles

1. **Re-test: dynamic filtering with high-cardinality keys + domain compaction** — DF IN-list ≥256 values compacted to range; `SET SESSION domain_compaction_threshold = 512`; when DF stops being effective for high-cardinality joins

2. **Trino resource groups for federated workloads** — `hardConcurrencyLimit`, `maxQueued`, source selectors with `X-Trino-Source` header; file-based config requires coordinator restart; queue depth monitoring

3. **ILIKE case-insensitive search via Trino → Postgres** — conditional on `enable_string_pushdown_with_collate=true` session property AND compatible column collation; COLLATE "C" warning for ICU columns; pg_trgm GIN index for unanchored LIKE

4. **federation + OPA: how Trino applies authorization to JDBC scans** — OPA evaluates at the Trino layer, not Postgres layer; `system.query()` bypasses column masking; file-based rules vs OPA integration

5. **Incremental MERGE INTO from Postgres with watermark — edge cases** — upper bound watermark prevents race condition; hard-delete handling; schema evolution (new columns)
