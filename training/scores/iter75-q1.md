# Iter 75 Q1 — Judge Score

**Topic**: Multi-tenant analytics
**Score date**: 2026-05-25

| Dimension | Score |
|---|---|
| Technical accuracy | 4 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.75** |

## Points covered

1. **Both models clearly described** — COVERED WELL. Model 1 (shared table with `tenant_id` + `day(occurred_at)` partitioning) and Model 2 (separate schema per tenant) are both clearly named, defined, and contrasted up front.
2. **Schema evolution burden** — COVERED WELL. Explicit "1 ALTER vs 200 ALTERs", plus correct mention that Iceberg makes ADD COLUMN metadata-only and back-fills NULLs for old files. Also raises the realistic schema-drift operational pain.
3. **Hive Metastore overhead at scale** — COVERED WELL. Concrete math (10 tables × 200 tenants = 2,000 entries today, 4,000+ in two years), names the failure modes (partition enumeration, planning, ingest job latency) and the workaround (separate metastore instances per tier).
4. **Cross-tenant analytics complexity** — COVERED WELL. Contrasts a single GROUP BY against a 200-way UNION ALL or a separate rollup job. Acknowledges maintenance burden of UNION ALL as tenants are added.
5. **Isolation guarantees** — COVERED. Explicitly states that separate schemas do not eliminate the need for OPA, and that shared table + views + OPA is equivalently safe. Adds the defense-in-depth argument.
6. **Clear recommendation for 200 tenants/15-20 per month** — COVERED WELL. Four numbered reasons tied directly to the engineer's scenario.
7. **`SECURITY INVOKER` view pattern in SQL** — PARTIALLY COVERED. The SQL is shown with correct Trino syntax (`CREATE VIEW ... SECURITY INVOKER AS SELECT ...`), but the surrounding narrative is technically wrong (see Issues).

## Issues found

**Main technical issue — `SECURITY INVOKER` semantics misstated**. The answer asserts:

> "Since `acme-service-account` has no base-table access, the isolation is enforced at the database level — not just by the `WHERE` clause in the view."

This is incorrect for `SECURITY INVOKER`. Per the Trino docs, `SECURITY INVOKER` means base tables are accessed with the **caller's** permissions. If the caller has had `ALL PRIVILEGES` revoked on `analytics.events`, the view query would fail at planning, not silently filter to one tenant. The pattern of "user has no base-table grant but can query through the view" is the `SECURITY DEFINER` semantics (the Trino default), not `SECURITY INVOKER`.

In practice in this production environment (OPA-backed Trino), OPA — not native Trino GRANT/REVOKE — is the authorization layer, and OPA can grant base-table access to the tenant role while constraining row visibility. So the `SECURITY INVOKER` choice is defensible because OPA centralizes the enforcement and the view becomes "just a stored query that adds a tenant filter." But the answer's specific defense-in-depth claim — that `REVOKE ALL` on the base table plus `SECURITY INVOKER` protects against a buggy WHERE clause — is not how `SECURITY INVOKER` actually behaves.

**Secondary observation**. The SQL mixes Trino-native `CREATE ROLE` / `GRANT` / `REVOKE` with a production stack that uses OPA for authorization (per `prod_info.md`). Native Trino GRANT/REVOKE generally do not take effect under OPA-backed access control. A more environment-aware example would frame the GRANTs as "what OPA policy must allow" rather than as Trino DDL the engineer should literally run.

These issues are real but narrow — the structural reasoning (when to pick each model, why 200 tenants implies Model 1) is correct and well-argued.

## Accuracy verification

- **Trino `CREATE VIEW SECURITY INVOKER` syntax**: verified against Trino docs (`CREATE [OR REPLACE] VIEW view_name [COMMENT ...] [SECURITY {DEFINER | INVOKER}] AS query`). Answer's SQL is syntactically correct. Sources: trino.io/docs/current/sql/create-view.html.
- **Default security mode is DEFINER**: confirmed. The answer does not state this explicitly but does not contradict it either.
- **SECURITY INVOKER vs DEFINER semantics**: verified — INVOKER runs with caller's permissions, DEFINER runs with view owner's permissions. The answer's narrative about defense-in-depth via REVOKE on the base table is inconsistent with INVOKER semantics (see Issues).
- **Iceberg `ALTER TABLE ADD COLUMN`**: verified as a metadata-only operation; existing files get NULL for the new column (no rewrite). Answer is correct. Source: iceberg.apache.org schema evolution docs.
- **Iceberg partition pruning by `tenant_id`**: verified — equality predicates on partition columns prune to the matching partition. Answer is correct. Sources: Trino Iceberg connector docs, Starburst Iceberg partitioning blog.
- **Hive Metastore degradation at thousands of tables/partitions**: verified — real-world reports of metastore RDBMS becoming the bottleneck at large scale; recommended limit ~10,000 partitions per query. Answer's framing is correct.

## Resource fix needed?

**Minor**. `resources/05-multi-tenant-analytics.md` should clarify the `SECURITY INVOKER` vs `SECURITY DEFINER` distinction explicitly:
- `SECURITY DEFINER` (Trino default) — caller does NOT need base-table grant; view runs as the owner. Good for native-RBAC isolation patterns.
- `SECURITY INVOKER` — caller DOES need base-table access; the view is "a saved query that adds a WHERE filter." In an OPA-backed stack, the WHERE filter convenience is fine, but the defense-in-depth claim ("REVOKE on base table blocks accidental leaks") only holds for DEFINER, not INVOKER.

This will prevent future answers from repeating the inverted defense-in-depth claim seen here.

## Updated topic average

Prior: 4.401 across 72 questions
New: (4.401 × 72 + 4.75) / 73 = (316.872 + 4.75) / 73 = 321.622 / 73 = **4.406** across 73 questions. PASSED.
