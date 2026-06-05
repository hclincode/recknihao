# Judge Feedback — Iter 475 (end-of-iteration, extended phase)

## Verdict: STRONG PASS — 4.6953 overall (74th consecutive extended-phase PASS)

| Q | Topic | Accuracy | Completeness | Clarity | Actionability | Avg | Verdict |
|---|---|---|---|---|---|---|---|
| Q1 | Query perf basics — `join_distribution_type` re-probe (regression fix confirmation) | 4.875 | 4.5 | 4.625 | 4.75 | **4.6875** | STRONG PASS |
| Q2 | dbt snapshots SCD2 — timestamp vs check (2nd angle) | 4.75 | 4.25 | 4.625 | 4.625 | **4.5625** | STRONG PASS |
| Q3 | Oracle PL/SQL→Trino — DECODE NULL → searched CASE | 4.875 | 4.625 | 4.75 | 4.75 | **4.75** | STRONG PASS |
| Q4 | Iceberg maintenance — `$files` SQL inspection + optimize | 4.875 | 4.75 | 4.625 | 4.875 | **4.78125** | STRONG PASS |

**Overall avg: 4.6953125** — STRONG PASS. Highest score since iter469 (4.648).

---

## Critical confirmation: `join_distribution_type` regression FIX LANDED

**iter474 fab** = `SET SESSION distributed_join_distribution_type = 'partitioned'` (does not exist on Trino 467; "Session property does not exist" error).

**iter475 Q1 responder output** = `SET SESSION join_distribution_type = 'PARTITIONED'` — **exact canonical form, no `distributed_` prefix, three accepted values `PARTITIONED | BROADCAST | AUTOMATIC` (default AUTOMATIC) correctly listed, dbt pre_hook form correctly stated, no-query-hints fact correctly held**.

Verified against:
- https://trino.io/docs/current/optimizer/cost-based-optimizations.html (session property `join_distribution_type` with values AUTOMATIC/BROADCAST/PARTITIONED)
- https://trino.io/docs/current/admin/properties-general.html (config property hyphenated form `join-distribution-type`)

**Iter475 EDIT 1 (new 8-row DO-NOT-WRITE matrix in r24)** = LANDED CLEAN in a single iteration of corrective action. The responder did not synthesize ANY of the 8 banned variants (`distributed_join_distribution_type`, `distributed_joins`, `distributed-joins-enabled`, `distributed_join`, `broadcast_join_distribution_type`, `hash_join_distribution_type`, `join_distribution`, `join_strategy`). The pre-emptive ban-by-keyword strategy worked — when the responder reached for the property name, the canonical token surfaced cleanly without prefix splice.

---

## Fabrication audit — ZERO load-bearing fabs across Q1–Q4

**Q1**: property name, accepted values, default — all canonical. No prefix splice. No dead-legacy form. Clean.

**Q2**: strategy names (`timestamp`, `check`), `check_cols` list form, metadata cols (`dbt_valid_from`, `dbt_valid_to`, `dbt_scd_id`, `dbt_is_deleted` 1.9+) — all verified per docs.getdbt.com/docs/build/snapshots + /reference/resource-configs/check_cols. No `dbt_is_current` fab (correctly absent). No fake config-key like `compare_cols`/`monitor_cols`/`watch_cols`.

**Q3**: Oracle DECODE NULL=NULL semantic (DECODE uses IS-NOT-DISTINCT-FROM internally, treats two NULLs as equal — verified per docs.oracle.com/en/database/oracle/oracle-database/26/sqlrf/Nulls.html + modern-sql.com/feature/is-distinct-from + sqlines DECODE-NULL-issue page). Trino simple `CASE col WHEN NULL` `=`-semantics → UNKNOWN → silent ELSE fallthrough — correct per standard ANSI. Searched-CASE-with-IS-NULL fix — correct. COALESCE sentinel alternative — valid Trino syntax. No `DECODE` keyword claimed on Trino. No over-claim of `IS NOT DISTINCT FROM` operator availability.

**Q4**: `$files` column names (`content`, `file_size_in_bytes`, `file_path`, `file_format`, `partition`) — all in the canonical $files column list per trino.io/docs/current/connector/iceberg.html. Content codes (0=DATA, 1=POSITION_DELETES, 2=EQUALITY_DELETES) — verified per Iceberg spec + Trino GH issue #28910. `EXECUTE optimize(file_size_threshold => '128MB')` — exact named-parameter syntax (`=>`, string-with-unit value), default 100MB threshold per Trino Iceberg connector docs. Sibling metadata tables `$snapshots/$history/$manifests/$partitions` — all real per trino.io Iceberg connector docs. Double-quoting `"fct_events$files"` — correct per Trino identifier rules. No fake `$delete_files` table, no fake `manifest_size_in_bytes`-on-$files column, no fake `file_age_days` column.

---

## Minor completeness gaps (not fabs, not load-bearing)

| Q | Gap | Impact |
|---|---|---|
| Q2 | Did not explicitly show the `updated_at: column_name` config key for the timestamp strategy. Did not call out the `check_cols='all'` shorthand variant. | Engineer still gets correct strategy choice + check_cols list pattern; would need to glance at docs.getdbt.com for the exact `updated_at:` key spelling. Per directive, minor-only. |
| Q4 | Did not flag that `EXECUTE optimize` only bin-packs within the existing partition spec (does NOT rewrite to a new spec — that requires Spark `rewrite_data_files` with `rewrite-all=true`). | Out-of-scope for this question's "inspect files via SQL" framing — not a deduction. |

---

## Teacher actions for iter476 (breadth design; NO dedicated federation probe)

### PRIMARY — breadth design across 4 angles

Federation row (4.49944/310) sits 0.0006 below the 4.5 raised threshold. A single thin probe locks or breaks it; per the iter472/473/474/475 pattern, **NO dedicated federation probe** this iter. Let the count grow naturally if federation surfaces incidentally in a multi-topic question.

Suggested 4-question breadth slate for iter476:

1. **dbt snapshots SCD2 — 3rd-angle hardening re-probe**. Topic just promoted to PASSED at 2 datapoints (4.5625 avg). A 3rd angle would harden the lock. Candidate angles: (a) `hard_deletes = invalidate | new_record | ignore` config (1.9+), (b) `target_schema` / `target_database` placement vs `+schema:` in dbt_project.yml, (c) `snapshot_meta_column_names` config to rename `dbt_valid_from` → custom column, (d) `invalidate_hard_deletes: true` legacy flag (pre-1.9) vs new `hard_deletes:`. Pick ONE — phrase it differently from Q2 (don't repeat timestamp-vs-check).

2. **Trino-specific angle with low recent coverage**. Candidates: (a) `SHOW STATS FOR table` output interpretation (NDV / data_size / nulls_fraction columns and how CBO consumes them), (b) `EXPLAIN ANALYZE` runtime stats vs `EXPLAIN` plan-only distinction, (c) catalog-level `iceberg.expire-snapshots.min-retention` floor that gates `EXECUTE expire_snapshots(retention_threshold => 'Xd')`, (d) `system.runtime.queries` table for live-query inspection on cluster.

3. **Oracle PL/SQL → dbt/Trino migration — non-NULL-semantics angle**. Topic at 4.5580/49 with stable PASS history. Candidates: (a) Oracle `CONNECT BY ... PRIOR` recursive query → Trino `WITH RECURSIVE`, (b) Oracle sequences (`SEQ.NEXTVAL`) → Trino UUID/row_number/dbt `dbt_utils.surrogate_key` patterns (Trino has no native sequence object), (c) Oracle `PIVOT (sum(x) FOR col IN (...))` → Trino conditional-aggregation form (Trino does NOT have PIVOT operator on 467), (d) Oracle `LISTAGG(x, ',') WITHIN GROUP (ORDER BY y)` → Trino `array_join(array_agg(x ORDER BY y), ',')`.

4. **Wildcard breadth probe — low-count topic re-probe**. Candidates: (a) `dbt sources / source freshness` (3 probes, 4.219 avg — could use a re-probe), (b) `Storage tiering on Trino+Iceberg+MinIO` (2 probes, 4.25 avg — could use a re-probe specifically testing the MinIO `--transition-days N` age-only mechanism after iter475 EDIT 2's "NOT access time" callout), (c) `Improving complex SQL performance on Trino with dbt` (4 probes, 4.7781 avg — strong topic, low count). The storage-tiering re-probe is especially valuable as a confirmation that the "NOT access time / NOT access pattern" pre-emptive callout in r16 lands when an engineer asks about MinIO tiering specifically.

### SECONDARY — citation-hygiene watchlist for iter476

Items to flag if they appear in any responder output:

- Any `distributed_*` prefix on `join_distribution_type` (regression watchlist — iter474 fab class, iter475 confirmed-fixed; keep on watchlist for at least 3 iters of clean re-probes before retiring).
- Any `WITH (SECURITY DEFINER)` form on CREATE VIEW (iter468 syntax slip, fixed iter469, kept on watchlist).
- Any `MinIO tiers based on access time / access pattern / last-read` framing (iter474 minor slip, iter475 teacher pre-empted with explicit "NOT access time" callout in r16 — watch if it resurfaces).
- Any `column_order` Iceberg table property (iter470 fab — does not exist).
- Any `parse_date` Trino function (iter471 fab — Trino has `date_parse` / `parse_datetime` / `from_iso8601_date`, NO `parse_date`).
- Any `SET PARTITION SPEC` Spark-ism on Trino (iter471 fab — correct is `ALTER TABLE t SET PROPERTIES partitioning = ARRAY[...]`).
- Any `WHEN NOT MATCHED BY SOURCE` MERGE clause claimed on Trino (Snowflake/Spark-only; Trino MERGE supports WHEN MATCHED / WHEN NOT MATCHED only).
- Any `parquet_bloom_filter_columns` table property claimed as settable on Trino 467 (it is 469+, per PR #24573 merged Dec 25 2024).

### TERTIARY — resource hygiene (no urgent edits required)

Iter475 EDITS 1 (r24 DO-NOT-WRITE matrix for fab session-property names) and 2 (r16 "NOT access time" callout) both landed cleanly. No reconciliation work needed for iter476.

If teacher has capacity for a non-urgent resource patch, candidates:
- Add a brief Oracle DECODE-NULL-semantic callout to r27 (Oracle PL/SQL → dbt/Trino migration) reinforcing the searched-CASE-with-IS-NULL pattern for DECODE migration near other Oracle→Trino function-mapping content (helps findability).
- Confirm r17 (Iceberg table maintenance) lists `$files` column inventory with content-code legend (0=DATA / 1=POSITION_DELETES / 2=EQUALITY_DELETES) near the EXECUTE optimize section — Q4 responder produced this correctly suggesting findability is fine, but reinforcing co-location helps future maintenance queries.

---

## Closing summary

Iter475 is a textbook regression-fix iteration: the iter474 `distributed_join_distribution_type` fab closed in one iter via a targeted DO-NOT-WRITE matrix in r24, and the responder produced canonical `join_distribution_type` cleanly on the very next re-probe. Q2–Q4 all STRONG PASS with zero fabs and only minor completeness gaps. dbt-snapshots-SCD2 micro-topic promoted to PASSED at 2 distinct datapoints. Federation row unchanged per directive. Citation-hygiene streak fully restored.

Iter476 priority: breadth design (no federation probe), optional 3rd-angle hardening on dbt-snapshots-SCD2, optional MinIO-tiering 2nd-angle confirmation of the iter475 "NOT access time" callout.
