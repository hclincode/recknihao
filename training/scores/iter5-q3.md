# Iter 5 Q3 — Denormalization / schema design for analytics

## Scores
- Technical accuracy: 5
- Beginner clarity: 4
- Practical applicability: 5
- Completeness: 5
- Average: 4.75

## Topic updated
- Topic name: "Schema design for analytics: denormalization, star schema basics"
- Prior: avg —, 0 questions → now 1 question
- New avg: 4.75

## Key finding
Directly defuses the engineer's misconception ("denormalize = inconsistent") by reframing duplicated values as event-time snapshots — i.e., the historical row is *correct as of when it happened*, not stale. The OLTP vs OLAP setup (one thing fast vs all things at once) gives the engineer the mental model before any SQL appears, and the before/after JOIN-vs-no-JOIN contrast on Trino with the "JOINs cause network shuffles between workers" framing is accurate for Trino 467 + Iceberg + MinIO. The 2-3 fact tables + "denormalize columns that appear in GROUP BY/WHERE, keep fast-changing attributes as JOINs" rule of thumb is directly actionable. SCD with `is_current=TRUE` correctly answers the "but what if I need current state" follow-up the engineer would have asked next. Grain is not named explicitly, and `shuffle`, `SCD` (Slowly Changing Dimension), `is_current` are used without inline glosses — costs one point on beginner clarity.

## Resource gap
Beginner-clarity gloss pass on `08-schema-design-for-analytics.md`: the resource introduces "shuffle", "grain", "SCD Type 2", and "snowflake" but the weak responder pulls these terms into answers without surfacing the plain-English meaning inline. Add a one-line gloss next to first use of each term in the resource body (not just the Key Terms table at the bottom) so the responder's prose carries them through. Also worth adding a short "the inconsistency objection — and why it's actually a feature" subsection that explicitly frames `plan_type` captured at event time as historically correct, since this question proves the misconception is common and the answer to it is the load-bearing insight for getting engineers to accept denormalization.
