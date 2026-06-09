# iter815 Judge Feedback — FIX-A verification (round-to-NEAREST-N-min + array pad-then-slice)

**Verification basis:** all 4 dialect claims checked against trino.io/docs/467 (datetime / array / window) via WebFetch + WebSearch on 2026-06-09. PIN: Trino 467.

## Per-question scores

### Q1 — round timestamp to NEAREST 5-min mark (10:02→10:00, 10:03→10:05)
RESPONDER: `from_unixtime(round(to_unixtime(reading_time)/300)*300)` + N=900/1800 scaling + full GROUP BY.
- **Accuracy 5** — VERIFIED. `to_unixtime`→double epoch seconds, `/300`, `round()` is half-up = nearest (NOT floor), `*300`, `from_unixtime`→timestamp. Genuinely rounds to NEAREST: 10:02 (epoch%300=120s) → round(.4)→down→10:00; 10:03 (180s) → round(.6)→up→10:05. Matches engineer's explicit "nearest mark not floor" requirement exactly.
- **Completeness 5** — gives the 5-min canonical, the N-scaling rule (900=15min, 1800=30min), AND the full GROUP BY/ORDER BY for the dashboard use case.
- **Clarity 5** — step-by-step epoch walkthrough, concrete 10:02/10:03 trace.
- **Actionability 5** — copy-paste-ready, engineer knows exactly what to run.
- **Per-Q avg: 5.00**
- **FIX LANDED — round-to-NEAREST-N-min FINALLY CLOSED (1st post-fix clean datapoint).** Responder LED with the `round()` epoch form and did NOT regress to either iter814 defanged form (`date_trunc('hour',ts+INTERVAL '30' MINUTE)` = nearest-HOUR-only, or the `%30`-EXTRACT form = FLOOR-only). 4th-touch fix worked.

### Q2 — slice + NULL-pad to exactly first 3
RESPONDER: `slice(concat(recent_actions, ARRAY[NULL,NULL,NULL]),1,3)`.
- **Accuracy 5** — VERIFIED. `concat()` accepts multiple arrays (array.html "Concatenates the arrays array1, array2, …, arrayN"); `slice(x,start,length)` is 1-based; `array_concat` correctly NOT used (does not exist in Trino 467 — confirmed array.html + WebSearch). Explicitly told the engineer "slice() NOT array_slice".
- **Completeness 4.5** — semantics correct (≥3 elements → first 3 via slice; <3 → NULL pad fills). Minor: did not flag the NULL-typing caveat (`ARRAY[NULL,NULL,NULL]` is `array(unknown)` and may need a CAST in strict-typing contexts); pad-3 guarantees ≥3 only because source max is 10 — fine here.
- **Clarity 5** — clear "concatenate NULLs first then slice" framing + worked 2-item example.
- **Actionability 5** — drop-in for the fixed-width CSV export.
- **Per-Q avg: 4.875**
- **FIX LANDED — array_concat fabrication closed (1st post-fix clean datapoint).** Used `concat` correctly, named the array_concat trap.

### Q3 — access field in array-of-ROW structs
RESPONDER: `UNNEST(properties) AS t(elem)` + `elem.value` dot-notation + `WHERE elem.key=...`; one-row alt `element_at(array_agg(elem.value) FILTER (WHERE elem.key=...),1)`.
- **Accuracy 5** — VERIFIED. ROW fields accessed by dot/field-name notation; `element_at` is for MAP/ARRAY subscripts (responder states this correctly). UNNEST of ARRAY(ROW) into `t(elem)` then `elem.value`/`elem.key` is docs-correct. `array_agg(...) FILTER` + `element_at(...,1)` one-row extraction is valid.
- **Completeness 5** — gives both explode-to-rows and one-row-per-event forms.
- **Clarity 5** — declares the assumed schema, explains dot vs element_at distinction.
- **Actionability 5** — both patterns runnable.
- **Per-Q avg: 5.00**

### Q4 — LAG with default for first row (no COALESCE)
RESPONDER: `LAG(metric_value, 1, 0) OVER (PARTITION BY user_id ORDER BY event_date)` + change expression.
- **Accuracy 5** — VERIFIED. `lag(x[, offset[, default_value]])` — third arg returned when offset row is outside the partition (window.html). First row → returns 0 → change = value − 0.
- **Completeness 5** — full signature explained + the change-from-prior derivation.
- **Clarity 5** — explicitly addresses "no COALESCE after the fact".
- **Actionability 5** — copy-paste-ready window query.
- **Per-Q avg: 5.00**

## Overall
| Q | Acc | Comp | Clar | Act | Avg |
|---|---|---|---|---|---|
| Q1 | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | 5 | 4.5 | 5 | 5 | 4.875 |
| Q3 | 5 | 5 | 5 | 5 | 5.00 |
| Q4 | 5 | 5 | 5 | 5 | 5.00 |

**OVERALL AVG = 4.969 → PASS** (threshold 3.5; overall average governs, no per-Q veto).

## Fix-landing verdict
- **Q1 round-to-NEAREST-N-min: FINALLY LANDED / CLOSED** (4th touch). Responder led with `round(to_unixtime/N)*N`, no date_trunc regression. Needs 1 more phrasing angle (e.g. nearest-15-min, or "snap to nearest") to fully BULLETPROOF.
- **Q2 array_concat: FIXED / LANDED.** Used `concat` + named array_concat as nonexistent. Needs 1 more angle (pad-to-N with N≠source-max, or NULL-CAST caveat) to BULLETPROOF.

## iter816 directive
**DEFAULT NO-OP / durability-breadth sweep** — no open defect this iteration. Teacher makes ZERO edits.
- Re-probe round-to-NEAREST 2nd angle (nearest-15-min "snap" phrasing) + pad-then-slice 2nd angle (pad to N≠source-max, or surface the `ARRAY[NULL...]` unknown-type CAST caveat) to convert both fresh fixes from LANDED→BULLETPROOFED.
- PRESERVE: r07 timestamp-rounding FLOOR/NEAREST/CEILING router + both defangs; r07 pad-then-slice canonical + array_concat defang; UNNEST(ARRAY(ROW)) dot-notation + array_agg-FILTER surfaces; lag 3-arg-default.
- 2 fresh adjacent topics of teacher's choice. NO federation edits.
- DO NOT bump training/state.json (already 815).
