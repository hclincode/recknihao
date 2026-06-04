# Judge Feedback — Iter 447 (EXTENDED PHASE — end-of-iteration only)

**Overall: 4.234 PASS** (Q1 4.5625 + Q2 4.625 + Q3 3.9375 + Q4 3.8125) — **-0.32 step-DOWN from iter446 4.5547**. **NEW BREADTH DESIGN: federation NOT directly probed this iter — topic stays as recorded near-miss at 4.49944/310 (FAIL by -0.00056). Two NEW confident-inaccuracies this iter: (a) Q3 Trino ANALYZE syntax regression — `ANALYZE TABLE iceberg.analytics.orders` is Spark/Hive syntax that FAILS in Trino (correct: `ANALYZE iceberg.analytics.orders` — NO TABLE keyword); (b) Q4 fabricated `ALTER TABLE ... SET ROW FILTER` Iceberg DDL + miscited PR #16569 (which is actually Iceberg branch read, NOT row filters).** Zero-inaccuracy streak BROKEN at 2 fresh fabrications. Federation untouched/not-probed this iter — recorded near-miss preserved.

---

## HEADLINE

1. **Q3 TRINO ANALYZE — REGRESSION CONFIDENT-INACCURACY.** Responder wrote `ANALYZE TABLE iceberg.analytics.orders` as the Trino command in multiple places (dbt on-run-end hook AND standalone refresh commands). This is WRONG for Trino — the correct Trino syntax is `ANALYZE <table>` with NO `TABLE` keyword (verified per trino.io/docs/current/sql/analyze.html: `ANALYZE table_name [ WITH ( property_name = expression [, ...] ) ]`). `ANALYZE TABLE` is Spark/Hive syntax. An engineer pasting `ANALYZE TABLE iceberg.analytics.orders` into Trino CLI/JDBC hits a parse error: `mismatched input 'iceberg'. Expecting: '.', 'WITH'`. The Spark-side `spark.sql("ANALYZE TABLE ... COMPUTE STATISTICS")` IS correct in Spark context — but the responder mixed the keyword into Trino commands too. This is a REGRESSION — the same answer pattern was correct at iter429/437. Same root cause as the iter446 string-pushdown name fabrication: confidently copy-paste-ready command that does not parse.

2. **Q4 ROW-FILTER + PR #16569 — TWO CONFIDENT-INACCURACIES IN OPTION 3.**
   - **Fabricated DDL.** `ALTER TABLE ... SET ROW FILTER column(tenant_id) = CONTEXT_PRINCIPAL()` is NOT real Iceberg or Trino syntax. Iceberg has no `SET ROW FILTER` DDL; Trino row-level filtering is implemented via system access control (OPA plugin, file-based access-control rules) — NOT a per-table DDL clause. `CONTEXT_PRINCIPAL()` is also not a Trino function (Trino has `current_user`/`current_groups`).
   - **Miscited PR.** Cited "PR #16569 added support" — verified via GitHub search: trinodb/trino #16569 is "Support Iceberg branch read" (titled `SELECT * FROM "table$branch_name"`), NOT row filters. The citation is wrong.
   - The responder DID hedge ("not yet mature", "NOT standard Trino") — that partially mitigates but does NOT cancel a fabricated DDL form + wrong PR number. An engineer copy-pasting the SET ROW FILTER line will hit a parse error, and the PR citation will erode trust when followed-up.
   - Option 1 (per-tenant views + REVOKE base table) and Option 2 (OPA/JWT + external governance doc) are SOUND and fit prod env.

3. **Q1 CONNECT BY → WITH RECURSIVE — PASS 4.5625.** Accurate: experimental flag, `max_recursion_depth` default 10, base + recursive UNION ALL pattern, closure-table alternative for deep trees. Verified per trino.io/docs/current/sql/select.html.

4. **Q2 SELECT * WIDE TABLE — STRONG PASS 4.625.** Accurate: Parquet columnar — only named columns read off disk; SELECT * reads ALL 80 columns; network I/O dominates worker-to-coordinator; fix is explicit column list; EXPLAIN ANALYZE Physical Input bytes verification; correct note that low-cardinality strings still deserialize via dictionary/RLE even though compressed.

---

## Critical confirmations (explicit)

### (a) Q3 ANALYZE-TABLE-keyword verdict — CORRECT or WRONG?

**WRONG. CONFIDENT-INACCURACY (regression).**

Per trino.io/docs/current/sql/analyze.html the syntax is:
```
ANALYZE table_name [ WITH ( property_name = expression [, ...] ) ]
```

Examples from the official docs: `ANALYZE web;` and `ANALYZE hive.default.stores;` — all using the bare `ANALYZE` keyword followed by the fully-qualified table name. There is NO `TABLE` keyword between `ANALYZE` and the table name in Trino.

The responder's recurring `ANALYZE TABLE iceberg.analytics.orders` is Spark/Hive syntax (Spark uses `ANALYZE TABLE <table> COMPUTE STATISTICS`). When pasted into a Trino session it raises a parse error. This is a REGRESSION because iter429 and iter437 had this correct.

Spark context note: the responder's `spark.sql("ANALYZE TABLE iceberg.analytics.orders COMPUTE STATISTICS FOR ALL COLUMNS")` is CORRECT — Spark does use `ANALYZE TABLE`. The error is restricted to Trino-context invocations (dbt on-run-end hook + Trino CLI refresh examples).

Other Q3 claims verified:
- Trino does NOT auto-refresh stats after INSERT/COPY into Iceberg — CORRECT (Trino's ANALYZE writes stats; new data files don't update Puffin NDV).
- `SHOW STATS FOR <table>` to inspect — CORRECT.
- NDV stored in Puffin sidecar — CORRECT per iceberg.apache.org/puffin-spec/.
- `drop_extended_stats` footgun before column-subset re-analyze — CORRECT (if mentioned).

### (b) Q4 SET-ROW-FILTER + PR #16569 verdict — REAL or FABRICATED?

**BOTH FABRICATED.**

(i) **`ALTER TABLE ... SET ROW FILTER column(tenant_id) = CONTEXT_PRINCIPAL()` is NOT real syntax.** Verified by web search and Trino docs:
   - Iceberg spec has no row-filter DDL. Iceberg row-level filtering (delete files) is via `MERGE INTO`/`DELETE`, not a SET ROW FILTER clause on the table definition.
   - Trino row-level filtering is implemented OUTSIDE the table DDL — via system access control plugins (`access-control.name=opa` or `access-control.name=file`). File-based rules use `etc/rules.json` schema with `tables.filter` per-role row filters; OPA plugin evaluates per-query policies. Neither uses `ALTER TABLE ... SET ROW FILTER`.
   - No Trino built-in function called `CONTEXT_PRINCIPAL()`. Trino exposes `current_user`, `current_groups()`, `current_catalog`, `current_schema` for session context.

(ii) **PR #16569 citation is wrong.** Verified via GitHub: trinodb/trino issue #16569 is titled **"Support Iceberg branch read"** (open March 2023; goal: enable `SELECT * FROM "table$branch_test"`). Has nothing to do with row filters.

Hedge mitigation: responder did say "not yet mature" / "NOT standard Trino" — this partially softens the claim but does NOT excuse pairing a fabricated DDL form with a wrong PR number. An engineer following the hedge ("let me try this experimental thing") hits a parse error on line 1 and finds nothing matching when chasing PR #16569.

(iii) Option 1 (per-tenant views + REVOKE on base table) and Option 2 (OPA/JWT, defer to external governance doc) — SOUND. Option 2 correctly fits prod_info.md (OPA + JWT + external governance doc). Confirmed.

### (c) Any other new confident-inaccuracies this iter?

None beyond (a) and (b).

### (d) Verified-claim spot checks

- **Q1 WITH RECURSIVE experimental + max_recursion_depth default 10** — VERIFIED per trino.io/docs/current/sql/select.html: "This feature is experimental only." Default depth limit 10 confirmed via GitHub issue #4771 referencing "Recursion depth limit exceeded (10)".
- **Q1 base + recursive UNION ALL pattern** — CORRECT; canonical SQL standard recursive CTE form.
- **Q1 closure-table alternative for deep trees** — CORRECT; classic graph-flattening pattern for hierarchies where recursive query overhead is unacceptable.
- **Q2 Parquet columnar — only named columns read** — VERIFIED; Parquet's row-group + column-chunk layout enables per-column file-section reads.
- **Q2 SELECT * reads all 80 columns** — CORRECT; Trino's optimizer expands SELECT * before pushdown.
- **Q2 EXPLAIN ANALYZE Physical Input bytes** — CORRECT verification path (per trino.io/docs/current/sql/explain-analyze.html).
- **Q2 low-cardinality strings dict/RLE compress but still deserialize** — CORRECT; compression reduces storage but deserialization cost remains per-row.
- **Q3 Trino ANALYZE syntax** — RESPONDER WRONG (`ANALYZE TABLE` is Spark, not Trino). See (a).
- **Q3 NDV in Puffin** — CORRECT per iceberg.apache.org/puffin-spec/.
- **Q3 SHOW STATS FOR / no auto-refresh** — CORRECT.
- **Q4 SET ROW FILTER + CONTEXT_PRINCIPAL() + PR #16569** — RESPONDER WRONG (fabricated DDL + miscited PR). See (b).
- **Q4 per-tenant views + REVOKE base** — CORRECT canonical isolation pattern.
- **Q4 OPA/JWT + external governance doc** — CORRECT per prod_info.md.

---

## Per-question scoring

### Q1 — Oracle CONNECT BY → WITH RECURSIVE migration

**Scores: 4.75 / 4.5 / 4.5 / 4.5 — avg 4.5625 PASS**

What landed correct:
- Trino WITH RECURSIVE is experimental — CORRECT.
- `max_recursion_depth` session property default 10 — CORRECT.
- Base + recursive UNION ALL pattern shown — CORRECT.
- Closure-table alternative for deep trees / wide hierarchies — CORRECT.

Docks:
- BC dock 0.5: dense; a small 2-step "Oracle CONNECT BY example" → "Trino WITH RECURSIVE equivalent" side-by-side comparison would help an engineer with no recursive-CTE background.
- PA dock 0.5: could state explicitly that depth-10 default will silently truncate org-charts >10 levels — engineer should `SET SESSION max_recursion_depth = 50;` (or similar) before running.
- Comp dock 0.5: could mention quadratic plan-size growth with depth (per Trino docs warning).

### Q2 — SELECT * on wide 80-column table

**Scores: 4.75 / 4.5 / 4.75 / 4.5 — avg 4.625 STRONG PASS**

What landed correct:
- Parquet is columnar — only named columns read off disk; SELECT * forces all 80 columns — CORRECT.
- Network I/O dominates (worker → coordinator serialization) — CORRECT.
- Fix is explicit column list — CORRECT actionable guidance.
- EXPLAIN ANALYZE Physical Input bytes verification — CORRECT.
- Low-cardinality strings dict/RLE compress but still deserialize per row — CORRECT subtle point.

Docks:
- BC dock 0.5: "columnar" / "deserialize" / "RLE" not always glossed.
- Comp dock 0.5: could mention that dbt models defaulting to `SELECT *` from upstream sources propagate this anti-pattern down the DAG — fix at source.

### Q3 — Stale stats after big load (Trino CBO / ANALYZE)

**Scores: 3.5 / 4.5 / 3.5 / 4.25 — avg 3.9375 PASS (drags topic)**

What landed correct:
- Trino does NOT auto-refresh stats after big INSERT/COPY — CORRECT.
- `SHOW STATS FOR <table>` to verify staleness (estimates vs actual) — CORRECT.
- NDV stored in Puffin sidecar — CORRECT.
- Spark-side `spark.sql("ANALYZE TABLE ... COMPUTE STATISTICS FOR ALL COLUMNS")` — CORRECT in Spark context.

What landed WRONG (CONFIDENT-INACCURACY):
- **Trino command `ANALYZE TABLE iceberg.analytics.orders` is invalid.** Trino syntax is `ANALYZE iceberg.analytics.orders` (NO TABLE keyword) per trino.io/docs/current/sql/analyze.html. This wrong form appeared in MULTIPLE places: the dbt `on-run-end` hook example AND standalone "after big load" refresh commands. An engineer pasting either will hit a parse error. This is a REGRESSION — iter429/437 had this correct.

Docks:
- TA dock 1.5: recurring confidently-wrong syntax that breaks copy-paste; same failure mode as iter446 string-pushdown name fabrication.
- PA dock 1.5: the remediation path (the dbt hook + manual refresh command) is the most actionable part and it's the broken part.
- Comp dock 0.75: could mention column-targeted `ANALYZE table WITH (columns = ARRAY['col_a','col_b'])` to reduce refresh cost on 500GB+ tables, and `drop_extended_stats` footgun if previous full ANALYZE was column-targeted.

**Verdict:** PASS but below topic mean (4.7341 → 4.6618, -0.0723 nudge DOWN). Trino CBO topic remains PASSED (4.6618 > 4.5 raised threshold) but margin shrinks.

### Q4 — Row-level tenant isolation (multi-tenant)

**Scores: 3.0 / 4.25 / 3.5 / 4.5 — avg 3.8125 PASS (drags topic)**

What landed correct:
- Option 1: per-tenant views + REVOKE on base table — SOUND canonical SQL-only isolation pattern.
- Option 2: OPA/JWT — defer specific policy rules to external governance doc — CORRECT per prod_info.md.
- Trade-offs discussion (Option 1 = high view-count maintenance; Option 2 = central policy + on-prem fit) — CORRECT.

What landed WRONG (TWO CONFIDENT-INACCURACIES in Option 3):
- **Fabricated DDL**: `ALTER TABLE ... SET ROW FILTER column(tenant_id) = CONTEXT_PRINCIPAL()` is NOT real Iceberg or Trino syntax. Iceberg has no SET ROW FILTER clause; Trino row-filtering is via system access control plugins (OPA / file-based rules), NOT per-table DDL. `CONTEXT_PRINCIPAL()` is not a Trino function.
- **Miscited PR**: trinodb/trino #16569 is "Support Iceberg branch read", NOT row filters. An engineer following this citation will find nothing matching.

Docks:
- TA dock 2.0: two fabrications in a single option even though hedged. Hedge ("not yet mature") softens but does not erase invalid DDL + wrong PR.
- PA dock 1.5: engineer might attempt the SET ROW FILTER command in a sandbox to "see if it works" — wastes cycles before realizing nothing matches in Trino source.
- BC dock 0.75: Option 3 framing is confusing because it presents a non-existent feature as a "third option" alongside two real options.

**Verdict:** PASS but well below topic mean — drags multi-tenant 4.4549 → 4.4505 (-0.0044). Topic remains PASSED (> 3.5 baseline) but margin erodes.

---

## Topic-score updates

| Topic | Before | After | Delta | Status |
|---|---|---|---|---|
| Oracle PL/SQL → dbt + Trino SQL migration | 4.6407 / 22 | **4.6371 / 23** | -0.0036 | PASSED — Q1 4.5625 below topic mean, slight nudge down |
| SQL query best practices for OLAP | 4.5726 / 40 | **4.5739 / 41** | +0.0013 | PASSED — Q2 4.625 above topic mean, slight nudge up |
| Trino CBO / ANALYZE TABLE / Puffin statistics / NDV / join ordering | 4.7341 / 10 | **4.6618 / 11** | -0.0723 | PASSED — Q3 3.9375 well below topic mean; ANALYZE syntax regression drags average DOWN; margin to 4.5 threshold shrinks from +0.234 to +0.162 |
| Multi-tenant analytics: isolating customer data in SaaS | 4.4549 / 147 | **4.4505 / 148** | -0.0044 | PASSED — Q4 3.8125 below topic mean, slight nudge down |
| Trino federation / cross-source connectors | 4.49944 / 310 | **4.49944 / 310** | 0 (NOT PROBED) | FAIL — preserved near-miss; new breadth design skipped dedicated federation probe |

(Column-oriented storage topic NOT updated — Q2 mapped primarily to SQL query best practices for OLAP per user mapping; Column-oriented storage covered tangentially but not the primary frame.)

---

## Pattern across all four answers

| Q | Score | Topic | Verdict |
|---|---|---|---|
| Q1 | 4.5625 | Oracle migration (CONNECT BY → WITH RECURSIVE) | PASS — experimental flag, depth-10 default, base+recursive UNION ALL, closure-table fallback all canonical |
| Q2 | 4.625 | SQL best practices OLAP (SELECT * on 80-col Parquet) | STRONG PASS — columnar economics + EXPLAIN Physical Input bytes verification correct |
| Q3 | 3.9375 | Trino CBO / ANALYZE (stale stats after big load) | PASS — but `ANALYZE TABLE` Spark-vs-Trino keyword regression confidently wrong |
| Q4 | 3.8125 | Multi-tenant (row-level tenant isolation) | PASS — Options 1+2 sound; Option 3 fabricated DDL + miscited PR |

**Average 4.234 PASS — -0.32 step-DOWN from iter446 4.5547.** Two NEW confident-inaccuracies this iter (Trino ANALYZE keyword regression on Q3 + SET ROW FILTER fabrication + PR #16569 miscitation on Q4).

**Headline outcomes:**
- **TWO new confident-inaccuracies** (Q3 + Q4) — zero-inaccuracy streak broken at 0 iters (iter446 had 1, iter447 has 2 — accelerating not slowing).
- **FEDERATION not probed** — near-miss 4.49944/310 preserved.
- **NEW BREADTH DESIGN tradeoff visible**: by not probing federation this iter, judge surfaced regressions in two previously-PASSING topics (Trino CBO ANALYZE syntax, multi-tenant row-isolation DDL claims). Broadening probe coverage is finding stale assumptions.
- **REGRESSION PATTERN**: Q3 `ANALYZE TABLE` was correct at iter429/437 and is now wrong again — same failure mode as iter440/444 Limit-vs-TopN regression. Resource consolidation strategy that fixed Limit-vs-TopN at iter445 must be applied to ANALYZE-keyword resource (r29 Trino CBO).

**Strategic observation:** Iter447's new breadth design exposed TWO regressions in topics whose averages were comfortably above threshold. The signal is that "PASSED" topics with sparse recent probes can silently drift back into confident-inaccuracy territory. The teacher's iter445 leading-worked-example + DO-NOT-WRITE block pattern that fixed Limit-vs-TopN must be replicated for (a) Trino ANALYZE syntax in r29, and (b) Trino row-level filtering "via system access control NOT table DDL" in r33 (or wherever multi-tenant row-isolation lives).

---

## Teacher actions next (iter 448)

1. **CRITICAL — FIX r29 (Trino CBO) Trino ANALYZE syntax canonical worked-example block.** Add a leading directive: "Trino ANALYZE syntax is `ANALYZE <fully-qualified-table>` — NO `TABLE` keyword. `ANALYZE TABLE ...` is Spark/Hive and FAILS in Trino with a parse error." Worked example block:
   ```sql
   -- CORRECT Trino syntax (any Iceberg/Hive/PG table):
   ANALYZE iceberg.analytics.orders;
   ANALYZE iceberg.analytics.orders WITH (columns = ARRAY['user_id', 'created_at']);

   -- CORRECT Spark syntax (Spark Iceberg session only — NOT Trino):
   spark.sql("ANALYZE TABLE iceberg.analytics.orders COMPUTE STATISTICS FOR ALL COLUMNS")
   ```
   DO-NOT-WRITE block:
   - `ANALYZE TABLE iceberg.analytics.orders;` (WRONG in Trino — Spark syntax leaked into Trino context)
   - `ANALYZE TABLE iceberg.analytics.orders COMPUTE STATISTICS;` (WRONG in Trino — Spark syntax + Trino has no COMPUTE STATISTICS clause)
   Add the side-by-side "Trino vs Spark ANALYZE keyword" comparison table at top of section so dbt on-run-end hook examples can copy-paste the correct form.

2. **CRITICAL — FIX r33 (or multi-tenant resource) Trino row-filtering "DDL vs system access control" worked-example block.** Add a leading directive: "Trino row-level filtering is configured in system access control (OPA plugin or file-based rules), NOT via per-table DDL. There is NO `ALTER TABLE ... SET ROW FILTER` clause in Iceberg or Trino." Provide:
   - File-based rules example (`etc/rules.json`) with `tables.filter` per-role (conceptual illustration only — note prod_info.md says actual rules live in external governance doc).
   - OPA policy snippet (conceptual) showing the `data.trino.allow` filter pattern (again conceptual; defer real policies to external doc).
   - Per-tenant view + REVOKE base table pattern (Option 1) as the SQL-only fallback when OPA is unavailable.
   DO-NOT-WRITE block:
   - `ALTER TABLE ... SET ROW FILTER column(tenant_id) = CONTEXT_PRINCIPAL();` (WRONG — fabricated Iceberg DDL; no such clause exists in Iceberg or Trino)
   - `CONTEXT_PRINCIPAL()` as a function reference (WRONG — Trino exposes `current_user`, `current_groups()`)
   Citation cleanup: remove ANY reference to trinodb/trino PR #16569 in row-filter context — that PR is "Support Iceberg branch read" per github.com/trinodb/trino/issues/16569.

3. **HIGH — Loop posture: regression-on-revisit pattern.** Two iterations in a row (iter446 PostgreSQL session-property fabrication, iter447 Trino ANALYZE keyword regression) have surfaced confident-inaccuracies on previously-correct material. The teacher must add a "CITATION HYGIENE" guardrail in resources: when responder cites a specific PR number, function name, or DDL clause that does not appear verbatim in trino.io docs, that line MUST carry a "VERIFY: not in trino.io/docs" disclaimer or be removed.

4. **MEDIUM — Federation NOT probed this iter.** Topic stays at 4.49944/310 near-miss. Judge iter448 should probe federation directly to either confirm the near-miss or move it. Suggested probe: CAST-wrapped pushdown break ("Does `WHERE CAST(account_id AS VARCHAR) = '12345'` push to Postgres?") — expected NO, rewrite as `account_id = 12345`.

---

## Judge probe targets next (iter 448) — RECOMMENDED

1. **HIGH — Re-probe Trino ANALYZE keyword directly.** Ask: "What's the exact Trino command to refresh stats on `iceberg.analytics.orders` after a big incremental load?" Expected: `ANALYZE iceberg.analytics.orders;` (NO `TABLE` keyword). Confirm iter447 Q3 regression is fixed.

2. **HIGH — Re-probe Trino row-filtering implementation.** Ask: "How do I enforce row-level tenant isolation on an Iceberg table in Trino?" Expected: OPA plugin or file-based access control (NOT `ALTER TABLE ... SET ROW FILTER` — no such DDL). Per-tenant views + REVOKE base table as SQL-only fallback.

3. **HIGH — Federation probe (skipped this iter).** CAST-wrapped predicate pushdown break: "Does `WHERE CAST(account_id AS VARCHAR) = '12345'` push to Postgres?" Expected NO — CAST on the column side breaks pushdown.

4. **MEDIUM — Column-targeted ANALYZE syntax.** Ask: "How do I run ANALYZE on only the join-key columns of a 500GB table to save time?" Expected: `ANALYZE iceberg.analytics.orders WITH (columns = ARRAY['user_id', 'product_id']);` (Trino syntax, NO TABLE keyword) + `drop_extended_stats` footgun warning if previous full ANALYZE was column-targeted.

5. **MEDIUM — `CALL system.<procedure>` vs DDL clause discrimination.** Ask: "Is there a Trino DDL to mask credit-card columns for non-admin users?" Expected: NO standard DDL; column masking via OPA plugin or file-based `tables.columns` rules. (Tests whether responder will fabricate another `ALTER TABLE ... SET COLUMN MASK` clause.)

6. **LOW — Carry forward** federation pushdown corner cases (LIKE prefix, OR-of-equality), expire_snapshots durability, isolation-level write props.

---

## Critical message to teacher for iter 448

**Iter447 is a 4.234 PASS overall but TWO NEW CONFIDENT-INACCURACIES surfaced** — a Trino ANALYZE keyword REGRESSION on Q3 (Spark/Hive `ANALYZE TABLE` leaked into Trino context; correct: `ANALYZE <table>` with no TABLE keyword per trino.io/docs/current/sql/analyze.html) and a Q4 Option-3 FABRICATION pair (`ALTER TABLE ... SET ROW FILTER column(tenant_id) = CONTEXT_PRINCIPAL()` — fabricated DDL that doesn't exist in Iceberg or Trino; cited PR #16569 which is actually "Support Iceberg branch read" not row filters).

**KEY iter448 PRIORITIES:**
1. **FIX r29 Trino ANALYZE syntax** with leading directive + worked example + DO-NOT-WRITE block. Use the iter445 Limit-vs-TopN consolidation recipe.
2. **FIX r33/multi-tenant Trino row-filtering** with leading directive that says row-filtering is via OPA/file-based access control, NOT DDL. Include DO-NOT-WRITE for SET ROW FILTER and PR #16569 citation. Defer specific policy rules to external governance doc per prod_info.md.
3. **Add CITATION HYGIENE guardrail** to resources so PR numbers / function names / DDL clauses get verify-against-trino.io discipline.

**Q1 Oracle CONNECT BY → WITH RECURSIVE PASS 4.5625** — experimental flag + depth-10 default + base/recursive UNION ALL + closure-table fallback all canonical.

**Q2 SELECT * on wide 80-column Parquet STRONG PASS 4.625** — columnar economics correct, EXPLAIN ANALYZE Physical Input bytes verification correct, dict/RLE compression nuance correct.

**Q3 Trino ANALYZE stale-stats PASS 3.9375** — surrounding claims correct (no auto-refresh, SHOW STATS FOR, NDV in Puffin) BUT `ANALYZE TABLE` Trino syntax is WRONG (regression from iter429/437 correct form).

**Q4 row-level tenant isolation PASS 3.8125** — Options 1 (per-tenant views + REVOKE) and 2 (OPA/JWT external governance doc) SOUND but Option 3 has TWO fabrications (SET ROW FILTER DDL + PR #16569 miscitation).

**Loop status:** Federation NOT probed this iter (new breadth design intentional). Two new confident-inaccuracies in topics OUTSIDE federation. Pattern signal: broadening probe coverage finds stale assumptions in PASSED topics. 46th consecutive overall PASS in extended phase.

**Other key verifications this iter:**
- Trino ANALYZE syntax `ANALYZE <table>` with NO `TABLE` keyword — VERIFIED per trino.io/docs/current/sql/analyze.html.
- trinodb/trino PR #16569 is "Support Iceberg branch read" NOT row filters — VERIFIED per github.com/trinodb/trino/issues/16569.
- Trino has no `ALTER TABLE ... SET ROW FILTER` DDL; row filtering is via system access control plugins — VERIFIED per trino.io/docs/current/security/file-system-access-control.html and trino.io/docs/current/security/opa-access-control.html.
- Trino WITH RECURSIVE experimental with `max_recursion_depth` session property default 10 — VERIFIED per trino.io/docs/current/sql/select.html and GitHub issue #4771.
- Parquet columnar: SELECT * forces read of all named columns — VERIFIED per Parquet format spec.
