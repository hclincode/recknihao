# Judge Feedback — Iter 813 (EXTENDED PHASE)

**Sweep type:** DEFAULT NO-OP / durability-breadth sweep — teacher made ZERO resource edits; 4 fresh adjacent probes. Federation NOT probed.

**Overall: 4.125 / 5 — PASS** (overall avg governs; threshold ≥ 3.5; no single-Q veto)
Per-Q avgs: Q1 5.00 / Q2 2.00 / Q3 5.00 / Q4 4.50 = 16.50 / 4 = **4.125**.

All dialect claims verified against trino.io/docs/467 (datetime / aggregate / json / math .html) on 2026-06-09.

---

## Q1 — Trailing 7-CALENDAR-day sum, robust to missing days (RANGE-INTERVAL frame)

**Answer:** `SUM(signup_count) OVER (ORDER BY signup_date RANGE BETWEEN INTERVAL '6' DAY PRECEDING AND CURRENT ROW)` — value-based calendar-aware frame, robust to missing days. Cites r07.

| Axis | Score |
|---|---|
| Accuracy | 5 |
| Completeness | 5 |
| Clarity | 5 |
| Actionability | 5 |
| **Avg** | **5.00** |

**Verdict — CORRECT.** Verified against trino.io/docs/467 window-frame semantics: a `RANGE` frame with an `INTERVAL` bound is **value/date-based** — it includes every row whose `ORDER BY` date falls within 6 days of the current row's date, regardless of how many physical rows exist. This is exactly what makes it robust to missing days, unlike a `ROWS BETWEEN 6 PRECEDING` frame which counts physical rows and would silently shorten the window when days are absent. The `INTERVAL '6' DAY PRECEDING ... CURRENT ROW` = 7 calendar days inclusive (current + 6 prior). The ROWS-vs-RANGE distinction is correctly drawn. Clean datapoint for the standing trailing-window / RANGE-INTERVAL topic.

---

## Q2 — Snap reading_time to the NEAREST 5-minute boundary

**Answer:** (a) `date_trunc('minute', reading_time + INTERVAL '2.5' MINUTE / 2) AS snapped_5min`; (b) `from_unixtime(to_unixtime(reading_time) - to_unixtime(reading_time) % 300 + 150) AS snapped_5min`. Claims add-half-then-floor; cites the nearest-hour pattern `date_trunc('hour', ts + INTERVAL '30' MINUTE)`. Cites r07.

| Axis | Score |
|---|---|
| Accuracy | 1.5 |
| Completeness | 2 |
| Clarity | 3 |
| Actionability | 1.5 |
| **Avg** | **2.00** |

**VERDICT — DEFECT. BOTH FORMS ARE WRONG for "nearest 5 minutes." This is the primary finding of the sweep.**

Verified against trino.io/docs/467:

- **Form (a) is garbled on two counts.**
  1. `date_trunc('minute', ...)` truncates to the **MINUTE**, not to a 5-minute boundary. Per trino.io/docs/467/functions/datetime.html, `date_trunc` accepts only fixed units — `millisecond, second, minute, hour, day, week, month, quarter, year` — **there is NO 5-minute unit.** So even after the shift this lands on a 1-minute boundary (e.g. `10:02:00` or `10:03:00`), never on `10:00`/`10:05`. Wrong granularity entirely.
  2. `INTERVAL '2.5' MINUTE` is a **fractional interval literal**; Trino interval literals are integer-valued (docs show `INTERVAL '2' DAY`-style integers only). `'2.5' MINUTE` is at best non-idiomatic and likely a parse-time problem; dividing an interval by a scalar (`INTERVAL ... / 2`) is also dubious. The "add half then floor" intent is right but the construction is malformed.

- **Form (b) lands on the bucket MIDPOINT, not the nearest boundary.**
  Walk it: `to_unixtime(ts)` → epoch seconds (double). `- (… % 300)` **floors** to the start of the 5-minute (300s) bucket. `+ 150` then adds 2.5 minutes → lands on the bucket **midpoint** (always `:02:30`, `:07:30`, …), NOT snapped to the nearest of `:00`/`:05`. For NEAREST rounding you must add half **BEFORE** flooring, not after.

**The CORRECT Trino 467 forms (round-to-nearest-multiple-of-300s):**
```sql
-- Cleanest: round epoch-seconds to the nearest multiple of 300, convert back.
from_unixtime(round(to_unixtime(reading_time) / 300) * 300) AS snapped_5min
-- Equivalent add-half-then-FLOOR (note +150 then % BEFORE subtract):
from_unixtime(to_unixtime(reading_time) + 150 - (to_unixtime(reading_time) + 150) % 300) AS snapped_5min
```
(`round(x)` rounds a double to the nearest integer — verified math.html; `%` works on doubles — verified.)
For reference, **FLOOR**-to-5-min-bucket-start (if that were wanted) is `from_unixtime(to_unixtime(ts) - to_unixtime(ts) % 300)` — i.e. with NO `+150`.

**On the cited nearest-hour pattern:** `date_trunc('hour', ts + INTERVAL '30' MINUTE)` IS correct for hours (r07:1807, the iter631 NEAREST-hour canonical) because an `'hour'` unit exists. But it does **NOT generalize to 5 minutes** — there is no 5-minute `date_trunc` unit. The responder mis-adapted the nearest-hour add-half-then-floor idea onto a tool (`date_trunc('minute')`) that cannot express a 5-minute granularity.

**CONTENT / FINDABILITY GAP — confirmed.** Grepped `resources/07-analytical-query-patterns.md`:
- r07:1807 / 1810-1818 — NEAREST-**hour** canonical (`date_trunc('hour', ts + INTERVAL '30' MINUTE)`). Correct, but hour-only.
- r07:1836-1862 (iter606 LEADING) and r07:1864-1942 (iter715 PIN) — sub-hour **N-minute bucket** cards covering THREE **FLOOR**-to-bucket-start idioms: epoch-floor `to_unixtime(ts) - to_unixtime(ts) % 900`, date_trunc+interval-mod, and floor-to-hour+add-N-steps. The keyword anchor at r07:1832 even literally says **"floor timestamp to nearest 5 minutes"** — but every worked form there is FLOOR (bucket-START), NOT round-to-nearest.

So the resources cover (i) FLOOR-to-N-min and (ii) NEAREST-**hour**, but there is **NO canonical for round-to-nearest-arbitrary-N-minutes** (the `from_unixtime(round(to_unixtime(ts)/N_seconds)*N_seconds)` form). When asked for "nearest 5 min" the responder had no NEAREST-N-min card to land on, so it incorrectly hybridized the nearest-hour shift with a floor-N-min tool. This is both a content gap and a findability trap (the r07:1832 anchor advertises "nearest 5 minutes" but only delivers floor forms).

---

## Q3 — Extract `$.user.address.geo.lat` and `$.items[0].id` from a JSON string

**Answer:** `json_extract_scalar(payload, '$.user.address.geo.lat')`; `json_extract_scalar(payload, '$.items[0].id')`; `json_extract` for nested objects; array index 0-based `$[0]`; CAST scalar results. Cites r13.

| Axis | Score |
|---|---|
| Accuracy | 5 |
| Completeness | 5 |
| Clarity | 5 |
| Actionability | 5 |
| **Avg** | **5.00** |

**Verdict — CORRECT.** Verified against trino.io/docs/467/functions/json.html: `json_extract_scalar(json, json_path)` returns a varchar scalar; deep dot-nesting `$.user.address.geo.lat` and array subscript `$.items[0].id` are both supported, **indexes are 0-based** (docs: "indexes are zero-based", e.g. `$.children[0]`, `$.store.book[0].author`). `json_extract` returns JSON for nested-object/array results. The advice to `CAST` the scalar string to the target numeric type (e.g. `CAST(... AS double)` for `lat`) is correct and useful. Clean datapoint for nested-JSON-path.

---

## Q4 — Build a {rating: count} value-to-count map over a column

**Answer:** `map_agg(rating, count_val)` over a subquery `(SELECT rating, COUNT(*) AS count_val FROM survey GROUP BY rating)` → MAP. Cites r07 map_agg.

| Axis | Score |
|---|---|
| Accuracy | 5 |
| Completeness | 4 |
| Clarity | 4.5 |
| Actionability | 4.5 |
| **Avg** | **4.50** |

**Verdict — CORRECT but INDIRECT (two-step).** Verified against trino.io/docs/467/functions/aggregate.html: `map_agg(key, value)` "returns a map created from the input key/value pairs," so `map_agg(rating, count_val)` over a `(rating, COUNT(*))` GROUP BY subquery does correctly produce `{rating: count}`. Output is right.

**Note — `histogram()` is the purpose-built one-step canonical.** trino.io/docs/467/functions/aggregate.html: `histogram(x) -> map(K, bigint)` "returns a map containing the count of the number of times each input value occurs." So `histogram(rating)` yields `{1:4, 2:10, …}` in ONE step with **no subquery and no GROUP BY**. The responder's answer works and is credited as accurate, but it missed the direct, idiomatic one-liner — hence the completeness/actionability half-dings.

**Findability check:** grep of r07 for `histogram` finds only the **`width_bucket`** numeric-binning material (r07:3750 "Pattern C4", r07:4008 "Pattern C4a fixed-width $N histogram") and `map_agg` (r07:225, 229, 243, 259). The frequency-map aggregate **`histogram(x)`** is NOT present in r07 (the word "histogram" there refers to numeric range-binning, a different concept). So the direct value→count `histogram()` aggregate is a (minor) surfacing gap.

---

## iter814 DESIGNATION — FIX-A (round-timestamp-to-nearest-N-minutes), optional histogram surfacing

The sweep surfaced ONE real defect (Q2) plus one minor completeness/surfacing gap (Q4). Recommend **FIX-A**, scoped tightly:

1. **HIGH — round-timestamp-to-nearest-N-minutes canonical (the Q2 fix).** In `resources/07-analytical-query-patterns.md`, at/near the sub-hour-bucket cards (the iter606 LEADING block r07:1836 and the iter715 PIN block r07:1864), add a **NEAREST-N-minute** canonical distinct from the existing FLOOR-N-min forms:
   - Lead: `from_unixtime(round(to_unixtime(ts) / 300) * 300)` for nearest-5-min; generalize `N_seconds = N*60` (5→300, 10→600, 15→900, 30→1800).
   - Also show the add-half-then-FLOOR epoch form: `from_unixtime(to_unixtime(ts) + 150 - (to_unixtime(ts) + 150) % 300)` — and stress "add half **before** floor."
   - **Defang both responder bugs explicitly** as inline-marked WRONG (un-copyable): (a) `date_trunc('minute', ts + INTERVAL '2.5' MINUTE / 2)` — wrong granularity (no 5-min `date_trunc` unit) + fractional/divided interval literal; (b) `from_unixtime(... - ...%300 + 150)` — `+150` AFTER floor lands on the bucket MIDPOINT, not nearest.
   - **Disambiguate from the existing keyword anchor** at r07:1832 which currently advertises "floor timestamp to nearest 5 minutes" but only delivers FLOOR forms — clarify FLOOR (bucket-start) vs NEAREST (closer boundary) vs CEILING for sub-hour buckets, mirroring the three-way FLOOR/NEAREST/CEILING table that already exists for hours at r07:1806-1808. Place the NEAREST-N-min keywords ("round timestamp to nearest 5 minutes", "snap to nearest 5-minute boundary", "round reading_time to nearest N minutes") on the new card so the responder routes there instead of the floor cards.

2. **OPTIONAL / LOW — surface `histogram()` (the Q4 note).** Near the r07 `map_agg` material (r07:225-259), add a one-line cross-ref: "value→count frequency map in ONE step → `histogram(rating) -> map(K, bigint)`; use `map_agg(k, COUNT(*))` over a GROUP BY subquery only when you need a custom value (not a plain count)." Keyword anchors: "frequency map", "value to count map", "count occurrences of each value as a map". Do this only alongside the Q2 fix; not worth a standalone churn.

**HOLD all standing locks** (iter534-812 inventory: RANGE-INTERVAL window, nested-JSON-path, FLOOR-N-min buckets, nearest-hour, bool_and/bool_or, map_agg, etc.) — Q1/Q3 confirmed clean this sweep; do not churn those cards. Do NOT touch training/state.json (already 813).
