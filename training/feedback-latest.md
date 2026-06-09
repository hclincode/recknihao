# Judge Feedback — iter873 (EXTENDED PHASE)

## Verdict: 5.00 STRONG PASS overall (per-Q 5.00/5.00/5.00/5.00 = 20.00/4 = 5.00; margin +1.50)

Overall average governs; no per-Q veto. DEFAULT NO-OP durability sweep — all 4 answers dialect-clean and textbook-correct, verified against trino.io/docs/467. Teacher should make ZERO resource edits this iteration.

Federation NOT probed this iteration — the 4.49944/310 FAIL row is UNCHANGED.

---

## Per-question scoring

### Q1 — Random ~10k-row sample from a 500M-row event table (TABLESAMPLE) — 5.00
Acc 5 / Comp 5 / Clar 5 / Act 5

Responder's SYSTEM-vs-BERNOULLI characterization is fully correct.

VERIFIED vs trino.io/docs/467 sql/select.html (TABLESAMPLE clause):
- **BERNOULLI**: "Selects each row independently with the specified probability." All physical blocks are scanned and rows are skipped via per-row random comparison. Row-level, uniform, does NOT reduce disk I/O (full scan). MATCHES responder.
- **SYSTEM**: divides the table into logical segments and "either selects all the rows from a particular segment of data or skips it." Coarser granularity, connector-dependent, faster, less uniform. MATCHES responder ("skips whole file segments/splits", "reads less from disk", "chunks grouped, fast").
- **Argument is a PERCENTAGE**: docs example `TABLESAMPLE BERNOULLI (50)` / `SYSTEM (75)`. MATCHES responder ("n is a PERCENTAGE").
- Neither guarantees a deterministic row count — responder's `TABLESAMPLE SYSTEM (1) LIMIT 10000` (sample ~1% then cap at 10k) is the right practical idiom for "grab ~10k quickly for exploration", and the BERNOULLI(5)+partition-filter example is valid.

No defect. The fast-but-less-uniform (SYSTEM) vs uniform-but-full-scan (BERNOULLI) trade-off is exactly right for the exploration use case.

### Q2 — Deduplicate elements inside a single array column value — 5.00
Acc 5 / Comp 5 / Clar 5 / Act 5

VERIFIED vs trino.io/docs/467 functions/array.html:
- `array_distinct(x) -> array` — "Remove duplicate values from the array x." MATCHES responder. (Docs phrase it "remove duplicate values"; responder's "keeping first occurrence" is the observed stable behavior and not misleading.)
- `cardinality(x) -> bigint` — "Returns the cardinality (size) of the array x." So `cardinality(array_distinct(tags))` = distinct element count. MATCHES responder.

`['discount','discount','promo'] -> array_distinct -> ['discount','promo']` is correct. No defect.

### Q3 — Each status change alongside the NEXT change per ticket (LEAD) — 5.00
Acc 5 / Comp 5 / Clar 5 / Act 5

VERIFIED vs trino.io/docs/467 functions/window.html:
- `lead(x[, offset[, default_value]])` — "returns the value at offset rows after the current row in the window partition"; default offset 1; "if the offset refers to a row that is not within the partition, the default_value is returned, or if it is not specified null is returned." So the last row per partition yields NULL. MATCHES responder.
- `LEAD(current_status) OVER (PARTITION BY ticket_id ORDER BY changed_at) AS next_status` is the correct transition-pairing form; the noted NULL-at-partition-end and ORDER-BY requirement are both accurate.
- The transition-count aggregation (`GROUP BY current_status, next_status WHERE next_status IS NOT NULL`) correctly drops the terminal NULL rows. Solid completeness.

No defect.

### Q4 — Percentage of NULLs in a column for a data-quality report — 5.00
Acc 5 / Comp 5 / Clar 5 / Act 5

VERIFIED vs trino.io/docs/467 functions/aggregate.html:
- FILTER clause is "supported for all aggregate functions": `aggregate_function(...) FILTER (WHERE <condition>)`. So `COUNT(*) FILTER (WHERE company_name IS NULL)` is valid. MATCHES responder.
- `count(*)` = "the number of input rows"; `count(x)` = "the number of non-null input values" — confirms the alternative `100.0*(COUNT(*)-COUNT(col))/COUNT(*)` the responder did not need to mention.
- `100.0 *` is a DECIMAL/double literal that promotes the multiplication, so the subsequent `/ COUNT(*)` is non-integer division (no integer truncation). The formula yields the NULL percentage correctly; `ROUND(.., 2)` formats to 2 dp. MATCHES responder.
- The multi-column UNION ALL variant is a valid one-report-many-columns shape; explaining FILTER as a filtered aggregate "avoiding CASE" is accurate (CASE-sum and AVG(CASE..) are equivalent alternatives — completeness nuance only, not a gap).

No defect.

---

## iter874 recommendation: DEFAULT NO-OP

All four answers are dialect-clean, fully accurate, and complete. NO defect surfaced; NO FIX-A; NO escalation. Teacher should make ZERO resource edits.

- Do NOT add any "TABLESAMPLE wrong" / "array_distinct wrong" / "LEAD wrong" / "FILTER wrong" card — every form the responder gave is correct.
- Optional fresh adjacents for future probes (do NOT write content preemptively): TABLESAMPLE determinism / repeatable sampling; `TABLESAMPLE SYSTEM` vs `LIMIT`-only sampling skew; `array_distinct` ordering vs `array_sort`; multi-element dedup with `array_intersect`/`array_union`; `LAG()` (previous row) as the mirror of `LEAD()`; `LEAD(x, 2)` offset/default_value; `COUNT(*) FILTER` vs `count_if` for null-rate; per-group null-rate with `GROUP BY`.
- HOLD all iter534-872 locks. Do NOT re-touch the iter872-corrected DATE-coercion cards (r07 weekday TRUTH3, r23 format-vs-format_datetime, r27 §4.2A) — clean and untested this iter.
- PIN Trino 467. NO federation edits (r22 §13.x ZERO; federation row stays 4.49944/310, still FAIL).
- DO NOT bump training/state.json (already 873/passed).

All facts VERIFIED vs trino.io/docs/467 (sql/select.html TABLESAMPLE, functions/array.html, functions/window.html, functions/aggregate.html) via WebFetch 2026-06-10.
