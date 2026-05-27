# Iter 333 Q2 Score — Null source_lsn During Debezium Initial Snapshot

**Topic**: Postgres-to-Iceberg ingestion
**Question**: Is null `source_lsn` during Debezium initial snapshot normal, and will it corrupt the MERGE dedup that uses `s.source_lsn > t.source_lsn`?

## Score table

| Dimension | Score | Notes |
|---|---:|---|
| Technical accuracy | 5 | All five sub-claims verified against Debezium docs and SQL three-valued logic |
| Beginner clarity | 5 | Step-by-step trace of the MERGE evaluation makes the NULL semantics intuitive |
| Practical applicability | 5 | Drop-in corrected MERGE plus a concrete test procedure |
| Completeness | 5 | Covers: expected behavior, why it breaks, the fix, and how to verify |
| **Average** | **5.00** | |

## What worked

- **Correct root-cause explanation**: snapshot rows have no WAL position because they were read via SELECT before streaming began. Clearly distinguishes snapshot reads (`op='r'`) from WAL-derived events (`'c'/'u'/'d'`).
- **NULL-propagation walkthrough**: the numbered trace ("`500 > NULL` evaluates to NULL → NULL is falsy → UPDATE does not fire → silent drop") is exactly the right level for a SaaS engineer with no SQL three-valued-logic background. Names the failure mode (silent drop) which is the actual production risk.
- **Corrected MERGE is the canonical pattern**: `WHEN MATCHED AND (t.source_lsn IS NULL OR s.source_lsn > t.source_lsn)`. Reads cleanly and preserves the idempotency guard for the non-snapshot case.
- **Test procedure is actionable and falsifiable**: insert pre-Debezium, update post-Debezium, check Iceberg. Explicitly states the negative case ("without the fix, the update will be silently dropped") so the engineer knows what failure looks like.
- **Bootstrap pattern reference**: the `df.withColumn("source_lsn", lit(None).cast("long"))` snippet matches the bootstrap pattern documented in resources/13 (line 2087), which gives the engineer the upstream view of why null shows up.
- **Tight scope**: doesn't drift into adjacent topics. Answers exactly what was asked.

## What missed

- Nothing material. Could have noted that `op='r'` is the Debezium identifier for snapshot reads (so the engineer could verify in Kafka envelope inspection), but the answer focuses on the `source_lsn` field which is what the question is about.
- Minor: doesn't explicitly call out that this exact problem also affects the `WHEN NOT MATCHED AND s.op IN ('c','r','u')` clause if `'r'` was previously omitted — but the included MERGE has `'r'` in the insert branch, so the fix is implicitly correct.

## Technical accuracy verification

Verified all five sub-claims:

1. **Null source.lsn during initial snapshot is normal**: CONFIRMED. Debezium PostgreSQL connector docs and Confluent docs both describe snapshot reads (`op='r'`) as generated before WAL streaming begins; LSN at that point is the offset placeholder, not a per-row WAL position. The answer's framing ("rows did not come from the WAL, so no LSN to attach") is the correct mental model.
2. **`500 > NULL` evaluates to NULL, not false**: CONFIRMED. SQL three-valued logic (ANSI SQL, also documented by Microsoft Learn and modern-sql.com) returns UNKNOWN for any arithmetic/comparison operator with a NULL operand. In MERGE `WHEN MATCHED AND <condition>`, UNKNOWN is treated as not-true, so the UPDATE branch does not fire.
3. **`t.source_lsn IS NULL OR s.source_lsn > t.source_lsn` is the correct fix**: CONFIRMED. This is the canonical NULL-safe guard for the snapshot-then-stream pattern. `IS NULL` returns true (not unknown), so the OR short-circuits correctly when the target is a snapshot row.
4. **Null LSN means initial snapshot vs WAL stream**: CONFIRMED. This is the semantic distinction the answer makes and it aligns with Debezium's documented snapshot vs streaming phases.
5. **Test procedure (insert before, update after) is valid**: CONFIRMED. This exercises exactly the failing path — a snapshot row (null LSN) receiving a subsequent live CDC update.

## Rubric update

- Postgres-to-Iceberg ingestion: prior 4.499 across 118 questions → (4.499 × 118 + 5.00) / 119 = **4.503 across 119 questions**. Status: PASSED.
