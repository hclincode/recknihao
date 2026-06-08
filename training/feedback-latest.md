# Judge Feedback — iter697

**Verdict: PASS (overall 4.65625, margin +1.15625 above 3.5 floor).**

## Per-Q sub-scores

| Q | Topic | Acc | Comp | Clar | Act | Q-avg |
|---|---|---|---|---|---|---|
| Q1 | approx_percentile sketch alg (FIX-A re-probe) | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | month-over-month revenue growth | 2.5 | 3 | 5 | 4 | 3.625 |
| Q3 | date-spine gap-filling (zero-activity days) | 5 | 5 | 5 | 5 | 5.00 |
| Q4 | Iceberg small-file compaction (ALTER TABLE EXECUTE optimize) | 5 | 5 | 5 | 5 | 5.00 |

**Per-Q avg cross-check: (5.00 + 3.625 + 5.00 + 5.00)/4 = 18.625/4 = 4.65625.**
Dim-avg cross-check: Acc (5+2.5+5+5)/4 = 4.375 / Comp (5+3+5+5)/4 = 4.50 / Clar (5+5+5+5)/4 = 5.00 / Act (5+4+5+5)/4 = 4.75 -> (4.375+4.50+5.00+4.75)/4 = **4.65625** — agrees.

**Governing label: PASS (4.65625 >= 3.5 by margin +1.15625; all four Qs above per-Q 3.5 floor; Q2 lowest at 3.625).**

---

## Q1 — approx_percentile sketch algorithm (FIX-A re-probe) — 5.00

**FIX-A APPROX_PERCENTILE/APPROX_DISTINCT SKETCH-ALGORITHM INOCULATION: CLOSED.**

Responder explicitly:
- Named the sketch as **T-Digest**, NOT HyperLogLog.
- Said Trino "doesn't publish a single fixed-percentage error figure" for approx_percentile.
- Pre-empted the iter696 conflation forms: "your teammate might have confused this with `approx_distinct(user_id)` which uses HyperLogLog and has documented ~2.3% standard error."
- Did NOT invent an `approx_percentile(x, p, accuracy)` overload (correct — Trino 467 has only four overloads; accuracy is a `qdigest_agg(x, w, accuracy)` param).
- Gave both scalar and array forms with GROUP BY page, both executable Trino 467.

VERIFIED against trino.io/docs/467/functions/aggregate.html (2026-06-08):
- approx_percentile has FOUR overloads (x,pct) / (x,pcts) / (x,w,pct) / (x,w,pcts); NO accuracy 3-arg overload.
- approx_distinct documents 2.3% default standard error.
- Docs do NOT explicitly name t-digest as approx_percentile's sketch, but the responder's attribution ("T-Digest, not HyperLogLog") matches the cross-resource consistency (r23, r05) and is consistent with the user-facing qdigest_agg family — no penalty.

The iter696 Q4 sketch-algorithm conflation defect is **CLOSED** on first re-probe — both the r07:587 mirror inoculation and the r07 Pattern C2 primary sketch-algorithm inoculation block worked. Mark FIX-A inoculation durable pending a second-angle re-probe in a later iter.

## Q2 — month-over-month revenue growth — 3.625 (SEMANTIC MISMATCH)

Responder gave a clean, executable, one-pass Trino 467 SQL:
- `SUM(amount) FILTER (WHERE month=current AND year=current)` vs `SUM(amount) FILTER (WHERE month=current AND year=current-1)`
- Correctly used FILTER (not WHERE) so both periods survive aggregation.
- Correct NULLIF(...,0) guard and x1.0 decimal cast.

**BUT this answers SAME-MONTH-YEAR-OVER-YEAR, NOT month-over-month.** The saas-engineer asked "this month vs LAST MONTH, up or down by what percent" — that means consecutive months (e.g., June 2026 vs May 2026), not June 2026 vs June 2025. The responder's SQL compares June-of-this-year vs June-of-last-year — that is YoY for the same month, a different metric entirely.

Cleaner canonical: `LAG(monthly_revenue) OVER (ORDER BY month)` on a monthly-pre-aggregated CTE — exactly one row per month, exactly one LAG to reach the immediately previous month. Alternative FILTER form: key on the actual previous calendar month, e.g., `FILTER (WHERE date_trunc('month', sale_date) = date_trunc('month', current_date) - INTERVAL '1' month)`.

Penalty breakdown:
- **Accuracy 2.5**: SQL is syntactically valid Trino 467 (`month()`, `year()`, `FILTER` all valid), but semantically answers the wrong question.
- **Completeness 3**: Misses the canonical LAG-on-monthly-CTE pattern entirely; doesn't address consecutive-month vs same-month-YoY at all.
- **Clarity 5**: Credit for the otherwise-clean one-pass explanation; FILTER vs WHERE rationale is good; NULLIF/x1.0 guards correctly explained.
- **Actionability 4**: Engineer could copy-paste and ship — but they'd ship the wrong metric. The FILTER technique is reusable; deduct one point for the wrong target.

## Q3 — date-spine gap-filling (zero-activity days) — 5.00

Docs-perfect. Verified against trino.io/docs/467/functions/array.html (sequence, UNNEST) and trino.io/docs/467/sql/select.html (CROSS JOIN, LEFT JOIN):
- `sequence(DATE '2026-01-01', DATE '2026-01-31', INTERVAL '1' DAY)` — valid DATE+INTERVAL form in Trino 467.
- `UNNEST(...) AS t(d)` — valid.
- `customers CROSS JOIN date_spine` produces every (customer, date) pair — the canonical dense-frame pattern.
- `LEFT JOIN actual_activity ... COALESCE(count, 0)` correctly fills zero rows.
- Predicate pushdown on `activity_timestamp >= DATE '2026-01-01' AND < DATE '2026-02-01'` is partition-friendly (no function on the column).

Range, sequence step, customers-from-DISTINCT, LEFT JOIN direction, COALESCE->0 — all four mechanically correct.

## Q4 — Iceberg small-file compaction without full rewrite/downtime — 5.00

VERIFIED against trino.io/docs/467/connector/iceberg.html (2026-06-08):
- `ALTER TABLE ... EXECUTE optimize(file_size_threshold => '256MB')` — correct Trino 467 form. Docs default is `'100MB'`; explicit `'256MB'`/`'128MB'` overrides are valid DataSize strings.
- `expire_snapshots(retention_threshold => '7d')` — correct param name and duration-string format; matches the default min-retention of 7d.
- `remove_orphan_files(retention_threshold => '7d')` — same.
- Note: `rollback_to_snapshot` is the CALL form in 467 (per memory entry reference_trino_rollback_snapshot_form.md); responder correctly did NOT use ALTER TABLE EXECUTE for rollback — only for optimize/expire/remove.

Operational claim "runs within existing partitions, does NOT rewrite files already above threshold, metadata-fast, parallel across workers, no table lock/downtime, old files readable until expire_snapshots a week later so time-travel still works" — all accurate. Maintenance cadence (optimize nightly, expire weekly, remove orphan weekly) matches best-practice guidance and won't violate the 7d min-retention default.

---

## Teacher feedback for iter698

**Closed this iter:**
- FIX-A approx_percentile/approx_distinct sketch-algorithm inoculation **CLOSED** on first re-probe. r07:587 mirror block + r07 Pattern C2 primary block + r23:2463 split glossary entries all worked — responder produced docs-perfect distinction with zero conflation. Hold these edits.

**New findable-but-missing gap (HIGH priority for iter698 — FIX-A2):**

**Q2 month-over-month semantic mismatch is a genuine findable gap.** The responder's FILTER form compared this-month-current-year vs this-month-PREVIOUS-year (= year-over-year for the same month), not vs the immediately previous calendar month. The cleaner canonical (LAG on a monthly-pre-aggregated CTE) is the standard month-over-month idiom and is not currently routed to from the "month over month" / "this month vs last month" keyword landing.

Recommended FIX-A2 inoculation:
1. Add a `month-over-month vs year-over-year` inoculation card in r07 (or r23) keyed on these phrases: `month over month`, `MoM`, `this month vs last month`, `consecutive months`, `previous month`, `prior month`, `month-over-month growth`.
2. Show the canonical: pre-aggregate to monthly grain CTE -> `LAG(monthly_revenue) OVER (ORDER BY month_start)` -> growth pct via `(curr - prev) / NULLIF(prev,0) * 100.0`.
3. Show an alternative date-truncated FILTER form keyed on `date_trunc('month', sale_date) = date_trunc('month', current_date) - INTERVAL '1' month` for the previous-month bucket.
4. **DO-NOT-WRITE block** (defanged with inline `-- WRONG: this is YoY for the same month, NOT MoM`): the `month(current_date) AND year(current_date)-1` form the responder emitted — to inoculate against the same conflation. Per memory entry feedback_defang_donotwrite_snippets.md, inline-mark each banned snippet WRONG on the same line and make the canonical the copy-attractive block.
5. Cross-link to r07 timezone-CAST-trap iter686 (already HELD) for the date arithmetic guardrails.

**Optional FIX-B (LOW priority):**

A second-angle re-probe of approx_percentile in iter698 to confirm 2-iter durability of the FIX-A inoculation before marking it long-term durable. Suggested probe shape: ask about histogram_quantile-style multi-percentile dashboards or "what's the error like for p99 vs p50" — anything that pulls the responder back to the accuracy / sketch-algorithm narrative.

**Holds for iter698 (DO NOT touch):**
- r22 federation guardrails (53-iter ZERO probe streak, 4.49944 vs 4.5 thin).
- iter697 r07:587 mirror + Pattern C2 primary FIX-A inoculation blocks (CLOSED on first re-probe).
- iter695 r23:1014-1071 QUALIFY inoculation card + r23:744 bridge (3-iter durability now).
- All iter534-696 locks (~260 locks across 17 resource files).

**DO NOT** bump training/state.json (orchestrator handles).
