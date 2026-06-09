# Judge Feedback — iter783

**Phase:** extended (final-style; feedback at end of iteration)
**Sweep:** LIGHT ADDITIVE FINDABILITY FIX-A — iter782 Q3 cited `array_intersect` (an ARRAY function) for a row-level INTERSECT; iter783 enhanced r23 §3.1F set-operations card with INTERSECT/EXCEPT anchors + array-vs-row disambiguator. Q1 re-probes the fix; Q2–Q4 fresh.
**Overall: 4.6875 — PASS** (threshold 3.5; overall average governs, no single-Q veto)

All dialect claims verified against trino.io/docs/467 (select.html, functions/aggregate.html, functions/map.html, Iceberg connector metadata tables) on 2026-06-09.

---

## Q1 — Set intersection (products sold in BOTH Jan AND Feb), two queries, no join — RE-PROBE / THE FIX CHECK

`SELECT product_id FROM sales_january INTERSECT SELECT product_id FROM sales_february`. Notes INTERSECT returns DISTINCT rows present in both; cleaner than a JOIN. Cites r23 §3.1F (the enhanced card).

**VERIFIED (select.html):** INTERSECT returns only rows present in the result sets of BOTH queries, DISTINCT by default (INTERSECT ALL available for duplicate-preserving). Exactly right for "products that sold in both months."

**THE FIX WORKED.** The responder **LED with the row-level INTERSECT set operator** and cited the **enhanced r23 §3.1F set-operations card** — it did NOT reach for the `array_intersect(...)` ARRAY function (the iter782 Q3 mis-cite). The array-vs-row disambiguator + INTERSECT/EXCEPT anchors steered the keyword match correctly. This is the **1st clean post-fix datapoint** → set-operations is **CLOSED** (needs 1 more phrasing from a different angle → BULLETPROOFED).

- Accuracy **5** · Completeness **5** · Clarity **5** · Actionability **5** → **avg 5.00**

## Q2 — Group concat (all product names per order into one comma-separated string)

`listagg(product_name, ', ') WITHIN GROUP (ORDER BY product_name) AS product_list ... GROUP BY order_id` → `"Hat, Shoes, Socks"`. Notes `WITHIN GROUP (ORDER BY)` is required; `CAST(id AS varchar)` if the value is numeric (Trino has no implicit number→string). Cites r07 + r27.

**VERIFIED (aggregate.html):** `listagg(expression[, separator])` WITHIN GROUP (ORDER BY ...) is native Trino; separator + WITHIN GROUP usage correct; Trino has **no** `string_agg` (standing listagg pin held). The equally-valid alternative `array_join(array_agg(product_name ORDER BY product_name), ', ')` exists per resources — choosing listagg is NOT penalized; both correct. The CAST-numeric note is sound (no implicit numeric→varchar coercion).

- Accuracy **5** · Completeness **5** · Clarity **5** · Actionability **5** → **avg 5.00**

## Q3 — Map key lookup (pull value for key 'os'/'locale' out of a MAP column to filter/group)

`element_at(metadata, 'os') AS os_value` — returns NULL for a missing key, safer than the bracket subscript `metadata['os']` which errors on a missing key; usable in WHERE and GROUP BY. Cites r09.

**VERIFIED (functions/map.html):** `element_at(map, key)` returns the value or NULL if the key is absent; the subscript `map[key]` **throws an error** when the key is not present. So `element_at` is the safe NULL-returning accessor — exactly right, and usable in WHERE/GROUP BY. Matches the standing element_at-for-map pin.

- Accuracy **5** · Completeness **5** · Clarity **5** · Actionability **5** → **avg 5.00**

## Q4 — Iceberg table file/row count (small-files diagnosis without scanning)

PRIMARY: `SELECT partition, record_count, file_count, total_size/1024/1024 AS total_size_mb FROM iceberg.<cat>.<schema>.<table>"$partitions" ORDER BY file_count DESC`.
SECONDARY: `SELECT snapshot_id, json_extract_scalar(summary, 'total-data-files') AS total_files, json_extract_scalar(summary, 'total-records') AS total_rows FROM ...<table>"$snapshots" ORDER BY committed_at DESC LIMIT 1`. Cites r18.

**PRIMARY ($partitions) — CORRECT.** VERIFIED against the Iceberg connector metadata-tables docs: `$partitions` exposes `partition`, `record_count`, `file_count`, `total_size` (and `data`). `record_count`/`file_count` are the right small-files diagnostic, and ordering by `file_count DESC` to find the worst partitions is exactly the actionable move. This is metadata-only (no data scan) as the question asked. Good answer.

**SECONDARY ($snapshots) — DIALECT DEFECT.** VERIFIED: in Trino's Iceberg `$snapshots` metadata table, the `summary` column is typed **`map(VARCHAR, VARCHAR)`**, NOT a JSON/varchar string. Therefore `json_extract_scalar(summary, 'total-records')` is **WRONG** — `json_extract_scalar` requires a JSON/varchar input, not a map; passing a map type-errors. The correct accessors are the **map subscript** `summary['total-records']` / `summary['total-data-files']` or **`element_at(summary, 'total-records')`**. (Ironic: Q3 in this very sweep was exactly about `element_at` for maps — the same tool applies here.)

**Resource vs responder — this is a RESPONDER SLIP, resources are CLEAN.** r18 (`18-query-performance-regression.md`, "Diagnose small files", lines 1097–1112) shows the CORRECT form `summary['total-data-files']` / `summary['total-records']` and even annotates *"file/row counts live INSIDE the summary map (a map(varchar, varchar)) — NOT as top-level columns."* r17 (lines 1021, 1209–1211, 2913–2917) and r26 (239–240, 376) likewise use `summary['...']` / `element_at(summary, ...)`. **No resource shows `json_extract_scalar` applied to `summary`.** The responder imported the json_extract_scalar pattern (correct for `readable_metrics` JSON, per r10/r17/r18) onto a map column — a mis-pick at answer time, not a resource defect.

Scored down on Accuracy for the secondary; PRIMARY correctness and the metadata-only framing hold up Completeness/Clarity/Actionability.

- Accuracy **3** · Completeness **4** · Clarity **4** · Actionability **4** → **avg 3.75**

---

## Verdicts (explicit)

**(a) Set-operations CLOSED?** **YES — CLOSED (1st clean post-fix datapoint).** Q1 fix worked: responder LED with the row-level INTERSECT operator + cited the enhanced r23 §3.1F card, did NOT reach for `array_intersect`. The iter782 array-vs-row mis-cite did not recur. One more phrasing from a different angle (e.g., EXCEPT / "products in Jan but NOT Feb", or UNION-vs-UNION-ALL) → BULLETPROOFED.

**(b) Q4 $snapshots-summary verdict.** PRIMARY `$partitions` (record_count/file_count/total_size, ORDER BY file_count) is **CORRECT** and the right small-files diagnostic. SECONDARY `$snapshots` is a **DEFECT**: `summary` is `map(VARCHAR, VARCHAR)`, so `json_extract_scalar(summary, 'total-records')` is invalid (json_extract_scalar takes JSON/varchar, not a map). **Correct form: `element_at(summary, 'total-records')` or `summary['total-records']`** (likewise `summary['total-data-files']`). The defect is a **responder slip** — r18 (and r17/r26) already show the correct map-subscript form; resources are clean.

**(c) iter784 designation — DEFAULT NO-OP / durability-breadth (NOT FIX-A).** The Q4 $snapshots json_extract_scalar-on-map does NOT trace to a resource defect — r18 §"Diagnose small files" is correct and even warns summary is a map. Since the slip is responder-side and resources are clean, no edit is warranted (a FIX-A here risks churning a verified-correct card). Teacher: **ZERO edits**.

### iter784 probe suggestions
- **Set-operations 2nd angle (to bulletproof):** EXCEPT phrasing — "products sold in Jan but NOT in Feb" (`... EXCEPT ...`), or UNION-vs-UNION-ALL dedup framing — confirm the responder still picks row-level set ops over array functions.
- **Re-probe Q4 $snapshots map access from a different phrasing** (e.g., "how many rows did the last commit add" → `summary['added-records']`) to confirm whether the json_extract_scalar-on-map slip recurs. If it recurs across 2+ phrasings, RE-DESIGNATE as a light FIX-A: add an inline anchor at the r18 $snapshots card explicitly flagging *"summary is a map — use `summary['key']` / `element_at(summary,'key')`, NOT `json_extract_scalar` (that's for JSON/varchar like `readable_metrics`)"* as a disambiguator. For now it's a single slip → no edit.
- Fresh adjacent: `$manifests` column-form file counts (added/existing/deleted_data_files_count) vs `$snapshots.summary` map access (the r18 contrast); `$files` per-file size distribution.

**PRESERVE (verified clean, churn risk):** r23 §3.1F enhanced set-operations card (load-bearing — drove the Q1 fix), r07/r27 listagg + array_join group-concat, r09 element_at-for-map, r18 $partitions/$snapshots small-files cards.
