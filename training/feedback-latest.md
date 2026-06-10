# Judge Feedback — iter920 (targeted-probe RETRY: free-text regexp-alternation pipe-escape probe + 3 fresh adjacents)

**Overall: 4.969 PASS** (Q1 4.875 / Q2 5.00 / Q3 5.00 / Q4 5.00 = 19.875 / 4 = 4.969; margin +1.469). OVERALL AVERAGE governs — no per-Q veto.

All dialect claims verified vs trino.io/docs/467 (functions/regexp.html, sql/select.html, functions/aggregate.html) + standing pins, multi-source WebSearch/WebFetch, 2026-06-10. Trino 467 PINNED. Teacher made ZERO edits expected — pure targeted-probe / durability sweep.

**iter921 = DEFAULT NO-OP — no source-verified findable-but-missing gap; no dialect defect.**

## ★ Q1 PIPE-ESCAPE VERDICT — CLEAN PLAIN PIPES → CONCERN CLOSED / NO-OP ★

The iter919 INCONCLUSIVE probe was deliberately retried with a question that GENUINELY REQUIRES regex alternation on free-text/substring intent ("flag rows whose message CONTAINS any of timeout/refused/reset anywhere"). This time the responder DID reach for `regexp_like` — the regex path was exercised.

**Verdict: the responder wrote CLEAN PLAIN PIPES** `regexp_like(message, 'timeout|refused|reset')` and `regexp_like(message, '(?i)timeout|refused|reset')` — bare `|` alternation, NO backslash-escaped `\|`.

- **(a) Pipes are plain `|` (correct alternation).** VERIFIED functions/regexp.html: Trino 467 uses Java pattern syntax, where `|` is alternation. A backslash-escaped `\|` would match a LITERAL pipe char = WRONG for alternation. Responder did NOT escape — CORRECT.
- **(b) regexp_like is a CONTAINS/substring match.** VERIFIED functions/regexp.html verbatim: "The `pattern` only needs to be contained within `string`... this performs a _contains_ operation rather than a _match_ operation." So the pattern correctly flags messages containing any of the three words MID-SENTENCE (the exact "anywhere" intent). For this free-text substring ask, regexp_like is the RIGHT tool (unlike the iter919 exact-value ask where IN-list was superior).
- **(c) `(?i)` inline flag valid in 467 and applies to the whole alternation.** VERIFIED functions/regexp.html: "Case-insensitive matching (enabled via the `(?i)` flag) is always performed in a Unicode-aware manner." Placed at pattern start (`(?i)timeout|refused|reset`), the Java inline flag scope extends from that point through the remainder of the pattern, so all three alternatives are case-insensitive. CORRECT.

**THE TRAP DID NOT TRIGGER.** No markdown-table pipe-escape mis-copy occurred — the companion-table pipe-escape defense WORKS / the canonical was emitted as plain pipes. **The pipe-escape concern is CLOSED. NO FIX-A. NO iter921 FENCED-block escalation needed.** The markdown-pipe-escape-trap (memory: Markdown Table Pipe-Escape Trap) is now empirically confirmed handled for the regexp-alternation case.

All four dimensions clean → **Q1 = 5.0 on every axis**, except a tiny optional-completeness note (below) keeping Comp at 4.5; net 4.875 (does not affect the strong overall PASS).

---

## Per-question scores

### Q1 — "flag rows whose message contains any of timeout/refused/reset anywhere" → 4.875
`regexp_like(message, 'timeout|refused|reset')` + case-insensitive variant `regexp_like(message, '(?i)timeout|refused|reset')`; responder explained regexp_like is a contains/substring match.
- **VERDICT: CORRECT — clean plain pipes, valid substring semantics, valid `(?i)` flag (see ★ verdict above).**
- Minor COMPLETENESS nuance only (not a defect): a fully exhaustive answer could note that because regexp_like is unanchored substring, `timeout|refused|reset` will also match these tokens as part of a larger word (e.g. "timeouts", "unrefused") — fine for the stated "contains anywhere" intent, but worth a word-boundary `\b` aside if whole-word matching were ever wanted. Pure nuance.
- Acc 5.0 / Comp 4.5 / Clar 5.0 / Act 5.0 = **4.875**.

### Q2 — "total stock per product across warehouses" → 5.00
`SELECT product_id, SUM(quantity_on_hand) AS total_stock FROM inventory GROUP BY product_id`.
- **VERDICT: CORRECT.** VERIFIED select.html GROUP BY + aggregate.html SUM; one row per product with summed stock across all warehouse rows.
- Caveat (i) "Trino has no implicit type coercion, so CAST text to bigint/decimal if quantity_on_hand is text" — **practically correct**: VERIFIED Trino does NOT implicitly cast varchar→numeric for SUM, so SUM on a text column errors; CAST is the right fix. The blanket phrase "no implicit type coercion" is a SLIGHT overstatement (Trino DOES have some numeric-widening and timestamp coercions), but the actionable text→number advice is correct — weigh as a TINY imprecision, NOT a defect.
- Caveat (ii) "Trino does not allow aliases in GROUP BY — repeat the expression" — **CONFIRMED** vs select.html: GROUP BY takes input columns or ordinal positions, NOT SELECT aliases; repeating the expression (or using the ordinal) is correct. Matches the pinned GROUP-BY rule.
- Acc 5.0 / Comp 5.0 / Clar 5.0 / Act 5.0 = **5.00**.

### Q3 — "count customers per spending tier (low/medium/high)" → 5.00
`WITH per_customer AS (SELECT customer_id, SUM(order_value) AS total_spend FROM orders GROUP BY customer_id), labeled AS (SELECT total_spend, CASE WHEN total_spend<100 THEN 'low' WHEN total_spend<1000 THEN 'medium' ELSE 'high' END AS tier FROM per_customer) SELECT tier, COUNT(*) AS customer_count FROM labeled GROUP BY tier ORDER BY MIN(total_spend)`.
- **VERDICT: CORRECT.** Two-level aggregation: (1) per-customer SUM spend, (2) CASE tier label, (3) GROUP BY tier COUNT(*) = customers per tier. VERIFIED select.html GROUP BY + CASE; ORDER BY MIN(total_spend) over the grouped result is valid (aggregate in ORDER BY evaluated after GROUP BY) and orders tiers low→high by their min spend.
- **POSITIVE DURABILITY SIGNAL:** the responder EXPLICITLY WARNS that putting `customer_id` in the outer GROUP BY would yield one row per customer (the wrong-shape / count-of-entities trap). This shows the count-of-entities wrap lesson is internalized — exactly the muddled-middle pattern flagged in prior iters, correctly avoided AND called out here.
- Acc 5.0 / Comp 5.0 / Clar 5.0 / Act 5.0 = **5.00**.

### Q4 — "count orders shipped from a non-default warehouse" → 5.00
`SELECT COUNT(*) FROM orders WHERE shipped_from_warehouse_id != default_warehouse_id` (+ `SUM(CASE WHEN ... THEN 1 ELSE 0 END)` variant + `COUNT(*) FILTER (WHERE ...)` variant).
- **VERDICT: CORRECT.** `!=` and `<>` both valid in Trino 467 (pin); counts orders whose shipping warehouse differs from the default. SUM(CASE) and COUNT(*) FILTER variants are equivalent valid rewrites (FILTER supported on all aggregates).
- Minor NULL nuance (not flagged, not a defect): if EITHER column is NULL, `!=` yields NULL so the row is EXCLUDED from the count — a reasonable default interpretation; flagging it would be exhaustive completeness, but its omission is a minor nuance only.
- Acc 5.0 / Comp 5.0 / Clar 5.0 / Act 5.0 = **5.00**.

---

## iter882 verify-first (applied BOTH directions)
- regexp_like alternation = PLAIN pipes (Java syntax) + UNANCHORED substring/_contains_ matching + `(?i)` valid → CONFIRMED (functions/regexp.html); responder's Q1 form is correct, NOT falsely flagged.
- SUM requires numeric input / no implicit varchar→numeric cast → CONFIRMED (aggregate.html); Q2 CAST caveat correct.
- GROUP BY rejects SELECT alias, repeat-expression/ordinal required → CONFIRMED (select.html); Q2 caveat (ii) + Q3 GROUP BY tier correct.
- `!=`/`<>` both valid, FILTER on all aggregates valid → CONFIRMED (pins); Q4 all three forms correct.
- No doc-CORRECT claim flagged as a defect; no doc-WRONG claim blessed.

## Scope / next-sweep guidance
- **iter921 = DEFAULT NO-OP.** No source-verified findable-but-missing gap; no dialect defect. Teacher: ZERO edits. Do NOT add any "wrong" card.
- **PIPE-ESCAPE PROBE RESOLVED — CONCERN CLOSED:** the retry exercised the regex path; responder emitted CLEAN PLAIN PIPES `'timeout|refused|reset'` + valid `(?i)`, NO escaped `\|`, NO table-cell mis-copy. The markdown-table pipe-escape-trap is empirically confirmed handled for regexp-alternation. **Do NOT re-probe this angle again unless a NEW pipe-bearing canonical (regex, bitwise-OR string, etc.) is added to a TABLE cell.** Do NOT add a FENCED-block FIX-A — none needed.
- Do NOT mark Q1 regexp_like-plain-pipes, Q2 SUM-GROUP-BY+CAST-caveat, Q3 per-customer-CTE→CASE-tier→GROUP-BY-tier-COUNT, or Q4 `!=`/FILTER/SUM(CASE) wrong (all correct).
- Federation (4.49944/310) is the ONLY un-passed row — bulletproofed angles only.
- Do NOT touch any iter534-919 pin. PIN 467. NO federation edits. DO NOT bump training/state.json (already passed; overall 4.969 PASS holds).
