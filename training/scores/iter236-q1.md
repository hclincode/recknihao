# Score: iter236-q1 — PostgreSQL Write-Back with MERGE

**Score: 4.85 / 5.0**

## What was correct

- **MERGE not supported in Trino 467**: Verified. MERGE for the PostgreSQL connector was added in Release 470 (5 Feb 2025). Production stack is on 467, so the answer correctly states it is unsupported.
- **Non-transactional flag introduced in 470**: Verified. `merge.non-transactional-merge.enabled=true` is the correct catalog property and was added in 470. The answer is correct that adding it to a 467 catalog will not work (the connector does not recognize the property in 467).
- **Transactional MERGE in 475+**: Verified against PR #24467 and Release 475 notes — transactional MERGE for PostgreSQL connector arrived in 475 (specifically with retry_policy=TASK and fault-tolerant execution context, then more broadly). Wording is reasonable.
- **UPDATE constant-assignment limitation**: Verified against Trino PostgreSQL connector docs — "Only UPDATE statements with constant assignments and predicates are supported." Arithmetic expressions and function calls in SET are not supported. The answer's example `SET col = col + 100` is correctly flagged as not allowed.
- **Recommendation to upsert in application via `INSERT ... ON CONFLICT ... DO UPDATE`**: Correct, idiomatic PostgreSQL upsert. This is the production-correct pattern: use Trino as the analytical engine and let the OLTP database own the transactional write.
- **Cross-statement non-atomicity warning for INSERT + UPDATE through Trino**: Correct. Each statement commits independently; this is a real risk that the engineer needs to know.
- **OPA permission note**: Appropriate for the production stack (custom OPA authorization on Trino). Phrased generally without inventing specific policies — matches prod_info.md guidance.
- **Staging table + atomic swap recommendation (Option 3)**: Valid pattern; correctly places the atomic swap in PostgreSQL where transactional guarantees exist.
- **Framing**: "Trino is a query engine, not a transaction engine" is accurate and the right mental model for the engineer.

## What was wrong or missing

- **`INSERT ... SELECT WHERE NOT EXISTS` syntax**: The shown form in Option 2 is slightly awkward — `INSERT INTO app_pg.public.billing_snapshots SELECT ... WHERE NOT EXISTS (SELECT 1 FROM billing_snapshots WHERE customer_id = source.customer_id AND date = source.date)` references `source.customer_id` without showing the source CTE/subquery. The pattern is conceptually valid in Trino but the snippet as written would not parse without a source alias. Minor — readers can infer intent, but a cleaner example would help.
- **CTAS to PostgreSQL caveat not mentioned in Option 3**: `CREATE TABLE AS SELECT` through the PostgreSQL connector does work, but the answer could mention that the PostgreSQL connector creates the table with Trino-inferred types which sometimes need tuning. Minor omission.
- **No mention of dbt**: The production stack supports dbt. For nightly billing aggregates, dbt's `incremental` materialization with `unique_key` is a common pattern that some teams use to manage this kind of upsert workflow. Not strictly required but would be a natural reference for a SaaS engineer.
- **`merge.non-transactional-merge.enabled` would be "silently ignored" in 467**: Slight inaccuracy in wording — unknown catalog properties typically cause Trino to fail catalog startup, not silently ignore. Behavior depends on version, but "silently ignored" oversells the safety. Very minor.

## Verification notes

Verified via WebSearch against official Trino documentation and GitHub:
1. **PG MERGE version**: Confirmed via [Release 470 (5 Feb 2025)](https://trino.io/docs/current/release/release-470.html) and [PR #24467](https://github.com/trinodb/trino/pull/24467). 467 does NOT support MERGE on PostgreSQL — answer is correct.
2. **Non-transactional flag**: Confirmed via [PostgreSQL connector docs](https://trino.io/docs/current/connector/postgresql.html): "PostgreSQL connector supports adding, updating, and deleting rows using MERGE statements if the `merge.non-transactional-merge.enabled` catalog property is enabled."
3. **Transactional MERGE in 475**: Confirmed via Release 475 notes — MERGE with retry_policy=TASK added.
4. **UPDATE constant limitation**: Confirmed via PostgreSQL connector docs — only constant assignments and predicates are supported.
5. **INSERT ... WHERE NOT EXISTS**: Confirmed valid Trino SQL pattern; the WHERE NOT EXISTS clause belongs to the SELECT, not the INSERT directly.
6. **OPA note**: Aligns with prod_info.md — general conceptual mention without inventing specific policy rules.

## Recommendation for teacher

Resources are in solid shape on this topic. Minor enhancements to consider:
- Add a clean, copy-pasteable INSERT ... WHERE NOT EXISTS example with a proper source CTE alias so readers don't have to reconstruct it.
- Optionally add a dbt incremental materialization note for upsert-style nightly jobs targeting PostgreSQL (since dbt is supported in production).
- Soften the "silently ignored" claim about unknown catalog properties — actual behavior is usually startup error or warning, not silent ignore.

No critical fixes required. The PostgreSQL MERGE version matrix flagged in iter235 feedback is now correctly reflected in the responder's answer.

Sources:
- [Release 470 (5 Feb 2025) — Trino docs](https://trino.io/docs/current/release/release-470.html)
- [Support transactional MERGE for PostgreSQL connector PR #24467](https://github.com/trinodb/trino/pull/24467)
- [PostgreSQL connector — Trino docs](https://trino.io/docs/current/connector/postgresql.html)
- [Release 475 (23 Apr 2025) — Trino docs](https://trino.io/docs/current/release/release-475.html)
- [Release 468 (17 Dec 2024) — Trino docs](https://trino.io/docs/current/release/release-468.html)
