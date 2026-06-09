# Judge Feedback — iter816 (EXTENDED PHASE)

## Headline

**ALL 4 QUESTIONS DECLINED by the responder — but ALL 4 answers PROVABLY EXIST in `resources/`, docs-correct for Trino 467.** This is a **RESPONDER RETRIEVAL SLIP across the board**, NOT a content gap. iter816 made ZERO resource edits (DEFAULT NO-OP), and Q1+Q2 were answered CLEANLY at iter815 (Q1=5.00, Q2=4.875) from the very same files/lines — so the content is provably still present and was retrievable. The decline is a findability/retrieval failure in the responder, not a resource defect.

An honest decline on covered-and-retrievable content scores LOW (the content exists, was just answered last iteration, and the keyword anchors are in place). All four questions score 1.00.

## Per-question scores

| Q | Topic | Acc | Comp | Clar | Act | Avg |
|---|---|---|---|---|---|---|
| Q1 | round timestamp to NEAREST 15-min | 1 | 1 | 1 | 1 | 1.00 |
| Q2 | array slice + null-pad to fixed width | 1 | 1 | 1 | 1 | 1.00 |
| Q3 | safe MAP lookup with fallback default | 1 | 1 | 1 | 1 | 1.00 |
| Q4 | safe numeric cast (TRY_CAST / try) | 1 | 1 | 1 | 1 | 1.00 |

**Overall avg = 4.00/4 = 1.00 → FAIL** (threshold 3.5). A blanket decline on fully-covered content is a hard fail regardless of root cause.

## Findability verdicts (per question)

### Q1 — round to NEAREST 15-min: CONTENT EXISTS (responder slip)
- **Location:** `resources/07-analytical-query-patterns.md:1909` — "LEADING CANONICAL — round a timestamp to the NEAREST N minutes" (iter814 PIN), with copy-attractive block at `r07:1918`: `from_unixtime(round(to_unixtime(reading_time) / 300) * 300)` and inline note `nearest 15 min -> /900*900`. FLOOR/NEAREST/CEILING router at `r07:1922-1928`. Keyword anchors at `r07:1911` include "round to the nearest 5/15/30 minutes", "snap a timestamp to the closest mark".
- **Docs-correct Trino 467 form:** `from_unixtime(round(to_unixtime(ts) / 900) * 900)` (nearest 15 min = 900 s). Verified: `to_unixtime`/`from_unixtime` exist; `round(x)` rounds to nearest integer; casting timestamp to lower precision rounds (not truncates). The resource form matches exactly.
- The responder SAID it found `date_trunc` "but no canonical for nearest-N-min" — false; the nearest-N-min LEADING CANONICAL is right there with explicit `/900*900` for 15-min. Retrieval slip.

### Q2 — array slice + null-pad: CONTENT EXISTS (responder slip)
- **Location:** `resources/07-analytical-query-patterns.md:738-747` — "Worked example #4 — first N elements, PADDED with NULLs". Copy-attractive block at `r07:741`: `slice(concat(tags, ARRAY[NULL, NULL, NULL, NULL, NULL]), 1, 5)` plus the `||` operator variant and the `array_concat` defang. (Added iter815; matches the run-prompt's expected line.)
- **Docs-correct Trino 467 form:** `slice(concat(arr, ARRAY[NULL,NULL,NULL,NULL]), 1, 4)` — pad-then-slice (slice is 1-based; concat()/|| concatenate arrays; no `array_concat`). Resource form is correct; just adjust the pad count to 4 for this question.
- The responder said it found `element_at` and `array_*` "but no pad-to-fixed-width canonical" — false; Worked example #4 IS exactly that. Retrieval slip.

### Q3 — safe MAP lookup with fallback default: CONTENT EXISTS (responder slip)
- **Location:** `resources/09-lakehouse-schema-design.md:707` — H3 "`COALESCE(element_at(map_col, key), <default>)` — MAP lookup with a fallback value when the key is missing". Worked example at `r09:715-720`: `COALESCE(element_at(settings, 'theme'), 'default_theme')`. Keyword anchors at `r09:709` include "map lookup with default", "fall back when key missing", "return default when key not in map". Also reinforced at `r07:210/213` (element_at NULL-safe) and `r09:711` (no 3-arg overload — compose with COALESCE).
- **Docs-correct Trino 467 form:** `COALESCE(element_at(metadata, 'campaign_id'), 'default')`. Verified: `element_at(map, key)` returns NULL on a missing key (does NOT error — the `[]` subscript errors, `element_at` is the NULL-safe accessor); `COALESCE` returns first non-NULL. Resource form is correct.
- The responder said it found `element_at(map,key)` returns null "but no fallback-default canonical" — false; the COALESCE-element_at canonical with full keyword anchors is exactly that. Retrieval slip.

### Q4 — safe numeric cast: CONTENT EXISTS (responder slip)
- **Location:** `resources/27-oracle-plsql-to-dbt-trino.md:1402` (TRY_CAST returns NULL on failure / "bad input becomes NULL instead of failing the query"); `r27:1426` (`TRY_CAST(col AS BIGINT)` for "bad rows should become NULL"); `r27:1513` (`TRY_CAST(order_total AS DECIMAL(18,2))` — "bad rows become NULL instead of failing the query"); `r27:1522` §4.4E full `try(expression)` CANONICAL. Also `resources/23-sql-best-practices-olap.md:837` (`TRY_CAST(col AS BIGINT)` if a bad row should become NULL).
- **Docs-correct Trino 467 form:** `TRY_CAST(raw_amount AS DECIMAL(18,2))` returns NULL on parse failure (vs `CAST` which errors). Verified at conversion.html: "TRY_CAST(value AS type) — like cast(), but returns null if the cast fails." Resource form is correct.
- The responder said it found CAST "but no try_cast/safe_cast canonical" — false; TRY_CAST appears in BOTH r27 and r23 with the exact "bad rows become NULL instead of failing the query" framing the question asks for. Retrieval slip.

## Root-cause classification (for iter817)

- **(a) Covered + responder slipped (ALL FOUR):** Q1 (r07:1909), Q2 (r07:738), Q3 (r09:707), Q4 (r27:1402/§4.4E + r23:837). Content is present, docs-correct, and (for Q1/Q2) was successfully retrieved and answered at iter815. **The resources are SOUND. This is a pure responder retrieval failure across all four.**
- **(b) Genuinely absent:** NONE. No real content gap this iteration.

## iter817 directive

**This is NOT a FIX-A content emergency.** The resources are correct and complete for all four topics. Do the following:

1. **RE-PROBE all four topics** (Q1 nearest-N-min, Q2 array pad-then-slice, Q3 map-lookup-with-default, Q4 TRY_CAST/try) to confirm the content is findable again. A single blanket-decline iteration immediately after a clean iter815 strongly suggests a transient responder retrieval failure (e.g., the responder failed to actually search resources/ this cycle, or short-circuited to a global decline). Confirm it does not recur.
2. **DO NOT churn** the four canonical cards — they are docs-verified and copy-attractive. Editing them risks regressing content that just scored 5.00/4.875.
3. **OPTIONAL light anchor reinforcement ONLY IF** a re-probe shows a specific keyword still under-routing:
   - Q3: the question phrasing "Map column of arbitrary key-value metadata… fallback DEFAULT value… safe key lookup with fallback" — confirm the `r09:709` anchor list covers "metadata", "campaign_id-style key", "safe key lookup with fallback". If "safe key lookup" / "metadata map" are weak routes, add those two phrases to the `r09:709` anchor line (no structural change).
   - Q4: confirm "raw_amount text junk n/a blank cast to numeric" routes to TRY_CAST. If the dominant landing for "cast text to numeric, null on bad value" is weak, ensure a TRY_CAST(... AS DECIMAL) copy-attractive line sits at the keyword landing in r23 (the cast-fix landing), not only inside the Postgres-`::`-migration framing of r27.
4. **If the re-probe answers all four cleanly, this confirms iter816 was a transient responder slip — note it and return to DEFAULT NO-OP / durability-breadth.** Do NOT treat a one-off blanket decline as a resource defect.

HOLD all iter534-815 locks. DO NOT bump training/state.json (already 816).
