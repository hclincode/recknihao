# Score: iter242-q1 — Domain-Compaction-Threshold

**Score: 4.7 / 5.0**

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.75 → reported as 4.7** |

## What was correct

All six target claims verified against trino.io official docs:

1. **`domain-compaction-threshold` default = 256** — verified. The answer correctly names the property and the default. (Confirmed via Trino 481 PostgreSQL/MySQL/Snowflake/Redshift connector docs and trinodb/trino discussion #14019.)

2. **IN-list collapses to BETWEEN min/max above threshold** — verified. Trino compacts large pushed predicates into a simpler range predicate when the IN-list exceeds the threshold; the answer's framing ("compacts it to a min/max range like `WHERE customer_id BETWEEN 1 AND 100`") is accurate.

3. **Asymmetric effect Iceberg vs JDBC** — verified, and this is the answer's strongest contribution. The Iceberg side still benefits from file-level min/max pruning against Parquet/manifest stats with a BETWEEN range (just less selectively than an exact IN-list), while the PostgreSQL side receives the compacted range and streams back every row in the range. The answer correctly identifies the PostgreSQL side as "the real culprit" for the user's row-explosion symptom.

4. **Catalog-level property in `etc/catalog/<name>.properties`** — verified. The answer explicitly tells the engineer NOT to put it in `etc/config.properties`. Correct.

5. **`SET SESSION <catalog>.domain_compaction_threshold = N`** — verified. The answer flags the mandatory catalog-name prefix and warns that the bare form errors. This was a specifically-flagged failure mode in iter163/164/165 and the answer handles it correctly.

6. **`EXPLAIN ANALYZE VERBOSE` shows whether DF is IN-list vs BETWEEN** — verified. Trino docs (Dynamic Filtering admin page; EXPLAIN ANALYZE page) confirm VERBOSE surfaces actual filter values applied by dynamic filtering, including whether the value set was kept as an IN-list or compacted to a range. The answer's verification recipe (look for `dynamicFilters = {customer_id IN (...)}` vs `dynamicFilters = {customer_id BETWEEN ... AND ...}`) is operationally correct.

Additional strong moves:
- Pairs EXPLAIN ANALYZE VERBOSE with the Input/Output row-count comparison on the PostgreSQL TableScan as a second, independent diagnostic.
- Suggests tailing the PostgreSQL slow query log (`log_min_duration_statement=0` on a replica) as the ground-truth check on what SQL the connector actually shipped.
- Trade-offs section correctly warns that 10K+ IN-lists can stress the PostgreSQL planner and inflate wire size, so "raise threshold to 10000" is not unconditionally safe — directly opposing the "just crank it up" anti-pattern.
- Recommends 1024–2048 as the safe band for a 500-customer case, with concrete reasoning.

## What was wrong or missing

Minor technical imprecision (does not affect score):
- The answer frames compaction as something "the PostgreSQL connector" does to a "dynamic filter derived from your subquery." In Trino's SPI, `domain-compaction-threshold` is a generic JDBC-connector-side property that compacts ANY pushed `TupleDomain` — whether the IN-list came from (a) an explicitly written `WHERE id IN (...)` literal, (b) a static IN-list from a CTE/subquery materialized on Trino side, or (c) a runtime dynamic filter. The user's question used a subquery, so the DF path is the most likely actor, but conflating "this only happens for DF" would mislead engineers who hit the same symptom from an explicit literal IN-list. The answer leans heavily on the DF framing without explicitly noting the property also applies to non-DF pushed predicates.
- The "`BETWEEN 1 AND 7842`" example in the Iceberg section is internally inconsistent with the user's 500-customer scenario (where min/max would be set by the actual customer-id range from the segment, not an invented 7842). Minor illustrative drift, not factually wrong.

Beginner clarity gaps (cost one point):
- Terms used without inline plain-English glosses: "dynamic filter", "Parquet files", "min/max statistics", "TableScan node", "index range scan", "PostgreSQL slow query log", "catalog properties file", "session property", "wire size". A zero-OLAP-background engineer would need to look up at least half of these. The answer reads as targeted at a moderately-advanced Trino user, not the rubric's beginner persona.
- No upfront 1-sentence plain-English summary ("Trino has a safety knob that turns large lists into ranges; below 256 entries you're safe, above it you fall off a cliff on JDBC sources"). The body has the explanation but the engineer has to read the whole thing to extract the headline.

Completeness — no material gaps. All three parts of the question (what's happening, Iceberg side, PostgreSQL side) are answered, plus verification and remediation paths.

## Verification notes

- `domain-compaction-threshold` default 256: confirmed via trino.io/docs/current/connector/postgresql.html and the GitHub discussion trinodb/trino#14019 ("DISCUSS: Default domain compaction threshold is too low for basejdbc derived connectors").
- IN-list to BETWEEN compaction mechanism: confirmed via trinodb/trino PR #6057 ("Simplify extra large domains in JDBC connectors by default") and PostgreSQL connector docs ("Trino compacts large predicates into a simpler range predicate by default").
- Iceberg BETWEEN-range file pruning: confirmed via trino.io/blog/2023/04/11/date-predicates.html ("File pruning can skip portions of a data file ... if the queried range value does not overlap with the indexed Iceberg metadata range of values contained in the file") and the dynamic filtering admin page (min-max dynamic filtering still helps when build side is large).
- Catalog-prefixed session property: confirmed via PostgreSQL connector session properties section.
- EXPLAIN ANALYZE VERBOSE dynamic filter values: confirmed via trino.io/docs/current/sql/explain-analyze.html and the dynamic filtering admin page (VERBOSE option used for detailed dynamic-filter domain reporting).

Cross-referenced against `resources/22-trino-federation-postgresql.md` Sections 4.7d, 5.4, and the dedicated "Large IN-lists are silently compacted to a range" section — the answer aligns with the resource's content and does not contradict it.

## Recommendation for teacher

Resource 22 already covers domain-compaction-threshold well across multiple sections (the responder clearly drew from Section 4.7d and Section 5.4). No new resource content is required.

Suggested low-priority polish for the next teacher cycle:
1. **Distinguish DF-derived IN-list compaction from static-IN-list compaction** in the resource. The answer slightly overfits to the DF case because the resource's most prominent treatment of the threshold is in the DF/federation section. Add a one-line note that `domain-compaction-threshold` also applies to explicitly-written IN-lists pushed to JDBC connectors, not only to runtime dynamic filters.
2. **Beginner-clarity gloss pack**: when answers must rely on terms like "dynamic filter", "Parquet min/max stats", "TableScan node", "JDBC connector", and "catalog properties file", the responder should be able to pull a 1-line gloss from the resource for each. Consider adding a "Key terms used in this section" mini-glossary at the top of Section 5 (Dynamic filtering) in `22-trino-federation-postgresql.md`.

**Rubric topic update**: Trino federation / cross-source connectors — prior avg 4.432 across 157 questions; new running avg (4.432 × 157 + 4.7) / 158 = (695.824 + 4.7) / 158 = **4.435 across 158 questions**. Status: NEEDS WORK (4.435 < 4.5 raised threshold; gap narrowed from 0.068 to 0.065). Iteration 242 Q1 lifts the topic average very slightly but the raised-threshold deficit persists — continue tracking via iter242 Q2.

Verified: trino.io/docs/current/connector/postgresql.html; trino.io/docs/current/admin/dynamic-filtering.html; trino.io/docs/current/sql/explain-analyze.html; trino.io/blog/2023/04/11/date-predicates.html; trinodb/trino#14019; trinodb/trino PR #6057.
