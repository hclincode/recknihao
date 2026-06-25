# Judge Feedback — iter1100 (2026-06-26)

**Iteration**: 1100
**Phase**: extended (passed:true, post-final)
**Mode**: thin-margin durability sweep — Q1 storage-tiering FRESH ANGLE (access-vs-age) + Q2 perf-regression 2nd angle (small-files/skew) + Q3 dbt-snapshots HARD-DELETE angle + Q4 Oracle LISTAGG
**Overall Average**: 3.1875 — **FAIL** (overall avg governs; below 3.5 threshold)

**Two distinct deficits this iter:** (a) **Q1 = FINDABILITY FAILURE** — the access-vs-age caveat literally exists at r16 L533 ("CRITICAL — transitions are by OBJECT AGE ... NOT by access time / access pattern / last-read timestamp") but the responder bailed because the L501 keyword anchors lack access-recency phrasings; (b) **Q3 = CONTENT GAP** — r09 covers SCD2 snapshot basics but has NO subsection on `hard_deletes` config / `invalidate_hard_deletes` / `dbt_is_deleted` meta column. Q2 has a minor accuracy defect (wrong `$files` column names that would parse-error). Q4 is clean.

---

## Per-question scoring

### Q1 — Engineer assumes Iceberg/MinIO tiering moves files based on last-read/query access ("frequently-accessed old data stays warm"). Is that how it works?

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 2 | Responder bailed with "I don't have enough information... resources don't cover Iceberg tiering policies / access-vs-age." It did NOT echo a false claim, but **it also failed to correct the engineer's explicit misconception** that tiering is access-aware. The engineer leaves the conversation still believing "frequently-accessed old data stays warm" — which is FALSE on this stack (verified r16 L533 + docs.min.io ILM rule reference). Source ground truth: MinIO `mc ilm rule add` transitions trigger on `--transition-days N` (days since OBJECT CREATION) ONLY; there is NO `--transition-access-days` / `--last-accessed-days` flag. Heavily-read 6-month-old data WILL get tiered on a 90-day rule. Access-aware tiering is only achievable at the application layer (Mechanism C: two-table recent+archive split). |
| Beginner clarity | 3 | The bail itself is clearly stated. But "I don't know" leaves the engineer's mental model unchanged and they will now design wrong (e.g., expect a hot-table-stays-on-hot-tier guarantee that does not exist). |
| Practical applicability | 1 | Engineer cannot act. Worse, will likely build an architecture that assumes incorrect tiering semantics. |
| Completeness | 1 | Did not address the question. |
| **Q1 average** | **1.75** | |

**SOURCE-VERIFIED CONTENT EXISTS — FINDABILITY DEFECT:**
- r16 §LEADING CANONICAL tiering block (L499–620) is the canonical answer location for tiering questions on this stack.
- r16 L533 explicitly addresses this exact misconception verbatim: *"CRITICAL — transitions are by OBJECT AGE (`--transition-days N`), NOT by access time / access pattern / last-read timestamp. ... a heavily-read 6-month-old hot dashboard table will still get tiered if your rule says `--transition-days 90` — age, not heat, is the trigger. If you actually want access-aware tiering (which is what AWS S3 Intelligent-Tiering offers), you have to implement it yourself at the application layer (Mechanism C), MinIO ILM will not do it for you."*
- r16 L501 keyword load (~30 phrasings) is rich on "tier/hot/cold/lifecycle/archive/move old data" but **MISSING the access-recency family**: "last read", "last accessed", "how recently queried", "frequently accessed", "frequently-accessed stays warm", "hot data stays hot", "access pattern", "access-aware tiering", "Intelligent-Tiering", "access time", "S3 Intelligent-Tiering equivalent".
- The Haiku responder's keyword→file→section retrieval missed the block entirely because the engineer's phrasing ("frequently-accessed old data stays warm") doesn't match any L501 anchor. The L533 critical note is buried 32 lines below the anchor list.

### Q2 — Nightly ingest then dashboard slow; small-files vs skew — how to tell & fix?

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 3 | **Diagnosis methodology is correct** — EXPLAIN ANALYZE per-fragment to distinguish `Scheduled time >> CPU time` (I/O small-files) from `1 driver busy / rest idle` (skew); `EXECUTE optimize(file_size_threshold => '128MB')` for small-files; repartition for skew. All sound. **BUT the `$files` metadata query has WRONG COLUMN NAMES that would parse-error:** (a) responder used `file_size` — the actual Iceberg `$files` column is `file_size_in_bytes` (verified r13 L3083, r16 L394–396, r17 L107–110); (b) responder used `WHERE NOT is_deleted` — there is NO `is_deleted` column on `$files`; the correct discriminator is `content = 0` (data files), `content = 1` (position deletes), `content = 2` (equality deletes) per r13 L3066–3085 + trino.io connector/iceberg.html metadata-tables section. A paste-into-Trino of the responder's query would fail with `Column 'file_size' cannot be resolved` / `Column 'is_deleted' cannot be resolved`. |
| Beginner clarity | 4 | The small-files-vs-skew distinguishing signal (Scheduled >> CPU vs 1-driver-busy) is well-explained. |
| Practical applicability | 3 | Engineer can follow the EXPLAIN ANALYZE methodology, but the `$files` SQL query as written will not run — engineer wastes a debug cycle hunting for the wrong column name before realizing the typo. |
| Completeness | 4 | Covers the two distinguishing signals AND the two fixes. Misses: (a) check for delete-file accumulation (`content = 1`) as a third cause, (b) `EXPLAIN ANALYZE` ROW_COUNT skew detection on hashed joins. |
| **Q2 average** | **3.50** | |

**SOURCE-VERIFIED DEFECT (minor accuracy):** the `$files` column names — the correct names per Trino 467 Iceberg connector are:
- `file_size_in_bytes` (NOT `file_size`)
- `content` integer enum: 0=DATA, 1=POSITION_DELETES, 2=EQUALITY_DELETES (NOT `is_deleted` boolean)

The CORRECT version of the responder's small-files query is:
```sql
SELECT
  COUNT(*) AS small_files,
  SUM(file_size_in_bytes) / 1024.0 / 1024 AS small_bytes_mb
FROM iceberg.analytics."events$files"
WHERE content = 0
  AND file_size_in_bytes < 16 * 1024 * 1024;
```

This is **broken-secondary family** (per the [Responder Broken Secondary Alternative] pattern) — the primary diagnosis is right but the illustrative `$files` query has fabricated column names that mirror Postgres/MySQL conventions. Per-instance one-off; resource canonicals (r13/r16/r17) already use the correct column names. NO resource fix needed; per-instance responder slip.

### Q3 — Source rows physically DELETED in Oracle; want dbt snapshot to record the deletion + when. How?

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 3 | Responder bailed: "I don't have enough information... not covered." Suggested workarounds: (a) switch to soft-deletes in source, (b) row-count reconciliation. Neither workaround is wrong as a fallback, but both miss the actual native dbt answer (`hard_deletes` config). The bail itself produces no incorrect technical claim, but the engineer is told "dbt snapshot mechanics are out of scope" which is **false** — dbt snapshots have first-class hard-delete support that the responder simply could not find. |
| Beginner clarity | 3 | The bail is clearly stated. |
| Practical applicability | 2 | The "switch to soft-deletes in source" workaround requires modifying the Oracle source system — frequently NOT possible (the source may be a legacy ERP, vendor-owned, or read-only). The engineer asked specifically because they couldn't change the source. Row-count reconciliation is a monitoring pattern, not a deletion-history recording pattern — it doesn't answer the question. |
| Completeness | 1 | Did not address the actual question. The dbt answer exists and is well-documented. |
| **Q3 average** | **2.25** | |

**SOURCE-VERIFIED CONTENT GAP — r09 covers SCD2 basics but NOT hard-delete handling. Exact verified dbt config names (from docs.getdbt.com/reference/resource-configs/hard-deletes + docs.getdbt.com/docs/build/snapshots):**

| Config | dbt version | Allowed values | Behavior |
|---|---|---|---|
| `hard_deletes` (new, recommended) | dbt 1.9+ | `'ignore'` (default) | No action on deleted source rows. The snapshot row's `dbt_valid_to` stays NULL — the row appears "still current" even though the source deleted it. |
| `hard_deletes` | dbt 1.9+ | `'invalidate'` | When a source row vanishes, dbt sets that snapshot row's `dbt_valid_to` to the current snapshot run timestamp — same effect as the legacy `invalidate_hard_deletes=true`. Implicit-delete pattern. |
| `hard_deletes` | dbt 1.9+ | `'new_record'` | When a source row vanishes, dbt INSERTS a new snapshot row with all the previous column values, sets `dbt_valid_from` to the current snapshot run time, and **adds a new meta column `dbt_is_deleted` set to the string `'True'`** (`'False'` on all non-deletion rows). Explicit-delete pattern that preserves a queryable "this row was deleted at time T" record. |
| `invalidate_hard_deletes` (legacy) | dbt 1.8 and earlier | `true` / `false` | When `true`, behaves identically to the new `hard_deletes='invalidate'`. Deprecated in 1.9+; cannot be used alongside the new `hard_deletes` config. |

The engineer's exact ask ("record the deletion + when") maps **directly** to `hard_deletes='new_record'` on dbt 1.9+ (gives a queryable `dbt_is_deleted='True'` row at the deletion timestamp), or to `hard_deletes='invalidate'` / `invalidate_hard_deletes=true` if they only need to know the row is no longer current.

### Q4 — Oracle LISTAGG WITHIN GROUP ORDER BY → Trino 467 equivalent.

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | All four claims VERIFIED against trino.io/docs/current/functions/aggregate.html: (a) Trino 467 has native `listagg(expression, separator)` — TRUE; (b) supports `WITHIN GROUP (ORDER BY ...)` — TRUE (in fact REQUIRED per the docs grammar `LISTAGG(expr [, sep] [ON OVERFLOW ...]) WITHIN GROUP (ORDER BY ...)`); (c) supports `ON OVERFLOW TRUNCATE` — TRUE (variants: `ON OVERFLOW ERROR` default, `ON OVERFLOW TRUNCATE [str] WITH COUNT`, `ON OVERFLOW TRUNCATE [str] WITHOUT COUNT`; default overflow throws when output exceeds 1,048,576 bytes); (d) both Oracle and Trino LISTAGG skip NULLs by default — TRUE (per SQL:2016 standard which both follow); (e) windowed `LISTAGG(...) OVER (...)` is NOT supported in Trino — TRUE (the docs explicitly state "The current implementation of listagg function does not support window frames"); workaround `array_join(array_agg(x ORDER BY y) OVER (...), sep)` is correct. Matches the [Trino listagg Native] pin. |
| Beginner clarity | 5 | Migration is presented as a 1:1 syntax mapping with the OVER-clause caveat called out. |
| Practical applicability | 5 | Engineer can paste the LISTAGG form directly; knows the OVER-window fallback shape if they hit that case. |
| Completeness | 5 | Covers: (a) the 1:1 mapping, (b) ON OVERFLOW TRUNCATE, (c) NULL-skipping behavior, (d) the no-OVER-window caveat with workaround. All four corners of the Oracle→Trino migration question. |
| **Q4 average** | **5.00** | |

---

## Score table

| Q | Accuracy | Clarity | Applicability | Completeness | Avg |
|---|---|---|---|---|---|
| Q1 storage-tiering (access-vs-age) | 2 | 3 | 1 | 1 | **1.75** |
| Q2 perf-regression small-files/skew | 3 | 4 | 3 | 4 | **3.50** |
| Q3 dbt snapshots hard-deletes | 3 | 3 | 2 | 1 | **2.25** |
| Q4 Oracle LISTAGG → Trino | 5 | 5 | 5 | 5 | **5.00** |
| **Iter overall** | | | | | **3.1875** |

**FAIL** (overall avg 3.1875 < 3.5 threshold). Two distinct severe deficits (Q1 findability, Q3 content-gap) pull the iter below threshold despite Q4 being a clean 5.

---

## Source verification (each technical claim checked)

| Claim | Source | Verdict |
|---|---|---|
| MinIO ILM `mc ilm rule add --transition-days N` is creation-age based, NOT access-time based | docs.min.io/enterprise/aistor-object-store/reference/cli/mc-ilm-rule/mc-ilm-rule-add/ + r16 L529–533 | VERIFIED — no `--transition-access-days` flag exists; trigger is days-since-creation |
| Iceberg `$files` column name is `file_size_in_bytes` NOT `file_size` | r13 L3083, r16 L107–113, r17 L107–110 + trino.io/docs/current/connector/iceberg.html metadata-tables | VERIFIED — responder's `file_size` would parse-error |
| Iceberg `$files` discriminator is `content` integer enum, NOT `is_deleted` boolean | r13 L3066–3085 + trino.io connector/iceberg.html | VERIFIED — content: 0=DATA, 1=POSITION_DELETES, 2=EQUALITY_DELETES; no `is_deleted` column exists |
| dbt 1.9+ `hard_deletes='ignore'/'invalidate'/'new_record'` | docs.getdbt.com/reference/resource-configs/hard-deletes | VERIFIED — three values, default `ignore`; `new_record` adds `dbt_is_deleted` meta column |
| Legacy `invalidate_hard_deletes=true` in dbt 1.8 and earlier | docs.getdbt.com snapshots docs | VERIFIED — equivalent to new `hard_deletes='invalidate'`; deprecated 1.9+ |
| Trino 467 native LISTAGG with WITHIN GROUP (ORDER BY) + ON OVERFLOW TRUNCATE | trino.io/docs/current/functions/aggregate.html | VERIFIED — full syntax incl. WITH COUNT / WITHOUT COUNT variants |
| Trino 467 LISTAGG does NOT support OVER window | trino.io aggregate.html (verbatim "does not support window frames") | VERIFIED — workaround `array_join(array_agg(...) OVER (...), sep)` is correct |
| Trino LISTAGG skips NULL inputs by default | SQL:2016 standard + Trino aggregate.html implicit | VERIFIED — matches Oracle LISTAGG NULL-skipping semantics |

---

## Teacher guidance — TWO FIX-A REQUIRED

### FIX-A #1 — r16 storage-tiering FINDABILITY (Q1)

**Root cause:** the L499–620 leading canonical block has the right answer at L533 but the L501 keyword anchor list lacks access-recency phrasings, so the Haiku responder's keyword→file→section retrieval cannot reach it from the engineer's "frequently-accessed old data stays warm" phrasing.

**Required edits to resources/16-cost-considerations.md:**

1. **L501 keyword anchor expansion** — append the access-recency family to the keyword list inside the leading canonical block at L501. Specifically add (verbatim):
   - "is tiering access-aware", "is tiering based on access time", "is tiering based on access pattern", "is tiering based on last read", "is tiering based on last access", "is tiering based on query frequency"
   - "frequently-accessed old data stays warm", "frequently accessed stays hot", "hot data stays hot", "heavily-read old data"
   - "last read", "last accessed", "last access time", "how recently queried", "how recently read"
   - "access-aware tiering", "Intelligent-Tiering equivalent", "S3 Intelligent-Tiering on MinIO", "Intelligent tiering on MinIO"
   - "MinIO tiers cold-read objects", "MinIO moves cold-read objects to cheap storage"

2. **New routing row at ~L508 (the capability-bound table)** — add a row near the top of the §"What engineers often expect to exist" table:
   - Column 1: "Access-aware tiering — frequently-accessed old data stays on hot tier, rarely-read old data moves to cold tier (S3 Intelligent-Tiering style)"
   - Column 2: "**NO. MinIO ILM transitions trigger on object AGE (`--transition-days N`), NOT on last-read or access frequency.** There is no `--transition-access-days` flag, no last-access mode. A heavily-read 6-month-old hot table WILL get tiered on a 90-day rule. See §below + L533."
   - Column 3: docs.min.io/enterprise/aistor-object-store/reference/cli/mc-ilm-rule/mc-ilm-rule-add/

3. **Direct cross-reference at L533** — leave the existing critical block intact (it's already correct), but ALSO add at the very top of the leading canonical block a one-liner like: *"If your question is 'does tiering keep frequently-accessed old data on hot tier' or 'is tiering based on last read / query frequency / access pattern' — jump directly to L533 for the access-vs-age critical note."*

4. **Optional new DO-NOT-WRITE row at L612 table** — append a row to the banned-tiering-forms table:
   - "MinIO ILM tiers based on access pattern / last-read timestamp / query frequency" → "Wrong. MinIO ILM transitions are age-only (`--transition-days N` = days since object creation). For access-aware behavior, implement at app layer (Mechanism C)."

### FIX-A #2 — r09 dbt snapshots HARD-DELETE handling (Q3)

**Root cause:** r09 covers SCD2 snapshot basics (timestamp/check strategies, 4 meta columns, point-in-time queries) but has NO subsection on what happens when source rows physically vanish (the Oracle-DELETE scenario).

**Required edit — new subsection in resources/09-lakehouse-schema-design.md (or wherever the dbt snapshots SCD2 canonical lives — verify location first):**

Add a new §labeled something like *"LEADING CANONICAL — handling hard-deletes in dbt snapshots (source rows physically deleted)"*. Required content:

1. **Keyword anchor block** — "hard delete", "hard-delete", "physically deleted", "row vanished", "row disappeared", "row removed from source", "track deletion", "record deletion", "record deletion timestamp", "when was a row deleted", "deletion event", "source DELETE", "source physical delete", "Oracle DELETE captured in snapshot", "snapshot deletion handling", "dbt_is_deleted", "invalidate_hard_deletes", "hard_deletes config".

2. **The dbt 1.9+ `hard_deletes` config matrix** (verified against docs.getdbt.com/reference/resource-configs/hard-deletes):

   | Value | Behavior | When to use |
   |---|---|---|
   | `'ignore'` (default) | No action. Deleted source rows leave their last snapshot row's `dbt_valid_to` NULL, appearing "still current" forever. Wrong for most production snapshots. | Only when you genuinely don't care about deletions (e.g., append-only sources). |
   | `'invalidate'` | When a source row is missing, dbt sets that snapshot row's `dbt_valid_to` to the current snapshot run timestamp. Implicit-delete: you can detect deletion by `dbt_valid_to IS NOT NULL AND no_newer_active_row_exists`. Same behavior as legacy `invalidate_hard_deletes=true`. | When you only need to know "this row stopped being current at time T" — no explicit deletion marker needed. |
   | `'new_record'` | When a source row is missing, dbt INSERTS a new snapshot row with the previous column values and **adds a new meta column `dbt_is_deleted` set to `'True'`**. Explicit-delete: queryable as `WHERE dbt_is_deleted = 'True'`. | When you need an auditable deletion event — exactly the Oracle-physical-delete capture case. |

3. **Legacy config** — call out that dbt 1.8 and earlier used `invalidate_hard_deletes=true` (Boolean). dbt 1.9+ replaces it with `hard_deletes='invalidate'`. The two cannot coexist on the same snapshot.

4. **Worked example for the Oracle DELETE case** (the engineer's exact ask):
```yaml
# dbt_project.yml or snapshot config block
snapshots:
  my_project:
    customer_dim_snapshot:
      +strategy: timestamp
      +updated_at: updated_at
      +hard_deletes: new_record   # dbt 1.9+; adds dbt_is_deleted='True' row on source deletion
```
```sql
-- Query for deletion events recorded by the snapshot
SELECT id, dbt_valid_from AS deleted_at_run_ts
FROM {{ ref('customer_dim_snapshot') }}
WHERE dbt_is_deleted = 'True';
```

5. **Cross-link** to the existing r09 SCD2 query template (point-in-time `WHERE id=... AND dbt_valid_from <= T AND (dbt_valid_to IS NULL OR dbt_valid_to > T)`) — note that the `dbt_is_deleted='True'` row is itself a "valid" snapshot row whose `dbt_valid_from` IS the deletion event time, so point-in-time queries naturally see "deleted" state after T_deletion.

---

## Recommendation

- **MUST commit BOTH FIX-A #1 (r16 access-recency anchors + L508 routing row) AND FIX-A #2 (r09 hard-delete handling subsection).** Without these, the same questions will fail again next sweep.
- **Re-probe Q1 next sweep** with multiple access-recency phrasings ("does tiering keep hot data warm based on query frequency?", "is MinIO tiering access-aware?", "frequently-accessed old data — does it stay on hot tier?") to confirm FIX-A #1 reaches the responder via different keyword paths.
- **Re-probe Q3 next sweep** with the dbt 1.9+ `hard_deletes='new_record'` question phrased multiple ways ("source row deleted, how to capture in snapshot?", "track Oracle DELETE in dbt snapshot", "record deletion event with timestamp").
- **NO state.json bump** (already 1100, already passed:true, but FAIL on this iter degrades thin-margin topic rows — see below).
- **NO federation re-probe** (4.50244/312 fragile-PASS per iter1097; do not stress it on a FAIL iter).
- **Q2 column-name slip = per-instance broken-secondary** (per [Responder Broken Secondary Alternative] pin) — primary diagnosis methodology is correct, only the illustrative SQL has wrong column names; resource canonicals (r13/r16/r17) already use the correct names. NO resource fix; one-off responder slip.
- **Q4 LISTAGG clean** — no action.

### Topic-row updates (this iter)

| Topic | Before | This iter Q score | After | Status |
|---|---|---|---|---|
| storage-tiering on Trino+Iceberg+MinIO | 4.4167 / 3 | 1.75 | (13.25 + 1.75) / 4 = **3.75 / 4** | PASSED (heavily dragged; thinnest row at 4 datapoints; still above 3.5 but margin only +0.25) |
| query performance regression diagnosis | 4.3535 / 19 | 3.50 | (82.7165 + 3.50) / 20 = **4.3108 / 20** | PASSED (-0.043) |
| dbt snapshots SCD2 | 4.4933 / 9 | 2.25 | (40.4397 + 2.25) / 10 = **4.2690 / 10** | PASSED (-0.224, sizeable drop) |
| Oracle PL/SQL → dbt+Trino migration | 4.4421 / 102 | 5.00 | (453.0942 + 5.00) / 103 = **4.4475 / 103** | PASSED (+0.005) |

All four topics REMAIN PASSED (still above 3.5), but storage-tiering is now at the LOWEST margin in the rubric (3.75 / 4 datapoints, +0.25 over threshold). One more sub-2.0 storage-tiering score would push it BELOW threshold (3 × 4.4167 + 1.75 + 2.0 = 17.0 / 5 = 3.40 < 3.5 → would FAIL the topic row outright). FIX-A #1 is therefore high-priority next-sweep work.

### Trap-pattern flags

- **No `::` cast.** No QUALIFY. No false-semi-join. No fabricated function (LISTAGG, contains_sequence-equivalent, etc.). No regex-backslash defect. No INTERVAL quarter/week. No `LIMIT n OFFSET m` (Postgres order). No over-warning folklore. No Spark-Oracle-spillover.
- **Q2 broken-secondary family appearance (column names):** continues the broken-secondary pattern documented in the [Responder Broken Secondary Alternative] pin (iter936 window-in-GROUP-BY / iter943 PERCENTILE_CONT / iter948 price-suffix menu / iter950 nested-aggregate max_by / iter954 TO_CHAR-wrong-codes / iter1013 ORDER-BY-ungrouped / iter1019 TABLESAMPLE-after-WHERE / iter1020 regexp_extract-comma / **iter1100 $files-wrong-column-names**). Per-instance, no resource fix.
- **Two findability/content-gap failures in one iter is unusual** — both are root-cause-traceable to specific resource defects (L501 anchor list incomplete; r09 missing hard-delete subsection), not Haiku synthesis ceiling. FIX-A is the correct response, not "stop churning".
