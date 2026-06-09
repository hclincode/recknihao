# Judge Feedback — iter877 (EXTENDED PHASE)

**Overall: 4.84 STRONG PASS** (per-Q 5.00 / 5.00 / 5.00 / 4.375 = 19.375 / 4 = 4.84375; margin +1.34 over the 3.5 bar; overall average governs — no per-Q veto.)

**FEDERATION NOT PROBED** — the 4.49944/310 federation row is UNCHANGED this iter (all 4 questions are analytical-SQL / Trino-dialect, no cross-source connector content).

All dialect facts VERIFIED against trino.io/docs/467 (sql/select.html, functions/json.html, functions/window.html, functions/conversion.html) + the Trino "Introducing new window features" blog + WebSearch (Athena/Trino recursion-depth error text) on 2026-06-10. Trino 467 PINNED throughout.

---

## Q1 — Longest run of consecutive SUBSCRIBED MONTHS per customer (gaps-and-islands) — 5.00

Sub-scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5.

The responder emitted the correct **3-LAYER** gaps-and-islands form:
- **Layer 1** — `CASE WHEN date_diff('month', LAG(subscription_month) OVER (PARTITION BY customer_id ORDER BY subscription_month), subscription_month) = 1 THEN 0 ELSE 1 END AS is_new_streak` over a `SELECT DISTINCT customer_id, subscription_month` dedup.
- **Layer 2** — `SUM(is_new_streak) OVER (PARTITION BY customer_id ORDER BY subscription_month) AS streak_id` in its OWN layer.
- **Layer 3** — inner `COUNT(*) AS streak_len GROUP BY customer_id, streak_id`, outer `MAX(streak_len) GROUP BY customer_id`.

And it explicitly stated Trino does NOT allow nesting window functions, so each window goes in its own layer.

VERIFIED: (1) No nested window function (NESTED_WINDOW would throw — git-tag 467 `ExpressionAnalyzer.analyzeWindow`/`extractWindowExpressions`, pinned iter875/876). (2) Exactly one GROUP BY per query level (no double-GROUP-BY parse error). (3) `date_diff('month', earlier, later) = 1` is the correct month-granularity gap flag (`date_diff(unit, ts1, ts2) -> bigint`, NULL on the first row's LAG so the first month flags as a new streak — datetime.html, pinned iter876). The month-granularity variant behaves identically to the day variant validated at iter876.

**This is the 2nd CLEAN datapoint for the gaps-and-islands FIX-A (iter876 day-granularity, iter877 month-granularity). The fix is BULLETPROOFED — no regression, no escalation needed.**

## Q2 — 7-day moving average of daily events per user, one pass — 5.00

Sub-scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5.

Responder: pre-aggregate to one-row-per-day-per-user in a CTE (`COUNT(*) AS daily_events GROUP BY user_id, event_date`), then `AVG(daily_events) OVER (PARTITION BY user_id ORDER BY event_date RANGE BETWEEN INTERVAL '6' DAY PRECEDING AND CURRENT ROW)`.

VERIFIED:
- **Trino 467 SUPPORTS `RANGE BETWEEN INTERVAL '6' DAY PRECEDING AND CURRENT ROW`** over a date/timestamp ORDER BY column. RANGE-with-offset was added in Trino 346 (issue #609, "Introducing new window features" blog shows `RANGE BETWEEN INTERVAL '1' MONTH PRECEDING AND CURRENT ROW`); present and stable in 467. The sort key must be a single sortable (numeric/datetime) column and the offset an interval that can be added/subtracted from it — exactly the responder's shape.
- The **ROWS-vs-RANGE distinction is accurate**: `ROWS BETWEEN 6 PRECEDING` counts physical rows and would (a) count 6 EVENTS not 6 days if applied to raw per-event rows, and (b) shift the window when calendar days are missing; `RANGE … INTERVAL '6' DAY` is calendar-value-aware and includes all rows within 6 days regardless of how many physical rows exist.
- The **pre-aggregate-first reasoning is correct** — collapsing to daily grain before windowing is the right (and necessary) move to get a day-based moving average.

No defect.

## Q3 — Recursive traversal of a product-category parent-child tree — 5.00

Sub-scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5.

Responder: `WITH RECURSIVE category_tree` (base `WHERE category_id = ?`; recursive `JOIN categories c ON c.parent_category_id = t.category_id WHERE t.depth < 50`) then join products. Claimed (1) WITH RECURSIVE is EXPERIMENTAL in Trino 467, (2) `max_recursion_depth` defaults to 10 and ERRORS when exceeded, settable via `SET SESSION max_recursion_depth = 50`, (3) the base UNION ALL recursive form.

VERIFIED — **all three claims ACCURATE, NOT over-cautious**:
- **(c) WITH RECURSIVE IS experimental in Trino 467.** sql/select.html states verbatim: *"This feature is experimental only. Proceed to use it only if you understand potential query failures and the impact of the recursion processing on your workload."* The responder's "experimental / not yet production-stable" framing is CORRECT, not over-cautious.
- **max_recursion_depth DEFAULT IS 10.** Docs verbatim: *"recursion depth is fixed, defaults to 10, and doesn't depend on the actual query results"* and *"You can adjust the recursion depth with the session property max_recursion_depth."*
- **Exceeding the depth ERRORS — it does NOT silently truncate.** The Trino/Athena (Trino-engine) error confirmed via WebSearch: `NOT_SUPPORTED: Recursion depth limit exceeded (10). Use 'max_recursion_depth'`. The responder's "errors when exceeded" is CORRECT.
- The recursive-CTE syntax (anchor SELECT `UNION ALL` recursive SELECT referencing the CTE) is correct Trino. The `WHERE t.depth < 50` guard plus `SET SESSION max_recursion_depth = 50` is exactly the right safety pairing.

No defect.

## Q4 — One JSON object per customer (total_orders / total_spend / avg_order_value) for a downstream API — 4.375

Sub-scores: Accuracy 5 / **Completeness 3.5** / Clarity 4.5 / Actionability 4.5.

Responder: `CAST(MAP(ARRAY['total_orders','total_spend','average_order_value'], ARRAY[CAST(COUNT(DISTINCT order_id) AS VARCHAR), CAST(SUM(amount) AS VARCHAR), CAST(AVG(amount) AS VARCHAR)]) AS JSON) AS customer_stats`; `json_format(CAST(... AS JSON))` for a VARCHAR string; warned that `CAST(map AS VARCHAR)` gives the non-JSON debug form `{k=v}` and not to hand-roll JSON.

VERIFIED:
- **MAP→JSON object is CORRECT.** json.html verbatim: `CAST(MAP(ARRAY['k1','k2','k3'], ARRAY[1,23,456]) AS JSON)` -> `JSON '{"k1":1,"k2":23,"k3":456}'`. MAP→JSON requires VARCHAR keys (satisfied). `json_format(...)` for the VARCHAR string and the `{k=v}` debug-form trap are both correct (matches the r09 LEADING CANONICAL card at L757-786).
- **(d) json_object / json_array DO EXIST in Trino 467** as SQL/JSON constructors — `JSON_OBJECT(key VALUE value [, ...] [NULL ON NULL | ABSENT ON NULL] [RETURNING type])` and `JSON_ARRAY(...)` (functions/json.html). `json_object('total_orders' VALUE count(...), 'total_spend' VALUE sum(...), 'avg_order_value' VALUE avg(...))` builds the SAME object WHILE PRESERVING NUMERIC TYPES.

**COMPLETENESS NUANCE (the only ding):** the responder's all-VARCHAR MAP forces every value through `CAST(... AS VARCHAR)`, so the downstream API receives `"total_spend":"1250.50"` (quoted string) instead of numeric `"total_spend":1250.50`. Because MAP requires a SINGLE homogeneous value type, you genuinely cannot mix INT + DECIMAL + DOUBLE in one MAP→JSON — so stringifying is an inherent MAP limitation. BUT `json_object(... VALUE ...)` has no homogeneity constraint and preserves each value's native JSON type. Since json_object EXISTS in 467 and is the type-preserving idiom an API consumer usually wants, NOT mentioning it is a real (minor) completeness miss — hence Completeness 3.5. The answer still WORKS (valid JSON, correct keys); the values are just quoted numbers.

**NOTE on the question's ROW→JSON premise:** the prompt asserted `CAST(ROW(...) AS JSON)` "produces a JSON ARRAY (loses field names)." This is OUTDATED for Trino 467. Verified on functions/json.html (467): `CAST(CAST(ROW(123,'abc',true) AS ROW(v1 BIGINT, v2 VARCHAR, v3 BOOLEAN)) AS JSON)` -> `JSON '{"v1":123,"v2":"abc","v3":true}'` — a NAMED ROW casts to a JSON OBJECT with field names; only an ANONYMOUS ROW casts to an array. (Field-name-losing array behavior was true in old Presto/Trino <=~352 — changed since ~370.) This does NOT affect the responder's score (it used MAP and made no ROW→array claim), and the r09 card already documents this correctly (L772-774). Flagged only to keep the run-prompt premise from propagating into a future directive.

---

## iter878 recommendation

**DEFAULT NO-OP with an OPTIONAL LIGHT FIX-A.** Three of four answers are flawless (5.00) and the gaps-and-islands FIX is now bulletproofed (2nd clean datapoint). The only blemish is the Q4 completeness nuance.

- **OPTIONAL FIX-A (Q4 only):** In the r09 `CAST(map/array/row AS JSON)` LEADING CANONICAL card (resources/09-lakehouse-schema-design.md, L757-786), ADD a short note that for a **type-preserving** JSON object (numbers stay numeric for a downstream API) the SQL/JSON constructor `json_object('total_orders' VALUE count(...), 'total_spend' VALUE sum(...), 'avg_order_value' VALUE avg(...))` is the idiom, and contrast it with the all-VARCHAR MAP→JSON which stringifies values due to MAP's homogeneous-value-type requirement. Keep the existing MAP→JSON canonical (it is correct and the best answer when stringified values are acceptable). FENCE all SQL (pipe-escape trap). Keyword anchors: json_object Trino, type-preserving JSON object, numbers not quoted in JSON, build JSON object per row preserving numeric types, json_object VALUE constructor, SQL/JSON object constructor.
- **DO NOT** touch the iter876 B-Streak card, the iter875 reconciliation card, or any iter534-876 pin. The Q1/Q2/Q3 forms are all dialect-clean — add no "wrong" cards for them.
- **NO escalation.** No regression surfaced.

PIN Trino 467. NO federation edits. DO NOT bump training/state.json.

### Explicit answers to (c) and (d)
- **(c)** WITH RECURSIVE IS experimental in Trino 467 (docs say so verbatim); `max_recursion_depth` DEFAULT IS 10, and exceeding it ERRORS (`Recursion depth limit exceeded (10)`), it does NOT silently truncate. The responder's claims were ALL accurate.
- **(d)** `json_object` (and `json_array`) DO exist in Trino 467 as SQL/JSON constructors. The responder's all-VARCHAR MAP→JSON works but stringifies numbers; json_object would preserve numeric types — a completeness miss, not an error.
