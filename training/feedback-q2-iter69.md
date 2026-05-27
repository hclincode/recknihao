# Judge feedback — Iter 69 Q2

**Topic**: Multi-tenant analytics: isolating customer data in SaaS
**Question angle**: Per-tenant query performance monitoring (noisy-neighbor detection + data-volume growth) in a shared Trino analytics setup.
**Answer file**: /Users/hclin/github/recknihao/training/answers/iter69-q2.md

## Scores

| Dimension | Score |
|---|---|
| Completeness | 5.0 |
| Accuracy | 4.5 |
| Clarity | 5.0 |
| No hallucination | 4.5 |
| **Average** | **4.75** |

**Pass threshold**: 3.5. **Result: PASS.**

## What worked

- **Three-layer structural framing** — `system.runtime.queries` (live) → HTTP event listener → Iceberg audit table (historical) → `$partitions` metadata table (source-volume) — maps cleanly onto the question's two distinct concerns (per-tenant slowness AND data-volume growth). The engineer can pick a layer based on the question they need to answer.
- **All 5 expected coverage points hit**:
  1. `system.runtime.queries` filtered by `user` with `resource_group_id`, `state`, `elapsed_time` columns — column names correct, with a realistic RUNNING/QUEUED diagnostic SQL.
  2. HTTP event listener `QueryCompletedEvent` POSTed to a receiver, persisted to an Iceberg audit table — correct config keys.
  3. Per-tenant P50/P99 latency + week-over-week bytes_read + queue-timeout percentage SQL examples that the engineer can run as-is (modulo the `QUEUED_TIMEOUT` issue below).
  4. Iceberg `$partitions` for per-tenant size growth with correct column names (`record_count`, `total_size`, `file_count`).
  5. Security note: tenants must NOT have SELECT on `system.runtime.queries`, framed as an OPA-policy concern.
- **Production-stack fit**: re-uses Iceberg + MinIO + Hive Metastore for the audit table instead of inventing new infrastructure, mentions OPA correctly per `prod_info.md`, and gives a realistic "by end of week" rollout plan that ends with concrete tasks.
- **Operationally honest**: explicitly calls out that `system.runtime.queries` is in-memory only (last N entries) and routes the engineer to the audit table for historical analysis — that distinction is the most common confusion for engineers coming from cluster-metrics-only monitoring.

## Minor accuracy issues (cost 0.5 on Accuracy and 0.5 on No-hallucination)

1. **`QueryCompletedEvent` field-name annotations are approximate.** The answer says `statistics.elapsedTimeMs` and `metadata.queryState`. The Trino SPI `QueryStatistics` exposes `elapsedTime` (a `Duration` serialized as an ISO-8601 string, not a millisecond long suffixed with `Ms`), and `queryState` lives on the event envelope (or `QueryMetadata`), not consistently under a `metadata.` prefix in every release. An engineer copy-pasting `event.statistics.elapsedTimeMs` would not find that exact JSON path in a real captured event.
2. **`query_state = 'QUEUED_TIMEOUT'` is not a Trino terminal query state.** Real terminal states in QueryCompletedEvent are `FINISHED` and `FAILED`, with an `errorCode` like `EXCEEDED_TIME_LIMIT` or `QUERY_QUEUE_FULL` distinguishing queue-timeout failures. The illustrative SQL would return zero rows on production data. Engineer would need to filter on `error_code` / `error_type` instead.

Neither of these damages the architectural advice — the wiring, the three-layer split, and the "what to look for" interpretations are all correct. They are wording-level fixes.

## Action items for teacher

Refinements to `/Users/hclin/github/recknihao/resources/05-multi-tenant-analytics.md` HTTP-event-listener subsection:

1. Replace `statistics.elapsedTimeMs` with `statistics.elapsedTime` (Duration as ISO-8601 string in JSON), and add a one-line note that callers extracting milliseconds typically post-process this client-side.
2. Replace `query_state = 'QUEUED_TIMEOUT'` examples with `state = 'FAILED' AND error_code = 'EXCEEDED_TIME_LIMIT'` (or `error_type = 'USER_ERROR'`) so the illustrative SQL is runnable.
3. Consider adding a worked example of the JSON envelope shape `{"metadata": {...}, "statistics": {...}, "context": {...}, "ioMetadata": {...}}` so downstream answers do not drift on field paths.

## Topic state

- Multi-tenant analytics: isolating customer data in SaaS — prior avg 4.367 across 67 questions; new running avg **4.373** across 68 questions. Status: **PASSED** (well above 3.5 threshold; topic remains tested from many distinct angles).
