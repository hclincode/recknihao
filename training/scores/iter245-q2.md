# Iter245 Q2 Score

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.75** |

**Topic**: Trino federation / cross-source connectors
**Pass/Fail**: PASS (threshold 4.5)

## Strengths
- Core technical claim verified against official Trino docs: MySQL connector does NOT push down any predicates on CHAR/VARCHAR columns (the "case-insensitive collation correctness" reason underpins this), while PostgreSQL DOES push down equality/IN/!= on textual types. Answer captures this asymmetry precisely.
- Correctly identifies the silent-degradation failure mode: no error, query just ships entire table over JDBC and filters in Trino memory. This is the exact "silently perform badly" scenario the engineer asked about.
- Dynamic filtering caveat is correct and especially valuable: a DF derived from a small build side that produces an IN-list on a VARCHAR join key will not push into MySQL — this is a non-obvious consequence of the broader VARCHAR pushdown limitation that catches teams by surprise.
- Workaround pattern (pair VARCHAR filter with date/numeric pushdown predicate) is practical and immediately actionable.
- Summary table at the end is clean, scannable, and accurate — including the subtle "VARCHAR range does NOT push" for PostgreSQL (matches PR #9746 status: only equality/!= push, range still doesn't).
- JDBC unit difference (`socketTimeout` ms vs s) verified — this is a real operational footgun that has bitten teams in production.
- SSL property name differences (`sslmode=verify-full` Postgres vs `sslMode=VERIFY_IDENTITY` MySQL) verified against official docs.
- DELETE with VARCHAR predicate failing at planning time is a real Trino behavior — DELETE on JDBC connectors requires the predicate be fully pushable, so this is correct.
- Fits the production stack (Trino 467 with PostgreSQL + MySQL JDBC catalogs alongside Iceberg) — no advice contradicts the on-prem k8s + MinIO architecture.

## Gaps / Errors
- Minor overstatement: "cert must be JKS format, not PEM" for MySQL. MySQL Connector/J 8.x supports PEM via `sslCert`/`sslKey`/`sslMode` properties; the JKS requirement is specific to the `trustCertificateKeyStoreUrl` property. Not wrong as written but slightly absolutist.
- Beginner clarity dings: terms like "predicate pushdown," "dynamic filtering," "build side," "probe side," "JDBC," "co-predicate" appear with only partial explanation. Predicate pushdown is defined inline (good), but "dynamic filtering" and "build side" are introduced without unpacking what makes a side the build side. A SaaS engineer with no OLAP background may struggle with the dynamic filtering section.
- Could mention the underlying reason for the limitation (MySQL's default case-insensitive collation makes Trino's case-sensitive comparison semantically different — Trino refuses to push to preserve correctness). The "why" would help the engineer reason about whether a collation-aware workaround exists.
- Doesn't mention `domain-compaction-threshold` (default 256) — recent iterations flagged this as a high-priority gap. While it's more relevant to DF compaction than to the core VARCHAR question, it would have rounded out the dynamic filtering subsection.
- Doesn't cite the MySQL connector's 1-split-per-table limitation (no parallel reads from a single MySQL table), which is another major reason MySQL federation underperforms vs PostgreSQL at scale.
- Concrete remediation flow ("how do I diagnose this in EXPLAIN ANALYZE") is missing — an engineer hitting silent degradation would benefit from a "check the input rows on the JdbcTableScan node" pointer.
