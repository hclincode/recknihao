# Iter1121 Judge Feedback — 4.9844 STRONG PASS NO-OP + WATCH CLEARED

## Verdict: STRONG PASS, NO-OP. Multi-column ADD COLUMN WATCH CLEARED.

Iter average **4.9844** (margin +1.4844 above 3.5 threshold). All four answers technically correct against RAW Trino 467 docs. The iter1120 Q4 imported-prior slip (Postgres-habit multi-clause `ALTER TABLE ... ADD COLUMN a T, ADD COLUMN b T`) DID NOT RECUR on a direct re-probe targeted at the same Postgres-to-Trino syntax-import surface — classified as iter1120 one-off, not a structural resource gap. WATCH closed.

---

## Q1 — Multi-column ADD COLUMN to Iceberg (iter1120 Q4 RE-PROBE)

**Score: 5.00** (Accuracy 5.00, Clarity 5.00, Applicability 5.00, Completeness 5.00)

### Recurrence verdict: CLEARED. No recurrence.

The Postgres engineer explicitly invited the multi-clause habit ("in Postgres I'd do one ALTER with all four comma-separated"). Responder correctly redirected to **four SEPARATE `ALTER TABLE iceberg.analytics.events ADD COLUMN <name> <type>;` statements** (one per column, all four shown). No comma-list multi-clause attempted.

Verified against `trino.io/docs/current/sql/alter-table.html` synopsis quoted verbatim:
```
ALTER TABLE [ IF EXISTS ] name ADD COLUMN [ IF NOT EXISTS ] column_name data_type
  [ DEFAULT default ] [ NOT NULL ] [ COMMENT comment ]
  [ WITH ( property_name = expression [, ...] ) ]
  [ FIRST | LAST | AFTER after_column_name ]
```
SINGLE `ADD COLUMN` clause per statement — confirmed.

Responder also correctly framed the lock/concurrency distinction: each Iceberg `ADD COLUMN` is metadata-only / instant / no table-rewrite, so the Postgres motivation for batching (avoid multiple ACCESS EXCLUSIVE locks) does not apply on Iceberg. Four separate statements = four metadata commits, negligible cost. Clean transfer.

**Watch closed.** The iter1120 slip was a first-instance imported-prior on a copy-pasteable DDL aside; one direct re-probe cleanly avoiding it confirms responder one-off classification, not resource defect. No FIX-A needed.

---

## Q2 — 90-day rolling distinct user count via HLL sketches

**Score: 4.9375** (Accuracy 4.75, Clarity 5.00, Applicability 5.00, Completeness 5.00)

### Architectural pattern: fully correct.

PRIMARY recommendation = build a daily HLL sketch table, then rolling-join the sketch table against itself.

All four core technical claims verified against `trino.io/docs/current/functions/hyperloglog.html`:
- **(a)** `approx_set(x) -> HyperLogLog`: documented, "Returns the HyperLogLog sketch of the input data set of x. This sketch underlies the approx_distinct function and can be serialized for later use." Castable to varbinary confirmed by docs example: `cast(approx_set(user_id) AS varbinary)`. PASS.
- **(b)** `merge(HyperLogLog) -> HyperLogLog`: documented as the aggregate that unions sketches. `cardinality(merge(...))` for distinct count: confirmed. PASS.
- **(c)** Sketch self-join avoids raw-row rescan: correct architectural pattern. 365 days x ~90 sketches/day = ~33K tiny merge operations, vs 500M-row/day raw self-join.
- **(d)** Correctly did NOT claim COUNT(DISTINCT) can be a window function. Trino 467 has no `COUNT(DISTINCT col) OVER (ORDER BY ... RANGE BETWEEN ... PRECEDING AND CURRENT ROW)` — distinct-aggregate-over-sliding-window is not supported. HLL + sketch-join is the correct architectural workaround. PASS.

SECONDARY exact form (date-spine + `COUNT(DISTINCT s2.user_id)` self-join on raw events) correctly characterized as "exact but rescans 500M/day" — honest performance trade-off.

### Minor accuracy shave: 2.3% figure conflation

Responder cites "~2.3% standard error" on the approx_set-based sketch. Per docs:
- `approx_distinct(x)` — documented as "2.3%, which is the standard deviation of the (approximately normal) error distribution" (trino.io aggregate.html).
- `approx_set(x)` — docs do NOT publish a default error figure on the HyperLogLog page itself; mathematically the default precision (b=12, sqrt(1.04/2^12) ~= 1.625%) corresponds to a smaller max standard error than the 2.3% standard-deviation figure used for approx_distinct.

The 2.3% is the figure ENGINEERS will recognize from Trino docs, and `approx_distinct = cardinality(approx_set(x))` so the underlying error characteristics of the sketch are the same engine — the responder's claim is defensible and matches the documented Trino figure. But strictly, `approx_set`'s default error parameter is the 1.625% precision number, not the 2.3% standard-deviation figure. **Minor shave only** (-0.25 on Accuracy); not a resource defect, not worth a FIX-A. Cross-references the `reference_trino_approx_percentile_error` pin (2.3% is for approx_distinct ONLY).

---

## Q3 — `cardinality(feature_flags)` for array length

**Score: 5.00** (Accuracy 5.00, Clarity 5.00, Applicability 5.00, Completeness 5.00)

`cardinality(array(T)) -> bigint` returning element count is native to Trino 467 (trino.io/docs/current/functions/array.html). No UNNEST needed for length-only — UNNEST is for row-multiplication / grouping by element, which is not what the question asks. Clean lead with companion array-function family (contains/array_distinct/element_at) appropriately scoped as "next-step" not "for completeness padding". No over-warning or alternative-form trap.

---

## Q4 — Storage tiering for 3yr Iceberg data, dashboards hit last 6mo, can't delete

**Score: 5.00** (Accuracy 5.00, Clarity 5.00, Applicability 5.00, Completeness 5.00)

### All three mechanisms verified correct.

**Mechanism A — MinIO object-lifecycle tiering:**
- `mc ilm tier add` + `mc ilm rule add --transition-days <N> --transition-tier <tier>` confirmed against `docs.min.io` object-lifecycle-management page.
- "Transparent to Trino" confirmed: "MinIO AIStor manages retrieving tiered objects on-the-fly without any additional application-side logic." S3-API access continues to work.
- Age-based (calendar days from object creation), as iter1100/1102 FIX-A reinforces.
- "Keep `metadata/` hot" matches the iter1119 Q2 storage-tiering canonical (don't tier Iceberg metadata, it's hot small files Trino reads on every query).
- Matches production stack (on-prem MinIO from prod_info.md). PASS.

**Mechanism B — archive table + UNION ALL view:**
- `compression_codec='ZSTD'` is a VALID Trino 467 Iceberg table property in `WITH(...)`. Confirmed against iceberg connector docs: supported values are `NONE | SNAPPY | LZ4 | ZSTD | GZIP`; catalog-level default is `iceberg.compression-codec=ZSTD`. No defect; ZSTD is the connector default for Iceberg.
- `partitioning month(occurred_at)` is a valid Trino 467 Iceberg transform. PASS.
- UNION ALL view over hot+archive tables is the standard access-aware workaround in the absence of native per-partition tier DDL.

**Mechanism C — combo:** correct combination of A (storage layer) + B (application-layer access pattern).

**Negative guardrails:**
- "DO NOT delete" — respects the legal-hold constraint in the question.
- "DO NOT invent `ALTER TABLE ... SET STORAGE TIER`" — correctly defangs the fabricated-DDL trap that has bitten storage-tiering questions before. Matches the canonical "no built-in per-partition tier DDL in Trino+Iceberg" pin in the rubric row.

Lifts the thinnest required-topic row by ~+0.15 — storage-tiering 8th datapoint clean confirms the iter1100/1102 FIX-A lineage is durable across novel angles (now: 3yr+legal-hold framing was a new shape vs iter1119's flat-volume framing).

---

## Score table

| Q | Accuracy | Clarity | Applicability | Completeness | Avg |
|---|---|---|---|---|---|
| Q1 multi-col ADD COLUMN re-probe | 5.00 | 5.00 | 5.00 | 5.00 | **5.0000** |
| Q2 90-day rolling HLL sketch | 4.75 | 5.00 | 5.00 | 5.00 | **4.9375** |
| Q3 cardinality(array) | 5.00 | 5.00 | 5.00 | 5.00 | **5.0000** |
| Q4 MinIO tiering + compression_codec + archive view | 5.00 | 5.00 | 5.00 | 5.00 | **5.0000** |

**Iter average = (5.0000 + 4.9375 + 5.0000 + 5.0000) / 4 = 4.9844 STRONG PASS** (margin +1.4844)

---

## Source-verified defects

**None warranting a resource edit.**

The single minor item (Q2 2.3% standard-error conflation) is:
1. Defensible — 2.3% is the published Trino figure for `approx_distinct` and matches the engine the engineer will see in docs;
2. A -0.25 accuracy shave, not a -1.0 factual error;
3. Already pinned in `reference_trino_approx_percentile_error` memory note (2.3% applies to approx_distinct only);
4. Not findable in `resources/` as a wrong claim — responder didn't pull from a corrupted source, this is a conventional cross-reference engineers make.

Scope: per-instance responder shading, not a resource defect. No FIX-A.

---

## Q1 RECURRENCE VERDICT (the central watch from iter1120 + state.json note)

**CLEARED.** Responder produced SEPARATE `ALTER TABLE iceberg.analytics.events ADD COLUMN <name> <type>;` statements (one per column, all four shown) — no comma-separated multi-clause attempted, no Postgres-habit single-statement multi-operation. The Postgres engineer explicitly framed the question to surface the import habit ("in Postgres I'd do one ALTER with all four comma-separated"), and responder correctly redirected to the Trino 467 grammar (single ADD COLUMN clause per statement, verified against trino.io/docs/current/sql/alter-table.html synopsis).

Classification stabilized: iter1120 Q4 multi-clause slip was a **first-instance responder one-off, not a structural resource gap**. The conceptual canonical (r09 §153 "ADD COLUMN is metadata-only on Iceberg") reaches cleanly AND the syntax detail reaches cleanly on the very next direct re-probe. WATCH discipline matching iter1116 ts-minus-ts: NO-OP on first instance + targeted re-probe within 1-2 iters = correct call.

---

## Topic updates (relevant rubric rows)

- **Lakehouse schema design** (Q1 ADD COLUMN schema evolution): 4.5273/16 -> (72.4368 + 5.00)/17 = **4.5551/17 PASSED** (+0.0278; margin to 3.5 = +1.0551, comfortable; iter1120 syntax drag fully recovered).
- **Analytical query patterns on Iceberg+Trino** (Q2 HLL rolling-distinct sketch): 4.4539/75 -> (334.0425 + 4.9375)/76 = **4.4603/76 PASSED** (+0.0064).
- **SQL query best practices for OLAP** (Q3 array cardinality / no-UNNEST): 4.5148/176 -> (794.6048 + 5.00)/177 = **4.5175/177 PASSED** (+0.0027).
- **Storage tiering on Trino+Iceberg+MinIO** (Q4 8th angle, 3yr+legal-hold framing): 3.7679/7 -> (26.3753 + 5.00)/8 = **3.9219/8 PASSED** (+0.1540; margin to 3.5 widens from +0.2679 to **+0.4219** — clear lift off the floor, no longer thinnest).

All required topics REMAIN PASSED.

**New thinnest order after this iter:** dbt-snapshots SCD2 4.0961/15 (+0.5961) -> cost-considerations 4.2504/21 (+0.7504) -> query-perf-regression-diagnosis 4.3108/20 (+0.8108) -> query-perf-basics 4.3629/20 (+0.8629) -> storage-tiering 3.9219/8 (+0.4219, lifted off floor).

Storage-tiering is no longer the thinnest required topic — dbt-snapshots SCD2 inherits that position.

---

## Teacher guidance (RECOMMENDATION = NO-OP)

**Do nothing to resources/.** Commit rubric + feedback only.

Rationale:
1. Iter average 4.9844 (margin +1.4844) — well above STRONG PASS band.
2. iter1120 Q4 multi-clause ADD COLUMN watch CLEARED on direct re-probe — first-instance one-off confirmed, no structural defect.
3. All four answers source-verified against trino.io/docs/current/{alter-table.html, functions/hyperloglog.html, functions/aggregate.html, connector/iceberg.html, functions/array.html} and docs.min.io/object-lifecycle-management.
4. Storage-tiering row lifted off the floor — iter1100/1102 FIX-A lineage is durable.
5. No `::` / QUALIFY / false-semi-join / fabricated-fn / regex-backslash / INTERVAL-quarter-week / OFFSET-before-LIMIT / CAST-truncate / EXECUTE-rollback-on-467 / Spark-Oracle-spillover / imported-prior / GREATEST-NULL-Postgres / array_sum / `->`/`->>`-JSON / DATEDIFF-dialect-import / multi-arg-COUNT-DISTINCT / ts-minus-ts / over-warning / multi-clause-ADD-COLUMN recurrence.

**Re-probe queue priorities for next sweep:**
1. **dbt-snapshots SCD2 16th angle** (now thinnest at 4.0961/15): `dbt_is_deleted` hard-delete CDC behavior in 1.9+ / check_cols 'all' vs explicit list perf edge cases / Type 1+2 hybrid materialization.
2. **cost-considerations 22nd angle** (4.2504/21): partition-level cost attribution via `$manifests`, multi-tenancy cost split, per-customer storage attribution.
3. **query-perf-regression-diagnosis 21st angle** (4.3108/20): slow-query oncall workflow with concurrent ETL-vs-dashboard contention.
4. **query-perf-basics 21st angle** (4.3629/20): EXPLAIN reading basics / dynamic filtering verification / partition pruning diagnosis on new partition transforms.
5. Continue probing federation 4.5024/312 only on bulletproofed angles (iter170 raised-threshold row stays fragile).

**Pattern observation (continuing the broken-secondary thread):**
This iter's storage-tiering Q4 also shipped multiple alternative mechanisms (A/B/C) — all three were correct. That contrasts with the iter1120 syntax slip pattern where the multi-mechanism conceptual frame was clean but the DDL example drifted. Today's clean execution on a SAME-shape multi-alternative answer reinforces the responder-broken-secondary-alternative pattern as a per-instance shading issue (high-stakes-detail in copy-pasteable code), NOT a "responder always botches alternatives" rule. Continue NO-OP on first instances + targeted re-probe — the watch-clear approach is working.

6-iter ≥4.7 streak: 1090 (4.91) / 1092 (4.95) / 1093 (4.97) / 1117 / 1118 / 1119 (5.00) -> 1120 (4.75 first-instance ADD-COLUMN slip) -> **1121 (4.9844, watch CLEARED)**. Content lineage durable.
