# Judge Feedback — Iter 315

Date: 2026-05-27
Phase: extended
Topics: Storage sizing and growth estimation for lakehouse workloads (Q1) + Real-time vs batch analytics trade-offs (Q2)

---

## Q1 — Storage sizing and growth estimation for lakehouse workloads

### Score

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.0 | Math chain is sound and well-labeled as estimates. Postgres index/bloat heuristics (30-50%) and Parquet ratios (5-10x baseline) are within accepted ranges. `pg_total_relation_size` decomposition, `expire_snapshots` guidance, and `$files` query syntax confirmed correct. **MinIO EC:4 claim is wrong as a general statement**: "4 parity drives per 8-drive set, ~50% efficiency, plan 2× raw" only describes an 8-drive set; on 12/16-drive sets EC:4 = ~67-75% usable. Delta encoding for timestamps at "10-20x" is slightly optimistic. |
| Beginner clarity | 5.0 | Explicitly debunks the naive "140 GB / compression" math. Explains indexes, bloat, fragmentation, dictionary/delta/RLE encoding in plain terms with concrete column-type examples. Step-by-step labeled multipliers. Zero assumed OLAP knowledge. |
| Practical applicability | 4.5 | Runnable Postgres diagnostic SQL, Spark JDBC validation snippet, concrete sizing formula, `$files` monitoring SQL, four operational gotchas (snapshot expiry, compaction pairing, monitoring, tiered retention). MinIO over-provisioning advice (2× raw) is wasteful but not dangerous. Single-node MinIO suggestion glosses over HA. |
| Completeness | 5.0 | Hits every part of the question: why Postgres baseline misleads, why Parquet compresses and by how much, growth projection, snapshot overhead, hardware sizing formula, validation procedure, ongoing monitoring, tiered retention bonus. |
| **Average** | **4.625** | **PASS** |

### What Worked
- Two-step decomposition (strip Postgres overhead first, then apply compression) corrects the most common engineering mistake
- Labeled math with named multipliers so the engineer can substitute measured values
- "Measure before you commit" sample-export procedure converts heuristics into verifiable numbers
- `$files` monitoring query is correct Trino+Iceberg syntax and immediately useful
- Snapshot accumulation gotcha (2-3× without expiry) is exactly the failure mode that bites teams in months 3-6

### What Missed
- **MinIO EC:4 misstated** — "plan 2× raw" only applies to 8-drive sets; 12-drive → 1.5×, 16-drive → 1.3× (now fixed in resources/11)
- Single-node MinIO skips HA/failure-domain considerations for on-prem production
- Delta encoding "10-20x" for timestamps is on the high end of realistic

### Technical Accuracy
Verified against: PostgreSQL wiki Disk Usage, Apache Parquet encodings docs, Trino 481 Iceberg connector docs (`$files` syntax confirmed), Iceberg spark-procedures docs, MinIO erasure coding docs and calculator.

### Rubric Update
- Storage sizing: prior avg 4.500 across 5 questions → (4.500 × 5 + 4.625) / 6 = **4.521 across 6 questions**. Status: PASSED.

---

## Q2 — Real-time vs batch analytics trade-offs

### Score

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.75 | WAL/Debezium/Kafka/Spark Structured Streaming chain is correct. Two-timestamp pattern (occurred_at vs ingested_at) is industry standard. Late-arrival watermarking concept is real. **Minor: describes Kafka as requiring "ZooKeeper"** — ZooKeeper was removed in Kafka 4.0 (2025); KRaft has been default since Kafka 3.3. For a 2026 on-prem deployment this is a real inaccuracy (now fixed in resources/14). |
| Beginner clarity | 4.75 | Tiered "freshness spectrum" framing is excellent for a non-OLAP engineer. Wi-Fi/mobile example for late-arriving events is concrete and memorable. Acronyms mostly defined in context. |
| Practical applicability | 5.0 | Directly fits the production stack (on-prem Spark + Iceberg + Trino + k8s). Recommends K8s CronJob. Concrete "three next steps" tell the engineer exactly what to do Monday morning. "Ask the customer first" framing is mature SaaS advice. |
| Completeness | 4.5 | Covers tiered freshness, CDC chain, late-arriving events, two-timestamp pattern, micro-batch-first recommendation. Light on: (a) Iceberg small-files problem from frequent commits — now fixed in resources/14; (b) Trino read-time effects during high-frequency commits; (c) HMS lock contention at sub-minute micro-batch commit frequency. |
| **Average** | **4.75** | **PASS** |

### What Worked
- "Tiers, not binary choices" framing is exactly how a senior engineer thinks about freshness SLAs
- "10× more complex per tier" heuristic gives a memorable cost model
- "'We want real-time' is not a metric" — teaches better requirements gathering
- partition-by-ingested_at / aggregate-by-occurred_at recommendation is the correct Iceberg pattern
- Recommends hourly batch first — verified against sources that 80%+ of workloads are well-served by batch/micro-batch

### What Missed
- **Kafka/ZooKeeper reference outdated** — KRaft is default since Kafka 3.3, ZooKeeper fully removed in Kafka 4.0 (now fixed in resources/14)
- **Small-files problem not named** — frequent Iceberg commits create small files that degrade Trino query performance; `rewrite_data_files` schedule not mentioned (now added to resources/14)
- Hive Metastore lock contention under high commit frequency not mentioned
- Postgres replication slot WAL retention as an operational gotcha for Debezium consumers not mentioned

### Technical Accuracy
Verified against: Debezium Postgres connector docs, Confluent CDC docs, Spark Structured Streaming docs, Databricks watermarking blog, Honeycomb ingest timestamps blog, Kafka 4.0 KRaft release notes.

### Rubric Update
- Real-time vs batch: prior avg 4.775 across 5 questions → (4.775 × 5 + 4.75) / 6 = **4.771 across 6 questions**. Status: PASSED.

---

## Iter 315 Summary

**Iter 315 average: 4.6875 — PASS** ✓

### Notable
- Q1 4.625: Storage sizing answered with correct two-step decomposition; MinIO EC:4 error caught and fixed in resources
- Q2 4.75: Real-time vs batch answered with correct tiered framing; Kafka/ZooKeeper anachronism and small-files gap caught and fixed in resources

### Resource fixes applied this iteration
1. **resources/11-lakehouse-storage-sizing.md** — Added MinIO EC:4 erasure-set-size table (8/12/16 drives → 50%/67%/75% usable) replacing incorrect blanket "2× raw" claim; added Snapshot Management Commands section with full Iceberg 1.5.2 Spark procedure syntax
2. **resources/14-real-time-vs-batch.md** — Updated Kafka reference from ZooKeeper to KRaft (Kafka 3.3+/4.0); added "small-files problem" operational subsection with `rewrite_data_files` schedule recommendation

### Suggested focus for Iter 316
- "Storage sizing and growth estimation" (4.521/6 — just asked, probe a different angle: retention math, partition-level sizing, or time-travel cost)
- "Real-time vs batch" (4.771/6 — probe the Trino read-side effects of high-frequency streaming commits)
- "Postgres-to-Iceberg ingestion" (4.486/107 — consistently lowest, high question count — try a CDC-specific angle: slot WAL bloat, schema evolution mid-migration)
- "Multi-tenant analytics" (4.473/114 — probe OPA decision log debugging, the mixed endpoint config footgun from iter314 feedback)
