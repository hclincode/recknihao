# Score: Iter 345 Q1 — Postgres-to-Iceberg ingestion (Debezium schema-change handling)

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | All major claims verified: (1) Debezium uses WAL RELATION messages and `schema.refresh.mode=columns_diff` default to auto-detect schema changes — confirmed against debezium.io docs. (2) Iceberg ADD COLUMN is field-ID-based, metadata-only, existing rows return NULL — confirmed against iceberg.apache.org evolution docs. (3) Postgres ADD COLUMN NOT NULL without default is rejected on populated tables — confirmed (PG cannot determine values for existing rows). (4) Spark MERGE INTO against a target missing the source column raises AnalysisException — consistent with documented Spark/Iceberg behavior (schema mismatch when source has extra columns). (5) The "do NOT restart Debezium" callout is correct — the connector has already adopted the new schema via WAL. Subtle but accurate framing: "your pipeline won't crash on the Postgres side, but the consumer will error" — this distinction is exactly right. |
| Beginner clarity | 5.0 | Opens with a direct, plain-English summary ("pipeline will not crash... but the target needs a manual update"). Each step labeled, no unexplained jargon. WAL, RELATION, MERGE INTO, AnalysisException all introduced in context. Concrete kubectl/SQL commands grounded the explanation. Total downtime estimate ("under 60 seconds") and the analogy of "wake up to an alert, not silent failure" give a beginner a clear mental model of the failure mode. |
| Practical applicability | 5.0 | Concrete runbook with exact commands (kubectl scale, ALTER TABLE syntax), production-relevant warnings (don't restart Debezium, watch for offset loss), and clear automation recommendation (detect AnalysisException → PagerDuty). Fits the on-prem k8s + Spark + Iceberg + Hive Metastore stack described in prod_info.md. Engineer knows exactly what to do tonight: pause consumer → ALTER Iceberg → resume. |
| Completeness | 5.0 | Covers: what triggers the schema change in Postgres, how Debezium detects it, what flows into Kafka, the exact consumer failure mode, the runbook to recover, the do-NOT-restart-Debezium warning, the NOT-NULL-without-default edge case, the correct nullable-then-backfill pattern, and the automation guidance. Nothing material missing for the question asked. |
| **Average** | **5.00** | **STRONG PASS (PERFECT)** |

## What Worked

- **Step-by-step causal chain** (Postgres → WAL → Debezium → Kafka → Spark consumer → AnalysisException) gave the engineer the full mental model, not just "what to do."
- **Named the exact error** (`AnalysisException`) so the on-call can grep logs immediately.
- **Pinpointed the asymmetry**: Debezium handles schema changes automatically; Iceberg ALTER is manual. This is the single most important takeaway and the answer led with it.
- **Do-NOT-restart-Debezium callout** addresses a common instinct that would cause secondary problems (offset loss, re-snapshot).
- **NOT NULL edge case** is non-obvious nuance — answer correctly notes the ALTER never commits, so Debezium sees nothing, so there is nothing to recover. Engineer doesn't waste time investigating a phantom failure.
- **Runbook is concrete**: kubectl commands, exact SQL syntax, time estimate. Production-ready, not abstract.
- **Cited resources/13 sections 4-6** — traceable back to source material.

## What Missed

Nothing substantive at this score level. Very minor possible additions (not required, not deducted):
- Could mention Iceberg-Kafka-Connect Sink (commonly used in production CDC stacks) as an alternative architecture where schema evolution can be auto-applied via `iceberg.tables.evolve-schema-enabled`. Not required for the question as asked, which assumed a Spark MERGE consumer.
- Could mention DROP COLUMN and TYPE WIDENING as related cases the engineer will encounter next. The answer scoped tightly to ADD COLUMN as asked — appropriate.
- The 7-day Kafka retention default is sensible but is configurable; a one-liner "check your topic's `retention.ms`" would be ideal. Not deducted because the headroom point still lands.

## Technical Accuracy Verification

WebSearch-verified against official sources:

1. **Debezium `schema.refresh.mode=columns_diff` default** — Confirmed via debezium.io/documentation/reference/stable/connectors/postgresql.html. `columns_diff` is the default and safest mode; in-memory schema stays in sync with the database schema as WAL messages arrive.

2. **WAL RELATION messages** — Confirmed. The Postgres logical decoding plugin (pgoutput) emits RELATION messages describing table structure; Debezium uses these to refresh its in-memory schema representation when discrepancies are detected.

3. **Iceberg ADD COLUMN field-ID, metadata-only, NULL for existing rows** — Confirmed via iceberg.apache.org/docs/latest/evolution/. "Iceberg uses unique IDs to track each column in a table. When you add a column, it is assigned a new ID so existing data is never used by mistake." "Iceberg didn't rewrite any files—it just updated the metadata. When reading old Parquet files that don't have this column, Iceberg automatically fills in NULL."

4. **Postgres NOT NULL ADD COLUMN without default rejected on populated tables** — Confirmed. PG cannot determine values for existing rows; the ALTER is rejected. (PG 11+ allows ADD COLUMN with a constant DEFAULT to be instant — answer's "add as nullable → backfill → add constraint" is the canonical safe pattern.)

5. **Spark MERGE INTO AnalysisException on unknown source column** — Consistent with documented Spark/Delta/Iceberg schema-mismatch behavior. Source schema with an extra column that doesn't exist in the target raises AnalysisException at analysis time unless `mergeSchema`/`write.spark.accept-any-schema` is enabled (which the answer correctly does not recommend as a quiet auto-evolve, since the pause-ALTER-resume pattern keeps schema changes explicit and controlled).

6. **Production-fit (prod_info.md)** — On-prem k8s, Spark 1.5.2 + Iceberg, Hive Metastore. The kubectl scale + Trino/Spark ALTER TABLE pattern fits this stack exactly. No incompatible recommendations (no cloud-managed services, no AWS Glue, etc.).

All five required verifications passed. Answer is technically airtight.
