# Judge Feedback — Iter 463 (EXTENDED PHASE)

**Phase**: extended (end-of-iteration feedback only)
**Date**: 2026-06-05
**Overall: 3.656 THIN PASS** (62nd consecutive PASS in extended phase but the thinnest margin in many iters; Q1 is a TRUE FAIL on its own at 2.50 — only the strength of Q2/Q3/Q4 keeps the overall above the 3.5 floor.)

## Per-question breakdown

| Q | Topic | Accuracy | Clarity | Completeness | Actionability | Avg | Verdict |
|---|---|---|---|---|---|---|---|
| Q1 | Iceberg time-travel — branch/tag read | 2.0 | 4.0 | 2.0 | 2.0 | **2.50** | **FAIL** |
| Q2 | dbt incremental MERGE slowdown (MoR deletes) | 3.5 | 4.5 | 4.5 | 3.5 | **4.0** | PASS |
| Q3 | Trino+Iceberg+MinIO cost justification vs Postgres | 4.5 | 4.0 | 3.0 | 3.5 | **3.75** | PASS |
| Q4 | Oracle CONNECT BY → Trino WITH RECURSIVE | 4.0 | 4.5 | 4.5 | 4.5 | **4.375** | PASS |

Overall: (2.50 + 4.0 + 3.75 + 4.375) / 4 = **3.656**

## Fabrications + load-bearing inaccuracies

### Q1 — TWO LOAD-BEARING FABRICATIONS + FINDABILITY MISS + REGRESSION (PRIMARY ISSUE THIS ITER)

**FAB-1**: "the resources do NOT provide detailed syntax for named branches and tags"
- **FALSE.** r17 (resources/17-iceberg-table-maintenance.md) has a full LEADING CANONICAL block (added iter462) covering:
  - `FOR VERSION AS OF '<branch_or_tag_name>'` (string literal)
  - The BIGINT-vs-string clause-disambiguation table
  - The Snowflake / Delta / Spark / Oracle / BigQuery muscle-memory map
  - Worked examples for audit-tag reads and WAP branch reads
- Grep on r17 confirms multiple instances of `FOR VERSION AS OF '<branch-name>'` worked examples, including the explicit statement "Trino 467 cannot create or drop tags, but it CAN query a tagged snapshot using `FOR VERSION AS OF '<tag-name>'`."

**FAB-2**: "With Hive Metastore, branches and named tags are NOT a native feature" / "they are a Project Nessie (REST catalog) feature" / "you'd need to migrate to Nessie"
- **FALSE.** Iceberg branches/tags are a TABLE-LEVEL metadata feature stored in the Iceberg `metadata.json` and readable via the `$refs` metadata table — INDEPENDENT of the catalog.
- Verified at iceberg.apache.org/docs/latest/branching/ — "Branching and Tagging" is listed under the **Tables** section across versions 1.9.x–1.11.x, NOT under any catalog-specific section.
- Verified at trino.io/docs/current/connector/iceberg.html — both `FOR VERSION AS OF 8954597067493422955` (BIGINT) and `FOR VERSION AS OF 'historical-tag'` / `FOR VERSION AS OF 'test-branch'` (string name) are documented; no catalog-type restriction.
- HMS-backed Iceberg supports branches/tags fully: Spark `ALTER TABLE ... CREATE BRANCH` / `CREATE TAG` writes them to `metadata.json`; HMS just keeps the pointer to that file. Nessie adds CATALOG-LEVEL multi-table branch transactions, which is a SEPARATE feature from TABLE-LEVEL branches/tags.

**FINDABILITY MISS**: The correct answer IS in the resources. The responder's keyword search ('branch' + 'Nessie' + 'HMS') landed on r21 (HMS/Nessie interaction) instead of r17 (time-travel + branches/tags). The r17 LEADING CANONICAL block exists; the responder didn't reach it.

**REGRESSION SIGNAL**: iter452/iter453 the responder correctly used `FOR VERSION AS OF '<branch>'` for branch reads. iter463 regressed and projected a fabricated catalog-level restriction onto a catalog-agnostic feature.

**Impact on the engineer**: They either (a) waste weeks evaluating Nessie migration when their HMS already supports the feature, or (b) build a brittle external `branch_name → snapshot_id` mapping table by hand.

### Q2 — LOAD-BEARING SYNTAX FAB (malformed `$files` quoting)

Responder wrote `FROM iceberg.analytics.your_fact_table_here"$files"` — the double-quoted string starts AFTER `your_fact_table_here` instead of wrapping the entire `table$files` identifier.

**Correct form** (per trino.io/docs/current/connector/iceberg.html and trinodb/trino PR #13026):
`FROM iceberg.analytics."your_fact_table_here$files"` — the `$` requires the ENTIRE composite identifier `table$files` to live inside ONE pair of double quotes.

**Consistency note**: iter462 Q3 used the correct form `iceberg.analytics."events$files"`. So this is a quoting drift, not a doc gap — but a load-bearing one: the responder's form fails to parse, so the very first diagnostic step the engineer would run on the production stack doesn't work.

### Q3 — Double "I don't have enough information" hedge

Two hedges in one answer undersell the answerable content (measure storage ratio + amortized Trino cluster $/hr + concurrency multiplier + EXPLAIN-driven CPU on representative queries). No fabrications, but the conclusion is hedged below what the resources actually support. Accuracy stays high (4.5); completeness docked to 3.0.

### Q4 — MINOR VERSION-PIN + "EXPERIMENTAL" OVERSTATEMENT

- "WITH RECURSIVE since release 343" — actually milestoned for release **340** per github.com/trinodb/trino/pull/4250 ("martint added this to the 340 milestone Aug 8, 2020"). Release 343 (25 Sep 2020) notes contain no recursive-CTE entry. Off-by-3 version pin; both are eight-year-old historical releases, so practical impact on a 467 stack is zero, but the citation is wrong.
- "experimental" — WITH RECURSIVE is documented stable in trino.io/docs/current/sql/select.html with no experimental warning. "Fixed recursion depth + quadratic plan growth" are limitations but not "experimental" status.

## Topic-row updates

| Topic | Before | After | Delta | Driver |
|---|---|---|---|---|
| Iceberg table maintenance | 4.4961 / 123 | **4.4842 / 125** | −0.0119 | Q1 2.50 FAIL well below avg + Q2 4.0 slightly below avg (two-question hit) |
| Cost considerations | 4.2079 / 18 | **4.1846 / 19** | −0.0233 | Q3 3.75 below avg (double-hedge) |
| Oracle PL/SQL → dbt/Trino migration | 4.5895 / 36 | **4.5840 / 37** | −0.0055 | Q4 4.375 slightly below avg (minor version-pin + "experimental" overstatement) |
| Improving complex SQL perf on Trino with dbt | 4.7781 / 4 | **4.7781 / 4** | unchanged | Q2 maps to maintenance/MoR-deletes topic, not the dbt-perf topic |
| Trino federation / cross-source | 4.49944 / 310 | **4.49944 / 310** | unchanged | NOT probed per directive |

## Concrete teacher actions for iter464

### (1) PRIMARY — Q1 branch/tag-read findability fix

The r17 LEADING CANONICAL block IS correct and complete; the problem is the responder didn't reach it. The fix is in cross-references and keyword anchoring, not new canonical content.

**1a. Add an XR/redirect line at the top of r21's branches/tags section** (resources/21-hive-metastore-iceberg.md):
```
> **READING a branch or tag from Trino on HMS-backed Iceberg?** See r17 § "FOR VERSION AS OF '<branch_or_tag_name>'". Iceberg branches/tags are **TABLE-LEVEL metadata** stored in `metadata.json`, NOT a Nessie-only feature. HMS-backed Iceberg supports them fully — Spark writes them via `ALTER TABLE ... CREATE BRANCH/TAG`, Trino reads them via `FOR VERSION AS OF '<name>'`. Nessie adds **CATALOG-LEVEL multi-table branch transactions**, which is a SEPARATE feature from TABLE-LEVEL branches/tags.
```

**1b. Add a dedicated DO-NOT-WRITE row to r17's time-travel DO-NOT-WRITE table**:
| DO NOT write | Why it's wrong | Correct form |
|---|---|---|
| "Iceberg branches/tags require Nessie" / "branches/tags are not supported on Hive Metastore" / "you'd need to migrate to Nessie to use branches" | **FABRICATED capability restriction.** Branches and tags are TABLE-LEVEL Iceberg metadata stored in `metadata.json`, catalog-agnostic per iceberg.apache.org/docs/latest/branching/ (listed under Tables, not Catalogs). HMS-backed Iceberg supports them fully; Nessie's separate value is CATALOG-LEVEL multi-table branch transactions. | HMS users CAN use branches/tags. Spark writes via `ALTER TABLE ... CREATE BRANCH/TAG`; Trino reads via `FOR VERSION AS OF '<name>'`. |

**1c. Reinforce the keyword anchor in r17** — add a short paragraph near the top of the time-travel section: "**Q-pattern matcher**: 'How do I read from a branch / tag on HMS-backed Iceberg from Trino?' → `FOR VERSION AS OF '<branch_or_tag_name>'` (string literal). Works on Trino 467 + HMS. Branches/tags are TABLE-LEVEL Iceberg metadata, NOT catalog-level; do NOT need Nessie." This ensures the responder's keyword search 'branch read HMS Trino' lands here directly.

### (2) Q2 — quoting consistency audit

Grep r17 + r28 + r16 (and any other file referencing metadata tables) for any `table"$files"` / `table"$snapshots"` / `table"$refs"` malformed forms. The correct uniform form is `"table$files"` / `"table$snapshots"` / `"table$refs"` (entire composite identifier inside ONE pair of double quotes). If any malformed examples exist, fix in place — do not just append a callout.

### (3) Q3 — strengthen the concrete Trino-vs-Postgres comparison in r16

The responder hedged twice on the Postgres-vs-Trino CPU comparison even though the resources support a concrete answer. Add a short LEADING CANONICAL block in r16 with:
- Storage ratio (Postgres on-disk vs Iceberg-Parquet+Zstd on MinIO, with the 5–10x anchor)
- Amortized Trino-cluster $/hr (fixed) vs Postgres per-query CPU (scales with concurrency)
- Concurrency-multiplier framing — how to compute break-even between fixed cluster cost and per-query DB cost
- EXPLAIN-driven CPU profiling on representative queries (`split_cpu_time_ms` or equivalent from `system.runtime.tasks` — confirm exact column name from `DESCRIBE system.runtime.tasks` on the production stack)

So the responder doesn't fall back to "I don't have enough information" when the question is well-defined.

### (4) Q4 — minor cleanup (low priority)

Change "WITH RECURSIVE since release 343" → "WITH RECURSIVE since release 340 (Aug 2020)" in whatever resource the responder pulled this from. Drop the "experimental" framing — feature is stable, just has fixed recursion depth and quadratic plan growth.

### (5) Breadth design for iter464

Pick a NON-time-travel, NON-MoR-delete angle to test that the Q1 branch/tag-read fix doesn't crowd out other content. Candidates:
- dbt macro syntax (e.g., adapter.dispatch, custom test macros)
- Trino EXPLAIN-driven CPU profiling (ties to Q3 hedge fix)
- Multi-tenant partitioning re-probe (older PASSED topic, hasn't been touched recently)
- Postgres-to-Iceberg CDC (large topic with 158 datapoints, due for a re-probe)

### (6) Federation — DO NOT PROBE in iter464

The 4.49944/310 row sits 0.001 below the 4.5 raised threshold. A thin probe in either direction locks or breaks the row depending on which side it lands. Skip federation in iter464 unless a specific bulletproofed angle emerges.

## Streak status

- **Citation-hygiene streak**: BROKEN at iter463. Iter463 introduces a NEW load-bearing fab class — **capability-restriction fab** (claiming Iceberg branches/tags require Nessie when they are catalog-agnostic table-level metadata). Distinct from prior cross-dialect-spillover (iter456, iter459) and version-pin / Trino-internal-clause-conflation (iter458, iter461) classes.
- **Branch/tag-read regression**: iter452/iter453 correctly handled this; iter463 regressed. After iter464 reconciliation, MUST re-probe this exact angle in iter465+ to confirm the fix at the 2nd-angle bar.
- **Margin**: VERY THIN at 3.656. The PASS is only the average — Q1's 2.50 is a TRUE FAIL on its own. Do not treat this iter as a clean pass.
