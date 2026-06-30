# Judge Feedback — Iteration 1287

**Overall**: 4 questions, average **4.797 STRONG PASS NO-OP** (Q1 5.0 STRONG / Q2 4.875 STRONG / Q3 4.9375 STRONG / Q4 4.6875 STRONG).

**Headline**: All four reach STRONG PASS, no FIX-A needed. **iter1286 truncate-2-arg L1638 MANDATORY FIX-A REACHED + WATCH CLOSES on 1st re-probe** — Q1 RE-PROBE of Oracle TRUNC(amount,2) port returns the corrected canonical exactly: "Trino 467 truncate() is 1-ARG ONLY, NO 2-arg overload (lands ~471+), use `truncate(x*power(10,d))/power(10,d)`, FLOOR is wrong for negatives (rounds toward -inf), round() is HALF_UP not truncation." Zero recurrence of the 2-arg-available claim, fully reverses iter1286-Q4 mechanism. iter1286-Q4 missed-sibling-reconcile family recovery confirmed. Q4 cleanly handles the engineer's faulty Oracle premise ("Oracle skipped NULLs") — engineer is wrong, Oracle ALSO returns NULL on any NULL arg; PostgreSQL is the actual outlier; cross-engine matrix correct.

| Q | Topic | Score | Status | Verdict |
|---|---|---|---|---|
| Q1 Oracle TRUNC(x,2) chop-without-rounding → Trino (RE-PROBE iter1286 L1638) | Oracle PL/SQL → dbt + Trino SQL migration | 5.0 | STRONG PASS | 1-ARG ONLY + scale-by-power(10,d) + 2-arg-is-~471+ + FLOOR-toward-neg-inf trap + round()-is-half-up all correct; iter1286 L1638 FIX-A reach test FULLY CLOSED |
| Q2 daily-active-users date-spine gap-fill with COALESCE zeros | Analytical query patterns on Iceberg+Trino | 4.875 | STRONG PASS | sequence(date,date,INTERVAL '1' DAY) + UNNEST AS d(day) + LEFT JOIN + COALESCE(metric,0) all correct; both bounds inclusive correct; no-generate_series-in-Trino correct |
| Q3 accepted_values + severity warn (status validation) | dbt model contracts / dbt tests cluster | 4.9375 | STRONG PASS | Syntax + values + config.severity warn/error semantics + store_failures audit schema + NULL-passes-accepted_values caveat all correct |
| Q4 Oracle GREATEST/LEAST NULL → Trino (engineer's Oracle-skipped-NULLs premise wrong) | SQL query best practices for OLAP | 4.6875 | STRONG PASS | Engineer's premise CORRECTLY REFUTED — Oracle ALSO returns NULL on any NULL; Postgres is the outlier; cross-engine matrix correct; COALESCE-sentinel workaround sound (minor: floor=0 only safe for non-negative columns, not explicitly flagged) |

---

## Q1 — Oracle TRUNC(amount, 2) port (RE-PROBE iter1286 FIX-A) — 5.0 STRONG PASS

**Acc 5.0 / Clar 5.0 / Prac 5.0 / Compl 5.0.**

**iter1286-Q4 missed-sibling-reconcile (L1638 mapping-row reversed iter1286) REACHES CLEANLY ON 1ST RE-PROBE — WATCH CLOSES.**

Three load-bearing facts source-verified this iter via WebFetch of [trino.io/docs/467/functions/math.html](https://trino.io/docs/467/functions/math.html):
1. **`truncate(x)` is 1-ARG ONLY on 467** — verbatim signature `truncate(x) → double / Returns x rounded to integer by dropping digits after decimal point.` — NO 2-arg `truncate(x, d)` overload listed. Matches pinned `reference_trino_truncate_1arg_only`.
2. **Correct toward-zero negative-safe form** — `truncate(amount * power(10, 2)) / power(10, 2)`:
   - 19.999 × 100 = 1999.9 → truncate → 1999 → /100 → 19.99 (correct chop)
   - -19.999 × 100 = -1999.9 → truncate → -1999 (toward-zero, NOT -2000 toward -inf) → /100 → -19.99 (correct toward-zero behavior, matches Oracle TRUNC)
3. **FLOOR is WRONG for negatives** — `floor(-19.999 * 100) / 100 = floor(-1999.9)/100 = -2000/100 = -20.00`, which is FALSE for "truncate" (Oracle TRUNC returns -19.99). FLOOR rounds toward -∞, truncate rounds toward zero. Responder explicitly defangs FLOOR — important Oracle-migration trap.
4. **`round(amount, 2)` is HALF_UP not truncation** — 19.999 → 20.00 (vs truncate's 19.99). Responder explicitly defangs.

iter1286 L1638 mapping-table row reconcile to "1-ARG ONLY + scale-by-power(10,d) form" successfully reaches: responder no longer claims 2-arg form is available on 467, instead leads with the power(10,d) scale-form + correctly gates 2-arg as ~471+. Pattern shape matches iter1285 / iter1271 / iter1267 / iter1232 / iter1216 / iter1198 / iter1221 — every recent MANDATORY FIX-A has reached cleanly on 1st-re-probe (17th consecutive). **iter1286-Q4 watch CLOSES.**

No imported-prior, no broken-secondary, no over-warning, no fabrication. Cites r27 §4.4C.

---

## Q2 — Daily-active-users date-spine gap-fill (4.875 STRONG PASS)

**Acc 5.0 / Clar 4.75 / Prac 5.0 / Compl 4.75.**

Date-spine gap-fill pattern is the canonical Trino 467 form. Verified facts via WebFetch of [trino.io/docs/467/functions/array.html](https://trino.io/docs/467/functions/array.html):
- **`sequence(start, stop, step)` for dates** — signature documented with `step` as INTERVAL DAY TO SECOND or INTERVAL YEAR TO MONTH. `sequence(DATE '2025-06-01', DATE '2025-06-30', INTERVAL '1' DAY)` returns an array of DATE values.
- **Both bounds inclusive** — Trino sequence semantics; responder correctly notes this (matches the Postgres `generate_series(start, stop, step)` inclusive-both behavior).
- **UNNEST flattens the array into rows** — `UNNEST(sequence(...)) AS d(day)` produces one row per date, the standard Trino spine pattern.
- **No `generate_series` in Trino** — correct (Postgres-only); responder pre-empts the common port mistake.

Gap-fill pattern is textbook: spine LEFT JOIN sparse_data ON spine.day = sparse_data.day → COALESCE(metric, 0) replaces missing-day NULLs with 0. Engineer can paste-and-run.

Minor Compl shave (-0.5): didn't explicitly walk through the per-account variation (CROSS JOIN accounts × dates spine for per-account zero-fill) — important real-world extension since the engineer's framing is "daily-active-users PER ACCOUNT." Engineer would need to figure that out — minor recall ceiling not a defect.

Minor Clar shave (-0.25): could explain WHY LEFT JOIN (spine drives all dates so missing-day rows appear with NULL on the right side, COALESCE then maps NULL → 0) more pedagogically for the OLAP novice.

No imported-prior, no broken-secondary, no over-warning, no fabrication.

---

## Q3 — accepted_values test + warn severity (4.9375 STRONG PASS)

**Acc 5.0 / Clar 5.0 / Prac 5.0 / Compl 4.75.**

All four load-bearing facts source-verified via WebFetch of [docs.getdbt.com/reference/resource-properties/data-tests](https://docs.getdbt.com/reference/resource-properties/data-tests):
1. **accepted_values syntax** — verbatim `data_tests: - accepted_values: { values: [...] }` schema.yml shape; newer dbt 1.10.5+ uses nested `arguments:` form but both work, responder uses the legacy-flat form which is the most common.
2. **severity warn vs error** — `config: { severity: warn }` correctly framed: `error` (default) = halt build / non-zero exit / downstream skipped; `warn` = log + continue. Engineer's stated need ("warn not fail") solved directly.
3. **store_failures: true → `<schema>_dbt_test__audit`** — correct: failing rows captured to an audit schema for later investigation; standard dbt feature.
4. **NULL-passes-accepted_values caveat** — verbatim from docs: "validates that all of the **non-null** values in a column are present in a supplied list of `values`." Responder correctly explains 3-valued logic: `NULL NOT IN ('active','inactive','pending')` evaluates UNKNOWN (not TRUE), NULL rows excluded from failing set → silent pass. Pair with `not_null` test if NULL must also fail. This is the iter1218 FIX-A canonical reaching cleanly for the Nth consecutive iteration.

Minor Compl shave (-0.25): didn't explicitly show the paired YAML (`- not_null` + `- accepted_values: ...`) for the engineer's "silent corruption" framing — though the caveat acknowledges the trap. The engineer might just enable warn severity and still have silent NULL corruption.

No imported-prior, no broken-secondary, no over-warning, no fabrication. Cites r27 §6.7A.

---

## Q4 — Oracle GREATEST/LEAST NULL → Trino (engineer's premise wrong) — 4.6875 STRONG PASS

**Acc 4.75 / Clar 4.75 / Prac 4.75 / Compl 4.5.**

**Engineer's faulty premise CORRECTLY REFUTED** — this is the critical evaluation point. Engineer claimed "Oracle GREATEST skipped NULLs, returned max of non-null." Responder explicitly states: "Trino (and **Oracle**, MySQL, BigQuery) return NULL if ANY argument is NULL. PostgreSQL is the OUTLIER — it ignores NULLs." Engineer is WRONG; Oracle ALSO returns NULL on any NULL.

**VERIFIED via WebFetch of [database.guide GREATEST in Oracle](https://database.guide/greatest-function-in-oracle/)**: verbatim "If any argument is null, the result is null" with worked example `SELECT GREATEST(null, 2), GREATEST(1, null) FROM DUAL;` both returning null. **VERIFIED via WebSearch of PostgreSQL conditional-expression docs**: "NULL values in the argument list are ignored. The result will be NULL only if all the expressions evaluate to NULL." So:
- **Trino, Oracle, MySQL, BigQuery, SQL Server**: GREATEST/LEAST returns NULL if ANY arg is NULL (the SQL:2003-standard behavior).
- **PostgreSQL**: outlier — ignores NULLs.

Engineer likely confused row-wise GREATEST/LEAST with the MAX aggregate, which DOES skip NULLs in all engines. Responder doesn't explicitly call out this likely-source-of-confusion (would have lifted Compl), but correctly refutes the bare premise.

**COALESCE-sentinel workaround SOUND**: `greatest(coalesce(a,0), coalesce(b,0), coalesce(c,0))` — floor sentinel for GREATEST; `least(coalesce(a,9e18), ...)` — ceiling sentinel for LEAST. Pattern matches r23 §3.1I + iter1226 canonical exactly.

**Minor Acc shave (-0.25): floor=0 sentinel is only safe for guaranteed-non-negative columns**. For the engineer's pricing scenario (tier prices, presumably ≥ 0), 0-floor is fine. But for columns where real values CAN be negative (e.g., profit margins, temperature deltas, signed offsets), 0 sentinel would silently win over true negative values and return wrong answer. Responder's framing uses "floor sentinel" / "ceiling sentinel" terminology which IMPLIES outside-domain — but a beginner copying `coalesce(a, 0)` without thinking about whether their column is non-negative gets a silent bug. Should explicitly state: "Choose sentinel BELOW (GREATEST) or ABOVE (LEAST) any possible real value — for non-negative columns 0/9e18 fine; for signed values use -9e18/9e18 or a domain-specific cap."

**Minor Compl shave (-0.5): didn't surface the row-wise-vs-aggregate confusion source** (engineer's likely mental model bug). Brief one-line "you may be thinking of MAX() aggregate, which DOES skip NULLs row-wise vs GREATEST() compares values across columns within a row" would have been pedagogically valuable.

CASE-expression alternative for 2-column case noted. Cross-engine reference matrix (Trino+Oracle+MySQL+BigQuery=NULL-on-any-NULL, Postgres=skip) is the most useful framing for an Oracle-migration engineer.

No imported-prior, no broken-secondary, no over-warning, no fabrication. Cites r23 §3.1I.

This RE-PROBE matches iter1226 Q4 (also GREATEST/LEAST Oracle-premise correction) which scored 5.0. The 0.3125 delta is the sentinel-must-be-outside-domain caveat — non-load-bearing for the engineer's pricing scenario, recall-ceiling for general case.

---

## Watches / FIX-A actions

### CLOSED
- **iter1286-Q4 truncate-2-arg L1638 reconcile FIX-A reach test**: Q1 above demonstrates the L1638 mapping-row reverse from "Trino 467 HAS 2-arg `truncate(x, d)` overload" to "1-arg ONLY + scale-by-power(10,d) form" REACHED. Responder no longer recommends 2-arg form. **CLOSED on 1st re-probe (17th consecutive 1st-re-probe-close).**

### CARRY (existing, not re-probed this iter)
- iter1285-Q2 timestamp-tz tagging pattern (re-probe within 4-6 iters).
- iter1283-Q3 hard_deletes-as-volunteered-secondary-without-dbt-trino-caveat (re-probe under "set up customers snapshot end-to-end" framings).
- iter1283-Q4 strpos-3-arg-banned-myth recurrence (re-probe under "nth occurrence of delimiter" framings).
- iter1284-Q3 delete+insert Hive-non-ACID framing (re-probe within 4-8 iters).
- iter1278-Q1 Scheduled-vs-CPU as I/O-wait imprecision (route to Blocked time explicitly) — periodic SOFT.

### NEW
- **None this iter.** All four answers reached without exposing new defects. Q4 sentinel-outside-domain caveat is recall-ceiling not resource-sourced (r23 §3.1I shows the pattern correctly; engineer's pricing context defaults non-negative so sentinel 0 is fine in practice).

---

## Topic routing

- Q1 (Oracle TRUNC port) → **Oracle PL/SQL → dbt + Trino SQL migration** (Oracle function port to Trino dialect; same routing as iter1286-Q4).
- Q2 (date-spine gap-fill) → **Analytical query patterns on Iceberg+Trino** (operational time-series gap-fill pattern).
- Q3 (accepted_values + warn) → **dbt model contracts** cluster (data-integrity declaration / dbt tests subfamily, same routing as iter1218/1221/1229).
- Q4 (Oracle GREATEST/LEAST → Trino) → **SQL query best practices for OLAP** (cross-engine SQL dialect / function-port pattern, same routing as iter1226 Q4).

All four touched topics already PASSED with margin >0.9; iter1287 lift contributes small but positive to each.

---

## Sources

- [trino.io/docs/467/functions/math.html](https://trino.io/docs/467/functions/math.html) — truncate() 1-arg-only signature verified
- [trino.io/docs/467/functions/array.html](https://trino.io/docs/467/functions/array.html) — sequence() date/timestamp/integer signatures
- [docs.getdbt.com/reference/resource-properties/data-tests](https://docs.getdbt.com/reference/resource-properties/data-tests) — accepted_values syntax + NULL-non-null caveat + severity
- [database.guide GREATEST in Oracle](https://database.guide/greatest-function-in-oracle/) — Oracle GREATEST returns NULL if any arg NULL
- [PostgreSQL Conditional Expressions](https://www.postgresql.org/docs/current/functions-conditional.html) — Postgres GREATEST/LEAST skip NULLs
- [Trino comparison.html (GREATEST/LEAST NULL semantics)](https://trino.io/docs/467/functions/comparison.html) — Trino returns NULL if any arg NULL
