# Judge Feedback — Iteration 461

**Phase**: extended (end-of-iteration feedback only)
**Date**: 2026-06-05
**Overall**: 4.625 PASS (60th consecutive extended-phase PASS)

## Verdict

**PASS** — overall 4-question avg **4.625** (PASS threshold 3.5).

## Per-question scores

| Q | Topic angle | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|---|
| Q1 | Iceberg storage sizing 200GB CSV / 500M rows (iter460 Q3 formula RE-PROBE) | 5.0 | 4.75 | 5.0 | 5.0 | **4.9375** |
| Q2 | Oracle NEXTVAL → Trino surrogate keys (`dbt_utils.generate_surrogate_key` / `ROW_NUMBER()` / no Iceberg identity) | 5.0 | 4.75 | 4.75 | 5.0 | **4.875** |
| Q3 | dbt materialization choice per model (view / table / incremental+merge / ephemeral) | 5.0 | 4.5 | 5.0 | 5.0 | **4.875** |
| Q4 | Iceberg time-travel real? snapshots = full copies? (`FOR VERSION AS OF` / `$snapshots` / `expire_snapshots`) | 3.0 | 4.5 | 4.5 | 3.25 | **3.8125** |

Overall avg = (4.9375 + 4.875 + 4.875 + 3.8125) / 4 = **4.625** -> PASS.

## CRITICAL FINDING #1 -- Q1 formula streak status: FIXED, FULLY CONFIRMED

The iter460 Q3 dimensionally-wrong formula (`(raw bytes x row count) ÷ compression ratio`) class is **FULLY RESOLVED** on first re-probe.

- Responder used `on_disk ~ total_raw_bytes ÷ compression_ratio = 200GB / 7 ~ 29GB` -- dimensionally correct.
- Responder explicitly self-corrected: "never multiply by row count again -- double-counting".
- iter461 teacher r11 two-forms rewrite (Form A `total_raw_bytes ÷ compression_ratio` + Form B `avg_bytes_per_row x row_count ÷ compression_ratio` with explicit "algebraically identical") + DO-NOT-WRITE table banning the double-count form LANDED at the keyword path.
- Formula streak now at **1 PASS post-fix**. Needs another angle at iter462+ to lock the fix across phrasings (e.g. starting from per-row size, mixed-type schema sizing, year-over-year growth projection) -- not just a verbatim "200GB CSV -> ?" re-probe.

## CRITICAL FINDING #2 -- Q4 syntax fab ruling: `FOR VERSION AS OF TIMESTAMP '...'` is INVALID Trino syntax

Responder wrote:
```
SELECT * FROM iceberg.analytics.events FOR VERSION AS OF TIMESTAMP '2026-05-29 14:30:00 UTC';
```

Per **trino.io/docs/current/connector/iceberg.html** (Time travel queries section), Trino has TWO distinct, non-interchangeable time-travel clauses:

1. **Snapshot-id form** (integer-only):
   ```
   SELECT * FROM example.testdb.customer_orders FOR VERSION AS OF 8954597067493422955;
   ```
   `FOR VERSION AS OF` accepts ONLY a snapshot-id BIGINT literal.

2. **Timestamp form** (separate clause):
   ```
   SELECT * FROM example.testdb.customer_orders FOR TIMESTAMP AS OF TIMESTAMP '2022-03-23 09:59:29.803 Europe/Vienna';
   ```
   `FOR TIMESTAMP AS OF` accepts ONLY a TIMESTAMP literal.

`FOR VERSION AS OF TIMESTAMP '...'` welds the snapshot-id clause keyword with a timestamp literal that belongs to a different clause -- it is a Trino parse error. An engineer migrating off Oracle Flashback Query (`AS OF TIMESTAMP ...`) who copies the responder's example gets a syntax error on the exact use case they came to time-travel for. **Load-bearing syntax fab.** Accuracy docked 5.0 -> 3.0, Actionability docked to 3.25.

This is a new fab class -- **clause-conflation within Trino** (not strictly cross-dialect-spillover, but same mechanism). Engineers from Snowflake/Delta backgrounds know `AT (TIMESTAMP => ...)` / `AT (VERSION => ...)` (single clause + parameterized arg); engineers from Spark know `TIMESTAMP AS OF` / `VERSION AS OF` (separate clauses, but both standalone). Trino splits the two forms into two distinct clauses, so muscle memory from other engines can produce a welded hybrid that "looks Trino-flavored" but parses as neither.

## Fabrication / inaccuracy list (with correct fact + source)

1. **Q4 -- `FOR VERSION AS OF TIMESTAMP '2026-05-29 14:30:00 UTC'`** (load-bearing syntax fab)
   - **Correct**: For timestamp travel, use `FOR TIMESTAMP AS OF TIMESTAMP '2026-05-29 14:30:00 UTC'`. `FOR VERSION AS OF` is snapshot-id-only.
   - **Source**: trino.io/docs/current/connector/iceberg.html (Time travel queries section).

No other fabrications. Q1 / Q2 / Q3 each ZERO fabrications. Specifically:
- Q1 -- `$files` columns `file_size_in_bytes` and `record_count` verified at trino.io/docs/current/connector/iceberg.html (Files columns reference). Formula dimensionally correct.
- Q2 -- `dbt_utils.generate_surrogate_key` MD5-by-default, VARCHAR ~32 hex chars verified at github.com/dbt-labs/dbt-utils/blob/main/macros/sql/generate_surrogate_key.sql. Iceberg issue #12297 "Support for Identity Columns in Apache Iceberg" status is "Closed as not planned" at github.com/apache/iceberg/issues/12297. Trino has no `CREATE SEQUENCE` / NEXTVAL verified per Trino SQL grammar.
- Q3 -- All four materialization semantics match docs.getdbt.com/docs/build/materializations and docs.getdbt.com/docs/build/incremental-models. Minor omission of the 5th type `materialized_view` is acceptable in dbt-trino + Iceberg production context.

## Cross-cutting patterns

1. **Citation-hygiene streak status**:
   - iter460 dimensional-error formula class: FULLY RESOLVED at Q1 (1 PASS post-fix).
   - iter460 NULLS-default fix held across a different Oracle migration sub-topic (surrogate keys at Q2 -- no Oracle-vs-Trino default leakage when surrogate-key generation was the only angle).
   - NEW FAB at Q4: Trino-internal-clause-conflation (`FOR VERSION AS OF TIMESTAMP '...'`). Distinct fab class from prior cross-dialect-spillover (iter456) and version-pin-spillover (iter458/459). Same mechanism (muscle memory) but the conflated clauses are both internal to Trino.

2. **Topic margin movements**:
   - Storage sizing 4.5072/9 -> **4.55023/10** (+0.04303) -- Q1 4.9375 well above topic avg, dimensional-error class resolved.
   - Oracle PL/SQL->dbt/Trino migration 4.5722/33 -> **4.5811/34** (+0.0089) -- Q2 4.875 above topic avg, surrogate-key clean.
   - Improving complex SQL performance on Trino with dbt 4.7458/3 -> **4.7781/4** (+0.0323) -- Q3 4.875 above topic avg, low-population topic still above 4.7.
   - Iceberg table maintenance 4.4998/120 -> **4.4941/121** (-0.0057) -- Q4 3.8125 below topic avg, time-travel timestamp syntax fab docks margin slightly; still above 3.5 floor but tightened.
   - Federation NOT probed -- 4.49944/310 row UNCHANGED per directive.

## Concrete teacher actions for iter462 (breadth design; no dedicated federation probe)

### (1) PRIMARY ACTION -- Fix the Q4 time-travel clause-conflation fab class

**Resource target**: locate the file containing Iceberg time-travel content (likely r17, r18, or the Iceberg table maintenance resource -- grep for `FOR VERSION AS OF` and `FOR TIMESTAMP AS OF`). Plan:

- **Add a LEADING CANONICAL block** titled "Iceberg time travel on Trino -- TWO distinct clauses, NOT interchangeable":
  - Side-by-side table of the two clauses with explicit type rules.
  - **Rule A**: `FOR VERSION AS OF <integer-snapshot-id>` -- takes ONLY a snapshot-id BIGINT literal (look up via `SELECT snapshot_id FROM iceberg.<schema>."<table>$snapshots"`).
  - **Rule B**: `FOR TIMESTAMP AS OF TIMESTAMP '...'` -- takes ONLY a TIMESTAMP literal (with timezone preferred for cross-cluster reproducibility).
  - Explicit ban: "`FOR VERSION AS OF TIMESTAMP '...'` is NOT valid; the two clauses cannot be combined or substituted."
  - Verbatim quote from trino.io/docs/current/connector/iceberg.html for each clause.
  - Two worked examples (one for snapshot-id, one for timestamp) using the same `iceberg.analytics.events` table that recurs across the resources.

- **DO-NOT-WRITE table** banning:
  - `FOR VERSION AS OF TIMESTAMP '...'` (the iter461 Q4 fab verbatim).
  - `FOR TIMESTAMP AS OF <integer>` (symmetric error -- timestamp clause cannot take an integer).
  - `AT (TIMESTAMP => ...)` / `AT (VERSION => ...)` (Snowflake/Delta cross-dialect leakage).
  - `TIMESTAMP AS OF '...'` (Spark-style clause without the `FOR` keyword).
  - `VERSION AS OF '...'` (Spark-style clause without the `FOR` keyword).

- **Cross-ref to §4.4B cross-dialect-spillover guardrail** explaining the muscle-memory mechanism: Snowflake/Delta unify version/timestamp under a single clause (`AT (...)`); Spark uses separate clauses but without the `FOR` keyword (`TIMESTAMP AS OF '...'` / `VERSION AS OF <id>`); Trino requires `FOR` + two separate clauses with disjoint argument types. Engineers from those backgrounds will instinctively weld keywords.

- **Reconciliation discipline**: if any existing resource shows a `FOR VERSION AS OF` example, audit it to ensure the literal type matches; do NOT append the new block -- fix in place and remove any stale or imprecise wording.

### (2) BREADTH -- Lock the storage-sizing formula fix across a NEW angle

iter461 Q1 was the verbatim 200GB CSV re-probe. To confirm the fix persists across phrasings (not just the re-probe phrasing), iter462 should probe storage sizing from a NEW angle:
- Per-row sizing starting from a Postgres schema (rows-per-month projection over 12 months, mixed-type columns).
- OR year-over-year growth projection with retention policy (90d hot + 1y warm + 3y cold).
- OR include compaction overhead / snapshot retention overhead in the total.

Either of these probes the same Form A/Form B logic from a different starting point. If the fix is robust, both forms should be applied correctly.

### (3) BREADTH -- Mid-tier topic rotation (keep cost / multi-tenant / query-perf-regression warm)

- **Cost considerations** is the LOWEST-buffer PASSED topic (4.2079/18). Pick a fresh cost angle (e.g. tenant chargeback at month-end accounting close, or per-query cost attribution for a specific noisy-neighbor incident).
- OR **Multi-tenant analytics** (4.4562/151) -- pick a new isolation angle.
- OR **Query performance regression diagnosis** (4.3338/16) -- oncall workflow.

### (4) BREADTH -- One Oracle migration angle to confirm iter460+iter461 fixes hold across question phrasings

iter461 Q2 covered surrogate keys / sequences. Pick a non-NULLS, non-sequence Oracle angle:
- PL/SQL cursor -> set-based rewrite.
- `MERGE INTO` Oracle vs Trino/Iceberg MERGE.
- `NVL` / `DECODE` / `CONNECT BY` rewrites.
- Oracle `ROWNUM` vs Trino `LIMIT` / `OFFSET` / window functions.

This widens the topic's coverage rather than re-probing the just-fixed angles.

### (5) FEDERATION -- NOT probed unless a specific bulletproofed angle emerges

Federation row stays at 4.49944/310 (FAIL threshold raised to 4.5; current 4.49944 is the recorded near-miss). Do NOT probe federation unless a specific, doc-verifiable angle is ready (e.g. a Trino release note that closes a known federation fab class). Random federation probes risk re-opening unresolved fab classes.

### (6) Reconciliation hygiene reminder

When updating the time-travel resource, do NOT append the new canonical block at the end -- locate and REPLACE/FIX in place any stale content that contradicts the two-clause rule. If multiple files mention time travel, audit all of them and either unify on a single canonical source or cross-ref from secondary mentions to the canonical block. iter460+iter461 has shown that leaving the responder to find the right cross-ref is fragile when keyword paths diverge.

## Streak summary

- 60 consecutive overall PASS in extended phase.
- Formula streak: 1 PASS post-fix (needs another angle to lock).
- NULLS-default streak: held across a different Oracle migration sub-topic at iter461 Q2 (incidental confirmation -- not a dedicated re-probe).
- New fab class introduced at iter461 Q4: Trino-internal-clause-conflation in time travel. Must be resolved at iter462.
