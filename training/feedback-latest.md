# Feedback — Iter 280 (Extended phase)

Date: 2026-05-27
Topic: Trino federation — Postgres type mapping (Q1 PASS) + Postgres schema cache flush (Q2 FAIL)

## Results summary

| Question | Topic angle | Score | Pass/Fail |
|---|---|---|---|
| Q1 | Postgres type mapping: jsonb→JSON, IGNORE silent drop, CONVERT_TO_VARCHAR, enum→VARCHAR, array-mapping | **4.95** | PASS |
| Q2 | Postgres schema cache: metadata.cache-ttl, flush_metadata_cache() parameterless for JDBC, SELECT* freeze, TTL | **4.30** | FAIL |

**Iter 280 average: 4.625 — mixed** (Q2 FAIL from wrong flush parameters)

**Topic update**: Trino federation: 4.489/233 → **4.490/235** (NEEDS WORK, gap 0.010)

---

## What worked

### Q1 — Postgres type mapping (4.95 — near-perfect)
1. jsonb → Trino JSON natively — verified
2. postgresql.unsupported-type-handling=IGNORE (default) → silent column drop — verified
3. CONVERT_TO_VARCHAR fix — verified
4. Diagnostic method: Postgres \d vs Trino DESCRIBE + JDBC DEBUG logging — excellent
5. postgresql.array-mapping: DISABLED (default)/AS_ARRAY/AS_JSON — verified
6. Custom ENUM types → VARCHAR natively — verified
7. Naming convention: hyphens in catalog file, underscores in session property — correct
8. Concrete next-steps checklist — excellent

### Q2 — Postgres schema cache (4.30 FAIL)
What worked:
1. Metadata cache existence and metadata.cache-ttl property — correct
2. metadata.cache-ttl=0s default (disabled) — correct
3. SELECT* view freeze problem and CREATE OR REPLACE VIEW fix — correct
4. Iceberg contrast (no flush_metadata_cache for Iceberg) — correct
5. Coordinator-only scope — correct

---

## Errors / gaps (Q2 — caused FAIL)

### Q2 — flush_metadata_cache parameters WRONG

The answer included `schema_name => 'public', table_name => 'users'` as named parameters to `flush_metadata_cache()` for the PostgreSQL connector. A judge verified against official Trino docs: **the JDBC-based PostgreSQL connector's `flush_metadata_cache()` is parameterless**. Those named parameters (`schema_name =>`, `table_name =>`) only exist for the Delta Lake and Hive connectors.

Correct syntax for PostgreSQL connector:
```sql
CALL app_pg.system.flush_metadata_cache();   -- parameterless, clears entire catalog
```

Wrong (Delta Lake / Hive syntax only):
```sql
CALL app_pg.system.flush_metadata_cache(schema_name => 'public', table_name => 'users');  -- ERROR on JDBC
```

**Root cause:** The resource had a correctly-labeled WRONG example but it wasn't prominent enough; the responder provided the wrong parameterized form anyway. Teacher281 has now added a prominent at-a-glance bullet distinction at the top of the flush callout.

---

## Resource fixes completed (teacher281)

1. **flush_metadata_cache parameter distinction** (resource 22, Section 2.6):
   - Added explicit bullet contrast: PostgreSQL/JDBC = parameterless; Hive/Delta = `schema_name =>` / `table_name =>`
   - Existing 13 PostgreSQL flush calls already in parameterless form — confirmed correct
   - WRONG example at line 690 preserved intentionally as a do-not-copy demonstration

---

## Suggested iter281 angles (MUST target Trino federation, gap 0.010)

Topic at 4.490/235. Need ~5 more questions at 4.875+ to cross 4.500 threshold.

1. **Re-test: Postgres schema cache flush** — same angle but ensure answer does NOT include named parameters for PostgreSQL connector; resource now has prominent callout

2. **Multi-tenant cross-schema federation** — engineer wants to query multiple tenant schemas (one per customer) dynamically; Trino cannot use dynamic schema names (static planning); UNION ALL generator in Python; system.query() for discovery; Iceberg with tenant_id + bucket partitioning

3. **Postgres type mapping re-test** — variation: engineer has uuid columns, hstore, or custom range types; how to expose them; CONVERT_TO_VARCHAR; uuid→UUID native mapping

4. **Trino connector authentication to Postgres** — engineer asks about SSL/TLS connection to Postgres through Trino, SSL trust store config, read-only role for the trino user

5. **Federation at read-replica** — engineer wants to point Trino at a Postgres read replica to avoid OLTP load; connection string; implications for stale reads; when to use system.query() vs normal federation
