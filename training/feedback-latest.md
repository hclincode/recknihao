# Judge Feedback — Iter 450 (END-OF-ITERATION, EXTENDED PHASE)

## Verdict
**4.6406 PASS overall** (Q1 4.75 + Q2 4.6875 + Q3 4.75 + Q4 4.375). TWO confident-inaccuracies in Q4 (Trino-dialect DDL bugs). 49th consecutive overall PASS in extended phase. **Citation-hygiene streak BROKEN.**

## Per-question breakdown

| Q | Topic | Acc | Comp | Clar | Act | Avg | Verdict |
|---|---|---|---|---|---|---|---|
| Q1 | data-lakehouse (lakehouse vs Snowflake/BQ) | 4.875 | 4.75 | 4.75 | 4.625 | **4.75** | STRONG |
| Q2 | data-warehouse (premature for 20-person SaaS?) | 4.75 | 4.75 | 4.625 | 4.625 | **4.6875** | PASS |
| Q3 | tools-comparison (BQ vs Snowflake vs Iceberg+Trino at 50p) | 4.875 | 4.75 | 4.75 | 4.625 | **4.75** | STRONG |
| Q4 | schema-design (wide-flat 30-col event table) | 4.125 | 4.375 | 4.5 | 4.5 | **4.375** | PASS w/ CAVEAT |

**Iter-overall avg = (4.75 + 4.6875 + 4.75 + 4.375) / 4 = 4.6406**

## Per-question justification

### Q1 — Lakehouse vs Snowflake/BigQuery (4.75 STRONG PASS)
- Correctly named Snowflake has **NO on-prem** — VERIFIED per docs.snowflake.com/en/user-guide/intro-cloud-platforms ("Snowflake does not support on-premises deployment... runs completely on cloud infrastructure").
- Correctly named BigQuery Omni is **multi-cloud AWS/Azure only, NOT on-prem** — VERIFIED per cloud.google.com/bigquery/docs/omni-introduction.
- Snowflake proprietary FDN micro-partition format vs open Parquet — accurate.
- "Marginal $/query ~0 once cluster running" — fair simplification for self-hosted Trino+MinIO on k8s.
- iter450 r04 leading canonical worked example LANDED.

### Q2 — 20-person SaaS warehouse premature? (4.6875 PASS)
- Diagnostic questions (multi-source joins / replica buckling / 500M+rows scanning weeks / 3+ independent writers) are well-calibrated; framed as decision signals, not universal laws.
- "2+ yes → build" rule of thumb is reasonable.
- Postgres tuning ladder (pg_partman → partial indexes → MVs → pooling) is sound. **pg_partman is real** — VERIFIED per github.com/pgpartman/pg_partman.
- 14-24 engineer-week cost framed as planning estimate — fair.
- iter450 r02 leading canonical worked example LANDED.

### Q3 — BigQuery vs Snowflake vs Iceberg+Trino at 50-person B2B (4.75 STRONG PASS)
- On-prem constraint correctly used as primary disqualifier for Snowflake + BigQuery.
- 7 decision levers framework (on-prem / lock-in / cost-shape / ops-burden / dbt-support / multi-tenant / time-to-dashboard) well-organized.
- dbt adapter maturity claims align with verified versions as of June 2026: **dbt-bigquery==1.11.1, dbt-snowflake==1.11.4, dbt-trino==1.10.1** all on compatible-track per docs.getdbt.com/docs/dbt-versions/compatible-track-changelog.
- Anti-tiebreakers (benchmarks, AI features, auto-scaling, time-travel, streaming) correctly called marketing-misleads.
- iter450 r15 leading canonical worked example LANDED.

### Q4 — Wide flat 30-col event table — denormalize? (4.375 PASS-WITH-CAVEAT) — **CITATION HYGIENE BROKEN**
- **SOUND**: denormalization-is-RIGHT-default-for-OLAP; copy GROUP-BY/WHERE columns into the fact table; MAP for long-tail attributes; point-in-time correctness ("what plan WHEN") is a feature; single-JSON-blob is an anti-pattern (kills column pruning).
- **DIALECT BUG #1**: `MAP<VARCHAR,VARCHAR>` is **Hive/Spark angle-bracket syntax**, NOT valid Trino DDL. Trino uses **`MAP(VARCHAR, VARCHAR)`** with parentheses per trino.io/docs/current/language/types.html. Pasting into Trino 467 = parse error.
- **DIALECT BUG #2**: `PARTITIONED BY (day(occurred_at), tenant_id)` is **Spark/Hive DDL**, NOT valid Trino Iceberg DDL. Trino uses **`WITH (partitioning = ARRAY['day(occurred_at)', 'tenant_id'])`** per trino.io/docs/current/connector/iceberg.html. Transforms AND identity columns both go inside the ARRAY[].
- Both bugs together violate the Trino-Dialect-Accuracy memory directive. Q4 didn't fail (4.375 > 3.5), but dropped schema-design topic avg from 4.60 to 4.5417.

## Fabrications / inaccuracies — full list

| # | Q | Claim | Reality | Source |
|---|---|---|---|---|
| 1 | Q4 | `MAP<VARCHAR,VARCHAR>` as Trino DDL | Trino uses `MAP(VARCHAR, VARCHAR)` with parentheses | https://trino.io/docs/current/language/types.html |
| 2 | Q4 | `PARTITIONED BY (day(occurred_at), tenant_id)` as Trino DDL | Trino uses `WITH (partitioning = ARRAY['day(occurred_at)', 'tenant_id'])` | https://trino.io/docs/current/connector/iceberg.html |

ZERO fabrications in Q1, Q2, Q3. The on-prem-disqualification reasoning in Q1+Q3 was CORRECT (no claim that Snowflake/BigQuery CAN run on-prem). No PR/issue numbers cited this iter (no fabrication-exposure surface).

## Topic-average updates

| Topic | Before | After | Delta | Notes |
|---|---|---|---|---|
| Data lakehouse | 4.625/2 | **4.6667/3** | +0.0417 | Q1 4.75 above topic avg — strong gain, 3-datapoint milestone |
| Data warehouse | 4.647/3 | **4.6573/4** | +0.0103 | Q2 4.6875 slightly above topic avg |
| Tools comparison | 4.75/2 | **4.75/3** | +0.0000 | Q3 4.75 exactly at topic avg — held |
| Schema design (denorm/star schema basics) | 4.60/5 | **4.5417/6** | -0.0583 | Q4 dialect bugs dropped Accuracy to 4.125; still PASS by 1.04 cushion |
| Trino federation | 4.49944/310 | **UNCHANGED** | n/a | Not probed this iter per directive |

## Concrete teacher actions for iter 451

### CRITICAL — reconcile Trino-dialect DDL across schema-design resources

The Q4 answer reproduced two Spark/Hive-dialect DDL patterns as if they were Trino. Likely source: the wide-fact-table canonical example in `resources/07-olap-schema-design.md` and/or `resources/12-lakehouse-schema-design.md`. Required actions:

1. **Grep all schema-design resources for `MAP<` (angle-bracket map type)**:
   - Replace every `MAP<VARCHAR,VARCHAR>` (and similar `MAP<X,Y>`) with `MAP(VARCHAR, VARCHAR)` in DDL blocks labeled or implied as Trino.
   - If a Spark-DDL block legitimately uses the angle-bracket form, label it explicitly: `-- Spark Iceberg DDL (NOT Trino — Trino uses MAP(K, V) with parentheses)`.
   - Add a one-paragraph callout: "**Trino uses `MAP(K, V)` with parentheses.** Angle-bracket `MAP<K,V>` is Hive/Spark syntax; pasting into Trino 467 produces a parse error."

2. **Grep all schema-design resources for `PARTITIONED BY`**:
   - In any Trino-labeled or Trino-implied CREATE TABLE, replace `PARTITIONED BY (day(col), other_col)` with `WITH (partitioning = ARRAY['day(col)', 'other_col'])`.
   - Add a callout: "**Trino Iceberg CREATE TABLE uses `WITH (partitioning = ARRAY[...])`.** `PARTITIONED BY (...)` is Spark/Hive DDL. Identity columns and transforms both go inside the ARRAY as strings."

3. **Add a DO-NOT-WRITE block to the schema-design canonical worked example**:
   - `MAP<VARCHAR,VARCHAR>` → NO, use `MAP(VARCHAR, VARCHAR)` in Trino
   - `PARTITIONED BY (day(col))` → NO, use `WITH (partitioning = ARRAY['day(col)'])` in Trino
   - Corollary: when copy-pasting from a Spark tutorial, always re-check dialect.

4. **Add top-of-file rubric reminder in r07 + r12**: "ALL CREATE TABLE / ALTER TABLE / MAP / ARRAY / ROW type DDL in this file is Trino 467 dialect unless explicitly labeled otherwise."

### MAINTENANCE — Q1/Q2/Q3 canonical worked examples landed cleanly

- r04 (lakehouse) leading example LANDED — keep as-is, no edits this iter.
- r02 (warehouse) leading example LANDED — keep as-is, no edits this iter.
- r15 (tools-comparison) leading example LANDED — keep as-is, no edits this iter.

### BREADTH FOR ITER 451 — suggested probe mix (no dedicated federation probe)

Per design directive, federation stays paused at 4.49944/310. iter451 should rotate to:
- **Schema-design re-probe** — explicitly verify the r07/r12 dialect fix lands. Ask a Trino-DDL-heavy schema-design question.
- **Cost considerations** (4.1547/16) — still lowest-buffer PASSED topic; another strong probe would push toward ~4.18.
- **Lakehouse schema design / fact-and-dim** (4.4773/11) — reasonable buffer but related territory to Q4 dialect bug; worth a bias-check.
- **OLAP vs OLTP** (4.657/4) — fresh-angle probe (e.g., "why can't I just keep adding read replicas?").

### CITATION-HYGIENE STREAK — RESTART AT 0

Iter448-449 had zero confident-inaccuracies. Iter450 introduced 2 dialect bugs in Q4. Streak resets. Teacher must lock down Trino-dialect DDL across schema-design files before iter451 probes hit.

## Status

- Iter450 PASS overall (4.6406).
- ALL required topics still above threshold; schema-design buffer eaten modestly (4.5417 vs 3.5 floor = 1.04 cushion remaining).
- Federation untouched at 4.49944/310 (0.0006 below the 4.5 override threshold).
- 49th consecutive overall PASS in extended phase.
- Citation-hygiene streak: **BROKEN** — restart at 0.
