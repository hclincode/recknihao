# Iter1168 — Judge Feedback

## Verdict: PASS + FIX-A — Average 4.4219 / 5.0

| Q | Topic row | Score | Verdict |
|---|---|---:|---|
| Q1 Postgres ILIKE → Trino case-insensitive (LOWER+LIKE / regexp_like) | SQL query best practices for OLAP | 4.875 | pin-perfect, both forms correct |
| Q2 per-category MEDIAN minutes opened→first_response (HARDER 2-STEP SYNTHESIS) | Analytical query patterns on Iceberg+Trino | 4.9375 | 2-level assembly CORRECT, T-Digest claim VERIFIED accurate |
| Q3 register existing Parquet on MinIO as Iceberg via migrate/snapshot | Iceberg table maintenance | 2.875 | **RESOURCE-SOURCED DEFECT — claims migrate is Spark-only when Trino 467 implements it natively** |
| Q4 Oracle NVL2 → Trino CASE / IF | Oracle PL/SQL → dbt+Trino migration | 5.0 | clean pin-perfect, both rewrites valid |

Iter average = (4.875 + 4.9375 + 2.875 + 5.0) / 4 = **4.4219 PASS** (margin +0.9219 over 3.5 threshold, Q3 drags hard).

---

## Per-question detail

### Q1 (4.875 — Acc 5.0 / Clar 4.75 / App 5.0 / Compl 4.75) — Postgres ILIKE → Trino case-insensitive

**Verified correct on all load-bearing facts:**
- "Trino has NO native ILIKE — parse error" — confirmed via [trino.io/docs/467/functions/comparison.html](https://trino.io/docs/467/functions/comparison.html) ("Matching characters is case sensitive"; no ILIKE keyword in the comparison or LIKE syntax tables). Matches pinned `reference_trino_no_ilike.md`.
- Option 1: `WHERE LOWER(customer_name) LIKE '%acme%'` — correct, canonical case-fold-then-LIKE.
- Option 2: `WHERE regexp_like(customer_name, '(?i)acme')` — correct; the Java-regex inline `(?i)` case-insensitive flag is honored by Trino's `regexp_like` per [trino.io/docs/467/functions/regexp.html](https://trino.io/docs/467/functions/regexp.html) (Trino regex uses java.util.regex semantics, which supports embedded flag expressions).
- Suffix example `LOWER(filename) LIKE '%.csv'` / `regexp_like(filename, '(?i)\.csv$')` correct (single-backslash regex literal per pinned `reference_trino_regex_backslash.md`).
- "Normalize with LOWER() at ingest" tip is the right durable fix.

**Minor completeness shave (-0.25 Compl):** did not name the partition-pruning caveat — applying `LOWER(col)` on a partition/sort key can hide the bare column from Iceberg pruning. Engineer's scenario (free-text customer_name search) is not a partitioned column, so the omission is non-load-bearing. NOT a defect.

Cites r23. Resource-aligned.

### Q2 (4.9375 — Acc 5.0 / Clar 4.75 / App 5.0 / Compl 5.0) — per-category MEDIAN minutes opened→first_response (HARDER 2-STEP SYNTHESIS)

**THE 2-STEP ASSEMBLY IS CORRECTLY ASSEMBLED.** This was the key check for this iter; reporting in detail:

**Step 1 (CTE pivot per ticket):**
```sql
WITH ticket_gaps AS (
  SELECT category, ticket_id,
         date_diff(
           'minute',
           MIN(CASE WHEN event_type='opened' THEN event_time END),
           MIN(CASE WHEN event_type='first_response' THEN event_time END)
         ) AS minutes_to_response
  FROM tickets
  WHERE event_type IN ('opened','first_response')
  GROUP BY category, ticket_id
)
```
- **Grain correct:** `GROUP BY category, ticket_id` produces exactly one row per ticket (per category, which is fine because tickets don't change category across events).
- **Pivot correct:** `MIN(CASE WHEN event_type='opened' THEN event_time END)` returns the opened-event timestamp for that ticket; CASE returns NULL on non-matching rows; MIN ignores NULLs per [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/467/functions/aggregate.html). Same for first_response.
- **date_diff arg order correct:** verified via [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html): `date_diff(unit, timestamp1, timestamp2) → bigint` returns "`timestamp2 - timestamp1` expressed in terms of `unit`" — so earlier=arg2, later=arg3 for positive result. Responder's explicit swap-warning ("if you swap, you'll get a negative number") is correct and useful.
- **WHERE event_type IN ('opened','first_response') predicate** correctly drops 'resolved' rows before the pivot — small efficiency win, doesn't change correctness.

**Step 2 (outer median per category):**
```sql
SELECT category, approx_percentile(minutes_to_response, 0.5) AS median
FROM ticket_gaps
WHERE minutes_to_response IS NOT NULL
GROUP BY category;
```
- **`approx_percentile(x, 0.5)` correctly used as median** per [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/467/functions/aggregate.html) (verified via WebFetch — signature `approx_percentile(x, percentage) → [same as x]`).
- **NULL filter correct:** tickets missing one event (opened-but-no-response, or response-without-opened) produce NULL `minutes_to_response` — sensible to exclude before percentile.
- **GROUP BY category** for per-category median — correct grain.

**Claim verifications:**
1. **"No MEDIAN aggregate in Trino 467"** — VERIFIED CORRECT. WebFetch of trino.io/docs/467/functions/aggregate.html lists only `approx_percentile`, `tdigest_agg`, `qdigest_agg`, `value_at_quantile` — no `median()` function.
2. **"No PERCENTILE_CONT / PERCENTILE_DISC ordered-set aggregates"** — VERIFIED CORRECT. The Trino 467 aggregate-functions page does not list these (they are SQL:2003 ordered-set aggregates that PostgreSQL/Oracle support but Trino has not implemented).
3. **"approx_percentile multi-quantile array form"** — VERIFIED CORRECT. Doc: "Returns the approximate percentile for all input values of `x` at each of the specified percentages. Each element of the `percentages` array must be between zero and one." Responder's example `approx_percentile(x, ARRAY[0.25,0.5,0.75,0.95])` is the canonical multi-quantile call.
4. **"approx_percentile uses T-Digest sketches internally"** — VERIFIED ACCURATE for Trino current. Per [trinodb/trino PR #5158](https://github.com/trinodb/trino/pull/5158) "Add T-digest type and functions" + subsequent change replacing QuantileDigest with T-Digest in the implementation of `approx_percentile(x, percentage)` and `approx_percentile(x, weight, percentage)` overloads. The 4-arg `approx_percentile(x, weight, percentage, accuracy)` overload still uses QuantileDigest. The responder's blanket "uses T-Digest sketches internally" is mostly accurate (3 of 4 overloads), only the 4-arg accuracy form is qdigest. Engineer-action wise, the routing-level claim (sketch-based, fast on huge data, approximate) is correct. **MINOR shave already absorbed in Acc score** — not load-bearing for the engineer's per-category-median query (uses the 2-arg overload which IS t-digest).

**Conclusion: HARDER 2-STEP SYNTHESIS PIN-PERFECTLY ASSEMBLED.** No grain misread, no nested-aggregate trap, no `approx_percentile`-inside-OVER fabrication, no swap on date_diff args. Clean canonical reach on a 2-level question. Cites r23. Resource-aligned.

### Q3 (2.875 — Acc 2.0 / Clar 4.0 / App 2.5 / Compl 3.0) — register Parquet on MinIO as Iceberg

**DEFECT: RESOURCE-SOURCED FACTUAL ERROR on `migrate` Spark-only claim.**

**What the responder said (lifted from resources):**
- "Option 1 in-place: `CALL iceberg.system.migrate('analytics.events')` — Spark SQL, NOT Trino"
- "Option 2 shadow: `CALL iceberg.system.snapshot('analytics.events','analytics.events_iceberg')` — Spark-only"
- "Follow up `CALL iceberg.system.rewrite_manifests(...)` — Spark-only"

**Verified facts:**

1. **`system.migrate` IS NATIVE in Trino 467 — NOT Spark-only.** Verified via [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) "Procedures" section. Direct quote of the documented call shape:
   ```sql
   CALL example.system.migrate(
     schema_name => 'testdb',
     table_name => 'customer_orders')
   ```
   Plus optional `recursive_directory => 'true'|'false'|'fail'` parameter. **Enabled by default — no `iceberg.migrate-procedure.enabled` flag needed** (unlike `register_table` / `add_files_from_table` which DO need explicit enablement). Accepts Parquet, ORC, or Avro source files. Bucketed Hive tables convert to non-bucketed Iceberg tables.

   The feature was added via [trinodb/trino#13493](https://github.com/trinodb/trino/pull/13493), closing feature request [trinodb/trino#13196](https://github.com/trinodb/trino/issues/13196). It has been available natively in Trino for many releases before 467.

2. **`system.snapshot` (shadow-copy form) IS Spark-only** — VERIFIED CORRECT. Trino 467 docs do not list a `snapshot` procedure; the Spark-side `system.snapshot(source, target)` is documented only at [iceberg.apache.org/docs/latest/spark-procedures/](https://iceberg.apache.org/docs/latest/spark-procedures/). Responder is right on this one.

3. **`system.rewrite_manifests` IS Spark-only** — VERIFIED CORRECT. Trino's manifest rewriting is `ALTER TABLE ... EXECUTE optimize_manifests`, available in Trino 470+ (PR #24678), NOT in 467. Responder is right on this one.

4. **Missing alternatives the responder did not name:**
   - **`register_table`** — Trino 467 native (gated by `iceberg.register-table-procedure.enabled=true`). For the engineer's scenario ("hundreds of millions of rows in Parquet on MinIO from old Spark jobs, already date-partitioned dirs, register existing files as an Iceberg table without a full ETL reload"), `register_table` is the lighter-weight option IF the source already has an Iceberg `metadata.json` somewhere (it doesn't here — Hive Parquet wouldn't), so the right answer for the engineer's scenario truly IS `migrate`.
   - **`add_files`** — Trino 467 native (gated by `iceberg.add-files-procedure.enabled=true`). Adds existing Parquet/ORC/Avro files into an already-existing Iceberg table — useful as a follow-on or for partial-partition imports.

**Practical impact:** The engineer follows the responder's advice and spins up a Spark session (which the production stack DOES have per prod_info.md "Apache Spark with Iceberg 1.5.2 backed by Hive Metastore (ingestion use only)") to run `CALL iceberg.system.migrate(...)`. That works. But they could have done it natively from Trino with the exact same procedure name — saving the Spark detour. The mental model "Trino can't migrate Hive to Iceberg, you must use Spark" is durably wrong and will mis-direct future similar questions.

**Source classification: RESOURCE-SOURCED DEFECT — NOT a one-off responder slip.** Grep results confirm the responder lifted the false claim from the resources:

- `resources/21-hive-metastore-iceberg.md:78` "Both run from **Spark SQL** (not Trino — Trino does not implement the migration stored procedures)."
- `resources/21-hive-metastore-iceberg.md:141` "Runs from Spark, not Trino | Trino does not implement `CALL system.migrate()`. Use a Spark session or a Spark-based notebook."
- `resources/21-hive-metastore-iceberg.md:147` "run `CALL iceberg.system.migrate('your_schema.your_table')` from Spark."
- `resources/17-iceberg-table-maintenance.md:231` "`publish_changes`, `cherrypick_snapshot`, `migrate`, `snapshot` (table-snapshot form) | Various migration/WAP flows. | Spark only."
- `resources/17-iceberg-table-maintenance.md:912` "`publish_changes`, `cherrypick_snapshot`, `set_current_snapshot` (procedure form), `migrate`, `snapshot` (the table-snapshot form for migration) — all Spark-only."

The responder followed the resource correctly; the resource has the wrong fact. Per pinned `feedback_trace_recurring_folklore_to_resource_root_cause.md` — confirmed before declaring it a pure responder slip.

**FIX-A SPEC (REQUIRED):**

1. **r21 §78 + §80-95 + §141 + §147** — REWRITE migrate framing:
   - Replace "Both run from Spark SQL (not Trino)" with "**`migrate` runs natively in Trino 467 via `CALL iceberg.system.migrate(schema_name => '...', table_name => '...')` — no Spark required.** `snapshot` (shadow copy) remains Spark-only because Trino 467 does not implement the snapshot procedure."
   - Replace the §86 example with Trino-native form: `CALL iceberg.system.migrate(schema_name => 'analytics', table_name => 'events');` (named args required by Trino).
   - Add the `recursive_directory => 'true'|'false'|'fail'` parameter as an optional argument (default is `'fail'`).
   - Replace the §141 table row "Runs from Spark, not Trino" with "Runs natively in Trino 467 (and from Spark — both work; Trino is simpler if you don't already have a Spark session)."
   - Update §147 bottom-line: "run `CALL iceberg.system.migrate(schema_name => 'analytics', table_name => 'events')` from **Trino directly** (or Spark if you prefer)."
   - Cite the Trino docs URL [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html) "Procedures" section.
   - Cite the PR that added it: [trinodb/trino#13493](https://github.com/trinodb/trino/pull/13493).

2. **r17 §231 (Spark-only procedures table)** — REMOVE `migrate` from the Spark-only list. Keep `publish_changes`, `cherrypick_snapshot`, `snapshot` (table-snapshot form) as Spark-only.

3. **r17 §912** — REMOVE `migrate` from the "all Spark-only" sentence. Keep the others.

4. **Add new entry near r17 §219 (Trino-native CALL procedures table)**: `migrate` row with named-arg syntax + `recursive_directory` parameter + supported formats Parquet/ORC/Avro + "no flag needed (enabled by default)" + use-case "convert an existing Hive Parquet table to Iceberg in place without rewriting data files."

5. **Cross-ref from r21 §migration to r17 §219 register_table/migrate Trino-native procedure table.**

6. **DO-NOT-WRITE** (defang the now-corrected myth at top of r21): "Trino cannot migrate Hive Parquet to Iceberg — you must use Spark" — WRONG since Trino 401-ish; Trino 467 has the native `CALL iceberg.system.migrate(...)` procedure with `recursive_directory` option.

7. **Keyword anchors to embed near the corrected r21 §migrate**: "hundreds of millions of rows in Parquet on MinIO from old Spark jobs", "register existing files as an Iceberg table without ETL reload", "Hive Parquet to Iceberg without rewriting data", "do I need Spark to migrate to Iceberg", "metadata-only Hive to Iceberg conversion Trino", "in-place Iceberg migration from Trino".

8. **PIN the corrected fact** in CLAUDE.md memory: `reference_trino_iceberg_migrate_native.md` — Trino 467 implements `CALL iceberg.system.migrate(schema_name => ..., table_name => ...)` natively, enabled by default (unlike register_table/add_files), accepts Parquet/ORC/Avro source. Past resource claim "migrate is Spark-only" was wrong; corrected r21+r17.

**Watch label:** `r21+r17 migrate-Trino-native FIX-A iter1168` — re-probe in next sweep with structurally similar question ("can I convert my Hive Parquet table to Iceberg directly from Trino or do I need Spark?") to confirm FIX-A reaches. If reaches → close watch. If still routes to Spark-only → escalate to top-of-r21 callout box.

### Q4 (5.0 — Acc 5.0 / Clar 5.0 / App 5.0 / Compl 5.0) — Oracle NVL2 → Trino CASE / IF

**Verified correct on all facts:**
- "Trino has no NVL2" — verified via [trino.io/docs/467/functions/conditional.html](https://trino.io/docs/467/functions/conditional.html). The page lists `if`, `coalesce`, `nullif`, `try`, `CASE` — no `nvl2`. (Trino does have NVL/2-arg-COALESCE coverage; only the 3-arg NVL2 is Oracle-specific.)
- `CASE WHEN commission_rate IS NOT NULL THEN base_salary*1.1 ELSE base_salary END` — correct, ANSI-standard CASE shape.
- `IF(commission_rate IS NOT NULL, base_salary*1.1, base_salary)` — correct. Verified `if(condition, true_value, false_value)` signature: "Evaluates and returns `true_value` if `condition` is true, otherwise evaluates and returns `false_value`."
- Anatomy mapping (arg1 → `IS NOT NULL` test, arg2 → THEN/true_value, arg3 → ELSE/false_value) is the right migration mental model — engineer porting hundreds of NVL2 calls knows exactly the find-and-replace pattern.

Cites r27. Clean 5.0 all dimensions.

---

## Topic row updates

| Topic | Before | After | Delta |
|---|---|---|---|
| SQL query best practices for OLAP (Q1) | 4.5859 / 237 | (4.5859 × 237 + 4.875)/238 ≈ **4.5871 / 238** | +0.0012 micro-lift |
| Analytical query patterns on Iceberg+Trino (Q2) | 4.5293 / 119 | (4.5293 × 119 + 4.9375)/120 ≈ **4.5327 / 120** | +0.0034 micro-lift |
| Iceberg table maintenance (Q3) | 4.4561 / 193 | (4.4561 × 193 + 2.875)/194 ≈ **4.4480 / 194** | **-0.0081 drag** (still PASSED, margin +0.9480) |
| Oracle PL/SQL → dbt+Trino migration (Q4) | 4.4675 / 136 | (4.4675 × 136 + 5.0)/137 ≈ **4.4714 / 137** | +0.0039 micro-lift |

ALL required topics REMAIN PASSED.

---

## Source-verified outcomes this iter
- 0 dialect errors on Q1/Q2/Q4
- 0 findability gaps
- 1 resource-sourced false-fact (Q3 migrate-Spark-only) — FIX-A REQUIRED
- 0 responder over-warning folklore
- 1 strong reach on harder 2-step synthesis (Q2) — clean assembly

## Recommendation

**PASS + LIGHT FIX-A.** Iter average 4.4219 well above threshold; topic margins intact. Q3 defect is RESOURCE-sourced (r21 + r17 both teach the wrong "Trino doesn't implement migrate" claim) — teacher to fix per the FIX-A spec above. Q1/Q2/Q4 clean reaches; Q2 harder synthesis confirms the 2-level CTE-pivot-then-aggregate pattern is durable. Continue breadth probing next iter; re-probe migrate-Trino-vs-Spark with different phrasing to confirm FIX-A reaches.

**Open watches:** `r21+r17 migrate-Trino-native FIX-A iter1168` (new this iter — re-probe in next sweep).
