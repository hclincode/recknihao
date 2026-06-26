# Iter1112 Feedback — 3.89 PASS — Q1 RECURRENCE NEGATIVE (NO-OP on r28), Q4 r09 dbt-snapshot bail RECURRED (2nd of 4) → LIGHT FIX-A r27/r28 signpost to r09

**Iter average:** (4.875 + 4.125 + 4.9375 + 1.625) / 4 = **3.890625 PASS** (margin +0.39 over 3.5 threshold).

Topics touched: complex-SQL-perf-Trino-dbt (Q1), SQL-best-practices-OLAP (Q2+Q3), dbt-snapshots-SCD2 (Q4). ALL required topics REMAIN PASSED after this iter. dbt-snapshots-SCD2 takes the deepest drag (-0.194) from Q4 1.625 bail but stays at 3.957/13 (+0.46 margin above 3.5).

---

## Per-question scoring

### Q1 — dbt incremental dedup (RE-PROBE of iter1111 omission) — current_account_state, one row per account_id, what config + SQL?

**Responder gave:** `materialized='incremental'` + **`incremental_strategy='merge'`** + **`unique_key='account_id'`** + a ROW_NUMBER() pre-dedup CTE (`PARTITION BY account_id ORDER BY state_changed_at DESC`, filtered `WHERE rn=1`) + `is_incremental()` lookback against `(SELECT MAX(state_changed_at) FROM {{ this }})`. Explicitly noted that Trino MERGE errors if source has multiple rows per unique_key, so the pre-dedup is required.

**Verification:**
- `incremental_strategy='merge'` is a valid dbt-trino strategy per [docs.getdbt.com/reference/resource-configs/trino-configs](https://docs.getdbt.com/reference/resource-configs/trino-configs) — confirmed.
- Trino MERGE source-side dedup requirement verified vs RAW [trino.io/docs/current/sql/merge.html](https://trino.io/docs/current/sql/merge.html): *"The query fails if a single target table row matches more than one source row."* Trino raises `MERGE_TARGET_ROW_MULTIPLE_MATCHES` (per [supporting-merge.html](https://trino.io/docs/current/develop/supporting-merge.html): MarkDistinct node + AssignUniqueId node detect the violation). Pre-dedup of source on `unique_key` is the canonical fix. Responder's framing is correct.
- ROW_NUMBER() partition-by-account_id ORDER BY state_changed_at DESC, filter `rn=1` is the standard latest-per-key idiom (canonical in r28 §6.8 and r07).
- `is_incremental()` lookback bootstrapped with COALESCE(MAX, sentinel) is the r28 §139-150 canonical block.

| Dimension | Score | Reasoning |
|---|---|---|
| Accuracy | 5.0 | All four config keys correct; Trino MERGE constraint accurately characterized; pre-dedup CTE syntactically valid Trino 467. |
| Clarity | 4.75 | Step-by-step: strategy → unique_key → pre-dedup CTE → lookback. Beginner-readable. |
| Applicability | 5.0 | Directly copy-pasteable into the engineer's dbt model. |
| Completeness | 4.75 | Hits all three pieces the iter1111 omission missed (merge + unique_key + pre-dedup). Tiny shave: did not mention `partitioning = ARRAY['day(state_changed_at)']` for source-CTE scan reduction, but dedup-correctness was the ask. |
| **Q1 score** | **4.875** | |

**Q1 RECURRENCE VERDICT — NEGATIVE.** Iter1111's "incremental WITHOUT merge+unique_key" omission was a per-instance Haiku slip. Re-probe on a fresh domain (latest-per-account_id state vs last-iter's latest-per-user_id event window) gave a clean, complete answer. **NO resource fix.** Per `feedback_synthesis_ceiling_stop_churning`, do NOT escalate to a r28 top-of-file STEP-0 "incremental dedup requires merge+unique_key" router — the canonical correct form is already at 5 locations in r28 and the responder retrieved it cleanly when the question shape varied. **NO-OP on the iter1111-driven r28 STEP-0 candidate; close that watch.**

---

### Q2 — April-not-May churn: cleaner set-subtraction than LEFT JOIN ... IS NULL, is it faster?

**Responder gave:** `SELECT account_id FROM events WHERE April-range EXCEPT SELECT account_id FROM events WHERE May-range`. Framed as "syntax sugar, internally compiles to a LEFT JOIN + NULL filter, same shape, readability not speed; real perf lever is partition pruning on occurred_at."

**Verification (RAW [trino.io/docs/current/sql/select.html](https://trino.io/docs/current/sql/select.html) via WebFetch):**
- `EXCEPT` defaults to `EXCEPT DISTINCT` in Trino 467 — output is DISTINCT by default. `EXCEPT ALL` preserves duplicates if asked.
- The "compiles to a LEFT JOIN + NULL filter" claim is an oversimplification — Trino implements EXCEPT as a hash-based set operation (right side hash-built, left side probes with mark-distinct), and the EXCEPT DISTINCT default **deduplicates output**, which a literal LEFT JOIN ... IS NULL **does not** (LEFT JOIN preserves left-side duplicates; engineer would need `SELECT DISTINCT account_id` on top to match EXCEPT semantics).
- For the engineer's actual ask (distinct churned account_ids), EXCEPT is genuinely the right tool — MORE than syntax sugar because of the implicit DISTINCT. The "readability not speed" framing understates this.
- The partition-pruning-on-occurred_at point is correct and valuable — that IS the real lever for this query shape.

| Dimension | Score | Reasoning |
|---|---|---|
| Accuracy | 3.75 | EXCEPT recommendation correct; "syntax sugar, same as LEFT JOIN + NULL" is misleading because EXCEPT DISTINCT semantically deduplicates (LEFT JOIN does not). Partition-pruning insight correct. |
| Clarity | 4.5 | Clear SQL example with both date ranges; readable. |
| Applicability | 4.5 | Engineer can copy the EXCEPT and add partition predicates as advised. |
| Completeness | 3.75 | Missed the load-bearing DISTINCT-semantics nuance; did not explain that LEFT JOIN ... IS NULL needs an extra DISTINCT/GROUP BY to match EXCEPT output. Did not show EXCEPT ALL contrast. |
| **Q2 score** | **4.125** | |

**Q2 framing defect class:** matches `feedback_responder_overwarning_folklore` weakly (over-deflationary "it's just syntax sugar" framing where the construct actually has different semantics from the suggested equivalent). NOT a recurring resource defect — grep audit of r23/r07 shows EXCEPT canonical is correctly framed in resources. Pure per-instance Haiku framing artifact. **NO resource fix.**

---

### Q3 — GREATEST(trial_end_date, subscription_start_date), trial_end_date sometimes NULL; does Trino skip NULLs like Postgres?

**Responder gave:** Trino returns NULL if ANY arg is NULL (Postgres is the outlier; Oracle/MySQL/BigQuery also NULL-if-any-NULL like Trino). Fix = COALESCE each arg (sentinel DATE '1970-01-01' for GREATEST) OR a 2-arg CASE for non-null pick.

**Verification (RAW [trino.io/docs/current/functions/comparison.html](https://trino.io/docs/current/functions/comparison.html) via WebFetch):** *"Like most other functions in Trino, they return null if any argument is null. Note that in some other databases, such as PostgreSQL, they only return null if all arguments are null."* — Responder's framing is verbatim correct on both the Trino semantic AND the Postgres-outlier characterization. Memory pin `reference_trino_greatest_least_null` re-confirmed.

| Dimension | Score | Reasoning |
|---|---|---|
| Accuracy | 5.0 | Trino semantic correct; Postgres-outlier correctly attributed; COALESCE sentinel pattern correct; 2-arg CASE alternative correct. |
| Clarity | 5.0 | Two-line answer + two fixes with concrete sentinel value. |
| Applicability | 5.0 | Direct paste-ready fix for the engineer's Trino expression. |
| Completeness | 4.75 | Could briefly mention LEAST has the same NULL semantics (the pair); otherwise fully addresses. |
| **Q3 score** | **4.9375** | |

---

### Q4 — dbt snapshot: what it creates + how to query plan as of March 15 (BAILED — findability miss on r09)

**Responder gave:** "I don't have sufficient information in the resources to answer this. dbt snapshots are not covered in the available resources." Pointed to external dbt docs.

**This is FALSE — the canonical IS in r09.** Grep audit of `resources/09-lakehouse-schema-design.md`:
- L350-510 has the full "Option 1 — dbt snapshot (recommended for teams already using dbt)" block.
- L450-455 lists the **four always-present meta columns** verbatim: `dbt_scd_id` / `dbt_updated_at` / `dbt_valid_from` / `dbt_valid_to` — exactly what "what does a snapshot create?" needs.
- L461-466 has the **point-in-time as-of-date query** verbatim:
  ```sql
  SELECT * FROM analytics.users_snapshot
  WHERE dbt_valid_from <= TIMESTAMP '2025-08-10 12:00:00'
    AND (dbt_valid_to IS NULL OR dbt_valid_to > TIMESTAMP '2025-08-10 12:00:00');
  ```
  Substituting `'2026-03-15 00:00:00'` for the engineer's "March 15" trivially answers Q4 in full.
- L357-363 explains `strategy='timestamp'` vs `strategy='check'` (required `updated_at` vs required `check_cols`).
- L473+ has the `hard_deletes` block.

**Responder DID find and use this exact block successfully in:**
- iter1099 Q3 (dbt-snapshots SCD2 as-of-date) — passed
- iter1102 Q2 (dbt-snapshots hard-deletes routing) — passed

**Responder BAILED on dbt-snapshot questions in:**
- iter1100 Q3 (dbt-snapshots hard-deletes)
- **iter1112 Q4** (dbt snapshot basics + as-of-date) — this iter

| Dimension | Score | Reasoning |
|---|---|---|
| Accuracy | 1.5 | Did not produce any of the meta-column names or the canonical point-in-time query, both of which are in r09. Pointing to dbt docs is honest but the in-resource canonical was missed. |
| Clarity | 2.5 | Clearly admits insufficient info; clean bail. |
| Applicability | 1.5 | Engineer has to leave the responder entirely and read external dbt docs to act. |
| Completeness | 1.0 | Question NOT answered — bailed on both halves (what a snapshot creates AND the as-of-date query). |
| **Q4 score** | **1.625** | |

---

## Q4 FINDABILITY VERDICT — LIGHT FIX-A RECOMMENDED (a, not b)

The dbt-snapshot canonical is durably in `r09 §"Option 1 — dbt snapshot"` (L350-510) and the responder has now hit-2 / miss-2 on it across iters 1099/1100/1102/1112 — **borderline findable**.

**Root cause of the routing miss:** `r09` is named `09-lakehouse-schema-design.md`, and the snapshot block sits BELOW a "Slowly Changing Dimensions" subsection header. A pure "dbt has a snapshot, what does it create + query as-of-date" question carries **dbt-snapshot keywords** that route Haiku to dbt-centric files first — namely `r27-oracle-plsql-to-dbt-trino.md` and `r28-complex-sql-performance-trino-dbt.md`. Both r27 and r28 have many uses of the word "snapshot" but they ALL refer to Iceberg snapshots (`$snapshots` metadata table, `expire_snapshots`, "snapshot replaces prior data atomically" framing — verified via grep). When Haiku scans for "dbt snapshot" keywords, r27/r28 supply many false-positive hits without ever pointing to r09 §SCD2.

**Verdict choice (a) findability FIX-A vs (b) Haiku non-determinism NO-OP:**
- (a) supported by: 50% miss rate (2/4) on a question type that has clear in-resource content; non-deterministic Haiku alone would suggest a higher hit rate when content is canonical; the keyword-routing trap (r27/r28 "snapshot" hits flooding the dbt-snapshot anchor) is a structural findability problem, not a randomness problem.
- (b) supported by: topic still passes (3.957/13 above 3.5), and the synthesis-ceiling memo cautions against churning.

**RECOMMENDATION: (a) LIGHT FIX-A — additive forward-pointer signposts ONLY, no content rewrite.**

### Specific teacher FIX-A guidance (do NOT rewrite r09):

1. **r27 (Oracle PL/SQL → dbt + Trino) — add a top-level keyword-anchored signpost.** Near r27's dbt mechanics overview / TOC (not buried deep), add a one-liner:

   > **dbt snapshots (SCD2) — what dbt snapshots create + as-of-date queries:** see [resource 09 §"Option 1 — dbt snapshot"](09-lakehouse-schema-design.md). Keyword anchors: `dbt snapshot`, `SCD2`, `slowly changing dimension type 2`, `dbt_scd_id`, `dbt_updated_at`, `dbt_valid_from`, `dbt_valid_to`, `point-in-time as-of-date query`, `strategy='timestamp'`, `strategy='check'`, `check_cols`, `hard_deletes`, `dbt_is_deleted`. Note: every other "snapshot" reference in r27 is an **Iceberg** snapshot (different concept) — for the **dbt snapshot mechanism**, go to r09.

2. **r28 (Improving complex-SQL perf on Trino with dbt) — add the same forward-pointer.** Same keyword anchors, same one-liner pointing to r09 §"Option 1 — dbt snapshot." Place it near r28's dbt-mechanics overview / materializations discussion (not in the Iceberg-snapshot diagnostic sections where "snapshot" is the wrong concept).

3. **r09 — hoist a top-level keyword-anchored signpost at the file head** (so Haiku that DOES land in r09 finds the snapshot block without scanning past unrelated star-schema/dim/fact content). A one-liner at r09's top:

   > **dbt snapshots (SCD2 / as-of-date history) live in §"Option 1 — dbt snapshot" at L350+** with keyword anchors: dbt snapshot, SCD2, slowly changing dimension type 2, point-in-time query, as-of-date query, plan history with effective dates, history table, dbt_scd_id, dbt_updated_at, dbt_valid_from, dbt_valid_to, strategy=timestamp, strategy=check, check_cols, hard_deletes.

**Do NOT:**
- Re-write or duplicate the L350-510 canonical content elsewhere.
- Add a new "dbt snapshot" landing file (would create a finder-vs-content split).
- Touch r09's "Option 1 — dbt snapshot" block content itself — the canonical is correct.

**Re-probe plan:** next 2 iters, ask a dbt-snapshot question from at least 2 different angles (basics+as-of-date AND a different angle like strategy=timestamp-vs-check decision OR snapshot-on-deletes). If the FIX-A reaches, the responder produces the four meta cols + the point-in-time query without bailing. If the bail recurs after FIX-A, escalate to hoisting the L450-466 worked-example block as a top-of-r09 `COPY THIS` card.

---

## Q2 nuance shave — addressable but NO resource fix

Responder's "EXCEPT is syntax sugar that compiles to a LEFT JOIN + NULL filter" framing is technically misleading because EXCEPT defaults to DISTINCT semantics (LEFT JOIN does not). For the engineer's churn use case (distinct churned account_ids) EXCEPT IS strictly better than LEFT JOIN ... IS NULL. The framing was over-deflationary. **NOT a resource defect** — grep audit of r23 and r07 shows EXCEPT canonical is correctly framed with the DISTINCT-by-default semantic. Pure per-instance Haiku framing artifact, matches `feedback_responder_overwarning_folklore` family weakly. **NO resource fix.**

---

## Score table

| Question | Accuracy | Clarity | Applicability | Completeness | Q avg |
|---|---|---|---|---|---|
| Q1 dbt incremental dedup (merge+unique_key+ROW_NUMBER pre-dedup) | 5.0 | 4.75 | 5.0 | 4.75 | **4.875** |
| Q2 EXCEPT vs LEFT JOIN ... IS NULL for churn | 3.75 | 4.5 | 4.5 | 3.75 | **4.125** |
| Q3 GREATEST NULL semantics (Trino vs Postgres) | 5.0 | 5.0 | 5.0 | 4.75 | **4.9375** |
| Q4 dbt snapshot (BAILED — findability miss on r09) | 1.5 | 2.5 | 1.5 | 1.0 | **1.625** |
| **Iter average** | **3.8125** | **4.1875** | **4.0** | **3.5625** | **3.890625** |

PASS (margin +0.39). No imported-prior issues. No ::/QUALIFY/false-semi-join/fabricated-fn/regex-backslash/INTERVAL-quarter-week/OFFSET-before-LIMIT/CAST-truncate/EXECUTE-rollback-on-467/Spark-Oracle-spillover. One per-instance framing artifact (Q2 "syntax sugar" over-deflation) + one findability miss (Q4 r09 dbt-snapshot bail, 2nd of 4 attempts).

---

## Topic rubric updates

- Improving-complex-SQL-perf-Trino-dbt 4.5560 / 21 → (95.676 + 4.875) / 22 = **4.5694 / 22 PASSED** (+0.0134)
- SQL-best-practices-OLAP 4.4893 / 165 → (740.7345 + 4.125 + 4.9375) / 167 = **4.4898 / 167 PASSED** (+0.0005)
- dbt-snapshots-SCD2 4.1513 / 12 → (49.8156 + 1.625) / 13 = **3.9570 / 13 PASSED** (-0.1943, margin to 3.5 narrows to +0.457; second-thinnest after storage-tiering 3.5625/6 +0.0625)

ALL required topics REMAIN PASSED. dbt-snapshots-SCD2 is now the **second-thinnest** passing margin (+0.457) and a recurring bail risk — the FIX-A above is targeted at preventing further drag from this row.

---

## Recommendation summary

1. **TEACHER LIGHT FIX-A** on `r27` + `r28` (forward-pointer signposts to r09 §"Option 1 — dbt snapshot") + top-of-r09 keyword-anchored signpost. Additive only, ~3 short blocks total, no rewrite of L350-510.
2. **NO Q1 RECURRENCE FIX** — iter1111 omission did not recur; per-instance verdict confirmed.
3. **NO Q2 FIX** — over-deflationary framing artifact, no resource source.
4. **NO Q3 FIX** — clean.
5. **State.json:** advance iteration counter; preserve `phase: extended`, `passed: true`, `final_iterations_remaining: 0`.
6. **Next-sweep probes:** dbt-snapshot question from 2 different angles (basics + non-as-of-date angle like strategy=timestamp-vs-check or hard_deletes-on-delete-tracking) to confirm FIX-A reach. Continue storage-tiering 7th datapoint (3.5625/6 still thinnest passing), federation 313th probe ONLY on bulletproofed angles (4.50244/312 fragile-PASS).

Pattern observation: the iter1100→1102 hoist-affirmative-above-negative-framing FIX-A worked durably for the r09 hard-deletes anchor; the same pattern (additive top-of-file keyword signposts) is the lowest-risk lever for closing the r27/r28→r09 cross-file findability gap. Avoid content duplication; the canonical at r09 L350-510 is correct and durable.
