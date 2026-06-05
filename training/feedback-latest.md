# Iter 513 — Judge Feedback (extended phase)

**Overall: 4.336 PASS** (+0.836 above 3.5 floor). 112th consecutive overall PASS in extended phase. **Margin slightly above iter512's +0.734 — the Q1 DECIMAL-SUM fix LANDED and absorbed cleanly, but Q4 introduced a NEW load-bearing inverted-semantics error that drops a single answer below the 3.5 threshold.**

---

## Per-question scoring

### Q1 — DECIMAL-SUM re-probe (DECIMAL(8,2) revenue over ~2B rows) — **4.969 STRONG PASS**

| Dim | Score |
|---|---|
| Technical accuracy | 5.0 |
| Beginner clarity | 5.0 |
| Practical applicability | 5.0 |
| Completeness | 4.875 |

**ITER513 PRIMARY FIX LANDED — DECIMAL-SUM CANONICAL CONFIRMED.** Verified against trino.io/docs/current/functions/aggregate.html ("sum(decimal(p, s)) returns decimal(38, s)"), trino.io/docs/current/language/types.html (max precision 38), and trinodb/trino #20227 (overflow raises NUMERIC_VALUE_OUT_OF_RANGE; older versions surfaced an "internal error" but never silent truncation):

- "You do NOT need the cast" — CORRECT
- "Trino auto-widens `sum(decimal(8,2)) -> decimal(38,2)`" — CORRECT (matches docs verbatim)
- "2B rows × max ~1e6 per row = ~2e15, well under 1e38" — CORRECT (DECIMAL(8,2) max is 999,999.99 ~ 1e6, x 2e9 rows = 2e15 ~ 16 digits, fits with 22 digits of headroom)
- "Does NOT silently truncate/round; overflow raises NUMERIC_VALUE_OUT_OF_RANGE hard error" — CORRECT (per #20227 + Trino aggregate code path)
- Troubleshooting checklist for "too small" SUM (WHERE filter, JOIN drop/fan, upstream CAST scale truncation, NULL-heavy column + SUM skips NULLs, integer division upstream) — all 5 causes match the iter513 teacher canonical (r23 §3.1B)
- Calling the cast advice "folklore from cloud-warehouse migration guides" — rhetorically strong; technically accurate (Snowflake/BigQuery DO have different auto-widening behavior, so the folklore origin is plausible)

**The iter513 r23 §3.1B reconcile-in-place LANDED on FIRST re-probe — 23rd consecutive leading-canonical bulletproofing landing instance.** Iter512 Q2's "Trino does NOT auto-widen / truncates silently / need SUM(CAST(... AS DECIMAL(38,2)))" trifecta-fabrication is GONE.

-0.125 Completeness for no explicit pre-emption of the avg(decimal) sister-case (`avg(decimal(p,s)) -> decimal(38,s)` per same doc page) and no quote of the actual error-message text — non-load-bearing.

---

### Q2 — COALESCE(preferred_name, legal_name, username) — **4.938 STRONG PASS**

| Dim | Score |
|---|---|
| Technical accuracy | 5.0 |
| Beginner clarity | 5.0 |
| Practical applicability | 5.0 |
| Completeness | 4.75 |

Clean against trino.io/docs/current/functions/conditional.html verbatim ("returns the first non-null value... arguments are only evaluated if necessary" -> short-circuit). Left-to-right first-non-null semantics correct, same as Postgres correct, no false-gotchas invented.

-0.25 Completeness for no callout that all COALESCE arguments must be coercible to a common supertype (e.g., `COALESCE(varchar, int)` would fail type resolution) and no callout that `COALESCE(NULL, NULL, NULL)` returns NULL (the all-null edge case). Non-load-bearing.

---

### Q3 — Iceberg $history vs $snapshots — **4.000 PASS (two real defects)**

| Dim | Score |
|---|---|
| Technical accuracy | 3.5 |
| Beginner clarity | 4.5 |
| Practical applicability | 4.0 |
| Completeness | 4.0 |

**TWO REAL NITS verified against trino.io/docs/current/connector/iceberg.html and iceberg.apache.org/spec:**

**Nit (i) — $snapshots operation values list is INCOMPLETE + MERGE->'replace' mapping is WRONG.** Per the Iceberg spec (section "Snapshots -> operation"), the four canonical operation values are: `append`, `replace`, `overwrite`, `delete`. The responder lists only `append, replace, delete` — **`overwrite` is MISSING**. Worse, the responder claims "MERGE shows as operation='replace'" — this is BACKWARDS:

- `append` = INSERT INTO (new files added, no files removed)
- `overwrite` = MERGE INTO / UPDATE / DELETE-with-row-filter / INSERT OVERWRITE (data files rewritten; affected rows replaced via copy-on-write or merge-on-read). **THIS is where MERGE lands.**
- `replace` = compaction / `REPLACE TABLE AS` / OPTIMIZE / rewrite_data_files (files rewritten with identical logical content)
- `delete` = pure file removals (e.g., DELETE that matches whole partitions -> metadata-only delete)

An engineer reading the answer and grepping `WHERE operation = 'replace'` looking for the corrupting MERGE will find ONLY compaction snapshots, miss the actual MERGE, and target the wrong snapshot for rollback. Load-bearing mis-routing on a who-corrupted-the-table question.

**Nit (ii) — "audit WHO DID WHAT" overstates $snapshots's coverage.** $snapshots columns are `committed_at`, `snapshot_id`, `parent_id`, `operation`, `manifest_list`, `summary`. **There is NO user/principal column.** The `summary` map MAY contain engine-set fields like `trino_query_id`, `added-data-files`, `total-records`, but not a SQL user identity. The honest answer is: $snapshots tells you WHAT (operation) and WHEN (committed_at), maybe HOW MUCH (summary counts), but NOT WHO — for WHO you need Trino query-log correlation via `summary['trino_query_id']` joined to your query history. The "audit WHO DID WHAT and WHEN" framing reads to a beginner as if $snapshots is a full audit table, which it isn't.

**What was CORRECT and good:**
- Whole-token quoting `"events$snapshots"` — VERIFIED CORRECT (split-quote `"events"$snapshots` and bare-dollar `events$snapshots` both fail to parse; iter509 r17 canonical holds)
- $snapshots is one-row-per-snapshot — correct
- $history is linearized current-ancestry with `made_current_at`/`parent_id`/`is_current_ancestor`/`snapshot_id` — correct routing target for time-travel / `FOR VERSION AS OF`
- "use $snapshots for who-wrote-when-and-what" routing — correct (modulo the operation-values nit above)
- "find snapshot by timestamp window" query pattern — correct

-1.5 Accuracy split: -1.0 for the `MERGE -> operation='replace'` inversion (load-bearing mis-routing), -0.5 for the missing `overwrite` value. -0.5 Clarity for not defining `summary` as a MAP nor explaining the trino_query_id correlation path. -1.0 Applicability for the wrong rollback-target if engineer searches by operation. -1.0 Completeness for the missing `overwrite` + missing "no user column, correlate via summary['trino_query_id']" callout.

---

### Q4 — dbt model tags + reference in dbt build — **3.4375 sub-threshold INDIVIDUAL FAIL**

| Dim | Score |
|---|---|
| Technical accuracy | 2.5 |
| Beginner clarity | 4.5 |
| Practical applicability | 2.75 |
| Completeness | 4.0 |

**CRITICAL LOAD-BEARING INVERSION.** Verified against docs.getdbt.com/reference/node-selection/set-operators verbatim:

> "Commas with no spaces within an argument define an intersection, and a space between arguments combines their results as a union."
>
> Example: `dbt run --select "tag:a,tag:b"` selects resources with BOTH tag:a AND tag:b (intersection / AND).
> Example: `dbt run --select "tag:a tag:b"` selects resources with EITHER tag:a OR tag:b (union / OR).

**The responder's answer is BACKWARDS:**
- Claims `dbt build --select tag:nightly_heavy,tag:realtime_light` = "OR logic" -> **FALSE**, that comma is AND (intersection), and will return ONLY models tagged with BOTH `nightly_heavy` AND `realtime_light`. For real production models that's typically the **empty set** — engineer's nightly CronJob runs 0 models, on-call gets paged the next morning when the BI dashboard is stale.
- For OR (the "give me everything tagged nightly_heavy OR realtime_light" intent the responder describes), the correct syntax is **space-separated**: `dbt build --select "tag:nightly_heavy tag:realtime_light"` (quoted because shells split on spaces).

**Correct rule the teacher must canonicalize:**

| Operator | Meaning | Example | Result |
|---|---|---|---|
| `,` (comma, no space) | **INTERSECTION (AND)** | `tag:a,tag:b` | models with BOTH tag:a AND tag:b |
| ` ` (space-separated args) | **UNION (OR)** | `"tag:a tag:b"` | models with EITHER tag:a OR tag:b |
| Combined | comma-within-arg AND, space-between-args OR | `"tag:a,tag:b tag:c"` | (tag:a AND tag:b) OR tag:c |

**What was CORRECT and good:**
- `config(tags=['nightly_heavy'])` in-model config block — correct per docs.getdbt.com/reference/resource-configs/tags
- Multiple tags as list `tags=['a', 'b']` — correct
- `dbt build --select tag:nightly_heavy` single-tag selector — correct
- Folder-level / path-level tags via `dbt_project.yml` `models:` block — correct
- k8s CronJob example shape — correct (separate CronJobs per tag is one valid way to avoid the comma-vs-space pitfall by accident)

**Severity:** Inverted-semantics error on the EXACT command the question asked about. An engineer copy-pasting the comma form into their CronJob ships a broken pipeline. Same failure-class as past Trino-syntax inversions (Spark-only-form-as-Trino-syntax, INTERSECT=anti-join mislabel). -2.5 Accuracy. -2.25 Applicability (the actionable command is wrong). -0.5 Clarity (no symbolic table makes the inversion harder to catch). -1.0 Completeness (no callout that shells split on spaces so quoting is required for the OR form; no callout that combined `comma+space` evaluates intersection-first-then-union).

**Q4 is sub-threshold individually (3.4375 < 3.5) but absorbed at the iter-wide level by Q1/Q2/Q3.**

---

## EXPLICIT confirmations the user asked for

- **Q1 DECIMAL-SUM canonical (iter513 r23 §3.1B): LANDED.** Responder now correctly says NO cast needed, `sum(decimal(p,s))` auto-widens to `decimal(38, s)`, overflow ERRORS as NUMERIC_VALUE_OUT_OF_RANGE not silent truncation, and gives the real "too small" causes (WHERE filter, JOIN drop/fan, upstream CAST scale, NULL-heavy column, integer division upstream). 23rd consecutive leading-canonical bulletproofing landing. The iter512 Q2 "does not widen / truncates silently / need CAST to DECIMAL(38,2)" trifecta-fabrication is GONE.
- **Q1 SemiJoin FilterMode=ANTI fabrication (iter512 Q1): NOT RE-PROBED THIS ITER.** Iter513 Q1 was DECIMAL-SUM not INTERSECT/EXCEPT plan-node, so the iter512 r23 §10 SemiJoin reconcile-in-place edits (lines 458, 459, 535, 571, 583, 584, 780) and r27 §4.5 EXPLAIN-rendering sub-note remain UNEXERCISED. The fabricated annotation could still resurface on the next plan-node probe — recommend keeping it on the iter514 probe-target list at MEDIUM.
- **Q4 dbt --select comma-vs-space inversion: NEW ITER513 LOAD-BEARING ERROR.** Correct rule (re-stated for the teacher): COMMA `,` = INTERSECTION (AND, both tags); SPACE ` ` between quoted args = UNION (OR, either tag). Responder said comma = OR — backwards.
- **Q3 $snapshots: TWO nits.** Operation-values set is incomplete (missing `overwrite`); MERGE-to-operation mapping is wrong (MERGE -> `overwrite`, NOT `replace`; `replace` is compaction); "audit WHO" overstates because $snapshots has no user/principal column (summary map may carry engine query_id, not a SQL user).
- **Federation row 4.49944/310 UNCHANGED.** Federation NOT probed this iter (per iter472-513 directive). No edits to resources/22 §13.x.

---

## Other fabrications / risks

- Q3 "operation values" enumeration is the only enumeration risk this iter. The responder confidently listed three values when the spec defines four — this is a sibling failure-class to the iter512 `FilterMode = ANTI` fabrication: confident-but-incomplete enumeration of an externally-defined value set. Recommend teacher add an explicit DO-NOT-WRITE row banning the 3-value list and the MERGE->replace mapping in the same canonical block.
- Q4 inversion is the same failure-class as iter408 `rewrite_data_files(sort_order =>)` Spark-as-Trino-syntax slip and iter511 INTERSECT=anti-join mislabel: confident-but-inverted directional semantics on a 2-element set. Teacher canonical must include a symbolic table (comma vs space) AND a concrete "engineer-pastes-this-CronJob" worked example to anchor the routing.

---

## Concrete next-teacher actions for iter514

**PRIMARY (HIGH) — dbt --select set-operator canonical reconcile-in-place.** Land a tight canonical in r27 (likely §6.7C or new §6.7F, near existing dbt-build / tag-selector content). Required contents:
1. ONE-LINE RULE: `tag:a,tag:b` = INTERSECTION (AND); `"tag:a tag:b"` = UNION (OR). Comma binds tighter than space.
2. SYMBOLIC TABLE with 4 rows: single tag / comma-separated / space-separated / mixed-precedence.
3. WORKED EXAMPLE: nightly CronJob — `dbt build --select "tag:nightly_heavy tag:realtime_light"` (note the quotes — shell splits on space otherwise) produces "models tagged with EITHER nightly_heavy OR realtime_light"; `dbt build --select tag:nightly_heavy,tag:realtime_light` produces "models tagged with BOTH" (almost always empty set in real projects).
4. DO-NOT-WRITE: "comma = OR"; "tag:a,tag:b = either tag"; "space = AND". (Bans the iter513 Q4 trifecta-inversion verbatim.)
5. Verified source: docs.getdbt.com/reference/node-selection/set-operators + /reference/node-selection/syntax.
6. Keyword anchors: dbt select multiple tags, dbt tag OR, dbt tag AND, dbt comma vs space, dbt build multiple tags, dbt CronJob multiple tags.

**SECONDARY (HIGH) — Iceberg $snapshots operation canonical reconcile-in-place.** In r17 (Iceberg metadata) at the existing $snapshots section. Required contents:
1. The FOUR canonical values: `append` / `replace` / `overwrite` / `delete`. Spell out which SQL op maps to which:
   - `append` = INSERT INTO, CTAS into existing table
   - `overwrite` = MERGE INTO, UPDATE, DELETE-with-row-filter, INSERT OVERWRITE (copy-on-write rewrites of affected files)
   - `replace` = OPTIMIZE / compaction / rewrite_data_files / REPLACE TABLE (logical content unchanged, files rewritten)
   - `delete` = whole-partition DELETE (metadata-only file removals)
2. Explicit "MERGE shows as operation='overwrite', NOT 'replace'" routing rule.
3. WHO/WHAT/WHEN scope statement: $snapshots tells you WHAT + WHEN + HOW MUCH (summary counts), NOT WHO. For WHO, join `summary['trino_query_id']` to Trino's query-log/event-listener output.
4. DO-NOT-WRITE: "operations are append, replace, delete" (3-value enumeration); "MERGE shows as operation='replace'"; "$snapshots tells you who ran the query".
5. Verified sources: iceberg.apache.org/spec/#snapshots, trino.io/docs/current/connector/iceberg.html ($snapshots metadata table section).

**TERTIARY (MEDIUM) — keep iter512 SemiJoin EXPLAIN-rendering reconcile-in-place edits unexercised-but-armed.** No additional action; just ensure iter514 probe targets include a plan-node re-probe so the bulletproofing gets exercised.

---

## Iter514 judge probe targets

| Priority | Probe | Verifies |
|---|---|---|
| **HIGH** | dbt comma-vs-space RE-PROBE: "I want my CronJob to run models tagged `nightly_heavy` OR `realtime_light` — is `dbt build --select tag:nightly_heavy,tag:realtime_light` right?" | Whether iter514 teacher r27 set-operator canonical LANDS — verifies the comma=AND, space=OR fix. **MUST RE-PROBE — this is the iter513 primary fix target for iter514.** |
| **HIGH** | $snapshots operation values RE-PROBE: "what does `operation` look like for a MERGE INTO statement? I want to find the snapshot from a corrupting MERGE." | Whether iter514 teacher r17 four-value operation canonical LANDS — verifies MERGE->overwrite mapping fix. |
| **MEDIUM** | $snapshots WHO 2nd angle: "I want to know which user/team ran the corrupting MERGE — does $snapshots have a user column?" | Verifies "no user column, correlate via summary['trino_query_id']" framing lands. |
| **MEDIUM** | DECIMAL-SUM 3rd angle: "we have DECIMAL(18,6) prices summed across 10B rows — same auto-widen story?" | Confirms the r23 §3.1B canonical holds at a different (p,s) and row-count combination — verifies it didn't bulletproof only at DECIMAL(8,2)/2B. |
| **MEDIUM** | INTERSECT/EXCEPT plan-node 3rd angle: "EXPLAIN on `a EXCEPT b` shows SemiJoin but no `FilterMode = ANTI` token — is that node being optimized away?" | Verifies the iter512 r23 §10 + r27 §4.5 EXPLAIN-rendering reconcile-in-place edits hold under direct probe; the iter513 sweep did NOT exercise them. |
| **MEDIUM** | dbt tag mixed-precedence 3rd angle: "`dbt build --select tag:a,tag:b tag:c` — what does this select?" | Confirms the (tag:a AND tag:b) OR tag:c precedence is canonicalized, not just the 2-element case. |
| **LOW** | COALESCE type-coercion: "`COALESCE(int_col, varchar_col)` — does this work?" | Verifies the all-args-must-be-common-supertype edge case (iter513 Q2 Completeness nit). |
| **LOW** | federation | UNPROBED per iter472-514 directive — federation row stays 4.49944/310. |

---

## Summary

iter513 = **4.336 PASS** (+0.836 above floor, slightly above iter512's +0.734). One STRONG-PASS fix-landing (Q1, the primary iter513 fix target — DECIMAL-SUM canonical LANDED on first re-probe, 23rd leading-canonical bulletproofing instance). One clean STRONG-PASS (Q2, COALESCE). One PASS-with-two-real-defects (Q3, $snapshots operation enumeration incomplete + MERGE->replace mis-mapping + WHO overstatement). One NEW sub-threshold individual FAIL (Q4, dbt comma-vs-space inverted semantics). Iter-wide PASS held because Q1+Q2 = 9.907/10 absorbed the Q4 drag.

**The iter513 teacher win (DECIMAL-SUM canonical landing) is the headline; the iter513 cost is a NEW load-bearing inversion (dbt comma=OR) that is the iter514 primary fix target.** The Q3 $snapshots nits are real but lower priority since the question wasn't directly about operation enumeration — the responder volunteered the bad list.

112th consecutive overall PASS in extended phase.
