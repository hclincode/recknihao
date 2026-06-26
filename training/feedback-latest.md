# Iter1119 — Judge Feedback

**Overall verdict: 5.00 STRONG PASS (NO-OP)** (margin +1.50 above 3.5). Thin-margin sweep — all four targeted rows lift cleanly. Q1 (longest run of consecutive CALENDAR MONTHS active per subscription — novel domain, NOT login-days; the iter1118-flagged synthesis-transfer probe) lands the gaps-and-islands skeleton correctly with the right `date_trunc('month',...)` collapse FIRST so `date_diff('month', LAG, cur)` operates on month-START dates (no partial-month miscount). Q2 (MinIO+Trino+Iceberg on-prem storage tiering — thinnest row at 3.5625/6) is the iter1100/1102 storage-tiering FIX-A re-confirm: tiering = MinIO mc ilm (NOT Trino DDL), AGE-based via `--transition-days` (NOT read-frequency aware), app-layer hot/archive UNION ALL view for access-pattern awareness. Q3 (dbt model contracts on dbt-trino+Iceberg) hits every contract semantic: enforced:true, build-time preflight on column-name+type, Compilation Error halts materialize, dbt-trino enforces ONLY not_null (primary_key/unique/check metadata-only). Q4 (Iceberg metadata-overhead cost drivers on flat-volume MinIO bill) lists the 4 canonical drivers in the right order with correct `$snapshots`/`$files` diagnostics and correct Trino-467-native EXECUTE procedure signatures.

---

## Source verifications (Trino 467 docs / dbt-trino docs / MinIO docs / pinned memory)

- **Q1 date_diff('month') on month-truncated dates**: trino.io/docs/current/functions/datetime.html — `date_diff(unit, t1, t2) -> bigint` returns whole units between t1 and t2. With both inputs collapsed via `date_trunc('month', payment_timestamp)` to month-start (first-of-month) dates, adjacent active months (e.g. 2024-01-01 → 2024-02-01) give `date_diff('month',...) = 1` exactly; a one-month skip (2024-01-01 → 2024-03-01) gives 2. The responder's `<> 1` gap test is therefore correct AND avoids the partial-month miscount r07 §3279 warns about for `date_diff('month')` on RAW dates (where 2024-01-31 → 2024-02-01 returns 1 despite being adjacent days). Truncating FIRST is the right order. Verified canonical.
- **Q1 SELECT DISTINCT to collapse multi-payments-per-month**: explicit "first collapse multi-payments-per-month so an active month appears once" requirement of the question — `SELECT DISTINCT subscription_id, date_trunc('month', payment_timestamp)` is the canonical Trino form (equivalent `GROUP BY subscription_id, date_trunc('month', payment_timestamp)` also works). Correct.
- **Q1 streak-id via cumulative SUM of gap-flag**: canonical gaps-and-islands; identical 3-CTE shape to iter1118 login-days but on a NOVEL domain (subscriptions+months). Skeleton transfers cleanly — confirms the iter1118 synthesis-transfer probe.
- **Q2 MinIO mc ilm AGE-based not access-frequency**: docs.min.io `mc ilm rule add --transition-days` — "specifies the number of calendar days from object creation after which MinIO marks an object as eligible for transition". Pure age-from-creation. NO `--access-since` / NO read-tracking / NO access-frequency filter. Verified via WebSearch this iter. Responder's "PURELY AGE-BASED, does NOT know which files belong to which table or how often read" is correct.
- **Q2 tiering not a Trino feature**: trino.io/docs/current/connector/iceberg.html — table properties include `format`, `partitioning`, `sorted_by`, `location`, etc., but NO `storage_class`/`tier`/`lifecycle` property. There is no `ALTER TABLE ... SET TIER` DDL. Tiering is purely an object-storage layer concern in this stack. Correct.
- **Q2 keep metadata/ prefix hot**: Iceberg's manifest-list / manifest / metadata.json files are read on EVERY query plan; tiering them off to a cold tier breaks query latency. Restricting the lifecycle rule to the `data/` prefix only is the standard production pattern. Correct.
- **Q2 app-layer hot/archive UNION ALL view for access-aware tiering**: pinned `r10` storage-tiering Mechanism C — split the table into `events_recent` (last 90d, on hot bucket) and `events_archive` (older, on cold bucket via separate catalog path or MinIO tier), wrap in a dbt view `UNION ALL`. This is the standard on-prem workaround for "tier by access". Correct.
- **Q3 dbt contract preflight**: docs.getdbt.com/docs/mesh/govern/model-contracts — "when building a model with a defined contract, dbt will run a preflight check to ensure that the model's query will return a set of columns with names and data types matching the ones you have defined". Build-time, before materialize. Compilation Error on mismatch halts the model AND downstream models (skipped). Responder correct.
- **Q3 dbt-trino only not_null enforced**: docs.getdbt.com/reference/resource-properties/constraints + dbt-trino adapter docs — "for Trino, only constraints with type as not_null are supported"; primary_key/unique/check/foreign_key are definable in YAML for documentation but NOT enforced at write time on dbt-trino+Iceberg (they're treated as metadata-only). Pair with `dbt test` for runtime validation. Responder correct.
- **Q3 Trino types not generic**: dbt-trino requires `data_type` strings to be Trino native (`BIGINT`, `VARCHAR`, `DECIMAL(18,2)`, `TIMESTAMP(6)`, etc.); generic `string`/`int`/`number` are NOT valid Trino types and the preflight will fail to match. Correct.
- **Q4 Iceberg cost driver ordering** (snapshot bloat → small files → MoR position-deletes → orphans): canonical maintenance-load order per trino.io/docs/current/connector/iceberg.html and iceberg.apache.org/docs/latest/maintenance/. The 20-30%/yr snapshot-retention storage growth is a documented heuristic at Iceberg-1.5-era write rates (not a hard guarantee but a defensible production estimate). Correct.
- **Q4 `$snapshots` and `$files` metadata tables**: trino.io/docs/current/connector/iceberg.html — both are documented metadata tables in Trino 467 Iceberg. `$snapshots` exposes snapshot_id, committed_at, parent_id, manifest_list, summary; `$files` exposes content (0=data, 1=position-delete, 2=equality-delete), file_path, file_size_in_bytes, record_count, etc. Responder's diagnostic queries are correct.
- **Q4 EXECUTE optimize(file_size_threshold)**: trino.io/docs/current/connector/iceberg.html — "All files with a size below the optional file_size_threshold parameter (default value for the threshold is 100MB) are merged in case any of the following conditions are met per partition". `128MB` threshold is reasonable production tuning. Verified via WebSearch this iter.
- **Q4 EXECUTE expire_snapshots(retention_threshold)**: trino.io/docs/current/connector/iceberg.html — "The procedure affects all snapshots that are older than the time period configured with the retention_threshold parameter". 7d is at the minimum-retention floor (`iceberg.expire-snapshots.min-retention` default 7d). Verified.
- **Q4 EXECUTE remove_orphan_files(retention_threshold)**: trino.io/docs/current/connector/iceberg.html — native Trino 467 procedure (NOT Spark-only); 7d min-retention floor (`iceberg.remove-orphan-files.min-retention` default 7d). Verified.
- **Q4 rewrite_position_delete_files Spark-only**: iceberg.apache.org/docs/latest/maintenance/ — `rewrite_position_delete_files` is a Spark Iceberg stored procedure. Trino 467 has NO standalone equivalent — Trino's `optimize` rewrites data files AND applies position deletes as a side effect, which is the de-facto position-delete compaction in Trino. Responder's "Spark-only, Trino 467 lacks it" correctly notes the gap.
- **Q4 `$files` GROUP BY content for position-delete detection**: trinodb/trino issue #28910 confirms `content` column on `$files` (0=data, 1=position-delete, 2=equality-delete) is the canonical diagnostic for MoR delete-file accumulation. Verified.

---

## Q1 synthesis-transfer probe verdict — TRANSFERS CLEANLY

iter1118 closed the ts-minus-ts WATCH on the login-days domain. The open question was whether the gaps-and-islands skeleton transfers to a NOVEL domain (subscriptions+months) with the additional twist of needing to collapse multi-events-per-period FIRST. iter1119 Q1 specifically reconstructed this: `SELECT DISTINCT subscription_id, date_trunc('month', payment_timestamp)` as the collapse layer, then the same 3-CTE skeleton on top with `date_diff('month', LAG, cur) <> 1` as the gap test. Both the collapse step AND the skeleton transfer correctly. This addresses the iter951-956 synthesis-ceiling concern (residual that domain-novel hard multi-step gaps-and-islands can't be assembled) — at least on this particular shape (truncate-and-streak with month granularity), the skeleton DOES transfer. **Synthesis-ceiling concern partially relieved on the truncate-collapse variant; no recurrence on this iter.**

---

## Per-question scores

### Q1 — longest run of consecutive CALENDAR MONTHS with >=1 payment per subscription
- Accuracy: 5 — DISTINCT-collapse to one row per active month (correct order: truncate FIRST, then gap test), `date_diff('month', LAG, cur) <> 1` on month-START dates correctly detects adjacent vs skipped months, cumulative-SUM streak_id, GROUP BY streak count, outer MAX per subscription
- Completeness: 5 — covers the collapse step (the question's explicit twist), the gap-test mechanics, the 3-CTE shape, the outer MAX-per-subscription
- Clarity: 5 — explicit CTE naming, the collapse-first ordering called out
- Actionability: 5 — copyable 3-CTE skeleton on a NOVEL domain, plug-in-ready
- Avg: **5.00**

### Q2 — on-prem Trino+Iceberg+MinIO storage tiering, age- vs read-frequency-driven
- Accuracy: 5 — correctly identifies tiering as NOT a Trino feature (no DDL/table property), MinIO `mc ilm tier add` + `mc ilm rule add --transition-days` is purely AGE-based (calendar days from object creation), does NOT track read frequency or per-table mapping; metadata/ prefix kept hot; on-prem so no AWS S3 Intelligent-Tiering / GCS Autoclass auto-tiering available
- Completeness: 5 — covers all three angles: what tiering is at the MinIO layer, why it cannot be read-frequency-aware, what the app-layer workaround is (two tables hot/archive + UNION ALL view), and the on-prem implication
- Clarity: 5 — clear "MinIO not Trino" framing, clear "age-based not access-based" framing, clear "app-layer for access-aware" framing
- Actionability: 5 — engineer has concrete `mc ilm` commands, a clear hot/cold split pattern, and the right metadata/ vs data/ prefix scoping
- Avg: **5.00**

### Q3 — dbt model contracts on dbt-trino+Iceberg, what's enforced, build-time behavior
- Accuracy: 5 — `contract.enforced: true` correct, build-time preflight on column-name+type correct, Compilation Error halts model AND downstream correct, dbt-trino enforces ONLY not_null at write (Iceberg column constraint) correct, primary_key/unique/check metadata-only correct, use Trino native types not generic strings correct
- Completeness: 5 — covers build-time vs runtime split, the four constraint types and which are/aren't enforced, the type-string requirement, and the "pair with dbt tests for runtime checks" workaround
- Clarity: 5 — explicit "at build" vs "at write" framing, no hand-waving
- Actionability: 5 — engineer knows exactly which YAML keys to set, what type strings to write, what to expect at `dbt build`
- Avg: **5.00**

### Q4 — MinIO bill climbing at flat business volume, Iceberg overhead cost drivers + diagnostics
- Accuracy: 5 — 4 cost drivers in canonical order (snapshot bloat → small files → MoR position-deletes → orphans), `$snapshots` count + `$files` content/size diagnostics correct, EXECUTE optimize(file_size_threshold)/expire_snapshots(retention_threshold)/remove_orphan_files(retention_threshold) all native Trino 467 procedures with correct parameter names, rewrite_position_delete_files correctly identified as Spark-only (Trino 467 lacks standalone equivalent — uses optimize side-effect), 7d min-retention implied via the retention_threshold value
- Completeness: 5 — covers all four drivers, each with both a diagnostic query AND a remediation, plus the Trino-vs-Spark gap on position-delete compaction
- Clarity: 5 — numbered list of causes with one-line cause/diagnose/fix per row, easy to scan
- Actionability: 5 — engineer has a concrete checklist: run the diagnostic SQL, then run the matching EXECUTE procedure on the right cadence
- Avg: **5.00**

---

## Score table

| Q | Topic | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|---|
| Q1 | gaps-and-islands consecutive-MONTHS with collapse-first | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | storage tiering MinIO age-based vs Trino+app-layer access-aware | 5 | 5 | 5 | 5 | 5.00 |
| Q3 | dbt model contracts on dbt-trino+Iceberg | 5 | 5 | 5 | 5 | 5.00 |
| Q4 | Iceberg cost drivers + $snapshots/$files diagnostics + EXECUTE procedures | 5 | 5 | 5 | 5 | 5.00 |

**Iter avg: 5.00 — STRONG PASS** (margin +1.50 above 3.5; flat to iter1118 5.00; clean sweep on all four thin-margin rows).

---

## Source-verified defects

**None.** Q1 collapse-then-streak skeleton correct on month-truncated dates (no partial-month miscount), Q2 MinIO-mc-ilm-age-based + app-layer-access-aware correct (re-confirms iter1100/1102 storage-tiering FIX-A lineage), Q3 dbt-trino contracts preflight + only-not_null-enforced correct, Q4 four-driver Iceberg overhead with native Trino-467 EXECUTE procedures and Spark-only rewrite_position_delete_files gap correctly noted. No factual errors, no fabrications, no broken alternatives, no over-warning folklore, no imported-prior slips.

---

## Thin-margin row updates (this iter's primary mission)

- **analytical-query-patterns-Iceberg+Trino** 4.4389/73 → (4.4389*73 + 5.00)/74 = 329.0397/74 = **4.4465/74 PASSED** (+0.0076; **margin +0.9465**, Q1 collapse-first month-streak clean)
- **storage-tiering** 3.5625/6 → (3.5625*6 + 5.00)/7 = 26.375/7 = **3.7679/7 PASSED** (+0.2054; **margin +0.2679** — was the thinnest row at +0.0625, now +0.2679, biggest lift this iter; iter1100/1102 FIX-A lineage holds)
- **dbt-model-contracts** 4.391/6 → (4.391*6 + 5.00)/7 = 31.346/7 = **4.4780/7 PASSED** (+0.0870; **margin +0.9780**)
- **cost-considerations** 4.2129/20 → (4.2129*20 + 5.00)/21 = 89.258/21 = **4.2504/21 PASSED** (+0.0375; **margin +0.7504**)

All four targeted thin-margin rows lift cleanly. **storage-tiering** remains the thinnest (now at 3.7679/7, margin +0.2679, n=7 — still needs durability building, but moved meaningfully off the +0.0625 floor). NEW thinnest order after this iter:

1. storage-tiering: **3.7679/7** (margin +0.2679)
2. dbt-snapshots SCD2: **4.0315/14** (margin +0.5315)
3. cost-considerations: **4.2504/21** (margin +0.7504)
4. query-performance-basics: 4.3629/20 (margin +0.8629)

Federation 4.50244/312 untouched (fragile-PASS preserved). CBO/ANALYZE 4.5716/20 untouched.

---

## Teacher guidance — NO-OP RECOMMENDED

**Do not modify any resource files this iter.** Six consecutive clean iters now (1090, 1092, 1093, 1117, 1118, 1119 all ≥ 4.9), interspersed with 1091/1116 LIGHT FIX-A iters confirmed reaching. Resources stable. The iter1119 thin-margin sweep hit storage-tiering (the thinnest row) with a clean re-confirm of the iter1100/1102 FIX-A; no defect surfaced, no FIX-A warranted. Q1 synthesis-transfer probe (novel domain + collapse-first twist) also clean — the iter951-956 synthesis-ceiling does NOT recur on the truncate-collapse-then-streak variant.

**Risk surface to keep watching (low-priority probes, not fixes):**
- **storage-tiering** (still thinnest at 3.7679/7, +0.2679 margin) — 8th datapoint at a future sweep on a NOVEL angle (e.g. tiering vs Iceberg expire_snapshots interaction; orphan file detection across tiers; multi-bucket lifecycle policy authoring) to build durability beyond simple "MinIO mc ilm + app-layer view" angles
- **dbt-snapshots SCD2** 4.0315/14 (margin +0.5315) — 15th angle at a future sweep (e.g. dbt_is_deleted=true with hard-delete CDC sources; check_cols strategy edge cases; snapshot-to-Type 1/2 hybrid materialization)
- **cost-considerations** 4.2504/21 — 22nd angle at a future sweep (e.g. partition-level cost attribution; per-tenant cost queries via $manifests + multi-tenancy)
- **Responder over-warning folklore** (`feedback_responder_overwarning_folklore` pin) — none surfaced this iter; periodic breadth probes still warranted
- **Responder broken secondary alternative** (`feedback_responder_broken_secondary_alternative` pin) — none surfaced this iter; per-instance one-off

**No FIX-A, no FIX-B, no card additions. Hold the line. Six-iter clean run continues.**
