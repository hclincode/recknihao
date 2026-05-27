# Iter 295 Q1 — Score

**Question**: SCD Type 2 for plan_name on Iceberg + dbt — how to track a mutating column over time so "who was on Pro last quarter?" becomes answerable.

## Score table

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4 | Core SCD Type 2 concept, valid_from/valid_to/is_current row structure, date-range query semantics, and dbt snapshot mechanics are all correct. Two minor errors: (1) dbt does NOT emit a `dbt_is_current` column by default — the standard dbt metadata is `dbt_valid_from`, `dbt_valid_to`, and `dbt_is_deleted`; "current" is identified by `dbt_valid_to IS NULL`. The answer asserts dbt "automatically adds `dbt_valid_from`, `dbt_valid_to`, and `dbt_is_current`" which is factually wrong about the third column. (2) The snippet `{% snapshot users_snapshot %}` is missing the required `{{ config(target_schema=..., strategy='check' or 'timestamp', unique_key=..., check_cols=[...] or updated_at=...) }}` block — as written it would not run. |
| Beginner clarity | 5 | Excellent. Opens with a one-paragraph short answer, contrasts current overwrite behavior vs SCD2 layout using a concrete `u_123` example, explains why nightly sync breaks analytics in plain OLTP-vs-OLAP terms, and gives a Type 1 vs Type 2 decision table tied to real SaaS columns (email, plan tier, country, sales rep). Jargon (SCD, dimension, OLAP) is introduced and immediately glossed. |
| Practical applicability | 4 | Engineer gets a usable `users_dim` DDL sketch, three runnable Trino-style SQL queries (point-in-time, last-quarter count, current-only), a description of the nightly maintenance logic, and a dbt snapshot pattern that fits the production stack. Docked one point because: (a) the dbt snapshot example is incomplete and won't run without the `config()` block, (b) no mention of the dbt-trino Iceberg-specific TIMESTAMP precision caveat that dbt-trino docs call out for snapshots on Iceberg, (c) no Spark `MERGE INTO` SQL example for engineers who would rather hand-roll the SCD2 sync inside their existing Spark ingestion job instead of bolting on dbt. The "easiest way" framing is fine but should still show one Spark alternative since Spark is the official ingestion stack per prod_info. |
| Completeness | 5 | Covers: SCD definition, why overwrite breaks history, Type 1 vs Type 2 distinction, table layout, point-in-time query, time-range overlap query for "during a quarter", current-only query, sync algorithm, dbt snapshot automation, and a decision rule table. The last-quarter overlap predicate is correctly written as `valid_from < quarter_end AND (valid_to IS NULL OR valid_to >= quarter_start)`. Addresses the engineer's exact question end-to-end. |

**Average: (4 + 5 + 4 + 5) / 4 = 4.50 — PASS**

## Verification notes

- Verified at docs.getdbt.com/docs/build/snapshots and docs.getdbt.com/reference/resource-configs/dbt_valid_to_current that dbt snapshots emit `dbt_valid_from`, `dbt_valid_to`, and (since dbt 1.9) `dbt_is_deleted`. The "current" record is the one where `dbt_valid_to IS NULL` (or equals `dbt_valid_to_current` if configured). There is no `dbt_is_current` column. The answer's claim of `dbt_is_current` is wrong.
- Verified dbt-trino adapter supports snapshot materialization on Iceberg via MERGE (Trino added MERGE in v393; production runs 467, so MERGE is available on the Iceberg connector). dbt-trino docs note a TIMESTAMP precision caveat for Iceberg snapshots that the answer omits.
- SCD Type 2 row structure (valid_from / valid_to / is_current) and the close-old-row + insert-new-row maintenance logic match standard Kimball-style modeling and dbt's implementation.
- Overlap predicate (`valid_from < quarter_end AND (valid_to IS NULL OR valid_to >= quarter_start)`) is the correct half-open interval test for "active during quarter".
- Type 1 vs Type 2 column classification table aligns with Kimball guidance.

## Topic mapping

Primary: **Schema design for analytics: denormalization, star schema basics** (SCD2 dimension table design is core to dimensional modeling).

Secondary: **Lakehouse schema design: fact tables, dimension tables, denormalization** (users_dim as a slowly-changing dimension).

Tertiary: **Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling** (the question is explicitly about the nightly Postgres → Iceberg sync overwriting history; dbt snapshot is one of the named patterns for handling mutable source tables).

## Verdict

**PASS (avg 4.50).** Pedagogically strong, structurally complete, and directly answers the engineer's question with runnable SQL for the production Trino+Iceberg+dbt stack. The two factual errors (invented `dbt_is_current` column; incomplete `{% snapshot %}` block without `config()`) should be fixed in `resources/` before this exact code is copy-pasted into a real dbt project — they will cause a runtime failure or schema mismatch. Recommend teacher fix in the relevant schema-design / dbt resource: correct the dbt metadata column list and show a complete `{% snapshot %} ... {{ config(strategy='check', unique_key='user_id', check_cols=['plan_name','country']) }} ... {% endsnapshot %}` template. Also worth adding a Spark `MERGE INTO` alternative since Spark is the production ingestion engine per prod_info.md.
