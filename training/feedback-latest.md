# Judge Feedback — iter958

**Phase**: extended (final_iterations_remaining=0)
**Mode**: DEFAULT NO-OP breadth sweep per iter957 recommendation; teacher made ZERO resource edits.
**Verdict**: **4.109375 PASS** (margin +0.609 over 3.5 threshold; OVERALL AVERAGE governs, no per-Q veto).

Per-Q scores: Q1 4.75 / Q2 2.50 / Q3 4.8125 / Q4 4.375 = 16.4375 / 4 = 4.109375.

Federation NOT probed (4.49944/310 row UNCHANGED per directive).
All dialect verified vs trino.io/docs/467 (functions/aggregate.html, functions/window.html, sql/select.html, connector/iceberg.html) + WebSearch 2026-06-10 (ALTER TABLE EXECUTE optimize = Trino-native compaction; rewrite_data_files = Spark Iceberg procedure CONFIRMED) — NOT against resources/; iter882 verify-BOTH-directions discipline.

---

## ★ ★ ★ Q2 VERDICT — RESPONDER SLIP ON MANY-SIDE-vs-ONE-SIDE FAN-OUT RULE ★ ★ ★

**The directive's critical check is confirmed.** Trace on O1 W1 [qty 2,3,5] + O2 W1 [qty 4]: after `orders JOIN order_line_items` on order_id, O1 produces 3 rows (W1, qty 2/3/5), O2 produces 1 row (W1, qty 4). `SUM(li.quantity) GROUP BY o.warehouse_id` = 2+3+5+4 = **14 = the correct total quantity for W1**. The join fan-out replicates the ORDER row (one-side) but each LINE-ITEM row (many-side) contributes its own quantity exactly once. Summing a MANY-side attribute after the join is CORRECT; over-counting from fan-out happens only when summing a ONE-side attribute (e.g., orders.order_total replicated per line item).

**The responder's flow:**
1. Shows the direct `SUM(li.quantity)` query.
2. **Incorrectly marks it "WRONG — overcounts because of join inflation"** — this is a FALSE CLAIM.
3. Offers an unnecessary pre-aggregate CTE (sum per order_id first, then per warehouse) as "RIGHT".
4. Re-shows the original query, says "Wait — this is the same query I marked as wrong above," and self-corrects: "the sum IS correct because each line item contributes its quantity; the issue only arises if you sum order-LEVEL attributes (like order total) which get replicated per line item."
5. Adds the rule-of-thumb about checking cardinality.

**Disposition**:
- The FINAL conclusion is CORRECT (many-side SUM is fine; fan-out over-counts only ONE-side attributes).
- The pre-aggregate CTE is a valid-if-unnecessary alternative.
- BUT a reader is misled BEFORE the self-correction; the answer is muddled and self-contradictory.
- The user's complaint ("different row count than expected" after the join) is a row-count observation (correct — fan-out replicates rows), which the responder does eventually clarify, but the WRONG-mark on a correct aggregate query damages trust and learning.

**Scope**: RESPONDER SLIP on the many-side-vs-one-side fan-out rule. The user's question is exactly the place this rule should land cleanly. Not a clean "resource defect" verdict — see findability check below.

**Findability check for the many-side-vs-one-side rule**:
- r23 (sql-best-practices-olap.md) covers JOIN cardinality and fan-out.
- The PINNED DIALECT FACT from the directive ("JOIN fan-out over-counts ONLY when summing a replicated ONE-side attribute; summing a MANY-side attribute is correct") is the precise teaching needed.
- Q2's "different row count than expected after the join" + asking for SUM(quantity) GROUP BY warehouse is a TEXTBOOK trigger for that rule.
- The responder reached the correct rule mid-answer, demonstrating the resource is FINDABLE — but only after an incorrect first pass. This points to **responder synthesis slip**, not a routing failure: the keyword anchors took (eventually), but Haiku produced a false initial diagnosis ("any JOIN row replication → SUM over-counts") before retrieving and applying the more precise rule.

**Slip vs gap?** Mostly slip with a borderline findability nuance: if r23's fan-out card LEADS with a copy-attractive CORRECT-then-WRONG block making the many-side-vs-one-side distinction explicit *at the top* (rather than embedded in prose), the responder is less likely to commit to the false initial mark. **Not warranting an immediate edit** per re-probe-don't-churn doctrine — re-probe on 1-2 more surfaces before escalating.

---

## ★ Q1 — 4.75 CLEAN

`CASE WHEN year(current_date) - year(birth_date) BETWEEN 18 AND 24 THEN '18-24' ... ELSE 'unknown' END AS age_group, COUNT(*) FROM users WHERE birth_date IS NOT NULL GROUP BY (same CASE expression)`. Verified valid Trino 467:
- `year(date)` returns year-field per functions/datetime.html.
- Per-bucket count shape: GROUP BY the CASE expression ONLY (no unique key) + COUNT(*) returns rows per bucket — CORRECT.
- CASE expression repeated in GROUP BY, NOT the alias — CORRECT per sql/select.html (Trino does NOT allow alias in GROUP BY).
- WHERE birth_date IS NOT NULL runs before GROUP BY — CORRECT.
- CTE variant offered — valid alternative.

**Year-difference vs precise age**: `year(current_date) - year(birth_date)` is a rough age (ignores whether the birthday has passed this year — a person born 1995-12-31 evaluated on 2026-01-01 shows as 31 not 30). This is the COMMON SIMPLIFICATION for bracket dashboards (precise age requires birthday-adjusted calc or `date_diff('year', birth_date, current_date)` which Trino computes as a year-field difference too). Acceptable for a bracket dashboard; minor knock for not flagging the approximation. Acc 4.75 / Comp 4.75 / Clar 4.75 / Act 4.75.

---

## ★ Q2 — 2.50 SLIP

(See verdict section above.) Acc 2.5 (false initial WRONG-mark on a correct query, self-corrected) / Comp 3.0 (final conclusion correct + pre-aggregate CTE valid alternative + rule-of-thumb included) / Clar 2.0 (self-contradictory; reader misled before the correction) / Act 2.5 (final guidance is actionable but the path to it is messy; reader risks taking away "always pre-aggregate" instead of the precise many-vs-one-side rule).

---

## ★ Q3 — 4.8125 CLEAN

`WITH account_balances AS (SELECT account_id, ..., SUM(CASE WHEN entry_type='credit' THEN amount ELSE -amount END) OVER (PARTITION BY account_id ORDER BY created_at ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_balance FROM ledger_entries) SELECT DISTINCT account_id FROM account_balances WHERE running_balance < 0`.

Verified valid Trino 467:
- Signed running SUM via CASE (credit +amount / debit -amount) — correct.
- `SUM() OVER (PARTITION BY ... ORDER BY ... ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` = canonical running-total window per functions/window.html.
- WHERE on the CTE-materialized `running_balance` runs after the window (the window already computed inside the CTE; the outer WHERE filters the materialized rows) — CORRECT, no WHERE-before-window trap.
- SELECT DISTINCT account_id returns each flagged account once even when multiple rows go negative — correct for "ever went below zero".
- NOT a gaps-and-islands pattern; no filter-then-count always-zero trap (signed sum keeps all rows; window captures full running balance; any-row-<0 detection is straightforward).
- Window-fn-not-app-code note adds appropriate framing.

Acc 5.0 / Comp 4.75 (could optionally mention adding `, entry_id` to ORDER BY as a deterministic tie-breaker for same-instant ledger entries, but not required) / Clar 4.75 / Act 4.75.

---

## ★ Q4 — 4.375 MOSTLY CLEAN (minor completeness)

`SHOW CREATE TABLE` to inspect partitioning — valid 467. Partition-aware WHERE (product_id=42 AND order_date >= current_date - INTERVAL '90' DAY) reduces scan via partition pruning — sound general advice. `ALTER TABLE ... SET PROPERTIES partitioning=ARRAY['day(order_date)']` valid 467 Iceberg DDL; responder correctly flags it affects **new writes only** (the iter925 partition-evolution semantics pin holds). `CALL iceberg.system.rewrite_data_files(...)` correctly attributed to a **Spark SQL session, not Trino** — verified vs trino.io/docs/current/connector/iceberg.html: Trino's Iceberg connector does NOT expose `rewrite_data_files`; Trino-native compaction is `ALTER TABLE <t> EXECUTE optimize`.

**Minor completeness gaps**:
- Should ideally have offered Trino-native `ALTER TABLE <t> EXECUTE optimize` as the in-stack-friendly compaction option (the production stack runs Trino 467 + Spark via Iceberg 1.5.2 ingest; both available, but Trino-native is the lower-friction choice for ad-hoc compaction). Currently the answer routes the user to a Spark session for old-data rewrites, which is workable but adds a context switch.
- For a `product_id=42` lookup specifically, bucketing or sorting by product_id (or per-file min/max stats / per-file column-level skipping) helps the predicate directly. Date-partition-pruning is good general advice but tangential to a product-id point lookup if `order_date` is unfiltered or coarsely filtered.
- Materialized table via dbt — fair suggestion for a hot query.

Acc 4.5 / Comp 4.0 / Clar 4.5 / Act 4.5. No PARTITIONED BY footgun; no bucket(N, col) Spark-order footgun; clean 467 DDL throughout.

---

## SCOPE SUMMARY

- **Q1**: Clean per-bucket count via CASE bucketing; rough-age year-diff acceptable for bracket dashboard. NO defect.
- **Q2**: RESPONDER SLIP on many-side-vs-one-side fan-out rule. False initial WRONG-mark on a CORRECT aggregate query; self-corrects mid-answer with the correct rule. Final conclusion is right. Damages mid-answer trust but final guidance lands. Borderline findability nuance: r23 fan-out card may benefit from a copy-attractive CORRECT-vs-WRONG block making many-side-vs-one-side distinction TOP-OF-CARD — but NO immediate edit warranted per re-probe-don't-churn.
- **Q3**: Clean running-balance window. NOT a gaps-and-islands trap. Correct any-row-<0 detection. NO defect.
- **Q4**: Mostly clean lakehouse-perf playbook. Minor completeness on Trino-native `ALTER TABLE EXECUTE optimize` (responder routed to Spark for compaction — workable, not wrong). NO dialect error; correct attribution of `rewrite_data_files` to Spark.

**Overall pattern**: 3 of 4 questions clean (≥4.375); Q2 is the soft spot — a single-question responder slip muddling a question whose correct rule IS taught in r23. Margin +0.609 above PASS threshold remains comfortable.

---

## iter959 RECOMMENDATION = DEFAULT NO-OP + optional LIGHT FIX-A only if many-side-vs-one-side fan-out slip recurs on different surface in next 2 sweeps

**Reasoning**:
1. iter958 was a NO-OP DEFAULT breadth sweep and 4.109 PASS confirms breadth pivot still working; margin +0.609 above threshold.
2. Q2 slip is a single-instance responder synthesis miss; the responder DID retrieve the correct rule mid-answer (demonstrating r23 fan-out content is findable on this surface). Adding a card right now risks pulling adjacent JOIN-cardinality questions (e.g., "SUM(order_total) with line-item join — same total appears in each row, is that wrong?" — that one IS over-counted) toward the wrong canonical, per `feedback_new_card_over_attracts_adjacent.md`.
3. Q1/Q3 clean; Q4 has only minor Trino-native-compaction completeness — not warranting edits.
4. NO federation probe per directive (4.49944/310 row hard-locked).

**Optional LIGHT FIX-A (only if Q2-style fan-out slip recurs on a different surface in next 2 sweeps)**:
- In r23 fan-out / JOIN-cardinality section, lead with a copy-attractive CORRECT-vs-WRONG block:
  - **CORRECT**: "Summing a many-side attribute (line-item quantity) after a one-to-many JOIN — `SUM(li.quantity) GROUP BY o.warehouse_id` — is NOT over-counted; each line-item row contributes its own value exactly once."
  - **WRONG (DO NOT COPY)**: "Summing a one-side attribute (order_total) after the same JOIN — `SUM(o.order_total) GROUP BY o.warehouse_id` — IS over-counted because the order row replicates once per line item; pre-aggregate per order_id first."
  - Plus a WHICH-X router: "Which side of the join produces the column you're summing? Many-side (per-row attribute): SUM is fine. One-side (replicated per join row): pre-aggregate or DISTINCT-anchor first."
- Keep BRIEF; no isolated DO-NOT-WRITE snippet blocks per `feedback_defang_donotwrite_snippets.md`.

**Next-sweep probes**:
- A different many-side-vs-one-side fan-out surface (e.g., "SUM(o.order_total) on orders × line_items — totals look inflated" — should land "yes, one-side attribute IS over-counted, pre-aggregate") to test whether the rule is teachable in both directions.
- Window-frame BETWEEN variants (`BETWEEN N PRECEDING AND N FOLLOWING`).
- GROUPING SETS / ROLLUP / CUBE.
- Lateral JOIN UNNEST.
- Trino-native `ALTER TABLE EXECUTE optimize` vs Spark `rewrite_data_files` direct probe — does the responder LEAD with Trino-native compaction when asked "how do I compact old data in Iceberg"?
- One IS DISTINCT FROM null-safe-inequality angle (recurring per iter957 nuance check).
- Do NOT re-probe gaps-and-islands streak-construction yet.

**DO NOT TOUCH**:
- r23 fan-out card (defer to recurrence-driven LIGHT FIX-A).
- r07 L3226-3263 strengthened B-Streak defang (3 iters old, holding).
- r07 L37 HAVING-perf reword.
- r07 L1624 anti-nesting.
- r07 NESTED_WINDOW WRONG #1+#2 / two-GROUP-BY WRONG #2.
- r23 §3.1G argmax / COUNT(DISTINCT) canonical / HAVING-vs-WHERE / QUALIFY-not-Trino / regexp_like card / NULLS-LAST default / geometric/harmonic mean cards.
- r09 partition DDL strings + bucket(col,N) column-first.
- r28 DATE-literal + date_trunc-to-range nuance.
- r13 json_exists strict path.
- r22 §13.x federation (all rows hard-locked).
- Percentile cards / INTERVAL qualifier cards / format_datetime-vs-to_char card / PARTITIONED-BY guidance / price-suffix canonical / MAX_BY-nested defang.

---

## PINS REINFORCED

- **JOIN fan-out: many-side attribute (line-item quantity) SUM after one-to-many JOIN is NOT over-counted (each many-side row contributes its value exactly once); one-side attribute (order_total) SUM IS over-counted (the one-side row replicates per many-side row, value is counted multiple times). Pre-aggregate (CTE/subquery on order_id first) is required ONLY when summing one-side attributes; for many-side attributes, the direct JOIN+GROUP BY is correct.**
- **Per-bucket count via CASE bucketing: `CASE WHEN ... THEN 'bucket-label' ... END AS bucket, COUNT(*) FROM t WHERE ... GROUP BY (same CASE expression)` — GROUP BY repeats the CASE expression (NOT the alias) per sql/select.html.**
- **`year(date)` returns year-field per functions/datetime.html; year-difference (`year(a)-year(b)`) is a rough age (ignores whether the birthday has passed this year) — acceptable for bracket dashboards.**
- **Running total: `SUM() OVER (PARTITION BY ... ORDER BY ... ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` per functions/window.html; signed sum via `CASE WHEN type='credit' THEN amount ELSE -amount END`.**
- **Window functions run after WHERE per functions/window.html; WHERE on a CTE-materialized window-output column filters after the window — no filter-before-window trap when the window is computed inside the CTE.**
- **Trino-native Iceberg compaction = `ALTER TABLE <t> EXECUTE optimize` per connector/iceberg.html; `rewrite_data_files` is a Spark Iceberg procedure (not exposed by Trino's Iceberg connector).**
- **`ALTER TABLE <t> SET PROPERTIES partitioning=ARRAY['day(order_date)']` valid 467 Iceberg DDL — affects NEW WRITES ONLY (partition evolution semantics).**
- **Partition pruning via bare-column WHERE (no function wrapper on partition column unless the unwrap rule applies) per `reference_trino_unwrap_temporal_predicates.md`.**
- **`bucket(col, N)` column-first in Trino Iceberg (NOT Spark's `bucket(N, col)`) per `reference_trino_bucket_arg_order.md`.**
- **Default NULLS LAST in 467 per `reference_trino_null_ordering_default.md`.**
- **SELECT DISTINCT valid for "any row matched" deduplication.**

PRESERVE full iter534-957 pin inventory; NO federation edits, NO percentile-card edits, NO PARTITIONED-BY defang card, NO INTERVAL-qualifier edits, NO HAVING-perf defang card, NO price-suffix canonical card, NO MAX_BY-nested defang card, NO B-Streak defang edits, NO r23 fan-out card edits (defer to recurrence-driven LIGHT FIX-A).

PIN 467. DO NOT bump training/state.json (already 958; passed=true preserved; overall 4.109 PASS holds; final_iterations_remaining 0).
