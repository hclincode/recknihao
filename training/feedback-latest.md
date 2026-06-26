# Iter1149 Judge Feedback

**Verdict: 4.625 STRONG PASS NO-OP+WATCH. EXTRACT(YEAR_MONTH) iter1148 WATCH CLOSED — re-probe (Q1) returned the canonical `date_trunc('month', event_at)` month bucket with `COUNT(*) FILTER (WHERE event_type = '...')` pivot, no MySQL-field recurrence. One-off iter1148 slip confirmed not source-anchored, not recurrent. Q2 (AVG NULL handling) and Q4 (Trino no implicit varchar→date coercion + DATE 'YYYY-MM-DD' typed literal) are both pin-perfect against trino.io 467 docs. Q3 is the only soft spot of the sweep: the snapshot-isolation explanation for in-place writes is CORRECT and well-sourced to r17 §163 + r27 §298, but the headline "Dashboards are safe / never an error" overstates and the actionable caveat misroutes the engineer's stated FULL-REBUILD job to "switch to incremental MERGE with unique_key and merge_update_columns" — which is an architectural pivot the engineer did not ask for and which addresses a different problem class (large-table delta efficiency) than full-rebuild reader safety. The correct concrete answer for a dbt-trino `materialized='table'` full rebuild is `on_table_exists` mechanic: default `rename` (atomic two-step rename, reader-safe) or explicit `replace` (CREATE OR REPLACE TABLE = single atomic Iceberg snapshot swap, exactly matches the "single Iceberg snapshot" principle the responder named). Classified responder-side recall + misroute (not a resource defect — r17 §163 names CREATE OR REPLACE TABLE as the atomic full-rebuild canonical, r27 §298 names `materialized='table'` as the Iceberg-snapshot-atomic path; neither resource names `on_table_exists`); same family as pinned `feedback_responder_broken_secondary_alternative.md` — primary explanation correct, padded "for completeness" alternative directs to wrong materialization shape. NO FIX-A this iteration; watch label below for re-probe.**

---

## Q1 — Per-month pivot of created+cancelled subscriptions side-by-side, net growth over time (re-probe of iter1148 EXTRACT(YEAR_MONTH) slip)

**Question:** subscriptions(subscription_id, event_type 'created'|'cancelled', event_at timestamp). One row per CALENDAR MONTH with created and cancelled as two side-by-side columns. Net growth over time.

**Responder's answer (summary):**
- `SELECT date_trunc('month', event_at) AS month, COUNT(*) FILTER (WHERE event_type = 'created') AS created, COUNT(*) FILTER (WHERE event_type = 'cancelled') AS cancelled, created - cancelled AS net_growth FROM subscriptions GROUP BY date_trunc('month', event_at) ORDER BY month`.
- Alternative form: `SUM(CASE WHEN event_type = 'created' THEN 1 ELSE 0 END) AS created` etc.
- Claims both produce "identical results AND execution plans" on Trino 467.

**Critical verification:**

> `date_trunc('month', event_at)` is the canonical Trino 467 month-bucket function (verified [trino.io/docs/current/functions/datetime.html](https://trino.io/docs/current/functions/datetime.html)). Returns the truncation aligned to the month start; works on both `timestamp` and `date` inputs.
>
> `COUNT(*) FILTER (WHERE ...)` is supported on Trino 467 per [trino.io/docs/current/functions/aggregate.html](https://trino.io/docs/current/functions/aggregate.html): _"The `FILTER` keyword can be used to remove rows from aggregation processing with a condition expressed using a `WHERE` clause. This is evaluated for each row before it is used in the aggregation and is supported for all aggregate functions."_
>
> No `EXTRACT(YEAR_MONTH FROM ...)` in this answer. **The iter1148 MySQL-import slip did NOT recur.**

**Minor accuracy shave on the "identical execution plans" claim.** `COUNT(*) FILTER (WHERE cond)` and `SUM(CASE WHEN cond THEN 1 ELSE 0 END)` are semantically equivalent (both count rows where `cond` is true), and Trino's logical optimizer often plans them similarly, but "**identical** execution plans" is unverifiable as an absolute. The physical plans share the aggregation operator shape but the projection expressions feeding the aggregator differ (FILTER push-down vs. CASE projection), and I cannot find an official Trino claim that the two are rewritten to a common form. Engineer impact: zero — both queries produce the same results and similar performance — but the responder over-states a guarantee. Minor shave only.

**Watch closure.** r07 `EXTRACT-YEAR_MONTH-MySQL-import iter1148` WATCH **CLOSED**. Single-iteration one-off slip, not recurrent on a re-probe with a structurally similar month-bucketing pivot question. No FIX-A. The pinned imported-prior family (MySQL→Trino) recurs across iter925 / iter1006 / iter954 / iter1148 — each per-question one-off, no single resource fix.

**Scores:**
- Technical accuracy: **4.5** — primary canonical correct; "identical execution plans" minor overstatement.
- Beginner clarity: **5.0** — decoded `FILTER (WHERE ...)`, walked through both forms, named `ORDER BY month` for time-series.
- Practical applicability: **5.0** — copy-paste works.
- Completeness: **5.0** — pivot shape + net growth column + alternative form + ORDER BY for time-series — all covered.
- **Avg: 4.875** — STRONG PASS

---

## Q2 — AVG() with NULL rows — does it count nulls in the denominator, or skip like SUM?

**Question:** AVG() over a column where some rows are NULL — does it count NULL rows in the denominator (deflating the average) or skip them like SUM?

**Responder's answer (summary):**
- AVG() **skips NULLs** in both numerator AND denominator — same as SUM. ANSI behavior.
- Walk-through: 10 rows, 3 NULLs → divide sum-of-non-null by 7 (not 10).
- To include zeros in denominator instead: `AVG(COALESCE(revenue, 0))`.
- Diagnostic: `COUNT(*)` vs `COUNT(revenue)` reveals NULL count.

**Critical verification (trino.io/docs/current/functions/aggregate.html):**

> Quoted: _"all of these aggregate functions ignore null values and return null for no input rows or when all values are null"_ — applies to `avg()` per the general aggregate function family note.
>
> Quoted explicitly for `avg()`: _"does not include null values in the count"_ — i.e., NULL rows are excluded from BOTH the sum AND the divisor.

Exact match. `AVG(COALESCE(revenue, 0))` to include NULL→0 in denominator is the canonical workaround. `COUNT(*) − COUNT(revenue)` for NULL-row count is the standard diagnostic.

**Scores:**
- Technical accuracy: **5.0** — official docs confirm both numerator + denominator skip NULL.
- Beginner clarity: **5.0** — 10 rows / 3 NULLs / divide by 7 walk-through is the cleanest possible exposition.
- Practical applicability: **5.0** — gives both the default behavior AND the COALESCE workaround for counting-zeros case AND the diagnostic.
- Completeness: **5.0** — covers the question, the why-it-matters, the fix, and the diagnostic.
- **Avg: 5.0** — STRONG PASS

---

## Q3 — Nightly dbt full-rebuild of Iceberg events table + concurrent dashboard reads — torn reads / mid-rebuild errors / does Iceberg handle it?

**Question:** Nightly dbt job FULL REBUILDS the events Iceberg table ("drops everything and rewrites it from scratch"). Customer dashboards hit the same table 24/7. Risk that a dashboard query lands mid-rebuild and gets half-old/half-new data or an error? Or does Iceberg handle it?

**Responder's answer (summary):**
- Headline: "Iceberg's snapshot isolation protects readers. Dashboards are safe."
- Explanation: optimistic concurrency + snapshot isolation; readers see the snapshot current when they started; never torn reads; commit atomically swaps the current-snapshot pointer; "never an error."
- CAVEAT: "If your nightly job does a full drop and rewrite (rather than incremental MERGE/INSERT), ensure dbt is written to do an ATOMIC SWAP (single Iceberg snapshot) not a two-phase delete-then-insert. The standard dbt incremental model with unique_key and merge_update_columns handles this correctly."
- Cites r26.

**Critical verification:**

> **(a) Iceberg snapshot isolation for in-place writes — CORRECT.** [iceberg.apache.org/docs/latest/reliability/](https://iceberg.apache.org/docs/latest/reliability/) + [Iceberg spec](https://iceberg.apache.org/spec/) confirm: every write (INSERT/MERGE/DELETE/UPDATE) produces a new snapshot via atomic metadata-file swap; readers loaded at snapshot S see the table exactly as it was at S regardless of subsequent writer commits. r26 §45 of this repo (verified) states verbatim: _"Both isolation levels give readers full snapshot isolation: a query started at snapshot S sees the table exactly as it was at S, regardless of how many writers committed after S."_ For INSERT / INSERT OVERWRITE / MERGE / DELETE the responder's "dashboards safe, never an error" framing is correct.
>
> **(b) BUT the engineer's exact phrasing is "drops everything and rewrites it from scratch" — a literal interpretation matters.** dbt-trino's `table` materialization supports four `on_table_exists` strategies (verified at [docs.getdbt.com/reference/resource-configs/trino-configs](https://docs.getdbt.com/reference/resource-configs/trino-configs)):
> - **`rename` (DEFAULT)** — creates intermediate, renames target→backup, renames intermediate→target. Atomic two-step rename; reader-safe in practice.
> - **`replace`** — emits `CREATE OR REPLACE TABLE` which, per [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html) verbatim _"The connector supports replacing an existing table, as an atomic operation"_ → a single Iceberg snapshot swap; readers see old OR new, never empty, never error.
> - **`drop`** — actual `DROP TABLE` then `CREATE TABLE`. Has a **real window where the table does not exist**; concurrent dashboard reads in that window get **"Table not found"** errors. Documented as an AWS Glue limitation workaround.
> - **`skip`** — no-op via `CREATE TABLE IF NOT EXISTS`.
>
> Iceberg snapshot isolation **only protects against torn reads WITHIN a table's snapshot history.** It does NOT protect against the table object itself being dropped (DROP TABLE removes the catalog entry; readers in that window get a hard "Table does not exist" error from the metastore, not a snapshot fallback). r17 §163 (verified) names this: _"`CREATE OR REPLACE TABLE` ... downstream readers either see the OLD content or the NEW content, never an empty middle state. ... The two-step `DELETE FROM tbl;` then `INSERT INTO tbl SELECT ...;` is NOT atomic across statements — readers can see an empty table between the two commits."_
>
> **(c) Responder's caveat misroutes.** The principle "atomic swap (single Iceberg snapshot) not two-phase delete-then-insert" is the RIGHT load-bearing fact. But the routing "the standard dbt incremental model with unique_key and merge_update_columns handles this correctly" is wrong for the engineer's stated job: the engineer **explicitly said FULL REBUILD**, not an incremental delta. The right concrete answer for a full-rebuild job is the dbt-trino `materialized='table'` configuration with either:
> - default `on_table_exists='rename'` (reader-safe via atomic rename), OR
> - explicit `on_table_exists='replace'` which emits `CREATE OR REPLACE TABLE` — a single Iceberg snapshot swap that exactly matches the responder's named "single Iceberg snapshot" principle.
>
> Both are full-rebuild-compatible. Pivoting to `materialized='incremental'` is an architectural change the engineer didn't ask for, and "incremental MERGE with unique_key" is the wrong fix for "is my full rebuild safe" — it's a fix for a different problem (large-table delta efficiency).
>
> **(d) Headline overstatement.** "Never an error" is too absolute. If the job uses `on_table_exists='drop'`, OR if it's a two-phase `DELETE FROM ...; INSERT INTO ...;` in two separate transactions, there IS a window where dashboards either error ("table not found") or see an empty table. Snapshot isolation alone does NOT cover those scenarios — the right framing is "in-place INSERT/MERGE/DELETE → snapshot-isolated and safe; full-rebuild via `CREATE OR REPLACE TABLE` (single statement) → atomic snapshot swap and safe; explicit DROP+CREATE OR two-step DELETE+INSERT → NOT safe, fix the dbt config."

**Source classification.** The load-bearing canonical IS in resources:
- r17 §163 explicitly names `CREATE OR REPLACE TABLE` as the atomic full-rebuild path on Iceberg 467 with verbatim "never an empty middle state."
- r27 §298 explicitly names `materialized='table'` as emitting `CREATE OR REPLACE TABLE` with "Iceberg snapshot replaces prior data atomically."
- r28 §930 corroborates the same DDL.
- r26 §45 has the verbatim reader-isolation guarantee.

Neither resource names the `on_table_exists` config knob or the dbt-trino default-rename vs explicit-replace mechanics; that level of dbt-trino-internal detail is a recall ceiling. But the principle ("CREATE OR REPLACE TABLE = single atomic Iceberg snapshot, full-rebuild safe") IS in r17 §163 and r27 §298 — the responder did not route through either, instead routed to incremental MERGE which is the wrong materialization shape for the engineer's stated job.

Same family as pinned `feedback_responder_broken_secondary_alternative.md` — primary explanation (snapshot isolation for in-place writes) is correct, padded "for completeness" caveat misroutes to the wrong materialization shape. NO single-edit resource fix would prevent this; it's a Haiku synthesis pattern. Engineer is still mostly safe (the headline "snapshot isolation protects readers" is broadly true, the principle "atomic swap" is named) — but the concrete actionable guidance is muddled.

**NO FIX-A this iteration.** Watch label: r17 / r27 full-rebuild + dashboard safety route — re-probe with a different framing (e.g., "is `materialized='table'` reader-safe for live dashboards?", "can I do a daily full refresh of an Iceberg fact table without breaking concurrent BI users?") to confirm whether the responder reliably routes to `CREATE OR REPLACE TABLE` / `materialized='table'` rather than misrouting to incremental MERGE. If recurrent → consider an additive r27 / r17 cross-ref card explicitly naming the full-rebuild reader-safety question shape and routing to the `materialized='table'` + `CREATE OR REPLACE TABLE` canonical rather than incremental MERGE.

**Scores:**
- Technical accuracy: **3.5** — snapshot isolation explanation correct; "never an error" overstatement (`on_table_exists='drop'` and two-phase DELETE+INSERT both have real windows of failure); caveat names the right principle ("atomic swap, single Iceberg snapshot") but then routes to wrong materialization shape.
- Beginner clarity: **4.5** — clear walk-through of snapshot isolation mechanics; the "MVCC for tables" framing is helpful.
- Practical applicability: **3.0** — engineer with a full-rebuild dbt job is told to switch to incremental MERGE, which is an architectural change they didn't ask for and which addresses a different problem class. Correct concrete answer (use `materialized='table'`; consider `on_table_exists='replace'` for explicit CREATE OR REPLACE TABLE; avoid `on_table_exists='drop'`) not given.
- Completeness: **3.5** — covers in-place-write snapshot isolation well, partially names the atomic-swap principle, misses the concrete dbt-trino full-rebuild mechanics that resolve the engineer's actual question.
- **Avg: 3.625** — PASS (just above threshold)

---

## Q4 — Oracle implicit `WHERE created_date = '2024-01-15'` → Trino type mismatch — right way + migration pattern

**Question:** Oracle allowed `WHERE created_date = '2024-01-15'` (implicit string→date coercion). Trino throws type mismatch. Right way to write date literal comparisons + a consistent migration pattern?

**Responder's answer (summary):**
- Trino has NO implicit string→date coercion. Bare `'2024-01-15'` against a DATE column raises type error.
- Fix: typed literal `WHERE created_date = DATE '2024-01-15'`.
- Migration table: DATE column → `DATE 'YYYY-MM-DD'`; TIMESTAMP column → `TIMESTAMP 'YYYY-MM-DD HH:MM:SS'`.
- Note: `CAST(event_ts AS DATE) = DATE '...'` still prunes via optimizer unwrap-cast-in-comparison, but prefer bare-column form `event_ts >= TIMESTAMP '... 00:00:00' AND event_ts < TIMESTAMP '...+1 00:00:00'` for clarity and to avoid edge cases.
- Cites r07 and r28.

**Critical verification:**

> **(a) No implicit varchar→date coercion in Trino.** Verified via [Trino issue #7334 "Cannot compare timestamp with varchar value"](https://github.com/trinodb/trino/issues/7334) + [trino.io/docs/current/language/types.html](https://trino.io/docs/current/language/types.html) + community report _"In Trino, comparisons like `123 = '123'` raise 'Cannot apply operator: varchar(3) = integer'"_ and _"Trying to query ... with a varchar value (`cd = '2021-01-01'`), Trino fails with 'Cannot apply operator: date = varchar(10)'"_. The implicit-coercion list in Trino is narrow (numeric widening, CHAR↔VARCHAR with trailing-space stripping) — varchar→date is NOT in it.
>
> **(b) `DATE 'YYYY-MM-DD'` typed literal is the fix.** Standard Trino type-prefixed literal syntax per [trino.io/docs/current/language/types.html](https://trino.io/docs/current/language/types.html). Same pattern for `TIMESTAMP '... 00:00:00'`, `TIMESTAMP WITH TIME ZONE '... UTC'`.
>
> **(c) `CAST(event_ts AS DATE) = DATE '...'` still prunes via optimizer unwrap.** Verified per pinned `reference_trino_unwrap_temporal_predicates.md` and [trino.io/docs/current/optimizer/pushdown.html](https://trino.io/docs/current/optimizer/pushdown.html) — Trino's default-on `UnwrapCastInComparison` / `UnwrapYearInComparison` / `UnwrapDateTruncInComparison` rules rewrite `CAST(col AS date) = lit` (and `year(col) = lit`, `date_trunc(col) = lit`) into bare-column ranges that still prune partitions on identity / day / month / year transforms. So the responder's "still prunes via unwrap, but prefer bare-column form" is the precisely-correct framing — both forms prune, bare-column is just easier to read and avoids edge cases (e.g., the unwrap rule has known edge cases on type-narrowing casts).

All four facts in Q4 are verified correct. Migration pattern is the canonical Oracle→Trino dialect translation. Cross-ref to r07 (temporal-predicate pruning canonicals) and r28 (full-rebuild materialization) is appropriate.

**Scores:**
- Technical accuracy: **5.0** — no implicit varchar→date coercion confirmed; DATE typed literal confirmed; unwrap-cast still prunes confirmed; migration table accurate.
- Beginner clarity: **5.0** — explained the error message engineer would see, gave drop-in replacement, named the cast-still-prunes nuance with the right preference order.
- Practical applicability: **5.0** — engineer has a copy-paste migration table for both DATE and TIMESTAMP columns.
- Completeness: **5.0** — names the type error, the fix, the migration pattern, AND the unwrap-cast edge case — covers everything the engineer needs.
- **Avg: 5.0** — STRONG PASS

---

## Overall verdict

**Iter1149: 4.625 STRONG PASS NO-OP+WATCH**

| Q | Score | Topic | Status |
|---|---|---|---|
| Q1 | 4.875 | Analytical query patterns on Iceberg+Trino | STRONG PASS — iter1148 EXTRACT(YEAR_MONTH) WATCH CLOSED |
| Q2 | 5.000 | SQL query best practices for OLAP | STRONG PASS |
| Q3 | 3.625 | Iceberg table maintenance | PASS (full-rebuild reader-safety route slightly off) |
| Q4 | 5.000 | Oracle PL/SQL→dbt/Trino migration | STRONG PASS |

**FIX-A spec (DO NOT WRITE — watch only):**
- None this iteration. Q3 misroute is responder-side recall ceiling + broken-secondary-alternative family (pinned `feedback_responder_broken_secondary_alternative.md`); the load-bearing canonicals ARE in r17 §163 + r27 §298 + r28 §930. Q1 watch closes cleanly.

**Watch labels for next sweep:**
- r17 / r27 full-rebuild reader-safety route — re-probe with a different framing of the same scenario (e.g., "is `materialized='table'` reader-safe for live dashboards?", "what happens to BI users when a daily full-refresh fact table runs?", "do I need to add a maintenance window for nightly Iceberg rebuilds?") to confirm whether the responder leads with `materialized='table'` + `CREATE OR REPLACE TABLE` atomic-snapshot canonical or misroutes to incremental MERGE. If recurrent → additive cross-ref card explicitly mapping "full-rebuild + concurrent dashboards" question shape to the `materialized='table'` / `CREATE OR REPLACE TABLE` canonical (not incremental).
- r07 EXTRACT-YEAR_MONTH-MySQL-import — CLOSED (iter1149 re-probe used `date_trunc('month', event_at)` cleanly).

**Production-environment fit:** All four answers fit the on-prem Trino 467 + Spark + Iceberg 1.5.2 + HMS + MinIO stack. Q3's snapshot-isolation explanation is correct for in-place writes on this stack; the misroute is a recall/synthesis issue, not a stack-fit issue. Q4's migration guidance is squarely on dialect.

**Margin status across all touched topics (post-update):**
- Analytical query patterns on Iceberg+Trino: was 4.58259/101, after Q1=4.875 → ~4.5854/102 — clean lift, margin +1.0854.
- SQL query best practices: was 4.56727/214, after Q2=5.0 → ~4.5693/215 — clean lift.
- Iceberg table maintenance: was 4.48113/183, after Q3=3.625 → ~4.47645/184 — small drop, margin still +0.97645 above threshold.
- Oracle PL/SQL migration: was 4.44275/121, after Q4=5.0 → ~4.4501/122 — clean lift.

All topics remain comfortably above the 3.5 pass threshold (and well above the +0.9 historical margins for the at-risk rows).

---

## Doc citations

- [Trino 467 Date/time functions — date_trunc](https://trino.io/docs/current/functions/datetime.html) — confirms `date_trunc('month', ts)` canonical month-bucket.
- [Trino 467 Aggregate functions — FILTER clause + avg() NULL handling](https://trino.io/docs/current/functions/aggregate.html) — confirms `COUNT(*) FILTER (WHERE ...)` is supported on all aggregates AND `avg()` skips NULL in both numerator and denominator (`"does not include null values in the count"`).
- [Trino 467 Iceberg connector — CREATE OR REPLACE TABLE atomic](https://trino.io/docs/current/connector/iceberg.html) — confirms _"The connector supports replacing an existing table, as an atomic operation"_ and _"Atomic table replacement creates a new snapshot with the new table definition as part of the table history."_
- [Iceberg Reliability docs — snapshot isolation](https://iceberg.apache.org/docs/latest/reliability/) — confirms readers see consistent snapshot at load time, immune to subsequent writer commits.
- [Apache Iceberg spec — atomic metadata swap](https://iceberg.apache.org/spec/) — confirms commit mechanic is single atomic metadata-file swap.
- [dbt-trino configurations — on_table_exists modes](https://docs.getdbt.com/reference/resource-configs/trino-configs) — confirms four modes (`rename` default, `replace`, `drop`, `skip`); `rename` is atomic two-step rename; `replace` uses `CREATE OR REPLACE TABLE`; `drop` does literal `DROP TABLE` + `CREATE TABLE` (window of non-existence).
- [Trino issue #7334 — Cannot compare timestamp with varchar](https://github.com/trinodb/trino/issues/7334) — confirms no implicit varchar→date coercion; comparison raises `TYPE_MISMATCH: Cannot apply operator: date = varchar(10)`.
- [Trino 482 / current data types](https://trino.io/docs/current/language/types.html) — implicit-coercion list does NOT include varchar→date.
- [Trino optimizer / pushdown — UnwrapCastInComparison](https://trino.io/docs/current/optimizer/pushdown.html) — `CAST(col AS date) = lit` still prunes via bare-column-range rewrite.
- r07 (EXTRACT field validity), r17 §163 (`CREATE OR REPLACE TABLE` as atomic full-rebuild canonical), r26 §45 (reader snapshot-isolation guarantee), r27 §298 (`materialized='table'` = `CREATE OR REPLACE TABLE` Iceberg-snapshot-atomic), r28 §930 (same dbt-trino DDL) — all source-aligned with responder's claims where claimed; the Q3 misroute did NOT use these canonicals.
