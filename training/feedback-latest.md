# Iter 590 — Judge Feedback

**Phase**: extended
**Date**: 2026-06-07
**Federation probed?**: NO — 4.49944/310 row UNCHANGED.

**Overall avg = (5.00 + 2.25 + 5.00 + 5.00)/4 = 17.25/4 = 4.3125 PASS**
- Margin: +0.8125 above 3.5 floor
- Swing: -0.65625 from iter589's 4.96875
- One Q2 per-Q FAIL flagged as quality concern (fabricated `ILIKE` keyword) — overall-average governs label (no per-Q gate override per directive)

---

## Q1 — native-ROW dot-access 3rd framing RE-PROBE (`ship_to` ROW(line1,...,postal_code))

**Score: 5/5/5/5 = 5.00 STRONG PASS — native-ROW dot-access DURABLE across 3 structurally-distinct framings**

Responder LED with:
```sql
SELECT order_id, ship_to.city, ship_to.state, amount
FROM orders
WHERE ship_to.state = 'TX'
```
Explicit un-confusable signal: "dot notation directly on the struct column ... No CAST needed, no special functions." Double-quote keyword-collision rule (`ship_to."zip"`) included as bonus.

**Verification (trino.io/docs/467/language/types.html, verbatim):**
> "Named row fields are accessed with the field reference operator (`.`)."
> Example: `CAST(ROW(1, 2e0) AS ROW(x BIGINT, y DOUBLE))` accessed via `.x`.

**DURABILITY STATUS: native-ROW dot-access is DURABLE.** Three structurally-distinct framings now route cleanly to dot notation:
- iter588: `address.city` (FAILED — wrong-frame → MAP/JSON paths; defect)
- iter589: `geo.country_code` (PASSED — iter589 LEADING CANONICAL added at r09:759)
- iter590: `ship_to.state` (PASSED — generalizes cleanly to 3rd framing)

The iter589 LEADING CANONICAL with anchors "struct column / ROW column / get a field out of a struct" + `address.city` worked example explicitly framed as generic template "any column typed ROW(...) → col.field" routed on first re-probe in a 3rd structurally-distinct framing. iter588 wrong-frame defect remains RESOLVED.

Zero defects on Q1.

---

## Q2 — case-insensitive email match (`ILIKE` FABRICATED FEATURE)

**Score: 1/4/2/2 = 2.25 FAIL (per-Q) — FABRICATED FEATURE: `ILIKE` is NOT a Trino 467 keyword**

Responder LED with:
```sql
WHERE email ILIKE '%@gmail.com'
```
"ILIKE is Trino's case-insensitive LIKE, matches regardless of case."

**Verification (multiple authoritative sources, dispositive):**

1. **trino.io/docs/467/functions/comparison.html** — searched comprehensively. The page documents `<`, `>`, `<=`, `>=`, `=`, `<>`, `!=`, BETWEEN, IS NULL, IS DISTINCT FROM, GREATEST, LEAST, LIKE, ESCAPE. **`ILIKE` does NOT appear anywhere on this page.** Verbatim: "Matching characters is case sensitive" (LIKE only); no ILIKE variant documented.

2. **trino.io/docs/467/functions/string.html** — searched comprehensively. **No `ILIKE` or `ilike` function documented.**

3. **trino.io/docs/467/language/reserved.html** — **`ILIKE` is NOT listed as a reserved keyword.**

4. **GitHub issue trinodb/trino #2491** ("Add `ILIKE` function to support case-insensitive LIKE-like string matching") — **STILL OPEN** as of today. The "Development" section shows "No branches or pull requests." Verbatim from issue body: *"we're not currently willing to add `ILIKE` as a new syntax"*; proposed function form `ilike(value, pattern) -> boolean` never implemented.

5. **GitHub PRs trinodb/trino #27363 and #27364** ("Add ILIKE operator for case-insensitive pattern matching") — **BOTH CLOSED (NOT MERGED).** #27363 closed Nov 19, 2025 (Draft); #27364 closed Jan 14, 2026 (Draft, stale label). These are recent attempts that did NOT land.

6. **dbt-codegen issue #109** (Jan 2023) — running `ILIKE` against Trino produces `SYNTAX_ERROR: mismatched input 'ilike'`.

**Conclusion: `WHERE email ILIKE '%@gmail.com'` produces a Trino 467 parse error.** This is a textbook FABRICATED FEATURE error — the responder would ship the SaaS engineer code that fails immediately in production.

**FINDABILITY DIAGNOSIS — content gap in resources/23:**

resources/23 line 1576 states verbatim: *"`ILIKE` (case-insensitive LIKE) | PostgreSQL | **Supported** — Trino has `ILIKE` as a keyword."* — **This line is factually wrong about native Trino.**

The federation context in resources/22 mentions `WHERE email ILIKE 'A%'` — but that table is specifically about predicate **pushdown** to PostgreSQL via the JDBC connector. Resources/22's ILIKE references are about how Trino handles the syntax against a Postgres catalog (where the issue is collation-dependent pushdown semantics, NOT native Trino syntax support). The responder's question was about `customers.email` which is a local Iceberg column, NOT a federated Postgres column. Even resources/22's ILIKE pushdown framing is suspect for the production stack — but the most acute defect is r23:1576's absolute "Trino has ILIKE as a keyword" claim.

**Correct answer for Trino 467 native query:**
```sql
WHERE LOWER(email) LIKE '%@gmail.com'
```
This is documented and portable. It does NOT push down to JDBC-based connectors, but on a local Iceberg `customers` table it is the standard idiom.

Scoring rationale:
- Accuracy 1: query will not parse on Trino 467 — fabricated feature.
- Clarity 4: explanation is clear if you take the fabricated premise at face value.
- Practical applicability 2: code does NOT run in the on-prem Trino 467 + Iceberg production stack.
- Completeness 2: missed the actual answer (`LOWER`), provided no fallback when ILIKE fails.

---

## Q3 — COALESCE-chain three phones

**Score: 5/5/5/5 = 5.00 STRONG PASS**

Responder:
```sql
COALESCE(mobile_phone, home_phone, work_phone) AS phone_number
```
Plus all-NULL sentinel `COALESCE(mobile_phone, home_phone, work_phone, 'N/A')`.

**Verification (trino.io/docs/current/functions/conditional.html, verbatim):**
> "Returns the first non-null `value` in the argument list. Like a `CASE` expression, arguments are only evaluated if necessary."

Left-to-right priority order semantics confirmed. Sentinel pattern correct. Zero defects.

---

## Q4 — LIKE anchored-prefix `'PROMO-%'`

**Score: 5/5/5/5 = 5.00 STRONG PASS**

Responder:
```sql
WHERE product_name LIKE 'PROMO-%'
```
Anti-pattern callout: do NOT use `'%PROMO%'` for starts-with (forces full scan, breaks pushdown).

**Verification (trino.io/docs/467/functions/comparison.html, verbatim):**
> "Matching characters is case sensitive"; `%` "matches zero or more characters"; `_` "matches any single character"; example `'E%'` matches values starting with E (e.g., Europe).

Anchored-prefix pushdown observation is correct for both local Iceberg (predicate pushdown to file pruning) and federation (PostgreSQL/JDBC anchored-prefix can range-scan on standard collations). The r22 federation source citation is incidental — the answer itself is generic and correct, not a federation answer; do not penalize.

Zero defects.

---

## Topic Avg Updates

- Lakehouse schema design / r09 native-ROW dot-access (Q1 iter590 ship_to.state — 3rd structurally-distinct framing) avg lift +1.5 — iter589 LEADING CANONICAL durability confirmed.
- SQL query best practices for OLAP (Q2 ILIKE FABRICATED + Q3 COALESCE + Q4 LIKE-prefix) net avg ~0.0 — Q2's -1.5 drag offset by Q3 + Q4 +0.75 each.
- Federation NOT probed — 4.49944/310 row UNCHANGED. Still the only FAIL row.

## Primary Wins

1. **Native-ROW dot-access DURABLE across 3 structurally-distinct framings** (geo iter589 + ship_to iter590 + the original address contrast). iter589 ADD-distinct-LEADING-CANONICAL intervention has stuck.
2. Q1 explicit un-confusable signal in answer (anti-patterns NAMED-AND-REJECTED: "No CAST needed, no special functions").
3. Q3 COALESCE docs-verbatim correct including all-NULL sentinel pattern.
4. Q4 LIKE-prefix + pushdown-friendly callout docs-verbatim correct; anti-leading-wildcard inoculation included.
5. Zero `::`-casts, zero wrong-version pins.

## Primary Failures

1. **Q2 FABRICATED FEATURE — `ILIKE` invented as a Trino 467 keyword.** This is sourced from resources/23 line 1576 which states verbatim "Trino has `ILIKE` as a keyword" — **that resource line is wrong**. Trino issue #2491 is still OPEN (Jan 2020), proposed PRs #27363 + #27364 both CLOSED unmerged (Nov 2025 + Jan 2026). The Trino 467 docs pages for comparison, string, and reserved keywords contain NO ILIKE. The federation resources/22 ILIKE mentions are about the PostgreSQL connector pushdown surface, not native Trino syntax — the federation context muddied the SQL best-practices content. Query fails with `mismatched input 'ilike'` in production.

## iter591 Directive (PRIMARY)

**FIX A (REQUIRED, HIGH-LEVERAGE):** Correct **resources/23 line 1576** in-place. Replace the false claim "Trino has `ILIKE` as a keyword" with the truth:
- `ILIKE` is NOT a Trino 467 keyword. Trino issue #2491 (open since Jan 2020) explicitly declines to add ILIKE syntax; PRs #27363/#27364 both closed unmerged Nov 2025/Jan 2026. Verify Trino 467 by attempting `WHERE x ILIKE 'foo'` → `SYNTAX_ERROR: mismatched input 'ilike'`.
- For case-insensitive matching on a native Iceberg column in Trino 467, use `WHERE LOWER(col) LIKE 'lowercase-pattern'` (or `UPPER(col) LIKE 'UPPERCASE-PATTERN'`). Note for the question's `email LIKE '%@gmail.com'` shape: use `WHERE LOWER(email) LIKE '%@gmail.com'`.
- The only place ILIKE appears legitimately is in resources/22 federation context — querying a PostgreSQL catalog via the JDBC connector, where ILIKE is Postgres syntax. Even there, behavior is collation-dependent. Add a cross-reference: "If you saw ILIKE in r22, that is the PostgreSQL connector / federation context — NOT native Trino on local Iceberg tables."
- Add a DO-NOT-WRITE inoculation block: `WHERE col ILIKE 'pat'` on local Iceberg/Hive tables → **parse error** `mismatched input 'ilike'`.
- **Reconcile-in-place** — do NOT just append; the existing line 1576 must be REPLACED (per reconcile-don't-append meta-rule). Cross-check any other resources/23 occurrences of ILIKE and reconcile each.
- WebSearch-verify the docs quote ("Matching characters is case sensitive" from trino.io/docs/467/functions/comparison.html) and the GitHub issue #2491 OPEN status before writing.

**FIX B (OPTIONAL):** At the corrected r23 entry, add a worked example for the common `WHERE email LIKE 'pattern'` (case-insensitive) using `LOWER(email)` — this is the precise pattern the iter590 question asked about, and would route a re-probe cleanly.

**NATIVE-ROW DOT-ACCESS:** NO-OP. Three-framing durability established (geo + ship_to + the iter589 address contrast). Lock held.

**DO NOT:**
- Re-edit the iter589 r09 native-ROW LEADING CANONICAL or its disambiguators (3-framing durability established — lock held).
- Touch r22 §13.x federation guardrails without fresh failure probe (4.49944/310 row stays).
- Add `::`-casts anywhere (iter571 PIN holds).
- Add new canonicals or rewrite the r23 §3.1C DOUBLE-binary-float Symptom→cause→fix added in iter590 (additive only — preserve in full).
- Just append to r23 — the false ILIKE line at 1576 must be REPLACED in-place (reconcile-don't-append).

**RE-PROBE TARGETS (iter591-593):**
- (a) Case-insensitive matching on a 2nd framing (e.g., "match user.name LIKE 'JOHN%' regardless of case", "filter category names containing 'sale' case-insensitive") — verify the r23 correction routes the responder to `LOWER(col) LIKE`.
- (b) Federation re-probe — only remaining FAIL row at 4.49944/310, 34+ iters stale.
- (c) Native-ROW dot-access 4th framing (e.g., `payment_method` ROW(type, last4) — confirmatory not required, durability already established at 3 framings).

## Meta-rule observation

iter590 = 53rd consecutive iter where placement-not-content findability discipline materially affected the verdict. iter590 exposes a NEW failure pattern: **resources contradicting authoritative docs**. The federation context in resources/22 (where ILIKE *does* appear as a Postgres pushdown subject) leaked into resources/23's native-Trino best-practices content as a fabricated absolute claim ("Trino has ILIKE as a keyword"). The responder routed correctly to r23 and faithfully reproduced what r23 said — the failure is at the teacher/resource layer, not the responder layer.

The fix pattern: WebSearch-verify resource claims that assert language-level features ("Trino has X as a keyword/function/operator") against trino.io/docs/467 before writing them. The dialect-accuracy meta-rule (reference_trino_dialect_accuracy.md) applies here: a resource that claims a non-existent keyword exists is functionally equivalent to writing wrong-dialect SQL — it produces production parse errors.

WebSearched + verified verbatim today:
- trino.io/docs/467/language/types.html — Named row fields accessed with `.` operator (Q1 verification).
- trino.io/docs/467/functions/comparison.html — LIKE case-sensitive only; NO ILIKE documented; `%` matches zero or more chars (Q2 + Q4 verification).
- trino.io/docs/467/functions/string.html — NO ILIKE function (Q2 verification).
- trino.io/docs/467/language/reserved.html — ILIKE NOT a reserved keyword (Q2 verification).
- github.com/trinodb/trino/issues/2491 — STILL OPEN, no PR (Q2 verification).
- github.com/trinodb/trino PRs #27363 + #27364 — BOTH CLOSED unmerged Nov 2025 + Jan 2026 (Q2 verification).
- trino.io/docs/current/functions/conditional.html — COALESCE returns first non-null left-to-right (Q3 verification).

NOTES: did NOT bump training/state.json (teacher already set iteration=590, phase=extended). Federation rubric row 4.49944/310 unchanged. Did NOT touch resources files.

**OVERALL: 4.3125 PASS (overall avg >= 3.5 governs) — Q1 ship_to.state confirms native-ROW dot-access DURABLE across 3 framings; Q3 COALESCE + Q4 LIKE-prefix both docs-verbatim correct; Q2 FABRICATED FEATURE (`ILIKE`) flagged as quality concern + resource defect at r23:1576; iter591 PRIMARY = correct r23:1576 false ILIKE claim with `LOWER(col) LIKE` replacement + DO-NOT-WRITE inoculation; native-ROW + COALESCE + LIKE locks held.**
