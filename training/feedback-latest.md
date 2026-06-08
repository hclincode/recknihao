# Judge Feedback — iter730

**Verification basis:** All dialect claims verified against trino.io/docs/467 (math.html, sql/select.html, functions/string.html, functions/array.html) on 2026-06-08. Not graded against resources/.

## Per-question scores (Accuracy / Completeness / Clarity / Actionability)

### Q1 — round UP (ceil/ceiling) — avg 5.00
- 5 / 5 / 5 / 5
- VERIFIED: math.html — `ceiling(x)` = "Returns x rounded up to the nearest integer" (toward +infinity); `ceil(x)` is explicitly "an alias for ceiling()". 4.1→5, 4.0→4 both correct.
- Responder used ceil()/ceiling() ONLY. Did NOT use round() (4.1→4 wrong), floor (toward −inf), truncate (toward zero), or CAST (rounds half-up). Clean.
- **ROUND-TO-WHOLE 4-WAY CANONICAL: STAYS CLOSED / BULLETPROOFED.** This is the 2nd consecutive clean round-direction datapoint after iter729 (CAST-rounds-not-truncates FIX-A). The round-up (ceil) leg is now confirmed correct from a distinct phrasing ("seat packs, always round up"). No defect.

### Q2 — TABLESAMPLE — avg 4.75
- 5 / 4 / 5 / 5
- VERIFIED: select.html — both `TABLESAMPLE BERNOULLI (percentage)` and `TABLESAMPLE SYSTEM (percentage)` exist. BERNOULLI = per-row independent probability, scans all blocks, no I/O reduction, uniform. SYSTEM = divides table into logical segments and samples at that granularity, can reduce I/O, non-uniform/connector-dependent. Responder's SYSTEM-vs-BERNOULLI characterization is accurate. `TABLESAMPLE SYSTEM (1)` syntax and percentage-arg form are valid Trino 467.
- Minor completeness ding: docs note neither method gives "deterministic bounds on the number of rows returned" — so ~1% is approximate, and `LIMIT 100` after a 1% sample of 400M still materializes ~4M sampled rows before the cap. Worth a one-line caveat but not an error.

### Q3 — strip specific leading characters (trim LEADING) — avg 4.75
- 5 / 4 / 5 / 5
- VERIFIED: string.html — `trim([ [ specification ] [ string ] FROM ] source)` IS supported with LEADING/TRAILING/BOTH. Docs examples: `trim('!' FROM '!foo!')→'foo'`, `trim(BOTH '$' FROM '$var$')→'var'`, `trim(TRAILING 'ER' FROM upper('worker'))→'WORK'`. Responder's `trim(LEADING '0' FROM '000042')→'42'` and `trim(LEADING '$' FROM '$PRD-99')→'PRD-99'` are correct.
- **CRITICAL NUANCE — CORRECTED vs the run-prompt framing:** the Trino 467 FROM-form trim_character is NOT single-char-only. The docs `trim(TRAILING 'ER' FROM 'WORKER')→'WORK'` strips a SET of characters (both E and R), and docs state "if the trim string contains duplicates, only the first is used." So the FROM-form IS the set-capable form. Separately, Trino 467 string.html documents NO `ltrim(string, chars)` / `rtrim(string, chars)` two-arg set form — only single-arg whitespace `ltrim(string)` / `rtrim(string)`. The run-prompt's premise (FROM-form=single-char; set-form=ltrim/rtrim(string,chars)) is INVERTED relative to the 467 docs.
- Net judgment: responder's answer is technically correct for the cases shown AND the trim form it cited already handles "a set of characters." The only real gap is presentational — the user explicitly said "(or set)" and the responder described trim as stripping "a specific character" without showing a multi-char example like `trim(LEADING '0$' FROM ...)` or stating that the FROM-form already accepts a char set. Minor completeness ding, NOT an accuracy error.

### Q4 — concatenate two array columns — avg 5.00
- 5 / 5 / 5 / 5
- VERIFIED: array.html — `||` concatenates arrays (`ARRAY[1] || ARRAY[2] → [1,2]`); `concat(array1,...,arrayN)` is the function form, explicitly "the same functionality as the SQL-standard concatenation operator (||)"; `array_distinct(x)` removes duplicate values. Responder's `product_tags || support_tags`, `array_distinct(...)` dedup, and the claim that `||` is BOTH the string and array concatenation operator are all accurate.

## Overall

| Q | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|
| Q1 | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | 5 | 4 | 5 | 5 | 4.75 |
| Q3 | 5 | 4 | 5 | 5 | 4.75 |
| Q4 | 5 | 5 | 5 | 5 | 5.00 |

**OVERALL AVERAGE = 4.875 → PASS** (threshold 3.5).

## Teacher feedback / flags for iter731

1. **Q1 round-to-whole 4-way canonical: CLOSED / bulletproofed.** No action. Two consecutive clean datapoints (iter729 CAST-rounds, iter730 ceil round-up) across different phrasings.

2. **Q3 trim set-form nuance — LIGHT ADDITIVE candidate (verify against docs first):** If the trim/strip-leading-chars canonical in r27 (and any r23 mirror) currently implies trim's FROM-form is single-character-only, that is WRONG for Trino 467 — `trim(LEADING|TRAILING|BOTH chars FROM s)` strips a SET of characters (docs example `trim(TRAILING 'ER' FROM 'WORKER')→'WORK'`; duplicates collapse to first). Also confirm the canonical does NOT recommend `ltrim(string, chars)` / `rtrim(string, chars)` as the Trino set-form — those two-arg forms are NOT documented in Trino 467 string.html (only single-arg whitespace ltrim/rtrim). The copy-attractive set-strip form is `trim(LEADING '0$' FROM s)`. Recommend a one-line keyword anchor + multi-char example so a "set of characters" phrasing lands on the trim-FROM set form, not on a non-existent ltrim/rtrim(string,chars). This is the only genuine (minor) gap surfaced this iter.

3. **Q2 TABLESAMPLE:** Accurate and well-targeted. Optional one-line note that the sample size is approximate (no deterministic row-count bound) would close the small completeness gap. Not urgent.

No false dialect claims emitted by the responder this iteration. state.json NOT modified.
