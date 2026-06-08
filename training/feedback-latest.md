# Iter 719 Judge Feedback — 2026-06-08

**Phase**: extended | **Iteration**: 719 | **State**: not bumped (orchestrator handles)
**Verdict**: **PASS (overall 4.500 / 5.0)** — but ONE genuine, findable-but-missing gap surfaced in Q2 that warrants iter720 FIX-A. (Q1 sub-scores all 5 → Q1=20, Q2=12, Q3=20, Q4=20; sub-score-sum 72/16=4.500; per-Q-avg 18.00/4=4.500; dim-avg 4.500 — all three methods agree.)

---

## Per-question scoring

### Q1 — ROW field access (`address.zip`) vs JSON-text fallback
| Dim | Score | Notes |
|---|---|---|
| Accuracy | 5 | Verified vs [trino.io/docs/467/language/types.html](https://trino.io/docs/current/language/types.html) — `row_col.field` dot notation is the documented Trino 467 form for ROW (typed struct) sub-field access. JSON-text vs typed-ROW disambiguator (`json_extract_scalar(col,'$.zip')`) correct. |
| Completeness | 5 | Both shapes covered (typed ROW + JSON text), plus the "promote hot fields to typed columns via `from_json` at ingest" best-practice. |
| Clarity | 5 | One-line worked SQL up front; ROW-vs-JSON branch made explicit; cross-refs to r09/r13 land where the keyword would route. |
| Actionability | 5 | Engineer can copy `address.zip` immediately; knows the alt path if their column is JSON text. |
**Q1 subtotal: 5.00**

### Q2 — Explode a MAP into one row per key/value (CRITICAL — verified)
| Dim | Score | Notes |
|---|---|---|
| Accuracy | 2 | **DIALECT DEFECT.** The responder wrote `CROSS JOIN UNNEST(map_entries(feature_flags)) AS t(flag_entry)` with a SINGLE alias + `flag_entry.key` / `flag_entry.value` dot-access. This is **INVALID Trino 467**. Verified against [trino.io/docs/467/sql/select.html](https://trino.io/docs/current/sql/select.html): when UNNEST is applied to `array(row(K,V))`, Trino FLATTENS the ROW into separate columns — so the alias list must name BOTH columns: `AS t(key_alias, value_alias)`. A single alias produces an alias-count mismatch (1 alias for 2 produced columns) and the `flag_entry.key` dot-access has no ROW to bind to. The CORRECT canonical forms in Trino 467 are EITHER (a) `CROSS JOIN UNNEST(feature_flags) AS t(flag_name, flag_value)` — UNNEST a MAP DIRECTLY expands into two columns (key, value) — OR (b) `CROSS JOIN UNNEST(map_entries(feature_flags)) AS t(flag_name, flag_value)` with TWO aliases (flattened). The single-alias-dot-access form the responder produced does not parse / does not run. |
| Completeness | 4 | The CROSS-JOIN-UNNEST-before-WHERE clause-order note is correct and useful, and the "filter parents first via subquery, then UNNEST" guidance is sound. But the missing canonical (`UNNEST(map) → 2 cols`) leaves the cheaper, simpler form unmentioned. |
| Clarity | 4 | Prose is clear and the explanation of `map_entries → array(row(k,v)) → UNNEST` is well-structured — but the worked SQL is wrong, which undermines the clarity for a copy-paste reader. |
| Actionability | 2 | An engineer who pastes this answer hits a parser error immediately. That is the worst-case actionability outcome — a Haiku-grade answer that LOOKS authoritative but doesn't run. |
**Q2 subtotal: 3.00**

**Is Q2 a findable-but-missing gap?** YES. Grep across `resources/` shows NO `UNNEST a MAP into key/value rows` canonical — r07 §1a covers `CROSS JOIN UNNEST` for ARRAYS only (tags, sequence(...)) and r09 §MAP-HOFs is the OPPOSITE direction (filter/reshape map IN-PLACE without UNNEST). r23 §3.1A is `split_to_map` (string parsing, not map→rows). The responder reached for the closest analog (`map_entries → array(row) → UNNEST`) and got the alias arity wrong because there's no leading canonical anchoring the correct shape. **Candidate FIX-A for iter720:** add a "LEADING CANONICAL — UNNEST a MAP into one row per (key, value)" H4 to r07 §1a (near the array UNNEST canonical), with keyword anchors (`explode map Trino`, `map to rows`, `one row per map entry`, `flatten feature flags map`, `key value rows from map`, `MAP UNNEST two columns`, `UNNEST map_entries flatten`, `map column to long format`), the TWO valid canonical shapes shown explicitly (`UNNEST(feature_flags) AS t(k, v)` PREFERRED + `UNNEST(map_entries(feature_flags)) AS t(k, v)` ALT, both with TWO aliases), and a DO-NOT-WRITE inline-defang row for the single-alias-dot-access form (`AS t(flag_entry)` + `flag_entry.key`) with the verbatim error reason ("alias-count mismatch: UNNEST(array(row(K,V))) flattens into 2 columns, requires 2 aliases").

### Q3 — `uuid()` per row at INSERT + dbt non-determinism warning
| Dim | Score | Notes |
|---|---|---|
| Accuracy | 5 | Verified vs [trino.io/docs/467/functions/uuid.html](https://trino.io/docs/current/functions/uuid.html) — `uuid()` returns "pseudo randomly generated UUID (type 4)" per call, returns `uuid` type, CAST to varchar yields the 36-char canonical string. The non-deterministic-so-not-a-stable-dbt-key warning and the `md5(concat(business_keys))` deterministic alternative are correct and match dbt-utils `generate_surrogate_key` semantics. |
| Completeness | 5 | Covers (a) the canonical INSERT form, (b) the uuid→varchar CAST, (c) the dbt unique_key / surrogate-key trap with the correct fix. Nothing material missing. |
| Clarity | 5 | The "do NOT use as dbt surrogate key" warning is loud and reason-anchored ("non-deterministic, every re-run generates different UUIDs"). |
| Actionability | 5 | Engineer can ship the INSERT today AND knows how to derive a stable hash key when re-runnability matters. |
**Q3 subtotal: 5.00**

### Q4 — Suppress errors in computed columns (`TRY` + `TRY_CAST` + `NULLIF`)
| Dim | Score | Notes |
|---|---|---|
| Accuracy | 5 | Verified vs [trino.io/docs/467/functions/conditional.html](https://trino.io/docs/current/functions/conditional.html) — `try(expression)` documented (catches division-by-zero, invalid casts/function args, numeric overflow → returns NULL), `try_cast(value AS type)` returns NULL on failed cast, `nullif(v1, v2)` documented. Trino's integer/decimal division-by-zero DOES raise an error so the `NULLIF(denom, 0)` guard is necessary. Combining `TRY(numer / NULLIF(denom, 0))` is the documented Trino 467 belt-and-suspenders shape. |
| Completeness | 5 | Both error-suppression mechanisms (TRY, TRY_CAST) covered, NULLIF div-by-zero idiom covered, downstream SUM/COUNT-skip-NULL behavior noted. |
| Clarity | 5 | Two-mechanism split (cast errors → TRY_CAST; everything else → TRY) is the right mental model. |
| Actionability | 5 | Engineer can wrap their broken expression immediately. |
**Q4 subtotal: 5.00**

---

## Overall

| Q | Subtotal |
|---|---|
| Q1 | 5.00 |
| Q2 | 3.00 |
| Q3 | 5.00 |
| Q4 | 5.00 |
| **Sum** | **18.00** |
| **Overall avg (sum / 4)** | **4.5000** |

Sub-score sum across all 16 sub-scores: Q1(5+5+5+5=20) + Q2(2+4+4+2=12) + Q3(5+5+5+5=20) + Q4(5+5+5+5=20) = **72**. Mean: **72/16 = 4.500**. Dim-avg cross-check: Acc(5+2+5+5)/4=4.25 / Comp(5+4+5+5)/4=4.75 / Clar(5+4+5+5)/4=4.75 / Act(5+2+5+5)/4=4.25 = (4.25+4.75+4.75+4.25)/4 = **4.500**. All three methods agree at 4.500.

**PASS threshold:** 3.5. **Verdict: PASS at 4.500 / 5.0.** No per-Q veto under the prompt rules — Q2 flagged in prose as the iter720 FIX-A candidate.

---

## Actionable teacher feedback for iter720

**ONE FIX-A only — no other gaps surfaced.**

**FIX-A — Add LEADING CANONICAL for "UNNEST a MAP into one row per key/value" in r07 §1a (between current array-UNNEST canonical and §1a.1 clause-order rule).**

Required content:
1. **Keyword anchor** (route Haiku here on phrases like): `explode map Trino`, `map to rows`, `one row per map entry`, `flatten feature flags map`, `key value rows from map`, `MAP UNNEST two columns`, `UNNEST map_entries flatten`, `map column to long format`, `expand map to rows`, `per-key per-value rows from map column`, `pivot map long`, `flag→value rows per user`, `feature_flags explode`.
2. **One-fact summary:** Trino 467 `UNNEST(map_col)` applied DIRECTLY to a `MAP(K,V)` expands into TWO columns `(key, value)` — the alias list must name BOTH: `AS t(key_alias, value_alias)`. Verified at [trino.io/docs/467/sql/select.html](https://trino.io/docs/current/sql/select.html) ("Maps are expanded into two columns (key, value)").
3. **Two valid canonicals, both with TWO aliases:**
   - PREFERRED (simpler, no `map_entries` round-trip): `CROSS JOIN UNNEST(feature_flags) AS t(flag_name, flag_value)`.
   - EQUIVALENT ALT (via `map_entries → array(row(K,V))`, where Trino FLATTENS the ROW into separate columns — STILL requires TWO aliases): `CROSS JOIN UNNEST(map_entries(feature_flags)) AS t(flag_name, flag_value)`.
4. **Worked example** with a `user_features (user_id BIGINT, feature_flags MAP(VARCHAR, VARCHAR))` table → `SELECT user_id, flag_name, flag_value FROM user_features CROSS JOIN UNNEST(feature_flags) AS t(flag_name, flag_value)` plus a `GROUP BY flag_name, flag_value COUNT(*)` aggregation example so the engineer sees the end-to-end shape.
5. **DO-NOT-WRITE inline-defang table** (mark un-copyable, the iter693 lesson):
   - `UNNEST(map_entries(m)) AS t(entry) ... entry.key / entry.value` — **WRONG: ALIAS-COUNT MISMATCH.** UNNEST(array(row(K,V))) flattens into 2 columns; 1 alias provided → Trino parse error.
   - `UNNEST(m) AS t(entry)` — **WRONG: same reason.** UNNEST(map) produces 2 columns; needs 2 aliases.
   - `SELECT m.key, m.value FROM users CROSS JOIN UNNEST(m)` — **WRONG: m is the parent column, not the UNNEST output relation.** Must use the `AS t(k, v)` alias names.
6. **Cross-ref** TO `09 §MAP higher-order functions` (when you want to keep the map AS a map, not explode it) and FROM that H3 back to this new canonical (so the navigation works both directions — the iter715 lesson about findability cross-refs).
7. **Closing fact:** the `CROSS JOIN UNNEST(...)` is part of the FROM clause and MUST appear BEFORE `WHERE` (link to existing §1a.1 — do not re-explain).

**Where to place it:** r07 §1a is the natural anchor (it's the existing "explode array column" landing point). New H3/H4 should sit IMMEDIATELY AFTER the array-UNNEST canonical and BEFORE §1a.1 (clause-order rule) so the clause-order rule then applies to BOTH array and map forms.

**Other observations (no action needed):**
- Q1, Q3, Q4 are clean perfects — no edits needed to ROW dot-access (r09), uuid() (r27 §4.5D), or TRY/TRY_CAST/NULLIF (r27 §4.4).
- The dbt-surrogate-key warning landing in Q3 is paying off — that's the iter706 pattern of bundling the "WHY this is wrong for dbt" with the function. Keep that template for the new MAP-UNNEST canonical too.
- No regressions detected in the iter703-718 fix sweep.

Sources:
- [Trino 467 SELECT — UNNEST behavior with MAP and array of ROW](https://trino.io/docs/current/sql/select.html)
- [Trino 467 conditional functions — TRY, TRY_CAST, NULLIF](https://trino.io/docs/current/functions/conditional.html)
- [Trino 467 UUID function](https://trino.io/docs/current/functions/uuid.html)
- [Trino 467 language types — ROW, MAP, dot-access](https://trino.io/docs/current/language/types.html)
