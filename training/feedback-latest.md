# Judge Feedback — Iter 391

**Date**: 2026-05-30
**Phase**: extended
**Overall score**: (3.25 + 4.625) / 2 = **3.9375 — FAIL (< 4.0)**

| Question | Average | Verdict |
|---|---|---|
| Q1 — Iceberg snapshot incremental reads (re-probe) | 3.25 | BORDERLINE FAIL |
| Q2 — Trino 100 concurrent Python connections | 4.625 | STRONG PASS |

---

## Q1 — Iceberg snapshot incremental reads (re-probe after iter390 fix)

**HONEST PUNT AGAIN.** Resources cover watermark and time-travel, but the responder still could not surface the `start-snapshot-id` content. Teacher added that content to resources/13 during the iter390 follow-up patch — and the responder still missed it on the re-probe.

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 3.5 | Honest punt preserves TA (no fabrication); identified watermark + time-travel correctly. |
| Beginner clarity | 4.0 | Clearly states what is known and what is not. |
| Practical applicability | 3.0 | Recommends docs but the engineer leaves with no answer for a feature that IS documented and IS in resources. |
| Completeness | 2.5 | Canonical answer (`system.table_changes` Trino TVF + Spark `start-snapshot-id` option) was added to resources by teacher in iter390 — responder did not find it. |
| **Average** | **3.25** | **BORDERLINE FAIL** |

### Why this is worse than a normal honest-punt

This is the SECOND consecutive iteration where the responder honest-punts on incremental-reads, and the FIRST iteration where the responder honest-punts on a topic the teacher had already patched. In iter390 the teacher added:
- Trino `system.table_changes(schema, table, since_snapshot_id, end_snapshot_id)` table function
- Spark `spark.read.option("start-snapshot-id", ...).option("end-snapshot-id", ...).load(table)`

…to resources/13. The responder either (a) did not retrieve resources/13, (b) retrieved it but the keywords in the question ("snapshot incremental reads", "since last snapshot") did not match the headings in the patch, or (c) the patch landed in a sub-section that is hard to surface.

**This is no longer a content gap — it is a RETRIEVAL gap.** The teacher must verify the patch landed with discoverable headings.

---

## Q2 — Trino 100 concurrent Python connections

Strong technical answer that maps cleanly to the production stack.

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.5 | Pool need correct; HTTP polling vs TCP correct; `http-server.max-concurrency` correctly named; 10-20 per replica is reasonable; JWT-per-connection correct (bearer tokens aren't pool-shareable). Minor: "HTTP long-poll" is shorthand for poll-`nextUri` pattern. |
| Beginner clarity | 4.5 | Concrete numbers; clear conceptual frame (HTTP is different from Postgres MaxConnections). |
| Practical applicability | 5.0 | Engineer knows exactly: (1) configure SQLAlchemy/DBAPI pool 10-20 per replica, (2) set `http-server.max-concurrency` server-side, (3) each pooled connection carries its own JWT. Maps to prod_info.md JWT auth stack. |
| Completeness | 4.5 | Covers client pool, server limit, sizing, JWT, JDBC HikariCP vs Python equivalent. Minor gap: `query.max-concurrent-queries` (coordinator cap) and resource groups for fair-share at saturation. |
| **Average** | **4.625** | **STRONG PASS** |

---

## Action items for teacher (iter 392)

### CRITICAL — Fix the iter390 patch retrievability
1. Open `resources/13` (or wherever the iter390 incremental-reads patch landed). Verify:
   - There is an explicit top-level heading like `## Incremental reads: rows changed between two snapshots (system.table_changes)`.
   - The content uses the exact phrasings a SaaS engineer would search for: "incremental read", "rows changed since last snapshot", "CDC export", "delta between snapshots", "what changed".
   - Cross-link from the snapshot-expiry and time-travel sections so retrieval from those queries also surfaces this content.
   - Confirm both Trino path (`SELECT * FROM TABLE(system.table_changes(...))`) and Spark path (`spark.read.option("start-snapshot-id", ...)`) are in the same section.
2. If the content is already there with good headings, the issue may be retrieval-keyword-mismatch. Add a short FAQ stub at the top of resources/13 like: "Q: How do I read only the rows that changed since the last snapshot? A: Use `system.table_changes(...)` — see section X."

### MED — Trino concurrent client polish (not urgent)
3. Q2 is in good shape. Optional addition: a minimal SQLAlchemy code block:
   ```python
   from sqlalchemy import create_engine
   engine = create_engine(
       "trino://user@host:443/iceberg",
       connect_args={"auth": JWTAuthentication(token), "http_scheme": "https"},
       pool_size=15, max_overflow=5, pool_pre_ping=True,
   )
   ```
   …plus a note on JWT lifecycle (token refresh under pool reuse — 1-hour token expiry vs 24-hour pooled connection).

---

## Action items for judge (iter 392 probe targets)

1. **CRITICAL — Iceberg incremental reads, THIRD angle.** Phrase as "weekly CDC export of changed rows from Iceberg to downstream Postgres". If responder honest-punts a third time, the issue is structural retrieval failure — escalate to teacher with explicit instruction to restructure resources/13 indexing.
2. Trino concurrent client second angle — JWT token refresh under pool reuse (1-hour token expiry, 24-hour app session). Tests whether the responder understands JWT lifecycle, not just pool sizing.
3. Carry-forward standard backlog (HMS->Nessie no-downtime, SPILL_FAILED 60GB at 200GB cap, MERGE INTO rollback, OPA-override timeout, schema registry forward/backward compat, EXPLAIN TYPE IO + VALIDATE, etc.).

---

## Pattern observed

- Two-iteration PASS streak (iter389 4.75 + iter390 4.125) broken at iter391 (3.9375 FAIL).
- Q1 floor (honest-punt) + Q2 ceiling (canonical answer) pattern continues, but Q1 floor dropped to 3.25 because the topic was already supposed to be patched. Honest-punt-on-already-patched-content is a worse outcome than honest-punt-on-true-gap — it means the responder cannot be trusted to retrieve content the teacher has written.
- Q2 strong production-stack-fit (JWT auth maps to prod_info.md).
- Recommendation: **next iter must re-probe Iceberg incremental reads from a third angle**. If it punts again, this is a structural problem (resource indexing, not content) and the teacher should restructure rather than just adding more content.

Trajectory iter370–391: 4.625 -> 4.375 -> 4.47 -> 3.98 FAIL -> 4.5625 -> 4.75 -> 4.1875 -> 4.4375 -> 4.40625 -> 4.5625 -> 3.25 FAIL -> 4.71875 -> 4.8125 -> 4.78125 -> 4.375 -> 4.094 -> 4.4375 -> 4.4375 -> 4.4375 -> 4.25 -> 3.125 FAIL -> 4.75 PASS -> 4.125 PASS -> **3.9375 FAIL**.

Sources:
- [Trino HTTP client properties (admin/properties-http-client.html)](https://trino.io/docs/current/admin/properties-http-client.html)
- [Trino JWT authentication (security/jwt.html)](https://trino.io/docs/current/security/jwt.html)
- [Trino Python client](https://github.com/trinodb/trino-python-client)
- [Trino Iceberg connector — system.table_changes](https://trino.io/docs/current/connector/iceberg.html)
