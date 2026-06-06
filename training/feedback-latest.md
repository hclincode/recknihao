# Iter 538 Feedback — 2026-06-06 (EXTENDED PHASE)

## Verdict

**Overall avg = 4.531 → PASS** (margin +1.031 above 3.5 floor). 133rd consecutive overall PASS in extended phase.

Per-question: Q1 = 4.625, Q2 = 5.000, Q3 = **3.500 (CRITICAL ROUNDING-MODE FAB — see below)**, Q4 = 5.000.

Federation NOT probed — rubric row 4.49944/310 untouched.

---

## Q1 — Dedupe with ROW_NUMBER over (user_id, event_type, event_timestamp) — 4.625 STRONG PASS

**Per-dimension**: Accuracy 4.5, Completeness 4.5, Clarity 4.5, Actionability 5.0.

- ROW_NUMBER() OVER (PARTITION BY ... ORDER BY inserted_at DESC) in a subquery + WHERE rn = 1 is the canonical Trino 467 idiom — verified at trino.io/docs/current/functions/window.html (window functions including ROW_NUMBER are supported) + trino.io/docs/current/sql/select.html (no QUALIFY clause exists in Trino, so the subquery form is exactly what's needed). Correct.
- rn <= N for top-N per group — correct, useful extension.
- CTAS-rebuild + rename for in-place Iceberg dedup — sound advice. Trino on Iceberg v2 *does* support row-level DELETE by predicate (`DELETE FROM ... WHERE …`), but for "delete duplicates keeping only the most recent per combo" you cannot express that as a single-predicate DELETE — you need either MERGE or CTAS-rebuild because the deletion criterion is per-group, not per-row. Responder's "no stable row id" framing is slightly imprecise but lands on the right workflow.

**Minor slip**: "no stable row id for a simple DELETE" is imprecise but lands on the correct answer. Score not penalized aggressively.

---

## Q2 — ROLLUP / GROUPING bitmask — 5.000 STRONG PASS

**Per-dimension**: Accuracy 5.0, Completeness 5.0, Clarity 5.0, Actionability 5.0.

**CRITICAL VERIFY (per directive): bitmask values for GROUPING(plan, region) with ROLLUP(plan, region)**:

Verified at trino.io/docs/current/sql/select.html via WebFetch verbatim: "Trino also supports complex aggregations using the `GROUPING SETS`, `CUBE` and `ROLLUP` syntax" + "`grouping(col1, ..., colN) -> bigint` The grouping operation returns a bit set converted to decimal, indicating which columns are present in a grouping" + **"To compute the resulting bit set for a particular row, bits are assigned to the argument columns with the rightmost column being the least significant bit. For a given grouping, a bit is set to 0 if the corresponding column is included in the grouping and to 1 otherwise."**

So for `GROUPING(plan, region)` (leftmost = plan = high bit; rightmost = region = low bit):
- detail row (both columns present): binary 00 = **0** correct
- plan subtotal (region rolled up, plan present): binary 01 = **1** correct
- grand total (both rolled up): binary 11 = **3** correct
- region-only (plan rolled up, region present) under CUBE: binary 10 = **2** correct (responder noted CUBE adds this fourth combination)

Responder's 0/1/3 mapping for ROLLUP is **EXACT**. ROLLUP correctly skips 2 because it only rolls up right-to-left (region rolls up first, then plan — never plan-without-region). CUBE adds 2. CASE GROUPING(...) labeling pattern is clean. ORDER BY GROUPING(...), plan NULLS LAST, region NULLS LAST is correct (Trino default is NULLS LAST regardless of direction — verified at trino.io iter537).

No fabrication. Bulletproof answer.

---

## Q3 — CAST FLOAT → DECIMAL rounding for billing — 3.500 PASS w/ CRITICAL ROUNDING-MODE FAB

**Per-dimension**: Accuracy 2.0, Completeness 4.0, Clarity 4.5, Actionability 3.5.

### CRITICAL VERIFICATION RESULT: BANKER'S ROUNDING CLAIM IS A FABRICATION

The responder asserted: "Trino uses BANKER'S ROUNDING (round-half-to-even). So 123.456 becomes 123.46 and 123.454 becomes 123.45."

**Verification (Trino source code, DecimalConversions.java at github.com/trinodb/trino)**:

```java
import static java.math.RoundingMode.HALF_UP;

// internalDoubleToLongDecimal:
BigDecimal bigDecimal = BigDecimal.valueOf(value).setScale(intScale(scale), HALF_UP);

// realToLongDecimal:
BigDecimal bigDecimal = new BigDecimal(String.valueOf(floatValue)).setScale(intScale(scale), HALF_UP);
```

Trino uses **`RoundingMode.HALF_UP`** (round-half-away-from-zero for positive values) for ALL four DOUBLE/REAL → DECIMAL cast paths. This is the **opposite** of banker's rounding (HALF_EVEN).

VARCHAR-to-DECIMAL (separate cast path) also uses HALF_UP — confirmed at DecimalCasts.java verbatim: `result = new BigDecimal(stringValue).setScale(DecimalConversions.intScale(scale), HALF_UP)`.

Note: the official trino.io docs (decimal.html, types.html, conversion.html) do NOT explicitly document the rounding mode — multiple WebFetches confirmed this gap. The source code is the authoritative reference.

### Why the responder's examples don't disprove either rule

The two examples (123.456 → 123.46, 123.454 → 123.45) are NOT tie-break cases at the rounding digit:
- 123.456 at scale=2: the digit-after is 6, which rounds up under both HALF_UP and HALF_EVEN.
- 123.454 at scale=2: the digit-after is 4, which rounds down under both HALF_UP and HALF_EVEN.

The clean tie cases that distinguish the two are `0.5 → ?` (HALF_UP: 1; HALF_EVEN: 0) and `2.5 → ?` (HALF_UP: 3; HALF_EVEN: 2). The responder's examples happen to be consistent with BOTH rules — so the worked numbers do not prove the responder's named rule.

### Billing-context impact (this is why Accuracy is hit hard)

For a billing pipeline rounding to DECIMAL(18,2):
- $0.005 under HALF_UP (Trino's actual behavior) → $0.01 (always rounds up at exact .5)
- $0.005 under HALF_EVEN (what the responder claimed) → $0.00 (rounds to even)

A SaaS engineer reading "Trino uses banker's rounding" will reconcile against the wrong rule and either:
1. Build incorrect mental tests that pass spuriously (the responder's own non-tie examples), or
2. Be confused when their actual Trino output doesn't match the banker's-rounding mental model on tie values.

The "round half away from zero" rule is the simple, well-known billing rule and matches Postgres `numeric(p, s)` cast behavior — calling it "banker's" inverts the meaning.

### What IS correct in the answer

- "Trino does NOT silently wrap on overflow; overflow raises NUMERIC_VALUE_OUT_OF_RANGE" — CORRECT. Verified at trino.io/docs/current/functions/decimal.html and trinodb/trino#20227 ("the expected user-facing error for decimal overflow conditions").
- DECIMAL(18,2) being a sensible billing default — CORRECT.

### Score rationale

- Accuracy 2.0: rounding-mode mode-name FAB is billing-load-bearing. Other claims (overflow, scale, hard-error) are correct.
- Completeness 4.0: covered overflow, scale choice, default precision — missing the "verify with `SELECT CAST(...)` empirical probe" recommendation that would have caught the FAB itself.
- Clarity 4.5: explanation flows well; the (wrong) examples are clearly stated.
- Actionability 3.5: dropped because following the recipe gives a wrong mental model for tie cases.

---

## Q4 — dbt exposures — 5.000 STRONG PASS

**Per-dimension**: Accuracy 5.0, Completeness 5.0, Clarity 5.0, Actionability 5.0.

Verified at docs.getdbt.com/docs/build/exposures via WebFetch verbatim:
- "Exposures make it possible to define and describe a downstream use of your dbt project, such as in a dashboard, application, or data science pipeline."
- Required fields: `name` (snake_case), `type` (one of `dashboard`, `notebook`, `analysis`, `ml`, `application`), `owner` (must include `name` or `email`). Expected: `depends_on` (list of `ref`, `source`, `metric`). Optional: `url`, `description`, `maturity`, `label`.
- `dbt run -s +exposure:weekly_jaffle_report` / `dbt test -s +exposure:weekly_jaffle_report` selector syntax confirmed verbatim.
- Exposures are metadata constructs (not enforced contracts); they surface in the dbt docs site DAG with an 'EXP' indicator and enable impact analysis.

Responder's distinction from `contracts` (contract = schema enforcement at build time / not_null can be runtime-enforced via Iceberg column constraint; exposure = non-enforcing downstream-consumer metadata) is correct and pedagogically useful. The YAML example shape (name/type/depends_on with ref()/owner with name+email/url/description) matches the doc canonical exactly. The `dbt ls -s +exposure:name` selector is correct.

No fabrication. Bulletproof.

---

## Topic average updates

- **SQL query best practices for OLAP** (Q1 ROW_NUMBER dedup + Q3 CAST DECIMAL rounding cluster): 4.5385/102 → (4.5385·102 + 4.625 + 3.500)/104 = 471.052/104 = **4.5293/104** (-0.0092 — Q3 FAB drags below topic average; Q1 above lifts partially).
- **Common analytical query patterns** (Q2 ROLLUP/GROUPING multi-level subtotals cluster): 4.7331/14 → (4.7331·14 + 5.000)/15 = 71.2634/15 = **4.7509/15** (+0.0178 — Q2 perfect above topic avg).
- **dbt model contracts** (Q4 exposures cluster — closest semantic match is the dbt-build-metadata family but the contracts row covers ENFORCEMENT semantics specifically; exposures are NON-enforcing). **No topic row update for Q4** to avoid mis-attribution — exposures are out-of-scope for the contracts row's enforcement semantics. Small rubric-coverage gap noted for future iters (no dbt-exposures-specific row exists yet).

Federation row UNCHANGED at 4.49944/310 per iter472-538 directive.

---

## PRIMARY ITER539 FIX TARGET (HIGH — billing-critical)

### FIX A — Trino DECIMAL-cast rounding-mode canonical + DO-NOT-WRITE banner against "banker's rounding"

**Where**: resources/23-sql-best-practices-olap.md (DECIMAL section) OR resources/07-analytical-query-patterns.md DECIMAL/billing block, whichever the responder's keyword path hits first. Use the iter534 signal-INSIDE-the-line strategy.

**Canonical to add (verbatim — recommended text)**:

> **Trino DECIMAL-cast rounding mode**
> Trino uses **`HALF_UP`** (round-half-away-from-zero for positive values) when casting `DOUBLE`/`REAL`/`FLOAT`/`VARCHAR` → `DECIMAL(p, s)`. This is **NOT banker's rounding** (`HALF_EVEN`).
>
> Source: `DecimalConversions.java` (`internalDoubleToLongDecimal`, `realToLongDecimal`) and `DecimalCasts.java` (VARCHAR path) all `import static java.math.RoundingMode.HALF_UP;` and call `.setScale(intScale(scale), HALF_UP)`. The trino.io docs do not explicitly document the rounding mode — the source code is the authoritative reference.
>
> **Tie-case examples (HALF_UP, what Trino actually does)**:
> ```sql
> SELECT CAST(DOUBLE '0.5'   AS DECIMAL(1, 0));  -- 1     (NOT 0)
> SELECT CAST(DOUBLE '2.5'   AS DECIMAL(2, 0));  -- 3     (NOT 2 — banker's would give 2)
> SELECT CAST(DOUBLE '0.005' AS DECIMAL(3, 2));  -- 0.01  (NOT 0.00 — billing-load-bearing)
> SELECT CAST(DOUBLE '0.015' AS DECIMAL(3, 2));  -- 0.02  (NOT 0.01 — billing-load-bearing)
> ```
>
> **DO-NOT-WRITE**: do not describe Trino's cast rounding as "banker's rounding" or "round-half-to-even" or "HALF_EVEN". Trino's cast uses HALF_UP. (Postgres `numeric` cast also uses HALF_UP; only some accounting/financial libraries default to HALF_EVEN.)
>
> **Overflow** (separately, also non-silent): `CAST(DOUBLE '1e20' AS DECIMAL(10,2))` raises `NUMERIC_VALUE_OUT_OF_RANGE` — hard error, not silent wrap.
>
> **Verification probe (always advise)**: when in doubt about how a specific value rounds, run a 1-line `SELECT CAST(...)` empirically before trusting any mental rule.

**Keyword anchors** (inline in the canonical for the Haiku responder's keyword-match path): "Trino DECIMAL cast rounding / Trino CAST DOUBLE to DECIMAL / banker's rounding Trino / round half to even Trino / round half up Trino / Trino billing decimal / DECIMAL(18,2) billing / HALF_UP HALF_EVEN Trino".

**Signal-INSIDE-the-line strategy** (per iter534 precedent that broke a 3-iter recurrence): in any SQL block showing `CAST(... AS DECIMAL(...))` for billing context, add an EOL comment: `-- HALF_UP (NOT banker's; 0.5 -> 1)`.

---

## SECONDARY ITER539 FIX TARGETS (LOW)

### FIX B (LOW — Q1 minor framing) — "Iceberg DELETE for dedup" clarification

In the Iceberg-on-Trino DML resource (r17 or wherever DELETE on Iceberg v2 is discussed), add a short note:

> For "dedup keeping only the most recent per group", a single-predicate `DELETE` is not expressible — the criterion is per-group, not per-row. Use either MERGE-style logic (`MERGE INTO target USING (SELECT … ROW_NUMBER() OVER … WHERE rn = 1) AS src ON …`) or CTAS-rebuild + RENAME. Trino does support `DELETE FROM iceberg_table WHERE <predicate>` on Iceberg v2 — it just cannot express "delete duplicates" in one predicate.

Not load-bearing; the responder's CTAS-rebuild advice is correct, just slightly imprecisely framed.

---

## NO FIXES NEEDED

- Q2 ROLLUP/GROUPING bitmask — bulletproof (5.000).
- Q4 dbt exposures — bulletproof (5.000).

---

## Iter539 probe targets

1. **HIGH — DECIMAL cast rounding 2nd angle (verifies FIX A landing)**: "I cast a DOUBLE column with value 0.005 to DECIMAL(3,2) for billing — what value do I get? Is it banker's rounding?" (direct tie-case probe — must answer 0.01 + must NOT say banker's). Alternative angle: "is Trino's CAST consistent with Postgres for monetary rounding?"
2. **MEDIUM — DECIMAL cast overflow 2nd angle (durability of correct claim)**: "what happens if my DOUBLE is 1e20 and I cast to DECIMAL(10,2) — does Trino silently wrap?"
3. **LOW — ROW_NUMBER dedup 2nd angle (well-bulletproofed)**: "I have a Kafka events table where the same primary_key was reprocessed multiple times — give me the SQL to get the latest version per key in Trino."
4. **LOW — dbt exposures 2nd angle (well-bulletproofed)**: "what's the difference between a dbt exposure and a dbt source?" OR "can I run `dbt build` only on models that feed a specific exposure?"
5. **LOW — GROUPING bitmask 3-arg angle**: "if I have `GROUP BY CUBE(plan, region, channel)` how do I label the row that is plan+channel total (region rolled up)?" (tests 3-arg bitmask understanding — bit pattern 010 = 2).
6. **UNPROBED — Federation row stays 4.49944/310** (per iter472-538 directive).

---

## Meta-rule observation

The directive's "verify YOUR OWN corrections before asserting" caveat was DECISIVE this iteration. Without source-code verification, a judge could plausibly have either:
- (a) accepted the responder's "banker's rounding" claim because it sounds technically authoritative and the non-tie examples don't contradict it, OR
- (b) overcorrected with an unverified counter-claim.

Both would be wrong. The correct answer — `HALF_UP`, sourced from DecimalConversions.java — required direct repo verification because trino.io docs (decimal.html, types.html, conversion.html) do NOT explicitly document the rounding mode (multiple WebFetches confirmed this gap). The Trino docs gap itself is worth noting in the teacher canonical: cite the source code, not just a doc URL.

This is the second consecutive iter (after iter537 NULLS-LAST direct-verification) where the meta-rule prevented a false-positive correction in either direction. Continue applying.
