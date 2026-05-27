# Answer to Q1: rewrite_manifests Not Available in Trino 467 (Iter 346)

**You are not missing anything — `rewrite_manifests` is genuinely not available in Trino 467, which is your production version.** This is not a syntax you're forgetting or a feature hidden behind a flag. It's a real capability gap.

Here's the exact situation from your stack's perspective:

| Engine | `rewrite_manifests` support |
|---|---|
| **Spark SQL** (any recent version, including with Iceberg 1.5.2) | Fully available: `CALL iceberg.system.rewrite_manifests(table => 'analytics.events')` |
| **Trino 470+** (Feb 2025 and later) | Available as `ALTER TABLE iceberg.analytics.events EXECUTE optimize_manifests` |
| **Trino 467 (your production version)** | **NOT available** — both the `CALL` form and the `ALTER TABLE ... EXECUTE optimize_manifests` syntax fail with "Procedure not registered" / syntax errors |

**You need to run `rewrite_manifests` from Spark.** There is no Trino 467 equivalent. Here's the command:

```sql
-- Run this from Spark SQL (spark-sql CLI or spark-submit)
CALL iceberg.system.rewrite_manifests(table => 'analytics.events');
```

**Why you'll want to do this anyway:** manifest rewrite consolidates the metadata layer after compaction and snapshot expiry have churned your data files. After hundreds of writes, you can accumulate hundreds of small manifest files, which makes query planning take 10+ seconds before Trino even touches the data. After `rewrite_manifests` runs, those small manifests get collapsed into a few large ones, sorted by partition — planning drops to under 1 second.

**The standard maintenance workflow for your stack:**

1. **Nightly compaction** (Trino is fine: `ALTER TABLE ... EXECUTE optimize`)
2. **Weekly (in this order):**
   - Expire snapshots (Trino: `ALTER TABLE ... EXECUTE expire_snapshots(retention_threshold => '30d')`)
   - Remove orphan files (Trino: `ALTER TABLE ... EXECUTE remove_orphan_files(retention_threshold => '7d')`)
   - **Rewrite manifests** ← **Run this from Spark only:** `CALL iceberg.system.rewrite_manifests(table => 'analytics.events')`

The first three steps you can run entirely from Trino if you want. The fourth step (manifest rewrite) requires Spark. Most teams run the entire weekly job from Spark anyway because it's more natural with batch schedulers like Airflow or Kubernetes CronJobs — same engine for all four steps, cleaner orchestration.

**No workarounds or alternative approaches** — you have to use Spark for this. Upgrading to Trino 470+ would give you the `ALTER TABLE ... EXECUTE optimize_manifests` syntax if you wanted to eventually move everything into Trino, but until then, Spark is the answer.

**Resources cited:** `/Users/hclin/github/recknihao/resources/17-iceberg-table-maintenance.md`
