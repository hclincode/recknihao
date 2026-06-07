# Iter584 Judge Feedback — 2026-06-07 (EXTENDED PHASE)

## Verdict: **PASS** — overall avg **4.5625** (margin +1.0625 above 3.5 floor)

**Overall-average governs the label** (per directive). Quality concern flagged separately: Q1 per-question score 3.25 is below the per-question 3.5 floor — the iter584 §3.1E intent-anchor extension was a landing-point miss for the exact question phrasing it was designed to intercept. This is a routing defect, not a content defect.

---

## Per-question scores (Accuracy / Completeness / Clarity / Actionability)

### Q1 — count_if RE-PROBE (per-region fraud count) — 3.5 / 2.5 / 4.0 / 3.0 = **3.25 (quality concern)**

**Responder LED with `WHERE is_fraud = true ... COUNT(*) GROUP BY region`**, then offered `SUM(CASE WHEN is_fraud THEN 1 ELSE 0 END)` as the "equivalent." The responder **did NOT surface `count_if(is_fraud)`** and **did NOT surface `COUNT(*) FILTER (WHERE is_fraud)`** at all.

**Verifications (Trino 467 docs, WebFetched today):**
- `count_if(x) -> bigint`: *"Returns the number of `TRUE` input values. This function is equivalent to `count(CASE WHEN x THEN 1 END)`."* — trino.io/docs/467/functions/aggregate.html
- `FILTER`: *"The `FILTER` keyword can be used to remove rows from aggregation processing with a condition expressed using a `WHERE` clause."* — same page; supported for all aggregates

**Two defects:**
1. **count_if omission (FINDABILITY MISS — iter584 §3.1E intent-anchor did NOT route).** The iter584 fix EXTENDED the §3.1E LEADING CANONICAL keyword-anchor line with SaaS intent-phrasings (`count where boolean is true`, `count of trues per group`, `conditional count`, `per-customer count of X where Y is true`, etc.) and ADDED a per-group worked example with the three-form rank (`count_if` → `FILTER (WHERE)` → `SUM(CASE)`). The Q1 question hit the exact intent-phrasing target ("count of the true ones, per region; cleanest Trino way to count rows where a boolean is true per group") and STILL did not surface count_if. The §3.1E anchor extension is a landing-point miss for THIS question — the responder routed elsewhere (likely a `count` / `WHERE filter` / `SUM(CASE)` canonical that sits at a different section).
2. **Zero-group-drop fragility in the PRIMARY/headline form.** `WHERE is_fraud = true ... GROUP BY region` filters BEFORE grouping; a region with zero fraudulent orders disappears entirely from the result set (no row showing 0). The question said "for **each** region" — implying every region, including clean ones with zero. The robust idiomatic form `count_if(is_fraud) GROUP BY region` (no WHERE) keeps every region and emits 0 for clean ones. `COUNT(*) FILTER (WHERE is_fraud)` and `SUM(CASE WHEN is_fraud THEN 1 ELSE 0 END)` over the full unfiltered table also preserve zero-groups. The responder's SUM(CASE) alternative is correct (full-table scan, preserves zero-groups), but the PRIMARY/headline WHERE-form is semantically fragile for the "per each region" requirement.

Partial credit: SUM(CASE WHEN is_fraud THEN 1 ELSE 0 END) over the full table IS a correct equivalent (the §3.1E "form 3 portable fallback"); the responder reached form 3 but not forms 1 or 2.

### Q2 — listagg-DISTINCT 2nd-angle durability (per-region unique product names) — 5.0 / 5.0 / 5.0 / 5.0 = **5.00 STRONG PASS**

Responder led with `array_join(array_agg(DISTINCT product_name ORDER BY product_name), ', ')` and explicitly stated *"Do NOT use listagg(DISTINCT product_name, ', ') — Trino's listagg has no DISTINCT keyword."*

**Verification:** Trino 467 `LISTAGG` signature: `LISTAGG( expression [, separator] [ON OVERFLOW overflow_behaviour]) WITHIN GROUP (ORDER BY sort_item, [...]) [FILTER (WHERE condition)]` — NO DISTINCT slot anywhere in the signature. `array_agg(DISTINCT x ORDER BY x)` + `array_join(array, ', ')` are both valid Trino 467 aggregate forms.

**iter583 relocation (listagg-no-DISTINCT moved from r07 §1a.2A → r27 §7A.2B) is DURABLE across a 2nd framing** (iter583 page-names + iter584 product-names). Function-named-keyword landing-point routing meta-rule validated on a 5th independent case.

### Q3 — CASE in ORDER BY (custom priority sort) — 5.0 / 5.0 / 5.0 / 5.0 = **5.00 STRONG PASS**

`ORDER BY CASE WHEN status='urgent' THEN 1 WHEN status='high' THEN 2 ELSE 3 END, status` — correct Trino 467. CASE expressions are valid in ORDER BY (Trino accepts any SQL expression in ORDER BY per trino.io/docs/467/sql/select.html "Each expression may be composed of output columns, or it may be an ordinal number selecting an output column by position..."). Tie-break by `status` is a thoughtful determinism nudge.

### Q4 — Integer-division gotcha — 5.0 / 5.0 / 5.0 / 5.0 = **5.00 STRONG PASS**

Diagnosed BIGINT/BIGINT integer-division truncation (5/100 = 0); fix = `CAST(... AS DOUBLE) / COUNT(*)`; also offered `DECIMAL(18,4)` variant for monetary precision. Correct Trino 467 semantics.

**Interesting cross-question signal:** Q4 correctly used `COUNT(*) FILTER (WHERE converted = true)` while Q1 did NOT use the same construct for the structurally equivalent "count rows where boolean is true per group" question. This confirms the §3.1E intent-anchor MISS at Q1 is real and routing-driven, not knowledge-gap-driven — the responder knows the FILTER form but only surfaces it under a non-§3.1E framing (the division-gotcha framing). The §3.1E intent-anchors did not intercept the "count where boolean true per group" framing at Q1.

---

## OVERALL AVERAGE = (3.25 + 5.00 + 5.00 + 5.00) / 4 = 18.25 / 4 = **4.5625 PASS**

Overall-avg governs label. Quality concern: Q1 = 3.25 < 3.5 per-question floor (routing defect, not content defect; no overall-label override per directive).

---

## count_if-routing diagnosis (CRITICAL for iter585)

The iter584 fix added correct content at r23 §3.1E:
- Extended keyword-anchor line with SaaS intent-phrasings
- Added per-group worked example with three-form rank
- Added §11 cross-ref pointer

But Q1 — which used the exact intent-phrasing the anchor was designed for ("count of the true ones, per region; cleanest Trino way to count rows where a boolean is true per group") — STILL did not route to §3.1E. The responder produced `WHERE is_fraud = true + COUNT(*)` as the primary and `SUM(CASE WHEN is_fraud THEN 1 ELSE 0 END)` as the equivalent — neither form is at §3.1E's lead. The responder routed somewhere ELSE.

**Where did it route?** Most likely:
1. A generic "filter rows + COUNT(*)" pattern at a basic-aggregation section (the primary form), OR
2. The §11 conditional-aggregation block's SUM(CASE) example (the alternative form), OR
3. r07 §5's existing "the CASE-WHEN form `SUM(CASE WHEN event_type='purchase' THEN 1 ELSE 0 END)` is also valid but more verbose" line — which surfaces SUM(CASE) but does NOT have count_if as the lead at that landing point.

The §3.1E intent-anchor extension was correctly authored but the responder's keyword search routed to a section that does NOT cross-ref §3.1E for "count where boolean is true per group." The iter584 §11 cross-ref pointer was added but it sits AFTER the existing §11 `COUNT(*) FILTER (WHERE event_type='purchase')` lead, so even if §11 routes, the cross-ref to §3.1E is the SECOND thing the responder sees — not the first; and a basic "WHERE + COUNT" landing point is even further from §3.1E.

**Why r07 §5 likely intercepted instead.** The Q1 phrasing "count of the true ones, per region" maps to a "per-group count" framing more strongly than a "conditional expression family" framing. The responder's keyword router probably sees "per region" + "count" + "true" + "boolean" and lands at a per-group-count section in r07, not the conditional-expression-family section at r23 §3.1E. The §3.1E intent-anchors cover the SEMANTIC intent but the responder's router is keyword-positional, not semantic.

---

## iter585 directive — PRIMARY landing-point fix

**Goal:** Make `count_if(bool)` LEAD for the actual section the "per-group count where boolean is true" question opens, AND add a zero-group-safe note.

**Action 1 (PRIMARY — find the actual landing point).** Grep r07 + r23 for the section the responder ACTUALLY opens for "count where boolean true per group" / "count of flagged rows per group" / "fraudulent orders per region count." Candidates:
- r07 §5 conditional aggregation / wide-pivot
- r07 GROUP BY rules anchor
- r23 §11 conditional-aggregation-FILTER LEAD canonical (already has `COUNT(*) FILTER (WHERE event_type='purchase')` as the lead — extend to add count_if as the PRIMARY lead-form variant for the single-boolean case so the responder finds count_if at the FIRST thing read, not as the second-thing cross-ref)

At the section that actually intercepts, ADD count_if as the LEAD form (not just as a cross-ref). The §3.1E anchor extension stays as-is (it was correct), but the FIRST landing point the question opens must ALSO surface count_if at the top, not as a cross-ref.

**Action 2 (zero-group-safe note — CRITICAL).** At the same landing point, ADD an explicit warning:
> When the question says "per each X" or "for each X," the form `count_if(bool) GROUP BY x` (no WHERE filter) keeps ALL groups including those with zero matches. The `WHERE bool = true ... GROUP BY x` form DROPS groups with zero matches — a region with zero fraud disappears entirely from the result set. Same for `COUNT(*) FILTER (WHERE bool) GROUP BY x` (preserves zero-groups) and `SUM(CASE WHEN bool THEN 1 ELSE 0 END) GROUP BY x` (preserves zero-groups). Reach for `count_if(bool) GROUP BY x` first; only use `WHERE bool ... GROUP BY x` if you explicitly want zero-match groups suppressed.

**Action 3 (meta-rule).** The iter584 intent-anchor extension at §3.1E was correct CONTENT placed at the WRONG landing point (the responder's keyword router did not route there for the per-group framing). Mirror the iter583 listagg-no-DISTINCT relocation lesson: when a content-correct fix fails to route, RELOCATE / DUPLICATE the lead to the section the responder's keyword router ACTUALLY opens. For "count where boolean true per group" the landing point is the per-group / conditional-aggregation section, NOT the conditional-expression-family section.

**Re-probes for iter585:**
- Q1 re-probe (3rd framing): "per warehouse, how many shipments arrived damaged (boolean `damaged = true`)" — should surface `count_if(damaged) GROUP BY warehouse` as the LEAD with a zero-group-safe note.
- Q2 listagg-DISTINCT 3rd framing for durability (e.g., "per customer, comma-separated UNIQUE coupon codes").
- Federation re-probe slot (4.49944/310 row still below 4.5 raised threshold, 33+ iter stale).

**Preserve all iter534-584 locks.** No churn on:
- iter583 listagg-no-DISTINCT relocation at r27 §7A.2B
- iter584 §3.1E count_if intent-anchor extension (correct content, just add ANOTHER copy/lead at the actual routing landing point)
- r22 §13.x federation guardrails

---

## Topic rubric updates

- **SQL query best practices for OLAP** (Q1 count_if r23 §3.1E + Q2 listagg-DISTINCT r27 §7A.2B + Q3 CASE-in-ORDER-BY r23 §3.1G area + Q4 integer-division r23): current 4.4664/156
  - Q1: (4.4664·156 + 3.25)/157 = **4.4587/157** (−0.0077 Q1 drag, count_if intent-anchor landing-point miss + zero-group-drop fragility)
  - Q2: (4.4587·157 + 5.00)/158 = **4.4621/158** (+0.0034 Q2 lift, listagg-DISTINCT durable on 2nd framing)
  - Q3: (4.4621·158 + 5.00)/159 = **4.4655/159** (+0.0034 Q3 lift, CASE-in-ORDER-BY clean)
  - Q4: (4.4655·159 + 5.00)/160 = **4.4688/160** (+0.0033 Q4 lift, integer-division gotcha clean)
- **Federation NOT probed** — 4.49944/310 row UNCHANGED.

---

## HEADLINE

**iter584 OVERALL: 4.5625 PASS** (overall-avg governs the label). Q1 per-question 3.25 is BELOW the per-question 3.5 floor (flagged as a quality concern but does NOT change the overall label per directive). **Two strong wins**: Q2 listagg-DISTINCT relocation DURABLE on 2nd framing (iter583 fix holds), Q4 integer-division gotcha clean with `COUNT(*) FILTER (WHERE)` correctly surfaced + CAST-to-DOUBLE / DECIMAL fix correct. **One critical landing-point miss**: iter584 §3.1E count_if intent-anchor extension was correctly authored content but DID NOT route for the Q1 per-group framing the anchor was designed to intercept. The responder still used `WHERE bool = true + COUNT(*)` as the primary (with zero-group-drop fragility) and `SUM(CASE)` as the equivalent — never reaching `count_if` or `COUNT(*) FILTER (WHERE)`. **iter585 PRIMARY**: find the actual section the per-group "count where boolean true" question opens (likely r23 §11 or r07 §5, NOT r23 §3.1E) and put count_if as the LEAD there + add zero-group-safe note (`count_if(bool) GROUP BY x` preserves all groups, `WHERE bool ... GROUP BY x` drops zero-groups).
