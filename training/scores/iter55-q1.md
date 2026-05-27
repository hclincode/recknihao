# Score: iter55-q1

**Topic**: Multi-tenant analytics
**Score**: 5.0 / 5.0

## Dimension scores
- Completeness: 5/5
- Accuracy: 5/5
- Clarity: 5/5
- No hallucination: 5/5

## What the answer got right
- Correctly explains $-suffix tables are Iceberg metadata tables, not row data — and explicitly states "No row-level data is exposed" so the engineer understands the precise nature of the leak.
- Accurate breakdown of $snapshots fields: commit timestamps, operation type (append/overwrite), summary stats (records added/deleted per snapshot) — matches Trino official docs.
- Accurate breakdown of $files fields: file paths (with concrete MinIO example path `s3a://lakehouse/tenant/acme/events/...` that makes the partition-path leak tangible), per-file row counts, file sizes, and column min/max statistics — matches Trino's $files table schema (content, file_path, record_count, file_size_in_bytes, lower_bounds, upper_bounds, etc.).
- Correctly explains why per-tenant views do NOT block this — the view's WHERE clause is on row data; $-suffix queries bypass the view body and hit the metadata layer directly. Includes a labeled "Your setup probably looks like this" SQL block to ground the explanation.
- Correctly identifies the fix as a single OPA Rego deny rule for table names containing `$` for tenant principals, with admin carve-out for `admin`, `data-team`, `spark-ingest`.
- Inline glossary defines principal, Rego, carve-out, and deny-by-default — addresses the recurring beginner-clarity gap on OPA jargon flagged in earlier iterations.
- Refuses to invent Rego code — explicitly defers to the external governance document. This is the correct posture given the production stack and avoids hallucination.
- Verification recipe is concrete and runnable: SELECT against $snapshots, $files, $partitions LIMIT 1 from a tenant role should all return Access Denied; normal per-tenant view query should still succeed.
- Correctly identifies the separation from system.runtime.queries — explicitly notes blocking the system catalog does NOT protect Iceberg metadata tables in the iceberg catalog, and both rules are needed.
- Actionable closing: 4 prioritized action items including a CI test, plus framing as a P0 security issue.

## What the answer missed or got wrong
- None of substance. Minor nits: $partitions is mentioned only in the verification recipe but not enumerated in the "what these tables expose" section (partition key values = tenant IDs is arguably the most damaging leak); $history/$manifests/$entries are mentioned in the "covers all these at once" phrasing but not detailed. These omissions are appropriate given question scope (the customer asked specifically about $snapshots and $files).

## Recommendation for teacher
No resource fix required. `resources/05-multi-tenant-analytics.md` already has a comprehensive "Iceberg metadata table leak" section that the responder pulled from accurately. The inline glossary in the answer matches resource style and addresses the OPA-jargon clarity gap from earlier iterations. Resource is performing as designed for this topic angle.
