# Iter689 Judge Feedback

**Scope**: 4 Q probe — Q1 running-cumulative-percent FIX-A RE-PROBE (Pareto), Q2 median-per-category, Q3 Iceberg ADD COLUMN nullable, Q4 LEAD time-to-next.

**Dialect verification**: WebSearch/WebFetch against trino.io/docs/467 (window functions, aggregate functions, datetime, Iceberg connector) and Apache Iceberg docs.

---

## Q1 — Running cumulative % of total revenue (Pareto) — FIX-A RE-PROBE

**Answer recap**: CTE pre-aggregates per-product revenue; outer SELECT runs `100.0 * SUM(product_revenue) OVER (ORDER BY product_revenue DESC ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) / SUM(product_revenue) OVER ()` with ROUND(_, 1); explicitly notes single `100.0 *` (never trailing `* 100`), last row equals exactly 100.0, and to find top-N-make-80% wrap in outer query with `WHERE cumulative_pct_of_total <= 80.0`.

**Verification vs trino.io/docs/467**:
- `SUM(x) OVER (ORDER BY ... ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` — valid running total frame. CONFIRMED.
- `SUM(x) OVER ()` empty window — valid grand-total. CONFIRMED.
- Single leading `100.0 *` — forces decimal division AND converts 0..1 ratio to 0..100 percent in one operation. Last row of running ÷ grand-total = 1.0 → ×100 = exactly 100.0. CONFIRMED.
- No trailing `* 100` — the iter688 double-multiply bug (final row = 10000.0) is NOT present. CLEAN.
- Window result in WHERE requires CTE/subquery wrap — responder correctly says "wrap in an outer query". CONFIRMED.
- `ORDER BY product_revenue DESC` in window for Pareto walk — correct shape (steeply climbing cumulative).

**Scores**: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 = **5.0**

**FIX-A verdict for Q1**: **CLOSED.** The iter688 double-100 fab (`100.0 * x / y * 100`) is GONE. The responder now writes EXACTLY one ×100 via the single leading `100.0 *` literal, correctly explains the dual-role of that literal (decimal-division-force + percent-conversion), explicitly inoculates against the trailing `* 100`, and reaches exactly 100.0 on the last row. The new Pattern A3 fusion card at r07 (between Pattern A2 and Pattern B) plus the DO-NOT-WRITE row for `100.0 * x / y * 100` evidently landed cleanly in the responder's keyword path.

---

## Q2 — Median order amount per category

**Answer recap**: `SELECT category, approx_percentile(amount, 0.5) AS median_amount FROM orders GROUP BY category;` Notes: no MEDIAN() in Trino, 0.5 = median, T-Digest, multi-percentile ARRAY[0.5, 0.95, 0.99] in one pass.

**Verification vs trino.io/docs/467 aggregate functions**:
- `approx_percentile(x, percentage)` with 0.5 = median. CONFIRMED.
- No MEDIAN function in Trino 467. CONFIRMED.
- ARRAY of percentages signature `approx_percentile(x, percentages) → array<...>` valid one-pass multi-percentile. CONFIRMED.
- GROUP BY category with aggregate — standard. Valid.

**Scores**: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 = **5.0**

---

## Q3 — Iceberg ADD COLUMN nullable, no rewrite

**Answer recap**: `ALTER TABLE iceberg.analytics.customers ADD COLUMN loyalty_tier VARCHAR;` — metadata-only, fast, no rewrite, old Parquet returns NULL, columns always nullable, can't add NOT NULL in one step, use dbt not_null test or backfill+SET NOT NULL.

**Verification (trino.io ALTER TABLE + Iceberg DDL docs + Trino issues 13587/20315)**:
- ADD COLUMN on Iceberg is metadata-only (one of Iceberg's five metadata-only schema modifications: Add, Remove, Rename, Widen, Reorder). CONFIRMED.
- New column nullable by default; existing rows return NULL (no rewrite). CONFIRMED.
- Cannot SET NOT NULL post-add because Iceberg doesn't know whether existing NULL rows exist; cannot add NOT NULL with default in one step on Trino — known issue. CONFIRMED.
- Three-part name `iceberg.analytics.customers` matches the prod stack (Trino 467 + Iceberg connector + Hive Metastore on MinIO). CONFIRMED fit.

**Scores**: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 = **5.0**

---

## Q4 — LEAD time-to-next ticket per customer

**Answer recap**: `LEAD(created_at) OVER (PARTITION BY customer_id ORDER BY created_at)` + `date_diff('hour', created_at, LEAD(...))`; LEAD returns NULL for last row per customer; explicitly bans `created_at - LEAD(...)` (no ts-minus-ts operator); says compare to plain number, not INTERVAL.

**Verification vs trino.io/docs/467 (window + datetime)**:
- `lead(x)` returns the value at offset rows after current; if offset refers to a row outside the partition, default_value (or NULL) is returned. CONFIRMED — last row per customer = NULL.
- PARTITION BY customer_id ORDER BY created_at — standard LEAD shape. CONFIRMED.
- `date_diff('hour', ts1, ts2)` returns ts2 - ts1 in hours. CONFIRMED.
- timestamp - timestamp NOT a valid operator (subtraction defined only with INTERVAL operand). CONFIRMED — inoculation correct.

**Scores**: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 = **5.0**

---

## Overall

| Q | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|
| Q1 (Pareto cumulative %) | 5 | 5 | 5 | 5 | 5.0 |
| Q2 (median per category) | 5 | 5 | 5 | 5 | 5.0 |
| Q3 (Iceberg ADD COLUMN) | 5 | 5 | 5 | 5 | 5.0 |
| Q4 (LEAD time-to-next) | 5 | 5 | 5 | 5 | 5.0 |

**Overall average: 5.0 / 5.0 — PASS** (threshold 3.5).

**FIX-A (Q1 running-cumulative-percent double-100) — CLOSED.** The iter688 `100.0 * x / y * 100` double-multiply fab is fully eliminated. Responder writes EXACTLY one ×100 via the leading decimal literal, explicitly states "never add trailing * 100", reaches exactly 100.0 on the last row, and correctly handles the Pareto top-N-makes-80% follow-up via outer-query WHERE wrap. The new Pattern A3 fusion card landed cleanly via the responder's keyword path.

**Weak answers flagged**: NONE. All four answers are bulletproof, dialect-clean, and prod-stack-correct.

---

## Teacher feedback for iter690

**Recommendation: DEFAULT NO-OP / durability-breadth.**

The targeted iter689 FIX-A surgical insertion (Pattern A3 Pareto/running-cumulative-percent fusion card) is empirically confirmed closed. All four answers passed at 5.0 with verified docs-truth alignment. No regressions detected on Q2/Q3/Q4 baselines.

Suggested iter690 posture:
- **No code changes** to resources/ — the iter689 insertion is doing its job, and adjacent locks (share-of-grand-total r07:1234, Pattern A r07:1700, Pattern A2 r07:1868, iter667 BROADEN r07:1829) all held verbatim.
- **Durability-breadth probing**: pick 4 questions across different topic axes from the rubric that haven't been probed in the last ~30 iters (federation, CBO/ANALYZE, dbt incremental edge cases, OPA/JWT auth conceptual answer, Iceberg compaction/expire_snapshots, MoR vs CoW trade-offs, time-travel via VERSION AS OF, partition evolution, MERGE INTO, sessionization) — confirm none of those have silently regressed.
- If iter690 also passes with no edits, consider this terminal-stable; otherwise teacher reacts with smallest-possible surgical fix on whichever single topic dipped.
- resources/22 HARD LOCK preserved — do not touch.

No teacher action required unless iter690 surfaces a regression.
