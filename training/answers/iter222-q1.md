# Iter 222 Q1 — Cross-Catalog Join Pushdown Limits: Does Trino Send the Join to MySQL, and What Is Dynamic Filtering?

## Answer

Based on your question about joining MySQL and Iceberg tables in Trino, here is what actually happens:

### 1. Trino Does NOT Push the Join Itself to MySQL

When you write:
```sql
SELECT ...
FROM billing_mysql.billing.invoices i
JOIN iceberg.analytics.customers c ON i.customer_id = c.customer_id
```

Trino **never** sends the join to MySQL. The join always executes on **Trino workers**, not in MySQL. This is a fundamental architectural rule: **cross-catalog join pushdown does not exist**. MySQL has no concept of Iceberg tables and Iceberg has no concept of MySQL tables, so neither can execute a join that spans both systems. Only predicates on each side can push down (MySQL applies filters to MySQL data; Iceberg applies filters to Iceberg data), but the hash join itself is Trino's responsibility.

### 2. Dynamic Filtering: Yes, It Sends an IN-List to MySQL (Under Certain Conditions)

Trino has a feature called **dynamic filtering** that partially solves the problem you're describing. Here's how it works:

**The mechanism:**
1. During query planning, Trino identifies that you're joining a small table (the Iceberg `customers` table at ~200K rows is your build side) to a large table (the MySQL `invoices` table at ~50M rows is your probe side).
2. Trino executes the build side first and materializes the 200K customer IDs in memory.
3. Trino then derives a runtime filter—an **IN-list of customer IDs** found in Iceberg—and pushes this to MySQL.
4. MySQL receives something like: `SELECT * FROM invoices WHERE customer_id IN (cust_id_1, cust_id_2, ..., cust_id_200k)` (or sometimes a min/max range if the list is too large).
5. MySQL applies that filter server-side and returns only matching rows instead of scanning the entire 50M-row table.

**This is enabled by default** and is what makes large × small cross-catalog joins survivable in production.

**Critical caveat for MySQL specifically:**
The MySQL connector has **narrower predicate pushdown than PostgreSQL**. Specifically, `VARCHAR` equality and `LIKE` patterns do **NOT push down** to MySQL by default (they do push to PostgreSQL). However, **numeric and date predicates DO push down**, and **dynamic filtering with IN-lists on numeric join keys DOES work**. So if your `customer_id` is a BIGINT, dynamic filtering will push the IN-list to MySQL correctly.

### 3. How to Verify What's Actually Happening

Use these two commands:

**Step 1: Check the plan (does NOT execute the query):**
```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT COUNT(*) AS event_count
FROM billing_mysql.billing.invoices i
JOIN iceberg.analytics.customers c ON i.customer_id = c.customer_id
WHERE c.plan_type = 'enterprise';
```

Look for these signals in the output:

- **On the Iceberg side** (the build side, customers table): You should see the `customers` scan listed first, with any filters pushed down.
- **On the MySQL side** (the probe side, invoices table): Look for a `dynamicFilters = {customer_id = #df_...}` annotation. This annotation means dynamic filtering was wired at plan time.
- **Plan shape**: If you see the customer scan completing before the invoices scan references it, that's the sign of dynamic filtering setup.

**Step 2: Verify it actually fired at runtime (executes the query — use cautiously):**
```sql
EXPLAIN ANALYZE
SELECT COUNT(*) AS event_count
FROM billing_mysql.billing.invoices i
JOIN iceberg.analytics.customers c ON i.customer_id = c.customer_id
WHERE c.plan_type = 'enterprise';
```

On the **MySQL TableScan operator** in the output, look for:
- **`dynamicFilterSplitsProcessed = N`** — A **non-zero value** proves dynamic filtering actually pruned rows at runtime, not just appeared in the plan.
- **`Filtered: X%`** — if you see a high percentage here, MySQL applied the filter server-side.
- **`Input: N rows (size)`** — compare this to the full table size. If it's much smaller than 50M rows, dynamic filtering worked.

### 4. What the Plan Looks Like: Two Scenarios

**Scenario A — Dynamic Filtering IS Firing (the good case):**
```
Fragment 1 [SOURCE]
    TableScan[table = iceberg:analytics.customers, constraint = (plan_type = 'enterprise')]
        Layout: [customer_id, ...]
        # ^ Build side (small, 200K rows after filter)

Fragment 2 [SOURCE]
    TableScan[table = billing_mysql:billing.invoices]
        Layout: [customer_id, amount, ...]
        dynamicFilters = {customer_id = #df_customers_id_0}
        # ^ Probe side receives the IN-list of customer IDs from build side
```

**Scenario B — Dynamic Filtering Did NOT Fire (the bad case):**
```
Fragment 1 [SOURCE]
    TableScan[table = iceberg:analytics.customers, constraint = (plan_type = 'enterprise')]
        Layout: [customer_id, ...]

Fragment 2 [SOURCE]
    TableScan[table = billing_mysql:billing.invoices]
        Layout: [customer_id, amount, ...]
        # ^ NO dynamicFilters annotation — the build side was too big
        #   (exceeded the dynamic-filtering.small-join.estimated-size-in-bytes threshold)
        #   or wait timeout was hit
```

### 5. Why Dynamic Filtering Might Not Fire

Dynamic filtering is enabled by default, but it **will NOT fire** if:

- **Build side is too large:** If your Iceberg side, after filtering, returns more than `dynamic-filtering.small-join.estimated-size-in-bytes` (default: ~100 MB), Trino concludes the IN-list would be too large or too slow to push and skips dynamic filtering.
- **Wait timeout is hit:** `dynamic-filtering.wait-timeout` (default: 1 second) controls how long Trino waits for the build side to complete before the probe side scan starts. If the build side hasn't finished in that time, the probe scan starts without the filter to avoid blocking queries indefinitely.
- **Join orientation is wrong:** If the CBO chooses the wrong build/probe assignment (e.g., treating MySQL as the build side because the CBO has no stats on Iceberg), dynamic filtering goes the wrong direction.

### 6. Practical Recommendations to Speed Up This Query

1. **Ensure both tables have statistics:**
   - For Iceberg: Run `ANALYZE iceberg.analytics.customers WITH (columns = ARRAY['customer_id']);` from Trino.
   - For MySQL: Run `ANALYZE TABLE billing.invoices;` natively in MySQL, not through Trino.
   - Verify with `SHOW STATS FOR iceberg.analytics.customers;` and `SHOW STATS FOR billing_mysql.billing.invoices;` — `distinct_values_count` should be populated (not NULL) for the join key.

2. **Add a selective filter on the small side (Iceberg):**
   Your query already has `c.plan_type = 'enterprise'` — good. This shrinks the build side (Iceberg) so the IN-list is smaller and more effective when pushed to MySQL.

3. **Confirm `customer_id` is a numeric type:**
   If `customer_id` is VARCHAR on MySQL, the IN-list may not push down efficiently (MySQL's VARCHAR pushdown is limited). Use `DESCRIBE billing_mysql.billing.invoices;` to check. If it's numeric (BIGINT, INT), you're good.

4. **Check the actual row count shipped from MySQL:**
   Run `EXPLAIN ANALYZE` and check the MySQL `Input: N rows (size)` line. If it's close to 50M, dynamic filtering either didn't fire or the IN-list wasn't selective enough. If it's much smaller (e.g., 5–10M), dynamic filtering is working.

5. **Force BROADCAST join distribution if Iceberg is small enough:**
   ```sql
   SET SESSION join_distribution_type = 'BROADCAST';
   -- Re-run the query
   ```
   This sends the entire Iceberg dimension to every worker, making dynamic filtering maximally precise and avoiding a repartition shuffle.

6. **Point at a read replica for MySQL:**
   Ensure `connection-url` in your `billing_mysql.properties` catalog file points at a replica, never the OLTP primary.

The bottom line: **Dynamic filtering is your ally here.** With good statistics and selective predicates on the Iceberg side, Trino derives a precise IN-list and pushes it to MySQL, turning a 50M-row full table scan into a much smaller scoped scan.
