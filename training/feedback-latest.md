# Judge Feedback — iter1023

**OVERALL: 4.6875 (75.0/16) — PASS** (threshold 3.5; margin +1.1875; OVERALL AVERAGE governs, no per-Q veto)

Verified BOTH directions vs trino.io/docs/467 (functions/string.html split_part/strpos/substr, functions/aggregate.html approx_distinct, functions/map.html map_keys/element_at, sql/select.html logical processing order) + WebSearch (WHERE-cannot-reference-SELECT-alias, GitHub #16533) — NOT resources/. Prod stack (Trino 467 + Iceberg + MinIO, ~400M-row tables) all 4 fit; no federation/auth angle this iter.

---

## Per-question scores

### Q1 — split_part, "part after the first dash" — 4.75 CLEAN
`split_part(promo_code,'-',2)` → 'summer2024' from 'ACME-summer2024'. VERIFIED string.html: split_part is 1-based (field 1 = before first delimiter, field 2 = after); when index exceeds field count OR delimiter is absent, returns NULL (responder's "no-dash → NULL" CORRECT). Responder also surfaced the robust multi-dash alternative `substr(s, strpos(s,'-')+1)` — important because split_part(...,2) returns ONLY the 2nd field (for 'A-b-c' it yields 'b', not 'b-c'). The user's example has a single dash, so split_part is exactly correct for it, and the substr caveat is the right "everything-after-first-dash" generalization.
- Accuracy 5 / Completeness 4.75 / Clarity 4.75 / Actionability 4.75

### Q2 — approx_distinct for a trend chart over ~400M rows — 4.8125 CLEAN
`approx_distinct(customer_id)` — HyperLogLog, fixed tiny memory, far faster than COUNT(DISTINCT) which builds a full distinct set. VERIFIED aggregate.html: documented "standard error of 2.3%" applies to approx_distinct (the 2.3% figure is for approx_distinct, NOT approx_percentile — responder cited it on the correct function). Correct tool selection for a dashboard/trend chart; COUNT(DISTINCT) reserved for billing/exact needs. Right call for the 400M-row scale.
- Accuracy 5 / Completeness 4.75 / Clarity 4.75 / Actionability 4.75

### Q3 — all keys present in a MAP — 4.71875 CLEAN
`map_keys(metadata)` → ARRAY of keys. VERIFIED map.html: `map_keys(x(K,V)) → array(K)` returns all keys. `element_at(map,key)` for a single value (returns NULL on missing vs subscript `map[key]` which throws). For all DISTINCT keys across rows: `CROSS JOIN UNNEST(map_keys(metadata)) AS t(key)` + `SELECT DISTINCT` — valid and idiomatic. Covers both the single-row ask and the across-rows generalization.
- Accuracy 5 / Completeness 4.75 / Clarity 4.625 / Actionability 4.75

### Q4 (KEY) — WHERE cannot reference SELECT alias — 4.8125 CLEAN
Responder: WHERE is evaluated BEFORE SELECT projection, so `WHERE risk_score > 0.8` (risk_score being a SELECT-list alias) errors; fix via CTE (preferred) or repeat the full expression in WHERE. VERIFIED — Trino logical processing order is FROM → WHERE → GROUP BY → HAVING → SELECT(aliases created) → ORDER BY; aliases are not visible in WHERE (consistent with GitHub #16533 GROUP-BY-alias behavior; same root cause). CTE/subquery wrap or expression-repeat are both correct fixes. Fully correct Trino 467 behavior.
- Accuracy 5 / Completeness 4.75 / Clarity 4.75 / Actionability 4.75

---

## Resolved verdicts (with citations)
1. **Q1 split_part** — 1-based; delimiter-absent/over-index → NULL; multi-dash returns only the 2nd field (substr+strpos for "after first dash"). [trino.io/docs/467/functions/string.html] — responder CORRECT.
2. **Q2 approx_distinct 2.3%** — "standard error of 2.3%" documented for approx_distinct (HLL); correct vs COUNT(DISTINCT) for trends. [trino.io/docs/467/functions/aggregate.html] — responder CORRECT.
3. **Q3 map_keys** — `map_keys(x(K,V)) → array(K)`; UNNEST + DISTINCT valid for all-keys-across-rows; element_at NULL-safe. [trino.io/docs/467/functions/map.html] — responder CORRECT.
4. **Q4 WHERE-alias** — WHERE precedes SELECT projection; alias not referenceable; repeat expr or CTE/subquery. [trino.io/docs/467/sql/select.html + GitHub #16533] — responder CORRECT.

## Defects / notes
- ZERO defects. No QUALIFY / no false semi-join / no fabricated functions (split_part, strpos, substr, approx_distinct, map_keys, element_at all real & verified) / no regex-backslash / no INTERVAL-quarter-week / no OFFSET-before-LIMIT / no generate_subscripts / no broken-secondary alternative this iter. `::` cast absent in all 4.
- All 4 answers paired the direct ask with a correct generalization (Q1 substr-multidash, Q2 exact-vs-approx tradeoff, Q3 across-rows UNNEST, Q4 CTE-vs-repeat).

## Recommendation = DEFAULT NO-OP
Margin +1.1875; all 4 clean & verified both directions; KEY Q4 (WHERE-alias) and Q2 (approx_distinct 2.3%) both resolved in responder's favor. No source-verified findable gap, no resource defect, no 2-in-2 recurrence. NO resource edit; NO FIX-A; NO git commit. MUST NOT bump state.json (already 1023; orchestrator commits).

Re-probe (monitor only): (a) split_part 1-based + multi-dash-returns-2nd-field + substr/strpos for "after first dash"; (b) approx_distinct 2.3%-std-error HLL vs COUNT(DISTINCT) exact; (c) map_keys→array + UNNEST/DISTINCT all-keys + element_at NULL-safe vs subscript-throws; (d) WHERE-cannot-reference-SELECT-alias (repeat-expr or CTE). Federation r22 §13.x hard-locked NOT probed (4.49944/310).
