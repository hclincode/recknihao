# Score — Iter286 Q1

**Score: 4.90/5.0 PASS**

## Breakdown
- Technical accuracy (40%): 5/5 — Default 1s confirmed via trino.io docs. Correctly states Iceberg has no session property; correctly contrasts with Hive's `<hive-catalog>.dynamic_filtering_wait_timeout`. Catalog config key `iceberg.dynamic-filtering.wait-timeout` and the requirement of coordinator restart are correct. The build/probe side identification (Postgres 50K = build, Iceberg 200M = probe) matches Trino's join-reordering behavior.
- Completeness (25%): 5/5 — Covers diagnosis, the catalog-only property, restart requirement, explicit failure mode of the session-property attempt, three workarounds (selective WHERE, second catalog, ingest into Iceberg), and EXPLAIN ANALYZE verification with `dynamicFilterSplitsProcessed`.
- Production fit (20%): 5/5 — Fits Trino 467 + Iceberg 1.5.2 + on-prem Kubernetes well. The "second Iceberg catalog with longer timeout" is a particularly strong on-prem k8s suggestion since it avoids restarting the primary catalog. The ingest-to-Iceberg path aligns with the documented Spark+Iceberg ingestion stack.
- Clarity (15%): 4/5 — Very clear about the no-session-property gotcha, with a literal failing SQL example. The tradeoff section is concise. Minor nit: could explicitly call out that "second catalog" still requires adding a new properties file (small operational point), but otherwise actionable.

## What was correct
- Default wait-timeout of 1s
- Iceberg connector exposes the timeout only as catalog config `iceberg.dynamic-filtering.wait-timeout`
- No session property exists for Iceberg's wait timeout
- Correct contrast with Hive's session property form
- Coordinator restart required for catalog config change
- All three workarounds (selective predicate, second catalog, ingest to Iceberg) are valid
- EXPLAIN ANALYZE verification with `dynamicFilterSplitsProcessed > 0`
- Correct build/probe side identification

## Errors or gaps
- None significant. The failing-SQL snippet uses underscores (`iceberg.dynamic_filtering_wait_timeout`) which is the natural guess a user would try — useful pedagogically. Could have added one line that adding a new catalog file also requires propagation to all worker nodes in k8s (typically a ConfigMap reload), but this is minor.

## Verification
- trino.io/docs/current/connector/iceberg.html (WebFetch): `iceberg.dynamic-filtering.wait-timeout` default = `1s`; no session property documented for this setting.
- trino.io/docs/current/connector/hive.html (WebSearch): Hive connector exposes BOTH `hive.dynamic-filtering.wait-timeout` config and `<hive-catalog>.dynamic_filtering_wait_timeout` session property — confirms the answer's contrast.
- GitHub issue trinodb/trino#11600 ("Use dynamic-filtering.wait-timeout for delta lake connector") corroborates that this property family exists per-connector and is exposed inconsistently (Hive has session form; Delta/Iceberg historically did not).
