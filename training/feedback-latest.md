# Judge Feedback — iter1104 (2026-06-26)

**Phase**: extended (passed:true). Breadth durability sweep, 4 angles.
**Iter average**: (4.9375 + 5.0 + 2.75 + 5.0) / 4 = **4.422 PASS** (margin +0.922)
**Verdict**: PASS on average; **ONE source-verified Q3 defect** — FIX-A on r28 GROUPING SETS findability/router-prominence.

---

## Verification — RAW sources / official docs

| Claim | Source verified | Verdict |
|---|---|---|
| `cume_dist()` returns fraction at-or-below (preceding + peer / total) | trino.io/docs/current/functions/window.html (quoted: "number of rows preceding or peer with the row ... divided by the total number of rows") | CORRECT |
| `cume_dist=0.85` with `ORDER BY api_calls ASC` ⇒ top 15% | Logical: 85% have api_calls ≤ current → current is in top 15% by api_calls | CORRECT |
| `percent_rank()` = (rank-1)/(N-1), [0,1] rank position | trino.io/docs/current/functions/window.html | CORRECT |
| `json_extract_scalar(json, path)` returns VARCHAR | trino.io/docs/current/functions/json.html (return type varchar) | CORRECT |
| Missing JSONPath → NULL (no error) | trinodb/trino discussions/19197 + general ON ERROR default = NULL semantics | CORRECT |
| `GROUP BY ROLLUP(a, b)` emits (a,b) + (a) + () — NO (b)-only | trino.io/docs/current/sql/select.html GROUP BY ROLLUP grammar | CORRECT (this is why responder Q3 LEAD is wrong) |
| `GROUP BY CUBE(a, b)` emits full power set including (a,b) detail | sql/select.html GROUP BY CUBE | CORRECT |
| `GROUP BY GROUPING SETS ((a),(b),())` emits exactly per-A + per-B + grand total, NO (a,b) detail | sql/select.html GROUPING SETS — this is the precise tool for Q3 | CORRECT |
| `config.contract.enforced=true` runs a build-time preflight comparing projected columns+types to declared `columns` list | docs.getdbt.com/docs/collaborate/govern/model-contracts (quoted "preflight check ... names and data types matching" + "contract must include every column's name and data_type") | CORRECT |
| Undeclared projected columns fail the preflight | docs.getdbt.com (quoted "contracts apply to all columns defined in a model") | CORRECT |
| Only `not_null` is runtime-enforced on dbt-trino+Iceberg; primary_key/unique are metadata-only | docs.getdbt.com/reference/resource-configs/trino-configs + dbt-trino constraint support docs | CORRECT |

---

## Per-Question scoring

### Q1 — CUME_DIST vs PERCENT_RANK percentile rank within plan tier ("you're in top 15%")

| Dimension | Score | Notes |
|---|---|---|
| Accuracy | 5.0 | Both window functions correctly described; "0.85 → top 15%" with ASC ORDER BY is mathematically right; PERCENT_RANK contrast (rank position, not at-or-below fraction) is right |
| Clarity | 5.0 | Direct framing "fraction at-or-below"; engineer can read without OLAP background |
| Applicability | 5.0 | `CUME_DIST() OVER (PARTITION BY plan_tier ORDER BY api_calls)` is copy-paste ready |
| Completeness | 4.75 | Covered both functions + the contrast cleanly. Tiny shave for not flagging the peer-row tie semantics or NULL-skip behavior — edge angles, not the asked question |

**Q1 avg: 4.9375** CLEAN.

---

### Q2 — Extract fields from a JSON-string `properties` column; missing-field behavior

| Dimension | Score | Notes |
|---|---|---|
| Accuracy | 5.0 | `json_extract_scalar(properties, '$.plan')` → VARCHAR ✓; missing path → NULL (no error) ✓; `CAST(...) AS BIGINT` for seats ✓ |
| Clarity | 5.0 | JSONPath dot notation explicit; NULL-on-missing behavior stated plainly |
| Applicability | 5.0 | `COALESCE(json_extract_scalar(...), 'default')` exactly the prod idiom; CAST for typed fields exactly right |
| Completeness | 5.0 | Covered missing-key NULL semantics, COALESCE default, CAST for type-safe consumption — all three things a SaaS engineer using JSON-string columns needs |

**Q2 avg: 5.0** CLEAN.

---

### Q3 — Signups grouped by country, by plan_tier, AND grand total — one query, replacing 3 UNIONed aggregations

| Dimension | Score | Notes |
|---|---|---|
| Accuracy | 2.5 | **LEAD with `GROUP BY ROLLUP(country, plan_tier)` is WRONG for the asked question.** ROLLUP emits `(country, plan_tier)` detail + `(country)` subtotals + `()` grand total — it does **NOT** emit `(plan_tier)`-only totals. The manager **explicitly asked for "signups grouped by plan tier"** as one of the three target row groups. Engineer who copies the LEAD verbatim ends up with every plan-tier-only total **missing** from the report. CUBE fallback ("if you need independent margins") is workable but over-produces (includes the unwanted `(country, plan_tier)` cross detail). **The precise tool — `GROUP BY GROUPING SETS ((country), (plan_tier), ())` — is NEVER MENTIONED.** GROUPING(country,plan_tier) CASE labeling is internally fine but applied to the wrong operator |
| Clarity | 3.5 | Internal explanation is clear, but the engineer cannot tell from the answer which tool actually matches their three-row-group need; they're being routed to ROLLUP-or-CUBE without the surgical option |
| Applicability | 3.0 | Engineer who follows the LEAD gets wrong output. CUBE alternative requires post-filter to remove cross-detail rows, which the responder did not mention. The "column-names-only" reminder is correctly cited but only for the wrong operators |
| Completeness | 2.0 | Misses the precise tool entirely. The literal question wording ("by country, by plan tier, AND grand total — replace 3 UNION ALL queries") is the textbook GROUPING SETS use case. Does not surface the GROUPING bitmask labels adapted for the GROUPING SETS form |

**Q3 avg: 2.75** Q-level FAIL (below 3.5); iter PASSES on average via no-veto rule.

---

### Q4 — dbt model contract `enforced: true`; new column on underlying Iceberg table, build fails before SQL runs

| Dimension | Score | Notes |
|---|---|---|
| Accuracy | 5.0 | Build-time preflight comparing model's projected columns+types to YAML declared `columns` list ✓; every projected column must be declared (no undeclared extras) ✓; data_type must match exactly (bigint ≠ integer) ✓; only `not_null` enforced at write on dbt-trino+Iceberg ✓; `primary_key`/`unique` metadata-only ✓. All VERIFIED against docs.getdbt.com + dbt-trino constraint docs |
| Clarity | 5.0 | "Trino itself doesn't know contracts exist — dbt is the enforcer" framing is the right mental model |
| Applicability | 5.0 | Engineer knows exactly what to do: add the new column with `name:` + `data_type:` to the `.yml` columns list — that's literally the fix and the responder named it |
| Completeness | 5.0 | Addresses both halves: (a) what the contract check does (preflight column/type match), (b) how to fix the broken build (declare the new column). Draws the build-time vs runtime constraint enforcement line correctly |

**Q4 avg: 5.0** CLEAN.

---

## Summary table

| Q | Topic | Accuracy | Clarity | Applicability | Completeness | Avg |
|---|---|---|---|---|---|---|
| Q1 | Analytical query patterns (CUME_DIST percentile within partition) | 5.0 | 5.0 | 5.0 | 4.75 | **4.9375** |
| Q2 | SQL best practices (json_extract_scalar idiom) | 5.0 | 5.0 | 5.0 | 5.0 | **5.0** |
| Q3 | Improving complex SQL on Trino with dbt (GROUPING SETS / ROLLUP / CUBE) | 2.5 | 3.5 | 3.0 | 2.0 | **2.75** |
| Q4 | dbt model contracts | 5.0 | 5.0 | 5.0 | 5.0 | **5.0** |

**Iter average = 17.6875 / 4 = 4.422 PASS** (no per-Q veto; pass threshold 3.5).

---

## Q3 verdict — FINDABILITY / ROUTER-PROMINENCE FIX-A on r28

### Is the GROUPING SETS content present in resources?

**YES.** Grep against `resources/28-complex-sql-performance-trino-dbt.md`:

- **r28 L413**: `LEADING CANONICAL — Trino GROUPING SETS / ROLLUP / CUBE` block exists
- **r28 L415**: keyword anchors include `subtotal, subtotals, grand total, ROLLUP, CUBE, GROUPING SETS, GROUPING function, GROUPING_ID, row_type, label the subtotal row, multi-level aggregate, hierarchy rollup`
- **r28 L417 (Decision keyword anchors)**: `region totals AND category totals`, `subtotals on both dimensions`, `independent margins`, `every combination of subtotals`, `breakdown by both X and Y with subtotals for each`
- **r28 L419-422 (router)** explicitly states:
  - "detail + subtotals down a group hierarchy + grand total" → `ROLLUP(a, b)`
  - "every combination including each column alone" → `CUBE(a, b)`
  - "only specific named grouping sets (a hand-picked list, NOT the cross-tab detail)" → `GROUPING SETS (...)`
- **r28 L462 (DECIDE FIRST section)**: ROLLUP vs CUBE vs GROUPING SETS decision matrix
- **r28 L481-489** — the **exact worked example for this question**:
  ```sql
  -- by-region totals AND by-category totals AND grand total — but EXPLICITLY NOT the per-region-per-category detail.
  -- WRONG — CUBE(region, product_category) emits the FULL power set INCLUDING the (region, product_category) detail
  -- RIGHT — GROUPING SETS lists EXACTLY the three wanted summaries and nothing else:
  GROUP BY GROUPING SETS ((region), (product_category), ())
  ```
- **r28 L493**: `DO NOT WRITE GROUPING SETS ((a,b),(a),(b),()) when you do NOT want the detail → that IS CUBE(a,b)`
- **r28 L495**: 3-way one-line rule: "hand-picked SPECIFIC subtotals (NOT the full cross-tab) → `GROUPING SETS ((a), (b), ())`; EVERY combination / full power set → `CUBE(a, b)`; hierarchical / prefix drill-down → `ROLLUP(a, b)`"

### Why didn't the GROUPING SETS canonical reach?

**FINDABILITY: the responder read ROLLUP first and stopped — visual STOP point above the GROUPING SETS worked example.**

1. **The ROLLUP "COPY THIS" block at r28 L426-434 is the FIRST copyable example after the router.** Haiku reads top-down; the first `COPY THIS for "subtotal per group + grand total" (hierarchical subtotals)` block lands before the engineer reads the DECIDE FIRST section at L462 + its WRONG/RIGHT GROUPING SETS worked example at L481-489.
2. **Router phrasing at L422 — "only specific named grouping sets (a hand-picked list, NOT the cross-tab detail)"** — is CS-abstract. The engineer's natural phrasing of "I have 3 UNION ALL queries doing different group-bys + a grand total, combine them" does not lexically match "hand-picked list."
3. **Missing keyword anchors for the engineer's actual phrasing.** Greppable anchors in r28 L415-417 do not include any of:
   - "replace N UNION ALL aggregations / consolidate multiple GROUP BYs"
   - "totals by X and by Y and a grand total in one query"
   - "by-country totals AND by-plan totals AND grand total"
   - "subtotals on two independent dimensions without the cross detail"
   - "three independent groupings in one query"
4. **The router's "subtotals on both dimensions" + "independent margins" anchors (L417, L466) currently route to `CUBE(a, b)`**, but CUBE over-produces (adds the unwanted detail). The natural "two independent dimensions + grand total, NO cross detail" phrasing has no clear anchor pointing at the surgical GROUPING SETS form.

### Verdict: FIX-A on r28 — findability / router-prominence (NOT content-addition; content is correct)

**SAME PATTERN as iter1100 storage-tiering (L501 anchor expansion) and iter1101→iter1102 r16/r09 TL;DR-HOIST.** Correct content exists below a visual STOP point; FIX is to expand keyword anchors so the natural-phrasing question routes there AND hoist the surgical worked example into the prominent position adjacent to the router.

### Recommended FIX-A on r28 — three coordinated edits

1. **Expand keyword anchors at r28 L415** to include the natural engineer phrasings:
   - `replace 3 UNION ALL aggregations into one query`
   - `consolidate multiple GROUP BYs`
   - `totals by X and by Y and a grand total in one query`
   - `by-country totals AND by-plan totals AND a grand total`
   - `subtotals on two independent dimensions without the cross detail`
   - `three independent groupings in one query`
   - `signups by country + signups by plan + grand total in one report`
   - `manager wants three summary breakdowns combined`

2. **Add a NEW prominent "REPLACE N UNION ALL" decision-router row at r28 L417 (Decision keyword anchors)** with explicit ROLLUP/CUBE/GROUPING SETS branches and a one-liner: "if your current code is `SELECT ... GROUP BY a` UNION ALL `SELECT ... GROUP BY b` UNION ALL `SELECT ... grand total`, the surgical Trino replacement is `GROUP BY GROUPING SETS ((a), (b), ())`."

3. **Hoist the `GROUPING SETS ((a),(b),())` "RIGHT" worked example at L486-489 to a `COPY THIS` block immediately under the router at L422**, so it appears **BEFORE** the ROLLUP `COPY THIS` block at L426. Current structure puts ROLLUP `COPY THIS` first — Haiku grabs it. Router decision must be visually adjacent to all three copyable examples, not just the ROLLUP one.

**Re-probe next sweep**: Q3 from 2 angles — (a) the literal 3-UNION-ALL replacement scenario (this iter's wording) and (b) a different domain (e.g. "ops wants daily totals AND per-region totals AND grand total in one dashboard query") — to confirm both reach the GROUPING SETS canonical.

### What this defect is NOT

- Not a Trino dialect error or fabricated function.
- Not a [Responder Broken Secondary Alternative] — the LEAD itself is the problem, not a trailing aside.
- Not a [Responder Over-Warning Folklore] — no over-cautious framing.
- Not an imported-prior self-error on the judge or directive side.
- Not a content gap in resources — the precise tool with a worked example is correctly documented at r28 L481-495.

---

## Topics touched & rubric score updates

| Topic | Prior | This iter Q | New running | Status |
|---|---|---|---|---|
| Analytical query patterns on Iceberg+Trino | 4.378 / 52 | Q1 CUME_DIST percentile-within-partition (4.9375) | (227.656 + 4.9375) / 53 = **4.388 / 53** | PASSED |
| SQL query best practices for OLAP | 4.4672 / 156 | Q2 json_extract_scalar+CAST+COALESCE (5.0) | (696.8832 + 5.0) / 157 = **4.471 / 157** | PASSED |
| Improving complex SQL performance on Trino with dbt | 4.6764 / 18 | Q3 GROUPING SETS / ROLLUP / CUBE for 3-UNION-ALL collapse (2.75) | (84.1752 + 2.75) / 19 = **4.575 / 19** | PASSED (drag from Q3 but well above threshold) |
| dbt model contracts | 4.2687 / 5 | Q4 enforced:true + new column on Iceberg breaks build (5.0) | (21.3435 + 5.0) / 6 = **4.391 / 6** | PASSED (recovers off sub-4.3) |

**All four touched topics REMAIN PASSED.** No row crosses below threshold.

---

## Recommendation

**LIGHT FIX-A on r28** — findability / router-prominence on the GROUPING SETS canonical (3 coordinated edits above). NOT a content-addition; the correct worked example already exists at L481-495, but it sits below the ROLLUP `COPY THIS` visual-STOP point and the engineer's natural phrasing doesn't have anchors pointing at it.

- **NO state.json bump** (already 1104, already passed:true).
- **NO federation re-probe** (4.50244 / 312 fragile-PASS per iter1097).
- **NO Q1 / Q2 / Q4 follow-up** (all clean breadth).
- **Re-probe Q3 next sweep** from 2 different domains (3-UNION-ALL collapse, two-independent-dimension report) to confirm FIX-A reach.
- **Optional durability probes** (no edits): storage-tiering row (3.5625 / 6, still thinnest), dbt-snapshots-SCD2 (4.1513 / 12), cost-considerations 22nd angle.

### Pattern observation

Nth findability defect of the iter1100→iter1101→iter1102 family: correct content exists in r28 but lives BELOW a visual STOP point (the ROLLUP `COPY THIS` block). Same fix pattern that worked for r16 storage-tiering (TL;DR-hoist + DO-NOT-WRITE defang) and r09 dbt-snapshots (TL;DR three-orthogonal-decisions hoist) applies here: HOIST the surgical worked example into the router's adjacent COPY THIS position, expand keyword anchors at the top of the LEADING CANONICAL block, add natural-engineer-phrasing routing (UNION ALL collapse, two independent dimensions without cross detail). Per [Trace Recurring Folklore to Resource Root Cause] memory-pin — when a responder repeatedly misroutes between operators in the same router despite all three options being documented, the fix is at the router-card prominence layer, not at the content layer.
