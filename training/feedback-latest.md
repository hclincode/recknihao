# Judge Feedback — Iter 384 (EXTENDED PHASE)

## Iteration outcome: 4.4375 PASS (both Q1 + Q2 pass cleanly)

Strong recovery from iter383 3.875 Q1 FAIL. Schema registry framing now leads with evolution-safety, not size optimization. Apicurio named for on-prem fit.

---

## Q1 — Schema registry for Debezium re-probe (evolution-safety framing)

**Score: 4.50 STRONG PASS** (TA 4.75, BC 4.0, PA 4.75, Comp 4.5)

Responder said: schema-evolution safety is PRIMARY value (silent data corruption otherwise), WAL detection is separate, Apicurio on-prem Apache 2.0, add when >10K msg/sec OR multiple consumers, skip OK for stable schema + single sink, debezium-server-iceberg auto-ALTERs.

### What worked
- **TA recovery (+0.75 from iter383)**: Evolution-safety lead is exactly the right framing. Registry-as-compatibility-gate is the production-value pattern, not registry-as-size-optimization.
- **PA production-fit (+0.75 from iter383)**: Apicurio specifically named — Apache 2.0 license, no Confluent license required, runs on on-prem k8s. Closes the iter383 gap where Confluent SR was implied without on-prem cost call-out.
- **Comp threshold rule**: ">10K msg/sec OR multiple consumers" is concrete and acts as the add-registry trigger. "Skip for stable schema + single sink" is the symmetric skip rule — engineer can decide both directions.
- **debezium-server-iceberg auto-ALTER**: correctly framed as default behavior — clarifies that for the simple single-sink case the consumer handles schema evolution downstream without a registry intermediary.

### Remaining gaps
- **BC (−1.0)**: WAL, Apicurio, ALTER TABLE, sink, msg/sec not inline-glossed. One-liner each (WAL = Postgres write-ahead log Debezium tails for CDC; Apicurio = Red Hat's open-source schema registry drop-in for Confluent SR; sink = downstream consumer like the Iceberg writer).
- **Comp (−0.5)**: Could explicitly couple registry schemaId increment → Iceberg ALTER TABLE ADD COLUMN flow. The mechanism by which auto-ALTER works (Debezium envelope carries schema → consumer parses → applies Iceberg DDL) would close the loop on "how does the safety actually manifest in production."

---

## Q2 — EXPLAIN TYPE LOGICAL vs DISTRIBUTED

**Score: 4.375 PASS** (TA 4.75, BC 3.75, PA 4.5, Comp 4.5)

Responder said: LOGICAL = abstract CBO plan with rows:? signal for missing stats, debug join order / build-probe; DISTRIBUTED = physical plan with RemoteExchange types (REPARTITION/REPLICATE), predicate pushdown position, fragment topology; LOGICAL cheaper + CBO focus, DISTRIBUTED for execution topology; neither executes the query (ANALYZE does).

### What worked
- **TA**: All technical claims accurate — LOGICAL/DISTRIBUTED distinction, rows:? as missing-stats signal, RemoteExchange REPARTITION vs REPLICATE, neither-executes vs EXPLAIN ANALYZE.
- **PA**: Use-case split is the actionable takeaway — LOGICAL for join order debugging (cheaper, CBO focus), DISTRIBUTED for execution topology (shuffle cost, pushdown verification). Engineer knows which to run for which symptom.
- **Comp**: Hits both modes plus the critical ANALYZE distinction (executes vs plans-only).

### Remaining gaps
- **BC (−1.25)**: CBO, build-probe, RemoteExchange, predicate pushdown, fragment topology used without inline gloss. For a beginner: CBO = picks plan from row count estimates; build-probe = inner side built into hash table, outer side probes it; RemoteExchange = data shuffle between worker nodes; predicate pushdown = filter pushed to storage layer; fragment = unit of work assigned to a stage.
- **Comp (−0.5)**: Could mention sibling modes TYPE IO (data locations to be read — useful for pushdown verification) and TYPE VALIDATE (parse-only check). Not critical but rounds out the EXPLAIN-family picture.

---

## Pattern observations across iter 384

1. **iter383 recovery confirmed**: Q1 4.50 vs iter383 3.875 — evolution-safety framing now lead, Apicurio production-fit named. Teacher's iter383 actions on schema registry topic landed.
2. **BC drag persists across both Qs**: Q1 4.0, Q2 3.75 — jargon cascade unmitigated. The −0.5 to −1.25 BC penalty has been the consistent dimension-floor for 6+ iterations. Inline-gloss one-liners for stack-specific vocab (WAL, Apicurio, CBO, RemoteExchange, build-probe, fragment) would lift BC by ~0.5 across the board.
3. **PA strong both Qs**: 4.75 + 4.5 — pragmatic guidance present (specific tool names, concrete thresholds, use-case split). Pattern continues from iter378-383.
4. **TA both Qs ≥4.75**: factual precision strong — no critical factual errors.
5. **Comp both Qs 4.5**: covers core, misses minor adjacent topics (Iceberg ALTER coupling for Q1, TYPE IO/VALIDATE for Q2).

## Teacher action priorities for iter 385

1. **HIGH BC** — inline-gloss one-liners for high-frequency stack vocab. Persistent BC drag is the single biggest score lever now.
2. **LOW Comp Q1 schema registry** — schemaId → Iceberg ALTER TABLE ADD COLUMN flow diagram.
3. **LOW Comp Q2 EXPLAIN family** — TYPE IO (locations read, pushdown verification), TYPE VALIDATE (parse-only).

## Judge probe targets for iter 385

1. Schema registry 4th angle — "consumer broke after producer added enum value, registry would have prevented?" (tests forward/backward compatibility specifics).
2. EXPLAIN 2nd angle — "EXPLAIN ANALYZE shows 50× row estimate vs actual on inner side, which TYPE would have told me sooner?" (tests stale-stats detection via LOGICAL rows:? signal).
3. Carry-forward: Trino result caching (iter381), Iceberg branches concurrent fast_forward (iter381), bucket sizing 32/128/256 (iter382), partition spec migration without downtime (iter382), JWT+OPA concurrency (iter382).
