# Judge Score — Iter 328 Q2

## Scores
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | Every column name verified against Trino official docs. `length` BIGINT, `added_data_files_count` INTEGER, full 12-column list, and the `"events$manifests"` quoting are all correct. The Trino 467 vs 470+ note re `optimize_manifests` is also accurate. |
| Beginner clarity | 5 | Leads with the exact two answers in bold, explicitly calls out the wrong names the engineer guessed, explains the quoting rule, and the column table has plain-English meanings. Zero unexplained jargon. |
| Practical applicability | 5 | Copy-pasteable Trino 467 query against the engineer's likely table (`iceberg.analytics.events`), correct quoting, interpretation thresholds (>200 manifests, <5 files = streaming pattern), and before/after rewrite_manifests workflow with the correct Spark CALL syntax. Engineer can run this immediately on prod. |
| Completeness | 5 | Both asked-for columns answered with exact types, full query example, full column list with types and meanings, quoting syntax explained, and before/after diagnostic flow added as bonus. Nothing material missing. |
| **Average** | **5.00** | **PASS** |

## What Worked
- Anti-pattern callout structure: leads with "not `manifest_length`, not `file_size`" exactly matching the engineer's guesses in the question.
- Quoting explanation includes the wrong form alongside the right form — directly addresses "I don't want another runtime error".
- Full column table with types and beginner-friendly descriptions doubles as a reference card.
- Correctly distinguishes `added_data_files_count` from `existing_*` and `deleted_*` and explains what each means (added in this manifest vs inherited from prior snapshots vs removed).
- Bonus before/after rewrite_manifests example is the natural next operational step.
- Correctly flags that `optimize_manifests` is Trino 470+ and not available on prod Trino 467, points to Spark CALL form.

## What Missed
- Nothing material. Could nitpick that `partition_summaries` is shown as `ARRAY(ROW)` rather than the fully-spelled `ARRAY(row(contains_null BOOLEAN, contains_nan BOOLEAN, lower_bound VARCHAR, upper_bound VARCHAR))` from Trino docs, but the abbreviation is acceptable in a beginner table.
- Could mention `$all_manifests` as the alternative when historical (non-current-snapshot) manifests are needed, but the engineer only asked about current-state size, so this is out of scope.

## Technical Accuracy (verified)
WebSearched Trino official Iceberg connector documentation. Confirmed:
1. **`length` (BIGINT)** is the correct column for manifest file size. `manifest_length` does NOT exist. ✓
2. **`added_data_files_count` (INTEGER)** is a real column in `$manifests`. ✓
3. **Full 12-column list verified** against trino.io/docs/current/connector/iceberg.html — every column name and type in the answer matches exactly: content (INTEGER), path (VARCHAR), length (BIGINT), partition_spec_id (INTEGER), added_snapshot_id (BIGINT), added_data_files_count (INTEGER), added_rows_count (BIGINT), existing_data_files_count (INTEGER), existing_rows_count (BIGINT), deleted_data_files_count (INTEGER), deleted_rows_count (BIGINT), partition_summaries (ARRAY(ROW(...))). ✓
4. **`"events$manifests"` quoting** is the standard Trino convention for `$`-named metadata tables. ✓
5. `CALL iceberg.system.rewrite_manifests(table => 'analytics.events')` Spark form is correct.
6. Trino 467 not having `optimize_manifests` is correct — that procedure was added later (470+).

Sources:
- [Iceberg connector — Trino current docs](https://trino.io/docs/current/connector/iceberg.html)
- [Trino PR #10809: Expose data files rows statistics fields in $manifests table](https://github.com/trinodb/trino/pull/10809)

## Rubric Update
- Iceberg table maintenance: prior avg 4.556 across 24 questions → (4.556 × 24 + 5.00) / 25 = (109.344 + 5.00) / 25 = 114.344 / 25 = **4.574 across 25 questions**. Status: **PASSED**.
