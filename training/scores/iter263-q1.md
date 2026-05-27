# Iter263 Q1 Score

Score: 4.81

## Per-dimension scores
- Technical accuracy: 4.75
- Beginner clarity: 4.75
- Practical applicability: 5.0
- Completeness: 4.75
- **Average: 4.81**

## Verdict
PASS (>= 4.5)

## Strengths
- Three-step diagnostic workflow is exactly what an oncall SaaS engineer needs: EXPLAIN first (cheap), EXPLAIN ANALYZE second (Input/Output row counts), pg_stat_activity as ground truth.
- Correctly identifies that the *absence* of `ScanFilterProject` / `Filter` above the TableScan is the signature of successful pushdown — this aligns with the official Trino docs which state "If predicate pushdown for a specific clause is successful, the EXPLAIN plan for the query does not include a ScanFilterProject operation."
- Correctly identifies the four classic blockers: non-pushable peer predicates (ILIKE), function wrapping on the column, type-mismatch coercion, and IN-list expansion past `domain_compaction_threshold`.
- `domain_compaction_threshold` session property is correctly named and the catalog-prefix syntax (`SET SESSION app_pg.domain_compaction_threshold = 1024`) is correct.
- Correctly notes that date/timestamp range predicates push reliably to Postgres (verified against Trino postgresql connector docs: "Predicates are pushed down for most types, including UUID and temporal types, such as DATE").
- The "all-or-nothing for the entire scan" framing is a useful mental simplification, even if technically the connector returns an unpushed portion via `applyFilter` (the practical effect is the same: a Filter node appears above TableScan and Postgres receives less filtering).
- pg_stat_activity ground-truth recommendation is exactly right.
- Concrete row-count example (52,000 vs 5,200,000 with byte counts) makes the diagnostic actionable.

## Gaps / Errors
- The "constraint on [created_at]" notation under the TableScan node is presented as the success signature, but the official Trino docs (https://trino.io/docs/current/optimizer/pushdown.html) describe successful pushdown as the *absence* of ScanFilterProject above the scan, not the presence of a "constraint on" line. Trino does show pushed predicates in the TableScan node (typically as `:: predicate` or in the table handle / constraint summary lines), but the exact `constraint on [col] <predicate>` literal block as shown is not the canonical Trino EXPLAIN format. The teaching intent is right but the literal output snippet is stylized rather than verbatim.
- ILIKE pushdown statement is presented as absolute ("ILIKE does NOT push down"). The Trino postgresql docs do not explicitly document ILIKE non-pushdown; LIKE on VARCHAR also historically does not push by default because of collation-correctness concerns (the docs mention `enable-string-pushdown-with-collate` as an opt-in). The advice "replace ILIKE with LIKE — may push on standard collation columns" is plausible but the underlying mechanism (collation safety, not ILIKE-vs-LIKE) is glossed over.
- The IN-list cap is described as "256 distinct values" — that matches the default `domain-compaction-threshold` of 256, but the answer slightly conflates two things: (1) compaction is what *replaces* the IN-list with a min/max BETWEEN, not strictly a "cap." A user with exactly 200 distinct values is *not* getting their IN-list rewritten — the threshold is when compaction kicks in. Phrasing is close enough to be practically useful.
- No mention of the `Estimates:` line in EXPLAIN that often reveals whether the optimizer knows the predicate selectivity, which is another common diagnostic. Minor completeness gap.
- The answer does not mention that newer Trino versions (467 is the prod stack) include the pushed-down SQL fragment in the TableScan node itself, which would be a stronger and more verifiable success signal than waiting for pg_stat_activity. Small completeness gap given the prod stack pin.

## Technical accuracy notes
- Verified against https://trino.io/docs/current/optimizer/pushdown.html — successful pushdown is signaled by the *absence* of ScanFilterProject. The answer's framing is directionally correct but the literal "constraint on" syntax shown is illustrative rather than the verbatim Trino output. This is a minor stylization, not a factual error.
- Verified against https://trino.io/docs/current/connector/postgresql.html — equality (`=`, `!=`, `IN`) push universally; range predicates (`>`, `<`, `BETWEEN`) push on numeric and temporal types including DATE/TIMESTAMP; range on CHAR/VARCHAR does NOT push by default (requires `enable_string_pushdown_with_collate` opt-in). The answer's claim that date range predicates push reliably is correct.
- Verified `domain_compaction_threshold` is the correct session property name and the default is 256. The answer's mechanism description (IN-list → BETWEEN min/max) is correct.
- pg_stat_activity is the correct Postgres system view for inspecting active queries. The recommended filter on `state = 'active'` is sound.
- Function-wrapping (`date_trunc('day', col)`) blocking pushdown is consistent with the docs' note that connectors push down direct column references; expressions are not converted to remote SQL.
