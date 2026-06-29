# Judge Feedback — iter1276

**Overall**: 4 answers, average **4.78 STRONG PASS** (Q1 4.875 / Q2 4.9375 / Q3 4.625 / Q4 4.6875). Carried SOFT watch iter1271-Q2 (current-vs-longest streak) **CLOSES POSITIVELY** — responder now correctly returns the CURRENT (most-recent) streak, not the LONGEST. Q1 thinnest-topic lift on columnar projection EXPLAIN-ANALYZE-Input-bytes diagnostic. No new defects, no new watches.

---

## Q1 — Wide-table columnar projection (80 cols, SELECT 3 vs SELECT *): **4.875 STRONG PASS — thinnest-topic LIFT, mechanism + diagnostic both verified**

Engineer's mental model gap was "20s vs 4 min on identical row count makes no sense in row-store thinking." Responder routed cleanly through the Parquet columnar mechanism and gave an EXPLAIN-ANALYZE recipe to confirm projection I/O is the cause.

**Load-bearing facts verified**:
- Parquet stores each column as separate **column chunks** within row groups — engine reads only the column chunks for projected columns. Verified via Parquet format docs + Iceberg connector docs.
- Cost dominated by **bytes read from MinIO + decompression**, ~proportional to columns projected, NOT row count — verified principle of column-oriented storage; this is exactly the property that beats Postgres-style row-store on wide-table analytics.
- Iceberg metadata flow (manifest → data files → only-selected column byte-ranges) — correct.
- **Parquet row group ~128MB default** — verified via [trinodb/trino#28250](https://github.com/trinodb/trino/issues/28250) discussing `write.parquet.row-group-size-bytes` 128MB default (Iceberg native table property + Trino session property `parquet_writer_block_size`).
- **EXPLAIN ANALYZE Input/Physical Input line** — verified at [trino.io/docs/467/sql/explain-analyze.html](https://trino.io/docs/467/sql/explain-analyze.html): fragment shows `Input: 1500000 rows (18.17MB) ... Physical Input: 4.51MB`. Both rows identical, **physicalInputDataSize** is the byte-count differentiator. Matches pinned `reference_trino_unwrap_temporal_predicates` adjacent prior-art and iter1258 Q1 verification.

Diagnostic recipe (run EXPLAIN ANALYZE both queries, compare Physical Input line — rows match, bytes differ) is the textbook confirmation flow for projection-I/O vs other-cause.

Minor Clar shave (-0.25, didn't explicitly call out that `SELECT *` materializes ALL 80 column chunks even if many are then discarded — "wasteful" framing is implied but the wide-table SaaS engineer benefits from the explicit "no column-elimination after row materialization" mental model). Minor Compl shave (-0.25, no mention of column-chunk **dictionary/RLE compression** being asymmetric across columns — high-cardinality VARCHAR columns dominate bytes vs INT/BOOL — explains why the ratio can be much more skewed than 3/80; nice-to-have, not load-bearing).

No imported-prior, no broken-secondary, no over-warning, no fabrication.

Acc 5.0 / Clar 4.75 / Prac 5.0 / Compl 4.75.

---

## Q2 — CURRENT consecutive-login streak (RE-PROBE of iter1271-Q2): **4.9375 STRONG PASS — iter1271-Q2 SOFT WATCH CLOSES POSITIVELY**

The iter1271-Q2 failure mode was: responder built the gaps-and-islands mechanism correctly but the FINAL aggregation returned `MAX(streak_len) per user` = LONGEST-ever streak, not the CURRENT (most-recent) streak. The engineer's worked example explicitly distinguished current=1 (last=Jun 25, prior=Jun 20) from any longer historical streak.

**This iter, responder returns CURRENT — not LONGEST — by a correct mechanism**:

1. `is_new_streak` CTE flags streak starts via `LAG(login_date) IS NULL OR date_diff('day', LAG, login_date) != 1`.
2. `streaks` CTE: `SUM(is_new_streak) OVER (PARTITION BY user_id ORDER BY login_date)` = monotonically increasing `streak_id` per user.
3. `per_streak` CTE: `COUNT(*) AS current_streak_length, MAX(login_date) AS latest_login GROUP BY user_id, streak_id`.
4. **Final filter**: `WHERE latest_login = (SELECT MAX(login_date) FROM streaks s WHERE s.user_id = per_streak.user_id)` — selects the per-user MOST-RECENT streak (the one whose final day equals the user's overall last login).

This is mathematically correct: the most-recent streak is the one containing each user's overall max login_date — equivalently, the run with the highest streak_id (since streak_id is monotonic in login_date per user). The correlated-subquery filter form works (no per-row mutation, the subquery is per-user MAX = constant per outer row).

**Day-aware `date_diff('day', a, b) = b - a`** is correct Trino 467 per [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html) — returns days between two dates as bigint. Correct arg order so `=1` catches consecutive-day pairs.

**Gotcha noted**: "build over full history, do NOT pre-filter by date" — this is the standard streak-construction trap (pre-filtering breaks the LAG chain and gives always-zero or wrong-shape streaks per pinned `feedback_synthesis_ceiling_stop_churning.md` family). Surfacing it explicitly is a clarity win.

**Iter1271-Q2 SOFT WATCH `current-vs-longest-streak final-aggregation framing` — CLOSES POSITIVELY** on 1st re-probe. No MAX(streak_len) misroute, no LONGEST-vs-CURRENT confusion. The opposite-direction correction shape — responder now disambiguates "current streak ending on overall max(login_date)" from "longest historical streak."

Minor Clar shave (-0.25, the final correlated subquery is dense for an OLAP newcomer; an equivalent join-to-MAX-table or QUALIFY-style top-row pattern would read more cleanly, though the correlated form is unambiguously correct).

No imported-prior, no broken-secondary, no over-warning, no fabrication.

Acc 5.0 / Clar 4.75 / Prac 5.0 / Compl 5.0.

---

## Q3 — dbt macros for shared WHERE-clause filter: **4.625 STRONG PASS — mechanism correct, "Oops wrong include" detour is a minor clarity ding**

**Load-bearing facts verified** at [docs.getdbt.com/docs/build/jinja-macros](https://docs.getdbt.com/docs/build/jinja-macros):
- `macros/` directory convention (configurable via `macro-paths` in `dbt_project.yml`) — correct.
- `{% macro macro_name(arg1, arg2=default_value) %} ... {% endmacro %}` definition syntax — verbatim correct.
- `{{ macro_name(args) }}` call syntax — correct.
- **Compile-time expansion**: docs verbatim "macro expansion happens at compile time"; compiled SQL lands in `target/compiled/` — correct.
- INTERVAL `'{{ days }}' DAY` interpolation produces valid Trino syntax `INTERVAL '90' DAY` (Trino 467 INTERVAL qualifier DAY is supported per pinned `reference_trino_interval_qualifiers.md`).
- Default-arg form `{% macro last_n_days(column_name, days=90) %}` — supported per dbt Jinja macro spec.
- Edit-one-file → all 15 models pick up next dbt run — correct (compile-time substitution means next build sees new value).

The PRIMARY answer the engineer needs (file location, macro syntax, call site syntax, default-arg pattern, compile-time mental model) is all correct.

**THE DING**: responder included a deliberate WRONG-then-corrected detour:
```
WHERE {% include 'macros/date_filters.sql' %}  -- Oops, wrong include — see below
```
followed by the correct `{{ last_n_days('occurred_at', 90) }}` form.

This is the `feedback_responder_broken_secondary_alternative.md` family pattern — Haiku appending a self-labeled broken alternative to demonstrate contrast. It's at least SELF-LABELED ("Oops, wrong include") and the canonical form follows immediately, so the engineer arrives at the right answer. But for a beginner who scans top-to-bottom and copy-pastes the first thing, the broken `{% include %}` line is noise. The "Oops" framing reduces the harm but doesn't fully neutralize the broken-secondary habit.

Per pinned `feedback_responder_broken_secondary_alternative.md`: scope per-instance one-off slip, NOT a resource defect (no single resource fix addresses the responder's padding-with-self-corrected-wrong-example pattern). **No FIX-A**, no new watch.

Minor Clar shave (-1.0, the "Oops" detour). Minor Prac shave (-0.25, doesn't surface `{{ var('lookback_days', 90) }}` as an even-simpler alternative for a single numeric parameter; the macro is still the right answer for a re-usable WHERE clause but `var()` is the lighter-weight pattern when only the number changes and the column is uniform). Minor Compl shave (-0.25, no mention of `--vars '{lookback_days: 60}'` CLI override or `dbt_project.yml` `vars:` block for environment-level overrides; recall ceiling).

No imported-prior, no over-warning, no fabrication.

Acc 5.0 / Clar 4.0 / Prac 4.75 / Compl 4.75.

---

## Q4 — Oracle MONTHS_BETWEEN / ADD_MONTHS → Trino: **4.6875 STRONG PASS — wrapper Oracle-correct, fractional approximation acceptable with bounded drift**

**Load-bearing facts verified**:

**(a) ADD_MONTHS clamp rule + last_day_of_month wrapper:**
- Oracle ADD_MONTHS clamp rule verified verbatim at [docs.oracle.com ADD_MONTHS](https://docs.oracle.com/en/database/oracle/oracle-database/18/sqlrf/ADD_MONTHS.html): "If date is the last day of the month or if the resulting month has fewer days than the day component of date, then the result is the last day of the resulting month."
- **2026 is NON-leap** (2026 / 4 = 506.5, not integer) → Feb has 28 days → Feb 28 2026 IS month-end. Responder's example `ADD_MONTHS(DATE '2026-02-28', 1) → 2026-03-31` is **correct** (Feb 28 = last day → clamp to last day of March).
- Naive `date_add('month', 1, DATE '2026-02-28')` in Trino → `2026-03-28` (preserves day-of-month) — correct, no Oracle clamp.
- **`last_day_of_month(x) → date`** is a REAL Trino 467 function — verified at [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html).
- Wrapper `CASE WHEN d = last_day_of_month(d) THEN last_day_of_month(date_add('month', n, d)) ELSE date_add('month', n, d) END`:
  - Input IS last-day-of-month → clamps result to last-day-of-target-month ✓
  - Input NOT last-day, target has fewer days (e.g., Jan 30 + 1mo → Feb): relies on Trino's `date_add('month',...)` default behavior of clamping invalid days down to the target-month last day. Standard Trino behavior (Java-Time–based ZonedDateTime arithmetic clamps invalid day-of-month).
  - Net: wrapper replicates Oracle ADD_MONTHS behavior for both rule branches under standard Trino month-arithmetic. **Oracle-correct**.

**(b) MONTHS_BETWEEN integer form + arg order:**
- `date_diff(unit, timestamp1, timestamp2) = timestamp2 - timestamp1` per pinned `reference_trino_datediff_dayaware.md` — DAY-AWARE complete-months semantics (drops fractional), `date_diff('month', '2024-01-15', '2024-02-14') = 0` (haven't reached Feb 15 yet), `date_diff('month', '2024-01-15', '2024-02-15') = 1`.
- Oracle `MONTHS_BETWEEN(d1, d2) = d1 - d2`. So `MONTHS_BETWEEN(current_date, hire_date) → date_diff('month', hire_date, current_date)` — **arg order correct** (responder flips d1/d2 correctly).

**(c) Fractional MONTHS_BETWEEN fallback `date_diff('day', start, end) / 31.0`:**
- This is the documented Oracle "31-day-month" approximation idiom (per iter1269-Q4 prior verification at [docs.oracle.com MONTHS_BETWEEN](https://docs.oracle.com/en/database/oracle/oracle-database/18/sqlrf/MONTHS_BETWEEN.html): "Otherwise Oracle Database calculates the fractional portion of the result based on a 31-day month").
- **For within-1-month spans**: `total_days / 31` MATCHES Oracle's piecewise formula `month_diff - 1 + (31 - day(d2) + day(d1))/31` exactly. Example: Jan 15 → Feb 14 = 30/31 ≈ 0.9677, Oracle formula = 1 - 1 + (31 - 15 + 14)/31 = 30/31 ≈ 0.9677. Match.
- **For multi-month spans**: drifts up to ~1/31 from Oracle's piecewise formula. Example: Jan 15 → Mar 1 — `total_days / 31` = 45/31 ≈ 1.452; Oracle: month_diff=2, day(d1)>day(d2), formula ~ 1.548. Drift ~0.1 months on a 1.5-month span (~6%).
- **Verdict**: acceptable approximation for most accrual/proration reporting (matches Oracle exactly within a single month, bounded drift on multi-month spans, drift converges to 0 as span → integer month boundaries). Responder correctly **hedges** "use only if proration NEEDS the fraction" and offers integer date_diff as primary — steering engineer to the exact-Oracle integer form when fractional isn't required.
- **Minor accuracy caveat NOT FLAGGED**: responder didn't explicitly surface that the day/31 approximation has bounded drift on multi-month spans (quarterly aggregates could see ~3% disagreement with Oracle). Same gap as iter1269-Q4 (where the topic was also accepted as STRONG PASS with -0.25 compl shave for the same reason).

Production-stack-correct (Trino 467 + dbt; wrapper offered as a dbt macro is the right reuse pattern for 5-10 call sites).

Minor Clar shave (-0.5, the wrapper CASE expression density — a beginner OLAP engineer may not immediately see why `d = last_day_of_month(d)` is the Oracle-rule's first branch; a 1-line "this catches inputs that are already month-end → clamp result similarly" preamble would help). Minor Compl shave (-0.5, didn't surface (i) the bounded-drift caveat on multi-month spans for day/31 approximation; (ii) `date_add('quarter', n, d)` / `date_add('year', n, d)` are NOT subject to the Oracle clamp ambiguity since Oracle has separate ADD_MONTHS-only quirk; (iii) `last_day_of_month()` works on TIMESTAMP too if input column is timestamped). Recall ceiling.

No imported-prior, no broken-secondary (the wrapper is the load-bearing answer, not a secondary alternative), no over-warning, no fabrication.

Acc 5.0 / Clar 4.5 / Prac 4.75 / Compl 4.5.

---

## Summary table

| Q | Topic | Score | Notes |
|---|---|---|---|
| Q1 | Query performance basics (columnar projection / EXPLAIN ANALYZE Physical Input) | 4.875 | Thinnest-topic lift; mechanism + diagnostic both verified |
| Q2 | Analytical query patterns (CURRENT consecutive-day streak) | 4.9375 | **iter1271-Q2 SOFT WATCH CLOSES POSITIVELY**; responder now returns CURRENT not LONGEST |
| Q3 | Improving complex SQL perf on Trino with dbt (dbt macros) | 4.625 | Mechanism correct; "Oops wrong include" detour is per-instance broken-secondary slip (NO FIX-A) |
| Q4 | Oracle PL/SQL → dbt+Trino (MONTHS_BETWEEN/ADD_MONTHS) | 4.6875 | last_day_of_month wrapper Oracle-correct; day/31 fractional approximation acceptable with bounded drift |

## Watches closed this iter

- **`iter1271-Q2 current-vs-longest-streak final-aggregation framing`** — **CLOSES POSITIVELY** on first re-probe under explicit CURRENT/MOST-RECENT framing with worked example. Responder mechanism: per-user MAX(login_date) correlated filter to isolate the most-recent streak. No MAX(streak_len) misroute. Opposite-direction correction confirmed.

## No new watches

No new defects. Q3 "Oops wrong include" detour is per-pinned `feedback_responder_broken_secondary_alternative.md` — per-instance one-off, no resource fix appropriate. Q4 day/31 drift is the same accepted approximation as iter1269-Q4 (carry implicitly, no escalation).

## Recommendation to teacher

**NO-OP.** Carried SOFT watch closes; no new defects; thinnest topic lifts steadily. Continue breadth probing.

**Carry watches (un-probed this iter)**: iter1272-Q3 unit-test-free-tier hallucination / iter1270-Q1 PRIMARY-KEY-in-Trino-CREATE-TABLE synthesis slip / iter1268-Q3 dbt grants service-account=USER-vs-ROLE branching / iter1267 Q1+Q2 example-SQL GROUP-BY-shape synthesis slip.

**Thinnest required topic** still query-perf-basics at ~4.16 (+ this iter's 4.875 lift). Q1 4.875 raises it slightly; remains comfortably above 3.5 threshold but the lowest of all PASSED topics.
