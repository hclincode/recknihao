# Answer to Q1: CTAS / Write-Side Exfiltration in Multi-Tenant Trino (Iter 310)

Yes, this is a real risk — and it's called the **write-side exfiltration surface**. The view-per-tenant setup controls **read access** — Trino's authorization layer prevents tenant A from querying the base table directly, and their view filters their own rows. But the view does NOT prevent a tenant from writing.

## Why the Risk Is Real

When customer A runs:
```sql
CREATE TABLE acme_scratch.exfil AS SELECT * FROM tenant_acme.events;
```

They now own a table in their own schema containing their data. From Trino's perspective, this is valid — they created it, they own it. But then they can query the metadata layer:
```sql
SELECT file_path FROM acme_scratch."exfil$files";
```

This returns the actual MinIO object storage paths for the Parquet files they created. If they have S3/MinIO credentials (or can extract them), they can read those files directly and bypass Trino entirely. The view filter is worthless at that point because they're not going through Trino anymore.

The core problem: **Trino controls SQL access; it doesn't control who can reach MinIO directly.** A tenant who discovers their data's MinIO path and holds credentials can bypass all query-layer isolation.

## How to Close It (Layered Approach)

Implement all four mitigation layers:

### 1. Deny CREATE TABLE / CTAS Outside the Tenant's Own Schema (OPA Rule)

Your OPA policy must explicitly deny `CreateTable` and `CreateTableAsSelect` operations unless the target schema matches the tenant's allowed scratch space. For tenant `acme`, that means:

- Allow: `CreateTable`/`CTAS` into `iceberg.acme_scratch.*` only
- Deny: any attempt to CTAS into `iceberg.analytics.*`, `iceberg.public.*`, or any other shared schema
- Deny: any attempt to create a table in another tenant's scratch space (e.g., `iceberg.beta_scratch.*`)

This stops the attacker at step 1. But don't stop there — assume this rule could misfire.

### 2. Deny Metadata-Table Access on ALL Iceberg Metadata Tables (OPA Rule)

Even if a tenant owns the scratch table they created, they cannot learn the file paths without `$files` access. Add an OPA rule that denies any query from a tenant principal where the table name contains `$` — covering all of these: `$files`, `$partitions`, `$snapshots`, `$manifests`, `$all_metadata_entries`, etc.

Your CI test (run as a tenant principal):
```sql
SELECT * FROM iceberg.acme_scratch."exfil$files" LIMIT 1;  -- must fail with Access Denied
```

### 3. Restrict MinIO IAM Credentials at the Object-Storage Layer

Even if the first two rules fail and a tenant somehow learns the file paths, they should not be able to read them from MinIO. This is the belt-and-suspenders layer.

**Option A (stronger):** Tenants get **no direct MinIO credentials** at all. Trino is the only client that reads MinIO. If a tenant needs bulk export, route it through an explicit export endpoint you control — not direct S3 reads. That endpoint can produce a time-limited, signed download URL for a CSV or Parquet file in a tenant-isolated location.

**Option B (if you must give MinIO access):** Tenant credentials are scoped to paths they own only. Their MinIO IAM policy allows `s3:GetObject` only on `s3://lakehouse/warehouse/acme_scratch/*`, **not** on the broader warehouse bucket. This prevents reading other tenants' files or the analytics base table's files, but still allows reading within their own scratch space.

### 4. Audit-Log Every CTAS and Alert

Add a CI assertion and a production alert. The HTTP event listener should capture every `CreateTableAsSelect` operation (check `input.action.operation` in the OPA decision logs).

- **CI test:** As a tenant principal, attempt `CREATE TABLE iceberg.analytics.exfil_attempt AS SELECT * FROM tenant_acme.events;` and verify it fails with `Access Denied`.
- **Production alert:** If a `CreateTableAsSelect` succeeds for a tenant principal AND the target schema is not their own scratch space, page immediately. This is a P0 cross-tenant data leak.

## What Happens If a Customer Somehow Builds Their Scratch Table Anyway

If OPA rule #1 misfires and they create a scratch table, layers 2 and 3 still protect you:

1. **OPA rule #2 stops them from discovering file paths** — `SELECT * FROM <scratch>.$files` is denied.
2. **MinIO credentials don't grant access** — even if they know the path, their IAM policy doesn't allow reading it.

So a single rule failure or misconfiguration doesn't create an all-or-nothing hole.

## Where to Implement These Rules

The actual OPA Rego code lives in your external governance document. Your OPA bundle should already have the baseline deny rules for `system.runtime.queries` and `$`-suffix metadata tables; add the write-side rules to the same policy file.

**Summary checklist:**
- OPA denies `CreateTableAsSelect` to any schema except the tenant's own scratch
- OPA denies all metadata-table reads (`$files`, `$partitions`, etc.) for tenant principals
- MinIO IAM credentials for tenants (if they exist) are path-scoped, not bucket-wide
- CI tests verify both positive (tenant can write to their scratch schema) and negative (cannot access metadata tables, cannot CTAS to analytics)
- Production alerts fire on any unexpected `CreateTableAsSelect` in the decision logs

This approach — multiple overlapping layers, each independently sufficient — is what lets you expose customer-facing ad-hoc query access safely.
