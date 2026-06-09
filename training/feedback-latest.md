# Judge Feedback — iter786 (DEFAULT NO-OP / durability-breadth sweep)

Teacher made ZERO resource edits this iteration. 4 fresh adjacent probes. All dialect claims verified against trino.io/docs/467 (string/conversion .html + ROW-type access) via WebFetch/WebSearch on 2026-06-09. state.json NOT touched (already 786).

## Per-question scores

| Q | Topic | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|---|
| Q1 | Weighted average | 5 | 5 | 5 | 5 | **5.00** |
| Q2 | Custom sort order (ORDER BY CASE) | 5 | 5 | 5 | 5 | **5.00** |
| Q3 | Fixed-width padding (pad to 20 + truncate) | 2 | 2 | 4 | 2 | **2.50** |
| Q4 | ROW/STRUCT field access (geo.country) | 5 | 5 | 5 | 5 | **5.00** |

**Overall avg = (5.00 + 5.00 + 2.50 + 5.00) / 4 = 4.375 → PASS** (threshold 3.5; overall average governs, no single-Q veto).

---

## Q1 — Weighted average — 5.00 CLEAN

`SUM(rating * review_count) / SUM(review_count) AS weighted_avg_rating`. Textbook weighted average (Σ value·weight / Σ weight) — VERIFIED correct. Cites r23 §3.1B (actually about `SUM(DECIMAL)` auto-widening to `decimal(38,s)`; loosely relevant since it governs the aggregate-sum type, not a weighted-avg formula — the formula itself is right regardless). Minor un-penalized: if both `rating` and `review_count` were pure INTEGER the division would be integer division; with `rating` typically DECIMAL the numerator widens to decimal and the division is fractional. A one-line CAST-to-DOUBLE note for the all-integer edge case would be nice but it is not a defect. Score high.

## Q2 — Custom sort order — 5.00 CLEAN

`ORDER BY CASE priority WHEN 'urgent' THEN 1 WHEN 'high' THEN 2 WHEN 'normal' THEN 3 WHEN 'low' THEN 4 END`. VERIFIED valid Trino — `ORDER BY CASE <col> WHEN ... THEN <int> END` yields a custom (non-alphabetical) sort key. Cites r07. Clean, complete, directly actionable.

## Q3 — Fixed-width padding — 2.50 — PRIMARY FINDING (DEFECT + MISSED CANONICAL)

The sweep's primary finding. The responder's PRIMARY form is **doubly defective**, and it MISSED the one-function canonical.

**Defect 1 — `LEFT()` does NOT exist in Trino 467.** PRIMARY form `format('%-20s', LEFT(product_code, 20))` calls `LEFT(product_code, 20)`. VERIFIED vs trino.io/docs/467/functions/string.html: Trino has **NO `left()` / `right()`** (those are MySQL/Postgres). `LEFT(...)` raises `Function 'left' not registered` → **the primary form does not compile.** Recurrence of the standing no-`left()`/`right()` pin (already at r27:978 — "NO `right()` / `left()` IN TRINO ... Use `substr(s, 1, n)` for the FIRST n chars").

**Defect 2 — even ignoring `LEFT`, `format('%-20s', x)` does NOT truncate.** VERIFIED (Java `java.util.Formatter` / WebSearch): `%-20s` left-justifies and right-pads SHORT strings to width 20 but does **NOT** truncate strings longer than 20 — you'd need the precision form `%-20.20s` (the `.20` after the width truncates). So even after fixing the LEFT() call, `format('%-20s', x)` alone fails the question's explicit "truncate if longer" requirement. The responder leaned on `LEFT()` to do the truncation precisely because plain `%-20s` can't — and `LEFT()` doesn't exist.

**The MISSED canonical — `rpad(product_code, 20, ' ')`.** VERIFIED vs trino.io/docs/467/functions/string.html, verbatim: `rpad(string, size, padstring) -> varchar` — "Right pads `string` to `size` characters with `padstring`. **If `size` is less than the length of `string`, the result is truncated to `size` characters.**" This does **EXACTLY** what the question asks — right-pad to 20 with spaces AND truncate if longer — in ONE built-in function. `lpad(string, size, padstring)` is the left-pad sibling (same truncate-if-longer behavior). The responder never mentioned rpad.

The ALTERNATIVE the responder gave — `CONCAT(SUBSTRING(product_code,1,20), REPEAT(' ', GREATEST(0, 20 - LENGTH(SUBSTRING(product_code,1,20)))))` — actually DOES compile and is correct (substr+repeat hand-roll), but it's a clunky 4-function reimplementation of `rpad`. Credit for a working fallback keeps Q3 off the floor, but leading with a non-compiling primary and missing the one-call answer is the defect.

**Q3 verdict: DEFECT (non-compiling `LEFT()` primary + `%-20s` doesn't truncate) + MISSED CANONICAL (`rpad`).**

### Resource diagnosis — FINDABILITY GAP (content exists, unreachable from the question's keywords)

`rpad`/`lpad` DO exist in resources, but only in the Oracle-migration porting table:

- **r27 (27-oracle-plsql-to-dbt-trino.md):983** — `| LPAD(s, n, pad) / RPAD(s, n, pad) | lpad(s, n, pad) / rpad(s, n, pad) | ...`. Framed entirely around **(a) Oracle→Trino porting** and **(b) the zero-pad-numeric trap** ("you MUST CAST a numeric column to VARCHAR first ... `lpad(CAST(account_id AS VARCHAR), 10, '0')`"). Anchors there: "zero-pad number Trino, lpad numeric column, pad account number, lpad cast varchar, rpad numeric."
- **r27:1056** — INITCAP section's string-function inventory merely LISTS `lpad`/`rpad` among existing functions (no padding-task guidance).

The content is **NOT reachable** from a "pad a string to fixed width for a flat-file export / pad to exactly 20 chars / right-pad with spaces / truncate if longer" query. The responder went to r23 §3.1A (`format()` printf canonical) instead — a reasonable keyword match for "pad/format" — but r23 §3.1A's specifier table (lines 568-574) only shows `%s`, `%d`, `%,d`, `%05d`, `%.2f`: it shows **zero-pad for INTEGERS (`%05d`)** but has NO string-width-pad example and NO mention of `%-20s` / `%-20.20s` / `rpad`. So the responder extrapolated `%-20s` (and reached for non-existent `LEFT` to truncate) because the actual fixed-width-string canonical wasn't on the landing page it found.

This is a **FINDABILITY GAP edging toward CONTENT GAP**: the rpad/lpad *signature* exists (r27:983) but there is **no fixed-width-string-padding canonical** anywhere — no card that says "to pad/truncate a STRING to a fixed width (flat-file export), use `rpad(s, N, ' ')` / `lpad(s, N, '0')`; it pads AND truncates in one call; do NOT use `LEFT`/`%-20s`." Quote of the only existing content: r27:983 (Oracle-porting + numeric-cast framing).

---

## Q4 — ROW/STRUCT field access — 5.00 CLEAN

`geo.country` dot notation, usable in SELECT/WHERE/GROUP BY/ORDER BY, no CAST needed for a typed `ROW(... country varchar)` column. VERIFIED correct vs Trino 467 ROW-type access — dot-access on a typed ROW field is valid in all those clauses. The `json_extract_scalar(geo, '$.country')` fallback for the case where `geo` is a JSON *string* (not a typed ROW) is also correct and a good disambiguation. Cites r09. Clean and complete.

---

## iter787 designation — FIX-A (additive findability, fixed-width string padding)

Real defect + miss (not a one-off responder slip), so iter787 is a **light additive FIX-A**:

1. **Add a fixed-width string-padding canonical at a findable landing point.** Best home: r23 §3.1A (beside the `format()` printf canonical, where "pad/format a string" keywords land) AND/OR a cross-ref-anchored card near r27:983. Feature the copy-attractive one-liner:
   - **`rpad(product_code, 20, ' ')`** — right-pad to 20 chars with spaces, **truncates if longer than 20** (one function, verbatim docs behavior). `lpad(string, size, padstring)` for left-pad (e.g. zero-pad `lpad(CAST(id AS VARCHAR), 10, '0')`).
2. **Add the no-`LEFT` / `%-20s`-doesn't-truncate note** (DO-NOT-WRITE, inline-marked WRONG so the weak responder doesn't copy the negative example):
   - DO NOT write `LEFT(s, 20)` → `Function 'left' not registered`; use `substr(s, 1, 20)` or just let `rpad`/`lpad` truncate.
   - DO NOT write `format('%-20s', s)` for a fixed-width column that must truncate — `%-20s` pads short strings but does NOT truncate long ones (need `%-20.20s`); prefer `rpad(s, 20, ' ')` which pads AND truncates in one call.
3. **Keyword anchors** (so this is reachable next time): "pad a string to fixed width, fixed-width flat-file export, right-pad with spaces, pad to exactly N characters, truncate if longer, rpad / lpad Trino, fixed-width column export, pad product code/SKU to N chars."
4. **Reconcile in place** — keep r27:983's Oracle-porting + numeric-cast framing (load-bearing for the zero-pad-numeric trap); ADD a cross-ref to the new fixed-width-string card. Do NOT duplicate-and-contradict.

**PRESERVE (verified clean, churn risk):** r23 §3.1B SUM(DECIMAL) widen + §3.1A `format()` printf canonical, r07 ORDER BY CASE custom-sort, r09 ROW dot-access + json_extract_scalar fallback. Do NOT touch these.

---

## Summary

- Per-Q avgs: Q1 5.00 / Q2 5.00 / Q3 2.50 / Q4 5.00
- **Overall avg 4.375 — PASS**
- Q3 verdict: **DEFECT** (non-compiling `LEFT()` primary + `%-20s` doesn't truncate) **+ MISSED CANONICAL `rpad(product_code, 20, ' ')`** (pads AND truncates in one call). Resources have rpad/lpad at **r27:983** but only under Oracle-porting/numeric-zero-pad framing → **FINDABILITY GAP edging to content gap** (no fixed-width-string-padding canonical, unreachable from flat-file-export keywords).
- **iter787 = FIX-A** (additive): feature `rpad(s, 20, ' ')` / `lpad(s, N, '0')` fixed-width-string canonical at a findable landing point (r23 §3.1A and/or r27 cross-ref) with the no-`LEFT` + `%-20s`-doesn't-truncate notes and the keyword anchors above.
