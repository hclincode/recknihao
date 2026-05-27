# Judge Score — Iter 83 Q2

## Score: 4.91 / 5.0
| Dimension | Score |
|---|---|
| Technical accuracy | 4.875 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 4.75 |

## Points covered
This question targeted the "Postgres-to-Iceberg ingestion" topic, specifically the hard-delete blind spot of watermark-based incrementals (the novel angle called out in state.json for iter 83). Coverage points hit:

1. Explicit confirmation that `updated_at` watermark incrementals are blind to hard deletes (root-cause explanation: no row, no timestamp).
2. GDPR-erasure framing of why this matters in a SaaS context.
3. Option A — Soft deletes in Postgres (`deleted_at` column) with concrete SQL, plus a filter view (`users_active`) and physical cleanup via `DELETE` + `rewrite_data_files` + `expire_snapshots`. Notes that the existing watermark pipeline keeps working.
4. Option B — Debezium CDC with correct op codes (`c`, `u`, `d`, `r`) and a runnable Spark `MERGE INTO ... WHEN MATCHED AND s.op = 'd' THEN DELETE` example using the Debezium envelope's `before` field for the PK.
5. Option C — Periodic primary-key set-diff reconciliation in Spark (`iceberg_ids.subtract(pg_ids)`), with explicit scale caveat ("under a few hundred million rows") and frequency guidance (deletes are rare).
6. Decision guidance ("which to recommend") tied to the team's operational reality, not just abstract pros/cons.
7. Suggests reconciliation as a safety net even when soft-delete is the primary strategy — pragmatic defense-in-depth advice.
8. Immediate next step (audit `DELETE` call sites) is concrete and actionable.
9. Production fit: stays inside Spark + Iceberg + MinIO on-prem stack; doesn't invoke any cloud-only services.
10. Iceberg maintenance hygiene (`rewrite_data_files`, `expire_snapshots`) correctly bundled into the physical-purge path so soft-deletes don't accumulate as stale bytes forever (important for GDPR — the bytes must actually disappear).

## Accuracy notes
Verified via WebSearch:
- **Debezium op codes** (debezium.io/documentation/reference/stable/connectors/postgresql.html): `c` = create, `u` = update, `d` = delete, `r` = read (snapshot). Confirmed. Delete events carry the previous row state in the `before` field with `after = null`. The answer's use of `s.before.user_id` in the MERGE ON clause is correct for the envelope schema.
- **Spark MERGE INTO conditional DELETE** (iceberg.apache.org/docs/latest/spark-writes/): `WHEN MATCHED AND <condition> THEN DELETE` is supported syntax. Multiple `WHEN MATCHED` clauses with different conditions can coexist (first match wins). The answer's pattern `WHEN MATCHED AND s.op = 'd' THEN DELETE / WHEN MATCHED AND s.op = 'u' THEN UPDATE SET * / WHEN NOT MATCHED AND s.op IN ('c','r') THEN INSERT *` is idiomatic and correct.
- **Soft-delete + view pattern** is a well-documented standard data-warehouse approach (Qlik whitepaper, LeapFrogBI, Integrate.io). The answer's framing of it as "least disruptive to existing pipeline" matches industry guidance.
- **PK set-diff reconciliation** is a standard pattern (FULL OUTER JOIN / EXCEPT / subtract). The scale caveat the answer gives ("under a few hundred million rows", one-column scan on both sides) is realistic — at 100M+ rows the Postgres-side scan starts becoming a non-trivial load on the OLTP database.
- **Iceberg procedures** `rewrite_data_files` (with `where` predicate) and `expire_snapshots` (with `older_than`) signatures match current Spark procedures docs.

## Issues / gaps
Minor:
- **Postgres-side enforcement of soft-delete**: the answer says "audit your application code to find all DELETE call sites" but doesn't mention the safety belt of a Postgres trigger / revoking DELETE on the table at the role level so a stray `DELETE` from a forgotten code path or a manual psql session can't bypass the soft-delete contract. A SaaS engineer reading this would benefit from "and revoke DELETE on the table from the app role, or add a `BEFORE DELETE` trigger that raises an exception."
- **Tombstone events in Debezium**: the answer covers the `op='d'` event correctly, but Debezium also emits a follow-up null-payload tombstone message for Kafka log compaction. Not relevant to the MERGE logic itself, but worth a one-line callout so a streaming consumer doesn't NPE on the tombstone.
- **Reconciliation scale story**: the "subtract" approach pulls all Postgres PKs into Spark. For a 500M-row table, that's a serious one-time read pressure on Postgres. A more incremental reconciliation pattern (sharded by hash bucket, or month at a time) would be worth one sentence for engineers with large tables.
- **Trino-side option**: in this production stack, Trino can read both Postgres (via the postgresql connector) and Iceberg, so the reconciliation can be a single `SELECT id FROM postgresql.public.users EXCEPT SELECT user_id FROM iceberg.analytics.users` without Spark involvement. Not wrong to use Spark, but the Trino option is sometimes simpler.

None of these are deductions worth more than 0.25 on Completeness. Technical accuracy gets a 4.875 only because the Postgres-trigger / role-revoke enforcement story is a non-trivial omission for "did the engineer get the full picture."

## Resource fix needed?
**No urgent fix.** State.json already flagged "resources/13 — add hard-delete invisibility callout (moderate priority)" for iter 83, and this answer demonstrates the responder handled the question well without a resource update being in place yet (good generalization from related material).

**Optional polish** for `resources/13-postgres-to-iceberg-ingestion.md` (low priority — topic is at 4.448 over 77 questions, well above pass):
- Add an explicit "hard-delete invisibility of `updated_at` watermark" callout with the three-option treatment (soft delete / CDC / reconciliation) similar to this answer's structure.
- Add a one-line note on enforcement: revoke DELETE on the table from the app role or add a `BEFORE DELETE` trigger, so soft-delete is a contract not a convention.
- Add a one-line note on Debezium tombstone events so a streaming consumer doesn't fail on null payloads.
- Mention the Trino `EXCEPT` reconciliation path as an alternative to the Spark `subtract` pattern, since both query engines are in the production stack.
