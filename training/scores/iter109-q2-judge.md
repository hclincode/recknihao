# Iter 109 Q2 — Judge Verdict

**Question**: Debezium CDC → Iceberg; bulk DELETE of 2M trial rows on Sunday causes Trino slowness for 1-2 days. What's happening and what should we do?

**Topic**: Postgres-to-Iceberg ingestion (CDC with Debezium)

**Answer file**: `/Users/hclin/github/recknihao/training/answers/iter109-q2.md`

---

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 3.5 | Core MoR/position-delete mechanism correct; diagnostic SQL uses wrong column name; rewrite_data_files prescription omits the option that actually triggers delete cleanup |
| Beginner clarity | 4.5 | Excellent layering; "markers vs rewrites" metaphor is accessible; no unexplained jargon |
| Practical applicability | 3.5 | Production-fit (Spark procedures, MinIO, on-prem compatible); decision matrix is actionable; BUT key code snippets are broken/incomplete and won't behave as described |
| Completeness | 4.0 | Covers root cause, diagnosis, immediate + long-term fixes, decision matrix; misses `rewrite_position_delete_files` and write-mode property |
| **Weighted average** | **3.875** | Passes 3.5 threshold but with notable accuracy gaps for a topic that should now be mature |

---

## Verified technical claims

### Correct
- Iceberg v2 MoR semantics: DELETE writes position delete files rather than rewriting data; query-time merge applies them. Confirmed against [Iceberg spec](https://iceberg.apache.org/spec/) and [Trino Iceberg docs](https://trino.io/docs/current/connector/iceberg.html).
- Debezium Postgres connector streams **one DELETE event per affected row** even for bulk SQL DELETEs. Confirmed in [Debezium PostgreSQL connector docs](https://debezium.io/documentation/reference/stable/connectors/postgresql.html) — "produces a change event for every row-level insert, update, and delete operation."
- `expire_snapshots` is the correct procedure name and signature for snapshot cleanup so MinIO can reclaim space.
- `CALL iceberg.system.*` correctly labeled as a Spark procedure (not Trino).

### Incorrect / misleading
1. **Broken diagnostic SQL (HIGH severity)** — The answer's query is:
   ```sql
   SELECT COUNT(*) FROM iceberg.analytics."expired_trials$files"
   WHERE file_type = 'POSITION_DELETE';
   ```
   The Trino Iceberg `$files` metadata table does **not** have a `file_type` column. It has a `content` column of type INTEGER with values `0=DATA`, `1=POSITION_DELETES`, `2=EQUALITY_DELETES`. Confirmed against current Trino documentation. The correct query is:
   ```sql
   SELECT COUNT(*) FROM iceberg.analytics."expired_trials$files"
   WHERE content = 1;
   ```
   An engineer who copy-pastes the answer's SQL into Trino 467 will get a "Column 'file_type' cannot be resolved" error. This breaks the diagnosis step entirely.

2. **`rewrite_data_files` without `delete-file-threshold` may not clean position deletes (MEDIUM severity)** — By default `rewrite_data_files` rewrites only when data-file criteria are met; accumulated position deletes alone do not necessarily trigger a rewrite of the data files they reference. The answer should include either:
   ```python
   options => map('delete-file-threshold', '1', 'target-file-size-bytes', '268435456')
   ```
   or call the more targeted `rewrite_position_delete_files` procedure (which the answer never mentions). Without one of these, the prescribed "quickest fix" may leave delete markers in place after running.

3. **"UPDATEs produce fewer delete markers than DELETEs" (LOW severity)** — Both UPDATEs and DELETEs in MoR mode write position deletes; UPDATE is internally delete+insert, producing one position delete marker per affected row plus a new data row. The real benefit of the soft-delete pattern is **timing control** (cleanup runs in a maintenance window) and **predictability**, not fewer markers. The answer's framing is misleading.

4. **No mention of COW mode (LOW severity)** — For a table that experiences predictable bulk-delete patterns, setting `write.delete.mode=copy-on-write` at the table level pushes the rewrite cost into the writer rather than the reader. This is a one-property fix that fundamentally changes the tradeoff and deserves at least a mention in the decision matrix.

---

## Errors / gaps to address

1. **Resource fix needed**: The Trino metadata-table syntax for delete file counting must be corrected wherever it appears in `resources/`. The pattern `WHERE file_type = 'POSITION_DELETE'` against `$files` is not valid Trino syntax — the correct column is `content` (integer, value `1` for position deletes). Search resources for similar mistakes.
2. **Resource enhancement needed**: Document `rewrite_position_delete_files` Spark procedure and the `delete-file-threshold` option on `rewrite_data_files`. Without these, the "compact after bulk delete" prescription is incomplete.
3. **Resource enhancement needed**: Add a brief note on `write.delete.mode` table property (`merge-on-read` default vs `copy-on-write`) and when to flip it for bulk-delete-heavy tables.
4. **Resource correction needed**: Clarify that soft-delete UPDATEs do NOT produce fewer position deletes than hard DELETEs — the benefit is timing control, not marker volume.

---

## Production environment fit

- Spark procedure syntax (`CALL iceberg.system.*`) is correct for on-prem Spark + Iceberg 1.5.2.
- MinIO/S3 mentioned appropriately for snapshot expiry → object reclamation.
- No incorrect cloud-only tool recommendations.
- Auth/OPA not relevant to this question.

---

## Running average update

- Prior topic avg: 4.480 across 93 questions
- This score: 3.875
- New avg: (4.480 × 93 + 3.875) / 94 = (416.640 + 3.875) / 94 = 420.515 / 94 = **4.474** across 94 questions
- Status: **PASSED** (4.474 >= 3.5)

This score (3.875) is the lowest the topic has seen in recent iterations and pulls the topic average down from 4.480 to 4.474. The two material accuracy issues (broken SQL, incomplete compaction recipe) are the kind of mistakes that erode trust because they fail on first use rather than being abstract inaccuracies.

---

## Verdict

**PASS** at 3.875 weighted, but with concrete resource fixes required:
1. Correct `$files` metadata table column name from `file_type` (string) to `content` (integer 0/1/2).
2. Document `rewrite_position_delete_files` and the `delete-file-threshold` option.
3. Add `write.delete.mode` (MoR vs COW) to the decision toolkit.
4. Correct the "fewer markers" framing for soft-delete UPDATE pattern.
