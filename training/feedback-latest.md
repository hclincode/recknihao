# Judge Feedback — iter851 (DEFAULT NO-OP durability sweep)

**Overall: 4.44 PASS** (Q1 5.00 / Q2 4.625 / Q3 3.875 / Q4 4.25). Pass threshold 3.5 (overall average governs, no per-Q veto). Teacher made ZERO resource edits this iteration (default no-op sweep). All dialect claims docs-verified vs trino.io/docs/467 (string/regexp/aggregate) + WebSearch 2026-06-09. PIN Trino 467. No prod-env conflict (pure SQL; on-prem Trino 467 + Iceberg + MinIO unaffected).

---

## Per-question scores

### Q1 — strip ALL whitespace from a phone string (Postgres `regexp_replace(phone,'\s+','','g')` → Trino) — **5.00 CLEAN**
- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5
- `regexp_replace(phone, '\s+', '')` is exactly right. VERIFIED vs trino.io/docs/467/functions/regexp.html: `regexp_replace(string, pattern, replacement)` "replaces every instance of the substring matched by the regular expression pattern" — replaces ALL non-overlapping matches BY DEFAULT, no Postgres-style `g` flag exists or is needed. `'\s+'` matches whitespace runs (spaces/tabs/newlines). Worked example `'555 867 5309'→'5558675309'` correct.
- The `replace(phone, ' ', '')` literal-single-space alternative is correct and the responder correctly scoped it ("for a literal single space" vs "for all whitespace use the regex"). No defect.

### Q2 — count occurrences of `'urgent'` in a comma-tag string — **4.625 (minor completeness)**
- Accuracy 5 / Completeness 4 / Clarity 5 / Actionability 4.5
- Workaround `cardinality(split(tags, 'urgent')) - 1` is CORRECT for counting non-overlapping occurrences (splitting on a substring with N occurrences yields N+1 elements → N occurrences). Minor example-arithmetic imprecision in the responder's narration of the worked example, but the FORMULA is correct; folded into completeness, not an accuracy error.
- **CLEANER-NATIVE NOTE (the completeness ding):** the responder said "resources document NO direct count function" and stopped at the split workaround. Trino 467 DOES have `regexp_extract_all(string, pattern)` (VERIFIED regexp.html — returns array of all matches), so `cardinality(regexp_extract_all(tags, 'urgent'))` is a cleaner one-call native count that does NOT need the `-1` correction and is more robust. The responder missed this. Workaround is valid, so this is completeness/actionability only, not accuracy.

### Q3 — most-common (mode) reason value, no `ORDER BY COUNT DESC LIMIT 1` — **3.875 (muddled first example)**
- Accuracy 3.5 / Completeness 4.5 / Clarity 3.5 / Actionability 4
- "No single `mode()` aggregate" is CORRECT (Trino 467 has no `mode()`). `max_by(reason, cnt)` over a `(GROUP BY reason, COUNT(*) cnt)` subquery returns the reason at the max count = the single mode (VERIFIED aggregate.html: `max_by(x, y)` returns value of x associated with the maximum value of y). `histogram(reason)` is a valid frequency-map aside; `approx_most_frequent` exists as another alternative.
- **MUDDLED-FIRST-EXAMPLE NOTE:** EX1 `SELECT reason, max_by(reason, cnt) ... FROM (grouped) GROUP BY 1` is WRONG/confusing. `GROUP BY 1` = `GROUP BY reason`, so the outer query produces ONE ROW PER REASON, and each group's `max_by(reason, cnt)` over its single inner row just returns that same reason — it does NOT collapse to the single mode. EX2 `SELECT max_by(reason, cnt) FROM (grouped)` (no outer GROUP BY) is CORRECT and returns the single most-common reason. Leading with a wrong example before the correct one drags accuracy (3.5) and clarity (3.5): a beginner could copy EX1 and get every reason back instead of the mode.

### Q4 — numeric code of a character (`'A'`=65) and reverse — **4.25 (factual error in worked example)**
- Accuracy 3 / Completeness 5 / Clarity 4.5 / Actionability 4.5
- Function usage is CORRECT: `codepoint(varchar) → integer` (single char only), `chr(bigint) → varchar` inverse (VERIFIED trino.io/docs/467/functions/string.html: codepoint = "Unicode code point of the only character of string"; chr = "Unicode code point n as a single character string"). The single-char constraint + `substr(s,1,1)` wrap for the first char of a longer string + `codepoint('US')` errors are all correct. `codepoint('a')→97`, `codepoint('ñ')→241`, `chr(85)→'U'`, `chr(241)→'ñ'` are all correct.
- **FACTUAL ERROR:** the responder wrote `codepoint('A') -> 85`. THAT IS WRONG — `codepoint('A') = 65` (ASCII/Unicode 'A' is 65; 85 is 'U'). VERIFIED chr(65)='A' per docs. This is a real factual error in a worked example (a beginner reading "A→85" learns the wrong value), so accuracy drops to 3 even though every function signature and the other values are correct.

**Q4 codepoint('A')=65-not-85 verdict: RESPONDER-SLIP (transcription error), NOT a resource defect.** GREP of `resources/` confirms the codepoint card lives at `resources/23-sql-best-practices-olap.md:528-547` and the resource CORRECTLY uses `codepoint('U') → 85` (line 536) and `codepoint('a') → 97` (line 537) — it does NOT contain any `codepoint('A')` example and never states `codepoint('A')=85`. The resource is CLEAN and CORRECT. The responder appears to have substituted the character `'A'` while carrying over the `85` value from the resource's `'U'` example — a responder mis-transcription, not content the resource taught. → **NO FIX-A; iter852 = DEFAULT NO-OP.**

---

## Defects / gaps summary
- **No resource defect surfaced.** The only accuracy errors this iteration (Q4 `codepoint('A')→85`, Q3 muddled EX1) are responder-side slips against CLEAN, CORRECT resources. The Q2 gap (missed `regexp_extract_all` count) is a minor completeness omission, not a content error.
- Q1 fully bulletproof.

## iter852 directive — **DEFAULT NO-OP** (NOT a FIX-A; no resource defect)
No resource edit is warranted (all errors are responder slips, all resources verified clean). Re-probe fresh adjacent 2nd-angle batch to keep durability coverage:
- (a) **Q3 mode re-probe** — confirm the correct scalar `max_by(x, cnt)`-over-grouped-subquery (no outer GROUP BY) is what the responder leads with on a rephrase; watch for the muddled `GROUP BY 1`-returns-one-row-per-value form re-appearing. OPTIONAL light findability touch ONLY if the muddled form recurs: at the most-common/mode card, lead with `SELECT max_by(reason, cnt) FROM (SELECT reason, COUNT(*) cnt ... GROUP BY reason)` as the copy-attractive canonical and inline-defang the `... GROUP BY 1` outer form on its own un-copyable line ("returns one row per value, NOT the single mode"). Do NOT churn if Q3 comes back clean on re-probe — a single muddled example does not justify an edit yet.
- (b) **Q2 count-occurrences re-probe** — OPTIONAL light findability touch: co-locate `cardinality(regexp_extract_all(s, 'sub'))` as the cleaner native next to the `cardinality(split(s,sub))-1` workaround at the count-occurrences landing (verify regexp_extract_all returns one element per match → cardinality = count, no `-1`).
- (c) **Q4 codepoint re-probe** — re-confirm `codepoint('A')=65` holds under rephrase (the resource is correct; this was a one-off transcription slip). No edit needed.
- (d) Fresh adjacent: `replace(s, old, new)` literal multi-char replace vs regexp_replace / `regexp_extract` single-match vs `regexp_extract_all` / `arbitrary()`/`any_value` vs `max_by` / `approx_most_frequent(n, x, capacity)` top-N frequencies.

PRESERVE all standing pins (iter843 approx_percentile accuracy / iter842 value-vs-rank / iter840 weighted-avg §3.1B-WA / iter837 string→DATE MySQL-vs-Joda / iter836 lpad/format pad / iter831 month-name grouping / iter827 boolean-aggregate-NULL / iter824/823 split_part/GROUP-BY-alias/repeat-char / trim char-set / default-NULLS-LAST / CAST-rounds-half-up / iter744 codepoint/chr card at r23:528-547 / full iter534-850 inventory). NO federation edits (federation 4.49944/310). **iter851 is NOT a FIX-A (no defect). DO NOT bump training/state.json (already 851).**
