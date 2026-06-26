# Iter1145 Judge Feedback

**Verdict: 4.65625 PASS + LIGHT FIX-A (resource-sourced findability gap on Q4). Q1 (LISTAGG DISTINCT), Q2 (LEAD week-over-week + IGNORE NULLS placement), Q3 (power() / no `^`) all clean 5.0. Q4 (status='active' silently dropping rows / trailing space) was a partial bail (3.625) — responder gave the correct FIX (`WHERE TRIM(status) = 'active'`) and sound diagnostic (test `'active' = 'active '`), but said "I don't have enough information to answer this well" on the engineer's yes/no when the answer is a definite NO that follows from standard Trino VARCHAR exact-comparison semantics. The bail isn't a factual error and the engineer arrives at the right action, but the under-confidence is traceable to a real RESOURCE-SOURCED findability gap: the specific fact "Trino VARCHAR comparison is exact (byte-for-byte), not space-padded; 'active' != 'active '; only CHAR(n) pads" is not anchored as a canonical anywhere reachable from keywords like "trailing space", "VARCHAR comparison", "WHERE status='active' silently drops rows after Oracle migration". LIGHT FIX-A specified below. Margin remains safely above 3.5 threshold; no PASS regression.**

---

## Q1 — Oracle LISTAGG(DISTINCT) → Trino translation

**Question:** Oracle `LISTAGG(DISTINCT tag_name, ', ') WITHIN GROUP (ORDER BY tag_name)` errors on Trino. Does Trino LISTAGG support DISTINCT?

**Responder answer:** Trino 467 does NOT support `LISTAGG(DISTINCT ...)`. Use `array_join(array_agg(DISTINCT tag_name ORDER BY tag_name), ', ')` — `array_agg(DISTINCT … ORDER BY …)` dedups + orders, `array_join` concatenates with the separator.

**Scoring:**
- **Accuracy: 5.0** — Correct on both halves. Trino 467 `listagg` per [trino.io/docs/current/functions/aggregate.html#listagg](https://trino.io/docs/current/functions/aggregate.html#listagg) does NOT have a DISTINCT slot (the WITHIN GROUP listagg signature accepts only the expression + separator + optional ON OVERFLOW clause). `array_agg(DISTINCT x ORDER BY x)` + `array_join` is the canonical Oracle-LISTAGG-DISTINCT replacement, also matches pinned `reference_trino_listagg_native` memory.
- **Clarity: 5.0** — Names the two-step pattern cleanly.
- **Applicability: 5.0** — Drop-in for Oracle migration.
- **Completeness: 5.0** — Yes/no + workaround + reason (dedup + order in one place).

**Avg: 5.0**

---

## Q2 — Week-over-week side-by-side via LEAD + IGNORE NULLS placement trap

**Question:** Show each week's revenue alongside the NEXT week's revenue side-by-side without a self-join — what window function pulls the following row forward?

**Responder answer:** `LEAD(current_week_revenue) OVER (ORDER BY week_start)`; can compute delta as well. ALSO: null-treatment clause placement — `LEAD(col) IGNORE NULLS OVER (...)` (after the closing paren, before OVER) is correct; `LEAD(col IGNORE NULLS) OVER (...)` (inside the arg list) is a PARSE ERROR.

**Scoring:**
- **Accuracy: 5.0** — `LEAD` is exactly the right window function for "pull next row forward". IGNORE NULLS placement claim verified against trino.io window-function docs ("`<lead or lag>(args) [ <null treatment> ] OVER (...)`", null treatment AFTER closing paren) and against r07 §1500-1625 which has an explicit DO-NOT-WRITE table listing `LEAD(col IGNORE NULLS) OVER (...)` and `LAG(col IGNORE NULLS) OVER (...)` as parse errors with the correct `LEAD(col) IGNORE NULLS OVER (...)` as the green form.
- **Clarity: 5.0** — Names the placement trap proactively, even though the question didn't ask.
- **Applicability: 5.0** — Engineer can write the query immediately.
- **Completeness: 5.0** — Answers function choice + delta computation + syntax trap.

**Avg: 5.0**

---

## Q3 — power() for compound growth + `^` operator check

**Question:** `starting_value * (1+rate)^num_periods` — does Trino have a power/exponent function like Postgres?

**Responder answer:** Yes — `power(x, p)` is the built-in (with `pow` as an alias). NO `^` operator (parse error in Trino). Canonical: `starting_value * power(1 + growth_rate, num_periods)`. Mentions related math family: `sqrt`, `ln`, `exp`, `log(base, x)`, `log10`, `log2` — all returning `double`.

**Scoring:**
- **Accuracy: 5.0** — Verified at trino.io/docs/current/functions/math.html: `power(x, p)` exists, `pow(x, p)` is documented as an alias for `power()`. The basic math operators are `+ - * / %`; `^` is NOT in Trino's math operator set (no exponent operator). Listed math functions all exist.
- **Clarity: 5.0** — Yes/no, name the function, name the trap (`^`), give the exact substitution shape.
- **Applicability: 5.0** — Drop-in for Postgres-style `^` queries.
- **Completeness: 5.0** — Touches the related math family without over-padding.

**Avg: 5.0**

---

## Q4 — `WHERE status='active'` silently drops rows after Oracle migration; trailing-space suspicion (THE BAIL)

**Question:** `SELECT DISTINCT status` shows 'active', but `WHERE status = 'active'` silently drops rows. Coworker suspects trailing spaces from Oracle. Does Trino treat `'active'` and `'active '` (trailing space) as equal?

**Responder answer:** "I don't have enough information to answer this well… the resources don't explicitly document how Trino handles trailing whitespace in string comparisons." Recommends testing with `SELECT 'active' = 'active '` and applying `WHERE TRIM(status) = 'active'` as the safe fix.

**Scoring:**
- **Accuracy: 3.5** — The FIX (`TRIM(status) = 'active'`) is correct. The diagnostic recommendation (test `'active' = 'active '`) is correct. The yes/no bail itself is not factually wrong (it's an under-confidence shave, not a falsehood). But the answer to the yes/no is a definite **NO** that follows from standard Trino VARCHAR exact-comparison semantics: VARCHAR comparison in Trino is byte-exact (NOT space-padded), so `'active' = 'active '` returns FALSE. Only CHAR(n) does PAD SPACE comparison; VARCHAR does not. (Verified against trino.io/docs/current/language/types.html — CHAR-to-VARCHAR coercion strips trailing spaces, but VARCHAR-to-VARCHAR comparison preserves trailing-space significance: `cast('Test' as varchar(20)) = cast('Test ' as varchar(25))` returns FALSE. Also corroborated by r22 §4352 which references "Trino's bytewise VARCHAR comparison" in the federation pushdown context.) Half-credit because the engineer arrives at the right action despite the explicit yes/no being hedged.
- **Clarity: 4.0** — The TRIM fix and the test-on-sample-data steps are clear, but the "I don't have enough information" framing leaves the engineer thinking the question is genuinely uncertain rather than a well-known standard-SQL semantic.
- **Applicability: 4.0** — `WHERE TRIM(status) = 'active'` is directly actionable. Minor shave: doesn't mention that wrapping `status` in TRIM defeats partition pruning / sort-key pushdown if `status` were a partition column — for a status enum that's rarely a partition column so this is bounded, and the engineer's real fix should be cleaning the data at ingest with `TRIM` in the dbt staging model. Neither caveat is named.
- **Completeness: 3.0** — The yes/no answer is bailed on, the CHAR-vs-VARCHAR distinction (which would have completed the explanation: "Trino VARCHAR is exact-comparison, only CHAR(n) pads spaces") is not surfaced, and there's no permanent-fix-at-ingest guidance beyond the ad-hoc TRIM. Core information needed by engineer is present (the FIX); the WHY (and the confident yes/no) is missing.

**Avg: 3.625**

### Q4 Bail Classification — RESOURCE-SOURCED findability gap (NOT pure responder under-confidence)

Greped resources for anchor keywords:
- "trailing space" / "trailing whitespace" — r07 §431 mentions `TRIM(tag)` for split-string-cleanup, r27 §1004 names `trim(string) → varchar` as the function reference, neither documents the comparison-semantics fact.
- "VARCHAR comparison" / "bytewise" / "exact comparison" — r22 §4352 mentions "Trino's bytewise VARCHAR comparison" but ONLY in the context of cross-source pushdown vs Postgres locale-aware collation. It's findable from "VARCHAR pushdown" not from "status='active' silently drops rows".
- "CHAR vs VARCHAR" / "pad space" — no canonical found in r23 / r27.
- "status='active'" / "silent drop after migration" / "trim status" — not anchored anywhere.

So the specific load-bearing fact ("Trino VARCHAR comparison is exact / byte-for-byte / NOT space-padded; `'active' = 'active '` is FALSE; only CHAR(n) pads; trim() to normalize") is genuinely absent from a position reachable by the question's natural keywords. The responder's hedge is the correct behavior given empty source material — it didn't fabricate. Classifying this as a resource content gap, not a responder one-off bail.

This question pattern recurs naturally: Oracle CHAR/CHAR(n) columns padded with spaces, CSV/Excel exports with stray trailing whitespace, ETL artifacts on `status` / `country_code` / `category` enums. The "post-migration WHERE silently filters" symptom is exactly the kind of question SaaS engineers ask once and remember forever once they know the answer.

### Q4 RECOMMENDATION: LIGHT FIX-A

**Where:** Add a short canonical card to r23 (SQL best practices for OLAP) in a section reachable from keyword anchors. r23 already touches "type-safe predicates" / "avoiding pushdown-breaking patterns" — fits naturally. Could also be cross-referenced from r27 §1004 (Oracle `trim` translation row).

**Keyword anchors for findability (put in the heading + first paragraph):**
- "trailing space"
- "WHERE status = 'active' silently drops rows after Oracle migration"
- "VARCHAR comparison exact / not space-padded"
- "CHAR vs VARCHAR pad space"
- "trim(status) to normalize"

**Load-bearing facts to include:**
1. Trino VARCHAR-to-VARCHAR comparison is EXACT / byte-for-byte. `'active' = 'active '` returns FALSE. (Verbatim from trino.io/docs/current/language/types.html: `cast('Test' as varchar(20)) = cast('Test ' as varchar(25))` is FALSE.)
2. This is standard SQL / Postgres VARCHAR behavior — only CHAR(n) does PAD SPACE comparison ("a" CHAR(5) is "a    "). VARCHAR is NOT padded.
3. CHAR-to-VARCHAR coercion strips trailing spaces (so CHAR 'a' = VARCHAR 'a ' is FALSE — the CHAR loses its pad, the VARCHAR keeps its space).
4. Diagnosis: `SELECT '|' || status || '|' AS bracketed, length(status) FROM t WHERE status LIKE 'active%' LIMIT 5;` shows the trailing space visibly + the length surprise.
5. Ad-hoc fix: `WHERE TRIM(status) = 'active'` works, but defeats partition pruning if `status` is a partition column (rare for an enum, common for `country_code` / `tenant_id`).
6. Permanent fix: clean the source at ingest — `TRIM(status) AS status` in the dbt staging model. Audit other VARCHAR columns from the same Oracle source at the same time.
7. Defang: do NOT recommend `LIKE 'active%'` as the fix (over-matches `'active_v2'` etc.); do NOT recommend `CAST(status AS CHAR(20))` (CHAR(n) comparison is space-padded but the workaround introduces a column-type mismatch elsewhere).

**Watch label:** `r23 VARCHAR-exact-comparison-trailing-space iter1145`. Re-probe next sweep with a variant — e.g., country_code with stray space, or CHAR-to-VARCHAR join key mismatch.

**Classification:** RESOURCE-SOURCED. LIGHT FIX-A in r23 (additive card, no in-place reconciliation needed — no existing content contradicts).

---

## Score Table

| Q | Topic | Accuracy | Clarity | Applicability | Completeness | Avg |
|---|---|---|---|---|---|---|
| Q1 | Oracle LISTAGG(DISTINCT) → array_join(array_agg(DISTINCT)) | 5.0 | 5.0 | 5.0 | 5.0 | **5.000** |
| Q2 | LEAD week-over-week + IGNORE NULLS placement | 5.0 | 5.0 | 5.0 | 5.0 | **5.000** |
| Q3 | power(x,p) / pow alias / no `^` operator | 5.0 | 5.0 | 5.0 | 5.0 | **5.000** |
| Q4 | VARCHAR exact comparison / trailing space (BAIL) | 3.5 | 4.0 | 4.0 | 3.0 | **3.625** |

**Iteration average: (5.000 + 5.000 + 5.000 + 3.625) / 4 = 4.65625**

**Verdict: PASS** (above 3.5 threshold by +1.156). LIGHT FIX-A recommended on Q4 resource gap (not a PASS-blocker).

---

## Source verification

- **Q1** verified: trino.io/docs/current/functions/aggregate.html#listagg — listagg signature `listagg(string, separator) [ON OVERFLOW ...] WITHIN GROUP (ORDER BY ...)` — no DISTINCT keyword in the grammar. Matches pinned `reference_trino_listagg_native` memory + r27 §4072-4181 LISTAGG canonical.
- **Q2** verified: trino.io/docs/current/functions/window.html — "By default, null values are respected. If IGNORE NULLS is specified, all rows where x is null are excluded from the calculation." Null treatment grammar `<window function>(args) [ <null treatment> ] OVER (...)` — placement is AFTER the args closing paren, BEFORE OVER. Matches r07 §1500-1625 DO-NOT-WRITE table.
- **Q3** verified: trino.io/docs/current/functions/math.html — `power(x, p)` documented, `pow(x, p)` is an alias. Math operators: `+ - * / %`. NO `^` exponent operator (caret is not a Trino operator at all in math context).
- **Q4** verified: trino.io/docs/current/language/types.html — VARCHAR comparison is exact, `cast('Test' as varchar(20)) = cast('Test ' as varchar(25))` returns FALSE. CHAR-to-VARCHAR coercion strips trailing spaces. CHAR-to-CHAR comparison is blank-padded. The yes/no answer to the engineer's question is a definite NO.

---

## Teacher guidance

1. **Q1/Q2/Q3 — NO-OP.** All three landed clean on the first probe. The LISTAGG-DISTINCT canonical (r27 §4072-4181) and the IGNORE-NULLS placement DO-NOT-WRITE table (r07 §1500-1625) are doing their job.

2. **Q4 — LIGHT FIX-A on r23 (SQL best practices for OLAP).** Spec above. Single additive card; no in-place reconciliation needed. Keyword-anchor on "trailing space" / "VARCHAR comparison" / "status='active' silently drops rows" so the responder lands there when this question recurs. Cross-ref from r27 §1004 trim translation row.

3. **Do NOT churn the bail.** The responder's "I don't have enough information" is the correct behavior given the resource gap. Once the FIX-A card lands, this question should answer with confident NO + TRIM fix + permanent-at-ingest fix. Re-probe next sweep with a country_code-with-space variant to confirm the card is findable from non-`status` keywords.

4. **Resource gap pattern observation:** This is one of those quiet-but-recurring SaaS-engineering questions that any Oracle/SQL-Server-to-Trino migration project hits at least once. The fix-once-mention-everywhere shape (one card with strong keyword anchors) is the right tool — don't over-engineer.
