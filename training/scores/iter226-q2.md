# Score: iter226-q2
Score: 4.50
Topic: Trino federation / cross-source connectors

## What was correct
- Confirms that Trino can write to MySQL via the JDBC connector — INSERT, UPDATE, DELETE, CREATE TABLE, DROP TABLE are all supported. Verified against trino.io/docs/current/connector/mysql.html.
- Correctly identifies that UPDATE is limited to constant assignments only and that expression-based updates (e.g., `balance = balance + 100`) will fail. The docs explicitly state: "Only UPDATE statements with constant assignments and predicates are supported."
- Correctly identifies the `insert.non-transactional-insert.enabled` catalog property and the default two-phase staging behavior. Accurately frames the orphan / partial-write risk when the property is enabled.
- Correctly identifies the VARCHAR predicate pushdown limitation for the MySQL connector. The docs confirm: "The connector does not support pushdown of any predicates on columns with textual types like CHAR or VARCHAR." The follow-up warning about "fetch all + filter locally + delete" for VARCHAR-filtered DELETEs is accurate and actionable.
- Correctly identifies non-atomicity of multi-row UPDATE/DELETE through Trino-JDBC and recommends running atomic operations directly through the application's MySQL connection.
- Production-fit comment about OPA potentially denying DML on the `billing_mysql` catalog is appropriate given prod_info.md (OPA is the production authz backend).
- Practical recommendations (idempotent ops, constant-only UPDATEs, numeric/date-only DELETE filters, test on replica first) are concrete and engineer-ready.
- Clean summary table makes the operation matrix scannable.

## What was wrong or missing
- **MERGE support claim is OUTDATED / WRONG.** The answer states "MERGE: No — Not supported on MySQL JDBC connector." Per the current Trino docs (verified May 2026) and PR #24428 (chenjian2664), MERGE **IS** supported on the MySQL connector when `merge.non-transactional-merge.enabled=true` (or the `non_transactional_merge` session property) is set. This is a meaningful correctness error — an engineer following this answer would not consider MERGE as a viable option for upsert-style writes from Iceberg into MySQL. Cost: roughly -0.5 on Technical accuracy.
- Minor: the answer says "MySQL connector supports the same DML operations as the PostgreSQL connector" — this is approximately true but glosses over the per-connector pushdown differences (PostgreSQL pushes down more VARCHAR predicates because of `unsupported-type-handling` and array support differences). Not strictly wrong, but the symmetry framing is loose.
- Minor: does not mention that MERGE (when enabled) is non-transactional too and carries the same partial-write risk — would have been a natural completeness add given the answer's framing.
- Minor: does not mention CREATE TABLE AS SELECT (CTAS) which is the most natural cross-catalog pattern (`CREATE TABLE billing_mysql.invoices_snapshot AS SELECT ... FROM iceberg...`) and would have been a useful adjacent recommendation.

## Per-dimension scores
- Technical accuracy: 4.0 (MERGE-not-supported is a real factual error; rest is solid and well-cited)
- Beginner clarity: 5.0 (clear language, gotchas labeled, example SQL contrasts "this fails" vs "this works", summary table)
- Practical applicability: 5.0 (engineer-ready: concrete property names, OPA caveat appropriate for the prod stack, idempotency advice, replica-first guidance)
- Completeness: 4.0 (covers INSERT/UPDATE/DELETE/transactional caveats well; misses current MERGE support, misses CTAS)
- Average: 4.50

## Verdict
**PASS** — meets the topic-specific threshold of 4.5 exactly. The answer is mostly excellent and production-aware; the single notable defect is the outdated MERGE claim, which should be corrected in resources to reflect that MERGE on MySQL has been supported since the addition of `merge.non-transactional-merge.enabled`. Teacher action item: update the MySQL federation resource to add MERGE-on-MySQL with the non-transactional-merge property, and note the same partial-write risk applies.
