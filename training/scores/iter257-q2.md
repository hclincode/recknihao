# Iter257 Q2 Score

**Score: 3.3 / 5.0** — FAIL (threshold: 4.5)

## What was correct
- Correctly identifies that Trino's PostgreSQL connector uses JDBC under the hood.
- Correctly notes the default `fetch-size` was historically hard-coded to 1000 (verified via Trino issue #16153 and PR #16644, though it is now adaptive 1000–100,000 in recent Trino versions).
- Correctly states that Trino's JDBC connectors do NOT support wrapping a query in a long-lived `REPEATABLE READ` transaction across multiple statements (verified via Trino issue #18438: "Catalog only supports writes using autocommit"; multi-statement transactions are not supported).
- Correctly states there is no Trino-side knob to change the isolation level via the PostgreSQL connector.
- Workarounds are practical and fit the production stack:
  - Materialize to an Iceberg staging table (excellent fit for the on-prem MinIO + Iceberg + Trino 467 environment).
  - Use a replica with lag.
  - Schedule during low-write windows.
  - Accept the gap.
- Tone, structure, and step-through timeline are clear for a SaaS engineer with no OLAP background.
- Final summary section reinforces the key takeaways without inventing new claims.

## Gaps or errors
- **Central mechanistic claim is technically wrong.** The answer asserts: "Each batch of 1000 rows is a **separate statement** with its own `READ COMMITTED` snapshot." This is incorrect. Per the PostgreSQL official docs (postgresql.org/docs/current/transaction-iso.html), a single `SELECT` command in READ COMMITTED sees a snapshot taken at the moment the SELECT begins, and that snapshot is stable for the entire execution of that SELECT — it does NOT take a new snapshot per fetch batch. The PostgreSQL JDBC driver's `defaultRowFetchSize` mechanism uses a server-side cursor inside a transaction with `autocommit=false`, which preserves the original SELECT's snapshot across all fetches from that cursor. So fetching batches 1, 2, 3, ... N from a single SELECT all see the SAME snapshot — not different ones.
- The real reason inconsistency CAN happen with Trino is more subtle and the answer never explains it correctly:
  - Trino may issue multiple SELECT statements per query (e.g., one per split when predicate pushdown produces partitioned reads, or across separate scans on the same table for joins/subqueries), and each gets its own snapshot.
  - Fault-tolerant execution / split retries can re-issue a statement and pick up newer commits.
  - Aggregates that scan the table more than once across the plan can see different snapshots between scans.
- The detailed step-through ("batch 2 at T10 can see rows written at T5") is therefore misleading. It would only be true if Trino issued multiple separate SELECTs, not because of fetch batching within one cursor.
- The recommendation to "wrap the Postgres read in a `REPEATABLE READ` transaction" is the right idea but the framing slightly oversells the problem — under READ COMMITTED, a single SELECT is already snapshot-consistent for the rows it returns.
- Minor: the answer cites `defaultRowFetchSize=1000` as a fixed catalog setting; in Trino versions after PR #16644 the value is computed adaptively per query (1000–100,000 depending on column count). The hard-coded 1000 framing is dated for Trino 467 (the production version per `prod_info.md`).

## WebSearch verification notes
- **Trino fetch-size default**: Verified via GitHub issue trinodb/trino#16153 and PR #16644 — historically 1000 hard-coded, now adaptive 1000–100,000.
- **Trino JDBC multi-statement transactions**: Verified NOT supported via GitHub issue trinodb/trino#18438 ("Catalog only supports writes using autocommit").
- **No REPEATABLE READ support in Trino PostgreSQL connector**: Confirmed — no documented session property or connector config exposes isolation level control. Trino issue #6274 on SQL Server SNAPSHOT ISOLATION explicitly notes "Presto doesn't read transactionally, there is no advantage of increased isolation beyond single query consistency."
- **PostgreSQL READ COMMITTED snapshot scope**: Per postgresql.org/docs/current/transaction-iso.html — "a SELECT query sees a snapshot of the database as of the instant the query begins to run... never sees... changes committed by concurrent transactions during the query's execution." A new snapshot is taken *per command*, not per fetch within a command. This directly contradicts the answer's central mechanistic claim.
- **PostgreSQL JDBC `defaultRowFetchSize` mechanics**: Per pgjdbc docs and issue #2227 — requires autocommit=off; uses a server-side cursor inside a transaction; cursor preserves the snapshot of the originating SELECT for the duration of the fetch loop.
- **PostgreSQL connector single-connection / serial scan**: Confirmed via Trino issue #389 — JDBC-based tables historically use a single connection; not parallel by split unless partitioned-table pushdown is configured.

## Verdict
The answer reaches the right practical conclusion (inconsistency is possible; materialize to Iceberg) and gives strong actionable guidance that fits the on-prem Trino 467 + Iceberg + MinIO stack. However, the mechanistic explanation for *why* inconsistency happens is technically incorrect in a way a careful reader could be misled by. A SaaS engineer who takes the "each fetch batch is its own snapshot" claim at face value and tries to explain it to their team would be teaching wrong PostgreSQL semantics. This is a meaningful technical accuracy failure on a question that is fundamentally about technical accuracy. Below the 4.5 PASS bar.
