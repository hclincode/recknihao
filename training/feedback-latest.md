# Iter 502 Judge Feedback — 2026-06-06 (EXTENDED PHASE)

## Overall: 4.1719 PASS (margin +0.6719 above 3.5 floor; lowest in 12 iters; Q4 FINDABILITY-GAP FAIL drags 0.6+)

Three answers clean / STRONG PASS or PASS-with-deduction. One FAIL (Q4) — load-bearing misdirection that resources/ ALREADY HAS the right canonical for (r13:5405-5522) but the responder never landed on. **Pattern matches the iter499 dbt-snapshot findability gap: content is correct and complete in resources/, but the question's keywords don't route there.**

---

## Per-Question Scores

### Q1 — p95 latency per customer per day on 300M rows (approx_percentile) — **4.875 STRONG PASS**

- Accuracy 5.0, Clarity 4.75, Actionability 5.0, Completeness 4.75

**Verified clean (WebSearch trino.io/docs/current/functions/aggregate.html + tdigest.html):**
- `approx_percentile(col, 0.95)` single-percentile form — VALID Trino 467 (T-Digest-backed per PR #5158).
- `approx_percentile(col, ARRAY[0.50, 0.95, 0.99])` array form returning `array<[same as x]>` — VALID Trino 467, one-pass evaluation.
- `<1% error` claim — CORRECT for T-Digest (and explicitly NOT confused with the ~2.3% relative error of HLL/`approx_distinct`).
- `GROUP BY customer_id, CAST(event_date AS DATE)` — correct group-key construction for per-customer-per-day.

Minor (-0.25 Completeness): no mention of partition-pruning predicate on `event_date` to limit the 300M-row scan (the question explicitly says "300M rows" — partition predicate would be the actionable speedup beyond approx_percentile).

### Q2 — Undo a bad Iceberg write without manual row deletion (rollback_to_snapshot) — **4.875 STRONG PASS**

- Accuracy 5.0, Clarity 4.75, Actionability 5.0, Completeness 4.75

**Verified clean (WebSearch trino.io/docs/current/connector/iceberg.html + GitHub PR #24580):**
- `CALL iceberg.system.rollback_to_snapshot('analytics', 'events', <snapshot_id>)` positional 3-arg form — VALID Trino 467 (system.rollback_to_snapshot is being deprecated in favor of a table procedure per PR #24580 but is still functional and the documented form in 467).
- `iceberg.analytics."your_table$snapshots"` whole-token-quoted metadata reference — CORRECT (the `$snapshots` form requires whole-table-name quoting because `$` is not a bare-identifier character).
- `ORDER BY committed_at DESC` to find latest snapshots — CORRECT (committed_at column verified on metadata table).
- "Metadata-pointer revert / atomic / seconds" framing — CORRECT (rollback flips current snapshot pointer in metadata.json, no data movement).
- 7-day default snapshot history + `expire_snapshots` caveat — CORRECT operationally.

Minor (-0.25 Completeness): could mention checking `iceberg.analytics."your_table$history"` to also see which snapshots are still rollback-eligible (not expired).

### Q3 — Oracle `SELECT sysdate FROM DUAL` and `seq_name.NEXTVAL FROM DUAL` → Trino — **4.0625 PASS** (LOAD-BEARING MD5 TYPE ERROR, partially mitigated by canonical dbt_utils form)

- Accuracy 3.5, Clarity 4.5, Actionability 4.0, Completeness 4.25

**Verified clean:**
- SELECT-without-FROM in Trino — VALID (Trino does NOT require `FROM DUAL`; bare `SELECT current_timestamp` parses).
- `CURRENT_DATE` and `current_timestamp` for SYSDATE — CORRECT mapping (Trino `current_timestamp` returns `TIMESTAMP(3) WITH TIME ZONE` corresponding to Oracle SYSTIMESTAMP).
- `current_timestamp AT TIME ZONE 'America/New_York'` — VALID Trino syntax.
- Iceberg #12297 "Support for Identity Columns" closed NOT PLANNED — VERIFIED via WebSearch (GitHub issue confirms closure by github-actions[bot] as not planned).
- Trino has no `CREATE SEQUENCE`/`.NEXTVAL` — CORRECT (parse-fail).
- `{{ dbt_utils.generate_surrogate_key(['tenant_id','order_id','created_at']) }}` canonical form — CORRECT and is what engineers should actually use.
- "Hash keys won't match Oracle numeric IDs" caveat — CORRECT and important.

**LOAD-BEARING TYPE ERROR (-1.5 Accuracy)** — verified via WebSearch trino.io/docs/current/functions/binary.html + string.html:

The hand-rolled fallback `md5(concat_ws('||', tenant_id, order_id, created_at))` has **two type errors** as written:
1. **`md5()` in Trino 467 takes `VARBINARY`, not VARCHAR.** Per trino.io/docs/current/functions/binary.html, signature is `md5(binary) -> varbinary`. Passing a VARCHAR directly fails function resolution at parse time.
2. **`concat_ws` requires all-VARCHAR args.** `created_at` is a TIMESTAMP and would need `CAST(created_at AS VARCHAR)` first.
3. **To get the hex-string surrogate key form** the engineer expects, the correct Trino idiom is `to_hex(md5(to_utf8(concat(CAST(tenant_id AS VARCHAR), '||', CAST(order_id AS VARCHAR), '||', CAST(created_at AS VARCHAR)))))` — this is what `dbt_utils.generate_surrogate_key` compiles to internally on dbt-trino.

**Engineer copy-pasting the hand-rolled form gets:** `Unexpected parameters (varchar) for function md5. Expected: md5(varbinary)`.

**Partial mitigation:** the answer also gave `dbt_utils.generate_surrogate_key([...])` as the primary recommendation, which is correct and is the form engineers actually use. So Accuracy gets 3.5 (not 2.5) — the canonical answer is correct, the hand-rolled fallback example is broken.

### Q4 — Incremental dbt column ADDED but silently absent from output table — **2.875 FAIL** (FINDABILITY GAP — answered with CONTRACTS instead of on_schema_change)

- Accuracy 2.5, Clarity 3.5, Actionability 2.5, Completeness 3.0

**THIS IS THE TEXTBOOK `on_schema_change` SCENARIO — VERIFIED via docs.getdbt.com/docs/build/incremental-models:**

Verbatim from dbt docs:
> "**`ignore` (default)**: If you add a column to your incremental model, and execute a `dbt run`, this column will not appear in your target table."

The question states verbatim: "An incremental dbt model had a column ADDED, build succeeded, but the column was silently absent from the output table." This IS the dbt default `on_schema_change='ignore'` behavior. The precise fix is one line:

```yaml
{{ config(
    materialized='incremental',
    on_schema_change='append_new_columns'  -- or 'sync_all_columns' or 'fail'
) }}
```

**The responder answered with CONTRACTS** (`config.contract.enforced: true` + columns/data_type list per docs.getdbt.com/docs/mesh/govern/model-contracts). Contracts CAN detect column mismatches at build-time preflight, but:
- Contracts compare declared YAML schema vs SELECT output — they do NOT change incremental-merge behavior.
- Contracts require declaring every column with name + data_type upfront (high-friction for SaaS engineers iterating on schemas).
- The dbt-native, one-line fix for the EXACT scenario described is `on_schema_change`, not contracts.

**FABRICATION (-0.5 Accuracy)** — answer's YAML showed BOTH a top-level `enforced: true` AND `contract: {enforced: true}` in the same config. The bare top-level `enforced: true` outside the `contract:` block is **not a valid standalone dbt config** — engineers copy-pasting will get a config-parse warning or silent ignore. Per docs.getdbt.com/reference/resource-configs/contract, the only valid form is `contract: {enforced: true}` nested under `config:`.

**FINDABILITY GAP CONFIRMED — content EXISTS in resources/:**

`grep on_schema_change resources/` returns:
- **`resources/13-postgres-to-iceberg-ingestion.md:5405-5522`** — full canonical `### on_schema_change — the FOUR options and the correct default` section with EXACT match to the question scenario: "If you do not set `on_schema_change` explicitly, dbt uses `ignore` semantics: any new column added to the source SELECT is **silently dropped** from the INSERT/UPDATE, never propagates to the target Iceberg table, and never appears in downstream queries. This is silent data loss for newly-added source columns." Includes 4-option table (ignore / fail / append_new_columns / sync_all_columns) with new-column and removed-column behaviors. Recommended `append_new_columns` for SaaS pipelines.
- `resources/27-oracle-plsql-to-dbt-trino.md:349` — single-line summary mentioning `on_schema_change='append_new_columns'` is safe default.
- `resources/28-complex-sql-performance-trino-dbt.md:159` — table row pointing to dbt docs.
- `resources/27-oracle-plsql-to-dbt-trino.md:1452` — cross-ref pointing to r13 §on_schema_change.

**Why didn't the responder route here?** The question keywords are "incremental model" + "column ADDED" + "build succeeded" + "silently absent" + "make dbt fail/warn." The r13 canonical sits inside a long `Postgres-to-Iceberg ingestion` resource and the section header is `### on_schema_change — the FOUR options and the correct default`. The keywords "silently absent" / "incremental column added" / "make dbt fail" don't lead to r13 from a Haiku keyword-match perspective. The `silently dropped` verbatim language IS in r13:5407 but the section title doesn't surface terms like "schema change," "schema drift," or "incremental column added."

**Verdict:** Identical pattern to the iter499 → iter500 dbt-snapshot findability fix. The fix is NOT new content (r13 §on_schema_change is canonical and correct) — it's keyword anchors and forward-pointer cross-refs.

---

## Topic Avg Updates

| Topic | Before | Computation | After |
|---|---|---|---|
| SQL query best practices for OLAP (Q1 approx_percentile maps here) | 4.5314/56 | (4.5314*56 + 4.875)/57 = 258.633/57 | **4.5374/57** (+0.0060) |
| Iceberg table maintenance (Q2 rollback_to_snapshot maps here) | 4.4982/150 | (4.4982*150 + 4.875)/151 = 679.605/151 | **4.5007/151** (+0.0025) |
| Oracle PL/SQL→dbt/Trino migration (Q3 SYSDATE/NEXTVAL maps here) | 4.5460/73 | (4.5460*73 + 4.0625)/74 = 335.9205/74 | **4.5395/74** (-0.0065 — Q3 md5 type error drags below topic avg, still PASS) |
| dbt model contracts (Q4 misdirection contracts answer maps here) | 4.1146/3 | (4.1146*3 + 2.875)/4 = 15.2188/4 | **3.8047/4** (-0.3099 — Q4 misdirection + fabricated top-level enforced drags low-sample row noticeably; still PASS at 3.5 floor) |
| Postgres-to-Iceberg ingestion (on_schema_change canonical lives in r13; Q4 misdirection bucket-charged here) | 4.4923/168 | (4.4923*168 + 2.875)/169 = 757.5814/169 | **4.4827/169** (-0.0096 — still PASS) |

Federation NOT probed — **4.49944/310 row UNCHANGED** per iter472-502 directive (and per task constraint: do NOT touch §13.x federation guardrails or federation rubric row).

---

## Verification Summary

| Check | Result |
|---|---|
| Q1 approx_percentile array form valid Trino 467 | CONFIRMED via trino.io/docs/current/functions/aggregate.html + tdigest.html — single-pass T-Digest, <1% error claim accurate |
| Q1 GROUP BY customer_id + CAST(event_date AS DATE) correct | CONFIRMED |
| Q2 `CALL iceberg.system.rollback_to_snapshot(schema, table, snapshot_id)` positional 3-arg Trino 467 | CONFIRMED via trino.io/docs/current/connector/iceberg.html (procedure deprecated per PR #24580 but functional in 467) |
| Q2 `"table$snapshots"` whole-token quoting + committed_at column | CONFIRMED |
| Q2 metadata-pointer revert / atomic / 7-day default | CONFIRMED operationally |
| Q3 SELECT-without-FROM valid Trino | CONFIRMED (Trino does not require FROM DUAL) |
| Q3 CURRENT_DATE / current_timestamp / AT TIME ZONE | CONFIRMED via trino.io/docs/current/functions/datetime.html |
| Q3 Iceberg #12297 identity column closed NOT PLANNED | CONFIRMED via github.com/apache/iceberg/issues/12297 (closed by github-actions[bot] as not planned) |
| Q3 dbt_utils.generate_surrogate_key canonical | CONFIRMED correct |
| **Q3 md5() type signature in Trino 467** | **TYPE ERROR CONFIRMED** — per trino.io/docs/current/functions/binary.html, `md5(binary) -> varbinary` — VARCHAR arg fails function resolution. Correct form: `to_hex(md5(to_utf8(concat(...))))`. concat_ws also requires all-VARCHAR args (created_at TIMESTAMP needs CAST). |
| Q4 contracts feature semantics (build-time preflight, columns + data_type) | CONFIRMED via docs.getdbt.com/docs/mesh/govern/model-contracts — but WRONG TOOL for the question described |
| **Q4 on_schema_change is the correct fix for "incremental column added → silently dropped"** | **CONFIRMED via docs.getdbt.com/docs/build/incremental-models** — verbatim "If you add a column to your incremental model, and execute a dbt run, this column will not appear in your target table" is the `ignore` default; fix is `on_schema_change='append_new_columns'` (or `sync_all_columns` or `fail`) |
| **Q4 top-level bare `enforced: true` (outside `contract:` block) is a valid config** | **FABRICATION** — not a valid standalone dbt config per docs.getdbt.com/reference/resource-configs/contract; only valid form is `contract: {enforced: true}` |
| **Q4 on_schema_change content exists in resources/** | **EXISTS at r13:5405-5522** (canonical), r27:349, r28:159, r27:1452 (cross-ref). FINDABILITY GAP, not content gap. |

---

## Concrete Next-Teacher Actions (iter503 — HIGH PRIORITY)

### 1. on_schema_change FINDABILITY FIX (HIGH — Q4 misdirection from iter502 — pattern matches iter499→500 dbt-snapshot fix)

**DO NOT WRITE NEW on_schema_change CONTENT.** r13:5405-5522 is canonical, complete, and correct. Adding duplicate content risks iter495-style stale-block contradiction.

**Pure-findability fix (zero new content):**

1. **Add a leading keyword anchor at the top of r13 §on_schema_change (line ~5405):** Insert a one-line anchor with the keywords the question uses:
   ```markdown
   <!-- KEYWORDS: incremental model column added / column silently absent / column silently dropped / make dbt fail when schema changes / make dbt warn on schema drift / incremental schema drift / dbt incremental column missing / dbt added column not in output -->
   ```
   These are the exact phrases the iter502 question used.

2. **Add forward-pointer cross-refs from any resource that mentions `incremental` model material to r13 §on_schema_change:**
   - r27 §6.7 (dbt section) — add a "see r13 §on_schema_change for incremental schema-drift behavior" callout
   - r28 §incremental tuning — add same callout
   - **dbt-contracts canonical** (wherever it lives in resources/) — add a DO-NOT-CONFUSE callout: "Contracts catch column mismatches at build-time preflight against the YAML schema. For incremental models that silently drop new SELECT columns on incremental runs, use `on_schema_change` (see r13 §...), NOT contracts. Contracts and on_schema_change are complementary, not interchangeable."

3. **At the contracts canonical (wherever it lives), add a DO-NOT-WRITE banner banning:**
   - Top-level bare `enforced: true` outside `contract:` block (NOT valid; only `contract: {enforced: true}` parses)
   - Suggesting contracts as the fix for "incremental column went missing" (correct answer is `on_schema_change`)

### 2. md5/concat_ws TYPE-ERROR FIX (MEDIUM — Q3 hand-rolled fallback example is broken)

**Reconcile-in-place in r27 §sequences/surrogate-key (line ~349 vicinity, or wherever the hand-rolled md5 example lives):**

Find and fix any `md5(concat_ws(...))` or `md5(<varchar>)` hand-rolled example. Replace with:
```sql
-- CORRECT Trino 467 hand-rolled surrogate-key form (use this if you can't use dbt_utils):
to_hex(md5(to_utf8(
  concat(
    CAST(tenant_id AS VARCHAR), '||',
    CAST(order_id AS VARCHAR), '||',
    CAST(created_at AS VARCHAR)
  )
)))
```

Plus a DO-NOT-WRITE row banning:
- `md5(<varchar>)` directly — `md5` takes VARBINARY only per trino.io/docs/current/functions/binary.html (signature `md5(binary) -> varbinary`); pass `to_utf8(<varchar>)` to convert first
- `concat_ws('||', tenant_id, order_id, created_at)` where any arg is non-VARCHAR — concat_ws requires all-VARCHAR; CAST non-VARCHAR args first
- `md5(...)` returned directly to a hex-string column — md5 returns VARBINARY; wrap in `to_hex(...)` for the hex string

**Primary recommendation should remain `dbt_utils.generate_surrogate_key([...])`** — engineers should default to that; the hand-rolled form is the escape hatch and must be correct.

### 3. Minor (LOW)

- Q1: could add partition-pruning predicate example to the approx_percentile canonical (event_date WHERE clause to limit 300M-row scan — load-bearing for the actual SaaS scenario).

---

## Judge Probe Targets for iter503

| Probe | Priority | Rationale |
|---|---|---|
| **on_schema_change re-probe from different angle** ("I added a column to my dbt incremental SELECT but the column is missing from the table — how do I make dbt actually pick it up?") | **HIGH** | Confirm the iter503 findability fix routes Haiku to r13 §on_schema_change instead of contracts. Must include phrasing variants: "silently absent," "silently dropped," "incremental column went missing," "make dbt fail on schema change," "make dbt warn on schema drift." Pattern-matches the iter500 dbt-snapshot findability fix re-probe. |
| **md5/concat_ws Trino type-error re-probe** ("I need a hand-rolled surrogate key in Trino — `md5(concat_ws(...))` doesn't work, what's the correct form?") | **HIGH** | Confirm the reconcile-in-place lands. Test that responder writes `to_hex(md5(to_utf8(concat(CAST(...AS VARCHAR), ...))))` and NOT `md5(concat_ws(...))` or `md5(<varchar>)`. |
| dbt contracts vs on_schema_change DIFFERENTIATION probe ("when do I use dbt contracts vs on_schema_change?") | **MEDIUM** | Probes whether teacher's DO-NOT-CONFUSE callout (action #1.3 above) routes correctly. Both features should be defended but for DIFFERENT scenarios. |
| approx_percentile single-percentile + partition-predicate combo ("p95 of response_time, only last 30 days, fast on a 300M-row table") | **MEDIUM** | Confirm Q1 still passes when engineer asks for the time-bounded version (partition-pruning predicate on event_date must surface). |
| Trino rollback_to_snapshot 2nd angle ("rolled back but my old data is still there in MinIO — do I need to clean up?") | **MEDIUM** | Probes whether responder correctly explains that rollback flips snapshot pointer (data files orphaned but not deleted until `expire_snapshots`). |
| Iceberg identity-column / surrogate-key from a 3rd angle ("can I add an AUTO_INCREMENT column to my Iceberg table?") | **LOW** | Confirms Iceberg #12297 closed-not-planned holds across phrasings. |
| Federation | **DO NOT PROBE** | §13.x federation guardrails and 4.49944/310 row are LOCKED per task constraint. |

---

## Other Findings

- **NO Spark-isms detected** in any answer this iter (no `SET TBLPROPERTIES`, no `UPDATE SET *`, no `INSERT *`, no `ANALYZE TABLE` for Trino).
- **NO new Trino session-property fabrications.**
- **Q4 is the ONLY hard fabrication this iter** (top-level bare `enforced: true`). Q3 md5 is a TYPE ERROR, not a fabrication — the function exists, just with the wrong signature in the example.
- **101st consecutive overall PASS** in extended phase, but **lowest overall in 12 iterations** (4.1719 vs iter501 4.7969 and iter500 4.6406). The Q4 FAIL is the dominant drag.
- **Findability-gap pattern is recurring** — this is the 3rd findability gap in extended phase (iter499 dbt-snapshot, iter502 on_schema_change). Both fixes are pure-routing interventions (keyword anchors + cross-refs), zero new content. The iter500 dbt-snapshot findability fix LANDED on first re-probe — same pattern should work here.

---

## Confidence

- HIGH on Q1/Q2 STRONG PASS verdicts (multiple-source verification).
- HIGH on Q3 md5 type-error finding (binary functions doc unambiguous + canonical pattern is well-known `to_hex(md5(to_utf8(...)))`).
- HIGH on Q4 on_schema_change-vs-contracts finding (verbatim docs match + r13 canonical exists + answer's contracts pivot is documented mismatch).
- HIGH on Q4 top-level `enforced: true` fabrication (no doc supports it; contract config is the only valid form).
