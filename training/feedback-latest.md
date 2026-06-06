# Judge Feedback — Iter 573

PIN: Trino 467. All verifications run against trino.io/docs/467 (or stable doc text identical across 467-481 where the cited statement has not changed).

## Verdict: STRONG PASS — overall avg 4.96875 (margin +1.46875 above 3.5 floor)

iter573 FIX A (spine clean-up, kill GROUP-BY-on-aggregate via scalar-subquery or literal-date form) + FIX B (max_by-vs-MAX "latest not largest" guard) BOTH VALIDATED on first re-probe. All four iter569/571/572 historical defects are now RESOLVED:
- IGNORE-NULLS-inside-paren parse error (iter569/571) — held resolved at iter572, held resolved here.
- Pre-join window anti-pattern (iter570) — held resolved.
- GROUP-BY-on-aggregate spine (iter572 Q1) — RESOLVED via responder's `DATE '2026-01-01'` + `sequence(0,89)` literal-bound form (avoided the need for a MIN()-of-source-date trap entirely).
- MAX-vs-max_by semantic slip (iter572 Q1) — RESOLVED via responder's `max_by(count_val, recorded_at)` use in Q1 + correct contrast-with-MAX framing in Q2.

Q1 5.00 / Q2 5.00 / Q3 4.9375 / Q4 4.9375 = **4.96875 STRONG PASS**. Zero defects on all four. Federation NOT probed — 4.49944/310 row unchanged.

---

## Per-question scores

### Q1 — Daily end-of-day inventory composition re-probe (PRIMARY iter573 FIX A + FIX B check)
**5.0 / 5.0 / 5.0 / 5.0 = 5.00 STRONG PASS**

Verification of each directive sub-point:

(i) **Dense spine — CLEAN.** Responder built spine as `DISTINCT stores CROSS JOIN date_add('day', n, DATE '2026-01-01') FROM UNNEST(sequence(0, 89)) AS t(n)`. This uses a LITERAL date (`DATE '2026-01-01'`) — not a `MIN(date)` aggregate — so there is no `GROUP BY` on an aggregate. The iter572 Q1 defect (the malformed `GROUP BY date_trunc('week', MIN(posted_date))` form) is fully avoided. Hits the spirit of FIX A's bounds-CTE / scalar-subquery alternatives by taking the simplest path: literal date bounds, which is the cleanest form when the question fixes the window (Q1 = Jan 1 to Mar 31, 90 days). Verified at trino.io/docs/current/functions/datetime.html: `sequence(start, stop, step)` returns the integer/date range, `UNNEST` expands the array to rows. No parse-error risk.

(ii) **Per-bucket dedup uses `max_by(count_val, recorded_at)` — CORRECT.** Verified VERBATIM at trino.io/docs/current/functions/aggregate.html: "**max_by(x, y)** — Returns the value of x associated with the maximum value of y over all input values." This is precisely the "last count of the day, not the biggest" semantic — the value of `count_val` from the row whose `recorded_at` is the latest in the bucket. The iter572 Q1 defect (`MAX(balance)` used for "end-of-week balance") is fully avoided. FIX B routed.

(iii) **IGNORE NULLS placement + frame — CLEAN.** Responder wrote `LAST_VALUE(inventory_count) IGNORE NULLS OVER (PARTITION BY store_id ORDER BY day ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)`. IGNORE NULLS is OUTSIDE the args paren, BEFORE OVER — placement-correct per the grammar (`name '(' args ')' nullTreatment? filter? over?`). Frame is look-BACK (UNBOUNDED PRECEDING AND CURRENT ROW) — no UNBOUNDED FOLLOWING future-fill leak. No pre-join window — the LAST_VALUE is applied in the final SELECT over the LEFT-JOIN-padded dense rows. All three iter569/570/571 anti-patterns avoided.

End-to-end composition: calendar (literal date spine × stores) → daily_counts (per-bucket max_by dedup) → dense_with_nulls (LEFT JOIN spine to daily_counts) → final (COALESCE + LAST_VALUE IGNORE NULLS forward-fill). Order is canonical: dense spine first, then dedup, then JOIN, then window — fanout-safe, gap-filling correct, "quiet days still need a row" requirement met by the COALESCE wrapping the carry-forward.

Zero defects. This is the cleanest Q1 in the past 5+ iterations.

### Q2 — max_by vs MAX micro-probe (PRIMARY iter573 FIX B direct check)
**5.0 / 5.0 / 5.0 / 5.0 = 5.00 STRONG PASS**

Responder's `max_by(status, timestamp_recorded) AS latest_status GROUP BY device_id` is exactly the docs-verbatim form for "value at the latest time": from trino.io/docs/current/functions/aggregate.html: "**max_by(x, y)** — Returns the value of x associated with the maximum value of y over all input values." The contrast with MAX is explicit ("MAX gives the lexicographically/numerically largest, not the chronologically latest") — exactly the FIX B canonical framing. Zero defects. FIX B validated end-to-end (Q1 composition + Q2 direct micro-probe).

### Q3 — approx_distinct vs COUNT(DISTINCT)
**5.0 / 4.75 / 5.0 / 5.0 = 4.9375 STRONG PASS**

(a) **HyperLogLog claim** — CORRECT. Trino's `approx_distinct` is implemented via HyperLogLog (the underlying sketch type is `HyperLogLog` per trino.io/docs/current/functions/hyperloglog.html, and `approx_distinct` is the HLL cardinality estimator).

(b) **Default 2.3% standard error** — CORRECT. Verified at trino.io/docs/current/functions/aggregate.html: "The default standard error is 2.3%." Responder's "approx_distinct(user_id) uses HyperLogLog, default ~2.3% standard error" matches the doc string.

(c) **RSD interpretation** — CORRECT. The 2.3% figure is a standard error / standard deviation, not a hard ceiling, so framing it as "68% of queries within ±2.3%, 95% within ±4.6%" is the textbook normal-distribution interpretation (1σ / 2σ). The "standard deviation not a ceiling" caveat is exactly the right nuance for a SaaS engineer comparing exact vs approximate. The "most accurate 1K–10M" guidance is consistent with HLL behavior (HLL is least accurate on very small cardinalities where the algorithm uses linear counting and on very large cardinalities approaching the sketch capacity).

When-to-use is clean: exact for billing/customer-facing/audit, approx for internal dashboards/monitoring/trends. Minor -0.25 completeness nit: didn't mention the `approx_distinct(x, e)` two-arg form for custom error tolerance (`e` in `[0.0040625, 0.26000]` per docs verbatim) — engineer might want to tighten accuracy at the cost of more memory. Not load-bearing for the question asked. Otherwise strong.

### Q4 — UNNEST array to rows
**5.0 / 5.0 / 4.75 / 5.0 = 4.9375 STRONG PASS**

Responder led with the NATIVE-ARRAY form (`CROSS JOIN UNNEST(tags) AS t(tag)`) — which is exactly right since the question said the field is ALREADY an array. The SPLIT variant (`CROSS JOIN UNNEST(SPLIT(tags, ',')) AS t(tag)`) was added as a secondary case for comma-separated strings. Clause-order point (UNNEST in FROM before WHERE) is correct per Trino 467 SELECT grammar.

LEFT JOIN UNNEST ON TRUE for NULL/empty-array preservation — verified VERBATIM at trino.io/docs/current/sql/select.html: CROSS JOIN UNNEST returns zero entries when array is empty or NULL, so rows are lost; LEFT JOIN preserves the parent row with NULL-padded unnested column ("LEFT JOIN is preferable in order to avoid losing the row containing the array/map field"). The "ON TRUE" constraint is also correct per docs: "in case of using LEFT JOIN the only condition supported by the current implementation is ON TRUE."

Per the judge directive's clarity nit watch: the question said "Event field stores an array of tags like ['mobile','beta','pro']" — i.e., the field IS already an array. Responder led with the native-array form, so the nit doesn't apply. Minor -0.25 clarity nit: could have made the native-array example slightly more prominent (e.g., bolded heading "If `tags` is already an array (your case):") to make the primary case stand out from the secondary SPLIT case. Not load-bearing.

---

## Overall: 4.96875 STRONG PASS (margin +1.46875)

`(5.00 + 5.00 + 4.9375 + 4.9375) / 4 = 19.875 / 4 = 4.96875`

Best iteration in the past 10+. iter573 FIX A + FIX B both routed cleanly on first re-probe. No regressions on iter566/567/568/569/570/571/572 fixes — IGNORE NULLS placement held, no pre-join window, no fabricated features, no cross-engine slips, no wrong-frame errors, dense spine intent held, no UNBOUNDED FOLLOWING leaks. All eight historical anti-patterns in the analytical-query-patterns / SQL-best-practices stack are now consistently dodged across re-probes.

---

## Topic avg updates

- **Analytical query patterns on Iceberg+Trino** (Q1 spine+max_by end-to-end composition, Q4 UNNEST array): 4.3411/24 → (4.3411·24 + 5.00)/25 = **4.3675/25** (+0.0264) → (4.3675·25 + 4.9375)/26 = **4.3894/26** (+0.0219).
- **SQL query best practices for OLAP** (Q2 max_by micro-probe, Q3 approx_distinct): 4.4401/139 → (4.4401·139 + 5.00)/140 = **4.4441/140** (+0.0040) → (4.4441·140 + 4.9375)/141 = **4.4476/141** (+0.0035).
- **Federation row** 4.49944/310 — UNCHANGED (not probed this iteration).

---

## Primary wins

1. **iter573 FIX A (spine clean-up — kill GROUP-BY-on-aggregate)** VALIDATED on Q1 first re-probe. Responder took the literal-date-bound path (`DATE '2026-01-01'` + `sequence(0,89)`) which sidesteps the MIN()-trap entirely. Both the scalar-subquery and bounds-CTE alternatives in r07 §4's new 5th DO-NOT-WRITE bullet are present as backup forms if the question fixes the window dynamically. Either way, the iter572 Q1 defect is gone.
2. **iter573 FIX B (max_by-vs-MAX "latest not largest" guard)** VALIDATED end-to-end on Q1 composition AND Q2 direct micro-probe. Responder applied `max_by(count_val, recorded_at)` in Q1 daily_counts CTE for "last count of the day not biggest"; gave perfect MAX-vs-max_by contrast in Q2.
3. **Q3 approx_distinct + HLL + 2.3% default** all docs-verbatim correct. Engineer-friendly RSD interpretation.
4. **Q4 UNNEST native-array primary + LEFT JOIN ON TRUE NULL/empty-array preservation** docs-verbatim correct.

## Primary failures

NONE this iteration. Zero defects across all four answers.

---

## iter574 directive

**Verdict: STRONG PASS at 4.96875.** No new fix targets — the iter569/570/571/572/573 historical defects are all locked down. iter574 should be a **DURABILITY iteration**: re-probe orthogonal angles to verify the locks hold against different framings.

### Fix targets

(Fix A — NO-OP — r07 §4 COMBINED CANONICAL spine + max_by + IGNORE NULLS + look-back frame) — All five DO-NOT-WRITE bullets routed cleanly. ZERO edits.

(Fix B — NO-OP — r23 §3.1D max_by canonical + DO-NOT-WRITE blockquote) — VALIDATED on Q2 direct micro-probe + Q1 composition. ZERO edits.

(Fix C — NO-OP federation) — 4.49944/310 unchanged; ZERO edits to resources/22 §13.x.

(Fix D — OPTIONAL LOW — approx_distinct(x, e) two-arg form mention) — In whichever resource hosts the approx_distinct canonical, optionally add a one-liner noting the two-arg form `approx_distinct(x, e)` with `e in [0.0040625, 0.26000]` for custom error tolerance (per trino.io/docs/current/functions/aggregate.html verbatim). Single additive sentence; do not rewrite the existing canonical. NOT load-bearing — Q3 scored 4.9375.

### Probe angles for iter574

- **HIGH — Q1 4th-angle composition** with a DIFFERENT bucket-aggregate framing (e.g., "closing balance per account per quarter" or "final reading per sensor per hour") to verify iter573 FIX A + FIX B durability under another spine bound (this time DYNAMICALLY computed from source min/max — to force the scalar-subquery / bounds-CTE path explicitly, not the literal-date escape hatch).
- **HIGH — Q2 2nd-angle max_by composition** — embed max_by inside a larger query (CTE chain or join) to verify the "value at the latest time" canonical routes even when max_by isn't the headline.
- **MEDIUM — Q3 2nd-angle approx_distinct nuance** — ask about custom-error variant (`approx_distinct(x, e)`) or HLL merge across rollups (`approx_set` + `merge` + `cardinality`) to verify durability of HLL framing beyond the default-error case.
- **MEDIUM — Q4 2nd-angle UNNEST WITH ORDINALITY** to verify the responder knows the `WITH ORDINALITY` variant for preserving array position.
- **LOW — Federation** — 4.49944/310 not probed; if iter574 wants to nudge above the 4.5 federation threshold, plan ONE carefully-bulletproofed federation angle. Otherwise leave alone.

### Meta-rule observation

Directive's "SCRUTINIZE Q1: verify each of (i)-(iii)" was decisive — Q1's composition could have looked complex enough to slip past as "mostly right" without checking each substep. WebSearching trino.io/docs/current/functions/aggregate.html for max_by VERBATIM + trino.io/docs/current/sql/select.html for UNNEST + LEFT JOIN ON TRUE VERBATIM was load-bearing for confidence. 36th consecutive iter (iter537-573) where meta-rule discipline materially affected the verdict (this time CONFIRMING strength rather than catching a defect).

WebSearched verbatim:
- trino.io/docs/current/functions/aggregate.html — `max_by(x, y)` "Returns the value of x associated with the maximum value of y over all input values" + `approx_distinct(x)` "The default standard error is 2.3%" + `approx_distinct(x, e)` "e in [0.0040625, 0.26000]"
- trino.io/docs/current/sql/select.html — UNNEST "returns zero entries when the array/map is empty" + "LEFT JOIN is preferable in order to avoid losing the row containing the array/map field" + "in case of using LEFT JOIN the only condition supported by the current implementation is ON TRUE"
- trino.io/docs/current/functions/window.html — "By default, null values are respected. If IGNORE NULLS is specified, all rows where x is null are excluded from the calculation."

NOTES: did NOT bump training/state.json (teacher already set iteration=573). Federation rubric row 4.49944/310 unchanged. Did NOT touch resources files. iter573 FIX A + FIX B = CLEAN WIN, routed on first re-probe across all four answers.

**OVERALL: 4.96875 STRONG PASS — iter573 FIX A (spine GROUP-BY-on-aggregate kill) + FIX B (max_by-not-MAX guard) BOTH routed cleanly; Q1 5.00 + Q2 5.00 + Q3 4.9375 + Q4 4.9375; zero defects across all four; iter574 should be DURABILITY-only with NO new resource churn — orthogonal-framing re-probes to verify locks hold under different angles.**
