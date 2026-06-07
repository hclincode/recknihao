# Iter652 Judge Feedback — 2026-06-08

## Verdict: STRONG PASS — Overall 4.96875 (margin +1.46875 above 3.5 floor)

This is a CLEAN NO-OP / durability-breadth iteration. All four anticipated fresh-area probes LANDED CLEAN on first probe under the new keyword surfaces. Zero per-Q scores below 3.5. Lowest per-Q is Q4 at 4.875 — well above floor. The iter646/iter647 GROUP-BY-rule hardening held cleanly on both Q3 (all-aggregate SELECT, no stray ungrouped column) and Q4 (GROUP BY REPEATS the regexp_extract / CASE expression — no stray alias).

---

## Per-question scoring

### Q1 — count orders whose tags ARRAY contains 'gift' — **5.0 STRONG PASS**
- **Accuracy 5.0** — `WHERE contains(tags, 'gift')` is the exact Trino 467 canonical. VERIFIED at trino.io/docs/current/functions/array.html: `contains(x, element) -> boolean — Returns true if the array x contains the element.` Signature, return type, and use case match docs verbatim.
- **Completeness 5.0** — Noted case-sensitive exact match, mentioned UNNEST per-tag alternative for the multi-row-output variant.
- **Clarity 5.0** — One-line SQL, alias `orders_with_gift_tag` is self-documenting.
- **Actionability 5.0** — Engineer can paste directly into Trino 467.

### Q2 — most recent row per customer from customer_snapshots — **5.0 STRONG PASS**
- **Accuracy 5.0** — `ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY updated_at DESC)` in subquery + outer `WHERE rn = 1` is the canonical Trino latest-per-key dedup. QUALIFY-absent caveat is correct per Trino 467 (confirmed via web search — no QUALIFY support in 467; Starburst community thread shows this is a long-standing user request).
- **Completeness 5.0** — Correctly noted Trino has no QUALIFY (subquery + WHERE rn=1 instead); SELECT * shape requires ROW_NUMBER form (max_by would be a per-column alternative but does NOT compose with SELECT * — correctly NOT recommended here, no penalty).
- **Clarity 5.0** — Clean two-level query, intent obvious.
- **Actionability 5.0** — Drop-in canonical that handles the common SaaS "latest snapshot per entity" pattern.

### Q3 — quarter pivot (Q1/Q2/Q3/Q4 revenue columns, current year, one row) — **5.0 STRONG PASS**
- **Accuracy 5.0** — `SUM(CASE WHEN QUARTER(order_date)=N THEN amount END)` is the canonical Trino pivot (no PIVOT keyword in Trino — verified at r23:2092 + r07:731 lock). VERIFIED at trino.io/docs/current/functions/datetime.html: `quarter(x) -> bigint — Returns the quarter of the year from x. The value ranges from 1 to 4.` AND `year(x) -> bigint`. WHERE `YEAR(order_date) = YEAR(CURRENT_DATE)` pins current year correctly. FILTER alternative `SUM(amount) FILTER (WHERE QUARTER(order_date) = 1)` is dialect-correct (FILTER WHERE supported on all aggregates per Trino docs).
- **Completeness 5.0** — Both CASE-WHEN and FILTER forms shown. GROUP BY YEAR(order_date) included (technically optional given WHERE pins one year — bare aggregate with no GROUP BY would also yield one row — but harmless and correct).
- **Clarity 5.0** — Compact, side-by-side primary + alt forms.
- **Actionability 5.0** — Ready to copy.
- **GROUP-BY-RULE CHECK: CLEAN** — SELECT contains ONLY the four SUM(CASE)/FILTER aggregates (zero stray ungrouped columns). GROUP BY YEAR(order_date) with WHERE-pinned single year → one group → one row. The iter646/iter647 GROUP-BY hardening (no stray ungrouped column in SELECT) holds.

### Q4 — extract browser name from user_agent + count per browser — **4.875 PASS**
- **Accuracy 5.0** — `regexp_extract(user_agent, '(Chrome|Safari|Firefox)')` 2-arg form returns the first whole matched substring — VERIFIED at trino.io/docs/current/functions/regexp.html: `regexp_extract(string, pattern) -> varchar — Returns the first substring matched by the regular expression pattern in string.` The alternation match in this position returns the browser-name token directly (no group index needed). LIKE/CASE alternative also dialect-correct.
- **Completeness 4.5 (-0.5)** — Minor data-modeling nuance missed: real Chrome UA strings contain BOTH 'Chrome' and 'Safari' substrings (Chrome UAs include 'AppleWebKit ... Chrome/120.0.0.0 Safari/537.36'), so regexp_extract returns whichever appears LEFTMOST in the source string. Modern Chrome UAs typically have 'Chrome' BEFORE 'Safari', so leftmost-match lands on 'Chrome' correctly — but in older Webkit-derived UAs the ordering could swap. The LIKE/CASE form has the same ordering hazard (CASE-WHEN-LIKE-%Chrome%-first matters). Not a Trino-dialect error, just a UA-parsing nuance worth a one-line caveat.
- **Clarity 5.0** — Both forms clear, GROUP BY repeats expression explicitly so the responder showed (not just stated) the rule.
- **Actionability 5.0** — Both forms paste-ready.
- **GROUP-BY-RULE CHECK: CLEAN** — Primary form: `GROUP BY regexp_extract(user_agent, '(Chrome|Safari|Firefox)')` REPEATS the SELECT-list expression (does NOT reference the `browser` alias from the same SELECT — correctly avoids the alias-in-GROUP-BY trap). LIKE/CASE alt also REPEATS the CASE expression in GROUP BY. The iter647/iter649 hardening on alias-in-same-SELECT visibility holds.

---

## Dimension cross-check

| Dim | Q1 | Q2 | Q3 | Q4 | Avg |
|---|---|---|---|---|---|
| Accuracy | 5.0 | 5.0 | 5.0 | 5.0 | 5.0 |
| Completeness | 5.0 | 5.0 | 5.0 | 4.5 | 4.875 |
| Clarity | 5.0 | 5.0 | 5.0 | 5.0 | 5.0 |
| Actionability | 5.0 | 5.0 | 5.0 | 5.0 | 5.0 |
| **Per-Q** | **5.0** | **5.0** | **5.0** | **4.875** | **4.96875** |

Per-Q overall: (5.0 + 5.0 + 5.0 + 4.875)/4 = 19.875/4 = **4.96875**
Dim-avg cross-check: (5.0 + 4.875 + 5.0 + 5.0)/4 = 19.875/4 = **4.96875** — agrees.

---

## Docs-truth verification (this iter)

- **contains(array, element) -> boolean** — VERIFIED trino.io/docs/current/functions/array.html. Signature and return type match the resource (r07:235 LEADING CANONICAL).
- **QUALIFY NOT supported in Trino 467** — VERIFIED via release-notes search; Trino 467 release notes (6 Dec 2024) added DISTINCT in windowed aggregates + LISTAGG-as-window — NO mention of QUALIFY support. Starburst community thread confirms long-standing user request unfulfilled. ROW_NUMBER subquery + WHERE rn=1 remains the canonical Trino pattern (r23:2184 + r23:673 + r23:880 inoculations hold).
- **QUARTER(x) -> bigint, YEAR(x) -> bigint** — VERIFIED trino.io/docs/current/functions/datetime.html. Both return bigint; quarter ranges 1..4.
- **regexp_extract(string, pattern) -> varchar (2-arg returns whole first match)** — VERIFIED trino.io/docs/current/functions/regexp.html. Two-argument form returns the first substring matched by pattern (no group index = whole-match). Example in docs: `regexp_extract('1a 2b 14m', '\\d+')` returns `'1'`.
- **FILTER (WHERE x) supported on all aggregates** — Previously verified at trino.io/docs/current/functions/aggregate.html and re-confirmed via Q3 SUM FILTER alternative.

All four Trino 467 dialect claims in the four answers are docs-correct.

---

## Durability-breadth assessment

All four iter652 anticipated fresh-area probes LANDED CLEAN on the first probe under new keyword surfaces:

1. **Q1 contains(array, element) for tag membership** — r07:235 + r07:255 inoculation routed perfectly; no edits ever needed.
2. **Q2 ROW_NUMBER latest-per-key dedup + QUALIFY-absent** — r23 §3.1G canonical block (line 857+) + r23:673 + r23:880 + r23:2184 inoculations routed cleanly; the responder correctly cited the QUALIFY-absence rule.
3. **Q3 quarter pivot SUM(CASE WHEN QUARTER()=N) all-aggregate SELECT** — r07:729+ wide-pivot canonical + r23:2092 conditional-aggregation lock routed cleanly. iter646/iter647 GROUP-BY hardening on no-stray-ungrouped-column held.
4. **Q4 regexp_extract group-token + GROUP-BY-repeat expression** — r27:1030 + r27:933 regex anchors routed cleanly. iter647 GROUP-BY-rule hardening (REPEAT expression, no same-level-alias) held on both the regexp_extract form AND the LIKE/CASE alternative.

The grep-verify approach (pre-mapping each anticipated question shape to existing canonical anchors in resources/) successfully predicted the routing for all four answers without any resource edits. This is the cleanest NO-OP iteration since iter651's 4.9375 — iter652 actually edges UP to 4.96875.

---

## iter653 recommendation: DEFAULT NO-OP / DURABILITY-BREADTH

- No per-Q < 3.5 — no FIX-A target this iteration.
- Lowest per-Q = Q4 at 4.875; the -0.125 completeness gap on the UA-ordering nuance is a data-modeling note, not a Trino-dialect error. NOT worth a teacher edit — adding a UA-parsing caveat to r27 would distract from the dialect-correctness focus and could regress the clean keyword routing.
- All iter534-iter651 locks PRESERVED IN PLACE — DO NOT touch r07 §1a UNNEST, r07 §3 cohort retention, r09:551+/r13:3361+ JSON extract, r23 §3.1E + §11 count_if, r07 Pattern C4a fixed-width-histogram (iter650 FIX-A), r07 Pattern D rolling-N-day-MA (iter649 FIX-A), r23 §8 extract-then-count GROUP-BY-rule (iter647 FIX-A), r23:982/1063 second-largest/top-N-with-ties (iter643/645), r23:1100 date-difference-in-days (iter641), r07 period-total-YoY-ratio + active-every-N-full-months (iter640), r07:§1a.2A listagg/array_join varchar-CAST (iter639), r07:617+ rolling-distinct-HLL (iter637), or any other iter534-iter651 lock.
- Federation NOT probed iter652. Row stays at 4.49944/318 with a now-EIGHT-iteration zero-probe streak (iter645-iter652). r22 §13.x federation guardrails remain thin — DO NOT rewrite.
- Suggested fresh-area probes for iter653 (synthesizable-from-primitives — DO NOT pre-probe content; the existing canonicals should compose): (a) HOF on map column (transform_values / map_filter) "filter map keys by predicate"; (b) array_distinct / array_agg(DISTINCT) one-column flatten + dedup; (c) Trino-Iceberg time-travel FOR VERSION AS OF / FOR TIMESTAMP AS OF re-probe; (d) INSERT OVERWRITE partition semantics in Trino-Iceberg; (e) bulletproofed federation predicate-pushdown re-probe IF opted-in (8-iter zero-probe streak is becoming long enough that a bulletproofed re-probe would be informative — but only if the question routes through the locked predicate-pushdown anchors, NOT through cross-catalog join limits).

---

## Topic average updates (suggested)

- **Analytical query patterns on Iceberg+Trino / r07** — Q1 contains array-membership canonical durability-confirmed (+0.25), Q3 quarter-pivot wide-pivot canonical durability-confirmed under "current year, 4-column" surface (+0.25) — net UP slightly.
- **SQL query best practices for OLAP / r23** — Q2 ROW_NUMBER latest-per-key dedup + QUALIFY-absent canonical durability-confirmed (+0.25), Q4 regexp_extract + GROUP-BY-repeat-expression rule durability-confirmed (+0.25) — net UP slightly.
- **Trino federation** — NOT probed; row stays 4.49944/318 (ZERO probe iter645-iter652 streak = 8 iterations).

---

## Final verdict: **STRONG PASS — Overall 4.96875**

CLEAN NO-OP iteration. All four answers Trino 467 dialect-correct, all four routed through existing canonical anchors without needing resource edits, both GROUP-BY-rule probes (Q3 all-aggregate SELECT, Q4 GROUP-BY-REPEAT-expression on both forms) held cleanly. iter646/iter647 GROUP-BY hardening durable. Recommend iter653 = DEFAULT NO-OP / DURABILITY-BREADTH continuation.
