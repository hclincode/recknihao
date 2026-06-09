# Judge Feedback — iter862

**Overall: 4.78125 — STRONG PASS** (Q1 5.00 / Q2 4.625 / Q3 5.00 / Q4 4.50)

Phase: extended. LIGHT FIX-A verification of the iter861 Q3 NTILE-inversion defect.
All four answers are pure-SQL, dialect-only; on-prem Trino 467 + Iceberg + MinIO (JWT/OPA) unaffected.
All dialect claims docs-verified vs trino.io/docs/467 (window / datetime / math / conditional .html) + WebFetch 2026-06-10, Trino 467 pinned, multi-source.

**HEADLINE: the iter861 Q3 NTILE-direction FIX LANDED.**

---

## Q1 — Split customers into 5 equal groups by lifetime spend, group 1 = HIGHEST (VIP tier)
**Sub-scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 — avg 5.00 CLEAN**

This is the iter861 Q3 NTILE-inversion fix RE-PROBE, and the **fix LANDED**.

Responder answered `NTILE(5) OVER (ORDER BY total_spend DESC) AS tier`, and — critically — explicitly stated that **the SORT DIRECTION determines which bucket is tier 1**: you want highest, so sort `DESC`, which makes **tier 1 = top 20% / biggest spenders** and tier 5 = bottom 20%. Also noted remainder rows go to the earliest buckets.

VERIFIED vs trino.io/docs/467 functions/window.html (verbatim):
- "Divides the rows for each window partition into `n` buckets ranging from `1` to at most `n`. Bucket values will differ by at most `1`."
- Uneven division verbatim: "the remainder values are distributed one per bucket, starting with the first bucket."
- Example: "with `6` rows and `4` buckets, the bucket values would be as follows: `1` `1` `2` `2` `3` `4`" (larger buckets first, in ORDER BY order).

Buckets are numbered 1..n in ORDER BY order. `ORDER BY total_spend DESC` => the highest values sort first => land in bucket 1. The responder's direction is now CORRECT and the explanation is label-explicit (it ties the DESC choice directly to "tier 1 = top"). This is the exact inverse of the iter861 Q3 error ("bucket 1 = top under ASC"), which is now gone. The remainder-to-earliest-buckets note also matches the docs. **Fix CONFIRMED LANDED.**

---

## Q2 — Duration between started_at and finished_at as plain minutes/hours
**Sub-scores: Accuracy 5 / Completeness 4 / Clarity 5 / Actionability 4.5 — avg 4.625**

Responder answered `date_diff('minute', started_at, finished_at) AS duration_minutes` and `date_diff('hour', started_at, finished_at) AS duration_hours`; result is BIGINT; put the earlier timestamp first or you get a negative.

VERIFIED vs trino.io/docs/467 functions/datetime.html:
- Signature `date_diff(unit, timestamp1, timestamp2)`, returns **bigint**.
- "Returns `timestamp2 - timestamp1` expressed in terms of `unit`" => timestamp1 earlier yields a positive result. Responder's earlier-first guidance is correct.
- `'minute'` and `'hour'` are valid units (millisecond/second/minute/hour/day/week/month/quarter/year).

CORE CORRECT. **Non-blocking completeness gap (the truncation nuance):** `date_diff` counts whole-unit boundaries and **truncates** — a 90-minute gap in `'hour'` returns **1, not 1.5**. The responder did not flag this. A SaaS engineer expecting a fractional "1.5 hours" duration would be silently surprised. The clean fractional-hours path is `date_diff('second', started_at, finished_at) / 3600.0` (or `/ 60.0` for fractional minutes). Minor deductions on Completeness/Actionability only; the integer-boundary core is correct and is what most callers want.

---

## Q3 — Each row's value as a percent of the overall total, in one query
**Sub-scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 — avg 5.00 CLEAN**

Responder answered `ROUND(100.0 * revenue / SUM(revenue) OVER (), 2) AS pct_of_total`; explained that the empty `OVER ()` computes the grand total repeated on every row, and that `100.0` (not `100`) forces decimal division else integer division truncates.

VERIFIED vs trino.io/docs/467:
- window.html: "All Aggregate functions can be used as window functions by adding the `OVER` clause." Empty `OVER ()` (no PARTITION BY / no ORDER BY / no frame) => the frame is all rows => `SUM(revenue) OVER ()` is the grand total repeated on every row. Valid window usage, correct.
- math.html: "Division (integer division performs truncation)" — confirms all-integer operands (`100 * revenue / SUM(...)`) would truncate. Promoting one operand to decimal/double (`100.0`) makes the whole division non-integer. The `100.0`-not-`100` caveat is correct and well-explained.

Clean, well-reasoned, no gaps.

---

## Q4 — First non-null of preferred_email, backup_email, work_email in one expression
**Sub-scores: Accuracy 5 / Completeness 4 / Clarity 5 / Actionability 4 — avg 4.50**

Responder answered `COALESCE(preferred_email, backup_email, work_email) AS contact_email`; returns the first non-null, NULL if all null; cleaner than nested IF.

VERIFIED vs trino.io/docs/467 functions/conditional.html (verbatim):
- "Returns the first non-null `value` in the argument list. Like a `CASE` expression, arguments are only evaluated if necessary." Variadic (`value1, value2[, ...]`). Returns NULL if all are NULL.

CORE CORRECT. **Non-blocking completeness gap (empty-string vs NULL):** the question said "some rows have preferred_email filled in, some don't." If "don't" means an **empty string `''`** rather than NULL, COALESCE will NOT skip it — `COALESCE('', backup_email)` returns `''`, not the backup. COALESCE only treats NULL as absent. A short note ("if blank fields are `''` not NULL, wrap each with `NULLIF(preferred_email,'')`") would have made this bulletproof against real-world data where empty strings are common. COALESCE is the correct core answer; minor Completeness/Actionability deductions only.

---

## Verdict & iter863 recommendation

**Overall 4.78125 = STRONG PASS** (threshold 3.5; no per-question veto). Every dialect fact verified accurate against trino.io/docs/467.

- (a) **Q1 NTILE direction fix LANDED** — responder now uses `ORDER BY ... DESC` for bucket 1 = highest and explains the direction-to-label tie explicitly. The iter861 Q3 inversion is fixed (1st post-fix datapoint on the VIP/quintile/highest phrasing; needs 1 more angle — e.g. an ASC "bottom decile / lowest-N" phrasing, or a label-mismatch trap — to fully bulletproof the C3 direction card).
- (b) **Q2 date_diff correct**; whole-unit truncation IS worth a one-line note (90 min in hours = 1 not 1.5) — minor completeness only, not a defect.
- (c) **Q3 SUM() OVER () percent-of-total + integer-division caveat fully correct** — clean.
- (d) **Q4 COALESCE correct**; empty-string-vs-NULL (`NULLIF(x,'')`) was a reasonable completeness note given the "some don't have it" phrasing — minor only, not a defect.

**No defect surfaced. No fabrication, no wrong signature, no crossed-family error, no findability slip, no prod-env conflict.**

**iter863 = DEFAULT NO-OP / durability sweep.** No resource edit warranted. Recommended probes:
- Re-probe NTILE direction from a 2nd angle (ASC "bottom/lowest band" or a deliberately-mislabeled trap) to bulletproof the iter862 label-explicit C3 card.
- Optional fresh adjacents only: `date_diff` fractional-duration phrasing (does the responder reach for `/3600.0`?); COALESCE-with-empty-string phrasing (does it reach for `NULLIF`?). Escalate to a LIGHT FIX-A ONLY if either dings below threshold on a 2nd datapoint — neither is warranted now (single clean datapoints).
- PRESERVE iter862 label-explicit NTILE-direction C3 card + full iter534-861 pin inventory; NO federation edits (federation stays 4.49944/310).

DO NOT bump training/state.json (already 862).
