# Iter274 Q1 Score

**Score**: 4.75 / 5.0
**Pass/Fail**: PASS

## Dimension scores
- Technical accuracy: 4.5/5
- Beginner clarity: 5/5
- Practical applicability: 5/5
- Completeness: 4.5/5

## What the answer got right
- **Core diagnostic rule is correct and well-framed**: "ScanFilterProject above TableScan = pushdown failed; bare TableScan with `constraint on [col]` block = pushdown succeeded." Verified against trino.io/docs/current/optimizer/pushdown.html and the Trino GitHub master docs. The official guidance is that successful pushdown results in the absence of a ScanFilterProject for that clause, with the predicate embedded in the TableScan node — exactly what the answer says.
- **Annotated plan examples are highly readable**: side-by-side success vs. failure plans with `Input:`/`Output:` row counts make the difference visually obvious. The 5.2M-row failure example explicitly shows `Input ≈ Output` at TableScan (= no local filter) vs the failed case where TableScan returns full table size and ScanFilterProject reduces it.
- **Predicate-type matrix is mostly correct**: equality, numeric/date ranges, IN-list, NULL checks push down — confirmed against trino.io/docs/current/connector/postgresql.html. The PG connector explicitly supports pushdown for equality (=, IN), inequality (!=), and pushdown of most temporal/numeric ranges.
- **Correctly flags VARCHAR range as non-pushable**: matches the PG connector docs verbatim ("does not support pushdown of range predicates, such as >, <, or BETWEEN, on columns with character string types like CHAR or VARCHAR" due to collation).
- **Correctly flags `LOWER(col) = ...` as non-pushable** (no expression pushdown for arbitrary functions on the PG connector by default).
- **Four-step diagnostic checklist is genuinely actionable** — engineer can run EXPLAIN, scan the tree, identify position, then verify with EXPLAIN ANALYZE and Postgres slow-query log as ground truth.
- **Ground-truth fallback (Postgres `log_min_duration_statement = 0`)** is a great practical tip — the only definitive answer if the plan is ambiguous.
- **Three-row summary table** crystallizes the three plan shapes (constraint on / ScanFilterProject / standalone Filter) in one glance.

## Errors or gaps
- **ILIKE pushdown claim is slightly outdated/oversimplified**: The answer states "Case-insensitive LIKE: WHERE email ILIKE 'a%' — not supported by Trino's PostgreSQL connector" and later "ILIKE never pushes in OSS Trino 467." This is too absolute. PR #11045 ("JDBC function predicate pushdown with PostgreSQL LIKE pushdown") merged complex function pushdown for LIKE/ILIKE-style operations on the PG connector. Behavior is nuanced — it depends on session properties (`complex_expression_pushdown`) and whether the column has the right collation. In Trino 467, LIKE pushdown to PostgreSQL is supported (with caveats); a categorical "never" is wrong. The answer would be more accurate saying "may or may not push depending on session config and column collation — verify with EXPLAIN."
- **Minor format imprecision in the example block**: The "Pushdown success" example shows the constraint as indented bullet-style text under TableScan; real Trino EXPLAIN output uses `predicate = ...` / `constraint = ...` style key/value lines rather than the prose form shown. The conceptual point is right, but an engineer searching for a literal "constraint on [status, order_date]" line in their plan may not find that exact string. A note like "the exact text varies by Trino version — look for the predicate as part of the TableScan node, not above it" would help.
- **Three-shape table calls "standalone Filter above TableScan" a pushdown failure** without nuance — sometimes this is a post-aggregation HAVING-like filter that was never a candidate for pushdown, not necessarily a "failure." Minor.
- **Doesn't mention `EXPLAIN (TYPE IO)` or `EXPLAIN (TYPE DISTRIBUTED)`** which are sometimes more readable for confirming pushdown vs the default logical plan. Small completeness gap.
- **No mention that the production environment is Trino 467 with the Iceberg connector + PG via JDBC**, but the answer does correctly scope its examples to the PG connector (the question is PG-focused), so this is not a fit problem.

## WebSearch findings
Verified against official Trino docs (current = 481, but rules unchanged from 467):
- **trino.io/docs/current/optimizer/pushdown.html**: confirms "if predicate pushdown for a specific clause is successful, the EXPLAIN plan does not include a ScanFilterProject operation for that clause." Pushdown failure → ScanFilterProject appears.
- **trino.io/docs/current/connector/postgresql.html**: confirms equality and inequality on VARCHAR push down, but range predicates (>, <, BETWEEN) on CHAR/VARCHAR do NOT push down due to collation differences. Experimental override exists: `postgresql.experimental.enable-string-pushdown-with-collate=true`.
- **github.com/trinodb/trino PR #11045**: LIKE/ILIKE pushdown to PostgreSQL was added via complex function pushdown; behavior depends on session/connector configuration. The answer's categorical "ILIKE never pushes" is the main accuracy issue, though it is the common observed behavior with default settings.
- **The "TableScan with predicate embedded vs ScanFilterProject above" rule is canonical** and matches both the official docs and multiple community references (posulliv.github.io, Trino wiki).

## Topics updated
Trino federation / cross-source connectors — prior avg 4.485 across 221 questions; new running avg (4.485 × 221 + 4.75) / 222 = (990.785 + 4.75) / 222 = 995.535 / 222 = **4.485 across 222 questions**. Status: NEEDS WORK (4.485 < 4.5 raised threshold, but only 0.015 away). Gap: ILIKE/LOWER pushdown nuance — resources should explicitly note that complex function pushdown (including LIKE/ILIKE) was added to the JDBC PG connector and behavior depends on session config + collation, rather than asserting "never pushes." Also: the literal EXPLAIN text format for the `predicate`/`constraint` line on TableScan nodes should be illustrated with a real Trino 467 output snippet so engineers can grep for the exact string.
