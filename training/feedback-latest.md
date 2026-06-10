# iter960 Judge Feedback

**Phase:** extended | **Federation NOT probed** (4.49944/310 row UNCHANGED) | **DID NOT bump state.json**

All dialect/logic claims verified against trino.io/docs/467 + git-tag 467 source + WebSearch 2026-06-11 (BOTH directions). PINNED Trino 467.

## Per-question scores

### Q1 — anti-join (added but never published; better than LEFT JOIN; big joins slow)
Acc 4.0 / Comp 4.75 / Clar 4.5 / Act 4.75 = **4.50**

- All three anti-join forms correct. Option A LEFT JOIN + `WHERE pp.product_id IS NULL` + SELECT DISTINCT; Option B NOT IN with the NULL-3VL trap correctly flagged ("0 rows if right col nullable" — verified, NOT IN over a nullable right column yields 0/empty by 3VL); Option C NOT EXISTS correctly called NULL-safe.
- VERIFIED nuance: Trino DOES have anti-join transformations (NOT IN / NOT EXISTS subqueries → AntiJoin) and SemiJoin decorrelation (per git-tag query-planner decorrelation rules + Trino issue/PR history). The responder's "Option A LEFT JOIN/IS NULL decorrelates into a hash SemiJoin" is **slightly imprecise**: the LEFT JOIN/IS NULL form is a *manually written* outer-join anti-join, not a subquery that the planner *decorrelates* — it simply executes as a hash left-join with a null-filter. The decorrelate-to-SemiJoin/AntiJoin machinery is what fires for the IN/EXISTS *subquery* family. The practical conclusion (Option A is an efficient hash-based anti-join, prefer it) is sound. Knock Acc -1.0 for the imprecise "decorrelates into SemiJoin" attribution on the LEFT JOIN form specifically.

### Q2 — credits/debits separately in one pass
Acc 3.0 / Comp 4.5 / Clar 4.5 / Act 4.5 = **4.125**

- The SQL **lead is fully correct and clean**: `SUM(CASE WHEN amount>0 THEN amount ELSE 0 END)` / `SUM(CASE WHEN amount<0 THEN ABS(amount) ELSE 0 END)` + net `SUM(amount)`; the FILTER alternative `SUM(amount) FILTER (WHERE amount>0)` / `SUM(ABS(amount)) FILTER (WHERE amount<0)` is verified-valid 467 (FILTER clause confirmed on functions/aggregate.html; ABS valid). Both compute in one pass. CORRECT.
- **FALSE TACKED-ON CLAIM** (flagged per directive): "Both decorrelate internally to the same SemiJoin operations, so performance is identical." This is **nonsense** — conditional aggregation (SUM(CASE)/FILTER) has NOTHING to do with SemiJoin; functions/aggregate.html FILTER docs make no SemiJoin reference and there is no decorrelation involved (no subquery, no correlation). The *practical* takeaway the responder was reaching for (the two forms are equivalent and both single-pass) is true, but stated via a fabricated mechanism. Knock Acc -2.0 for the false statement. This is the **broken-secondary/spurious-padding meta-pattern** (iter936/943/948/950/954/958/959 family) — the lead is correct, the "for completeness" mechanism claim is wrong — NOT a wrong lead and NOT a resource defect.

### Q3 — distinct countries per user
Acc 5.0 / Comp 5.0 / Clar 4.75 / Act 4.75 = **4.875**

- `SELECT user_id, COUNT(DISTINCT country_code) ... GROUP BY user_id ORDER BY distinct_countries DESC`. Textbook-correct: single-arg COUNT(DISTINCT) verified 467; GROUP BY per-user; ORDER BY alias resolves per sql/select.html. The "hash set per group, costlier than COUNT(*)" note is accurate; approx_distinct ~2.3% standard error correctly attributed to **approx_distinct only** (the documented figure for that function). Clean.
- POSITIVE SIGNAL: responder reaches for COUNT(DISTINCT) correctly where it genuinely applies — NO over-avoidance after the iter959 SUM(DISTINCT)-as-dedup slip. Confirms that was a one-off synthesis miss, not a systemic over-correction.

### Q4 — refunds per agent, last 30 days, sorted; Trino gotchas vs Postgres
Acc 4.0 / Comp 4.75 / Clar 4.5 / Act 4.75 = **4.50**

- SQL correct: `... WHERE processed_at >= current_date - INTERVAL '30' DAY GROUP BY agent_id ORDER BY refund_count DESC`. INTERVAL '30' DAY valid (DAY is one of six valid qualifiers); `current_date - INTERVAL` valid direction; Gotcha1 "INTERVAL - DATE errors" correct (direction matters). Gotcha3 NULL agent_id forms own group + `AND agent_id IS NOT NULL` correct. Gotcha2 partition-pruning-needs-partition-col-in-WHERE correct; naked-`processed_at` form is indeed pruning-friendly; EXPLAIN-for-`constraint=`-on-TableScan advice sound.
- **FABRICATED RULE NAME** (verified): the date_trunc-unwrap *behavior* is REAL and correct (`DATE_TRUNC('day', processed_at) >= ...` is rewritten to a bare-column range predicate that still prunes), but the rule is named **`UnwrapDateTruncInComparison`** in Trino 467 (git-tag source file `UnwrapDateTruncInComparison.java`; PRs #14011/#14161 "Simplify predicates involving date_trunc"). The responder's **"SimplifyDateTrunc" rule name is a fabrication** — no such optimizer rule exists. Knock Acc -1.0 for the invented rule name; behavior claim is otherwise sound.

## Overall

| Q | Acc | Comp | Clar | Act | Avg |
|---|---|---|---|---|---|
| Q1 | 4.0 | 4.75 | 4.5 | 4.75 | 4.500 |
| Q2 | 3.0 | 4.5 | 4.5 | 4.5 | 4.125 |
| Q3 | 5.0 | 5.0 | 4.75 | 4.75 | 4.875 |
| Q4 | 4.0 | 4.75 | 4.5 | 4.75 | 4.500 |

**Overall average = (4.500 + 4.125 + 4.875 + 4.500) / 4 = 18.0/4 = 4.500 → PASS** (margin +1.00; OVERALL AVERAGE governs, no per-Q veto).

## Scope notes / recommendation

**DEFAULT NO-OP.** Two accuracy knocks, both the same meta-pattern, both single-instance, NEITHER a resource defect:

1. **Q2 "decorrelate to same SemiJoin operations"** — false-mechanism padding on a correct lead. Broken-secondary-alternative meta-pattern (iter936/943/948/950/954/958/959). Per `feedback_responder_broken_secondary_alternative.md`, scope as a per-instance Haiku padding slip, NOT a resource fix (no single resource line teaches "SUM(CASE) decorrelates to SemiJoin" — this is responder invention). Do NOT churn.
2. **Q4 "SimplifyDateTrunc" rule name** — fabricated optimizer-rule name on correct behavior. The real name is `UnwrapDateTruncInComparison`. 1st-instance of a fabricated-rule-name slip; behavior canonical (date_trunc/cast unwrap → range → still prunes) is correct in resources (r28 date_trunc-to-range nuance + `reference_trino_unwrap_temporal_predicates.md`). Optional LIGHT FIX-A trigger ONLY if the wrong rule NAME recurs on a different surface in next 2 sweeps: add the correct rule name (`UnwrapDateTruncInComparison` / `UnwrapCastInComparison`) once to the existing unwrap canonical so the responder has a name to cite rather than inventing one. Keep BRIEF; do NOT add an isolated DO-NOT-WRITE snippet (per `feedback_defang_donotwrite_snippets.md`).

POSITIVE: Q3 confirms COUNT(DISTINCT) is reached for correctly where it applies (no iter959 over-correction). Q1 anti-join family solid incl. NOT IN 3VL trap.

**Federation (4.49944/310) — only un-passed-margin row — NOT probed; bulletproofed angles only; r22 §13.x hard-locked, do NOT probe.**

NEXT SWEEP PROBES: window-frame BETWEEN N PRECEDING AND N FOLLOWING; GROUPING SETS/ROLLUP/CUBE; lateral JOIN UNNEST; a one-side-over-counts JOIN angle (AVG/MAX over fan-out vs SUM); do NOT re-probe gaps-and-islands streak-construction.

DO NOT bump state.json (already 960; passed=true preserved; overall 4.500 PASS; final_iterations_remaining 0).
