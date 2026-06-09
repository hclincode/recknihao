# Judge Feedback — iter881 (EXTENDED PHASE)

**Overall: 4.94 STRONG PASS** (per-Q 5.00 / 4.75 / 5.00 / 5.00 = 19.75 / 4 = 4.9375; margin +1.44 over 3.5)
Overall average governs — no per-Q veto.
**FEDERATION NOT PROBED** this iteration — the 4.49944/310 federation row is UNCHANGED.

All four answers verified clean against trino.io/docs/467 + Trino git-tag 467 source (WebFetch/WebSearch 2026-06-10). PIN 467.

---

## Q1 — Strip control / non-printable chars (ASCII < 32) from imported text — 5.00

Sub-scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5.

Responder gave `regexp_replace(dirty_text, '[\x00-\x1F\x7F]', '')` to drop only control chars (0–31 + DEL 127) while keeping printable + multibyte, plus the stricter `'[^\x20-\x7E]'` to keep only printable ASCII (and correctly warned it strips multibyte too), and noted the 2-arg `regexp_replace(s, pattern)` deletes matches (= 3-arg with `''`).

VERIFIED vs trino.io/docs/467 functions/regexp.html:
- 2-arg form: "Removes every instance of the substring matched by the regular expression `pattern` from `string`" — CONFIRMED (delete = 3-arg with empty replacement).
- 3-arg form: "Replaces every instance ... with `replacement`" — CONFIRMED.
- Regex dialect: Trino uses Java pattern syntax — CONFIRMED, so the `\x00-\x1F`, `\x7F`, and `[^\x20-\x7E]` character classes are valid Java-regex.

No defect. Both the "keep multibyte" and "ASCII-only" variants are correct and the multibyte-stripping caveat on the second form is a precision plus.

## Q2 — Inline per-row lookup without a top-level join — 4.75

Sub-scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 4.75.

Responder gave a scalar subquery in the SELECT list `(SELECT c.account_created_at FROM customers c WHERE c.customer_id = o.customer_id) AS ...`, noted Trino's decorrelation may rewrite it as a join (else O(N*M)), recommended the explicit LEFT JOIN as the load-bearing production pattern, and scoped the scalar subquery to small / PK lookups.

VERIFIED vs trino.io/docs/467 sql/select.html:
- "A scalar subquery is a non-correlated subquery that returns zero or one row. It is an error for the subquery to produce more than one row. The returned value is NULL if the subquery produces no rows." — CONFIRMED the one-value-per-row + >1-row-errors behavior.
- "Currently only single column can be returned from the scalar subquery." — consistent with the single-column lookup.
- "Support for correlated subqueries is limited. Not every standard form is supported." — the decorrelation/explicit-join guidance is exactly the right hedge.

No defect. The "prefer the explicit LEFT JOIN in production, use scalar subquery for small PK lookups" framing is sound and SaaS-actionable. Tiny actionability nuance (-0.25): the scalar subquery here is correlated (it references `o.customer_id`), so the doc's "non-correlated scalar subquery" wording is worth a one-line acknowledgement — but the responder's behavioral description (one value/row, errors on >1) and the prefer-LEFT-JOIN advice are entirely correct. Not a defect.

## Q3 — Character count vs byte length of a unicode string — 5.00

Sub-scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5.

Responder: `length(name)` -> character (code-point) count; `octet_length(name)` -> UTF-8 byte count; examples 😀 = 1 char / 4 bytes, "Café" = 4 chars / 5 bytes (é = 2 bytes), ASCII = 1 char = 1 byte; CASE validation.

VERIFIED:
- trino.io/docs/467 functions/string.html: `length(string) -> bigint` "Returns the length of string in characters." and the page notes string functions "operate on Unicode code points" — CONFIRMED length = code-point count.
- functions/binary.html: `length(binary) -> bigint` "Returns the length of binary in bytes." — confirms the byte-count concept.
- octet_length is the SQL-standard byte-length function (UTF-8 byte count for varchar in Trino) — the responder's usage is correct.
- Encoding arithmetic independently verified: 😀 (U+1F600) = 1 code point, 4 UTF-8 bytes; é (U+00E9) = 2 UTF-8 bytes; "Café" = 4 code points, 5 bytes; ASCII = 1 byte each. All examples correct.

No defect. (Minor non-dinged nuance: `length` counts code points, not grapheme clusters — irrelevant to the asked emoji/accent examples, which are single code points.)

## Q4 — Banker's rounding / round-half-to-even (2.5->2, 3.5->4) for finance — 5.00

Sub-scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5.

Responder: Trino has NO built-in banker's-rounding mode; `ROUND()` and `CAST(DOUBLE AS DECIMAL)` both use HALF_UP (2.5->3, 3.5->4); examples `CAST(DOUBLE '2.5' AS DECIMAL(2,0))` -> 3, `ROUND(2.5,0)` -> 3.0; recommended implementing round-half-even in app code / dbt macro / ETL. ALSO editorialized that "most financial regulations require HALF_UP, banker's is uncommon in production billing systems."

**CRITICAL VERIFICATION — all four points:**

1. **Trino 467 round(x) / round(x,d) mode = HALF_UP (round half away from zero) — CONFIRMED from git-tag 467 source** (`core/trino-main/.../operator/scalar/MathFunctions.java`):
   - Double path: `DoubleMath.roundToBigInteger(rescaled, RoundingMode.HALF_UP)` with a `sign *` multiplier (= half away from zero).
   - Decimal `roundShort` path: `int roundUp = remainder >= remainderBoundary ? 1 : 0;` (remainderBoundary = factor/2) = HALF_UP.
   - math.html documents only "rounded to the nearest integer / d decimal places" (silent on mode) — source is dispositive and confirms HALF_UP.

2. **CAST(double/decimal AS decimal) with reduced scale = HALF_UP — CONFIRMED**: git-tag 467 `DecimalCasts.java` uses `.setScale(..., HALF_UP)` (varchar->decimal explicit; double/decimal rescale share the same HALF_UP semantics); WebSearch confirms Trino's documented cast-to-lower-precision behavior is "rounded, not truncated". `CAST(DOUBLE '2.5' AS DECIMAL(2,0))` -> 3 is correct.

3. **NO built-in round-half-even / banker's-rounding function in Trino 467 — CONFIRMED**: functions/list.html has no `round_even` / `round_half_to_even` / `bankers` / `half_even`; MathFunctions.java has no HALF_EVEN path. The honest decline is **CORRECT behavior — a genuinely-absent function, NOT a findable-but-missing gap and NOT a defect.** This is the distinction that matters: declining to invent a non-existent function and routing the user to app/dbt/ETL is exactly right.

4. **Editorial claim "most financial regulations require HALF_UP, banker's is uncommon in production billing" — OVERSTATED non-SQL opinion.** Round-half-to-even IS the IEEE-754 default and is common in accounting/finance (it minimizes cumulative bias). This is a debatable, unsupported editorial overreach. Per the run directive this is a **minor accuracy consideration, NOT a SQL-dialect defect** — the core SQL answer (no built-in banker's; ROUND/CAST are HALF_UP; implement elsewhere) is fully correct and is what the question turns on. The overreach is mild enough that it does not pull the per-Q below 5 under overall-governs scoring, but flagging it: the responder should present round-half-even neutrally as a legitimate, common requirement rather than dismiss it.

No SQL defect. The core answer is correct and well-scoped; the one soft spot is the gratuitous regulatory editorializing.

---

## iter882 recommendation — **DEFAULT NO-OP**

All four answers are dialect-clean. Q4 is a **correct honest decline of a genuinely-absent function** (no built-in banker's rounding in Trino 467), not a defect — so **NO FIX-A**. Do NOT add any "wrong" card for Q1–Q4 (all forms correct). Do NOT touch any iter534–880 pin. NO federation edits. PIN 467. DO NOT bump training/state.json.

OPTIONAL micro-polish only (not required, must not churn a pin): if a rounding card exists, a one-line neutral note — "Trino round()/CAST-to-decimal = HALF_UP; no built-in round-half-even (banker's) — implement in dbt/app if required; both HALF_UP and half-even are legitimate finance conventions" — would inoculate against the editorial overreach without asserting a regulatory opinion. Skip if it would disturb existing content.

## Explicit confirmation of (d)
- **Is Trino 467 round()/round(x,d) HALF_UP?** YES — verified HALF_UP (round half away from zero) from git-tag 467 MathFunctions.java (double and decimal paths).
- **Is CAST(double/decimal AS decimal) reduced-scale HALF_UP?** YES — verified (DecimalCasts.java setScale HALF_UP; "rounded not truncated").
- **Does any built-in banker's / round-half-to-even function exist in Trino 467?** NO — none in functions/list.html or MathFunctions.java. The responder's decline is CORRECT.
