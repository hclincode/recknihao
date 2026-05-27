# Iter 221 Q2 Judge Score

## Score: 4.80

## Topic: Trino federation cross-source connectors

## What the answer got right

- **VARCHAR pushdown claim is correct and absolute**: Confirmed against Trino docs and issue #6746 — MySQL connector does NOT push down any predicates on textual (CHAR/VARCHAR) columns due to case-insensitive collation concerns. The answer's blanket statement ("not VARCHAR equality, not LIKE patterns, not IN-lists on text columns, nothing") is accurate.
- **DATE predicate pushdown**: Correctly states that `invoice_date >= DATE '2026-01-01'` pushes to MySQL. DATE range predicates are pushed by the MySQL connector.
- **COUNT pushdown gated by full predicate pushdown**: This is the crux of the question and the answer nails it. Verified against PRs #6667, issues #4111/#4112 — "aggregation pushdown is only possible when aggregation is direct above table scan." If a residual Filter node sits above TableScan (because VARCHAR didn't push), the aggregate cannot push down. The answer's framing ("MySQL is NOT returning one number. Trino is pulling rows over JDBC and counting them itself") directly addresses the user's confusion.
- **Execution flow described accurately**: The 4-step breakdown (MySQL date-filter → ship rows over JDBC → Trino filters status in memory → Trino counts) matches actual JDBC connector behavior.
- **EXPLAIN reading guidance**: Correctly explains that `ScanFilterProject`/`Filter` node above `TableScan` indicates non-pushed predicate, and that fully-pushed plans show the constraint inside the TableScan. Matches Trino EXPLAIN ANALYZE semantics — `Filtered:` percentage on the Filter operator reveals in-memory filtering volume.
- **Practical fixes are excellent**:
  - Narrowing date range is the right immediate win (reduces JDBC payload).
  - Numeric `status_code` workaround is the canonical Trino-MySQL workaround.
  - Iceberg ingest recommendation fits the production environment exactly (Trino 467 + Iceberg + MinIO on-prem stack from `prod_info.md`).
- **Beginner clarity**: Defines what "pushdown" means in context, walks through what each step costs, gives concrete EXPLAIN ANALYZE output sample. No assumed OLAP background.
- **Aligned with prior iter220 Q1 correct content**: The MySQL VARCHAR-no-pushdown messaging is consistent with the resource section added after iter219 failure — shows resources are being used correctly.

## What the answer missed or got wrong

- **PostgreSQL aside is slightly imprecise**: "PostgreSQL connector supports VARCHAR equality and simple LIKE pushdown since Trino 365" — the version "365" specifically isn't easy to verify (PR #9746 mentions range pushdown with collation as later/experimental). PostgreSQL connector pushes down VARCHAR equality (= and !=) by default and requires `postgresql.experimental.enable-string-pushdown-with-collate` for range predicates. The answer's claim is directionally correct but the version pin is unverified. Minor since it's a side comparison.
- **Doesn't mention `domain_compaction_threshold`** for the date range case (e.g., if user used a large IN-list on dates instead). Iter220 notes flagged this as a follow-up resource gap.
- **No mention that `SELECT COUNT(*) FROM table` with NO WHERE clause would push down as a metadata/single-row read** — would have been a nice contrast to drive the "WHY all predicates must push" point home.
- **EXPLAIN ANALYZE sample is plausible but synthetic**: "Filtered: 97.2%" with "2500000 rows (245MB)" reads like a fabricated example rather than typical Trino output formatting. Real `EXPLAIN ANALYZE` output uses slightly different field names (`Input:` is correct, but `Filtered:` is reported per operator on Filter operators, not on the TableScan itself as the formatting suggests). Minor stylistic issue, not a correctness problem.
- **Could note connection-side impact**: Pulling millions of rows over JDBC also holds a MySQL connection open longer (relevant if there's connection pooling pressure). Would round out the perf discussion.

## WebSearch verification notes

Verified against:
- https://trino.io/docs/current/connector/mysql.html — confirms MySQL connector does NOT push any predicates on CHAR/VARCHAR columns; aggregate pushdown supported for COUNT/SUM/AVG/MIN/MAX/stddev/variance functions.
- https://trino.io/docs/current/optimizer/pushdown.html — aggregate pushdown depends on connector support AND "query structure allows pushdown to take place." Documentation does not explicitly state the "all WHERE must push for aggregate to push" rule, but...
- GitHub PR #6667 (findepi, "HAVING pushdown and more advanced aggregation pushdown in JDBC connectors") and issues #4111/#4112 — confirm that JDBC aggregation pushdown is "only possible when aggregation is direct above table scan." A residual Filter node above TableScan blocks aggregate pushdown. This is the technical foundation for the answer's central claim and it is correct.
- GitHub issue #6746 — confirms VARCHAR/CHAR pushdown is intentionally disabled for MySQL connector due to collation correctness concerns.
- PR #9746 — confirms PostgreSQL collation-aware string range pushdown is gated by experimental flag (mildly contradicts answer's offhand "since 365" version claim; equality pushdown is default though).

## Recommendation for teacher

The MySQL section the teacher added after iter219 is paying off — this answer is on-target and addresses the exact "does the COUNT push down when the VARCHAR doesn't" confusion crisply. Two small additions would harden the resource further:

1. **Add an explicit example for `SELECT COUNT(*) FROM mysql_tbl` (no WHERE)** showing that with zero WHERE clauses (or only pushing WHERE clauses), the COUNT pushes and only "1 row, ~8 bytes" returns over JDBC. Contrast it with the mixed-pushdown case. This makes the "all predicates must push" rule click for beginners.
2. **Verify and correct the PostgreSQL VARCHAR version claim**. Either drop the "since 365" version pin or replace with the accurate state: "PostgreSQL connector pushes VARCHAR equality by default; range predicates require the experimental `postgresql.experimental.enable-string-pushdown-with-collate` flag."
3. **Optional**: Add a brief note that connection pool pressure is also a side effect of non-pushdown queries — useful for the federation monitoring topic flagged in state.json notes.

Topic running average update: prior 4.447 across 116 → new (4.447 × 116 + 4.80) / 117 = **4.450 across 117 questions**. Topic still NEEDS WORK against 4.5 threshold but trending in the right direction.
