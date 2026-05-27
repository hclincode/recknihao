# Iter83 Q2 — Answer

**Question**: `updated_at` watermark incremental sync is blind to hard deletes in Postgres. Confirmation + options: soft deletes, Debezium CDC, periodic reconciliation. Which to recommend?

---

## Answer

Yes, you're exactly right — `updated_at` watermarks are completely blind to hard deletes. When a row is physically deleted from Postgres, there is no `updated_at` timestamp to trip your watermark filter. The row simply ceases to exist in the source, so your incremental sync job never sees the deletion event. The stale copy in Iceberg sits there indefinitely. This is a critical correctness issue for GDPR compliance, data accuracy, and user trust.

**Why the blind spot exists.** Incremental syncs work by filtering `WHERE updated_at > last_run`. When a DELETE happens in Postgres, there's no row anymore — there's no `updated_at` value to compare against. Your pipeline has no way to know the row existed. This catches every team running watermark-based ingestion into a system where users can delete accounts or support staff can hard-delete records.

### Your Three Practical Options

**Option 1: Soft deletes (best for most teams, least disruptive to your existing pipeline).**

Stop using `DELETE FROM users` in your application code. Instead, add a `deleted_at TIMESTAMP` column to every mutable table in Postgres. When a user deletes their account, run:

```sql
UPDATE users SET deleted_at = now(), updated_at = now() WHERE id = ?
```

Now the "deletion" is just a regular UPDATE — `updated_at` advances, your watermark catches it on the next hourly run, and Iceberg sees the change via MERGE INTO. Your query layer filters soft-deleted rows through a view:

```sql
-- Analysts always query this view, never the raw table
CREATE OR REPLACE VIEW iceberg.analytics.users_active AS
SELECT * FROM iceberg.analytics.users WHERE deleted_at IS NULL;
```

For physical cleanup (actually removing the bytes from Iceberg), run periodically:

```sql
DELETE FROM iceberg.analytics.users WHERE deleted_at IS NOT NULL AND deleted_at < now() - INTERVAL '90' DAY;
CALL iceberg.system.rewrite_data_files(table => 'analytics.users', where => "deleted_at IS NOT NULL");
CALL iceberg.system.expire_snapshots(table => 'analytics.users', older_than => CURRENT_TIMESTAMP - INTERVAL '7' DAY);
```

The cost is a one-time audit of your application code to find and convert every hard-DELETE call site to soft-delete UPDATEs. After that, your existing `updated_at` watermark pipeline works perfectly — no pipeline changes needed.

**Option 2: Debezium CDC (best when CDC infrastructure already exists).**

If your organization already runs Debezium to stream Postgres changes to Kafka, CDC captures hard deletes as `op='d'` events with the deleted row's primary key in the `before` field. A Spark Structured Streaming consumer applies these as hard DELETEs to Iceberg via MERGE INTO:

```sql
MERGE INTO iceberg.analytics.users t
USING cdc_delta s
ON t.user_id = s.before.user_id
WHEN MATCHED AND s.op = 'd' THEN DELETE
WHEN MATCHED AND s.op = 'u' THEN UPDATE SET *
WHEN NOT MATCHED AND s.op IN ('c', 'r') THEN INSERT *
```

This gives full fidelity — hard deletes, soft deletes, and updates all propagate accurately, typically within seconds. The tradeoff is complexity: Debezium connector, Kafka, streaming consumer, exactly-once delivery semantics. Only stand this up if your team already operates Kafka or if sub-minute delete propagation is a hard product requirement (regulated industries, strict GDPR enforcement).

**Option 3: Periodic full-rekey reconciliation (acceptable when deletes are rare).**

Once a week or month, run a primary-key set diff:

```python
pg_ids = spark.read.jdbc(url=PG_URL, table="(SELECT id FROM users) t", properties=PG_PROPS)
iceberg_ids = spark.read.table("iceberg.analytics.users").select("user_id")
orphaned = iceberg_ids.subtract(pg_ids)
orphaned.createOrReplaceTempView("orphaned_ids")
spark.sql("DELETE FROM iceberg.analytics.users WHERE user_id IN (SELECT user_id FROM orphaned_ids)")
```

This is cheap for tables under a few hundred million rows (just a one-column scan on both sides), but only practical if hard-deletes are infrequent and a week of staleness on deleted rows is tolerable. Good fit for an `accounts` or `subscriptions` table where a handful of rows get deleted per day. Poor fit for `messages` where deletions happen constantly.

### Which to Recommend

**For most SaaS teams: Option 1 (soft deletes).** It eliminates the blind spot entirely without adding infrastructure, composes naturally with your existing `updated_at` watermark pipeline, and the app code migration is a one-time investment. After that, your sync just works. This fits your on-prem Spark + Iceberg stack perfectly without adding operational burden.

**If you're already running Debezium elsewhere in your data stack,** Option 2 becomes attractive — you're not starting from zero and you get real-time fidelity.

**As a safety net even on a soft-delete system**, run the reconciliation from Option 3 weekly. It catches any hard-deletes that happened in Postgres before your team finished migrating away from DELETE calls, and gives you confidence your Iceberg table is a true replica of Postgres.

**Immediate next step**: audit your app code to find all `DELETE` call sites. Count them. If there are only a handful, soft deletes are a few-hour fix. If `DELETE` is scattered across dozens of services and codepaths, you may need Option 3 to buy time while you refactor.
