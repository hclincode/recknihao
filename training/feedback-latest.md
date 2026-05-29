# Iter 383 Feedback — 2026-05-30 (EXTENDED PHASE)

**Overall: 4.094 — PASS (barely)** — Q1 3.875 FAIL + Q2 4.3125 PASS

Q1 schema registry FAILED at 3.875 — first per-question fail since iter381 STRONG PASS streak. Q2 CBO stats freshness PASSED at 4.3125. Iteration cleared 4.0 average but Q1 needs targeted fix.

---

## Q1 — Schema registry necessity for Debezium + Iceberg pipeline: 3.875 FAIL

| Dim | Score | Issue |
|---|---|---|
| TA | 4.0 | "NOT required" stated correctly but understates schema-evolution-safety value |
| BC | 3.75 | WAL/DDL/Avro/Protobuf/JSON serialization without inline gloss |
| PA | 4.0 | "Use JSON now, add later" pragmatic but missed when-exactly threshold + on-prem options |
| Comp | 3.75 | Missed schema-evolution safety (the real value), Iceberg coupling, on-prem registry options (Apicurio), cost-of-not-using |

### Teacher actions for Q1 (MEDIUM priority — FAIL recovery)

1. **MEDIUM TA + Comp** — Reframe schema registry from "size optimization" to **schema evolution safety gate**. The primary value of a schema registry in CDC pipelines is NOT message size (Avro vs JSON) — it is **compatibility enforcement**: registry rejects incompatible schema changes (e.g., dropping a non-null column) BEFORE producer publishes, preventing silent breakage of the Iceberg writer downstream. Without registry, Iceberg writer can mid-stream encounter a schema version it can't apply, requires manual snapshot rollback. Add this framing to `resources/postgres-to-iceberg-cdc.md` or schema-evolution resource.

2. **MEDIUM PA — on-prem fit** — Production stack is on-prem k8s, no public cloud. Confluent Schema Registry requires Confluent license for production use. **Apicurio Registry** (Red Hat, Apache 2.0) is the on-prem-friendly drop-in replacement — runs as a k8s deployment, REST-compatible with Confluent SR client API. Add to resources as the on-prem recommendation.

3. **MEDIUM BC inline-gloss cascade for CDC/Kafka vocab** — add one-liners for:
   - WAL = Postgres write-ahead log Debezium tails for row-level changes
   - DDL = `ALTER TABLE` etc. — schema-change SQL, separate from row-level changes
   - Avro = compact binary message format with schema, ~5x smaller than JSON
   - Protobuf = Google's compact binary format, schema-first
   - Schema registry = central service that stores schema versions + enforces compatibility

4. **MEDIUM Comp — when to add registry** — add concrete threshold table:
   - Use plain JSON if: <1000 msg/sec, single consumer (just Iceberg writer), schemas stable
   - Add registry if: schemas evolving monthly+, multiple consumers, message rate >5k/sec, OR after first production incident from incompatible schema change

5. **MEDIUM Comp — Iceberg schema-evolution coupling** — registry version increment → Iceberg writer should detect via Debezium message envelope `schemaId`, apply `ALTER TABLE ADD COLUMN` to Iceberg table. Document this flow (already mentioned in recent strong-pass iterations on Debezium schema change — verify resource currency).

---

## Q2 — Trino CBO statistics freshness after ANALYZE: 4.3125 PASS

| Dim | Score | Issue |
|---|---|---|
| TA | 4.5 | Stats-don't-auto-refresh + 3 failure modes accurate; "memory reservation" wording loose |
| BC | 4.0 | CBO/broadcast vs partitioned/skew need inline gloss |
| PA | 4.5 | Weekly column-targeted ANALYZE is concrete; could add `WITH (columns=ARRAY[...])` syntax |
| Comp | 4.25 | Missed Puffin NDV specifics, stale-stats detection (EXPLAIN row estimate vs actual), staged refresh hot/cold |

### Teacher actions for Q2 (LOW priority — already PASS)

1. **LOW Comp — Puffin NDV detail** — Trino 467 reads NDV (number of distinct values) sketches from Iceberg Puffin sidecar files. Add to `resources/trino-cbo-statistics.md`: Puffin file is the on-disk artifact; ANALYZE writes/updates it; CBO reads it at plan time. Production stack relevance: Iceberg 1.5.2 + Trino 467 fully supports Puffin.

2. **LOW PA — stale-stats detection oncall step** — add to oncall flow: run `EXPLAIN <query>` and compare estimated row counts vs `EXPLAIN ANALYZE` actuals. >2x divergence = stats stale → trigger targeted ANALYZE.

3. **LOW PA — column-targeted ANALYZE syntax** — `ANALYZE TABLE iceberg.tenant_db.events WITH (columns = ARRAY['tenant_id','event_date','event_type'])` — cheaper than full table, runs in minutes for hot columns.

4. **LOW Comp — staged refresh for skewed tenants** — production strategy: hot tenants (top 10 by row count) daily ANALYZE on join/filter columns; full table weekly. Document as scheduled job pattern.

5. **LOW BC** — inline-gloss CBO (cost-based optimizer = picks plan based on row count estimates), broadcast join (small side copied to every worker), partitioned join (both sides shuffled by join key), skew (one tenant has 100x rows of others).

---

## Patterns across iter 383 and recent extended phase

- **Iter383 4.094 ≈ 4.10 PASS but Q1 FAIL drops avg significantly** — first per-question FAIL since iter381 STRONG PASS streak. Q1 schema-registry topic appears underdeveloped relative to Debezium/Iceberg CDC core resources.
- **TA drag on Q1 (−1.0)** — framing schema registry as size-optimization rather than evolution-safety-gate is the technical accuracy miss; recurring pattern when responder treats optional tools as purely optional without articulating production-grade value.
- **BC drag both Qs (−1.0 / −1.25)** — vocab cascade (WAL/DDL/Avro/Protobuf for Q1; CBO/broadcast/partitioned/skew for Q2) still missing inline gloss. Carry-forward from iter378-382 BC drag pattern.
- **PA strong both Qs (4.0 / 4.5)** — pragmatic guidance (use JSON, add later; weekly column-targeted ANALYZE) is present; missing only the precise threshold and on-prem-specific tool names.
- **Comp drag Q1 (−1.25)** — schema-evolution coupling + on-prem registry options + Iceberg writer schema-flow all missing in Q1; Q2 Comp drag (−0.75) is Puffin + stale-stats detection.
- **Production-stack fit miss on Q1** — Apicurio vs Confluent on-prem licensing was not mentioned. Recurring pattern: responder gives generic guidance, misses on-prem k8s + MinIO + no-public-cloud constraint when recommending tools.

## Probe targets for iter 384+

1. **Schema registry 2nd angle** — "I'm seeing my Iceberg writer fail after a Postgres `ALTER TABLE` last night, what should I have done differently?" — tests schema-evolution-safety framing in reverse.
2. **Schema registry 3rd angle** — "We're on-prem k8s with no Confluent license; what registry should I run?" — tests Apicurio recommendation specifically.
3. **CBO stats 2nd angle** — "EXPLAIN says estimated rows = 10k but actual = 5M, what does that mean?" — tests stale-stats detection step.
4. **CBO stats 3rd angle** — "Our tenant_id has 100x skew across customers; how do I keep stats accurate without re-ANALYZING the whole 10TB table?" — tests staged refresh strategy.
5. **Carry-forward** — concurrency JWT+OPA overhead (iter382), Trino result caching layer choice (iter381), Iceberg branches concurrent fast_forward (iter381), bucket(N) sizing 32 vs 128 vs 256 (iter382), partition spec migration without downtime (iter382).
