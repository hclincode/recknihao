# Iter528 Judge Feedback — 2026-06-06 (EXTENDED PHASE)

## Overall result: **4.9063 STRONG PASS** (margin +1.4063 above 3.5 floor)

Federation NOT probed — row stays **4.49944/310** (no edits to resources/22 §13.x guardrails).

---

## Headline result

**Both iter528 family-canonical teacher fixes LANDED on first re-probe.** No new fab-absence surfaced this iter. The recurring fab-absence pattern (iter505 split_to_map → iter517 contains → iter520 CAST(map AS JSON) → iter520 string_agg → iter522 try() → iter524 WITH ORDINALITY + approx_distinct(x,e) → iter526 width_bucket → iter527 map_filter) **WAS BROKEN this iteration** by switching strategy from single-function leading canonicals to whole-FAMILY canonicals. Q1 (MAP HOF family) and Q2 (ARRAY HOF family) both probed the freshly-added r09 and r07 §1a.4 canonicals and the responder routed correctly in both cases without hedging.

---

## Per-question scores

### Q1 — MAP(VARCHAR, BOOLEAN) settings → list of keys where value is true, WITHOUT unnesting (LOAD-BEARING re-probe of iter527 Q3 fab-absence + iter528 FIX A): **4.8125 STRONG PASS**

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | `map_keys(map_filter(notification_settings, (k, v) -> v))` is exactly canonical Trino 467. Verified verbatim at trino.io/docs/current/functions/map.html: `"map_filter(map(K, V), function(K, V, boolean)) → map(K, V)"` and `"Constructs a map from those entries of map for which function returns true"`, plus `"map_keys(x(K, V)) → array(K)"`. The optional `(k,v) -> v = 'true'` callout for VARCHAR-encoded booleans is a correct and useful caveat. NO fab-absence. |
| Beginner clarity | 4.5 | Step-by-step "map_filter keeps true-valued entries, map_keys extracts keys" explains the composition cleanly. One row in / one row out framing emphasizes the no-UNNEST property. |
| Practical applicability | 5.0 | Exactly the one-liner the engineer needs. Cites r09 map-HOF canonical so the engineer knows where the family lives. |
| Completeness | 4.75 | Hits the headline answer + the VARCHAR variant. Could optionally mention `map_values(map_filter(...))` if the engineer needs the booleans back too, but non-load-bearing. |

**ITER527 Q3 FAB-ABSENCE GONE.** The iter527 denial `"there is no built-in Trino function to filter a map directly without unnesting it"` is dead. The iter528 r09 MAP HOF family canonical (`map_filter` / `map_keys` / `map_values` / `transform_keys` / `transform_values`) **LANDED on first re-probe**.

---

### Q2 — ARRAY(DECIMAL) line_item_prices → (a) per-element ×1.08, (b) sum scalar, both WITHOUT unnesting (LOAD-BEARING re-probe of iter528 FIX B pre-emption): **4.9375 STRONG PASS**

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | (a) `transform(line_item_prices, p -> p * DECIMAL '1.08')` is exactly canonical. Verified verbatim at trino.io/docs/current/functions/array.html: `"transform(array(T), function(T, U)) → array(U)"` "Returns an array resulting from applying a function to each element." Returns ARRAY(DECIMAL) confirmed. (b) `reduce(line_item_prices, DECIMAL '0.00', (total, price) -> total + price, total -> total)` is exactly canonical — verified verbatim 4-arg signature `"reduce(array(T), initialState S, inputFunction(S, T, S), outputFunction(S, R)) → R"`. Init state `DECIMAL '0.00'`; input function `(s,x)->s` adds price; output function `s->s` returns final sum. All four arguments correctly typed. NO fab-absence. |
| Beginner clarity | 4.75 | "in-array, no UNNEST" explicitly framed; lambda `x -> expr` syntax used cleanly without ceremony; identity output function `total -> total` is the slightly subtle bit but reasonable inline. |
| Practical applicability | 5.0 | Two one-liners ready to drop into a SaaS query. Cites r07 §1a.4 so the engineer knows where the ARRAY HOF family canonical lives. |
| Completeness | 5.0 | Both subparts answered with the correct primitive — `transform` for per-element, `reduce` for scalar fold. No unnecessary detail. |

**ITER528 FIX B PRE-EMPTED THE NEXT PREDICTABLE FAB-ABSENCE.** The iter527 fab-absence pattern would have predicted a "Trino has no built-in transform/filter/reduce over arrays" denial when the array-HOF family came up. **DID NOT happen.** r07 §1a.4 ARRAY HOF family canonical (`transform` / `filter` / `reduce 4-arg` / `any_match` / `all_match` / `none_match` / `array_sort` / `zip` / `zip_with`) **LANDED on first re-probe**.

---

### Q3 — ROW_NUMBER vs RANK vs DENSE_RANK tie handling, rank customers by spend: **5.000 STRONG PASS**

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | All three exist in Trino 467 (verified at trino.io/docs/current/functions/window.html). Responder's table is correct: ROW_NUMBER 1,2,3,4 (no ties, no gaps); RANK 1,2,2,4 (ties same rank, then gap of 1); DENSE_RANK 1,2,2,3 (ties same rank, no gap). Verbatim doc support: RANK `"tie values in the ordering will produce gaps in the sequence"`; DENSE_RANK `"tie values do not produce gaps in the sequence"`; ROW_NUMBER `"a unique, sequential number for each row, starting with one, according to the ordering of rows within the window partition"`. |
| Beginner clarity | 5.0 | Worked example with concrete numbers; guidance on which to pick for which use case; clean explanation of "gap" vs "no gap" with the contrast highlighted. |
| Practical applicability | 5.0 | Engineer can directly pick the right function for their "rank customers by spend" question. |
| Completeness | 5.0 | All three covered + tie semantics + use-case guidance. |

---

### Q4 — Unix epoch BIGINT → timestamp (for date_trunc/comparisons) and timestamp → epoch: **4.875 STRONG PASS**

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | `from_unixtime(epoch_seconds) → timestamp(3) with time zone` verified verbatim at trino.io/docs/current/functions/datetime.html (`from_unixtime(unixtime) → timestamp(3) with time zone`, "interpreted as the number of seconds since 1970-01-01 00:00:00 UTC"). `to_unixtime(ts) → double` verified verbatim (`to_unixtime(timestamp) → double` "Returns timestamp as a UNIX timestamp"). The `EXTRACT(EPOCH FROM ts) NOT supported` claim is CORRECT — Trino's documented EXTRACT field list is YEAR, QUARTER, MONTH, WEEK, DAY, DAY_OF_MONTH, DAY_OF_WEEK, DOW, DAY_OF_YEAR, DOY, YEAR_OF_WEEK, YOW, HOUR, MINUTE, SECOND, TIMEZONE_HOUR, TIMEZONE_MINUTE — **EPOCH is not in the list**; the engineer's likely Postgres muscle-memory is correctly redirected to `to_unixtime`. `date_diff('second', ...)` for durations is the canonical Trino pattern. BIGINT-to-DOUBLE coerces cleanly into `from_unixtime`. |
| Beginner clarity | 4.75 | Bidirectional examples + the "Postgres-ism" callout + date_diff recommendation are all engineer-friendly. Could optionally mention millisecond epochs need `from_unixtime(ms/1000)` divide — non-load-bearing. |
| Practical applicability | 5.0 | Two one-liners + downstream date_trunc/date_diff guidance is exactly what a SaaS engineer porting epoch-millis from app code needs. Cites r13. |
| Completeness | 4.75 | Covers both directions + the Postgres EXTRACT-EPOCH trap + duration arithmetic. Doesn't explicitly say `from_unixtime` returns `timestamp(3) with time zone` (vs `timestamp(3)` without tz) — minor zone-awareness gap that could matter for some date_trunc edge cases, non-load-bearing. |

---

## Iter528 outcomes

- **Q1 outcome**: r09 MAP HOF family canonical **LANDED**. Iter527 Q3 fab-absence GONE. Confirmed via verbatim trino.io/docs/current/functions/map.html quote: `"map_filter(map(K, V), function(K, V, boolean)) → map(K, V)"`.
- **Q2 outcome**: r07 §1a.4 ARRAY HOF family canonical **LANDED**. Pre-emptive fab-absence DID NOT surface. Confirmed via verbatim trino.io/docs/current/functions/array.html quote (incl. 4-arg reduce signature `"reduce(array(T), initialState S, inputFunction(S, T, S), outputFunction(S, R)) → R"`).
- **Q3 outcome**: Window ranking canonicals continue to land cleanly across phrasings.
- **Q4 outcome**: Epoch ↔ timestamp canonicals (r13) land cleanly. EXTRACT-EPOCH-NOT-SUPPORTED Postgres-ism caveat is correct and well-placed.

**Recurring fab-absence pattern: BROKEN this iter.** Strategy shift from single-function leading canonical to whole-FAMILY canonical worked on first probe across BOTH freshly-added families. This is the cleanest no-fab-absence iter since iter525.

**No new fabrications surfaced.**

---

## Next-teacher actions for iter529 (LOW PRIORITY — all four iter528 dims passed strong)

All three iter528 fixes landed clean; no new gaps. Optional low-risk polish only:

1. **POLISH (non-load-bearing)** — r13 epoch block could add a one-line callout for millisecond epochs `from_unixtime(epoch_ms / 1000)` since SaaS app code often stores Unix epoch in milliseconds (Java `System.currentTimeMillis()`, JS `Date.now()`). LOW priority, no FAIL risk if skipped.
2. **POLISH (non-load-bearing)** — r13 epoch block could note that `from_unixtime(...)` returns `timestamp(3) with time zone` (not naive `timestamp(3)`); if the engineer wants a naive timestamp for partition keys, they'd `CAST(from_unixtime(epoch) AS timestamp(6))`. LOW priority.

## Iter529 judge probe targets

- **MAP HOF family 2nd angle (HIGH)** — "transform map values in place via a lambda (e.g. multiply all numeric values by 1.1)" — probes `transform_values` route from the r09 MAP HOF family canonical. Verifies the family canonical covers HOFs beyond `map_filter` + `map_keys`. **Highest-value next probe** because it tests whether the family canonical is durable across DIFFERENT map HOFs, not just the iter527 worked example.
- **ARRAY HOF family 2nd angle (HIGH)** — "filter an ARRAY(VARCHAR) to entries matching a LIKE predicate, without UNNEST" — probes `filter(array, x -> x LIKE 'foo%')` route from the r07 §1a.4 array HOF family canonical. Verifies the family canonical lands on `filter` (not just `transform`/`reduce`).
- **ARRAY HOF any_match / all_match (HIGH)** — "does ANY element of `tags` array match a predicate?" — probes whether the family canonical surfaces `any_match`/`all_match`/`none_match` as the canonical (vs the easy-to-fab UNNEST + EXISTS workaround).
- **MAP HOF transform_keys 2nd angle (MEDIUM)** — "rename all keys in a MAP to lowercase" — probes `transform_keys` route, verifies the family canonical covers transform_keys.
- **Epoch conversion 2nd angle (MEDIUM)** — "I store Unix epoch in MILLISECONDS — how do I get a timestamp?" — probes whether the responder offers the `/1000` divide pattern or hedges. Hits the polish gap above.
- **ROW_NUMBER/RANK/DENSE_RANK 3rd angle (LOW)** — well-bulletproofed.
- **Federation stays UNPROBED (LOW)** — row stays 4.49944/310 per locked directive.

---

## Streak

**124th consecutive overall PASS in extended phase** (iter525 4.984 → iter526 4.1875 → iter527 3.781 → **iter528 4.9063**, net swing +1.125 from iter527 because both family canonicals carried Q1+Q2 to strong-pass + Q3+Q4 stable). Strongest iter since iter525 (4.984). Iter524's first FAIL of the streak is now 4 iters back; the family-canonical strategy looks like the right durable fix for the recurring fab-absence class.

**38th consecutive leading-canonical bulletproofing landing instance** (iter528's r09 MAP HOF family + r07 §1a.4 ARRAY HOF family both landed on first re-probe — rare double-family-land in single iter).
