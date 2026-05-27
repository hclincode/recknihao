# Feedback — Iter 305 (Extended phase)

Date: 2026-05-27
Topics: Trino resource groups (Q1) + Iceberg partition strategy for multi-tenant SaaS events table (Q2)

## Results summary

| Question | Topic angle | Score | Pass/Fail |
|---|---|---|---|
| Q1 | Trino resource groups: hardConcurrencyLimit/softMemoryLimit/maxQueued, selectors, weighted_fair | **4.8** | PASS |
| Q2 | Partition strategy: `(day(occurred_at), tenant_id)`, pruning, metadata-only query, compaction, evolution | **4.8** | PASS |

**Iter 305 average: 4.8 — PASS** ✓

**Topic updates**:
- Multi-tenant analytics: 4.461/107 → **4.464/108 questions** (PASSED — improving)
- Iceberg partition design for SaaS: 4.583/16 → **4.596/17 questions** (PASSED — improving)

---

## No resource fixes needed

Both answers were technically accurate and verified against official docs. No resource corrections required before iter306.

---

## What worked

### Q1 — Trino resource groups (4.8)
1. Correctly distinguishes resource groups from "just a queue" — controls concurrency, memory, and admission together
2. All three primary properties named and explained: `hardConcurrencyLimit`, `softMemoryLimit`, `maxQueued`
3. Two-file setup (`resource-groups.properties` + `resource-groups.json`) correct with exact required properties
4. Working JSON config: dashboard and ingestion subgroups under root, correct structure
5. `schedulingPolicy: weighted_fair` correctly placed at parent level; `schedulingWeight` correctly on children
6. Selectors: source/user/queryType routing, first-match-wins ordering rule
7. Client-side `X-Trino-Source` header / JDBC `?source=` parameter correctly identified as routing key
8. Common-mistakes section: forgetting .properties file and wrong property names called out explicitly
9. Verification via `system.runtime.queries` — concrete and runnable
10. Correctly distinguishes group-level `softMemoryLimit` from per-query `query.max-memory-per-node`

### Q2 — Partition strategy (4.8)
1. `(day(occurred_at), tenant_id)` recommended as standard SaaS default with clear reasoning
2. Both-axis pruning explained: time range AND per-tenant, and cross-tenant scenario
3. Metadata-only billing query advantage of identity `tenant_id` vs bucket — explicitly notes bucketing loses this
4. Correct skew threshold (200+ tenants) before switching to bucket transform
5. Production DDL for both Trino and Spark — syntax verified
6. Compaction procedure correctly scoped to Spark with correct options map syntax
7. Snapshot expiry paired with compaction; Trino 467 7-day floor noted
8. Partition evolution: `ALTER TABLE SET PROPERTIES partitioning = ARRAY[...]` syntax verified
9. EXPLAIN ANALYZE verification step gives engineer a concrete next action
10. "What NOT to do" addresses hour/minute, tenant-only, and event_type anti-patterns

---

## Minor gaps (not errors, not resource fixes needed)

### Q1
- Doesn't explicitly answer the CPU question ("Trino resource groups do not have a CPU quota knob — concurrency limits + scheduling weights govern CPU indirectly"). The user asked about CPU; the answer implies it but doesn't state it directly.
- `softCpuLimit` / `hardCpuLimit` optional fields (CPU-time-based admission over a window) not mentioned — rarely used but worth one line.
- JWT auth: `user` selector matches JWT principal name, not a Trino role name — not strictly needed for this question but a recurring gap.

### Q2
- "Column order doesn't affect pruning" is slightly oversimplified — column order can affect directory layout under Hive-compatible paths and write distribution, though pruning itself is indeed column-order-independent.
- Hidden partitioning (no need to add a derived `event_date` column) not mentioned explicitly.

---

## Suggested iter306 angles

1. **Approx_percentile for p99 latency dashboards** — when `approx_percentile` is appropriate vs exact, accuracy guarantees, multi-percentile syntax `approx_percentile(col, ARRAY[0.5, 0.95, 0.99])`
2. **CDC ingestion: Debezium → Kafka → Iceberg** — how change-data-capture works end to end, merge semantics for upserts, handling deletes in Iceberg MoR mode
3. **When Postgres is enough vs when to move to an OLAP layer** — concrete decision triggers (row counts, query latency, concurrent users, query complexity), how to profile Postgres first
4. **Trino CBO follow-up: join ordering with NDV** — what happens when ANALYZE is stale, how to tell if the optimizer made a bad join order decision
