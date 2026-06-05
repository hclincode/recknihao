# Judge Feedback — Iter 486 (Extended Phase — end-of-iteration)

**Overall: 4.3906 PASS** (~0.89 above 3.5 floor; thinner margin than iter485's 4.703)
**Phase: extended — end-of-iteration feedback**
**Federation: NOT probed this iter (4.49944/310 row held per directive)**

| Q | Topic | Score | Verdict |
|---|---|---|---|
| Q1 | Trino UNNEST array per-tag count | 4.875 | STRONG PASS — ZERO fabs |
| Q2 | Iceberg col reorder + SET NOT NULL on Trino 467 (4-step workaround) | 4.8125 | STRONG PASS — handled the NOT-NULL trap |
| Q3 | Small static CSV plan-code lookup (dbt seed) | 4.0625 | PASS — minor outdated-path nit (`data/` vs `seeds/`) |
| Q4 | Spark partitioned write — tiny files + OOM | 3.8125 | PASS — fabricated Spark session conf key |

---

## Per-question detail

### Q1 — Trino UNNEST array per-tag count — 4.875 STRONG PASS
- Accuracy 5.0 / Completeness 4.75 / Clarity 4.75 / Actionability 5.0
- `CROSS JOIN UNNEST(tags_column) AS t(tag) ... GROUP BY tag` is canonical Trino per trino.io/docs/current/sql/select.html#unnest.
- `GROUP BY tag` is safe here — `tag` is a real unnested output column produced by the UNNEST alias, NOT an expression-alias-reference (so no GROUP-BY-alias-reference issue like iter484 Q2).
- Partition filter (`event_date = DATE '...'`) on the base table side still prunes before the CROSS JOIN.
- ZERO fabs.

### Q2 — Iceberg column reorder + SET NOT NULL on Trino 467 — 4.8125 STRONG PASS
- Accuracy 5.0 / Completeness 4.75 / Clarity 4.5 / Actionability 5.0
- **Handled the NOT-NULL trap correctly.** WebFetch of trino.io/docs/current/sql/alter-table.html confirms the ALTER COLUMN variants on Trino-current are exactly: `SET DEFAULT`, `DROP DEFAULT`, `SET DATA TYPE`, **`DROP NOT NULL`** — `SET NOT NULL` is NOT listed (asymmetric on purpose).
- The 4-step workaround (ADD `country_code_v2` nullable / UPDATE backfill via COALESCE / DROP old / RENAME new) is the canonical Trino-467-compatible recipe.
- Iceberg's field-ID model keeps old data files readable through the ADD/DROP/RENAME chain — metadata-only operations per Iceberg connector docs.
- Column-position-doesn't-matter framing (columnar storage; field-ID indexing) correct; "use explicit column lists" is the right pragmatic fix (no Trino DDL for column reorder).
- ZERO fabs.

### Q3 — Small static CSV plan-code lookup (dbt seed) — 4.0625 PASS
- Accuracy 3.5 / Completeness 4.25 / Clarity 4.25 / Actionability 4.25
- Concept correct: dbt seed for small static CSV → `dbt seed` loads → `{{ ref('plans') }}` references. Right tool for plan-code lookup.
- **MINOR INACCURACY (fab class: outdated-default-path / version-pin-spillover)**: responder placed CSV at `dbt_project_root/data/plans.csv`. The `data/` directory was the PRE-dbt-1.0 default. **Current default since dbt 1.0 (Dec 2021, 4+ years stale) is `seeds/`** per docs.getdbt.com/reference/project-configs/seed-paths ("By default, dbt expects seeds to be located in the `seeds` directory. For example, `seed-paths: [\"seeds\"]`").
- Paste-and-fail for a new project (the implied context) unless engineer explicitly sets `seed-paths: ["data"]` in dbt_project.yml.
- `{{ ref('plans') }}` to reference seed by basename is correct per docs.getdbt.com/docs/build/seeds.

### Q4 — Spark partitioned write tiny files + OOM — 3.8125 PASS
- Accuracy 3.5 / Completeness 4.0 / Clarity 4.0 / Actionability 3.75
- **Correct primary recipe** (first half):
  - `write.target-file-size-bytes` = 128MB as TABLE PROPERTY — REAL (default 512MB / 536870912 per Iceberg docs; settable via TBLPROPERTIES at CREATE or ALTER TABLE SET TBLPROPERTIES).
  - `write.distribution-mode` = 'hash' as TABLE PROPERTY — REAL per iceberg.apache.org/docs/latest/spark-writes; valid values `none` / `hash` / `range`; `hash` requests Spark hash-shuffle by partition value to avoid fan-out OOM. Default changed to `hash` in Iceberg 1.2.0 / Spark 3.3, so on Iceberg 1.5.2 this matches the current default.
  - `writeTo().tableProperty(...).create()` form correct.
  - `CREATE TABLE TBLPROPERTIES(...)` form correct.
- **LOAD-BEARING FAB (fabricated-conf-property class — recurrence of iter474/478/479 fabricated-session-property class)**: `spark.conf.set("spark.sql.iceberg.target_file_size_bytes", "134217728")` is **NOT a documented Iceberg Spark session conf key**.
  - Verified via WebSearch + WebFetch of iceberg.apache.org/docs/latest/spark-configuration + spark-writes + guptaakashdeep.com/are-your-iceberg-writes-optimized.
  - The only documented mechanisms for setting Iceberg target file size from Spark are:
    1. TABLE PROPERTY: `write.target-file-size-bytes` (persistent; set via TBLPROPERTIES at CREATE or via `ALTER TABLE ... SET TBLPROPERTIES('write.target-file-size-bytes'='134217728')`).
    2. DataFrameWriter OPTION: `target-file-size-bytes` (per-write; e.g., `df.writeTo(t).option("target-file-size-bytes", "134217728").overwrite(...)`).
  - The `spark.sql.iceberg.` namespace is real (legitimate keys exist: `spark.sql.iceberg.handle-timestamp-without-timezone`, `spark.sql.iceberg.vectorization.enabled`, `spark.sql.iceberg.check-nullability`, `spark.wap.id`, `spark.wap.branch`), but `target_file_size_bytes` under that namespace is fabricated.
  - Failure mode: Spark accepts arbitrary string conf keys silently — `spark.conf.set("spark.sql.iceberg.target_file_size_bytes", "...")` will be stored but no Iceberg code path reads it; file size remains at the default 512MB or whatever the table property says. Engineer thinks they fixed it but tiny files persist.
  - LOAD-BEARING because the "if past table creation" fallback is the most operationally common situation (adjusting file size on an existing table), and the answer directs engineer to a fake conf key instead of the real `ALTER TABLE SET TBLPROPERTIES` or per-write `.option()`.

---

## Fabrication / inaccuracy log

| # | Class | Where | Wrong | Correct | Source |
|---|---|---|---|---|---|
| 1 | outdated-default-path / version-pin-spillover | Q3 | `dbt_project_root/data/plans.csv` | `dbt_project_root/seeds/plans.csv` (default since dbt 1.0, Dec 2021) | docs.getdbt.com/reference/project-configs/seed-paths |
| 2 | fabricated-conf-property (sibling of fabricated-session-property) | Q4 | `spark.conf.set("spark.sql.iceberg.target_file_size_bytes", "134217728")` | TABLE PROPERTY `write.target-file-size-bytes` (via TBLPROPERTIES or ALTER TABLE SET TBLPROPERTIES) OR DataFrameWriter `.option("target-file-size-bytes", "134217728")` | iceberg.apache.org/docs/latest/spark-configuration + iceberg.apache.org/docs/latest/spark-writes |

---

## Teacher actions for iter 487

### PRIMARY (2 surgical fixes — both load-bearing)

**Fix 1: dbt seed default path canonical anchor**
- Grep `resources/` for any `data/` reference used as a dbt seed path.
- Install LEADING CANONICAL anchor (likely in the dbt-tooling resource, or wherever seeds are mentioned):
  > **dbt seed directory — default since dbt 1.0 (Dec 2021) is `seeds/`**
  > Place small static CSVs at `dbt_project_root/seeds/plans.csv`. Reference via `{{ ref('plans') }}` (basename, no extension). Run `dbt seed` to load.
  > **Do NOT use `data/`** — that was the pre-dbt-1.0 default and is deprecated. A new project will fail with "No seed files found" if you place files in `data/`. Override the default only by setting `seed-paths: ["custom_dir"]` in `dbt_project.yml`.
  > Citation: docs.getdbt.com/reference/project-configs/seed-paths.
- DO-NOT-WRITE row banning `data/` as the assumed default seed dir for any dbt 1.0+ project.

**Fix 2: Iceberg Spark file-size 3-tier canonical card**
- Locate in r17 (Iceberg table maintenance) or wherever Spark-write file-sizing is covered; if not present, add a new section.
- Install LEADING CANONICAL "Spark Iceberg target file size — 3 tiers" card:
  > 1. **TABLE PROPERTY (persistent)**: `write.target-file-size-bytes` — set via `CREATE TABLE ... TBLPROPERTIES('write.target-file-size-bytes'='134217728')` or `ALTER TABLE db.t SET TBLPROPERTIES('write.target-file-size-bytes'='134217728')`. Default 536870912 (512MB).
  > 2. **PER-WRITE OPTION (one-off)**: `df.writeTo(t).option("target-file-size-bytes", "134217728").overwrite(...)` — overrides table property for this write only.
  > 3. **NO Spark session conf**: there is NO `spark.sql.iceberg.target_file_size_bytes` (or `target-file-size-bytes`) session-level key. Setting one via `spark.conf.set(...)` silently no-ops — Spark stores the key but Iceberg never reads it.
  > Citation: iceberg.apache.org/docs/latest/spark-configuration + iceberg.apache.org/docs/latest/spark-writes.
- DO-NOT-WRITE row explicitly banning `spark.sql.iceberg.target_file_size_bytes`, `spark.sql.iceberg.target-file-size-bytes`, and any `spark.sql.iceberg.*` key claimed for file sizing.
- This is the **fourth recurrence** of the fabricated-conf-property / fabricated-session-property class (after iter474 `distributed_join_distribution_type`, iter478 `task_max_memory` + `memory_revoking_enabled`, iter479 `spill_order_by_enabled`) — the pattern is now a recognized failure mode. The fix shape is well-trodden: explicit allow-list + DO-NOT-WRITE row + cite docs.

### SECONDARY

- **Breadth design 4-Q with NO dedicated federation probe** (federation 4.49944/310 row held per iter472-485+ directive).
- Q1 (UNNEST) and Q2 (SET NOT NULL trap + 4-step workaround) were ZERO-fab STRONG PASS — consider a 2nd-angle re-probe on Trino SET NOT NULL trap from a different angle (e.g., engineer pastes the Trino error message verbatim, or asks "I'm coming from PostgreSQL — why doesn't ALTER TABLE ... ALTER COLUMN SET NOT NULL work?") at iter488-490 to lock the iter486 STRONG PASS at 2+ confirmations.
- Low-count topics still worth additional datapoints: dbt sources freshness (3 questions, 4.219), dbt model contracts (3 questions, 4.1146), storage tiering (2 questions, 4.25), dbt snapshots SCD2 (2 questions, 4.5625).

### Schedule note

- 5-min cadence: **delaySeconds=300** for ScheduleWakeup (MANDATORY as last action of every turn).
