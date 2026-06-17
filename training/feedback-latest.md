# Judge Feedback — iter1021

**OVERALL: 4.515625** (72.25/16) | **PASS** (threshold 3.5; margin +1.015625)
OVERALL AVERAGE governs — NO per-question veto.

Verified BOTH directions vs trino.io/docs/467 (functions/aggregate.html listagg/array_agg, functions/datetime.html date_diff/quarter) + WebSearch (array_agg DISTINCT+ORDER-BY rule, SELECT DISTINCT * vs GROUP-BY-all-columns / MarkDistinct shuffle cost) — NOT resources/. Prod stack (purchases/sessions/events/orders on Iceberg+Trino 467+MinIO) all 4 fit; no federation/auth angle (r22 §13.x hard-locked, federation row stays 4.49944/310, NOT probed).

---

## Per-question scores

### Q1 — distinct products per customer in one comma-separated cell — **4.75** CLEAN
PRIMARY `listagg(product_name, ', ') WITHIN GROUP (ORDER BY product_name)` correct (non-distinct); CAST-to-varchar note for numeric ids correct; then "if you need DISTINCT, use `array_join(array_agg(DISTINCT product_name ORDER BY product_name), ', ')` because listagg has no DISTINCT."
- **(a) listagg has NO DISTINCT — CONFIRMED.** aggregate.html synopsis `LISTAGG(expression [, separator] [ON OVERFLOW ...]) WITHIN GROUP (ORDER BY ...) [FILTER ...]` has no DISTINCT slot; WebSearch confirms `listagg()` does not support a DISTINCT modifier. So `listagg(DISTINCT ...)` would be invalid — and **the responder did NOT write the invalid form** (correctly steered to array_agg). Good.
- **(b) `array_join(array_agg(DISTINCT product_name ORDER BY product_name), ', ')` — VALID & CORRECT.** array_agg supports DISTINCT and supports ORDER BY; the only forbidden combination is DISTINCT + ORDER-BY over a DIFFERENT expression ("For aggregate function with DISTINCT, ORDER BY expressions must appear in arguments"). Here ORDER BY `product_name` IS the DISTINCT argument expression, so it is allowed. This is the correct distinct-rollup.
- **Nit (completeness/ordering only):** the ask was explicitly DISTINCT products, but the distinct form was the SECONDARY; listagg (non-distinct) led. Not an accuracy error — both forms present and correct; just suboptimal ordering for an explicitly-distinct question.
- Acc 5 / Comp 4.5 / Clar 4.75 / App 4.75

### Q2 — days elapsed between two timestamps — **4.8125** CLEAN
`date_diff('day', started_at, ended_at)` → bigint; no ts-ts subtraction operator; day-aware/whole-units (1 not 1.08); unit list second..year incl week/quarter.
- **CONFIRMED.** datetime.html: `date_diff(unit, timestamp1, timestamp2) → bigint`. Unit set = millisecond, second, minute, hour, day, week, month, quarter, year. date_diff('day',...) returns complete whole days (drops fractional). Correctly distinguishes date_diff units (where 'week'/'quarter' ARE valid) from INTERVAL qualifiers (where QUARTER/WEEK are parse errors) — matches the INTERVAL-qualifiers pin.
- Acc 5 / Comp 4.75 / Clar 4.75 / App 4.75

### Q3 (KEY) — SELECT DISTINCT * to remove fully-duplicate rows — **3.6875** DEFECT (over-warning / folklore-flattening)
Responder: `SELECT DISTINCT *` "not the right tool / slow / global shuffle"; `ROW_NUMBER() OVER (PARTITION BY customer_id, product_name, purchase_date ORDER BY customer_id) rn=1` "faster"; MERGE-on-write/row_hash upstream; "DISTINCT is a last resort, not production."
- **(a) SELECT DISTINCT * IS the correct, idiomatic Trino tool for fully-identical-row dedup.** It is the canonical way to remove all-column duplicate rows. It is expensive (full distinct = shuffle), but expensive ≠ wrong tool. Calling it "not the right tool" is a perf-overstatement on what is actually the right tool.
- **(b) "ROW_NUMBER is faster" — MISLEADING.** `SELECT DISTINCT *` == `GROUP BY <all columns>` == a full distinct/hash-aggregation + shuffle. `ROW_NUMBER()` partitioned by all columns is **comparable cost** (also a full partition-wide shuffle), NOT meaningfully faster. WebSearch confirms distinct dedup in Trino is a shuffle-bound MarkDistinct/hash-aggregation operation; no basis for "ROW_NUMBER faster." If anything ROW_NUMBER adds a sort within partitions.
- **(c) KEY-MISMATCH BUG in the example.** The ROW_NUMBER example partitions by only 3 columns (customer_id, product_name, purchase_date). That dedupes on a **3-column key**, a DIFFERENT operation from "remove fully-duplicate rows" (all columns identical). If two rows share those 3 columns but differ in any other column, this **silently drops a row that is NOT a duplicate**. Wrong answer to the asked question.
- Upstream/MERGE/row_hash dedup advice is reasonable and fits the prod stack (Iceberg MERGE), so the answer is rescued from a low floor.
- **Classification: responder OVER-WARNING / folklore-flattening — per-instance one-off, NOT a findable resource gap.** Same family as iter1016 (correlated-subquery "always O(N×M)"), iter1017 (plain-IN-NULL-zero-rows). The responder reflexively casts a correct-but-expensive idiom as "wrong/slow" and invents a faster alternative that is (1) comparable cost and (2) semantically different. No single resource edit fixes responder editorializing.
- Acc 3.0 / Comp 4.0 / Clar 4.0 / App 3.75

### Q4 — extract quarter number 1-4 from a timestamp — **4.8125** CLEAN
`quarter(placed_at)` → 1-4; or `EXTRACT(QUARTER FROM placed_at)`; no `quarter_of_year()`; caveat `INTERVAL '1' QUARTER` invalid → `date_add('quarter',1,...)` or `INTERVAL '3' MONTH`.
- **CONFIRMED.** datetime.html: `quarter(x) → bigint`, "value ranges from 1 to 4"; EXTRACT field table maps QUARTER → quarter(), same bigint 1-4. No `quarter_of_year()` in the docs (correctly flagged absent — note this is the right direction, not an imported-prior over-claim). INTERVAL QUARTER caveat correct (QUARTER is a valid date_diff/date_add unit but NOT an INTERVAL qualifier) — matches INTERVAL-qualifiers pin.
- Acc 5 / Comp 4.75 / Clar 4.75 / App 4.75

---

## Sub-score table

| Q | Acc | Comp | Clar | App | Avg |
|---|---|---|---|---|---|
| Q1 listagg/array_agg distinct rollup | 5 | 4.5 | 4.75 | 4.75 | 4.75 |
| Q2 date_diff day | 5 | 4.75 | 4.75 | 4.75 | 4.8125 |
| Q3 (KEY) DISTINCT * dedup | 3.0 | 4.0 | 4.0 | 3.75 | 3.6875 |
| Q4 quarter() | 5 | 4.75 | 4.75 | 4.75 | 4.8125 |
| **Overall** | | | | | **4.515625** |

---

## TICS / hygiene
`::` cast shorthand ABSENT all 4 (good). No QUALIFY, no false semi-join, no fabricated function (listagg/array_agg/array_join/date_diff/quarter all real & verified), no regex-backslash issue, no OFFSET-before-LIMIT, no generate_subscripts. Q4 correctly affirmed INTERVAL QUARTER is invalid. The ONE issue is Q3 over-warning + key-mismatched ROW_NUMBER example.

## Recommendation = DEFAULT NO-OP
Margin +1.015625; 3/4 clean incl Q1 (no invalid listagg(DISTINCT), correct array_agg distinct form present) and Q2/Q4 fully verified. Q3 is a FIRST-occurrence over-warning/folklore one-off (correct-tool-cast-as-wrong + comparable-cost "faster" claim + key-mismatched example), NOT a findable resource gap, NOT 2-in-2. No resource edit, no FIX-A, no git commit.

Re-probe (monitor only):
- (a) **full-row dedup** — watch for relapse where responder calls `SELECT DISTINCT *` "wrong/slow" or proposes a ROW_NUMBER on a column SUBSET (silently drops non-duplicates). If 2-in-2 → LIGHT findability nudge: "SELECT DISTINCT * is the correct idiomatic tool for all-column dedup (expensive but right); ROW_NUMBER must PARTITION BY ALL columns to be equivalent, and is comparable cost not faster; upstream MERGE only for production dedup."
- (b) distinct-rollup-in-one-cell — listagg(no DISTINCT) lead vs array_join(array_agg(DISTINCT x ORDER BY x)) for explicitly-distinct asks; watch the lead-with-non-distinct-on-a-distinct-ask ordering nit.
- (c) date_diff('day') bigint whole-days + week/quarter ARE date_diff units but NOT INTERVAL qualifiers.
- (d) quarter()/EXTRACT(QUARTER) 1-4 + INTERVAL QUARTER invalid.

MUST NOT bump state.json (already 1021; orchestrator commits). Federation r22 §13.x hard-locked NOT probed (4.49944/310).
