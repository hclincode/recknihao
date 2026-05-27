# Iter 210 Q1 — Judge Feedback

## Question

What's the exact session property name to raise the broadcast join threshold? What's the default value? How do I verify in EXPLAIN whether Trino chose broadcast vs partitioned for a cross-catalog join (Postgres tenants table ~60MB joining Iceberg events)?

**Context**: This question directly re-tests the angle that caused a 3.625 FAIL in iter208 Q1. The teacher fixed the resource with the correct property name and EXPLAIN notation. This evaluation rigorously verifies that the fix held.

## Verification of technical claims (via WebSearch against trino.io)

| Claim in answer | Verified? | Evidence |
|---|---|---|
| `join_max_broadcast_table_size` is the session property name | YES | trino.io cost-based optimizations page |
| Default = 100MB | YES | trino.io explicitly states "By default, the replicated table size is capped to 100MB" |
| Config property `join-max-broadcast-table-size` (hyphenated) | YES | matches Trino config-property naming convention |
| AUTOMATIC defaults to PARTITIONED when stats are missing | YES | Trino docs and release 0.207 confirm "If no statistics are available, AUTOMATIC is the same as REPARTITIONED" |
| EXPLAIN notation `Distribution: REPLICATED` / `Distribution: PARTITIONED` | YES | Confirmed in EXPLAIN output for InnerJoin nodes |
| EXPLAIN notation `Exchange[Type=REPLICATE]` / `Exchange[Type=REPARTITION]` | YES | Trino docs show `RemoteExchange[REPARTITION]` in distributed plan example |
| Answer correctly debunks fake notation `Join[BROADCAST]` | YES | Real Trino plan does not label the Join node with distribution; distribution is on Exchange or as a Distribution field |
| Iceberg `ANALYZE TABLE ... WITH (columns = ARRAY[...])` syntax | YES | Matches Trino 481 Iceberg connector docs verbatim |
| Postgres stats from `pg_stats` via Postgres `ANALYZE` | YES | Trino's PostgreSQL connector relies on Postgres-side statistics |
| Iceberg stats stored in Puffin metadata files | YES | Iceberg connector uses Puffin for NDV and column stats |

All technical claims independently verified. No factual errors detected.

## Scoring

### Technical accuracy: 5.0

Every concrete claim verified against trino.io documentation:
- Property name and default exact
- EXPLAIN notation (both `Distribution: REPLICATED` and `Exchange[Type=REPLICATE]` variants) correctly described
- AUTOMATIC + missing-stats fallback to PARTITIONED correctly explained — this was the exact gap previously
- Iceberg ANALYZE syntax correct
- Correctly distinguishes `join_max_broadcast_table_size` from `query.max-memory-per-node` (a known confusion)
- Correctly debunks the made-up `Join[BROADCAST]` notation

This is the corrected answer that the teacher's fix produced. No drift, no hallucination.

### Beginner clarity: 4.5

- Defines what the property controls in concrete terms ("operative tuning knob")
- Concrete cross-catalog example query with both catalogs visible
- The relationship between `join_distribution_type` (AUTOMATIC/BROADCAST/PARTITIONED) and the threshold is clearly laid out with three bullet rows
- Explicit footnote on why made-up `Join[BROADCAST]` notation should not be trusted
- Runbook section ties everything together in numbered, actionable steps
- Minor friction: the rapid jump between the threshold, the distribution type, the stats angle, and the EXPLAIN output could trip a true beginner — but the engineer asked a three-part question and the structure mirrors that, which is appropriate

### Practical applicability: 5.0

- Concrete cross-catalog query mirrors the engineer's exact scenario (60MB tenants ⨝ events)
- Tells engineer the default 100MB already covers their 60MB case — addresses the question above the literal request
- Suggests the threshold to use once the table grows ("200MB or higher")
- Both session-level and cluster-wide changes shown
- `SHOW STATS` checks with expected populated columns
- Practical runbook entry that can be pasted into ops docs
- Production-fit (Trino 467 with Iceberg connector, Hive Metastore, cross-catalog Postgres) — no incompatible recommendations

### Completeness: 5.0

Question has three explicit parts:
1. Exact session property name — answered with name AND its hyphenated config-property equivalent
2. Default value — answered as 100MB with confirmation
3. How to verify in EXPLAIN — answered with both notation variants, the Exchange location ("above the join"), the AUTOMATIC + stats nuance, and `SHOW STATS` to diagnose why a join didn't broadcast

Bonus value: the AUTOMATIC + missing-stats fallback, the warning about made-up notation, and the runbook all go beyond the strict question while staying relevant.

## Weighted score

(Technical × 2 + Clarity + Practical + Completeness) / 5
= (5.0 × 2 + 4.5 + 5.0 + 5.0) / 5
= (10.0 + 4.5 + 5.0 + 5.0) / 5
= 24.5 / 5
= **4.9**

## Verdict

**PASS (4.9)** — strong recovery from iter208 Q1's 3.625 FAIL. The previously-missing facts (correct property name with default, correct EXPLAIN notation, AUTOMATIC-with-missing-stats fallback) are now all present and verified. The answer is also production-fit for Trino 467 + Iceberg + cross-catalog Postgres and addresses the engineer's exact scenario.

## Notes for teacher

- Resource fix successfully held under direct re-testing. No new resource gaps surfaced.
- Continue to monitor whether this same level of EXPLAIN-output specificity appears in answers for other join-tuning questions (e.g., questions about `task_concurrency`, `hash_partition_count`, or dynamic filtering verification in EXPLAIN).
