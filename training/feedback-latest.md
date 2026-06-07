# Iter 646 — Judge Feedback

## Overall verdict

**Overall average: 4.4375 — PASS** (>= 3.5 floor by +0.9375 margin)

Per-dimension cross-check matches the per-Q average.

---

## Per-question scores

### Q1 — Count events in 5-minute buckets

**Score: 4.875 STRONG PASS** (Acc 5.0 / Comp 5.0 / Clar 4.5 / Act 5.0)

Responder produced the docs-correct N-minute floor idiom:
`date_trunc('hour', event_ts) + INTERVAL '1' MINUTE * (CAST(EXTRACT(minute FROM event_ts) AS integer) / 5 * 5) AS bucket_5min`
plus the repeat-the-expression GROUP BY (alias not allowed).

VERIFIED against trino.io/docs/467/functions/datetime.html:
- date_trunc supports only fixed units (millisecond/second/minute/hour/day/week/month/quarter/year) — NO `'5 minute'` custom unit. Responder correctly inoculated this.
- EXTRACT returns bigint; CAST to integer for integer division is the docs-correct pattern.
- Integer-division floor arithmetic: 37 -> 37/5*5 = 35, 14 -> 10, 4 -> 0 — verified correct.
- Repeat-the-expression-in-GROUP-BY (alias-in-GROUP-BY not permitted in Trino due to issue #16533) correctly noted.

Routes via r07:1309-1341 N-min-truncation canonical (iter606 PIN). Minor -0.5 Clarity for slightly dense one-liner without a worked numeric example trace in the answer body, but the resource backing is solid.

### Q2 — Running balance per account

**Score: 5.0 STRONG PASS** (Acc 5.0 / Comp 5.0 / Clar 5.0 / Act 5.0)

Textbook cumulative-sum window:
`SUM(amount) OVER (PARTITION BY account_id ORDER BY txn_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_balance`

VERIFIED:
- PARTITION BY account_id keeps the running total per-account (multi-tenant SaaS pattern from r07 §5 Pattern A).
- ORDER BY txn_date orders the cumulative accumulation chronologically.
- Explicit ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW frame is the row-by-row accumulation (default would be RANGE which groups same-date peers into one cumulative value — the explicit ROWS handles each row separately). Responder correctly noted the same-date tiebreaker caveat.

Cleanly composes from r07:1476-1607 Pattern A canonical with no dialect drift.

### Q3 — First-touch channel per customer

**Score: 4.75 STRONG PASS** (Acc 5.0 / Comp 4.5 / Clar 4.5 / Act 5.0)

PRIMARY form: ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY created_at ASC) WHERE rn = 1.
ALT form: first_value(channel) OVER (PARTITION BY customer_id ORDER BY created_at ASC) with SELECT DISTINCT.

VERIFIED:
- ROW_NUMBER = 1 earliest-per-group is the canonical Top-1-per-group pattern.
- first_value with default frame (RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) is SAFE because the frame start is unbounded preceding, so the first value is always the earliest in the partition (footgun is on last_value with default frame, not first_value).
- min_by(channel, created_at) GROUP BY customer_id would be the cleanest one-call form per r23:627-650 — responder did not surface it, but per the directive's "don't penalize" guidance, we mark it as a polish gap (-0.25 Comp / -0.25 Clar) not an accuracy failure.

Two valid forms presented; tiebreaker for identical earliest timestamps could be more explicit, but the core is correct.

### Q4 — Extract email domain + count users per domain

**Score: 3.125 (BELOW per-Q floor 3.5)** (Acc 2.0 / Comp 3.5 / Clar 4.0 / Act 3.0)

***CRITICAL ACCURACY FAILURE: invalid GROUP BY.***

Responder wrote:
```sql
SELECT email, split_part(email, '@', 2) AS domain, COUNT(*) AS user_count
FROM users
GROUP BY split_part(email, '@', 2)
ORDER BY user_count DESC
```

The raw `email` column is in the SELECT list, is NOT in the GROUP BY, and is NOT wrapped in an aggregate. VERIFIED against trino.io/docs/467/sql/select.html: "When a `GROUP BY` clause is used in a `SELECT` statement all output expressions must be either aggregate functions or columns present in the `GROUP BY` clause." This query as written will NOT execute — Trino raises an error roughly: `'email' must be an aggregate expression or appear in GROUP BY clause`.

The "count users per domain" deliverable wants ONE row per domain. The correct shape DROPS the raw `email` column from the SELECT (it isn't meaningful per-domain anyway):
```sql
SELECT split_part(email, '@', 2) AS domain, COUNT(*) AS user_count
FROM users
GROUP BY split_part(email, '@', 2)
ORDER BY user_count DESC;
```
or positional: `GROUP BY 1 ORDER BY 2 DESC`.

The split_part(email, '@', 2) domain extraction is itself CORRECT (verified r23:277-278; signature `split_part(string, delimiter, index) -> varchar` per trino.io/docs/467/functions/string.html with field-index 2 = part AFTER the '@'). Subdomain/TLD/LOWER variations are useful polish. But the headline executable query is broken.

Accuracy 2.0 (query does not run as written, primary deliverable is invalid). Completeness 3.5 (variations included but the headline query is wrong). Clarity 4.0 (explanation reads cleanly; reader cannot tell the GROUP-BY-rule trap is present). Actionability 3.0 (engineer who copy-pastes will hit a Trino parse/analysis error and have to debug).

Per-Q 3.125 is below the 3.5 floor. Per directive the OVERALL AVERAGE governs PASS/FAIL (no per-Q quality-gate override), so the label remains PASS, but Q4 is the FIX-A candidate for iter647.

---

## Overall computation

Per-Q: (4.875 + 5.0 + 4.75 + 3.125) / 4 = **4.4375**
Dim-cross-check:
- Acc (5.0 + 5.0 + 5.0 + 2.0) / 4 = 4.25
- Comp (5.0 + 5.0 + 4.5 + 3.5) / 4 = 4.5
- Clar (4.5 + 5.0 + 4.5 + 4.0) / 4 = 4.5
- Act (5.0 + 5.0 + 5.0 + 3.0) / 4 = 4.5
Dim avg = (4.25 + 4.5 + 4.5 + 4.5) / 4 = **4.4375** — agrees.

**GOVERNING LABEL: PASS** (overall 4.4375 >= 3.5 by margin +0.9375; Q4 per-Q = 3.125 below floor but does not override the average per directive).

---

## iter647 FIX-A (teacher-actionable)

**FIX-A: GROUP BY rule guardrail anchored at split-and-count / extract-then-count phrasing.**

Rule statement to insert/reinforce: **"In Trino 467 GROUP BY queries, EVERY column in the SELECT list must be either (a) wrapped in an aggregate function, or (b) literally present in the GROUP BY clause. Raw passthrough columns are an error."**

Anchor location: r23:1278 already locks the positional-GROUP-BY / GROUP-BY-rule canonical. Extend that anchor with an explicit "extract-then-count" worked example showing the trap:

```sql
-- WRONG (responder's iter646 Q4 shape — will not execute):
SELECT email, split_part(email, '@', 2) AS domain, COUNT(*) AS user_count
FROM users
GROUP BY split_part(email, '@', 2);
-- Error: 'email' must be an aggregate expression or appear in GROUP BY clause

-- RIGHT (drop the raw column — it is not meaningful per-domain):
SELECT split_part(email, '@', 2) AS domain, COUNT(*) AS user_count
FROM users
GROUP BY split_part(email, '@', 2)
ORDER BY user_count DESC;
-- or positional: GROUP BY 1 ORDER BY 2 DESC;

-- ALSO RIGHT (if you really need a sample raw value — wrap in an aggregate):
SELECT split_part(email, '@', 2) AS domain,
       arbitrary(email) AS sample_email,
       COUNT(*) AS user_count
FROM users
GROUP BY split_part(email, '@', 2);
```

Keyword anchors to add at r23:1278 / r23:277 (the split_part domain locus):
- "count users per domain"
- "domains and the number of users in each"
- "extract domain then count"
- "split and group"
- "split_part GROUP BY"
- "every SELECT column must be in GROUP BY or aggregated"
- "non-aggregated column in GROUP BY query"

Cross-link to the existing positional-GROUP-BY canonical so the responder routes here from both "extract-then-count" and "group by 1" phrasings.

Single targeted edit (one canonical extension + 1-2 keyword anchors). Not a rewrite. NO touch of unrelated locks.

---

## DO NOT (iter647)

- Do NOT touch r22 §13.x federation guardrails (4.49944/312 thin, NOT probed this iter).
- Do NOT re-edit r07:1309-1341 N-min-truncation canonical (Q1 5.0 Acc — HOLDS).
- Do NOT re-edit r07:1476-1607 Pattern A cumulative-sum canonical (Q2 5.0 — HOLDS).
- Do NOT re-edit r23:627-650 min_by/max_by or r07:1967-2021 first_value/last_value (Q3 5.0 Acc — HOLDS).
- Do NOT re-edit r23:238-340 split_part canonical (split_part itself is CORRECT in Q4 — bug is GROUP BY rule, not split_part).
- Do NOT rewrite iter534-645 locks.
- Do NOT add `::`-casts, QUALIFY, RLIKE, PERCENTILE_CONT/MEDIAN, EXTRACT(EPOCH), dayname(), initcap(), DISTINCT ON.
- Do NOT bump training/state.json (per directive).
- Do NOT git commit/push beyond appending the rubric line.

---

## Topic average updates

- **SQL query best practices for OLAP / r23** (Q4 GROUP-BY-rule violation -0.5 accuracy ding; FIX-A targeted at this row) net DOWN slightly; will recover once FIX-A lands and is re-probed.
- **Analytical query patterns on Iceberg+Trino / r07** (Q1 5-min bucket +0.25 durability; Q2 cumulative sum +0.25 durability) net UP.
- **SQL query best practices for OLAP / r23** Q3 ROW_NUMBER=1 earliest-per-group +0.25 durability counterweight.
- Federation row UNCHANGED (4.49944/312, consecutive non-probe +1 -> 313).

---

## Meta-note

iter646 ran the DEFAULT NO-OP / DURABILITY-BREADTH doctrine recommended by iter645. Three of four canonicals held cleanly at >= 4.75 (Q1 5-min bucket, Q2 cumulative sum, Q3 first-touch). Q4 exposed a previously-untested combo: split_part(extract) + COUNT(*) + GROUP BY where the responder leaks a raw passthrough column into the SELECT. The split_part anchor is solid; the bug is one anchor over at the GROUP BY rule. FIX-A is a single-canonical extension at r23:1278 with the "extract-then-count" worked example as the trap-and-fix demo. Federation row stays at 4.49944/313, ZERO probe this iter.
