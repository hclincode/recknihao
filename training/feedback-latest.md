# Judge Feedback — iter850 (DEFAULT NO-OP durability sweep)

**Verdict: overall 5.00 STRONG PASS** — teacher made ZERO resource edits; this was a durability sweep. All dialect claims docs-verified vs trino.io/docs/467 (map/array/datetime .html) + WebSearch 2026-06-09. PIN Trino 467. No prod-env conflict (pure SQL; on-prem Trino 467 + Iceberg + MinIO unaffected).

## Per-question scores

### Q1 — merge two map columns without UNION/join — `map_concat(account_attrs, session_attrs)`
- Accuracy **5** — VERIFIED vs map.html: `map_concat` exists, merges 2+ maps, on key collision "that key's value in the resulting map comes from the last one of those maps" = RIGHTMOST wins (responder: "put override/session last" — EXACT). Key-in-only-one → in result: correct. NULL-handling: docs are SILENT, but Trino's general scalar convention (RETURNS NULL ON NULL INPUT) makes the NULL-if-either-input-NULL claim correct, and `COALESCE(map_arg, MAP())` empty-map wrap is valid Trino syntax + a high-value defensive nuance (real columns are often NULL).
- Completeness **5** — covers merge, collision direction, key-in-one, and the NULL hazard with the empty-map fix. Nothing material missing.
- Clarity **5** — "put override/session last" is a beginner-friendly mnemonic for rightmost-wins.
- Actionability **5** — drop-in SELECT expression + the NULL guard the engineer will actually hit.
- **Q1 avg = 5.00 CLEAN**

### Q2 — numeric index of a value in an array — `array_position(enabled_flags, 'dark_mode')`
- Accuracy **5** — VERIFIED vs array.html: "Returns the position of the first occurrence of the element in array x (or 0 if not found)." 1-based (array `[]` indexed from one), 0-if-absent (NOT NULL), first-occurrence — all three EXACT. UNNEST(...) WITH ORDINALITY per-element-position alt is correct (verified iter844 vs select.html).
- Completeness **5** — leads with canonical, gives 3→3 worked example, proactively flags the duplicates-collapse-to-first caveat with the WITH ORDINALITY escape hatch.
- Clarity **5** — concrete '"dark_mode" 3rd → 3' example, zero assumed knowledge.
- Actionability **5** — engineer knows exactly what to write and when to switch to WITH ORDINALITY.
- **Q2 avg = 5.00 CLEAN**

### Q3 — quarter of year as label/number — `quarter(bill_date)` / `CONCAT('Q', CAST(quarter(bill_date) AS varchar))`
- Accuracy **5** — VERIFIED vs datetime.html: `quarter(x) → bigint` "Returns the quarter of the year from x. The value ranges from 1 to 4"; `EXTRACT(QUARTER FROM x)` maps to quarter(). CRITICAL PINNED FACT CONFIRMED: `quarter_of_year()` does NOT exist (docs list only `quarter()`, no alias by that name). The responder's contrast is also docs-accurate: `week_of_year(x)` IS an alias for `week()` — so "quarter has no _of_year variant unlike week" is exactly right. CONCAT('Q', CAST(quarter(x) AS varchar)) → 'Q1' valid.
- Completeness **5** — number form, EXTRACT equivalent, label form, AND the fabrication guardrail (don't reach for quarter_of_year) all covered.
- Clarity **5** — directly replaces the engineer's CASE WHEN month<=3 chain with a one-liner; clear.
- Actionability **5** — both number and 'Q1' label provided, ready to drop into the billing report.
- **Q3 avg = 5.00 CLEAN**

### Q4 — distinct calendar days active — `COUNT(DISTINCT CAST(event_timestamp AS date))`
- Accuracy **5** — VERIFIED vs Trino 467 standard semantics: `CAST(timestamp AS date)` truncates the instant to its calendar date; `COUNT(DISTINCT date)` counts unique days. The contrast with `COUNT(DISTINCT event_timestamp)` (counts each distinct instant → 3 same-day events = 3 not 1) is correct and is the exact trap the engineer would fall into.
- Completeness **5** — canonical + GROUP BY user_id + the wrong-alternative contrast with worked numbers. Complete.
- Clarity **5** — "3 events same day → 3 not 1" makes the instant-vs-day distinction concrete for a beginner.
- Actionability **5** — copy-paste per-user query.
- **Q4 avg = 5.00 CLEAN**

## Overall

| Q | Acc | Comp | Clar | Act | Avg |
|---|---|---|---|---|---|
| Q1 | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | 5 | 5 | 5 | 5 | 5.00 |
| Q3 | 5 | 5 | 5 | 5 | 5.00 |
| Q4 | 5 | 5 | 5 | 5 | 5.00 |

**Overall average = 5.00 → STRONG PASS** (threshold 3.5; overall average governs, no per-Q veto).

## Defects / gaps
- NONE. No fabrication, no parse-error risk, no dialect error, no findability slip, no prod-env conflict.
- Notable strengths: Q1 rightmost-wins + empty-map NULL guard; Q3 the `quarter_of_year()`-does-NOT-exist pinned fact held under rephrase AND the responder correctly distinguished it from the genuine `week_of_year()`/`week()` alias (a precise, non-fabricated contrast).

## iter851 directive — DEFAULT NO-OP / durability sweep (NOT a FIX-A; no defect surfaced)
All four answers clean at 5.00; no resource edit warranted. iter851 = re-probe fresh adjacent 2nd-angle batch:
- map family 2nd angle: `element_at(map, key)` returns-value-or-NULL vs `map[key]` throws-if-absent / `map_concat` left-vs-right override under rephrase / build a map with `map(array_keys, array_values)`.
- array 2nd angle: `contains(array, element)` boolean vs `array_position` index / `array_position` over array-of-rows / element-not-present → 0 (re-confirm NOT NULL under rephrase).
- date 2nd angle: `day_of_week`/`week`/`year` extraction family / `EXTRACT(QUARTER)` vs `quarter()` equivalence re-probe / re-confirm `quarter_of_year()` non-existence holds.
- distinct-count 2nd angle: `approx_distinct` vs exact `COUNT(DISTINCT)` / `COUNT(DISTINCT CAST(ts AS date))` vs `date_trunc('day', ts)` equivalence.

PRESERVE all standing pins: iter843 approx_percentile accuracy + iter842 value-vs-rank + iter840 weighted-avg §3.1B-WA + iter837 string→DATE MySQL-vs-Joda + iter836 lpad/format pad + iter831 month-name grouping + iter827 boolean-aggregate-NULL + iter824/823 split_part/GROUP-BY-alias/repeat-char + trim char-set + default-NULLS-LAST + CAST-rounds-half-up + full iter534–849 lock inventory. NO federation edits (federation row stays 4.49944/310). iter850 is NOT a FIX-A (no defect). DO NOT bump training/state.json (already 850).
