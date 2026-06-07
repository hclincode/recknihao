# Iter667 Judge Feedback

## Verdict: PASS — overall avg 4.5625

| Question | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|
| Q1 (Iceberg optimize + DataSize)   | 5 | 5 | 5 | 5 | 5.00 |
| Q2 (per-DAY running total)         | 4 | 4 | 4 | 5 | 4.25 |
| Q3 (time-travel + rollback)        | 5 | 5 | 5 | 5 | 5.00 |
| Q4 (partition evolution)           | 4 | 4 | 4 | 4 | 4.00 |
| **OVERALL**                        | **4.50** | **4.50** | **4.50** | **4.75** | **4.5625** |

PASS THRESHOLD (3.5) cleared with healthy margin.

---

## Per-question detail

### Q1 — Iceberg compact to ~256MB files (DataSize FIX-A1 re-probe) — 5.00

Responder gave verbatim:
```
ALTER TABLE iceberg.analytics.events EXECUTE optimize(file_size_threshold => '256MB');
ALTER TABLE iceberg.analytics.events EXECUTE expire_snapshots(retention_threshold => '7d');
```

**Docs verification (trino.io/docs/467/connector/iceberg.html):**
- `ALTER TABLE test_table EXECUTE optimize(file_size_threshold => '128MB')` — verbatim docs example. DataSize-typed unit-suffixed string. Default `100MB`.
- `ALTER TABLE test_table EXECUTE expire_snapshots(retention_threshold => '7d')` — verbatim docs example.

Responder used `'256MB'` (unit-suffixed DataSize string), explained `file_size_threshold` semantics, and mentioned `'128MB'` / `'512MB'` alternatives. NO bare-bytes form (`'134217728'` or bare integer) anywhere.

**DataSize FIX-A1 verdict: CLOSED.** Iter666 surface defect (bare-bytes risk) does not regress. Responder is on-target with unit-suffixed shape, explains the parameter, and adds correct expire_snapshots cleanup.

### Q2 — Per-DAY running total with many orders/day (ROWS-vs-RANGE FIX-A2 re-probe) — 4.25

Responder gave:
```sql
SELECT day, SUM(daily_revenue) OVER (ORDER BY day RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative_revenue_through_day
FROM (SELECT DATE(occurred_at) AS day, SUM(revenue) AS daily_revenue
      FROM orders WHERE occurred_at >= DATE '2026-01-01'
      GROUP BY DATE(occurred_at)) daily_aggregates
ORDER BY day;
```

**Docs verification (trino.io/docs/467/sql/select.html):**
- Default frame IS `RANGE UNBOUNDED PRECEDING` = `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`. Responder is correct that this is the default.
- RANGE lumps peers (tied ORDER BY values share one cumulative value). After `GROUP BY DATE(occurred_at)` each day is unique, so peer-group of size 1 = no lumping = ROWS-vs-RANGE produce identical results here.

**Structural FIX-A2 verdict: CLOSED.** The KEY FIX is present — pre-aggregate to one-row-per-day in a subquery FIRST, THEN run the window. That's exactly the iter666-flagged surface ("weird duplicate-looking numbers" caused by running the window directly over row-grain orders).

**Muddled-note flag:** the responder's explanatory aside — *"if multiple orders somehow tied on the same day, they all see the same cumulative value — deterministic semantics"* — is slightly confused, because the GROUP BY already collapsed every same-day group to a single row. There can be no same-day ties after the subquery. This does NOT break the result (SQL is correct, output is one row per day with cumulative through-day revenue) but it weakens the teaching: a junior reader could misread it as "RANGE is needed for safety" when in fact ROWS gives exactly the same answer here. The canonical shape (per r07:1164 iter667 broaden) is `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` after a one-row-per-day pre-aggregate — more intent-revealing because once each day is unique the positional vs peer-group distinction is moot, but ROWS makes the absence of peer-lumping explicit.

Per the run-prompt instruction: do not over-penalize since the SQL is correct. Knocked 1 point off Accuracy/Completeness/Clarity (still 4 each); Actionability stays 5 (engineer can paste and run).

### Q3 — Time-travel + rollback — 5.00

Responder gave:
- Step A: `SELECT snapshot_id, committed_at, operation FROM orders$snapshots WHERE committed_at >= current_timestamp - INTERVAL '3' DAY ORDER BY committed_at DESC LIMIT 20;`
- Step B: `SELECT * FROM orders FOR VERSION AS OF <snapshot_id> LIMIT 100;`
- Step C: `CALL iceberg.system.rollback_to_snapshot('analytics', 'orders', <snapshot_id>);`

**Docs verification (trino.io/docs/467/connector/iceberg.html — verified verbatim 2026-06-08):**
- `$snapshots` metadata table is documented and valid Trino syntax for inspecting snapshot history.
- `FOR VERSION AS OF` is the documented Trino 467 time-travel form. Verbatim docs example: `SELECT * FROM example.testdb.customer_orders FOR VERSION AS OF 8954597067493422955`. `FOR TIMESTAMP AS OF TIMESTAMP '...'` is also valid as an alternative.
- **Critical check on rollback syntax:** the run-prompt asserts Trino 467 rollback is `ALTER TABLE orders EXECUTE rollback_to_snapshot(...)` and that the CALL form is Spark. **The run-prompt premise is incorrect for Trino 467.** The docs example at trino.io/docs/467/connector/iceberg.html verbatim is `CALL example.system.rollback_to_snapshot('testdb', 'customer_orders', 8954597067493422955)`. The deprecation of the CALL form and the introduction of the `ALTER TABLE EXECUTE rollback_to_snapshot` table-procedure form is PR #24580, which merged for Trino **469** (per the PR release-notes). In Trino 467 the CALL form is the official and only documented form.

**Q3 rollback CALL-vs-EXECUTE verdict: NOT a Spark leak.** The responder's `CALL iceberg.system.rollback_to_snapshot('analytics', 'orders', <snapshot_id>)` is the correct, official Trino 467 syntax. The schema/table-as-two-separate-strings shape and the three-arg signature match the docs verbatim. (Spark's form is `CALL catalog.system.rollback_to_snapshot('db.table', snapshot_id)` — Spark uses ONE combined `'db.table'` string, while Trino uses TWO separate strings for schema and table. The responder used TWO strings = Trino-correct.)

Three-step recipe (inspect `$snapshots`, peek with `FOR VERSION AS OF`, then rollback via CALL) is exactly the canonical workflow. Clean answer.

### Q4 — Partition evolution on existing table — 4.00

Responder gave:
- Step 1: `ALTER TABLE iceberg.analytics.orders SET PROPERTIES partitioning = ARRAY['month(occurred_at)'];` — metadata-only, applies to NEW writes only, old data stays in old spec.
- Step 2 (EXPLICITLY labeled Spark, not Trino): `CALL iceberg.system.rewrite_data_files(table => 'analytics.orders', options => map('target-file-size-bytes', '268435456'));`
- Warning: do NOT use `SET PARTITIONING=...`; must be `SET PROPERTIES partitioning = ARRAY[...]`.

**Docs verification (trino.io/docs/467/connector/iceberg.html):**
- Verbatim docs: `ALTER TABLE table_name SET PROPERTIES partitioning = ARRAY['<existing partition columns>', 'my_new_partition_column']`. Responder shape matches.
- `month()` transform is a documented Iceberg partition transform supported by the Trino connector.
- Docs: "the connector queries data created before the change" — confirms old data retains the old spec, new writes use the new spec, mixed-spec reads work transparently. Responder's framing is accurate.
- Step 2 is correctly labeled as Spark. The Spark option key `target-file-size-bytes` IS bare-bytes by Iceberg spec — that is NOT a DataSize defect (different namespace, different type). The cross-spec attribution is correct.

**Minor completeness flag:** the answer could have noted that in Trino 467, if the engineer wants Trino-native compaction of historical partitions to match the new spec, the documented Trino route is `ALTER TABLE ... EXECUTE optimize` (which rewrites data files using the current partition spec). Pointing them to Spark for the historical rewrite is fine and correctly labeled, but a single sentence on "you can ALSO run optimize on existing date ranges from Trino to rewrite into the new spec" would have made this 5/5. Minor docking 1 point on Completeness/Clarity/Actionability.

The `SET PARTITIONING=` DO-NOT-WRITE warning is a good inoculation, useful for the engineer who might guess at the syntax.

---

## FIX-A1 and FIX-A2 verdicts (explicit per run-prompt requirement)

- **FIX-A1 (Q1 DataSize unit-suffix) — CLOSED.** Responder used `'256MB'` unit-suffixed DataSize string, mentioned `'128MB'`/`'512MB'` alternatives, zero bare-bytes leakage. Iter667's three-anchor inoculation (r17 post-1631 block, r12:82 inline sentence, r11:513 top-of-caveat-list) held under probe.
- **FIX-A2 (Q2 per-DAY running total) — CLOSED structurally.** Pre-aggregate-to-one-row-per-day-then-window pattern is present and correctly used. The iter667 broaden at r07:1164 (CONTRAST card recommend ROWS-frame for running totals on row-grain inputs after pre-aggregation) and the new sub-block at r07:1732+ (per-DAY pre-aggregate recipe with the canonical CTE shape) anchored this fix. Slight muddle in the explanatory note about "same-day ties after GROUP BY" — material enough to flag, not material enough to drop below threshold.

---

## Q3 rollback verdict (explicit per run-prompt requirement)

**Q3 rollback is NOT a Spark-CALL-vs-Trino-EXECUTE leak.** The run-prompt's premise is incorrect for Trino 467. The CALL form `CALL <catalog>.system.rollback_to_snapshot('schema', 'table', snapshot_id)` is the official documented Trino 467 syntax (verified verbatim at trino.io/docs/467/connector/iceberg.html). The `ALTER TABLE EXECUTE rollback_to_snapshot` form is a Trino 469+ addition (per PR #24580 deprecation/table-procedure-introduction, which targeted 469). Spark uses a different shape — ONE combined `'db.table'` string — which the responder did NOT use. Responder used the TWO-string Trino-correct shape: CALL form, two-string signature, three args — exactly Trino 467 spec.

**Note to teacher / future judges:** If a future iter standardizes on a newer Trino version (469+), the `ALTER TABLE EXECUTE rollback_to_snapshot(snapshot_id)` form becomes preferred. For Trino 467 (current prod_info.md target), the CALL form is correct and the deprecated-in-469 warning need NOT be applied.

---

## Flagged weak answers

- **Q2 explanatory note** is muddled but does NOT break correctness; the SQL produces the right result. Flagged for teacher awareness, not a regression.
- **Q4** could mention Trino-native `optimize` as a same-engine alternative to the Spark `rewrite_data_files` route; minor completeness gap, not a regression.

---

## Recommended iter668 directive: **DEFAULT NO-OP / durability-breadth**

Rationale: PASS at 4.5625 overall with FIX-A1 CLOSED and FIX-A2 CLOSED. Q3 is NOT a Spark leak — the responder's CALL form is the official Trino 467 syntax (run-prompt premise was incorrect). No fix-A is warranted.

Suggested iter668 plays (any of, in priority order):
1. **Durability-breadth probe.** Re-probe a known-strong topic (predicate pushdown, CTAS-with-partition-spec, MERGE INTO, ANALYZE TABLE for CBO/NDV, federation cross-source pushdown) from a fresh angle to confirm hold-the-line. Federation is the rubric's higher-bar topic (≥4.5) and is most worth re-probing on a never-asked sub-angle.
2. **Q2 muddled-note micro-tighten (optional).** A very small clarification at r07:1732+ explicitly stating "after GROUP BY day, each day is UNIQUE — there are no ties to lump, so ROWS and RANGE give identical results here; we recommend ROWS for intent clarity." This is a polish, not a fix-A.
3. **Trino-native optimize-after-partition-evolution micro-note (optional).** At the partition-evolution route (likely r17 or r24), add a one-sentence cross-reference: "for historical rewrite into the new spec FROM TRINO, run `ALTER TABLE ... EXECUTE optimize` on the target date ranges; the Spark `rewrite_data_files` path is an alternative if you prefer that engine."

Either of (2)/(3) is fine as a micro-polish. Neither is required to maintain PASS; the topics are well within margin.

**No new fix-A inoculations required.** No Spark/Trino dialect leak detected. Resources are durable on this iteration's probe surface.

---

Sources verified (WebSearch + WebFetch on 2026-06-08):
- [Trino 467 Iceberg connector docs](https://trino.io/docs/467/connector/iceberg.html) — rollback_to_snapshot CALL form, file_size_threshold DataSize unit-suffixed, expire_snapshots retention_threshold, FOR VERSION AS OF, SET PROPERTIES partitioning
- [Trino 467 SELECT docs](https://trino.io/docs/467/sql/select.html) — window frame default = RANGE UNBOUNDED PRECEDING; peers definition
- [Trino PR #24580 — Deprecate CALL rollback_to_snapshot, add ALTER TABLE EXECUTE](https://github.com/trinodb/trino/pull/24580) — merged for Trino 469, confirming CALL form is the only documented form in 467
