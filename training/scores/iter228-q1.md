# Score: iter228-q1
Score: 3.75
Topic: Trino federation / cross-source connectors

## What was correct
- Correctly affirms that Trino MERGE INTO is supported against the MySQL JDBC connector and can read from the Iceberg catalog in the same statement (cross-catalog MERGE works because MERGE writes only to one target catalog).
- Correctly identifies the catalog-level property name: `merge.non-transactional-merge.enabled=true` — exactly matches trino.io/docs/current/connector/mysql.html.
- Correctly identifies that this is disabled by default and must be explicitly enabled.
- Correct, runnable MERGE SQL syntax: `MERGE INTO ... USING (SELECT ...) ... ON ... WHEN MATCHED THEN UPDATE SET ... WHEN NOT MATCHED THEN INSERT (...) VALUES (...)` matches the Trino MERGE grammar at trino.io/docs/current/sql/merge.html.
- Correctly explains the non-transactional partial-write risk ("If your MERGE processes 5,000 of 10,000 rows and then the connection drops, those 5,000 rows stay committed") — matches the official "partial update" warning.
- Correctly recommends idempotent design (insert-or-update-by-PK is naturally idempotent) and warns against using MERGE on MySQL for non-idempotent patterns (e.g., conditional delete-then-reinsert).
- Production-environment-aware: mentions OPA authorization, which fits the prod_info.md stack.
- Strong practical applicability: the engineer has a copy-pasteable SQL example, the exact catalog property, and a session-level alternative for one-off testing.

## What was wrong or missing
- **Session property name is WRONG.** The answer uses `SET SESSION billing_mysql.non_transactional_merge = true;` — the correct name per official Trino docs is `non_transactional_merge_enabled` (with the `_enabled` suffix). Using `non_transactional_merge` will fail with an "Session property does not exist" error. This is a production-breaking factual error in the runnable code example, and it appears in two places (inside the SQL block at the top and in the "one-off test" callout below). For a federation/connector topic that is gated at threshold ≥ 4.5, this is a significant correctness penalty.
- Minor: no mention of MERGE result row-count behavior or how to verify success after a partial-write incident (e.g., reconciliation query against source vs target counts).
- Minor: does not call out that the source subquery should be deduplicated on the join key — if the Iceberg source has multiple rows per `customer_id`, MERGE on JDBC connectors will error (multiple source matches), similar to Iceberg MERGE semantics. Worth at least one line.
- Minor: does not mention that the target table needs a PRIMARY KEY or UNIQUE constraint matching the ON clause for the connector to plan the MERGE efficiently on MySQL.
- Minor beginner-clarity gap: "non-transactional" used without first defining transactional behavior vs MySQL InnoDB's actual transactional capability — the engineer may wonder "but MySQL DOES support transactions, why is this non-transactional?" A one-liner explaining that Trino's JDBC MERGE does NOT wrap the multi-statement plan in a single MySQL transaction (it issues individual statements) would close the loop.

## Dimension scores
- Technical accuracy: 3.0 — catalog property, syntax, and partial-write semantics are right; session property name is wrong (production-breaking when copy-pasted).
- Beginner clarity: 4.0 — clear structure, glossed where needed, but "non-transactional" deserves an inline gloss.
- Practical applicability: 4.0 — copy-pasteable, names the file path (`etc/catalog/billing_mysql.properties`), identifies OPA gotcha, idempotency guidance is concrete. Docked because the runnable session-level fallback won't actually run.
- Completeness: 4.0 — covers support, config, syntax, risk, idempotency, authorization. Missing: source-dedup requirement, target PK requirement, verification/reconciliation pattern.

Average: (3.0 + 4.0 + 4.0 + 4.0) / 4 = **3.75**

## Verdict
**FAIL** for this topic. Topic-specific threshold is ≥ 4.5 (Trino federation / cross-source connectors has a raised bar because of the iter158 critical-resource-gap precedent and the iter227 regression to 4.441). The wrong session property name (`non_transactional_merge` instead of `non_transactional_merge_enabled`) is exactly the class of production-breaking factual error that justifies the raised threshold — an engineer who runs the session-level snippet verbatim will hit "session property does not exist" and conclude the feature isn't supported. Teacher must fix the resource that documents the MySQL MERGE session property name before next iteration.
