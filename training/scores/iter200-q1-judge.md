# Iter 200 Q1 Judge — Schema Evolution and Metadata Caching

## Score
| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **5.00** |

## Verdict
PASS (threshold: 4.5 for Trino federation topic)

## Key findings
- Default `metadata.cache-ttl` claim verified against official Trino PostgreSQL connector docs: defaults to `0s` (caching disabled). Answer correctly states this and frames it as "safest for schema changes."
- `flush_metadata_cache()` parameter claim verified: the PostgreSQL/JDBC connector's procedure is parameterless. The answer correctly contrasts this with Hive/Delta Lake connectors which accept `schema_name`/`table_name` named params. This is a subtle and commonly-confused detail — answer nails it.
- Two failure modes are well separated and accurate:
  - **Silent corruption** (SELECT * in views + ADD COLUMN): correctly explained. The view's frozen column list is the actual mechanism, and the answer explicitly mentions that flushing the metadata cache does NOT fix views — it only fixes direct table queries.
  - **Hard error** (DROP/RENAME column referenced explicitly): correctly explained — Trino planner uses cached schema, push-down fails at Postgres with `ERROR: column "..." does not exist`.
- Intermittent error scenario across coordinators is a sophisticated insight that matches real-world Trino federated behavior.
- The post-migration checklist is concrete: check `etc/catalog/app_pg.properties`, run `flush_metadata_cache()`, update views with explicit column lists, coordinate with dashboard owners, verify with `DESCRIBE`. Each step is actionable.
- Trade-off discussion at the end (cache=60s for stable schema, 0s for active migration) is practical and matches the SaaS production setting.
- Beginner clarity: explains jargon (TTL, cache, pushdown implicit), gives scenarios, no assumed OLAP knowledge required.
- Production fit (on-prem k8s, Trino 467 + PostgreSQL read replica) is honored — no cloud-only tools recommended.

## Resource fix suggestions
None. The answer is materially aligned with `resources/22-trino-federation-postgresql.md` and the official Trino documentation. One very minor nuance the answer could have added (not required for a pass): mention that `metadata.cache-ttl` is itself NOT hot-loadable — changing the TTL value in the properties file requires a catalog reload (the resource covers this at line 407, but the question didn't ask about TTL changes, only forcing a refresh, so omission is acceptable).

Sources:
- [PostgreSQL connector — Trino 481 Documentation](https://trino.io/docs/current/connector/postgresql.html)
- [PostgreSQL connector — Trino 475 Documentation](https://trinodb.github.io/docs.trino.io/current/connector/postgresql.html)
