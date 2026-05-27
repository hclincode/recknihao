# Score: Iter 343 Q1 — Postgres-to-Iceberg incremental sync, MERGE_CARDINALITY_VIOLATION debugging

## Scores
| Dimension | Score | Reasoning |
|---|---|---|
| **Technical accuracy** | 5 | Error name is exact (`MERGE_CARDINALITY_VIOLATION: Cannot perform Merge as multiple source rows matched a single target row`) and matches Iceberg/Spark runtime semantics. The dedup recipe — `row_number() OVER (PARTITION BY pk ORDER BY updated_at DESC)` filtered to `_rn = 1` — is the canonical pattern verified against multiple Iceberg/Delta production docs. Full-refresh-vs-MERGE distinction is correct: full refresh writes all rows fresh with no ON-clause matching, so no cardinality check fires. The three root causes (overlap-window re-reads, multiple CDC events per row, missing PK constraint) are accurately ranked. LSN/offset tiebreaker note is a genuine refinement for CDC contexts. Diagnostic table mapping (same/different `updated_at` → cause) is technically sound. No factual errors detected. |
| **Beginner clarity** | 5 | Opens with one-sentence plain-English explanation ("source data has multiple rows matching the same target row"). Explicitly disambiguates non-causes ("not a schema problem or a bug in Spark itself") which matches the engineer's three confusion points in the question. Concrete `ON t.event_id = s.event_id` example anchors the abstraction. Each window-function clause is annotated inline (`partitionBy("event_id") groups…`, `row_number() == 1 keeps one row…`). No assumed OLAP jargon — even "cardinality" is unpacked by example. |
| **Practical applicability** | 5 | Engineer gets: (1) immediate log grep target (`MERGE_CARDINALITY_VIOLATION` or `multiple source rows matched`, with explicit "not 'parse error'" correction); (2) copy-paste PySpark dedup block ready to drop in; (3) a 3-row decision table to identify which of the three root causes applies in their specific environment based on observed `updated_at` patterns. Sequencing is right: diagnose → fix → verify. Fits production stack (Spark + Iceberg 1.5.2 + on-prem); no incompatible tool recommendations. |
| **Completeness** | 5 | All three sub-questions in the prompt addressed: "Is this a bug in my Spark job?" (no, semantic constraint), "A schema problem?" (no), "Do I have duplicate rows somewhere?" (yes, in the source delta — and here are 3 common causes). Adds value beyond the literal question: why full refresh masked it, LSN tiebreaker for CDC, diagnostic mapping by `updated_at` pattern. Only conceivable nit is no mention of the inverse direction (one-source-to-many-target as silent corruption), but that is not what was asked. |
| **Average** | **5.00** | **STRONG PASS** |

## What Worked
- Exact error string surfaced verbatim — directly addresses the "the error doesn't tell me much" pain point and gives a precise grep target. This was the specific gap flagged in iter342 Q2 and the resources/13 fix has clearly propagated.
- The "why full refresh works but MERGE doesn't" section directly answers a confusion the engineer voiced ("the job runs fine on a full refresh") rather than leaving it implicit.
- Root cause #1 (overlap-window re-reads) is correctly ranked as most likely for the engineer's described scenario (switched from full refresh to incremental MERGE) — this is the highest-yield diagnostic to try first.
- LSN/Kafka-offset tiebreaker callout is a non-obvious refinement that prevents the dedup itself from being non-deterministic when two rows share the same `updated_at`.
- Diagnostic table tying observed `updated_at` patterns to each of the three causes turns abstract "you have duplicates" into a concrete debugging procedure.
- Code block is complete and runnable: imports, Window definition, transformation, view registration, MERGE — no missing pieces.

## What Missed
- Nothing material. Could optionally have mentioned the inverse cardinality direction (one source row matching many target rows when the target has duplicate PKs — silent overwrite, not an error), but the question was specifically about the runtime error the engineer hit, so omitting it is defensible.
- Could optionally have noted that `WHEN MATCHED THEN UPDATE SET *` requires source and target schemas to align, but again outside the scope of the asked error.

## Technical Accuracy Verification
- **`MERGE_CARDINALITY_VIOLATION` is the correct Iceberg/Spark runtime error**: Verified via Apache Iceberg PR #2021 (added the cardinality check) and multiple Delta/Iceberg production references. The error fires when `>1` source row matches `1` target row via the ON clause — exactly as described.
- **`row_number() OVER (PARTITION BY pk ORDER BY updated_at DESC)` dedup pattern**: Verified as the canonical Spark SQL / PySpark pattern across Databricks, Delta Lake, and Iceberg documentation. `partitionBy(pk).orderBy(F.col("updated_at").desc())` plus `filter(_rn == 1)` is the standard idiom.
- **Full refresh avoids the error because it doesn't use MERGE**: Correct — full refresh overwrites all rows with no ON clause and no matching phase, so cardinality is never evaluated. This is structurally why the engineer didn't see the error before switching.
- **Overlap-window re-reads as #1 cause**: Consistent with prior iter (iter342, iter341) Postgres-to-Iceberg coverage of lag-buffer mechanics — the lag buffer intentionally creates an overlap that produces duplicate PKs in the source delta if a row updates near the boundary.
- **CDC double-event scenario**: Accurate — Postgres logical replication emits one event per UPDATE; same row updated twice in one micro-batch yields two events with the same PK.
- **LSN/offset as tiebreaker**: Standard CDC dedup practice; LSN is strictly monotonic per Postgres WAL, more reliable than wall-clock `updated_at` when clock skew or same-millisecond updates occur.

Sources:
- [Apache Iceberg PR #2021 — Add the cardinality check for MERGE INTO](https://github.com/apache/iceberg/pull/2021)
- [Spark MERGE cardinality violation explained — SQL with Manoj](https://sqlwithmanoj.com/2021/06/18/spark-cannot-perform-merge-as-multiple-source-rows-matched/)
- [Delta Lake issue #218 — Cannot perform MERGE as multiple source rows matched](https://github.com/delta-io/delta/issues/218)
- [Writing Efficient MERGE INTO Queries on Iceberg with Spark — Cazpian](https://cazpian.ai/blog/writing-efficient-merge-into-queries-on-iceberg-with-spark)
- [Tabular — Idempotent merge pipelines cookbook](https://www.tabular.io/apache-iceberg-cookbook/data-engineering-merge-idempotent-pipelines/)
- [Databricks deduplication strategies — SunnyData](https://www.sunnydata.ai/blog/databricks-deduplication-strategies-lakehouse)
- [Delta merge dedup strategies — Sathish_DE / Medium](https://py-spark.medium.com/strategies-to-remove-duplicates-in-delta-merge-best-practices-for-batch-and-streaming-in-delta-6926cc7de84a)
