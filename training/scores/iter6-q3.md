# Iter 6 Q3 — Column-oriented storage: GROUP BY cardinality / shuffle (2nd angle)

## Scores
- Technical accuracy: 4
- Beginner clarity: 3
- Practical applicability: 4
- Completeness: 3
- Average: 3.50

## Topic updated
- Topic name: "Column-oriented storage — what it is and why it's faster for analytics"
- Prior: avg 4.75, 1 question → 2nd question
- New running avg: 4.125

## Key finding
The answer correctly identifies the hash table / accumulator mechanism and the distributed shuffle as the two causes, and gives Trino-specific EXPLAIN ANALYZE node names (HashAggregate + RemoteExchange). However, for this production stack (Trino + Iceberg + MinIO with partition pruning), the most likely cause of a 15x slowdown when adding GROUP BY country is that country is not a partition column — meaning the query now triggers a full table scan with no file skipping, rather than the accumulator-count difference per se. The answer names "add WHERE on partition column" as fix #3 but treats it as an afterthought rather than the primary diagnostic hypothesis, which inverts the production-relevant priority.

## Resource gap
`resources/03-columnar-storage.md` covers file skipping well (the Iceberg manifest -> Parquet stats -> predicate pushdown cascade), but there is no resource connecting GROUP BY to the file-skipping story — specifically, that adding GROUP BY on a non-partition column does NOT add a new WHERE predicate, so if the query was previously pruning files via an implicit filter, removing that filter while adding GROUP BY exposes the full scan. A short "why GROUP BY can trigger a full scan" section in `03-columnar-storage.md` (or a new query-performance resource) should make this explicit, with EXPLAIN ANALYZE output showing the file count before and after, and a note that two-phase aggregation in Trino reduces shuffle volume for low-cardinality groups (150 countries is not the bottleneck; missing partition filter is).
