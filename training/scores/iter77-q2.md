# Iter 77 Q2 — Judge Score
**Topic**: Iceberg partition design
**Score date**: 2026-05-25

| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 4.5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | **4.875** |

## Points covered
1. `ALTER TABLE SET PROPERTIES partitioning = ARRAY['hour(occurred_at)']` — correct Trino syntax, correctly flagged as instant and not rewriting history.
2. Old files keep old layout; new writes use new spec — coexistence stated explicitly.
3. `spec_id` per file tracking and Trino's transparent multi-spec query handling explicitly called out.
4. Critical caveat that historical queries won't speed up until rewrite — clearly stated with concrete example ("2pm to 3pm on May 20th still scans full day").
5. `CALL iceberg.system.rewrite_data_files(...)` with correct options, labeled Spark-only with explicit inline comment.
6. Zero-downtime guarantee with snapshot isolation explanation (in-flight queries keep reading old files).
7. `expire_snapshots` follow-up shown with parameters; storage doubling during rewrite documented in the timeline table.
8. Production-fit: references MinIO storage explicitly; Trino used for ALTER, Spark used for CALL — matches the on-prem k8s stack.

## Issues
- "ANSI SQL" / "snapshot isolation" / "spec_id" used without inline gloss — minor beginner-clarity gap. The answer assumes the reader knows what snapshot isolation means at a conceptual level (it's mentioned but not defined inline). This is a recurring minor pattern (cf. iter 44 Q1 and iter 47 Q1 notes).
- 30–90 min duration estimate for "18 months of data" is unsourced and varies wildly with data volume per day — should be conditional on row/byte counts. Minor accuracy nit.
- No mention that during/after rewrite, the new files inherit the *current* spec at rewrite time (subtle behavior worth noting). Not strictly required.

## Accuracy verification
- Trino docs confirm `ALTER TABLE ... SET PROPERTIES partitioning = ARRAY[...]` is the correct partition-evolution syntax. Partition evolution does NOT rewrite history — confirmed.
- Iceberg docs confirm `rewrite_data_files` is a Spark procedure; Trino's `ALTER TABLE EXECUTE` supports `optimize`, `rewrite_manifests`, and `expire_snapshots` but not `rewrite_data_files`. Answer's Spark-only label is correct.
- Iceberg docs confirm split planning across partition specs — each layout plans files separately, both layouts coexist. Answer's claim about transparent query handling is accurate.
- Iceberg snapshot isolation is correctly characterized: reads use a committed snapshot, writes never partially visible. Safe-to-run-without-downtime claim is correct.

## Resource fix needed?
No required fix. The answer is near-perfect for an extended-phase iteration. Minor beginner-clarity polish (inline glosses for "snapshot isolation" and "spec_id") would push it to a 5/5 across the board but is not required for passing.

## Updated topic average: 4.538 / 10 questions
(Prior: 4.500 × 9 = 40.500. New: 40.500 + 4.875 = 45.375 / 10 = **4.538**.)
