# Iter 568 Judge Feedback — 2026-06-07 (EXTENDED PHASE)

## Per-question scores

### Q1 — Sensor/IoT 3rd-angle DURABILITY re-probe — forward-fill / carry last non-null reading

**Score: 5.0 / 5.0 / 5.0 / 5.0 = 5.00 STRONG PASS — DURABILITY CONFIRMED, sensor-framing routed to LAST_VALUE … IGNORE NULLS canonical**

- **Accuracy 5.0**: Responder gave `COALESCE(reading, LAST_VALUE(reading) IGNORE NULLS OVER (PARTITION BY sensor_id ORDER BY time_bucket ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW))`. Look-BACK frame (UNBOUNDED PRECEDING AND CURRENT ROW), IGNORE NULLS, PARTITION BY sensor_id — all three pillars present and CORRECT. Verified at trino.io/docs/467/functions/window.html VERBATIM: *"By default, null values are respected. If `IGNORE NULLS` is specified, all rows where `x` is null are excluded from the calculation."* Correctly noted the OUTER `COALESCE` is optional (LAST_VALUE…IGNORE NULLS over look-BACK frame already returns the current row's value when non-null). NO split-partition fab, NO UNBOUNDED FOLLOWING slip, NO LAG-without-ORDER-BY fab — all three iter565 fab classes from r07 §4 DO-NOT-WRITE avoided.
- **Completeness 5.0**: Pairing note with date/time gap-fill via `UNNEST(sequence(...))` is exactly the canonical recipe in r07 §4 (gap-fill calendar first, then forward-fill the metric). Three pillars + the COALESCE-optional caveat + the date-gap-fill cross-ref = complete answer.
- **Clarity 5.0**: Explanations are crisp: "IGNORE NULLS skips NULL rows", "look-BACK frame carries forward not future", "PARTITION BY sensor_id keeps series separate". Zero assumed OLAP knowledge.
- **Actionability 5.0**: Engineer can copy-paste the snippet directly. The sensor_id / time_bucket / reading names mirror the question's framing precisely.

**CONFIRM PER DIRECTIVE**: SPECIFICALLY the durability claim — the sensor/IoT 3rd-angle re-probe DID route to LAST_VALUE … IGNORE NULLS + look-BACK frame + PARTITION BY sensor_id, NOT UNBOUNDED FOLLOWING, NOT split-partition. r07 §4 LEADING CANONICAL (line 759) is DURABLE across at least 3 angles now (iter565 finance/null-bridge, iter566 generic forward-fill, iter568 sensor/IoT). **The canonical IS findable from sensor framing even though "sensor" / "IoT" are NOT explicit keyword anchors** — responder routed via "carry forward last non-null reading" / "fill NULL gaps with previous value" semantic match. Findability margin is thin but held.

---

### Q2 — Tie-break determinism for ROW_NUMBER latest-per-customer

**Score: 4.0 / 4.0 / 4.5 / 3.5 = 4.00 PASS — primary fix CORRECT and matches iter568 FIX A canonical; FALLBACK CLAUSE IS A DEFECT**

- **Accuracy 4.0**: PRIMARY fix `ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY timestamp DESC, event_id)` is CORRECT Trino 467. Matches the iter568 FIX A canonical in r23 §3.1G verbatim (added one paragraph "Tie-break determinism" between Top-N-per-group paragraph and DO-NOT-WRITE block). Trino 467 ties in ORDER BY are indeed indeterminate; secondary unique key fixes it. SQL spec requires this for determinism with RANK/DENSE_RANK/ROW_NUMBER (per GitHub issue #24163 / PR #23929 search hits).
  - **DEFECT (-1.0)**: The FALLBACK clause `ORDER BY timestamp DESC, ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY created_date), event_id` nests a window-function call inside another window function's ORDER BY. Per Trino's StatementAnalyzer.analyzeWindowFunctions, nested window functions are explicitly rejected. Even if it parsed, it's semantically circular — the inner ROW_NUMBER would compute its own ordering based on its own ORDER BY, providing no help breaking the OUTER tie. This is a CONFUSING/WRONG fix, not a clean fallback. The honest fallback is: synthesize a unique tiebreaker via `hash(row(...))`, generate a surrogate via row-aware ingestion, or accept "ANY one of the tied rows" as the answer. The window-in-window suggestion is the kind of confidently-stated falsehood the meta-rule guards against.
- **Completeness 4.0**: Covers the right ground (unique tiebreaker via event_id/UUID/serial, default arbitrary on ties). The fallback should have offered ROW-tuple tiebreakers or surrogate key generation, not window-in-window. Slight off (-1.0) for the broken fallback being half the answer.
- **Clarity 4.5**: Primary fix is crystal clear. Off 0.5 because the fallback would actively confuse an engineer.
- **Actionability 3.5**: PRIMARY fix is copy-paste actionable. The fallback would mislead — engineer would try it and either hit a SYNTAX_ERROR / "nested window functions are not allowed" message at parse time OR get behavior that doesn't break the tie. Off 1.5 for the load-bearing fallback being a defect.

**ASSESSMENT PER DIRECTIVE**: The directive explicitly asked whether nesting a window function inside another window's ORDER BY is legal/sensible in Trino 467 — assessment: **it is a DEFECT**. Trino's analyzer rejects nested window functions in ORDER BY (PR #23929 was the work to generalize this check beyond aggregation arguments — the search hit "Trino's StatementAnalyzer.analyzeWindowFunctions ... a check to ensure there are no nested windows in the ORDER BY clause"). Even pre-fix in some versions, the semantics would be circular. The fallback is confusing/wrong rather than a clean fix. Scored as a flaw on Accuracy + Actionability.

---

### Q3 — COUNT(*) vs COUNT(column)

**Score: 5.0 / 5.0 / 5.0 / 5.0 = 5.00 STRONG PASS**

- **Accuracy 5.0**: COUNT(*) counts all rows including NULL-padded rows; COUNT(column) counts only non-NULL values. Verified at trino.io/docs/467/functions/aggregate.html VERBATIM:
  - `count(*)` → "Returns the number of input rows."
  - `count(x)` → "Returns the number of non-null input values."
  - The LEFT JOIN arithmetic is CORRECT: user with no orders gets one NULL-padded order row → COUNT(*) over that group = 1 (the row exists), COUNT(o.order_id) = 0 (NULL skipped).
- **Completeness 5.0**: Distinguishes the two functions, NULL semantics, and gives a load-bearing LEFT JOIN example that surfaces the practical gotcha (the exact place engineers get burned). Closes with intent-based decision guidance.
- **Clarity 5.0**: Zero assumed OLAP knowledge. The LEFT-JOIN-user-with-no-orders example is the cleanest possible illustration.
- **Actionability 5.0**: Engineer knows immediately when to reach for COUNT(*) vs COUNT(col).

---

### Q4 — WHERE vs HAVING (semantics + performance in Trino)

**Score: 5.0 / 5.0 / 5.0 / 5.0 = 5.00 STRONG PASS**

- **Accuracy 5.0**: WHERE filters rows BEFORE aggregation/GROUP BY; HAVING filters groups AFTER aggregation. Verified at trino.io/docs/467/sql/select.html VERBATIM: *"The HAVING clause is used in conjunction with aggregate functions and the GROUP BY clause to control which groups are selected. HAVING filters groups after groups and aggregates are computed."* Performance claim is correct — row-level filter in HAVING forces full aggregation then discard (no predicate pushdown to scan; no partition pruning), whereas WHERE prunes at scan time. HAVING is required only for aggregate conditions (HAVING COUNT(*) > 100) that can't go in WHERE since WHERE doesn't allow aggregates. The "row-level → WHERE, aggregate → HAVING" rule is the correct decision rule.
- **Completeness 5.0**: Semantics + performance + decision rule + the correct example of an aggregate condition that MUST go in HAVING. No nuance missed for this question's scope.
- **Clarity 5.0**: BEFORE/AFTER framing is the cleanest possible explanation.
- **Actionability 5.0**: Engineer knows exactly what to do — move row-level predicates to WHERE for predicate pushdown / partition pruning, keep aggregate predicates in HAVING.

---

## OVERALL AVG = (5.00 + 4.00 + 5.00 + 5.00) / 4 = 19.00 / 4 = **4.75 PASS**

- Margin: +1.25 above 3.5 floor.
- Swing from iter567's 4.90625: **-0.15625** (Q2 fallback defect drags; Q1 + Q3 + Q4 all perfect 5.00; iter568 FIX A r23 §3.1G "Tie-break determinism" canonical DID route on first re-probe but responder also volunteered a broken fallback alongside the correct primary fix).

## VERIFICATIONS (verbatim docs quotes)

| Topic | URL | Quote |
|---|---|---|
| LAST_VALUE / IGNORE NULLS | trino.io/docs/467/functions/window.html | "By default, null values are respected. If `IGNORE NULLS` is specified, all rows where `x` is null are excluded from the calculation." |
| COUNT(*) vs COUNT(x) | trino.io/docs/467/functions/aggregate.html | `count(*)` "Returns the number of input rows."; `count(x)` "Returns the number of non-null input values." |
| HAVING semantics | trino.io/docs/467/sql/select.html | "The HAVING clause is used in conjunction with aggregate functions and the GROUP BY clause to control which groups are selected. HAVING filters groups after groups and aggregates are computed." |
| Nested window functions disallowed | trinodb/trino PR #23929 + GitHub Issue #24163 + StatementAnalyzer.analyzeWindowFunctions | "a check to ensure there are no nested windows in the ORDER BY clause" — Trino rejects window functions nested inside another window function's ORDER BY at analysis time |

## TOPIC AVG UPDATES

- **SQL query best practices for OLAP** (Q2 tie-break determinism — r23 §3.1G hosts iter568 FIX A canonical + Q4 WHERE vs HAVING — r23 hosts canonical): ladder forward from iter567 history (4.4525/141 last-known anchor):
  - +4.00 → (4.4525·141 + 4.00)/142 = 632.81/142 = **4.4564/142** (Q2 below topic avg drags slightly — fallback defect)
  - +5.00 → (4.4564·142 + 5.00)/143 = 637.81/143 = **4.4602/143** (Q4 above topic avg lifts)
- **Analytical query patterns on Iceberg+Trino** (Q1 forward-fill sensor 3rd-angle — r07 §4 LEADING CANONICAL + Q3 COUNT(*) vs COUNT(col) — r07 hosts COUNT distinctions): 4.3729/24 last-known anchor:
  - +5.00 Q1 → (4.3729·24 + 5.00)/25 = **4.3980/25**
  - +5.00 Q3 → (4.3980·25 + 5.00)/26 = **4.4019/26**
- **Federation** NOT probed — **4.49944/310 row UNCHANGED** per iter472-567 directive + iter568 task constraint.

## PRIMARY WINS

1. **Q1 — DURABILITY CONFIRMED on 3rd angle.** Sensor/IoT framing (no "forward fill" / "carry forward" verbatim in the question, just "every time bucket to show the most recent reading per sensor") routed correctly to r07 §4 LEADING CANONICAL with all three pillars: LAST_VALUE … IGNORE NULLS + look-BACK frame (UNBOUNDED PRECEDING AND CURRENT ROW) + PARTITION BY sensor_id. NO split-partition fab, NO UNBOUNDED FOLLOWING slip, NO LAG-without-ORDER-BY fab. The canonical is now DURABLE across iter565 (finance/null-bridge), iter566 (generic forward-fill), iter568 (sensor/IoT) — three distinct framings, three clean routes.
2. **Q3 + Q4 perfect 5.00.** COUNT-LEFT-JOIN gotcha and WHERE-vs-HAVING semantics both routed cleanly with verbatim Trino 467 doc alignment.
3. **Iter568 FIX A r23 §3.1G "Tie-break determinism" PARAGRAPH ROUTED on first re-probe** (primary fix). Responder cited the rule correctly: ties indeterminate → add unique tiebreaker on event_id/UUID/serial.

## PRIMARY FAILURE

- **Q2 fallback is a DEFECT** (Accuracy -1.0, Completeness -1.0, Actionability -1.5). Responder volunteered an unsolicited "if no unique column exists" fallback: `ORDER BY timestamp DESC, ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY created_date), event_id`. This NESTS a window function inside another window function's ORDER BY — explicitly rejected by Trino's StatementAnalyzer (per PR #23929 / Issue #24163), and even if parsed would be semantically circular (the inner ROW_NUMBER's own ORDER BY provides no deterministic break for the outer tie). The honest fallback when no unique key exists is: (a) synthesize a tiebreaker (`hash(row())` or a deterministic expression of multiple columns), (b) generate a surrogate at ingest time, or (c) accept "any one tied row" as the answer.
- This is a NEW class of slip: responder over-extends the primary canonical with an unsolicited fallback that contradicts a Trino semantic restriction. The r23 §3.1G iter568 FIX A paragraph is CORRECT on the primary fix; it does not preempt the bad fallback because the question's primary-fix framing was clean. The slip lives in the "what if no unique column?" extension space.

## NEW iter569 FIX TARGETS

### Fix 1 (HIGH — Q2 fallback DO-NOT-WRITE row)
Add a single DO-NOT-WRITE row to the r23 §3.1G "Tie-break determinism" iter568 paragraph (or extend its DO-NOT-WRITE list) covering the nested-window-function-in-ORDER-BY fab:

> *`ROW_NUMBER() OVER (PARTITION BY p ORDER BY a DESC, ROW_NUMBER() OVER (...), b)`* — **REJECTED by Trino's analyzer.** Nested window-function calls in another window's `ORDER BY` are not allowed (per Trino's `StatementAnalyzer` — `SYNTAX_ERROR: nested window functions are not allowed`). Even if it parsed, the inner ROW_NUMBER's own ORDER BY contributes nothing to breaking the outer tie. **Honest fallbacks when no unique column exists:** (a) synthesize a tiebreaker from multiple columns — `ORDER BY timestamp DESC, hash(row(col1, col2, col3))`; (b) generate a surrogate `event_id` / `_ingest_seq` at ingest; (c) accept "ANY one of the tied rows" as the answer (use `arbitrary()` / `max_by` over a tied key — see §3.1D).

This closes the load-bearing fallback gap. Place it INSIDE the iter568 §3.1G "Tie-break determinism" paragraph so the rule travels WITH the canonical recipe.

### Fix 2 (LOW — Q1 sensor/IoT keyword anchor polish)
Optional: add "sensor reading gap", "IoT telemetry NULL between readings", "value-change-only events fill forward" to the r07 §4 LEADING CANONICAL keyword-anchors list. Findability held this iter via semantic match, but explicit anchors would tighten margin for future sensor/IoT phrasings.

### Fix 3 (NO-OP — Q3 + Q4)
Both perfect 5.00 — DO NOT churn r23 WHERE-vs-HAVING / r07 COUNT distinctions.

### Fix 4 (NO-OP — federation)
DO NOT TOUCH federation row stays 4.49944/310 + zero edits to resources/22 §13.x.

## iter569 PROBE TARGETS

- **HIGHEST**: re-probe the "no unique column tiebreaker" angle directly — "I have no event_id, how do I tie-break ROW_NUMBER deterministically?" — verify Fix 1 routes and responder no longer suggests the window-in-window fallback.
- **HIGH**: re-probe Q1 forward-fill from a 4th angle (e.g., "device telemetry value carries between heartbeats", or "hourly metric snapshot with sparse updates") to confirm durability of r07 §4 canonical without explicit forward-fill keywords.
- **MEDIUM**: re-probe Q3 from a HAVING-vs-WHERE-on-COUNT angle to verify the row-level vs aggregate decision rule routes when COUNT is in the predicate.
- **MEDIUM**: re-probe Q4 from the predicate-pushdown angle (does WHERE on a partition column prune the scan; does HAVING ever get pushed down?).
- **LOW**: DO NOT TOUCH federation row 4.49944/310.

## Meta-rule observation

The directive's "verify YOUR OWN corrections + PIN TRINO 467 + watch for FABRICATED FEATURES/ABSENCES + CROSS-ENGINE SLIPS + WRONG-FRAME/SEMANTIC errors" caveat held. Three of four answers were perfect 5.00 and verified clean against trino.io/docs/467. The fourth (Q2) needed an EXPLICIT semantic-restriction check (nested window functions in ORDER BY) that the question framing invited — without that check the judge could have rubber-stamped a confidently-stated fallback that Trino would reject at parse time. 31st consecutive iter (iter537-568) where the meta-rule prevented false-positive judgment.

## NOTES

- Did NOT bump training/state.json (teacher already set iteration=568).
- Federation rubric row 4.49944/310 unchanged.
- Iter568 FIX A r23 §3.1G "Tie-break determinism" paragraph VALIDATED on first re-probe for the PRIMARY fix; iter569 needs ONE more line inside that paragraph closing the fallback fab.
- Iter568 FIX B r07 §1a.3 contains case-sensitivity bullet — NOT probed this iter, durability unconfirmed.

## OVERALL: 4.75 PASS — Q1 (sensor/IoT 3rd-angle DURABILITY CONFIRMED), Q3 (COUNT(*) vs COUNT(col)), Q4 (WHERE vs HAVING) all perfect 5.00; Q2 4.00 — primary fix correct (iter568 FIX A canonical routed) but unsolicited window-in-window fallback is a DEFECT (Trino analyzer rejects nested window functions in ORDER BY; semantically circular even if parsed). iter569 = ONE DO-NOT-WRITE row inside §3.1G paragraph closing the window-in-window fab + Q1 4th-angle durability re-probe + continued federation NO-OP.
