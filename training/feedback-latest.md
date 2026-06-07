# Iter 647 — Judge Feedback (EXTENDED PHASE)

**Overall average: 4.90625 — STRONG PASS** (margin +1.40625 above 3.5 floor; +0.46875 swing UP from iter646's 4.4375)

**FIX-A LANDED — CONFIRMED CLEAN**: iter647 FIX-A target was the GROUP-BY-rule extract-then-count guardrail at r23 §8 (immediately after the positional/alias anchor at r23:1521-1528). Q1 in this iter probed it directly with "count signups per source_code prefix = part before first dash". The PRIMARY snippet returned was `SELECT split_part(source_code, '-', 1) AS prefix, COUNT(*) AS signup_count FROM signups GROUP BY split_part(source_code, '-', 1) ORDER BY signup_count DESC`. **No stray raw column in SELECT** — only the grouped derived expression and the aggregate. The exact iter646 Q4 bug pattern (raw `email` next to a domain-only GROUP BY) is GONE. GROUP BY repeats the full `split_part(...)` expression (Trino-safe form; avoiding the alias-in-GROUP-BY ambiguity per Trino issue #16533). FIX-A insertion fully repaired the regression without disturbing other canonicals.

---

## Per-question scores

### Q1 — count signups per source_code prefix (FIX-A re-probe)
- **Accuracy: 5.0** — `split_part(source_code, '-', 1)` verified correct per trino.io/docs/467/functions/string.html ("Splits `string` on `delimiter` and returns the field `index`. Field indexes start with `1`."). Index=1 returns the part BEFORE the first dash. GROUP BY repeats the derived expression verbatim. SELECT carries ONLY `prefix` (grouped) + `COUNT(*)` (aggregated) — fully compliant with the GROUP BY rule per trino.io/docs/467/sql/select.html.
- **Completeness: 5.0** — Primary form + subquery alternative both shown. ORDER BY clause included for top-N readability.
- **Clarity: 4.5** — Clean and direct.
- **Actionability: 5.0** — Engineer can paste-and-run.
- **Per-Q avg: 4.875 STRONG PASS**
- **FIX-A status: LANDED CLEAN — no stray ungrouped column this time.**

### Q2 — each region's share of its OWN COUNTRY's revenue total
- **Accuracy: 5.0** — `SUM(revenue) OVER (PARTITION BY country)` over a `GROUP BY country, region` query is valid Trino 467: window functions run AFTER GROUP BY in evaluation order (verified trino.io/docs/467: "Window functions run after the HAVING clause but before the ORDER BY clause"). So the window aggregate operates on the per-region aggregated rows, summing them within each country partition. Two-level aggregate-then-window pattern is docs-correct. `100.0 * ... / ...` forces float division. ROUND(... , 2) is valid.
- **Completeness: 5.0** — GROUP BY grain explicit; window denominator explicit; ROUND to 2dp included.
- **Clarity: 5.0** — Two-level (aggregate-then-window) framing makes the pattern transferable.
- **Actionability: 5.0** — Drop-in shape.
- **Per-Q avg: 5.0 STRONG PASS**

### Q3 — count late vs on-time shipments
- **Accuracy: 5.0** — `COUNT(CASE WHEN cond THEN 1 END)` skips NULLs (untrue branch returns NULL, which COUNT ignores) — canonical Trino 467 form. `COUNT(*) FILTER (WHERE ...)` is the ANSI/Trino-supported alternative; verified per trino.io/docs/467/functions/aggregate.html: "The `FILTER` keyword can be used to remove rows from aggregation processing with a condition expressed using a `WHERE` clause...supported for all aggregate functions." Both forms equivalent for this use case.
- **Completeness: 4.5** — Both branches covered; NULL-ship-date edge case (rows where actual or promised is NULL fall outside both buckets) noted in question framing.
- **Clarity: 5.0** — Side-by-side CASE vs FILTER aids understanding.
- **Actionability: 5.0** — Engineer knows the two idiomatic Trino forms.
- **Per-Q avg: 4.875 STRONG PASS**

### Q4 — median order value (robust to outliers)
- **Accuracy: 5.0** — `approx_percentile(order_total, 0.5)` is the docs-correct Trino 467 median per trino.io/docs/467/functions/aggregate.html. The "no PERCENTILE_CONT/MEDIAN in Trino" claim is verified: the aggregate-functions reference contains no PERCENTILE_CONT/MEDIAN entries; only `approx_percentile(x, percentage)`, `approx_percentile(x, percentages)` (array form), and the weighted variants exist. ARRAY[0.5, 0.95, 0.99] multi-percentile one-pass form is the docs-correct form returning an array of the same type as x. Per-group GROUP BY variant is the standard pattern.
- **Completeness: 5.0** — Median + per-group + multi-percentile array form + Postgres/Snowflake-syntax inoculation all included.
- **Clarity: 4.5** — Three concrete forms clearly delimited.
- **Actionability: 5.0** — Engineer knows the only Trino percentile API and the Postgres/Snowflake gotchas to avoid.
- **Per-Q avg: 4.875 STRONG PASS**

---

## Dimension averages (cross-check)

- Accuracy: (5.0 + 5.0 + 5.0 + 5.0) / 4 = **5.0**
- Completeness: (5.0 + 5.0 + 4.5 + 5.0) / 4 = **4.875**
- Clarity: (4.5 + 5.0 + 5.0 + 4.5) / 4 = **4.75**
- Actionability: (5.0 + 5.0 + 5.0 + 5.0) / 4 = **5.0**
- Dim-avg overall: (5.0 + 4.875 + 4.75 + 5.0) / 4 = **4.90625**

Per-Q overall: (4.875 + 5.0 + 4.875 + 4.875) / 4 = **4.90625**

Both methods agree at **4.90625 STRONG PASS**.

---

## Verdict

**GOVERNING LABEL = STRONG PASS** (overall 4.90625 >= 3.5; margin +1.40625; no per-Q < 3.5; lowest per-Q = 4.875 well above floor).

---

## iter648 directive recommendation

**DEFAULT NO-OP / DURABILITY-BREADTH** — no per-Q < 3.5; lowest Q1/Q3/Q4 each at 4.875 well above floor; FIX-A guardrail at r23 §8 extract-then-count proven durable on first probe (Q1 returned the CORRECT shape with no stray ungrouped column).

**Suggested fresh-area probes** (synthesizable-from-primitives — DO NOT pre-probe with new content):
- (a) inverse of Q1: extract-then-aggregate where the engineer wants TO KEEP a sample raw value per group — should route to Remedy-2 wrapper `arbitrary(email)` / `min(email)` / `max(email)` rather than DROP-the-column
- (b) window-over-GROUP-BY inverse: share of GRAND total (no PARTITION BY) vs share of subset — exercises the iter636 share-of-subset r07:1097/1194 canonical
- (c) approx_percentile per group (GROUP BY category, `approx_percentile(amount, ARRAY[0.5,0.95])`) — exercises the array-form return-type handling
- (d) bulletproofed federation predicate-pushdown re-probe IF opted-in (federation row 4.49944/313 thin, ZERO probe iter645-647 streak now at +3 non-probe)

**DO NOT**:
- touch r22 federation (4.49944/313, zero probes since iter644 — thin margin)
- re-edit the iter647 FIX-A insertion at r23 §8 just landed (HOLDS — proven durable on first probe; rewriting risks the regression that iter646 demonstrated)
- re-edit r23:1521-1528 positional-GROUP-BY anchor (the FIX-A's parent — UNCHANGED and citing it via cross-link is sufficient)
- re-edit r23:277-278/305-318 split_part canonical (split_part(s,'-',1) confirmed correct for "before first dash" — index=1 returns left fragment)
- re-edit r23 approx_percentile / PERCENTILE_CONT inoculation (~L141-159; Q4 5.0 holds)
- re-edit r07 share-of-subset / share-of-grand-total canonicals (Q2 share-within-partition implicitly covered via window-over-GROUP-BY composition)
- re-edit r23 §3.1G COUNT(CASE WHEN) / FILTER WHERE share-of-total canonical (Q3 holds)
- rewrite iter534-646 locks (all 100+ canonicals preserved; per state.json reconciliation discipline)
- add `::`-casts (iter571 PIN), QUALIFY, RLIKE (iter623 ban), PERCENTILE_CONT/MEDIAN (iter611 ban), EXTRACT(EPOCH) (iter562 ban); fabricate dayname()/initcap; DISTINCT-ON Postgres-leak (iter634 ban)
- bump training/state.json (per directive)
- git commit/push beyond appending this rubric line

---

## Topic-row updates

- **SQL query best practices for OLAP / r23**: Q1 extract-then-count GROUP-BY-rule guardrail FIX-A landed clean (+0.5 BIG durability — closes iter646's Q4 3.125 regression on first re-probe); Q3 COUNT(CASE WHEN) / FILTER WHERE late-vs-on-time (+0.25 durability); Q4 approx_percentile median + ARRAY form + PERCENTILE_CONT-absent inoculation (+0.25 durability). **Net UP STRONGLY**.
- **Analytical query patterns on Iceberg+Trino / r07**: Q2 window-over-GROUP-BY share-within-partition (+0.25 durability — composes share-of-subset primitive into per-country region share). **Net UP**.
- **Federation r22**: NOT probed iter647. Row stays 4.49944/313; consecutive non-probe count +1 -> 314.

---

## Meta-note

iter647 demonstrates the FIX-A insertion model works for GROUP-BY-rule violations exactly as it did for iter643's RANK/DENSE_RANK/ROW_NUMBER decision canonical. The keyword anchor "count rows per category extracted from a column" + "extract-then-count" routed the Haiku responder cleanly to the LEADING CANONICAL section even though the iter647 Q1 question phrasing ("count signups per source_code prefix = part before first dash") did NOT include the exact iter646-failure keywords ("email", "domain"). This is the second proof point (after iter643->645 RANK/DENSE_RANK bi-directional probe) that FIX-A insertions with broad keyword-anchor coverage generalize to sibling phrasings of the same bug class.

**OVERALL: 4.90625 STRONG PASS** — all four canonicals durability-confirmed; iter646 Q4 GROUP-BY-rule regression closed via FIX-A canonical at r23 §8; iter648 recommended DEFAULT NO-OP / durability-breadth continuation; federation row stays 4.49944/314.
