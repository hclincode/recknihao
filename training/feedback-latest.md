# Iter 593 Judge Feedback — 2026-06-07 (EXTENDED PHASE)

## Summary

- **Overall average: 4.125 / 5 → PASS** (margin +0.625 above 3.5 floor; -0.875 swing from iter592's 5.00)
- Per-Q: Q1 = 5.00 STRONG PASS; Q2 = 3.25 (per-Q below 3.5 — quality concern, intent-miss); Q3 = 3.25 (per-Q below 3.5 — copy-paste incompleteness + wrong-target citation); Q4 = 5.00 STRONG PASS.
- Federation NOT probed — 4.49944/310 row UNCHANGED.

PASS/FAIL is governed by overall average (per directive: PASS = overall avg >= 3.5; no per-Q gate). Q2 and Q3 per-Q below-threshold scores are flagged as **quality concerns**, not label overrides.

---

## Per-question scoring + verifications

### Q1 — MODULO bucketing (`user_id % 10`) — **5.00 STRONG PASS** (Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5)

Responder gave both forms: `user_id % 10 AS bucket` and `mod(user_id, 10)` as identical aliases; plus the filter-one-bucket worked example `WHERE user_id % 10 = 0`.

**Trino 467 docs verification — trino.io/docs/current/functions/math.html (WebFetch):**
- `mod(n, m)`: *"Returns the modulo (remainder) of `n` divided by `m`."*
- `%` operator: *"Modulo (remainder)"* — confirmed valid Trino operator.
- `ceil(x)`: *"Returns `x` rounded up to the nearest integer."*
- `ceiling(x)`: *"Returns `x` rounded up to the nearest integer."* (alias confirmed)
- `floor(x)`: *"Returns `x` rounded down to the nearest integer."*

Both `%` and `mod()` are valid Trino 467 syntax. Zero defects. iter592 grep-summary anchor at r27:1007 routed cleanly.

### Q2 — extract domain after '@' (CLEAN way; user explicitly said position+substring "seems messy") — **3.25 per-Q quality concern — INTENT MISS** (Accuracy 4 / Completeness 2 / Clarity 4 / Actionability 3)

Responder LED with `substr(email, strpos(email, '@') + 1)` and `position('@' IN email)` — i.e. **EXACTLY the position-finding + substring approach the user said "seems messy."** Did NOT surface `split_part(email, '@', 2)` — the clean, direct Trino idiom for "the part after the delimiter."

**Trino 467 docs verification — trino.io/docs/current/functions/string.html (WebFetch):**
- `split_part(string, delimiter, index)`: *"Splits `string` on `delimiter` and returns the field `index`. Field indexes start with `1`. If the index is larger than the number of fields, then null is returned."*
- Confirmed `split_part('jane@acme.com', '@', 2)` → `'acme.com'` (1-indexed; field 2 = the part AFTER the '@').
- `strpos(string, substring)`: *"Returns the starting position of the first instance of `substring` in `string`. Positions start with `1`. If not found, `0` is returned."* (responder's strpos+substr form IS technically correct).
- `substr()` is an alias for `substring()`; 1-indexed.

**Diagnosis:** Both forms work and return the same result. But the user EXPLICITLY framed position+substring as "seems messy" and asked for "a cleaner way." The clean, documented Trino idiom for "give me the part AFTER a delimiter" is `split_part(s, delim, 2)`. Resources HAVE this content:
- r23 §3.1A (lines 225-285) full split-family reference table with `split_part(string, delimiter, index)` 1-indexed + NULL-on-out-of-range nuance + worked `split_part('acme.ourapp.com', '.', 1)` → `'acme'` example.
- r27:902 Oracle→Trino canonical with same subdomain-extraction example.

**Findability diagnosis — LANDING-POINT MISS:** The split_part content in r23 is framed around subdomain extraction (`split_part(domain, '.', 1)`) and split-on-dot examples. There is no explicit anchor for "part after the @" / "domain from email" / "everything after a character" / "part after a delimiter." The responder's keyword route for "extract X after a character" landed on strpos/position+substring instead of split_part because the split_part canonical's keyword surface is framed around dot-split (subdomain), not around "part after a delimiter generic."

**Docking:** Completeness -3 (missed the documented cleaner form the user explicitly requested); Actionability -2 (gave the "messy" form the user said they wanted to avoid; engineer would now go re-search). Accuracy NOT docked (strpos+substr DOES extract the domain correctly).

### Q3 — CTAS (save SELECT result as new Iceberg table) — **3.25 per-Q quality concern — COPY-PASTE INCOMPLETENESS + WRONG-TARGET CITATION** (Accuracy 4 / Completeness 3 / Clarity 3 / Actionability 3)

Responder named `CREATE TABLE ... AS SELECT (CTAS)` in prose and correctly noted the NOT-NULL-not-preserved gotcha (consistent with the r09 §1037-1133 CTAS-NOT-NULL-INFERENCE guardrail). BUT two slips:

**(i) COPY-PASTE INCOMPLETENESS — the worked SQL CODE BLOCK is missing the `CREATE TABLE ... AS` prefix.** The example shown is essentially a bare `SELECT event_date, user_id, ... FROM raw_events ... GROUP BY 1,2,3` — without the leading `CREATE TABLE schema.new_table AS`. The user asked "how do I create a new table directly from a SELECT" — copy-pasting the code block in the responder's answer would execute a SELECT that returns rows to the client, NOT create a table. Naming the pattern in prose does not rescue an incomplete worked example.

**Trino 467 docs verification — trino.io/docs/current/sql/create-table-as.html (WebFetch):**
- *Full syntax:* `CREATE [ OR REPLACE ] TABLE [ IF NOT EXISTS ] table_name [ ( column_alias, ... ) ] [ COMMENT table_comment ] [ WITH ( property_name = expression [, ...] ) ] AS query [ WITH [ NO ] DATA ]`
- The `AS query` clause is the load-bearing part the responder's example omitted.
- Correct copy-paste form: `CREATE TABLE iceberg.analytics.summary AS SELECT event_date, user_id, ... FROM raw_events ... GROUP BY 1,2,3` (optionally with `WITH (format = 'PARQUET', partitioning = ARRAY['event_date'])` per Iceberg connector).
- The NOT-NULL caveat the responder mentioned is real and consistent with r09's guardrail (CTAS carries column types only; NOT NULL not inferred).

**(ii) WRONG-TARGET CITATION — cited `/resources/25-trino-materialized-views-iceberg.md` as source for CTAS.** The file r25 DOES exist in the repo (Glob confirmed: `resources/25-trino-materialized-views-iceberg.md`), so this is **not a strictly-fabricated citation** (the file is real). HOWEVER, r25 is about **materialized views** (CREATE MATERIALIZED VIEW / REFRESH MATERIALIZED VIEW), NOT about CREATE TABLE AS SELECT. The actual CTAS canonicals live in r23:1525 (ad-hoc extract pattern `CREATE TABLE temp.my_extract AS SELECT ...`), r09 §1037-1133 (CTAS-NOT-NULL guardrail with the trino.io quote), and r13:4179-4185 (cross-ref). r25 line 356 mentions a CTAS in passing (`CREATE TABLE ... archive AS SELECT * FROM ...` as a one-liner inside the "drop MV but keep data" workaround) but is not a CTAS reference. **Diagnosis:** WRONG-TARGET citation (right-shape filename, wrong-topic content) — symptom of keyword "Iceberg + table create" routing to the MV file instead of the CTAS canonicals at r23/r09/r13. Not a clean fab, but it would mislead an engineer who clicks through expecting CTAS guidance and finds MV content.

**Docking:** Completeness -2 (worked example missing the load-bearing `CREATE TABLE ... AS` prefix); Clarity -2 (engineer copy-pasting the code block gets a SELECT, not a table — directly contradicts the question); Actionability -2 (would re-search after the SELECT runs without creating a table). Accuracy -1 (NOT-NULL prose is correct; wrong-target citation noted but file does exist).

### Q4 — CEIL/FLOOR (round UP / round DOWN) — **5.00 STRONG PASS** (Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5)

Responder gave `ceil(x)` / `ceiling(x)` round up (`ceil(50.0/12)` = 5), `floor(x)` round down (`floor(99.99)` = 99), `round(x, 0)` nearest (HALF_UP), AND flagged the integer-division gotcha: `50/12` (integer division) truncates to 4 so you need `50.0/12` (or `CAST`) to get the non-integer first before ceil.

**Trino 467 docs verification — trino.io/docs/current/functions/math.html (WebFetch):**
- `ceil(x)`: *"Returns `x` rounded up to the nearest integer."*
- `ceiling(x)`: *"Returns `x` rounded up to the nearest integer."* (alias of ceil)
- `floor(x)`: *"Returns `x` rounded down to the nearest integer."*
- `round(x)`: *"Returns `x` rounded to the nearest integer."* (with `round(x, d)` for d decimal places)
- Integer division: `50 / 12` with both INTEGER operands = INTEGER result via truncation = 4; `50.0 / 12` promotes to DOUBLE = 4.166... → `ceil(4.166...)` = 5. Responder correctly flagged this.

Zero defects. iter539 HALF_UP lock consistent. iter592 grep-summary anchor at r27:1008 routed cleanly.

---

## Overall

**(5.00 + 3.25 + 3.25 + 5.00) / 4 = 16.50 / 4 = 4.125 PASS.**

PASS with margin +0.625 above the 3.5 floor. Q2 + Q3 both per-Q below 3.5 are flagged as quality concerns; the overall-average label is PASS.

---

## iter594 teacher directive

### PRIMARY actions (FINDABILITY fixes — both LANDING-POINT misses, not content gaps)

**(a) Q2 fix — r23 §3.1A: add a "part after / before a delimiter" anchor at the split_part canonical.**

The split_part content exists at r23 §3.1A (lines 225-285) and r27:902 with a subdomain-extraction example. The findability surface routes off "split-on-dot" / "subdomain" but NOT off the user's phrasing "everything after the @" / "the part after a character" / "domain from email" / "domain part of email address."

Add an anchor block at the split_part canonical (reconcile-in-place; do NOT append a contradictory section):

```
Anchor: extract the part AFTER a delimiter → split_part(s, delim, 2)
Anchor: extract the part BEFORE a delimiter → split_part(s, delim, 1)
Worked example — domain from email: split_part('jane@acme.com', '@', 2) → 'acme.com'.
Worked example — local-part from email: split_part('jane@acme.com', '@', 1) → 'jane'.
Keyword anchors: domain from email, everything after the @, part after a character,
  part after a delimiter, after the dot, before the dot, local part of email, domain part of email.
DO NOT (when you just want the part after a delimiter): WHERE substr(email, strpos(email, '@') + 1)
  — works but verbose; split_part is the clean idiom. Use position+substring only when you need
  the offset itself (not just the trailing part) or when the delimiter is variable-length pattern (use regexp_extract).
```

**(b) Q3 fix — r23 §CTAS / r09 CTAS canonical: worked example MUST LEAD with the full `CREATE TABLE schema.tbl AS SELECT ...` form.**

The CTAS pattern is NAMED in prose by the responder but the worked code block omits the `CREATE TABLE ... AS` prefix — a copy-paste-completeness slip. Fix at the CTAS canonical (whichever the responder routes to — likely r23:1525 or r09 §1037-1133):

```
Lead-with-the-complete-statement worked example:

CREATE TABLE iceberg.analytics.daily_user_summary
AS
SELECT
  event_date,
  user_id,
  COUNT(*)         AS event_count,
  SUM(amount)      AS total_amount
FROM iceberg.raw.events
WHERE event_date >= DATE '2026-01-01'
GROUP BY 1, 2;

Watch out (carry forward from existing r09 guardrail): CTAS preserves column TYPES but NOT
  NOT-NULL constraints. If you need NOT NULL on the target, use the two-step explicit form
  (CREATE TABLE with column list + INSERT INTO SELECT) instead.
```

The point is the code block on the page must be a runnable CREATE TABLE statement so a responder copy-pasting the example reproduces the full statement, not a bare SELECT.

**(c) Q3 follow-up — wrong-target citation note (LOW PRIORITY).**

The responder cited `/resources/25-trino-materialized-views-iceberg.md` for CTAS. r25 exists but is about materialized views, not CTAS. Either:
- (preferred) leave r25 alone; ensure the CTAS canonicals at r23:1525 / r09 §1037-1133 / r13:4179-4185 have strong keyword anchors (`create a table from a SELECT`, `save SELECT result as Iceberg table`, `CTAS Iceberg`, `CREATE TABLE AS SELECT Iceberg`) so the responder routes to them instead of r25; OR
- (only if needed) add a one-line forward-reference at r25 top: "If you want CREATE TABLE AS SELECT (not a materialized view), see r23 §[CTAS canonical]." This avoids future wrong-target routing.

### DO NOT (carry-forward locks)

- DO NOT re-edit r23:1576 (ILIKE in-place REPLACE — iter591 lock, DURABLE across iter592 contains framing).
- DO NOT touch r22 §3.3 PG-connector ILIKE pushdown disambiguator.
- DO NOT touch r22 §13.x federation guardrails (4.49944/310 thin margin; need fresh failure probe before any churn).
- DO NOT add `::`-casts anywhere (iter571 PIN).
- DO NOT manufacture churn on the modulo (Q1) or ceil/floor (Q4) canonicals — both routed cleanly first-probe.
- DO NOT bump training/state.json (teacher already set iteration=593).

### RE-PROBE TARGETS (iter594-596)

1. **Q2 split_part 2nd framing** — to confirm the "part after a delimiter" anchor routes. Candidate: "extract the file extension from filename like 'report.pdf'" (should route to `split_part(filename, '.', 2)` or `regexp_extract` — the cleaner direct form). OR "extract the country code from phone like '+1-555-1234'" (should route to split_part with '-' delimiter).
2. **Q3 CTAS 2nd framing** — to confirm the worked-example-leads-with-CREATE-TABLE-AS fix. Candidate: "I want to materialize a join result as a new table for downstream queries" — should route to CTAS canonical and the responder's example should now LEAD with `CREATE TABLE schema.tbl AS SELECT ...`.
3. **Federation re-probe** — only remaining marginal row at 4.49944/310, now 37+ iters stale; highest-leverage breadth target. Carefully scope to NOT touch §13.x guardrails.

### Meta-rule observation

iter593 = 56th consecutive iter where placement-not-content findability discipline materially affected the verdict. Both Q2 and Q3 slips are **landing-point mismatches**, not content gaps:
- Q2: the split_part content exists at r23 §3.1A + r27:902 but the keyword surface is framed around dot-split / subdomain, not "part after a character" — responder's keyword route for "cleaner way than position+substring" landed on strpos+substr instead.
- Q3: the CTAS pattern is named in r23:1525 and r09 §1037-1133 but the worked code block visible at the routing-landing point lacked the `CREATE TABLE ... AS` prefix — responder copied the SELECT-only fragment, naming CTAS in prose but omitting it in code.

Both fixes are anchor-additions / worked-example-completeness corrections — exactly the iter586/587/589 ADD-distinct-LEADING-CANONICAL pattern, applied here to keyword surface (Q2) and example completeness (Q3).

### Verification log (WebFetch / docs URLs hit today)

- trino.io/docs/current/functions/math.html — confirmed `mod(n,m)`, `%`, `ceil`, `ceiling`, `floor`, `round` semantics for Q1 + Q4.
- trino.io/docs/current/functions/string.html — confirmed `split_part(string, delimiter, index)` 1-indexed + NULL-on-out-of-range; `strpos` 1-indexed + 0-if-not-found; `substr` alias of `substring` for Q2.
- trino.io/docs/current/sql/create-table-as.html — confirmed full CTAS syntax `CREATE [OR REPLACE] TABLE [IF NOT EXISTS] table_name [(...)] [COMMENT ...] [WITH (...)] AS query [WITH [NO] DATA]` for Q3.

### Repo files touched this iter

- training/feedback-latest.md (this file).
- training/rubric.md (one-line iter593 entry appended).
- Did NOT bump training/state.json (teacher already set iteration=593, phase=extended).
- Did NOT touch any resources/ files.
