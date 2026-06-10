# Judge Feedback — iter895 (EXTENDED PHASE, durability sweep with ONE Q3 defect)

**Overall: 4.33 PASS** (per-Q 4.9375 / 4.9375 / 2.50 / 4.9375 = 17.3125/4 = 4.328; margin +0.83 over 3.5 threshold; **overall average governs — no per-Q veto**). Federation NOT probed (4.49944/310 row UNCHANGED).

Three dialect-clean answers + **ONE genuine Q3 dialect-accuracy DEFECT (alias-in-WHERE, unsupported in Trino) PLUS a logic bug (query-1 filter value never matches its own CASE outputs)**. The defect is a **RESPONDER SYNTHESIS SLIP**, not a resource gap — resources/ already teach the alias-in-WHERE rule correctly and prominently. → **iter896 = re-probe-don't-churn** (optional narrow findability anchor in an email/format-validation context only; do NOT churn any pin).

All facts VERIFIED vs trino.io/docs/467 (select.html / datetime.html / aggregate.html / window.html) via WebFetch 2026-06-10. PIN Trino 467.

---

## Q1 — truncate created_at to Monday 00:00, group by week — 4.9375 (Acc5 / Comp5 / Clar4.75 / Act5)
`date_trunc('week', created_at) AS week_start`, `GROUP BY date_trunc('week', created_at)`. "Returns Monday at midnight; no day-of-week math."

**CORRECT.** VERIFIED datetime.html: date_trunc supports `week`; doc example truncates 2001-08-22 (a Wednesday) → **2001-08-20 00:00:00.000 (a Monday)** = start of ISO week at midnight. Trino weeks are Monday-start (ISO-8601), so no day-of-week arithmetic is needed — the responder's framing is exactly right. GROUP BY repeats the **expression** (not a SELECT alias) → valid (correctly sidesteps the alias-in-GROUP-BY trap). Tiny clarity nit only: could note timestamp-with-tz week boundaries follow session zone — not a defect.

## Q2 — earliest "first seen" timestamp per user — 4.9375 (Acc5 / Comp5 / Clar4.75 / Act5)
`MIN(created_at) AS first_seen ... GROUP BY user_id`; or `MIN(created_at) OVER (PARTITION BY user_id)` for per-row.

**CORRECT.** VERIFIED aggregate.html: `min(x)` "Returns the minimum value of all input values" — over a timestamp returns the earliest. VERIFIED window.html: "All Aggregate functions can be used as window functions by adding the OVER clause" → `MIN(created_at) OVER (PARTITION BY user_id)` is valid and broadcasts the per-user earliest onto every row. Correctly offers BOTH shapes (collapse-to-one-row GROUP BY vs keep-all-rows window) and explains when each is wanted. Solid.

## Q3 — flag rows where user_email is invalid (no @, or no dot after @) — 2.50 (Acc1.5 / Comp3 / Clar3 / Act2.5) — **DEFECT**
Two CASE-based queries; the **CASE/LIKE logic is reasonable**, but **BOTH queries filter on a SELECT-list OUTPUT ALIAS in the WHERE clause**, which Trino does NOT support, AND query-1's filter value never matches its own CASE outputs.

**CONFIRMED DIALECT DEFECT — alias-in-WHERE is unsupported in Trino 467.** VERIFIED select.html: WHERE is evaluated **before** the SELECT projection, so output-column aliases do not yet exist when WHERE runs; aliases are usable in GROUP BY*/HAVING/ORDER BY but **NOT in WHERE** — Trino raises `Column 'X' cannot be resolved`. (*GROUP BY by alias is itself a separate Trino gap, issue #16533.)
- **Query 1:** `... CASE ... END AS email_validation FROM events WHERE email_validation = 'INVALID'` → `Column 'email_validation' cannot be resolved`. **PLUS a logic bug independent of scoping:** the CASE only ever outputs `'INVALID: missing @'`, `'INVALID: no dot after @'`, or `'VALID'` — it **never** outputs the bare string `'INVALID'`, so even if alias-in-WHERE were legal this filter would match **ZERO rows**.
- **Query 2:** `... AS is_invalid_email FROM events WHERE is_invalid_email = TRUE` → `Column 'is_invalid_email' cannot be resolved`.

What IS correct: the LIKE predicate `user_email NOT LIKE '%@%.%'` (flag missing-@ or no-dot-after-@) is a reasonable approximate format check; `POSITION`, `SUBSTR`, `NOT LIKE '%@%'` usage is dialect-valid. The bug is purely the WHERE-clause filtering mechanism (+ the query-1 literal mismatch).

**CORRECT FIX (any one):** (a) filter the **raw expression** directly — `WHERE user_email NOT LIKE '%@%.%'`; (b) **repeat the CASE** in WHERE; or (c) **wrap in a CTE/subquery** and filter the alias in the OUTER query — `WITH v AS (SELECT user_email, CASE ... AS email_validation FROM events) SELECT * FROM v WHERE email_validation LIKE 'INVALID%'`. Note the outer-query filter must also use a value the CASE actually emits (e.g. `LIKE 'INVALID%'`, not `= 'INVALID'`).

**Acc scored 1.5:** two queries, both unrunnable as written (alias-in-WHERE), one additionally semantically dead (literal never matches) — a load-bearing copy-paste failure, not a cosmetic nit. Comp/Clar partial credit because the underlying validity logic is explained and reasonable.

## Q4 — % of orders above $500 in one query — 4.9375 (Acc5 / Comp5 / Clar4.75 / Act5)
Window form: `SUM(CASE WHEN order_total>500 THEN 1 ELSE 0 END) OVER ()`, `COUNT(*) OVER ()`, `ROUND(100.0*SUM(CASE...)OVER()/COUNT(*)OVER(),2)`. Summary form: `COUNT(CASE WHEN order_total>500 THEN 1 END)`, `COUNT(*)`, `ROUND(100.0*COUNT(CASE...)/COUNT(*),2)`.

**CORRECT (both forms).** VERIFIED window.html: aggregates are usable as window functions via OVER; empty `OVER ()` computes the aggregate over the entire result set (standard SQL, valid in 467) → broadcasts grand totals onto every row. VERIFIED: `100.0 * ...` uses a DECIMAL literal, forcing **non-integer (decimal) division** — avoids the integer-truncated-to-0 trap. `COUNT(CASE WHEN cond THEN 1 END)` counts only non-NULL results = counts matching rows (the idiomatic conditional-count) — correct. Both the per-row window form and the single-row summary form are valid and return the same percentage; offering both with the trade-off is exactly right.

---

## iter896 DIRECTIVE — re-probe-don't-churn (NO defect-marking of pins)

**SCOPE CHECK RESULT: resources/ is CORRECT and NOT silent on alias-in-WHERE → this is a RESPONDER SYNTHESIS SLIP, NOT a resource defect.** The rule is taught correctly and prominently in at least three places:
- `resources/27-oracle-plsql-to-dbt-trino.md` §4.2 (L768–793): explicit "GOTCHA — do NOT reference the SELECT output alias in WHERE … `WHERE` is evaluated BEFORE the SELECT projection … `Column 'occurred_at' cannot be resolved`", with the general rule "you cannot reference ANY SELECT output alias — nor a window-function result — in WHERE."
- `resources/23-sql-best-practices-olap.md` §8 (L487–500): GROUP-BY-alias guard + ORDER-BY asymmetry.
- `resources/07-analytical-query-patterns.md` (L2806, L2820): "Anywhere the alias appears before projection (GROUP BY, WHERE, HAVING, OVER's ORDER BY), use the expression instead," with a worked WHERE example and the fix.

There is **NO email-validation / format-check card** in resources/ that misuses alias-in-WHERE (grep for `email_validation` / `is_invalid_email` / `NOT LIKE '%@%` returned zero resource matches). So the responder did not copy a bad pattern from a card — it synthesized the alias-in-WHERE form itself despite the rule being documented elsewhere.

**ACTION for iter896: DEFAULT NO-OP / re-probe.** Per the iter882 + reconcile-don't-churn lessons, do NOT churn the existing (correct) alias-in-WHERE cards and do NOT add a "wrong" card. **OPTIONAL narrow LIGHT FIX-A (additive, only if it does not churn a pin):** add ONE small keyword-anchored note in an email/text-format-validation context routing the reader to the existing alias-in-WHERE rule + showing the correct CTE/subquery (or raw-expression) filter form — keyword anchors: *flag invalid emails / validate email format / filter on a CASE result / WHERE on a computed column / email_validation alias in WHERE / is_invalid_email*. If adding this would touch/duplicate the §27-4.2 or §23-8 or §07 alias guards, **SKIP it and just re-probe email-format validation from a 2nd phrasing next sweep** to confirm the slip is a one-off. All SQL must be FENCED (pipe-escape trap; the `%@%.%` LIKE pattern and any `|` content must not sit in a table cell).

**Do NOT** flag Q1/Q2/Q4 as defects (all dialect-clean, verified vs source first). **Do NOT** touch any iter534–894 pin. PIN 467. **NO federation edits.** **DO NOT bump training/state.json** (already passed; this run does not regress overall PASS).
