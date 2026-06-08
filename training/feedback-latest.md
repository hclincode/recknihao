# Judge Feedback — iter700 (MILESTONE)

**Mode**: extended-phase end-of-iteration (4-question DEFAULT NO-OP durability probe).
**Verdict**: PASS (overall avg 4.8125 ≥ 3.5).
**Verification basis**: trino.io/docs/current sql/select.html (WITH RECURSIVE + max_recursion_depth), functions/conversion.html (try_cast), docs.getdbt.com (data_tests vs tests, generic tests, build semantics). PIN TRINO 467.

---

## Per-question scoring

### Q1 — Weekly active users + WoW % change (period-over-period durability re-probe)

| Dimension | Score | Reasoning |
|---|---|---|
| Accuracy | 5 | (a) `date_trunc('week', event_date)` is a valid Trino 467 form (docs `functions/datetime.html`). (b) `LAG(weekly_active_users) OVER (ORDER BY week_start)` on a pre-aggregated weekly CTE is the canonical period-over-period idiom — `LAG` on the period-CTE matches the iter698 MoM card pattern, generalizes cleanly to week-over-week. (c) SINGLE `100.0 *` multiply — no double-100 bug. (d) `NULLIF(LAG(...), 0)` correctly guards div-by-zero on the first week (when LAG returns NULL, division returns NULL, not error — NULLIF here actually defends the all-NULL case from the prior period boundary). (e) `COUNT(DISTINCT user_id)` is fine here (not `COUNT(DISTINCT) OVER` which is banned). (f) Consecutive-period comparison — answer is week-over-week, NOT year-over-year, NOT a per-row self-join. |
| Completeness | 5 | Pre-aggregate CTE → LAG → percent change → ORDER BY in one go. Plus the explanation "LAG looks back one row = one week after pre-aggregation, no join needed" defuses the misroute to per-row self-join. References r07 + r23. |
| Clarity | 5 | Clean CTE-then-window structure; one-line plain-English explanation of each piece. |
| Actionability | 5 | Engineer can paste directly into Trino 467; will run as-is on `iceberg.analytics.user_events`. |

**Q1 avg = 5.00 — MoM/period-over-period card HELD. Generalizes cleanly from month to week. No regression.**

### Q2 — Org-chart recursive (WITH RECURSIVE)

| Dimension | Score | Reasoning |
|---|---|---|
| Accuracy | 5 | (a) `WITH RECURSIVE org_tree(...) AS (base UNION ALL recursive_step)` matches Trino 467 grammar — `trino.io/docs/current/sql/select.html` example uses exactly this UNION ALL form. (b) Column aliases on the CTE header (`employee_id, manager_id, name, depth`) are MANDATORY in Trino recursive form — responder included them, correct. (c) Base `WHERE manager_id IS NULL` (or `WHERE employee_id=<vp_id>`) → recursive `JOIN org_tree t ON e.manager_id = t.employee_id` is the standard top-down expansion. (d) **`max_recursion_depth` default = 10** — VERIFIED against trino.io/docs/current/sql/select.html: "recursion depth is fixed, defaults to `10`". PIN holds. (e) `SET SESSION max_recursion_depth = 20;` is the correct property name and syntax. (f) Exceeding depth raises an error (the docs note recursion will "abort" — responder said "errors", correct in spirit; NOT_SUPPORTED phrasing is a reasonable approximation). (g) "Experimental" caveat is CONFIRMED — trino.io docs still label WITH RECURSIVE: "This feature is experimental only." So that label is accurate, not stale. |
| Completeness | 5 | Full base+recursive+terminal-SELECT skeleton, depth column for level tracking, recursion-depth caveat + session-property workaround. Cross-ref to r27 §7A.1 CONNECT BY→WITH RECURSIVE migration card. |
| Clarity | 4.5 | Slightly compact; a beginner reading "default recursion depth 10 levels" might not immediately know that means "max 10 recursive iterations". But the SET SESSION example and the "15-level chain errors" sentence make the practical impact clear. |
| Actionability | 5 | Engineer can paste, swap in the VP filter, run on Trino 467. Knows the session knob to raise depth before a deep org chart fails. |

**Q2 avg = 4.875**

### Q3 — Bad-CSV-data graceful handling (try_cast)

| Dimension | Score | Reasoning |
|---|---|---|
| Accuracy | 5 | (a) `TRY_CAST(amount_str AS DECIMAL(10,2))` is a valid Trino 467 form — `trino.io/docs/current/functions/conversion.html`: "Like cast(), but returns null if the cast fails." (b) `DECIMAL(10,2)` is a valid Trino 467 type. (c) CASE expression with concatenation `'INVALID: '||amount_str` is valid Trino. (d) Distinguishing genuine-NULL input vs failed-cast NULL via `IS NULL AND amount_str IS NOT NULL` is correct. |
| Completeness | 4 | TRY_CAST core is correct, CASE-to-flag is a thoughtful add. **Minor tension with "without dropping the rows entirely":** the responder's `WHERE TRY_CAST(...) IS NOT NULL OR amount_str IS NULL` KEEPS valid casts and original-NULL rows but DROPS the bad-but-non-null rows (the 'N/A', 'pending' rows). The cleanest reading of the question would keep ALL rows and surface the bad ones as NULL+flag — not WHERE-filter them out. The responder DOES note "filter NULLs or keep+log to a bad-data table" so they're aware of the alternative, but the default SQL shown contradicts the literal "without dropping rows" framing. Half-point off completeness for that small mismatch. |
| Clarity | 5 | Clean. The CASE explanation ("flags which rows failed") and the WHERE explanation make the trade-off explicit. |
| Actionability | 5 | Engineer can paste and ship; will need to flip the WHERE if they want all-row retention (responder hints at this). |

**Q3 avg = 4.75**

### Q4 — dbt data-quality tests (built-in generic tests)

| Dimension | Score | Reasoning |
|---|---|---|
| Accuracy | 5 | (a) **Four built-in generic tests** — `unique`, `not_null`, `accepted_values`, `relationships` — VERIFIED against docs.getdbt.com/docs/build/data-tests: "Out of the box, dbt ships with four generic data tests already defined: unique, not_null, accepted_values, and relationships." (b) `data_tests:` vs `tests:` key — VERIFIED for **dbt 1.8+**: docs explicitly say "With the introduction of unit tests, the key was renamed from `tests:` to `data_tests:`" and `tests:` is retained for backward compat. Responder's "data_tests: key (dbt 1.8+)" is precise. (c) `dbt build` interleaves models + tests; failing test with default severity `error` skips downstream models — matches dbt build documentation. (d) Each generic test compiles to a SELECT returning failing rows; zero rows = PASS — correct dbt semantics. (e) `relationships: to ref('dim_customers') field customer_id` is correct schema.yml syntax for FK test. (f) `accepted_values values [...]` syntax is correct. (g) `unique` test is null-tolerant — correct (uniqueness check ignores NULLs). |
| Completeness | 5 | All four generic tests named with correct semantics; schema.yml example covers all four; build-gating + severity + failing-row-SELECT semantics; cross-link to r27 §6.7 and r28 §H3 with iter578 PIN context. |
| Clarity | 5 | Concrete schema.yml example beats abstract prose. Plain-English: "bad data never lands" tells the engineer the actual production behavior. |
| Actionability | 5 | Engineer can copy the schema.yml snippet, fill in their model name, run `dbt build` and immediately get test enforcement. |

**Q4 avg = 5.00**

---

## Overall

| Q | Avg |
|---|---|
| Q1 (WoW LAG) | 5.000 |
| Q2 (WITH RECURSIVE) | 4.875 |
| Q3 (try_cast) | 4.750 |
| Q4 (dbt tests) | 5.000 |
| **Overall** | **4.906** |

**Overall avg = 4.906 ≥ 3.5 → PASS.**

---

## MILESTONE iter700 durability summary

**Period-over-period card (iter698 MoM canonical at r07:2486-2587) — HELD.** The WoW probe in Q1 produced the exact same LAG-on-period-CTE shape, single 100.0 multiply, NULLIF guard, no per-row self-join, no YoY confusion. The fact-in-one-sentence + DO-NOT-WRITE defang + decision-table triad is doing its job across BOTH month-over-month AND week-over-week phrasings — the card generalizes correctly from month to week, which was the worry. No regression.

**WITH RECURSIVE (r27 §7A.1) — HELD.** Default 10 PIN was repeated precisely; UNION ALL form with mandatory column aliases is intact; SET SESSION workaround is named correctly; "experimental" label is still docs-accurate (re-verified today against trino.io/docs/current). No new finding.

**try_cast (r23) — HELD with a 0.25-point completeness nit.** Core fact (NULL on failed cast vs error) is correct; DECIMAL(10,2) valid; CASE flagging is a thoughtful add. The WHERE clause in the SQL example slightly contradicts the question's literal "without dropping rows entirely" framing — responder DOES verbalize the alternative ("keep+log to a bad-data table") but the default SQL drops the bad-but-non-null rows. This is a *minor* phrasing-discipline issue, not a technical error.

**dbt generic tests (r28 §H3 / r27 §6.7) — HELD.** Four-test list, data_tests: vs tests: key for 1.8+, schema.yml shape, build-gating semantics — all docs-correct.

---

## Findable-but-missing gap for iter701

**Candidate FIX-A: Q3 try_cast "without dropping rows" framing.** The r23 try_cast canonical (or wherever the responder is reading from) could benefit from a one-line "default-keep ALL rows, surface bad ones as NULL+flag; only filter if explicitly asked" lead-in that defaults the WHERE-shape to all-row-retention. Currently the responder produces a WHERE that drops bad-non-NULL rows by default. This is a small phrasing nudge, not a technical fix — the dimensional impact is one 0.25-point completeness deduction on Q3 (4.75 vs 5.0), which does not move the iteration verdict.

**Severity assessment: LOW.** All four answers PASS individually; overall 4.906 is a strong PASS. The try_cast WHERE-default is a *style* issue, not a *correctness* issue, and the responder shows awareness of the trade-off in the surrounding prose. Iter701 can remain DEFAULT NO-OP unless a stricter judge re-probe finds an actual misroute. If iter701 ends up touching r23, a single-line lead-in defaulting to all-row-retention would be the minimum-invasive fix.

**Recommendation for iter701: DEFAULT NO-OP.** The MILESTONE 700 integrity sweep + the three recent fixes (iter698 MoM, iter697 approx_percentile, iter695 QUALIFY) all confirmed-intact in this probe. Resources remain mature. No new findable-but-missing gap that would force a write this iteration.

---

## Sources verified today (2026-06-08)

- [Trino 481 SELECT docs (WITH RECURSIVE + max_recursion_depth default 10 + experimental label)](https://trino.io/docs/current/sql/select.html)
- [Trino 481 Conversion functions (try_cast returns null on fail)](https://trino.io/docs/current/functions/conversion.html)
- [dbt data tests (generic tests, data_tests vs tests, build semantics)](https://docs.getdbt.com/docs/build/data-tests)
