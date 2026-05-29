# Judge Feedback — Iter 387 (EXTENDED PHASE)

## Iter 387 overall: 4.25 — PASS (>=4.0 bar)

Q1 4.25 PASS (Iceberg catalogs: HMS vs Nessie vs Polaris) + Q2 4.25 PASS (Trino spill disk sizing). Mid-tier PASS — both Qs land identically at 4.25 average. This is a notable score drop from the iter384–386 plateau (4.4375 x3) because BOTH Qs lost a quarter point on TA (4.5 vs 4.75) and a quarter point on Completeness (4.25 vs 4.5). BC unchanged at 3.75 — still the dominant cap. PA holds at 4.5.

---

## Q1 — Iceberg catalog: HMS vs Nessie vs Polaris: 4.25 PASS

Responder gave: HMS = pointer lookup + SPOF on writes; switch trigger = HMS outages expensive or new deployment; Nessie = REST catalog + Git-style branching; Polaris = REST catalog, simpler; honest "stay on HMS if stable"; migration = URI change + table re-registration.

| Dimension | Score | Why |
|---|---|---|
| Technical accuracy | 4.5 | HMS pointer/SPOF correct; Nessie Git-style branching correct; Polaris simpler-REST correct; "stay if stable" pragmatic; migration framed as URI + re-registration correct. Minor TA gap: HMS write SPOF is more nuanced — HMS supports HA via multiple metastore replicas behind a load balancer; the SPOF is the backing DB (MySQL/Postgres), not HMS itself. Calling HMS "SPOF on writes" is loose without that qualifier. |
| Beginner clarity | 3.75 | "pointer lookup", "SPOF", "REST catalog", "Git-style branching", "URI change", "table re-registration" all dropped without inline gloss. Engineer with no Iceberg-catalog background can't tell what "pointer lookup" means (HMS stores current-snapshot-pointer to metadata.json) or what "REST catalog" buys you (HTTP API contract decoupling table state from a Hive thrift connection). |
| Practical applicability | 4.5 | Clear switch criteria (HMS outages cost real money OR fresh deployment); migration path actionable (URI + re-register); "stay if stable" honest. Engineer leaves with a decision rule. Minor PA gap: no mention of how to run the migration safely (dual-catalog parallel registration, validation read on new catalog before cutover) and no mention that Nessie/Polaris on-prem k8s deployment is non-trivial (Nessie needs JGit-style versioning backend; Polaris is Apache incubating with relatively young on-prem story). |
| Completeness | 4.25 | Three catalogs covered + switch trigger + migration mentioned. Gaps: (a) production-stack fit — prod is HMS today, so a "stay on HMS unless multi-branch CDC + cross-team isolation forces Nessie" framing would close the loop; (b) REST catalog spec significance (Iceberg REST Catalog API as the standard interface both Nessie and Polaris implement, which decouples engine from catalog); (c) HMS lock semantics (Iceberg uses HMS lock table for commit serialization — this is the actual write contention point, not "SPOF"); (d) no mention of catalog migration tooling (register_table procedure, snapshot-id preservation). |

**Q1 average: (4.5 + 3.75 + 4.5 + 4.25) / 4 = 4.25 — PASS**

---

## Q2 — Trino spill disk sizing: 4.25 PASS

Responder gave: max-spill-per-node = 200GB aggregate cap; query-max-spill-per-node = 50GB per-query cap; total ~350–400GB SSD per worker; disk-full → query OOMs anyway (spill delays not prevents OOM); LZ4 compression; spill is last resort after query restructuring.

| Dimension | Score | Why |
|---|---|---|
| Technical accuracy | 4.5 | Property names correct (`spiller-max-used-space-threshold` peer would also be relevant but the two named are accurate); 200GB / 50GB sizing reasonable for typical spill workloads; LZ4 is the default spill codec; "spill delays not prevents OOM" technically correct (spill helps queries that would otherwise OOM, but if spill disk fills, query fails with SPILL_FAILED, not strictly OOM). 350–400GB SSD per worker reasonable for k8s on-prem with hot-tier NVMe. Minor TA gap: spill must be explicitly enabled (spill-enabled=true) — assumed but not stated; the "OOM" framing for disk-full case is slightly loose (actual error is SPILL_FAILED or NO_NODES_AVAILABLE depending on path). |
| Beginner clarity | 3.75 | "spill", "aggregate cap", "per-query cap", "OOM", "LZ4 compression", "spill disk" all dropped without inline gloss. Engineer with no Trino-memory-model background can't tell what "spill" means (writing in-flight join/aggregation state to disk when query exceeds in-memory budget) or why per-query vs aggregate distinction matters (one runaway query vs all queries combined). |
| Practical applicability | 4.5 | Concrete sizing numbers (200GB / 50GB / 350–400GB SSD) — engineer can spec worker pods. "Spill is last resort after restructuring" pragmatically correct (better fix is partitioning/projection trimming/broadcast vs partitioned join). Production-stack-fit: k8s on-prem with local NVMe attached to worker pods is the right deployment shape. Minor PA gap: no mention of k8s emptyDir vs local PVC tradeoff for spill path, no `spiller-spill-path` config, no monitoring metric (spill_bytes per query). |
| Completeness | 4.25 | Sizing + cap relationship + compression + last-resort framing covered. Gaps: (a) spill-enabled flag — assumed but should be explicit; (b) `spiller-spill-path` config (where on disk spill goes; k8s PV mount point matters); (c) k8s/MinIO context — spill goes to LOCAL disk on worker pod, NOT MinIO/S3 (network-attached spill defeats the latency budget); (d) what user sees on disk-full (exact error code SPILL_FAILED, query retry semantics); (e) monitoring path (`spilled_data_size` query stats, alerting threshold). |

**Q2 average: (4.5 + 3.75 + 4.5 + 4.25) / 4 = 4.25 — PASS**

---

## Iter 387 overall: (4.25 + 4.25) / 2 = 4.25 — PASS

**Pattern note**: Score regressed from iter384-386 plateau of 4.4375 down to 4.25. Both TA and Comp slipped 0.25 each. The TA slips come from minor-but-real qualifier gaps: Q1 "SPOF on writes" is loose framing for HMS (the SPOF is the backing DB + HMS lock table contention, not HMS itself); Q2 "OOM anyway on disk full" is loose (actual error is SPILL_FAILED). The Comp slips come from missing production-stack-fit framing: Q1 no "stay on HMS — production stack" anchor, Q2 no k8s/local-PV vs network-attached-spill warning.

**BC drag persists at 3.75 across both Qs — 10+ consecutive iterations now**. Inline-gloss work remains the single biggest score lever.

---

## Teacher actions next (iter388)

1. **HIGH TA Q1** — Tighten HMS SPOF framing in catalog resource. Add: "HMS can be HA via multiple metastore replicas behind LB; the real write contention point is the HMS lock table used for Iceberg commit serialization, plus the backing RDBMS (MySQL/Postgres) which IS a SPOF unless replicated." Strike "SPOF on writes" oversimplification.

2. **HIGH TA Q2** — Tighten spill failure mode framing in spill resource. Add: "spill-enabled=true is required to activate; on disk full the error is SPILL_FAILED (not OOM); SPILL_FAILED query can be retried but spill state is lost." Strike "query OOMs anyway" oversimplification.

3. **HIGH BC Q1 inline-gloss cascade** — Iceberg catalog vocab:
   - "pointer lookup" = HMS returns current metadata.json location for table; engine reads metadata.json to find current snapshot
   - "SPOF" = single point of failure; if the component fails, the whole system stops
   - "REST catalog" = HTTP-based catalog API per Iceberg REST Catalog spec; decouples engine from catalog implementation
   - "Git-style branching" = named table branches like `main`, `staging` that can be created, merged, fast-forwarded
   - "URI change" = catalog connection string (e.g., `iceberg.catalog.uri=thrift://hms:9083` → `https://nessie:19120/api/v2`)
   - "table re-registration" = `register_table` procedure pointing catalog at existing metadata.json without rewriting data

4. **HIGH BC Q2 inline-gloss cascade** — Trino spill vocab:
   - "spill" = writing in-flight join/aggregation state from worker memory to local disk when query exceeds memory budget
   - "aggregate cap" = total spill budget across ALL concurrent queries on a node
   - "per-query cap" = max spill any single query can consume (prevents one query starving others)
   - "LZ4" = fast compression codec (~500MB/s/core) trading ratio for speed; default Trino spill codec
   - "OOM" = out-of-memory; query killed when total memory exceeds cluster budget

5. **MED Comp Q1** — Add production-stack-fit anchor: "Production runs HMS today (per prod_info.md). Stay on HMS unless: (a) you need multi-branch CDC isolation per tenant — Nessie wins; (b) cross-engine REST catalog standardization is a regulatory requirement — Polaris/Nessie win. Otherwise HMS + Iceberg 1.5.2 is production-tested and stable." Add Iceberg REST Catalog spec significance + HMS lock table commit serialization detail + `register_table` procedure name.

6. **MED Comp Q2** — Add production-stack-fit anchor: "k8s on-prem: mount local NVMe via PV/PVC at `spiller-spill-path=/spill`; do NOT spill to network storage (MinIO/NFS) — latency kills the spill speedup. Monitor `spilled_data_size` per query, alert when worker spill volume >80% full." Add SPILL_FAILED error code + spill-enabled flag + monitoring path.

---

## Judge probe targets next (iter388)

1. **Catalog 2nd angle** — "Migrating 5K Iceberg tables from HMS to Nessie without downtime; how to coordinate dual-write or cutover" tests register_table semantics + snapshot-id preservation + dual-catalog parallel registration pattern.

2. **Spill 2nd angle** — "Query keeps failing with SPILL_FAILED at 60GB even though max-spill-per-node=200GB; why" tests per-query cap (50GB) vs aggregate cap (200GB) interaction + how to diagnose via query stats.

3. **Carry-forward**: BC inline-gloss probe — ask responder to "explain this to a junior engineer who has never touched Iceberg" and see if vocabulary gets glossed inline; Z-order 2nd angle (sort vs WHERE predicate mismatch); audit log 2nd angle (event listener dropping events under load); MERGE INTO rollback; Trino timeout OPA-override; schema registry forward/backward compat; EXPLAIN TYPE IO + VALIDATE; result caching; Iceberg branches concurrent fast_forward; bucket sizing 32/128/256; JWT+OPA concurrency.
