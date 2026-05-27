# Score: iter229-q1
Score: 4.75
Topic: Trino federation / cross-source connectors

## Dimension scores
- Technical accuracy: 4.75
- Beginner clarity: 4.75
- Practical applicability: 4.75
- Completeness: 4.75

## What was correct
- The core explanation is technically accurate and matches Trino's documented behavior: "The query fails if a single target table row matches more than one source row" (trino.io/docs/current/sql/merge.html). Internally Trino enforces this via AssignUniqueId + MarkDistinct, raising MERGE_TARGET_ROW_MULTIPLE_MATCHES.
- Correctly attributes the requirement to the ISO SQL MERGE specification rather than a Trino quirk. Standard SQL MERGE indeed requires at most one source row per target row per WHEN clause.
- The plain-language reframing ("the database doesn't know which source row to use") is accurate and developer-friendly, exactly matching the documented motivation (non-deterministic results otherwise).
- Correctly diagnoses the common causes of "looks fine" duplicates: overlapping ingestion batches, late-arriving rows, joining on a non-unique column, and intermediate staging-layer duplicates. These are all realistic and accurate.
- The ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY updated_at DESC) WHERE rn = 1 pattern is the canonical, correct deduplication idiom for Trino and works as written. Syntax is valid Trino SQL.
- The MERGE statement example is syntactically valid Trino, uses fully-qualified catalog.schema.table naming (billing_mysql.billing_db.customer_usage, iceberg.analytics.customer_aggregates) consistent with the prod stack (Trino 467, Iceberg connector, MySQL connector), and structures WHEN MATCHED / WHEN NOT MATCHED clauses correctly.
- Goes beyond the immediate fix with the "Prevention for incremental ingestion pipelines" section — concrete, actionable advice for any MERGE-based upsert pipeline. Strong practical applicability.
- Zero jargon assumed. The answer explains what the ON clause does, why MERGE is "at most one action per target row," and why this matters — appropriate for a SaaS engineer with no OLAP background.

## What was wrong or missing
- Minor: The answer does not mention the specific Trino exception name MERGE_TARGET_ROW_MULTIPLE_MATCHES. The engineer's question quoted the error message; naming the exact Trino exception code would help with log grepping and Googling.
- Minor: Could have noted that this constraint applies per WHEN clause condition (the SQL spec subtlety), not just per ON clause — useful for engineers writing complex MERGEs with multiple WHEN MATCHED branches.
- Minor (prod-stack relevance): The MySQL connector also requires merge.non-transactional-merge.enabled=true at catalog level and the session property non_transactional_merge_enabled to be set for MERGE to work at all on MySQL targets (per prior iter228 finding). The current error is clearly NOT about that (the query already executed), so omitting it is defensible — but a one-line "assuming you already enabled MERGE on the MySQL catalog" aside would have been gold for the prod environment.
- The answer doesn't explicitly call out that running EXPLAIN on the source subquery (or a quick SELECT customer_id, COUNT(*) FROM source GROUP BY customer_id HAVING COUNT(*) > 1) is a fast way to confirm the duplicate hypothesis before rewriting the MERGE. A diagnostic step would have rounded out "practical applicability" to a full 5.
- The ISO SQL year reference ("ISO SQL:2003") is slightly off — MERGE was added in SQL:2003 but the current Trino reference is ISO/IEC 9075:2016. Minor pedantic point; doesn't affect correctness of the conclusion.

## Verdict
PASS. Average 4.75, comfortably above the raised 4.5 threshold for this topic. The answer correctly diagnoses the error, explains the SQL-standard origin, gives a working dedup pattern with valid Trino SQL, and adds forward-looking ingestion-pipeline guidance. The few omissions (exception name, MERGE-enable prerequisite reminder, diagnostic SQL) are nice-to-haves rather than gaps that would mislead the engineer. This is the kind of answer that helps a SaaS engineer fix the bug and avoid it next time.
