# Iter 202 Q2 Judge — JDBC Fetch Size and Timeout Tuning

## Score
| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.75** |

## Verdict
PASS (threshold: 4.5 for Trino federation topic)

## Key findings

- **Technical accuracy (5)**: All verified facts check out against the pgJDBC and Trino official docs.
  - `defaultRowFetchSize` is a real PostgreSQL JDBC URL parameter (PGProperty, documented at jdbc.postgresql.org). Correctly identified as JDBC-driver-level, not Trino-specific. Trino's PostgreSQL connector docs confirm fetch size is not exposed as a catalog property; it must be passed via `connection-url`.
  - `socketTimeout` and `connectTimeout` are correctly stated to be in **seconds** for pgJDBC (max 2147484, 0 disables). The values `60` and `10` are reasonable.
  - `prepareThreshold=0` for PgBouncer transaction-pooling mode is correct — pgJDBC server-side prepared statements collide with PgBouncer's transaction pooling because connections rotate across backends. This is the canonical workaround when not on PgBouncer ≥ 1.21.0 with `max_prepared_statements` enabled. The answer's claim that it is "mandatory in PgBouncer transaction-pooling mode" is slightly stronger than reality (PgBouncer 1.21+ has native PS support), but for the typical OSS Trino + PgBouncer deployment described in prod_info.md the recommendation stands.
  - `defaultRowFetchSize=3000` is within the well-known "Goldilocks zone" for analytics workloads — pgJDBC issue trackers and operator reports commonly cite 1k–10k. The trade-off framing (memory vs round-trips) is correct.
  - The "no native connection pool in OSS Trino" caveat is verified — `connection-pool.enabled` is documented only in Starburst Enterprise's docs and is absent from `trino.io/docs/current/connector/postgresql.html`.

- **Beginner clarity (4)**: Strong on the core analogy ("batch size: each network call grabs N rows") and the side-by-side timeout table. JDBC URL syntax is shown end-to-end so a reader who has never seen a JDBC URL can copy-paste. Docked one point because a few terms land without inline gloss: "predicate pushdown," "EXPLAIN (TYPE DISTRIBUTED)," "Physical Input," "round-trip," "starvation," "PgBouncer transaction-pooling mode," and "`statement_timeout=5m` on your replica role" all assume prior context. A SaaS engineer with no JDBC background will Google two or three of those terms before they can act on the predicate-pushdown verification step.

- **Practical applicability (5)**: Three ready-to-paste catalog property blocks (baseline, PgBouncer, tuned recommendation), explicit recommended starting values with rationale, and a clear "check pushdown first" warning that prevents the engineer from chasing the wrong knob. The "Other things to check" section (replica lag query, query-caching reframe) gives concrete fallback investigation steps.

- **Completeness (5)**: Covers all six required sub-topics: (1) fetch size trade-offs both directions, (2) `socketTimeout` vs `connectTimeout` distinction, (3) concrete recommended values (3000 / 60 / 10), (4) PgBouncer `prepareThreshold=0` note, (5) "check predicate pushdown first" advice, and (6) the OSS-vs-Starburst connection-pool reminder. Bonus: pairs `socketTimeout` with server-side `statement_timeout`, which is the correct operational pairing.

## Resource fix suggestions

- In `resources/22-trino-federation-postgresql.md`, add a one-line gloss for "predicate pushdown" the first time it appears in the JDBC-tuning section, since the federation topic now overlaps heavily with engineers who arrive without OLAP context.
- Soften the "`prepareThreshold=0` is mandatory" line to "required for PgBouncer transaction-pooling mode unless you are on PgBouncer ≥ 1.21.0 with `max_prepared_statements > 0`" — the absolute phrasing will misfire for teams on current PgBouncer releases.
- Consider adding a short note that `socketTimeout` and `connectTimeout` for pgJDBC are in **seconds** (not milliseconds like many other JDBC drivers) — this is a frequent footgun and the answer assumes the reader knows.
