# Judge Feedback — iter695

**Phase**: extended | **Iteration**: 695 | **Verdict**: PASS (overall avg 5.00 >= 3.5)

The overall average is **5.00 / 5.0**. All 16 sub-scores landed at 5. The QUALIFY FIX-A re-probe (Q1) **CLOSED** the iter694 regression.

---

## Per-question scores

### Q1 — Latest row per device (QUALIFY FIX-A re-probe)
| Dimension | Score | Notes |
|---|---|---|
| Accuracy | 5 | QUALIFY explicitly flagged as parse error in Trino 467. Option A `max_by(status, reading_time)` + `MAX(reading_time) GROUP BY device_id` is exactly the docs-verified shape (trino.io/docs/467/functions/aggregate.html confirms `max_by(x, y)` returns x at the max of y). Option B uses the ROW_NUMBER subquery with outer `WHERE rn = 1` and correctly states window functions cannot go in WHERE (confirmed against trino.io/docs/467/sql/select.html — WINDOW clause is post-WHERE; QUALIFY absent from clause synopsis). |
| Completeness | 5 | Both canonical Trino forms given with use-case guidance (Option A = aggregate-only / specific cols, Option B = need all cols). `NULLS LAST` ordering specified. Snowflake QUALIFY explicitly contrasted. |
| Clarity | 5 | Compact, no jargon left unexplained. Each option labeled with when to pick it. |
| Actionability | 5 | Engineer can copy-paste either form against `your_schema.device_readings` and ship. Resource pointer (r23 §3.1G) given. |

**Q1 avg: 5.00**

**QUALIFY FIX-A status: CLOSED.** The iter694 Q2 regression (responder emitted the QUALIFY+ROW_NUMBER one-liner) did NOT reappear in iter695 Q1. Responder routed to the new §3.1G keyword-anchored card and produced the correct non-QUALIFY forms — both Option A (max_by aggregate) and Option B (ROW_NUMBER subquery + outer WHERE rn=1) — and explicitly named QUALIFY as a parse error. The leading canonical + defanged DO-NOT-COPY card landed cleanly. Inline same-line `-- WRONG: DO NOT COPY` comments did NOT bleed into the response.

### Q2 — Conditional aggregation / manual pivot
| Dimension | Score | Notes |
|---|---|---|
| Accuracy | 5 | Correctly notes Trino has no PIVOT keyword. Both `SUM(CASE WHEN ... THEN 1 ELSE 0 END)` and `COUNT(*) FILTER (WHERE ...)` are valid Trino 467 (FILTER clause confirmed at trino.io/docs/467/functions/aggregate.html — "supported for all aggregate functions"). Daily grouping via `DATE_TRUNC('day', created_at)` is correct. |
| Completeness | 5 | Both equivalent shapes given. Notes they produce the same plan. Daily roll-up matches the manager's "single summary row per day" requirement. ORDER BY day for stable output. |
| Clarity | 5 | Aliases match the three statuses (open_count / in_progress_count / closed_count). Order of clauses correct. |
| Actionability | 5 | Drop-in query with schema placeholder. Resource pointer (r07 wide-pivot variant). |

**Q2 avg: 5.00**

### Q3 — dbt incremental on Iceberg
| Dimension | Score | Notes |
|---|---|---|
| Accuracy | 5 | `materialized='incremental'`, `incremental_strategy='merge'`, `unique_key='event_id'` all correct for dbt-trino + Iceberg. **`partitioning` NOT `partitioned_by`** correctly named as the Iceberg connector property (verified at trino.io/docs/467/connector/iceberg.html — `partitioning = ARRAY[...]`). `is_incremental()` vs `execute` distinction is correct (execute is True at compile/run for ALL builds; is_incremental() is False on first run AND on --full-refresh — exactly right). Trino MERGE multi-match gotcha and ROW_NUMBER pre-dedup recommendation are accurate. |
| Completeness | 5 | Config block + model body + three gotchas. Covers `on_schema_change`, properties dict format (with embedded quotes around 'PARQUET'), and the dedup workaround. |
| Clarity | 5 | Each gotcha numbered and explained. is_incremental vs execute trap explicitly called out. |
| Actionability | 5 | Engineer can drop this in as the model SQL. Resource pointer (r28 leading canonical). |

**Q3 avg: 5.00**

### Q4 — NULL handling in AVG / COUNT
| Dimension | Score | Notes |
|---|---|---|
| Accuracy | 5 | "All aggregates except COUNT(*) skip NULLs" — verified at trino.io/docs/467/functions/aggregate.html ("all of these aggregate functions ignore null values"). AVG excludes NULL from numerator AND denominator → true average of non-NULL values — correct. `COUNT(rating)` = non-null count, `COUNT(*)` = total rows — correct. All-NULL edge case (AVG→NULL, COUNT(rating)→0, COUNT(*)→1) is exactly right. |
| Completeness | 5 | Directly answers both halves: (a) whether AVG is misleading (no — but reviews-with-rating count needed to interpret it), (b) the side-by-side query. Bonus: includes both COUNT(rating) and the equivalent SUM(CASE WHEN rating IS NOT NULL THEN 1 ELSE 0 END) so the engineer sees the alternates. |
| Clarity | 5 | Each column's meaning called out in plain language. Edge case spelled out explicitly. |
| Actionability | 5 | Single query the engineer can ship against `your_schema.product_reviews`. Resource pointer (r23 §3.1D + ANSI). |

**Q4 avg: 5.00**

---

## Overall

| Q | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|
| Q1 | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | 5 | 5 | 5 | 5 | 5.00 |
| Q3 | 5 | 5 | 5 | 5 | 5.00 |
| Q4 | 5 | 5 | 5 | 5 | 5.00 |

**16 sub-scores: all 5.** Overall average: **5.00 / 5.0**. **PASS** (threshold 3.5).

---

## QUALIFY FIX-A verdict

**CLOSED.** iter695 fixed the iter694 Q2 regression. The new §3.1G QUALIFY inoculation card and the §3.1D bridge cross-ref successfully routed the responder to the docs-correct Trino 467 forms for "latest row per device":
1. Aggregate form: `max_by(x, sort_key)` + `MAX(sort_key)` GROUP BY entity — no window, single pass.
2. Whole-row form: ROW_NUMBER subquery + outer `WHERE rn = 1`.

Responder explicitly named QUALIFY as a parse error and did NOT emit it anywhere in Q1 (or any other answer). The defanged DO-NOT-COPY snippets did not bleed into the response — iter694's "weak responder copies the negative example" backfire mode did NOT reoccur this iter. Inline same-line `-- WRONG: DO NOT COPY` comments inside fenced sql blocks worked as designed.

## New findable-but-missing gaps for next iteration

None visible from this iter's 4 answers. All four questions hit on-pin docs-correct material with confident keyword routing:
- Q1 leveraged the new iter695 FIX-A card — clean landing.
- Q2 hit the existing manual-pivot canonical (SUM(CASE WHEN) and FILTER both surfaced) — no gap.
- Q3 hit r28 leading canonical with all three gotchas (partitioning vs partitioned_by, is_incremental vs execute, MERGE multi-match) — no gap.
- Q4 hit r23 §3.1D + ANSI aggregate behavior — no gap. AVG-with-all-NULL edge case correctly returned NULL (not 0) — exactly the trap that catches new engineers.

## Recommendation to teacher

- **HOLD** all iter695 edits. Do NOT touch resources/22 (federation lock preserved through 247+ iterations). Do NOT re-edit the new §3.1G QUALIFY inoculation card or the §3.1D bridge — they worked.
- The iter694 defang lesson (inline same-line `-- WRONG: DO NOT COPY` comments inside fenced code blocks) is confirmed effective and should remain the standard form for all banned-snippet inoculation cards going forward.

## Probe suggestion for next iter

Re-probe a Q2-shape variant that asks for FIRST AND LAST in one row (different sort key, e.g., "first and last order amount per customer") to confirm the §3.1D iter638/656 PIN still routes correctly now that the §3.1D area has the new QUALIFY bridge inserted. Also probe a top-N (N>1, not N=1) case to confirm Option B's "change rn=1 to rn<=3" guidance is findable. These two angles will harden the FIX-A card against future regressions before stamping it as long-term solid.
