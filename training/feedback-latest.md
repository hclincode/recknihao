# Iter 683 — Judge Feedback (EXTENDED PHASE)

## Per-question scoring (Acc/Comp/Clar/Act each 1-5)

### Q1 — dbt snapshot SCD2 for plan_tier (track historical changes per customer, valid-from/to ranges, source table only has current state)
**Responder answer summary**: `{% snapshot users_snapshot %}` with `target_schema='analytics'`, `unique_key='id'`, `strategy='timestamp'`, `updated_at='updated_at'`, SELECT `id AS user_id, email, plan_tier, updated_at FROM source('postgres','users')`; run `dbt snapshot`; meta columns `dbt_valid_from`/`dbt_valid_to`(NULL=current)/`dbt_scd_id`/`dbt_is_deleted`; as-of query `WHERE ts >= dbt_valid_from AND (dbt_valid_to IS NULL OR ts < dbt_valid_to)`; requires reliable `updated_at` that advances on change.

**DIALECT VERIFICATION** (docs.getdbt.com 2026-06-08):
- Snapshot meta-column names — CORRECT verbatim (dbt_scd_id / dbt_updated_at / dbt_valid_from / dbt_valid_to default four; dbt_is_deleted conditional on `hard_deletes='new_record'` in dbt 1.9+).
- Strategy=timestamp + updated_at config — CORRECT (docs.getdbt.com/reference/resource-configs/updated_at).
- As-of validity-window pattern (ts >= valid_from AND (valid_to IS NULL OR ts < valid_to)) — CORRECT half-open interval.
- dbt-trino supports snapshots — CONFIRMED at docs.getdbt.com/reference/resource-configs/trino-configs.
- **MATERIAL DEFECT**: `unique_key='id'` paired with `SELECT id AS user_id` — verified via docs.getdbt.com/docs/build/snapshots that `unique_key` refers to a column in the SELECT OUTPUT, not the source table. The SELECT output column is `user_id` (because the responder aliased `id AS user_id`), so `unique_key='id'` would NOT resolve. Correct config would be either `unique_key='user_id'` (matching alias) or drop the alias and write `SELECT id, email, plan_tier, updated_at FROM ...` with `unique_key='id'`. This is a copy-paste-and-it-breaks defect.

Acc 3.5 / Comp 4 / Clar 4 / Act 3.5 — **avg 3.75**
- -1.5 Acc for the unique_key/alias mismatch that would runtime-fail when run as-written.
- Otherwise meta-columns + as-of pattern + strategy choice + caveat about updated_at advancing on change are all correct.

### Q2 — dbt source freshness on raw_orders (auto warn/fail if stale >1 day)
**Responder answer summary**: `sources.yml` with `sources: - name: raw_pipeline, schema: raw, config: {loaded_at_field: updated_at, freshness: {warn_after: {count:12,period:hour}, error_after: {count:24,period:hour}}}, tables: [raw_orders]`; CI runs `dbt source freshness` (exits non-zero on error_after) THEN `dbt build`; notes `dbt source freshness` is a SEPARATE command NOT run by `dbt run`/`dbt build`; `loaded_at_field` must be stamped per row.

**DIALECT VERIFICATION** (docs.getdbt.com/reference/resource-properties/freshness 2026-06-08):
- Both `loaded_at_field` and `freshness` nested under `config:` — CORRECT for dbt v1.9+ (the modern shape).
- `warn_after: {count, period}` + `error_after: {count, period}` with period in {minute, hour, day} — CORRECT.
- `dbt source freshness` is a SEPARATE command, NOT part of `dbt run` or `dbt build` — CORRECT and well-flagged.
- Per-row stamped `loaded_at_field` requirement on dbt-trino (warehouse-metadata fallback NOT supported) — CORRECT.
- Exit-non-zero-on-error_after for CI gating — CORRECT.

Acc 5 / Comp 4.5 / Clar 4.5 / Act 5 — **avg 4.75**
- -0.5 Comp/Clar for not noting that the freshness state file is `target/sources.json` (not `manifest.json`) and not showing the `dbt build --select source_status:fresher+` slim-CI variant — but the answer is operationally complete for the question asked.

### Q3 — Storage tiering / cold data cost on 3yr Iceberg-on-MinIO history (rarely queried beyond 90 days)
**Responder answer summary**:
- Lever 1: `ALTER TABLE iceberg.analytics.events EXECUTE expire_snapshots(retention_threshold => '7d')` weekly (frees 10-40% first run).
- Lever 2: explicitly states "tiering to cheaper storage is NOT natively supported on Iceberg + MinIO". Options:
  - (a) `DELETE FROM events WHERE occurred_at < current_date - INTERVAL '90' DAY` then `expire_snapshots` + `remove_orphan_files`;
  - (b) `ALTER TABLE events EXECUTE optimize(file_size_threshold => '128MB') WHERE occurred_at >= current_date - INTERVAL '90' DAY` (compact recent partitions only);
  - (c) accept MinIO growth, ~$15-25/TB-month TCO.

**DIALECT VERIFICATION** (trino.io/docs/467/connector/iceberg.html 2026-06-08):
- **STORAGE-TIERING-NON-FABRICATED VERDICT: CONFIRMED CORRECT.** Responder explicitly disclaims native tiering on Trino+Iceberg+MinIO. NO fabricated `SET STORAGE TIER`, NO fabricated `storage_class`/`storage_tier` table property, NO fabricated `iceberg.storage-tier.*` catalog property. This is the key anti-fabrication outcome the rubric needed.
- `expire_snapshots(retention_threshold => '7d')` — CORRECT Trino 467 ALTER TABLE EXECUTE form, valid retention_threshold suffix.
- `remove_orphan_files` — CORRECT procedure name.
- `DELETE FROM events WHERE occurred_at < current_date - INTERVAL '90' DAY` — valid Trino DELETE on Iceberg with predicate; correctly paired with `expire_snapshots` to actually reclaim space (snapshot-pinned files do not free until expired).
- `optimize(file_size_threshold => '128MB') WHERE occurred_at >= current_date - INTERVAL '90' DAY` — VERIFIED via trino.io/docs/467 that the Iceberg connector's `optimize` ALTER TABLE EXECUTE form supports a WHERE clause whose predicate filters partitions, and `'128MB'` is the correct unit-suffixed DataSize literal (not bare bytes). VALID.
- ~$15-25/TB-month TCO — defensible order-of-magnitude for bare-metal MinIO on commodity storage (per prod_info.md the stack is on-prem MinIO).

Acc 5 / Comp 4 / Clar 4.5 / Act 4.5 — **avg 4.50**
- -1 Comp for not mentioning MinIO `mc ilm tier add` + `mc ilm rule add --transition-days N` as the canonical real-tiering path (the MinIO-object-lifecycle approach is documented in r16:519-541 and is the way to actually move cold data to a cheaper tier without DELETE). Lever 2 (a) is technically a deletion, not a tier-down, so the answer leans on retention rather than tiering. Still a sound, non-fabricated answer.

### Q4 — dbt seeds (load ~200-row country-code -> name CSV into warehouse via dbt)
**Responder answer summary**: `seeds/countries.csv` with `country_code,country_name` rows; optional `dbt_project.yml` `seeds: +column_types {country_code: varchar, country_name: varchar}`; run `dbt seed` (or `dbt build`); creates Iceberg table; reference via `{{ ref('countries') }}` in models; seed is truncate-and-reload on CSV change; seed-vs-source-vs-ingestion guidance.

**DIALECT VERIFICATION** (docs.getdbt.com/docs/build/seeds + docs.getdbt.com/reference/project-configs/seed-paths 2026-06-08):
- Default seed directory `seeds/` (since dbt 1.0, Dec 2021) — CORRECT.
- `dbt seed` command + `dbt build` includes seeds (`dbt run` does not) — CORRECT framing.
- `+column_types` under `seeds:` block in `dbt_project.yml` — CORRECT.
- Reference via `{{ ref('countries') }}` (basename, no `.csv`) — CORRECT.
- Truncate-and-reload semantics — CORRECT (docs verbatim: "dbt truncates the existing table and reinserts the data"). Responder also correctly notes structural changes need `--full-refresh`.
- Seed-vs-source-vs-ingestion right-tool-for-the-job guidance — CORRECT (lookup-small-static-rare-change is the dbt seed use case).

Acc 5 / Comp 5 / Clar 5 / Act 5 — **avg 5.00**

## Overall

| Q | Acc | Comp | Clar | Act | Avg |
|---|---|---|---|---|---|
| Q1 dbt snapshot SCD2 | 3.5 | 4.0 | 4.0 | 3.5 | **3.75** |
| Q2 dbt source freshness | 5.0 | 4.5 | 4.5 | 5.0 | **4.75** |
| Q3 storage tiering | 5.0 | 4.0 | 4.5 | 4.5 | **4.50** |
| Q4 dbt seeds | 5.0 | 5.0 | 5.0 | 5.0 | **5.00** |

**Per-Q overall avg**: (3.75 + 4.75 + 4.50 + 5.00) / 4 = **4.50**

**Dim-avg cross-check**: Acc (3.5+5+5+5)/4 = 4.625, Comp (4+4.5+4+5)/4 = 4.375, Clar (4+4.5+4.5+5)/4 = 4.50, Act (3.5+5+4.5+5)/4 = 4.50. Average of dims = (4.625+4.375+4.50+4.50)/4 = **4.50**. Agrees.

**GOVERNING LABEL = PASS** (overall 4.50 >= 3.5 by margin +1.00; per-Q quality-gate override NOT applied per directive; Q1 unique_key/alias mismatch flagged in prose only).

## Critical verdicts (per directive)

1. **Q3 STORAGE-TIERING-NON-FABRICATED VERDICT: CONFIRMED.** Responder explicitly disclaims that Trino+Iceberg+MinIO has no native storage-tiering feature. No fabricated DDL/properties. `expire_snapshots(retention_threshold => '7d')`, `remove_orphan_files`, `DELETE ... WHERE occurred_at < current_date - INTERVAL '90' DAY`, and `optimize(file_size_threshold => '128MB') WHERE occurred_at >= ...` (partition-scoped) all valid Trino 467 Iceberg connector syntax verified against trino.io/docs/467. `'128MB'` is unit-suffixed DataSize (correct, not bare bytes).

2. **Q1 unique_key='id' vs `SELECT id AS user_id` MISMATCH: MATERIAL.** Verified via docs.getdbt.com/docs/build/snapshots that `unique_key` refers to a column in the SELECT output. The responder's SELECT aliases `id AS user_id`, so the output has `user_id`, not `id`. Running the snapshot as-written would fail to resolve `unique_key='id'`. -1.5 Acc penalty (3.5 not 5) but doesn't kill the overall PASS — Q1 still 3.75 above 3.5 floor.

3. **Q2 freshness config nesting under `config:` block — VALID dbt 1.9+ form** (docs.getdbt.com/reference/resource-properties/freshness verbatim). `dbt source freshness` separate-command framing CORRECT.

4. **Q4 dbt seed mechanics — ALL VALID** against docs.getdbt.com/docs/build/seeds.

## Flagged weak answers

- **Q1 (3.75)**: passes the 3.5 floor but is the weakest of the four. The `unique_key`/alias mismatch is the kind of subtle defect that breaks copy-paste deployments. Worth a teacher inoculation pass.

## Teacher feedback (concrete, actionable)

**Optional FIX-A candidate (Q1 unique_key/alias)**: In r09 (the SCD2 / dbt snapshot canonical), add an explicit DO-NOT-WRITE / inoculation note:

> The `unique_key` config refers to a column in the SELECT output of the snapshot query, NOT the source table. If you alias `id AS user_id` in the SELECT, you must write `unique_key='user_id'`, not `unique_key='id'`. Easiest: don't alias the key column.

Place a worked snippet showing both the right and wrong forms side-by-side, since the responder's failure mode here is a near-miss that ships as a runtime error. Anchor the keyword block with phrases like "snapshot unique_key alias", "unique_key column not found", "dbt snapshot key vs source column".

**Other notes**:
- Q3 nailed the non-fabrication of native tiering. Resource r16:499-628 canonical is doing exactly its job. Optional belt-and-suspenders: add a one-line cross-ref so the `mc ilm tier add` MinIO-object-lifecycle path is shown as the FIRST lever for true tier-down (not retention), keeping retention-via-DELETE as the secondary lever.
- Q2 and Q4 are clean 4.75 and 5.00 — no edits needed.
- **iter684 directive: DEFAULT NO-OP / DURABILITY-BREADTH** is the recommended path UNLESS the teacher chooses to deploy FIX-A on Q1 unique_key/alias inoculation in r09. Given Q1 still cleared the 3.5 floor and the overall iteration is PASS at 4.50 with three strong answers, no-op is defensible; FIX-A is low-priority belt-and-suspenders.
- Federation NOT probed this iter — 39-iter ZERO probe streak (iter645-683) on the thinnest-margin topic. Consider a federation re-probe in iter685 or beyond once any Q1 inoculation lands.
- DO NOT bump training/state.json (teacher already set to 683).
- DO NOT touch r22 federation guardrails.
- DO NOT rewrite iter534-682 locks (iter681 CREATE-TABLE-no-PRIMARY-KEY FIX-A HELD, iter679 max_recursion_depth HELD, all earlier locks HELD).

## Trajectory

iter659 -> iter683: 5.00 / 5.00 / 4.5625 / 5.000 / 3.656 / 4.5625 / 4.5625 / 4.375 / 4.125 / 4.9375 / 5.000 / 4.9375 / 5.000 / 4.500 / 4.875 / 4.78 / 4.5625 / 4.875 / 4.375 / 5.000 / **4.500** — sustained 4.0+ across 26 of last 26 iterations; mild dip from iter682's 5.00 driven entirely by Q1 unique_key/alias responder-copy-paste-fail.

**OVERALL: 4.50 PASS — three strong answers (Q2 freshness 4.75 + Q3 storage-tiering 4.50 NON-FABRICATED + Q4 seeds 5.00) + one weak-but-passing Q1 (3.75, unique_key='id' fails to resolve against aliased SELECT output column `user_id`); Q3 storage-tiering non-fabrication CONFIRMED; iter684 recommended DEFAULT NO-OP (optional low-priority FIX-A on r09 unique_key/alias inoculation); consider federation re-probe (39-iter ZERO streak, thinnest rubric margin).**
