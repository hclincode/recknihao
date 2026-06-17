# Judge Feedback — iter1026

**OVERALL: 4.6875 (75.0/16) — PASS** (threshold 3.5; margin +1.1875; OVERALL AVERAGE governs, no per-Q veto)

Verified BOTH directions vs trino.io/docs/467 (functions/array.html filter/transform/any_match/array_remove, functions/aggregate.html approx_percentile overloads + approx_distinct 2.3%, functions/qdigest.html qdigest_agg/value_at_quantile, functions/comparison.html GREATEST/LEAST-NULL + IS DISTINCT FROM) — NOT resources/. Prod stack (Trino 467 + Iceberg + MinIO, on-prem k8s) all 4 fit; no federation/auth angle.

---

## Q1 — filter array elements longer than 3 chars — 4.8125 CLEAN
Acc 5 / Comp 4.75 / Clar 4.75 / App 4.75

`filter(tags, tag -> length(tag) > 3) AS long_tags` is exactly right. VERIFIED array.html: `filter(array(T), function(T, boolean)) -> array(T)` "Constructs an array from those elements of array for which function returns true." Keeps matching elements, stays an array, no UNNEST/re-agg. The transform / any_match / array_remove asides are all REAL functions with the signatures the responder implied (transform(array(T),function(T,U))->array(U); any_match(array(T),function(T,boolean))->boolean; array_remove(x,element)->array). No fabrication.

## Q2 (KEY) — p95 / approximate percentile + accuracy — 4.8125 CLEAN
Acc 5 / Comp 4.75 / Clar 4.75 / App 4.75

- `approx_percentile(response_time_ms, 0.95)` for p95 → CORRECT (aggregate.html `approx_percentile(x, percentage)`).
- ARRAY form `approx_percentile(x, ARRAY[0.50,0.95,0.99])` → CORRECT (`approx_percentile(x, percentages)` returns array).
- **Main accuracy distinction CORRECT (priority item):** docs publish NO fixed standard-error figure for approx_percentile; the documented "standard error of 2.3%" applies to **approx_distinct ONLY**. The responder explicitly told the engineer NOT to conflate them — exactly right. approx_percentile is T-Digest based with no single published error %.
- No built-in MEDIAN / PERCENTILE_CONT → CORRECT (absent from aggregate.html; PERCENTILE_CONT WITHIN GROUP is a parse error per r05 §2234 lock).
- **Sub-claim assessment — "approx_percentile(x, 0.95, accuracy) — no such overload; build qdigest for tunable accuracy" is FULLY CORRECT, not even an understatement.** VERIFIED aggregate.html: the ONLY overloads are `(x, percentage)`, `(x, percentages)`, `(x, w, percentage)`, `(x, w, percentages)`. The 3-arg form is the WEIGHTED form `(x, w, percentage)` — the third arg is a percentage, NOT accuracy. **NO approx_percentile overload exposes an accuracy parameter** (the run-prompt's hypothesis that a weighted form carries accuracy is NOT borne out by the 467 docs). Accuracy lives in `qdigest_agg(x, w, accuracy)` (VERIFIED qdigest.html: 3 overloads, 3rd takes "a value greater than zero and less than one... constant for all input rows") + `value_at_quantile(qdigest, quantile)`. The responder's recommendation to build a qdigest for tunable accuracy is the correct, idiomatic path. No defect.

## Q3 — highest of three warehouse columns per row — 4.78125 CLEAN
Acc 5 / Comp 4.75 / Clar 4.75 / App 4.625

`greatest(warehouse_a_stock, warehouse_b_stock, warehouse_c_stock)` → CORRECT (across columns, one row in/out). VERIFIED comparison.html: GREATEST/LEAST "return null if any argument is null" — so `GREATEST(100, NULL, 50) = NULL` in Trino exactly as stated. The Postgres contrast (Postgres ignores NULLs; Trino/Oracle/MySQL/BigQuery return NULL) is accurate. COALESCE-wrap (e.g. `greatest(coalesce(a,0), coalesce(b,0), coalesce(c,0))`) to ignore NULLs is the right fix. Matches reference_trino_greatest_least_null.md card.

## Q4 (KEY) — null-safe plan_tier-changed check — 4.5625 (minor sloppiness)
Acc 4.5 / Comp 4.75 / Clar 4.5 / App 4.5

Concept CORRECT and VERIFIED (comparison.html): `IS DISTINCT FROM` is null-safe; `a IS DISTINCT FROM b` is TRUE when values differ OR exactly one operand is NULL; FALSE only when both identical (including both NULL). Plain `!=`/`<>` returns UNKNOWN when an operand is NULL → 3-valued logic drops changed-with-NULL rows (e.g. free→NULL or NULL→paid transitions silently excluded). The worked example correctly JOINs `old_subscriptions o` + `new_subscriptions n ON id WHERE o.plan_tier IS DISTINCT FROM n.plan_tier` — fully correct.

**DEFECT (minor, dangling-alias sloppiness):** the FIRST snippet writes `FROM old_subscriptions o ... WHERE o.plan_tier IS DISTINCT FROM new.plan_tier` — there is NO `new` table/alias in that FROM clause, so the `new.` reference is undefined and would not run as written. The second (worked) example fixes this with a proper join + `n` alias. The concept and full worked example are both correct; only the throwaway first snippet has the dangling alias. Light Acc/Clar deduct, not a floor breaker. Per-instance responder slip (sloppy illustrative snippet family), NOT a findable resource gap.

---

## TICS scan
`::` shorthand ABSENT all 4 (good). No QUALIFY / no false semi-join glossary / no fabricated function (filter/transform/any_match/array_remove/approx_percentile/qdigest_agg/value_at_quantile/greatest all real & verified; MEDIAN/PERCENTILE_CONT correctly flagged absent) / no regex-backslash issue / no INTERVAL quarter-week / no OFFSET-before-LIMIT / no generate_subscripts. Only blemish: Q4's first-snippet dangling `new.` alias.

## RECOMMENDATION — DEFAULT NO-OP
Margin +1.1875; all 4 substantively correct incl BOTH KEY items resolved in the responder's favor: Q2 (no-2.3%-for-approx_percentile + T-Digest + no-accuracy-overload→qdigest) and Q4 (IS DISTINCT FROM null-safe vs != UNKNOWN-drops). Q4 dangling-alias is a FIRST-occurrence per-instance sloppiness in a throwaway snippet (worked example correct) — NOT a findable resource gap, NOT 2-in-2. No resource edit, no FIX-A, no git commit.

Re-probe (monitor only):
- (a) filter(array, lambda)→array keep-true, no UNNEST + transform/any_match/array_remove family.
- (b) approx_percentile no-2.3% (vs approx_distinct 2.3%), ARRAY-form for multiple, NO accuracy overload → qdigest_agg(x,w,accuracy)+value_at_quantile for tunable accuracy; watch MEDIAN/PERCENTILE_CONT relapse.
- (c) GREATEST/LEAST return NULL if ANY arg NULL (Postgres-contrast) + COALESCE-wrap.
- (d) IS DISTINCT FROM null-safe vs != UNKNOWN-drops; watch dangling-alias relapse in the illustrative snippet — if 2-in-2, LIGHT findability nudge (alias both sides of the join in the lead snippet).

Federation r22 §13.x hard-locked NOT probed (stays 4.49944/310). MUST NOT bump state.json (already 1026; orchestrator commits).
