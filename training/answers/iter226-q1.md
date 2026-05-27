# Iter 226 Q1 — Cross-catalog Join Build/Probe Orientation and CBO Statistics

## Answer

When Trino executes a join between your `billing_mysql` table and the `iceberg` dimension table, it has to make two key decisions:

1. **Which side becomes the "build" side** (the small table loaded into memory as a hash table) versus the "probe" side (the large table streamed through for lookups)
2. **Whether to broadcast that build side** to every worker or shuffle both sides across workers

Getting this backwards is expensive. If Trino builds a hash table from millions of rows, you exhaust worker memory. If it broadcasts a small dimension to every worker instead of using a more targeted join strategy, you waste network capacity.

The component that makes these decisions is called the **cost-based optimizer (CBO)**. To decide correctly, the CBO needs to estimate how many rows each table will have *after filters are applied*. To estimate cardinality, it needs three pieces of information:

- **Row count** (Iceberg provides this automatically from metadata — no setup needed)
- **Number of distinct values (NDV)** for each join key — does `plan_tier` have 4 distinct values or 4,000?
- **How the values are distributed** — are they uniform or does one value dominate?

Without NDV statistics, the CBO falls back to heuristics that assume things like "the join produces about 10% of the larger table's rows" — which is often wildly wrong for skewed data or very selective filters.

### What happens without statistics

Without NDV stats, the CBO makes bad guesses:

- It might think your small dimension is large and pick an expensive partitioned (shuffle) join
- For fact-to-dimension joins, it might build the wrong side as the hash table
- It may underestimate or overestimate memory needed, causing OOM errors or inefficient operator placement

In your specific case: if `billing_mysql` has millions of rows and your `iceberg` reference table has only a few thousand rows, the right move is to **broadcast the dimension to every worker** (small memory cost) rather than shuffling both sides. But without statistics, Trino might not know the dimension is actually small.

### What you need to run: `ANALYZE` for NDV statistics

The fix is to run Trino's `ANALYZE` command on your join key columns:

```sql
-- On the iceberg reference table (small dimension):
ANALYZE iceberg.your_schema.reference_table
  WITH (columns = ARRAY['plan', 'tier']);

-- On the MySQL side (if it's being joined frequently):
-- This step is different — see below
```

Here's what `ANALYZE` does:
- It scans the table and computes the number of distinct values for each column
- On Iceberg tables, the result is written as a small **Puffin file** (a statistics blob) stored alongside your table metadata in MinIO
- The CBO reads this file at query planning time and uses the NDV numbers to estimate join cardinality more accurately

After you run `ANALYZE` on both tables, re-run your query — the plan should change. The CBO will recognize that the dimension is tiny and make the right broadcast vs. partitioned decision.

### Important syntax note

**Trino's ANALYZE syntax is different from Spark/Hive.** Use:
```sql
ANALYZE iceberg.schema.table
```

NOT:
```sql
ANALYZE TABLE iceberg.schema.table  -- This will fail with a parser error
```

### For your MySQL catalog (`billing_mysql`)

Since `billing_mysql` is a **JDBC connector table** (not Iceberg), Trino doesn't run `ANALYZE` on it directly. Instead:

1. **Run native ANALYZE on your MySQL replica:**
   ```sql
   -- In your MySQL replica (via mysql CLI or your app's MySQL client):
   ANALYZE TABLE billing_mysql.invoices;
   ```
   
2. **Trino's CBO will automatically fetch those statistics** from MySQL's `INFORMATION_SCHEMA.STATISTICS` when planning the join. You do not need to do anything special on the Trino side.

3. After you run the MySQL native `ANALYZE`, verify Trino sees the stats:
   ```sql
   SHOW STATS FOR billing_mysql.public.invoices;
   ```
   If the `distinct_values_count` column is populated, MySQL stats are flowing through. If it's NULL, re-run the native `ANALYZE` on the MySQL side.

### How often to re-run ANALYZE

- **For your small reference table:** if it rarely changes, run `ANALYZE` once after you initially load it, then weekly or after major updates.
- **For the fact table (events, billing, etc.):** if it gets large daily ingests, run `ANALYZE` on a weekly schedule or after major backfills.

Stats do not auto-update when new data arrives. Stale statistics can mislead the CBO, so keeping a weekly cadence prevents the optimizer from working with month-old numbers.

### Verifying the fix worked

After running both ANALYZEs, check that the CBO now has stats to work with:

```sql
-- Check the iceberg dimension:
SHOW STATS FOR iceberg.your_schema.reference_table;

-- Check the MySQL table (if you ran ANALYZE on the MySQL side):
SHOW STATS FOR billing_mysql.public.invoices;
```

Look for the `distinct_values_count` column on your join key columns. If it shows a concrete number (not NULL), stats are populated.

Then run `EXPLAIN` on your join query before and after to see if the plan changed:

```sql
EXPLAIN
SELECT ...
FROM billing_mysql.public.invoices i
JOIN iceberg.your_schema.reference_table r
  ON i.plan_tier = r.plan_tier
...
```

In the output, look for `Join[BROADCAST]` vs `Join[PARTITIONED]`. With stats, a small dimension should show `BROADCAST`. Also check the `Estimates: {rows: N}` lines — concrete numbers instead of `?` means the CBO has stats.

**Key takeaway for your slow join:** Run `ANALYZE iceberg.your_schema.reference_table WITH (columns = ARRAY['plan', 'tier'])` on the Iceberg side and `ANALYZE TABLE billing_mysql.invoices` on the MySQL replica. Then re-run the query. The CBO should recognize the dimension is small and pick a cheaper join strategy.
