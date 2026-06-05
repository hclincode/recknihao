# Iter 500 Judge Feedback — 2026-06-06 (EXTENDED PHASE)

## Headline

**OVERALL = 4.6406 STRONG PASS** (+1.1406 above 3.5 floor). **DBT-SNAPSHOT FINDABILITY FIX LANDED.** Q1 jumped from iter499's 3.125 punt to 4.9375 STRONG — responder now routes to r09 §1a/1b on the first 3rd-angle re-probe, writes dialect-correct `strategy='check'` + `check_cols=['plan_tier','account_status']` LIST form + bans `['all']` list-wrap anti-pattern + all four metadata cols + `WHERE dbt_valid_to IS NULL` current-rows pattern. This is the 9th leading-canonical bulletproofing instance AND the first findability-only (zero-new-content) fix in the extended phase. Q2/Q3 fully clean. Q4 dbt not_null severity STRONG PASS with ONE minor non-load-bearing nit (compiled-SQL pattern misstatement). Federation NOT probed (per directive).

## Per-question scores

| Question | Accuracy | Clarity | Actionability | Completeness | Avg | Verdict |
|---|---|---|---|---|---|---|
| Q1 dbt snapshot SCD2 RE-PROBE | 5.00 | 4.75 | 5.00 | 5.00 | **4.9375** | STRONG PASS — FINDABILITY FIX LANDED |
| Q2 JSON parse + WHERE filter | 5.00 | 4.75 | 5.00 | 4.75 | **4.875** | STRONG PASS |
| Q3 Oracle ROWNUM → Trino top-N | 5.00 | 4.75 | 5.00 | 5.00 | **4.9375** | STRONG PASS |
| Q4 dbt not_null severity | 4.50 | 4.75 | 4.75 | 4.75 | **4.6875** | PASS (minor non-load-bearing nit) |

**Overall = (4.9375 + 4.875 + 4.9375 + 4.6875) / 4 = 19.4375 / 4 = 4.6406** (STRONG PASS)

---

## Q1 — dbt snapshot SCD2 RE-PROBE — **FINDABILITY FIX LANDED**

The iter500 findability fix landed cleanly on the first 3rd-angle re-probe. The responder now routes to r09 §1a/1b and writes a fully dialect-correct dbt snapshot answer.

Confirmed correct, load-bearing facts:
- `strategy='check'` (correct strategy name; no fabricated `hash` / `merge` / `changes`).
- `check_cols=['plan_tier', 'account_status']` in LIST form (correct; not list-wrapped `['all']`).
- Explicitly stated `check_cols=['all']` (list-wrapped) is WRONG and treated as a column literally named `all` — this is the iter499 banned anti-pattern, now correctly flagged as banned.
- Explained the LIST vs bare-string `'all'` shorthand distinction.
- Metadata columns `dbt_valid_from` / `dbt_valid_to` / `dbt_scd_id` / `dbt_is_deleted` (1.9+) all present and correct.
- Did NOT fabricate `dbt_is_current`.
- Current-rows query `WHERE dbt_valid_to IS NULL` correct.
- Mechanic: old row closed (`dbt_valid_to` stamped) + new row inserted on changed-col detection — correct.
- Non-listed cols ignored — correct.
- Cited r09 lines 378-426 (direct landing on canonical).

Verified against docs.getdbt.com/docs/build/snapshots and docs.getdbt.com/reference/resource-configs/check_cols — every claim is verbatim correct.

**The iter500 teacher's pure-routing intervention worked.** No new content, no duplication, only an r09 keyword anchor + 4 identical forward-pointer cross-refs from r10/r23/r27/r28. Single-source-of-truth preserved, zero stale-contradiction risk, zero new content drift. 9th successful leading-canonical bulletproofing instance and the first findability-only fix in the extended phase.

Minor (−0.25 Clarity only): didn't gloss "re-hashes" for an absolute beginner reader.

## Q2 — JSON parse + WHERE filter

Verified against trino.io/docs/current/functions/json.html (release 467 lineage):
- `json_extract_scalar(config, '$.plan') = 'enterprise'` — valid Trino 467, usable directly in WHERE. CORRECT.
- Returns NULL for missing path AND for malformed JSON — CORRECT.
- `JSON_VALUE(config, '$.plan' RETURNING varchar NULL ON EMPTY NULL ON ERROR)` — valid SQL/JSON syntax. CORRECT.
- json_extract_scalar vs JSON_VALUE NULL-control contrast — CORRECT.
- Perf note (JSON has no per-key stats so full scan; promote hot keys to top-level columns) — correct and SaaS-actionable.

No fabrications. Trino-dialect-clean.

Scores: 5.0 / 4.75 / 5.0 / 4.75.

## Q3 — Oracle ROWNUM → Trino top-N

Verified against trino.io/docs/current/sql/select.html and trino.io/docs/current/functions/window.html:
- "No ROWNUM in Trino" — correct.
- `ORDER BY created_at DESC LIMIT 100` — valid Trino top-N (optimizer uses TopN, not full sort). Correct.
- `ROW_NUMBER() OVER (ORDER BY ...) AS row_number ... WHERE row_number <= 100` via subquery — correct standard pattern. NO QUALIFY (Trino 467 doesn't support QUALIFY — good).
- Oracle ROWNUM-before-ORDER-BY inline-view trap explanation — correct. Oracle assigns ROWNUM before ORDER BY in the same SELECT; wrap-then-filter required.

No fabrications. Trino-dialect-clean.

Scores: 5.0 / 4.75 / 5.0 / 5.0.

## Q4 — dbt not_null severity (build fail vs warn)

Verified against docs.getdbt.com/reference/resource-configs/severity and /store_failures:

CORRECT load-bearing claims:
- `not_null` generic test exists — correct.
- Default severity is `error` — correct.
- `error` makes `dbt build` / `dbt test` exit non-zero — correct.
- `severity: warn` continues without failing the build — correct.
- `store_failures: true` writes failing rows to `<schema>_dbt_test__audit.<test_name>` — correct.
- YAML under `data_tests:` block — correct (modern key; legacy was `tests:`).
- Build halts AFTER materialization (so the bad table is already written) — correct, important nuance.

MINOR ACCURACY NIT (flagged, NOT load-bearing):
- Answer says dbt compiles the not_null test to `SELECT 1 FROM fct_orders WHERE customer_id IS NULL LIMIT 1`. This is WRONG. Real compile pattern is:
  ```
  SELECT COUNT(*) AS failures, COUNT(*) != 0 AS should_warn, COUNT(*) != 0 AS should_error
  FROM (SELECT * FROM <model> WHERE <col> IS NULL) dbt_internal_test
  ```
- Verified at docs.getdbt.com/docs/build/data-tests and dbt-core test macro source.
- Matters because the compiled test reports the ACTUAL failure count, which is what `error_if`/`warn_if` thresholds compare against. `LIMIT 1` would be incompatible with threshold-conditional severity (`error_if: ">10"`).
- SEVERITY / BUILD-HALT / store_failures behavior the engineer actually needs is all correct, so does NOT drop the answer below PASS. Accuracy −0.5 only.

Scores: 4.5 / 4.75 / 4.75 / 4.75.

---

## FINDABILITY-FIX-LANDED OUTCOME

**CONFIRMED LANDED.** The iter500 teacher's strategy (no new content; only r09 keyword anchor + 4 identical forward-pointer cross-refs from r10/r23/r27/r28) successfully routed the responder to r09 §1a/1b on the FIRST 3rd-angle probe. Q1 jumped from 3.125 FAIL (iter499 punt) to 4.9375 STRONG PASS.

Key wins:
- Single-source-of-truth preserved (no duplicate snapshot mechanics anywhere).
- Zero stale-contradiction risk (iter495-style trap avoided).
- Zero new content drift.
- 9th leading-canonical bulletproofing instance.
- **First findability-only zero-new-content fix to land in the extended phase** — strong signal that pure routing interventions work when the canonical content is already correct.

## NEW FABRICATIONS THIS ITER

ONE minor non-load-bearing nit only:
- **Q4 compiled-SQL pattern**: `SELECT 1 ... LIMIT 1` is wrong; actual is `SELECT COUNT(*) ... FROM (... WHERE col IS NULL) dbt_internal_test`. Not load-bearing (severity/build-halt behavior all correct). LOW priority.

No load-bearing fabrications. Zero recurrences of any prior-iter fab.

---

## Next-teacher actions (iter501)

LOW PRIORITY (single nit, not load-bearing):
1. **dbt tests resource — clarify compiled `not_null` test SQL.** Add one line near the existing dbt-tests / severity content: "dbt compiles `not_null` generic tests to `SELECT COUNT(*) AS failures, COUNT(*) != 0 AS should_warn, COUNT(*) != 0 AS should_error FROM (SELECT * FROM <model> WHERE <col> IS NULL) dbt_internal_test` — NOT `SELECT 1 ... LIMIT 1` (which would break threshold-conditional `error_if` / `warn_if`)." Keep tight, one line, single-source-of-truth. Do NOT duplicate severity content elsewhere.

DO NOT TOUCH (per directive):
- r22 §13.x federation guardrails (9 subsections 13.1–13.8 + 13.5A at lines 8050–9170). Federation rubric row stays 4.49944/310.
- r09 §1a/1b snapshot canonical — content is verified correct AND the findability fix landed; do not modify.
- Iter500's r09 anchor + r10/r23/r27/r28 cross-refs — they worked; leave as-is.
- r28 §3.3/§3.3A materialization canonical; r28 GROUPING-bitmask canonical; r27 §3.3 partitioning-key canonical; r27 §4.1A DECODE-NULL; r27 §4.6B MERGE star-shorthand guardrail; r13 §Pattern C MERGE engine-note; r03 no-index canonical; r17 view-storage canonical.

## Judge probe targets for iter501

- **dbt snapshot SCD2 from a 4th angle** (HIGH — confirm the findability fix HOLDS, not just landed once). Suggested phrasing: "I deleted a customer in source — does my dbt snapshot mark the row deleted or keep the old row open forever?" (probes `dbt_is_deleted` + `hard_deletes='new_record'` 1.9+ semantics).
- **dbt not_null severity 2nd angle** (MEDIUM — would lock in the compiled-SQL one-liner if teacher writes it). Suggested: "How do I let my not_null test tolerate up to 5 nulls before failing the build?" (probes `error_if: ">5"` threshold semantics — where the SELECT-1-LIMIT-1 fab would actively mislead).
- **Trino JSON_VALUE ON ERROR variants** (MEDIUM — 2nd angle on SQL/JSON RETURNING clause). Suggested: "JSON column has bad rows that break my query — how do I make malformed JSON return NULL instead of erroring?"
- **Top-N per group with ROW_NUMBER PARTITION BY** (MEDIUM — Q3 4th angle to lock in no-QUALIFY pattern). Suggested: "Top 3 events per user — how do I do per-group top-N in Trino?"
- **Federation row 4.49944/310 — stays UNPROBED** per long-standing directive.

---

## Sources verified

- [check_cols | dbt Developer Hub](https://docs.getdbt.com/reference/resource-configs/check_cols)
- [Add snapshots to your DAG | dbt Developer Hub](https://docs.getdbt.com/docs/build/snapshots)
- [snapshot_meta_column_names | dbt Developer Hub](https://docs.getdbt.com/reference/resource-configs/snapshot_meta_column_names)
- [JSON functions and operators | Trino Documentation](https://trino.io/docs/current/functions/json.html)
- [Window functions | Trino Documentation](https://trino.io/docs/current/functions/window.html)
- [severity, error_if, and warn_if | dbt Developer Hub](https://docs.getdbt.com/reference/resource-configs/severity)
- [store_failures | dbt Developer Hub](https://docs.getdbt.com/reference/resource-configs/store_failures)
- [About data tests property | dbt Developer Hub](https://docs.getdbt.com/reference/resource-properties/data-tests)
