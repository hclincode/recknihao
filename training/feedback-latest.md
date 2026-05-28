# Iter 356 Q1 Judge Feedback — 2026-05-29

## Question

"Our Trino workers keep running out of memory when we join a 200-million-row events table in Iceberg to a 50-million-row accounts table in Postgres via the postgresql connector. The workers crash with an out-of-memory error. Are there specific settings we should tune, or is there something fundamental about this kind of federated join that we're doing wrong?"

## Score

| Dimension | Score |
|---|---|
| Technical accuracy | 4.5 |
| Beginner clarity | 4.0 |
| Practical applicability | 4.5 |
| Completeness | 3.5 |
| **Average** | **4.125** |

**Verdict: PASS** (above the 4.0 per-question bar; Trino federation topic running average remains stable above 4.5 threshold)

Topic running average: Trino federation 4.513/252 → **4.511/253 questions** — PASSED, stable.

## What landed

- `join_distribution_type` session property with `BROADCAST`/`PARTITIONED` values — VERIFIED correct per trino.io/docs/current/admin/properties-general.html.
- `join_max_broadcast_table_size` default of 100MB — VERIFIED correct per trino.io/docs/current/optimizer/cost-based-optimizations.html.
- `EXPLAIN (TYPE DISTRIBUTED)` showing `Exchange[Type=REPLICATE]` (broadcast) vs `Exchange[Type=REPARTITION]` (partitioned) — VERIFIED correct per trino.io/docs/current/sql/explain.html.
- `SHOW STATS FOR postgres_catalog.public.accounts` + `ANALYZE public.accounts` on the Postgres primary if row_count is NULL — VERIFIED correct per trino.io/docs/current/optimizer/statistics.html (the Postgres connector relies on native PG statistics).
- Step-by-step diagnostic recipe is copy-pasteable on Trino 467.
- On-prem k8s recommendation to "force PARTITIONED for stability" is the right operational call.
- Honest caveat that 50M rows at 10-20GB uncompressed won't fit a 500MB broadcast threshold raise.

## What slipped — gaps to close in resources/22

### HIGH priority — the engineer literally asked "is there something fundamental we're doing wrong"

The answer treats this as purely a tuning question and never surfaces the architectural alternative: **ingest the Postgres accounts table into Iceberg as a dimension table** instead of joining live across catalogs. For a 50M-row Postgres dimension on this on-prem k8s + MinIO stack, materializing nightly with `INSERT INTO iceberg.analytics.accounts AS SELECT * FROM postgres_catalog.public.accounts` (or via Debezium CDC for fresher data) is often the right SaaS answer. The federate-vs-ingest tradeoff is literally a named bullet on the topic checklist ("when to federate vs ingest") and should have been the closing recommendation.

### MEDIUM priority — dynamic filtering not mentioned

Trino's dynamic filtering is the standard tool for exactly this Iceberg-fact x JDBC-dimension scenario. The Iceberg connector default `dynamic-filtering.wait-timeout=1s` (Trino 467) should have appeared. Iter164/165 already flagged dynamic filtering as a recurring gap on this topic — it slipped again.

### MEDIUM priority — worker memory and spilling

The engineer's question is about workers running out of memory. The answer doesn't mention any actual memory settings:
- `query.max-memory-per-node` and `query.max-memory` (cluster-wide limits)
- `memory.heap-headroom-per-node`
- `spill_enabled` session property (and `spill-enabled` config) for partitioned-join stability under memory pressure

These are the direct levers for the literal symptom described.

### LOW priority — minor technical imprecisions

- "Trino's CBO chooses the smaller table as the build side" — usually true but not a CBO rule; in AUTOMATIC mode the CBO can reorder based on cost.
- "Filter events aggressively first to ... make Trino more likely to pick events as build side or switch to partitioned join" — the actual mechanism is dynamic filtering + improved cost estimates, not just relative table size. Shrinking events doesn't directly shrink accounts.

### LOW priority — Beginner clarity

The 3-step structure is good, but key terms are used without inline definitions:
- "build side"
- "REPLICATE" / "REPARTITION"
- "hash-redistributes"
- "join distribution type"
- "broadcast threshold"

A one-line callout like *"Build side = smaller input read fully into a hash table; probe side = larger input streamed through. Broadcast replicates build to every worker; partitioned hash-redistributes both inputs on the join key."* would close most of this gap.

## Teacher action for iter357 (LOW-MEDIUM priority — Q1 passed)

1. Add a **"federated join OOM runbook"** to `resources/22-trino-federation-postgresql.md` ordered: (a) `EXPLAIN (TYPE DISTRIBUTED)` distribution check; (b) `SHOW STATS` + `ANALYZE` on Postgres source; (c) **dynamic filtering** as the first lever; (d) `join_distribution_type='PARTITIONED'` to force partitioned; (e) raise `join_max_broadcast_table_size` only if heap headroom allows; (f) `spill_enabled=true` for stability under pressure; (g) **architectural alternative**: ingest 10M+ row Postgres dimensions into Iceberg.
2. Add a **"build side vs probe side"** one-line definition callout.
3. Add the **"when to federate live vs ingest into Iceberg"** decision matrix: <10M rows → federate live; 10M-100M rows → ingest nightly; >100M rows → CDC pipeline. The topic checklist already names this as an in-scope element.

## Judge probe targets for iter357

Under-tested topics still open per iter355→356 notes:
1. **Query plan optimization** — reading `EXPLAIN ANALYZE` output to find bottlenecks (TableScan/Filter/Aggregate cost, scan stats, dynamic filter rows, hash collision count). Not yet probed.
2. **Cost considerations cloud vs on-prem** — Trino+Iceberg+MinIO on-prem vs AWS S3+Athena+Glue lift-and-shift. Not yet probed.
3. **Federate-vs-ingest architectural choice** — re-probe with phrasing like "we're joining a 50M-row Postgres customers table to Iceberg events every 5 minutes — keep federating live, or materialize customers into Iceberg?" to test if iter357 teacher action #3 lands.
4. **Postgres-vs-OLAP decision framing** — iter355 Q2 gave 4.9375 on first probe; needs at least one additional re-probe at different phrasing before this subtopic is declared durable.

## Sources verified via WebSearch

- [General properties — Trino 481 Documentation](https://trino.io/docs/current/admin/properties-general.html)
- [Cost-based optimizations — Trino 481 Documentation](https://trino.io/docs/current/optimizer/cost-based-optimizations.html)
- [EXPLAIN — Trino 480 Documentation](https://trino.io/docs/current/sql/explain.html)
- [Table statistics — Trino 480 Documentation](https://trino.io/docs/current/optimizer/statistics.html)
- [PostgreSQL connector — Trino 481 Documentation](https://trino.io/docs/current/connector/postgresql.html)

---

## Iter 356 End-of-Iteration Summary — 2026-05-29

### Scores table

| Question | Topic | Score | Verdict |
|---|---|---|---|
| Q1 | Trino federation OOM on Iceberg-fact x Postgres-dimension join | 4.125 | PASS (per-question bar 4.0) |
| Q2 | When to add OLAP / DuckDB proxy test for a slow 5M-row 45s Postgres query | 3.875 | FAIL (below 4.0 per-question bar) |
| **Iteration average** | | **4.000** | **MARGINAL PASS** |

### Root cause analysis

**Q1 (4.125 PASS, but soft pass)** — answer treated the prompt as purely a tuning question. The engineer literally asked "is there something fundamental we're doing wrong" and the answer never surfaced the federate-vs-ingest architectural alternative, never mentioned dynamic filtering (the standard tool for exactly this Iceberg-fact x JDBC-dimension scenario, and a recurring gap flagged back at iter164/165), and never named the direct memory levers (`query.max-memory-per-node`, `spill_enabled`). All cited Trino syntax/properties verified correct against trino.io/docs/current. The 3.5 on completeness is what dragged the average down — the answer covered the join-distribution-type and broadcast-threshold dimension well but missed three named subtopics from the checklist.

**Q2 (3.875 FAIL)** — two distinct failure modes compounded:

1. **Technical accuracy error**: recommended `SELECT ... INTO OUTFILE '/tmp/events.csv' FROM postgres ...` to extract the table for a DuckDB proxy test. `INTO OUTFILE` is **MySQL syntax**, not Postgres. Postgres requires `\COPY events TO '/tmp/events.csv' CSV HEADER` (psql client-side) or `COPY events TO '/tmp/events.csv' CSV HEADER` (server-side, requires superuser + server-writable path). DuckDB-side ingest is `COPY events FROM '/tmp/events.csv' (HEADER)` or `CREATE TABLE events AS SELECT * FROM read_csv_auto('/tmp/events.csv')`. A copy-paste-broken command on an OLAP-proxy-test recommendation directly defeats the purpose of the answer.
2. **Prod-environment-fit miss**: the org already runs Trino+Iceberg+MinIO on-prem (per prod_info.md). The natural proxy test is `CREATE TABLE iceberg.scratch.events AS SELECT * FROM postgres_catalog.public.events` followed by an aggregate query against the Iceberg copy — not a fresh DuckDB install on a laptop with manual CSV export. The answer recommended a tool the engineer would have to introduce vs. using infrastructure they already operate.
3. **Diagnostic depth too shallow**: 5M rows at 45s p95 is a tuning-first signal, not an OLAP-adoption signal. The answer should have led with `EXPLAIN (ANALYZE, BUFFERS)` reading (sequential scan vs index scan, sort spill to disk, hash join build size), missing/stale indexes, `work_mem` sizing, partial indexes on hot filter predicates, and BRIN for time-series — exactly the tuning-first framing that landed at 4.9375 on iter355 Q2. The answer jumped to "test OLAP via DuckDB" before establishing whether Postgres tuning closes the gap, which is the same premature-OLAP-push failure mode iter355 explicitly avoided.

### Pattern across Q1 and Q2

Both answers share a **practical-applicability ceiling**: technically defensible content that doesn't account for the production stack the engineer is sitting on. Q1 missed "ingest into the Iceberg you already have" as the architectural fix; Q2 missed "use the Trino+Iceberg you already have as the OLAP proxy" and recommended a tool outside the stack. Whatever resource is being read for "when to introduce OLAP" framing needs an explicit **prod-environment-aware decision step**: "before recommending a new engine, check if the engineer already runs one — if so, use it for the proxy test."

### Iter 357 teacher action suggestions

**HIGH priority — Q2 was the FAIL**:

1. **Fix Postgres CSV extraction syntax** wherever it appears in `resources/` (likely `resources/03-postgres-vs-olap.md` or the "when to add OLAP" doc). Replace any `INTO OUTFILE` reference with Postgres `\COPY` / `COPY ... TO` syntax. Verify against postgresql.org/docs/current/sql-copy.html.
2. **Add a "use the OLAP engine you already have" callout** to the OLAP-adoption resource. Decision tree: "(a) is the org already running Trino/Iceberg/Snowflake/BigQuery? If yes, copy a sample into that engine for the proxy test — do not install DuckDB. (b) only if no OLAP engine exists, then DuckDB is the cheapest proxy."
3. **Reinforce tuning-first framing for sub-10M-row Postgres p95 slowness**. Concrete checklist: `EXPLAIN (ANALYZE, BUFFERS)`, index audit (`pg_stat_user_indexes`), `work_mem` sizing, partial indexes, BRIN for time-series, materialized views, parallel query (`max_parallel_workers_per_gather`) — **before** any OLAP recommendation. This is the exact framing that earned 4.9375 on iter355 Q2 and slipped on iter356 Q2.

**MEDIUM priority — Q1 PASSED but soft**:

4. Add **"federated join OOM runbook"** to `resources/22-trino-federation-postgresql.md` in this order: (a) `EXPLAIN (TYPE DISTRIBUTED)` distribution check; (b) `SHOW STATS` + `ANALYZE` on Postgres source; (c) **dynamic filtering** as the first lever; (d) `join_distribution_type='PARTITIONED'`; (e) `join_max_broadcast_table_size` raise only if heap headroom allows; (f) `spill_enabled=true`; (g) **architectural alternative**: ingest 10M+ row Postgres dimensions into Iceberg.
5. Add **federate-vs-ingest decision matrix**: <10M rows → federate live; 10M-100M rows → ingest nightly; >100M rows → CDC pipeline. This is a named checklist subtopic that has slipped twice now.
6. Add inline definitions for "build side", "REPLICATE", "REPARTITION", "hash-redistributes" — beginner-clarity gap on Q1.

**LOW priority polish (carried from iter355 notes)**:

7. Fix `resources/17-iceberg-table-maintenance.md` Iceberg 1.8.0 release date `2026-02-13` → `2025-02-13`.

### Judge probe targets for iter 357

1. **Re-probe federate-vs-ingest at different phrasing** — e.g., "we're joining a 50M-row Postgres customers table to Iceberg events every 5 minutes — keep federating live, or materialize customers into Iceberg?" Tests if iter357 action #4-#5 lands.
2. **Re-probe OLAP-adoption with prod-environment-aware framing** — e.g., "Postgres query on a 5M-row table runs 30s, org already runs Trino+Iceberg+MinIO — what's the proxy test and what's the decision?" Tests if iter357 action #1-#2 lands and if the answer routes to existing Trino vs recommending DuckDB.
3. **Re-probe Postgres-vs-OLAP decision framing one more time** — iter355 4.9375 + iter356 3.875 = mixed signal, subtopic NOT durable yet, needs a third probe at a third phrasing before declaring stable.
4. **Query plan optimization** — `EXPLAIN ANALYZE` reading for slow Iceberg queries (TableScan/Filter/Aggregate cost, scan stats, dynamic filter rows). Still not probed.
5. **Cost considerations cloud vs on-prem** — Trino+Iceberg+MinIO on-prem vs AWS S3+Athena+Glue lift-and-shift cost model. Still not probed.
