# Iter 236 Q1 — PostgreSQL Write-Back with MERGE/Upsert from Trino

## Answer

**Short answer: No, MERGE is NOT supported in your production Trino 467 on PostgreSQL. Here are your three real options for upsert.**

Your production stack runs Trino 467, which does not support MERGE on the PostgreSQL connector. Attempting `MERGE INTO app_pg.billing_snapshots ...` will throw an unsupported-operation error at plan time. The MERGE feature for PostgreSQL didn't land in Trino until version 470 (Feb 2025), and even then it required an additional flag with non-transactional semantics. Transactional MERGE for PostgreSQL only arrived in Trino 475+.

This is a hard limitation in your version. Do not try to work around it by adding a `merge.non-transactional-merge.enabled=true` flag to your PostgreSQL catalog properties — the connector doesn't recognize that property until Trino 470, so it will be silently ignored and MERGE will still fail.

**Your three viable options, in order of preference:**

1. **Do the upsert in your application, not in Trino (recommended).** Use Trino to *compute* the daily billing aggregates, then have your application read those results and execute a native PostgreSQL upsert on its own connection. PostgreSQL has the perfect native syntax for this: `INSERT INTO billing_snapshots (...) VALUES (...) ON CONFLICT (customer_id, date) DO UPDATE SET ...`. Your app connection gets full transactional semantics, prepared statements, and atomic row locks. This is the production-correct approach — Trino is a query engine, not a transaction engine.

2. **Two-statement INSERT + UPDATE through Trino.** If you must stay in Trino SQL:
   - Run `INSERT INTO app_pg.public.billing_snapshots SELECT ... WHERE NOT EXISTS (SELECT 1 FROM billing_snapshots WHERE customer_id = source.customer_id AND date = source.date)` to add new rows.
   - Then run a separate `UPDATE app_pg.public.billing_snapshots SET total_api_calls = <constant>, overage_charges = <constant>, ... WHERE customer_id = ? AND date = ?` for existing rows.

   **Caveats**: (a) UPDATE only allows constant assignments — you cannot use expressions like `SET total_api_calls = total_api_calls + 100`. You can only set columns to literal values. (b) There is no cross-statement atomicity. Each `INSERT` and `UPDATE` commits independently. If the job crashes after the `INSERT` completes but before the `UPDATE` starts, you'll have new rows without updated columns in the old rows. This is idempotent only if re-running the same day's job produces the same final values.

3. **Snapshot-and-replace via Iceberg staging.** Compute the full day's billing data in Trino and materialize it into a temporary Iceberg table. Then use `CREATE TABLE AS SELECT` to write that Iceberg slice to a fresh PostgreSQL staging table. Finally, have your application swap the staging table for the live table inside a `BEGIN ... COMMIT` block in PostgreSQL, keeping the atomic operation where it belongs — in the database that provides transactional guarantees.

**Additional constraint to be aware of**: The OPA authorization layer on your production stack may already be denying all writes to the `app_pg` catalog. If you try any of these approaches and get an authorization error before the query reaches PostgreSQL, that's OPA enforcing a write-deny policy on purpose — check with your cluster admin before assuming the connector is misconfigured.

**Recommendation for your nightly billing job**: Option 1 is the right answer. Have Trino compute the aggregates and write them to a temporary table or result set, then let your application own the upsert using native PostgreSQL `ON CONFLICT` syntax on its own connection pool. This keeps billing logic where it belongs — in application code with full ACID guarantees — rather than stretching Trino beyond its design as an analytical query engine.
