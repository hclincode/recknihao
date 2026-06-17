# iter1003 Judge Feedback

**OVERALL 4.4063 — PASS** (threshold 3.5; margin +0.906). Sum 70.5/16. OVERALL AVERAGE governs, no per-Q veto.

All facts verified against trino.io/docs/467 + RAW git-tag 467 source + official GitHub issues — NOT against resources/. Prod stack (Trino 467 Iceberg + Hive Metastore on-prem MinIO + Spark ingestion + dbt) — all 4 Qs fit; no federation drag-in; no auth angle.

## Per-question scores

### Q1 — cumulative/running total of daily signups — 3.0 (DEFECT: `::` cast invalid in 467)
- Accuracy **2.0** / Clarity **4.0** / Applicability **2.0** / Completeness **4.0** = 12.0/4 = 3.0
- **WINDOW LOGIC CORRECT:** `SUM(COUNT(*)) OVER (ORDER BY day ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` is the canonical running-total-of-daily-aggregate pattern — aggregate-over-window after GROUP BY is legal Trino 467; the frame explanation (UNBOUNDED PRECEDING..CURRENT ROW = cumulative) is accurate and clear.
- ★★ **DEFECT — `::` CAST OPERATOR IS A PARSE ERROR IN TRINO 467.** The answer uses `created_at::date` THREE times (SELECT, GROUP BY, ORDER BY). Trino 467 does **NOT** support the PostgreSQL/Snowflake/DuckDB `::` cast shorthand.
  - **Citation:** GitHub issue [#23795 "Cast operator `::`"](https://github.com/trinodb/trino/issues/23795) is **OPEN** (labels: "enhancement", "syntax-needs-review"); linked PR [#25259](https://github.com/trinodb/trino/pull/25259) is **OPEN / unmerged** as of June 2026. Trino 467 was released **6 Dec 2024** (release-467), well before any merge. The `language/types.md` and conversion docs for 467 document only `CAST(x AS type)` / `TRY_CAST`; there is no `::` token in the grammar.
  - **CORRECTION (canonical):** use `CAST(created_at AS date)` in all three positions:
    ```sql
    SELECT CAST(created_at AS date) AS signup_day,
           COUNT(*) AS signups_today,
           SUM(COUNT(*)) OVER (ORDER BY CAST(created_at AS date)
                               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative_signups
    FROM user_events
    GROUP BY CAST(created_at AS date)
    ORDER BY CAST(created_at AS date)
    ```
  - **Imported-prior family** slip (PostgreSQL `::` habit). The query fails to parse on the first `::`, so the engineer cannot run it as written — hence low Accuracy/Applicability despite correct window semantics.
  - Stylistic alternative (not scored): `date_trunc('day', created_at)` (returns timestamp) is another day-bucketing form, but `CAST(... AS date)` is the right fix for the responder's intent.

### Q2 — pivot: one row per customer, count per plan, no joins — 5.0
- Accuracy **5.0** / Clarity **5.0** / Applicability **5.0** / Completeness **5.0** = 20/4 = 5.0
- Conditional aggregation `SUM(CASE WHEN plan_name='starter' THEN 1 ELSE 0 END)` per plan + `GROUP BY customer_id` is the correct join-free pivot. The `COUNT(*) FILTER (WHERE plan_name='starter')` variant is also correct and equivalent.
- **VERIFIED:** `FILTER (WHERE <condition>)` is supported for **all** aggregate functions in 467 (functions/aggregate). Both forms equivalent — responder's "both equivalent" claim correct. Clean, complete, no tics.

### Q3 — true median / 50th percentile (AVG skewed by outliers) — 4.8125
- Accuracy **5.0** / Clarity **4.75** / Applicability **4.75** / Completeness **4.75** = 19.25/4 = 4.8125
- **VERIFIED both directions:** `approx_percentile(col, 0.5)` (scalar) and `approx_percentile(col, ARRAY[0.5,0.95,0.99])` (array) both exist in 467 (functions/aggregate). There is **NO** native `MEDIAN()` and **NO** SQL-standard `PERCENTILE_CONT()` — both-absent claim correct (aligns with r05 §2234 PERCENTILE footgun lock). T-Digest/approximate framing correct; "exact requires full sort" accurate. Clean.

### Q4 — top 5 most-viewed pages per country (not global) — 4.8125
- Accuracy **5.0** / Clarity **4.75** / Applicability **4.75** / Completeness **4.75** = 19.25/4 = 4.8125
- `ROW_NUMBER() OVER (PARTITION BY country ORDER BY view_count DESC)` in a subquery, filtered `WHERE rank_in_country <= 5` — canonical top-N-per-group; PARTITION BY country gives per-country (not global) ranking. Correct; no QUALIFY (correctly avoided — not in 467). Clean.

## Tics check
All CLEAN except Q1 `::` cast. No QUALIFY, no fabricated function, no false-mechanism, no broken-secondary, no regex-backslash, no INTERVAL-quarter/week, no GREATEST/LEAST-NULL. Q2/Q3/Q4 bulletproof.

## Recommendation — DEFAULT NO-OP (with re-probe watch)

Despite the Q1 defect, recommend **DEFAULT NO-OP — no resource edit this iter**:
- **FIRST** observation of a `::`-cast slip in this sweep window. Per reconcile/2-in-2 discipline, a single imported-prior responder slip on an otherwise-correct query is a **per-instance one-off**, not yet a source-verified findable resource gap. Substance (window/cumulative) correct; only cast shorthand wrong.
- Before any FIX-A, the teacher/orchestrator should **grep resources/ for any `::` usage** — if a resource models `x::type`, that is the root cause and must be reconciled in place (replace with `CAST(x AS type)`). If resources are clean, this is responder prose import, not a defect.

**Re-probe next sweep:** issue another day/period-bucketing or cast-bearing Q (e.g. `CAST`-to-date, `date_trunc('day', ...)`). If `::` recurs (**2-in-2**), escalate to a LIGHT additive defang: a copy-attractive `CAST(x AS date)` canonical with an inline-marked `-- WRONG: x::date is a PARSE ERROR in Trino 467 (PR #25259 unmerged)` un-copyable note (defang-don't-bare-negative-example discipline).

Federation r22 §13.x hard-locked — NOT probed (OVERRIDDEN); federation row stays 4.49944/310. MUST NOT bump training/state.json (already 1003; passed=true preserved; final_iterations_remaining 0).
