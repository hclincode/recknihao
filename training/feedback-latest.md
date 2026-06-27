# Iter1182 Judge Feedback

**Overall verdict:** **FIX-A on Q3** — load-bearing `register_table` argument-name slip is RESOURCE-SOURCED (`r17` §244 / §911 / §3848-3853 / §3856-3859 all use a WRONG `metadata_file => '<s3a://full-path-to-metadata.json>'` form for Trino 467; the actual 467 signature is `table_location => '<directory>' + metadata_file_name => '<filename-only>'`, verified at git-tag 467 source `RegisterTableProcedure.java`). The responder muddied it further into `metadata_location =>` (mixing in r21's HMS column-name term). Q1, Q2, Q4 all clean; Q4 has a minor cosmetic MySQL-vs-Oracle slip in the contrast example but the dbt/Trino target is correct.

**Iter1182 watches OPENED:**
- **`r17 register_table arg-name slip — Trino 467 uses table_location + metadata_file_name (NOT metadata_file / NOT metadata_location) FIX-A iter1182`** — multi-site (r17 §244, §911, §3848-3853, §3856-3859) resource defect. Responder pulled wrong form from r17 and degraded further on the arg name. LIGHT FIX-A required: rewrite r17 register_table snippets to the verified 467 signature; defang the wrong arg names with DO-NOT-WRITE inline-WRONG markers; cross-ref from r21 HMS section to disambiguate `metadata_location` (HMS table-property COLUMN NAME) vs procedure ARG NAME.

Total iter1182 score: (4.75 + 4.75 + 3.0 + 4.625) / 4 = **4.28125 / 5**

| Q | Topic | Score | Note |
|---|---|---|---|
| 1 | SQL best practices — `map(keys_array, values_array)` 2-arg constructor | 4.75 | Pin-perfect; element_at NULL vs subscript-throws nuance + duplicate-key runtime-error + map_agg-for-dupes all correct |
| 2 | SQL best practices — `stddev_samp / avg` coefficient-of-variation scale-invariant spread | 4.75 | Pin-perfect; CV = stddev/mean correct, NULLIF guard correct, samp vs pop choice correct |
| 3 | Iceberg table maintenance — same-HMS Spark→Trino visibility + `register_table` recovery | 3.0 | **FIX-A** — broken `register_table` arg name (`metadata_location` does not exist in Trino 467; resource r17 also wrong with `metadata_file`); also missed naming Hadoop-vs-HMS catalog mismatch as the most common production cause |
| 4 | Oracle PL/SQL → dbt+Trino — cursor loop → set-based + dbt incremental merge | 4.625 | Translation table correct; minor cosmetic slip — contrast example uses MySQL `ON DUPLICATE KEY UPDATE` mislabeled as Oracle (Oracle uses `MERGE`) — dbt/Trino target correct |

---

## Q1 — `map(metric_names, metric_values)` 2-arg constructor pairs two same-length arrays

**Score: 4.75** (Tech 5 / Clarity 4.5 / Practical 5 / Completeness 4.5)

Pin-perfect. Verified at [trino.io/docs/current/functions/map.html](https://trino.io/docs/current/functions/map.html):

1. **`map(array(K), array(V)) → map(K,V)`** — 2-arg constructor pairs two same-length arrays; doc example `map(ARRAY[1,3], ARRAY[2,4])` → `{1 -> 2, 3 -> 4}`. Responder's `map(metric_names, metric_values)` correctly identifies the one-call form (no UNNEST + re-aggregate roundtrip needed). The question is direct: "Trino function that pairs two same-length arrays into a key-value map, or must unnest+re-aggregate?" Answer is the 2-arg `map()` constructor — exactly what was given.

2. **`element_at(map, key)` returns NULL on missing key** — verified verbatim at docs: "Returns value for given `key`, or `NULL` if the key is not contained in the map."

3. **Subscript `map[key]` throws on missing key** — verified verbatim at docs: "This operator throws an error if the key is not contained in the map. See also `element_at` function that returns `NULL` in such case." Engineer's lookup choice (NULL-safe vs throw) hinges on this distinction; responder gave both correctly.

4. **Duplicate keys raise a runtime error** — verified via [duckdb#3640 referencing Presto behavior](https://github.com/duckdb/duckdb/issues/3640): `MAP(ARRAY[1,1,3,4], ARRAY[10,9,8,7])` throws "Duplicate map keys are not allowed" at runtime in Trino/Presto. Responder named this correctly and gave the right escape hatch (`map_agg` if the keys may collide — `map_agg` per docs "Returns a map created from the input key/value pairs" with later-wins-style behavior, suitable for dedup-during-construction).

5. **Keys non-NULL constraint** — correctly noted; Trino throws on NULL map keys at runtime.

Engineer arrives at `map(metric_names, metric_values)` for the lookup MAP and knows to pick `element_at(m, 'clicks')` for the NULL-safe path. Cites r07. Topic: **SQL query best practices for OLAP** — 4.5724/260 → (4.5724×260 + 4.75)/261 = **4.5731/261 PASSED** (+0.0007, margin +1.0731).

---

## Q2 — Coefficient of variation = `stddev_samp / avg` for scale-invariant spread

**Score: 4.75** (Tech 5 / Clarity 4.5 / Practical 5 / Completeness 4.5)

Pin-perfect. Verified at [trino.io/docs/current/functions/aggregate.html](https://trino.io/docs/current/functions/aggregate.html):

1. **`stddev_samp(x) → double`** — "Returns the sample standard deviation of all input values." Confirmed exists in 467.
2. **`stddev_pop(x) → double`** — "Returns the population standard deviation of all input values." Confirmed exists.
3. **`stddev(x)` is an alias for `stddev_samp(x)`** — confirmed at docs ("This is an alias for `stddev_samp()`"). Responder correctly preferred the explicit `stddev_samp` name over the bare `stddev` alias for clarity.

The mathematical claim is correct: **coefficient of variation (CV) = σ/μ** is the textbook unit-less measure of relative dispersion (scale-invariant), exactly the metric for "how spread out is this account's revenue relative to its own average". Raw stddev across accounts of different revenue scales is not comparable — a $10K-MRR account with $1K stddev (CV = 0.10) is more erratic in relative terms than a $1M-MRR account with $50K stddev (CV = 0.05); the raw figure inverts the conclusion. Responder framed this correctly.

Query structure correct:
```sql
SELECT
  account_id,
  avg(monthly_revenue) AS avg_rev,
  stddev_samp(monthly_revenue) AS std_rev,
  stddev_samp(monthly_revenue) / NULLIF(avg(monthly_revenue), 0) AS cv
FROM monthly_billing
GROUP BY account_id
ORDER BY cv DESC
```
- `NULLIF(avg, 0)` correctly guards against division-by-zero (which on DOUBLE/REAL `/` would return Infinity/NaN per IEEE-754, not throw — per pinned `reference_trino_division_by_zero` — but on INTEGER/DECIMAL would throw; guard is safer regardless).
- Revenue columns being DECIMAL/DOUBLE → division is DOUBLE/DECIMAL division, NO integer-truncation issue.
- Single-pass GROUP BY exactly satisfies the "single-pass SQL" ask.
- `ORDER BY cv DESC` correctly ranks most-erratic-first.

Sample vs population choice rationale (use samp for SaaS where months are a sample of the underlying revenue process) correctly given. Cites r05.

Topic: **SQL query best practices for OLAP** — 4.5731/261 → (4.5731×261 + 4.75)/262 = **4.5738/262 PASSED** (+0.0007, margin +1.0738).

---

## Q3 — Spark→Trino HMS Iceberg visibility + `register_table` recovery — **FIX-A**

**Score: 3.0** (Tech 2.5 / Clarity 4 / Practical 2.5 / Completeness 3)

**Two defects: one load-bearing (broken `register_table` arg name, RESOURCE-SOURCED), one minor (missed Hadoop-vs-HMS catalog mismatch as most common cause).**

### Defect 1 (LOAD-BEARING, RESOURCE-SOURCED) — `register_table` arg name wrong

Responder's recovery SQL:
```sql
CALL iceberg.system.register_table(
  schema_name => '..',
  table_name => '..',
  metadata_location => 's3a://.../metadata/00000-abc.metadata.json'   -- WRONG ARG NAME
)
```

**Verified at the SOURCE LEVEL — Trino 467 git-tag [`RegisterTableProcedure.java`](https://github.com/trinodb/trino/blob/467/plugin/trino-iceberg/src/main/java/io/trino/plugin/iceberg/procedure/RegisterTableProcedure.java) declares exactly four argument constants:**

| # | Arg name (Trino 467) | Type | Required | Value shape |
|---|---|---|---|---|
| 1 | `schema_name` | VARCHAR | yes | schema name |
| 2 | `table_name` | VARCHAR | yes | table name |
| 3 | `table_location` | VARCHAR | yes | **directory URI** (e.g., `s3a://lakehouse/analytics/events/`) |
| 4 | `metadata_file_name` | VARCHAR | optional (null default) | **filename only** (e.g., `'v18.metadata.json'`) |

The correct 467 form (verified at [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html)):
```sql
CALL iceberg.system.register_table(
  schema_name        => 'analytics',
  table_name         => 'events',
  table_location     => 's3a://lakehouse/analytics/events/',
  metadata_file_name => 'v18.metadata.json'   -- optional, filename ONLY
);
```

**Engineer who copies the responder's form gets a parse/argument error:** Trino does not recognize `metadata_location` as a register_table parameter (it's the HMS table-property COLUMN name in the metastore backing store, not a procedure arg). Even substituting `metadata_file` (the form r17 currently has) is also wrong for 467, AND passing a full s3a:// path to a specific metadata.json is the wrong value shape — `table_location` expects the DIRECTORY, and `metadata_file_name` expects just the filename.

**Root cause is RESOURCE-SOURCED.** Grep evidence across resources/:
- `resources/17-iceberg-table-maintenance.md` §244: `register_table | Named args (schema_name => ..., table_name => ..., metadata_file => ...)` — wrong arg name
- `resources/17-iceberg-table-maintenance.md` §911: `metadata_file => 's3a://lakehouse/.../v18.metadata.json'` — wrong arg name AND wrong value shape
- `resources/17-iceberg-table-maintenance.md` §3848-3853 (Trino-form code block): `metadata_file => 's3a://lakehouse/analytics/events/metadata/v18.metadata.json'` — wrong arg name AND wrong value shape
- `resources/17-iceberg-table-maintenance.md` §3856-3859 (Spark-form code block): `metadata_file => '...'` — the Spark Iceberg form (which IS `metadata_file` in spark-iceberg) but mislabeled as the Trino canonical

The responder's degradation from r17's `metadata_file` to `metadata_location` is a separate Haiku slip layered on top of a real resource defect (likely cross-mixing with r21 §24 / §171 / §321 / r22 §857 etc. where `metadata_location` IS the correct HMS table-property column name — but those refer to the HMS backing-store column, not a procedure ARG NAME).

**LIGHT FIX-A SPEC:**
1. Rewrite r17 §244 table row, §911 example, and the §3848-3859 code blocks to the verified 467 form: `schema_name => '...', table_name => '...', table_location => '<directory>', metadata_file_name => '<filename>'` (with `metadata_file_name` shown as optional).
2. Add an explicit DO-NOT-WRITE inline-WRONG block in r17 right under §3853 defanging BOTH wrong forms:
   - WRONG: `metadata_file => '<full path to metadata.json>'` — not a Trino 467 arg name (Spark Iceberg has it; Trino doesn't)
   - WRONG: `metadata_location => '<full path>'` — not a procedure arg at all (it's the HMS table-property column name)
3. Add cross-ref to r21 from the new defang: "If you're looking up the current `metadata_location` HMS column to find the latest snapshot pointer, that's an HMS table-property column (r21 §171), NOT the `register_table` procedure arg name."
4. Keyword anchors for findability: "register existing Iceberg table in Trino metastore", "Spark-written Iceberg table not visible in Trino", "register_table Trino syntax", "re-attach dropped Iceberg table from surviving metadata.json".

### Defect 2 (MINOR completeness) — didn't name Hadoop-vs-HMS catalog mismatch as MOST COMMON cause

Responder said: "IF Spark wrote files but HMS never updated (misconfigured HMS client / different metastore / network), register manually..."

The single MOST COMMON real-world cause of "files-on-MinIO-but-Trino-can't-see-them-via-HMS" is **Spark using a Hadoop-type (path-based) catalog** (`spark.sql.catalog.X.type = 'hadoop'` or `'hadoopcatalog'`) that **bypasses HMS entirely** — Hadoop catalogs store all metadata in the filesystem (under `<warehouse>/<schema>/<table>/metadata/`) and never write to HMS. Trino with an HMS Iceberg catalog cannot discover those tables because the HMS row simply doesn't exist. Verified against [Trino Iceberg connector docs](https://trino.io/docs/current/connector/iceberg.html): "Trino's Iceberg connector requires access to one of several catalog types: a Hive metastore service (HMS), an AWS Glue catalog, a JDBC catalog, a REST catalog, a Nessie server, or a Snowflake catalog." Hadoop catalog is not in that list — Trino cannot read a Hadoop-catalog-only table directly; you must register it into HMS first.

The responder's "misconfigured HMS client / different metastore / network" framing is OK but misses the textbook on-prem Spark-and-Trino interop trap. On the production stack (Spark with Iceberg 1.5.2 + Trino 467, both backed by HMS per `prod_info.md`), the right diagnosis sequence is:

1. **Verify Spark IS using the HMS catalog** — `spark.sql.catalog.<name>.type = 'hive'` (not `'hadoop'`), `spark.sql.catalog.<name>.uri = thrift://<hms-host>:9083` matching what Trino's catalog properties point at.
2. If Spark is on Hadoop catalog → use `register_table` (with corrected arg names) to import the table into HMS, OR reconfigure Spark to write to the HMS catalog directly going forward.
3. If both are on HMS → check `mc ls` for `metadata/v*.metadata.json` presence on MinIO + `information_schema.tables` in Trino. The pointer should have been written atomically by Spark on commit; if it wasn't, Spark may have crashed mid-commit (rare) or there's a metastore-pointer-staleness issue.

Cites r21. Responder did include the `information_schema.tables` + `mc ls metadata/` diagnostic steps, which is good — the framework is right, the SQL is wrong.

**Topic: Iceberg table maintenance** — 4.4654/201 → (4.4654×201 + 3.0)/202 = **4.4581/202 PASSED** (-0.0073, margin still +0.9581 above threshold; one BROKEN-syntax slip absorbed by 201-question cushion). Topic stays PASSED but the FIX-A on r17 is required before next register_table re-probe.

---

## Q4 — Oracle PL/SQL cursor loop → set-based dbt + incremental merge

**Score: 4.625** (Tech 4 / Clarity 5 / Practical 5 / Completeness 4.5)

Core guidance correct and lands cleanly:

1. **Cursor loop → set-based SELECT/GROUP BY** — accurate. Responder's translation `cursor FOR rec LOOP ... LOOP END` → `SELECT customer_id, SUM(amount) FROM ref('stg_orders') GROUP BY customer_id` is the canonical procedural-to-declarative rewrite.
2. **Accumulation variable → SUM aggregate** — correct.
3. **IF/THEN → CASE** — correct (Oracle PL/SQL IF inside a cursor loop becomes a SQL `CASE WHEN ... THEN ... END` expression in the SELECT list).
4. **Row-by-row INSERT → INSERT...SELECT / dbt incremental merge** — correct. The dbt config:
   ```python
   {{ config(
       materialized='incremental',
       incremental_strategy='merge',
       unique_key='customer_id'
   ) }}
   ```
   correctly replaces the row-by-row INSERT loop with set-based MERGE on the target. Verified at [docs.getdbt.com/docs/build/incremental-strategy](https://docs.getdbt.com/docs/build/incremental-strategy) — `merge` strategy for Trino+Iceberg uses `MERGE INTO ... USING ... ON unique_key WHEN MATCHED ... WHEN NOT MATCHED INSERT ...` which Trino 467 + Iceberg connector supports per [trino.io/docs/467/sql/merge.html](https://trino.io/docs/467/sql/merge.html).
5. **Translation table** (cursor→JOIN/GROUP BY, accumulation→SUM, IF/THEN→CASE, row INSERT→INSERT...SELECT/incremental, MERGE→dbt incremental merge) — accurate and well-organized for a SaaS engineer making the mindset shift.

### Minor cosmetic slip (-1.0 Tech, but the load-bearing answer is correct)

Responder's Oracle illustrative example uses **`INSERT ... ON DUPLICATE KEY UPDATE total = total + amount`** — this is **MySQL syntax, NOT Oracle**. Oracle's row-by-row upsert in a PL/SQL cursor loop is typically `MERGE INTO ... USING (SELECT ...) ON (...) WHEN MATCHED THEN UPDATE SET ... WHEN NOT MATCHED THEN INSERT ...`, or a procedural `BEGIN UPDATE ...; IF SQL%ROWCOUNT = 0 THEN INSERT ...; END IF; END;` pattern. `ON DUPLICATE KEY UPDATE` does not exist in Oracle (introduced in MySQL 4.1, never adopted by Oracle).

This is cosmetic — the contrast example is meant to be the "before" picture, and a SaaS engineer reading the answer arrives at the correct dbt target (which IS the load-bearing part). Engineer would not run the Oracle example; they read it as scene-setting. But for a question explicitly grounded in Oracle PL/SQL, having the contrast example be MySQL syntax is a mild credibility cut.

**Classification: one-off responder Haiku slip — NO RESOURCE FIX.** Grep evidence: `grep -n "ON DUPLICATE KEY UPDATE" resources/` returns ZERO matches across r27 and the broader resources/ tree. The responder pulled the MySQL syntax out of general SQL training, not from r27. Recall ceiling. The `feedback_responder_broken_secondary_alternative` pattern is similar in family — Haiku reliably nails the LEAD (the dbt incremental merge target) then degrades on a secondary "contrast" example. Don't churn — scope as a per-instance one-off slip; the engineer arrives at the right dbt config.

Cites r27. Topic: **Oracle PL/SQL → dbt + Trino SQL migration** — 4.4653/144 → (4.4653×144 + 4.625)/145 = **4.4664/145 PASSED** (+0.0011, margin +0.9664).

---

## Summary

- **Iter1182 verdict: FIX-A on Q3 register_table arg names** — RESOURCE-SOURCED multi-site defect in r17 (§244, §911, §3848-3853, §3856-3859 all use a wrong `metadata_file => '<full path>'` form for Trino 467; the actual git-tag-source-verified form is `table_location => '<directory>' + metadata_file_name => '<filename>'`). Responder degraded it further into `metadata_location =>`. Light FIX-A required (rewrite r17 register_table snippets + inline-WRONG defang + cross-ref to r21 HMS column-name disambiguation).
- **Watches opened**: `r17 register_table arg-name slip — Trino 467 uses table_location + metadata_file_name FIX-A iter1182`; re-probe next sweep with structurally different framing ("recover dropped Iceberg table from MinIO via register_table" / "re-attach manually-uploaded metadata.json to HMS").
- **Q1, Q2 pin-perfect** on SQL best practices canonicals (map constructor + coefficient-of-variation). Both go into row 162.
- **Q4 core correct, minor cosmetic MySQL-syntax-in-Oracle-contrast slip** — recall ceiling, no resource fix.
- **All four touched rubric topics remain PASSED** with positive movement on Q1/Q2/Q4; Q3 brings Iceberg-maintenance row down 0.0073 but margin still +0.9581 above threshold.
- **Iter average 4.28125 / 5 → FIX-A.**

### Verification doc citations
- Trino 467 register_table source: [github.com/trinodb/trino/blob/467/plugin/trino-iceberg/.../RegisterTableProcedure.java](https://github.com/trinodb/trino/blob/467/plugin/trino-iceberg/src/main/java/io/trino/plugin/iceberg/procedure/RegisterTableProcedure.java)
- Trino 467 Iceberg connector docs (register_table syntax): [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html)
- Trino map() constructor + element_at + subscript: [trino.io/docs/current/functions/map.html](https://trino.io/docs/current/functions/map.html)
- Trino aggregate functions (stddev_samp / stddev_pop / stddev alias): [trino.io/docs/current/functions/aggregate.html](https://trino.io/docs/current/functions/aggregate.html)
- Trino MERGE SQL (used by dbt incremental merge on Iceberg): [trino.io/docs/467/sql/merge.html](https://trino.io/docs/467/sql/merge.html)
- dbt incremental-strategy merge: [docs.getdbt.com/docs/build/incremental-strategy](https://docs.getdbt.com/docs/build/incremental-strategy)
- Duplicate map keys runtime error reference: [github.com/duckdb/duckdb#3640](https://github.com/duckdb/duckdb/issues/3640) (referencing Presto/Trino behavior)
