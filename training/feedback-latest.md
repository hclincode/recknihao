# Feedback — Iter 274 (Extended phase)

Date: 2026-05-27
Topic: Trino federation — EXPLAIN plan interpretation (Q1 PASS) + JDBC connection pooling under load (Q2 PASS)

## Results summary

| Question | Topic angle | Score | Pass/Fail |
|---|---|---|---|
| Q1 | EXPLAIN plan: ScanFilterProject vs constraint on [col], Input/Output row counts, pushdown rules, diagnostic checklist | **4.75** | PASS |
| Q2 | JDBC connection pooling: no native pool, PgBouncer + prepareThreshold=0, resource groups, queuing behavior | **4.81** | PASS |

**Iter 274 average: 4.78 — PASS** ✓ Both passed!

**Topic update**: Trino federation: 4.485/221 → **4.487/223** (NEEDS WORK, gap 0.013 — improving steadily)

---

## What worked

### Q1 — EXPLAIN plan interpretation (4.75)
1. `ScanFilterProject` above `TableScan` = pushdown failure — correct
2. `constraint on [col]` inside `TableScan` = pushdown success — correct
3. Input/Output row count interpretation (large Input at TableScan = not pushed) — correct
4. Pushdown rules table (equality/ranges/IN-list push; ILIKE/function calls don't) — correct direction
5. Four-step diagnostic checklist — actionable
6. EXPLAIN ANALYZE runtime confirmation — correct
7. Postgres slow-query log as ground truth — practical

### Q2 — JDBC connection pool (4.81)
1. OSS Trino 467 has no native `connection-pool.*` properties — correct (verified)
2. PgBouncer + `prepareThreshold=0` — correct and complete explanation of why
3. Resource group `hardConcurrencyLimit` / `maxQueued` property names — correct
4. Queries queue at Trino, not Postgres — correct key insight
5. Four-layer defense (PgBouncer → Postgres role cap → resource groups → statement timeout) — excellent framing
6. Source-selector caveat (clients must set X-Trino-Source or selector silently fails) — high-value operational detail
7. `pg_stat_activity` + PgBouncer `SHOW POOLS` monitoring — concrete

---

## Errors / gaps to fix before iter275

### Q1 (important correction)
- **ILIKE "never pushes" is too absolute**: Answer stated "customer_email ILIKE 'a%'... never pushes in OSS Trino 467." Per PR #11045 (merged into Trino), LIKE/ILIKE pushdown was added to the PostgreSQL connector. Actual behavior depends on session config and column collation. The correct statement: "ILIKE may not push — always verify with EXPLAIN rather than assuming." Resource should reflect this nuance.

### Q2 (minor)
- "1 query = 1 connection" simplification needs a caveat: each Postgres **TableScan** = 1 connection; a query joining two Postgres tables opens 2 connections
- No mention of PgBouncer 1.21+ native prepared-statement tracking as an alternative to `prepareThreshold=0`
- `softMemoryLimit: "60%"` in resource group example given without explanation

---

## Resource fixes before iter275

### Important

1. **ILIKE/LIKE pushdown nuance** (resource 22, predicate pushdown section):
   - Change "ILIKE never pushes" to "ILIKE may or may not push depending on session config and column collation — always verify with EXPLAIN"
   - Add: the PostgreSQL connector has LIKE/ILIKE pushdown support (added via Trino PR #11045); behavior depends on `enable_string_pushdown_with_collate` session property and the column's collation
   - Keep the practical advice: verify with EXPLAIN rather than assuming

---

## Suggested iter275 angles (MUST target Trino federation, gap 0.013)

Topic at 4.487/223. Need ~6-7 more questions at 4.875+ to cross 4.500 threshold.

1. **Cross-catalog transaction limits** — engineer asks whether they can do a transaction that writes to both Postgres and Iceberg atomically; answer: no cross-catalog transactions in Trino; each catalog is independently committed; patterns for handling failure

2. **Trino Web UI for federation debugging** — engineer asks what the Trino UI shows when a federated query runs; stages, tasks, JDBC operator, where to find Input/Output row counts in the UI (vs EXPLAIN)

3. **Re-test: predicate pushdown with ILIKE** — now that we've corrected the resource, test whether the responder gives the nuanced answer (may push, verify with EXPLAIN) rather than the wrong categorical answer

4. **Re-test: resource group configuration** — earlier iters had errors here; verify the current resource correctly describes `hardConcurrencyLimit`, `maxQueued`, file-based vs db-based manager
