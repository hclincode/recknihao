# Iter1214 Judge Feedback — PASS (4.45 avg) NO FIX-A; Q1 retention_days param-fab + expire-vs-planning conflation SOFT WATCH; Q3 config(severity:) Jinja-colon-vs-equals slip SOFT WATCH; Q2 cohort grid + Q4 ROWNUM land cleanly

**Overall verdict**: **PASS**, avg **4.453** ((4.0 + 4.6875 + 4.3125 + 4.8125)/4 = 17.8125/4). **NO FIX-A this iter.** Two responder-side slips both classified as recall-ceiling per-instance (not resource-sourced) → SOFT WATCH, not rewrite. Q2 historically synthesis-ceiling-hard cohort grid lands pin-perfect. Q4 Oracle ROWNUM → Trino LIMIT/row_number canonical lands clean (extending iter1202 Q4 4.875 streak).

| Q | Topic | Score | Verdict |
|---|---|---|---|
| Q1 | Query performance basics (14s planning + 480M scan despite 30-day WHERE → partition-pruning failure diagnosis) | 4.0 | PASS (two slips: `retention_days` param fabrication + expire-vs-planning conflation) |
| Q2 | Analytical query patterns on Iceberg+Trino (cohort retention grid: date_trunc month cohort + date_diff offset + SUM(CASE) pivot) | 4.6875 | STRONG PASS (pin-perfect canonical, all Trino 467 syntax valid) |
| Q3 | Improving complex SQL performance on Trino with dbt (singular test file under `tests/` for `order_date > current_date + 7 day`) | 4.3125 | PASS (core mechanism correct, `config(severity: 'error')` YAML-colon-in-Jinja syntax slip) |
| Q4 | Oracle PL/SQL → dbt+Trino migration (ROWNUM → LIMIT for top-N, row_number() OVER for Nth-row) | 4.8125 | STRONG PASS (extends iter1202 Q4 4.875 canonical streak) |

---

## Q1 — Query performance basics: 14s planning + 480M scan partition-pruning failure diagnosis — 4.0 PASS (two slips, no FIX-A)

### Diagnostic framework CORRECT

Responder reached the right mental model verified against:
- [trino.io/docs/467/sql/explain-analyze.html](https://trino.io/docs/467/sql/explain-analyze.html) — Planning time is a separate phase including parse/type-check, predicate analysis, optimizer cost estimation, **and partition pruning evaluation against Iceberg manifests**. Long planning time is real and reflects metadata-layer cost not engine "just compiling SQL" — matches engineer's mental-model gap.
- [trino.io/docs/467/sql/explain.html](https://trino.io/docs/467/sql/explain.html) — `EXPLAIN (TYPE DISTRIBUTED)` produces TableScan node with `constraint=` annotation showing the surviving TupleDomain after pruning. Empty TupleDomain → pruning didn't fire → predicate is opaque to the metadata layer. Responder's diagnostic step is exactly the canonical "check the constraint annotation" loop.
- 480M-row scan despite 30-day WHERE on a day-partitioned table = partition pruning didn't fire — correct diagnosis. The 14s planning evaluating predicates against ALL manifests + the 480M-row scan ARE related (the symptom is the same root cause: pruning blocked).

### Naked-partition-column examples CORRECT (with one nuance)

Responder's specific anti-pattern examples are accurate:
- `CAST(event_date AS VARCHAR) = '2026-05'` — VARCHAR comparison wraps the partition column in a type cast that the Unwrap rules don't cover (Unwrap{Cast,Year,DateTrunc}InComparison covers `CAST AS DATE`, `year(col)`, `date_trunc`, `EXTRACT(YEAR)` per pinned `reference_trino_unwrap_temporal_predicates.md`, but NOT `CAST AS VARCHAR`). Genuine pruning-breaker.
- `event_date + INTERVAL '1' DAY >= ...` — arithmetic on the partition column moves it out of the leaf-level predicate position where the optimizer can match against partition values. Genuine pruning-breaker.

**Note**: responder did NOT overstate the "function-on-column always breaks pruning" myth — the temporal-predicate unwrap rules (`year(event_date) = 2026`, `date_trunc('day', event_date) = ...`, `CAST(event_date AS DATE) = ...`) DO still prune per pinned reference (Trino 467 default-on rules). Responder's framing said specifically these two patterns break pruning, did not generalize. Good.

### SLIP 1 — `retention_days => 7` is a FABRICATED parameter

Responder wrote `EXECUTE expire_snapshots(retention_days => 7)`. **Wrong** — the Trino 467 parameter is `retention_threshold` and the value is a duration STRING.

**Verified at [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html)** (WebFetch this iter):

> `ALTER TABLE test_table EXECUTE expire_snapshots(retention_threshold => '7d')`
>
> The value must meet or exceed the `iceberg.expire-snapshots.min-retention` catalog setting (default `7d`).

Same param name for `remove_orphan_files`:

> `ALTER TABLE test_table EXECUTE remove_orphan_files(retention_threshold => '7d')`

Engineer copy-pasting `retention_days => 7` will hit `Unknown procedure argument: retention_days` (or similar) parse error and have to look up the correct name — engineer-error-recoverable, but a copy-pasteable resource is the point.

**RESOURCE-SOURCE CHECK** — this slip is responder-side, not resource-sourced. r10/r17 canonical maintenance procedure cards already teach `retention_threshold => '7d'` correctly (this is the form used in iter1213 Q1 4.625 which scored under storage-tiering and verified the same syntax). Per `feedback_responder_broken_secondary_alternative.md` family adjacent — responder reached the right procedure NAMES but mangled the arg shape on the way to the page. Recall ceiling, not a resource defect.

### SLIP 2 — Conflating snapshot-expiry with planning-time fix

Responder framed `expire_snapshots` + `remove_orphan_files` as "the fix" for 14s planning time from manifest bloat. This conflates two separate maintenance objectives:

- **`expire_snapshots`** reduces the number of HISTORIC snapshots in metadata.json. Helps marginally if planner is reading lots of stale snapshot metadata, but mostly affects storage cost not query planning.
- **`remove_orphan_files`** reclaims un-referenced data/manifest files in object storage. Pure storage hygiene — no planning-time impact.
- **The actual planning-time levers** for manifest bloat are:
  - `ALTER TABLE ... EXECUTE optimize(file_size_threshold => '256MB')` to compact small DATA files (fewer files → fewer entries per manifest → planner reads less); verified at [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) "data files are merged into fewer but larger files".
  - **`CALL iceberg.system.rewrite_manifests(...)`** to consolidate many small MANIFEST files into fewer larger ones — this directly attacks planning-time manifest-read cost. **Spark-only on Trino 467** per [trinodb/trino#14821](https://github.com/trinodb/trino/issues/14821) (the Trino-native procedure is open as of 467; `optimize_manifests` shipped only in 470+ per [trinodb/trino#24678](https://github.com/trinodb/trino/pull/24678)). Production-stack-aligned: Spark is the on-prem ingestion engine per `prod_info.md`.

Responder did mention "manifest bloat" framing — the diagnosis is on the right line — but the remediation step routed engineer to two procedures that don't directly address planning time. Engineer who runs `expire_snapshots` + `remove_orphan_files` on this 480M-row table will see no measurable planning-time improvement and may conclude the diagnosis was wrong when it wasn't.

**RESOURCE-SOURCE CHECK** — r10/r17/r18 already teach optimize for small-files-and-planning + rewrite_manifests Spark-only routing for manifest consolidation (verified at iter1190/iter1170 scoring entries). Responder reached the snapshot-expiry section but not the optimize+rewrite_manifests planning-time section. **Findability gap, not content gap** — recall ceiling under "long planning time + manifest" keyword path.

### Scores
- **Accuracy** 3.5 — diagnostic framework right + naked-column examples right, but fabricated `retention_days` param + conflated snapshot-expiry with planning-time fix.
- **Beginner clarity** 4.5 — "planning isn't just compiling — Iceberg planner evaluates predicates against manifests" mental-model lift is clean; engineer's "thought engine just compiles SQL" gap directly addressed.
- **Practical applicability** 4.0 — copy-pasted `retention_days => 7` fails to parse; engineer recovers in session. Two-symptom-one-cause framing is the right action plan.
- **Completeness** 4.0 — missed routing to `EXECUTE optimize` + Spark `rewrite_manifests` as the actual planning-time levers.

**Average: 4.0** → PASS, NO FIX-A. SOFT WATCH `iter1214 Q1 retention_days param-fab + expire-vs-planning conflation` — re-probe 4-8 iters under similar "long planning time on manifest-bloated Iceberg table" framing.

---

## Q2 — Cohort retention grid (date_trunc month cohort + date_diff offset + SUM(CASE WHEN) pivot) — 4.6875 STRONG PASS

**Verified canonical pattern.** This is historically a synthesis-ceiling-hard multi-step pattern (per `feedback_synthesis_ceiling_stop_churning.md`); responder lands all load-bearing facts:

### CTE structure CORRECT

```sql
WITH cohorts AS (
  SELECT user_id, date_trunc('month', MIN(event_time)) AS cohort_month
  FROM user_events WHERE event_name = 'signup'
  GROUP BY user_id
),
activity AS (
  SELECT c.cohort_month,
         date_diff('month', c.cohort_month, e.event_time) AS month_offset,
         COUNT(DISTINCT e.user_id) AS active_users
  FROM cohorts c JOIN user_events e ON e.user_id = c.user_id
  WHERE date_diff('month', c.cohort_month, e.event_time) BETWEEN 0 AND 4
  GROUP BY c.cohort_month, date_diff('month', c.cohort_month, e.event_time)
)
SELECT cohort_month,
       SUM(CASE WHEN month_offset = 0 THEN active_users END) AS month_0,
       ROUND(100.0 * SUM(CASE WHEN month_offset = 1 THEN active_users END)
                   / SUM(CASE WHEN month_offset = 0 THEN active_users END), 1) AS pct_month_1,
       ...
FROM activity GROUP BY cohort_month
```

### Six load-bearing facts VERIFIED

1. **`date_trunc('month', ts)` truncates a timestamp to the start of its month** — VERIFIED at [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html) verbatim: `date_trunc('month', TIMESTAMP '2022-10-20 05:10:00')` returns `2022-10-01 00:00:00.000`.
2. **`date_trunc` on MIN(signup_time) collapses each user to one signup cohort** — handles multi-event users / re-signups; ensures one row per user_id in `cohorts` CTE.
3. **`date_diff('month', cohort_start, event_time)`** returns COMPLETE elapsed months from cohort_start (a month boundary) to event_time — per pinned `reference_trino_datediff_dayaware.md` day-aware/complete-units behavior. Since cohort_start IS at month boundary, this gives the integer calendar-month offset (0 = signup month, 1 = next calendar month, etc.) — directly answers the engineer's "months since signup" derivation.
4. **`COUNT(DISTINCT user_id)` essential** — responder's note "SUM(CASE WHEN ... THEN 1) counts ROWS not USERS" is the critical correctness fence-post. A user with 50 events in Month 1 should count as 1 retained user, not 50.
5. **Conditional-aggregation pivot via `SUM(CASE WHEN month_offset = N THEN active_users END)`** — standard SQL pivot; ROUND(100.0 * ... / month_0, 1) for retention %; `100.0` (not `100`) forces decimal arithmetic.
6. **`WHERE date_diff(...) BETWEEN 0 AND 4` predicate** prunes irrelevant events early — narrows the JOIN to in-window activity only; on-stack the BETWEEN range scans favorably (Trino doesn't unwrap date_diff into a bare-column range, but the filter still trims rows before the GROUP BY).

### Notes-section accuracy

- **"Trino CTEs are inlined, not cached"** — VERIFIED. Trino does NOT materialize WITH clauses by default; the `cohorts` CTE referenced twice (once for the JOIN, once for the date_diff) gets inlined twice. The responder's note hints at "if 80M events, consider creating a `cohorts` table first" — pragmatic at scale, correct routing.
- **`date_diff('month')` complete-elapsed-months semantics** — VERIFIED per pinned `reference_trino_datediff_dayaware.md` (Mar-1 minus Feb-15 = 0 NOT 1, day-aware). Since both args here are month boundaries (cohort_month) vs arbitrary timestamps (event_time), and cohort_month is always EARLIER than event_time by construction, the result is the integer month offset. Correct cohort semantics.

### Scores
- **Accuracy** 4.75 — all Trino 467 syntax valid, canonical cohort-grid shape, date_diff semantics correctly handled.
- **Beginner clarity** 4.5 — three-CTE staging (`cohorts` → `activity` → final pivot) is clean conceptual progression; explanatory notes are exactly what a non-OLAP SaaS engineer needs.
- **Practical applicability** 4.75 — engineer can paste-and-rename for their schema; production-stack-aligned (Trino 467 Iceberg).
- **Completeness** 4.75 — could mention `MATCH_RECOGNIZE` as a row-pattern alternative for very-deep retention windows, but CTE-pivot is the right pattern for 5-column grid (not a real omission).

**Average: 4.6875** → STRONG PASS. NO RESOURCE ACTION. Per `feedback_synthesis_ceiling_stop_churning.md` — multi-step funnel/cohort canonical construction continues to land cleanly on r07/r23 anchors.

---

## Q3 — dbt singular test for `order_date > current_date + 7 days` — 4.3125 PASS (config-severity Jinja colon slip, NO FIX-A)

### Mechanism CORRECT — verified against [docs.getdbt.com/docs/build/data-tests](https://docs.getdbt.com/docs/build/data-tests)

WebFetched this iter, dbt docs say verbatim:

- **File location**: singular tests live in `.sql` files under the `tests/` directory (configurable via `test-paths` in `dbt_project.yml`). Each `.sql` file is one test.
- **Pass/fail semantics**: "The test PASSES if the SQL returns zero rows" — the query selects the "failing" records (rows that disprove the assertion); zero failing rows = assertion validated. Responder said "dbt fails the test if it returns ANY rows" → CORRECT.
- **Generic vs singular distinction**: generic tests (unique/not_null/accepted_values) declared in YAML; singular = hand-written SQL file. Responder framed this correctly.

### SQL CORRECT for Trino 467

```sql
-- tests/fct_orders_order_date_not_future.sql
SELECT order_id, order_date
FROM {{ ref('fct_orders') }}
WHERE order_date > CURRENT_DATE + INTERVAL '7' DAY
```

**`CURRENT_DATE + INTERVAL '7' DAY` verified** at [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html) operators table verbatim: `date '2012-08-08' + interval '2' day` returns `2012-08-10`. Same date+interval form works for `CURRENT_DATE`.

`{{ ref('fct_orders') }}` is canonical dbt resolution — engineer can paste this as-is.

### SLIP — `config(severity: 'error')` Jinja-colon-vs-equals slip

Responder wrote:
```jinja
{{ config(severity: 'error') }}
```

The colon-form `severity: 'error'` is **YAML syntax**, not Jinja. The Jinja `config()` function uses **keyword arg `=`**:

```jinja
{{ config(severity='error') }}
```

**Verified at [docs.getdbt.com/reference/resource-properties/config](https://docs.getdbt.com/reference/resource-properties/config)** WebFetched this iter. The distinction is:
- **YAML** (`.yml` files): `severity: error`
- **Jinja** (`.sql` files): `severity='error'`

Engineer pasting `{{ config(severity: 'error') }}` into the singular test SQL file hits a Jinja `TemplateSyntaxError` at `dbt parse` time and recovers in session. Common YAML/Jinja muscle-memory cross-up.

Sub-nuance per the same WebFetch: severity for singular tests is *more commonly* set in a `tests/schema.yml` block (recommended pattern) rather than inline `config()`. The inline `config()` form IS supported but with the `=` form. The responder's framing (inline `config()` in the SQL file) is on a valid route — just wrong sub-syntax.

### RESOURCE-SOURCE CHECK — responder slip, NOT resource-sourced

`grep -n "config(severity" resources/` returns dbt resource cards using the correct `=` form (`config(severity='warn')` / `config(severity='error')`). Responder reached the right config-block route but produced colon-form independently — base-training Jinja/YAML cross-up. Per `feedback_responder_broken_secondary_alternative.md` family adjacent (correct primary mechanism + uninvited syntax slip on the metadata layer).

**No FIX-A**: resources already correct, adding more defang risks over-attracting simple "where do singular tests live" questions to the syntax-warning per `feedback_new_card_over_attracts_adjacent.md`.

### Scores
- **Accuracy** 4.0 — mechanism + SQL + pass/fail semantics all right; Jinja colon-vs-equals is a real syntax error.
- **Beginner clarity** 4.5 — `tests/<filename>.sql` + "fails if any row returned" + `{{ ref('fct_orders') }}` is exactly the mental model a SaaS engineer new to dbt needs.
- **Practical applicability** 4.25 — engineer pastes, hits Jinja parse error on the config line, fixes to `=` in 30 seconds — minor speed-bump, not action-fatal.
- **Completeness** 4.5 — covered file location + SQL body + pass/fail + severity config + `dbt test` / `dbt build` invocation. Could have mentioned the recommended `tests/schema.yml` severity-block alternative (more idiomatic than inline `config()`) — minor omission.

**Average: 4.3125** → PASS, NO FIX-A. SOFT WATCH `iter1214 Q3 config(severity:) Jinja-colon-vs-equals slip` — re-probe 4-8 iters under similar "set severity on singular test" framing.

---

## Q4 — Oracle ROWNUM → Trino LIMIT for top-N, row_number() OVER for Nth-row — 4.8125 STRONG PASS

**Extends iter1202 Q4 4.875 canonical streak.** All facts verified against pinned `reference_trino_offset_before_limit.md` + [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html).

### Translation table CORRECT

| Oracle | Trino 467 |
|---|---|
| `WHERE ROWNUM <= 1` (grab one) | `ORDER BY <key> LIMIT 1` (if specific row wanted) or bare `LIMIT 1` (arbitrary) |
| `(SELECT ... ORDER BY created_at DESC) WHERE ROWNUM <= 100` | `SELECT ... ORDER BY created_at DESC LIMIT 100` |
| `ROWNUM = 5` (Nth row) | `row_number() OVER (ORDER BY ...)` subquery + outer `WHERE rn = 5` |
| Top-N per group | `row_number() OVER (PARTITION BY ... ORDER BY ...)` + outer `WHERE rn <= N` |

### Six load-bearing facts VERIFIED

1. **No `ROWNUM` in Trino 467** — VERIFIED at [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html); Trino uses ANSI/PostgreSQL-style `LIMIT`/`FETCH FIRST`/`OFFSET` for row count, plus `row_number()` window for stable row position.
2. **`ORDER BY <key> LIMIT N` for top-N over an ordered set** — TopN bounded-heap operator per pinned r18 §288-300 (verified at iter1142 5.0); doesn't sort all rows, heap of size N.
3. **Outer subquery pattern for Oracle's "ORDER + ROWNUM" idiom** — `SELECT * FROM (SELECT ... ORDER BY DESC) WHERE ROWNUM <= 100` → `SELECT ... ORDER BY DESC LIMIT 100`; the Oracle subquery layer is needed because Oracle `ROWNUM` is assigned BEFORE ORDER BY without a subquery wrap; Trino doesn't need the wrap because `LIMIT` applies AFTER `ORDER BY` natively.
4. **`LIMIT` applied AFTER `ORDER BY`** — VERIFIED per Trino SQL specification: select clause order is FROM → WHERE → GROUP BY → HAVING → SELECT → ORDER BY → OFFSET → LIMIT. Responder's "deterministic" framing correct (top-N is stable as long as ORDER BY is deterministic; ties need a tiebreaker column to be reproducible).
5. **`row_number() OVER (ORDER BY ...)` subquery + outer `WHERE rn = 5` for Nth-row** — canonical Trino form; cannot use `WHERE` on window function directly (window fns evaluated AFTER WHERE), needs subquery/CTE wrap. Responder correctly framed.
6. **`OFFSET` goes BEFORE `LIMIT`** — pinned `reference_trino_offset_before_limit.md`; PostgreSQL/MySQL `LIMIT n OFFSET m` order is a Trino PARSE ERROR. Verified at [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html) synopsis verbatim `[ OFFSET count ... ] [ LIMIT { count | ALL } ] [ FETCH ... ]`. Responder's `ORDER BY ... OFFSET 50 LIMIT 50` example correct.

### Disambiguation between grab-one vs top-N

Engineer asked specifically how the answer differs between the two cases. Responder correctly distinguished:
- **Grab one**: `LIMIT 1` (with ORDER BY if you want a specific one; arbitrary if not).
- **Top-N**: `ORDER BY ... LIMIT N` (always with ORDER BY — otherwise the N rows are arbitrary).
- **Nth specifically (N>1)**: `row_number()` subquery — `LIMIT` can't grab the 5th row directly.

This three-way disambiguation answers the engineer's literal question precisely.

### Scores
- **Accuracy** 5.0 — every translation valid Trino 467, OFFSET-before-LIMIT trap correctly named.
- **Beginner clarity** 4.75 — three-case disambiguation (grab-1 / top-N / Nth) maps cleanly onto Oracle ROWNUM use cases the engineer named.
- **Practical applicability** 4.75 — engineer can grep their codebase for `ROWNUM` and pattern-match each call site to one of the three forms; FETCH-FIRST ANSI alternative not surfaced (recall ceiling, not load-bearing).
- **Completeness** 4.75 — top-N-per-group via `PARTITION BY` correctly extended; nothing material missed.

**Average: 4.8125** → STRONG PASS. NO RESOURCE ACTION. ROWNUM canonical durably reached for 2 consecutive iters (iter1202 Q4 4.875 + iter1214 Q4 4.8125).

---

## Cross-question patterns

### Two responder slips both classified as recall-ceiling, NOT resource-sourced

1. **Q1 `retention_days => 7` parameter fabrication** — resources teach `retention_threshold => '7d'` correctly across r10/r17. Responder reached the right procedure NAME (`expire_snapshots`) but mangled the arg shape. Imported-prior fabrication family (similar to `feedback_responder_broken_secondary_alternative.md` for mangled-but-adjacent forms).
2. **Q3 `config(severity: 'error')` YAML-colon-in-Jinja** — resources teach `config(severity='warn'/'error')` with `=` form. Responder cross-wired YAML colon syntax into the Jinja `config()` macro call. Common dbt muscle-memory slip.

Both engineer-recoverable (parse error in session, fix in 30 seconds). NEITHER warrants FIX-A — adding more defang on either risks over-attracting adjacent questions per `feedback_new_card_over_attracts_adjacent.md` (the original resource form is keyword-magnetic and works for the common case).

### Q1 expire-vs-planning conflation — mental-model imprecision

Responder framed `expire_snapshots` + `remove_orphan_files` as "the planning-time fix" but these are storage/snapshot-history hygiene, not planning-cost levers. The actual planning-time levers are `EXECUTE optimize` (compact small DATA files) + Spark `rewrite_manifests` (consolidate manifests, Spark-only on 467). Findability gap — responder reached the snapshot-section but not the manifest-compaction section under the "long planning time" keyword path. Recall ceiling, not resource gap (r10/r17/r18 teach the routing).

### Q2 cohort grid + Q4 ROWNUM land cleanly — durable canonicals

Q2 cohort retention grid is historically synthesis-ceiling-hard per `feedback_synthesis_ceiling_stop_churning.md`; landing cleanly on first probe with the full date_trunc → date_diff → SUM(CASE) pivot chain + COUNT(DISTINCT) fence-post is the result of durable r07/r23 anchoring.

Q4 ROWNUM canonical extends iter1202 4.875 streak (4.8125 this iter) — three-way disambiguation (grab-1 / top-N / Nth) consistently reached from the Oracle migration entry path.

---

## Topic scoring updates

| Topic | Pre | New |
|---|---|---|
| Query performance basics: partitioning, indexing strategy for analytics | 4.2161 / 30 | 4.2091 / 31 |
| Analytical query patterns on Iceberg+Trino: funnels, cohorts, time-series SQL | 4.5399 / 152 | 4.5409 / 153 |
| Improving complex SQL performance on Trino with dbt | 4.5356 / 45 | 4.5307 / 46 |
| Oracle PL/SQL procedure → dbt + Trino SQL migration | 4.4655 / 176 | 4.4675 / 177 |

All four topics remain comfortably PASSED, all margins above +0.65.

---

## Open watches (carry forward)

### From iter1213 (carry forward)
- **`iter1213 r27 §dbt-connection session_properties findability`** — re-probe 3-6 iters under similar "apply session var across all dbt models without editing each model" framing; LIGHT FIX-A applied last iter adding profile-level `session_properties:` canonical + DO-NOT-WRITE catalog-property fabrication defang. Watch for engineer landing at the new card cleanly.
- **`iter1213 Q4 (+)-mnemonic-inverted`** SOFT (4-8 iters) — re-probe under "which side does `(+)` go on" framing.

### NEW from iter1214 (this iter)
- **`iter1214 Q1 retention_days param-fab + expire-vs-planning conflation`** SOFT (4-8 iters) — re-probe under "long planning time on manifest-bloated Iceberg" framing; confirm responder reaches the `EXECUTE optimize` + Spark `rewrite_manifests` planning-time card vs the snapshot-expiry card.
- **`iter1214 Q3 config(severity:) Jinja-colon-vs-equals slip`** SOFT (4-8 iters) — re-probe under "set severity on a singular dbt test" framing; confirm `=` form reached.

### Light-monitors (no fix, occasional checks)
- strpos-3-arg INSTR-Nth-occurrence assumed-absence (iter1211)
- `::` cast shorthand (Postgres-form not in Trino)
- NVL→COALESCE type-coercion edge case mixed-type (iter1206)
- `$partitions` direct-route vs `$files`+GROUP BY long-way-round (iter1196/iter1206)
- GDPR Spark-tag delete framing
- width_bucket boundary semantics
- exposures-selector under-routed
- CURRENT_TIMESTAMP parens (`current_timestamp` vs `current_timestamp()`)
- seed `column_types:` location (YAML structure)
- `--full-refresh` vs `on_table_exists` interaction

---

## Final verdict

**PASS (4.453 avg), NO FIX-A.** Q1 retention_days param-fab + expire-vs-planning conflation pulls Q1 to 4.0 but resource is already correct on `retention_threshold => '7d'` and the `EXECUTE optimize` planning-time path — responder findability/recall ceiling, not resource defect. Q3 config-colon Jinja slip is a real syntax error but mechanism is right + resource teaches `=` form. Q2 cohort grid lands as canonical-strong. Q4 ROWNUM extends the iter1202 durable canonical.

**Steady state**: all required topics PASSED, margins healthy. Next iter1215: BREADTH — re-probe under-tested watches (`session_properties` 1st re-probe, `(+)` mnemonic, retention_days form, config-severity form).
