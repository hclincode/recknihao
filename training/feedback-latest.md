# iter963 Judge Feedback — 2026-06-11 (EXTENDED PHASE)

**OVERALL: 4.59375 PASS** (margin +1.09375; OVERALL AVERAGE governs, NO per-Q veto)

Per-Q: Q1 4.4375 / Q2 4.625 / Q3 4.75 / Q4 4.5625 = 18.375 / 4 = **4.59375**

All dialect/logic verified BOTH directions vs trino.io/docs/467 (sql/select.html INTERSECT DISTINCT-default + GROUPING bitmask + ROLLUP + NULLS-LAST-default; functions/array.html contains; functions/json.html json_parse + JSON→ARRAY cast) + git-tag 467 source (SetOperationNodeTranslator) + WebSearch 2026-06-11 — NOT against resources/. iter882 verify-BOTH-directions discipline. FEDERATION NOT PROBED (4.49944/310 row UNCHANGED; r22 §13.x hard-locked, OVERRIDDEN per run-prompt).

---

## ★★★ HEADLINE: iter962-Q3 dropped-stated-constraint slip = CONFIRMED ONE-OFF (re-probe CLEAN) ★★★

iter962-Q3 dropped the question's explicit "last 30 days" window (counted all-time both-platform users). iter963-Q1 was the deliberate re-probe: a BOTH-CONDITIONS-WITHIN-A-TIME-WINDOW question ("salespeople who hit Q1 quota AND closed >=1 enterprise deal IN THE LAST 90 DAYS"). The responder CARRIED the 90-day filter through:

```
SELECT sales_rep_id FROM quota_performance WHERE q1_quota_met = true
INTERSECT
SELECT sales_rep_id FROM deals WHERE deal_type = 'enterprise'
  AND deal_closed_date >= current_date - INTERVAL '90' DAY
```

The `deal_closed_date >= current_date - INTERVAL '90' DAY` predicate IS present on the deals side (the side the window applies to — Q1-quota is a season flag, not a recency event). VERDICT: **iter962-Q3 dropped-stated-constraint slip is a CONFIRMED ONE-OFF responder synthesis miss — NOT a resource/findability defect, NOT systemic.** This matters for orchestrator disposition: no FIX-A trigger fires.

---

## ★★★ INTERSECT "semi-join" claim = FALSE-MECHANISM PADDING (iter960 family); lead itself CORRECT ★★★

Two mechanism asides on Q1, verified against trino.io/docs/467 + git-tag 467 source:

**(a) "INTERSECT is NULL-safe — unlike a join with a NULL"** = ROUGHLY TRUE. Trino set operations (INTERSECT/EXCEPT/UNION) dedup with NOT-DISTINCT (null-equals-null) semantics, so two NULL rep_ids would match each other in the intersection — unlike an equi-join where `NULL = NULL` is UNKNOWN. The framing is a tangent (rep_id is almost never NULL in practice) but it is not technically wrong. No ding.

**(b) "Trino plans it as a semi-join (a special efficient operator), cheaper than two subqueries joined"** = **FALSE / imprecise mechanism.** Verified: Trino's `SetOperationNodeTranslator` rewrites INTERSECT (and EXCEPT) as a **UNION ALL of the inputs (each tagged with a source-marker column), followed by an aggregation that counts distinct source markers, then a filter** — NOT a SemiJoinNode. The SemiJoin operator backs IN / EXISTS subqueries, not set operations. This is the SAME false-mechanism padding family as iter960-Q2 ("conditional aggregation decorrelates to SemiJoin") and iter960-Q1 ("LEFT JOIN/IS NULL decorrelates into SemiJoin"). Minor Accuracy ding (-1.0 on Q1 Acc) — NOT a per-Q veto; the LEAD is correct.

**Lead correctness:** INTERSECT IS a valid, clean both-conditions answer. It returns DISTINCT rep_ids (correct for "which salespeople"), is more readable than a two-subquery JOIN, and carried the 90-day window. The "cleaner than two queries joined" thrust of the question is answered correctly.

---

## Per-question detail

### Q1 — both-conditions-in-90-days → INTERSECT — **4.4375** (Acc 4.0 / Comp 4.75 / Clar 4.5 / Act 4.5)
Lead CORRECT; 90-day window CARRIED (re-probe clean); INTERSECT DISTINCT-default verified (sql/select.html); NULL-safe aside roughly true. Acc -1.0 for the false "planned as a semi-join" mechanism padding. Strong otherwise.

### Q2 — rolling 3-week avg → window frame — **4.625** (Acc 4.75 / Comp 4.5 / Clar 4.75 / Act 4.5)
`AVG(weekly_sales) OVER (PARTITION BY sales_rep_id ORDER BY week_date ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)` — VERIFIED valid Trino 467 window-frame syntax; current + 2 preceding = 3 rows = correct trailing average; stays at row grain; "in SQL not app code" correct. Minor note (NOT a ding): ROWS counts PHYSICAL rows, so a rep with a missing/skipped week would pull a non-adjacent earlier week into the frame (RANGE INTERVAL would be calendar-aware). Acceptable canonical answer for a weekly-grain table; responder did not flag the gap-sensitivity nuance — trivial completeness gap only.

### Q3 — orders-by-status + grand-total in one query → ROLLUP — **4.75** (Acc 5.0 / Comp 4.75 / Clar 4.75 / Act 4.5)
`GROUP BY ROLLUP(status)` + `CASE GROUPING(status) WHEN 0 THEN 'Detail' WHEN 1 THEN 'GRAND TOTAL' END` — VERIFIED: ROLLUP valid 467, GROUPING() returns a bitmask (0 = column included/detail, 1 = column rolled-up/grand-total NULL), NULLS LAST is the documented default. One scan vs UNION two scans claim is sound. The simpler `GROUP BY ROLLUP(status) ORDER BY status NULLS LAST` variant is also correct. Highest-scoring answer.

### Q4 — array contains specific product without exploding → contains() — **4.5625** (Acc 4.75 / Comp 4.5 / Clar 4.5 / Act 4.5)
`WHERE contains(product_ids, 42)` — VERIFIED `contains(array(T), element) -> boolean` exists in 467 (functions/array.html); no UNNEST needed (directly answers "without exploding the array"). The JSON-varchar fallback `CAST(json_parse(product_ids) AS ARRAY(BIGINT))` is a valid idiom (json_parse returns JSON; JSON→ARRAY(BIGINT) cast supported). Solid and complete.

---

## Scope notes
- Q1 lead correct + 90-day carried (iter962-Q3 slip = CONFIRMED ONE-OFF) + INTERSECT "semi-join" = false-mechanism padding (iter960 family, per-instance Haiku slip, NO resource fix — adjacent over-attraction risk per feedback_new_card_over_attracts_adjacent.md).
- Q2/Q3/Q4 all clean across distinct families (window frame / ROLLUP+GROUPING / array contains). No resource defect, no findability gap anywhere this sweep.

## iter964 RECOMMENDATION = DEFAULT NO-OP
- overall 4.59375 PASS, margin +1.09375 comfortable;
- iter962-Q3 dropped-constraint slip CONFIRMED ONE-OFF (re-probe clean) — no FIX-A trigger;
- INTERSECT "semi-join" is the recurring false-mechanism-padding meta-pattern (iter936/943/948/950/954/958/959/960/961 family) — per-instance, no single resource fix; do NOT add an INTERSECT-plan card (risks pulling adjacent set-op / IN-EXISTS questions to a wrong/over-specific mechanism canonical);
- optional LIGHT FIX-A ONLY if (i) false-SemiJoin/false-plan-mechanism padding recurs on a set-op or IN/EXISTS surface in next 2 sweeps OR (ii) a stated-constraint drop recurs on a different both-conditions/recency-window surface;
- NEXT SWEEP PROBES: GROUPING SETS / CUBE (extend the ROLLUP angle); window frame BETWEEN N PRECEDING AND N FOLLOWING (centered) and RANGE INTERVAL (gap-aware); lateral JOIN UNNEST (the complement of Q4's no-explode); EXCEPT / anti-membership; do NOT re-probe gaps-and-islands streak-construction.

## DO NOT TOUCH
r22 §13.x federation (hard-locked, OVERRIDDEN) / r07 L3226-3263 B-Streak defang + L37 HAVING-perf + L1624 anti-nesting / r23 QUALIFY-not-Trino + argmax + COUNT(DISTINCT) + HAVING-vs-WHERE + regexp_like + fan-out card + geometric/harmonic mean + percentile/percentile_cont footgun / r09 partition DDL strings + bucket(col,N) column-first / r28 DATE-literal + UnwrapDateTruncInComparison / r13 json_exists strict path + 'partitioning' Iceberg key / r27 QUALIFY landmine §7A.2 / INTERVAL qualifier cards / format_datetime-vs-to_char / NULLS-LAST default / price-suffix canonical / MAX_BY-nested defang.

## PINS REINFORCED
- **INTERSECT returns DISTINCT rows by default (sql/select.html); set ops dedup with NOT-DISTINCT / null-equals-null semantics (so "NULL-safe" is roughly true vs an equi-join's UNKNOWN); INTERSECT is NOT planned as a SemiJoin — SetOperationNodeTranslator rewrites it to UNION ALL + marker-counting aggregation + filter; SemiJoin backs IN/EXISTS only ("planned as a semi-join" = false-mechanism padding).**
- **Rolling-N trailing average = `AVG(x) OVER (PARTITION BY k ORDER BY t ROWS BETWEEN N-1 PRECEDING AND CURRENT ROW)`; ROWS counts physical rows (gap-insensitive); RANGE INTERVAL is calendar-aware for missing-period gaps.**
- **Grand-total-in-same-query = `GROUP BY ROLLUP(col)` + `GROUPING(col)` bitmask (0=detail, 1=rolled-up/NULL grand-total row); one scan vs UNION two scans; default NULLS LAST.**
- **Array membership without UNNEST = `contains(array(T), element) -> boolean` (functions/array.html); JSON-varchar column → `CAST(json_parse(col) AS ARRAY(BIGINT))` then contains.**
- **Carry ALL stated constraints (esp. recency windows) into the query — iter962-Q3 dropped-30-day slip CONFIRMED ONE-OFF on the iter963-Q1 90-day re-probe.**
- **Broken-secondary / false-mechanism padding meta-pattern (iter936/943/948/950/954/958/959/960/961/963 family) persists — LEADS correct, tacked-on mechanism aside ships an imprecise claim; per-instance Haiku slip, NOT a resource defect.**

Federation (4.49944/310) only un-passed-margin row — bulletproofed angles only. PRESERVE full iter534-962 pin inventory; NO federation edits. PIN 467. DO NOT bump training/state.json (already 963; passed=true preserved; overall 4.59375 PASS holds; final_iterations_remaining 0).
