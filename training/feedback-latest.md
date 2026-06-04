# Judge Feedback — Iter 458 (2026-06-05)

## Overall verdict

**4.109 PASS overall** — 57th consecutive PASS, BUT margin THIN. Q1+Q2+Q4 all STRONG (4.6+); **Q3 is a CRITICAL FAIL (2.375)** with TWO load-bearing fabrications on a single answer. Federation NOT probed per iteration directive.

## Per-question breakdown

| Q | Topic | Acc | Comp | Clar | Act | Avg | Verdict |
|---|---|---|---|---|---|---|---|
| Q1 | Per-tenant Trino cost attribution / chargeback (Cost considerations) | 4.75 | 4.75 | 4.5 | 4.75 | **4.6875** | STRONG PASS |
| Q2 | Session properties to speed a slow query (Query perf regression) | 4.75 | 4.5 | 4.5 | 4.75 | **4.625** | STRONG PASS |
| Q3 | Iceberg ADD COLUMN with DEFAULT (Schema evolution / maintenance) | 1.5 | 2.5 | 3.75 | 1.75 | **2.375** | CRITICAL FAIL |
| Q4 | Oracle LISTAGG → Trino (Oracle migration) | 4.75 | 4.75 | 4.75 | 4.75 | **4.75** | STRONG PASS |

**Overall avg: 4.109 PASS** (threshold 3.5).

## Fabrications detected

### Q3 — TWO load-bearing fabrications (both confirmed against official docs)

**FAB-1: `ALTER TABLE iceberg.analytics.my_table ADD COLUMN new_status VARCHAR DEFAULT 'pending'` is a PARSE ERROR on Trino 467.**

- Support for `DEFAULT` clause in `ALTER TABLE ADD COLUMN` was added in **Trino 477** (24 Sep 2025), per release notes.
- Production stack is pinned to **Trino 467** (6 Dec 2024) per `prod_info.md`.
- Engineer copy-pastes the recommended DDL and gets `mismatched input 'DEFAULT'. Expecting: 'COMMENT', 'NOT', 'WITH', <EOF>` or equivalent parse error.
- Trino 467 grammar for ADD COLUMN: `ADD COLUMN [IF NOT EXISTS] name type [COMMENT ...] [WITH (...)]` — NO DEFAULT clause. (Trino 481 grammar adds DEFAULT / NOT NULL / FIRST | LAST | AFTER positioning, but that's irrelevant for the 467 prod stack.)
- Sources:
  - https://trino.io/docs/current/release/release-477.html ("Add support for default column values when creating tables or adding new columns")
  - https://trino.io/docs/current/release/release-467.html (no DEFAULT-clause feature listed)
  - https://trino.io/docs/current/sql/alter-table.html (current grammar shows DEFAULT, but this is 481 — not 467)

**FAB-2: "All existing rows automatically return 'pending' for the new column on read" is WRONG for Iceberg 1.5.2 (format v2).**

- The `initial-default` mechanism that backfills existing rows with the default at read time is an **Iceberg format-v3 spec feature**.
- Production stack uses **Iceberg 1.5.2** per `prod_info.md`, which is firmly format-v2 era.
- On v2 tables, existing rows return **NULL** for the newly added column. The default value applies only to NEW writes (`write-default`), not to historical reads.
- Sources:
  - https://iceberg.apache.org/spec/ (initial-default and write-default introduced in v3 schema evolution)
  - https://www.dremio.com/blog/dremio-iceberg-v3-default-column-values/ ("existing rows return the default value for the new column ... this is a significant improvement over v2, where the values of newly added columns on existing rows are NULL")
  - https://www.starburst.io/blog/iceberg-v3/ (confirms initial-default as v3 feature)

**Correct answer for the prod stack (Trino 467 + Iceberg 1.5.2):**

```sql
ALTER TABLE iceberg.analytics.my_table ADD COLUMN new_status VARCHAR COMMENT 'lifecycle status';
-- Metadata-only commit (TRUE — this part of the answer is correct).
-- Existing rows return NULL on read until backfilled.

-- To backfill a value:
UPDATE iceberg.analytics.my_table SET new_status = 'pending' WHERE new_status IS NULL;
-- Note: on Iceberg 1.5.2 MoR, UPDATE creates equality delete files;
-- consider a Spark INSERT OVERWRITE if you can rewrite the whole table at higher I/O cost.
```

### Q1, Q2, Q4 — ZERO fabrications

All verified against:
- `system.runtime.queries` columns (query_id, state, source, user, etc.) — confirmed via Trino GitHub discussion + system connector docs.
- `system.runtime.tasks` exists with CPU and bytes metrics consistent with Trino's task data model.
- `query_max_memory_per_node` (30% JVM heap default), `join_distribution_type` (PARTITIONED/BROADCAST/AUTOMATIC), `join_max_broadcast_table_size` (100MB default), `task_concurrency` (node-CPU default, min 2 max 32) — all real session properties per trino.io/docs/current/admin/properties-*.html and optimizer/cost-based-optimizations.html.
- LISTAGG with `ON OVERFLOW TRUNCATE ... WITH COUNT` and `WITHIN GROUP (ORDER BY ...)` syntax + **1,048,576 byte** default overflow threshold — verified verbatim per https://trino.io/docs/current/functions/aggregate.html.
- `array_join(array_agg(...))` pre-LISTAGG fallback valid; LISTAGG was added in Trino 358 (Jun 2021).

## Concrete teacher actions for iter459

### Priority 1 — NEW FAB CLASS: version-availability hallucination

The Q3 failure is a **new fab class** — version-gated feature presented as if available on the production stack. The responder hallucinated Trino 477+ syntax onto Trino 467 AND hallucinated Iceberg format-v3 read semantics onto Iceberg 1.5.2 (format v2). This is structurally similar to the iter456 dialect-spillover fabs but with a version-availability twist.

**Action**: Add a LEADING CANONICAL block to `resources/17-iceberg-table-maintenance.md` (or create a new resource subsection "Iceberg schema evolution on Trino 467 + Iceberg 1.5.2") with the following structure:

1. **Title**: "LEADING CANONICAL ICEBERG SCHEMA EVOLUTION ON TRINO 467 + ICEBERG 1.5.2 — 'How do I ADD COLUMN with a default value?'"
2. **Pinned-version banner**: Top-of-block callout citing `prod_info.md` Trino 467 + Iceberg 1.5.2 pin, with the warning that newer Trino/Iceberg releases support features (DEFAULT clause, initial-default) that **DO NOT exist on the prod stack**.
3. **CORRECT pattern verbatim**:
   ```sql
   ALTER TABLE iceberg.analytics.t ADD COLUMN new_col VARCHAR COMMENT '...';
   -- Metadata-only commit (Iceberg field-ID-based schema evolution). Existing data files NOT rewritten.
   -- Existing rows read as NULL for new_col until backfilled.
   ```
4. **Backfill pattern verbatim**:
   ```sql
   UPDATE iceberg.analytics.t SET new_col = 'pending' WHERE new_col IS NULL;
   ```
   With explicit Iceberg 1.5.2 MoR cost callout (creates equality delete files; alternative: Spark `INSERT OVERWRITE` to rewrite the whole table at higher I/O cost but no delete files).
5. **DO-NOT-WRITE matrix** banning at minimum:
   - `ADD COLUMN ... DEFAULT '<literal>'` syntax on Trino 467 → parse error; this syntax was added in **Trino 477** (24 Sep 2025), production stack is pinned to 467.
   - The claim "existing rows return the default value" on Iceberg 1.5.2 → requires Iceberg format v3 `initial-default`; production stack is Iceberg 1.5.2 (format v2), existing rows return NULL.
   - `ALTER TABLE ... ALTER COLUMN ... SET DEFAULT` → Trino 479+, not on 467.
   - `NOT NULL` on ADD COLUMN without DEFAULT → see prestodb/presto issue #20618 for the design problem.
   - **The broader fab-class meta-rule**: "Before recommending a Trino DDL clause, verify it exists in **Trino 467** (release-467.html and earlier); before recommending an Iceberg behavior, verify it exists in **Iceberg format v2** (Iceberg 1.5.2)."
6. **Cross-ref** to `prod_info.md` pinned versions at the top of the new block so the responder cannot mistakenly assume the latest release behavior applies.

### Priority 2 — Reinforce iter458 wins

The iter458 teacher LEADING CANONICAL blocks for Q1 (r16 per-tenant cost attribution) and Q2 (r18 session-property tuning) LANDED CLEAN — zero fabs on both. Keep these blocks intact and DO NOT regress. Both topics inched up in average score (cost 4.18→4.21, query-perf-regression 4.31→4.33), confirming the leading-canonical + DO-NOT-WRITE-matrix pattern works on low-buffer topics.

### Priority 3 — Iter459 breadth design (no federation probe per directive)

Federation row UNCHANGED at 4.49944/310. Iter459 should:
- **Q1**: Iceberg schema-evolution RE-PROBE under a different phrasing — verify the iter459 leading canonical block lands and the version-gated fab class is eliminated. Suggested probe: "I need to add a `region` column with a fixed value for all existing rows in a 500GB Iceberg table — what's the minimum-cost path?" (forces the responder to choose between ADD COLUMN + UPDATE backfill vs Spark INSERT OVERWRITE vs leaving NULLs).
- **Q2**: Lowest-buffer PASSED topic re-probe (after iter458's reinforcement, the new lowest-buffer is **Iceberg table maintenance 4.4955/118** which just got dinged by Q3). Probe from a maintenance angle that does NOT touch schema evolution (e.g., expire_snapshots retention floor, optimize partition-spec evolution, orphan file cleanup with active branches).
- **Q3**: A breadth question from a stable-passing topic to maintain the iteration breadth (e.g., Postgres-to-Iceberg ingestion CDC angle, multi-tenant analytics row-filter angle).
- **Q4**: An Oracle-migration angle that is NOT LISTAGG (already iter458) and NOT TO_CHAR (iter457) — e.g., Oracle sequences → Trino, Oracle DECODE → Trino CASE, Oracle CONNECT BY → recursive CTE.

### Priority 4 — Citation hygiene watchlist for iter459 judging

- **Version-availability fabs (NEW class as of iter458 Q3)**: for any DDL clause / session property / function / metadata table the responder recommends, the judge MUST verify it exists in Trino 467 specifically (check release-XXX.html for the feature's introduction release vs the 467 release date 6 Dec 2024).
- **Iceberg spec-version fabs (NEW class as of iter458 Q3)**: for any Iceberg behavior the responder recommends (default values, deletion vectors, row-lineage, etc.), the judge MUST verify it's supported in Iceberg format v2 (Iceberg 1.5.2). v3 features (initial-default, deletion vectors via puffin, row-lineage, geometry/geography types, VARIANT) MUST NOT be presented as if available on the prod stack.
- **Cross-dialect spillover fabs (carryover from iter456)**: query hints `/*+ ... */`, `::` cast operator, `ALTER SESSION SET`, `SET LOCAL`, `TO_CHAR` — all still on the watchlist.
- **Made-up column names** on `system.runtime.queries` / `system.runtime.tasks`: watch for `tenant_id`, `cost_usd`, `credits`, `peak_memory_bytes`, `catalog`, `query_stats` (the table) — none exist.

## Pass status

**PASS** — overall 4.109 above 3.5 floor; all topic averages remain above their per-topic thresholds (cost 4.21 > 3.5; query-perf-regression 4.33 > 3.5; iceberg-table-maintenance 4.4955 > 3.5; oracle-migration 4.5867 > 3.5; federation 4.49944 ≥ 4.5 override-threshold not regressed because not probed). System remains at terminal milestone (all topics passed). Q3 is a worrying single-question FAIL that the teacher MUST address in iter459 to prevent it becoming a recurring fab class. No `passed` state change needed.
