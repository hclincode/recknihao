# Judge Feedback — Iter 308

Date: 2026-05-27
Phase: extended
Topics: Multi-tenant isolation with Trino views (Q1) + JSONB column promotion during Postgres→Iceberg ingestion (Q2)

---

## Q1 — Multi-tenant isolation with Trino views + OPA

### Score

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | SECURITY DEFINER default verified against trino.io/docs/current/sql/create-view.html. CREATE ROLE / GRANT ROLE syntax verified. OPA as the back-door closer is consistent with prod_info.md and trino.io OPA access control docs. View inlining behavior with bound predicates is correctly characterized. |
| Beginner clarity | 4.5 | Lead-in ("why trust-the-code fails") frames the problem well. SECURITY DEFINER jargon is introduced but explained in plain English on the next line. Customer A vs Customer B walkthrough makes the abstraction concrete. Small nit: "view body executes with the view owner's privileges" appears before any explanation of what "view owner" means — a one-line intro to the privileged service account would help a true beginner. |
| Practical applicability | 5.0 | DDL is copy-pasteable and ordered as an onboarding script (table → schema → view → role → grant role → grant select). Fits the prod_info.md stack exactly: Iceberg connector, MinIO, OPA as the authz backend, no invented specific OPA policy. Operational notes call out OPA bundle propagation, schema drift, and 80-tenant scaling — all real concerns. |
| Completeness | 4.5 | Hits every key point from the rubric checklist: SECURITY DEFINER, grant-on-view-not-base, full DDL, OPA closing the back door, Access Denied examples, metadata leak surfaces (system.runtime.queries, $files, $partitions), CI verification queries. Minor gap: no mention of column masking as an alternative for partial column exposure; UNION ALL example shown but cross-join / subquery / CTAS exfil vectors not enumerated; no mention that view security mode can be made explicit with `SECURITY DEFINER` keyword (relies on default). |
| **Average** | **4.75** | **PASS** |

### What Worked
- Crisply states SECURITY DEFINER is Trino's default and explains the mechanism in one sentence
- DDL is end-to-end and runnable on the prod stack (Iceberg, MinIO-backed)
- Correctly separates the two enforcement layers: view+grant (front door) and OPA (back door)
- Concrete bypass attempts (direct base table, cross-tenant view, UNION ALL) with expected Access Denied outcomes
- Calls out the often-missed metadata leak vectors: `system.runtime.queries`, `events$files`, `events$partitions`
- CI verification block is exactly what a security team will ask for
- Respects prod_info.md boundary: mentions OPA conceptually, does not invent specific Rego policies
- Operational notes cover OPA bundle propagation lag and 80-tenant scaling via Terraform/templating

### What Missed
- No mention of column masking / row filtering as an alternative pattern OPA can supply (the OPA plugin can return row filters that behave like WHERE clauses — could be noted as a per-row alternative to per-tenant views at scale)
- Could note explicit `SECURITY DEFINER` keyword in CREATE VIEW for documentation/clarity even though it is the default
- CTAS / INSERT INTO ... SELECT exfiltration (creating a temp table the customer owns and then exporting from MinIO per the prod_info.md ad-hoc export pattern) not addressed as a possible bypass surface
- "View owner" not defined explicitly before being used (minor clarity gap for a true beginner)

### Technical Accuracy
No incorrect claims. All verified:
- SECURITY DEFINER is Trino's default view security mode (trino.io/docs/current/sql/create-view.html)
- CREATE ROLE and GRANT ROLE TO USER syntax is valid Trino (trino.io/docs/current/sql/create-role.html, /grant-roles.html)
- OPA can deny base table access per the opa-access-control plugin (trino.io/docs/current/security/opa-access-control.html)
- Iceberg `$files` and `$partitions` metadata tables exist and leak data volume info (trino.io/docs/current/connector/iceberg.html)

### Rubric Update
- Multi-tenant analytics: prior avg 4.464 across 108 questions → (4.464 × 108 + 4.75) / 109 = **4.467 across 109 questions**. Status: PASSED (well above 3.5 threshold).

---

## Q2 — JSONB column promotion during Postgres→Iceberg ingestion

### Score

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | `get_json_object(col("properties"), "$.key")` PySpark syntax is correct. `JSON_EXTRACT_SCALAR` Trino/dbt-trino usage is correct and distinguished from the PySpark function. Two-tier pattern (promoted columns + properties_raw fallback) is standard practice. Iceberg ADD COLUMN as metadata-only is correct. Historical rows returning NULL for new columns is correctly characterized as the silent data-loss trap. MERGE INTO backfill syntax is valid Trino/Iceberg. |
| Beginner clarity | 4.5 | "Why promoting JSON fields matters" section leads with concrete latency numbers (1–3s vs 30–45s) — immediately motivating. Two-tier pattern explained with clear 80/20 framing. "Do you have to reprocess historical data?" section directly answers a common beginner fear. Minor nit: the MERGE INTO backfill script is long and may feel daunting; a one-line summary of what MERGE does before the code block would help. |
| Practical applicability | 5.0 | Spark job is copy-pasteable with JDBC connection parameters matching prod_info.md stack. dbt approach included with the correct `JSON_EXTRACT_SCALAR` (not `get_json_object`). Decision table for promote-vs-keep is actionable. Backfill verify query (`still_null` check) is exactly what an engineer will run to confirm completeness. |
| Completeness | 4.5 | Covers the main pattern comprehensively. Minor gaps: no mention of `schema_of_json` / `from_json` for full struct promotion when schema is known ahead of time; no coalesce fallback pattern for queries during partial backfill; Iceberg snapshot isolation during MERGE backfill not discussed (safe but could note it). |
| **Average** | **4.75** | **PASS** |

### What Worked
- Clear explanation of why JSON-as-blob kills query performance (no min/max stats, forced re-parse per row)
- Two-tier pattern (promote hot keys + keep properties_raw) is the right production recommendation
- get_json_object vs from_json distinction explained correctly with practical guidance
- Historical backfill trap (NULLs in new column for old rows) called out with DANGEROUS warning before the code
- MERGE INTO backfill with verification query — complete, runnable
- Spark vs dbt table distinguishes when to use each (bulk ingest vs ongoing pipeline)
- Future promotion workflow (ALTER TABLE + update job + backfill + verify + wire dashboards) is exactly the four-step process engineers will follow
- Note that dbt-trino uses JSON_EXTRACT_SCALAR not get_json_object — prevents a common cross-environment mistake

### What Missed
- No mention of `schema_of_json` + `from_json` for cases where JSON schema is known (can promote an entire nested struct, not just individual keys)
- No coalesce fallback pattern for queries hitting a partially-backfilled table (e.g., `COALESCE(device_type, JSON_EXTRACT_SCALAR(properties_raw, '$.device_type'))` as a transitional query pattern)
- Iceberg snapshot isolation during the MERGE backfill not discussed — relevant for tables with concurrent writes during backfill
- Backfill time estimate ("a few hours") is reasonable but no guidance on parallelizing the MERGE with multiple non-overlapping tenant_id ranges

### Technical Accuracy
No incorrect claims. All verified:
- `get_json_object` PySpark function signature correct (spark.apache.org docs)
- `JSON_EXTRACT_SCALAR` is the correct Trino function (trino.io/docs/current/functions/json.html)
- Iceberg `ALTER TABLE ... ADD COLUMN` is metadata-only (iceberg.apache.org/docs/current/spark-ddl/#alter-table--add-column)
- MERGE INTO syntax is valid for Iceberg via Trino (trino.io/docs/current/sql/merge.html)
- Historical rows return NULL for newly added columns — correct Iceberg behavior due to field-ID tracking

### Rubric Update
- Postgres-to-Iceberg ingestion: prior avg 4.484 across 103 questions → (4.484 × 103 + 4.75) / 104 = **4.487 across 104 questions**. Status: PASSED.

---

## Iter 308 Summary

**Iter 308 average: 4.75 — PASS** ✓

### Suggested focus for Iter 309
- OPA row-filter alternative to per-tenant views (column masking / row-level filtering via OPA plugin) — multi-tenant at 200+ tenant scale
- CTAS/INSERT exfiltration as a bypass surface in multi-tenant Trino — what OPA policies must block beyond just base-table SELECT
- Iceberg snapshot isolation during MERGE backfill — concurrent write safety
- `schema_of_json` + `from_json` for full struct promotion when JSON schema is stable
- Replication slot WAL bloat — the #1 Debezium production incident (slot falls behind, WAL disk fills, Postgres hangs)
