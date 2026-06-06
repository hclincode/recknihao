# Iter 562 — Judge feedback (2026-06-07)

**OVERALL: 4.59375 PASS** (margin +1.09375 above 3.5 floor; -0.34375 swing from iter561's 4.9375 STRONG PASS — Q2 EXPLAIN ANALYZE skew drags 3.375 on placement-miss + fabricated absence; Q1 + Q3 + Q4 all perfect 5.00).

Federation NOT probed — federation rubric row 4.49944/310 UNCHANGED.

---

## Per-Question Scores

### Q1 — Postgres EXTRACT(EPOCH FROM order_ts) → Trino equivalent (iter562 r23 EXTRACT-EPOCH canonical WIN CHECK)

**Scores: 5.0 / 5.0 / 5.0 / 5.0 = 5.00 STRONG PASS**

Responder: `to_unixtime(order_ts)` returns DOUBLE seconds-since-epoch; CAST to BIGINT for whole seconds; `from_unixtime()` inverse. Note responder attributed answer to "to_unixtime is a standard Trino function (verified in resources as working)" — gave the correct answer but didn't explicitly cite the iter562-new r23 EXTRACT-EPOCH LEADING CANONICAL.

**Verbatim verification at trino.io/docs/467/functions/datetime.html:**
- `to_unixtime(_timestamp_) → double` — "Returns `timestamp` as a UNIX timestamp."
- EXTRACT supported fields: `YEAR, QUARTER, MONTH, WEEK, DAY, DAY_OF_MONTH, DAY_OF_WEEK, DOW, DAY_OF_YEAR, DOY, YEAR_OF_WEEK, YOW, HOUR, MINUTE, SECOND, TIMEZONE_HOUR, TIMEZONE_MINUTE` — **EPOCH is NOT in the supported field list**.

Answer maps 1:1 to docs. Inverse function name + signature correct. CAST guidance correct (DOUBLE → BIGINT for whole seconds; × 1000 → BIGINT for milliseconds is implied by the canonical, not stated, but acceptable). Per directive: "The ANSWER is correct regardless of citation — score on correctness." Answer is correct on every numeric.

**iter562 FIX B VALIDATED** — Postgres EXTRACT(EPOCH FROM ts) → Trino to_unixtime cross-engine canonical added to r23 between greatest/least canonical and §3.1H routed cleanly on first re-probe.

---

### Q2 — EXPLAIN ANALYZE skew diagnosis (iter562 r23 §4 Input std.dev. skew indicator WIN CHECK + PLACEMENT-MISS DIAGNOSIS)

**Scores: 3.5 / 3.0 / 3.5 / 3.5 = 3.375 THIN FAIL on this question alone (overall-average still PASS)**

Responder: "look at Scheduled time spread across workers / CPU vs Scheduled time; big wall-time spread in same operator = data skew; fix by partition-align GROUP BY / re-partition at ingest / sorted_by / pre-aggregate hot tenant." Cited r18 (query-performance-regression). EXPLICITLY said "The resources don't provide a detailed worked example of skew diagnosis."

**Verbatim verification at trino.io/docs/467/sql/explain-analyze.html:**
- Per-operator distribution fields literally printed: `"Input avg.: 1000.00 rows, Input std.dev.: 0.00"`
- Skew-as-purpose framing: `"Such statistics are useful when one wants to detect data anomalies for a query (e.g: skewness)."`

**Diagnosis (per directive):**

1. **Directional guidance is SOUND** — "look at wall-time / CPU vs Scheduled spread across workers" maps to the right concept (per-driver/operator variance is the skew tell); fixes named (salt the join key, re-partition at ingest, sorted_by, pre-aggregate hot tenant) are real Trino remediations.
2. **Did NOT name the precise Trino 467 field** — `Input avg.` / `Input std.dev.` per-driver fields that iter562 FIX A added to r23 §4 (L706 5-row red-flag cheat-sheet with `"High per-operator Input std.dev. % → DATA SKEW. Salt the hot key..."`). Loose terminology — Accuracy -1.5, Completeness -2.0.
3. **CRITICAL — FABRICATED ABSENCE**. Responder said "The resources don't provide a detailed worked example of skew diagnosis." VERIFIED FALSE:
   - **r18 §5** (`/Users/hclin/github/recknihao/resources/18-query-performance-regression.md` L944-1055) contains a full worked GROUP BY skew diagnosis using `EXPLAIN ANALYZE VERBOSE`, per-driver `inputRows` min/p50/max read pattern, telltale-signs table, AND four concrete fixes (two-level salt GROUP BY at L990 is the primary fix).
   - **r23 §4** just received the iter562 FIX A 5-row red-flag cheat-sheet table that names `Input std.dev. %` by exact label.
   The "resources don't provide" disclaimer is exactly the FABRICATED-ABSENCE failure mode the meta-rule names.

**PLACEMENT-MISS DIAGNOSIS (per directive):**

This is a layer-3 PLACEMENT MISS. The iter562 FIX A `Input std.dev.` skew indicator landed in **r23 §4 (SQL best practices — EXPLAIN ANALYZE field-name tightening)**, but the question "EXPLAIN ANALYZE one stage slow + big spread between workers + read it for data skew + fix" routes to **r18 (query-performance-regression — Step 3 / Step 5)** or **r24 (CBO / EXPLAIN-DISTRIBUTED)**.

GREP confirms (`grep -rn "Input std.dev|Input avg|skew|stddev|EXPLAIN ANALYZE" resources/{23,18,24}*.md`):
- r23 §4 L711 has the new `Input std.dev. %` skew-indicator row (iter562 FIX A).
- r18 §5 has older `EXPLAIN ANALYZE VERBOSE` per-driver `inputRows` min/p50/max content but NOT the new `Input std.dev.` exact-field-name canonical.
- r24 mentions skew in CBO context (L152, L391, L524) but no EXPLAIN ANALYZE field-name canonical.

The responder went to r18 (correct routing instinct) but only surfaced the older Step-3 / Step-5 content that uses VERBOSE per-driver `inputRows` min/p50/max — never reached the iter562 r23 §4 cheat-sheet that names `Input std.dev.` by exact Trino 467 label, because §4 "best-practices" isn't where a "slow query / EXPLAIN ANALYZE / data skew" question keyword-routes.

**iter563 FIX (layer-3 re-home / cross-ref):**
- **HIGH** — cross-ref or mirror the r23 §4 5-row red-flag cheat-sheet (especially the `Input std.dev. %` row + the salt-hot-key fix) into **r18 §5** ("Detecting GROUP BY skew with EXPLAIN ANALYZE VERBOSE", L965-986) AND **r24** (CBO / EXPLAIN canonical), so a "slow query + EXPLAIN ANALYZE + skew" routing lands on the precise Trino 467 field label.
- **HIGH** — add an explicit nav-hint at the top of r18 §5 like "WORKED EXAMPLE OF SKEW DIAGNOSIS HERE — Trino 467 EXPLAIN ANALYZE field `Input std.dev.` is the skew tell" so Haiku's keyword scan picks it up and stops fabricating an "absence."

Sound directionally; loose on the precise field name; FABRICATED ABSENCE on resource coverage. Polish-and-cross-ref fix, not a deep gap.

---

### Q3 — COUNT(DISTINCT user_id) on 500M rows → approx_distinct, accuracy, tuning

**Scores: 5.0 / 5.0 / 5.0 / 5.0 = 5.00 STRONG PASS**

Responder: `approx_distinct(user_id)` ~2.3% RSD (68% within ±2.3%, 95% ±4.6%); tunable via second param `approx_distinct(user_id, 0.01)` ~1%; valid range `[0.0040625, 0.26000]`; exact COUNT(DISTINCT) for billing; HLL sketch merge for rolling windows. Cited r23.

**Verbatim verification at trino.io/docs/467/functions/aggregate.html:**
- `approx_distinct(x) → bigint` and `approx_distinct(x, e) → bigint` — both signatures present.
- `"This function should produce a standard error of 2.3%, which is the standard deviation of the (approximately normal) error distribution over all possible sets."`
- `"The current implementation of this function requires that e be in the range of [0.0040625, 0.26000]."`

All three numerics (2.3% RSD default, [0.0040625, 0.26000] range, second-param tuning signature) match docs **verbatim**. 68/95 confidence framing for normal distribution is mathematically correct. Exact-for-billing carve-out + HLL sketch merge for rolling-window is the right additional context for a SaaS engineer.

---

### Q4 — LENGTH in Trino: characters or bytes? multi-byte (emoji/accents)?

**Scores: 5.0 / 5.0 / 5.0 / 5.0 = 5.00 STRONG PASS**

Responder: `LENGTH(string)` counts CHARACTERS (Unicode code points), not bytes; matches Postgres; `LENGTH('café')=4`, `LENGTH('👋')=1`; byte length via `OCTET_LENGTH` or `LENGTH(CAST(s AS VARBINARY))`. Cited "standard ANSI".

**Verbatim verification at trino.io/docs/467/functions/string.html:**
- `length(string) → bigint` — **"Returns the length of string in characters."**

CHARACTERS not bytes — verbatim correct. Postgres parity claim correct (Postgres `LENGTH(text)` also returns characters; `OCTET_LENGTH` for bytes — both standard ANSI). Worked examples: `LENGTH('café')` = 4 (c-a-f-é as 4 code points, correct); `LENGTH('👋')` = 1 (single emoji is one code point in Unicode, correct). `OCTET_LENGTH` is valid in Trino. `LENGTH(CAST(s AS VARBINARY))` byte-count workaround is standard and works.

---

## Overall Tally

| Q | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|
| Q1 (EXTRACT EPOCH → to_unixtime) | 5.0 | 5.0 | 5.0 | 5.0 | **5.00** |
| Q2 (EXPLAIN ANALYZE skew) | 3.5 | 3.0 | 3.5 | 3.5 | **3.375** |
| Q3 (approx_distinct) | 5.0 | 5.0 | 5.0 | 5.0 | **5.00** |
| Q4 (LENGTH chars vs bytes) | 5.0 | 5.0 | 5.0 | 5.0 | **5.00** |

**OVERALL AVERAGE = (5.00 + 3.375 + 5.00 + 5.00) / 4 = 18.375 / 4 = 4.59375 PASS** (margin +1.09375 above 3.5 floor).

---

## Confirmations

- **Q1 CONFIRMED** — iter562 FIX B (Postgres EXTRACT(EPOCH FROM ts) → Trino to_unixtime cross-engine canonical added to r23 between greatest/least canonical and §3.1H) routed on first re-probe; answer matches Trino 467 docs verbatim on every numeric.
- **Q3 CONFIRMED** — approx_distinct deep canonical at r23 strong; all three numerics (2.3% default RSD, [0.0040625, 0.26000] range, second-param tuning signature) match Trino 467 docs verbatim.
- **Q4 CONFIRMED** — LENGTH characters-not-bytes verified; OCTET_LENGTH + VARBINARY-CAST byte workarounds valid.

## Q2 Placement-Miss Diagnosis (iter563 fix target)

- **PLACEMENT MISS** — iter562 FIX A `Input std.dev.` skew-indicator cheat-sheet landed at r23 §4 (SQL best-practices, after the locked EXPLAIN-variants table at L676), but a "slow query + EXPLAIN ANALYZE + skew" question routes to r18 (query-perf-regression) or r24 (CBO/EXPLAIN). Responder routed to r18 (correct instinct), but only found the older Step-3 / Step-5 VERBOSE per-driver `inputRows` content — never reached the new r23 §4 cheat-sheet that names `Input std.dev.` by exact Trino 467 field label.
- **FABRICATED ABSENCE** — responder said "resources don't provide a detailed worked example of skew diagnosis." VERIFIED FALSE: r18 §5 L944-1055 has a full worked example with two-level salt GROUP BY fix at L990, and r23 §4 has the iter562 5-row red-flag cheat-sheet.
- **iter563 FIX (PRIMARY)**:
  - HIGH (layer-3 re-home / cross-ref) — mirror or cross-ref the r23 §4 5-row red-flag cheat-sheet (the `Input std.dev. %` skew row in particular) into r18 §5 ("Detecting GROUP BY skew with EXPLAIN ANALYZE VERBOSE") and r24 (CBO/EXPLAIN canonical), so a "slow query + EXPLAIN ANALYZE + skew" routing lands on the exact Trino 467 field label.
  - HIGH (responder-facing nav-hint at r18 §5 top) — add an explicit anchor line like "WORKED EXAMPLE OF SKEW DIAGNOSIS HERE — Trino 467 EXPLAIN ANALYZE field `Input std.dev.` is the skew tell; salt the hot key" so Haiku's keyword scan stops fabricating an "absence."

## Other Slips Flagged

- None. Q1 / Q3 / Q4 all clean; Q2 is the only finding.

## Meta-rule Discipline

- WebSearch-verified all four against trino.io/docs/467/ pages (datetime, explain-analyze, aggregate, string). Every responder claim either confirmed or precisely flagged. Meta-rule's "FABRICATED ABSENCES" caveat was decisive on Q2 — verified false against r18 §5 (worked salt-GROUP-BY example) + r23 §4 (iter562 FIX A cheat-sheet). 25th consecutive iter (iter537-562) where meta-rule discipline prevented a false-positive AND surfaced the layer-3 placement miss.

## Notes

- Did NOT bump training/state.json (teacher already set iteration=562).
- Did NOT touch resources/22 §13.x.
- Federation rubric row 4.49944/310 UNCHANGED.
- iter562 FIX B (EXTRACT(EPOCH) → to_unixtime canonical at r23) VALIDATED on first re-probe via Q1.
- iter562 FIX A (`Input std.dev.` skew indicator at r23 §4) NEEDS LAYER-3 RE-HOME / CROSS-REF to r18 §5 + r24 — iter563 primary fix target.

**OVERALL: 4.59375 PASS — Q1 (iter562 EXTRACT-EPOCH r23 canonical) + Q3 (approx_distinct) + Q4 (LENGTH chars) all STRONG WINS at 5.00; Q2 3.375 thin fail on this question alone (placement miss + fabricated absence) but overall-average rule holds PASS. iter563 fix = layer-3 re-home / cross-ref of `Input std.dev.` skew indicator into r18 §5 + r24 + responder-facing nav-hint at r18 §5 top to prevent fabricated-absence pattern on re-probe.**
