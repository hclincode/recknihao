# Judge Feedback — Iter 331

Date: 2026-05-27
Phase: extended
Topics: Iceberg table maintenance / history.expire.* Spark-only (Q1) + Multi-tenant analytics / Iceberg no metastore cache by design (Q2)

---

## Q1 — history.expire.* Properties: Spark Required, Not Trino

### Score
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | All four verification points pass: (1) Trino 467 SET PROPERTIES does not accept history.expire.* properties. (2) SET TBLPROPERTIES is correct Spark SQL syntax. (3) "events$properties" is the correct Trino metadata table for verification. (4) Floor semantics ("more conservative wins") are correct. |
| Beginner clarity | 4 | Correctly explains why Trino rejects these and what to do instead. Minor gap: doesn't explain to a true beginner what "connector-level property" means in plain language. |
| Practical applicability | 5 | Runnable Spark SQL block + Trino verification query. Fits on-prem Spark + Iceberg 1.5.2 stack. |
| Completeness | 5 | Covers both parts of the question: which engine to use AND why Trino can't do it. Plus explains what the properties do. |
| **Average** | **4.75** | **PASS** |

### What Worked
- Correctly routes to Spark SQL (`SET TBLPROPERTIES`) — the iter330 resource fix (ENGINE CALLOUT in resources/17) held perfectly.
- Trino connector-level vs Iceberg-native table property distinction is explained correctly.
- Verification via `"events$properties"` Trino metadata table — copy-pasteable and correct.
- Floor semantics framing is clear: "table-level properties are sticky and durable, per-call arguments are one-off overrides."
- No recurrence of iter330's Spark/Trino confusion.

### What Missed
- "Connector-level Iceberg properties" is jargon a beginner won't know — a one-sentence plain-English explanation would close this ("Trino only recognizes its own catalog settings like how data is partitioned or what file format to use, not Iceberg's internal metadata management settings").
- No mention of what happens if you accidentally set `history.expire.min-snapshots-to-keep` too conservatively and can't expire snapshots you need to — a brief "and here's how to unset it" would round out the answer.

### Technical Accuracy (verified)
1. Trino 467 SET PROPERTIES rejects history.expire.* — CORRECT
2. SET TBLPROPERTIES is correct Spark SQL syntax — CORRECT
3. "events$properties" is correct Trino metadata table — CORRECT
4. Properties act as a floor expire_snapshots cannot violate — CORRECT

### Rubric Update
- Iceberg table maintenance: prior avg 4.561 across 26 questions → (4.561 × 26 + 4.75) / 27 = 123.336 / 27 = **4.568 across 27 questions**. Status: **PASSED** (recovering from iter330 drop; fix held).

---

## Q2 — Iceberg Connector Has No Metastore Cache By Design

### Score
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.5 | All five major claims verified correct. Minor SQL drift: `execution_time_ms` is not a documented column of system.runtime.queries (use `queued_time_ms`, `analysis_time_ms`, `planning_time_ms`); `ORDER BY create_time DESC` should be `ORDER BY created DESC`. Both would fail at runtime. Resource/18 has correct column names — answer drifted slightly from it. |
| Beginner clarity | 4.5 | "Directory listing" mental model and snapshot-consistency reason are clear. "SPOF" expanded in context. |
| Practical applicability | 5.0 | Comma-separated hive.metastore.uri config, kubectl diagnosis, phase timing SQL, REST catalog migration path — all actionable. |
| Completeness | 4.5 | Covers: is the caching difference real, why no Iceberg cache, what 5-10s actually means, diagnosis, HMS HA, REST catalog. Minor gap: no mention of JVM heap sizing or concrete Postgres connection pool tuning. |
| **Average** | **4.625** | **PASS** |

### What Worked
- Correct reframe: "the missing cache is NOT what's causing your pause; the HMS call is cheap when healthy — something upstream is wrong."
- Snapshot consistency reason for no cache is explained correctly and clearly.
- trinodb/trino#13115 citation for the intentional no-cache decision.
- Comma-separated `hive.metastore.uri` failover config included (gap from iter330 Q2 filled).
- REST catalog (Polaris, Lakekeeper, Nessie) as long-term escape — correct and fits on-prem k8s stack.
- No fabricated config properties.

### What Missed
1. **SQL column name drift**: `execution_time_ms` is not a valid column in `system.runtime.queries` (documented columns are `queued_time_ms`, `analysis_time_ms`, `planning_time_ms`, `execution_time`). `ORDER BY create_time DESC` should be `ORDER BY created DESC`. Both would fail at runtime. Resource/18 is correct; the answer drifted from it.
2. No Iceberg-vs-Hive caching contrast statement ("Hive connector has `hive.metastore-cache-ttl`; Iceberg connector deliberately does not") as a direct explicit sentence — it's implied but not stated as plainly as it could be.
3. No concrete JVM heap number for HMS pods serving 80 tenants.

### Technical Accuracy (verified)
1. Hive connector has hive.metastore-cache-ttl — CORRECT
2. Iceberg connector intentionally has no metastore cache (trinodb/trino#13115) — CORRECT
3. Snapshot consistency is the reason — CORRECT (metadata pointer changes on every write)
4. Comma-separated hive.metastore.uri is valid Trino failover config — CORRECT (Trino release 346+)
5. system.runtime.queries has queued_time_ms, analysis_time_ms, planning_time_ms — CORRECT (but execution_time_ms is wrong; it's execution_time or similar)

### Rubric Update
- Multi-tenant analytics: prior avg 4.478 across 126 questions → (4.478 × 126 + 4.625) / 127 = 568.853 / 127 = **4.479 across 127 questions**. Status: **PASSED** (stable, slight upward drift).

---

## Iter 331 Summary

**Iter 331 average: (4.75 + 4.625) / 2 = 4.6875 — PASS** ✓ (Q1 PASS / Q2 PASS)

### Notable
- Q1 4.75: history.expire.* Spark-only fix — the iter330 ENGINE CALLOUT in resources/17 held perfectly. The recurring Spark/Trino confusion class of errors has been addressed in resources/17 three times; the latest probe was clean.
- Q2 4.625: Iceberg no-HMS-cache by design — correct conceptually, but two SQL column names drifted from what resource/18 documents. Resource/18 is already correct; this is a responder drift error, not a resource bug.

### Resource fixes applied this iteration
None needed. Resources/17 iter330 fix verified holding. Resources/18 already has correct column names — no fix needed.

### Suggested focus for Iter 332
- **Postgres-to-Iceberg ingestion** (4.496/117, not probed since iter329): probe `offset.flush.interval.ms` at-least-once delivery gap, or probe snapshot-row null LSN behavior in CDC dedup (identified as a gap in iter329 but never directly probed).
- **Multi-tenant analytics** (4.479/127): probe `hive.metastore-cache-ttl` usage on the Hive connector — when it helps, what the tradeoffs are, and how to avoid serving stale data. Or probe connection pool sizing for HMS backing Postgres at 80-tenant scale.
- **Iceberg table maintenance** (4.568/27, recovering): probe `$history` metadata table vs `$snapshots` — which to use for "which snapshot was live at time T" reconstruction (identified as a gap in iter330).
