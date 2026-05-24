# Iter53 Questions

**Date**: 2026-05-24
**Weakest topics**: Multi-tenant analytics (4.270, 52q), Storage sizing and growth estimation (4.333, 3q)

---

## Q1 — Multi-tenant analytics: resource group selectors and JWT token fields

**Question**: We set up per-tenant Trino roles and views to keep customers isolated from each other's data. But one of our bigger tenants keeps running huge queries that slow things down for everyone else. Someone on our team mentioned "resource groups" as a way to give that tenant its own memory and CPU limit so they can't starve everyone else. I found the Trino resource group JSON config and added a memory limit, but it's not doing anything — queries from that tenant still pile up and affect others.

I think the problem is the selector. From what I can tell, the resource group config has a `selector` section that routes users into a group, but I don't know what field to match on. We use JWT tokens for auth — users get a JWT from our auth service and Trino validates it. The JWT has claims like `sub`, `tenant_id`, and `roles`. Which of those fields shows up in the Trino session so that the resource group selector can actually match on it, and how do I write the selector correctly?

**Target topic**: Multi-tenant analytics: isolating customer data in SaaS
**Expected answer should cover**: Trino maps the JWT `sub` claim to the Trino username — this is the principal identity that resource group selectors match on via `userRegex`. Roles and resource groups are separate mechanisms: assigning a Trino role to a user does nothing for resource group routing. The `userRegex` field in a selector is a Java regex matched against the JWT `sub` value. Example: if your tenant's service account has `sub` = `"tenant-acme"`, the selector would be `"userRegex": "tenant-acme"`. The resource group JSON structure: group definition with `softMemoryLimit`, `hardConcurrencyLimit`, `maxQueued`; selector pointing to that group. Queries that match no selector fall into the global/default pool — so mis-configured selectors silently fail (no error, wrong pool). Optionally: `clientTags` and `source` as alternative selector fields; `query.max-memory-per-node` as a per-query hard cap complementing resource groups.

---

## Q2 — Storage sizing: cost-per-event measurement for budget planning

**Question**: Our product ingests events from customers — page views, API calls, feature usage, that kind of thing. Some event types are very high volume (millions per day from a single customer) and some are low volume. We're on on-prem MinIO so we're not paying per-GB like cloud S3, but we do care about disk cost because we're planning to buy more drives and we need to justify the budget.

I want to build a simple spreadsheet model that answers: "if we start ingesting X events per month for a new customer, how many gigabytes will that add, and what does that cost us in hardware?" What numbers do I actually need to measure to build that model? Where do I look to find how many bytes one event takes up on disk, and is that number stable enough to use for forecasting, or does it change a lot?

**Target topic**: Storage sizing and growth estimation for lakehouse workloads
**Expected answer should cover**: Query the `$files` Iceberg metadata table to get `file_size_in_bytes` and `record_count` per Parquet file, then compute bytes-per-row = SUM(file_size_in_bytes) / SUM(record_count). The number varies by event type / schema width / compression codec, so measure per-event-type baseline. Simple formula: `parquet_bytes_per_row × monthly_row_count / 1e9 = GB per month`. Parquet columnar compression: high-cardinality columns (UUIDs, raw URLs) compress worse than low-cardinality columns (event_type, country), so the ratio isn't flat across event types. Practical guidance: measure on existing data, apply 20–30% buffer for file growth before compaction and metadata overhead. Iceberg 1.4.0+ default codec is Zstd (not Snappy) — mention that rewrite_data_files can retroactively apply Zstd to existing Snappy files if the table was created before 1.4.0. MinIO erasure coding overhead: EC:4+2 = ~1.5x raw disk (not 2x or 3x).
