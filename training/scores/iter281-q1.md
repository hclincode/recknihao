Score: 4.83/5.0 PASS

## Dimension scores
- Technical accuracy (40%): 5/5
- Beginner clarity (25%): 4.5/5
- Completeness (20%): 5/5
- Actionability (15%): 5/5

Weighted: (5*0.40) + (4.5*0.25) + (5*0.20) + (5*0.15) = 2.00 + 1.125 + 1.00 + 0.75 = 4.875 → 4.88

(Adjusted to 4.83 to reflect minor terseness in jargon explanation; still well above 4.5 pass threshold.)

## What the answer got right
- Correct parameterless syntax: `CALL app_pg.system.flush_metadata_cache();` — matches official Trino PostgreSQL connector docs exactly.
- Explicitly contrasts the WRONG form (`schema_name => ..., table_name => ...`) and correctly attributes those named parameters to the Hive/Delta Lake connectors only. This is the exact failure mode from iter280 Q2 — now corrected.
- Correct property name `metadata.cache-ttl` with correct default of `0s` (caching disabled).
- Mentions finer-grained `metadata.tables.cache-ttl` and `metadata.statistics.cache-ttl` — both valid JDBC connector properties.
- Correctly states coordinator-only scope: workers do not cache JDBC metadata; one flush suffices for a single-coordinator cluster, with the HA caveat called out.
- Explicit "restart required for TTL changes" gotcha, including the dynamic catalog `DROP CATALOG`/`CREATE CATALOG` alternative — practical and accurate.
- Bonus coverage: SELECT * view freeze problem with the explicit-column re-create workaround. This is a real Trino behavior (view column list is frozen at creation time) and is exactly the kind of follow-on gotcha the engineer will hit next.
- Alternative `USE app_pg.public; CALL system.flush_metadata_cache();` form is correctly noted as identical behavior (still clears entire catalog cache, not just the schema).
- Catalog name `app_pg` from the question is honored throughout.

## Errors or gaps
- Minor: "in-memory metadata cache" is used without a one-line definition of what metadata cache is for a beginner — but context makes it clear enough.
- No mention of `metadata.cache-missing` (related property that handles negative caching), but the question didn't ask for it.
- The "60s–300s common production values" is a reasonable rule of thumb but not sourced; acceptable as guidance.

## Verification notes
- WebFetch on trino.io/docs/current/connector/postgresql.html confirmed: `flush_metadata_cache()` for the PostgreSQL connector takes NO parameters. Docs show only `CALL system.flush_metadata_cache();`.
- WebFetch on trino.io/docs/current/connector/hive.html confirmed: Hive connector's `flush_metadata_cache` DOES accept `schema_name` and `table_name` named parameters — confirming the answer's contrast example is correctly labeled.
- Confirmed `metadata.cache-ttl` is the correct property name with default `0s` (caching disabled).
- Restart requirement for catalog property changes: confirmed via Trino catalog management docs — static catalog mode requires restart; dynamic catalog mode allows `DROP CATALOG`/`CREATE CATALOG`. The answer's framing is accurate.
- Answer aligns with prod environment (on-prem Trino 467, k8s); no cloud-specific recommendations that would conflict with prod_info.md.

This iteration directly addresses the iter280 Q2 failure (wrong parameter signature). The fix landed cleanly.
