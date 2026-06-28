# Iteration 1216 — Judge Feedback

**Verdict: 4.78 STRONG PASS / NO-OP** (all four answers score 4.75–4.875; no FIX-A; resources already canonical on all four axes).

---

## Per-question scores

### Q1 — Day-vs-hour partitioning for ~60M rows/day + 6-hour-window dashboards

**Score: 4.75** (Acc 4.5 / Clar 4.5 / App 5.0 / Compl 5.0)

Sophisticated partition-design canonical reached cleanly. Load-bearing facts all verified:

1. **Iceberg hidden partitioning with `day(event_ts)` transform** — natural timestamp-range predicates `WHERE event_ts >= ts1 AND event_ts < ts2` prune at the day-partition level without filtering a separate `event_date` column. Verified at [iceberg.apache.org/spec/](https://iceberg.apache.org/spec/) "partition values are derived from data values using a partition transform" + [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) `partitioning = ARRAY['day(event_ts)']` syntax.

2. **Trino 467 default-on `Unwrap{Cast,Year,DateTrunc}InComparison` rules** — matches pinned `reference_trino_unwrap_temporal_predicates.md` (git-tag-source-verified iter871). `year(ts)=2026`, `date_trunc('day', ts)=DATE '...'`, `CAST(ts AS date)=...`, `EXTRACT(YEAR FROM ts)=...` all unwrap into bare-column range predicates that STILL prune partitions. Responder correctly does NOT recommit the iter870 imported-prior "function-on-column = full scan" error.

3. **`sorted_by` + `EXECUTE optimize` as the file-level pruning lever** — verified at [trinodb/trino PR #14891](https://github.com/trinodb/trino/pull/14891) + [Starburst — Improving performance with Iceberg sorted tables](https://www.starburst.io/blog/improving-performance-with-iceberg-sorted-tables/) "the Optimize command will sort the data based on the DDL of the table". `ALTER TABLE ... SET PROPERTIES sorted_by = ARRAY['event_ts ASC']` is metadata-only governing future writes; `EXECUTE optimize(file_size_threshold => '512MB')` physically re-sorts each rewritten file. Sharpens per-file Parquet min/max so the 2nd pruning layer (file-level) skips files outside the 6-hour window inside the day partition.

4. **Production-stack-aligned** — Spark ingestion (per `prod_info.md`) writes Parquet to MinIO; sorted-on-write is supported by `SortingFileWriter`; on-prem Hive Metastore catalog.

**Minor framing imprecision (-0.5 Acc)** — "Hour partitioning = 24x partition values, NO extra pruning advantage" is loosely framed. Hour partitioning IS finer pruning at the partition level (a raw-timestamp range filter on an `hour(event_ts)`-partitioned table prunes to ~6 hour partitions vs 1 day). The accurate framing is "sorted_by within day partitions delivers EQUIVALENT effective pruning via file-level min/max, WITHOUT the 24× metadata bloat / small-files risk" — not "no pruning advantage." Practical conclusion (sorted_by is the right answer) unchanged. Recall-ceiling phrasing slip, NOT a resource defect.

**Engineer outcome**: pastes the `sorted_by` ALTER + `EXECUTE optimize` and gets the speedup without re-partitioning.

---

### Q2 — Top-5-per-plan-tier via ROW_NUMBER() in Trino (Postgres-style WHERE on `rn`)

**Score: 4.75** (Acc 5.0 / Clar 4.5 / App 5.0 / Compl 4.5)

Canonical Trino 467 top-N-per-group reached cleanly. Responder:

1. **No QUALIFY in Trino 467** — verified by absence at [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html) (window functions only allowed in `SELECT` and `ORDER BY`, no QUALIFY clause documented). Engineer migrating from Snowflake/BigQuery (which DO have QUALIFY) gets the right "use a CTE instead" routing.

2. **Window functions can't appear in `WHERE`** — execution-order explanation (FROM → WHERE → GROUP BY → window → SELECT) correctly framed. Showing the broken `WHERE ROW_NUMBER() OVER (...) <= 5` form as a parse error is good defang per `feedback_defang_donotwrite_snippets.md` (inline-marked WRONG, not copy-attractive).

3. **CTE + outer `WHERE rn <= 5`** — pattern:
   ```sql
   WITH per_user AS (
     SELECT plan_tier, user_id, COUNT(*) AS event_count
     FROM events
     WHERE event_ts >= CURRENT_TIMESTAMP - INTERVAL '30' DAY
     GROUP BY plan_tier, user_id
   ),
   ranked AS (
     SELECT plan_tier, user_id, event_count,
            ROW_NUMBER() OVER (PARTITION BY plan_tier ORDER BY event_count DESC) AS rn
     FROM per_user
   )
   SELECT plan_tier, user_id, event_count
   FROM ranked
   WHERE rn <= 5
   ORDER BY plan_tier, rn;
   ```

4. **Tie-handling caveat omission** (-0.5 Compl) — could mention that `ROW_NUMBER` gives an arbitrary tie-break (vs `RANK`/`DENSE_RANK` that share ranks). For "top 5" this is rarely operationally load-bearing; not a defect.

**Engineer outcome**: copies the CTE pattern verbatim and runs immediately; understands WHY window-in-WHERE errors.

---

### Q3 — dbt `relationships` test for stg_events.user_id → dim_users (FK / referential integrity)

**Score: 4.75** (Acc 5.0 / Clar 4.5 / App 5.0 / Compl 4.5)

Canonical dbt referential-integrity-test reached cleanly. Verified at [docs.getdbt.com/reference/resource-properties/data-tests](https://docs.getdbt.com/reference/resource-properties/data-tests) + [docs.getdbt.com/docs/build/data-tests](https://docs.getdbt.com/docs/build/data-tests):

1. **`relationships` is one of four built-in generic tests** alongside `unique` / `not_null` / `accepted_values` — verbatim "out-of-the-box generic data tests."

2. **schema.yml syntax** under the column's `data_tests:` (legacy `tests:` also accepted) block — `relationships: {to: ref('dim_users'), field: user_id}`. Responder used the inline-flow-mapping form which is the older/simpler still-supported syntax; newer dbt 1.10+ docs prefer the `arguments:` nested block (`relationships: {arguments: {to: ref(...), field: id}}`), but both compile. Not a defect.

3. **`source()` variant** for testing against a source table (`to: source('raw','users')`) — correctly noted.

4. **Underlying SQL = orphan/anti-join check** — dbt compiles to roughly `SELECT * FROM stg_events s WHERE s.user_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dim_users d WHERE d.user_id = s.user_id)`. Zero rows returned = test PASS. NULL keys auto-excluded (consistent with FK constraint semantics).

5. **Run via `dbt test` or as part of `dbt build`** — correctly named both commands; default severity = `error` (non-zero exit, blocks downstream per pinned iter1202 severity canonical).

**Engineer outcome**: pastes the YAML into `models/staging/schema.yml`, runs `dbt test --select stg_events`, gets a row count of orphan user_ids if any exist. No production-stack adjustment needed (dbt-trino executes the generic test SQL transparently against Trino+Iceberg).

---

### Q4 — Oracle `ADD_MONTHS(d, n)` → Trino equivalent + month-end clamp divergence

**Score: 4.875** (Acc 5.0 / Clar 4.75 / App 5.0 / Compl 5.0)

Pin-perfect Oracle→Trino date-arithmetic migration canonical, consistent with iter1193 ADD_MONTHS landing. Verified at [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html):

1. **No native `ADD_MONTHS` in Trino 467** — function-list grep clean; parse error confirmed. Engineer's Oracle ADD_MONTHS lift-and-shift fails.

2. **Two valid forms**:
   - `date_add('month', n, date_col)` — verified signature `date_add(unit, value, timestamp) → [same as input]`; negative `n` subtracts (Oracle's `ADD_MONTHS(SYSDATE, -6)` → `date_add('month', -6, current_timestamp)`).
   - `date_col + INTERVAL 'n' MONTH` — verified operator at docs `timestamp + interval`.

3. **Oracle month-end CLAMP vs Trino day-of-month preserve — CORRECT semantic distinction**:
   - Oracle: `ADD_MONTHS(DATE '2026-02-28', 1) = DATE '2026-03-31'` (because Feb 28 = end-of-Feb, so preserve end-of-month status into March).
   - Trino: `date_add('month', 1, DATE '2026-02-28') = DATE '2026-03-28'` (preserve day-of-month; 28 exists in March so no roll-forward).
   - Separate documented Trino behavior: `DATE '2012-10-31' + INTERVAL '1' MONTH = DATE '2012-11-30'` clamps the DESTINATION-day (Nov has only 30 days max) — this is target-month-max clamping NOT Oracle's source-month-end-preserve.
   - Responder correctly distinguished these two semantics.

4. **Oracle-compat wrapper** — `CASE WHEN d = last_day_of_month(d) THEN last_day_of_month(date_add('month', 3, d)) ELSE date_add('month', 3, d) END` is the correct semantic-preservation pattern when invoice-renewal logic legacy-depended on month-end preservation.

5. **`last_day_of_month(date) → date`** — VERIFIED at the datetime functions page. `end_of_month` (Spark/BigQuery) does NOT exist in Trino 467 — correct defang per pinned-family `feedback_responder_overwarning_folklore.md`-adjacent assumed-absence-vs-real-existence reflex.

**Engineer outcome**: pastes `date_add('month', 3, invoice_date)` for renewals + `date_add('month', -6, current_date)` for lookback, and ships the CASE wrapper only if Oracle month-end semantic preservation matters for the contractual renewal rule (often it does).

---

## Cross-question patterns

- **No imported-prior slip** this iteration (no GREATEST-NULL / no false function-absence assumption / no Postgres-string-fn priors leaking in).
- **No broken-secondary-alternative** (`feedback_responder_broken_secondary_alternative.md` family clean — every alternative form shown is valid).
- **No over-warning folklore** (`feedback_responder_overwarning_folklore.md` family clean — no "X is slow, use Y" misframing of fine constructs).
- **iter1215 compression_codec-477 cutoff WATCH** — not re-probed this iter; carry forward 3-5 more iters before reading the no-recurrence signal.
- **strpos-3-arg ceiling** — not re-probed this iter; carry forward 7-11 more iters (per accepted ceiling, no churn).
- **iter1213 session_properties + (+)-mnemonic** — light-monitor, not re-probed this iter.
- **iter1214 retention_days param-fab + expire-vs-planning conflation soft watch** — not re-probed this iter; 3-7 iters remaining.
- **iter1206 LIKE-on-ROW + $partitions-omission soft watch** — not re-probed this iter; 4-8 iters remaining.

## Topic routing this iteration

- Q1 → `Iceberg partition design for SaaS` (partition strategy choice + sorted_by + small-files)
- Q2 → `Analytical query patterns on Iceberg+Trino` (top-N-per-group window canonical)
- Q3 → `dbt model contracts` (data-integrity declaration family; closest dbt row to a generic-test referential-integrity question)
- Q4 → `Oracle PL/SQL procedure → dbt + Trino SQL migration` (ADD_MONTHS dialect rewrite — same row as iter1193)

## Sources verified against

- [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) (sorted_by + EXECUTE optimize + partitioning array)
- [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html) (date_add / INTERVAL / last_day_of_month / no ADD_MONTHS / no end_of_month)
- [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html) (window in SELECT/ORDER BY only, no QUALIFY)
- [iceberg.apache.org/spec/](https://iceberg.apache.org/spec/) (partition transforms, manifest-level pruning)
- [docs.getdbt.com/reference/resource-properties/data-tests](https://docs.getdbt.com/reference/resource-properties/data-tests) (relationships syntax + four built-in tests)
- [trinodb/trino PR #14891](https://github.com/trinodb/trino/pull/14891) (sorted writes in Iceberg connector)
- [Starburst — Improving performance with Iceberg sorted tables](https://www.starburst.io/blog/improving-performance-with-iceberg-sorted-tables/) (Optimize sorts based on DDL)
- pinned `reference_trino_unwrap_temporal_predicates.md` (iter871 git-tag-verified)
- pinned `feedback_defang_donotwrite_snippets.md` (Q2 wrong-form defang pattern)

## Verdict

**STRONG PASS / NO-OP.** All four answers actionable; engineer ships in each case without re-reading docs. No FIX-A, no soft watch added, no churn warranted. Continue breadth probing.
