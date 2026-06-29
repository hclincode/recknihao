# Iter 1269 — Judge Feedback

**Overall: 4.95 STRONG PASS** (Q1 5.00 / Q2 5.00 / Q3 4.875 / Q4 4.9375)
**iter1268 Q2 QUALIFY-pulled-into-Trino-dialect WATCH → CLOSES on 1st-angle re-probe.**

---

## Per-question scores

### Q1 — feature_flags VARCHAR pipe-delimited → count events per individual flag (split + UNNEST + GROUP BY)

**Score 5.0** (Acc 5.0 / Clar 5.0 / Prac 5.0 / Compl 5.0)

Canonical split + CROSS JOIN UNNEST + GROUP BY explode-and-count pattern, all three primitives verified against Trino 467 docs.

Responder: `WITH exploded AS (SELECT event_id, flag FROM events CROSS JOIN UNNEST(split(feature_flags,'|')) AS t(flag)) SELECT flag, COUNT(*) FROM exploded GROUP BY flag ORDER BY count DESC` + caveat "if already ARRAY(VARCHAR) skip split".

VERIFIED via WebFetch of [trino.io/docs/467/functions/string.html](https://trino.io/docs/467/functions/string.html): `split(string, delimiter)` returns array; delimiter is LITERAL (not regex — for regex use `regexp_split`); `'|'` works as a literal pipe with no shell-escape concerns. CROSS JOIN UNNEST(array) AS t(col) produces one row per array element joined to outer row (cross-product); empty/NULL array drops the outer row (LEFT JOIN UNNEST ... ON TRUE would keep). For "count per individual flag" where empty-flag events should not contribute, CROSS JOIN is correct.

Engineer copy-pastes → exact answer to "event with 3 flags adds 1 to each flag".

No imported-prior slip, no broken-secondary alt, no over-warning. Strong probe, clean canonical.

### Q2 — Top 3 deals by value per salesperson, no QUALIFY in Trino 467 (RE-PROBE of iter1268 Q2)

**Score 5.0** (Acc 5.0 / Clar 5.0 / Prac 5.0 / Compl 5.0)

**iter1268 Q2 QUALIFY-pulled-into-Trino-dialect synthesis slip WATCH CLOSES on 1st-angle re-probe.**

Responder: `SELECT salesperson_id, account_name, deal_value, closed_at FROM (SELECT ..., ROW_NUMBER() OVER (PARTITION BY salesperson_id ORDER BY deal_value DESC) AS rn FROM deals) WHERE rn <= 3 ORDER BY salesperson_id, deal_value DESC` + explicit "Trino 467 does NOT support QUALIFY (Snowflake/BigQuery/Databricks/Teradata); must wrap window function in subquery + filter outer WHERE rn<=3" + RANK() variant for ties (rnk<=3 keeps ties, may return more than 3 rows).

VERIFIED via WebFetch of [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html): SELECT statement clauses are WITH → SELECT → FROM → WHERE → GROUP BY → HAVING → WINDOW → set-ops → ORDER BY → OFFSET → LIMIT — NO QUALIFY in the grammar; the term "QUALIFY" does not appear in the page. Canonical top-N-per-group pattern verified as the documented approach: ROW_NUMBER() in a subquery + outer WHERE rn<=N.

**Recovery shape**: opposite-of-iter1268 — this iter the responder EXPLICITLY refutes QUALIFY availability and lands the standard subquery pattern. The engineer's prompt "engineer KNOWS Trino 467 can't filter window result in same SELECT" framing did contain a strong hint, so this re-probe is a 1st-angle confirmation rather than an unprompted recall; watch closes as NEAR-CLOSE — recommend a 2nd-angle re-probe in the next 4-8 iters under framings WITHOUT the engineer-supplied "no QUALIFY" hint before declaring fully bulletproofed.

No imported-prior slip, no broken-secondary alt, no over-warning.

### Q3 — stg_events view → ephemeral with 4 downstreams; does ephemeral pre-compute or compile differently; would it speed builds?

**Score 4.875** (Acc 5.0 / Clar 4.75 / Prac 5.0 / Compl 4.75)

EPHEMERAL=COMPILE-TIME-CTE-INLINING semantic correctly named + "STAY WITH VIEW" verdict on 4 downstreams matches dbt docs verbatim.

Responder: (1) ephemeral compiles DIFFERENTLY not faster; (2) view = Trino VIEW object, downstream issues SELECT * FROM view at runtime; ephemeral = NO warehouse object, dbt inlines whole SELECT as a WITH clause in EVERY downstream's compiled SQL at COMPILE TIME; (3) switching view→ephemeral with 4 downstreams = compile-time SQL bloat (stg_events SQL inlined 4x, larger queries, longer parse + repeated computation per downstream); (4) recommend STAY with view; ephemeral only for small single-use intermediates (<2-3 downstreams).

VERIFIED via WebFetch of [docs.getdbt.com/docs/build/materializations](https://docs.getdbt.com/docs/build/materializations) verbatim: "ephemeral models are not directly built into the database. Instead, dbt will interpolate the code from an ephemeral model into its dependent models using a common table expression (CTE)"; CTE identifier prefixed `__dbt__cte__`; docs explicitly recommend ephemeral for "models used in **one or two downstream models**, and Models that don't need direct querying" — responder's "<2-3 downstreams" threshold matches docs.

Duplicate-computation mechanism correct: with 4 downstreams, the same stg_events transformation is computed independently 4 times (once per downstream's compiled query). Net: ephemeral does NOT speed builds for this shape, can actually slow them via plan bloat.

Minor shaves: (-0.25 Clar) "compile time" jargon used without a one-line beginner aside ("compile = when dbt converts your model into the SQL Trino actually runs"); (-0.25 Compl) didn't mention docs-surfaced cons "Overuse of ephemeral materialization can make queries harder to debug" (can't query an ephemeral object directly), and could surface "view materialization on Trino+Iceberg has trivial overhead since Trino inlines the view definition at plan time" to reinforce STAY-with-view.

No imported-prior, no broken-secondary alt, no over-warning, no fabrication.

### Q4 — Oracle MONTHS_BETWEEN fractional vs Trino date_diff('month') = 0 for Jan15→Feb14

**Score 4.9375** (Acc 5.0 / Clar 5.0 / Prac 5.0 / Compl 4.75)

DAY-AWARE complete-months semantics + Oracle 31-day approximation both correctly named, matches pinned `reference_trino_datediff_dayaware.md`.

Responder: (1) date_diff('month', d1, d2) counts COMPLETE months day-aware: Jan15→Feb14 = 0 (haven't reached Feb15 yet), Jan15→Feb15 = 1; (2) Oracle MONTHS_BETWEEN gives ~0.96 for Jan15→Feb14 (fractional, 31-day convention); (3) reproduce fractional in Trino: `CAST(date_diff('day', d1, d2) AS DOUBLE) / 31.0` — for Jan15→Feb14 = 30/31 ≈ 0.9677.

VERIFIED Oracle 31-day fractional convention via WebSearch + [docs.oracle.com MONTHS_BETWEEN](https://docs.oracle.com/en/database/oracle/oracle-database/18/sqlrf/MONTHS_BETWEEN.html) verbatim: "If date1 and date2 are either the same days of the month or both last days of months, then the result is always an integer. Otherwise Oracle Database calculates the fractional portion of the result based on a 31-day month."

Oracle formula (else-branch, day(d1)<day(d2)): months = month_diff - 1 + (31 - day(d2) + day(d1))/31. For MONTHS_BETWEEN(Feb14, Jan15): month_diff=1, day(d1)=14, day(d2)=15 → 1 - 1 + (31-15+14)/31 = 30/31 ≈ 0.9677. **EXACT MATCH** for responder's approximation on this specific case.

VERIFIED Trino date_diff('month') day-aware via pinned `reference_trino_datediff_dayaware.md` (DateTimeFunctions.java git-tag source): drops fractional, returns complete-units, Jan15→Feb14 = 0, Jan15→Feb15 = 1.

Minor (-0.25 Compl): the day/31 approximation matches Oracle EXACTLY for within-1-month spans but can drift up to ~1/31 from Oracle's piecewise-day-aware formula on multi-month spans (e.g., 6 weeks Jan15→Mar1 Oracle=1+17/31=1.548 vs day/31=42/31=1.355) — responder didn't surface that the approximation has bounded drift on >1-month spans; engineer using this for accrual could see ~3% disagreement vs Oracle on quarterly aggregates. Practical impact bounded; the responder correctly hedged "use only if proration/accrual NEEDS the fraction" steering away from day/31 when integer date_diff suffices.

No imported-prior slip, no broken-secondary alt, no fabrication.

---

## Verification results (judge WebSearch/WebFetch)

| Verify | Source | Result |
|---|---|---|
| Q1 split literal-delimiter + UNNEST one-row-per-element | trino.io/docs/467/functions/string.html | CONFIRMED — split(string, delimiter[, limit]); delimiter literal not regex |
| Q2 QUALIFY absent in Trino 467 + ROW_NUMBER subquery+outer WHERE canonical | trino.io/docs/467/sql/select.html | CONFIRMED — QUALIFY not in SELECT grammar; canonical pattern documented |
| Q3 ephemeral = compile-time CTE inlining, no DB object, recommend <2 downstreams | docs.getdbt.com/docs/build/materializations | CONFIRMED — "interpolate code into dependent models using a CTE"; docs recommend "one or two downstream models" |
| Q4 Oracle MONTHS_BETWEEN 31-day fractional convention | docs.oracle.com MONTHS_BETWEEN + pinned reference_trino_datediff_dayaware | CONFIRMED — 31-day convention verbatim; Trino date_diff day-aware complete-units verbatim from git-tag source |

---

## Explicit slip-status statement (per judge prompt)

1. **iter1268 Q2 QUALIFY-pulled-into-Trino slip recurred?** NO — Q2 this iter is CORRECT. Responder explicitly refuted QUALIFY availability ("Trino 467 does NOT support QUALIFY (Snowflake)") and used the canonical subquery + outer WHERE rn<=3 form, with a RANK() variant correctly described for tie-keeping behavior. The engineer's prompt did contain a "no QUALIFY" hint, so this is a 1st-angle hinted re-probe rather than unprompted recall — recommend 2nd-angle re-probe within 4-8 iters under "top 3 per group" framings WITHOUT the no-QUALIFY hint before declaring fully bulletproofed.

2. **Errors this iter?** None load-bearing. Two minor shaves: Q3 didn't surface the dbt-docs-listed "ephemeral makes debugging harder" con + didn't reinforce that Trino view overhead is trivial; Q4 didn't surface that the day/31 approximation has bounded ~1/31 drift from Oracle on multi-month spans. Neither shave triggers FIX-A.

3. **FIX-A / new watch?** NO FIX-A this iter. NO NEW WATCH. The iter1268 Q2 QUALIFY watch closes to NEAR-CLOSE (needs 2nd-angle unhinted re-probe). Other open watches carry over: iter1268 Q3 grants-service-account-USER-vs-ROLE (soft); iter1267 Q1+Q2 example-GROUP-BY-shape (soft); iter1215 strpos-3-arg (NEAR-CLOSE, needs 2nd angle); iter1260 Q1 CDC-MERGE-multi-event-dedup; iter1258 Q3 SELECT-*-EXCEPT; iter1255 Q1 bloom-CREATE-syntax; iter1248 Q3 MATCH_RECOGNIZE-adjacency; iter1229 @v1-Spark.

---

## Topic score updates

| Topic | Before | After | Delta |
|---|---|---|---|
| Analytical query patterns on Iceberg+Trino (Q1 5.0 + Q2 5.0) | 4.4960 / 195 | 4.5012 / 197 | +0.0052 |
| Improving complex SQL performance on Trino with dbt (Q3 4.875) | 4.4697 / 78 | 4.4748 / 79 | +0.0051 |
| Oracle PL/SQL → dbt + Trino SQL migration (Q4 4.9375) | 4.4996 / 237 | 4.5015 / 238 | +0.0019 |

All required topics PASSED. Thinnest topic remains Query performance basics (4.1953/38).

---

## Pattern observation across recent iters

iter1269 = 4.95 STRONG PASS, recovers cleanly from the iter1268 4.00 PASS (single-Q2 QUALIFY slip) and iter1267 4.0625 PASS (broken-example-shape slips). Three consecutive iters covered different failure modes (broken-example-shape → foreign-clause-pulled → clean recovery), and the recovery this iter REFUTED the iter1268 imported-prior explicitly — confirming the slip was per-instance synthesis variance, not a resource defect. No churn justified.

Continue BREADTH probing under the unhinted-framing principle: re-probe top-N-per-group AND fan-out-dedup framings WITHOUT the "engineer KNOWS no QUALIFY" hint within 4-8 iters; if responder lands the canonical subquery form unprompted, iter1268 Q2 watch fully closes.
