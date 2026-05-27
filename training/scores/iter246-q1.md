# Iter246 Q1 Score

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4.5 |
| Practical applicability | 5 |
| Completeness | 4.5 |
| **Average** | **4.75** |

**Topic**: Trino federation / cross-source connectors (PostgreSQL connector metadata caching, schema migration handling, flush_metadata_cache procedure)
**Pass/Fail**: PASS (threshold 4.5)

## Strengths
- Diagnosis is correct and immediately actionable: identifies `metadata.cache-ttl` as the cache being served, names the exact property file, and shows the exact `CALL <catalog>.system.flush_metadata_cache()` procedure to clear it without a restart.
- All technical claims verified against the official Trino 467 PostgreSQL connector docs:
  - `metadata.cache-ttl` default is `0s` (caching disabled) — correct.
  - `flush_metadata_cache` procedure exists in `<catalog>.system` and flushes JDBC metadata caches — correct syntax.
  - `metadata.cache-missing` property is real and the `true` value is sensible for write-heavy schemas.
- The comparison table (TTL=0s vs TTL=60s) crystallizes the trade-off in one glance — exactly what a SaaS engineer needs to decide a config value.
- The "important detail" about TTL value changes requiring a catalog reload is a subtle correctness point that distinguishes a flush from a config refresh — engineers running into this would otherwise be confused why their new TTL doesn't take effect.
- The verification step (`DESCRIBE app_pg.public.<table>`) gives a clean way to confirm the fix worked.
- Catalog naming convention (`app_pg`) and properties file path match real on-prem Trino conventions; advice fits the production environment (no cloud-only tools, no Starburst-only features).

## Gaps / Errors
- Does not mention the equivalent `USE <catalog>.<schema>; CALL system.flush_metadata_cache();` form shown in the official docs — both forms are valid; mentioning both would be more complete.
- The recommended `metadata.cache-ttl=60s` is presented as "a common production setting" without explaining *why* one would enable caching at all in a low-migration-frequency Postgres (saves repeated `information_schema` round-trips to Postgres on planning) — a one-line "why turn it on" rationale would strengthen the recommendation.
- Minor: does not mention that the flush is per-coordinator/worker JVM and in a multi-node cluster the procedure is broadcast to all nodes (most engineers won't hit this, but in a large cluster it's reassuring to know).
- The "after a schema migration, either wait 60 seconds or run `CALL ...`" guidance is good, but does not call out that the *migration runbook* should add `CALL ... flush_metadata_cache()` as a post-step so engineers don't have to remember.
- No mention of `metadata.cache-missing=true` rationale — it's listed in the config block without explanation of what it does (caches negative lookups, prevents repeated probes for not-yet-created tables).
