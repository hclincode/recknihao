# Judge Feedback — iter600 (FIX A VALIDATION re-probe)

**Date:** 2026-06-07 · **Phase:** extended · Trino 467 pinned · Docs verified against trino.io/docs/467 + Trino source.

Four everyday-engineer SQL shaping questions: NTILE top-decile FILTER (Q1, the FIX A validation), width_bucket histogram (Q2), date_trunc hour bucket (Q3), format_datetime 'yyyy-MM' label (Q4).

---

## Q1 — NTILE deciles, FILTER to top decile only (FIX A VALIDATION) — **4.875**

Responder: NTILE(10) OVER (ORDER BY order_value) computed inside a CTE `ranked_orders`, then `SELECT ... FROM ranked_orders WHERE value_decile = 10 ORDER BY order_value DESC` in the OUTER query. Explained bucket 10 = highest.

**Verification:**
- trino.io/docs/467/functions/window.html — NTILE: *"Divides the rows for each window partition into `n` buckets ranging from `1` to at most `n`. Bucket values will differ by at most `1`."* Window functions *"execute after the HAVING clause but before the ORDER BY clause"* — i.e. AFTER WHERE. So a window output alias is NOT referenceable in a same-level WHERE.
- **This answer is VALID Trino 467.** The NTILE is computed at the CTE level; the `WHERE value_decile = 10` is in the OUTER query referencing a CTE-projected column. That is exactly the correct outer-wrapper pattern (CTE is one query level out from the window) — NOT a window-fn-in-WHERE-at-same-level error.
- With `ORDER BY order_value` ASCENDING, the highest values land in the last/largest bucket. NTILE(10) → bucket 10 = highest decile. CORRECT. The final `ORDER BY order_value DESC` is presentation-only and fine.

**iter599 SLIP STATUS: RESOLVED.** iter599's Q4 produced an invalid `WHERE spending_tier IS NOT NULL` filtering an NTILE output alias at the SAME SELECT level. This re-probe shows the responder now uses the valid CTE + outer-query-filter wrapper. The FIX A inoculation callout added at r07 Pattern C3 (the WHERE-on-window-alias ban + RIGHT/WRONG outer-wrapper token pair) LANDED. No window-fn-in-WHERE slip recurred.

Scores — Accuracy 5 / Completeness 4.75 / Clarity 5 / Actionability 4.75 → **4.875**

---

## Q2 — width_bucket fixed-width histogram — **4.25** (off-by-one PROSE slip; SQL correct)

Responder: `width_bucket(invoice_amount, ARRAY[50.0,100.0,...,500.0]) AS bucket_id ... GROUP BY bucket_id`. Prose: "0 = below $50, 1 = $50-100, 2 = $100-150, ... up to 9 = $450-$500 and above".

**Verification:**
- trino.io/docs/467/functions/math.html — `width_bucket(x, bins) → bigint`: *"Returns the bin number of `x` according to the bins specified by the array `bins`."* Two overloads documented (equi-width `(x,bound1,bound2,n)` and custom `(x,bins)`). Function EXISTS in Trino 467; not Postgres-only. The chosen overload and SQL are CORRECT and runnable.
- **Bin-numbering (Trino source, MathFunctions.widthBucket Block overload):** binary search returns `lower`, which is 0 when value < bins[0] and `numberOfBins` (= N, the array length) when value >= the last bin. So for a bins array of **N = 10** elements `[50,...,500]`, the result ranges **0..10**: bucket 0 = below 50, bucket k = bins[k-1]..bins[k], and **bucket 10 = >= 500 ($500+)**.
- **OFF-BY-ONE in the PROSE:** The responder said "9 = $450-$500 and above," collapsing two distinct buckets. Correct labeling: **bucket 9 = $450–$500**, **bucket 10 = $500 and above**. The responder's prose loses the $500+ top bucket — which is exactly the bucket the question's "$500+" range names.

**Severity: moderate.** The SQL is fully correct and runnable — the histogram will compute all 11 buckets (0..10) correctly. Only the explanatory mapping is wrong, and it's wrong precisely at the bucket the engineer cares about ($500+). An engineer trusting the prose would mislabel their chart's top bin or write `WHERE bucket_id = 9` thinking it captures $500+ when it actually captures only $450–$500. Accuracy docked.

Scores — Accuracy 3.5 / Completeness 4.5 / Clarity 4.5 / Actionability 4.5 → **4.25**

---

## Q3 — date_trunc('hour', ts) hourly counts — **4.6875**

Responder: `date_trunc('hour', login_timestamp) AS hour_bucket ... GROUP BY date_trunc('hour', login_timestamp)`; noted that for hour-of-day 0–23 use `EXTRACT(HOUR FROM hour_bucket)` or an outer subquery.

**Verification:**
- trino.io/docs/467/functions/datetime.html — `date_trunc(unit, x) → [same as input]`, *"Returns `x` truncated to `unit`"*. `'hour'` is a valid unit. CORRECT and runnable.
- The question mixed two readings: "round timestamp down to its hour" (truncate-to-hour, keeps the date — distinct timestamp per day) vs "per hour-of-day" (0–23 collapsed across all days). The responder LED with truncate-to-hour (matching "round down to its hour") and explicitly offered the `EXTRACT(HOUR FROM ...)` path for the 0–23 reading. Handling the ambiguity by surfacing both is the right call — full marks for disambiguation.
- `EXTRACT(HOUR FROM ...)` is valid Trino 467. CORRECT.

Scores — Accuracy 5 / Completeness 4.75 / Clarity 4.5 / Actionability 4.5 → **4.6875**

---

## Q4 — format_datetime(date, 'yyyy-MM') month label — **3.875** (DATE-type cast gap)

Responder: `format_datetime(subscription_start_date, 'yyyy-MM') AS month_label ... GROUP BY format_datetime(...)`; noted Joda 'yyyy' = 4-digit year, 'MM' = month, lowercase 'mm' = minutes.

**Verification:**
- trino.io/docs/467/functions/datetime.html — `format_datetime(timestamp, format) → varchar`, *"Formats `timestamp` as a string using `format`."* Uses *"a format string that is compatible with JodaTime's DateTimeFormat pattern format."* So `'yyyy-MM'` is the correct Joda pattern → 4-digit year + zero-padded month. The Joda token guidance (yyyy=year, MM=month, lowercase mm=minutes) is CORRECT and a genuinely useful footgun warning. `date_format(timestamp, format)` is the documented MySQL-style alternative — responder mentioned date_format as the alternative.
- **GAP — DATE input type:** The signature is `format_datetime(timestamp, ...)`, NOT date. The question explicitly says "a **date** column." Trino does NOT auto-coerce DATE→TIMESTAMP for this function; passing a true DATE column raises a function-resolution error ("Unexpected parameters / function not registered for (date, varchar)"). The DATE-safe forms are `format_datetime(CAST(subscription_start_date AS timestamp), 'yyyy-MM')`, or the simpler `substr(CAST(subscription_start_date AS varchar), 1, 7)` (a DATE casts to 'YYYY-MM-DD'). The responder did NOT note the cast, so the literal copy-paste FAILS if the column is genuinely typed DATE. Note: many "date" columns in lakehouse tables are actually TIMESTAMP, in which case it runs as-written — but the question said DATE, so the cast caveat is required for correctness.

**Severity: moderate.** Correct function, correct format pattern, excellent Joda token note — but the literal SQL can fail on a true DATE column, and the question named DATE explicitly. The simplest robust answer for a DATE column is the `substr(CAST(d AS varchar),1,7)` idiom (which the resources already document at r10:1439) — that would have been the cleanest, cast-free 'YYYY-MM' answer.

Scores — Accuracy 3.5 / Completeness 3.75 / Clarity 4.5 / Actionability 3.75 → **3.875**

---

## OVERALL

| Q | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|
| Q1 | 5.0 | 4.75 | 5.0 | 4.75 | 4.875 |
| Q2 | 3.5 | 4.5 | 4.5 | 4.5 | 4.25 |
| Q3 | 5.0 | 4.75 | 4.5 | 4.5 | 4.6875 |
| Q4 | 3.5 | 3.75 | 4.5 | 3.75 | 3.875 |
| **Dim avg** | **4.25** | **4.4375** | **4.625** | **4.375** | |

**Overall = (4.25 + 4.4375 + 4.625 + 4.375) / 4 = 4.421875 → PASS** (>= 3.5).

No per-question quality-gate override applied; the overall average governs the label. Quality concerns (Q2 off-by-one prose, Q4 DATE-cast gap) flagged separately below.

---

## EXPLICIT: iter599 NTILE WHERE-on-window-alias slip — **RESOLVED**

Q1 of this re-probe shows the valid CTE/outer-wrapper form: NTILE in the CTE, decile-alias filter in the OUTER query. There is NO same-level `WHERE <window-alias>` error. The iter600 FIX A inoculation callout at r07 Pattern C3 LANDED. The iter599 slip is resolved and did not recur.

---

## DIAGNOSIS + iter601 TEACHER ACTIONS

### Q2 off-by-one prose (PRIMARY) — diagnosis: **resource-defect / content-incompleteness at the landing point**
The responder routed correctly to width_bucket (r07 Pattern C4, ~line 1798) and wrote correct SQL, but its bucket-numbering NARRATION is off by one at the top bin. This is a resource-content clarity gap: the C4 content evidently does not nail the **0..N** numbering crisply enough for the responder to narrate it. Precise fix for iter601:

- **Where:** resources/07-analytical-query-patterns.md, Pattern C4 width_bucket canonical (~line 1798).
- **What to add (reconcile-in-place, do NOT rewrite C4):** an explicit worked numbering line for the array overload. For an N-element bins array, results span **0..N**:
  - `width_bucket(x, ARRAY[50,100,...,500])` with **10** bounds → buckets **0..10**.
  - bucket **0** = `x < 50`; bucket **k** = `bins[k-1] <= x < bins[k]`; bucket **N (=10)** = `x >= 500` (the open-ended top "$500+" bin).
  - One-line trap callout: "the top bucket is **N**, NOT N-1 — the last array element opens a new bucket above it; do NOT fold '$500 and above' into bucket 9." Verified against Trino source MathFunctions.widthBucket (Block overload returns `numberOfBins` when value >= last bin) since trino.io/docs/467/functions/math.html does not spell out the edge cases.

### Q4 DATE-input cast gap (SECONDARY) — diagnosis: **routed-but-mis-applied + landing-point-miss**
The responder found format_datetime/date_format (r23 §dual-table, ~line 382-395) but did not surface the **DATE-type requires CAST** caveat, even though the cleaner cast-free idiom `substr(CAST(d AS varchar),1,7)` already exists at r10:1439. The format_datetime/date_format landing point does not warn that both require a TIMESTAMP and that a DATE column needs `CAST(d AS timestamp)`. Precise fix for iter601:

- **Where:** resources/23-sql-best-practices-olap.md, the date_format/format_datetime dual-function table (~line 382-395).
- **What to add (reconcile-in-place):** a short type-note row: "Both `format_datetime(timestamp, fmt)` and `date_format(timestamp, fmt)` require a **TIMESTAMP** input. A **DATE** column does NOT auto-coerce — wrap it: `format_datetime(CAST(d AS timestamp), 'yyyy-MM')`. For a plain 'YYYY-MM' label, the cast-free shortcut is `substr(CAST(d AS varchar), 1, 7)` (a DATE renders as 'YYYY-MM-DD'); cross-ref r10:1439." Verified: signature is `format_datetime(timestamp, format)` per trino.io/docs/467/functions/datetime.html; DATE input raises a function-resolution error (date != timestamp distinctness, multiple Trino issue threads).

### Q1, Q3 — no action needed
Q1 FIX A validated. Q3 disambiguation handled cleanly.

---

## NEW FABRICATION / SLIP FLAGS

- **No fabricated functions or absences.** width_bucket, date_trunc, format_datetime, date_format, EXTRACT all real and correctly used in Trino 467.
- **No `::`-cast, no QUALIFY, no window-fn-in-WHERE.** The Q1 outer-wrapper is the correct no-QUALIFY pattern.
- **Two prose/completeness slips (NOT fabrications):** Q2 width_bucket top-bucket off-by-one in narration (SQL correct); Q4 missing DATE→timestamp cast caveat (SQL fails on a true DATE column). Both are landing-point clarity gaps for iter601, addressed above. Neither sank the overall PASS but both should be closed — these are exactly the confident-but-wrong micro-details that erode trust at 250+ datapoints.
