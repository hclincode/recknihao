# Judge Feedback — iter972 (EXTENDED PHASE)

**OVERALL 4.375 PASS** (Q1 4.81 / Q2 4.81 / Q3 3.13 / Q4 4.75 = 17.50/4 = 4.375; margin +0.875). OVERALL AVERAGE governs — no per-Q veto.

Verified BOTH directions against trino.io/docs/467 (functions/datetime.html operators table, functions/json.html, functions/array.html, language/types.html) via WebFetch 2026-06-17 + pinned memory — NOT against resources/. Q1/Q3/Q4 traced on concrete examples; JOIN cardinality + column scope checked.

Prod fit: Trino 467 + Iceberg + Hive Metastore (prod_info.md). All four are pure SQL/dialect questions — environment-compatible.

---

## Q1 — Total units shipped vs returned per product (THE FAN-OUT RE-PROBE) — **4.81 CLEAN**

Responder PRE-AGGREGATED each table in its OWN CTE (shipped, returned) THEN LEFT JOINed on product_id. This is the CORRECT two-independent-multi-row-tables pattern — no cross-product.

TRACE (product X): shipments rows {10,20,30} → `shipped` CTE SUM=60 (1 row); returns rows {5,15} → `returned` CTE SUM=20 (1 row); LEFT JOIN on product_id → 1 row (shipped=60, returned=20). CORRECT. Without pre-agg, raw join = 3×2=6 rows → SUM(units) ships=120, returns=60 — inflates BOTH, exactly matching the user's "numbers way too high" complaint. Diagnosis of the cross-product is precise; COALESCE(returned,0) for no-return products correct.

**KEY VERDICT: the iter971 Q2 many-to-many JOIN fan-out is a CONFIRMED ONE-OFF.** This re-probe (a structurally identical two-separate-multi-row-tables ratio/compare) came back CLEAN — responder reached pre-aggregate-each-side-before-join unaided. The candidate FIX-A noted in state.json (named two-independent-tables canonical near r23 L933) is therefore NOT warranted on recurrence grounds. Acc 5 / Clar 4.75 / App 4.75 / Comp 4.75.

## Q2 — JSON-array-in-VARCHAR membership test — **4.81 CLEAN**

`contains(CAST(json_parse(feature_flags_json) AS ARRAY(VARCHAR)), 'export_v2')`. VERIFIED 467: `json_parse(varchar)→json` (functions/json.html), `CAST(json AS ARRAY(VARCHAR))` supported (VARCHAR is a supported element type), `contains(array, element)→boolean` (functions/array.html). Case-sensitive exact-match characterization correct. Native-ARRAY-column alternative `contains(feature_flags,'export_v2')` also valid. (A `json_array_contains(varchar, value)→boolean` one-call alternative also EXISTS in 467 and would be simpler, but the responder's parse+cast+contains is correct, idiomatic, and answers the "membership without app code" ask fully.) Acc 5 / Clar 4.75 / App 4.75 / Comp 4.75.

## Q3 — % tickets resolved within 24h by month (THE KEY DIALECT CHECK) — **3.13, ts-MINUS-ts DIALECT SLIP**

Conditional-aggregation structure is CORRECT: `COUNT(*)` total + `COUNT(*) FILTER (WHERE ...)` subset + `ROUND(100.0 * ... / COUNT(*), 1)` decimal pct + `GROUP BY date_trunc('month', created_at)` one-pass. FILTER-on-count, date_trunc('month'), 100.0* decimal promotion all VERIFIED valid 467.

**BUG (CONFIRMED, won't-compile):** the FILTER condition `resolved_at - created_at <= INTERVAL '24' HOUR` subtracts TWO TIMESTAMPS. VERIFIED against trino.io/docs/467 functions/datetime.html operators table BOTH directions: the binary `-` operator supports ONLY `date - interval`, `time - interval`, `timestamp - interval`, `interval - interval`. There is NO `timestamp - timestamp → interval` operand (unlike Postgres). So `resolved_at - created_at` fails to type-check → query does not compile. Canonical Trino form: `date_diff('hour', created_at, resolved_at) <= 24` (day-aware bigint). This is the ts-minus-ts trap.

**RESOURCE-vs-SLIP = RESPONDER DIALECT SLIP, NO resource defect.** Resources teach date_diff and the no-ts-minus-ts rule (pinned memory + r07/r23 date_diff canonicals; iter970 Q4 used `date_diff('day', first, second)` correctly "no ts-minus-ts"). Responder reached past the guard here. Imported-prior / ts-minus-ts family.

**Minor (cosmetic):** the "Why" text claims a `NULLIF(...,0)` guard against divide-by-zero, but the QUERY contains NO NULLIF — false-justification tic. (Also unneeded: per-group COUNT(*) ≥ 1 by construction, so the denominator can't be zero within a GROUP.) Counts toward Clarity, not a second won't-compile defect.

Acc 1.5 (real won't-compile type error; structure right so not 1) / Clar 3.0 (clear prose but the false-NULLIF claim contradicts the shown SQL) / App 3.0 (one date_diff swap from working) / Comp 4.0 (answers count+pct in one pass as asked, monthly).

## Q4 — Most-recent plan per user before aggregating by tier — **4.75 CLEAN**

`ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY changed_at DESC)` then `WHERE rn=1` then `GROUP BY plan_tier` — VERIFIED correct latest-per-group idiom. TRACE: user U with changes {Free@t1, Pro@t2, Free@t3} → rn assigns Free@t3=1 → U counted once under Free. Correct.

**Tic checks CLEAN:** uses ROW_NUMBER, NOT `MAX(varchar)`-as-latest — the MAX(varchar) mislabel did NOT recur. No QUALIFY (correctly used subquery+outer WHERE, not the non-Trino QUALIFY clause). Determinism tiebreaker note `ORDER BY changed_at DESC, plan_change_id DESC` is a genuine value-add. `COUNT(DISTINCT user_id)` after rn=1 is REDUNDANT (each user appears once post-filter) but harmless — not scored down. Acc 5 / Clar 4.75 / App 4.75 / Comp 4.5.

---

## Scope notes / disposition for iter973

- **Q1 fan-out re-probe CLEAN → iter971 Q2 many-to-many fan-out CONFIRMED ONE-OFF.** No FIX-A on recurrence grounds; the named two-tables canonical remains optional/not-warranted. Re-probe a third two-tables ratio only if curious about hardening, not for defect.
- **Q3 ts-minus-ts = RESPONDER dialect slip, resources guard it (date_diff canonical present, used correctly iter970).** Imported-prior/ts-minus-ts family — first appearance in recent sweeps (iter970 Q4 was CLEAN on this exact point). INTERMITTENT, NOT 2-in-2. Per-instance one-off. LIGHT FIX-A (defang/router toward `date_diff('hour',a,b)` near the ticket/duration canonical) ONLY if ts-minus-ts RECURS next sweep (would be 2-in-2 from here). Also note recurring false-justification tic (claimed-NULLIF-absent), broken-secondary family — per-instance, no resource fix.
- Q2/Q4 CLEAN. No semi-join mislabel, no MAX(varchar)-as-latest, no percent_rank inversion, no fabricated function, no QUALIFY, no missing-column-in-CTE-projection, no mid-churn.
- Federation r22 §13.x hard-locked — NOT probed (OVERRIDDEN).
- **iter973 RECOMMENDATION = DEFAULT NO-OP.** Re-probe (a) another duration-threshold-by-month Q (confirm responder reaches date_diff('hour',...) not ts-minus-ts — confirm intermittent), (b) another latest-per-entity-then-aggregate Q (ROW_NUMBER()=1 stays clean, no MAX(varchar)).
- DO NOT bump training/state.json (already 972; passed=true preserved; final_iterations_remaining 0). NO resource edits this iteration.
