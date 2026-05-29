# Judge Feedback — Iter 386 (EXTENDED PHASE)

## Iter 386 overall: 4.4375 — PASS (>=4.0 bar)

THREE consecutive iterations at exactly 4.4375 (iter384, iter385, iter386). The score is structurally pinned by BC = 3.75 across all six Q-scores in those three iterations while TA = 4.75 and PA = 4.75 remain ceiling-strong and Comp = 4.5 is stable. STRONG PASS (>=4.6) is blocked by a single unresolved lever: **inline-gloss vocabulary work**.

---

## Q1 — Iceberg Z-order/sort for multi-column filtering: 4.4375 PASS

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.75 | Min/max-stats file skipping correct; rewrite_data_files strategy=sort correct (Spark Actions API + Trino procedure both available in production stack); zorder() correct for high-cardinality; sorted_by table property correct at CREATE TABLE. |
| Beginner clarity | 3.75 | "min/max statistics", "Z-order", "high-cardinality", "sorted_by", "rewrite_data_files strategy=sort" used without inline gloss. Persistent BC cap. |
| Practical applicability | 4.75 | Concrete sort_order column list (tenant_id ASC, event_type ASC); concrete zorder column list (tenant_id, user_id); engineer knows the exact DDL + procedure call. |
| Completeness | 4.5 | Covers sort, Z-order, sorted_by, sort vs partition tradeoff. Missing: rewrite_manifests follow-up + write.distribution-mode=range pre-shuffle. |

---

## Q2 — Trino query history and auditing: 4.4375 PASS

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.75 | system.runtime.queries non-persistence correct; etc/http-event-listener.properties file path correct for Trino 467; payload field names match QueryCompletedEvent schema; OPA-as-tenant-isolation fits production stack. |
| Beginner clarity | 3.75 | "event listener", "JSON payload", "collector pattern", "OPA" used without inline gloss. Same persistent BC cap. |
| Practical applicability | 4.75 | Concrete file path + property names + three collector patterns. Iceberg-audit-table pattern especially production-fit since lakehouse already deployed. Engineer can act today. |
| Completeness | 4.5 | Covers non-persistence problem, listener mechanism, payload schema, sinks, access control. Missing: kafka-event-listener alternative, buffering/retry, QueryCreatedEvent vs QueryCompletedEvent split. |

---

## Pattern across iter384-386 (THREE consecutive at 4.4375)

- TA 4.75 + PA 4.75 ceiling-stable both Qs all three iters
- Comp 4.5 stable
- **BC 3.75 is the dominant score cap** — 6/6 Q-scores across three iterations
- Resource base is technically and practically sound; the only systemic gap is jargon-density without inline gloss

---

## Teacher actions next (iter387) — HIGHEST PRIORITY: inline-gloss cascade

### HIGH — BC inline-gloss for Iceberg sort vocab
- "min/max statistics" -> per-file metadata recording smallest+largest value of each column, used to skip files not matching WHERE
- "Z-order" -> interleaved bit ordering across N columns so adjacent values cluster on disk for any subset of those columns
- "high-cardinality" -> >1M distinct values; Z-order more useful than partition at this scale
- "sorted_by" -> CREATE TABLE WITH(sorted_by=ARRAY['col']) declares default sort for new writes
- "rewrite_data_files strategy=sort" -> Spark Actions or Trino procedure that physically re-clusters existing files on the sort columns

### HIGH — BC inline-gloss for Trino event listener vocab
- "event listener" -> Trino plugin invoked at query lifecycle events posting structured records to an external sink
- "http-event-listener.properties" -> etc/ file declaring event-listener.name=http + ingest-uri target URL
- "event payload" -> JSON record with context.user / metadata.query / ioMetadata.inputs+outputs / cpuTime fields
- "collector pattern" -> downstream service (Loki, ELK, Kafka, Iceberg audit table) that receives and persists event records

### MED — Comp Q1
- rewrite_manifests follow-up after rewrite_data_files (compact manifest list)
- write.distribution-mode=range pre-shuffles writes so new files arrive already sorted

### MED — Comp Q2
- kafka-event-listener as alternative to http (better backpressure handling)
- event listener buffering + retry semantics
- QueryCreatedEvent vs QueryCompletedEvent split

---

## Judge probe targets (iter387)

1. **Z-order 2nd angle**: "query still slow after sort, EXPLAIN shows all files scanned" — tests sort-column vs WHERE-predicate column mismatch, manifest stats freshness, write.distribution-mode
2. **Audit log 2nd angle**: "event listener dropping events under load, how to size + monitor" — tests buffering, queue depth metric, DLQ pattern, kafka-event-listener escape hatch
3. **Carry-forward**: MERGE INTO rollback, Trino timeout OPA-override, schema registry 4th angle, EXPLAIN TYPE IO + VALIDATE, result caching, Iceberg branches concurrent fast_forward, bucket sizing 32/128/256, JWT+OPA concurrency, partition spec migration without downtime
