# Judge Report — iter159 Q1

**Topic**: Trino federation / cross-source connectors (PostgreSQL connector, predicate pushdown, cross-catalog join limits, when to federate vs ingest)
**Per-topic pass threshold**: 4.5 (elevated, per rubric)
**Answer file**: /Users/hclin/github/recknihao/training/answers/iter159-q1.md

---

## Verification notes (WebSearch findings)

1. **Predicate pushdown defaults**: Confirmed via trino.io/docs/current/connector/postgresql.html — predicates push down for numeric, UUID, and temporal/DATE types by default. Range predicates (>, <, BETWEEN) on character string types (CHAR/VARCHAR) do NOT push down by default; only equality / IN push down for strings. Experimental `postgresql.experimental.enable-string-pushdown-with-collate` is available.
2. **Does Trino pull all 8M rows without a predicate?** The answer's claim is correct *only when there is a WHERE clause that can push down*. With no predicate at all, the connector must scan the full Postgres table — exactly what the answer acknowledges in the "8M × 500M" paragraph. Acceptable.
3. **Dynamic filtering**: Confirmed via trino.io/docs/current/admin/dynamic-filtering.html and the JDBC PR #13334 — dynamic filtering for JDBC connectors (including PostgreSQL) IS supported and is the key optimization that lets a probe-side scan into Postgres receive a small IN-list derived from the build side at runtime. **The answer does NOT mention dynamic filtering at all.** This is a critical omission for this exact question, because the resource doc (resources/22-trino-federation-postgresql.md §5) explicitly frames dynamic filtering as "the optimization that makes cross-catalog joins survivable" — and the question is a textbook large-vs-very-large cross-catalog join scenario.
4. **Read replica advice**: Correct and well-stated. `statement_timeout` recommendation is correct.
5. **Connection pool sizing**: The property name `postgresql.connection-pool-max-size` matches the form used in the teacher's resource doc and is plausible. Trino's official PostgreSQL connector documentation page does not surface a public connection pool property under that exact name; the Oracle connector uses dotted form `oracle.connection-pool.max-size`. This is a minor risk of property-name drift, but it matches the resource doc the responder was reading. The arithmetic (20 workers × 10 = 200 connections) is correct and operationally useful.
6. **EXPLAIN command**: Trino docs describe pushdown verification by examining the EXPLAIN plan for absence of `ScanFilterProject` and presence of filter conditions inside the `TableScan`. `EXPLAIN (TYPE DISTRIBUTED)` works and shows fragments, but the more precise verification idiom is plain `EXPLAIN` or `EXPLAIN ANALYZE`. The answer refers to looking for a "`FilterNode` above the scan" — docs use the term `ScanFilterProject`. Close but not exactly the term shown in plans.
7. **Slow-query logging suggestion** (`log_min_duration_statement=0`) is accurate Postgres practice and a good practical verification step.

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy (×2) | 4 | Core mechanics correct. Predicate pushdown explained correctly at a conceptual level. **Misses dynamic filtering entirely** — a significant gap given that DF is THE mechanism that makes the 8M × 500M scenario work. Minor wording miss: "FilterNode" instead of `ScanFilterProject`. No mention of string-range pushdown caveat. Connection-pool property name plausible but the official docs don't show that exact spelling for PostgreSQL. |
| Beginner clarity (×1) | 4.5 | Very accessible. Names the jargon ("predicate pushdown") and then defines it in plain English. Uses concrete numbers (20 workers × 10 connections = 200) the reader can map onto their stack. Tone is appropriately direct without being condescending. |
| Practical applicability (×1) | 4 | Actionable: gives a property to set, a Postgres timeout to set, an `EXPLAIN` command to run, and a Postgres-side verification (`log_min_duration_statement`). Mentions read replica as non-negotiable. Loses points because (a) does not tell the engineer how to validate that dynamic filtering actually fires (UI operator stats or `EXPLAIN ANALYZE` dynamicFilters), and (b) doesn't lay out the "federate vs ingest" decision crisply — the engineer is left with "if both sides are unconstrained, ingest first" but no concrete decision matrix. |
| Completeness (×1) | 3.5 | Addresses both halves of the question (does Trino pull everything? + production-Postgres risk). But misses dynamic filtering, string-pushdown caveat, hybrid UNION ALL pattern, and the explicit "cross-catalog joins always execute on Trino workers (no join pushdown across catalogs)" framing. For a question this specific to a 8M × 500M cross-catalog join, dynamic filtering is the single most important concept and its absence is felt. |

**Weighted average** = (4×2 + 4.5 + 4 + 3.5) / 5 = (8 + 4.5 + 4 + 3.5) / 5 = **20.0 / 5 = 4.00**

---

## Pass/fail vs threshold

- Baseline pass threshold: 3.5 → **PASSES baseline**
- Topic-specific elevated threshold: 4.5 → **DOES NOT PASS** (4.00 < 4.50)

This topic was flagged with an elevated bar precisely because the iter158 Q1 failure exposed a critical resource gap. The teacher built a strong resource doc (22-trino-federation-postgresql.md) that explicitly covers dynamic filtering, string-pushdown caveats, the "no join pushdown across catalogs" rule, and a federate-vs-ingest decision matrix. The responder used only a subset of that material. To pass the elevated bar, the responder must surface dynamic filtering when answering large-vs-large cross-catalog join questions, and must mention the string-range pushdown caveat at least briefly.

---

## Recommendations for the teacher (early-phase feedback)

The resource is technically good — it contains everything the responder would have needed. The gap is that the responder did not retrieve / surface §5 (dynamic filtering) when answering an 8M × 500M join question. Two possible fixes:

1. Add a short, prominent "If you're asked about a large × large cross-catalog join, you MUST mention dynamic filtering" prompt at the very top of section 3 (Predicate pushdown) so it's hard to miss.
2. Add a worked example in the resource of exactly this shape: "8M Postgres rows joined to 500M Iceberg rows — what happens, what to verify, what to tune." That gives the responder a direct template to mirror.

Also worth tightening:
- Standardize on `ScanFilterProject` (matches Trino docs/EXPLAIN output) rather than "FilterNode."
- Note that the property `postgresql.connection-pool-max-size` should be cross-checked against the exact Trino 467 release notes / source; if Trino's JDBC framework uses dotted form `connection-pool.max-size`, the doc should reflect that to avoid the engineer hitting an "unknown property" error at startup.

---

## Final score

**4.00 / 5.0** — PASSES baseline 3.5, **DOES NOT PASS** elevated 4.5 threshold for this topic.
