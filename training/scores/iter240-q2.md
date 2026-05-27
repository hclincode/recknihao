# Score: iter240-q2 — Iceberg Time-Travel + PostgreSQL Cross-Catalog Join

**Score: 4.4 / 5.0**

## What was correct

1. **Time-travel syntax** — `FOR TIMESTAMP AS OF TIMESTAMP '...'` and `FOR VERSION AS OF <snapshot_id>` are the documented canonical Trino forms for Iceberg time travel. The TIMESTAMP literal with embedded `UTC` zone is valid Trino syntax. Verified against trino.io/docs/current/connector/iceberg.html.

2. **`$snapshots` metadata table** — `iceberg.<schema>."<table>$snapshots"` with columns including `snapshot_id`, `committed_at`, `parent_id`, `operation` is the documented form. The recipe (filter on `committed_at <= T`, order DESC, LIMIT 1) is exactly how Trino itself resolves `FOR TIMESTAMP AS OF`.

3. **Cross-catalog join executes on Trino workers** — Correct. There is no cross-catalog join pushdown in Trino. The two scans run independently on their sources; the join runs on Trino workers. Verified.

4. **Time-travel preserves Iceberg-side predicate pushdown** — Correct. `FOR VERSION AS OF` and `FOR TIMESTAMP AS OF` resolve to a specific snapshot at plan time; once resolved, that snapshot's manifest list is scanned with the same partition-pruning + min/max stats logic used for the current snapshot. Time travel does NOT bypass pushdown.

5. **Dynamic filtering works across catalogs with time-travel** — Correct. Dynamic filtering operates on the runtime join plan, not on which snapshot is being scanned. The historical snapshot is treated as just another scan target, and the runtime IN-list / range filter from the build side still arrives at the probe-side scan. The bidirectional explanation (Postgres-build → Iceberg-probe, and vice versa) is accurate.

6. **`FOR TIMESTAMP AS OF` resolution semantics** — Correct. Iceberg resolves to the latest snapshot with `committed_at <= T`, NOT a snapshot committed exactly at T. The audit recommendation to pin a snapshot ID instead is the right call.

7. **"Time travel resolves BEFORE the join"** — Correct framing. Snapshot resolution happens during planning; the join executes against a fixed historical view.

8. **Read-replica reminder** — Correct and matches the resource's repeated guidance for any Postgres connector usage.

9. **EXPLAIN ANALYZE VERBOSE verification path** — Correct tool for confirming both sides' pushdown behavior; the "check pg_stat_activity for the actual JDBC SQL" tip is good operational advice.

## What was wrong or missing

1. **Overstated VARCHAR pushdown caveat (the most material error).** The answer says "VARCHAR equality filters do not always push reliably" and that "the dynamic filtering from the Iceberg side may not push the VARCHAR IN-list as aggressively as you'd hope." This is misleading. Official Trino PostgreSQL connector docs are explicit: equality predicates (`=`, `IN`) and `!=` on VARCHAR/CHAR columns ARE pushed down. The pushdown limitation on VARCHAR applies to RANGE predicates (`<`, `>`, `<=`, `>=`, `BETWEEN`), which is a different thing and is exactly what `postgresql.experimental.enable-string-pushdown-with-collate` exists to opt into. For a join-key IN-list (the case being discussed), the pushdown is reliable for equality. The recommendation to switch to numeric IDs is unwarranted advice for this scenario. Resource 22 itself is more nuanced — the answer flattened it incorrectly.

2. **Internal date inconsistency in the SQL examples.** The first example (line 11) uses `TIMESTAMP '2026-02-27 00:00:00 UTC'` (three months before today, 2026-05-27, which is correct), but the practical-steps example (line 81) uses `TIMESTAMP '2025-02-27 23:59:59 UTC'` — a year earlier. The customer asked for "three months ago", so both should be 2026-02-27. This is a copy-paste-class slip but would burn an engineer who pasted it verbatim.

3. **Did not mention `domain-compaction-threshold`.** When a build-side produces a large IN-list (say 10k+ values from Postgres `accounts`), Trino compacts the dynamic filter into a min/max range by default (threshold 256). For Iceberg this is usually fine because the scan still benefits, but for the PostgreSQL probe direction this is exactly the lever that controls how aggressive dynamic-filter pushdown to Postgres will be. Resource 22 covers `domain_compaction_threshold`; the answer omits it even though the engineer asked specifically about pushdown behavior.

4. **Did not mention snapshot expiration risk for time-travel queries.** A subtle but important operational point: `FOR TIMESTAMP AS OF` (and even `FOR VERSION AS OF`) fail if the underlying snapshot has been expired by table maintenance. For an audit "three months ago" the customer is asking Trino to read a snapshot that may be older than the snapshot-retention window the team configured. The answer should have warned: check your `expire_snapshots` retention before promising three-month time travel will work, and consider creating a branch or tag for audit anchors.

5. **No mention of dynamic filter wait-timeout asymmetry.** Resource 22 explicitly documents that the JDBC connector waits up to 20s for the dynamic filter, while Iceberg waits 1s. For a Postgres-build → Iceberg-probe direction (likely here, since `accounts` is small), the Iceberg side only briefly waits for the dynamic filter, and a slow Postgres scan could mean the dynamic filter arrives too late to fully prune the Iceberg snapshot. Worth a sentence.

6. **The "third practical step" `EXPLAIN ANALYZE VERBOSE -- (same query as above)` is a code-block placeholder, not a runnable example.** Minor, but a beginner reader could miss that they need to repeat the query underneath.

## Verification notes

- **Trino Iceberg connector docs (trino.io/docs/current/connector/iceberg.html):** `FOR TIMESTAMP AS OF` and `FOR VERSION AS OF` are the canonical forms. `$snapshots` metadata table has columns `committed_at`, `snapshot_id`, `parent_id`, `operation`, `manifest_list`, `summary`. Time-travel queries fall through the standard predicate-pushdown and partition-pruning code path.
- **Trino PostgreSQL connector docs (trino.io/docs/current/connector/postgresql.html):** "Equality predicates, such as `IN` or `=`, and inequality predicates, such as `!=` on columns with textual types are pushed down. Range predicates on character string types (`<`, `>`, `BETWEEN`) are NOT pushed down by default." This directly contradicts the answer's blanket VARCHAR-pushdown caveat.
- **Trino dynamic filtering docs (trino.io/docs/current/admin/dynamic-filtering.html):** Dynamic filtering is enabled by default, applies across catalogs, and is compacted at the `domain-compaction-threshold` boundary (default 256). The Iceberg connector's dynamic row filtering is on by default and works equally on time-travel scans.
- **GitHub trinodb/trino#10855:** Confirms there is no cross-catalog join pushdown.
- **GitHub apache/iceberg#8565 + Estuary blog:** `FOR TIMESTAMP AS OF T` resolves to the latest snapshot with `committed_at <= T`; expired snapshots cause errors for `FOR TIMESTAMP AS OF` (and can for `FOR VERSION AS OF` too, contrary to one source that claimed otherwise).

## Recommendation for teacher

1. **Tighten the VARCHAR pushdown story in resource 22.** Either the resource needs a clearer callout — "VARCHAR EQUALITY / IN pushes down; VARCHAR RANGE does NOT push down without `enable-string-pushdown-with-collate`" — or a short example showing the EXPLAIN difference. The weak-ai-responder is currently flattening "range pushdown limitation" into "general VARCHAR limitation" and giving bad advice to switch schemas.

2. **Add a short section on time-travel + federation specifically.** Resource 22 mentions time travel once (Section that compares ingest vs. federate); it does not discuss "what about cross-catalog joins WITH time travel?" Add ~half a page covering: (a) snapshot resolution happens at planning, (b) pushdown and dynamic filtering still apply to the historical snapshot, (c) snapshot-expiration risk for audit queries, (d) recommended pattern: snapshot-id pin + tag/branch for long-lived audit anchors.

3. **Reinforce the dynamic-filter wait-timeout asymmetry (20s JDBC / 1s Iceberg) in the federation context.** Already in resource 22, but it should be cross-referenced from a "common federated patterns" section so the responder pulls it into answers about Iceberg×Postgres joins.

4. **No new resource file needed — these are extensions to existing resource 22.**
