# iter712 Judge Feedback

## Scope

Re-probe of iter711 FLAG-ONLY NOT-IN-NULL diagnostic + 3 routine SQL-pattern probes
(percent-of-total, running-max window, substring filter).

PIN Trino 467 — all dialect facts verified against trino.io/docs/467 (+ /docs/current
where the page is unchanged across versions).

---

## Per-question scores

### Q1 — NOT IN three-valued-logic trap + catch-all for blanks

**User symptom:** `WHERE status NOT IN ('active','paused','cancelled')` "missing some
bad rows" — specifically the rows where `status IS NULL` (or empty/blank).

**Responder fix prescribed:**
- `WHERE status IS NULL OR status NOT IN ('active','paused','cancelled')` — catch-all
- `LEFT JOIN (VALUES('active'),('paused'),('cancelled')) AS valid(status) ON
  e.status=v.status WHERE v.status IS NULL` — anti-join alternative
- Cited resources/23 §10 NOT-IN + NULL gotcha.

**Verification vs trino.io/docs/467 + SQL 3VL semantics:**
- (a) Catch-all `IS NULL OR NOT IN (...)` — CORRECT. SQL 3VL: when the outer column
  is NULL, `NULL <> 'active' AND NULL <> 'paused' AND NULL <> 'cancelled'` evaluates
  to `UNKNOWN AND UNKNOWN AND UNKNOWN` → UNKNOWN, which the WHERE clause treats as
  not-true → row dropped. Adding `status IS NULL OR` re-includes those rows
  explicitly. Solves the symptom.
- (b) LEFT-JOIN-IS-NULL anti-join — VALID Trino 467. Standard SQL anti-join pattern;
  `(VALUES ...)` table constructor supported; NULL on the left side joins to nothing
  on the right → `v.status IS NULL` for any row whose left-side status didn't match
  → catches both "not in the list" rows AND "left side is NULL" rows. NULL-safe by
  design. Correct.

**MECHANISM-PRECISION nuance (flagged by directive):** Responder said "even one NULL
in the status column... every comparison evaluates to UNKNOWN... filters out EVERY
row — not just the invalid ones."

That description applies to the case where **the list/subquery side** contains a
NULL (then NOT IN expands to `... AND col <> NULL` which is UNKNOWN for every outer
row → empty result). In the user's actual scenario the list is literals
('active','paused','cancelled') with NO NULL, so the AND-chain `col <> 'active' AND
col <> 'paused' AND col <> 'cancelled'` is well-defined for every non-NULL outer
status — `NOT IN` works correctly for those. ONLY the outer rows where `status IS
NULL` get their predicate → UNKNOWN → silently dropped, which exactly matches the
user's "missing SOME bad rows" symptom (not "missing every row").

So the responder's MECHANISM PROSE conflates two adjacent sub-cases:
- Sub-case A: list/subquery contains NULL → every row vanishes (the canonical r23
  §10 framing).
- Sub-case B: list is pure literals, outer column has NULL rows → only the
  NULL-outer rows vanish (the user's actual scenario).

The PRESCRIBED FIX still solves the user's actual problem (the `IS NULL OR ...`
catch-all and the LEFT-JOIN anti-join both handle sub-case B correctly). The
symptom diagnosis ("missing rows because of NULL+3VL") is RIGHT. The exact
mechanism prose overstates by describing sub-case A behavior when sub-case B is
what's happening here.

**Flag-status verdict (per directive):**
- NOT-IN-NULL diagnostic flag = **PARTIALLY CLOSED**. The user gets a working
  catch-all and a valid alternative — that's the load-bearing deliverable, and it
  catches both NULLs and blanks. So the practical fix is solid.
- Mechanism-conflation = **MINOR PROSE NIT, NOT A FINDABLE GAP for iter713**. The
  responder still routed correctly to §10, still named 3VL, still picked the right
  fix shape, still gave both the catch-all AND the anti-join. A SaaS engineer
  reading the answer will fix their query correctly; they may walk away with
  slightly off mental model of which sub-case caused their symptom, but they will
  not write buggy code as a result. The teacher could optionally add a 2-line
  inline-marked sub-case split (literal-list + outer-NULL vs subquery + right-side
  NULL) adjacent to r23 §10 in iter713 if a future probe lands directly on the
  mechanism-precision question — but DO NOT prioritize this; resources are mature
  and reconcile-don't-append risk outweighs the marginal value.

**Sub-scores (1-5):**
- Accuracy: 4 — fix is correct, anti-join valid, but mechanism prose conflates
  list-NULL vs outer-NULL sub-cases (overstates "every row dropped" when only
  NULL-outer rows are dropped in this scenario).
- Completeness: 5 — both the IS-NULL-OR catch-all and the LEFT-JOIN anti-join
  given; references §10; explicitly mentions blanks.
- Clarity: 4 — terms are explained (3VL, UNKNOWN, anti-join via the WHERE-right-IS-
  NULL pattern), but the "filters out EVERY row" sentence could confuse a reader
  comparing the prose to their actual partial-loss symptom.
- Actionability: 5 — copy-paste-ready SQL for both shapes, immediately solves the
  user's data-quality check.
- **Avg: 4.50**

---

### Q2 — Percent of total in one pass

**Responder SQL:**
```sql
SELECT customer_id,
       SUM(amount) AS total_revenue,
       ROUND(100.0 * SUM(amount) / SUM(SUM(amount)) OVER (), 2) AS pct_of_total
FROM transactions
WHERE order_date >= DATE_TRUNC('month', CURRENT_DATE)
GROUP BY customer_id
ORDER BY total_revenue DESC;
```

**Verification vs trino.io/docs/467:**
- (a) `SUM(SUM(amount)) OVER ()` — VALID Trino 467. This is NOT illegal aggregate
  nesting. The inner `SUM(amount)` is the GROUP BY aggregate (one value per
  customer_id group); the outer `SUM(...) OVER ()` is a window function applied
  AFTER grouping, summing those group results across the empty-OVER window (= all
  grouped rows = grand total). Trino docs: "All aggregate functions can be used as
  window functions by adding the OVER clause." Canonical percent-of-total idiom.
  Correct.
- (b) Single `100.0 *` multiply, no double-100 — matches the percent-of-total PIN.
- (c) `DATE_TRUNC('month', CURRENT_DATE)` — valid Trino 467
  (trino.io/docs/467/functions/datetime.html). Returns first day of current month;
  `order_date >= that` filters to current month. Correct.
- (d) `ROUND(x, 2)` — valid Trino 467 numeric function.
- (e) Single scan, single GROUP BY, no self-join — meets the "cleaner one-pass"
  ask.
- (f) No NULLIF on the denominator — if the entire month has zero transactions the
  GROUP BY produces zero rows and the question is moot. If any customer has rows,
  the grand total > 0 (assuming amounts are positive). Minor edge case; not a real
  risk in this billing-dashboard context. Acceptable to omit.

**Sub-scores:**
- Accuracy: 5 — every Trino 467 form validated; canonical percent-of-total shape.
- Completeness: 5 — total_revenue + pct_of_total in one query; month filter
  included; ORDER BY DESC for dashboard ranking.
- Clarity: 5 — explains `SUM(SUM())` as "grand total via empty OVER ()", names the
  single-scan / no-self-join win.
- Actionability: 5 — drop-in copy-paste for the billing dashboard.
- **Avg: 5.00**

---

### Q3 — Running max ("personal best so far") per customer

**Responder SQL:**
```sql
SELECT customer_id, order_date, amount,
       MAX(amount) OVER (
         PARTITION BY customer_id
         ORDER BY order_date
         ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
       ) AS highest_to_date
FROM orders
ORDER BY customer_id, order_date;
```

**Verification vs trino.io/docs/467/functions/window.html:**
- (a) `MAX(x) OVER (PARTITION BY ... ORDER BY ... ROWS BETWEEN UNBOUNDED PRECEDING
  AND CURRENT ROW)` — VALID. Trino docs explicitly support all aggregate functions
  as window functions with PARTITION BY + ORDER BY + ROWS frame; UNBOUNDED
  PRECEDING and CURRENT ROW are documented frame bounds. This is the canonical
  running-max pattern. Correct.
- (b) No self-join, no correlated subquery — meets the user's explicit "without
  self-join" constraint. Correct.
- (c) Outer ORDER BY for readability — fine.

**Sub-scores:**
- Accuracy: 5 — exact-correct window-frame syntax, idiomatic running-max.
- Completeness: 5 — answers the question fully; explicit frame; outer sort for
  display.
- Clarity: 5 — names what the frame does ("every row from start through current").
- Actionability: 5 — drop-in copy-paste.
- **Avg: 5.00**

---

### Q4 — Filter rows where message contains "timeout"

**Responder SQL:**
```sql
SELECT id, message FROM logs WHERE message LIKE '%timeout%' ORDER BY id;
-- Also: WHERE regexp_like(message, '(?i)timeout')  for case-insensitive
```

**Verification vs trino.io/docs/467/functions/string.html + functions/regexp.html:**
- (a) `LIKE '%timeout%'` — VALID Trino 467. Standard SQL LIKE with `%` wildcard for
  any-chars-before-or-after. Case-sensitive by default. Correct for plain
  substring match.
- (b) `regexp_like(message, '(?i)timeout')` — VALID Trino 467. `regexp_like(string,
  pattern) → boolean` is documented. The `(?i)` inline flag is the standard
  Java/JONI regex case-insensitive modifier, and Trino docs explicitly note "Case-
  insensitive matching (enabled via the `(?i)` flag) is always performed in a
  Unicode-aware manner." Correct.
- (c) Comparison framing — responder correctly says LIKE is simpler + faster + more
  readable for plain substring; regexp_like is for case-insensitive or complex
  patterns. Matches Trino guidance.

**Sub-scores:**
- Accuracy: 5 — both forms validated against trino.io/docs/467.
- Completeness: 5 — primary fix (LIKE) plus the case-insensitive escalation
  (regexp_like + `(?i)`).
- Clarity: 5 — explains `%` wildcards and `(?i)` flag; gives selection guidance.
- Actionability: 5 — copy-paste ready for both shapes.
- **Avg: 5.00**

---

## Overall

| Q | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|
| Q1 NOT-IN-NULL catch-all | 4 | 5 | 4 | 5 | 4.50 |
| Q2 percent of total       | 5 | 5 | 5 | 5 | 5.00 |
| Q3 running max window     | 5 | 5 | 5 | 5 | 5.00 |
| Q4 substring + regex      | 5 | 5 | 5 | 5 | 5.00 |
| **OVERALL**               |   |   |   |   | **4.875** |

**Verdict: PASS (4.875 >= 3.5)**

---

## Flag-status & next-iteration directive

**iter711 NOT-IN-NULL diagnostic flag — PARTIALLY CLOSED.**
- The prescribed fix (catch-all `IS NULL OR NOT IN` + LEFT-JOIN anti-join) correctly
  solves the user's "missing blank-status rows" symptom. Both shapes are valid
  Trino 467. Responder routed to r23 §10. The load-bearing deliverable lands.

**Mechanism-conflation finding — PROSE NIT, NOT a findable gap for iter713.**
- The responder's "filters out EVERY row" sentence describes the list-contains-NULL
  sub-case (sub-case A) rather than the outer-column-NULL sub-case (sub-case B)
  that actually matches the user's symptom. The fix prescribed is still
  sub-case-B-correct, so no engineer will write buggy SQL from this answer. The
  mental model is slightly fuzzy but not wrong.
- Recommendation to teacher: **DO NOT add a new card for iter713.** Resources are
  mature (172+ consecutive PASSES) and reconcile-don't-append risk + responder
  confusion-from-defangs risk (cf. iter693 regression) outweigh the marginal
  benefit of a precision split. If a FUTURE probe explicitly asks "why are ONLY
  the NULL-status rows missing, not all rows" (mechanism-precision), THEN add a
  2-line inline-marked sub-case split adjacent to r23 §10. Until then, hold.

**Patterns across all 4 answers:** Trino 467 dialect fidelity is excellent. Window
function idioms (SUM(SUM()) OVER (), MAX() OVER ROWS UNBOUNDED PRECEDING) are
copy-paste-correct. Regex flag `(?i)` and DATE_TRUNC / LIKE / ROUND / GROUP BY +
ORDER BY shapes all validated. The only soft spot is mechanism prose in 3VL
explanations — and even there the actionable SQL is right.

**No rubric topic regression. No new required resource edits. State.json NOT
bumped (per directive).**
