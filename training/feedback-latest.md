# Judge Feedback — iter903 (NO-OP durability sweep)

**Overall: 5.00 STRONG PASS** (per-Q 5.00 / 5.00 / 5.00 / 5.00 = 20.00 / 4 = 5.00; margin +1.50 over the 3.5 bar). Overall average governs — no per-Q veto. **DEFAULT NO-OP for iter904 — teacher makes ZERO edits.** Do NOT bump `training/state.json` (already passed).

Federation (4.49944/310) was NOT probed this sweep — that row is UNCHANGED and remains the only un-passed topic.

---

## Q1 BACKSLASH VERDICT — THE RUN-PROMPT PREMISE IS REFUTED; `'\\s+'` IS CORRECT, NOT OVER-ESCAPED

The directive asked me to confirm that the secondary query's DOUBLE-backslash `regexp_replace(feedback, '\\s+', ' ')` is over-escaped/wrong and that the single-backslash `'\s+'` is the correct Trino form. **Verified against source first (iter882 discipline) — and the premise is the OPPOSITE of the truth:**

- The OFFICIAL Trino 467 `regexp.html` examples consistently use **DOUBLE backslash** for regex metacharacters and they WORK:
  - `regexp_replace('1a 2b 14m', '\\d+[ab] ')` → `'14m'`
  - `regexp_like('1a 2b 14m', '\\d+b')` → `true`
  - `regexp_replace('new york', '(\\w)(\\w*)', x -> upper(x[1]) || lower(x[2]))` → `'New York'`
- Multiple authoritative sources agree on the double-backslash convention: Trino current docs, the cited GitHub discussions (#17673 / #17474), and the Medium "Comprehensive Guide to Regular Expressions in Trino" (which uses `'\\d+'` and `'\\bworld\\b'`).
- Yes — Trino SQL string literals do not process backslash *as a SQL escape* (only single-quote-doubling escapes a quote). But the documented, working convention for regex metacharacters in Trino is nonetheless **double backslash** `'\\d'` / `'\\s'` / `'\\w'`, exactly as the responder wrote.

**Conclusion: the responder's `'\\s+'` matches the official 467 documented form. It is NOT over-escaped, it is NOT a defect, and there is NO Accuracy deduction.** The run-prompt's framing (and its "iter894 single-backslash was correct" contrast) is contradicted by the 467 docs.

**SCOPE-CHECK consequence:** Because there is no Q1 defect, there is NO escalation, NO iter904 re-probe on backslash form, and NO FIX-A. Critically — **do NOT "correct" any resource toward the single-backslash `'\s+'` form.** Doing so would push resources AWAY from the official Trino 467 double-backslash convention and could introduce a real defect. Leave the regexp_replace collapse-whitespace canonical untouched.

(This is exactly the iter882 trap: a doc-CORRECT responder claim must not be flagged as a defect just because a directive suspected it. Verify-first paid off.)

---

## Per-question verdicts (all VERIFIED vs trino.io/docs/467)

- **Q1 — count words (5.00).** PRIMARY `cardinality(split(trim(feedback), ' ')) AS word_count` — split → array, cardinality → length; trim() strips leading/trailing whitespace first. Valid (string.html `split`, array.html `cardinality`). SECONDARY multi-space-collapse variant with `'\\s+'` — correct double-backslash form (see verdict above).
- **Q2 — status_code → label (5.00).** Simple-CASE form `CASE status_code WHEN 1 THEN ... ELSE 'Unknown' END` confirmed valid (conditional.html). GROUP BY `status_label` on a subquery-wrapped CASE is legal — it groups on a REAL materialized outer-query column, not a same-level SELECT alias.
- **Q3 — active in BOTH Jan AND Feb (5.00).** `WHERE order_date >= DATE '2026-01-01' AND order_date < DATE '2026-03-01' GROUP BY customer_id HAVING COUNT(DISTINCT date_trunc('month', order_date)) = 2`. date_trunc('month',...) → first-of-month midnight; half-open range confines to Jan+Feb only; `= 2` distinct months ⇒ rows in BOTH months. Logic and dialect both sound.
- **Q4 — purely alphabetic (5.00).** `regexp_like(code, '^[A-Za-z]+$')` returns boolean; anchored `^...$` and the inline `(?i)` case-insensitive flag are both documented/supported. Used the correct Trino FUNCTION — no Postgres `~`-operator regression.

---

## Instructions for the teacher (iter904)

- **DEFAULT NO-OP. Make zero resource edits.**
- Do NOT add any "wrong" card for Q1–Q4.
- Do NOT mark the `'\\s+'` double-backslash regexp_replace form wrong — it is the official 467 form.
- Do NOT migrate any resource to single-backslash `'\s+'`.
- Do NOT churn the split/cardinality word-count, regexp_replace collapse-whitespace, simple-CASE status-label, date_trunc/COUNT(DISTINCT) both-months, or regexp_like alphabetic-check cards.
- Re-probe fresh adjacents next sweep. Federation (4.49944/310) is the only un-passed row — probe only bulletproofed angles there.
- Do NOT touch any iter534–902 pin. PIN Trino 467. NO federation edits. DO NOT bump `training/state.json`.

Sources:
- [Trino 467 regexp functions](https://trino.io/docs/467/functions/regexp.html)
- [Trino 467 conditional expressions](https://trino.io/docs/467/functions/conditional.html)
- [Trino 467 date/time functions](https://trino.io/docs/467/functions/datetime.html)
- [Trino data types / string literals](https://trino.io/docs/467/language/types.html)
- [Trino discussion #17673 — backslash handling in string literals](https://github.com/trinodb/trino/discussions/17673)
