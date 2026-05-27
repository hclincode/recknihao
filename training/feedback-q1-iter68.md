# Feedback — Iter 68 Q1

**Topic**: Postgres-to-Iceberg ingestion — idempotent Spark writes, retry safety, orphan files
**Question summary**: How to make hourly Spark-to-Iceberg writes safe to retry so a crashed job doesn't leave duplicates.

---

## Scores

| Dimension | Score | Notes |
|---|---|---|
| Completeness | 5.0 | All 5 expected coverage points hit cleanly |
| Accuracy | 5.0 | Every technical claim verified against Iceberg docs and resources/13 |
| Clarity | 5.0 | Atomicity-vs-idempotency framing up front, before/after summary table, "what NOT to do" callout |
| No hallucination | 5.0 | No invented APIs, properties, or behaviors |
| **Average** | **5.0** | PASS |

---

## What worked

1. **Framed the problem correctly up front.** "Atomicity (which Iceberg guarantees) vs idempotency (which you must build into your job)" is exactly the right mental model. The user thought Iceberg's transactional writes would prevent duplicates; the answer corrects that misconception in the first sentence.

2. **Two-case crash analysis.** Enumerating "snapshot committed before crash" vs "snapshot didn't commit" makes the duplicate-row mechanism concrete. Reader walks away knowing exactly which crash produces duplicates and which doesn't.

3. **The fix is actionable, not theoretical.** The `overwritePartitions()` + CLI batch date pattern is shown with full Spark code, defensive dedup window function, and a one-line `spark-submit` example for Kubernetes CronJob retry. An engineer can copy-paste and adapt within minutes.

4. **MERGE INTO escape hatch is correctly scoped.** The late-arriving-data caveat is exactly the dangerous edge case (`overwritePartitions` wiping legitimate rows in an old partition with just the 12 late rows) — same warning that resources/13 documents prominently. MERGE INTO is correctly framed as the alternative with the right tradeoff (slower but key-based upsert).

5. **Orphan files sequence is complete and correctly ordered.** `rewrite_data_files` → `expire_snapshots` → `remove_orphan_files` with the `older_than` 3-day safety parameter explained. The "Run via spark-submit, not Trino" note matches the maintenance-tooling guidance in resources/13.

6. **Production environment fit.** Spark + Iceberg + MinIO + Hive Metastore + Kubernetes — every detail (catalog config, k8s CronJob retry, MinIO orphan-file accumulation) matches the stack in prod_info.md.

---

## Verification

- **overwritePartitions() replaces only DataFrame partitions** — confirmed: dynamic INSERT OVERWRITE semantics, only partitions present in the written DataFrame are affected (Iceberg Spark docs).
- **remove_orphan_files has older_than parameter** — confirmed: default is 3 days ago, parameter exists as documented (Iceberg Spark procedures docs).
- **MERGE INTO idempotent on unique key** — confirmed: re-running the same MERGE on a unique join key updates existing rows in place, producing identical result.

---

## Issues found

None.

---

## Recommendation

No teacher action required. This answer is a model response for this topic. Continue using resources/13 as-is; the Spark code patterns and orphan-file sequence in the resource directly produced a complete, accurate answer.
