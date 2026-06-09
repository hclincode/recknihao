# Judge Feedback — iter822 (DEFAULT NO-OP durability sweep)

Phase: extended. Teacher made zero resource edits. All dialect claims verified against trino.io/docs/467 (string, array, regexp function pages).

## Per-question scores

### Q1 — group-concat into one comma-separated string
- Accuracy 5: `listagg(tag_name, ', ') WITHIN GROUP (ORDER BY tag_name) ... GROUP BY customer_id` is valid Trino 467. listagg requires `WITHIN GROUP (ORDER BY)` and a VARCHAR expression (CAST numeric IDs first) — both stated correctly. `array_join(array_agg(x ORDER BY x), ', ')` equivalent is correct.
- Completeness 5: covered ordering control, the CAST-to-varchar guardrail, and the array_join alternative.
- Clarity 5: worked output `'enterprise, high-value, trial'`, no assumed knowledge.
- Actionability 5: copy-ready, correct citations (r07:557-595, r27:4046-4087).
- **Avg 5.00**

### Q2 — position of a substring
- Accuracy 5: `strpos(s, sub)` is 1-based and returns 0 if not found (verified verbatim). `position(sub IN s)` equivalent — verified. 3-arg `strpos(s, sub, -1)` negative-instance for last occurrence — verified ("When instance is a negative number the search will start from the end").
- Completeness 5: first-occurrence, not-found semantics, equivalent form, and last-occurrence bonus.
- Clarity 5: worked example `strpos('https://example.com/api/users','/api')->19`.
- Actionability 5: correct, copy-ready, cited (r27:979-1056, r23:413-454).
- **Avg 5.00**

### Q3 — repeat a character N times to build an ASCII bar — FLOUNDERED
- Accuracy 2: The FINAL answer `rpad(lpad('', 7, '|'), 10, ' ')` is CORRECT — traced: `lpad('', 7, '|')` -> `'|||||||'`, then `rpad('|||||||', 10, ' ')` -> `'|||||||   '` (7 pipes + 3 spaces, width 10). BUT the path there is riddled with errors: (1) FALSE claim "Trino does not have a native repeat() function in the string library" — `repeat(element, count)` DOES exist in Trino 467; it returns an ARRAY, not a string. (2) Wrote a BROKEN `concat(repeat('|',7), repeat(' ',3))` form — concat of two arrays does not produce the string `'|||||||   '`. (3) Wrote `lpad(repeat('|', 7), 10, ' ')` — lpad's first arg must be varchar, repeat returns an array -> type error. The clean canonical `array_join(repeat('|', 7), '')` -> `'|||||||'` was never reached.
- Completeness 3: it does answer the literal question (a fixed-width bar form that works), but never delivers the clean repeat-into-string idiom and never corrects its own false repeat() claim.
- Clarity 1: self-contradictory, visible thrashing ("wait, that's wrong", "I don't have documentation of a repeat() function... Let me search more carefully"). An engineer reading this cannot tell which of the 4 forms shown is the right one without tracing each. Leaves the FALSE "no native repeat()" assertion standing.
- Actionability 2: only the very last line is usable; the rest is noise and one actively-wrong fact a reader could copy.
- **Avg 2.00**

### Q4 — check string is all digits
- Accuracy 5: `regexp_like(quantity, '^[0-9]+$')` is valid Trino 467 (Java/re2j regex; anchors `^`/`$` and char class `[0-9]+` all supported — verified). Float pattern `'^[0-9]+(\.[0-9]+)?$'` correct. The note that `LIKE '[0-9][0-9][0-9]'` does NOT work (Trino LIKE has no char classes; treats `[0-9]` as literal) is correct.
- Completeness 5: integer-only + float variant + rejected-input list + try_cast caveat.
- Clarity 5: explicit rejected examples (`'123abc'`, `'12.5'`, `' 123'`, `''`).
- Actionability 5: copy-ready, cited (r23:2743-2897, r27:1072-1220).
- **Avg 5.00**

## Overall

(5.00 + 5.00 + 2.00 + 5.00) / 4 = **4.25 — PASS** (overall average governs; no per-Q veto).

## Q3 DIAGNOSIS — findable-but-missing GAP (not a slip)

Grepped all of resources/ for `repeat`, `array_join(repeat`, `ASCII bar`, `progress bar`, `rpad(lpad`, `lpad('')`:
- NO match for any repeat-into-a-string canonical, no `array_join(repeat(...), '')`, no ASCII/progress-bar card anywhere.
- The only relevant card is the fixed-width pad card at **resources/23-sql-best-practices-olap.md:586-604** (`rpad`/`lpad` to fixed width). The responder correctly cited it (r23:586-604) and salvaged a correct final answer from it — but that card is about padding an EXISTING string to width; it has NO repeat/build-a-bar idiom and never mentions that `repeat()` returns an array.
- `array_join` appears extensively in r07 (435-589) but ONLY in the `array_join(array_agg(...))` group-rollup context, never as `array_join(repeat(char, n), '')`.

Conclusion: the responder floundered for LACK OF A CARD, not because it mangled present content. This is a **findable-but-missing GAP**. The false "no native repeat()" claim is exactly the symptom predicted by the foreign-function-priors pattern (cf. starts_with/listagg/trim/bitwise memory entries): with no card asserting repeat() exists, the responder guessed it doesn't.

## iter823 DIRECTIVE — FIX-A (close the Q3 gap)

Add a "repeat a character/string N times" canonical, placed where build-a-bar keywords route (adjacent to the r23:586 fixed-width pad card, since that is where the responder landed):
- LEAD canonical: `array_join(repeat('|', 7), '')` -> `'|||||||'`. Inline-state that **`repeat(element, count)` returns an ARRAY (`array(E)`), NOT a string** — so you must `array_join(..., '')` to flatten it; `concat(repeat(...))` / `lpad(repeat(...), ...)` are WRONG (type error / array, not string) — defang those two forms inline on their own lines, marked WRONG/un-copyable per the defang-snippets memory rule.
- Fixed-width-bar ALTERNATIVE: `rpad(lpad('', 7, '|'), 10, ' ')` -> `'|||||||   '` with the trace (lpad empty->7 pipes, rpad to 10 with spaces). This is the cleaner one-expression answer for the ASCII-progress-bar use case.
- Keyword anchors: *repeat a character, repeat a string, build an ASCII bar, progress bar, N times, fill with a character, gauge/meter string*.
- Explicitly correct the "Trino has no repeat()" misconception in the card text.

## Other flags

None. Q1/Q2/Q4 are bulletproof from these phrasings. If iter823 lands the repeat/array_join card cleanly, re-probe Q3 from a second angle (e.g. "repeat a dash to draw a separator line") to confirm before treating the topic as durable.
