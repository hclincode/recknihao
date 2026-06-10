# Judge Feedback — iter934

**Overall: 4.969 PASS** (Q1 5.00 / Q2 4.875 / Q3 5.00 / Q4 5.00 = 19.875/4 = 4.969; OVERALL AVERAGE governs, no per-Q veto). Margin +1.469 over the 3.5 threshold.

**FEDERATION NOT PROBED** — `Trino federation / cross-source connectors` row (4.49944/310) UNCHANGED.

**TEACHER iter934 EDITS: ZERO (NO-OP durability sweep as planned).**

---

## Per-question scoring

### Q1 — Trino slower than Postgres on simple `COUNT(*) GROUP BY status` — Score 5.00

Accuracy 5 / Beginner clarity 5 / Practical applicability 5 / Completeness 5

- Architectural explanation is correct: Trino on Iceberg/Parquet/MinIO has shuffle + columnar scan/coordinator-worker overhead that Postgres row-store skips; for a small `GROUP BY status` on a low-cardinality column Postgres on a covering index can genuinely be faster — this is not a defect.
- `ANALYZE orders WITH (columns = ARRAY['status'])` syntax VERIFIED against trino.io/docs/467 `sql/analyze.html` — the documented `ANALYZE table_name [WITH (property_name = expression [, ...])]` form with `columns = ARRAY[...]` is the exact pattern shown in official docs. Correct.
- Suggestions (partition-pruning WHERE, ANALYZE for CBO, materialized view / dbt incremental model if frequent) are all production-applicable on the MinIO + Iceberg + Trino 467 stack.
- Setting expectations correctly ("not a defect, here's what TO do and what NOT to do") fits the SaaS engineer audience.

### Q2 — Anti-join: products never sold (LEFT JOIN+IS NULL vs NOT IN vs NOT EXISTS) — Score 4.875

Accuracy 5 / Beginner clarity 5 / Practical applicability 5 / Completeness 4.5

- Hierarchy is correct: LEFT JOIN/IS NULL and NOT EXISTS recommended; NOT IN flagged as the silent-wrong-result trap if the subquery column is nullable (3-valued logic collapses to UNKNOWN → zero rows). This is a real and well-known Trino/ANSI-SQL trap; flagging it is exactly the right call.
- Equivalence claim that LEFT JOIN/IS NULL and NOT EXISTS both lower to the same SemiJoin (anti-join) physical operator is APPROXIMATELY correct — Trino's optimizer recognizes both patterns and produces an anti-join in many cases. The practical guidance (both correct + NULL-safe, NOT IN risky on nullable cols) is sound regardless of microscopic plan differences.
- Minor completeness ding: the answer could have explicitly noted the predicate-placement gotcha (when extra filters on the right table must move INTO the ON clause not WHERE, or they convert the LEFT JOIN to effectively an INNER JOIN and break the anti-join logic). This is a real practical SaaS engineer footgun. Not a defect — just a missed nuance.

### Q3 — Cumulative monthly revenue without self-joins — Score 5.00

Accuracy 5 / Beginner clarity 5 / Practical applicability 5 / Completeness 5

- `SELECT date_trunc('month', created_at) AS month, SUM(amount), SUM(SUM(amount)) OVER (ORDER BY date_trunc('month', created_at) RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) ... GROUP BY date_trunc('month', created_at)` is the CANONICAL ANSI-SQL aggregate-of-grouped-aggregate-in-a-window pattern; Trino 467 supports it (the inner SUM is the GROUP BY aggregate, the outer SUM is a window aggregate computed over the grouped output). VERIFIED against `date_trunc('month',...)` validity in `functions/datetime.html` and window-frame validity in `functions/window.html` (RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW is the documented default for ORDER-BY-with-no-explicit-frame as well as a valid explicit frame).
- The RANGE-vs-ROWS note (identical when one row per month; RANGE is ties-safe) is accurate.
- This is "the right way" — single-pass over the grouped result, no self-join, no correlated subquery, no triangular self-join.

### Q4 — Median on a large table; approximate vs exact — Score 5.00

Accuracy 5 / Beginner clarity 5 / Practical applicability 5 / Completeness 5

VERIFIED in BOTH directions against `functions/aggregate.html`:
- (a) NO `median()` builtin in Trino 467 — CONFIRMED ABSENT.
- (b) NO `percentile_cont` / `percentile_disc` for percentile values; no percentile-flavored `WITHIN GROUP (ORDER BY ...)` for an exact median — CONFIRMED ABSENT in 467 (the responder's "not supported in Trino 467" claim is correct). Note: `WITHIN GROUP` syntax exists in Trino but only for `listagg` per the docs; it is NOT a percentile entry point.
- (c) `approx_percentile(x, 0.5)` scalar form AND `approx_percentile(x, ARRAY[0.25, 0.5, 0.75])` array form are BOTH documented and valid — single pass, T-Digest backed, tunable accuracy parameter.
- (d) Responder's posture "Trino docs do NOT publish a standard-error figure for approx_percentile so don't claim one" is the CORRECT posture — the 2.3% standard-error figure is published for `approx_distinct` ONLY (pinned fact, verified verbatim in aggregate.html). Refusing to fabricate a number is exactly right.

The recommendation is operationally right for a large table on the production stack: single-pass approx is the realistic answer; flagging that no exact percentile builtin exists in 467 stops the engineer from chasing a non-existent function.

---

## Critical-check resolutions

1. **Q1 ANALYZE syntax** — VALID (trino.io/docs/467 sql/analyze.html confirms `WITH (columns = ARRAY[...])`). Architectural explanation accurate for MinIO+Iceberg+Trino vs Postgres-row-store.
2. **Q2 NOT-IN nullable trap** — REAL and correctly flagged. LEFT-JOIN/IS-NULL and NOT-EXISTS guidance sound; predicate-placement gotcha left unmentioned (minor completeness ding only).
3. **Q3 nested SUM(SUM()) OVER** — VALID. Aggregate-of-GROUP-BY-aggregate-in-window is standard ANSI SQL, supported by Trino, and is the canonical no-self-join cumulative-by-bucket idiom. `date_trunc('month', ...)` valid. RANGE-vs-ROWS note correct.
4. **Q4 percentile facts** — ALL four sub-claims VERIFIED (no median, no percentile_cont/disc, both approx_percentile forms valid, no published std error for approx_percentile). Caveat-posture matches pinned fact.

---

## Topic coverage touched

- SQL query best practices for OLAP — Q1 (ANALYZE for CBO, partition pruning); Q3 (running totals without self-joins); Q4 (approximate vs exact percentile).
- Query performance regression diagnosis — Q1 (slow simple aggregation, OLAP-vs-OLTP expectations).
- Analytical query patterns on Iceberg+Trino — Q2 (anti-join), Q3 (time-series cumulative), Q4 (percentile/median at scale).
- Trino CBO / ANALYZE TABLE — Q1 (recommends ANALYZE with columns option).
- Lakehouse design + columnar storage — Q1 (architectural framing).

No topic score row needs to be FAILed; all 4 questions are dialect-clean. The federation row (4.49944/310) remains the lone un-passed row but was not probed this iteration.

---

## Defect scoping

- **No RESOURCE DEFECT.**
- **No RESPONDER SLIP on taught content.**
- **No FINDABLE GAP** — Q2 predicate-placement nuance is a minor completeness opportunity, not a missing card. Resources already cover anti-join patterns; the responder picked the right tools and flagged the right traps.

---

## iter935 plan

**DEFAULT NO-OP** — overall 4.969 PASS, all four answers dialect-clean, zero new defects, zero findable gaps. NO teacher edits required.

Optional re-probe candidates (NO pin touch, SKIP if duplicative):
- Anti-join with an extra right-side filter to test predicate-placement (does responder put it in ON, not WHERE?).
- Cumulative-by-bucket variant with PARTITION BY (per-tenant monthly running total) to keep the SUM(SUM()) OVER muscle warm.
- Percentile-by-group `approx_percentile(amount, 0.5) GROUP BY tenant_id` to confirm group-aware percentile.

**Federation (4.49944/310) is still the only un-passed row** — bulletproofed angles only if probed; skip otherwise.

PIN 467. PRESERVE full iter534-933 pin inventory. NO federation edits. Do NOT bump training/state.json (already 934; passed=true preserved; overall 4.969 PASS holds).
