# Judge Feedback — iter1002

**Phase:** extended (passed=true preserved). OVERALL AVERAGE governs — no per-Q veto.
**Prod stack:** Trino 467 Iceberg + Hive Metastore on-prem MinIO + Spark ingestion + dbt — all 4 Qs fit; no federation drag-in; no auth angle.
**Verification:** Both directions vs trino.io/docs/467 + RAW git-tag 467 source — NOT against resources/.

## Source verifications (this iter)

- **json_extract_scalar (RAW git-tag 467 functions/json.md):** signature `json_extract_scalar(json, json_path) -> varchar`; returns the scalar value AS A STRING; JSON path `$.key` object-member access AND `$[index]` array access both documented (example `$.store.book[0].author`). Q1 `json_extract_scalar(properties,'$.plan')`→varchar + `CAST(... AS BIGINT)` for the numeric `seats` = CORRECT.
- **UNNEST join syntax (RAW git-tag 467 sql/select.md):** documented example `CROSS JOIN UNNEST(scores) AS t(score)` — exactly the `AS t(tag)` alias form the responder used. LEFT JOIN form: "in case of using LEFT JOIN the only condition supported by the current implementation is ON TRUE" — responder's `LEFT JOIN UNNEST(tags) AS t(tag) ON TRUE` is the documented and only-supported LEFT form. Q3 = CORRECT both forms.
- **ROW_NUMBER dedup:** PARTITION BY account_id ORDER BY updated_at DESC, filter rn=1 in outer query = canonical Trino dedup; NO QUALIFY in 467, correctly nested in a CTE. RANK()/tiebreak notes accurate. Q2 = CORRECT.
- **SUM() OVER () empty window:** empty OVER () = single partition over all result rows → grand total broadcast onto each row = CORRECT (classic ratio-to-total without self-join). `100.0` non-scientific = DECIMAL literal → avoids integer-division truncation = CORRECT. `NULLIF(SUM(...) OVER (),0)` divide-by-zero guard = CORRECT. PARTITION BY month variant correct. Q4 = CORRECT.

## Per-question scores (Accuracy / Completeness / Clarity / Actionability)

### Q1 — extract plan + seats from JSON string, GROUP BY them
- Accuracy 5.0 / Completeness 4.75 / Clarity 4.75 / Actionability 4.75 → **4.8125**
- json_extract_scalar→varchar + CAST seats to BIGINT correct; repeating the extraction expressions character-identically in GROUP BY is the right Trino approach (aliases not resolvable in GROUP BY). Two-tier "promote hot JSON keys to top-level Iceberg columns" note is genuinely useful prod guidance, not padding.

### Q2 — keep most recent row per account_id (dedup a status-change log)
- Accuracy 5.0 / Completeness 4.75 / Clarity 4.75 / Actionability 4.75 → **4.8125**
- Canonical ROW_NUMBER() PARTITION/ORDER DESC + rn=1; correctly nested in CTE (no QUALIFY in 467). Tiebreak-on-identical-timestamp note + RANK() ties-share-rank contrast both accurate and on-point.

### Q3 — explode array tags, count per individual tag
- Accuracy 5.0 / Completeness 4.875 / Clarity 4.75 / Actionability 4.75 → **4.84375**
- CROSS JOIN UNNEST(tags) AS t(tag) matches doc form exactly; LEFT JOIN ... ON TRUE to preserve NULL/empty-array rows is the documented-correct (and only-supported) LEFT form. Note that UNNEST is in FROM and precedes WHERE is accurate and helps the beginner reason about filtering.

### Q4 — each customer's % of monthly total in one query, no self-join
- Accuracy 5.0 / Completeness 4.75 / Clarity 4.75 / Actionability 4.875 → **4.84375**
- SUM() OVER () grand total + 100.0 decimal literal (avoids int truncation) + ROUND 2dp; NULLIF divide-by-zero guard and PARTITION BY month variant are exactly the right defensive additions. Half-open month range `>= DATE '2026-06-01' AND < DATE '2026-07-01'` uses typed DATE literals (no bare-varchar TYPE_MISMATCH trap).

## Overall

(4.8125 + 4.8125 + 4.84375 + 4.84375) / 4 = **4.8281** → **STRONG PASS** (margin +1.328)

16 sub-scores: 5.0/4.75/4.75/4.75 + 5.0/4.75/4.75/4.75 + 5.0/4.875/4.75/4.75 + 5.0/4.75/4.75/4.875.

## Tics — ALL CLEAN
No QUALIFY (Q2 correctly nests in CTE) / no fabricated-fn-or-syntax (json_extract_scalar, UNNEST alias `t(tag)`, LEFT JOIN UNNEST ON TRUE, ROW_NUMBER, SUM OVER (), NULLIF ALL real & verified) / no broken-secondary (all secondary notes — RANK tiebreak, LEFT JOIN ON TRUE, PARTITION BY month, NULLIF guard — are CORRECT, not the usual Haiku broken-padding) / no int-division-truncation slip (Q4 100.0 DECIMAL literal correct) / no regex-backslash (no regex Q) / no GREATEST-LEAST-NULL / no date-minus-integer / no ILIKE-conflation / no INTERVAL-quarter-week / no MAX-varchar / no semi-join-mislabel / no column-scope.

★ Notable: the "broken for-completeness secondary alternative" pattern (recurring Haiku failure mode) did NOT appear this iter — every secondary note was correct.

## Recommendation — DEFAULT NO-OP

Margin +1.328; all 4 deliverables correct and verified both directions against RAW git-tag 467 source; zero tics; zero fabricated functions/syntax; no findable resource gap; no 2-in-2 recurrence. NO resource edit warranted.

Re-probe next sweep:
- (a) another JSON-extraction + GROUP BY Q — confirm json_extract_scalar→varchar + CAST-for-numeric + repeat-expr-in-GROUP-BY lead holds.
- (b) another dedup/latest-row-per-key Q — confirm ROW_NUMBER+rn=1-in-CTE (no QUALIFY) + tiebreak; watch for QUALIFY slip.
- (c) another array-explode Q — confirm CROSS JOIN UNNEST AS t(col) + LEFT JOIN ON TRUE for empty-array preservation.
- (d) another ratio-to-total/window-aggregate Q — confirm SUM() OVER () grand total + decimal-literal-avoids-truncation + NULLIF guard.

Federation r22 §13.x hard-locked, NOT probed (OVERRIDDEN). NO resource edits. MUST NOT bump training/state.json (already 1002; passed=true preserved; final_iterations_remaining 0).
