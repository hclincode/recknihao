# iter991 Judge Feedback — 2026-06-17 (EXTENDED PHASE breadth sweep)

## Verdict: OVERALL 4.81 STRONG PASS

| Q | Accuracy | Completeness | Clarity | Actionability | Q-avg |
|---|---|---|---|---|---|
| Q1 LEFT-vs-INNER / find disappearing orders | 5.0 | 4.5 | 4.75 | 4.75 | 4.75 |
| Q2 regexp_replace + extract "Chrome" | 5.0 | 4.5 | 4.75 | 4.75 | 4.75 |
| Q3 date_trunc 'hour'/'week' valid units | 5.0 | 4.75 | 4.75 | 4.875 | 4.84 |
| Q4 earliest non-null date across columns | 5.0 | 5.0 | 4.75 | 4.875 | 4.91 |

**Overall = (4.75 + 4.75 + 4.84 + 4.91) / 4 = 4.81 → STRONG PASS** (margin +1.31; overall average governs, no per-Q veto). All dialect/logic claims verified BOTH directions vs trino.io/docs/467 + git-tag 467 raw source — NOT against resources/.

Prod stack (Trino 467 Iceberg + Hive Metastore on-prem MinIO + Spark ingestion + dbt) — all 4 Qs fit; no federation drag-in.

---

## Per-question verification

### Q1 — LEFT-vs-INNER semantics + anti-join diagnostic — 4.75 CLEAN
- INNER keeps only left rows with a right match; LEFT keeps all left rows (no-match → NULL right cols). VERIFIED CORRECT.
- The `r.refund_id IS NULL` filter on a LEFT JOIN is the textbook **anti-join** diagnostic — correctly referenced as the no-match set. **NO semi-join mislabel** (the known tic is clean here).
- Counting the IS NULL rows = the gap between LEFT and INNER row counts: correct.
- **Minor completeness gap (not a defect):** if `refunds` is one-to-many per order, the LEFT JOIN FANS OUT, so the LEFT-vs-INNER count delta is no longer purely "orders with no refund" (matched orders get multiplied). The responder did not mention fan-out / `COUNT(DISTINCT o.order_id)`. Only a Comp ding (4.5); the anti-join IS-NULL diagnostic itself correctly isolates the no-match orders regardless of fan-out.

### Q2 — regexp_replace + the REGEX BACKSLASH CHECK — 4.75 CLEAN
- **regexp_replace 3-arg `(string, pattern, replacement)` and 2-arg `(string, pattern)` removal form: BOTH VALID Trino 467** (functions/regexp.html raw source). CONFIRMED.
- **Capture-group backreference is `$1` / `$2`, NOT `\1`: CONFIRMED CORRECT.** Raw-source example: `regexp_replace('1a 2b 14m', '(\d+)([ab]) ', '3c$2 ')` uses `$2`. The responder's "$1 not \1 (\1 emits a literal backslash in Trino)" claim is accurate.
- **★ BACKSLASH VERDICT — responder's SINGLE-backslash `'(\d{3})(\d{3})(\d{4})'` is CORRECT working Trino. DO NOT FLAG.** Verified three ways:
  1. **types.md (467 raw source):** Trino does NOT process backslash escapes in standard single-quoted VARCHAR literals — a backslash is a LITERAL character (only `''` escapes a quote; only `U&'...'` strings use `\` escapes). So `'\d'` passes the two literal chars `\d` straight to the Java regex engine = digit class = WORKS. Conversely `'\\d'` would pass `\\d` to Java = escaped-backslash + `d` = matches a literal-backslash-then-d, which would NOT match a digit.
  2. **regexp.md (467 RAW markdown source):** the official examples write SINGLE backslash — `regexp_extract('1a 2b 14m', '\d+')`, `regexp_count('1a 2b 14m', '\s*[a-z]+\s*')`. (The HTML-rendered docs page shows `\\d` — that is a Sphinx/markdown RENDERING ARTIFACT, not the literal convention.)
  3. WebSearch confirmed the mechanism: Trino does no escape pre-processing; `'\d'` reaches Java regex as the digit class and works.
  - **Correction logged:** my 7-day-old `reference_trino_regex_backslash` memory asserted DOUBLE-backslash is canonical and single is "non-canonical/broken" — that was based on a misread of the HTML-rendered (escaped) example and is SUPERSEDED. The authoritative raw source + types.md escape semantics establish single-backslash `'\d'` as the correct working form. This is exactly the imported-prior self-error zone the directive flagged; verify-first prevented a false flag.
- Char-classes `[A-Za-z]` / `[^A-Za-z]` (which the responder also used) sidestep the backslash question entirely and are the safest copy-attractive form — good.
- **Minor completeness (Comp 4.5, not a defect):** the user asked to "extract just Chrome." The responder used the whole-string match-and-replace-with-`$1` trick and flagged it illustrative — acceptable — but **`regexp_extract(user_agent, 'Chrome', 0)` or `regexp_extract(user_agent, '(Chrome)/[0-9.]+', 1)` is the more natural EXTRACTION tool** for this exact ask. Mentioning regexp_extract would have improved the answer. Noted as a minor scope point, not an error.

### Q3 — date_trunc valid units — 4.84 CLEAN
- **'hour' and 'week' BOTH valid date_trunc units: CONFIRMED** (datetime.html / raw datetime.md).
- **'week' truncates to MONDAY: CONFIRMED** (raw-source example truncates to a Monday, ISO-8601). Responder's "Monday start, ISO-8601" is correct.
- **★ 'millisecond' VERDICT — the responder's inclusion of 'millisecond' is CORRECT, NOT an over-inclusion. DO NOT FLAG.** Verified: the 467 raw datetime.md date_trunc unit table lists `millisecond` as the first row, and GitHub issue #20427 ("date_trunc has `millisecond` support but missing in the doc") confirms millisecond IS supported (it was merely absent from some doc renderings). The full valid list — millisecond, second, minute, hour, day, week, month, quarter, year — matches the responder exactly. No date_trunc-unit-fabrication tic.
- **Minor clarity (Clar 4.75):** "NO sub-hour unit like 'minute'" is muddled phrasing — `minute` (and `second`/`millisecond`) ARE valid date_trunc units. The responder clearly MEANS "no built-in for custom N-minute buckets (5/15-min) — that needs arithmetic," which is correct. Cosmetic wording slip, not a logic error.

### Q4 — earliest non-null date across columns — 4.91 CLEAN / STRONG
- **MIN is an AGGREGATE (reduces rows); multi-arg `MIN(a,b,c)` row-wise is WRONG/errors: CONFIRMED.** Correct diagnosis of the user's error.
- **`LEAST(c1,c2,c3)` is the row-wise scalar minimum across columns: CONFIRMED** (functions/comparison.html). GREATEST/LEAST = scalar row-wise; MAX/MIN = aggregate down rows. Mental-model contrast is accurate.
- **★ LEAST returns NULL if ANY argument is NULL in Trino 467: CONFIRMED CORRECT** (comparison.md raw source: "Like most other functions in Trino, they return null if any argument is null" — explicitly contrasted with PostgreSQL which returns null only if ALL are null). The responder's "CRITICAL: LEAST returns NULL if ANY argument is NULL" is exactly right — this is the GREATEST/LEAST-NULL rule, and the responder did NOT fall into the Postgres-prior trap.
- **★ COALESCE-with-far-future-sentinel workaround CORRECT:** `LEAST(COALESCE(c1, DATE '2099-12-31'), ...)` makes NULL columns lose the LEAST comparison, so the result is the earliest NON-NULL date per row — the right idiom and it correctly addresses the user's actual intent (earliest non-null, not earliest-or-null). Strong, complete answer.

---

## Tic scan — ALL CLEAN
No QUALIFY / no false-mechanism semi-join mislabel (Q1 anti-join correctly referenced) / no MAX(varchar) / no percent_rank inversion / no fabricated functions (regexp_replace 2&3-arg, regexp_extract, LEAST/GREATEST, date_trunc 'millisecond'..'year' ALL REAL & correct) / no regex-backslash-error (Q2 single `\d` VERIFIED correct — NOT flagged) / no date_trunc-unit-fabrication (Q3 'millisecond' VERIFIED real) / no GREATEST-LEAST-NULL error (Q4 any-arg-NULL→NULL CORRECT) / no PARTITIONED-BY foreign DDL / no broken-secondary false-justification / no mid-churn / no column-scope / no ILIKE conflation.

## Scope notes
- **Q2 backslash:** single `'\d'` = CORRECT working Trino (types.md no-escape semantics + raw regexp.md single-backslash convention + mechanism confirmed); HTML `\\d` is a render artifact; `$1` backreference (not `\1`) CONFIRMED; regexp_replace 2&3-arg CONFIRMED; regexp_extract would be the more natural extractor (minor).
- **Q3:** 'hour' + 'week' valid, week=Monday CONFIRMED; **'millisecond' IS a real date_trunc unit (NOT over-inclusion)** per #20427 + raw source; "no sub-hour unit" phrasing is a minor clarity slip (means no custom N-minute bucket).
- **Q4:** LEAST-not-MIN CONFIRMED; **LEAST-NULL-propagation (any-arg-NULL→NULL) CONFIRMED CORRECT**; COALESCE-far-future-sentinel for earliest-non-null CONFIRMED CORRECT.
- **Q1:** anti-join IS-NULL diagnostic CORRECT; minor fan-out completeness gap (one-to-many refunds inflate the LEFT count) — Comp ding only.

## Recommendation = DEFAULT NO-OP
Margin +1.31; all 4 leads correct & verified both directions; zero tics; no findable resource/findability gap; no 2-in-2 recurrence. Re-probe next sweep: (a) another regex-extraction Q — confirm single-`\d` stays correct + watch for regexp_extract suggestion; (b) another date_trunc/bucketing Q — confirm millisecond/week-Monday + the N-minute-arithmetic phrasing; (c) STILL OWED from iter989: another DISTINCT-vs-GROUP-BY/dedup Q to settle the perf-folklore one-off (2-in-2 → trace to resource root cause). Federation r22 §13.x hard-locked NOT probed (OVERRIDDEN). NO resource edits. **MUST NOT bump training/state.json** (already 991; passed=true preserved; final_iterations_remaining 0).

**Self-correction this iter:** `reference_trino_regex_backslash` memory (DOUBLE-backslash canonical) is SUPERSEDED — single `'\d'` is the correct working form per types.md + raw regexp.md; HTML `\\d` was a render artifact I previously misread.
