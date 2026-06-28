# Iteration 1231 — Judge Feedback

**Verdict: 4.69 STRONG PASS (margin +1.19).** Q1 WATCH `iter1228 r27 §4.5A packages.yml-version-rename FIX-A` CLOSES cleanly on first re-probe — responder LEADS with the `generate_surrogate_key` was-renamed-from `surrogate_key` in dbt_utils 1.0.0 cause. Q2 + Q3 clean technically. Q4 formula CORRECT but the CLOSING NOTE is SELF-CONTRADICTORY (claims formula doesn't strictly-after when it does, and would BREAK if engineer follows the "add +INTERVAL '1' DAY" advice). Iter average = (5.0 + 5.0 + 4.5 + 4.25)/4 = 4.6875.

- **iter1228 r27 §4.5A packages.yml-version-rename FIX-A WATCH: CLOSES** on first re-probe (Q1 5.0). Responder now LEADS with: "FIRST thing to check: VERSION issue. `generate_surrogate_key` was introduced in dbt_utils 1.0.0 (Nov 2022); on <1.0.0 the macro doesn't exist under that name → `not found` even though install succeeded." Engineer arrives at version-pin fix (`>=1.1.0`, `<2.0.0`) + 4-cause checklist without false-route through wrong-file-location or wrong-package-name. 18th consecutive watch in 1st-NO-OP-then-LIGHT-FIX-A-then-CLOSE pattern. Both iter1228 watches now CLOSED (currency-format closed iter1230, version-rename closes iter1231).
- **Q4 closing-note contradicts the formula (NEW REAL DEFECT, MINOR).** The arithmetic formula `order_date + INTERVAL '1' DAY * CASE WHEN dow < target THEN target-dow ELSE (target+7)-dow END` is CORRECT and already implements Oracle NEXT_DAY (strictly-after) — for `dow == target` the ELSE branch hits and emits `+7` (next-week), not `+0`. BUT the final paragraph says "This includes the target date if today IS the target weekday. To get strictly-after (Oracle), add + INTERVAL '1' DAY." This is WRONG: the formula does NOT include the target date, and adding +1 DAY would BREAK it (engineer who follows the note ends up with NEXT_DAY('MONDAY') returning the Tuesday after next, an off-by-one overshoot). The responder is self-contradicting — the formula and the prose are pointing at different specs. Per `feedback_responder_broken_secondary_alternative.md` family: lead CORRECT, append-paragraph BROKEN. Per-instance ding, watch but NO FIX-A on first occurrence.
- **Q4 dead `WHEN day_of_week < 1` branch (cosmetic).** In the Monday example, responder writes a CASE arm that can never fire (ISO `day_of_week` returns 1..7, so `< 1` is unreachable). Cosmetic — does not affect output — but signals the responder doesn't fully "see" the day_of_week range when composing examples. Not load-bearing.
- **Q3 `{{ run_query('ANALYZE...', execute=true) }}` wrapper variant — slight imprecision (not wrong).** The on-run-end hook accepts a raw SQL STRING that dbt executes directly; `run_query()` is the macro-level way to execute SQL and bind results, used INSIDE macros that need to inspect query results. For an on-run-end hook the bare `"ANALYZE ..."` form is canonical and the responder DID lead with it; the `run_query` wrapper variant is added as a secondary "or you can do this" alternative. Not wrong per se (it does execute the SQL), but unnecessary scaffolding for an on-run-end use case. Verified at [docs.getdbt.com/reference/project-configs/on-run-start-on-run-end](https://docs.getdbt.com/reference/project-configs/on-run-start-on-run-end) — hook accepts `sql-statement` or `[sql-statement]` directly. Minor shave only.

Per-question summary:
- **Q1 5.0 (WATCH CLOSE)** — version-rename reached as #1 cause; 4-cause table covers version / dbt_packages-missing-at-compile / wrong-file-name / stale-install; `{{ generate_surrogate_key }}` call confirmed correct.
- **Q2 5.0** — SUM(...) FILTER (WHERE year/month = current vs current-1) single-pass YoY canonical; mutually-exclusive FILTERs; *1.0/NULLIF ratio guard correct.
- **Q3 4.5** — on-run-end runs ONCE at end (correct); bare `ANALYZE <table>` no TABLE keyword (correct); `WITH (columns = ARRAY[...])` Iceberg-valid (correct); `WITH (partitions = ARRAY[...])` Hive-only (correct). Minor `run_query` wrapper imprecision.
- **Q4 4.25** — formula CORRECT and `day_of_week` ISO Mon=1..Sun=7 correct; closing note is SELF-CONTRADICTORY (would overshoot if engineer adds +1 DAY); dead `< 1` CASE branch is cosmetic.

---

## Q1 (WATCH) — dbt-utils in packages.yml a while, works on coworker's laptop; fresh clone on new machine; `dbt deps` ran (dbt_packages/ created); `dbt run` → every `{{ dbt_utils.generate_surrogate_key([...]) }}` fails "macro 'generate_surrogate_key' not found in any package." Most likely causes on a fresh checkout after dbt deps? First thing to check — version, package-name, or skipped step?

**Score: 5.0** — Acc 5.0 / Clar 5.0 / App 5.0 / Compl 5.0

**WATCH OUTCOME: `iter1228 r27 §4.5A packages.yml-version-rename FIX-A` CLOSES on first re-probe.**

Responder shape:
- **FIRST thing to check: VERSION issue. `generate_surrogate_key` was introduced in dbt_utils 1.0.0 (Nov 2022); on <1.0.0 the macro doesn't exist under that name → 'not found' even though install succeeded.**
- **Fix: pin `version: [">=1.1.0", "<2.0.0"]` in packages.yml; `dbt deps`.**
- **4-cause table**:
  1. Version pinned to <1.0.0 (or floor unset and stale resolved version)
  2. `dbt_packages/` missing at compile time (CI environment skipped `dbt deps`)
  3. Wrong file location/name (`packages.yml` must be at project root; package name `dbt-labs/dbt_utils`)
  4. Stale install — `dbt clean` + `dbt deps`
- **The `{{ dbt_utils.generate_surrogate_key([...]) }}` call itself is correct shape.**

**Load-bearing facts VERIFIED:**

1. **`generate_surrogate_key` introduced in dbt_utils 1.0.0 as rename of `surrogate_key`** — verified at [docs.getdbt.com/docs/dbt-versions/core-upgrade/Older versions/upgrading-to-dbt-utils-v1.0](https://docs.getdbt.com/docs/dbt-versions/core-upgrade/Older%20versions/upgrading-to-dbt-utils-v1.0) (WebFetch this iter): "`generate_surrogate_key()` was introduced in dbt utils v1.0 as a replacement for the deprecated `surrogate_key()` macro." Behavior change: old `surrogate_key()` treated nulls and blanks identically (duplicate-key risk); new form handles nulls correctly.
2. **The "macro not found in any package" error surfaces literally when the resolved version is <1.0.0** — the macro genuinely doesn't exist under that name in pre-1.0.0 packages, so Jinja resolution fails the lookup. Engineer's `{{ dbt_utils.generate_surrogate_key([...]) }}` call is correct shape; the missing piece is the version.
3. **The coworker-works-mine-doesn't framing** is the canonical fingerprint: coworker has 1.0.0+ resolved in `dbt_packages/` from an older `dbt deps`; fresh `dbt deps` on the new machine resolves a DIFFERENT version (perhaps the floor lets <1.0.0 through, or there's no pin and a yanked release got resolved). The responder correctly routes engineer to version-pinning as the FIX, not to file-location-troubleshooting.
4. **`dbt-labs/dbt_utils` package name + `packages.yml` at project root** — standard dbt-labs documentation. Not the issue here (since `dbt_packages/` was created, install succeeded), but correctly listed as cause #3 for completeness.
5. **`dbt clean` + `dbt deps` for stale-install** — correct corruption-recovery step.

**Watch close evidence**: at iter1228 the responder FAILED to reach the version-rename row and routed to file-location/package-name troubleshooting only. The strengthened r27 §4.5A FIX-A added LEAD-WITH-VERSION-RENAME phrasing: "macro not found in any package = VERSION mismatch: generate_surrogate_key needs dbt_utils 1.0.0+, renamed from surrogate_key." The iter1231 responder now LEADS with exactly this — the strengthened card reached. WATCH CLOSES on first re-probe.

Engineer leaves with: a one-line version-pin fix + 4-cause checklist + the call confirmed correct. Cites r27. Topic routed to "Oracle PL/SQL → dbt + Trino SQL migration" (dbt packaging context).

---

## Q2 — Each account's total subscription revenue for CURRENT calendar month alongside same month LAST year. Two CTEs + join by account_id (hits events table twice). Cleaner single-pass for this-month + 12-months-ago side by side without self-join / two scans?

**Score: 5.0** — Acc 5.0 / Clar 5.0 / App 5.0 / Compl 5.0

Responder shape:
- **Single-pass conditional-aggregation YoY pattern** with `SUM(...) FILTER (WHERE ...)`:
  ```sql
  SELECT
    account_id,
    SUM(subscription_revenue) FILTER (
      WHERE year(event_date) = year(current_date)
        AND month(event_date) = month(current_date)
    ) AS current_month_revenue,
    SUM(subscription_revenue) FILTER (
      WHERE year(event_date) = year(current_date) - 1
        AND month(event_date) = month(current_date)
    ) AS same_month_last_year_revenue,
    1.0 * SUM(...) FILTER (...) / NULLIF(SUM(...) FILTER (...), 0) AS yoy_ratio
  FROM events
  WHERE event_date >= date_trunc('month', current_date - INTERVAL '13' MONTH)
  GROUP BY account_id;
  ```
- **One scan, mutually-exclusive FILTERs, single GROUP BY** — engineer's two-CTE-with-join becomes one TableScan + one HashAggregation.
- **NULLIF guard** for divide-by-zero on the ratio column.

**Load-bearing facts VERIFIED:**

1. **`SUM(expr) FILTER (WHERE cond)` native in Trino 467** — verified at [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/467/functions/aggregate.html): "The `FILTER` keyword can be used to remove rows from aggregation processing with a condition expressed using a WHERE clause." Supported for ALL aggregate functions, including `SUM`.
2. **`year(event_date)` + `month(event_date)`** — both standard Trino 467 date-extraction functions per [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html). Equivalent: `EXTRACT(YEAR FROM event_date)`, `EXTRACT(MONTH FROM event_date)`.
3. **Sargability**: `year(event_date) = year(current_date)` and `month(event_date) = month(current_date)` — per pinned `reference_trino_unwrap_temporal_predicates.md`, Trino 467's default-on `UnwrapYearInComparison` rewrites `year(col) = literal` into a bare-column range so partition pruning STILL works on `event_date`-day-partitioned tables. So the FILTER predicates do not block pruning.
4. **`1.0 / NULLIF(x, 0)` ratio guard** — per pinned `reference_trino_division_by_zero.md`, INTEGER/DECIMAL `/` by zero throws `DIVISION_BY_ZERO` in Trino 467; `NULLIF` returns NULL for the zero-denominator case, propagating NULL through the division as the standard idiom. `1.0 *` casts to DOUBLE so the ratio is decimal not integer-divided.
5. **`WHERE event_date >= date_trunc('month', current_date - INTERVAL '13' MONTH)`** — outer prune scoping the scan to the 14-month window the FILTERs care about (this month + 12 months ago, with a month of slack). Engineer's two-CTE form would have done this twice; single-pass does it once.

**Why this beats the two-CTE form**: engineer's CTEs each scan `events`; the JOIN merges them. Trino doesn't always FUSE the two TableScans into one (the optimizer treats them as logically separate Iceberg scans even if the table is the same). The single conditional-aggregation form has ONE TableScan + ONE HashAggregation — the optimizer doesn't need to fuse anything; the query plan is already minimal.

Engineer leaves with: drop-in single-pass YoY query + sargable predicates (still prunes day-partitions via `UnwrapYearInComparison`) + ratio-guard idiom. Cites r07/r23. Topic routed to "Analytical query patterns on Iceberg+Trino: funnels, cohorts, time-series SQL".

---

## Q3 — dbt builds model but plans use stale stats; manually run ANALYZE after. dbt_project.yml on-run-end hook — set up to run ANALYZE on a few specific tables at end of every dbt run? Does on-run-end run ONCE at the very end, or after each model?

**Score: 4.5** — Acc 4.5 / Clar 5.0 / App 4.0 / Compl 4.5

**Technical core clean; `run_query` wrapper variant slightly imprecise (not wrong).**

Responder shape:
1. **`on-run-end` runs EXACTLY ONCE at the very end** of `dbt run`/`dbt build`, after all models + tests complete — NOT per-model. (For per-model use `post-hook`.)
2. **dbt_project.yml hook**:
   ```yaml
   on-run-end:
     - "ANALYZE iceberg.analytics.fct_events WITH (columns = ARRAY['user_id','tenant_id','event_type'])"
     - "ANALYZE iceberg.analytics.dim_accounts"
   ```
3. **Trino syntax**: bare `ANALYZE <table>` — NO TABLE keyword (engineer's instinct from Spark/Hive `ANALYZE TABLE` would parse-fail in Trino).
4. **Iceberg `WITH (columns = ARRAY[...])`** for selective column-stat collection on large tables; `WITH (partitions = ARRAY[...])` is HIVE-ONLY (fails on Iceberg).
5. **Variant**: also showed `{{ run_query('ANALYZE ...', execute=true) }}` wrapper (this is slightly imprecise — see slip below).
6. **Cadence**: re-run after bulk ingests / weekly / pair with `EXECUTE optimize`.

**Load-bearing facts VERIFIED:**

1. **`on-run-end` runs once at end of invocation** — verified at [docs.getdbt.com/reference/project-configs/on-run-start-on-run-end](https://docs.getdbt.com/reference/project-configs/on-run-start-on-run-end) (WebFetch this iter): hook description says "at the end of" `dbt run` / `dbt build`. Per [docs.getdbt.com/docs/build/hooks-operations](https://docs.getdbt.com/docs/build/hooks-operations): "The `on-run-end` hook will be executed after the last model is built." NOT per-model (that's `post-hook`).
2. **Bare `ANALYZE <table>` Trino 467 syntax (no TABLE keyword)** — verified at [trino.io/docs/467/sql/analyze.html](https://trino.io/docs/467/sql/analyze.html): grammar is `"ANALYZE table_name [ WITH ( property_name = expression [, ...] ) ]"`. NO TABLE keyword. The `ANALYZE TABLE foo` form is Spark/Hive SQL; in Trino 467 it parse-errors. Pinned `reference_trino_offset_before_limit.md`-adjacent syntax-correctness fact.
3. **Iceberg `WITH (columns = ARRAY[...])` valid** — verified at [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) (WebFetch this iter): "You can specify a subset of columns to analyzed with the optional `columns` property." Example: `ANALYZE table_name WITH (columns = ARRAY['col_1', 'col_2'])`. Correctly named.
4. **`partitions = ARRAY[...]` is Hive-only** — Iceberg ANALYZE documentation does NOT list `partitions` as a supported property; this property appears only in the Hive connector ANALYZE properties. Engineer trying `WITH (partitions = ARRAY[...])` on an Iceberg table would hit `Catalog 'iceberg' does not support analyze property 'partitions'`. Responder's defang is correct.
5. **on-run-end accepts raw SQL string directly** — verified at the same docs.getdbt.com URL: hook accepts `sql-statement | [sql-statement]` directly. The `run_query()` macro is for INSIDE macros that need to bind/inspect results; for on-run-end, the raw SQL string form is the canonical pattern. The `{{ run_query('ANALYZE ...', execute=true) }}` variant DOES work (it executes the SQL and the wrapper just discards the result rowset), but it's unnecessary scaffolding for a fire-and-forget ANALYZE hook.

**Slip — `run_query` wrapper variant**: not wrong (it does execute the ANALYZE), but it's stylistically imprecise — the bare string form is canonical for on-run-end hooks. Engineer who copies the `run_query` form gets the same result; one extra Jinja indirection layer. Recall ceiling, not load-bearing. NO FIX-A.

Engineer leaves with: canonical on-run-end ANALYZE hook + correct Trino bare-ANALYZE syntax + Iceberg `columns` property + Hive `partitions` defang + cadence guidance. Cites r17/r27. Topic routed to "Trino CBO / ANALYZE TABLE / Puffin statistics".

---

## Q4 — Oracle `NEXT_DAY(some_date, 'MONDAY')` = next Monday strictly-after a date. No NEXT_DAY in Trino. Trino way to compute "next occurrence of a specific weekday after date X" (general, several weekdays)?

**Score: 4.25** — Acc 3.5 / Clar 4.5 / App 4.0 / Compl 5.0

**Formula CORRECT; closing note SELF-CONTRADICTORY — would BREAK the formula if engineer follows it.**

Responder shape:
1. **No `NEXT_DAY` in Trino — build via `day_of_week` + arithmetic.**
2. **ISO `day_of_week`: Mon=1, Tue=2, ..., Sun=7.**
3. **General formula**:
   ```sql
   order_date + INTERVAL '1' DAY * CASE
     WHEN day_of_week(order_date) < target_weekday
       THEN target_weekday - day_of_week(order_date)
     ELSE (target_weekday + 7) - day_of_week(order_date)
   END
   ```
4. Monday-specific example with dead `WHEN day_of_week < 1` branch (cosmetic dead code).
5. **CLOSING NOTE (WRONG)**: "This includes the target date if today IS the target weekday. To get strictly-after (Oracle), add + INTERVAL '1' DAY."

**Formula verification (CORRECT, matches Oracle NEXT_DAY):**

Walk through all four corner cases:
- **today=Monday(1), target=Monday(1)**: `dow < target` FALSE (1<1 false) → ELSE branch → `(1+7) - 1 = 7` → `+7 days` → **next Monday (strictly-after)**. ✓ Matches Oracle.
- **today=Sunday(7), target=Monday(1)**: `dow < target` FALSE (7<1 false) → ELSE branch → `(1+7) - 7 = 1` → `+1 day` → **next Monday (the immediate one)**. ✓
- **today=Monday(1), target=Friday(5)**: `dow < target` TRUE (1<5) → `5 - 1 = 4` → `+4 days` → **this Friday (strictly-after, same week)**. ✓
- **today=Friday(5), target=Friday(5)**: `dow < target` FALSE → ELSE branch → `(5+7) - 5 = 7` → `+7 days` → **next Friday (strictly-after)**. ✓

**Conclusion: formula ALREADY implements Oracle NEXT_DAY (strictly-after) for all cases**, including when `dow == target` (the ELSE branch fires and emits `+7`, NOT `+0`). The formula does NOT include the target date.

**Closing note SELF-CONTRADICTS the formula it just published.** The note says "this includes the target date if today IS the target weekday" — FALSE, the ELSE branch emits `+7` not `+0`. The note then says "to get strictly-after, add + INTERVAL '1' DAY" — this would BREAK the formula by overshooting:
- today=Monday(1), target=Monday(1): formula emits +7 (next Monday). Note's "add +1 day" → +8 → **Tuesday after next**, off by one.
- today=Friday(5), target=Friday(5): formula emits +7. Note's "add +1 day" → +8 → **Saturday after next Friday**, off by one.

Engineer who reads the prose and follows it gets a broken function. Engineer who reads only the formula gets the right answer. This is a **broken-secondary-alternative** pattern per `feedback_responder_broken_secondary_alternative.md`: lead correct, append-paragraph self-contradicts the lead.

**Verified facts:**

1. **No `NEXT_DAY` in Trino 467** — verified at [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html): no `next_day` function in the date/time function list. Engineer's premise correct.
2. **`day_of_week` ISO Mon=1..Sun=7** — verified at the same URL: "Returns the ISO day of the week from x. The value ranges from 1 (Monday) to 7 (Sunday)." Per [trinodb/trino PR #5149](https://github.com/trinodb/trino/pull/5149) optional second arg to set start-of-week, default Monday.
3. **`INTERVAL '1' DAY * <int>` valid** — `INTERVAL '1' DAY` is a `INTERVAL DAY TO SECOND` (or unit-interval), supports multiplication by an integer per Trino 467 `arithmetic.md` (verified at [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html) examples).
4. **Dead `WHEN day_of_week < 1` arm** — cosmetic; ISO `day_of_week` returns 1..7 so `< 1` is unreachable. Doesn't affect output but signals incomplete review.

**Dings:**
- Acc 3.5 — formula correct (+5), self-contradicting closing note that would break the formula if followed (-1.5).
- Clar 4.5 — formula readable; closing note creates a contradiction reader has to resolve.
- App 4.0 — engineer who reads the prose and adds `+1 DAY` gets broken output; engineer who reads only the formula is fine.
- Compl 5.0 — covers no-NEXT_DAY + ISO mapping + general formula + Monday example.

**Resource-source check**: searched resources/ for the wrong "add +1 DAY for strictly-after" framing — no resource teaches this; the responder is freelancing the closing note. NO FIX-A on first occurrence (per `feedback_responder_broken_secondary_alternative.md` — recall ceiling, not resource-sourced). Soft watch added; re-probe in 4-8 iters under similar "NEXT_DAY / next-occurrence-of-weekday" framing.

Engineer leaves with: working formula + correct ISO day_of_week mapping + a self-contradictory closing paragraph that would break the formula if followed. Cites r27. Topic routed to "Oracle PL/SQL → dbt + Trino SQL migration".

---

## Watch carryforward / pin maintenance

**Closes this iteration:**
- `iter1228 r27 §4.5A packages.yml-version-rename FIX-A` — CLOSES on first re-probe (Q1 5.0). Strengthened LEAD card ("`macro not found in any package` = VERSION mismatch: `generate_surrogate_key` needs dbt_utils 1.0.0+, renamed from `surrogate_key`") REACHED — responder leads with it instead of routing to file-location-troubleshooting. 18th consecutive watch in 1st-NO-OP-then-LIGHT-FIX-A-then-CLOSE pattern. **Both iter1228 open watches now CLOSED** (currency-format closed iter1230, packages.yml-version-rename closes iter1231).

**Soft watches added/persisted:**
- **NEW soft watch `iter1231 Q4 NEXT_DAY-closing-note-self-contradicts`** — re-probe in 4-8 iters under "Oracle NEXT_DAY / next-occurrence-of-weekday in Trino" framing. If recurs (responder publishes correct formula then appends a wrong "add +1 DAY" coda), consider light additive line in r27 NEXT_DAY canonical: "NB: the `target_weekday + 7` ELSE branch ALREADY emits strictly-after (next-week) when today IS the target weekday — do NOT add `+ INTERVAL '1' DAY`, which overshoots by a day." Per `feedback_responder_broken_secondary_alternative.md` — recall-ceiling family. NO churn-worthy FIX-A on first occurrence.
- `iter1230 Q2 plain-correlated-EXISTS-OVER-WARNING` (persisting) — re-probe in 3-7 iters; no recurrence this iter.
- `iter1230 Q3 ::cast in illustrative SQL bodies` (persisting) — passive light-monitor; no recurrence this iter.
- `iter1215 strpos-3-arg ceiling` — recall ceiling, passive watch, NO churn.
- `iter1213 session_properties + (+)-mnemonic` — passive watch.
- `iter1229 Q1 @v1 / "table@snapshot" snapshot-suffix Spark-only` — passive watch.
- `iter1208 width_bucket boundary off-by-one label-phrasing` — passive light-monitor.

**Pin-aligned health:**
- iter1228 r27 §4.5A packages.yml-version-rename FIX-A — REACHED + HOLDING (Q1 lead-with-version, no false-route to file-location).
- `reference_trino_unwrap_temporal_predicates.md` HOLDING (Q2 `year/month = literal` correctly understood as sargable, not flagged as pruning-killer).
- `reference_trino_division_by_zero.md` HOLDING (Q2 NULLIF ratio guard correctly applied).

**Health indicators:**
- All four answers within the PASS band (≥ 3.5 per dimension; iter average 4.6875).
- WATCH closes cleanly on first re-probe (the iter1228 packages.yml-version-rename pair is now down).
- Two questions land clean 5.0 (Q1 + Q2); one with minor stylistic shave (Q3 4.5); one with real (minor) defect (Q4 4.25 self-contradicting closing note).
- No fabrications. No imported-prior misroute. One self-contradicting append-paragraph (Q4) — NO FIX-A.

**Verdict: 4.69 STRONG PASS (margin +1.19). Watch iter1228 packages.yml-version-rename CLOSES. Both iter1228 open watches now CLOSED. NO FIX-A recommended for iter1231. NO-OP — return to breadth probes (training to 2026-06-30 23:59 CST, ~1.5 days remaining).**
