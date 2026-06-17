# Judge Feedback — iter999 (EXTENDED PHASE breadth sweep / re-probe of iter998)

**OVERALL 4.6172 — STRONG PASS** (margin +1.117). OVERALL AVERAGE governs; no per-Q veto.

| Q | Topic | Acc | Clar | App | Comp | Q-avg |
|---|---|---|---|---|---|---|
| 1 | Collapse internal multiple spaces → single (regexp_replace) | 3.5 | 3.75 | 4.25 | 4.5 | **4.0** |
| 2 | Pull "seats" from metadata JSON as NUMBER + SUM | 5.0 | 4.75 | 4.75 | 4.75 | **4.8125** |
| 3 | `WHERE refund_amount != NULL` returns zero rows | 5.0 | 4.875 | 4.75 | 4.75 | **4.84375** |
| 4 | "this month so far" auto-updating filter | 5.0 | 4.75 | 4.875 | 4.625 | **4.8125** |

Sum 18.46875 / 4 = **4.6172**.

Verified BOTH directions vs trino.io/docs/467 + RAW git-tag 467 source (NOT against resources/):
- RAW git-tag `regexp.md` (raw.githubusercontent.com/trinodb/trino/467/...) shows SINGLE-backslash examples `'\d+[ab] '`, `'(\d+)([ab]) '`, `'(\w)(\w*)'` — confirms single-backslash is the engine-level canonical; rendered-HTML doubling is the Sphinx artifact.
- functions/json.html: `json_extract_scalar(json, json_path) → varchar` ("returns the result value as a string").
- functions/comparison.html: "any comparison involving a `NULL` will produce `NULL`"; IS NULL / IS NOT NULL "treat NULL as a known value … guarantee either a true or false outcome."
- functions/datetime.html: `date_trunc(unit, x) → [same as input]`; `current_date` = current date as of query start.

Prod stack (Trino 467 Iceberg + Hive Metastore on-prem MinIO + Spark ingestion + dbt) — all 4 fit; NO federation drag-in; no auth/permission angle.

---

## Per-question scope notes

### ★ Q1 (KEY) — SQL CORRECT, PROSE DOUBLE-BACKSLASH CLAIM WRONG — **2nd CONSECUTIVE** (2-in-2)
- Deliverable SQL `regexp_replace(product_name, '\s+', ' ')` is CORRECT: 3-arg regexp_replace valid; SINGLE-backslash `'\s+'` is the canonical Trino 467 form (raw git-tag verified). Trino does NOT escape backslash in `'...'` literals, so `'\s'` reaches the engine as the Java whitespace class and WORKS; `'\\s+'` would reach the engine as literal-backslash+s and be BROKEN. `'\s+'`→single space collapses "Starter  Plan"→"Starter Plan" correctly. (Minor completeness: did not pair with trim() for edge spaces, but the question is specifically about INTERNAL spaces, and `\s+` would also collapse edge runs — immaterial.)
- ★★ PROSE DEFECT: the explanatory note "Trino regex strings use DOUBLE backslashes (`'\s+'` not `'\s'`) per the official Trino regexp documentation" is WRONG and internally garbled (it even contradicts its own correct single-backslash SQL). A user who FOLLOWED the prose and wrote `'\\s+'` would BREAK the query. This is the **SAME wrong prose claim as iter998 Q1 → 2nd CONSECUTIVE (2-in-2), same direction** (SQL single = correct both times; explanatory prose double = wrong both times).
- CLASSIFY: regex-backslash tic, PROSE direction. The wrong claim does not appear in resources (resources canonicalize single-backslash / backslash-free char-classes per iter991; r23 uses `[0-9]{8}`), so this is a RESPONDER recall slip pulled from external rendered-doc memory, NOT a wrong-content resource defect.
- ★ ORCHESTRATOR (PHASE 6) DISPOSITION: I (judge) have verified the FACT (single-backslash correct, double wrong). The orchestrator must GREP resources/ to decide the 2-in-2 disposition:
  - If correct single-backslash guidance is NOT findable from the regexp_replace context → **findability gap**; candidate **LIGHT additive co-located note** near the regexp keywords: "single-quoted string literals do not escape backslash; `'\s'`/`'\d'` reach the regex engine as-is — do NOT double them to `'\\s'`/`'\\d'`, which would break the pattern."
  - If correct guidance IS findable but the responder misreads it / pulls double-backslash from external rendered-doc memory → **responder recall ceiling**, no resource fix (accept the per-Q prose cost).
- Acc dinged to 3.5 for the wrong load-bearing prose (SQL correct so App/Comp held up).

### Q2 — json + CAST + SUM — CLEAN
`SUM(CAST(json_extract_scalar(metadata, '$.seats') AS INTEGER))` VERIFIED: json_extract_scalar→varchar, CAST to INTEGER for arithmetic, SUM ignores NULL; missing-key/malformed → NULL (correctly ignored). No fabricated function. Could have mentioned `JSON_VALUE(... RETURNING INTEGER)` as an alternative (not required). CLEAN.

### Q3 — IS NOT NULL (3VL) — CLEAN
Diagnosis CORRECT: `!= NULL` / `= NULL` always evaluate to NULL/UNKNOWN under 3-valued logic; WHERE keeps only TRUE, so UNKNOWN rows are dropped → zero rows (matches symptom). Fix `WHERE refund_amount IS NOT NULL` CORRECT (IS NOT NULL always returns boolean). CLEAN.

### Q4 — date_trunc month-to-date auto-update — CLEAN; #7334 NOT recurring
Recommended `WHERE recorded_at >= date_trunc('month', current_date)` VERIFIED CORRECT: date_trunc('month', current_date) = first-of-month, `>=` captures month-to-date, auto-updates on rollover. date_trunc-on-column variant `date_trunc('month', recorded_at) = date_trunc('month', current_date)` also correct (sargable via UnwrapDateTruncInComparison). `date_add('month', 0, ...)` is a redundant-but-valid alternative (harmless no-op wrapper, not broken). Prose `DATE '2026-06-01'` uses the DATE keyword literal (typed), so **#7334 bare-varchar-vs-TIMESTAMP TYPE_MISMATCH is SIDESTEPPED — NOT recurring**: the recommended form uses date_trunc/typed literals, no bare varchar against a TIMESTAMP column. CLEAN.

---

## Tic scan
CLEAN except Q1 regex-backslash PROSE slip (now 2-in-2). No QUALIFY / no false-mechanism semi-join mislabel / no MAX(varchar) / no percent_rank inversion / no fabricated functions (regexp_replace / json_extract_scalar / date_trunc / date_add all real & verified) / no GREATEST-LEAST-NULL / no temporal-vs-varchar-literal trap (Q4 sidestepped via date_trunc + DATE keyword) / no broken-secondary (Q4 date_add('month',0,...) redundant but valid, not broken) / no mid-churn / no column-scope / no ILIKE-conflation / no INTERVAL-quarter-week.

## Recommendation
**DEFAULT NO-OP on resources by the judge** (margin +1.117; all 4 deliverable SQL/diagnoses correct & verified both directions). The SINGLE actionable item is the **Q1 regex-backslash prose claim, now 2nd CONSECUTIVE (2-in-2, same direction)** — this crosses the 2-in-2 threshold and REQUIRES the orchestrator to GREP resources/ in PHASE 6 to disambiguate findability-gap (→ LIGHT additive defang note) vs responder recall-ceiling (→ no fix). Do NOT churn the deliverable SQL — it is correct.

Federation r22 §13.x hard-locked — NOT probed (OVERRIDDEN). MUST NOT bump training/state.json (already 999; passed=true; final_iterations_remaining 0).
