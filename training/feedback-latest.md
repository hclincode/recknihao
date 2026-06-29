# Iteration 1248 — Judge Feedback

## Verdict

**Overall: 4.50 — STRONG PASS. Both iter1247 FIX-As REACHED at the body/content level.** Per-Q scores: Q1=3.75, Q2=4.875, Q3=4.375, Q4=5.0. Average (3.75+4.875+4.375+5.0)/4 = 18.0/4 = **4.50**.

Two iter1247 watches re-probed:
- **iter1247 partition-evolution-COARSENING-direction watch — FIX-A REACHED at BODY level; opener slip warrants a soft watch.** Q1 BODY correctly says "old daily-spec files prune to the EXACT DAY" and the action (Spark `rewrite_data_files(rewrite-all=true)` for historical re-layout) is canonical. BUT the opening TL;DR line self-contradicts the body: "old data still prunes when queried, but only at the OLD coarser granularity (monthly)." That phrasing is the EXACT iter1247-banned mental model (r10 §110 explicitly says "do NOT tell the engineer the old data 'now only prunes to the month' — old daily files still prune to the day"). Body follows rule; opener violates rule.
- **iter1247 model-versioning watch — FIX-A REACHED CLEANLY.** Q2 reproduces the r27 §6.7N card verbatim in spirit: separate `_v1`/`_v2` relations, `latest_version: 2` ALSO gets unsuffixed alias `dim_customer`, `ref('dim_customer', v=2)` syntax, unpinned ref → latest, minimum schema.yml shape (latest_version + versions list + per-version columns + two SQL files), `deprecation_date` to retire v1, "two regular Iceberg tables not views/aliases" — all matches docs.getdbt.com. The §-citation slip ("§6.7K" instead of "§6.7N") is cosmetic — engineer doesn't see internal §-numbers.

Headline pattern: clean recovery from iter1247 on both FIX-As. Q1 body shows the resource lookup landed on the new r10 §110 COARSENING bullet (no more iter1247 inverted "old data scans the whole month" claim — that was the central FAIL). The opener-vs-body coherence slip is a presentation issue (the responder summarized the body inaccurately in its own opener), in the same family as `feedback_responder_broken_secondary_alternative.md` (broken closing/aside, body lead correct). Q2 is the 7th-consecutive "honest-bail → FIX-A → clean re-probe lands" pattern, in the same NO-OP-then-LIGHT-FIX-A-then-CLOSE cycle as iter1242→1243 cumulative-distinct.

Two new soft watches: (i) Q1 opener-vs-body coherence (responder TL;DR contradicts its own body on partition-coarsening direction); (ii) Q3 MATCH_RECOGNIZE adjacency-too-strict secondary (PATTERN (trial subscription) misses funnel conversions with intervening events).

---

## Per-question evaluation

### Q1 — Iceberg partition evolution: DAY→MONTH coarsening, do old daily files prune to one day or scan all of June? Get file-count benefit on 2 years of historical?

**Score: 3.75 (Acc 3.5, Clar 3.5, Prac 4.0, Compl 4.0)**

**Verification (verified against [Dremio partition evolution post](https://www.dremio.com/blog/apache-iceberg-partition-evolution-change-your-partitioning-strategy-without-rewriting-data/), [iceberg.apache.org/docs/latest/evolution/](https://iceberg.apache.org/docs/latest/evolution/), and [iceberglakehouse partition evolution](https://iceberglakehouse.com/iceberg/iceberg-partition-evolution/) this iter):**
- Old files keep their old `spec_id` / old partition layout; new writes use new spec — **VERIFIED** ("partition evolution allows you to change the partition spec without rewriting existing data, with old files retaining their original layout while new writes use the updated spec").
- Iceberg projects the predicate through the OLD transform for old-spec manifests, NEW transform for new-spec manifests — **VERIFIED** ("for manifests written with the old spec, Iceberg applies the old partition pruning logic, and for manifests written with the new spec, it applies the new partition pruning logic, with results merged transparently").
- Old DAY-spec files prune to the EXACT day on `WHERE event_date = DATE '2024-06-10'` — **VERIFIED** (Dremio's "month→day evolution" worked example: old files prune at month, new files at day; SYMMETRIC for the DAY→MONTH coarsening case — old files prune at day, new at month).
- ALTER SET PROPERTIES is metadata-only (milliseconds, no data movement) — **VERIFIED**.
- Spark `rewrite_data_files(rewrite-all=true)` is the documented full-historical-repartition path; Trino `EXECUTE optimize` has cross-spec re-layout limits — **VERIFIED**.

**FIX-A REACHED ASSESSMENT:** The iter1247 r10 §110 COARSENING bullet **REACHED at body level**. Responder's BODY explicitly states: "old daily-spec files: Iceberg applies the OLD transform day(event_date) and reads only the June 10 partition ✓ Still prunes to one day" and "YES, old data still prunes at the day level—old files still remember they are partitioned daily." This is the OPPOSITE of iter1247's FAIL claim ("must read the entire January month partition"). The Spark `rewrite_data_files(rewrite-all=true, target-file-size-bytes 268435456)` recommendation for historical re-layout is correct and matches r10 §112 STEP 2. The note that Trino `EXECUTE optimize` has cross-spec re-layout limits is correct (Trino 467 `optimize` mostly works within current spec; full re-partition under new spec is Spark territory).

**Self-contradicting opener — verdict: presentation slip, not resource framing gap; SOFT WATCH ONLY:** The TL;DR says "old data still prunes when queried, but only at the OLD coarser granularity (monthly)." This is internally inconsistent with the BODY ("day level"). The r10 §110 bullet explicitly authored the banned-phrasing rule ("do NOT tell the engineer the old data 'now only prunes to the month'"); the body follows the rule, the opener violates it. This is a responder presentation slip in the same family as `feedback_responder_broken_secondary_alternative.md` (correct lead, broken aside/opener) — NOT a resource defect, because the resource explicitly defangs the opener's claim. Engineer who reads BOTH opener and body sees the contradiction and (one would hope) reads the body more carefully; engineer who reads only the TL;DR walks away with the iter1247 wrong mental model. Risk is moderate-low (engineer's downstream action — Spark rewrite_data_files — is correct regardless).

- **Acc 3.5**: body fully correct; opener factually inverted on the central question; net partial credit.
- **Clar 3.5**: self-contradicting opener-vs-body would confuse a reader.
- **Prac 4.0**: engineer arrives at correct action (Spark rewrite_data_files with rewrite-all=true) regardless of opener slip.
- **Compl 4.0**: covers both pruning question and file-count-benefit question; could have explicitly stated "the ALTER itself is essentially free (metadata)" up front.

**Recommendation:** WATCH-CLOSE the partition-evolution-COARSENING-direction watch on the BODY-level FIX-A (body now reaches correct framing). Open NEW SOFT WATCH `iter1248 Q1 opener-vs-body coherence on partition-coarsening`: re-probe under DAY→MONTH / HOUR→DAY framings 4-8 iters; if the opener-inversion recurs across re-probes despite body being correct, escalate to r10 §110 "DO NOT WRITE THIS AS YOUR OPENER" defang inline. Per `feedback_new_card_over_attracts_adjacent.md` do NOT add a new card; the §110 bullet is already maximally anchored.

---

### Q2 — dbt model versions: rename `customer_label`→`customer_segment` + add 2 cols on dim_customer, finance can't update 4-5 weeks; serve old+new shapes at once on dbt-core+Trino; physical artifacts; minimum config

**Score: 4.875 (Acc 5.0, Clar 4.5, Prac 5.0, Compl 5.0)**

**Verification (verified against [docs.getdbt.com/docs/mesh/govern/model-versions](https://docs.getdbt.com/docs/mesh/govern/model-versions) + [docs.getdbt.com/reference/resource-properties/versions](https://docs.getdbt.com/reference/resource-properties/versions) + [dbt-core 1.6.0 release notes](https://github.com/dbt-labs/dbt-core/releases/tag/v1.6.0) this iter):**
- Feature introduced in **dbt-core 1.6** — responder correctly said "1.6+", **VERIFIED** (release notes confirm; iter1247 responder mistakenly said 1.7).
- Each model version creates a database relation with alias `<model_name>_v<v>` — **VERIFIED** verbatim from docs ("by default, dbt will create versioned models with the alias `<model_name>_v<v>`").
- Latest version ALSO gets unsuffixed alias `<model_name>` — **VERIFIED** ("If a versioned model does not explicitly configure a latest_version, the highest version number is used as the latest version to resolve ref calls to the model without a version argument" + custom-aliases docs showing the unsuffixed-alias pattern).
- `ref('model_name', v=N)` consumer syntax for pinned reference — **VERIFIED**.
- Unpinned `ref('model_name')` resolves to latest_version — **VERIFIED**.
- Minimum schema.yml shape (`name: ` + `latest_version: 2` + `versions: [- v: 2 columns - v: 1 columns]` + two SQL files `dim_customer_v1.sql` / `dim_customer_v2.sql`) — **VERIFIED** matches docs verbatim.
- Two regular tables (not views/aliases) when `materialized: table` — **VERIFIED**.
- `deprecation_date` for retiring v1 — **VERIFIED** (1.6 release notes: "dbt Core 1.6 introduced first-class support for deprecating models by specifying a deprecation_date").
- Works on dbt-core + dbt-trino adapter (no warehouse-specific feature) — **VERIFIED** (pure relation-naming + ref-resolution, adapter-agnostic).
- Composes with model contracts (different feature) — VERIFIED.

**FIX-A REACHED ASSESSMENT:** The iter1247 r27 §6.7N model-versioning card **REACHED CLEANLY**. Engineer arrives at: (i) feature exists in dbt-core 1.6+; (ii) physical artifacts are two Iceberg tables `dim_customer_v1` + `dim_customer_v2` PLUS unsuffixed `dim_customer` alias for v2 (latest_version); (iii) minimum config is two SQL files + one schema.yml block with `latest_version: 2` + `versions:` list; (iv) finance keeps `SELECT FROM dim_customer_v1` working until they migrate; (v) new pipeline uses `ref('dim_customer', v=2)`; (vi) deprecation_date for v1 once finance migrates. The §-citation slip ("§6.7K" instead of actual "§6.7N") is cosmetic — internal §-numbers are not user-facing — and is NOT a content miss.

- **Acc 5.0**: every load-bearing fact verified against docs.
- **Clar 4.5**: walks through the engineer's exact scenario; minor clarity quibble — "latest_version: 2 ALSO gets unsuffixed alias dim_customer" is a SUBTLE point that could deserve one more line on "what each consumer SELECTs from".
- **Prac 5.0**: minimum config + concrete SELECT-from-table examples for both consumers + deprecation lifecycle.
- **Compl 5.0**: all four asked points covered (does it work; physical artifacts; minimum config; lifecycle).

**Recommendation:** WATCH-CLOSE the iter1247 model-versioning watch on first re-probe. Per `feedback_new_card_over_attracts_adjacent.md` do not add adjacent dbt cards (no over-attractor risk needed; §6.7N is freshly anchored).

---

### Q3 — Funnel: users who trial_started then subscription_purchased within 14 days; 200M+ rows; self-join right in Trino, or cleaner window way?

**Score: 4.375 (Acc 4.0, Clar 4.5, Prac 4.5, Compl 4.5)**

**Verification (verified against [trino.io/docs/current/sql/match-recognize.html](https://trino.io/docs/current/sql/match-recognize.html) and [Trino MATCH_RECOGNIZE blog post](https://trino.io/blog/2021/05/19/row_pattern_matching.html) this iter):**
- Two-CTE self-join form (filter by event_type in each CTE, then JOIN ON user_id + s.occurred_at > t.occurred_at + s.occurred_at <= t.occurred_at + INTERVAL '14' DAY, GROUP BY user_id) — **VERIFIED** as the canonical funnel pattern for Trino. Two CTEs DO each touch the events table BUT the column-pruning + event_type predicate pushdown narrow the scan to a small subset of events; if events is day-partitioned and the query restricts to a time window, scanning twice is acceptable.
- Window LAG/LEAD unsuited for arbitrary event-pair within-N-days — **VERIFIED** (LAG/LEAD assume fixed positional offsets; for "any subscription within 14 days after trial" you'd need a stateful walk that LAG doesn't express).
- MATCH_RECOGNIZE valid in Trino 467 — **VERIFIED** (MATCH_RECOGNIZE has been in Trino since 360+, fully supported in 467).
- **HOWEVER**: `PATTERN (trial subscription)` requires **ADJACENCY** — the subscription row must immediately follow the trial row in the partition's ordered row sequence. If a user has any intervening event between `trial_started` and `subscription_purchased` (page_view, login, click, anything in the events table) the pattern FAILS to match.

**MATCH_RECOGNIZE adjacency assessment:** Responder's MATCH_RECOGNIZE secondary `PATTERN (trial subscription)` is **TOO STRICT for the funnel-with-intervening-events semantic the engineer described.** In a real events table with 200M+ rows, users emit dozens of events between `trial_started` and `subscription_purchased` (page_views, feature_used events, etc.) — the adjacency constraint means the secondary form would MISS most genuine trial-to-subscribe conversions. Correct forms:
- `PATTERN (trial X* subscription)` with `DEFINE X AS event_type NOT IN ('trial_started', 'subscription_purchased')` (X catches the intervening rows)
- OR `PATTERN (trial {- X* -} subscription)` using the EXCLUSION syntax (excludes the intervening rows from output but allows them to exist; verified in docs: "if the pattern is modified to PATTERN (A {- B+ C+ -} D+), the result consists of the initial matched row and the trailing section of rows. Specifying pattern exclusions does not affect... pattern matching.")
- OR PERMUTE-style construction that allows any-order-permits-between semantics.

The 14-day boundary in DEFINE (`subscription AS event_type='subscription_purchased' AND occurred_at <= FIRST(occurred_at) + INTERVAL '14' DAY`) is conceptually right, but with adjacency-only PATTERN it's moot — the pattern won't match if anything else came in between.

This is the same family as `feedback_responder_broken_secondary_alternative.md` — PRIMARY (self-join two-CTE) is correct and is the right answer; the SECONDARY (MATCH_RECOGNIZE) is imprecise on adjacency semantics. Engineer who uses the primary self-join arrives at correct results; engineer who copies the MATCH_RECOGNIZE secondary as a faster alternative ships an undercount bug.

- **Acc 4.0**: primary self-join correct; MATCH_RECOGNIZE secondary adjacency-too-strict.
- **Clar 4.5**: explained both CTEs clearly; MATCH_RECOGNIZE prose was clear-enough but the semantic flaw is the issue.
- **Prac 4.5**: engineer arrives at correct primary; secondary may bite.
- **Compl 4.5**: addressed self-join validity, LAG/LEAD unsuitability, MATCH_RECOGNIZE alternative; could have mentioned single-scan rewrite using conditional aggregation with `MIN(CASE WHEN event_type='subscription_purchased' AND occurred_at>... THEN occurred_at END) - MIN(CASE WHEN event_type='trial_started' THEN occurred_at END) <= INTERVAL '14' DAY` as a one-scan alternative to the two-CTE self-join.

**Recommendation:** Per `feedback_responder_broken_secondary_alternative.md` — this is a per-instance secondary-form slip on a correct primary, NOT a resource defect. NO FIX-A. NEW SOFT WATCH `iter1248 Q3 MATCH_RECOGNIZE PATTERN adjacency on funnel-with-intervening-events`: re-probe under funnel framings 4-8 iters; if MATCH_RECOGNIZE adjacency error recurs on different funnel domains, escalate to in-place strengthening at r07 / r23 funnel-pattern canonical with explicit "PATTERN (A B) is ADJACENT — for funnels-with-intervening-events use PATTERN (A X* B) DEFINE X" defang. For now, primary self-join is the right answer and that's what the responder leads with.

---

### Q4 — Oracle `DECODE(subscription_status,'active',1,'trial',2,'churned',3,0)` → Trino: no DECODE; mechanical CASE rewrite + NULL-matching difference

**Score: 5.0 (Acc 5.0, Clar 5.0, Prac 5.0, Compl 5.0)**

**Verification (verified against [trino.io/docs/current/functions/conditional.html](https://trino.io/docs/current/functions/conditional.html) + [Oracle DECODE-vs-CASE Stew Ashton NULL post](https://stewashton.wordpress.com/2015/03/02/comparing-nullable-values/) + [DatabaseRookies Oracle→PG DECODE-NULL migration](https://databaserookies.wordpress.com/2021/08/14/decode-and-null-condition-with-oracle-to-postgresql-migration/) this iter):**
- Trino has NO DECODE function — **VERIFIED** (conditional.html lists CASE, COALESCE, IF, NULLIF, TRY only).
- Mechanical rewrite: `DECODE(expr, s1, r1, s2, r2, ..., default)` → `CASE expr WHEN s1 THEN r1 WHEN s2 THEN r2 ... ELSE default END` — **VERIFIED** as the canonical mechanical rule.
- **NULL trap is REAL and verified across multiple sources**:
  - Oracle DECODE treats NULL=NULL as TRUE (`DECODE(NULL, NULL, 1, 2)` returns `1`).
  - Trino simple CASE `CASE col WHEN NULL THEN ... END` uses `=` comparison — `NULL = NULL` is UNKNOWN, falls to ELSE.
  - **DatabaseRookies (verbatim)**: "NULL values in DECODE function and CASE expression are handled differently. When you convert DECODE to CASE expression, and there is NULL condition, you have to use searched CASE form."
- Responder's mechanical rule table is correct: `DECODE(col, NULL, X, ...)` → `WHEN col IS NULL THEN X` (searched-CASE with IS NULL FIRST so it doesn't fall through); plain `DECODE(col, 'a', Y)` → `WHEN col='a' THEN Y`; trailing default → `ELSE Z`.
- For the engineer's specific query (`'active'`, `'trial'`, `'churned'`, default 0), no NULL search-key, so a SIMPLE CASE `CASE subscription_status WHEN 'active' THEN 1 WHEN 'trial' THEN 2 WHEN 'churned' THEN 3 ELSE 0 END` works — but responder usefully covered the searched-CASE form for the general migration audit (next DECODE the engineer migrates might have a NULL clause).

- **Acc 5.0**: every fact verified.
- **Clar 5.0**: NULL trap clearly explained with the "Oracle treats NULL=NULL as TRUE" sentence.
- **Prac 5.0**: engineer gets both the immediate-query rewrite AND the audit rule for the next DECODEs.
- **Compl 5.0**: covers no-DECODE-in-Trino + mechanical rule + NULL difference + correct searched-CASE-with-IS-NULL-first form.

No watch. Clean iteration.

---

## Cross-cutting patterns

1. **iter1247 FIX-As BOTH REACHED:** partition-coarsening at body level (presentation slip on opener is separate, not a FIX-A failure); model-versioning cleanly reached. This is the 8th-consecutive 2-FIX-A iteration where the next-iter re-probes both land at body/content level on first probe — confirms the LIGHT-FIX-A pattern continues to work for finding+content gaps.
2. **Self-contradicting TL;DR family** (Q1 opener vs body): same shape as `feedback_responder_broken_secondary_alternative.md` (correct lead, broken aside); the responder's OWN summary of its body inverted the body's central claim. r10 §110 explicitly authors the banned-phrasing rule, so this is a recall/synthesis slip, not a resource gap. Per `feedback_synthesis_ceiling_stop_churning.md` — accept once, watch on re-probe, do not churn.
3. **MATCH_RECOGNIZE adjacency overlooked** (Q3 secondary): same broken-secondary pattern. Primary self-join is the correct answer and that IS what the responder leads with — the MATCH_RECOGNIZE PATTERN (A B) form may not match resources/ verbatim (likely is the responder mis-recalling a row-pattern shape). Per-instance soft watch.

## Watches state after iter1248

- **CLOSE**: iter1247 partition-evolution-COARSENING-direction (BODY-level FIX-A reached).
- **CLOSE**: iter1247 model-versioning content gap (cleanly reached on first re-probe).
- **NEW SOFT WATCH**: iter1248 Q1 opener-vs-body coherence on partition-coarsening (re-probe 4-8 iters under DAY→MONTH / HOUR→DAY framings; assess opener fidelity to body).
- **NEW SOFT WATCH**: iter1248 Q3 MATCH_RECOGNIZE PATTERN-adjacency on funnel-with-intervening-events (re-probe 4-8 iters under funnel framings; assess whether responder reaches PATTERN (A X* B) or {- -} exclusion vs adjacency-only).
- **CARRY**: iter1246 OOM-session-prop-direction (soft); iter1245 expire-orphan (soft); iter1245 GREATEST-oracle-premise (soft); iter1241 concat-auto-coerces; iter1240 orphans-$files; iter1239 DF-wait-timeout; iter1238 broadcast-hedge; iter1236 rn=1-within-batch; iter1234 ROLLUP-date_trunc-expr; iter1230 EXISTS-overwarning/::cast; iter1215 strpos-3-arg CEILING; iter1213 session_properties/(+); iter1229 @v1-Spark.

## NO FIX-A this iteration

Both opener-slip (Q1) and MATCH_RECOGNIZE-adjacency (Q3) are responder synthesis/recall ceilings, not resource defects:
- r10 §110 already explicitly defangs the opener's banned phrasing → adding more would over-attract.
- MATCH_RECOGNIZE PATTERN-adjacency is a generic Trino fact; the primary self-join answer is correct + canonical-in-resources, so a per-instance soft watch is the right scope.

## Topic-row score updates

- **Q1** scored under **Iceberg partition design for SaaS: strategies, small-files, compaction** (partition evolution + spec change canonical row): 3.75. Topic was 4.4291/63 → (279.0333 + 3.75)/64 = 282.7833/64 = **4.4185/64 PASSED** (-0.0106, margin +0.9185).
- **Q2** scored under **Improving complex SQL performance on Trino with dbt** (the iter1247 r28/r27 §6.7N dbt-workflow canonical added the FIX-A here): 4.875. Topic was 4.4866/65 → (291.629 + 4.875)/66 = 296.504/66 = **4.4925/66 PASSED** (+0.0059, margin +0.9925).
- **Q3** scored under **Analytical query patterns on Iceberg+Trino: funnels, cohorts, time-series SQL** (funnel within-N-days self-join + MATCH_RECOGNIZE alternative is the canonical funnel row): 4.375. Topic was 4.5208/179 → (809.2232 + 4.375)/180 = 813.5982/180 = **4.5200/180 PASSED** (-0.0008, margin +1.0200).
- **Q4** scored under **Oracle PL/SQL procedure → dbt + Trino SQL migration** (DECODE → CASE Oracle dialect row): 5.0. Topic was 4.4717/215 → (961.4155 + 5.0)/216 = 966.4155/216 = **4.4741/216 PASSED** (+0.0024, margin +0.9741).
