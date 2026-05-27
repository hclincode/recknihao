# Iter 201 Q1 Judge — Multi-Schema Postgres Federation

## Score
| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.75** |

## Verdict
PASS (threshold: 4.5 for Trino federation topic)

## Key findings
- **One-connector-all-schemas claim: CORRECT.** Verified against trino.io/docs/current/connector/postgresql.html — "The PostgreSQL connector provides a schema for every PostgreSQL schema." A single `etc/catalog/app_pg.properties` exposes all four schemas (`public`, `billing`, `audit`, `tenant_data`) as Trino schemas under one catalog. The answer's `SHOW SCHEMAS FROM app_pg;` example is accurate.
- **Cross-schema join: CORRECT and well-explained.** The example `JOIN app_pg.tenant_data.subscriptions ... JOIN app_pg.billing.invoices` is exactly the right pattern. Bonus points for mentioning predicate pushdown, which keeps filtering on the Postgres side.
- **`search_path` does not carry over: CORRECT.** No Trino session property or PostgreSQL connector config exposes Postgres's `search_path` semantics (the multi-schema resolution behavior). The PostgreSQL connector documentation lists session properties like `array_mapping`, `decimal_mapping`, etc., but nothing equivalent to `search_path`.
- **Minor accuracy nit on "three-part naming is mandatory":** This is slightly overstated. Trino does support `USE catalog.schema` and session-level defaults — once set, you can use unqualified table names within that default schema (single-schema scope, not multi-schema search like Postgres). The answer's stronger claim ("every query must spell out the full three-part name") is true for cross-schema joins (which is the engineer's actual question) but is not technically true for single-schema queries with `USE` set. This is the only reason Technical accuracy is 4 instead of 5.
- **View workaround: CORRECT and practical.** The `CREATE VIEW analytics.tenant_subscriptions AS SELECT * FROM app_pg.tenant_data.subscriptions;` pattern is the standard way to hide three-part names from downstream tools.
- **Setup checklist: actionable and prod-aligned.** Catalog properties file path, env-var-based credentials, read-replica target, and verification step (`SHOW SCHEMAS`) are all correct for Trino 467 on-prem.
- **Beginner clarity is strong.** Postgres engineers reading this get a clear analogy ("`app_pg.billing` is one schema, `app_pg.tenant_data` is another"), and the framing of "search_path absence as good news / forced clarity" lands well.
- **Completeness: hits all five required points** — (1) one connector exposes all schemas, (2) three-part naming for cross-schema, (3) no search_path equivalent, (4) cross-schema join syntax example, (5) view-creation workaround.

## Resource fix suggestions
- In `resources/22-trino-federation-postgresql.md`, add a brief one-line note that Trino *does* support `USE app_pg.tenant_data;` to set a session-default schema, but stress that (a) this is single-schema scope only — it does NOT replicate Postgres `search_path`'s multi-schema resolution — and (b) for cross-schema queries (the typical federation case) you still need fully-qualified names. This would tighten the accuracy from "always required" to "always required when joining across schemas."
- Optionally add a one-sentence callout on `SET PATH` (Trino's session-level path for functions / table functions) so engineers don't confuse it with Postgres's `search_path` for tables.
- Consider adding a tiny "what about views in the source Postgres schemas?" note — i.e., does Trino expose Postgres views as tables? (Answer: yes, by default; the connector lists views as tables.) This is a follow-up question SaaS engineers commonly ask.
