# Answer to Q2: MERGE INTO ON Clause Must Use the Primary Key (Iter 342)

The rule is: **the ON clause must use a column (or column tuple) that uniquely identifies a single row in the target table**. In practice, that means your primary key. Using `updated_at`, `tenant_id`, or any other non-unique column breaks MERGE INTO in one of three ways.

## Why it must be unique

MERGE INTO works by matching each source row to exactly one target row. The ON clause is that match. If the ON clause can match multiple target rows — which happens with `tenant_id` (many rows per tenant) or `updated_at` (many rows per timestamp) — the behavior is undefined or corrupt:

1. **Parse error / query failure** — Iceberg detects the ambiguous multi-row match and fails the query with an error.
2. **Cross-join blowup** — If Iceberg processes it at all, every source row fans out across every matching target row, generating enormous intermediate results and likely corrupting data.
3. **Silent over-update** — A too-broad ON clause (like `tenant_id`) causes one source row to overwrite *all* target rows for that tenant — silently replacing many rows with the same value.

## Correct pattern

```sql
MERGE INTO iceberg.analytics.events t
USING events_delta s
ON t.event_id = s.event_id       -- PRIMARY KEY — uniquely identifies one row
WHEN MATCHED THEN UPDATE SET *
WHEN NOT MATCHED THEN INSERT *
```

The ON clause must be the same column(s) that form the primary key in your Postgres table. If the primary key is composite, use all parts:

```sql
ON t.tenant_id = s.tenant_id AND t.event_id = s.event_id
```

## Why specific column choices fail

| Column | Why it fails as an ON clause |
|---|---|
| `updated_at` | Multiple rows often share the same timestamp (same second or millisecond). MERGE matches all of them. |
| `tenant_id` | One tenant has thousands of rows. All match a single source row. |
| `created_at` | Same problem as `updated_at`. |
| `id` (primary key) | Correct — uniquely identifies one row per table. |

## Why this matters for idempotency

Your incremental sync will re-read a small overlap window on each run (due to the lag buffer). MERGE INTO is safe to re-run precisely because the primary key ON clause ensures that rows already in Iceberg get updated in place rather than duplicated. A non-unique ON clause breaks this property: re-read rows either error or corrupt data instead of idempotently updating.

## The one rule

> The ON clause must use the target table's primary key (or a column tuple that is unique within the target). If you can't name what makes a row unique in your table, you can't write a correct MERGE INTO.

**Resources cited:** `/Users/hclin/github/recknihao/resources/13-postgres-to-iceberg-ingestion.md`
