# Iter 572 Judge Feedback

PIN: Trino 467. All verifications run against trino.io/docs/467 (or stable doc text identical across 467-481 where the cited statement has not changed).

## Per-question scores

### Q1 — Forward-fill end-to-end weekly credit balance (IGNORE NULLS placement + composition re-probe)

Accuracy: 3.0 | Completeness: 4.0 | Clarity: 4.0 | Actionability: 3.0
**Q1 average: 3.50** (PASS thin)

PRIMARY-FIX VERIFICATION (the headline iter572 fix):
- (i) GOOD — IGNORE NULLS placement is now CORRECT: `LAST_VALUE(balance_eow) IGNORE NULLS OVER (PARTITION BY account_id ORDER BY week_start ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)`. The clause sits OUTSIDE the closing args paren, BEFORE OVER — matching the Trino 467 grammar verified via PR #1244 (SqlBase.g4): `(ORDER BY sortItem (',' sortItem)*)? ')' nullTreatment? filter? over?` — "null treatment clause is positioned after the closing parenthesis of arguments but before the OVER clause." Verified at trino.io/docs/467/functions/window.html: "By default, null values are respected. If IGNORE NULLS is specified, all rows where x is null are excluded from the calculation." **iter569/iter571 regression is RESOLVED on Q1**.
- (ii) GOOD — Composition order correct: no pre-join LAST_VALUE; forward-fill computed in the FINAL post-join SELECT with look-BACK frame `UNBOUNDED PRECEDING AND CURRENT ROW` (no UNBOUNDED FOLLOWING). Dense-spine intent acknowledged explicitly ("not just DISTINCT from the data, which would miss zero-activity weeks"). iter570 pre-join-window anti-pattern guard HELD.

ACCURACY DEFECTS (two execution-detail bugs):

**Defect 1 — weeks_spine CTE is MALFORMED (would not execute):**
```sql
-- responder wrote:
SELECT date_add('day', n * 7, date_trunc('week', MIN(posted_date))) AS week_start
FROM iceberg.analytics.ledger, UNNEST(sequence(0, 52)) AS t(n)
GROUP BY date_trunc('week', MIN(posted_date))
```
Two problems: (a) `GROUP BY date_trunc('week', MIN(posted_date))` GROUPs BY an expression containing an aggregate — Trino throws "GROUP BY clause cannot contain aggregations, window functions or grouping operations" per trino.io/docs/current/sql/select.html. (b) `n` appears in SELECT (via date_add) but is neither in GROUP BY nor aggregated → "must appear in GROUP BY" error. The query does NOT run as written.

**Correct form** (scalar-subquery the min, drive the rows from UNNEST):
```sql
WITH weeks_spine AS (
  SELECT date_add('day', n * 7, (SELECT date_trunc('week', MIN(posted_date)) FROM iceberg.analytics.ledger)) AS week_start
  FROM UNNEST(sequence(0, 52)) AS t(n)
)
```

**Defect 2 — MAX(balance) is the WRONG dedup aggregate ("latest, not largest"):**
```sql
-- responder wrote:
SELECT account_id, date_trunc('week', posted_date) AS week_start,
       MAX(balance) AS balance_eow
FROM ledger GROUP BY account_id, date_trunc('week', posted_date)
```
`MAX(balance)` returns the LARGEST balance in the week, not the chronologically-latest one. End-of-week balance = the balance at the LATEST posted_date in that week. Use `max_by`:
```sql
SELECT account_id, date_trunc('week', posted_date) AS week_start,
       max_by(balance, posted_date) AS balance_eow
FROM ledger GROUP BY account_id, date_trunc('week', posted_date)
```
Verified trino.io aggregate.html: "max_by(x, y) — Returns the value of x associated with the maximum value of y over all input values."

**Corrected end-to-end query:**
```sql
WITH
  account_weeks AS (
    SELECT DISTINCT account_id FROM iceberg.analytics.ledger
  ),
  weeks_spine AS (
    SELECT date_add('day', n * 7,
             (SELECT date_trunc('week', MIN(posted_date)) FROM iceberg.analytics.ledger)) AS week_start
    FROM UNNEST(sequence(0, 52)) AS t(n)
  ),
  calendar AS (
    SELECT a.account_id, w.week_start
    FROM account_weeks a CROSS JOIN weeks_spine w
  ),
  weekly_balance AS (
    SELECT account_id,
           date_trunc('week', posted_date) AS week_start,
           max_by(balance, posted_date) AS balance_eow   -- latest, not largest
    FROM iceberg.analytics.ledger
    GROUP BY account_id, date_trunc('week', posted_date)
  ),
  dense_with_gaps AS (
    SELECT c.account_id, c.week_start, wb.balance_eow
    FROM calendar c
    LEFT JOIN weekly_balance wb
      ON wb.account_id = c.account_id AND wb.week_start = c.week_start
  )
SELECT account_id, week_start,
       LAST_VALUE(balance_eow) IGNORE NULLS OVER (
         PARTITION BY account_id ORDER BY week_start
         ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
       ) AS balance_carried_forward
FROM dense_with_gaps
ORDER BY account_id, week_start;
```

### Q2 — Where does IGNORE NULLS go (standalone syntax micro-probe)

Accuracy: 5.0 | Completeness: 5.0 | Clarity: 5.0 | Actionability: 5.0
**Q2 average: 5.00** (STRONG PASS — direct FIX A validation)

Responder said IGNORE NULLS goes AFTER the function's closing paren, BEFORE OVER. Gave correct + wrong forms for LAST_VALUE / LAG / LEAD; called out the literal parse error "mismatched input 'IGNORE'" for the wrong form; gave the "close the args, then IGNORE NULLS, then OVER" mnemonic.

VERIFICATION: Trino 467 grammar (PR #1244 SqlBase.g4): `name '(' args ')' nullTreatment? filter? over?` — nullTreatment is OUTSIDE the args paren, BEFORE the OVER clause. trino.io/docs/467/functions/window.html confirms: "If IGNORE NULLS is specified, all rows where x is null are excluded from the calculation." Zero defects. **FIX A VALIDATED directly on this micro-probe.**

### Q3 — "Must appear in GROUP BY" error (rule + fix)

Accuracy: 5.0 | Completeness: 4.5 | Clarity: 5.0 | Actionability: 5.0
**Q3 average: 4.875** (STRONG PASS)

Rule statement is correct: every non-aggregated SELECT column must appear in GROUP BY. Three fixes are all valid Trino 467:
- (A) Add column to GROUP BY — correct.
- (B) Wrap in MAX/MIN/etc. — correct.
- (C) `arbitrary(col)` / `any_value(col)` — both valid Trino 467 per trino.io/docs/current/functions/aggregate.html: "arbitrary(x) — Returns an arbitrary non-null value of x, if one exists. Identical to any_value()." and "any_value(x) — Returns an arbitrary non-null value x, if one exists."

Minor completeness nit (-0.5): could have noted that this same constraint applies to expressions on the column (GROUP BY x means x, but x+1 also needs to be in GROUP BY or aggregated), and could have noted the `GROUP BY` ordinal/alias forms supported by Trino.

### Q4 — INNER vs LEFT join row drop (keep all users)

Accuracy: 5.0 | Completeness: 5.0 | Clarity: 5.0 | Actionability: 5.0
**Q4 average: 5.00** (STRONG PASS)

INNER JOIN default drops non-matching rows — correct. LEFT JOIN keeps all left-table rows, NULL-pads right — correct. The COUNT pitfall is correctly stated: `COUNT(*)` counts the NULL-padded row, `COUNT(p.purchase_id)` counts only real (non-null) matches — exactly right per SQL semantics (and per Trino aggregate.html: "count(x) — Returns the number of non-null input values"). Valid Trino 467 dialect. Zero defects.

---

## Overall

Average: (3.50 + 5.00 + 4.875 + 5.00) / 4 = **18.375 / 4 = 4.59375** → **PASS** (margin +1.09375 above 3.5 floor)

This is a +0.28125 swing from iter571's 4.3125 PASS. The primary iter572 fix (IGNORE NULLS placement) LANDED cleanly: Q2 direct micro-probe scored 5.00, and the placement is correct in Q1's composition as well. The regression that broke iter569/571 is RESOLVED.

Q1 still drags at 3.50 due to TWO new execution-detail defects orthogonal to the primary fix:
1. weeks_spine CTE is malformed (GROUP BY on aggregate + non-aggregated `n` not in GROUP BY) — would not run.
2. MAX(balance) returns largest-in-week, not end-of-week — semantically wrong for "last-known balance."

Both defects are in places the canonical's example query does cover, but the responder synthesized a new spine pattern rather than copying the canonical's sequence()+UNNEST scalar-subquery form, and used MAX instead of the iter571 canonical's max_by per-bucket dedup.

---

## iter573 directive

**FIX A iter572 — RESOLVED, no further canonical work needed for IGNORE NULLS placement.** iter572 FIX A (salience inversion + DO-NOT-WRITE expansion with all five exact-wrong-token forms + r23 §3.1 new H4 with translation table) ROUTED cleanly on Q1 placement + Q2 direct micro-probe. The recurring iter569/571 regression is resolved. Keep all iter572 FIX A surface area untouched.

**NEW FIX TARGETS (iter573):**

**FIX A (HIGH PRIMARY — r07 §4 COMBINED CANONICAL spine sub-pattern clean-up):**
The current canonical's spine CTE likely uses a form that lets the responder re-derive a malformed `FROM ledger, UNNEST(...) GROUP BY date_trunc('week', MIN(posted_date))` pattern. Re-shape the canonical's spine CTE explicitly so the pattern visible at the top of the spine CTE is unambiguously the SCALAR-SUBQUERY form:
```sql
WITH weeks_spine AS (
  SELECT date_add('day', n * 7,
           (SELECT date_trunc('week', MIN(posted_date)) FROM iceberg.analytics.ledger)
         ) AS week_start
  FROM UNNEST(sequence(0, 52)) AS t(n)
)
```
Add a DO-NOT-WRITE bullet adjacent to the spine CTE in r07 §4: "DO NOT compute MIN/MAX of the source date inline in the spine SELECT — that would force you to GROUP BY an aggregate (parse error 'GROUP BY clause cannot contain aggregations'). Wrap the MIN/MAX in a SCALAR SUBQUERY so the date is a single constant value, and drive rows from UNNEST(sequence(...))." Make the wrong form grep-findable verbatim: `FROM ledger, UNNEST(sequence(0,52)) ... GROUP BY date_trunc('week', MIN(posted_date))` ❌ PARSE ERROR.

**FIX B (HIGH — r23 §3.1D or wherever max_by lives — "latest not largest" guard):**
Add a short H4 or DO-NOT-WRITE bullet titled "DO NOT WRITE — MAX(x) when you mean 'latest x' (use max_by(x, ts))" with the WRONG/RIGHT translation:
```
WRONG (largest, not latest):   MAX(balance) AS balance_eow
RIGHT (latest by posted_date): max_by(balance, posted_date) AS balance_eow
```
Quote trino.io aggregate.html: "max_by(x, y) — Returns the value of x associated with the maximum value of y over all input values." Cross-ref from r07 §4 COMBINED CANONICAL spine/dedup section (any per-bucket "end-of-period balance" / "latest reading" / "as-of-end-of-day" dedup must use max_by, not MAX). Make grep-findable on tokens: "end of week balance", "end of day reading", "latest not largest", "as-of-end-of-bucket".

**FIX C (NO-OP federation):** 4.49944/310 unchanged. Zero edits to resources/22 §13.x.

**Probe targets for iter573:**
- HIGH — Q1 composition re-probe on a NEW per-bucket dedup framing (e.g., "monthly closing inventory by SKU" or "end-of-day account balance by user") — verify FIX A scalar-subquery spine + FIX B max_by-not-MAX both route. The composition order + IGNORE NULLS placement should hold (iter572 wins durable); the new things to test are spine sub-pattern legality and max_by-vs-MAX correctness.
- MEDIUM — Q2 IGNORE NULLS direct micro-probe DURABILITY check (different function: LAG IGNORE NULLS or FIRST_VALUE IGNORE NULLS). Verify the regression stays resolved across function names.
- MEDIUM — Q3 GROUP BY error in a slightly different framing (e.g., expression-on-column not in GROUP BY) to verify arbitrary/any_value durability.
- LOW — Q4 outer-join 2nd-angle (FULL OUTER JOIN or RIGHT JOIN COUNT pitfall) to verify durability.

**Meta-rule observation:**
Directive's "SCRUTINIZE Q1: verify each of (i)-(iv)" was load-bearing. The IGNORE NULLS placement looked right at a glance, but the weeks_spine subquery had a subtle but fatal SQL semantic bug (GROUP BY an aggregate + non-aggregated column in SELECT), and MAX-vs-max_by is the kind of "almost right" answer that passes inspection if you don't read for semantics. WebSearch on Trino GROUP BY-on-aggregate error message verbatim + max_by documentation verbatim was decisive — without it, this could have scored Q1 as a high-4 instead of 3.50. 35th consecutive iter (iter537-572) where meta-rule discipline materially affected the verdict.

WebSearched/verified: trino.io/docs/467/functions/window.html (IGNORE NULLS clause + frame semantics), trino.io/docs/current/functions/aggregate.html (max_by, arbitrary/any_value VERBATIM), GitHub PR #1244 (SqlBase.g4 grammar `name '(' args ')' nullTreatment? filter? over?` VERBATIM), trino.io/docs/current/sql/select.html ("GROUP BY clause cannot contain aggregations, window functions or grouping operations").

NOTES: did NOT bump training/state.json (teacher already set iteration=572). Federation rubric row 4.49944/310 unchanged.
