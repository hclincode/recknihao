# Score: 4.88/5.0 PASS

## Dimension scores
- Technical accuracy: 5/5
- Beginner clarity: 5/5
- Practical applicability: 5/5
- Completeness: 4.5/5

## Key findings

### Technical accuracy — VERIFIED (5/5)
All major claims check out against trino.io/docs/current:

- `approx_distinct()` uses HyperLogLog — VERIFIED at trino.io/docs/current/functions/hyperloglog.html. Trino implements approx_distinct() using the HyperLogLog data structure.
- Default standard error ~2.3% — VERIFIED. Trino documents standard error of approximately 2.3% for cardinalities above 256 (sparse layout below 256 is exact, error 0).
- `approx_distinct(col, 0.01)` syntax — VERIFIED. The function accepts a second argument `e` (max standard error) in range [0.0040625, 0.26000], so 0.01 (1%) is valid syntax.
- `EXPLAIN ANALYZE` executes the query — VERIFIED at trino.io/docs/current/sql/explain-analyze.html.
- `ScanFilterProject` vs `TableScan` distinction — VERIFIED. When ScanFilterProject appears, filtering occurs in Trino (post-scan). The answer's framing that "constraint on [event_date]" inside TableScan = pushdown is the accepted convention. The mapping is slightly simplified (ScanFilterProject does not categorically mean "no pushdown" — pushdown can still happen at the connector level even with a ScanFilterProject wrapper if dynamic filters apply), but for the partition-pruning-on-Iceberg case the answer asks about, the heuristic is directionally correct and matches teacher resources.
- `Physical Input` field — VERIFIED. Documented in EXPLAIN ANALYZE output as the bytes read from source.
- CPU / Scheduled / Blocked timing fields — VERIFIED with exact field names and semantic meaning (Blocked = waiting on I/O).
- 10–50x speedup claim — Realistic for HyperLogLog vs exact distinct on a shuffle-bound 300M-row query. Conservative if anything; many real-world reports show even larger gains. The 90s → 2–5s estimate is plausible.

Minor nit (not docked): the ±2% error table in the "concrete terms" section presents 2.3% standard error as a deterministic ±2% bound. HLL error is a standard deviation, not a max — actual error can exceed it with low probability. Phrasing "the default standard error is about 2.3%" is correct; the table is a reasonable simplification for beginners but technically tighter wording would be "typical error within ~2%."

### Beginner clarity (5/5)
- Frames *why* COUNT(DISTINCT) is slow (network shuffle) before introducing the alternative — perfect mental-model setup.
- HyperLogLog explained as "compact probabilistic algorithm... each worker builds a tiny sketch" without requiring math.
- Concrete error table (100K / 1M / 50M users) makes the abstract "2.3% standard error" tangible.
- Decision table (dashboards vs billing vs compliance) gives a clear "when to use which" without OLAP jargon.
- Postgres vs Trino EXPLAIN framing in Part 2 is the right hook for the audience.
- Three EXPLAIN forms (bare / DISTRIBUTED / ANALYZE) clearly delineated with cost warning ("EXPENSIVE!") on ANALYZE.

### Practical applicability (5/5)
- Drop-in SQL rewrite for the exact query pattern (events + tenant_id + week + user_id) — engineer can copy/paste.
- Pre-run checklist using bare EXPLAIN is directly actionable: three things to look for, each with what "good" looks like.
- Names the production stack implicitly correctly (MinIO physical input, Iceberg constraint pushdown).
- "If Scheduled >> CPU, you're I/O-bound" gives a clear diagnostic interpretation rule.
- "Run EXPLAIN first, then EXPLAIN ANALYZE only when debugging" is the right operational guidance for an on-prem cluster where ANALYZE costs full query execution.

### Completeness (4.5/5)
- Both halves of the question fully addressed: approx_distinct AND EXPLAIN reading.
- The "summary for your specific query" closing section ties both halves back to the engineer's original problem — excellent.
- Minor gap: the answer does not mention the related building-block functions (`approx_set` / `merge` / `cardinality` for pre-aggregating HLL sketches across days), which would be the natural next question for someone computing weekly DAU at scale. Could be a one-line cross-reference. This is a "next question" gap, not a current-question gap.
- Minor gap: does not mention the Trino Web UI as an alternative to text EXPLAIN — the UI presents the same plan graphically with live stats, which many engineers prefer.

## Sources verified
- [HyperLogLog functions — Trino 479 Documentation](https://trino.io/docs/current/functions/hyperloglog.html)
- [Aggregate functions — Trino 481 Documentation](https://trino.io/docs/current/functions/aggregate.html)
- [EXPLAIN ANALYZE — Trino 481 Documentation](https://trino.io/docs/current/sql/explain-analyze.html)
- [Cost in EXPLAIN — Trino 480 Documentation](https://trino.io/docs/current/optimizer/cost-in-explain.html)
- [HyperLogLog in Presto: A significantly faster way to handle cardinality estimation (engineering.fb.com)](https://engineering.fb.com/2018/12/13/data-infrastructure/hyperloglog/)

## Average calculation
(5 + 5 + 5 + 4.5) / 4 = 4.875 → **4.88 PASS**

## Topic update
SQL query best practices for OLAP — first question (Q1 of iter289) covered partition pushdown; this Q2 covers approximate functions + EXPLAIN verification. Two distinct angles tested on this topic in iter289 — eligible for "passing" if scores both clear threshold.
