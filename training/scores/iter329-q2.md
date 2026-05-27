# Iter 329 Q2 — Score

**Topic**: Postgres-to-Iceberg ingestion — CDC deduplication via `source_lsn` + `MERGE INTO`
**Question**: How `source_lsn` and `MERGE INTO` connect to prevent duplicate CDC rows in Iceberg
**Prior topic running avg**: 4.493 / 116 questions

---

## Score table

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | 4.75 | All major claims verified against official Debezium / Postgres / Iceberg docs; one minor caveat omitted (snapshot rows have null LSN) |
| Beginner clarity | 4.75 | Walks through duplicate scenario step-by-step with concrete LSN numbers; jargon defined inline |
| Practical applicability | 5.0 | Copy-pasteable PySpark, MERGE SQL, CREATE TABLE, and dedup window — production-ready |
| Completeness | 4.75 | Covers all four expected sub-topics (why dupes, what LSN is, MERGE pattern, per-source caveat); minor gap on snapshot/`r` op LSN being null |
| **Average** | **4.8125** | **PASS** |

---

## What worked

1. **Tight problem framing**: Opens with the exact failure scenario (pod dies before offset commit → Kafka replays → duplicate Iceberg rows). This is the real root cause and an engineer reading this will immediately recognize their situation.
2. **Walks the LSN through a concrete numeric example**: The `LSN=500` redelivered after `LSN=501` example with the explicit `500 > 501 = FALSE` evaluation makes the idempotency guard click instantly. This is exactly the right pedagogical move for a beginner.
3. **MERGE SQL is the canonical pattern**: `WHEN MATCHED AND s.op = 'd' THEN DELETE` + `WHEN MATCHED AND s.source_lsn > t.source_lsn THEN UPDATE SET *` + `WHEN NOT MATCHED AND s.op IN ('c', 'r', 'u') THEN INSERT *` is the standard CDC merge shape and is correctly ordered (DELETE branch before the LSN-guarded UPDATE branch).
4. **Pre-MERGE Spark window dedup is included**: The `Window.partitionBy("id").orderBy(col("source_lsn").desc())` + `row_number == 1` pattern is the recommended practice for handling intra-batch duplicates before they hit MERGE — a subtle but important detail.
5. **Per-source caveat is explicit and correct**: The statement that LSN spaces are independent across Postgres instances and that the composite key `(id, source_region)` must isolate the comparison is technically correct and is the most common multi-source CDC pitfall.
6. **Recovery angle**: Notes that persisting `source_lsn` also lets you query Iceberg for the last applied position to know where to resume from — practical operational value beyond just dedup.
7. **CREATE TABLE schema is shown**: The engineer can see exactly which columns to add.

---

## What missed (technical gaps)

1. **Snapshot rows have null LSN** (minor): During Debezium's initial snapshot (`op = 'r'`), the `source.lsn` field is null because no streaming offset has been established yet. The answer's `WHEN MATCHED AND s.source_lsn > t.source_lsn` guard would evaluate as NULL (treated as FALSE in SQL), which is actually safe — snapshot rows hitting an already-streamed row will be skipped. But this is not explained, and a reader extracting only "new rows always win" might be confused when their initial snapshot doesn't update existing target rows. Resources/13 line 2087 shows the bootstrap convention (`source_lsn = lit(None).cast("long")`), but the answer doesn't surface this.
2. **MERGE non-idempotency caveat absent**: Per the apache/iceberg GitHub issue surfaced in WebSearch, MERGE INTO in Spark+Iceberg has known runtime-operation-type quirks (operation decided at runtime based on actual join results), which can still produce duplicate inserts under certain race conditions. The answer presents MERGE as fully sufficient; in practice the pre-MERGE window dedup is *required*, not optional. The answer says "the resource also recommends" — softer than the engineer needs.
3. **Schema for `from_json` is referenced but not provided**: `debezium_schema` is used but not defined. A literal copy-paste would fail without this; a one-line note ("define `debezium_schema` as a StructType matching the Debezium envelope") would close the gap.
4. **`UPDATE SET *` requires column alignment**: The answer uses `UPDATE SET *` and `INSERT *`, which work but require the source view to have exactly the same column names as the target. A beginner pasting this could hit obscure column-mismatch errors. Not a wrong recommendation, just an unstated precondition.

None of these are critical errors — the core pattern is correct, the SQL is runnable, and the conceptual model is right.

---

## Technical accuracy verification

Five claims checked against official sources:

| Claim | Verified? | Source |
|---|---|---|
| (a) Debezium captures WAL position into `source.lsn` in CDC event envelope | YES | Debezium PostgreSQL connector docs; example envelope shows `source=Struct{...lsn=1073751968}` |
| (b) LSN is a strictly monotonically increasing 64-bit integer | YES | Postgres docs `pg_lsn` type: "Internally, an LSN is a 64-bit integer... increasing monotonically with each new record"; supports `>` comparator |
| (c) MERGE INTO with `s.source_lsn > t.source_lsn` guard is the correct idempotency approach | YES | Standard CDC pattern documented across Tabular cookbook, RisingWave Postgres→Iceberg lessons, datalakehousehub idempotent pipelines guide; matches resources/13 line 3045 |
| (d) LSN is per-source / not comparable across Postgres instances | YES | Each replication slot has its own WAL position space; cross-instance LSN comparison is meaningless |
| (e) Spark window function dedup before MERGE is recommended practice | YES | Resources/13 line 2697 shows `Window.partitionBy(...).orderBy(col("source_lsn").desc())`; required because Iceberg MERGE's runtime operation-type resolution can be non-idempotent (per apache/iceberg #11248) |

All five verified correct. No fabricated APIs, functions, or behaviors.

---

## Production-environment fit

Production stack is on-prem Spark + Iceberg 1.5.2 + Trino 467 with MinIO. The answer uses Spark Structured Streaming with Kafka source and Iceberg MERGE — all directly compatible. No cloud-only services recommended. Debezium + Kafka Connect is acknowledged in resources/13 as the prod CDC path running on k8s on-prem. Fit: appropriate.

---

## Topic score update

- Prior: 4.493 / 116 questions
- This answer: 4.8125
- New running avg: (4.493 × 116 + 4.8125) / 117 = **4.496 / 117 questions** — **PASSED** (above 3.5 threshold, mild upward drift)
