# Iter 348 Q2 — Judge Score Report

**Question topic**: Postgres-to-Iceberg ingestion — does a Postgres column DROP propagate to Iceberg via Debezium, and what happens to historical data in old rows?

**Answer file**: `/Users/hclin/github/recknihao/training/answers/iter348-q2.md`
**Resource cited**: `/Users/hclin/github/recknihao/resources/13-postgres-to-iceberg-ingestion.md`

---

## Score Table

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | Every load-bearing claim is correct and verifiable. Iceberg does NOT auto-drop columns on source change — correct. WAL RELATION message on next DML (no DDL event from pgoutput) — correct per Debezium docs. ALTER TABLE DROP COLUMN is metadata-only and existing Parquet bytes remain — correct per Iceberg spec. Time-travel queries against pre-DROP snapshots still expose the column via stable field IDs — correct per Iceberg semantics (Trino issue #14064 was fixed in PR #14076, so Trino 467 supports this). AnalysisException on MERGE INTO schema mismatch — directionally correct (Spark MERGE INTO with explicit column references will fail; with wildcards + mergeSchema it can fill NULL but write-ordering bug per apache/iceberg#10751 still trips it — the answer's framing is the safe operational stance). |
| Beginner clarity | 5.0 | Opens with the direct yes/no answer in plain English. "Stay queryable somehow" question is answered with concrete Trino SQL example. Concepts that could confuse (field IDs, snapshots, expire_snapshots) are explained inline with the consequence, not as theory. No unexplained jargon. |
| Practical applicability | 5.0 | Gives the exact runbook the engineer needs: `kubectl scale` to pause, `ALTER TABLE ... DROP COLUMN` SQL, `kubectl scale` to resume, "under 60 seconds" expected downtime. Names the production stack pieces (Trino, Spark, MinIO, Kafka 7-day retention) correctly per prod_info.md. Time-travel SQL example is copy-pasteable. Closes with the long-term preservation suggestion (export to separate table) — exactly the actionable next step. |
| Completeness | 5.0 | Covers all three angles of the question: (a) does Iceberg auto-drop — no, with explanation of why and consequences if you don't act, (b) what happens to historical data — stays in Parquet, queryable via time-travel until expire_snapshots, (c) bounded retention window — explicit 7-day callout. Bonus: failure mode (AnalysisException + streaming loop stall), `remove_orphan_files` mention, and long-term archival guidance. Nothing material missing for this scope. |
| **Average** | **5.00** | |

---

## What Worked

- **Three-layer framing** (Postgres → Debezium → Iceberg) parallels how column-RENAME (iter347 Q2) and column-TYPE-CHANGE (iter346 Q2) were answered. Consistent mental model is forming.
- **Direct answer first, then runbook**: "does NOT automatically drop" in line 3, before any setup. The engineer gets the answer they need before reading the why.
- **WAL RELATION + next DML** correctly framed (no DDL event from Postgres pgoutput plugin — Debezium piggybacks on the next data change to refresh schema). This is the exact gap that bites engineers who expect a "schema change" Kafka event.
- **Time-travel example is precise** — uses `FOR VERSION AS OF <snapshot_id_before_drop>` Trino syntax, and explains the field-ID mechanism that makes it work.
- **Snapshot expiry is the real cliff** — answer correctly identifies that the 7-day retention window is when data becomes truly unrecoverable, not the DROP itself. Many answers miss this bounded grace period.
- **Long-term preservation footnote** ("export to a separate table before running maintenance") gives the engineer a concrete option for the "we may need this later" case.

---

## What Missed

Nothing material for the question asked. Minor optional adds that would not raise the score further but worth noting:

- Did not mention `CALL iceberg.system.rollback_to_snapshot(...)` as the alternative recovery path if the DROP was a mistake (vs. the more manual time-travel-and-extract approach). Resource line 1493 covers this; responder chose extract-to-new-table only.
- Did not mention that downstream dbt models and Trino views referencing `legacy_metadata` will need to be updated before the DROP is run (coordination step). Out of strict scope but a real prod concern.
- Did not call out that Spark MERGE INTO with `mergeSchema=true` and wildcard column resolution can sometimes auto-fill NULL for the missing source column (apache/iceberg#10751 bug aside) — the answer presents AnalysisException as the only outcome, which is the safe operational framing but slightly oversimplified.

None of these would bump the score down — they are nice-to-haves, not required for completeness on this question.

---

## Technical Accuracy Verification (WebSearch)

| Claim | Verification source | Verdict |
|---|---|---|
| Postgres ALTER TABLE DROP COLUMN does not emit a DDL event via logical decoding; Debezium detects via RELATION message on next DML | debezium.io FAQ + pgoutput docs ("logical decoding does not support DDL changes... no changes recorded in WAL for existing records... only once a record is inserted/updated/deleted will the connector then capture the change") | CONFIRMED |
| Iceberg ALTER TABLE DROP COLUMN is metadata-only; existing Parquet files are NOT rewritten; column bytes remain physically on disk | iceberg.apache.org spec + Iceberg schema-evolution docs ("Iceberg allows columns to be added, renamed, reordered, or dropped without rewriting existing data files... Schemas are tracked using column IDs rather than names") | CONFIRMED |
| Time-travel queries against pre-DROP snapshots still expose the dropped column via stable field IDs | Iceberg spec + trinodb/trino issue #14064 (originally Trino did NOT respect historical schema; PR #14076 fixed it. Trino 467 has the fix) | CONFIRMED — Trino 467 supports this |
| Spark MERGE INTO throws AnalysisException when source events lack a column the target expects | apache/iceberg#10751 ("missing column in source DataFrame should be filled with NULL, however, this doesn't work if the missing column is used in write ordering... Spark responds with an AnalysisException") | CONFIRMED (with caveat — strict-schema MERGE always fails; wildcard + mergeSchema can NULL-fill except for write-ordering bug) |
| Iceberg `expire_snapshots` is what makes the column data truly unrecoverable | iceberg.apache.org maintenance docs | CONFIRMED |
| `remove_orphan_files` may eventually clean up the unreferenced Parquet files | iceberg.apache.org maintenance docs | CONFIRMED |
| Trino `ALTER TABLE iceberg.analytics.events DROP COLUMN legacy_metadata` syntax | trino.io Iceberg connector DDL docs | CONFIRMED |

All claims pass verification. No factual errors in the answer.

---

## Resource Fix Applied

**None required.** Resources/13 lines 1470–1493 already cover this scenario comprehensively:
- ADD vs DROP vs TYPE CHANGE asymmetry (line 1470)
- DROP is metadata-only, bytes remain in Parquet, recoverable via time-travel (line 1473)
- Time-travel SQL example with both VERSION AS OF and TIMESTAMP AS OF (lines 1475–1483)
- Explicit framing of the three retention windows (lines 1489–1491)
- Rollback recovery path via `rollback_to_snapshot` (line 1493)

The responder pulled the right content from the resource and presented it in the right order for an engineer-in-the-moment scenario. No teacher action needed.

---

## Rubric Update

**Topic**: Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling

- Prior: 4.513 avg across 128 questions
- This iter Q2 score: 5.00
- New running avg: (4.513 × 128 + 5.00) / 129 = (577.664 + 5.00) / 129 = 582.664 / 129 = **4.517 across 129 questions**
- Status: **PASSED** (5th consecutive perfect score on Debezium CDC schema-evolution scenarios: ADD COLUMN → RENAME COLUMN → TYPE CHANGE → DROP COLUMN — the resources/13 schema-evolution sections are now demonstrably battle-tested across all four DDL classes)
