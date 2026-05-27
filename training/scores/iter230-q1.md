# Iter 230 Q1 Score

**Score: 4.75 / 5.0**
**Pass: YES** (threshold is 4.5 in extended/final phase)

## What was correct

- **EXPLAIN ANALYZE executes the query**: Correctly warns the user up front that it re-runs the actual expensive query — important practical caveat for a one-minute query.
- **Output field semantics**: `CPU`, `Scheduled`, `Blocked: Input` / `Blocked: Output`, `Input`, and `Physical Input` are all real Trino EXPLAIN ANALYZE fields and the descriptions are accurate. Verified against Trino 481 docs and the operator-level breakdown showing e.g. `Input: 1500000 rows (18.17MB), Physical Input: 4.51MB`.
- **Three-layer framing** (Iceberg side / dynamic filtering / join distribution) is exactly the right diagnostic mental model for a federated MySQL × Iceberg query and is well-ordered.
- **Dynamic filtering description**: The build-side / probe-side mechanics are correct. Dynamic filtering on JDBC connectors is real (introduced in PR #13334) and the wait-timeout failure mode (timeout → Iceberg scan proceeds without the filter, high `Blocked: Input`) is correct. The default 20-second timeout claim is implied but not stated — minor.
- **Partition-pruning vs non-partition-column WHERE-clause example** is concrete and actionable; the `event_date` vs `event_type` example is exactly the kind of contrast a beginner can recognize in their own SQL.
- **Join distribution terminology** (`PARTITIONED` vs `BROADCAST`) is correct and matches official Trino EXPLAIN output. The guidance about BROADCAST for small dim tables / PARTITIONED for large is consistent with Trino CBO docs.
- **ANALYZE TABLE recommendation for missing CBO stats** is correct, including the MySQL-side caveat that statistics accuracy is lower (confirmed: Trino MySQL connector docs explicitly say this).
- **`SHOW STATS FOR <catalog>.<schema>.<table>`** is the correct command to inspect stats availability on a Trino-side catalog.
- **`Scheduled >> CPU` = I/O-bound** is the right rule of thumb for a remote scan.
- **Final framing** ("It's rarely a federation problem — it's usually data volume because filtering broke down") is exactly the right takeaway for a SaaS engineer.
- **Production fit**: Aligns with the on-prem Trino 467 + Iceberg + MinIO stack. No cloud-only references. MySQL as a billing-DB lookup is a realistic federated scenario.

## What was wrong or missing

- **"Use Scheduled, not Wall time — that field doesn't exist in Trino 467"** is a slightly misleading aside. Trino EXPLAIN ANALYZE has never used "Wall time" as a field name in standard output; the standard fields are CPU/Scheduled/Blocked/Output/Input. Telling the user a field "doesn't exist" implies they might have heard of it; better to just say "Scheduled is wall-clock time the operator was active." Minor and not factually wrong.
- **DynamicFilter operator naming**: The answer says to look for "DynamicFilter" or "DynamicFilterAssignment" — the actual node in the EXPLAIN plan typically appears as a `DynamicFilter` predicate annotation on the ScanFilterProject node (e.g., `dynamicFilter = ...` or `dynamicFilters = {df_1}`), not as a standalone operator node. A user grepping for `DynamicFilter` will still find it, but the phrasing could mislead them to expect a separate operator block.
- **`dynamic-filtering.wait-timeout` (default 20s) is not named**. Naming the actual catalog property would make the "MySQL side timed out" guidance fully actionable — the engineer could check or tune it in `etc/catalog/mysql.properties`.
- **`domain-compaction-threshold`** (default 256) is not mentioned. Trino's MySQL connector docs explicitly call this out as a tuning knob when dynamic filters get large; for a join producing 5K rows from a Iceberg/MySQL pair, this can matter and is a natural extension of the dynamic-filtering discussion.
- **Step 5 (network/I/O time)** is described correctly but the answer could mention `Blocked: Input` time on the MySQL scan as the specific signal for "JDBC roundtrip is slow," distinct from the Iceberg scan's I/O wait.
- **No mention of EXPLAIN (without ANALYZE)** as a cheaper first step to inspect the plan structure (join order, distribution, dynamic filter presence) without re-running the query. For a one-minute query the user could iterate faster with plain EXPLAIN first, then confirm with EXPLAIN ANALYZE.
- **5,000-row result context** (the user said the query returns ~5K rows) is not directly addressed. A small result set strongly suggests filtering breaks down somewhere mid-pipeline; the answer touches this implicitly via the Iceberg `Physical Input` step but doesn't explicitly say "5K final rows but Iceberg scanning GB → filter pushdown broke."

## Verification notes

- **EXPLAIN ANALYZE field names** (CPU, Scheduled, Blocked: Input/Output, Input, Physical Input): verified against Trino 481 docs (https://trino.io/docs/current/sql/explain-analyze.html). All field names in the answer are correct.
- **Physical Input vs Input distinction**: verified — Input is logical rows/bytes before filter, Physical Input is actual bytes read from storage; can differ due to column pruning and predicate pushdown.
- **Dynamic filtering on JDBC connectors**: verified via Trino dynamic filtering docs and PR #13334; supported for MySQL connector; `dynamic-filtering.enabled` and `dynamic-filtering.wait-timeout` (default 20s) are real catalog properties.
- **PARTITIONED vs BROADCAST join terminology**: verified — these are the actual values for `join-distribution-type` and appear in EXPLAIN output. AUTOMATIC mode lets the CBO decide; falls back to PARTITIONED when stats are absent.
- **MySQL connector statistics caveat**: verified — Trino MySQL connector docs state accuracy may be lower than other connectors and recommend `ANALYZE TABLE ... UPDATE HISTOGRAM ON` on the MySQL side for better stats.
- **SHOW STATS FOR**: verified as the correct Trino SQL command to inspect connector-supplied statistics.

## Recommendation for teacher

The resource is in strong shape on this topic — this is a clear pass. Optional refinements:

1. **Name the catalog properties** in the federation resource: `dynamic-filtering.enabled`, `dynamic-filtering.wait-timeout` (default 20s), and `domain-compaction-threshold` (default 256). These transform "the MySQL side timed out" advice from diagnostic to actionable.
2. **Clarify the DynamicFilter representation in EXPLAIN output**: it appears as a predicate annotation (`dynamicFilter = {df_1}` or `dynamicFilters = [...]`) on the probe-side ScanFilterProject, not as a standalone operator node. Add a one-line example of what to grep for.
3. **Add a "use EXPLAIN first, then EXPLAIN ANALYZE" workflow note** for expensive queries — cheap plan inspection before paying the runtime cost.
4. **Drop the "Wall time doesn't exist in Trino 467" aside** or rephrase to "Trino reports `Scheduled` (wall-clock) and `CPU` (compute time) — use `Scheduled` for end-to-end latency." The current phrasing is slightly confusing.
5. Consider an explicit pattern callout: "Small result set (5K rows) + long runtime + high Iceberg `Physical Input` = filter pushdown / dynamic filter broke down." This is the most common federated-slow-query archetype.

## Per-dimension scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4.75 | All major claims verified. Minor imprecision on DynamicFilter operator representation and the "Wall time" aside. |
| Beginner clarity | 4.75 | "Build side", "probe side", "CBO", "NDV" appear with brief inline glosses; concrete WHERE-clause examples; step-by-step checklist. Could use one more sentence on what "build/probe" mean visually. |
| Practical applicability | 4.75 | Step-by-step checklist with specific operators to look at and specific commands (`ANALYZE TABLE`, `SHOW STATS FOR`). Missing the specific tunable property names (`dynamic-filtering.wait-timeout`, `domain-compaction-threshold`) prevents a 5.0. |
| Completeness | 4.75 | Covers Iceberg scan, dynamic filtering, join distribution, MySQL scan, I/O vs CPU. Missing: plain EXPLAIN as cheap first pass; explicit small-result-set heuristic; named tuning properties. |
| **Average** | **4.75** | |
