# Iter294 Q2 Score — Fact tables vs dimension tables for wide events table

## Score table

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | Correctly distinguishes fact (one row per event, immutable, append-only) vs dimension (one row per entity, lookup, slow change). Denormalization rationale is correct: columnar storage on Iceberg + Parquet dictionary compression makes low-cardinality denormalized columns nearly free, and JOIN avoidance reduces network shuffles in Trino. SCD Type 2 layout (valid_from / valid_to / is_current) is textbook correct. ALTER TABLE ADD COLUMN being metadata-only on Iceberg is verified against iceberg.apache.org docs. MAP<VARCHAR,VARCHAR> for properties is valid Trino/Iceberg syntax. Partitioning by `day(occurred_at), tenant_id` is reasonable for a B2B SaaS event table. Point-in-time "what plan were they on when X happened" framing is accurate dimensional-modeling guidance. |
| Beginner clarity | 5 | Defines fact vs dimension in one-sentence operational terms ("thing that happened" vs "entity"). Walks through the *why* with a concrete plan-change scenario before showing schema. Glosses denormalization explicitly as the opposite of Postgres normalization (the engineer's mental model). Inline comments in SQL ("copied from users_dim", "Type 2: SCD") explain each column's role. Rule of thumb (3+ dashboards = promote) is concrete and memorable. No unexplained jargon. |
| Practical applicability | 5 | Directly tailored to engineer's stack: names Iceberg + Trino + MinIO, partitioning syntax matches Iceberg connector, references Iceberg's metadata-only schema evolution. Decision rule (10–20 hot columns to top level, rest in MAP, JOIN dim for rarely-queried attrs) is immediately actionable. Concrete column lists (always-copy: plan_type/country/is_paying/cohort/tier; never-copy: email/display_name) translate directly to a real schema decision. Before/after query example shows the speedup mechanism. Hundreds-of-columns advice gives a workable triage process. |
| Completeness | 5 | Covers: the rule (fact = events, dim = entities), why split, denormalization with explicit promotion criteria, full fact + dim DDL for users/features/accounts, MAP for long tail, SCD Type 2 history handling, point-in-time vs current-state trade-off, how queries change, and a triage strategy for the 300-column problem. Tenant_id partitioning fits B2B SaaS context. Nothing material is missing for the question asked. |

## Verification notes
- Iceberg `ALTER TABLE ADD COLUMN` is metadata-only with NULL for existing rows — confirmed at iceberg.apache.org/docs/latest/evolution/ ("Added columns never read existing values from another column", schema changes are independent and free of side-effects).
- Star schema denormalization rationale (reduce JOIN cost, columnar friendliness) is consistent with industry guidance for Iceberg+Trino lakehouses.
- Trino `MAP<VARCHAR, VARCHAR>` and `PARTITIONED BY (day(occurred_at), tenant_id)` are valid Iceberg connector syntax.
- Production-stack fit (Trino 467 + Iceberg + MinIO + dbt + Spark): no conflicting recommendations — partitioning, schema evolution, and SCD Type 2 via Spark MERGE / dbt snapshots all align with the on-prem stack.

## Topic mapping
- **Lakehouse schema design: fact tables, dimension tables, denormalization** — covered directly (4th angle). This rubric topic is already PASSED at 4.583 across 3 questions; this answer would lift the running avg.
- **Schema design for analytics: denormalization, star schema basics** — covered (denormalization criteria, columnar/Parquet dictionary rationale, copy-vs-JOIN rule).
- Touches: SCD Type 2 patterns, Iceberg schema evolution (ADD COLUMN metadata-only), partitioning strategy for event tables.

## Verdict
Average: (5 + 5 + 5 + 5) / 4 = **5.00** — **PASS**

This is an exemplary answer. It nails the conceptual rule, gives a concrete schema with annotated columns, articulates the denormalization trade-off with a clear promotion heuristic, and addresses the engineer's specific "300 columns" pain with a triage process. The SCD Type 2 callout pre-empts the natural follow-up question about user plan changes. Production stack is implicitly respected throughout.
