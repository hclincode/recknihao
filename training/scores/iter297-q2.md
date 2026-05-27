# Score: iter297-q2

**Question**: "Almost every dashboard query needs to join against our main Postgres customers table to filter by plan tier, signup date, or account region. We currently export a nightly CSV dump — joins are 24 hours stale. Can Trino query Postgres directly in the same SQL statement as our Iceberg event data? Is it fast enough to be practical, or does it just make everything slow?"

## Score table

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.5 | Core mechanisms (PostgreSQL connector, predicate pushdown, dynamic filtering on-by-default with 20s wait timeout, join on Trino workers, read-replica isolation) are correct. The claim that "Trino 467 has no JDBC connection pooling" is correct for open-source Trino — `connection-pool.enabled` is a Starburst Enterprise feature, not stock OSS Trino (verified). Small nuance: the "one JDBC connection per scan held for the entire query" framing is slightly oversimplified — each split/worker scan opens a connection, and Postgres-side predicate pushdown rewrites the connector-emitted SQL but does not always cover every type of predicate (e.g., range predicates on VARCHAR with collation are not pushed). These caveats are not load-bearing for the engineer's question. |
| Beginner clarity | 5 | No assumed OLAP knowledge. Mechanism is walked through step-by-step (3 numbered phases), and the dynamic filtering explanation is unusually concrete. Fast/slow examples make the "filter one side small" rule crystal clear. Catalog properties file is shown verbatim. |
| Practical applicability | 5 | Directly addresses the production stack (Trino 467, Iceberg, MinIO). Concrete catalog config snippet with env-var indirection, verification queries, named risks (replica lag, connection saturation, missing WHERE), and a fallback materialization pattern using `INSERT INTO ... SELECT` that fits the SaaS team's existing Spark/dbt workflows. Engineer knows exactly what to deploy next. |
| Completeness | 5 | Covers all four sub-questions: (1) can Trino do it (yes, mechanism shown), (2) is it fast enough (three reasons it is — pushdown, dynamic filtering, in-memory hash join), (3) does it slow things down (yes if rules are broken — connection saturation, full scans), (4) implicit "how do I roll this out" (catalog config, verification, monitoring, and a caching escape hatch for high-frequency dashboards). |

**Average: 4.875 — PASS**

## Verification notes

Searches and findings:
1. **Dynamic filtering on JDBC PostgreSQL connector** — verified via trino.io/docs/current/connector/postgresql.html: `dynamic-filtering.enabled` defaults to `true`; default `dynamic-filtering.wait-timeout` is 20s. Answer's claim "on by default" is correct.
2. **Predicate pushdown for PostgreSQL connector** — verified via Trino pushdown docs: WHERE clauses including `=`, `IN`, `!=`, and range predicates on numeric/date types are pushed down; range predicates on VARCHAR with collation are NOT pushed (correctness preservation). Answer's `c.plan_tier = 'enterprise'` example pushes down correctly.
3. **JDBC connection pooling in open-source Trino** — verified: `connection-pool.enabled` is a Starburst Enterprise-only feature (GitHub issue #15888 from Jan 2023 requesting it for OSS is still open as a feature request; the property exists in Starburst docs only). Answer's "Trino 467 has no JDBC connection pooling" is correct for the user's OSS Trino 467 stack.
4. **Read replica recommendation** — standard operational guidance, no specific doc claim made beyond "isolate Trino traffic from OLTP." Sound advice that matches Trino community guidance.
5. **Trino 467 release** — confirmed 6 Dec 2024; matches the production stack version.

## Topic mapping

Primary:
- **Trino federation / cross-source connectors** (PostgreSQL connector, predicate pushdown, cross-catalog join limits, when to federate vs ingest) — directly central. Pass threshold ≥ 4.5; this answer scores 4.875.

Secondary:
- **When to add an OLAP layer vs staying on transactional DB** — tangential (federation vs ingestion trade-off, materializing as Iceberg for high frequency).
- **Real-time vs batch analytics trade-offs** — tangential (live federation gives current-second freshness vs hourly materialization).

## Verdict

**PASS (avg 4.875)**. Answer is technically accurate, beginner-friendly, immediately actionable for the production Trino 467 + Iceberg + Postgres stack, and complete across all four implicit sub-questions. Minor technical-accuracy nuance on the connection-per-scan framing and predicate-pushdown edge cases is not load-bearing. The hybrid recommendation (live federation + optional hourly materialization for high-frequency dashboards) is the right architectural framing.

Sources consulted:
- [Trino PostgreSQL connector docs](https://trino.io/docs/current/connector/postgresql.html)
- [Trino pushdown optimizer docs](https://trino.io/docs/current/optimizer/pushdown.html)
- [Trino GitHub issue #15888 (PostgreSQL connection pooling)](https://github.com/trinodb/trino/issues/15888)
- [Starburst PostgreSQL connector docs (connection-pool.enabled reference)](https://docs.starburst.io/latest/connector/postgresql.html)
- [Trino Release 467 (6 Dec 2024)](https://trino.io/docs/current/release/release-467.html)
