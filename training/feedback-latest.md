# Judge Feedback — iter863 (EXTENDED PHASE)

**Overall: 4.84 STRONG PASS** (per-Q 4.875 / 5.00 / 4.875 / 4.625 = 19.375/4 = 4.84375; margin +1.34; overall avg governs, no per-Q veto)
**Federation NOT probed** — r22 §13.x untouched, federation row UNCHANGED (4.49944/310, still FAIL).
**iter864 recommendation: DEFAULT NO-OP / durability sweep** — all 4 clean, no defect, no resource edit.

All dialect facts verified against trino.io/docs/467 (comparison.html, window.html, aggregate.html, functions/list.html) + WebSearch, multi-source, PIN 467, 2026-06-10.

---

## HEADLINE

- **Q1 NTILE direction BULLETPROOFED BOTH WAYS.** iter862 proved DESC → bucket 1 = highest; iter863 (this) proves **ASC → bucket 1 = lowest**. 2nd clean datapoint, opposite direction. The iter862 §C3 label-explicit card is durable — no regression.
- **Q3 GREATEST NULL claim is CORRECT for Trino 467** (this was the critical check). The responder's "GREATEST() returns NULL if ANY argument is NULL" is **verbatim accurate** per comparison.html. My standing memory prior (historical Presto "doesn't accept NULL / throws") is OUTDATED for documented 467 behavior — see below. No defect, no FIX-A.

---

## Per-question scoring

### Q1 — NTILE(10) at-risk decile (ASC → bucket 1 = lowest)
Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 4.5 → **4.875**
- `NTILE(10) OVER (ORDER BY health_score ASC) AS risk_bucket`, explicitly ASC → bucket 1 = LOWEST scorers = at-risk. CORRECT.
- VERIFIED window.html: ntile divides ordered rows into n buckets 1..n; buckets numbered in ORDER BY order; example `1 1 2 2 3 4` (larger buckets first). ASC ⇒ lowest rows land in bucket 1. iter862 verbatim-verified this; opposite-direction datapoint now confirms both ways.
- Remainder-rows-to-earliest-buckets note CORRECT; NTILE-takes-no-frame-clause note CORRECT; window-fn-needs-CTE-to-filter (no QUALIFY in 467) CORRECT.
- **NTILE direction = BULLETPROOFED both ways. NO iter864 escalation.**

### Q2 — long→wide pivot (count per status as columns per day)
Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 4.5 → **4.875**
- Both forms valid in 467: `SUM(CASE WHEN status='completed' THEN 1 ELSE 0 END)` conditional aggregation, and `COUNT(*) FILTER (WHERE status='completed')`.
- VERIFIED aggregate.html: FILTER clause documented — "The FILTER keyword can be used to remove rows from aggregation processing with a condition expressed using a WHERE clause", syntax `aggregate_function(...) FILTER (WHERE <condition>)`. FILTER is genuinely Trino-native; the "more readable" framing is fair.
- `SUM(metric) FILTER (...)` for summing a value (not just counting) CORRECT. GROUP BY event_date correct.

### Q3 — GREATEST across columns + NULL behavior (CRITICAL CHECK)
Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 4.5 → **4.875**
- `GREATEST(price_usd, price_eur, price_gbp)` for the largest value across columns in a row. CORRECT.
- **NULL claim CORRECT.** VERIFIED comparison.html (greatest/least live there, NOT conditional.html/math.html): "Returns the largest of the provided values" / "Like most other functions in Trino, they return null if any argument is null", explicitly contrasted with PostgreSQL ("they only return null if all arguments are null"). list.html indexes greatest/least → comparison.html. WebSearch corroborated.
- So the responder's "if ANY argument is NULL, GREATEST() returns NULL" is exactly right, and the COALESCE(col,0)-wrap suggestion to ignore NULLs is the correct mitigation.
- GREATEST (across columns) vs MAX (down rows) vs array_max (within an array) distinction CORRECT; array_max EXISTS (array.html, verified via list.html).
- **NOTE for the loop owner:** my MEMORY/standing prior held that "Trino/Presto GREATEST/LEAST do NOT support NULL the way Postgres does" (historical Presto threw on NULL). That prior is OUTDATED vs documented Trino 467 behavior — 467 docs explicitly say GREATEST/LEAST RETURN NULL on any NULL arg. The run-prompt's suspicion that the responder might be wrong is itself refuted by the docs. NO FIX-A; do not add a "GREATEST throws on NULL" correction card (that would be wrong).

### Q4 — duplicate emails + counts (dedup detection)
Accuracy 5 / Completeness 4 / Clarity 5 / Actionability 4.5 → **4.625**
- `SELECT email, COUNT(*) AS occurrence_count FROM leads GROUP BY email HAVING COUNT(*) > 1 ORDER BY occurrence_count DESC`. Textbook, correct in Trino 467 (HAVING filters post-aggregate; COUNT(*) in HAVING valid).
- Minor completeness ding only: no note on NULL emails (grouped as one bucket) or case/whitespace normalization (LOWER(TRIM(email))) which real dedup often needs — nuance, not an error. Core dedup-detection pattern fully correct and findable.

---

## iter864 recommendation: DEFAULT NO-OP / durability sweep

No defect surfaced. **Teacher: ZERO resource edits.**
- NTILE direction is BULLETPROOFED both ways (iter862 DESC, iter863 ASC) — do NOT churn the §C3 label-explicit card.
- Q3 GREATEST-NULL is correct per 467 docs — **do NOT add a "GREATEST throws on NULL" card** (the historical-Presto prior is wrong for 467).
- FILTER + CASE-WHEN pivot both valid — no edit.
- Optional fresh adjacents to probe (only durability, not fixes): GREATEST/LEAST mixed-type coercion; COALESCE-wrap to make GREATEST ignore NULL (2nd phrasing); pivot with multiple metrics per status; dedup with LOWER(TRIM()) normalization; HAVING vs WHERE on aggregates.
- Do NOT churn any iter534-862 lock. PIN 467. NO federation edits (federation 4.49944/310 row stays FAIL).
- DO NOT bump training/state.json (already 863).

**What the Trino 467 docs say about GREATEST NULL handling (explicit):** comparison.html — "Returns the largest of the provided values. Like most other functions in Trino, they return null if any argument is null." Explicitly contrasted with PostgreSQL, which returns null only if ALL arguments are null. The responder is CORRECT.
