# Iter 1271 — Judge Feedback

**Overall: 3.59 BORDERLINE PASS** (Q1 2.00 / Q2 3.00 / Q3 4.625 / Q4 4.75)

The pass-loop continues but this iter is the THINNEST in many sweeps because **Q1 REGRESSED on the very thing iter1255 + iter1270 had landed correctly** (parquet_bloom_filter_columns IS a valid Trino 467 CREATE TABLE property — only ALTER SET PROPERTIES is 469+). Q2 mechanism right but answered the WRONG question (longest streak vs current/most-recent streak the engineer explicitly asked for, with worked example).

**Q1 verdict — RESOURCE-SOURCED REGRESSION + r17 §713/§1012 reconcile is the RIGHT fix.**
- VERIFIED via WebFetch of [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html): canonical example shows `CREATE TABLE test_table (c1 INTEGER, c2 DATE, c3 DOUBLE) WITH (format='PARQUET', location='/var/example_tables/test_table', parquet_bloom_filter_columns = ARRAY['c1','c2'])`. **parquet_bloom_filter_columns IS in the 467 CREATE TABLE property allow-list** — verbatim docs.
- ALTER TABLE SET PROPERTIES list in the same docs **does NOT include parquet_bloom_filter_columns** in 467 (only `format`, `format_version`, `partitioning`, `sorted_by`, `object_store_layout_enabled`, `data_location`). The ALTER form for parquet_bloom_filter_columns landed in 469+ per PR #24573.
- Responder said "Trino 467 CANNOT set bloom filters at CREATE TABLE time. parquet_bloom_filter_columns is Trino 469+, not available on 467" — **FACTUALLY WRONG, OPPOSITE direction**. Recommended Spark `ALTER SET TBLPROPERTIES write.parquet.bloom-filter-enabled.column.key_hash` + Spark rewrite_data_files for a brand-new table where the obvious answer is one Trino `CREATE TABLE ... WITH (parquet_bloom_filter_columns=ARRAY['key_hash'])` statement.
- Never gave the engineer the asked CREATE TABLE statement.
- Responder cited r17 §1012-1013 — and the iter1270 state confirms r17 carried the OVER-BROAD "469+/Spark-side bloom" framing that contradicts the CORRECT r03 §474 / §469 / §563 + r18 §1251 (which say CREATE-WITH works on 467). The iter1270 r03 copy-attractor FIX-A did NOT prevent this regression because the responder pulled from r17's wrong claim, not r03 — confirming the keyword-magnet was sitting on the WRONG resource.
- **r17 §713 + §1012 reconcile this iter is the RIGHT fix**: scoping "469+" strictly to the ALTER SET PROPERTIES form + naming CREATE-WITH-works-on-467 + cross-ref r03 §474 should close the regression loop, because the responder's chosen citation now agrees with r03/r18.
- This is the THIRD instance of "grep ALL resources for a wrong claim" reconcile (after iter1194/1195 optimize-clears-position-deletes r28 ↔ r13 sibling, and the iter1168 migrate-is-native r21/r17 reconcile). Pinned `feedback_reconcile_dont_append.md` validated again.

**Q2 verdict — LONGEST vs CURRENT MISREAD on a worked-example question. Accuracy/completeness ding.**
- Gaps-and-islands mechanism (LAG + flag + SUM running over → streak_id, off SELECT DISTINCT activity_date) is the textbook Trino approach and is correct.
- BUT the engineer EXPLICITLY asked for the **CURRENT/MOST-RECENT** consecutive-days streak, with the worked example **"active Mon-Wed, skip Thu, back Fri-Sat → current streak = 2"** (longest = 3). Responder framed the answer as "LONGEST streak per user" and computed `MAX(streak_len)`, which returns 3 for the example — the WRONG answer.
- The correct final aggregation: pick the streak_id containing each user's MAX(activity_date), then COUNT(*) for that streak_id. A clean form is `SELECT user_id, COUNT(*) AS current_streak FROM streaks WHERE (user_id, streak_id) IN (SELECT user_id, MAX(streak_id) FROM streaks GROUP BY user_id) GROUP BY user_id` (streak_id is monotonically increasing within each user, so MAX(streak_id) = latest streak).
- This is a longest-vs-current FRAMING misread on a question with an explicit worked example — the engineer's paste-and-run gets the wrong number on the very example they gave.

**Q3 verdict — CLEAN PASS.** Built-in `relationships` generic test correctly named; schema.yml `data_tests: - relationships: {to: ref('customers'), field: customer_id}` shape verified against [docs.getdbt.com data-tests](https://docs.getdbt.com/reference/resource-properties/data-tests) (relationships listed among the 4 built-in generic tests; flat-form syntax still compiles though dbt 1.10+ favors `arguments:` nesting — both work). `source()` variant for raw external sources correctly mentioned. NOT EXISTS / anti-join compilation framing is the correct mental model (dbt docs don't state the exact SQL but the underlying pattern is a `SELECT child.field FROM child WHERE child.field NOT IN (SELECT field FROM parent) AND child.field IS NOT NULL` shape; zero rows = pass).

**Q4 verdict — CLEAN PASS.** DECODE absent from Trino 467 confirmed via [trino.io/docs/467/functions/list.html](https://trino.io/docs/467/functions/list.html). Simple CASE shorthand `CASE plan_tier WHEN 'starter' THEN 1 WHEN 'growth' THEN 2 WHEN 'enterprise' THEN 3 ELSE 0 END` is the less-verbose Trino form. NULL caveat is the load-bearing migration trap: Oracle DECODE treats NULL=NULL as match, but Trino simple-CASE uses `=` equality which returns UNKNOWN on NULL → `WHEN NULL` never fires. Correct routing to searched CASE `WHEN plan_tier IS NULL THEN ... FIRST`.

---

## Per-question scores

### Q1 — NEW Iceberg api_keys CREATE TABLE with parquet_bloom_filter_columns on key_hash VARCHAR

**Score 2.00** (Acc 1.0 / Clar 3.5 / Prac 1.5 / Compl 2.0)

**REGRESSION — directly opposite-direction error to iter1255+iter1270, which both stated CREATE-with-bloom works on 467.**

The responder said "Trino 467 CANNOT set bloom filters at CREATE TABLE time. parquet_bloom_filter_columns is Trino 469+, not available on 467" — **FACTUALLY WRONG**. Then offered Spark `ALTER TABLE ... SET TBLPROPERTIES write.parquet.bloom-filter-enabled.column.key_hash = true` + Spark `rewrite_data_files`, and hedged "once cluster upgrades to 469+, set at CREATE via WITH (parquet_bloom_filter_columns=ARRAY[...])". The 469+ hedge is BACKWARDS — CREATE-with works on 467 today; only ALTER SET PROPERTIES is 469+.

**Verification:**
- [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) canonical example verbatim shows `CREATE TABLE test_table (c1 INTEGER, c2 DATE, c3 DOUBLE) WITH (format='PARQUET', location='/var/example_tables/test_table', parquet_bloom_filter_columns = ARRAY['c1','c2'])` — bloom WITH-clause property is FIRST-CLASS on 467 CREATE TABLE.
- Same docs page lists modifiable-via-ALTER-SET-PROPERTIES properties as `format`, `format_version`, `partitioning`, `sorted_by`, `object_store_layout_enabled`, `data_location` — parquet_bloom_filter_columns is NOT in this list for 467 (the ALTER form is the 469+ addition per PR #24573).

**Resource-source check — RESOURCE DEFECT confirmed and r17 §713/§1012 reconcile is RIGHT fix.**

The responder cited r17 §1012-1013 — which carried the OVER-BROAD "469+/Spark-side bloom write" framing inherited from iter1254. Per iter1270 state and pinned `reference_trino_parquet_bloom_filter_469.md`, r03 §474/§469/§563 + r18 §1251 had been correctly reconciled to "CREATE-WITH works on 467, ALTER form is 469+", but r17 §713/§1012 was MISSED in that pass — the classic "grep ALL resources for a wrong claim" miss.

The teacher applied a follow-up FIX-A this iter reconciling r17 §713 + §1012 to:
1. Scope "469+" narrowly to the ALTER SET PROPERTIES form.
2. Add explicit "CREATE TABLE ... WITH (parquet_bloom_filter_columns=ARRAY[...]) WORKS on 467" framing.
3. Cross-ref r03 §474 as the canonical copy-pasteable example.

**This is the right fix.** The keyword-magnet was on r17, not r03 — iter1270's r03 §474 attractor card couldn't prevent the regression because the responder didn't pull from r03 at all. Reconciling r17 in place (not appending another card) collapses the contradictory-resource hazard. Pinned `feedback_reconcile_dont_append.md` applies; this is the 3rd instance of a sibling-resource-defect that needed grep-all-resources discovery (after iter1194 optimize-clears-position-deletes r13 sibling and iter1168 migrate-is-native r21 sibling).

**Scoring rationale.**
- **Acc 1.0** — directly contradicts the 467 docs canonical example; engineer told "can't on 467" when 467 docs show the syntax verbatim.
- **Clar 3.5** — sentences read cleanly enough, just teaching the wrong fact confidently.
- **Prac 1.5** — engineer follows Spark ALTER+rewrite_data_files workflow for a NEW table when a 5-line Trino CREATE TABLE was the right answer; significant wasted setup work.
- **Compl 2.0** — never gave the asked full copy-pasteable CREATE TABLE statement; never addressed the NO-PRIMARY-KEY confirmation the engineer asked for explicitly.

**Watch status:** the iter1270 PRIMARY-KEY + cols-with-AS-SELECT synthesis-slip watch did NOT recur (responder never reached a CREATE statement at all this iter — different regression family). The iter1270 watch stays OPEN (still under-probed at 1 datapoint); the NEW watch is below.

**NEW HARD WATCH `iter1271 Q1 bloom-CREATE-467-vs-469 r17-reconcile FIX-A reach test`** — re-probe bloom-on-NEW-Iceberg-table framings within next 2 iters to verify the r17 §713/§1012 reconcile fired and the responder lands "CREATE-WITH works on 467, ALTER is 469+" cleanly. If the regression recurs, escalate to (a) re-grep ALL resources for any remaining "469+ for CREATE" instances + (b) consider stronger router from "bloom 467" keyword zone to r03 §474.

### Q2 — Current / most-recent consecutive-days streak per user (worked example: Mon-Wed skip Thu Fri-Sat → current = 2)

**Score 3.00** (Acc 3.0 / Clar 4.0 / Prac 2.5 / Compl 2.5)

**Gaps-and-islands MECHANISM correct; FINAL AGGREGATION answers the wrong question (LONGEST not CURRENT).**

What the responder built:
1. CTE 1 on `SELECT DISTINCT user_id, activity_date`: `CASE WHEN date_diff('day', LAG(activity_date) OVER (PARTITION BY user_id ORDER BY activity_date), activity_date) = 1 THEN 0 ELSE 1 END AS is_new_streak`.
2. CTE 2: `SUM(is_new_streak) OVER (PARTITION BY user_id ORDER BY activity_date) AS streak_id`.
3. Final: `SELECT user_id, MAX(streak_len) FROM (SELECT user_id, streak_id, COUNT(*) AS streak_len FROM streaks GROUP BY user_id, streak_id) GROUP BY user_id`.

The mechanism (LAG + day-diff = 1 flag + running SUM → streak_id) is the textbook Trino gaps-and-islands canonical and is correct. But step (3) returns **LONGEST streak**, not **CURRENT/MOST-RECENT streak**. The engineer's worked example "Mon-Wed (3) skip Thu Fri-Sat (2) → current = 2" pasted into the responder's query returns 3 (longest), not 2 (current). The query does not answer the question.

The correct CURRENT-streak final aggregation is to pick each user's MAX-activity-date streak_id and count its rows:

```sql
SELECT user_id, COUNT(*) AS current_streak
FROM streaks s
WHERE (user_id, streak_id) IN (
    SELECT user_id, MAX(streak_id)
    FROM streaks
    GROUP BY user_id
)
GROUP BY user_id
```

(MAX(streak_id) per user = the latest run, because streak_id is monotonically increasing within each user.)

Or equivalently, restrict to streaks whose MAX(activity_date) per user matches each user's overall MAX(activity_date).

**Classification.** The responder framed the answer as "longest streak" from the start and never engaged with the engineer's worked example. The "longest" canonical is well-anchored in resources and the responder lifted it cleanly — but lifted the WRONG canonical for the question asked. This is a question-comprehension miss, not a Trino dialect error.

**Resource-source check.** Need to verify whether a CURRENT-streak canonical exists in resources next to the gaps-and-islands canonical. If LONGEST is the only nearby example, the keyword-magnet would pull "current streak" questions into the LONGEST card.

**NEW SOFT WATCH `iter1271 Q2 current-vs-longest-streak final-aggregation framing`** — re-probe gaps-and-islands questions under varied framings (current/most-recent vs longest vs total active-day count) for 4-8 iters. If 2+ recurrences where the engineer asks "current" and the responder returns "longest", escalate to LIGHT FIX-A adding a copy-attractive CURRENT-streak final-aggregation block beside the LONGEST canonical with an inline DO-NOT-write "MAX(streak_len) returns longest, not current" defang.

**Scoring rationale.**
- **Acc 3.0** — mechanism right, final aggregation answers the wrong question; the SQL would be technically correct for a "longest" question but the engineer didn't ask that.
- **Clar 4.0** — narrative clear, three-CTE structure walked cleanly.
- **Prac 2.5** — engineer pastes the query, gets 3 not 2 on their own worked example, has to debug — significant friction even with the right primitives in hand.
- **Compl 2.5** — never returned the asked metric (current streak = 2); engineer would need to know the longest-vs-current distinction to repair the final SELECT themselves.

### Q3 — dbt referential-integrity test (orders.customer_id must exist in customers)

**Score 4.625** (Acc 5.0 / Clar 4.5 / Prac 4.75 / Compl 4.25)

**Built-in `relationships` generic test verified verbatim.** [docs.getdbt.com data-tests](https://docs.getdbt.com/reference/resource-properties/data-tests) lists `relationships` among the 4 built-in generic data tests; the docs describe it as "validates that all of the records in a child table have a corresponding record in a parent table. This property is referred to as referential integrity. This test automatically excludes NULL values from validation, consistent with how database foreign key constraints work."

**schema.yml syntax correct.** The responder's `data_tests: - relationships: {to: ref('customers'), field: customer_id}` is the legacy flat-form syntax that still compiles in dbt 1.x. dbt 1.10+ canonical adds an `arguments:` nesting level, but flat form is still supported and is what most production projects use. Note: `field:` should be the PARENT-table primary key column. The engineer's framing ("customer_id must exist in customers") implies customers.customer_id is the PK — if customers uses a different PK column name (e.g. `id`), the responder's `field: customer_id` would be wrong. Mild ambiguity but matches the engineer's naming.

**NOT EXISTS compilation claim is roughly correct.** dbt docs don't quote the exact compiled SQL, but the underlying pattern dbt uses for `relationships` is a `SELECT child.field FROM child LEFT JOIN parent ON child.field = parent.field WHERE parent.field IS NULL AND child.field IS NOT NULL` (anti-join) shape — equivalent to NOT EXISTS. Zero rows returned = pass. Reasonable framing for a Haiku-level explanation.

**`source()` variant for raw external sources** correctly mentioned, which is the right routing for testing references from ingested fact tables back to ingested dim tables before dbt models exist for them.

**Scoring rationale.**
- **Acc 5.0** — relationships is real, schema.yml shape compiles, source() variant correct.
- **Clar 4.5** — clean explanation; "anti-join" technical term used without one-sentence zero-assumption framing.
- **Prac 4.75** — engineer can drop this into schema.yml and run `dbt test` immediately.
- **Compl 4.25** — minor: didn't surface dbt 1.10+ `arguments:` nested form; didn't surface `where:` filter for partial-table tests; didn't mention severity config (warn vs error). Not load-bearing for the core question.

### Q4 — Oracle DECODE(plan_tier, 'starter', 1, 'growth', 2, 'enterprise', 3, 0) → Trino

**Score 4.75** (Acc 5.0 / Clar 4.75 / Prac 5.0 / Compl 4.25)

**No DECODE in Trino 467** — verified via [trino.io/docs/467/functions/list.html](https://trino.io/docs/467/functions/list.html) function index (DECODE is not present; the Oracle/PL/SQL list-of-pairs short-circuit form is Oracle-specific).

**Simple CASE shorthand correct:** `CASE plan_tier WHEN 'starter' THEN 1 WHEN 'growth' THEN 2 WHEN 'enterprise' THEN 3 ELSE 0 END`. This is the less-verbose form vs searched CASE `CASE WHEN plan_tier='starter' THEN 1 WHEN plan_tier='growth' THEN 2 ...` and is the right migration target.

**NULL caveat correct and load-bearing.** Oracle DECODE matches NULL=NULL as TRUE; Trino simple CASE uses `=` equality which returns UNKNOWN on NULL → `WHEN NULL` never fires (this is ANSI standard behavior in Trino — verified via the conditional expression section of the docs). Correct routing: use searched CASE `WHEN plan_tier IS NULL THEN X` FIRST, then chain the equality branches.

**Scoring rationale.**
- **Acc 5.0** — DECODE absent, simple CASE shape correct, NULL semantics correct.
- **Clar 4.75** — clean side-by-side with the original DECODE shown; NULL trap explained with the WHY (= NULL → UNKNOWN), not just the WHAT.
- **Prac 5.0** — engineer can paste-and-run, NULL caveat is exactly the production-migration gotcha they'd hit on a real plan_tier nullable column.
- **Compl 4.25** — didn't mention `COALESCE` as a NULL→sentinel pre-wrap alternative (`CASE COALESCE(plan_tier, '__null__') WHEN ...`) for cases where NULL handling needs to stay inside the simple-CASE shape. Minor.

---

## Overall pattern

- **Q1 is a hard regression on a topic that was correctly answered in iter1255 + iter1270.** Root cause: contradictory resources (r17 said 469+, r03/r18 said 467-OK). The responder picked the wrong one. Teacher's r17 §713/§1012 reconcile this iter is the correct fix.
- **Q2 is a question-comprehension miss on a worked-example question.** Mechanism right, framing wrong, engineer gets the wrong number.
- **Q3 + Q4 are clean PASSes.**

The pass-loop continues — average 3.59 is above the 3.5 threshold — but Q1 is the kind of regression that drags topic averages backwards. The r17 reconcile should close the loop; verify next 1-2 iters.

## Watches

**OPEN (new):**
- `iter1271 Q1 bloom-CREATE-467-vs-469 r17-reconcile FIX-A reach test` — re-probe bloom-on-NEW-Iceberg-table framings within 2 iters to verify the r17 §713/§1012 reconcile fired.
- `iter1271 Q2 current-vs-longest-streak final-aggregation framing` — re-probe gaps-and-islands "current" vs "longest" framings 4-8 iters.

**OPEN (carried):**
- `iter1270 Q1 PRIMARY-KEY-in-CREATE-TABLE + cols-with-AS-SELECT-mix synthesis slip` — did NOT recur this iter (responder never reached a CREATE statement), so watch is uncovered; carry forward.
- `iter1268 Q3 grants-USER-vs-ROLE`
- `iter1267 Q1+Q2 example-GROUP-BY-shape`
- `iter1260 Q1 CDC-MERGE-multi-event-dedup`
- `iter1248 Q3 MATCH_RECOGNIZE-adjacency`
- `iter1229 @v1-Spark`

## Sources

- [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) — parquet_bloom_filter_columns canonical CREATE example + ALTER SET PROPERTIES list (does NOT include bloom on 467)
- [trino.io/docs/467/functions/list.html](https://trino.io/docs/467/functions/list.html) — DECODE absence + CASE conditional support
- [docs.getdbt.com/reference/resource-properties/data-tests](https://docs.getdbt.com/reference/resource-properties/data-tests) — relationships built-in generic test
- [trinodb/trino PR #24573](https://github.com/trinodb/trino/pull/24573) — ALTER SET PROPERTIES for parquet_bloom_filter_columns landed in 469
- pinned `reference_trino_parquet_bloom_filter_469.md` — CREATE-vs-ALTER cutoff
- pinned `feedback_reconcile_dont_append.md` — sibling-resource reconcile pattern
