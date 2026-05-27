# Iter 302 Q1 Judge Score

## Topic
Schema design for analytics: denormalization, star schema basics

## Scores
| Dimension | Score |
|---|---|
| Technical accuracy | 5 |
| Beginner clarity | 5 |
| Practical applicability | 5 |
| Completeness | 5 |
| **Average** | 5.00 |

## Pass/Fail
PASS (threshold: 3.5)

## Technical accuracy verification

1. **Parquet dictionary encoding for low-cardinality columns** — VERIFIED CORRECT. Dictionary encoding builds a dictionary of distinct values and replaces them with indices, which are then RLE/bit-packed. For a column like `plan_tier` (3 distinct values across 100M rows), the compressed footprint is essentially the dictionary plus a bit-packed index — orders of magnitude smaller than naive storage. The answer's claim that "storing the same value 100 million times costs barely more than storing it once" is a fair, accessible simplification.

2. **SCD Type 2 with valid_from/valid_to and as-of join** — VERIFIED CORRECT. The pattern `c.valid_from <= e.occurred_at AND (c.valid_to IS NULL OR e.occurred_at < c.valid_to)` matches the canonical SCD2 as-of join. Including `is_current BOOLEAN` is a common optimization for "current state" queries. NULL `valid_to` to denote "currently active" is standard practice.

3. **PySpark broadcast join syntax** — VERIFIED CORRECT. `from pyspark.sql.functions import broadcast` and wrapping the smaller DataFrame as `broadcast(accounts_df)` is the standard idiom. Spark sends the broadcast side to every executor and avoids shuffling the large side. The example uses it correctly to enrich events at ingest.

4. **"No backfill when plans change" design** — VERIFIED CORRECT. This is the entire point of denormalizing slowly-changing attributes onto an immutable fact stream: the event records the state as it was when the event occurred. This is exactly right for funnel/conversion/cohort analytics. The framing of "historical vs current state" is precisely the distinction the engineer needed to internalize.

5. **Iceberg ADD COLUMN as metadata-only** — VERIFIED CORRECT. Confirmed in Trino and Iceberg docs: ADD COLUMN does not rewrite data files. Existing rows return NULL for the new column.

6. **Federated join concerns** — Plausibly correct. JDBC connection overhead, opaque Postgres statistics breaking the CBO, and repeated logic across dashboards are all legitimate, well-documented issues with Trino federated joins against operational Postgres. Fits the production stack (on-prem Trino 467 + Iceberg).

7. **Stack fit (prod_info.md)** — Excellent. Uses Spark for ingest, Iceberg as the target, Trino for queries. `WITH (partitioning = ARRAY['day(occurred_at)', 'tenant_id'])` is correct Iceberg/Trino partitioning syntax. Multi-tenancy hint via `tenant_id` partition is appropriate. No cloud-only services recommended.

## What worked
- Direct, well-organized lead with the "short answer" up front addressing both parts of the question (good idea? + backfill concern).
- The "historical vs current state" framing is the single most important conceptual insight for this question and the answer nails it with a concrete example (May 1–14 vs May 15+).
- Crisp "do denormalize vs don't denormalize" rules with reasoning (low-cardinality + stable + appears in GROUP BY/WHERE).
- Concrete SQL/PySpark/DDL examples make this immediately actionable.
- Correctly distinguishes the two query patterns: "what plan were they on when X happened?" (denormalized column) vs "what plan are they on now?" (join to dim).
- Notes the gotcha that adding a new denormalized column to existing tables needs a one-time backfill or NULL filters will silently exclude history — this is the kind of practical landmine that earns its keep.
- The Parquet dictionary encoding explanation is accessible without being misleading.

## What was wrong or missing
- Very minor: the as-of join example assumes Trino can broadcast the dim table. For a customer_dim with millions of rows that has SCD2 history (multiple rows per user), this can be larger than expected. The answer says "small dimension table" which is fine but worth flagging that SCD2 inflates dim row count.
- The DDL example includes `tenant_id` in the partitioning array but `tenant_id` is not listed as a column in the CREATE TABLE — a careful reader might notice this is implied. Cosmetic only.
- Could have mentioned that `signup_date` (vs the stable `signup_month`) is a date that doesn't change either — minor since the answer recommends `signup_month` as the cohort dimension.

These are nits, not deductions. The answer is comprehensive and accurate.

## Suggested topic score update
Old: 4.50 / 4 questions
New avg if this scores 5.00: (4.50×4 + 5.00) / 5 = 22.00 / 5 = **4.60 / 5 questions**
