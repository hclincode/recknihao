# Iter290 Q1 Score — DATE()/CAST() vs date_trunc Iceberg partition pruning (Trino 467)

## Overall: 2.88 / 5.0 — FAIL (below 3.5 pass threshold)

## Per-dimension scores

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | **2** | Central claim about date_trunc is wrong for Trino 467 |
| Beginner clarity | **4** | Well-written, clear examples, jargon explained |
| Practical applicability | **3** | TIMESTAMP-range recommendation is still safe and actionable, but the wrong rationale undermines trust |
| Completeness | **3** | Distinguishes DATE/CAST vs date_trunc and gives a recommendation, but the distinction itself is incorrect |

**Average: (2 + 4 + 3 + 3) / 4 = 3.00 → FAIL**

---

## CRITICAL ERROR — date_trunc IS unwrapped in Trino 467

The answer states:

> "`date_trunc('day', event_at)` is truly non-invertible and breaks pruning"
> "`date_trunc` is different: it is not invertible... Trino cannot unwrap this and falls back to scanning all files"

And the bad-patterns table lists `date_trunc('day', event_at) = ...` as "Non-invertible → full table scan".

**This is incorrect for Trino 467.**

Verified against:
1. **trino.io/blog/2023/04/11/date-predicates.html** (Trino's own blog, "Just the right time date predicates with Iceberg"):
   > "For `date_trunc('day', event_time) = DATE '2022-01-20'`, Trino similarly replaces the initial temporal filter to a filter testing whether the column `event_time` is within the constant timestamp range."
2. **trinodb/trino PR #14011** ("Simplify predicates involving date_trunc"): introduced the `UnwrapDateTruncInComparison` optimizer rule that transforms `date_trunc` comparisons into range predicates suitable for Iceberg's manifest min/max pruning.

So in Trino 467, `WHERE date_trunc('day', event_at) = DATE '2026-05-01'` IS unwrapped into a `event_at >= TIMESTAMP '2026-05-01' AND event_at < TIMESTAMP '2026-05-02'` form, and Iceberg partition pruning works.

The genuine nuance the answer missed:
- `UnwrapDateTruncInComparison` covers `date` and `timestamp` (without time zone).
- For `timestamp with time zone`, the engine-level rule cannot help (because `date_trunc` operates on local time), but the Iceberg connector specifically mitigates this since Iceberg stores all `timestamp with time zone` values in UTC. PR #14011 explicitly notes this Iceberg-specific handling.

So both DATE/CAST and date_trunc are in the same "Trino can unwrap this" bucket for the production stack (Trino 467 + Iceberg). The answer treats them as opposite categories, which is wrong.

---

## What was correct

- `DATE(x)` = `CAST(x AS DATE)` — correct, they are aliases.
- `UnwrapCastInComparison` handles DATE/CAST predicates and enables Iceberg partition pruning — correct.
- TIMESTAMP-range form is the safe, version-independent defensive pattern — correct and excellent guidance.
- `timestamp with time zone` is the genuine edge case to check with EXPLAIN — correct (and ironically the same caveat applies to date_trunc, which the answer didn't catch).
- `constraint on [event_at]` in TableScan vs `ScanFilterProject` as the pruning verification signal — correct and verified against Trino EXPLAIN output discussions on GitHub issues.
- Truly non-invertible functions for pruning: `LOWER(email)`, `SUBSTR(col, 1, 2)` — correct.
- `year(event_at)`, `month(event_at)` as risky/breaking — correct in general (these are not covered by an unwrap rule the same way date_trunc is).

---

## What was wrong / missing

1. **WRONG**: `date_trunc('day', event_at)` listed as a pruning-breaker. It is unwrapped in Trino 467 for `timestamp` columns and (via Iceberg-specific handling) for `timestamp with time zone`.
2. **MISSING**: The asymmetry the answer claims between DATE/CAST and date_trunc does not exist in Trino 467. Both are unwrapped; the real categories are "unwrap rule exists" vs "no unwrap rule" (year/month/LOWER/SUBSTR/non-monotonic transforms).
3. **MISSING**: The same `timestamp with time zone` caveat the answer correctly raised for DATE/CAST also applies to date_trunc — even more strongly, since the engine rule alone cannot help and the Iceberg connector handling is what saves it. The answer doesn't connect these two.
4. **MISSING**: The Trino blog post (cited in the answer for DATE/CAST) is the same source that covers date_trunc — the answer should have noticed.

---

## Topic / rubric update

**SQL query best practices for OLAP** — previously PASSED at 4.19 avg across 2 questions after iter289.
- New running avg: (3.50 + 4.88 + 3.00) / 3 = 11.38 / 3 = **3.79 across 3 questions**.
- Still above the 3.5 pass threshold, but a second consecutive answer has gotten the date_trunc / unwrap distinction wrong (iter289 Q1 got DATE/CAST wrong; iter290 Q1 gets date_trunc wrong). The topic shows a recurring failure mode around the unwrap optimizer rules.

---

## Feedback for teacher (extended-phase, end-of-iteration)

Resource 23 section 6 was corrected after iter289 Q1 to fix the DATE/CAST claim — but the correction over-rotated by labeling `date_trunc` as a pruning-breaker. That is wrong for Trino 467. The resource needs a unified treatment:

- Both `UnwrapCastInComparison` AND `UnwrapDateTruncInComparison` exist in Trino 467.
- DATE(x), CAST(x AS DATE), and date_trunc('day', x) all get unwrapped into TIMESTAMP-range predicates and DO enable Iceberg partition pruning on `timestamp` columns.
- The genuine pruning-breakers are: year(), month(), day_of_week(), non-monotonic time extractions, LOWER(), SUBSTR(), arithmetic that isn't a simple monotonic transform.
- For `timestamp with time zone`: DATE/CAST has known limitations (engine rule may not help); date_trunc on TZ-typed columns relies on Iceberg-specific connector handling (works because Iceberg stores TZ values as UTC). EXPLAIN verification is the safe answer.
- TIMESTAMP-range form remains the recommended defensive production pattern regardless — that part of the answer is good.

Sources to cite in the resource:
- https://trino.io/blog/2023/04/11/date-predicates.html
- https://github.com/trinodb/trino/pull/14011
- https://github.com/trinodb/trino/issues/12925
