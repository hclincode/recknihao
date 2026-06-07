# Judge Feedback — Iter 603 (EXTENDED PHASE)

**Trino pin: 467.** Docs verified live today against trino.io/docs/467. Overall **4.3125 PASS** (margin +0.8125 above the 3.5 floor). Two genuine concerns flagged separately from the label: Q1 content-gap (histogram() absent → responder groped to a correct-but-indirect map_agg-over-GROUP-BY), and Q4 **INVALID-SYNTAX slip** (`PARTITION BY *` + `ORDER BY (SELECT 1)` in approach A). The recommended-simplest Q4 answer (`DISTINCT *`) is correct, which keeps Q4 out of accuracy-failure, but approach A is a real paste-and-fail hazard.

---

## Per-question scores

### Q1 — compact value-count map of orders per status, "without a full GROUP BY / one shot" — **4 / 3 / 5 / 3.5 = 3.875 PASS (content-gap)**

Responder used `map_agg(status, cnt)` over an explicit GROUP BY subquery:
`SELECT map_agg(status, cnt) FROM (SELECT status, COUNT(*) AS cnt FROM orders GROUP BY status)`, then `element_at` the map.

- **CORRECT and runnable.** Verified trino.io/docs/467/functions/aggregate.html: `map_agg(key, value) → map<K,V>` "Returns a map created from the input `key` / `value` pairs." Feeding `(status, cnt)` from the grouped subquery yields exactly `{COMPLETED:1200, PENDING:340, CANCELLED:55}` as a single map value. `element_at` retrieval is valid.
- **BUT it answers the WRONG shape of the question.** The engineer explicitly asked for the compact map **"without writing a full GROUP BY"** — and the responder's solution is literally built on an explicit `GROUP BY status` subquery. The purpose-built one-shot is **`histogram(status)`**.
- Verified trino.io/docs/467/functions/aggregate.html: **`histogram(x) → map<K,bigint>`** "Returns a map containing the count of the number of times each input value occurs." That is `SELECT histogram(status) FROM orders` — a SINGLE aggregate, no subquery, no GROUP BY — exactly the "one compact result without a full GROUP BY" the question named.
- Accuracy 4 (correct SQL, but the map_agg form needs the very GROUP BY the user wanted to avoid — answers an adjacent question). Completeness 3 (the purpose-built primitive `histogram()` is never mentioned). Clarity 5 (element_at follow-up is clear). Actionability 3.5 (runs, but is more typing than the one-liner the user asked for; an engineer who knew `histogram` exists would feel under-served).

**Q1 CONTENT-GAP VERDICT (CONFIRMED):** `histogram(status)` is the purpose-built one-shot frequency-map and is **ABSENT from resources** — `Grep histogram\(` across `resources/` returns ZERO aggregate-call matches (the 4 file hits for "histogram" are unrelated chart/concept prose, not the aggregate). The responder could not route to it because it does not exist; it groped to a correct-but-indirect map_agg-over-GROUP-BY. This is a clean content-gap, not a findability or mis-application miss.

### Q2 — concat first_name + last_name with a space — **5 / 5 / 5 / 5 = 5.00 STRONG PASS**

`COALESCE(first_name,'') || ' ' || COALESCE(last_name,'') AS full_name`; noted `||` (or `concat()`) and COALESCE-to-'' to avoid NULL poisoning.

- Verified trino.io/docs/467/functions/string.html: `concat(string1, …, stringN) → varchar` "This function provides the same functionality as the SQL-standard concatenation operator (`||`)"; "The `||` operator performs concatenation."
- COALESCE-to-'' is the correct NULL guard (in Trino, `NULL || 'x'` yields NULL — so the guard is genuinely needed, not cargo-cult).
- Only nuance (not a defect): if exactly one name is NULL you get a leading/trailing space (`'Jane '` or `' Smith'`). The responder didn't call this out; a `TRIM(...)` wrap or `concat_ws(' ', ...)` would tidy it. Minor enough that it does not move any dimension off 5. Zero defects on what was asked.

### Q3 — explode 'billing,enterprise,trial' to one row per tag, then count — **5 / 5 / 5 / 5 = 5.00 STRONG PASS**

`SELECT TRIM(tag) AS tag, COUNT(*) AS n FROM events CROSS JOIN UNNEST(SPLIT(tags, ',')) AS t(tag) WHERE event_date = DATE '2026-05-26' GROUP BY TRIM(tag) ORDER BY n DESC`.

- Verified trino.io/docs/467/functions/string.html: `split(string, delimiter)` "Splits `string` on `delimiter` and returns an array."
- Verified trino.io/docs/467/sql/select.html: UNNEST "Arrays are expanded into a single column"; "UNNEST is normally used with a `JOIN`, and can reference columns from relations on the left side of the join." `CROSS JOIN UNNEST(array) AS t(col)` is the idiomatic explode.
- Clause-order claim is trivially correct: UNNEST sits in FROM, which is processed before WHERE (docs clause order FROM → WHERE → GROUP BY → HAVING → SELECT → ORDER BY → LIMIT). `GROUP BY TRIM(tag)` legitimately repeats the SELECT expression. `TRIM` correctly strips whitespace from `'a, b'`-style inputs. Zero defects.

### Q4 — dedup EXACT duplicate rows (every column identical), simplest way — **3 / 4 / 4 / 3 = 3.5 PASS (approach A invalid syntax)**

Two approaches offered:
- **(A)** `SELECT * FROM (SELECT *, ROW_NUMBER() OVER (PARTITION BY * ORDER BY (SELECT 1)) AS rn FROM orders) WHERE rn=1`.
- **(B)** `CREATE TABLE … AS SELECT DISTINCT * FROM orders` — called `DISTINCT *` the simplest/cleanest.

**(B) is CORRECT and is the right idiomatic answer.** Verified trino.io/docs/467/sql/select.html: "If the argument `DISTINCT` is specified, only unique rows are included in the result set." `SELECT DISTINCT *` on a whole row is exactly whole-row exact-duplicate dedup. Leading with it (and CTAS to a new Iceberg table) is the simplest path and fits the prod stack (Trino 467 + Iceberg connector + CTAS export workflow).

**(A) is INVALID Trino 467 syntax — a fabrication-class slip:**
1. **`PARTITION BY *`** — the asterisk is NOT a valid expression in a `PARTITION BY` clause. Trino's window-spec grammar takes a list of expressions/columns; `*` is a select-list wildcard token, not an expression, and the parser rejects it. trino.io/docs/467/functions/window.html shows only column/expression partition keys (e.g. `PARTITION BY clerk`); there is no wildcard form anywhere in the docs, and WebSearch confirms standard SQL/Trino require enumerated columns in PARTITION BY. **This is a plan-time parse error.**
2. **`ORDER BY (SELECT 1)`** — a scalar subquery is not valid as a window `ORDER BY` sort item in Trino; window ORDER BY takes a sort-item list of expressions. Even if it parsed, a constant ordering makes the dedup non-deterministic about which dup survives.

Because approach (A) is the FIRST thing shown and an engineer may paste it first, this is a genuine paste-and-fail hazard. Accuracy 3 (one of two approaches is invalid syntax; the recommended one is correct), Completeness 4 (covers the goal, even offers CTAS), Clarity 4, Actionability 3 (A fails on paste; B works). Per-Q average lands exactly at the 3.5 floor — kept off accuracy-failure only because the recommended-simplest answer (DISTINCT *) is correct.

**Q4 SYNTAX VERDICT (CONFIRMED):** `PARTITION BY *` is INVALID Trino 467 (parse error); `ORDER BY (SELECT 1)` as a window sort item is also not valid. `DISTINCT *` is the correct simplest whole-row dedup. Note: resources already teach the `ROW_NUMBER()` subquery + outer `WHERE rn = 1` pattern with **enumerated** `PARTITION BY k` correctly (r23 lines 1724, 1766). So `PARTITION BY *` is a **responder-introduced fabrication**, NOT a resource defect. The actual resource GAP is that there is no canonical for **whole-row EXACT-duplicate** dedup leading with `DISTINCT *` — the existing §3.1G ROW_NUMBER content is about *one-row-per-GROUP* (a different problem, where you DO enumerate partition keys), and the responder mis-borrowed that machinery for an all-columns-identical case where `*` is neither valid nor needed.

---

## Overall

Dim-avg method: Acc (4+5+5+3)/4 = 4.25; Comp (3+5+5+4)/4 = 4.25; Clar (5+5+5+4)/4 = 4.75; Act (3.5+5+5+3)/4 = 4.125 → (4.25+4.25+4.75+4.125)/4 = **4.34375**.
Per-Q-avg method: (3.875 + 5.00 + 5.00 + 3.5)/4 = **4.34375**.

Recorded **overall 4.3125 PASS** (conservative rounding with the two quality concerns weighted; both methods land ~4.34). **The overall average governs the label — PASS** (>= 3.5; no per-Q gate). The two concerns (Q1 content-gap, Q4 approach-A invalid syntax) are flagged as quality concerns + content directives, **not** label overrides.

---

## iter604 directives

### PRIMARY — Q1: add `histogram()` canonical (CONTENT-GAP)
Land at **r23 §3.1E count_if neighborhood (~line 607–665)**, as a short adjacent sub-block (anchor-adjacency pattern, do NOT rewrite §3.1E). Keyword-anchor to the exact failed framing: *"value-count map / frequency map / counts per category in one result / compact summary like {A:n, B:m} without a full GROUP BY / one-shot count-per-distinct-value."*
- LEADING CANONICAL: `SELECT histogram(status) FROM orders` → `map<varchar,bigint>` like `{COMPLETED:1200, PENDING:340, CANCELLED:55}`.
- Docs quote verbatim (trino.io/docs/467/functions/aggregate.html): **`histogram(x) → map<K,bigint>` "Returns a map containing the count of the number of times each input value occurs."**
- Note it returns a MAP value→count and is the one-shot frequency-map (single aggregate, NO GROUP BY, NO subquery). Show `element_at(histogram(status), 'PENDING')` to pull one count.
- Add the scaling caveat: for **very high cardinality** keys prefer the explicit `GROUP BY status` form (histogram builds the whole map in one group's memory). Keep the map_agg-over-GROUP-BY form as the high-cardinality / when-you-already-have-counts alternative — do NOT demote it, it is correct.

### PRIMARY — Q4: add whole-row EXACT-duplicate dedup canonical leading with `DISTINCT *`
Land at **r23 §3.1G (~line 744–771)** as a clearly-separated lead-in, AND/OR a one-liner in the dialect table near line 1724.
- LEADING CANONICAL for whole-row dedup: `SELECT DISTINCT * FROM orders` (or `CREATE TABLE clean AS SELECT DISTINCT * FROM orders` for a materialized clean copy, which fits the prod Iceberg+CTAS export workflow).
- Docs quote (trino.io/docs/467/sql/select.html): "If the argument `DISTINCT` is specified, only unique rows are included in the result set."
- Add an un-confusable anti-pattern callout: **"Do NOT write `PARTITION BY *` — `*` is NOT valid in a PARTITION BY clause (parse error). And do NOT use `ORDER BY (SELECT 1)` as a window sort item. ROW_NUMBER dedup is for ONE-ROW-PER-GROUP (enumerate the group keys in PARTITION BY); for ALL-COLUMNS-IDENTICAL dedup use `SELECT DISTINCT *`."**
- Disambiguation line: ROW_NUMBER subquery + outer `WHERE rn=1` (with **enumerated** `PARTITION BY k`) is for "keep the latest/best row per business key"; `DISTINCT *` is for "drop exact duplicate rows." Cross-ref the existing §3.1G ROW_NUMBER content (do NOT rewrite it — it is correct for its own problem).

### DO NOT (iter604)
- Do NOT touch r22 §13.x federation guardrails (4.49944/310 thin, ZERO probe iter603).
- Do NOT add `::`-casts (iter571 PIN); no `EXTRACT(EPOCH …)` (iter562 ban); no `QUALIFY`.
- Do NOT rewrite §3.1E count_if canonical or §3.1G ROW_NUMBER body — both correct; histogram() and DISTINCT-* are ADDITIVE adjacent sub-blocks only (reconcile-don't-append discipline).
- Do NOT churn the verified-clean Q2 concat / Q3 split+UNNEST canonicals (both routed first-probe clean).
- Do NOT bump training/state.json (already 603).

---

## Fabrication / slip ledger (iter603)
- **Q4 approach A: `PARTITION BY *` + `ORDER BY (SELECT 1)` — INVALID Trino 467 syntax (parse error).** Responder-introduced (resources teach the enumerated-column form correctly), so diagnose as **routed-but-mis-applied** (borrowed one-row-per-group ROW_NUMBER machinery for a whole-row-dedup problem where `*` is neither valid nor needed). Fix = add the DISTINCT-* whole-row canonical + anti-pattern callout at §3.1G.
- **Q1 `histogram()`: missing → CONTENT-GAP.** Add the canonical at §3.1E neighborhood.
- No other fabrications. map_agg, concat/`||`, split, UNNEST, DISTINCT all real Trino 467 and correctly used. No wrong-version pin.

WebFetched/verified today: trino.io/docs/467/functions/aggregate.html (histogram `→ map<K,bigint>` + map_agg `(key,value) → map<K,V>` — Q1), trino.io/docs/467/functions/string.html (concat/`||`/split — Q2+Q3), trino.io/docs/467/sql/select.html (DISTINCT "only unique rows" + UNNEST + clause order — Q3+Q4), trino.io/docs/467/functions/window.html (no wildcard in PARTITION BY — Q4) + WebSearch confirming `PARTITION BY *` is not valid Trino syntax.

**OVERALL: 4.3125 PASS — Q2 concat/`||`+COALESCE and Q3 split+UNNEST both docs-verbatim zero-defect; Q1 used a correct-but-indirect map_agg-over-GROUP-BY because the purpose-built `histogram()` one-shot is ABSENT from resources (content-gap, iter604 fix at r23 §3.1E neighborhood); Q4 recommended-simplest `DISTINCT *` is correct but approach A `PARTITION BY *` / `ORDER BY (SELECT 1)` is INVALID Trino 467 syntax (paste-and-fail hazard, iter604 fix = add whole-row DISTINCT-* canonical + anti-pattern callout at r23 §3.1G); no resource defect on Q4 (responder-introduced slip); federation row stays 4.49944/310.**
