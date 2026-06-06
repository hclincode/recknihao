# Judge Feedback — Iter 537

**Date:** 2026-06-06
**Phase:** extended
**Overall:** 4.813 STRONG PASS (margin +1.313 above 3.5 floor) — 132nd consecutive overall PASS
**Federation NOT probed — 4.49944/310 row UNCHANGED.**

---

## HEADLINE — Q1 dbt-snapshot-meta-columns WIN + Q4 NULLS-default CONFIRMED CORRECT

1. **PRIMARY WIN (Q1 — iter536 column slip CLOSED on first re-probe)**: Iter536 Q3 responder swapped `dbt_updated_at` for `dbt_is_deleted` in the default-meta-column list. Iter537 teacher rewrote r09 L410-416 in-place with the correct four defaults + a DEFAULT-vs-CONDITIONAL paragraph + DO-NOT-WRITE pin. **Iter537 responder now answers correctly on the first re-probe**: lists the four defaults `dbt_scd_id, dbt_updated_at, dbt_valid_from, dbt_valid_to` AND explicitly states "dbt_is_deleted is NOT one of the four defaults — added only if hard_deletes='new_record'". Verified at docs.getdbt.com/reference/resource-configs/snapshot_meta_column_names verbatim: "dbt_is_deleted ... Added when `hard_deletes='new_record'` is configured." **Same closure pattern as iter400/402/535/536 — teacher's in-place fix + DO-NOT-WRITE landed on first re-probe.**

2. **Q4 CRITICAL VERIFY — responder's NULLS-LAST-regardless-of-direction claim is CORRECT per Trino docs**. Verified at trino.io/docs/current/sql/select.html verbatim: **"The default null ordering is `NULLS LAST`, regardless of the ordering direction."** Responder's claim that "NULLs always appear at the bottom REGARDLESS of whether you sort ASC or DESC" matches the doc exactly. The Oracle-contrast ("different from Oracle which puts NULLs first on DESC by default") is also apt — Oracle's default is "NULLS LAST for ASC, NULLS FIRST for DESC." **NO fabrication — the responder's answer is doc-accurate.** This was exactly the kind of claim the meta-rule warned about (false-positives from inferring Trino behavior from Postgres/Oracle convention) — I verified against the Trino doc directly and the responder is right. Score Q4 HIGH.

---

## Per-question scores

### Q1 — dbt snapshot meta-columns (active-row filter)

| Dim | Score | Justification |
|---|---|---|
| Accuracy | 5.0 | Correct four defaults: `dbt_scd_id, dbt_updated_at, dbt_valid_from, dbt_valid_to`. Explicitly distinguishes `dbt_is_deleted` as conditional on `hard_deletes='new_record'` — matches dbt docs verbatim. Active-row filter `WHERE dbt_valid_to IS NULL` correct. |
| Completeness | 5.0 | All four defaults + the conditional fifth + the active-row filter + point-in-time reconstruction example. |
| Clarity | 5.0 | Plainly explains each column's role. |
| Actionability | 5.0 | Engineer can copy the WHERE clause and trust the column list. |

**Avg: 5.000 — STRONG PASS, WIN CLOSURE.**

### Q2 — approx_percentile (vs exact, accuracy tradeoff)

| Dim | Score | Justification |
|---|---|---|
| Accuracy | 4.5 | `approx_percentile(col, 0.95)` correct; `ARRAY[0.5,0.95,0.99]` array form verified at trino.io/docs/current/functions/aggregate.html. T-Digest sketch claim correct. **CORRECT**: "Trino does NOT support PERCENTILE_CONT(...) WITHIN GROUP" — verified absent from trino.io aggregate docs. **CORRECT**: no exact percentile aggregate in Trino. Conservative "docs don't publish a fixed error bound" is defensible — the aggregate-functions doc page does not quote an explicit error bound. **Minor under-claim**: did not surface the optional accuracy 4th parameter that some signatures expose (per github.com/trinodb/trino/issues/12276). |
| Completeness | 4.5 | Dashboard-vs-billing/SLA framing covers the when-vs-exact question; multi-percentile array form is a nice plus. Missed the optional accuracy parameter; PERCENT_RANK() window suggestion for exact percentiles is correct. |
| Clarity | 5.0 | Plain language, concrete examples. |
| Actionability | 4.5 | Engineer knows when to use it, what it costs, and that no exact aggregate exists in Trino. |

**Avg: 4.625 — STRONG PASS.**

### Q3 — Conditional aggregation (completed-only AOV)

| Dim | Score | Justification |
|---|---|---|
| Accuracy | 4.5 | `FILTER (WHERE ...)` clause is valid Trino — verified at trino.io/docs/current/functions/aggregate.html verbatim: "The `FILTER` keyword can be used to remove rows from aggregation processing with a condition expressed using a `WHERE` clause. ... This is ... supported for all aggregate functions." Equivalence with SUM(CASE WHEN ...) is correct. **MINOR MISLABEL**: first example used `SUM(order_value)` but labeled "avg"; the later `AVG(amount) FILTER` example is correct, so mechanism is well-illustrated overall. |
| Completeness | 4.5 | Covers FILTER, the CASE-WHEN equivalent, and that it works on COUNT/SUM/AVG. |
| Clarity | 4.5 | Clear despite the SUM-vs-AVG mislabel in the first snippet. |
| Actionability | 5.0 | Engineer can drop `FILTER (WHERE status='completed')` after their aggregate. |

**Avg: 4.625 — STRONG PASS.**

### Q4 — ORDER BY NULLS default + control

| Dim | Score | Justification |
|---|---|---|
| Accuracy | 5.0 | **VERIFIED CORRECT** against trino.io/docs/current/sql/select.html verbatim: "The default null ordering is `NULLS LAST`, regardless of the ordering direction." Responder's "NULLs always appear at the bottom REGARDLESS of whether you sort ASC or DESC" matches doc exactly. Oracle-contrast (NULLS FIRST on DESC by default) is apt. `NULLS FIRST` / `NULLS LAST` override syntax correct. |
| Completeness | 5.0 | Default + ASC/DESC clarification + Oracle contrast + explicit override syntax. |
| Clarity | 5.0 | DESC example showing NULLs at the bottom makes the "regardless of direction" rule concrete. |
| Actionability | 5.0 | Engineer knows the default AND how to override per column. |

**Avg: 5.000 — STRONG PASS.**

---

## Overall

`(5.000 + 4.625 + 4.625 + 5.000) / 4 = 19.250 / 4 = 4.8125 ≈ 4.813` — **STRONG PASS**, margin +1.313 above 3.5 floor.

132nd consecutive overall PASS in extended phase.

---

## Topic average updates

- **dbt snapshots SCD2** (Q1 active-row + default-meta-columns cluster) 4.2375/5 → (4.2375·5 + 5.000)/6 = 26.1875/6 = **4.3646/6** (+0.1271 — Q1's perfect 5.000 lifts the topic average; the iter536 column slip is closed).
- **SQL query best practices for OLAP** (Q2 approx_percentile + Q3 FILTER conditional-aggregation cluster) 4.5368/100 → (4.5368·100 + 4.625 + 4.625)/102 = 462.93/102 = **4.5385/102** (+0.0017 — both Q2 and Q3 marginally above topic avg).
- **Common analytical query patterns** (Q4 ORDER BY NULLS cluster — per established placement) 4.7126/13 → (4.7126·13 + 5.000)/14 = 66.2638/14 = **4.7331/14** (+0.0205 — Q4 above topic avg).

Federation NOT probed — **4.49944/310 row UNCHANGED** per iter472-537 directive.

---

## Iter538 PRIMARY FIX TARGETS

**No HIGH-priority fix needed this iter.** All four questions strong-pass.

LOW-priority polish targets:

1. **Q2 polish (LOW — approx_percentile accuracy parameter)**: r07 / approx_percentile canonical could surface the optional 4th accuracy parameter (e.g. `approx_percentile(x, percentage, accuracy)` where 0 < accuracy < 1). The responder's "no fixed error bound" is defensibly conservative, but mentioning the tunable accuracy gives the engineer a concrete knob. Doc anchor: github.com/trinodb/trino/issues/12276 (the accuracy parameter is real but not foregrounded on the aggregate-functions doc page).

2. **Q3 polish (LOW — SUM-vs-AVG label slip)**: the first example used `SUM(order_value)` but the surrounding text said "avg." Not load-bearing because the AVG example follows correctly. If the r07 FILTER canonical has the same SUM-labeled-as-avg pattern, fix the label to keep beginner copy-paste clean.

3. **Q1 / Q4 — NO fixes needed**. Both perfect 5.000.

## Iter538 probe targets

- **dbt snapshot meta-columns 3rd angle (LOW — verifies FIX A durability for the 2nd consecutive iter)**: e.g. "I see `dbt_is_deleted` in my snapshot — is that always there?" OR "I don't see `dbt_updated_at` — should I?"
- **approx_percentile accuracy-parameter 2nd angle (LOW — verifies LOW polish target if landed)**: "Can I tune the accuracy of approx_percentile?"
- **FILTER conditional-aggregation 2nd angle (LOW — well-bulletproofed)**.
- **ORDER BY NULLS 2nd angle (LOW — well-bulletproofed)**: e.g. "I want NULLs FIRST on a DESC sort — how?"
- **Federation stays UNPROBED** (LOW — row stays 4.49944/310).

---

## Doc quotes (verbatim verification)

- **dbt snapshot defaults** (docs.getdbt.com/reference/resource-configs/snapshot_meta_column_names): four defaults are `dbt_scd_id, dbt_updated_at, dbt_valid_from, dbt_valid_to`; `dbt_is_deleted` doc note: "Added when `hard_deletes='new_record'` is configured."
- **Trino ORDER BY NULLS default** (trino.io/docs/current/sql/select.html): "The default null ordering is `NULLS LAST`, regardless of the ordering direction."
- **Trino approx_percentile** (trino.io/docs/current/functions/aggregate.html): `approx_percentile(x, percentage)` + `approx_percentile(x, percentages)` array form confirmed; no `PERCENTILE_CONT` / `PERCENTILE_DISC` / `WITHIN GROUP` for percentiles in Trino.
- **Trino FILTER on aggregates** (trino.io/docs/current/functions/aggregate.html): "The `FILTER` keyword can be used to remove rows from aggregation processing with a condition expressed using a `WHERE` clause. ... This is ... supported for all aggregate functions."
