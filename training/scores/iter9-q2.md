# Iter 9 Q2 — Denormalization misconception: why a data warehouse deliberately "fails" database course rules

## Question summary

Engineer asks why moving from Postgres to a data warehouse requires denormalization, whether that just means duplicating data and inviting inconsistencies, and what a data warehouse does fundamentally differently that makes this the correct design.

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | All claims accurate: Trino distributes JOINs over the network (shuffle), Iceberg fact tables are append-only, plan_type embedded at write time is a historical fact not a mutable field, Parquet is columnar so unselected columns are skipped, Iceberg partitioning enables file skipping. Production stack (MinIO + Iceberg + Trino) named correctly throughout. No factual errors. |
| Beginner clarity | 4 | The core conceptual move ("immutable row, not stale data") is explained in plain English and is excellent. The before/after framing ("Fetch user 12345 vs COUNT signups by plan by country") is effective. Deductions: OLTP/OLAP introduced as labels without plain-English definitions of what "transaction processing" vs "analytical processing" means; "Parquet is columnar" used without explaining what columnar means or why other columns are ignored; "network shuffles between workers" unexplained; "Iceberg partitioning" mentioned without a gloss. A true zero-background reader would lose the thread at these points. |
| Practical applicability | 5 | Directly actionable: concrete `user_events` schema with column list, runnable SQL with no JOIN, explicit rule ("denormalize columns that appear in WHERE and GROUP BY"), 3 starter fact tables named. Stack-specific: "On your MinIO + Iceberg setup, storage is cheap." Engineer knows exactly what to build. |
| Completeness | 4 | Denormalization misconception is handled thoroughly and is the best part of the answer. However, the question closes with "What does a data warehouse actually do differently?" — a question that the resource (02-data-warehouse.md) answers with multi-source integration (Stripe + Mixpanel + Postgres → one SQL query), single source of truth, and "when do you need one" signals. None of these appear. The answer collapses the entire warehouse concept into OLAP-vs-OLTP / append-only semantics, which is correct but incomplete for the topic "What a data warehouse is and when a SaaS product needs one." |

**Average: 4.5**

## Topic updated

**Topic:** What a data warehouse is and when a SaaS product needs one

| | Value |
|---|---|
| Prior avg | 5.0 |
| Prior question count | 1 |
| This answer score | 4.5 |
| New running avg | (5.0 + 4.5) / 2 = **4.75** |
| New question count | 2 |
| Status | **PASSED** (avg 4.75 >= 3.5 threshold, 2 questions from different angles) |

## Key finding

The answer excels at defusing the "denormalization = inconsistency" misconception by grounding the reframe in append-only semantics and the "historical fact" framing, and it correctly names and applies the production stack throughout. The gap is that the question invited a full "what does a warehouse do differently" answer, but the response reduced the warehouse concept entirely to OLAP-vs-OLTP and append-only behavior, skipping the multi-source integration and single-source-of-truth value propositions that are the primary content of the resource.

## Resource gap

`resources/02-data-warehouse.md` — the multi-source integration angle (Stripe + Mixpanel + Postgres all queryable in one SQL statement) is the resource's central value proposition but did not surface in the answer. Add a callout in the resource flagging that when an engineer asks "what does a warehouse do differently," the answer has two parts: (1) query performance / OLAP design (covered well), and (2) multi-source consolidation (not surfaced). This will ensure the responder pulls both angles when the question invites them.
