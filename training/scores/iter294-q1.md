# Score: Iter 294 Q1 — Normalize vs Denormalize Iceberg Tables (Star Schema)

## Score Table

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 4 | Core claims correct: star schema definition, Postgres-vs-lakehouse JOIN cost flip, denormalization rationale, Iceberg ADD COLUMN as metadata-only, "plan at the time of event" point-in-time semantics. However, the final example shows `PARTITIONED BY (day(occurred_at), user_id)` — identity partitioning on a high-cardinality user_id column is a known Iceberg anti-pattern (would create millions of tiny partitions and small-files problems). Should be `bucket(N, user_id)` or simply `day(occurred_at)`. This is a load-bearing bug because the example is the concrete recipe the engineer will copy. |
| Beginner clarity | 5 | Explicitly addresses the Postgres-mindset starting point. Defines fact table and dimension table in one line each. ASCII star-schema diagram. Before/after SQL contrast for denormalization. No unexplained jargon — "shuffle," "cardinalities," "partition pruning" each get one-line context. The "plan they were on when they did X" framing makes point-in-time semantics intuitive. |
| Practical applicability | 4 | Concrete actionable advice: 2-3 fact table recipe table with column lists, the >3-dashboard rule of thumb, the "use Spark ingestion to flatten on the way in" instruction (aligns with the production Spark ingestion stack), and the concrete Postgres-to-Iceberg before/after example. Names Trino + Iceberg + MinIO + Kubernetes stack correctly. Loses a point because (a) the partition spec bug above would mislead an engineer copying the recipe, and (b) no mention that dbt is the appropriate place to build/maintain the denormalized fact tables — the prod stack includes dbt specifically for this transformation work. |
| Completeness | 5 | Covers all four parts of the multi-part question: (1) keep normalized vs flatten, (2) star schema definition, (3) OLTP-vs-OLAP modeling mindset, (4) how to actually structure SaaS tables. Adds value with the "what NOT to do" failure-mode list and the Iceberg schema-evolution safety net that addresses the unspoken "what if I get it wrong" concern. |

**Average: (4 + 5 + 4 + 5) / 4 = 4.50**

## Verification Notes

- **Iceberg ADD COLUMN as metadata-only** (verified via iceberg.apache.org evolution docs): Confirmed. "Iceberg schema updates are metadata changes, so no data files need to be rewritten." Added columns return NULL for existing rows. Answer's claim is accurate.
- **Identity partitioning on user_id**: Verified as a documented anti-pattern. Iceberg docs and AWS prescriptive guidance both recommend `bucket(N, user_id)` for high-cardinality columns. Identity partition on user_id "creates millions of partitions" and degrades performance — this is the bug in the answer's final PARTITIONED BY clause.
- **Star schema fact + dimension terminology**: Standard Kimball-style modeling; correctly described.
- **JOIN cost as network shuffle in distributed Trino**: Accurate — Trino does perform partitioned/broadcast joins with shuffle.
- **Point-in-time captured attribute (plan_type at event time)**: Correct semantics for analytics; aligns with SCD-Type-2-lite denormalization pattern documented elsewhere in the rubric (iter 95-ish answer notes).

## Topic Mapping

This question maps to:
- **Schema design for analytics: denormalization, star schema basics** (currently PASSED, avg 4.50, 2 questions) — primary topic; adds a 3rd angle (Postgres-mindset migration).
- **Lakehouse schema design: fact tables, dimension tables, denormalization** (currently PASSED, avg 4.583, 3 questions) — secondary topic; this question explicitly asked about both star schema and Iceberg-specific schema design.
- **OLTP-to-OLAP mindset: the mental model shift for SaaS engineers adopting a lakehouse** (currently PASSED, avg 4.50, 2 questions) — tertiary; the "Postgres instinct fails" section is exactly this mindset shift.

## Verdict

**PASS** — Average 4.50 is well above the 3.5 threshold. Answer is strong on clarity, completeness, and the OLTP-to-OLAP framing. The one material defect is the `PARTITIONED BY (day(occurred_at), user_id)` line, which propagates a documented Iceberg anti-pattern. Teacher should fix this in the schema-design resource: identity partitioning on user_id should be replaced with `bucket(16, user_id)` or removed entirely, with a brief note on why. Also worth adding a one-liner pointing engineers to dbt for maintaining the denormalized fact tables in this production stack.
