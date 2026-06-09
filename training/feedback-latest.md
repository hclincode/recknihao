# iter844 Judge Feedback — DEFAULT NO-OP durability sweep

**Overall: 5.00 STRONG PASS** (Q1 5.00 / Q2 5.00 / Q3 5.00 / Q4 5.00)
Phase: extended. Teacher made ZERO resource edits this iteration (default no-op). All dialect claims docs-verified vs trino.io/docs/467 (bitwise.html / string.html / select.html) + WebSearch 2026-06-09. PIN Trino 467. DO NOT bump training/state.json (already 844).

---

## Per-question scores

### Q1 — bitmask: check a bit + count set bits; is `&` an operator or function? — **5.00 CLEAN**
Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5

VERIFIED vs trino.io/docs/467/functions/bitwise.html (WebFetch):
- Trino has **NO `&` bitwise-AND operator** — only the `bitwise_and(x, y)` FUNCTION. CONFIRMED (no `&` operator documented). Responder correct.
- Trino has **NO `<<` shift operator** — only `bitwise_left_shift(value, shift)` FUNCTION. CONFIRMED. Responder's dynamic-bit form `bitwise_and(flags, bitwise_left_shift(1, n)) <> 0` is correct.
- `bit_count(x, bits)` **REQUIRES 2 args** ("number of bits set in x, treated as bits-bit signed integer"); **NO 1-arg form, NO popcount()**. CONFIRMED. Responder's `bit_count(flags, 64)` for a bigint + explicit CAVEAT (2nd arg required, no popcount) is exactly right.
- `bitwise_and(flags, 8) <> 0` (bit 3 = value 8) and `bit_count(13, 64) = 3` (1101) both arithmetically correct.

All four pinned facts confirmed. No defect.

### Q2 — expand array to rows WITH position — **5.00 CLEAN**
Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5

VERIFIED vs trino.io/docs/467/sql/select.html (WebFetch): `UNNEST ... WITH ORDINALITY` adds an additional ordinality column **at the END**, **1-based**, aliasable — doc example `UNNEST(...) WITH ORDINALITY AS t(a, b, rownumber)`. Responder's `CROSS JOIN UNNEST(tags) WITH ORDINALITY AS t(tag, position)` is correct; position 1-indexed as last alias; worked example (billing,1),(urgent,2),(refund,3) correct. Single-statement answer (no self-join needed) matches the ask. No defect.

### Q3 — fuzzy string distance — **5.00 CLEAN**
Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5

VERIFIED vs trino.io/docs/467/functions/string.html (WebFetch): `levenshtein_distance(string1, string2) → bigint`, minimum single-char edits (insert/delete/substitute). EXISTS, signature confirmed, return type bigint confirmed. Responder's `levenshtein_distance(lower(company_name), lower('acme inc')) <= 2` (case-insensitive wrap + threshold) is correct and idiomatic; threshold guidance (<=2 typo-tolerant, looser <=3/<=4) is sound practical advice. No defect.

### Q4 — custom (non-alphabetical) sort order — **5.00 CLEAN**
Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5

VERIFIED vs trino.io/docs/467/sql/select.html: ORDER BY accepts arbitrary expressions composed of output columns; CASE is a standard SQL expression and produces a valid numeric sort key. Responder's `ORDER BY CASE priority WHEN 'critical' THEN 1 ... END` sorts critical-first without mutating stored values; lookup-table suggestion for many values is a good scale note. No defect.

---

## Production-environment fit
All four answers are pure ANSI/Trino SQL with no infra dependency — no conflict with the on-prem Trino 467 + Iceberg + MinIO + HMS stack. No auth/authz scope issues. Clean.

## Summary
- ALL 4 CLEAN at 5.00. No defect, no findability slip, no fabrication, no dialect error.
- Q1 re-confirms the bitwise family bulletproofing (no `&` operator / no `<<` / 2-arg bit_count / no popcount) — a durability angle held with zero regression.
- Q2/Q3/Q4 are well-established correct surfaces; no churn warranted.

## iter845 directive — **DEFAULT NO-OP / durability sweep** (NO defect surfaced; NOT a FIX-A)
Teacher: make ZERO resource edits. Re-probe a fresh adjacent 2nd-angle batch, e.g.:
- bitwise: clear/set/toggle a bit (`bitwise_or`, `bitwise_xor`, `bitwise_not`) or right-shift; confirm no `|`/`^`/`~` operators.
- UNNEST WITH ORDINALITY over a MAP, or multi-array UNNEST positional alignment.
- levenshtein on longer strings / combined with a similarity ratio (1 - dist/length) framing.
- custom sort via a join to an ordering lookup table, or CASE-in-ORDER-BY with NULLS placement.

PRESERVE all standing pins: iter843 approx_percentile accuracy framing, iter842 value-vs-rank percentile clarifier, iter840 weighted-avg §3.1B-WA, iter837 string→DATE MySQL-vs-Joda, iter836 lpad/format pad card, iter831 month-name grouping, iter827 boolean-aggregate-NULL, iter824/823 split_part/GROUP-BY-alias/repeat-char, trim char-set, default-NULLS-LAST, and the full iter534-843 lock inventory. NO federation edits (r22 §13.x ZERO edits, federation row stays 4.49944/310). DO NOT bump training/state.json (already 844).
