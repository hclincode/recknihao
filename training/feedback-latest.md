# Judge Feedback — Iter 419 (EXTENDED PHASE — end-of-iteration only)

**Overall: 4.578 PASS** (Q1 4.875 + Q2 4.875 + Q3 3.9375 + Q4 4.625) — comfortably above the 3.5 PASS threshold and the eighteenth consecutive overall PASS in the iter402-419 window. **-0.078 step-down from iter418 4.65625**, but the headline is split: federation threshold-push DELIVERED on the bulletproofed content (Q1 + Q2 both at 4.875, the strongest federation pair in the topic's threshold-push history), and a NEW confident-inaccuracy returned in Q3 (self-contradiction with the responder's own r13 myth box on Spark write API).

**Headline:**
1. **FEDERATION THRESHOLD-PUSH LANDED — BOTH Q1 + Q2 AT 4.875.** The teacher's iter419 bulletproofing of resource 22 (verbatim doc quotes for join-type support, dynamicFilterSplitsProcessed semantics, wait-timeout default; doc-quoted equality/inequality vs range pushdown; explicit empirical-vs-doc-quoted sourcing labels) produced the largest single-iteration federation pair in the topic's recent threshold-push history. **+0.0028 nudge UP for the federation topic (4.4894 -> 4.4922)**. Topic now 0.0078 below threshold (was 0.0106). **19th consecutive iteration below threshold but trending UP for the 5th iteration in a row.**
2. **MYTH-BUSTER ZERO-CONFIDENT-INACCURACY STREAK BROKEN AT 1.** A NEW confident-inaccuracy appeared in Q3: the responder closed an otherwise-solid Spark JDBC parallelism recipe with `events_df.write.format("iceberg").mode("append").saveAsTable("iceberg.analytics.events")` — the EXACT legacy save() / saveAsTable API that the r13 myth box (row 7) explicitly flags as wrong. **This is a SELF-CONTRADICTION with the responder's own resource.** Failure-mode count is now 7 of prior 18 iterations.
3. **Q4 STRONG (4.625)** — file_size_threshold semantics correctly framed as "rewrite files SMALLER than" (NOT target output size); no-Trino-target-size-knob claim verified; clean engine-disambiguation to Spark `rewrite_data_files(target-file-size-bytes => ...)` for target-size control.

---

## Critical watch items — explicit confirmations

### (a) Did any NEW confident-inaccuracy / engine-confusion / version-gated-fix appear?

**YES — ONE NEW CONFIDENT-INACCURACY in Q3** (the API-confusion sub-flavor of the recurring pattern). The responder closed the JDBC parallelism recipe with:

```python
events_df.write.format("iceberg").mode("append").saveAsTable("iceberg.analytics.events")
```

This is the LEGACY save() / saveAsTable API. r13's own MYTH BOX (row 7) states verbatim:

> "NO — that path is the legacy `save(path)` API and doesn't work cleanly with the SparkCatalog plugin. The correct Iceberg-1.5.2 write API is the catalog-aware DataFrameWriterV2: `df.writeTo('iceberg.x.y').append()` ... The `save()` form will sometimes write to the wrong location or skip the catalog entirely."

**This is a SELF-CONTRADICTION with the responder's own resource.** It is in the same family as iter417's Spark-CALL-syntax-as-Trino-EXECUTE inversion (API-confusion sub-flavor) — the resource HAS the correct answer in a load-bearing myth box, and the responder still emitted the WRONG form. An engineer running this exact code in prod gets either a silently-wrong write path (skipping the catalog), partition spec ignored, or a hard CatalogPlugin error.

**Penalty applied:** Q3 technical accuracy 3.5 (from 4.5), practical applicability 3.75 (from 4.75). Avg 3.9375 LOW PASS. The READ-side mechanics of JDBC parallelism were solid — partitionColumn / lowerBound / upperBound / numPartitions / min(cores, max_connections) / index-on-partition-column gotcha all correct — but the WRITE-side closer was the failure point.

**Q1, Q2, Q4: ZERO new confident-inaccuracies.** Clean for federation and compaction.

### (b) Updated Trino federation topic average

**4.4894/274 -> 4.4922/276** (Q1 4.875 + Q2 4.875 — both well above the 4.5 threshold, +0.0028 nudge UP from the double-strong federation pair). Topic now **0.0078 below** the 4.5 pass threshold (was 0.0106 — moved 0.0028 closer). **19th consecutive iteration stuck below threshold** but trending UP for the **5th iteration in a row** (iter415 4.625 → iter417 4.75 → iter418 4.625 → iter419 [Q1 4.875 + Q2 4.875]).

**Does it cross 4.5?** NO — still 0.0078 below. But the iter419 result is the strongest single-iteration federation pair in the topic's recent threshold-push history. The bulletproofed content in resource 22 (verbatim doc quotes for join-type support, dynamicFilterSplitsProcessed semantics, wait-timeout default; doc-quoted pushdown categories) delivered exactly what the strategy predicted: 4.75+ on both federation questions. Sustained 4.75+ federation answers will continue to close the remaining 0.0078 gap.

### (c) Q3 SELF-CONTRADICTION verdict

**The responder used the API that the resource's own myth box explicitly flags as wrong.** This is the most concerning category of failure — not "the resource didn't cover it" or "the responder confused two engines on an edge case", but "the resource has a verbatim TRUTH callout for this exact question, and the responder produced the corresponding MYTH form anyway." 

Probable cause: the API form (`df.write.format("iceberg").mode("append").saveAsTable(...)`) is the dominant Spark idiom for non-Iceberg use cases (Hive, Parquet path-based), and the responder pattern-matched to the Spark-general idiom instead of pulling the Iceberg-specific form from r13's catalog-aware-DataFrameWriterV2 callout. The recovery is to make the myth box's TRUTH form more discoverable — e.g., a leading "Spark JDBC parallelism worked example" subsection in r13 that closes with the canonical `df.writeTo("iceberg.analytics.events").append()` form inline, not just in the myth box.

---

## Per-question scoring

### Q1 — Dynamic filtering verification (Trino federation / cross-source connectors)

**Scores: 5.0 / 4.75 / 5.0 / 4.75 — avg 4.875 STRONG PASS**

**What landed:**
- `dynamicFilterSplitsProcessed` > 0 from EXPLAIN ANALYZE VERBOSE operator stats as runtime proof — VERIFIED ("records the number of splits processed after a dynamic filter is pushed down to the table scan") against admin/dynamic-filtering.html.
- EXPLAIN (TYPE DISTRIBUTED) shows `dynamicFilters` annotation on probe-side TableScan as plan-time proof — CORRECT.
- Join-type support INNER + RIGHT JOIN with =/</<=/>/>=/IS NOT DISTINCT FROM + semi-join with IN — VERIFIED VERBATIM against admin/dynamic-filtering.html. LEFT OUTER and FULL OUTER explicitly do NOT fire because "all records from the left side must be returned at least once".
- `iceberg.dynamic-filtering.wait-timeout` default 1s — VERIFIED against connector/iceberg.html. Raise to 15-30s when build-side Postgres scan is slow — CORRECT operational advice. NO session-property form on the Iceberg connector (catalog-level only) — VERIFIED.
- Iceberg-must-be-probe-side (large fact table) framing — CORRECT (DF builds the IN-list from the small build side; probe side filters against it).
- VARCHAR join-key caveat (high-cardinality VARCHAR domains compact to ranges and lose selectivity at the 256 default) — CORRECT.
- IN-list-to-range compaction at 256 default mentioned — CORRECT.

**Verdict:** STRONG PASS. Bulletproofed content delivered the 4.75+ federation threshold-push. Engineer running this gets a complete verification stack (plan-time EXPLAIN + runtime EXPLAIN ANALYZE) + a complete debug checklist (join type / probe side / timeout / VARCHAR caveat).

### Q2 — Predicate pushdown categories (Trino federation / cross-source connectors)

**Scores: 5.0 / 4.75 / 5.0 / 4.75 — avg 4.875 STRONG PASS**

**What landed:**
- = / IN / IS NULL / numeric range / date range — VERIFIED PUSH against connector/postgresql.html.
- VARCHAR/text range does NOT push by default — VERIFIED against the same source.
- LIKE anchored prefix framed as "MAYBE / conservative — verify via EXPLAIN" — CORRECT NUANCE. Official docs do not explicitly say anchored LIKE pushes by default; in practice it generally does NOT push without the experimental flag because LIKE is range-class semantically. The "maybe / verify with EXPLAIN" framing is exactly the right calibrated answer; an absolute "anchored LIKE pushes" would be wrong, an absolute "no LIKE pushes" would be over-conservative.
- `postgresql.experimental.enable-string-pushdown-with-collate` (catalog + session forms) — VERIFIED (PR #9746, release 365, on 467). Correctly framed as opt-in with collation-correctness risk.
- Always verify EXPLAIN (TYPE DISTRIBUTED) for plan-time pushdown evidence — exemplary practical guidance.
- One-sentence model ("connector pushes equality+inequality on any type, numeric+date ranges, IS NULL; text range needs the collate flag") — clear and correct.

**Verdict:** STRONG PASS. Bulletproofed content delivered the 4.75+ federation threshold-push. LIKE "MAYBE" framing is the most defensible calibration of an ambiguous behavior.

### Q3 — Spark JDBC parallelism (Postgres-to-Iceberg ingestion)

**Scores: 3.5 / 4.5 / 3.75 / 4.0 — avg 3.9375 LOW PASS**

**What landed (READ side — solid):**
- `column` / `lowerBound` / `upperBound` / `numPartitions` — CORRECT.
- Bounds via `SELECT min(id), max(id)` collect — CORRECT.
- Splits as id-range BETWEEN WHERE clauses on parallel connections, no overlap — CORRECT.
- Out-of-range rows folded to first/last partition — CORRECT.
- numPartitions sizing = min(spark cores, Postgres max_connections budget) — CORRECT.
- Index-on-partition-column gotcha (without an index, Postgres falls back to sequential scan per split — n times the scan cost) — CORRECT.

**What FAILED (WRITE side — confident-inaccuracy):**
- The responder closed with `events_df.write.format("iceberg").mode("append").saveAsTable("iceberg.analytics.events")` — the LEGACY save() / saveAsTable API.
- r13's own MYTH BOX (row 7) explicitly flags this as wrong: "the legacy `save(path)` API ... doesn't work cleanly with the SparkCatalog plugin. The correct Iceberg-1.5.2 write API is the catalog-aware DataFrameWriterV2: `df.writeTo('iceberg.x.y').append()`".
- **This is a SELF-CONTRADICTION with the responder's own resource.** It is in the API-confusion sub-flavor of the recurring confident-inaccuracy pattern.

**Verdict:** LOW PASS. The read-parallelism mechanics are textbook correct, but the write-side closer is a confident-inaccuracy that an engineer would copy-paste into prod. If the read-side were the only ask, this would be a 4.75. The write-side slip drags it to LOW PASS.

### Q4 — Compaction on Trino 467 (Iceberg table maintenance)

**Scores: 4.75 / 4.5 / 4.75 / 4.5 — avg 4.625 STRONG PASS**

**What landed:**
- `ALTER TABLE iceberg.analytics.events EXECUTE optimize(file_size_threshold => '512MB')` syntax — VERIFIED CORRECT.
- **file_size_threshold semantics correctly framed: "rewrite files SMALLER than" threshold, NOT a target output size** — VERIFIED against connector/iceberg.html ("All files with a size below the optional file_size_threshold parameter (default value for the threshold is 100MB) are merged"). This is the exact watch-item.
- No Trino target-output-size knob — CORRECT (verified against current connector docs).
- For explicit target file size drop to Spark `CALL iceberg.system.rewrite_data_files(table => '...', options => map('target-file-size-bytes', '536870912'))` — CORRECT engine-disambiguation. Clean separation Trino-EXECUTE-optimize vs Spark-CALL-rewrite_data_files; NO inversion.
- Partition-scoped `EXECUTE optimize WHERE day = DATE '2026-06-02'` — CORRECT.
- Nightly optimize + weekly expire_snapshots + weekly remove_orphan_files lifecycle — CORRECT.

**Verdict:** STRONG PASS. Small nudge for not foregrounding the 512MB-vs-default-100MB rationale (when 512MB is appropriate vs when default 100MB is enough). file_size_threshold-as-rewrite-smaller-than is the key technical watch-item and the responder got it correctly.

---

## Pattern across all four answers

| Q | Score | Verdict |
|---|---|---|
| Q1 | 4.875 | STRONG PASS — federation threshold-push delivered (4.75+ band) |
| Q2 | 4.875 | STRONG PASS — federation threshold-push delivered (4.75+ band) |
| Q3 | 3.9375 | LOW PASS — NEW confident-inaccuracy on Spark write API (self-contradiction with r13 myth box) |
| Q4 | 4.625 | STRONG PASS — file_size_threshold semantics correct + clean engine-disambiguation |

**Average 4.578 PASS** — eighteenth consecutive overall PASS, -0.078 step-down from iter418 4.65625. **The headline is split:** the federation threshold-push DELIVERED (Q1 + Q2 both at the 4.75+ band, the strongest federation pair in the topic's threshold-push history), and a NEW confident-inaccuracy returned in Q3 (self-contradiction with the responder's own r13 myth box).

**Trajectory iter394-419:** `4.75P/3.125F/4.3125P/4.375P/4.34375P/4.09375P/4.0625P/3.8125F/4.59375P/3.875F/4.25P/4.6875P/4.40625P/4.625P/4.0625P/4.125P/4.5625P/4.0P/4.219P/4.625P/4.21875P/4.0625P/4.625P/4.5625P/4.375P/4.65625P/**4.578P**`.

**Topic status updates:**
- **Trino federation: 4.4894/274 -> 4.4922/276** (Q1 4.875 + Q2 4.875 both above 4.5 threshold, +0.0028 nudge UP — largest single-iteration federation movement in many iters; topic now 0.0078 below threshold, 19th consecutive iter below threshold but trending UP for 5th iter in a row).
- **Postgres-to-Iceberg ingestion: 4.4945/148 -> 4.4907/149** (Q3 3.9375 below topic avg, -0.0038 nudge DOWN).
- **Iceberg table maintenance: 4.4130/84 -> 4.4155/85** (Q4 4.625 above topic avg, +0.0025 nudge UP).

---

## Teacher actions next (iter 420)

1. **HIGH — Spark write API DURABILITY FIX for r13.** The Q3 self-contradiction is the most concerning failure mode this iteration. The myth box has the correct TRUTH form but the responder still emitted the MYTH form. Recovery moves:
   - Add a LEADING worked example "Spark JDBC parallelism end-to-end recipe" subsection EARLY in r13 (before the myth box) that ends with the canonical `df.writeTo("iceberg.analytics.events").append()` form inline — so the responder pattern-matches on the worked example FIRST.
   - Add an **API-CONFUSION GUARDRAIL** callout in r13 in the style of r18's ENGINE-CONFUSION GUARDRAIL: "When closing a Spark-to-Iceberg write recipe, the FINAL line must be `df.writeTo('iceberg.x.y').append()` / `.overwritePartitions()` / `.createOrReplace()`. NEVER `df.write.format('iceberg').mode(...).save()` or `.saveAsTable()` — those are the legacy save() path that the SparkCatalog plugin does NOT handle cleanly."
   - Cross-reference: the myth-box row 7 should be promoted to a numbered TOP-OF-DOC callout, not just one row in the myth table.

2. **MEDIUM — Continue Trino federation threshold-push.** Topic is 0.0078 below threshold (was 0.0106). The iter419 result PROVED that bulletproofed content delivers 4.75+ federation answers. Continue the bulletproofing pattern for the remaining federation angles likely to come up: cross-catalog 3-way JOIN execution location; aggregation pushdown to Postgres semantics; schema-evolution-with-pushdown mid-query; OR-with-mixed-types pushdown.

3. **LOW — Iter418 carry-forward optional refinement still pending:** foreground Trino 467 `EXECUTE remove_orphan_files` as the primary cleanup path after rollback in r17.

4. **LOW — Carry-forward backlog:** HMS->Nessie write-freeze alternative; branches-vs-expire_snapshots 3rd-angle; Snapshot vs serializable phantom-row 3rd-angle; Window NULL 2nd-angle calendar-dim densification; Iceberg v3 deletion vectors timeline; MERGE rollback; OPA-override timeout; schema registry compat; JWT+OPA concurrency.

---

## Judge probe targets next (iter 420)

1. **HIGH — Spark write API durability RE-PROBE in NEW shape.** Probe whether the iter419 Q3 API-confusion fix in r13 holds:
   - "I have a Spark JDBC read with parallelism set up — show me the complete end-to-end recipe to write the result to Iceberg." (direct re-probe in same shape)
   - "I want to do an idempotent backfill from Postgres to Iceberg for a single day partition — what's the Spark code?" (probes whether `.overwritePartitions()` is used, NOT `mode('overwrite').save()`)
   - "I'm bootstrapping a new Iceberg table from a Postgres dump — Spark recipe?" (probes whether `.createOrReplace()` is used, NOT `mode('overwrite').saveAsTable()`)

2. **HIGH — Trino federation threshold-push continuation in different shape.** Topic is 0.0078 below; iter419 Q1+Q2 delivered 4.875 each. Continue with bulletproofed-content-aligned angles:
   - Cross-catalog 3-way JOIN execution location (Postgres+Iceberg+Iceberg — which side dominates execution?)
   - Aggregation pushdown to Postgres (when does `SUM/COUNT/AVG` push? what's the EXPLAIN signature?)
   - Schema-evolution-with-pushdown (Postgres ADDs a new column mid-query — does the in-flight Trino plan still push the predicate?)

3. **MEDIUM — Iceberg branches-vs-expire_snapshots 3rd-angle** — still pending: "After running expire_snapshots, an old snapshot I thought was branch-protected is gone — why?"

4. **MEDIUM — Snapshot vs serializable phantom-row 3rd-angle** — still pending.

5. **MEDIUM — HMS->Nessie 2nd-angle for write-freeze alternative** — still pending.

6. **MEDIUM — Window NULL 2nd-angle (calendar-dim LEFT JOIN densification)** — still pending.

7. **LOW — Iceberg v3 deletion vectors timeline** carry-forward.

---

## Critical message to teacher for iter 420: federation bulletproofing WORKS — extend it to the Spark write API

The iter419 result is a clean **proof of concept** for the bulletproofing strategy: when the teacher loads verbatim doc quotes + explicit empirical-vs-doc-quoted sourcing labels into the resource, the responder lands 4.75+ on the question. Q1 + Q2 both at 4.875 are the strongest federation pair in the topic's recent threshold-push history.

The Q3 failure is structurally different from a content gap: r13 already HAS the correct answer in the myth box, but the responder pattern-matched to the dominant Spark-general idiom (`df.write.format(...).saveAsTable(...)`) instead of the Iceberg-specific catalog-aware DataFrameWriterV2 form. The fix is **discoverability and surfacing**, not new content: promote the myth-box row 7 to a leading numbered TOP-OF-DOC callout, add an API-CONFUSION GUARDRAIL in the style of r18's ENGINE-CONFUSION GUARDRAIL, and lead r13 with a complete end-to-end worked example that closes with the canonical writeTo() form inline.

The structural pattern is clear: when bulletproofed content is present and the responder uses it, the answer lands in the 4.75+ band. When a peripheral API form falls back to the dominant generic Spark/Trino idiom, a self-contradiction with the resource's own myth box appears. The recovery move is to make the correct form the **first thing the responder sees** for that API category.
