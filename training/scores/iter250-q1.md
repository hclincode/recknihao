# Iter250 Q1 Score

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **5.0** |

**Topic**: Trino federation / cross-source connectors
**Pass/Fail**: PASS (threshold 4.5)

## Strengths

- Correctly identifies the root cause: bare `dynamic-filtering.wait-timeout` is silently ignored in `iceberg.properties` because the Iceberg connector requires the `iceberg.` prefix. Verified against trino.io Iceberg connector docs (property: `iceberg.dynamic-filtering.wait-timeout`, default `1s`).
- Correctly distinguishes lakehouse connectors (Iceberg/Hive/Delta — prefix required) from JDBC connectors (PostgreSQL/MySQL — bare form). Verified: PostgreSQL connector docs show `dynamic-filtering.wait-timeout` without prefix (default `20s`).
- Correctly explains the two naming differences in session properties: hyphens become underscores, and the catalog-name prefix (not connector-name) is required. Verified against Trino SET SESSION docs and Hive connector docs which explicitly call out `<hive-catalog>.dynamic_filtering_wait_timeout` as the session form. The same convention applies to Iceberg per the catalog session property pattern.
- The comparison table is clear and immediately actionable — a beginner can map their situation onto the right row.
- Explains the silent-ignore behavior (no error message) — directly addresses the user's confusion about why EXPLAIN looked identical.
- Includes per-query session form alongside the persistent catalog form, giving the engineer two clear options.
- Reminds the user to restart workers, not just the coordinator — a common stumble.
- Ties the fix back to the user's actual federation scenario (Postgres build side feeding Iceberg probe side), reinforcing why the Iceberg-side timeout is what matters.
- Fits the on-prem k8s Trino 467 stack from prod_info.md: catalog file edits and SET SESSION both work in that environment.

## Gaps / Errors

- Minor: the example for JDBC catalog property uses `30s` while the Iceberg example uses `20s`. Not wrong (just illustrative), but mixing values in the same table could momentarily confuse the reader. Cosmetic only.
- The answer states the default Iceberg timeout is 1 second, which is correct per the docs — no change needed, just noting it was an unverifiable-by-the-user claim that did check out.

## Verification Sources

- [Iceberg connector — Trino docs](https://trino.io/docs/current/connector/iceberg.html) — confirms `iceberg.dynamic-filtering.wait-timeout`, default `1s`.
- [PostgreSQL connector — Trino docs](https://trino.io/docs/current/connector/postgresql.html) — confirms bare `dynamic-filtering.wait-timeout` (no prefix) for JDBC.
- [Hive connector — Trino docs](https://trino.io/docs/current/connector/hive.html) — confirms `<hive-catalog>.dynamic_filtering_wait_timeout` session-property form (catalog-name prefix + underscores), the same pattern Iceberg follows.
- [SET SESSION — Trino docs](https://trino.io/docs/current/sql/set-session.html) — confirms catalog-specific session properties use `catalogname.property_name` format.
