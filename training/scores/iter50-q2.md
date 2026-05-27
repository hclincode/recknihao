# Iteration 50, Q2 — Score

**Question**: Spark Structured Streaming job died over a long weekend; Postgres ran out of disk because Debezium's replication slot was not being consumed and WAL accumulated. What happened, and how do we prevent it?

**Topic**: Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling

---

## Technical verification (via WebSearch against postgresql.org and debezium.io)

1. **`pg_replication_slots` monitoring query** — VERIFIED CORRECT.
   - Per postgresql.org/docs/current/view-pg-replication-slots, `restart_lsn` is the LSN below which the slot's consumer no longer requires WAL — Postgres must retain everything from `restart_lsn` forward.
   - `pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)` is the canonical formula for "bytes of WAL retained on behalf of this slot."
   - `pg_size_pretty(...)` is the correct human-readable wrapper. `active` column is a useful addition.

2. **`max_slot_wal_keep_size` is the Postgres 13+ safety valve** — VERIFIED CORRECT.
   - Introduced in Postgres 13 per the release notes (postgresql.org/docs/13/release-13.html).
   - Per current docs, when a slot's required WAL would exceed `max_slot_wal_keep_size`, the slot is **marked invalid** (not literally dropped). The functional consequence is the same — the slot becomes unusable for the consumer, who must resync — but the answer's "drops the slot" wording is slightly imprecise relative to the docs ("marked invalid"). Minor technical nit, does not change behavior.
   - Default value is `-1` (unlimited) on a fresh install, which is exactly what bit the engineer.

3. **Slot dropped/invalidated → full Debezium snapshot resync** — VERIFIED CORRECT.
   - Per debezium.io PostgreSQL connector docs: when the connector first connects (or reconnects without a usable LSN position) it performs a consistent snapshot of the schemas, then streams forward from the snapshot point. The answer correctly identifies this as the recovery path.
   - The answer's recommendation to use `MERGE INTO` for idempotency on Iceberg during the resync is correct — without it, snapshot re-inserts would double existing rows.

4. **Production-stack fit (prod_info.md)**:
   - Correctly recommends k8s Deployment with `restartPolicy: Always` (matches the on-prem k8s stack).
   - Correctly names Spark Structured Streaming, Kafka consumer-lag monitoring, and Iceberg `MERGE INTO` — all consistent with prod_info.md.
   - The closing "consider batch instead" framing is appropriate and resource-grounded, not a tangent.

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| **Technical accuracy** | 5 | Every load-bearing technical claim is verified against postgresql.org and debezium.io. The monitoring SQL is correct and runnable. The `max_slot_wal_keep_size` Postgres-13+ attribution is correct. The default-unlimited behavior is correctly named as the latent footgun. The recovery path (resync via Debezium snapshot + MERGE INTO for idempotency) is correct. Only nit: "drops the slot" should technically be "marks the slot invalid" per the docs — functionally equivalent for the consumer but imprecise. Does not warrant a deduction at this level. |
| **Beginner clarity** | 4 | Strong opening "plain English" section explains the slot-as-bookmark mental model before any SQL appears. Numbered 5-step weekend timeline is excellent pedagogy — a junior engineer can follow exactly what went wrong without prior CDC knowledge. Beginner-clarity weakness: "WAL", "LSN", "restart_lsn", "replication slot" (in the technical sense), "Kafka consumer group lag", "Debezium connector management API", "snapshot mode" all appear without inline one-line glosses. The first paragraph defines slot conceptually but doesn't define WAL ("write-ahead log — Postgres's append-only change journal") explicitly. A reader who doesn't know what WAL stands for will have to infer. |
| **Practical applicability** | 5 | Engineer leaves with: (a) runnable Postgres monitoring SQL with concrete 10 GB alert threshold suggestion; (b) runnable `ALTER SYSTEM SET max_slot_wal_keep_size = '20GB'` plus `pg_reload_conf()`; (c) k8s Deployment spec snippet with the right restart policy; (d) Kafka consumer-lag SLA framing (30 min for a 5-min job); (e) 4-step recovery runbook if the slot is invalidated; (f) the meta-decision: CDC vs batch, with stated criteria. This is a complete Monday-morning playbook — nothing left to figure out. |
| **Completeness** | 5 | Covers all six items the expected-answer outline named: (1) slot retains WAL since `restart_lsn` when consumer stops — yes, plain-English; (2) the specific monitoring query — yes, with `active` flag added; (3) `max_slot_wal_keep_size` as the Postgres-13+ safety valve — yes, with concrete value; (4) auto-restart for the Spark job (k8s Deployment vs manual spark-submit) — yes, with YAML snippet; (5) alert on Kafka consumer-group lag — yes, with SLA framing; (6) recovery path = snapshot resync + MERGE INTO idempotency — yes, with 4 steps. Bonus content (the CDC-vs-batch reframe at the end) is on-resource and not a tangent. |

**Average**: (5 + 4 + 5 + 5) / 4 = **4.75**

---

## Rubric update

Topic: Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling
- Prior: avg 4.267 across 51 questions (per state.json notes from iter49)
- New: (4.267 × 51 + 4.75) / 52 ≈ **4.276** across 52 questions
- Status: PASSED (≥ 3.5 threshold maintained)

---

## Notes for teacher

This answer represents one of the strongest CDC-operational answers in the run — the responder correctly diagnosed the failure, gave runnable mitigation SQL, hit the Postgres 13 version-gated safety valve, and reframed the bigger CDC-vs-batch decision without going off-resource. Indicates that `resources/13-postgres-to-iceberg-ingestion.md` (or a sibling resource) now has solid coverage of CDC operational gotchas.

Two small refinement opportunities:

1. **Beginner gloss pass on the CDC operational vocabulary.** First-use glosses are missing for WAL ("write-ahead log — Postgres's append-only change journal that durably records every modification before it's applied"), LSN ("log sequence number — a monotonic position pointer into the WAL"), `restart_lsn` ("the oldest WAL position the slot's consumer still requires"), and Kafka consumer-group lag ("how many messages a consumer is behind the latest message on a topic, per partition"). Adding these inline (one sentence each at first use) would push the beginner-clarity score from 4 to 5 without bloating the answer.

2. **Precision on `max_slot_wal_keep_size` behavior.** Per postgresql.org, the slot is **marked invalid**, not literally dropped. The functional outcome (consumer must resync) is identical, but a reader who runs `SELECT * FROM pg_replication_slots` after the safety valve fires will see the slot still listed with a non-NULL `invalidation_reason` (Postgres 16+) or `wal_status = 'lost'` — not a missing row. Resource should note this so engineers know what to look for in `pg_replication_slots` post-incident.

No critical gaps — the answer hits all six items the expected-answer outline named and adds two pieces of value the outline didn't even ask for (the k8s Deployment YAML and the CDC-vs-batch reframe at the close).
