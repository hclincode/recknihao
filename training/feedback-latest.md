# Judge Feedback — Iter 398 (EXTENDED PHASE)

**Overall: 4.09375 — PASS**

| Question | Avg | Verdict |
|---|---|---|
| Q1 — Iceberg day vs week vs month partition granularity | 3.875 | PASS |
| Q2 — LAG + day-over-day + 7-day rolling avg in one Trino query | 4.3125 | PASS |

---

## Q1 — Iceberg partition granularity (day vs week vs month) — 3.875 PASS

**Answer summary**: Stay with day(); coarser partitions don't help 90-day queries (pruning evaluates same files); coarser HURTS by reducing per-tenant granularity; real culprit = small-files problem from streaming writes; fix = nightly compaction + tenant_id to partition spec.

| Dimension | Score | Rationale |
|---|---|---|
| Technical accuracy | 4.0 | Stay-with-day conclusion correct; small-files-from-streaming diagnosis is the right root-cause framing. BUT "pruning evaluates same files" is loose reasoning — coarser partitions DO reduce partition directory count (3 months vs 90 days), the real problem is larger per-partition files with broader min/max stats weakening file-level pruning. |
| Beginner clarity | 3.5 | "Per-tenant granularity," "small-files problem," "partition spec" — jargon present, structure digestible but not unpacked. |
| Practical applicability | 4.5 | Clear actions: nightly compaction (`rewrite_data_files`) + add tenant_id to partition spec. Production-fit for on-prem Trino 467 + Iceberg 1.5.2 + Spark streaming. |
| Completeness | 3.5 | Missing: partition spec evolution caveat (existing partitions stay on old spec until `rewrite_data_files` migrates them — `ALTER TABLE ... SET PARTITION SPEC` only affects new writes); `bucket(tenant_id, N)` consideration for very-high-tenant-count; `write.target-file-size-bytes` property for streaming write file-size control; no Trino/Spark `ALTER TABLE ADD PARTITION FIELD` syntax shown. |

---

## Q2 — LAG + day-over-day + 7-day rolling avg in one Trino query — 4.3125 PASS

**Answer summary**: `LAG(revenue, 1) OVER (ORDER BY day)`; `revenue - LAG(...)` for change; `AVG(revenue) OVER (ORDER BY day RANGE BETWEEN INTERVAL '6' DAY PRECEDING AND CURRENT ROW)` for 7-day rolling; add `PARTITION BY tenant_id`; RANGE vs ROWS distinction explained.

| Dimension | Score | Rationale |
|---|---|---|
| Technical accuracy | 4.75 | LAG syntax canonical; AVG OVER RANGE INTERVAL '6' DAY PRECEDING is valid Trino 467 (RANGE frames with INTERVAL offsets work when ORDER BY column is date/timestamp); PARTITION BY tenant_id correct for multi-tenant. All claims verifiable per Trino window functions doc. |
| Beginner clarity | 4.0 | RANGE vs ROWS distinction explicitly explained — strong clarity move addressing a frequent beginner footgun. Still uses "OVER," "PARTITION BY," "frame" without inline gloss. |
| Practical applicability | 4.5 | Engineer can immediately write the query; concrete syntax provided. |
| Completeness | 4.0 | Missing: full combined SELECT example showing all three computations in ONE query (user explicitly asked for "one query"); gap-day callout — RANGE INTERVAL = true calendar window even with missing days vs ROWS BETWEEN 6 PRECEDING = 7 consecutive rows ignoring calendar gaps (critical for SaaS dashboards with sparse-day tenants); LAG default NULL handling note (`LAG(revenue, 1, 0)` to coalesce first-row NULL); no note that window functions execute after scan/filter so partition pruning on `day` still applies. |

---

## Teacher actions for iter 399

1. **MEDIUM** — Iceberg partition granularity resource: tighten the "coarser doesn't help" reasoning. Replace "pruning evaluates same files" with the precise mechanism: "coarser partitions = fewer partition directories but larger per-partition file sets with broader min/max stats — file-level pruning becomes less selective for narrower-window queries." Add partition spec evolution caveat: `ALTER TABLE ... SET PARTITION SPEC` only affects new writes; existing data needs `rewrite_data_files` to repartition; old snapshots still readable via Iceberg's per-snapshot spec tracking.

2. **LOW** — Window function resource: add a full combined SELECT example showing LAG day-over-day + AVG OVER RANGE 7-day stacked in one query:
   ```sql
   SELECT day, tenant_id, revenue,
          revenue - LAG(revenue, 1, 0) OVER (PARTITION BY tenant_id ORDER BY day) AS dod_change,
          AVG(revenue) OVER (PARTITION BY tenant_id ORDER BY day
                             RANGE BETWEEN INTERVAL '6' DAY PRECEDING AND CURRENT ROW) AS rolling_7d
   FROM daily_revenue
   WHERE day >= DATE '2026-03-01'
   ```

3. **LOW** — RANGE vs ROWS gap-day callout: explicitly document that `RANGE BETWEEN INTERVAL '6' DAY PRECEDING` gives a 7-calendar-day window (correct semantics even if intermediate days are missing) while `ROWS BETWEEN 6 PRECEDING` gives 7 consecutive rows regardless of calendar gaps — the former is what SaaS dashboards usually want.

4. **LOW** — `bucket(tenant_id, N)` 2nd-angle resource: when tenant count > 10K, prefer bucket() over identity partition on tenant_id to avoid partition explosion.

## Judge probe targets for iter 399

1. `bucket(tenant_id, N)` partition design 2nd angle for very high cardinality (>10K tenants) — tests partition spec migration + write.distribution-mode=hash.
2. PERCENT_RANK / NTILE window function 3rd angle — tests ranking window function durability.
3. Carry-forward backlog: HMS→Nessie no-downtime migration, SPILL_FAILED 60GB at 200GB cap, MERGE INTO rollback, OPA-override timeout, schema registry compat, EXPLAIN TYPE IO + VALIDATE, result caching patterns, Iceberg branches fast_forward, JWT+OPA concurrency under load, partition spec migration, Iceberg tagging 3rd angle, fs.cache 3rd angle JMX.

## Trajectory iter 370-398

4.625 → 4.375 → 4.47 → 3.98 FAIL → 4.5625 → 4.75 → 4.1875 → 4.4375 → 4.40625 → 4.5625 → 3.25 FAIL → 4.71875 → 4.8125 → 4.78125 → 4.375 → 4.094 → 4.4375 → 4.4375 → 4.4375 → 4.25 → 3.125 FAIL → 4.75 PASS → 4.125 PASS → 3.9375 FAIL → 4.625 PASS → 4.75 PASS → 3.125 FAIL → 4.3125 PASS → 4.375 PASS → 4.34375 PASS → **4.09375 PASS**

Consistent ~4.0–4.4 PASS band continues. Q1 dipped to 3.875 due to loose pruning reasoning but still passes; Q2 strong on Trino window function correctness. No critical factual errors; both answers production-stack-fit for on-prem Trino 467 + Iceberg 1.5.2.

## WebSearch verification

- RANGE BETWEEN INTERVAL '6' DAY PRECEDING AND CURRENT ROW — CONFIRMED valid Trino syntax per [Trino window functions documentation](https://trino.io/docs/current/functions/window.html): RANGE frames with INTERVAL offsets are supported when the ORDER BY column is date/timestamp.
- Iceberg partition transforms (day/week/month/bucket) — CONFIRMED per [Iceberg partition spec](https://iceberg.apache.org/spec/#partitioning).
- Iceberg streaming write small-files problem — CONFIRMED real production issue per [Iceberg structured streaming guide](https://iceberg.apache.org/docs/latest/spark-structured-streaming/) — compaction via `rewrite_data_files` is the canonical fix.
