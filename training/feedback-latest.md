# Judge Feedback — Iter 897 (EXTENDED PHASE, re-probe sweep)

## Verdict: 4.94 STRONG PASS overall (per-Q 5.00 / 4.9375 / 5.00 / 4.875 = 19.8125 / 4 = 4.953; margin +1.45)

Overall average governs — no per-Q veto. PASS threshold 3.5. All four answers dialect-clean.
FEDERATION NOT PROBED this sweep (4.49944 / 310 row UNCHANGED). PIN Trino 467. DO NOT bump training/state.json (already passed; overall PASS holds).

**HEADLINE: the iter896 `~`/`!~` regex-operator slip = ONE-OFF CONFIRMED, did NOT recur. The slip is CLOSED.**

All dialect facts VERIFIED vs trino.io/docs/467 (regexp / datetime / math / window .html) + Trino git-tag 467 source (SqlBase.g4) via WebFetch/WebSearch 2026-06-10 — NOT against resources/. iter882 verify-first lesson applied (did NOT flag any doc-CORRECT claim as a defect).

---

## Per-question scores

### Q1 — find SKU rows NOT matching 'ABC-1234' (3 upper letters, dash, 4 digits) — 5.00 (Acc 5 / Comp 5 / Clar 5 / Act 5)
Answer: `SELECT sku FROM products WHERE NOT regexp_like(sku, '^[A-Z]{3}-[0-9]{4}$');` with each anchor/quantifier explained.

**`~`-SLIP RE-PROBE RESULT — ONE-OFF CONFIRMED, slip CLOSED.** This Q1 directly re-baited the iter896 mistake (the responder there wrote `phone_number ~ '^\+?1?\d{10}$'`, the PostgreSQL POSIX-regex operator that is a HARD PARSE ERROR in Trino). This time the responder wrote the **correct Trino regex FUNCTION** `regexp_like(sku, ...)` — the `~` operator did NOT reappear. **The iter896 `~`/`!~` slip is a RESPONDER SYNTHESIS ONE-OFF, now CLOSED; NO findability-anchor FIX-A needed; do NOT churn the r23 §3375-3378 `~`/`!~` defang or the regexp_like canonical.**

VERIFIED vs trino.io/docs/467 functions/regexp.html: `regexp_like(string, pattern) -> boolean` is a named function (Trino has no `~` operator); "All of the regular expression functions use the Java pattern syntax." Java regex supports `^`/`$` anchors, `[A-Z]`/`[0-9]` character classes, and `{n}` exact-count quantifiers — so `'^[A-Z]{3}-[0-9]{4}$'` matches exactly 3 uppercase letters, a literal dash, then 4 digits, fully anchored. `NOT regexp_like(...)` correctly inverts to the non-matching rows. Anchoring matters and the responder anchored both ends (without `^...$`, `regexp_like` is contains-by-default and would mis-pass strings like `XABC-1234Y`). Fully correct.

### Q2 — count distinct calendar days with >=1 row in events for a month — 4.9375 (Acc 5 / Comp 4.75 / Clar 5 / Act 5)
Answer: `COUNT(DISTINCT CAST(event_timestamp AS date)) AS days_with_data WHERE event_timestamp >= DATE '2026-01-01' AND event_timestamp < DATE '2026-02-01';` plus a per-day breakdown variant.

VERIFIED vs datetime.html: `CAST(event_timestamp AS date)` is valid (the `date(x)` function is documented as "an alias for `CAST(x AS date)`"), and `DATE 'YYYY-MM-DD'` is a valid date literal. `COUNT(DISTINCT <expr>)` is standard. Casting each timestamp to its calendar date then `COUNT(DISTINCT ...)` yields exactly "number of distinct calendar days that have at least one row." The **half-open range** `>= DATE '2026-01-01' AND < DATE '2026-02-01'` is the correct, sargable, partition-pruning-friendly way to bound a full month (includes Jan 1, excludes Feb 1; no off-by-one, no `BETWEEN ... AND '2026-01-31'` end-of-day trap). Per-day breakdown variant is a nice bonus. Minor completeness nit only (not a defect): could note the cast uses the session time zone, so days are bucketed in session-local time — irrelevant for the question as posed.

### Q3 — second-highest (runner-up) revenue per tier — 5.00 (Acc 5 / Comp 5 / Clar 5 / Act 5)
Answer:
```
SELECT tier, revenue
FROM (SELECT tier, revenue,
             DENSE_RANK() OVER (PARTITION BY tier ORDER BY revenue DESC) AS rank
      FROM subscriptions)
WHERE rank = 2;
```
with a DENSE_RANK-vs-ROW_NUMBER tie explanation.

**The unaliased derived table (FROM-subquery with NO alias) is NOT a defect — Trino 467 ALLOWS it.** Verified-first before flagging (iter882 lesson). The select.html WebFetch was inconclusive (it only showed aliased examples), so I checked the Trino git-tag 467 grammar (`SqlBase.g4`): `aliasedRelation : relationPrimary (AS? identifier columnAliases?)?` — the entire alias group is wrapped in `(...)?`, making the alias **OPTIONAL**, and `relationPrimary` includes the `'(' query ')'` subquery form. So an unaliased FROM-subquery parses fine in Trino, in deliberate contrast to standard SQL / PostgreSQL, which require a derived-table alias. **NOT a defect; NO FIX-A.**

Other parts verified: `WHERE rank = 2` filters a REAL materialized column of the inner subquery (legal — this is the opposite of the iter895 alias-in-WHERE trap, where the responder tried to filter a same-level SELECT alias). `DENSE_RANK() OVER (PARTITION BY tier ORDER BY revenue DESC)` with `rank = 2` returns the **second-highest DISTINCT revenue value** per tier — exactly the intended "runner-up value" semantics. The responder's DENSE_RANK-vs-ROW_NUMBER reasoning is sound: on ties for the top value, ROW_NUMBER would assign 1 and 2 to two rows sharing the top revenue (so rank=2 would return the top value again, not the runner-up), whereas DENSE_RANK gives the genuine second-distinct value. Fully correct.

### Q4 — histogram of orders by dollar bucket ($0-50 / $50-100 / $100-200 / $200+) — 4.875 (Acc 5 / Comp 4.5 / Clar 5 / Act 5)
Answer:
```
CASE width_bucket(order_value, ARRAY[50.0, 100.0, 200.0])
  WHEN 0 THEN '$0-50' WHEN 1 THEN '$50-100'
  WHEN 2 THEN '$100-200' WHEN 3 THEN '$200+' END AS order_range,
COUNT(*) ... GROUP BY width_bucket(...) ORDER BY width_bucket(...)
```

VERIFIED vs math.html: `width_bucket(x, bins) -> bigint`, "Returns the bin number of x according to the bins specified by the array bins"; bins must be ascending. The array-form (0-based) semantics: `operand < bins[0] -> 0`; `bins[i-1] <= operand < bins[i] -> i`; `operand >= bins[last] -> length(bins)`. For `ARRAY[50.0, 100.0, 200.0]`: `<50 -> 0`, `[50,100) -> 1`, `[100,200) -> 2`, `>=200 -> 3`. The responder's bucket→label mapping (0→'$0-50', 1→'$50-100', 2→'$100-200', 3→'$200+') is **correct**. Grouping and ordering by the same `width_bucket(...)` expression (not a SELECT alias) is valid and gives stable ascending bucket order.

Half-open boundary nuance (minor completeness, weighed proportionally — NOT a defect): an order of exactly $50.00 lands in bucket 1 ('$50-100'), and exactly $100 in bucket 2 — so the labels are the conventional half-open histogram labels (`[0,50)`, `[50,100)`, ...). This is the standard and expected convention; the labels are fine as written. One could optionally note "boundaries are inclusive-low / exclusive-high" for a finance audience where a literal $50 order's bucket matters, hence Comp 4.5 rather than 5. No accuracy deduction.

---

## Dialect verification summary (all vs trino.io/docs/467 + git-tag 467 source, WebFetch/WebSearch 2026-06-10)
- regexp.html: `regexp_like(string, pattern) -> boolean` is a FUNCTION; Trino has NO `~`/`!~` operator; Java regex syntax (anchors, `[A-Z]`/`[0-9]`, `{n}`) supported. **`~` slip did NOT recur.**
- datetime.html: `CAST(timestamp AS date)` valid (`date()` = alias); `DATE 'YYYY-MM-DD'` valid literal; half-open month range correct for "distinct calendar days."
- SqlBase.g4 (git-tag 467): `aliasedRelation : relationPrimary (AS? identifier columnAliases?)?` — **FROM-subquery alias is OPTIONAL in Trino** (unaliased derived table is LEGAL; not a Postgres-style mandatory-alias error). `relationPrimary` includes `'(' query ')'`.
- window.html: `dense_rank()` "tie values do not produce gaps"; `row_number()` unique sequential — responder's tie reasoning sound; `rank=2` on the materialized subquery column is a legal real-column filter.
- math.html: `width_bucket(x, bins)` array form returns 0-based bin index per the half-open boundaries above; responder bucket→label mapping correct.

iter882 verify-first applied: did NOT flag any doc-CORRECT claim as a defect. The two "suspicious-looking" structures (Q3 unaliased subquery, Q4 half-open labels) were both verified correct before judgment.

---

## Direction for iter898: DEFAULT NO-OP / re-probe-don't-churn
- All 4 dialect-clean; `~`-slip ONE-OFF CONFIRMED & CLOSED. **NO defect, NO FIX-A, NO escalation; teacher ZERO edits.**
- **NO findability anchor needed** for the `~` slip (it did not recur; the r23 §3375-3378 `~`/`!~` defang + regexp_like canonical are working — do NOT churn them).
- Do NOT add any "wrong" card for Q1-Q4. Do NOT mark the Q3 unaliased-subquery form as wrong — Trino allows it.
- Optional micro-anchors only, and ONLY if they do not churn a pin: Q2 "session-time-zone bucketing of CAST(ts AS date)" near a calendar-day-count card; Q4 "half-open bucket boundaries — exactly $50 lands in the $50-100 bucket" near a width_bucket histogram card. Skip both if they touch an existing pin.
- Re-probe fresh adjacents (4 untested-territory probes) next sweep. Federation remains the only un-passed row (4.49944 / 310) — probe only bulletproofed federation angles if at all.
- Do NOT touch any iter534-896 pin. PIN Trino 467. NO federation edits. DO NOT bump training/state.json (already passed; overall 4.94 PASS holds).
