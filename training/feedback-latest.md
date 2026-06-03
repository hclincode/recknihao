# Judge Feedback — Iter 417 (EXTENDED PHASE — end-of-iteration only)

**Overall: 4.375 PASS** (Q1 3.75 + Q2 4.75 + Q3 4.25 + Q4 4.75) — above the 3.5 overall PASS threshold and the sixteenth consecutive PASS in the iter402-417 window. Step-DOWN of -0.1875 from iter416 4.5625 entirely driven by Q1's NEW confident-inaccuracy (Spark CALL procedure syntax presented as Trino EXECUTE syntax).

**Headline:**
1. **MYTH-BUSTER STREAK BROKEN AT 2.** The "zero new confident-inaccuracies on load-bearing claims" streak (iter415 + iter416 = 2 clean iterations) ended at iter417. A NEW sub-flavor of the recurring failure mode surfaced in Q1: the responder presented `rewrite_data_files(sort_order => ARRAY['plan_type','event_ts'])` — which is Spark CALL procedure syntax — as if it were a Trino 467-valid ALTER TABLE EXECUTE form. **This is the engine-confusion flavor of confident-inaccuracy.** It is the same family as the recurring "X can't do Y" failure pattern (and same family as iter416 Q4's "version-gated-fix-recommendation" flag) but a slightly different sub-flavor: the recommended fix names a Spark procedure as Trino syntax.
2. **Q4 STRONG (4.75) — best federation answer in many iterations.** Cross-catalog JOIN runs on Trino workers (not pushed); WHERE on dim column pushes to Postgres; PG small side becomes build hash; DF derives account_id set; pushes to Iceberg scan; prunes files via min/max. DF default-on Trino 467 — VERIFIED. INNER/RIGHT only — VERIFIED. iceberg.dynamic-filtering.wait-timeout default 1s — VERIFIED. dynamicFilterSplitsProcessed verification recipe — CORRECT. Federation topic 4.4880/272 -> 4.4889/273 (+0.0009), 17th consecutive iter below 4.5 threshold but trending up.
3. **Q2 STRONG (4.75)** — partitioning != security pattern clean; JWT + OPA + per-tenant views + REVOKE base + MinIO direct-creds-bypass warning + external governance doc deferral all correct and match prod_info.md exactly.
4. **Q3 PASS (4.25)** — no-CREATE-INDEX framing correct; partition pruning + sort order + manifest min/max substitutes correct; but minor echo of Q1's procedure-naming-confusion ("sort order via rewrite_data_files") — not flagged as a NEW confident-inaccuracy here because the framing was more conceptual ("achievable via X procedure") rather than recommending a specific syntax form.

---

## Critical watch items — explicit confirmations

### (a) Did a NEW confident-inaccuracy on a load-bearing "X can't do Y" claim appear this iteration?

**YES** — but the sub-flavor is different from the canonical "X can't do Y" pattern. The Q1 inaccuracy is "Spark CALL procedure syntax presented as Trino EXECUTE procedure syntax" — recommending `ALTER TABLE EXECUTE rewrite_data_files(sort_order => ARRAY[...])` on Trino 467 when:
- **Verified against trino.io/docs/current/connector/iceberg.html:** the Trino Iceberg connector's supported ALTER TABLE EXECUTE procedures are `optimize`, `optimize_manifests`, `expire_snapshots`, `remove_orphan_files`, `drop_extended_stats`. **`rewrite_data_files` is NOT among them.**
- **Verified:** the Trino `optimize` procedure accepts only `file_size_threshold` argument; **it does NOT accept a `sort_order` argument.**
- **The Trino-467-valid clustering path is:** `ALTER TABLE foo SET PROPERTIES sorted_by = ARRAY['plan_type']` then `ALTER TABLE foo EXECUTE optimize`. (Trino reads the sorted_by table property at OPTIMIZE time, added via PR #14891 release 412 Feb 2023.)
- **The Spark CALL form** `CALL spark_catalog.system.rewrite_data_files(table=>'db.tbl', strategy=>'sort', sort_order=>'plan_type ASC')` is a valid Spark path but the responder presented this name+arg-list as if it works on Trino 467.

An engineer running the responder's recommended SQL on Trino 467 will get a procedure-not-found or unknown-argument error. This is a load-bearing fix-recommendation failure that breaks user actions, and it's the SAME family of failure as the recurring confident-inaccuracy pattern (5 of prior 10 iters had at least one such failure; was ABSENT iter415 + iter416; **now reappears at iter417**, so the cleanest reading is 6 of prior 16, with a 2-iter clean window in between).

### (b) Is the Q1 `rewrite_data_files(sort_order => ARRAY[...])` syntax Trino-467-valid?

**NO — it is Spark-only syntax** (verified above). The responder slipped Spark CALL procedure form into a Trino ALTER TABLE EXECUTE recommendation.

### (c) Updated Trino federation topic average after Q4

**4.4880/272 -> 4.4889/273** (+0.0009 nudge UP — Q4 4.75 STRONG PASS, above 4.5 threshold). Topic now **0.0111 below** the 4.5 pass threshold. **17th consecutive iteration stuck below threshold** but Q4 was the strongest federation answer in many iterations and the trend is upward. Sustained 4.7+ federation answers continue to be the path to cross threshold.

---

## Q1 — Bloom-filter version-gate re-probe (Query performance regression)

**Scores: 3.0 / 4.5 / 3.5 / 4.0 — avg 3.75 PASS (below STRONG)**

### What landed
- **parquet_bloom_filter_columns NOT settable on Trino 467** — CORRECT (Trino 469+ via PR #24573, verified against trino.io/docs/current/release/release-469.html).
- **Iceberg per-column lower/upper bounds for ALL columns by default** — CORRECT (verified iceberg.apache.org/docs/latest/spec/#manifests).
- **Min/max skip only works if rows clustered** — CORRECT.
- **Spark write-time bloom filter via parquet.bloom.filter.columns (write.parquet.bloom-filter-enabled.column.X Iceberg property)** — CORRECT (Iceberg PR #5035 verified).
- **Trino 467 reads bloom filters at scan time but doesn't expose the write property** — CORRECT.

### NEW CONFIDENT-INACCURACY (Q1 deduction driver)
- **Responder recommends `rewrite_data_files sort_order => ARRAY['plan_type','event_ts']` as Trino-467-valid clustering path.** This is Spark CALL procedure syntax, NOT Trino ALTER TABLE EXECUTE syntax.
- **Verified via trino.io/docs/current/connector/iceberg.html:** Trino EXECUTE-supported procedures = `optimize` / `optimize_manifests` / `expire_snapshots` / `remove_orphan_files` / `drop_extended_stats`. **`rewrite_data_files` is NOT one of them.**
- **The Trino `optimize` procedure accepts ONLY `file_size_threshold` argument** — NOT `sort_order`.
- **The correct Trino 467 path is:** `ALTER TABLE foo SET PROPERTIES sorted_by = ARRAY['plan_type']` then `ALTER TABLE foo EXECUTE optimize` (sorted_by table property + EXECUTE optimize, supported since release 412 via PR #14891).
- An engineer running the responder's syntax on Trino 467 will get a procedure-not-found / unknown-argument error. This is a load-bearing fix-recommendation that breaks user actions.

### Verdict
PASS but below STRONG. Right diagnosis on bloom-filter version-gate (parquet_bloom_filter_columns Trino 469+) + right Spark write-time alt — but the Trino-side clustering FIX names a Spark procedure as Trino EXECUTE syntax. Technical accuracy and practical applicability both suffer.

---

## Q2 — Partitioning != access control (Multi-tenant analytics)

**Scores: 5.0 / 4.5 / 5.0 / 4.5 — avg 4.75 STRONG PASS**

### What landed
- **Partitioning = storage layout WHERE data sits, NOT who can read** — CORRECT canonical framing.
- **SELECT on base table returns all tenants regardless of partition** — CORRECT (no row filter at storage layer).
- **Enforcement at Trino engine via JWT auth + OPA authz** — CORRECT and matches prod_info.md exactly.
- **Per-tenant views with hardcoded WHERE tenant_id + REVOKE base + GRANT view** — CORRECT canonical isolation pattern.
- **OPA checks JWT tenant claim** — CORRECT for prod stack.
- **MinIO direct S3 creds bypass entirely** — CORRECT and CRITICAL security callout.
- **Partition pruning = perf optimization NOT security boundary** — CORRECT (sensitive callout: engineer confusing "I partitioned by tenant_id so tenants are isolated" with security is the typical bug).
- **External governance doc per prod_info.md correctly deferred** — CORRECT.

### Verdict
STRONG PASS. Right framing, right enforcement stack, right MinIO-bypass warning, right external-governance-doc deferral. Matches prod_info.md precisely.

---

## Q3 — No indexes in Iceberg (Query performance basics)

**Scores: 4.0 / 4.5 / 4.0 / 4.5 — avg 4.25 PASS**

### What landed
- **No CREATE INDEX in Iceberg/Trino by design** — CORRECT (Iceberg considered and rejected secondary indexes for append-only model).
- **Index maintenance expensive in append-only** — CORRECT framing.
- **Substitutes: partition pruning primary, sort order, per-column min/max manifest stats free** — CORRECT.
- **Selective filter NOT full scan if partitioned/sorted** — CORRECT.
- **If physicalInputDataSize huge cause is unpartitioned+unsorted random clustering, fix compaction+sort** — CORRECT.

### Minor flag (not fully deducted)
- Responder references "sort order via rewrite_data_files" — echoes the Q1 procedure-name confusion. Framing was more conceptual ("achievable via X procedure") rather than recommending a specific syntax form, so didn't flag as NEW confident-inaccuracy here. But pattern is concerning.

### Verdict
PASS (below STRONG). Right framing, right substitutes, slightly weaker on the concrete next-step due to Q1 echo.

---

## Q4 — Federated JOIN + dynamic filtering (Trino federation)

**Scores: 5.0 / 4.5 / 5.0 / 4.5 — avg 4.75 STRONG PASS**

### What landed
- **JOIN runs on Trino workers, neither Postgres nor Iceberg sees other side** — CORRECT canonical federation framing.
- **WHERE plan_type='enterprise' pushes to Postgres returning only those rows** — CORRECT (equality on VARCHAR pushes by default).
- **Postgres small side becomes build hash, Iceberg probe** — CORRECT canonical execution.
- **DF derives account_id set after build side, pushes to Iceberg scan, prunes files via min/max** — CORRECT.
- **DF default-on Trino 467** — **VERIFIED** against trino.io/docs/current/admin/dynamic-filtering.html ("Dynamic filtering is enabled by default").
- **INNER/RIGHT only, not LEFT/FULL** — **VERIFIED** ("Currently inner and right joins with =, <, <=, >, >=, or IS NOT DISTINCT FROM join conditions, and semi-joins with IN conditions are supported").
- **iceberg.dynamic-filtering.wait-timeout default 1s, increase for large dimensions** — **VERIFIED** against trino.io/docs/current/connector/iceberg.html (default 1s).
- **Verify EXPLAIN ANALYZE dynamicFilterSplitsProcessed > 0** — CORRECT canonical verification recipe.

### Verdict
STRONG PASS — best federation answer in many iterations. All version-specific facts verified against current Trino docs.

---

## Pattern across all four answers

| Q | Score | Verdict |
|---|---|---|
| Q1 | 3.75 | PASS (below STRONG) — NEW confident-inaccuracy: Spark `rewrite_data_files(sort_order=>ARRAY[...])` syntax presented as Trino-467 EXECUTE form |
| Q2 | 4.75 | STRONG PASS — partitioning != security, JWT+OPA, per-tenant views, MinIO bypass warning all correct |
| Q3 | 4.25 | PASS — no-CREATE-INDEX framing correct; minor Q1 echo on rewrite_data_files naming |
| Q4 | 4.75 | STRONG PASS — best federation answer in many iters; DF mechanics + 1s default + INNER/RIGHT only all verified |

**Average 4.375 PASS** — sixteenth consecutive overall PASS, step-DOWN -0.1875 from iter416 4.5625. **Myth-buster zero-confident-inaccuracy streak broken at 2.**

**Trajectory iter394-417:** `4.75P/3.125F/4.3125P/4.375P/4.34375P/4.09375P/4.0625P/3.8125F/4.59375P/3.875F/4.25P/4.6875P/4.40625P/4.625P/4.0625P/4.125P/4.5625P/4.0P/4.219P/4.625P/4.21875P/4.0625P/4.625P/4.5625P/**4.375P**`.

**Topic status updates:**
- Query performance regression diagnosis: 4.5957/9 -> 4.5314/10 (Q1 3.75 well below avg, nudge DOWN -0.0643).
- Multi-tenant analytics: 4.4527/146 -> 4.4549/147 (Q2 4.75 above avg, nudge UP +0.0022).
- Query performance basics: 4.4445/10 -> 4.4314/11 (Q3 4.25 below avg, nudge DOWN -0.0131).
- **Trino federation: 4.4880/272 -> 4.4889/273** (Q4 4.75 above 4.5 threshold, nudge UP +0.0009; topic now 0.0111 below threshold; **17th consecutive iter below threshold**).

---

## Teacher actions next (iter 418)

1. **HIGH — Engine-confusion fix for resource 17 + resource 18:** add explicit "Trino ALTER TABLE EXECUTE procedures vs Spark CALL procedures" disambiguation table:
   - **Trino EXECUTE-supported:** `optimize` (file_size_threshold only), `optimize_manifests`, `expire_snapshots`, `remove_orphan_files`, `drop_extended_stats`
   - **Spark CALL-supported (NOT Trino):** `rewrite_data_files(strategy=>'sort', sort_order=>'col ASC')`, `rewrite_manifests`, `expire_snapshots(retain_last=>..., clean_expired_metadata=>...)`, `rewrite_position_delete_files`, `migrate`, `snapshot`
   - **The Trino-467 path to cluster files by a column is:** `ALTER TABLE foo SET PROPERTIES sorted_by = ARRAY['col']` then `ALTER TABLE foo EXECUTE optimize` — NOT `rewrite_data_files(sort_order => ...)`.
   - Add explicit "DO NOT use Spark CALL syntax for Trino EXECUTE" callout with engine-error example.

2. **MEDIUM — Trino federation topic threshold-push continuation.** Q4 4.75 helped (+0.0009); sustained 4.7+ federation answers continue to be needed. Topic 0.0111 below threshold; still 17 consecutive iters below. Continue auditing resource 22 for any remaining myth-buster gaps that could be elevated to leading callouts.

3. **LOW — Carry-forward backlog:** HMS->Nessie write-freeze alternative; branches-vs-expire_snapshots 3rd-angle; Snapshot vs serializable phantom-row 3rd-angle; Window NULL 2nd-angle calendar-dim densification; Iceberg v3 deletion vectors timeline; MERGE rollback; OPA-override timeout; schema registry compat; JWT+OPA concurrency.

---

## Judge probe targets next (iter 418)

1. **HIGH — Q1 rewrite_data_files Trino-syntax re-probe (durability check on iter418 teacher fix):** "I ran `ALTER TABLE foo EXECUTE rewrite_data_files(sort_order => ARRAY['plan_type'])` on Trino 467 and got an error — what's wrong, what's the correct syntax?" — probes responder now correctly disambiguates Spark CALL vs Trino EXECUTE procedures and gives the sorted_by + EXECUTE optimize path.

2. **HIGH — Trino federation threshold-push 4th-angle** — different shape than iter417 Q4's DF (e.g., cross-catalog JOIN pushdown semantics for non-equality predicates, schema-evolution-with-pushdown when Postgres ADDs a new column, OR-with-mixed-types pushdown, multi-catalog 3-way JOIN execution location).

3. **MEDIUM — Iceberg branches-vs-expire_snapshots 3rd-angle** — still pending: "After running expire_snapshots, an old snapshot I thought was branch-protected is gone — why?" probes legitimate failure modes.

4. **MEDIUM — Snapshot vs serializable phantom-row 3rd-angle** — still pending.

5. **MEDIUM — HMS->Nessie 2nd-angle for write-freeze alternative** — still pending.

6. **MEDIUM — Window NULL 2nd-angle (calendar-dim LEFT JOIN densification)** — still pending.

7. **LOW — Iceberg v3 deletion vectors timeline** carry-forward.

---

## Critical message to teacher for iter 418: the engine-confusion sub-flavor needs an explicit disambiguation table

The iter417 result is a setback after 2 clean iters (iter415 + iter416). The Q1 inaccuracy is the engine-confusion sub-flavor of the recurring confident-inaccuracy pattern — Spark CALL procedure syntax presented as Trino EXECUTE syntax. The fix is an explicit disambiguation: a leading "Trino EXECUTE procedures vs Spark CALL procedures" table in resources 17/18 with the Trino-467-valid clustering recipe (sorted_by table property + EXECUTE optimize) as the leading recommendation. The myth-buster pattern from iter415-416 needs ONE more dimension: not just "does X exist on Trino 467" but also "is the X syntax I'm typing Trino syntax or Spark syntax". Add that dimension and the next durability re-probe should land clean.
