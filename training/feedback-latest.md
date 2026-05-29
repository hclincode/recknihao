# Judge Feedback — Iter 400

**Average: 3.8125 FAIL** (Q1 4.0 PASS, Q2 3.625 FAIL)

Pattern this iteration: the responder nailed the *what* (factual claims correct on both questions) but consistently lost points on *how* (no shown YAML / ALTER syntax) and *what-it-means-for-a-beginner* (jargon used without unpacking). This is the same gap that has appeared 4+ times in the last 10 iterations: correct mechanism + missing concrete syntax + unglossed jargon.

---

## Q1 — Iceberg format v1 vs v2 → 4.0 PASS

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.5 | v1 append-only, v2 delete-files-for-DML, v1→v2 metadata-only — all correct against Iceberg 1.5.2 spec. "~2-3% overhead" is hand-wavy but in-bounds for sparse delete tables. |
| Beginner clarity | 3.5 | "delete files," "metadata-only," "MERGE" used without glossing. No example. |
| Practical applicability | 4.0 | Clear decision rule (v2 unless pure append; upgrade is free). Missing `ALTER TABLE ... SET TBLPROPERTIES('format-version'='2')` exact syntax. |
| Completeness | 4.0 | Covers when, upgrade path, overhead. Missing CoW vs MoR (`write.delete.mode` / `write.update.mode` / `write.merge.mode` — the real v2 tuning knob), v3 deletion vectors, prod-stack compat note (Iceberg 1.5.2 + Trino 467 both write v2 by default). |

## Q2 — dbt + Trino for Iceberg → 3.625 FAIL

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.5 | All four gotchas correct: `incremental_strategy` default `append`, `on_schema_change` default `ignore`, no MATCH conditional on merge, `insert_overwrite` Spark-only. dbt-trino is the right adapter. |
| Beginner clarity | 3.0 | Dense gotcha list with no unpacking. "MATCH," "merge strategy," "insert_overwrite" assumed familiar. No YAML shown. |
| Practical applicability | 3.5 | References "canonical config template" + "maintenance schedule" but doesn't show them. Engineer needs to look it up. Production-fit (dbt is permitted per prod_info.md). |
| Completeness | 3.5 | Missing: `unique_key` requirement (merge silently degrades to append without it), `incremental_predicates` for partition pruning, `partition_by` model config, `post-hook` pattern for `optimize` + `expire_snapshots`, dbt-trino version pinning. |

---

## Teacher actions next (iter 401)

1. **HIGH (Q2 root cause)** — Expand `resources/` dbt-trino guide with **actual YAML examples** for each of the four gotchas:
   - `incremental_strategy: 'merge'` + `unique_key: 'id'` + `merge_update_columns: [...]` (fix the conditional-update gap)
   - `on_schema_change: 'append_new_columns'` or `'sync_all_columns'` (fix silent data loss)
   - `incremental_predicates: ["DBT_INTERNAL_DEST.day >= current_date - 7"]` (partition pruning at production scale)
   - Explicit "do NOT use `insert_overwrite`" callout with the `delete+insert` substitute
2. **HIGH (Q2 maintenance gap)** — Add canonical `post-hook` snippet showing `ALTER TABLE {{ this }} EXECUTE optimize` and `ALTER TABLE {{ this }} EXECUTE expire_snapshots(retention_threshold => '7d')` so the "maintenance schedule" claim is concrete.
3. **MEDIUM (Q1 row-level mode gap)** — In Iceberg format-version resource, add the CoW vs MoR decision table tied to `write.delete.mode`, `write.update.mode`, `write.merge.mode` — this is the actual v2 tuning knob the responder missed.
4. **MEDIUM (Q1 prod-stack tie)** — Add explicit Iceberg 1.5.2 + Trino 467 default behavior note: both write v2 by default, so the question "should I use v2" is moot for *new* tables in this stack — the live question is "do I need to upgrade legacy v1 tables and which mode (CoW/MoR) should I pick for my write rate."
5. **LOW (beginner clarity recurring)** — Standing teacher prompt: gloss any of these on first use — "delete files (positional vs equality)," "metadata-only (no data file rewrite)," "MATCH (the WHEN MATCHED THEN UPDATE branch of a SQL MERGE)," "merge strategy (dbt's incremental mode that does an upsert via SQL MERGE INTO under the hood)."

## Judge probe targets next (iter 401)

1. **2nd-angle v1 vs v2** — "I have a legacy v1 table receiving DELETE statements from a dbt model — what happens?" (probes whether responder knows DML fails on v1 or whether engine silently rewrites whole partitions, and whether they recommend the v1→v2 upgrade as the fix).
2. **2nd-angle dbt-trino merge** — "My dbt incremental merge model is producing duplicates — what should I check?" (probes whether responder knows `unique_key` is required and `incremental_strategy` defaults to `append`).
3. **CoW vs MoR 3rd-angle** — "MERGE INTO is rewriting 80GB per run on a 200GB table — how do I switch to row-level deletes?" (probes `write.merge.mode=merge-on-read` + delete file format).
4. **Carry-forward backlog** — write.isolation-level 2nd-angle, SHOW SESSION/catalog-prefix 2nd-angle, HMS→Nessie no-downtime, SPILL_FAILED 60GB at 200GB cap, MERGE INTO rollback, OPA-override timeout, schema registry compat, EXPLAIN TYPE IO + VALIDATE, result caching 2nd-angle, Iceberg branches fast_forward 2nd-angle, JWT+OPA concurrency, partition spec migration + rewrite_data_files, Iceberg tagging 3rd-angle, fs.cache 3rd-angle JMX, bucket(tenant_id) high-cardinality 2nd-angle, PERCENT_RANK/NTILE 3rd-angle, RANGE INTERVAL gap-day semantics.

## Trajectory iter 391–400

4.75 → 4.125 → 3.9375 FAIL → 4.625 → 4.75 → 3.125 FAIL → 4.3125 → 4.375 → 4.0625 → **3.8125 FAIL**

Three FAILs in the last 10 iterations all share the same shape: correct mechanism, missing concrete syntax/YAML, unglossed beginner-jargon. The Q2 dbt-trino failure is the most actionable — a one-page "dbt-trino Iceberg canonical config" resource with the YAML inline would likely have flipped this to PASS.
