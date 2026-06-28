# Iteration 1234 — Judge Feedback

## Verdict

**Overall: 3.5625 — BARELY PASS at threshold.** Q3 is a substantive FAIL (2.125) on the dbt-incremental-merge late-arriving-older-row scenario with TWO compounding errors: (1) factually-wrong claim about Trino MERGE syntax, (2) wrong cross-run solution. Q2 is a borderline-pass (3.0) responder-recall-slip on the well-documented "no expressions inside ROLLUP" rule. Q1 and Q4 are clean.

**FIX-A RECOMMENDATION: YES — LIGHT FIX-A WARRANTED on Q3 (findability + myth-defang).** See §FIX-A SPEC at end.

---

## Per-question scores

### Q1 — Iceberg time travel to wall-clock time (FOR TIMESTAMP AS OF) — 4.375

| Dim | Score | Reasoning |
|---|---|---|
| Acc | 4.0 | Primary answer `FOR TIMESTAMP AS OF TIMESTAMP '2026-06-18 09:00:00'` correct and verified at [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html). Snapshot-closest-not-after semantics correct. 7-day retention caveat correctly raised. **MINOR SLIP — `FOR VERSION AS OF '<snapshot_id>'` aside with snapshot_id QUOTED**: Trino 467 docs show numeric snapshot_id is BIGINT unquoted (`FOR VERSION AS OF 8954597067493422955`); only NAMED tags/branches take quoted strings (`FOR VERSION AS OF 'historical-tag'`). Engineer copying `'<numeric_snapshot_id>'` from $snapshots hits a type mismatch and recovers by removing quotes. Not load-bearing (engineer's actual ask was wall-clock time, not snapshot_id). |
| Clar | 4.5 | Wall-clock-to-snapshot mapping mechanism explained well. |
| App | 4.5 | Engineer arrives at working query for the stated wall-clock-time use case. |
| Compl | 4.5 | Covers TIMESTAMP form + retention caveat + VERSION-AS-OF aside. |

**Routing**: Iceberg table maintenance (matches iter1229/iter1232 routing for time-travel/snapshot questions).

### Q2 — ROLLUP for subtotals + grand total in ONE scan — 3.0

| Dim | Score | Reasoning |
|---|---|---|
| Acc | 2.0 | **CONFIRMED PARSE-TIME BUG**. Responder wrote `GROUP BY ROLLUP(plan_tier, date_trunc('month', billing_date))` — VERIFIED at [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html) (WebFetched this iter): *"Complex grouping operations do not support grouping on expressions composed of input columns. Only column names are allowed."* Trino 467 ROLLUP / CUBE / GROUPING SETS accept COLUMN NAMES (or ordinals) ONLY — `date_trunc('month', billing_date)` IS an expression and will FAIL analysis. Engineer copying the SQL hits a parse error. The fix (pre-compute `date_trunc('month', billing_date) AS billing_month` in a CTE, then `ROLLUP(plan_tier, billing_month)`) is NOT shown. The CASE GROUPING(...) logic itself is technically sound but moot because the query won't run. GROUPING SETS ((plan_tier), ()) aside also uses bare column name — correct. |
| Clar | 4.0 | ROLLUP-vs-GROUPING-SETS distinction taught well; GROUPING() function explained. |
| App | 2.5 | Engineer hits parse error, has to debug the fix from scratch. |
| Compl | 3.5 | Right shape (ROLLUP + GROUPING() + label CASE) for the question, but the exact syntax fails. |

**Classification: RESPONDER RECALL SLIP on well-documented + findable content** — `Trino-complex-grouping-column-names-only` pinned memory + r28 §452/§580/§589 prominently anchor this rule with DO-NOT-COPY `date_trunc(...)` examples and pre-compute-in-CTE-then-ROLLUP-over-name pattern. The keyword chain "ROLLUP + date_trunc + month" should have routed to the disambiguation card; it did not. **NOT a content gap. NO FIX-A** — per `feedback_responder_broken_secondary_alternative.md` family adjacent (responder reached the correct PATTERN at the conceptual level but slipped on the documented Trino-vs-Postgres/Snowflake syntactic constraint). Recall ceiling.

**Routing**: Analytical query patterns on Iceberg+Trino.

### Q3 — dbt incremental merge late-arriving older row — 2.125 (FAIL)

| Dim | Score | Reasoning |
|---|---|---|
| Acc | 1.5 | **TWO COMPOUNDING FACTUAL ERRORS.** |
| Clar | 3.5 | Code shape explained clearly; the conclusions are clearly stated (just wrong). |
| App | 1.5 | Engineer follows advice → target row STILL gets overwritten by older row → silent data corruption in production. |
| Compl | 2.0 | Misses the canonical dbt-trino-native answer (`incremental_predicates`) entirely. |

**Error 1 — FACTUALLY WRONG: "Trino MERGE does NOT support WHEN MATCHED AND condition (Snowflake/Databricks extension)."** VERIFIED at [trino.io/docs/467/sql/merge.html](https://trino.io/docs/467/sql/merge.html) (WebFetched this iter):
- `WHEN MATCHED [ AND condition ] THEN DELETE`
- `WHEN MATCHED [ AND condition ] THEN UPDATE SET ( column = expression [, ...] )`
- `WHEN NOT MATCHED [ AND condition ] THEN INSERT [ column_list ] VALUES (expression, ...)`

Docs explicitly show `WHEN MATCHED AND s.address = 'Centreville' THEN DELETE`. Resource r27 §2171, §2174, §2187 verbatim teach multi-branch `WHEN MATCHED AND s.op='d' THEN DELETE` / `WHEN MATCHED AND s.op IN ('u','c','r') THEN UPDATE SET ...` and explicitly state "Multiple `WHEN MATCHED [AND condition]` branches are supported." The responder propagated the EXACT myth that r13 §5514 flags as "a very common AI-generated mistake" — but the responder ALSO mis-attributed the limitation to TRINO (the r13 warning is about default dbt-compiled MERGE not adding the AND, NOT about Trino MERGE syntax). This is an imported-prior (Snowflake-MERGE-vs-Trino-MERGE) recurrence.

**Error 2 — WRONG CROSS-RUN SOLUTION: pre-dedupe staging via `ROW_NUMBER() PARTITION BY subscription_id ORDER BY updated_at DESC` + `WHERE rn = 1` does NOT solve the asked scenario.** The engineer's stated scenario is a CROSS-RUN ordering bug:
- This run's batch has ONE row for `subscription_id=X` with `updated_at=yesterday` (the late row).
- `rn=1` keeps it (it's the only row for that key in THIS batch).
- The merge's `WHEN MATCHED THEN UPDATE` then unconditionally overwrites the target's `updated_at=this-morning` row with the older `updated_at=yesterday` row.
- Result: target now holds the older data. The "idempotent: only updates if source has a newer updated_at" conclusion is FALSE.

Pre-dedupe ROW_NUMBER solves the WITHIN-BATCH dup case (one batch has two rows for the same key). That is a different problem from what was asked.

**Missing — the correct dbt-trino-native answer is `incremental_predicates`.** VERIFIED at [docs.getdbt.com/docs/build/incremental-strategy](https://docs.getdbt.com/docs/build/incremental-strategy) (WebFetched this iter):
```jinja
{{ config(
    materialized='incremental',
    unique_key='subscription_id',
    incremental_strategy='merge',
    incremental_predicates=[
        "DBT_INTERNAL_DEST.updated_at < DBT_INTERNAL_SOURCE.updated_at"
    ]
) }}
```
dbt-trino adds the listed predicate to the MERGE's ON clause alongside `DBT_INTERNAL_DEST.subscription_id = DBT_INTERNAL_SOURCE.subscription_id`. When the source is OLDER than the dest, the ON clause evaluates FALSE → NOT MATCHED branch. (Caveat: with `unique_key` set, dbt's default `WHEN NOT MATCHED THEN INSERT` would then attempt to insert a duplicate key — this is a known nuance and a reason why some adapters route the predicate to `WHEN MATCHED AND ...` instead. r13 §5529 hedges this with "ON clause (or as additional AND ... predicates depending on adapter version)" — accurate hedge for the dbt-trino case.) This canonical lives at **resources/13-postgres-to-iceberg-ingestion.md §5516-5529** and is NOT anchored or cross-referenced from r27/r28's dbt-merge sections where the question's keywords ("late-arriving older row", "only update if newer", "merge overwrite", "blindly overwrite target") naturally lead.

**Routing**: Improving complex SQL performance on Trino with dbt (matches iter1162 Q4 routing for dbt incremental_strategy questions).

### Q4 — Oracle NVL2 → Trino CASE / IF — 4.75

| Dim | Score | Reasoning |
|---|---|---|
| Acc | 5.0 | Trino 467 has NO NVL2 — verified at [trino.io/docs/467/functions/conditional.html](https://trino.io/docs/467/functions/conditional.html) (conditional functions are CASE / IF / COALESCE / NULLIF / TRY only). `CASE WHEN col IS NOT NULL THEN 'has a value' ELSE 'is null' END` valid. `IF(col IS NOT NULL, 'has a value', 'is null')` valid (Trino IF is 3-arg). NVL → COALESCE mapping correct. NULLIF → NULLIF identity correct. |
| Clar | 4.5 | Mapping table is clean. |
| App | 5.0 | Bulk find-replace regex suggestion is actionable. |
| Compl | 4.5 | Covers both CASE and IF forms; adjacent NVL/NULLIF mappings noted. |

**Routing**: Oracle PL/SQL → dbt+Trino migration.

---

## Direct answers to teacher's three explicit questions

### (1) Is Q2 a recall slip vs content gap?

**RECALL SLIP, not content gap.** Resources cover this rule prominently:
- Pinned memory `reference_trino_complex_grouping_column_names_only.md` explicitly: "GROUPING SETS/CUBE/ROLLUP accept COLUMN NAMES ONLY (no expressions; pre-compute in CTE); plain GROUP BY accepts expressions."
- r28 §452, §580, §589 anchor it with DO-NOT-COPY `date_trunc(...)` examples + the pre-compute-then-ROLLUP-over-bare-name canonical.
- r27 (referenced via r28 cross-link) also defangs the Postgres/Snowflake-allowed-inside-ROLLUP imported prior.

The keyword chain "ROLLUP + date_trunc + month/quarter" should have routed to the disambiguation card; recall didn't reach it. NO content fix needed.

### (2) Is the Q3 Trino-MERGE-conditional claim wrong?

**YES, FACTUALLY WRONG.** Verified at trino.io/docs/467/sql/merge.html — Trino 467 MERGE supports `WHEN MATCHED [ AND condition ] THEN UPDATE SET ...` / `THEN DELETE` and `WHEN NOT MATCHED [ AND condition ] THEN INSERT ...`. Docs example: `WHEN MATCHED AND s.address = 'Centreville' THEN DELETE`. r27 §2171/§2174/§2187 already teach the correct Trino MERGE multi-branch + AND-condition pattern. The responder's misattribution to "Snowflake/Databricks extension" is an imported-prior error (likely confusion between "default dbt-compiled MERGE omits the AND condition" and "Trino MERGE syntax doesn't support the AND condition").

### (3) Is a LIGHT FIX-A warranted for Q3 findability?

**YES — LIGHT FIX-A WARRANTED.** Both sub-issues recur if left:
- The "Trino MERGE doesn't support WHEN MATCHED AND" myth is propagated by Snowflake/Databricks-trained LLMs. This is the 8th instance of an imported-prior assumed-absence error against Trino syntax (after starts_with / to_char / listagg / array_sum / format_number / migrate / LATERAL).
- The "only update if newer" / "late-arriving older row" canonical answer (`incremental_predicates=['DBT_INTERNAL_DEST.x < DBT_INTERNAL_SOURCE.x']`) lives at r13 §5516-5529 but is NOT anchored from the r27/r28 dbt-merge sections where the question's keywords lead.

#### FIX-A SPEC — exactly where to anchor

**Anchor 1 (r27 §4.6 / §6.8 area — dbt-merge canonical):** Add a 5-7 line callout near the existing dbt-incremental-merge CANONICAL (around r27 §6.8 is-incremental WHERE-clause guardrail neighborhood, or §4.6 MERGE section after §2187 "Correct claims preserved" list) with:
- Keyword anchors: "late-arriving older row", "out-of-order updated_at", "merge overwrites newer with older", "only update if source is newer", "guard against stale row overwriting fresh row in incremental merge".
- Load-bearing fact: Trino MERGE syntactically SUPPORTS `WHEN MATCHED AND ... THEN UPDATE` (see r27 §2171 / §2187 — cross-ref); but dbt-compiled MERGE does NOT emit the AND condition by default.
- The dbt-trino-native solution: `incremental_predicates=['DBT_INTERNAL_DEST.updated_at < DBT_INTERNAL_SOURCE.updated_at']` (cross-ref to r13 §5516-5529 for the full canonical).
- DO-NOT-WRITE row: "Trino MERGE doesn't support WHEN MATCHED AND condition — it's Snowflake/Databricks only" — INLINE-MARK WRONG, point at the r27 §2187 list of "Correct claims preserved — Trino-valid".

**Anchor 2 (r28 around line 382 — incremental_predicates partition-pruning lever):** Add a 3-line sibling row next to the existing partition-aligned-merge `incremental_predicates` row noting the second use case: "only-update-if-newer" semantics for late-arriving CDC, with cross-ref to r13 §5516-5529.

**Anchor 3 (r13 §5514 — defang myth more sharply):** The existing CRITICAL warning at r13 §5514 ("a very common AI-generated mistake is to claim dbt compiles `WHEN MATCHED AND s.updated_at > t.updated_at THEN UPDATE SET ...`") is currently dbt-scoped. Add one sentence disambiguating dbt-COMPILED MERGE (doesn't add the AND by default) from TRINO MERGE SYNTAX (supports the AND — see r27 §2171/§2187). This closes the imported-prior loop.

**Watch label**: `iter1234 Trino-MERGE-WHEN-MATCHED-AND-myth + r13-incremental_predicates-only-update-if-newer findability + cross-ref FIX-A`. Re-probe within 4-8 iters under framings like:
- "late-arriving row in dbt incremental, target already has newer, how to guard"
- "dbt merge only update if source is newer"
- "Trino MERGE conditional update — does it support WHEN MATCHED AND"

If the re-probe lands the `incremental_predicates` canonical AND correctly states Trino MERGE supports `WHEN MATCHED AND ...`, watch closes. Same family as iter948 r07 HAVING-trims-memory and iter1226 r17/r21 table_changes-MoR — recurring AI-misconception traced to a resource findability gap.

---

## Patterns this iteration

1. **Imported-prior assumed-absence — 8th instance.** Q3 "Trino MERGE doesn't support WHEN MATCHED AND" follows the same pattern as starts_with / to_char / listagg / array_sum / format_number / migrate / LATERAL — assuming a foreign-looking feature isn't in Trino. This pattern is now systematic enough that the teacher might consider a unified myth-defang index in r27 / r28 (one place LLMs can land that lists "Trino DOES have X — Snowflake/Databricks prior is wrong").
2. **Complex-grouping expression-allowed prior — recurrence.** Q2 echoes the `Trino-complex-grouping-column-names-only` pinned memory error. Recall ceiling on findable content.
3. **Cross-run vs within-batch dedup confusion (Q3).** Pre-dedupe-to-rn=1 is a common LLM auto-pilot answer that DOESN'T address the cross-run late-arriving-older-row scenario. This is a NEW responder-pattern note — worth tracking if recurs.
4. Q1 minor `FOR VERSION AS OF '<snapshot_id>'` quoted-string slip is a recall ceiling (not load-bearing for the wall-clock question), passive monitor only.

---

## Rubric topic updates this iteration

| Topic | Prior | Q | Score | New |
|---|---|---|---|---|
| Iceberg table maintenance | 4.4393/229 | Q1 | 4.375 | 4.4391/230 (-0.0002) |
| Analytical query patterns on Iceberg+Trino | 4.5715/166 | Q2 | 3.0 | 4.5621/167 (-0.0094) |
| Improving complex SQL performance on Trino with dbt | 4.5478/53 | Q3 | 2.125 | 4.5029/54 (-0.0449) |
| Oracle PL/SQL → dbt+Trino migration | 4.4600/199 | Q4 | 4.75 | 4.4615/200 (+0.0015) |

All topics still PASS healthy margins. Overall iter1234 avg = **3.5625 PASS at threshold** (would have been ~4.5+ without Q3).
