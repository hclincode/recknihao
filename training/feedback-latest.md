# Judge Feedback — iter919 (targeted-probe sweep: regexp-alternation pipe-escape probe + 3 fresh adjacents)

**Overall: 4.969 PASS** (Q1 4.875 / Q2 5.00 / Q3 5.00 / Q4 5.00 = 19.875 / 4 = 4.969; margin +1.469). OVERALL AVERAGE governs — no per-Q veto.

All dialect claims verified vs trino.io/docs/467 (functions/regexp.html, sql/select.html, functions/aggregate.html) + Trino optimizer correlated-subquery decorrelation docs + standing pins, multi-source WebSearch/WebFetch, 2026-06-10. Trino 467 PINNED. Teacher made ZERO edits expected — pure targeted-probe / durability sweep. **iter920 = DEFAULT NO-OP (no source-verified findable-but-missing gap surfaced; the regex pipe-escape trap was NOT exercised — probe INCONCLUSIVE, retry with a question that genuinely REQUIRES regex alternation).**

FEDERATION NOT PROBED — the 4.49944/310 federation row is UNCHANGED (still the only un-passed row; bulletproofed angles only).

---

## Per-question scores

### Q1 — "single pattern matching status one of pending/failed/cancelled" → 4.875
Responder answered `WHERE status IN ('pending', 'failed', 'cancelled')` — an **IN-list, NOT a regex**.
- **VERDICT: CORRECT and idiomatic — arguably SUPERIOR to a regex for this ask.** For matching EXACT whole status values, IN-list is the cleaner/safer choice. VERIFIED vs trino.io/docs/467 functions/regexp.html: `regexp_like(s,'pending|failed|cancelled')` would do **UNANCHORED SUBSTRING** matching ("performs a _contains_ operation rather than a _match_ operation"), so it would FALSE-POSITIVE on `'pending_review'` / `'failed_retry'` unless anchored `^(pending|failed|cancelled)$`. IN-list has no such hazard. Pipe `|` for alternation is a PLAIN pipe (Java pattern syntax), confirming the pinned regexp-alternation fact — but the responder did not reach for regexp_like at all.
- **EXPLICIT — PIPE-ESCAPE TRAP NOT EXERCISED:** because the responder used IN-list (not `regexp_like(...,'a|b|c')`), the markdown-table pipe-escape mis-copy trap (memory: Markdown Table Pipe-Escape Trap) was **NOT triggered**. No escaped-pipe `\|` mis-copy occurred. The probe is **INCONCLUSIVE** for the escaped-pipe question — it neither confirms nor refutes the trap.
- **NOT penalized** for skipping regex (per directive — IN-list is correct/idiomatic here).
- Deduction is a minor COMPLETENESS nuance only: a fully complete answer could MENTION `regexp_like(status,'pending|failed|cancelled')` (plain pipes) + `^(...)$` anchoring as the alternative for SUBSTRING/PARTIAL matching — not a defect.
- Acc 5.0 / Comp 4.5 / Clar 5.0 / Act 5.0 = **4.875**.

### Q2 — "count direct reports per manager" → 5.00
`SELECT manager_id, COUNT(*) AS direct_reports FROM employees WHERE manager_id IS NOT NULL GROUP BY manager_id`.
- **VERDICT: CORRECT.** VERIFIED select.html GROUP BY + COUNT(*) aggregate valid; grouping by manager_id yields one row per manager with the count of employees reporting to them. NO self-join needed (responder correctly noted this — each employee row already carries its manager_id, so a plain GROUP BY counts reports). `WHERE manager_id IS NOT NULL` correctly excludes top-level employees (no manager) from producing a spurious NULL-key group.
- Acc 5.0 / Comp 5.0 / Clar 5.0 / Act 5.0 = **5.00**.

### Q3 — "count products priced above their category average" → 5.00
TWO forms delivered, BOTH valid:
- (a) correlated subquery: `SELECT category, COUNT(*) FROM products p WHERE price > (SELECT AVG(price) FROM products WHERE category = p.category) GROUP BY category`.
- (b) window: `WITH category_stats AS (SELECT ..., AVG(price) OVER (PARTITION BY category) AS avg_price_in_category FROM products) SELECT category, COUNT(*) ... WHERE price > avg_price_in_category GROUP BY category`.
- **VERDICT: BOTH CORRECT.** (a) is the CANONICAL decorrelatable form — VERIFIED the Trino optimizer's OWN documented example is structurally identical (`i.i_current_price > (SELECT AVG(j.i_current_price) FROM item j WHERE i.i_category = j.i_category)`): equality correlation + scalar AVG, no LIMIT/no nesting ⇒ Trino decorrelates to aggregation-over-outer-join. The select.html "correlated subquery support is limited" caveat does NOT bite this simple form. (b) VERIFIED window.html: `AVG(price) OVER (PARTITION BY category)` materializes each row's category average; CTE + outer `WHERE price > avg_price_in_category` then `GROUP BY category COUNT(*)` correctly counts above-category-average products per category (no QUALIFY in 467 — subquery+outer-filter is the right rewrite). NO window-fn-in-WHERE muddle; NO group-by-output violation.
- Acc 5.0 / Comp 5.0 / Clar 5.0 / Act 5.0 = **5.00**.

### Q4 — "count users who logged in on their signup day" → 5.00
`SELECT COUNT(DISTINCT u.user_id) FROM users u INNER JOIN logins l ON u.user_id=l.user_id AND CAST(l.login_date AS date)=CAST(u.signup_date AS date)`.
- **VERDICT: CORRECT.** VERIFIED CAST(ts AS date) date-equality join valid in 467 (standing pin); placing the date-equality in the ON clause restricts the join to same-calendar-day logins; COUNT(DISTINCT u.user_id) collapses multiple same-day login rows to one count per user (guards against a user with several logins on signup day being counted multiple times). The DATE-columns variant (`l.login_date = u.signup_date`, no CAST) is ALSO valid when both columns are already DATE-typed — responder's CAST form is the robust general form (handles TIMESTAMP login_date). One row, single total.
- Acc 5.0 / Comp 5.0 / Clar 5.0 / Act 5.0 = **5.00**.

---

## iter882 verify-first (applied BOTH directions)
- regexp_like alternation = PLAIN pipes + UNANCHORED substring matching → CONFIRMED (functions/regexp.html); this is precisely why IN-list (Q1) is superior for exact matching — responder's choice NOT flagged as a miss.
- IN-list (Q1), GROUP BY+COUNT(*) (Q2), correlated-AVG subquery + window AVG-OVER-PARTITION (Q3), CAST(ts AS date) date-equality join + COUNT(DISTINCT) (Q4) — ALL verified VALID; none falsely flagged.
- No doc-CORRECT claim flagged as a defect; no doc-WRONG claim blessed.

## Scope / next-sweep guidance
- **iter920 = DEFAULT NO-OP.** No source-verified findable-but-missing gap; no dialect defect. Teacher: ZERO edits. Do NOT add any "wrong" card. Do NOT mark Q1 IN-list, Q2 GROUP-BY-COUNT, Q3 either form, or Q4 date-equality-join/COUNT(DISTINCT) wrong (all correct).
- **PIPE-ESCAPE PROBE INCONCLUSIVE — RETRY DELIBERATELY:** the escaped-pipe mis-copy trap can only be exercised if the responder actually emits `regexp_like(col,'a|b|c')`. An EXACT-value-matching question correctly attracts IN-list. To force the regex path, RE-PROBE with a question that genuinely REQUIRES regex alternation on free-text / partial matching — e.g. "flag rows whose free-text `error_message` CONTAINS any of 'timeout', 'refused', or 'reset'" (substring intent, no exact-value option) — then check whether the responder emits PLAIN pipes `'timeout|refused|reset'` and whether any markdown-table cell renders them as escaped `\|`. SKIP if it duplicates the pinned regexp-alternation card without adding the table-escape angle.
- Federation (4.49944/310) is the ONLY un-passed row — bulletproofed angles only.
- Do NOT touch any iter534-918 pin. PIN 467. NO federation edits. DO NOT bump training/state.json (already passed; overall 4.969 PASS holds).
