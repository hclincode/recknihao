# Judge feedback — iteration 1263

**Phase**: extended (continuous PASS loop)
**Iter avg**: **4.328 PASS with Q1 FAIL** (Q1 2.875 / Q2 4.6875 / Q3 4.75 / Q4 5.0)
**Prior iter**: 1262 = 4.984 STRONG PASS + proactive RECONCILE r03 §524
**State**: passed=true, all required topics still PASSED (Q1 FAIL absorbed by topic margin)
**Verdict**: PASS WITH Q1 FAIL — Q1 inverted the Iceberg-NULL-partition diagnosis (false-sargability claim + missed-skew root cause). Q2/Q3/Q4 clean. **LIGHT FIX-A RECOMMENDED** (Iceberg-NULL-partition canonical — confirmed resource gap per teacher pre-grep).

---

## Per-question scores

### Q1 — Iceberg identity-partition by `plan_tier` / free-tier `NULL` / `WHERE plan_tier IS NULL` = full-scan time / does NULL get a dedicated partition + does IS NULL prune + why slow + fix without dropping partitioning: **2.875 FAIL** — inverted diagnosis

**Topic routing**: Iceberg partition design for SaaS — strategies, small-files, compaction (row 4.4226/65 → 4.3992/66, **−0.0234**; still PASSED, margin +0.8992).

**Scores**: Acc 2.5 / Clar 4.0 / Prac 2.5 / Compl 2.5.

**What's right (load-bearing first half)**:
- "Iceberg creates a SINGLE partition for NULL values, not scattered" — **CORRECT**. Per Iceberg spec ([iceberg.apache.org/spec/](https://iceberg.apache.org/spec/) verbatim WebFetched this iter): "All transforms must return `null` for a `null` input value." Identity transform on a NULL source row produces partition tuple value = NULL; all such rows share that partition tuple → single conceptual NULL partition.
- `$partitions` diagnostic query suggestion to see row distribution by `plan_tier` — useful.
- `EXECUTE optimize` to compact small files — generally correct maintenance step.

**What's wrong (load-bearing second half — THE inverted diagnosis)**:

**(1) FALSE-SARGABILITY claim**. Responder wrote: "file-level pruning on partition columns does NOT automatically narrow to just the NULL partition without explicit predicate application" and "many engines conservatively scan all partition values unless data is physically clustered to make NULL files distinct" and "WHERE plan_tier IS NULL should THEORETICALLY prune... however in practice many engines conservatively scan all partitions."

This is **a Postgres-style sargability-folklore prior imported into Iceberg context** — and it is **WRONG for Iceberg + Trino 467**. Per Iceberg spec manifest field_summary (WebFetched verbatim):

> "contains_null: Whether the manifest contains at least one partition with a null value for the field"
> "lower_bound: Lower bound for the non-null, non-NaN values in the partition field, or null if all values are null"
> "upper_bound: Upper bound for the non-null, non-Nan values in the partition field, or null if all values are null"

Iceberg manifest summaries explicitly record `contains_null` per partition-field per manifest. `WHERE col IS NULL` on an identity-partitioned column is a **first-class prunable predicate**: the planner skips every manifest entry where `contains_null = FALSE` and only opens files where the partition tuple value is NULL. IS NULL DOES PRUNE. This is the same pruning mechanism that handles `WHERE col = 'free'` — there is no "predicate not eligible for partition pruning" carve-out for IS NULL.

**(2) MISSED THE LIKELY-REAL ROOT CAUSE — data skew, not pruning failure**.

The engineer said free-tier users have `plan_tier=NULL`. **Free-tier is almost always the MAJORITY in a SaaS** (typical 70–95% of users are free, paid tiers are the long tail). So:

- NULL partition holds 70–95% of all events.
- `WHERE plan_tier IS NULL` correctly prunes to JUST the NULL partition.
- Scanning the NULL partition = scanning 70–95% of the table ≈ full-scan time.
- **This is expected and correct behavior**. Pruning succeeded; the data is just skewed.

The responder only considered the OPPOSITE case ("if NULL holds a tiny partition (1–2%) but query takes 45 min, the issue is many files per partition → compact"). For a 1–2% partition the slow-cause IS small files. **For a 70–95% partition the slow-cause is the partition itself being most of the table**, and compaction (`optimize`) won't help much because there's not much to compact — you're still scanning ~80% of the bytes.

**(3) The actual practical fixes the responder missed**:
- **Don't use NULL as a partition value when it dominates**. Backfill `plan_tier` to a sentinel like `'free'` (then the partition value is `'free'` not NULL — still a single partition, but the modeling is explicit and avoids the NULL-as-default trap).
- **Add a secondary partition transform** that splits the NULL bucket. E.g., `partitioning = ARRAY['plan_tier', 'day(occurred_at)']` — now the NULL-plan_tier partition is further split by day, and a query like `WHERE plan_tier IS NULL AND occurred_at >= …` reads only the recent days.
- **Use bucket() on user_id** to spread the NULL-bucket across N files in parallel — doesn't reduce scan bytes, but parallelizes the scan and reduces wall-clock.
- **If `plan_tier IS NULL` queries are rare and `plan_tier = 'enterprise'` queries are hot**, accept the skew — `plan_tier` partitioning is still doing its job for the non-NULL queries.

**Engineer's actual take-away from the responder's answer**: run `EXECUTE optimize WHERE plan_tier IS NULL` and re-query. Probably no improvement (the partition is huge regardless of file count). Engineer concludes "Iceberg partition pruning is broken on NULLs" — exactly the false-sargability folklore the responder validated.

**Slip category**: imported-prior (Postgres-style "NULL/function-on-col is non-sargable" wrongly applied to Iceberg manifest pruning) + missed-skew diagnostic miss. Family-member of `reference_trino_unwrap_temporal_predicates.md` (`function-on-column = full scan` is a FALSE imported sargability prior on Trino+Iceberg).

**iter1263 Q1 NULL-PARTITION VERDICT** (explicit per teacher ask):
- ✅ **Iceberg isolates NULLs into a dedicated partition tuple** (identity transform returns NULL for NULL → single NULL partition value → all NULL rows share that tuple).
- ✅ **IS NULL DOES prune** to the NULL-partition files via the manifest `contains_null` field-summary (Iceberg spec verbatim).
- ❌ **Responder inverted it** (claimed "engines conservatively scan all partitions" / "IS NULL doesn't prune automatically") — FALSE sargability folklore.
- ✅ **Likely real cause = data skew** (free-tier is majority of SaaS users → NULL partition holds 70–95% of rows → scanning it ≈ full scan because the partition IS most of the table, NOT because pruning failed).

**FIX-A DECISION**: **LIGHT FIX-A RECOMMENDED**. Teacher pre-grep confirmed resources have NO Iceberg-NULL-partition-pruning canonical (only partition-EVOLUTION-producing-NULL-keys content, a different topic). This is a genuine content gap that the inverted responder answer can be sourced to.

**Where to place the FIX-A card**: short canonical in **r07** (Iceberg partition design / partition pruning section) AND/OR cross-ref from **r09** (Query performance basics: partitioning). Keyword anchors must include: "WHERE col IS NULL partition pruning", "IS NULL doesn't prune", "NULLs scattered across partitions", "free-tier NULL partition slow", "NULL partition full scan", "$partitions NULL row count".

**Suggested card content (teacher to write)**:
1. **Iceberg identity partition + NULL**: NULL source rows produce partition tuple value = NULL (Iceberg spec "all transforms return null for null input"). All NULL rows go into a **single dedicated NULL partition**, not scattered.
2. **IS NULL DOES prune**: Iceberg manifest field_summary records `contains_null` per partition-field per manifest. `WHERE col IS NULL` is fully prunable — the planner skips manifest entries where `contains_null = FALSE` and only opens files where the partition tuple value is NULL. Same first-class status as `col = literal`.
3. **DEFANG the Postgres-prior**: "function-on-column / IS NULL is non-sargable" is Postgres folklore — NOT how Iceberg manifest pruning works. Trino+Iceberg do NOT "conservatively scan all partitions" for IS NULL on an identity-partitioned column.
4. **THE LIKELY-REAL CAUSE OF SLOW IS-NULL QUERIES — SKEW**: If a NULL partition is slow to scan, the partition likely holds most of the table (common when NULL = the default state, e.g., free-tier=NULL where free is majority). Pruning succeeded; the partition just IS most of the data. Verify via `SELECT plan_tier, sum(record_count) FROM "events$partitions" GROUP BY plan_tier ORDER BY sum DESC` — if NULL row is 70%+ of total, you have skew not pruning failure.
5. **FIXES** when NULL-partition is dominant (without dropping the partition column):
   - Backfill NULL → sentinel (`'free'`) so the partition value is explicit (Iceberg has no problem with NULL-as-partition-value, but explicit sentinels avoid the modeling trap and make queries `WHERE plan_tier = 'free'` semantically clearer).
   - Add a secondary partition transform that splits the NULL bucket — e.g., `partitioning = ARRAY['plan_tier', 'day(occurred_at)']` partitions NULL × day, so date-bounded queries on free-tier touch only recent days.
   - `bucket(user_id, N)` to parallelize the scan within the NULL partition.
   - Accept the skew if NULL-IS-NULL queries are rare and the partitioning helps the non-NULL hot path.
6. **Cross-link** to existing partition-pruning sections + `reference_trino_unwrap_temporal_predicates.md` family (same false-sargability-prior class).

**Per `feedback_new_card_over_attracts_adjacent.md`**: keep the card scoped to NULL-partition pruning specifically; do NOT let it bleed into general "all partition pruning" content (which already exists). Defang at the bottom: "if the NULL partition is tiny but the query is still slow, see [small-files compaction card] — different problem."

---

### Q2 — view_pricing → start_trial within 7 days on `events(user_id, event_type, occurred_at)` ~400M; self-join 45 min; right pattern + speed-up: **4.6875 PASS**

**Topic routing**: Analytical query patterns on Iceberg+Trino — funnels, cohorts, time-series SQL (row 4.5164/189 → 4.5173/190, +0.0009; PASSED, margin +1.0173).

**Scores**: Acc 4.75 / Clar 4.75 / Prac 4.75 / Compl 4.5.

**Pattern**: Two filtered CTEs (`pricing_view` on `event_type='view_pricing'` + date window; `trial_start` on `event_type='start_trial'` + date window) → INNER JOIN on `user_id` AND `ts.trial_at > pv.pricing_at` AND `ts.trial_at <= pv.pricing_at + INTERVAL '7' DAY`. `date_diff('day', pv.pricing_at, ts.trial_at)` for days_to_trial. Recommends date-range partition pruning, NOT NULL guards, `ANALYZE TABLE` for CBO join ordering, `MATCH_RECOGNIZE` mention for 4+ step funnels.

**Verified**:
- Self-join (filtered-CTEs-then-INNER-JOIN form) IS the canonical "A then B within window" pattern on Trino. 45 min on 400M with a 7-day inequality is plausible (the inequality forces a partition-wise nested loop or broadcast hash join — both expensive at 400M).
- Filter event_type FIRST in the CTE (responder did this) so the join builds on ~10–20% of source rows, not all 400M.
- Date-window partition pruning via `occurred_at >= …` raw-timestamp predicate works on a `day(occurred_at)`-partitioned table (constant-replacement pushdown; per `reference_trino_unwrap_temporal_predicates.md`).
- MATCH_RECOGNIZE for 4+ step funnels is a reasonable escalation hint.

**Minor completeness shave (−0.5)**: returns multiple rows per user if a user has multiple `view_pricing` events or multiple `start_trial` events in the 7-day window. For **distinct converting users** (the usual KPI ask: "how many free users converted to trial within 7d of viewing pricing"), wrap with `SELECT DISTINCT user_id` or `GROUP BY user_id` taking the first trial after pricing (e.g., `MIN(trial_at)` per user-pricing-event pair). Responder didn't mention this multiplicity / dedup step. Engineer who copies the query and counts rows will get inflated numbers if any user viewed pricing twice or started trials on different products.

**Practical applicability** (−0.25): "45 min not unreasonable for 400M" is a fair framing but the engineer is asking how to make it NOT 45 min. Suggested compactions:
- Pre-aggregate to first-view-per-user and first-trial-per-user CTEs before the inequality join (collapse multiplicity early).
- Or rewrite as window-functions on a UNION ALL of the two events (LAG/LEAD over a time-ordered single-table scan), avoiding the self-join entirely. The `MATCH_RECOGNIZE` hint hints at this but doesn't make the cheaper LAG/LEAD alternative explicit.

**No imported-prior, no broken-secondary, no over-warning, no fabrication.** Lead is correct.

---

### Q3 — dbt incremental + added `session_id` to source / `dbt run` fails "column session_id does not exist in target table" / `on_schema_change` options / pick + risk of silent loss: **4.75 PASS**

**Topic routing**: Postgres-to-Iceberg ingestion — full refresh, incremental, CDC, JSONB handling (row 4.4936/176 → 4.4951/177, +0.0015; PASSED, margin +0.9951). Routed here per iter1201/iter1204 precedent (on_schema_change is dbt-incremental-mechanism, fits Postgres-to-Iceberg incremental ingestion row).

**Scores**: Acc 4.5 / Clar 5.0 / Prac 5.0 / Compl 4.5.

**Verified at [docs.getdbt.com/docs/build/incremental-models](https://docs.getdbt.com/docs/build/incremental-models)** (WebFetched this iter):

| Option | Behavior | Responder claim |
|---|---|---|
| `ignore` (default) | New columns in model SILENTLY EXCLUDED from INSERT (target schema unchanged); removed columns trigger fail | ✅ "silently drops new columns" |
| `fail` | Errors on any schema divergence | ✅ "errors" |
| `append_new_columns` | ALTER ADD COLUMN; new columns added, removed columns retained (non-destructive) | ✅ "recommended, adds new columns" |
| `sync_all_columns` | Adds new AND DROPS removed; type changes accepted | ✅ "adds AND DROPS removed cols, destructive" |

All four-row matrix verbatim correct.

**Recommendation**: `on_schema_change='append_new_columns'` to pick up `session_id` without silent loss and without DROP risk. Config block with `materialized='incremental'`, `unique_key='event_id'`, `on_schema_change='append_new_columns'` — production-grade. Notes that backfilling old rows for `session_id` requires `--full-refresh` (correct — none of the four options backfill historical NULLs).

**Minor accuracy shave (−0.5)** — error-message reconciliation gap. Engineer reported a **hard ERROR** "column session_id does not exist in target table". Responder framed default `ignore` as **silent drop**. These are two different mechanisms:
- Per dbt docs verbatim ("ignore" = silently drop new columns), the engineer should NOT have seen this error — the new column would have been silently excluded from the compiled INSERT.
- The actual error implies either (a) the engineer's dbt-trino adapter doesn't fully implement `ignore`-silent-drop (adapter quirk; some adapters surface schema-mismatch as a hard error even at `ignore`), OR (b) the model uses `SELECT * FROM source` and the materialization passed the wildcard expansion through to the INSERT without column-projection narrowing, OR (c) the project is on `fail` not `ignore` (less likely if engineer says "default").

The responder didn't reconcile this — engineer reads "default = silent drop" but observed "default = hard error" and is left confused about whether the responder's mental model matches their reality. The **fix recommendation (`append_new_columns`) is correct regardless** of which of (a)/(b)/(c) is the actual cause, so the engineer arrives at the right action.

**Completeness shave (−0.5)**: didn't mention the dbt-trino-specific incremental MERGE compilation and that on Iceberg the `ALTER ADD COLUMN` is metadata-only (instant on 6mo of rows) — would have closed the loop with the engineer's likely follow-up "is this safe on 6mo of data". (`reference_trino_count_distinct_single_arg.md` is unrelated; relevant pin would be the Iceberg-metadata-only schema-evolution facts from iter1251.)

**No imported-prior, no broken-secondary, no over-warning, no fabrication.** Lead + four-row matrix + risk notes all correct. Engineer arrives at right action.

---

### Q4 — Oracle `INITCAP(first||' '||last)` → "function INITCAP not found" in Trino / built-in equivalent or rewrite: **5.0 STRONG PASS**

**Topic routing**: Oracle PL/SQL procedure → dbt + Trino SQL migration (row 4.4870/230 → 4.4893/231, +0.0023; PASSED, margin +0.9893).

**Scores**: Acc 5.0 / Clar 5.0 / Prac 5.0 / Compl 5.0.

**Verified at [trino.io/docs/467/functions/string.html](https://trino.io/docs/467/functions/string.html)** (WebFetched this iter): native string function list does NOT include `initcap` or any title-case helper. Full list quoted: `chr, codepoint, concat, concat_ws, hamming_distance, length, levenshtein_distance, lower, lpad, ltrim, luhn_check, position, replace, reverse, rpad, rtrim, soundex, split, split_part, split_to_map, split_to_multimap, strpos, starts_with, substr, substring, translate, trim, upper, word_stem, normalize, to_utf8, from_utf8`. No `initcap`, no `ends_with`, no `capitalize` — responder is correct.

**Primary rewrite**: `regexp_replace(lower(first||' '||last), '(\w)(\w*)', x -> upper(x[1]) || lower(x[2]))` — Trino 467 `regexp_replace` 3-arg lambda form, `\w` regex shorthand works in single-backslash form per `reference_trino_regex_backslash.md` (verified RAW 467 source). Lambda receives match array, indices 1-based. `lower(first||' '||last)` normalizes input first.

**Alt rewrite**: `array_join(transform(split(lower(first||' '||last), ' '), w -> upper(substr(w, 1, 1)) || substr(w, 2)), ' ')` — split-transform-join lambda chain, also valid Trino 467, handles space-separated words. Both equivalent for typical first/last name input.

**DO-NOT-WRITE defang**: `initcap(...)` flagged as "not registered" — correct, matches iter1246 (per memory pinned) + verified docs.

**Consistency with prior iters**: matches iter1246 INITCAP canonical answer shape exactly. Resource canonical (r27 Oracle migration string-function compat table) is reaching cleanly across re-probes.

**No imported-prior, no broken-secondary, no over-warning, no fabrication.** Pin-perfect.

---

## Iteration-level summary

**Iter avg 4.328** = (2.875 + 4.6875 + 4.75 + 5.0) / 4 — first sub-4.5 iter avg in 12+ iters (since iter1249 row-level-delete-reclaim FAIL@2.875).

**Q1 FAIL absorbed by topic margin**: Iceberg-partition-design row drops 4.4226 → 4.3992 (−0.0234, still PASSED with +0.8992 margin). No topic falls below threshold. State unchanged (passed=true).

**Verdicts on the four explicit asks**:

1. **Q1 NULL-partition verdict** (load-bearing): Iceberg DOES isolate NULLs into a dedicated partition tuple AND IS NULL DOES prune via manifest `contains_null` field-summary (verified Iceberg spec verbatim). Responder INVERTED this with a Postgres-style sargability folklore claim ("engines conservatively scan all partitions"). The likely-real root cause = **data skew** (free-tier=NULL is typically 70–95% of SaaS events; NULL partition IS most of the table; scanning it ≈ full scan correctly). Responder only considered the opposite case (NULL = tiny 1–2% partition + small-files cause).

2. **Q2**: filtered-CTEs-then-INNER-JOIN A-then-B-within-7-days pattern is correct; minor missed DISTINCT/dedup note for multi-event-per-user case (multiplicity shave).

3. **Q3**: four-row `on_schema_change` matrix verbatim correct per docs; `append_new_columns` fix correct; engineer's error-message-vs-default-silent-drop reconciliation not addressed (minor — fix is right regardless).

4. **Q4**: Trino 467 has no `initcap`; regexp_replace lambda title-case rewrite verbatim correct.

**FIX-A DECISION**: **NEW LIGHT FIX-A — Iceberg-NULL-partition canonical** (teacher to write next iter).

- **Confirmed gap** (teacher pre-grep): no existing canonical on `WHERE col IS NULL` pruning behavior on identity-partitioned Iceberg tables (only partition-EVOLUTION-producing-NULL-keys content, different topic).
- **Where**: short card in **r07** (Iceberg partition design / pruning section), cross-link from r09 (query performance basics: partitioning).
- **Card scope**: (1) NULL goes into a single dedicated partition tuple; (2) IS NULL DOES prune via manifest `contains_null`; (3) DEFANG the Postgres-style "IS NULL non-sargable" prior; (4) likely-real cause of slow IS-NULL = data skew (NULL is majority); (5) fixes — sentinel backfill, secondary partition transform, bucket() parallelism, accept-skew.
- **Keyword anchors**: "WHERE col IS NULL partition pruning", "IS NULL doesn't prune", "NULLs scattered", "free-tier NULL partition slow", "NULL partition full scan", "$partitions NULL".
- **Defang per `feedback_new_card_over_attracts_adjacent.md`**: scope to NULL-partition specifically; do NOT let it over-attract general partition-pruning questions; bottom cross-link to small-files-compaction card for the OPPOSITE case.

**Class of slip**: imported-prior (Postgres sargability folklore → Iceberg manifest-pruning context), same family as `reference_trino_unwrap_temporal_predicates.md` ("function-on-column=full scan" is a FALSE imported sargability prior).

**Watch closures**: none this iter (iter1262 r03 §524 sorted_by-Spark-only-stale-claim — RECONCILED iter1262 by teacher proactively; no re-probe yet).

**New watches**:
- **NEW (LIGHT FIX-A scheduled)**: `iter1263 Q1 Iceberg-NULL-partition pruning + skew-not-pruning-failure` — once teacher writes the canonical, re-probe under framings: "WHERE plan_tier IS NULL slow on identity-partitioned Iceberg", "is IS NULL prunable in Iceberg", "free-tier NULL partition holds most rows what to do". Confirm 1st-re-probe-CLOSE in 4–8 iters.
- **NEW (soft watch)**: `iter1263 Q3 dbt on_schema_change error-message-vs-silent-drop reconciliation` — re-probe under "got hard error on incremental schema mismatch even though default is ignore" framing; if recurs, consider adapter-specific note at r13 §5527-area on_schema_change canonical. NO FIX-A this iter (per-instance recall ceiling, fix is right regardless).

**Open watches inherited**:
- iter1262 Q2 r03-§524-sorted_by-Spark-only-stale-claim (RECONCILED by teacher; confirm reach)
- iter1260 Q1 CDC-MERGE-multi-event-dedup
- iter1260 Q3 source-hard-delete-snapshot-routing
- iter1258 Q3 SELECT-*-EXCEPT
- iter1257 Q4 strpos-arithmetic
- iter1255 Q1 bloom-CREATE-syntax
- iter1255 Q3 INSERT-OVERWRITE
- iter1253 Q4 regexp_extract-2arg
- iter1248 Q3 MATCH_RECOGNIZE-adjacency
- iter1241 concat-auto-coerces
- iter1229 @v1-Spark

**No broken-secondary, no over-warning, no fabrication this iter.** Q1 is a single inverted-diagnosis slip; Q2/Q3/Q4 are clean.

**Production-stack alignment**: every recommendation fits on-prem Trino 467 + Iceberg 1.5.2 + MinIO + dbt-trino. Q1 (despite the inverted diagnosis) — `EXECUTE optimize` + `$partitions` queries are Trino-native; Q2 — pure Trino 467 dialect + `date_diff('day',...)`; Q3 — dbt-trino `incremental` materialization with `on_schema_change='append_new_columns'`; Q4 — Trino 467 native `regexp_replace` 3-arg lambda + `lower`/`upper`/`substr`.

**State unchanged** (passed=true, all topics PASSED). Iteration logged as PASS WITH Q1 FAIL absorbed by topic margin; LIGHT FIX-A scheduled for next iter.
