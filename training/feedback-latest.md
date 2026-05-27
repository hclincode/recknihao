# Judge Feedback — Iter 329

Date: 2026-05-27
Phase: extended
Topics: Multi-tenant analytics / OPA bundle management (Q1) + Postgres-to-Iceberg ingestion / CDC source_lsn + MERGE INTO exactly-once dedup (Q2)

---

## Q1 — OPA bundle management

### Score
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | All key claims verified against official OPA docs: (1) `data.json`/`data.yaml` required (other filenames silently ignored). (2) Directory path becomes Rego data namespace — `bundle/tenants/data.json` → `data.tenants`. (3) OPA polls via `min_delay_seconds`/`max_delay_seconds`. (4) No Trino-side decision cache — next query sees updated bundle immediately. No fabricated config properties. |
| Beginner clarity | 4.5 | Clear jargon definitions, concrete directory layout + Rego reference chain, verification curl command. Missed: no gloss on what "Rego" is for true beginners. |
| Practical applicability | 4.5 | curl diagnostic step, concrete file layout, honest scope disclaimer on config format. Missing: no OPA config YAML skeleton, no .tar.gz packaging note. |
| Completeness | 4.5 | Covers what a bundle is, naming requirement, serving concepts, propagation timing. Missing: .tar.gz packaging, .manifest file, environment-specific hosting (MinIO). |
| **Average** | **4.625** | **PASS** |

### What Worked
- **Critical naming rule as the lede**: "must be `data.json` or `data.yaml`; other filenames silently ignored" — exactly OPA's documented behavior and highest-leverage fix.
- **Directory-as-namespace shown end-to-end**: `bundle/tenants/data.json` → `data.tenants` with both the file layout AND the Rego reference — engineer can verify end-to-end.
- **Verification step is excellent**: `curl http://opa:8181/v1/data/tenants` to confirm data actually loaded after bundle push.
- **No fabricated config properties**: cleanly avoided the historical failure mode for this topic (iter316 fabricated `opa.policy.cache-ttl-seconds`; iter322 fabricated log strings).
- **Honest scope disclaimer**: explicitly deferred to OPA docs for full config format rather than inventing properties.

### What Missed
- No mention of bundle compression: OPA bundles are `.tar.gz` archives — an engineer building this for the first time doesn't know to `tar -czf bundle.tar.gz bundle/`.
- No `.manifest` mention: production bundles conventionally include a root-level `.manifest` for roots and revision metadata.
- No environment-specific hosting: "S3 or HTTP endpoint" is vague; for this on-prem MinIO + k8s stack, the answer is "host `.tar.gz` on MinIO via S3 protocol or serve from an nginx pod."
- No OPA config YAML skeleton: even a minimal `services:` + `bundles:` stub would have made the answer fully actionable without risk of fabrication.

### Technical Accuracy (verified)
1. `data.json`/`data.yaml` required — CORRECT (OPA docs: "OPA will only load data files named `data.json` or `data.yaml`. Other JSON and YAML files will be ignored.")
2. Directory path → Rego namespace — CORRECT (confirmed `bundle/tenants/data.json` → `data.tenants`)
3. OPA bundle polling — CORRECT (`min_delay_seconds`/`max_delay_seconds` configurable)
4. No Trino-side decision cache — CORRECT (verified against trino.io OPA access control docs)

### Rubric Update
- Multi-tenant analytics: prior avg 4.477 across 124 questions → (4.477 × 124 + 4.625) / 125 = 559.773 / 125 = **4.478 across 125 questions**. Status: **PASSED** (stable).

---

## Q2 — CDC source_lsn + MERGE INTO exactly-once deduplication

### Score
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.75 | All five major claims verified: Debezium captures `source.lsn`; LSN is strictly monotonic 64-bit int; `s.source_lsn > t.source_lsn` guard is canonical idempotency pattern; LSN is per-source; Spark window dedup before MERGE is required practice. Minor gap: snapshot rows have null LSN (not mentioned). |
| Beginner clarity | 4.75 | Concrete numeric LSN example (500 > 501 = FALSE) makes the guard intuitively clear. Step-by-step failure scenario (pod dies → Kafka replays) is exactly the real root cause. |
| Practical applicability | 5.0 | Copy-pasteable PySpark extraction, MERGE SQL, CREATE TABLE schema, and window dedup — all production-ready for the on-prem Spark + Iceberg 1.5.2 stack. |
| Completeness | 4.75 | Covers all four expected sub-topics: why dupes happen, what LSN is, MERGE pattern with guard, per-source caveat. Minor gap: null LSN for snapshot rows not surfaced. |
| **Average** | **4.8125** | **PASS** |

### What Worked
- **Root cause framing**: opens with the exact failure scenario (pod dies before offset commit → Kafka replays → duplicate rows) — engineer immediately recognizes their situation.
- **Numeric LSN walkthrough**: `500 > 501 = FALSE` makes the idempotency guard click for a beginner — best pedagogical move in the answer.
- **MERGE SQL is the canonical pattern**: DELETE branch before LSN-guarded UPDATE branch is correct ordering.
- **Pre-MERGE Spark window dedup included**: handles intra-batch duplicates before they hit MERGE.
- **Per-source caveat is explicit**: LSN spaces independent across Postgres instances, composite key `(id, source_region)` required — the most common multi-source pitfall.
- **Recovery angle**: persisted `source_lsn` lets you query Iceberg to find last applied position for resumption.

### What Missed
- Snapshot rows (`op='r'`) have null `source_lsn` — `500 > NULL` evaluates as NULL (treated as FALSE in SQL), which is actually safe, but not explained. Engineers who see null LSNs during initial snapshot will be confused.
- Pre-MERGE window dedup framed as optional ("the resource also recommends") when it's actually required for full idempotency per apache/iceberg #11248.
- `debezium_schema` used in PySpark snippet but not defined — copy-paste would fail without StructType definition.
- `UPDATE SET *`/`INSERT *` precondition (column-name alignment) not stated.

### Technical Accuracy (verified)
1. Debezium captures `source.lsn` in CDC envelope — CORRECT
2. LSN is strictly monotonic 64-bit integer — CORRECT (`pg_lsn` type docs)
3. `s.source_lsn > t.source_lsn` guard is canonical idempotency pattern — CORRECT (Tabular cookbook, RisingWave lessons)
4. LSN is per-source / not comparable across Postgres instances — CORRECT
5. Spark window dedup before MERGE is recommended (required) practice — CORRECT (per apache/iceberg #11248)

### Rubric Update
- Postgres-to-Iceberg ingestion: prior avg 4.493 across 116 questions → (4.493 × 116 + 4.8125) / 117 = 526.0005 / 117 = **4.496 across 117 questions**. Status: **PASSED** (mild upward drift).

---

## Iter 329 Summary

**Iter 329 average: (4.625 + 4.8125) / 2 = 4.719 — PASS** ✓ (Q1 PASS / Q2 PASS)

### Notable
- Q1 4.625: OPA bundle management — correctly named `data.json` naming rule as the critical fact, no fabricated config properties (clean run on a topic with prior fabrication history).
- Q2 4.8125: CDC source_lsn + MERGE INTO — comprehensive answer with concrete numeric walkthrough and all five technical claims verified. Pre-MERGE dedup included but framed as optional rather than required.

### Resource fixes applied this iteration
None needed.

### Suggested focus for Iter 330
- **Multi-tenant analytics** (4.478/125): consider probing HMS/Hive Metastore tuning for multi-tenant scenarios — connection pooling, partition cache invalidation TTL, or the impact of tenant-specific schemas on HMS performance.
- **Iceberg table maintenance** (4.574/25, not probed this iter): probe `$snapshots` metadata table diagnostics — how to interpret snapshot history and identify which snapshots can be expired safely, or probe `expire_snapshots` arguments and the 7-day floor.
- **Postgres-to-Iceberg ingestion** (4.496/117, recovering): consider probing `offset.flush.interval.ms` at-least-once delivery gap and how to absorb it — the window between Kafka Connect offset commits and the risk it creates.
