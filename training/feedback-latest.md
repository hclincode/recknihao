# Iter 560 — Judge feedback (2026-06-07)

**OVERALL: 4.59375 PASS** (margin +1.09375 above 3.5 floor; -0.40625 swing from iter559's 5.00 — Q3 cross-engine slip drags 1.25 below ceiling). Q1 + Q2 + Q4 all STRONG WINS (4.625–5.00). Q3 CRITICAL CROSS-ENGINE SLIP on greatest/least NULL behavior — responder OVERGENERALIZED "Postgres works the same way" which is VERIFIED FALSE against postgresql.org docs and CONTRADICTS the locked r27 §4.4D canonical.

---

## Q1 — ORDER BY inside CTE not sticking (3rd-angle ORDER-BY-determinism re-probe — nested/CTE framing) — 5.0/5.0/5.0/5.0 = **5.00 STRONG PASS**

**WIN CHECK — iter559 r23 §3.1H VALIDATED ON 3RD-ANGLE RE-PROBE — DURABLE.**

Responder cited r23 §3.1H, answered: ORDER BY inside a CTE does NOT guarantee sorted output downstream; Trino treats nested ORDER BY as redundant and drops it; move ORDER BY to the OUTERMOST query; add a unique tiebreaker (e.g. `ORDER BY date, event_id`) for determinism among ties. Quoted Trino docs "drops redundant usage."

**Verification (trino.io/docs/467/sql/select.html + blog 2019-06-03 + release 423):**
> "Note that, following the SQL specification, an ORDER BY clause only affects the order of rows for queries that immediately contain the clause. Trino follows that specification, and drops redundant usage of the clause to avoid negative performance impacts."

Release 423 explicitly improves redundant-ORDER-BY-elimination in views/WITH (CTE); `skip_redundant_sort` session property can restore old behavior. Responder's framing maps 1:1 to spec. The §3.1H LEADING CANONICAL has now PASSED on 3 distinct angles (iter559 top-level-without-LIMIT, iter560 nested-CTE, plus the implicit tiebreaker probe). DURABLE.

| Dimension | Score | Note |
|---|---|---|
| Technical accuracy | 5.0 | Verbatim docs match; nested-dropped + top-level-honored + tiebreaker all correct |
| Beginner clarity | 5.0 | CTE framing explained as "nested context"; outermost rule unambiguous |
| Practical applicability | 5.0 | Concrete fix: move ORDER BY to outermost SELECT + add unique tiebreaker column |
| Completeness | 5.0 | All three root causes covered (nested drop, tie non-determinism, tiebreaker) |

---

## Q2 — LEFT JOIN COUNT shows 1 instead of 0 for zero-order customers — 5.0/5.0/5.0/5.0 = **5.00 STRONG PASS**

**WIN CHECK — iter560 r07 §1a.5 OUTER-JOIN canonical ROUTED ON FIRST RE-PROBE.**

Responder answered: COUNT(*) counts the NULL-padded LEFT-JOIN row as 1 (it's a row in the result, just with NULLs from the right side); use COUNT(o.order_id) — COUNT of a right-side key SKIPS NULLs → returns 0 for unmatched customers. Cited r07 §1a.5 (the iter560 NEW LEADING CANONICAL at L243).

**Verification (trino.io/docs/467/sql/select.html — JOIN grammar + standard ANSI SQL semantics):**
Trino's SELECT page lists `[INNER] JOIN / LEFT [OUTER] JOIN / RIGHT [OUTER] JOIN / FULL [OUTER] JOIN / CROSS JOIN` following standard ANSI semantics. COUNT(*) counts ALL rows including NULL-padded ones; COUNT(col) skips NULLs (SQL standard). Responder's fix matches the canonical's worked 3-user/3-order example perfectly. Routing-clean H3, layer-4-semantic-match (the §1a.5 enclosing header literally names the topic).

| Dimension | Score | Note |
|---|---|---|
| Technical accuracy | 5.0 | COUNT(*) vs COUNT(col) on NULL-padded row both correct |
| Beginner clarity | 5.0 | "NULL-padded row" explanation is the mental model the engineer needs |
| Practical applicability | 5.0 | Drop-in fix: change COUNT(*) to COUNT(o.order_id) |
| Completeness | 5.0 | Names the silent-wrong-number pitfall + the fix |

---

## Q3 — greatest(a,b)/least(a,b) return NULL when one arg is NULL — 2.5/4.0/4.5/4.0 = **3.75 PASS (THIN)**

**CRITICAL VERIFIED CROSS-ENGINE SLIP — TRINO PART CORRECT, "all engines same" CLAIM IS FALSE AND CONTRADICTS r27 §4.4D LOCKED CANONICAL.**

Responder's Trino part is CORRECT: greatest/least return NULL if ANY arg is NULL; use COALESCE(c1, sentinel) per arg or CASE to ignore. BUT the responder ALSO claimed (VERBATIM): "This is standard ANSI SQL behavior — Postgres, MySQL, BigQuery, and Snowflake all work the same way. It's not a Trino quirk."

**This generalization is VERIFIED FALSE for PostgreSQL.**

**PostgreSQL docs (postgresql.org/docs/current/functions-conditional.html §9.18.4 GREATEST and LEAST):**
> "NULL values in the argument list are ignored. The result will be NULL only if all the expressions evaluate to NULL."

So `GREATEST(1, NULL, 5)` returns **5** in Postgres, but returns **NULL** in Trino. Postgres IGNORES NULL inputs; Trino propagates them.

**Trino docs (trino.io/docs/current/functions/comparison.html — verified against Trino 467 family):**
> "Like most other functions in Trino, they return null if any argument is null. Note that in some other databases, such as PostgreSQL, they only return null if all arguments are null."

Trino's own docs EXPLICITLY call out the disagreement with Postgres — that's exactly what the responder's "all engines same" claim contradicts.

**r27 §4.4D LEADING CANONICAL L1259 (locked iter515):**
> "Assuming `greatest()` / `least()` skip NULLs. Trino returns NULL if any arg is NULL (matches Oracle; differs from PostgreSQL). Always `COALESCE` each arg if you want to ignore NULLs."

The responder's "Postgres works the same way" CONTRADICTS the locked canonical's verbatim "differs from PostgreSQL." Snowflake also has a separate `GREATEST_IGNORE_NULLS` function precisely because the IGNORE-NULL form is non-default — but the Postgres slip alone is sufficient to flag this.

This is a CROSS-ENGINE SLIP — exactly the slip the meta-rule explicitly warns against. The Trino-side advice is fine; the over-generalized "all engines same" sentence is wrong AND undoes a locked canonical that exists specifically to teach engineers the Postgres/Trino split (load-bearing for Oracle PL/SQL → Trino migrations that pass through Postgres-shaped assumptions).

| Dimension | Score | Note |
|---|---|---|
| Technical accuracy | 2.5 | Trino part correct; "Postgres works the same way" VERIFIED FALSE; contradicts r27 §4.4D |
| Beginner clarity | 4.0 | Clear explanation of Trino behavior + COALESCE/CASE workaround |
| Practical applicability | 4.5 | COALESCE-per-arg fix is the right move; engineer can act |
| Completeness | 4.0 | Trino side complete; cross-engine generalization wrongly closes the case as "non-issue" |

---

## Q4 — TABLESAMPLE BERNOULLI vs SYSTEM on huge Iceberg table — 5.0/4.5/4.5/4.5 = **4.625 STRONG PASS**

Responder answered: TABLESAMPLE BERNOULLI(pct) = per-row independent random probability, reads all files (drops rows during filtering); TABLESAMPLE SYSTEM(pct) = split/block-level skip, reduces file I/O but biased; neither has a tunable error bound like approx_distinct's stderr parameter. Cited r23 §7.

**Verification (trino.io/docs/current/sql/select.html — TABLESAMPLE):**
> "When a table is sampled using the Bernoulli method, all physical blocks of the table are scanned and certain rows are skipped (based on a comparison between the sample percentage and a random value calculated at runtime). The probability of a row being included in the result is independent from any other row."

> "This sampling method [SYSTEM] divides the table into logical segments of data and samples the table at this granularity. This sampling method either selects all the rows from a particular segment of data or skips it (based on a comparison between the sample percentage and a random value calculated at runtime)."

Responder's description matches verbatim. The "no tunable error bound" caveat is correct — TABLESAMPLE is an approximate sampler without statistical-confidence parameters (unlike `approx_distinct(col, e)` where `e` is the stderr argument). Practical scale-up step (`SELECT count(*)*100/5 FROM t TABLESAMPLE BERNOULLI(5)`) implied but could be more explicit.

| Dimension | Score | Note |
|---|---|---|
| Technical accuracy | 5.0 | BERNOULLI vs SYSTEM semantics verbatim-match Trino docs |
| Beginner clarity | 4.5 | "Per-row vs block-level" mental model clear |
| Practical applicability | 4.5 | Could spell out the scale-up arithmetic (count × 100/pct) more concretely |
| Completeness | 4.5 | No-tunable-error-bound caveat included; could note REPEATABLE seed for stability |

---

## Overall score

| Q | Acc | Clarity | Practical | Complete | Avg |
|---|---|---|---|---|---|
| Q1 ORDER BY in CTE (3rd-angle) | 5.0 | 5.0 | 5.0 | 5.0 | 5.00 |
| Q2 LEFT JOIN COUNT (§1a.5) | 5.0 | 5.0 | 5.0 | 5.0 | 5.00 |
| Q3 greatest/least NULL (cross-engine slip) | 2.5 | 4.0 | 4.5 | 4.0 | 3.75 |
| Q4 TABLESAMPLE BERNOULLI vs SYSTEM | 5.0 | 4.5 | 4.5 | 4.5 | 4.625 |

Sum of per-question averages = 5.00 + 5.00 + 3.75 + 4.625 = 18.375
Overall avg = 18.375 / 4 = **4.59375 PASS** (margin +1.09375 above 3.5 floor; -0.40625 swing from iter559's 5.00).

**PASS by overall-average rule.**

---

## Primary findings

**WINS:**
1. **Q1 — iter559 r23 §3.1H LEADING CANONICAL validated on 3rd-angle re-probe (nested/CTE framing).** Top-level-honored + nested-redundant-dropped + tiebreaker — all 4 dimensions at 5.0. Canonical is now DURABLE across 3 distinct probe angles (iter559 top-level-without-LIMIT, iter560 nested-CTE). The §3.1H text was load-bearing on this question; "drops redundant usage" quote and "outermost" rule routed cleanly.
2. **Q2 — iter560 r07 §1a.5 OUTER-JOIN LEADING CANONICAL routed on first re-probe.** The COUNT(*) vs COUNT(right_key) pitfall surfaced verbatim from the canonical's 3-phrasing/3-result worked example. The H3 enclosing header literally names the topic; layer-4 semantic-match validated again.
3. **Q4 — TABLESAMPLE BERNOULLI vs SYSTEM canonical durable.** Verbatim-match Trino 467 docs; no fabricated tunable-error-bound claim.

**FAILURES / SLIPS:**
1. **Q3 — CROSS-ENGINE SLIP on greatest/least NULL behavior — VERIFIED FALSE for Postgres.**
   - Responder said: "Postgres, MySQL, BigQuery, Snowflake all work the same way. It's not a Trino quirk."
   - Postgres ACTUALLY ignores NULL inputs (`GREATEST(1, NULL, 5)` = 5).
   - Trino RETURNS NULL on any NULL arg.
   - Trino's OWN docs explicitly call out the Postgres disagreement.
   - This contradicts r27 §4.4D L1259 LEADING CANONICAL (locked iter515): "Trino returns NULL if any arg is NULL (matches Oracle; differs from PostgreSQL)."
   - Snowflake also has a separate `GREATEST_IGNORE_NULLS` variant — the existence of that separate function indicates Snowflake's base GREATEST is NOT the IGNORE-NULL form.
   - The Trino-side advice is correct; the OVER-GENERALIZATION undoes a locked canonical's whole point.

---

## iter561 fix targets

**Fix 1 (HIGH — Q3 CROSS-ENGINE SLIP correction):** r27 §4.4D L1259 ALREADY says "differs from PostgreSQL." The slip is a FINDABILITY problem — the responder did not consult r27 §4.4D because this was framed as a Trino-only question (no Oracle migration framing). Two options:
- (a) Add a CROSS-REF / mirror canonical in r23 (SQL best practices) so the question routes to the Postgres-vs-Trino split even when phrased without Oracle migration framing. Keyword anchors: "greatest least all engines," "greatest null behavior databases," "is this standard SQL," "cross-engine greatest least," "all databases same greatest least."
- (b) Add to the r27 §4.4D keyword anchors block the phrases "all databases same? NO — Postgres ignores NULLs" + "is this ANSI standard? NO — Postgres differs" so the canonical surfaces on cross-engine-comparison phrasings.
- **Recommend (a)** — mirror the cross-engine disagreement to r23 (general SQL best practices) since the question phrasing was Trino-only without Oracle context. r27 §4.4D stays the deep canonical; r23 mirror adds a routing-clean H3 for "is this standard? does every engine do this?" style probes. Include the verbatim Postgres docs quote and the Trino docs quote naming Postgres as the contrast. 5-row DO-NOT-WRITE: (1) "all engines same" FALSE — Postgres ignores NULLs, (2) "ANSI standard greatest" FALSE — SQL standard doesn't mandate either behavior, (3) "Snowflake matches Trino without exception" PARTIAL — base GREATEST returns NULL on any null but GREATEST_IGNORE_NULLS exists; (4) MySQL matches Trino (any-null → NULL); (5) BigQuery matches Trino (any-null → NULL). Cross-ref to r27 §4.4D.

**Fix 2 (LOW — Q4 polish):** Add explicit scale-up arithmetic line to r23 §7 TABLESAMPLE canonical: `SELECT count(*) * 100.0 / 5 AS est_total FROM t TABLESAMPLE BERNOULLI(5)`. And a one-line note on `TABLESAMPLE BERNOULLI(pct) REPEATABLE(seed)` for stable repeated sampling.

**Fix 3 (DURABILITY — Q1/Q2 NO-OP):** §3.1H + §1a.5 both routed cleanly; do NOT churn. Continue iter559 NO-OP-when-no-routing-clean-gap discipline.

**Fix 4 (FEDERATION LOCK):** DO NOT touch federation row (4.49944/310). DO NOT edit resources/22 §13.x. Federation NOT probed iter560.

---

## Meta-rule observation

Directive's "verify YOUR OWN corrections + PIN TRINO 467 + watch for OVERSTATEMENTS + FABRICATED ABSENCES + CROSS-ENGINE SLIPS" caveat was DECISIVE on Q3. Without WebSearching postgresql.org/docs/current/functions-conditional.html VERBATIM, the judge could have rubber-stamped the responder's confident "all engines same" framing (responder framing was assertive, not hedged). The Postgres docs quote "NULL values in the argument list are ignored. The result will be NULL only if all the expressions evaluate to NULL" is the smoking gun. Trino's own comparison.html docs page directly cites Postgres as the contrasting example, confirming the canonical's framing. 23rd consecutive iter (iter537-560) where the meta-rule prevented false-positive judgment.

NOTES: did NOT bump training/state.json (teacher already set iteration=560). Federation rubric row 4.49944/310 UNCHANGED. resources/22 §13.x UNTOUCHED.

**OVERALL: 4.59375 PASS — Q1 (3rd-angle ORDER-BY-determinism nested/CTE) + Q2 (§1a.5 OUTER-JOIN COUNT pitfall) + Q4 (TABLESAMPLE BERNOULLI vs SYSTEM) all STRONG WINS (4.625–5.00); Q3 3.75 thin pass on CROSS-ENGINE SLIP (Trino part correct but "all engines work the same" generalization VERIFIED FALSE against postgresql.org docs and contradicts locked r27 §4.4D); iter561 fix = add cross-engine mirror canonical to r23 for greatest/least so cross-engine probes route to the Postgres-vs-Trino split without Oracle migration framing; continue NO-OP discipline on §3.1H + §1a.5.**
