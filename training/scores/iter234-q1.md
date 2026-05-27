# Iter 234 Q1 Score

**Score: 4.75 / 5.0**
**Pass: YES** (threshold is 4.5 in extended/final phase)

## What was correct

- **MySQL connector write support correctly enumerated**: INSERT, UPDATE, DELETE, and MERGE are all supported on the Trino MySQL connector. The summary table is accurate.
- **UPDATE constant-only restriction is correctly stated** with a working example (`SET status = 'inactive'`) and a failing example (`SET balance = balance + 100`). This matches the official docs verbatim ("arithmetic expressions, function calls, and other non-constant UPDATE statements are not supported").
- **DELETE VARCHAR pushdown failure is correctly identified** and the practical workaround (pair VARCHAR predicate with a pushdownable date/numeric predicate) is exactly the right mitigation. The example uses `summary_date = DATE '2026-05-27'` as the pushdown driver, which is correct.
- **MERGE disabled-by-default behavior is correctly stated**, with the right catalog property name (`merge.non-transactional-merge.enabled=true`) and the right session property name (`non_transactional_merge_enabled` — verified against trino.io docs).
- **Excellent callout on the catalog-vs-session naming asymmetry** (hyphens with `merge.non-transactional-merge.enabled` vs underscores with `non_transactional_merge_enabled`). This is a common foot-gun and worth surfacing.
- **Non-transactional / no-rollback semantics correctly explained** for UPDATE/DELETE/MERGE; the partial-commit scenario ("6,500 of 10,000 rows then fails") is accurate.
- **Idempotency guidance is sound**: the MERGE-by-primary-key example is the canonical safe upsert pattern.
- **Production fit is appropriate**: mention of OPA permissions matches the on-prem stack described in `prod_info.md`. Lakehouse-vs-MySQL latency framing (Iceberg-native writes vs JDBC) is consistent with the stack.
- **"What you should avoid" section is concrete and actionable** for a SaaS engineer who is new to OLAP.

## What was wrong or missing

- **Missing the non-transactional INSERT property name**. The answer says "Fast non-transactional mode available" for INSERT but never names `insert.non-transactional-insert.enabled` (catalog) or `non_transactional_insert` (session). An engineer who wants to opt into the faster path has no string to grep for. This is a small completeness gap.
- **Minor: MySQL `max_execution_time`** is set in milliseconds via `SET GLOBAL max_execution_time = 300000` (5 min). Correct. However, `max_execution_time` only applies to read-only SELECT statements in MySQL; it does NOT bound UPDATE/DELETE/INSERT lock duration. For runaway write lock prevention, the engineer would actually want `innodb_lock_wait_timeout` or `wait_timeout`, not `max_execution_time`. This is a factual error in the production checklist — small but real.
- **No mention of CTAS** (`CREATE TABLE AS SELECT`) as an alternative pattern for the nightly summary use case. Not strictly required by the question, but a relevant adjacent option.

## Verification notes

Verified against https://trino.io/docs/current/connector/mysql.html:
- INSERT supported; non-transactional toggle via catalog `insert.non-transactional-insert.enabled` / session `non_transactional_insert`.
- UPDATE limited to constant assignments and predicates; no arithmetic / function-call assignments; all-columns-at-once not supported.
- DELETE requires WHERE predicate to fully push down; the connector "does not support pushdown of any predicates on columns with textual types like CHAR or VARCHAR", confirming the VARCHAR DELETE failure mode.
- MERGE supported when `merge.non-transactional-merge.enabled=true` (catalog) / `non_transactional_merge_enabled` (session); partial-update risk explicitly called out by Trino docs.

All four naming claims in the answer (catalog property hyphenation, session property `_enabled` suffix for merge, etc.) match the official docs.

## Recommendation for teacher

- **LOW** — Add the non-transactional INSERT property names (`insert.non-transactional-insert.enabled` / `non_transactional_insert`) to the MySQL connector resource alongside the MERGE properties so the symmetry is visible.
- **LOW (correctness)** — Fix the `max_execution_time` claim: clarify it bounds SELECT only, and recommend `innodb_lock_wait_timeout` (or session `SET SESSION wait_timeout`) for write-lock bounding on the MySQL side.
- **LOW** — Consider adding a brief CTAS-as-alternative note for the "write nightly summary back to MySQL" pattern, since some engineers will reach for CTAS first.

The answer is otherwise an exemplar of how to address this question: correct, gotcha-aware, production-grounded, and beginner-readable. Topic running average for Trino federation should tick up with this pass.
