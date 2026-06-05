# Judge Feedback — Iteration 483

**Overall**: 4.3125 / 5.0 — **PASS** (thin margin, ~0.81 above 3.5 floor)
**82nd consecutive PASS in extended phase** — but a load-bearing fab on Q1 dragged the iter from STRONG to THIN.
**Federation NOT probed** this iter (per directive — 4.49944/310 row held unchanged).

---

## Per-question scores

| Q | Topic | Accuracy | Completeness | Clarity | Actionability | Avg | Verdict |
|---|---|---|---|---|---|---|---|
| Q1 | Iceberg concurrent-write commit conflict + retry + isolation | 2.5 | 3.5 | 4.0 | 2.0 | **3.0** | LOAD-BEARING FAB |
| Q2 | approx_distinct for COUNT DISTINCT over 1B rows | 5.0 | 4.75 | 4.5 | 5.0 | **4.81** | STRONG PASS |
| Q3 | dbt macros + dbt_utils for surrogate keys / date logic | 4.75 | 4.75 | 4.75 | 4.75 | **4.75** | STRONG PASS |
| Q4 | Why both Spark and Trino — division of labor | 4.75 | 4.5 | 4.75 | 4.75 | **4.69** | STRONG PASS |

**Per-question average**: (3.0 + 4.81 + 4.75 + 4.69) / 4 = **4.3125 PASS**

---

## Critical fab — Q1 ruling (the suspicion was correct)

**The responder's bare `ALTER TABLE iceberg.analytics.orders SET PROPERTIES "commit.retry.num-retries" = '8', "commit.retry.min-wait-ms" = '500', "write.merge.isolation-level" = 'snapshot'` is INVALID Trino syntax.** Engineer copy-pasting this gets a Trino error along the lines of:

```
Catalog 'iceberg' table property 'commit.retry.num-retries' does not exist
```

### Why it fails

Verified via WebFetch of trino.io/docs/current/connector/iceberg.html, the Trino Iceberg connector's `SET PROPERTIES` allow-list (15 properties total) is:

| Trino-native table property | Notes |
|---|---|
| `format` | PARQUET / ORC / AVRO |
| `compression_codec` | NONE / ZSTD / SNAPPY / LZ4 / GZIP |
| `partitioning` | array of transforms |
| `sorted_by` | array of sort columns |
| `location` | table location URI |
| `format_version` | 1 / 2 / 3 |
| **`max_commit_retry`** | **THIS is the Trino-native name for commit retries; defaults to 4 via catalog property `iceberg.max-commit-retry`** |
| `delete_after_commit_enabled` | boolean |
| `max_previous_versions` | int |
| `orc_bloom_filter_columns` | array |
| `orc_bloom_filter_fpp` | double |
| `parquet_bloom_filter_columns` | array |
| `object_store_layout_enabled` | boolean |
| `data_location` | data location URI |
| **`extra_properties`** | **`map(varchar, varchar)`; pass-through for native Iceberg properties NOT in the Trino-native allow-list** |

### The two fab forms — both wrong as written

1. **`"commit.retry.num-retries" = '8'`** — fabricated-capability-GRANT. The native Iceberg property `commit.retry.num-retries` exists in the Iceberg library, but **Trino's connector renames it to `max_commit_retry`** in its public table-property surface. The correct Trino form is:

   ```sql
   ALTER TABLE iceberg.analytics.orders SET PROPERTIES max_commit_retry = 8;
   ```

2. **`"commit.retry.min-wait-ms" = '500'` / `"commit.retry.max-wait-ms"` / `"commit.retry.total-timeout-ms"` / `"write.merge.isolation-level" = 'snapshot'` / `"write.update.isolation-level"` / `"write.delete.isolation-level"`** — these have **NO Trino-native equivalent**. They are not in the allow-list. To set them from Trino, use the `extra_properties` map pass-through:

   ```sql
   ALTER TABLE iceberg.analytics.orders SET PROPERTIES
     extra_properties = MAP(
       ARRAY['commit.retry.min-wait-ms', 'commit.retry.max-wait-ms', 'write.merge.isolation-level'],
       ARRAY['500', '60000', 'snapshot']
     );
   ```

   The Trino docs explicitly note about `extra_properties`: "The properties are not used by Trino, and are available in the `$properties` metadata table" — meaning Trino doesn't interpret them, it just persists them in Iceberg metadata where the underlying Iceberg writer (which may be Trino's writer or a Spark writer reading the same table) will honor them.

   **Caveat for isolation-level**: whether `write.merge.isolation-level = 'snapshot'` set via Trino `extra_properties` actually changes Trino's own MERGE behavior at runtime is unverified in the public Trino docs — Trino's MERGE implementation may not consult those properties. The safer path for forcing a known isolation behavior on Trino-issued MERGE is to coordinate via the Iceberg library itself (Spark `ALTER TABLE ... SET TBLPROPERTIES`).

3. **Spark alternative** (always works, since Spark uses the Iceberg native property names directly):

   ```sql
   -- Run via Spark SQL
   ALTER TABLE iceberg.analytics.orders SET TBLPROPERTIES (
     'commit.retry.num-retries' = '8',
     'commit.retry.min-wait-ms' = '500',
     'write.merge.isolation-level' = 'snapshot'
   );
   ```

### What WAS correct in Q1

- Optimistic concurrency framing
- `CommitFailedException` / `ValidationException` distinction
- Atomic snapshot-pointer swap as the conflict-detection mechanism
- Loser-retries-or-fails semantics
- Default isolation = serializable; snapshot is the relaxed mode
- **NO global `write.isolation-level`** (only per-operation `write.merge.isolation-level` / `write.update.isolation-level` / `write.delete.isolation-level`) — this is the right anti-fab landmine
- Serialize-jobs-if-same-rows fallback advice
- `$properties` metadata table diagnostic SQL pattern (correct table-syntax, correct LIKE filtering)

The CONCEPTS in Q1 are accurate per r26. The failure is **operational syntax**: the responder claimed Trino `SET PROPERTIES` accepts native Iceberg dotted property names directly, which it does not.

---

## Verifications confirmed (Q2/Q3/Q4 — ZERO fabs)

### Q2 approx_distinct
- `approx_distinct(x)` real + ~2.3% default standard error verified at trino.io/docs/current/functions/aggregate.html ("should produce a standard error of 2.3%, which is the standard deviation of the (approximately normal) error distribution over all possible sets")
- Optional 2nd arg `e ∈ [0.0040625, 0.26000]` verified — signature `approx_distinct(x, e) → bigint`
- "~2.3% standard error → 68% within ±2.3%, 95% within ±4.6%" framing is statistically correct (1σ ≈ 68% and 2σ ≈ 95% for the approximately-normal HLL error distribution)
- `approx_set(x) → HyperLogLog`, `merge(HyperLogLog) → HyperLogLog`, `cardinality(hll) → bigint`, `empty_approx_set() → HyperLogLog` all confirmed at trino.io/docs/current/functions/hyperloglog.html
- Rolling-window pre-aggregated HLL pattern (approx_set per-day + merge across N days + cardinality at query) is the canonical Trino idiom

### Q3 dbt_utils
- `dbt_utils.generate_surrogate_key(['col1','col2'])` confirmed at github.com/dbt-labs/dbt-utils ("This macro implements a cross-database way to generate a hashed surrogate key using the fields specified")
- MD5 is the default hash algorithm
- packages.yml + `dbt deps` install flow correct per docs.getdbt.com/docs/build/packages
- `concat_ws(sep, ...)` valid Trino per trino.io/docs/current/functions/string.html
- `date_trunc('month', ts)` valid Trino
- Macro = jinja-function invoked via `{{ }}` framing correct

### Q4 Spark vs Trino division
- Spark = write-heavy / ingestion / maintenance / procedural — correct
- Trino = query-heavy / interactive / federation / CBO / dynamic filtering / dbt query layer — correct
- **`rewrite_position_delete_files` Spark-only claim CONFIRMED** — Trino's ALTER TABLE EXECUTE list per trino.io/docs/current/connector/iceberg.html is `optimize`, `optimize_manifests`, `expire_snapshots`, `remove_orphan_files`, `drop_extended_stats` (+ `rollback_to_snapshot` post-469). `rewrite_position_delete_files` is in Iceberg's Spark procedure set (iceberg.apache.org/docs/latest/spark-procedures/), NOT exposed in Trino — engineer needing position-delete-file compaction must run Spark.
- Spark batch-isolated vs Trino concurrent-multi-user correct
- Canonical Spark-ingest + dbt-orchestrate + Trino-query pattern matches production stack

---

## Topic average updates

| Topic | Before | After | Delta | Mapping rationale |
|---|---|---|---|---|
| Iceberg table maintenance | 4.4998 / 138 | **4.4890 / 139** | -0.0108 | Q1 maps here as closest existing row covering commit-retry + snapshot-isolation operational config |
| SQL query best practices for OLAP | 4.5866 / 45 | **4.5915 / 46** | +0.0049 | Q2 — "approximate functions" is in the topic-row keyword list |
| Oracle PL/SQL to dbt/Trino migration | 4.4920 / 57 | **4.4965 / 58** | +0.0045 | Q3 dbt macros — closest existing row covering dbt-side rewrite tooling for procedural source code |
| Postgres-to-Iceberg ingestion | 4.5023 / 161 | **4.5034 / 162** | +0.0011 | Q4 Spark-ingestion-vs-Trino-query division — closest existing row covering ingestion architecture |
| Trino federation (NEAR-MISS row) | 4.49944 / 310 | **4.49944 / 310** | 0 | NOT PROBED — held per iter472-482+ directive |

---

## Fabrications and inaccuracies — comprehensive list

### Q1 fabrications (LOAD-BEARING)

| # | Fabrication | Correct fact | Source |
|---|---|---|---|
| 1 | `SET PROPERTIES "commit.retry.num-retries" = '8'` | Trino-native name is `max_commit_retry` — `SET PROPERTIES max_commit_retry = 8` | trino.io/docs/current/connector/iceberg.html |
| 2 | `SET PROPERTIES "commit.retry.min-wait-ms" = '...'` | Not in Trino allow-list. Use `extra_properties = MAP(ARRAY['commit.retry.min-wait-ms'], ARRAY['...'])` OR Spark `SET TBLPROPERTIES` | trino.io/docs/current/connector/iceberg.html |
| 3 | `SET PROPERTIES "commit.retry.max-wait-ms" = '...'` | Same as #2 — use `extra_properties` or Spark | trino.io/docs/current/connector/iceberg.html |
| 4 | `SET PROPERTIES "commit.retry.total-timeout-ms" = '...'` | Same as #2 — use `extra_properties` or Spark | trino.io/docs/current/connector/iceberg.html |
| 5 | `SET PROPERTIES "write.merge.isolation-level" = 'snapshot'` | Not in Trino allow-list. Use `extra_properties` map syntax (with caveat that Trino's own MERGE implementation may not honor it at runtime); for guaranteed effect use Spark `ALTER TABLE ... SET TBLPROPERTIES` | trino.io/docs/current/connector/iceberg.html |
| 6 | `SET PROPERTIES "write.update.isolation-level" = 'snapshot'` | Same as #5 | trino.io/docs/current/connector/iceberg.html |
| 7 | `SET PROPERTIES "write.delete.isolation-level" = 'snapshot'` | Same as #5 | trino.io/docs/current/connector/iceberg.html |

### Q2/Q3/Q4: ZERO fabrications

---

## Pattern analysis — fabricated-capability-GRANT keeps surfacing

This is the **5th** iter in the extended phase where a fabricated-capability-GRANT class fab has dragged the score from STRONG to THIN:

| Iter | Q | Fab |
|---|---|---|
| 474 | Q? | `distributed_join_distribution_type` (fabricated session property) |
| 476 | Q1 | Oracle `TRUNC` (uppercase, Oracle-only) presented as Trino |
| 478 | Q3 | `task_max_memory` + `memory_revoking_enabled` (fabricated session properties) |
| 481 | Q4 | `listagg(...) WITHIN GROUP (ORDER BY ...) OVER (PARTITION BY ...)` (windowed listagg, not supported) |
| **483** | **Q1** | **Bare `SET PROPERTIES "commit.retry.num-retries"` / `"write.merge.isolation-level"` (native Iceberg dotted props, not in Trino allow-list)** |

**Common pattern**: the responder reaches for a plausible-sounding name from a sibling system (native Iceberg, Oracle, Spark/Delta, Presto-era) and presents it as Trino. The previous fixes (iter479 r18 memory/spill canonical card, iter482 r27 listagg canonical card, iter477 r27 Oracle TRUNC reconciliation) each closed ONE instance — but new instances surface on different surface areas because the underlying responder behavior (extrapolate by name similarity) keeps producing them.

**Structural recommendation**: every Trino-surface card in resources/ that documents an operation expressible via `SET PROPERTIES`, `SET SESSION`, function call, or DDL should include an explicit allow-list block with: (a) the verbatim trino.io doc URL, (b) the complete list of accepted property/property-key names, (c) a DO-NOT-WRITE row listing the sibling-system names that should NOT appear as Trino keys with the citation that they don't exist in Trino. This pattern was applied successfully in iter479 (memory/spill) and iter482 (listagg). Now needed for `SET PROPERTIES` on Iceberg tables.

---

## Teacher actions for iter484

### PRIMARY — Install Trino-Iceberg SET PROPERTIES allow-list canonical card

**Files**: `resources/26-iceberg-concurrent-write-conflicts.md` AND `resources/17-iceberg-table-maintenance.md`

**Content**:

1. **Allow-list block** — verbatim 15-property Trino-native list (from trino.io/docs/current/connector/iceberg.html) with each property's purpose:
   - `format`, `compression_codec`, `partitioning`, `sorted_by`, `location`, `format_version`, `max_commit_retry`, `delete_after_commit_enabled`, `max_previous_versions`, `orc_bloom_filter_columns`, `orc_bloom_filter_fpp`, `parquet_bloom_filter_columns`, `object_store_layout_enabled`, `data_location`, `extra_properties`

2. **Trino-native name mapping** for the commit-retry case:
   - `commit.retry.num-retries` (native Iceberg) -> **`max_commit_retry`** (Trino-native, defaults to 4 via catalog `iceberg.max-commit-retry`)
   - Working example: `ALTER TABLE iceberg.analytics.orders SET PROPERTIES max_commit_retry = 8`

3. **DO-NOT-WRITE matrix** banning bare Trino `SET PROPERTIES` keys:
   - `"commit.retry.num-retries"` -> use `max_commit_retry` (Trino-native)
   - `"commit.retry.min-wait-ms"` -> use `extra_properties` map or Spark
   - `"commit.retry.max-wait-ms"` -> use `extra_properties` map or Spark
   - `"commit.retry.total-timeout-ms"` -> use `extra_properties` map or Spark
   - `"write.merge.isolation-level"` -> use `extra_properties` map or Spark (caveat: Trino MERGE may not honor)
   - `"write.update.isolation-level"` -> same as above
   - `"write.delete.isolation-level"` -> same as above
   - Citation: trino.io/docs/current/connector/iceberg.html (allow-list)

4. **`extra_properties` map syntax** worked example:
   ```sql
   ALTER TABLE iceberg.analytics.orders SET PROPERTIES
     extra_properties = MAP(
       ARRAY['commit.retry.min-wait-ms', 'commit.retry.max-wait-ms'],
       ARRAY['500', '60000']
     );
   ```

5. **Spark alternative** worked example:
   ```sql
   ALTER TABLE iceberg.analytics.orders SET TBLPROPERTIES (
     'commit.retry.num-retries' = '8',
     'commit.retry.min-wait-ms' = '500',
     'write.merge.isolation-level' = 'snapshot'
   );
   ```

6. **Keyword anchors** for findability (responder lands on the ban via keyword match):
   - "commit retry trino", "commit.retry.num-retries trino", "max_commit_retry", "write.merge.isolation-level trino", "iceberg snapshot isolation trino", "ALTER TABLE SET PROPERTIES commit.retry", "trino extra_properties iceberg"

### RECONCILE — do not append

Grep existing resources for `commit\.retry\.` and `write\.merge\.isolation` and `write\.update\.isolation` and `write\.delete\.isolation` patterns. If any current resource shows these as bare Trino `SET PROPERTIES` keys, **fix in place** to the `extra_properties` / Spark / `max_commit_retry` form. Reconcile, don't append — responder may cite the wrong one if a stale contradictory form remains.

### SECONDARY — breadth design

- 4-Q iter484 with **no dedicated federation probe** (federation 4.49944/310 row held)
- Consider a 2nd-angle re-probe on iceberg-concurrent-write SET PROPERTIES at iter485-486 from a different keyword angle to confirm the fix landed. Example angles:
  - "How do I change the commit retry count in Trino for an Iceberg table?"
  - "How do I switch a Trino Iceberg table to snapshot isolation for MERGE?"
  - "What is `max_commit_retry` in Trino?"
- Low-count topics still worth additional datapoints: dbt sources freshness (3 questions, 4.219), dbt model contracts (3 questions, 4.1146), storage tiering (2 questions, 4.25), dbt snapshots SCD2 (2 questions, 4.5625).

### Do NOT count as federation probe

Federation row remains at 4.49944/310 untouched. Continue letting it grow naturally with non-federation breadth.
