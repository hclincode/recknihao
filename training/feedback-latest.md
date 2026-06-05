# Iter 494 Judge Feedback — 2026-06-06 (EXTENDED PHASE)

## Overall: 4.5469 PASS (+1.047 above 3.5 floor)

DECODE-NULL canonical HELD. iter494 primary teacher fix (r27 §4.1A LEADING CANONICAL block for `DECODE(status,NULL,'Missing','A','Active','Unknown')`) PATTERN-MATCHED VERBATIM by responder — 4th successful instance of the leading-canonical-example bulletproofing pattern.

One LOAD-BEARING accuracy slip on Q3: the dbt-trino `properties` dict used `partitioning` instead of `partitioned_by`. Teacher reports the root-cause stale content at r27:2405 and r16:571 was corrected this iteration; re-probe at iter495 will confirm the fix landed.

Federation NOT probed — 4.49944/310 row UNCHANGED per iter472-494 directive.

---

## Per-question scoring

### Q1 — DECODE(status, NULL, 'Missing', 'A', 'Active', 'Unknown') → Trino — 4.9375 STRONG PASS

| Dim | Score | Notes |
|---|---|---|
| Accuracy | 5.0 | Searched CASE with `WHEN status IS NULL THEN 'Missing'` FIRST, then `WHEN status = 'A' THEN 'Active'`, ELSE 'Unknown'. Explicitly states `status = NULL` returns UNKNOWN under 3VL and never matches. States `IS NULL` is the only Trino construct returning TRUE for NULL. Rule that every `DECODE(col, NULL, ...)` becomes searched CASE with `IS NULL` first. Verified at trino.io/docs/current/functions/conditional.html. ZERO fabrications. |
| Clarity | 4.75 | "Why your current CASE fails" framing explains 3VL with the exact failure mode the engineer hit. |
| Actionability | 5.0 | Copy-pasteable Trino-467-valid fix; ordering rule callable as a checklist item. |
| Completeness | 5.0 | WHY (3VL) + HOW (IS NULL first) + GENERAL RULE all covered. |

**iter494 PRIMARY FIX CONFIRMED LANDED**: r27 §4.1A LEADING CANONICAL block matched verbatim. ZERO recurrence of the 3VL `WHEN status = NULL` trap. ZERO collapse-into-ELSE drift. 4th successful instance of the leading-canonical-example bulletproofing pattern (after r13 Spark writeTo iter420, r07 GROUP-BY-expression iter485, r07 §5 YoY Pattern B2 iter493).

### Q2 — dbt exposures (what / runtime / where) — 4.625 STRONG PASS

| Dim | Score | Notes |
|---|---|---|
| Accuracy | 4.75 | Exposures = descriptive metadata only, NO runtime effect, NO DDL/SQL — CONFIRMED at docs.getdbt.com/docs/build/exposures ("purely declarative and don't affect dbt's execution"). YAML fields (name, type, maturity, owner, depends_on via ref()/source()) CORRECT. Shows up in `dbt docs generate`/`serve` DAG lineage CORRECT. Useful for impact analysis CORRECT. |
| Clarity | 4.75 | "Documentation-only" framing directly answers the runtime sub-question. |
| Actionability | 4.5 | YAML example useful. Could have shown the `dbt run -s +exposure:my_dashboard` impact-analysis selection syntax explicitly. |
| Completeness | 4.5 | All three sub-questions answered. Optional fields (`meta`/`tags`/`label`/`url`) not mentioned but not asked. |

ZERO fabrications.

### Q3 — Iceberg event_date + bucket(customer_id) coexistence + setup — 3.75 PASS (DRAGGED)

| Dim | Score | Notes |
|---|---|---|
| Accuracy | 3.0 | **LOAD-BEARING ERROR**: dbt config block uses `properties={'partitioning': "ARRAY['month(order_date)', 'bucket(customer_id, 16)']"}` — WRONG KEY for the dbt-trino `properties` dict. Per resources/27 §4 DO-NOT-WRITE and resources/28 LEADING CANONICAL (authoritative for this repo's stack), the dbt-trino `properties` Iceberg partition key is **`partitioned_by`** (snake_case). The `partitioning` key INSIDE the dbt `properties` dict is the iter452-documented known-fab class (silently no-ops or errors at apply time). The bare-Trino DDL `WITH (partitioning = ARRAY[...])` IS correctly using `partitioning` (that IS the right key for raw Trino CREATE TABLE / SET PROPERTIES). The responder mixed up which key belongs on which surface. Bucket+month coexistence CORRECT; bucket(col, N) hash-distribution explanation CORRECT; pruning behavior CORRECT; bucket-count guidance CORRECT. |
| Clarity | 4.5 | Step-by-step bare-Trino-then-dbt structure is clean; bucket-hashing explanation is good. |
| Actionability | 3.0 | Engineer copy-pasting the dbt block AS DELIVERED would hit the iter452 silent no-op / apply-time error. The bare-Trino DDL half is copy-pasteable and works. Net actionability is split — half of what was delivered is broken. |
| Completeness | 4.5 | All three sub-questions answered (is it real, can you have both, how to set up). |

**Root cause was stale content at r27 line 2405 and r16 line 571 — BOTH CORRECTED THIS ITERATION (iter494 teacher fix to `partitioned_by`).** The responder's wrong-key answer in this iteration came from content that has now been fixed; the fix must be re-probed at iter495 to confirm it landed and routes from the partition-design keyword path.

### Q4 — TRY / TRY_CAST for junk strings ("N/A", "") — 4.875 STRONG PASS

| Dim | Score | Notes |
|---|---|---|
| Accuracy | 5.0 | TRY_CAST returns NULL on unparseable, CAST throws — CONFIRMED at trino.io/docs/current/functions/conversion.html ("Like cast(), but returns null if the cast fails."). is_junk_data CASE pattern to distinguish parse-failure NULL from genuine-NULL is correct Trino dialect. "No perf penalty" claim defensible (per-row local op, no shuffle/spill change). |
| Clarity | 4.75 | Comparison table CAST-vs-TRY_CAST makes the difference immediate; NULL-conflation gotcha is exactly what bites in production. |
| Actionability | 5.0 | Direct copy-paste fix + audit pattern + caveat about losing original junk values for forensic review. |
| Completeness | 4.75 | Fix + load-bearing gotcha both covered. |

ZERO fabrications.

---

## Overall calculation

(4.9375 + 4.625 + 3.75 + 4.875) / 4 = 18.1875 / 4 = **4.5469 PASS**

---

## Topic average updates

| Topic | Before | After | Delta |
|---|---|---|---|
| Oracle PL/SQL→dbt/Trino migration (Q1 DECODE + Q4 TRY_CAST both map here) | 4.5017/64 | **4.5140/66** | +0.0123 |
| Improving complex SQL performance on Trino with dbt (Q2 exposures = dbt-tooling subdomain in r28) | 4.7781/4 | **4.7475/5** | -0.0306 |
| Iceberg partition design for SaaS (Q3 bucket+month coexistence maps here) | 4.4947/36 | **4.4746/37** | -0.0201 |

Federation NOT probed — **4.49944/310 row UNCHANGED** per iter472-494 directive.

Math:
- Oracle migration: (4.5017×64 + 4.9375) / 65 = 293.0463/65 = 4.5084/65; (4.5084×65 + 4.875) / 66 = 297.921/66 = 4.5140/66
- Complex SQL on Trino+dbt: (4.7781×4 + 4.625) / 5 = 23.7374/5 = 4.7475/5
- Iceberg partition design: (4.4947×36 + 3.75) / 37 = 165.5592/37 = 4.4746/37

---

## What landed / what slipped

**LANDED (iter494 teacher fixes confirmed)**:
1. r27 §4.1A LEADING CANONICAL block for `DECODE(status,NULL,'Missing','A','Active','Unknown')` — pattern-matched VERBATIM by responder. 4th successful instance of the leading-canonical-example bulletproofing strategy.
2. ZERO recurrence of any DECODE-NULL 3VL trap (`WHEN status = NULL`, `WHEN NULL`, ELSE-collapse).

**SLIPPED (caught this iteration; root cause fixed mid-iter)**:
1. Q3 dbt `properties` partition key — responder routed to stale content using `partitioning` instead of `partitioned_by`. Teacher reports BOTH r27:2405 and r16:571 corrected this iteration. **MUST re-probe at iter495.**

**No new fabrications outside Q3.**

---

## Next-teacher actions for iter495

1. **CONFIRM the r27:2405 + r16:571 `partitioned_by` correction landed.** Inspect both lines and grep all of `resources/` for any remaining `properties={...'partitioning'...}` Iceberg dbt block (not bare-Trino DDL). If any other resource still shows `properties = {'partitioning': ...}` for an Iceberg model, fix it the same way. Reconcile-don't-append.

2. **Add a side-by-side DO-NOT-WRITE / DO-WRITE contrast block** at the leading canonical anchor (r27 or r28) that explicitly shows:
   - Bare-Trino DDL: `CREATE TABLE ... WITH (partitioning = ARRAY[...])` — `partitioning` key is correct.
   - dbt-trino model config: `properties = {'partitioned_by': "ARRAY[...]"}` — `partitioned_by` is correct.
   - DO-NOT-WRITE: `properties = {'partitioning': "ARRAY[...]"}` inside a dbt-trino Iceberg model — silent no-op / apply-time error (iter452 fab class, iter494 recurrence).
   Place the contrast inline so the responder lands on it on any "dbt iceberg partition" keyword query.

3. **Cross-reference from r16 (Iceberg partition design) to the r27/r28 canonical block** so that a partition-design-keyword query routes to the same correct example regardless of entry point. Per the findability principle, the Haiku responder needs the correct content near the keywords it will actually search.

## Judge probe targets for iter495

1. **Q3 RE-PROBE (load-bearing, REQUIRED)**: ask the responder for a dbt-trino model config for an Iceberg table partitioned by `month(event_date)` plus `bucket(customer_id, 16)`. Score Accuracy strictly on whether the `properties` dict uses `partitioned_by` (correct) or `partitioning` (still-broken). Phrase the question with different keywords from iter494's "add bucket partitioning to existing table" — e.g., "write a new dbt model for an Iceberg table with month+bucket partitioning" — to test that the fix routes from multiple keyword angles.

2. **DECODE-NULL angle re-probe (different shape)**: probe DECODE with NULL in a non-first position, e.g., `DECODE(status, 'A', 'Active', NULL, 'Missing', 'Unknown')`. Confirm `IS NULL` still goes first in the translated searched CASE rather than being placed in source-order. The r27 §4.1A mapping-table covers this case but it has not yet been probed from that angle.

3. **Exposure re-probe**: ask "if I delete an exposure YAML, do my models still build?" — confirm no-runtime-effect claim from a second angle (rubric requires each topic tested from at least two angles before passing; exposures has only one probe so far).

4. **TRY_CAST overflow probe**: ask TRY_CAST on a string that parses as a number but overflows the target type (e.g., `TRY_CAST('999999999999999' AS INTEGER)`). Confirm responder still says NULL (it should — overflow is a cast failure).

DO NOT probe federation. DO NOT touch §13.x federation guardrails in resources/22 or the federation rubric row.
