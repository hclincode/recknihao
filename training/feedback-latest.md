# iter973 Judge Feedback — EXTENDED PHASE breadth sweep

**OVERALL 4.375 PASS** (Q1 4.8125 / Q2 4.8125 / Q3 3.125 / Q4 4.75 = 17.50/4 = 4.375; margin +0.875; OVERALL AVERAGE governs, no per-Q veto).

All 4 Qs verified BOTH directions vs trino.io/docs/467 (functions/datetime.html, functions/aggregate.html, functions/array.html) + docs.getdbt.com (model-contracts) + dbt-trino adapter docs (trino-configs) via WebFetch/WebSearch 2026-06-17 — NOT against resources/. Q1 percentage logic TRACED on a concrete example. Production stack: Trino 467 Iceberg, dbt-trino — answers fit it.

---

## Q1 — %-support-chats->5min-by-month — 4.8125 CLEAN ★ THE DURATION RE-PROBE (DECISIVE)

**date_diff('minute', started_at, ended_at) > 5 USED + no-ts-minus-ts rule EXPLICITLY STATED.**

- VERIFIED datetime.html: `date_diff('minute', earlier, later)` → BIGINT, later-arg third, computes later−earlier. Correct.
- VERIFIED BOTH directions: Trino 467 has NO timestamp−timestamp→interval operator (`-` supports only temporal−interval). Responder's explicit statement ("you cannot subtract timestamps directly... use date_diff... compare to plain 5 not INTERVAL '5' MINUTE") is exactly right.
- TRACE (month M, 10 chats, 3 long): inner GROUP BY (month,is_long_chat) → (M,1,3)+(M,0,7); outer SUM(CASE is_long_chat=1)=3, SUM(chat_count)=10, 3*100.0/10 = 30.0%. CORRECT per-month %.
- Column scope CLEAN: inner projects month/is_long_chat/chat_count; outer references all three. 100.0* decimal promotion present.
- Acc 5 / Clar 4.75 / App 4.75 / Comp 4.75.

**KEY VERDICT: iter972 Q3 ts-MINUS-ts dialect slip = CONFIRMED ONE-OFF.** This structurally-identical duration-threshold-by-month re-probe came back CLEAN — responder reached date_diff('minute',...) unaided AND volunteered the no-ts-minus-ts guard verbatim. NOT 2-in-2. The candidate LIGHT FIX-A toward date_diff('hour'/'minute',a,b) (flagged in iter972) is NOT warranted on recurrence grounds. r23 L2211 duration canonical + r07 date_diff usages confirmed sufficient.

## Q2 — orders-from->1-warehouse (ARRAY col, no UNNEST) — 4.8125 CLEAN ★

- VERIFIED array.html: `cardinality(array)` → bigint (size); `contains(array, element)` → boolean (membership). Both exist 467.
- `WHERE cardinality(warehouse_ids) > 1` = multi-warehouse: correct (>1 means ≥2 slots). `WHERE contains(warehouse_ids, 123)` = membership: correct. No UNNEST needed: correct (both are scalar array functions, no row explosion).
- Acc 5 / Clar 4.75 / App 4.75 / Comp 4.75.

## Q3 — approximate-median-per-region, 800M rows — 3.125 ★ PERCENTILE-FABRICATION RECURRENCE (KEY CHECK)

**LEAD CORRECT; closing "if exact" aside FABRICATED.**

LEAD (verified correct):
- `approx_percentile(transaction_amount, 0.5) AS approx_median_usd GROUP BY sales_region` — VERIFIED aggregate.html: approx_percentile(x, percentage) exists, is the median fn.
- "no published fixed error %, unlike approx_distinct's documented 2.3%" — VERIFIED: the 2.3% standard-error figure is documented for **approx_distinct ONLY**; approx_percentile's entry has NO error figure (matches pinned reference_trino_approx_percentile_error.md). Responder got this exactly right.
- "NOT HyperLogLog" + avoids O(N log N) sort — correct rationale for 800M rows.

CLOSING ASIDE (fabricated — won't compile / nonsensical):
- "use exact PERCENTILE_CONT" — **FABRICATION. VERIFIED aggregate.html: Trino 467 has NO percentile_cont, NO percentile_disc; WITHIN GROUP = listagg-only.** Won't compile.
- "or a COUNT(DISTINCT) window function" for exact median — **NONSENSICAL: COUNT(DISTINCT) does not compute a median.** Wrong on its face.
- MINOR (tangential): "quantile-digest / T-digest" conflates qdigest and tdigest — two distinct 467 sketch types. Not scored heavily.

**RESOURCE-vs-SLIP = PURE RESPONDER SYNTHESIS SLIP, NO resource fix.** The percentile footgun is ALREADY maximally guarded — r05 L2234-2266 (no PERCENTILE_CONT WITHIN GROUP, approx_percentile is the median fn) and r23 L265/L273-278 (no PERCENTILE_CONT/DISC, no exact-percentile fn, approx_percentile no published std-error, 2.3% is approx_distinct's). The responder reached PAST a maximally-guarded canonical in a VOLUNTEERED secondary "if you need exact" aside while leading correctly. Classic broken-secondary-alternative pattern (iter936/943/948/950/954/970...).

**RECURRENCE NOTE for orchestrator:** This is the 2nd PERCENTILE_CONT fabrication in 3 iters (iter970 Q4, now iter973 Q3) — BUT both are lead-correct + confined to an un-asked secondary aside, and the resource already maximally guards it. Per feedback_synthesis_ceiling_stop_churning.md + feedback_responder_broken_secondary_alternative.md → **Haiku synthesis ceiling, NOT a resource defect. NO resource fix; re-probe per-instance, do NOT churn the guarded footgun.** The two occurrences are NOT consecutive (iter971/972 had no percentile Q; approx_percentile used correctly in interim) and are NOT a findability gap.

- Acc 2.0 (lead copyable-correct; aside ships a fabricated fn + a nonsensical COUNT(DISTINCT)-median claim — real, not cosmetic) / Clar 3.5 / App 3.25 (lead is exactly what to run; aside misleads if copied) / Comp 3.75.

## Q4 — dbt model contract to fail build on rename/retype — 4.75 CLEAN ★

- VERIFIED docs.getdbt.com model-contracts: `contract: {enforced: true}` + every column `name` + `data_type` required; **compile-time "preflight" check raises a Compilation/contract Error BEFORE materialize** on column removal/rename or data_type change. Responder correct.
- Trino types (BIGINT/VARCHAR/TIMESTAMP(6)/DECIMAL(p,s), not string/int) — correct: data_type must match what the platform understands; Trino dialect types are right.
- "contracts are dbt-core not Trino-specific; pair with data tests" — correct.
- dbt-trino constraint claim — VERIFIED against dbt-trino trino-configs docs: **"only not_null constraints are supported"** on the adapter; primary_key/unique are definable in YAML but NOT enforced at write time → need dbt test assertions. Responder's nuance is accurate.
- Acc 5 / Clar 4.75 / App 4.75 / Comp 4.5.

---

## SCOPE / TIC SUMMARY

- Q1/Q2/Q4 CLEAN. Q3 = lead-correct + fabricated secondary aside (PERCENTILE_CONT + COUNT(DISTINCT)-median) = RESPONDER synthesis slip; resource already maximally guards it (no findability gap, no resource defect).
- ★ **iter972 ts-MINUS-ts = CONFIRMED ONE-OFF** (this duration re-probe CLEAN with explicit no-ts-minus-ts statement). No FIX-A warranted.
- ★ **PERCENTILE_CONT fabrication = 2nd in 3 iters but lead-correct + secondary-aside + resource-maximally-guards-it = Haiku synthesis ceiling, NO resource fix, re-probe-don't-churn.**
- NO QUALIFY / semi-join-mislabel / MAX(varchar)-as-latest / percent_rank-inversion / missing-CTE-column / JOIN-fan-out / mid-churn / ts-minus-ts slips this sweep.
- Federation r22 §13.x hard-locked — NOT probed (OVERRIDDEN).
- NO resource edits warranted. state.json NOT bumped (passed=true, final_iterations_remaining 0 preserved).

**iter974 RECOMMENDATION = DEFAULT NO-OP.** Re-probe (a) another approximate-median / volunteered-exact-percentile Q (confirm lead stays approx_percentile, watch whether the PERCENTILE_CONT aside recurs — would be 3rd occurrence; LIGHT defang ONLY if it becomes lead-level or 2-in-2 consecutive), (b) another array-membership/size Q (cardinality/contains stay clean). LIGHT FIX-A only on lead-level or consecutive recurrence.
