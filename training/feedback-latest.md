# Iter 385 Feedback — 2026-05-30 (EXTENDED PHASE)

**Overall: 4.4375 — PASS**

## Q1: Iceberg MERGE INTO internals + CDC upserts (4.4375 PASS)

Responder coverage:
- CoW = rewrites affected data files (no separate delete markers)
- MoR = position deletes + new data files
- MERGE INTO CDC pattern: op='u' → UPDATE, op='d' → DELETE, WHEN NOT MATCHED → INSERT
- Equality delete bug #12838 in Iceberg 1.5.2 (production-stack fit)
- Post-MERGE maintenance loop (compaction + snapshot expiry)

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | 4.75 | CoW/MoR + three-branch MERGE pattern + #12838 all correct; minor — #12838 is more precisely RewriteDataFiles + equality-delete interaction across partitions, slightly understated |
| Beginner clarity | 3.75 | "Position delete", "equality delete", "MoR/CoW", "op='u'/'d'" all thrown without inline gloss — same BC cascade as iter384 |
| Practical applicability | 4.75 | Concrete MERGE INTO pattern + 1.5.2-specific bug callout + maintenance follow-up = engineer knows exact next steps |
| Completeness | 4.5 | Misses: write.merge.mode / write.delete.mode table-property toggle that controls CoW vs MoR per-operation |

## Q2: Trino per-query timeout (4.4375 PASS)

Responder coverage:
- query_max_run_time = total elapsed (queue + planning + execution)
- query_max_execution_time = active computation only
- query.max-run-time=10m in config.properties (cluster default)
- Session Property Manager for per-tier limits
- OPA enforces non-override of session property bounds
- CALL system.runtime.kill_query for immediate kill

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | 4.75 | run-time vs execution-time distinction correct per Trino 481 docs; OPA-as-enforcer fits Trino 467 stack; kill_query correct |
| Beginner clarity | 3.75 | "Session Property Manager", "OPA", "config.properties" all thrown without inline gloss — same BC cascade |
| Practical applicability | 4.75 | Concrete config value (10m) + specific file (config.properties) + per-tier mechanism + immediate-kill procedure |
| Completeness | 4.5 | Misses: query.max-queued-time peer property + EXCEEDED_TIME_LIMIT error code users observe |

## Pattern observations

Two consecutive iterations (384, 385) landed at exactly **4.4375**. This is no coincidence:
- TA 4.75 both Qs both iters (ceiling-strong)
- PA 4.75 both Qs both iters (ceiling-strong)
- Comp 4.5 stable (minor missing peer-property gaps)
- **BC 3.75 both Qs both iters — the consistent score cap**

BC drag is now ~8 iterations of unresolved jargon cascade. Until inline-gloss work lands, STRONG PASS (≥4.6) is structurally blocked even with perfect TA + PA.

## Teacher actions next (iter 386)

1. **HIGH — MERGE INTO BC inline-gloss cascade**
   - "position delete = pointer (file_path, position) to a row in an existing file marked for skip at read time"
   - "equality delete = predicate-based delete e.g. WHERE id=5 stored as a delete file"
   - "CoW (copy-on-write) = rewrites the entire affected data file with the change applied"
   - "MoR (merge-on-read) = keeps delete file separate, applied at scan time, reconciled later by compaction"
   - "op='u'/'d'/'c'/'r' = Debezium operation code in change event envelope: update / delete / create / read-snapshot"

2. **HIGH — Trino timeout BC inline-gloss cascade**
   - "Session Property Manager = Trino coordinator config (session-property-config.properties) mapping user/group/source patterns to per-session property defaults"
   - "config.properties = cluster-wide Trino coordinator/worker config file in etc/"
   - "elapsed time = wall-clock from query submit including queue wait"
   - "execution time = active CPU/IO time excluding queue and planning phases"

3. **MED — Q1 Comp**: write.merge.mode / write.delete.mode / write.update.mode table properties that toggle CoW vs MoR per-operation (default CoW in 1.5.2)

4. **MED — Q2 Comp**: query.max-queued-time peer property + EXCEEDED_TIME_LIMIT error code surface (what user sees in error message)

## Judge probe targets next

1. **MERGE INTO 2nd angle** — "MERGE failed mid-batch on equality delete file; how to roll back?" tests snapshot rollback + MoR equality-delete corruption recovery + interaction with iter385 #12838 fix.
2. **Trino timeout 2nd angle** — "User complains query killed at 8m but they set session property to 30m; why didn't override take effect?" tests OPA-policy enforcement of session-property bounds + Session Property Manager precedence ordering.
3. **Carry-forward** — schema registry 4th angle (forward/backward compat after enum add), EXPLAIN TYPE IO + VALIDATE, Trino result caching, Iceberg branches concurrent fast_forward, bucket sizing 32/128/256, JWT+OPA concurrency, partition spec migration without downtime.

## Trajectory

iter370 → 385: 4.625 / 4.375 / 4.47 / 3.98 FAIL / 4.5625 / 4.75 / 4.1875 / 4.4375 / 4.40625 / 4.5625 / 3.25 FAIL / 4.71875 STRONG / 4.8125 STRONG / 4.78125 STRONG / 4.375 PASS / 4.094 PASS / 4.4375 PASS / **4.4375 PASS** — 8 consecutive iterations above 4.0 pass bar. Resource base stable; BC inline-gloss work is the only remaining lever between PASS and STRONG PASS.
