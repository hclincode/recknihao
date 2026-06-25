# Judge Feedback — iter1103 (2026-06-26)

## Source verification

- **Trino 467 `all_match(array(T), function(T,boolean)) -> boolean`** — VERIFIED via WebFetch trino.io/docs/current/functions/array.html: signature `all_match(array(T), function(T, boolean)) -> boolean`; empty array returns TRUE; NULL predicate returns NULL otherwise. Matches [Trino listagg-style verify-first] / array-fn family pins.
- **Trino 467 `array_except(x, y) -> array`** — VERIFIED via WebFetch trino.io/docs/current/functions/array.html: "Returns an array of elements in `x` but not in `y`, without duplicates." So `array_except(required, user_flags)` returns `required \ user_flags`; cardinality=0 iff every required element is present in user_flags. The responder's `cardinality(array_except(ARRAY['beta_export','dark_mode','new_billing'], user_flags)) = 0` is semantically correct — argument order is right (required first as `x`, user_flags second as `y`).
- **Trino 467 `contains(array, element) -> boolean`** — VERIFIED via WebFetch array.html: "Returns true if the array `x` contains the `element`." `all_match(required, x -> contains(user_flags, x))` is the canonical "every required flag is in user_flags" form. CORRECT.
- **Iceberg `ALTER TABLE ... RENAME COLUMN`** — VERIFIED via Apache Iceberg schema-evolution spec (referenced in trino.io connector/iceberg.html as "Iceberg supports schema evolution, with safe column add, drop, and rename operations, including in nested structures"). Iceberg column identity is field-ID based (assigned at column creation in metadata.json), so renames are pure metadata operations: the table metadata maps the new name → field ID, and existing Parquet data files (which carry only field IDs, not names) are NOT touched. No file rewrite, no scan disruption. Responder's framing is correct.
- **Trino integer division** — VERIFIED documented behavior: `BIGINT / BIGINT` returns BIGINT (truncated toward zero). `clicked_count * 1.0 / session_count * 100`: per Trino operator precedence (left-to-right, same precedence for `*` and `/`), this parses as `((clicked_count*1.0)/session_count)*100`. The `1.0` promotes clicked_count to DECIMAL, then division is DECIMAL division (correct). `CAST(clicked_count AS double) / session_count * 100` parses as `(CAST(clicked_count AS double)/session_count) * 100` — DOUBLE division. BOTH fixes are valid.
- **NOT IN + NULL three-valued-logic** — VERIFIED per SQL standard + Trino: `NOT IN (subquery)` where the subquery contains a NULL evaluates as `NOT (x = a OR x = NULL OR ...)` → `NOT (UNKNOWN)` → UNKNOWN → row filtered out. NOT EXISTS does not use equality semantics on the right side and is NULL-safe. Both `NOT EXISTS` and `WHERE customer_id IS NOT NULL` on the subquery are correct fixes.
- **COUNT(DISTINCT x) NULL handling** — VERIFIED via WebFetch trino.io/docs/current/functions/aggregate.html: "Except for `count()`, `count_if()`, `max_by()`, `min_by()` and `approx_distinct()`, all of these aggregate functions ignore null values"; and `count(x)` is "the number of non-null input values". **COUNT(DISTINCT customer_id) IGNORES NULLs.** The responder's diagnostic "check if `SELECT COUNT(DISTINCT customer_id) FROM churned_customers` includes a NULL" is **technically wrong**: COUNT(DISTINCT) cannot tell you whether NULLs are present — it returns the same number whether they are or not. A correct diagnostic is `SELECT COUNT(*) FROM churned_customers WHERE customer_id IS NULL` or `SELECT EXISTS (SELECT 1 FROM churned_customers WHERE customer_id IS NULL)`.

---

## Per-question scoring

### Q1 — Array `user_flags VARCHAR[]` contains ALL required flags

**Answer summary**: Two canonical forms — (A) `cardinality(array_except(ARRAY['beta_export','dark_mode','new_billing'], user_flags)) = 0`, (B) `all_match(ARRAY[...required...], x -> contains(user_flags, x))`. Explains contains() membership and array_except(B,A) = elements of B not in A. Advises against UNNEST+COUNT(DISTINCT) for this case.

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | Both forms are valid Trino 467 — all three functions (`array_except`, `all_match`, `contains`) verified in array.html. Argument order on `array_except(required, user_flags)` is correct: result is `required \ user_flags`, cardinality=0 iff user_flags ⊇ required. `all_match` with lambda predicate is the canonical "every element matches" form. |
| Beginner clarity | 5.0 | Explains contains() membership semantics and the array_except set-difference semantics in plain language; engineer who has never written lambda SQL can follow. |
| Practical applicability | 5.0 | Two drop-in forms with WHERE-clause-ready SQL. The anti-pattern callout (UNNEST+COUNT) prevents the common naive approach. |
| Completeness | 5.0 | Both canonical forms covered + anti-pattern. The NULL edge (empty user_flags → TRUE for all_match; NULL element → 3VL UNKNOWN) is unstated but not required for the asked question. |
| **Q1 average** | **5.000** | **PASS** |

---

### Q2 — Iceberg `RENAME COLUMN evt_ts -> event_timestamp`; corrupts Parquet? do dbt models break?

**Answer summary**: `ALTER TABLE iceberg.schema.events RENAME COLUMN evt_ts TO event_timestamp;` — Parquet safe (Iceberg field-ID based metadata; no data rewrite). dbt models that reference `evt_ts` break IMMEDIATELY (`Column 'evt_ts' cannot be resolved`); no grace period because the table now exposes only the new name. Three migration patterns: (1) update-all-in-one-PR (small codebase), (2) add-new + dual-write + drop (large codebase, zero downtime), (3) bridging view aliasing new AS old (temporary, lets old dbt models keep working until cutover).

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | RENAME COLUMN syntax correct for Trino's Iceberg connector. Metadata-only / field-ID-based / no Parquet rewrite is CORRECT per Iceberg spec — column identity is field ID, not name; Parquet files carry field IDs (or a column-mapping that resolves via field IDs), so renames update only metadata.json. dbt-break framing is correct: the table's new schema exposes only `event_timestamp`; any query against `evt_ts` parse-errors at planning time. |
| Beginner clarity | 5.0 | The "Iceberg uses field IDs internally, names are just labels at the metadata layer" explanation gives the engineer the right mental model for why renames are cheap. Three migration patterns labeled clearly. |
| Practical applicability | 5.0 | Engineer gets exact DDL + a decision tree across three migration patterns matching codebase size and downtime tolerance. Bridging-view pattern is particularly production-relevant for staged dbt rollouts. |
| Completeness | 5.0 | Addresses BOTH sub-questions (Parquet safety + dbt break) explicitly. Migration-pattern menu is thorough. Could optionally mention `ALTER VIEW` consideration for downstream views or the time-travel implication (queries against old snapshots still need the new schema), but those are nice-to-haves, not required. |
| **Q2 average** | **5.000** | **PASS** |

---

### Q3 — `clicked_count / session_count * 100` returns 0 when should return 25

**Answer summary**: Integer division truncation — `BIGINT / BIGINT` returns BIGINT (truncates toward zero). 1/4 = 0, then 0*100 = 0. Two fixes: (A) `clicked_count * 1.0 / session_count * 100` (1.0 promotes to DECIMAL), (B) `CAST(clicked_count AS double) / session_count * 100`. Either yields 25.0.

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | Root cause correct (integer division truncates toward zero in Trino's BIGINT arithmetic). Both fixes valid: `*1.0` promotes to DECIMAL via Trino's type-coercion rules, parses left-to-right as `((c*1.0)/s)*100`; CAST AS double yields DOUBLE division. |
| Beginner clarity | 5.0 | Cause-and-effect chain is laid out clearly: type system → integer division → truncation → 0. The 1/4 worked example pins it. |
| Practical applicability | 5.0 | Drop-in fix. Engineer knows exactly what to change in the SQL. |
| Completeness | 4.5 | Covers cause + two canonical fixes. Could mention `CAST AS DECIMAL(18,2)` for fixed-precision percentage display or note that DOUBLE has IEEE-754 rounding (1.0/3.0 != exact .333…), but those are minor edge cases not asked about. |
| **Q3 average** | **4.875** | **PASS** |

---

### Q4 — `WHERE customer_id NOT IN (SELECT customer_id FROM churned_customers)` returns zero rows

**Answer summary**: NULL in the subquery → three-valued logic — `x NOT IN (a, NULL, ...)` evaluates to `NOT (x=a OR x=NULL OR ...)` → `NOT (UNKNOWN)` → UNKNOWN → row filtered out. Fix: rewrite as `NOT EXISTS (SELECT 1 FROM churned_customers c WHERE c.customer_id = customers.customer_id)` (NULL-safe anti-join semantics) OR add `WHERE customer_id IS NOT NULL` filter inside the subquery. Diagnostic: "check if `SELECT COUNT(DISTINCT customer_id) FROM churned_customers` includes a NULL".

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.0 | Core diagnosis is CORRECT — NULL in NOT IN subquery causes three-valued-logic UNKNOWN → zero rows. NOT EXISTS fix is CORRECT (NULL-safe anti-join). IS NOT NULL filter on subquery is CORRECT alternate fix. **BUT the stated diagnostic — "check if SELECT COUNT(DISTINCT customer_id) FROM churned_customers includes a NULL" — is WRONG.** COUNT(DISTINCT) IGNORES NULLs (verified trino.io/docs/current/functions/aggregate.html: count() and count(x) are the only aggregates that don't ignore NULL, but `count(x)` returns "the number of non-null input values"). COUNT(DISTINCT customer_id) returns the same number whether NULLs are present or not — it cannot reveal a NULL. The correct diagnostic is `SELECT COUNT(*) FROM churned_customers WHERE customer_id IS NULL` or `SELECT EXISTS (SELECT 1 FROM churned_customers WHERE customer_id IS NULL)`. Minor accuracy shave — the core NOT EXISTS fix is correct; the secondary diagnostic suggestion would mislead the engineer if they actually run it. |
| Beginner clarity | 5.0 | Three-valued logic walkthrough is the standard textbook explanation; the `NOT (x=a OR x=NULL)` → UNKNOWN unfolding is clear. NOT EXISTS contrast is well-framed as "NULL-safe anti-join". |
| Practical applicability | 4.5 | Primary fix (NOT EXISTS) is drop-in and correct. Secondary fix (IS NOT NULL subquery filter) is drop-in and correct. The wrong diagnostic SQL is the actionability shave — engineer who runs `COUNT(DISTINCT customer_id)` to confirm the cause will see a clean count, conclude "no NULLs", and chase a wrong hypothesis. The correct diagnostic in the very next sentence (or instead of) would have prevented this. |
| Completeness | 5.0 | Cause + two fixes + diagnostic intent all covered. The diagnostic is wrong but the *intent* is right (verify NULL presence in the subquery source). |
| **Q4 average** | **4.625** | **PASS** |

**Per-instance broken-secondary classification**: This matches the [Responder Broken Secondary Alternative] memory-pin pattern (iter936 / iter943 / iter948 / iter950 / iter954 / iter1013 / iter1019 / iter1020 / iter1102 Q3 PERCENTILE_CONT lineage). The PRIMARY answer (NOT EXISTS / IS NOT NULL filter) is correct and complete; the SECONDARY auxiliary "diagnostic to confirm cause" suggestion uses the wrong aggregate (COUNT(DISTINCT) doesn't surface NULLs). Per pin: scope as per-instance one-off re-probe, **NOT a resource defect**, do not let it bias the topic score. Re-probe NOT-IN-NULL angle at most ONE more time next sweep IF SQL-best-practices row drops below 4.4.

---

## Score table

| Q | Topic | Accuracy | Clarity | Applicability | Completeness | Q avg |
|---|---|---|---|---|---|---|
| Q1 | Analytical query patterns Iceberg+Trino (array all-of) | 5.0 | 5.0 | 5.0 | 5.0 | **5.000** |
| Q2 | Iceberg table maintenance / schema evolution (RENAME COLUMN) | 5.0 | 5.0 | 5.0 | 5.0 | **5.000** |
| Q3 | SQL best practices OLAP (integer division) | 5.0 | 5.0 | 5.0 | 4.5 | **4.875** |
| Q4 | SQL best practices OLAP (NOT IN + NULL 3VL) | 4.0 | 5.0 | 4.5 | 5.0 | **4.625** |

**Iter average = (5.000 + 5.000 + 4.875 + 4.625) / 4 = 4.875 — STRONG PASS** (margin +1.375 over 3.5 threshold).

---

## Topic updates

- **Analytical query patterns Iceberg+Trino** — prior 4.3662 / 51 → (222.6762 + 5.000) / 52 = 227.6762 / 52 = **4.378 / 52** PASSED (+0.012)
- **Iceberg table maintenance** — prior 4.4607 / 170 → (758.3175 + 5.000) / 171 = 763.3175 / 171 = **4.4639 / 171** PASSED (+0.003)
- **SQL query best practices for OLAP** — prior 4.4635 / 154 → (687.379 + 4.875 + 4.625) / 156 = 696.879 / 156 = **4.4672 / 156** PASSED (+0.004)

All required topics REMAIN PASSED.

---

## Defect classification

- **NO resource defects identified.** All claims that were correct were source-verified; the one wrong claim (Q4 diagnostic COUNT(DISTINCT) does not reveal NULL) is a responder-side broken-secondary suggestion, not a resource defect. Grep audit unnecessary — resources have never asserted that COUNT(DISTINCT) reveals NULLs (any resource that discusses NOT IN + NULL would use IS NOT NULL or NOT EXISTS as the canonical diagnostic).
- **NO ::/QUALIFY/false-semi-join/fabricated-fn/regex-backslash/INTERVAL-quarter-week/OFFSET-before-LIMIT/over-warning/Spark-Oracle-spillover/imported-prior** issues this sweep.
- The Q4 diagnostic slip is one occurrence of the broken-secondary family pin. No resource fix recommended.

---

## Recommendation

**NO-OP.** No resource edits. Iter average 4.875 STRONG PASS with comfortable +1.375 margin. All four topics touched remain PASSED with positive contributions on three of them. The Q4 wrong-diagnostic auxiliary suggestion is a per-instance Haiku padding slip matching the [Responder Broken Secondary Alternative] memory-pin pattern — the primary fix (NOT EXISTS / IS NOT NULL filter) is correct and the resource doesn't carry the wrong claim, so this is a one-off, not a resource defect.

- **NO state.json bump** (already 1103, already passed:true).
- **NO federation re-probe** (4.50244 / 312 fragile-PASS per iter1097, not stressed this iter).
- **NO commit beyond rubric + feedback** (default no-op pattern).
- **Optional durability probes next sweep** (no edits, just probe): storage-tiering 7th datapoint (3.5625 / 6 still thinnest row; recovery confirmed iter1102 but 6 datapoints is thin), dbt model contracts 6th datapoint (4.2687 / 5 second-thinnest), cost-considerations 21st angle (4.2129 / 20, third-thinnest). Also: re-probe a NOT-IN-NULL angle from a different domain in 1–2 sweeps to confirm Q4 broken-secondary doesn't recur — if the responder again proposes COUNT(DISTINCT) as the NULL-presence diagnostic, escalate to resource-side check for a misleading example.

The iter1103 breadth sweep is clean: 4 varied less-recently-probed angles (array all-of / Iceberg RENAME COLUMN / integer-division / NOT-IN-NULL) all PASS at Q-level, three at 5.0 or 4.875. Recovery pattern from iter1102 holds (storage-tiering + dbt-snapshots FIX-A REDOs reached and bedded in).
