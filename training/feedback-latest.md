# Feedback — Iteration 53 (Extended Phase)

**Date**: 2026-05-24
**Phase**: Extended (continuing until 2026-05-30 12:00 CST)
**Iteration average**: 4.00
**Status**: All 20 topics PASSED.

---

## Iteration 53 score summary

| Question | Topic(s) | Score |
|---|---|---|
| Q1 — Resource group selectors: JWT `sub` claim and `"user"` field syntax | Multi-tenant analytics | 3.50 |
| Q2 — Bytes-per-event measurement from `$files` for storage budget planning | Storage sizing and growth estimation | 4.50 |
| **Iteration average** | | **4.00** |

---

## Topic score updates after iteration 53

| Topic | Prior avg | Prior q | New avg | New q | Change |
|---|---|---|---|---|---|
| Multi-tenant analytics | 4.270 | 52 | 4.255 | 53 | −0.015 (Q1 at 3.50) |
| Storage sizing and growth estimation | 4.333 | 3 | 4.375 | 4 | +0.042 (Q2 at 4.50) |

Both topics remain PASSED (above 3.5).

---

## What went well

**Q2 scored 4.50 — cost-per-event model mostly complete.** The responder correctly covered:
- `$files` metadata table with correct quoted Trino syntax (`"events$files"`)
- `file_size_in_bytes` / `record_count` columns for bytes-per-row
- Monthly growth formula with worked example (50M page views × 6.2 bytes = 310 MB/month)
- Per-column compression breakdown (dictionary encoding, delta encoding, UUIDs)
- 20–30% buffer with three sources (small files pre-compaction, metadata, new-customer variation)
- MinIO EC:4+2 = 1.5x raw disk (not 2x or 3x)
- Zstd default in Iceberg 1.4.0+ with correct `ALTER TABLE ... SET PROPERTIES` Trino syntax

**Q1 conceptual model correct.** The JWT `sub` → Trino username → resource group selector mapping was correctly explained. Silent failure mode (no-match → default pool) was correctly identified. Verification via `system.runtime.queries` was present. The `CALL system.runtime.kill_query(...)` syntax was correct.

---

## Issues

### Q1 critical bug: fabricated selector field name `"userRegex"` (correct name is `"user"`)

The answer's JSON example used `"userRegex"` as the selector field name — but this field does not exist in Trino. The actual field is `"user"`. The value of `"user"` is interpreted as a Java regex, which makes `"userRegex"` an intuitive but wrong name.

From the Trino resource groups docs: `"user"` is a selector field that matches the username as a Java regex. `"userRegex"` is not a valid field; it is silently ignored. An engineer copy-pasting the Q1 answer's JSON would reproduce exactly the silent-no-match bug they were trying to fix.

The correct resource (05-multi-tenant-analytics.md) already used `"user"` correctly at lines 484–496. The responder hallucinated `"userRegex"` despite reading the correct example.

**Fix applied**: `resources/05-multi-tenant-analytics.md` — added an explicit callout block in the "use correct property names" section naming `"userRegex"` as a fabricated field that does not exist, with a correct vs wrong side-by-side JSON example.

### Q2 technical bug: `$files` per-event-type GROUP BY is invalid

The answer included:
```sql
SELECT
  event_type,
  SUM(file_size_in_bytes) * 1.0 / SUM(record_count) AS bytes_per_row
FROM iceberg.analytics."events$files"
GROUP BY event_type
```

`$files` is file-level metadata — it has `file_path`, `file_size_in_bytes`, `record_count`, `partition`, etc., but NOT row-level columns like `event_type`. This query fails with "Column 'event_type' cannot be resolved".

The correct approaches:
- If table is partitioned by `event_type`: `GROUP BY partition.event_type` on `$files`
- If not partitioned by `event_type`: sample from the base table via Spark

**Fix applied**: `resources/11-lakehouse-storage-sizing.md` — added "Measuring bytes-per-row from existing Iceberg data ($files approach)" subsection with the correct overall query, an explicit warning that `$files` is file-level (no row-level columns), and both Option A (partition column) and Option B (base table sampling) approaches for per-event-type breakdown.

### Recurring issues

- Q1: Missing `clientTags` and `source` as alternative selector fields; `query.max-memory-per-node` as per-query hard cap not mentioned.
- Q1 + Q2: Beginner clarity — WAL, replication slot, schema registry, $files metadata table — appear without inline glosses.

---

## Resource fixes applied in iter53

**HIGH priority — COMPLETED**: `resources/05-multi-tenant-analytics.md`
- Added selector field name callout: `"user"` is the correct Trino field (value is a regex); `"userRegex"` does not exist and is silently ignored. Correct vs wrong JSON side-by-side.

**HIGH priority — COMPLETED**: `resources/11-lakehouse-storage-sizing.md`
- Added "Measuring bytes-per-row from existing Iceberg data ($files approach)" subsection: overall `$files` query, explicit warning that `$files` is file-level not row-level, Option A (partition column), Option B (base table Spark sampling), Option C (quick approximation).

---

## Weakest topics heading into iter54

| Topic | Avg | q |
|---|---|---|
| Multi-tenant analytics | 4.255 | 53 |
| Postgres-to-Iceberg ingestion | 4.275 | 53 |
| Storage sizing and growth estimation | 4.375 | 4 |
| Analytical query patterns on Iceberg+Trino | 4.438 | 4 |
| Iceberg partition design | 4.500 | 6 |

Novel angles for iter54:
- **Multi-tenant**: Post-fix validation — test resource group `"user"` field now that resource is fixed; or test OPA integration angle (how OPA blocks system.runtime.queries for tenant principals)
- **Postgres-to-Iceberg**: Post-fix validation — test CDC schema evolution with relation messages (now in resource); or test column TYPE CHANGE (INT → BIGINT widening) under CDC
- **Storage sizing**: Post-fix validation — test `$files` per-event-type query (both partition column and base-table sampling approaches now in resource)
- **Analytical patterns**: NTILE for percentile distribution; RANK vs DENSE_RANK for ranking tenants
