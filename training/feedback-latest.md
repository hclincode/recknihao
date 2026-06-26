# Iter 1129 — Judge Feedback

**Iter average: 4.40625 PASS (margin +0.906).** Q1/Q3/Q4 land clean (4.875 / 5.0 / 4.875). **Q2 = 2.875 REAL CORRECTNESS DEFECT — data-loss DELETE.** Responder's PRIMARY form `DELETE FROM t WHERE (user_id, event_type, occurred_at) IN (SELECT those tuples FROM dedup WHERE rn > 1)` deletes the KEEPER row too because the question's premise (duplicates share user_id+event_type+occurred_at, only event_id differs) means the keeper (rn=1) has the IDENTICAL tuple as the duplicates (rn>1) — the IN predicate matches all copies including the one to keep. Verified data-loss bug, not a parse error, **wrong-result without warning**. Plus: `ORDER BY occurred_at ASC` alone is non-deterministic for "earliest" when all duplicates share occurred_at (needs `ORDER BY occurred_at, event_id` tiebreaker). ALTERNATIVE form (`INSERT INTO new_table SELECT * WHERE rn=1`) is correct (modulo tiebreaker non-determinism). **Defect classification: RESOURCE-SOURCED.** r27 §1976-1983 Pattern B2 (MERGE-with-DELETE on ROW_NUMBER subquery) uses the same `tgt.k = dup.k` join shape on the partition+order columns without warning about the "duplicates share join-key columns" trap, and has no event_id / unique-row-id alternative for this common scenario. The responder mechanically translated Pattern B2 from MERGE-form into DELETE-IN-form, inheriting the trap. **RECOMMENDATION = LIGHT FIX-A at r27 §1976-1983.** Add (a) one-line warning to Pattern B2: "if duplicates share ALL columns in PARTITION BY + ORDER BY, this DELETEs the keeper too — use Pattern B3 below", (b) NEW Pattern B3 — `DELETE FROM t WHERE event_id IN (SELECT event_id FROM dedup WHERE rn > 1)` (DELETE BY UNIQUE-ROW-ID) for the common case where a stable unique column distinguishes duplicates, (c) tiebreaker note on the ORDER BY: when the order column has ties, append the unique-id column (`ORDER BY occurred_at, event_id`) for deterministic "earliest" semantics. Reconcile-in-place per `feedback_reconcile_dont_append`; do not append elsewhere.

---

## Per-question scoring

### Q1 — dashboards time out when nightly dbt job runs; memory/worker-slot or Iceberg write conflict; how to stop ETL starving dashboards — **4.8750**

| Dim | Score | Reasoning |
|---|---|---|
| Acc | 5.0 | Resource-group/worker-slot contention diagnosis correct; Iceberg snapshot isolation correctly distinguished from blocking (verified iceberg.apache.org/spec/ + jack-vanlightly snapshot isolation analysis — "Readers use the snapshot that was current when they load the table metadata and are not affected by changes until they refresh"; reads NOT blocked by concurrent writes/MERGE/ingest). `system.runtime.queries` columns `queued_time_ms` + `state` verified against trino.io/docs/current/connector/system.html (queries table tracks how long a query was queued; bigint queued_time_ms + varchar state are documented columns). Resource groups + maxRunning (hardConcurrencyLimit) + source-based selectors verified against trino.io/docs/current/admin/resource-groups.html — "source selector field is a Java regex to match against source string". resource-groups.properties + resource-groups.json placement on coordinator correct. |
| Clar | 5.0 | Clean three-step structure: rule out write conflict → diagnose with system.runtime.queries → fix with resource groups + concrete JSON. |
| App | 5.0 | maxRunning=20 (dashboards) / maxRunning=5 (etl) concrete numbers + selectors-by-source ready to paste. |
| Compl | 4.5 | Minor shave: doesn't surface `softCpuLimit`/`hardCpuLimit` CPU-priority or per-query memory caps (query.max-memory-per-node) as adjacent levers for "ETL is starving dashboards" — resource group concurrency alone is the right primary lever but combining with CPU/memory limits is the production-grade configuration. Per-instance completeness, NOT a resource gap. |

### Q2 — collector retries created duplicates (same user_id+event_type+timestamp, different event_id); keep earliest per user_id+event_type on 400M rows, no self-join — **2.8750 (REAL DEFECT)**

| Dim | Score | Reasoning |
|---|---|---|
| Acc | 2.0 | PRIMARY form `DELETE FROM large_events_table WHERE (user_id, event_type, occurred_at) IN (SELECT user_id, event_type, occurred_at FROM dedup WHERE rn > 1)` is a **DATA-LOSS BUG** on this question's premise. The question states duplicates share (user_id, event_type, occurred_at) — only event_id differs. So the keeper (rn=1) has the IDENTICAL (user_id, event_type, occurred_at) tuple as its duplicates (rn>1). The IN-subquery returns that shared tuple. The DELETE then matches every row whose tuple matches — INCLUDING the keeper — and removes all copies. Wrong-result without parse/runtime error; the engineer running this on 400M rows would silently lose every keeper for every duplicated key. Secondary issue: `ORDER BY occurred_at ASC` alone is non-deterministic for the tie (all duplicates share occurred_at, so any duplicate could be chosen as rn=1) — "earliest" semantics needs `ORDER BY occurred_at, event_id` tiebreaker. ALTERNATIVE form `INSERT INTO large_events_table_deduplicated SELECT * FROM dedup WHERE rn = 1` is CORRECT shape (CTAS / new-table-rebuild, picks 1 keeper per partition) modulo the same tiebreaker concern. The CORRECT in-place form is DELETE BY UNIQUE ROW ID: `DELETE FROM t WHERE event_id IN (SELECT event_id FROM dedup WHERE rn > 1)` — the question explicitly gives event_id as the unique-per-row column. |
| Clar | 4.0 | Structure is clear (CTE + two forms); doesn't flag the trap. |
| App | 2.0 | If the engineer pastes the PRIMARY form, they LOSE DATA on 400M rows. That's worse than getting no answer — it's the failure mode (silent wrong-result) the responder is supposed to prevent. The ALTERNATIVE form salvages the answer if the engineer skips down to it, but PRIMARY-labeled forms are what most engineers reach for. |
| Compl | 3.5 | Missing event_id-based DELETE (the natural fix when the question highlights event_id as the unique column); missing tiebreaker note; ALTERNATIVE CTAS form is sound and partially salvages the answer. |

### Q3 — MAP(VARCHAR,BIGINT) column; find map keys appearing in >= 100 rows; built-in to extract keys or unnest? — **5.0000**

| Dim | Score | Reasoning |
|---|---|---|
| Acc | 5.0 | `map_keys(x(K, V)) → array(K)` verified against trino.io/docs/current/functions/map.html — for `map(varchar, bigint)` returns `array(varchar)`. `CROSS JOIN UNNEST(map_keys(...)) AS u(feature_name)` is the canonical map-key-frequency idiom; `COUNT(*) FROM t CROSS JOIN UNNEST(...) GROUP BY feature_name HAVING COUNT(*) >= 100` correctly counts ROWS (one row contributes one occurrence per distinct key in its map; if a map has the key twice — which `MAP` doesn't allow because keys are unique within a map — that's not a concern). HAVING is the right placement (post-aggregation filter). |
| Clar | 5.0 | One-sentence concept + one-block SQL = beginner-friendly. |
| App | 5.0 | Direct copy-paste. |
| Compl | 5.0 | Fully addresses built-in (map_keys) AND the unnest pattern in one answer. |

### Q4 — 3yr data in MinIO, bill growing; auto-move data older than 6mo to cheaper storage class in Iceberg/MinIO, or archive table? — **4.8750**

| Dim | Score | Reasoning |
|---|---|---|
| Acc | 5.0 | "No Trino DDL for per-partition tiering" correct (Iceberg connector has no built-in tier-per-partition spec; verified against trino.io/docs/current/connector/iceberg.html — `partitioning`/`format`/`location`/`compression_codec` properties only, no per-partition storage class). Mechanism A `mc ilm tier add` + `mc ilm rule add --transition-days 180 --transition-tier` verified against docs.min.io — "transition-days: The number of calendar days from object creation after which MinIO marks an object as eligible for transition"; age-based (NOT last-access — MinIO ILM is creation-time-based, not access-time-based). Prefix scoping (`data/` not `metadata/`) correct — moving Iceberg metadata files to a slow tier would break query planning. Mechanism B ZSTD via `WITH (compression_codec = 'ZSTD')` is a valid Iceberg connector property. Mechanism C archive table + nightly INSERT/DELETE + UNION ALL view is the canonical workaround pattern. |
| Clar | 5.0 | Three labeled mechanisms (A/B/C) with clear trade-off notes. |
| App | 5.0 | Concrete mc commands + Iceberg properties + UNION ALL view DDL all paste-ready. |
| Compl | 4.5 | Minor shave: doesn't explicitly call out (a) MinIO ILM transitions are one-way (objects don't auto-promote back if a query re-touches them; if cold tier has high egress, hot queries on archive data get expensive), (b) per-tier cost trade-off (S3 Glacier-style tiers add per-request fees and retrieval latency that may surprise dashboards). Per-instance completeness, NOT a resource gap. |

---

## Score table

| Q | Acc | Clar | App | Compl | Avg |
|---|---|---|---|---|---|
| Q1 (resource groups + Iceberg snapshot isolation + system.runtime.queries) | 5.0 | 5.0 | 5.0 | 4.5 | **4.8750** |
| Q2 (dedup DELETE — data-loss bug on tied-tuple) | 2.0 | 4.0 | 2.0 | 3.5 | **2.8750** |
| Q3 (map_keys + UNNEST key-frequency) | 5.0 | 5.0 | 5.0 | 5.0 | **5.0000** |
| Q4 (storage tiering — Trino/MinIO/archive table) | 5.0 | 5.0 | 5.0 | 4.5 | **4.8750** |
| **Iter average** | | | | | **4.40625** |

**Overall: PASS (margin +0.906 over 3.5 threshold)** — Q2's defect is a real correctness bug but the iter average remains above the threshold by ~0.9.

---

## Source-verified defects

**Q2 PRIMARY DELETE form — data-loss bug (resource-sourced from r27 §1976-1983 Pattern B2).**

The trap mechanism, verified by hand-walking the IN-predicate semantics:
- Question premise: duplicates share `(user_id, event_type, occurred_at)`; only `event_id` differs.
- `dedup` CTE labels rn=1 (keeper) and rn>1 (duplicates), but all share the same `(user_id, event_type, occurred_at)` tuple.
- PRIMARY: `DELETE FROM t WHERE (user_id, event_type, occurred_at) IN (SELECT user_id, event_type, occurred_at FROM dedup WHERE rn > 1)` — the subquery returns the shared tuple; the predicate matches **every** row with that tuple, including the keeper.
- Result: ALL copies deleted, including the row meant to be retained. No error, no warning — silent data loss on 400M rows.

The CORRECT in-place form uses the unique row id directly:
```sql
DELETE FROM large_events_table WHERE event_id IN (SELECT event_id FROM dedup WHERE rn > 1);
```

This works because `event_id` uniquely identifies each row — the IN predicate only matches the duplicates, not the keeper. The question explicitly highlights `event_id` as the per-row unique column, so reaching for it is natural.

Additionally: the responder's `ORDER BY occurred_at ASC` is non-deterministic for the tie scenario (all duplicates share `occurred_at`). For deterministic "earliest" semantics, append a unique tiebreaker: `ORDER BY occurred_at, event_id`.

**Resource root cause:** r27 §1976-1983 Pattern B2 (MERGE-with-DELETE on ROW_NUMBER subquery) uses the same join-on-partition+order-columns shape — `tgt.customer_id = dup.customer_id AND tgt.created_at = dup.created_at` — and has the IDENTICAL trap when partition+order columns don't uniquely identify rows. The canonical doesn't warn about this case and doesn't offer the unique-row-id alternative. The responder almost certainly translated Pattern B2 from MERGE-form into DELETE-IN-form, inheriting the trap.

Verified clean for Q1/Q3/Q4 against:
- trino.io/docs/current/admin/resource-groups.html (resource groups + selectors-by-source)
- trino.io/docs/current/connector/system.html (system.runtime.queries columns)
- iceberg.apache.org/spec/ + jack-vanlightly snapshot isolation analysis (reads not blocked by writes)
- trino.io/docs/current/functions/map.html (`map_keys(x(K,V)) → array(K)`)
- docs.min.io mc-ilm-rule-add (`--transition-days` age-based; `--transition-tier` required)
- trino.io/docs/current/connector/iceberg.html (no per-partition storage tier property; `compression_codec` is valid)

---

## Teacher guidance

**LIGHT FIX-A at r27 §1976-1983 (Pattern B2 — Oracle ROWID-dedup → Trino "MERGE-with-DELETE" in-place form).** Two surgical additions, reconciled in place per `feedback_reconcile_dont_append`:

1. **Warning at top of Pattern B2** — one paragraph:
   > **Pattern B2 ONLY works when the PARTITION BY + ORDER BY columns uniquely identify each row.** If duplicates share IDENTICAL values across BOTH the partition columns AND the order columns (the common "collector-retry duplicates" scenario: same business-key + same timestamp + DIFFERENT surrogate id), the MERGE ON clause matches the KEEPER too and DELETEs all copies including the row meant to be kept. **Silent wrong-result, no error.** When a stable unique row id (`event_id`, `request_id`, `_metadata.file_path`, etc.) exists, use **Pattern B3** below instead.

2. **NEW Pattern B3 — DELETE BY UNIQUE ROW ID** (insert after Pattern B2):
   ```sql
   -- Pattern B3 — DELETE BY UNIQUE ROW ID (preferred when a stable unique column exists):
   WITH dedup AS (
     SELECT event_id,
            ROW_NUMBER() OVER (
              PARTITION BY user_id, event_type
              ORDER BY occurred_at, event_id    -- tiebreaker for ties on occurred_at
            ) AS rn
     FROM iceberg.analytics.events
   )
   DELETE FROM iceberg.analytics.events
   WHERE event_id IN (SELECT event_id FROM dedup WHERE rn > 1);
   ```
   With a note: "This is safe even when `occurred_at` (or any other ORDER BY column) has ties — `event_id` is the unique-per-row column the IN-predicate matches, so only duplicates are removed."

3. **ORDER BY tiebreaker note** to Patterns A / B1 / B2 / B3: "When the ORDER BY column may tie (e.g., multiple events at the same `occurred_at`), append a unique tiebreaker (`ORDER BY occurred_at, event_id`) — without it, `ROW_NUMBER` ties are broken non-deterministically and rerunning the dedup may pick a different keeper."

Defang Pattern B2 with an INLINE WRONG marker for the common-tied-tuple scenario, per `feedback_defang_donotwrite_snippets` — keep the existing Pattern B2 (it's correct when partition+order DOES uniquely identify rows, e.g., (customer_id, created_at) with millisecond timestamps), but front it with the warning so the responder routes to B3 on the tied-tuple scenario.

**Re-probe queue (carry-forward, plus B3 verification):**
1. **NEW priority**: dedup-tied-tuple re-probe — "duplicates share business-key + timestamp, only surrogate id differs, drop dupes in place" — confirm responder reaches Pattern B3 / `WHERE event_id IN (...)` shape on first instance after FIX-A lands.
2. storage-tiering 10th angle (now 4.0278/9 after Q4 lift; still thin row, opportunity to push above 4.1)
3. dbt-snapshots SCD2 17th angle (check_cols edge cases, hard_deletes='new_record' downstream interaction)
4. cost-considerations 22nd angle (`$manifests` partition-cost attribution, per-tenant cost split)
5. query-perf-regression-diagnosis 21st angle (this iter's Q1 covered concurrent ETL-vs-dashboard contention oncall — partial coverage)
6. Trino-side EXECUTE optimize after partition evolution (carry from iter1128 re-probe queue)

**Watch streams: NEW WATCH OPENED.** *Dedup-tied-tuple DELETE-IN trap.* First instance, defect classification RESOURCE-SOURCED. After FIX-A lands, re-probe with: (a) the exact iter1129 framing again to confirm B3 is reached; (b) a near-duplicate framing ("collector retries created dupes with same key + same timestamp but different request_id, drop dupes on 200M rows"); (c) a Pattern-B2-safe framing ("dedup customers with same email but different created_at; keep earliest") to verify Pattern B2 still routes correctly when partition+order DOES uniquely identify rows (regression-check after FIX-A).

**Pattern observation.** 12-iter sustainment band shape continues: STRONG PASS iters 1090/1092/1093/1117/1118/1119/1121/1122/1125/1127/1128 with LIGHT FIX-A iters 1091/1116/1124/**1129** reaching between, and NO-OP+WATCH iters 1120/1123/1126 with watches CLOSED. iter1129 4.40625 PASS+LIGHT-FIX-A matches the iter1091 4.40 PASS+LIGHT-FIX-A profile — single Q with a real correctness defect found via the question structure, defect classified resource-sourced, surgical FIX-A targeting the specific canonical with reconcile-in-place + defang. NOT the `feedback_responder_broken_secondary_alternative` shape (that's PRIMARY-correct + secondary-broken; here it's PRIMARY-broken + ALTERNATIVE-correct). NOT the `feedback_synthesis_ceiling_stop_churning` shape (the bug is a specific pattern-translation trap in a canonical, not a multi-step synthesis ceiling). The trap class — "canonical's join-key columns happen to be non-unique in this question's premise, IN/MERGE matches the keeper" — is a NEW defect class worth pinning to MEMORY.md after FIX-A re-probe confirms the fix sticks. Q1 reaffirms resource-groups + Iceberg-snapshot-isolation-vs-blocking durable. Q3 reaffirms map_keys + UNNEST + GROUP BY + HAVING canonical durable (no map-vs-array confusion). Q4 reaffirms three-mechanism storage-tiering (no built-in Trino DDL, MinIO mc ilm age-based, archive-table + UNION ALL view) durable from r17/r24.
