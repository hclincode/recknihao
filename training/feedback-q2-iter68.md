# Feedback — Iter 68 Q2

**Question topic**: Iceberg partition design for SaaS — bucket transform for tenant_id at 2K+ tenants (why direct tenant partitioning breaks, what bucket does differently, how to choose N).

**Final score**: 4.0 / 5

| Dimension | Score | Rationale |
|---|---|---|
| Completeness | 5.0 | All five expected coverage points hit cleanly: metadata explosion, small-files from heterogeneous tenants, hash-mod-N mechanics with worked example, trade-off of losing strict per-tenant isolation, file-size-based N selection plus tiered rules of thumb, hybrid bucket+day spec. Bonus migration walkthrough included. |
| Accuracy | 3.0 | Conceptually correct (hashing, mod N, manifest growth, snapshot semantics, partition spec change being metadata-only). Two factual errors in code samples — see below. |
| Clarity | 5.0 | Strong narrative arc. Concrete `hash('acme') mod 128 -> bucket 42` example. Tables and math make the trade-offs visual. Zero assumed knowledge. |
| No hallucination | 3.0 | The bucket-argument-order error is a Spark-syntax leak into a Trino-targeted answer. The `rewrite_data_files` sort call is incomplete. Other claims are grounded in the resources. |

---

## What worked

- Opens with a clear "your teammate is right" framing that respects the engineer's existing direction rather than relitigating the question.
- Three concrete failure modes for direct tenant_id partitioning, each with numbers (200 vs 2,000 tenants × 365 days). The 80/20 small-tenant framing is exactly the SaaS reality.
- The `hash('acme') mod 128 -> bucket 42` worked example makes "hash transform" tangible without invoking cryptographic vocabulary.
- The trade-off section is honest and proportionate — it acknowledges loss of strict per-tenant file isolation without scaremongering.
- The "how to pick N" section combines first-principles math (events/day × bytes/event ÷ N → bucket-day size) with tiered rules of thumb (32 / 128 / 256). A SaaS engineer can act on this without further research.
- The summary table at the end is genuinely useful — engineer can paste it into a design doc.

## Factual issues

### 1. Bucket transform argument order is wrong for Trino (the production stack)

The answer uses `bucket(N, column)` throughout — both in prose ("`bucket(128, tenant_id)` does X") and in DDL (`partitioning = ARRAY['bucket(128, tenant_id)', 'day(event_ts)']`). This is the **Apache Spark / Iceberg-core DDL order**.

**Production stack is Trino 467 with the Iceberg connector**, which uses `bucket(column, N)` — column first. Verified against:
- https://trino.io/docs/current/connector/iceberg.html (example: `'bucket(account_number, 10)'`)
- resources/10-lakehouse-partitioning.md, which consistently uses `bucket(tenant_id, 64)`, `bucket(user_id, 100)`, `bucket(user_id, 10000)`.

A SaaS engineer copy-pasting the answer's CREATE TABLE into a Trino notebook would hit a parse / type-mismatch error and lose 30+ minutes debugging before realizing the order is wrong. This is the same Spark-DDL-vs-Trino-DDL bleed flagged in Iter 43 Q2.

**Locations to fix in the answer**: lines 33, 38, 43, 82, 101, the summary table heading, the migration section heading.

### 2. `rewrite_data_files(strategy => 'sort')` without `sort_order` is misconfigured

The migration example calls:
```sql
CALL iceberg.system.rewrite_data_files(
  table    => 'analytics.events',
  strategy => 'sort',
  options  => map('target-file-size-bytes', '268435456')
);
```

Per the Iceberg Spark procedures docs and the open issue apache/iceberg#10346, `strategy => 'sort'` without an explicit `sort_order` argument does not respect the table's default sort order — it either errors or silently degrades. For a partition-spec migration (the goal here is repartitioning, not sort layout), `strategy => 'binpack'` is the correct default. If sort is genuinely wanted, the call should include `sort_order => 'tenant_id, event_ts'`.

## Action items for the teacher (resources/)

1. **resources/10-lakehouse-partitioning.md** — add a prominent Spark-vs-Trino bucket-argument-order callout near the top, side-by-side:
   - Trino DDL: `bucket(tenant_id, 128)`
   - Spark DDL: `bucket(128, tenant_id)`
   The resource currently uses the correct Trino form throughout but never explicitly warns about the Spark variant, so the weak responder's pretraining leaks the wrong form into answers. An explicit "if you see `bucket(N, col)` in a Spark tutorial, the Trino equivalent flips the arguments" note would prevent this regression.

2. **resources/10-lakehouse-partitioning.md** maintenance section — add a one-liner: `strategy => 'sort'` requires an explicit `sort_order` parameter; for partition-spec migrations use `strategy => 'binpack'`.

## Rubric impact

- Topic: **Iceberg partition design for SaaS: strategies, small-files, compaction**
- Prior: 4.500 avg over 6 questions, PASSED
- New: (4.500 × 6 + 4.0) / 7 = **4.429** across 7 questions, still PASSED
- Topic remains comfortably above the 3.5 pass threshold but slipped from 4.500 — the Spark-vs-Trino DDL pattern is the only recurring weakness on this topic.
