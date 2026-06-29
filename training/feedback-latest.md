# Iteration 1260 — Judge Feedback

## Verdict

**Overall: 4.516 PASS with one moderate completeness gap on Q3.** Three of the four answers are STRONG PASS material (Q1 4.50 / Q2 4.8125 / Q4 4.875); Q3 (3.875) misses the native dbt feature (`dbt snapshots` + `hard_deletes='invalidate'`/`'new_record'`) for source-side hard-deletes — the responder gave technically-valid reconciliation + CDC-delete-event alternatives but never named the canonical dbt-native primitive that exists specifically for this scenario.

- Q1 (MERGE CDC three-branch on Iceberg) — **4.50**: structurally correct (DELETE-first first-match-wins, explicit columns, Spark/Snowflake-only forms defanged). Practical-applicability shave: the responder did NOT mention that CDC batches with multiple events per `account_id` in one staging load will trigger `MERGE_TARGET_ROW_MULTIPLE_MATCHES` ("The query fails if a single target table row matches more than one source row" — verified verbatim at [trino.io/docs/467/sql/merge.html](https://trino.io/docs/467/sql/merge.html)). The source MUST be pre-deduped to the LATEST event per key via `ROW_NUMBER() OVER (PARTITION BY account_id ORDER BY updated_at DESC) = 1` before the MERGE — and r13 ALREADY documents this pattern (§5231-5235 "deduplication before the MERGE using the `ROW_NUMBER()` window pattern"), so the gap is responder findability not resource content.
- Q2 (cohort retention conditional-aggregation pivot) — **4.8125**: pin-perfect. Three-CTE structure (`cohorts` → `activity` → `pivoted`), `date_diff('month', cohort_month, date_trunc('month', event_time))` month-offset, `COUNT(DISTINCT user_id)` (avoids over-counting on multi-event-per-user), `SUM(CASE WHEN months_since=N THEN active_users END)` conditional-aggregation pivot, immature-cohort exclusion via `WHERE date_diff('month', cohort_month, CURRENT_DATE) >= 6`, retention pct = `ROUND(100.0 * monthN_count / month0_count, 1)`. All Trino 467 valid. Explicit no-PIVOT-keyword note correct.
- Q3 (dbt incremental source hard-deletes) — **3.875**: MISSED `dbt snapshots` + `hard_deletes='invalidate'`/`'new_record'` (the standard dbt-native feature for source-side physical deletes, verified at [docs.getdbt.com/reference/resource-configs/hard-deletes](https://docs.getdbt.com/reference/resource-configs/hard-deletes), 1.9+, replaces legacy `invalidate_hard_deletes=true`). Responder's three patterns (delete+insert / reconciliation anti-join / CDC delete events) are all VALID and the CDC-delete-event pattern is essentially what `hard_deletes='invalidate'` does mechanically — but the responder never named the canonical primitive. **PRODUCTION-STACK NUANCE**: dbt docs explicitly list hard_deletes adapter support as "dbt-postgres, dbt-bigquery, dbt-snowflake, and dbt-redshift" — `dbt-trino` is NOT in the list, so the production-stack applicability of hard_deletes ON THIS STACK is uncertain. Even so, the canonical answer for a generic "standard dbt way" question is dbt snapshots with hard_deletes (with the adapter-support caveat).
- Q4 (Oracle MONTHS_BETWEEN → Trino) — **4.875**: pin-perfect on the key dialect divergence. `date_diff('month', start, current_timestamp)` returns BIGINT (integer) DAY-AWARE complete months — verified against pinned `reference_trino_datediff_dayaware.md` (Trino 467 `DateTimeFunctions.java` git-tag); 2026-01-15→2026-07-25 yields Oracle `MONTHS_BETWEEN` ≈ 6.32 vs Trino `date_diff('month')` = 6. For fractional, `date_diff('day', start, now) / 31.0` is the documented Oracle 31-day-month convention (verified verbatim at [docs.oracle.com](https://docs.oracle.com/en/database/oracle/oracle-database/18/sqlrf/MONTHS_BETWEEN.html): "Oracle Database calculates the fractional portion of the result based on a 31-day month"). Pragmatic routing ("most SaaS reporting needs only the integer") is correct.

---

## Per-question scores

| Q | Acc | Clar | Prac | Compl | Avg | Verdict |
|---|---|---|---|---|---|---|
| Q1 MERGE CDC three-branch on Iceberg | 4.75 | 4.75 | 4.5 | 4.0 | **4.50** | PASS, multi-event-source-dedup miss is the only shave |
| Q2 cohort retention conditional-pivot | 5.0 | 4.75 | 4.75 | 4.75 | **4.8125** | STRONG PASS |
| Q3 dbt incremental source hard-deletes | 4.5 | 4.5 | 3.5 | 3.0 | **3.875** | PASS but native-feature miss |
| Q4 MONTHS_BETWEEN → date_diff('month') | 5.0 | 4.75 | 5.0 | 4.75 | **4.875** | STRONG PASS |

**Iteration average**: 4.516

---

## Q1 verdict — three-branch MERGE on Iceberg + missing source-dedup note (NO FIX-A; soft watch)

**Core correctness CONFIRMED via [trino.io/docs/467/sql/merge.html](https://trino.io/docs/467/sql/merge.html)** (WebFetched this iter):
- "MERGE supports an arbitrary number of WHEN clauses" — three-branch (DELETE / UPDATE / INSERT) supported.
- "For each source row, the WHEN clauses are processed in order. Only the first matching WHEN clause is executed and subsequent clauses are ignored" — first-match-wins enforced; responder's "DELETE branch FIRST" ordering is correct.
- Iceberg connector supports MERGE per [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html).
- Defang of `UPDATE SET *` / `INSERT *` / `WHEN NOT MATCHED BY SOURCE` (Spark/Snowflake-only) is correct for Trino 467.
- Explicit-columns convention is the right call (`UPDATE SET col1=s.col1, col2=s.col2, ...` not unstar-shorthand).

**THE MISS — multi-event-source-dedup completeness gap**:
- Trino docs verbatim: "The query fails if a single target table row matches more than one source row" — this is the `MERGE_TARGET_ROW_MULTIPLE_MATCHES` runtime error.
- CDC batches frequently contain multiple events per primary key (e.g., user updated email then plan_tier in same Postgres second → staging table has 2 rows for `account_id=42`). The responder's MERGE would crash on this.
- Canonical fix: pre-dedupe source to LATEST event per key:
  ```sql
  USING (
    SELECT * FROM (
      SELECT *, ROW_NUMBER() OVER (PARTITION BY account_id ORDER BY updated_at DESC) AS rn
      FROM staging
    ) WHERE rn = 1
  ) s
  ```
- The engineer running a real CDC pipeline will hit this within days; load-bearing for a "CDC upsert" framing.

**FIX-A DECISION — NO FIX-A this iter, watch only**.
- Resource grep confirms r13 §5231-5235 ALREADY documents "deduplication before the MERGE using the `ROW_NUMBER()` window pattern" with explicit "Trino-compatible canonical dedup-before-MERGE pattern" + verbatim ROW_NUMBER subquery template. Content exists. Gap is responder findability — the question framing keyed on "three-branch MERGE syntax" and the responder reached the MERGE-syntax content without pulling the adjacent dedup-source caveat from the same r13 section.
- **NEW SOFT WATCH `iter1260 Q1 CDC-MERGE missing multi-event-source-dedup note`**: re-probe under "CDC staging table with multiple events per key / MERGE" / "MERGE crashes with MULTIPLE_MATCHES" framings 4-8 iters; if 2+ recurrences under different phrasings (especially explicit "what happens if staging has 2 rows for same key"), escalate to LIGHT FIX-A — co-locate a one-line dedup-required call-out inside the three-branch MERGE example in r13 / r05 / wherever the three-branch CDC pattern is taught (the dedup pattern at §5231-5235 is far from the MERGE-syntax example).

---

## Q3 verdict — dbt snapshots hard_deletes MISSED for source hard-delete capture (NO FIX-A this iter; soft watch — same family as iter1249/iter1253)

**Canonical answer the responder missed — VERIFIED at [docs.getdbt.com/reference/resource-configs/hard-deletes](https://docs.getdbt.com/reference/resource-configs/hard-deletes)** (WebFetched this iter):
- Three values for `hard_deletes` config (dbt 1.9+, replaces legacy `invalidate_hard_deletes=true`):
  - `ignore` (default — deleted rows stay in snapshot looking "current" forever, the engineer's described symptom)
  - `invalidate` — when a row disappears from source, dbt stamps `dbt_valid_to = run_time` so the row stops matching `WHERE dbt_valid_to IS NULL`
  - `new_record` — inserts a marker row with `dbt_is_deleted = 'True'` for explicit deletion audit trail
- Config example: `snapshots: - name: my_snapshot config: hard_deletes: invalidate`
- This is the FIRST-CLASS dbt-native primitive for "Postgres physically deleted a row, snapshot needs to react" — exactly the engineer's scenario.

**Production-stack adapter-support caveat** — dbt docs verbatim "You can use hard_deletes with dbt-postgres, dbt-bigquery, dbt-snowflake, and dbt-redshift adapters." `dbt-trino` is NOT in the listed adapters. Whether dbt-trino actually supports hard_deletes is an open question (the responder's CDC + reconciliation alternatives may end up being the production-stack-applicable answer anyway). But a complete dbt-native answer should NAME the snapshot feature even if it has to flag the adapter-support uncertainty.

**Responder's three alternatives that DID land**:
1. `incremental_strategy='delete+insert'` (correctly noted it still doesn't catch Postgres hard-deletes — true).
2. Separate reconciliation model anti-joining Iceberg vs `SELECT id FROM postgres.subscriptions` + stamp `deleted_at` (DIY pattern, valid).
3. CDC delete events → MERGE WHEN MATCHED THEN DELETE (this is mechanically what `hard_deletes='invalidate'` does internally; the responder reached the right TECHNIQUE but not the dbt-native primitive that wraps it).

**FIX-A DECISION — NO FIX-A this iter; SOFT WATCH ONLY** per `feedback_synthesis_ceiling_stop_churning.md` and the iter1249 dbt-snapshot recall-variance family precedent:
- iter1249 was a hard BAIL (1.0) on a dbt-snapshot question. iter1253 was a STRONG PASS (4.8125) on the same family (strategy='check') — the iter1253 close confirms the resources are anchored correctly.
- This iter is a different angle (incremental-context source-hard-deletes) where the question's keywords point to incremental, not snapshot. The responder's answer wasn't WRONG — it was incomplete on a tangentially-related native feature.
- Resources already have:
  - r27 §302-304: `snapshot` row inside materializations table with explicit "hard_deletes" keyword + cross-ref to r09 §SCD.
  - r28 §20: keyword-anchor wall pointing to r09 §SCD for `hard_deletes` keyword among many.
  - r09 §SCD Option 1: full canonical for hard_deletes='invalidate'/'new_record' + dbt_is_deleted marker.
- Both r27 and r28 incremental sections do NOT cross-reference r09 §SCD hard_deletes FROM the angle "source row physically deleted / incremental can't capture this." That's the findability gap — but adding a cross-ref every time a slightly different question shape exposes a recall gap risks `feedback_new_card_over_attracts_adjacent.md` over-attractor.
- **NEW SOFT WATCH `iter1260 Q3 source-hard-delete missing dbt-snapshot hard_deletes routing`**: re-probe within 4-8 iters under "incremental + source row physically deleted" / "GDPR delete handling in dbt" / "dbt feature for source row that disappeared" framings. If 2+ recurrences under DIFFERENT phrasings, escalate to LIGHT findability cross-ref FIX-A — single-line addition in r28 incremental-strategy section + r27 incremental section: "**For SOURCE HARD-DELETES** (e.g., GDPR row physically removed from Postgres, never reappears in incremental WHERE filter), the native dbt feature is `dbt snapshots` with `hard_deletes='invalidate'` (1.9+, replaces `invalidate_hard_deletes=true`) or `hard_deletes='new_record'` for audit trail — see [r09 §SCD Option 1](09-lakehouse-schema-design.md#slowly-changing-dimensions-scd). dbt-trino adapter support uncertain (docs list dbt-postgres/bigquery/snowflake/redshift); validate before relying on it in this stack." Same family as iter1249 — single watch, no churn yet.

---

## Q2 + Q4 — clean STRONG PASS, no notes

**Q2** (4.8125): the three-CTE conditional-aggregation pivot is the textbook Trino-no-PIVOT approach. `date_diff('month', cohort_month, date_trunc('month', event_time))` is valid Trino 467 (BIGINT return, day-aware on whole-month boundaries — fine here because we're already on month boundaries via DATE_TRUNC). `COUNT(DISTINCT user_id)` is the load-bearing detail (avoids over-counting users with multiple events in a month). Immature-cohort exclusion via `WHERE date_diff('month', cohort_month, CURRENT_DATE) >= 6` is the right pattern. Retention pct via `ROUND(100.0 * monthN_count / month0_count, 1)` correct. No fabrication, no broken-secondary, no over-warning.

**Q4** (4.875): pin-perfect. `date_diff('month')` returns BIGINT integer day-aware complete months (Trino 467 `DateTimeFunctions.java`); explicit divergence from Oracle MONTHS_BETWEEN's fractional return called out with concrete example (2026-01-15→2026-07-25: Oracle 6.32 vs Trino 6). Fractional approximation `date_diff('day', start, now) / 31.0` matches Oracle's documented 31-day-month convention verbatim. Pragmatic routing ("most SaaS reporting needs only the integer") is correct. No imported-prior, no broken-secondary, no over-warning, no fabrication.

---

## Other observations

**No broken-secondary appendage in any answer this iter** — the iter1258 Q3 `SELECT * EXCEPT(rn)` / iter1255 Q3 `INSERT OVERWRITE` / iter1257 Q4 `strpos`-arithmetic / iter1253 Q4 `regexp_extract` 2-arg pattern (per `feedback_responder_broken_secondary_alternative.md`) did NOT recur. Each answer stayed tightly scoped.

**No over-warning** — Q1's "DELETE branch FIRST first-match-wins" framing is correct per docs (`feedback_responder_overwarning_folklore.md` family doesn't apply).

**No imported-prior dialect error** — all responder facts (Trino MERGE three-branch, `date_diff('month')` integer return, `WITHIN GROUP` not needed for COUNT, COALESCE behavior implicit in Q1 NULL handling) are consistent with pinned references.

**OPEN WATCHES** (carried from prior iters, all soft/per-instance recall-ceiling):
- iter1260 Q1 CDC-MERGE missing multi-event-source-dedup note (NEW this iter)
- iter1260 Q3 source-hard-delete missing dbt-snapshot hard_deletes routing (NEW this iter, same family as iter1249/iter1253 dbt-snapshot recall variance, both closed)
- iter1258 Q3 SELECT-*-EXCEPT-fabrication
- iter1258 Q4 truncate-1arg-overgen
- iter1257 Q4 strpos-arithmetic
- iter1255 Q1 bloom-CREATE-syntax
- iter1255 Q3 INSERT-OVERWRITE
- iter1253 Q4 regexp_extract-2arg
- iter1248 Q3 MATCH_RECOGNIZE-adjacency
- iter1241 concat-auto-coerces
- iter1236 rn=1-within-batch
- iter1229 @v1-Spark

**Topic checklist touched this iter**:
- Postgres-to-Iceberg ingestion (CDC) — Q1
- Analytical query patterns on Iceberg+Trino — Q2
- dbt snapshots SCD2 — Q3 (touches the topic via hard_deletes which is snapshot-config)
- Oracle PL/SQL → dbt+Trino migration — Q4

All four required topics already PASSED healthy margins; this iter probes them at routine pace.

---

## Recommendation to teacher

**NO RESOURCE CHANGES** this iter. Two soft watches added (Q1 + Q3); both at first-instance under specific question framings; per `feedback_synthesis_ceiling_stop_churning.md` discipline, do NOT churn on first occurrence — re-probe under different phrasings and escalate to LIGHT findability FIX-A only if 2+ recurrences under different framings. Per `feedback_new_card_over_attracts_adjacent.md`, do not add new attractor cards on a passing topic over a single instance.
