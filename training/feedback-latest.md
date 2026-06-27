# Iter1157 — Judge Feedback

**Verdict: STRONG PASS NO-OP. Both iter1156 watches CLOSE.**

Iter average = (5.00 + 5.00 + 5.00 + 4.75) / 4 = **4.9375 STRONG PASS** (margin +1.4375; recovery from iter1156's 3.656 thinnest-in-30-iter pass). All four answers pin-perfect or near-pin-perfect. Both iter1156 LIGHT-FIX-A/watch re-probes confirmed reaching the canonical.

| Q | Score | Status | Notes |
|---|---|---|---|
| Q1 literal underscore in LIKE pattern | **5.00** | STRONG PASS — **watch `r23 LIKE-ESCAPE findability bail iter1156` CLOSES** | `LIKE '%\_%' ESCAPE '\'` lifted verbatim from r23 §3493 canonical (the underscore-twin example). Regex framed correctly as overkill ("regex is overkill for a single wildcard literal; LIKE...ESCAPE for percent/underscore literals; switch to regexp_like only for character classes/anchors/quantifiers"). No bail. FIX-A reached. |
| Q2 single company-wide weighted avg rating | **5.00** | STRONG PASS — **watch `r23 §3.1B-WA weighted-avg single-overall-vs-per-group grain-misread iter1156` CLOSES** | `SUM(rating*review_count)*1.0/NULLIF(SUM(review_count),0) FROM products` — **NO GROUP BY**, explicit "returns ONE row with the single company-wide average". Integer-division *1.0 caveat + NULLIF div-by-zero guard present. Drops the spurious iter1156 GROUP BY. |
| Q3 detect Infinity/NaN in DOUBLE rate column | **5.00** | STRONG PASS | `WHERE NOT is_finite(rate)` catches both Inf+NaN; `IF(is_finite(rate), rate, NULL)` to replace inline. is_finite/is_infinite/is_nan table correct. Critical distinction included: only for DOUBLE/REAL; INTEGER/DECIMAL `/` by zero ERRORS (no Inf/NaN) — guard with NULLIF or try(). Matches pinned `reference_trino_division_by_zero`. |
| Q4 Oracle temp tables → dbt/Trino | **4.75** | PASS | Two-pattern guidance: (A) small intermediate = CTE within one model; (B) large/reused = separate `materialized='table'` intermediate model referenced via `ref()`. Idiomatic. Minor over-generalization on "atomic Iceberg snapshot, rolls back on failure" (default `on_table_exists='rename'` is multi-step; `'replace'` is single atomic CREATE OR REPLACE). Not load-bearing for the question. |

---

## Q1 — literal underscore in LIKE (watch CLOSES)

### Engineer's framing

`coupon_codes(code)` with rows like `SAVE_10`, `BULK_50`. `WHERE code LIKE '%_%'` returns everything because `_` is a single-char wildcard. How to match only rows whose code contains a **real** underscore?

### Responder's answer (verbatim shape)

```sql
WHERE code LIKE '%\_%' ESCAPE '\';
-- the \_ is a literal underscore; ESCAPE '\' names backslash as the escape char
-- any char can be the escape (e.g. ESCAPE '!' with '%!_%')
```

Plus explicit framing: *"Why not regex? Regex is overkill for a single wildcard literal. Use LIKE...ESCAPE for percent/underscore literals; switch to regexp_like only for character classes/anchors/quantifiers."*

### Verification

[trino.io/docs/467/functions/comparison.html](https://trino.io/docs/467/functions/comparison.html) LIKE clause section:
> Syntax: `... column [NOT] LIKE 'pattern' ESCAPE 'character';`
> "The wildcard characters `_` and `%` must be escaped to allow you to match them as literals. This can be achieved by specifying the `ESCAPE` character to use."

Doc example uses `'South\_America' LIKE 'South\_America' ESCAPE '\'` (literal underscore in name). Responder's `'%\_%' ESCAPE '\'` is the same pattern wrapped in wildcard `%...%` for "contains" semantics. Correct.

### Watch outcome — CLOSES

Iter1156 LIGHT FIX-A added: (1) top-of-file Common myths entry naming "Trino LIKE has no way to match a literal `%` or `_` — drop to regex" as FALSE with canonical + cross-ref to §3493; (2) closing sentence on §3491 regex-box pointing to §3493 for literal-wildcard matching; (3) additional keyword anchors at §3495 including "match a literal underscore". The underscore-different-framing re-probe confirms all three reaches: the responder named LIKE ESCAPE as the LEAD (not a bail to regex), gave the underscore canonical verbatim, and explicitly framed regex as overkill (matching the §3491-defang language). FIX-A reached. **CLOSE watch.**

Scores: Acc 5.0 / Clar 5.0 / App 5.0 / Compl 5.0 = **5.00 STRONG PASS**.

---

## Q2 — single overall weighted average (watch CLOSES)

### Engineer's framing

One row per product with `avg_rating` and `review_count`. Want a SINGLE company-wide weighted average rating where a 10,000-review product influences more than a 5-review one. **"Literally ONE row for the whole company, not one per product."**

### Responder's answer

```sql
SELECT
  SUM(rating * review_count) * 1.0 / NULLIF(SUM(review_count), 0) AS company_avg_rating
FROM products;
```

Explicit text: "Returns ONE row with the single company-wide average." NO GROUP BY. Integer-division `*1.0` caveat present. NULLIF divide-by-zero guard present.

### Verification

- [trino.io/docs/467/functions/math.html](https://trino.io/docs/467/functions/math.html) — integer `/` truncation behavior confirms `*1.0` lift to DOUBLE.
- [trino.io/docs/467/functions/conditional.html](https://trino.io/docs/467/functions/conditional.html) — `nullif(value1, value2) returns null if value1 equals value2, otherwise value1` — correct guard semantics.
- Bare aggregate SELECT with no GROUP BY (ANSI standard, single overall row) — supported in Trino 467 (and every SQL engine).
- r23 §3.1B-WA canonical match — verbatim shape.

### Watch outcome — CLOSES

Iter1156 the responder added a spurious `GROUP BY endpoint_name`, returning one row per endpoint instead of one company-wide row. Watch was classified NO-OP (per `feedback_synthesis_ceiling_stop_churning.md`) because the canonical itself is correct and the slip was a Haiku synthesis-ceiling grain misread. Iter1157 re-probe with explicit "literally ONE row for the whole company, not one per product" framing — responder correctly drops the GROUP BY and produces the single-overall shape. One-off classification confirmed. **CLOSE watch.** No resource fix; no over-attractor card needed.

Scores: Acc 5.0 / Clar 5.0 / App 5.0 / Compl 5.0 = **5.00 STRONG PASS**.

---

## Q3 — Infinity/NaN detection in DOUBLE column

### Engineer's framing

`metrics(rate DOUBLE)`; some rows show Infinity or NaN. `WHERE rate > 999999` doesn't catch Infinity. How to test for these special states and filter/replace with NULL?

### Responder's answer

```sql
-- filter out
WHERE NOT is_finite(rate);
-- replace inline
SELECT IF(is_finite(rate), rate, NULL) AS rate_clean FROM metrics;
```

Plus a three-row table: `is_finite` (true if normal number, not Inf/NaN), `is_infinite` (Inf or -Inf), `is_nan` (NaN). Critical caveat included: this is only for DOUBLE/REAL; for INTEGER/DECIMAL, `/` by zero THROWS DIVISION_BY_ZERO — guard with `NULLIF(denom, 0)` or `try(numer/denom)`. Cites r27.

### Verification

[trino.io/docs/467/functions/math.html](https://trino.io/docs/467/functions/math.html) Floating Point Functions:
- `is_finite(x) → boolean` "Determine if x is finite."
- `is_infinite(x) → boolean` "Determine if x is infinite."
- `is_nan(x) → boolean` "Determine if x is not-a-number."
- `infinity() → double`, `nan() → double` — Trino DOUBLE supports IEEE-754 Inf/NaN.

`NOT is_finite(x)` catches both Inf AND NaN in a single predicate (IEEE-754: finite ≡ not-Inf AND not-NaN). Correct.

The integer/decimal division-by-zero ERRORS vs DOUBLE/REAL Infinity/NaN distinction matches pinned `reference_trino_division_by_zero`: INTEGER/DECIMAL `/` by zero THROWS DIVISION_BY_ZERO; DOUBLE/REAL `/` by zero returns IEEE-754 ±Infinity or NaN. Verified r27 §4.4H is correct.

Scores: Acc 5.0 / Clar 5.0 / App 5.0 / Compl 5.0 = **5.00 STRONG PASS**.

---

## Q4 — Oracle global temp tables → dbt/Trino

### Engineer's framing

Oracle global temporary table = scratch table written partway through a procedure, read in a later step. Trino has no temp-table concept. Idiomatic way to restructure logic that relied on temp tables as intermediate storage?

### Responder's answer

Pattern A (small intermediate, used once): a CTE within one dbt model: `WITH enriched AS (...) SELECT ... FROM enriched ...`.

Pattern B (large intermediate, reused or expensive): a separate materialized intermediate model `int_orders_enriched` config'd `materialized='table'`, referenced downstream via `ref('int_orders_enriched')`. Cursor loops → LEFT JOIN/CASE; multi-step → multiple models chained via ref().

Plus "each dbt model materializes as an atomic Iceberg snapshot (rolls back on failure)" sentence.

### Verification

Two-pattern decomposition is correct and idiomatic for Oracle PL/SQL → dbt/Trino migration:
- CTE-within-model for in-query intermediate scratch — standard.
- Intermediate model + ref() chaining — dbt-idiomatic; matches r27 / r28 guidance.

**Minor over-generalization on atomicity** (-0.5 Acc / -0.5 Compl): [docs.getdbt.com/reference/resource-configs/trino-configs](https://docs.getdbt.com/reference/resource-configs/trino-configs) confirms `materialized='table'` default uses `on_table_exists='rename'` — a **multi-step** rename pattern (create intermediate → rename target to backup → rename intermediate to target), NOT a single atomic op. The fully-atomic single-commit shape requires `on_table_exists='replace'` (emits CREATE OR REPLACE TABLE, supported in dbt-trino 1.7.1+). Both are reader-safe in practice on Iceberg, but the "atomic Iceberg snapshot, rolls back on failure" framing implies single-commit semantics for the default — which isn't exact.

Not load-bearing for the engineer's question (which is about restructuring logic, not atomicity guarantees). Acceptable for the temp-table topic. **No resource fix.** If a future question specifically asks about atomic full-rebuild swaps, the `on_table_exists='replace'` canonical (added by iter1150-1151 r28 FIX-A) is the right answer — that canonical is in resources and would be reached.

Scores: Acc 4.5 / Clar 5.0 / App 5.0 / Compl 4.5 = **4.75 PASS**.

---

## Topic score updates

| Topic | Before | After | Δ | Margin |
|---|---|---|---|---|
| SQL query best practices for OLAP | 4.5666/223 | (4.5666·223 + 5.0 + 5.0 + 5.0)/226 = **4.5723/226** | +0.0057 | +1.0723 |
| Oracle PL/SQL → dbt/Trino migration | 4.4632/128 | (4.4632·128 + 4.75)/129 = **4.4654/129** | +0.0022 | +0.9654 |

Q1 (LIKE ESCAPE), Q2 (weighted avg single-overall), Q3 (is_finite/Inf/NaN) → SQL-best-practices-OLAP (r23). Q4 (temp tables → CTE/intermediate model) → Oracle-migration (r27/r28).

All required topics REMAIN PASSED. No required topic threshold at risk.

---

## Source-verified summary

- Q1: r23 §3493 LIKE-ESCAPE canonical reached; FIX-A myth-row + regex-box exception worked. Watch CLOSES.
- Q2: r23 §3.1B-WA weighted-avg canonical reached with NO GROUP BY; iter1156 grain misread confirmed one-off. Watch CLOSES.
- Q3: Trino 467 `is_finite`/`is_infinite`/`is_nan` verified at trino.io/docs/467/functions/math.html; INTEGER/DECIMAL vs DOUBLE/REAL div-by-zero distinction matches `reference_trino_division_by_zero` pin.
- Q4: Two-pattern CTE/intermediate-model + ref() chaining correct and idiomatic; minor over-generalization on default-rename atomicity (not load-bearing for the question).

**Watches after iter1157:** none open. Both iter1156 watches CLOSED.

**Recommendation:** NO-OP. Iter1157 4.9375 STRONG PASS confirms both iter1156 LIGHT-FIX-A reaches; resources are in a good state across all required topics; thinnest-margin required topic remains dbt-snapshots-SCD2 4.1079/18 (+0.6079, untouched this iter).

**Pattern observation:** Iter1156 → iter1157 recovery (3.656 → 4.9375, +1.28) follows the textbook FIX-A confirm-reach pattern: thin-margin iter exposes a findability gap on a buried canonical, light additive FIX-A promotes the canonical via top-of-file myth + adjacent-misroute defang + extra anchors, next-iter re-probe with different framing confirms reach. The Q2 single-overall grain misread also resolved as expected for a synthesis-ceiling NO-OP: re-probe with sharper "literally ONE row" framing produces the correct shape on its own. Both confirm the "verify-first / source-classify / minimal-touch" iter1156 judge calls.
