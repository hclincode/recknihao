# Judge Feedback — iter795 (durability-breadth sweep, no teacher edits)

**Verification:** All dialect claims checked against trino.io/docs/467 (regexp.html, aggregate.html) via WebFetch. Resources grepped for `regexp_extract`.

## Per-question scores

### Q1 — Match ANY keyword in one expression (regexp-alternation RE-PROBE #2)
Answer: `WHERE regexp_like(comment, '(slow|crash|bug)')` — PLAIN unescaped pipes; `|` = alternation = OR; matches anywhere (contains). Cites r23 §3.1A.

- **Accuracy: 5** — Verified against regexp.html: `regexp_like` is a CONTAINS check; plain `|` is Java-regex alternation; `(slow|crash|bug)` matches if any alternative appears. Responder emitted PLAIN `|` (NOT `\|`). Correct.
- **Completeness: 5** — Single-expression alternative delivered exactly as asked.
- **Clarity: 4** — Muddled lead prose ("LIKE with OR chain is idiomatic... but") slightly undercuts; the question explicitly wanted the single-expression form, which it did land on. Minor ding only.
- **Actionability: 5** — Copy-paste ready, correct pipe form.
- **Q1 avg: 4.75**

**BULLETPROOF VERDICT: regexp-alternation is now BULLETPROOFED.** 2nd consecutive clean plain-pipe datapoint after iter794's FIX-A (r23:2793 fenced canonical + markdown-table-pipe defang at r23:2795/2798). The markdown-table-pipe pin can RETIRE.

### Q2 — Extract first run of digits as a number  ⚠️ PRIMARY DEFECT
Answer: claimed "Trino 467 does NOT have a digit-extraction function"; gave `CAST(regexp_replace(product_label, '[^0-9].*', '') AS INTEGER)`; claimed "Size 12 (Large)"→12, "Weight 340g"→340. Cites r23 §3.1A/3.2A.

- **Accuracy: 1** — TWO defects:
  1. **FALSE claim.** Trino 467 HAS `regexp_extract(string, pattern) -> varchar` ("Returns the first substring matched") and `regexp_extract(string, pattern, group)` (verified regexp.html). Correct answer: `CAST(regexp_extract(product_label, '[0-9]+') AS INTEGER)` (or `'\d+'`). `regexp_extract_all` returns all matches. The "no dedicated function" claim is simply wrong.
  2. **BROKEN workaround.** Traced `regexp_replace(product_label, '[^0-9].*', '')` on the given examples: pattern `[^0-9].*` matches the FIRST non-digit char + greedy `.*` everything after. "Size 12 (Large)" starts with 'S' (non-digit) → match spans 'S'→end → ENTIRE string removed → returns `''`. "Weight 340g" starts with 'W' → same → `''`. `CAST('' AS INTEGER)` ERRORS. The claimed outputs (12, 340) are WRONG; the query produces empty/error for the very examples cited. It would "work" only for strings that START with the digits.
- **Completeness: 2** — Recognized the shape but missed the canonical tool and shipped a non-working query.
- **Clarity: 3** — Fluent but describes behavior the query does NOT have ("leaving only the leading digit sequence" — it leaves nothing).
- **Actionability: 1** — Copy-pasting this errors on CAST for both example inputs. Negative actionability.
- **Q2 avg: 1.75**

**Findability vs content gap:** `regexp_extract` IS present in resources — **r23:2805** documents `regexp_extract | (string, pattern[, group]) → varchar | Pull the first match (or capture group) out`, and **r27:989 / r27:1216** (Oracle REGEXP_SUBSTR→regexp_extract rename). **This is a FINDABILITY MISS, not a content gap.** The r23:2805 entry lives in the "complete Trino 467 regex function family" reference table inside the section keyworded around "Match ANY of several substrings/keywords" / alternation (r23:2790-2812). NO canonical landing is reachable from the keywords "extract first number", "first digits", "pull number out of string", "parse leading integer". The responder keyword-matched into the alternation neighborhood, found no extract-a-number recipe, and improvised a broken regexp_replace.

### Q3 — Collect group into a real ARRAY
Answer: `array_agg(product_id ORDER BY line_item_seq) AS product_ids GROUP BY order_id`; ORDER BY for determinism; LEFT JOIN → `COALESCE(array_agg(...) FILTER (WHERE x IS NOT NULL), ARRAY[])`. Cites r07 §1a.2.

- **Accuracy: 5** — Verified aggregate.html: `array_agg(x ORDER BY y)` builds an ordered array; FILTER drops nulls; COALESCE(..., ARRAY[]) handles empty. Correct.
- **Completeness: 5** — Covers determinism + LEFT-JOIN null/empty edge cases.
- **Clarity: 5** — Clear.
- **Actionability: 5** — Ready to run.
- **Q3 avg: 5.0** (standing array_agg/group-concat pin holds)

### Q4 — Per-order flag true iff EVERY package delivered
Answer: `bool_and(delivered) AS all_delivered GROUP BY order_id`; predicate form `bool_and(status='completed')`; notes MAX(bool) works but bool_and is canonical. Cites r23 §3.1D.

- **Accuracy: 5** — Verified aggregate.html: `bool_and(boolean)` returns TRUE iff every input is true (alias `every()`); predicate form valid; the "MAX(bool) works but bool_and is canonical" note is accurate.
- **Completeness: 5** — Predicate form + canonical-vs-MAX note.
- **Clarity: 5** — Clear.
- **Actionability: 5** — Ready to run.
- **Q4 avg: 5.0** (standing bool_and/bool_or all-rows-satisfy pin holds)

## Overall

| Q | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|
| Q1 | 5 | 5 | 4 | 5 | 4.75 |
| Q2 | 1 | 2 | 3 | 1 | 1.75 |
| Q3 | 5 | 5 | 5 | 5 | 5.00 |
| Q4 | 5 | 5 | 5 | 5 | 5.00 |

**Overall avg = (4.75 + 1.75 + 5.00 + 5.00) / 4 = 4.125 → PASS** (overall average governs; no single-Q veto). Q2 is a hard defect that does not sink the sweep but mandates a targeted fix.

## Teacher feedback

(a) **regexp-alternation BULLETPROOFED** — Q1 is the 2nd clean plain-pipe `regexp_like(col, '(a|b|c)')` datapoint post-iter794. The markdown-table-pipe pin can retire. (Optional micro-polish: the muddled "LIKE OR is idiomatic... but" lead suggests the section could lead with the single-expression regexp_like form even harder — cosmetic only.)

(b) **Q2 verdict** — Correct tool is `regexp_extract(product_label, '[0-9]+')` → first digit run; `CAST(regexp_extract(product_label, '[0-9]+') AS INTEGER/BIGINT)` for a number. The responder's `regexp_replace(product_label, '[^0-9].*', '')` is **BROKEN**: returns `''` for "Size 12 (Large)" and "Weight 340g" (both start with a letter → `[^0-9].*` eats the whole string), so `CAST('' AS INTEGER)` errors — the claimed 12/340 outputs are wrong. The "Trino has no extraction function" claim is FALSE. **FINDABILITY MISS** (regexp_extract present at **r23:2805** and **r27:989 / r27:1216**) — no landing reachable from "extract first number / first digits / pull number from string".

(c) **iter796 = FIX-A.** Add a findable first-digit-run canonical at a keyword-reachable landing point (near r23 §3.1A/3.2A string section, anchored on "extract first number / pull digits / parse leading integer"):
- Canonical: `CAST(regexp_extract(s, '[0-9]+') AS INTEGER)` (first digit run → number; BIGINT if large). Note `regexp_extract(s, '[0-9]+')` returns NULL if no digits, so `CAST(NULL AS INTEGER)`→NULL (safe).
- Capture group: `regexp_extract(s, pat, n)` for the nth group.
- All matches: `regexp_extract_all(s, '[0-9]+')`.
- DEFANG the broken `regexp_replace(s, '[^0-9].*', '')` form inline-marked WRONG (returns `''` for any string not starting with the digits → CAST error), with the regexp_extract canonical as the copy-attractive block.
