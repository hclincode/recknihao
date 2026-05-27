# Iter 8 Q2 — SCD Type 2 and plan_type history on Iceberg+Trino

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | SCD Type 2 row structure (valid_from/valid_to/is_current), point-in-time SQL, Iceberg MERGE INTO via Spark, dbt snapshots, and denormalize-at-write-time are all correct. No factual errors. |
| Beginner clarity | 4 | Problem restated in engineer's terms before any solution; table example is concrete and clear. MERGE INTO, dbt snapshots, and "snapshot materialization" land without inline glosses. "Denormalize" used without explanation (persistent gap from Iter 5 Q3). |
| Practical applicability | 4 | Two concrete implementation paths given (Spark MERGE INTO, dbt snapshots), both fit the prod stack. Denormalize-at-write-time is directly actionable. Missing: what to do about existing historical events already loaded with current plan_type (backfill path or accept-the-gap decision not addressed). |
| Completeness | 4 | Answers the literal "do I have to rebuild?" question (no). Forward-going solution (denormalize at ingest) and reference-table SCD Type 2 both covered. Gap: no guidance on remediating already-loaded historical events with stale plan_type — this is the practical follow-on question any engineer will face immediately. |
| **Average** | **4.25** | |

## Topic updated

**Schema design for analytics: denormalization, star schema basics**
- Prior avg: 4.75 (1 question, Iter 5 Q3)
- This question avg: 4.25
- New running avg: (4.75 + 4.25) / 2 = **4.50** across 2 questions
- Status: **PASSED** (avg 4.50 >= 3.5 threshold, 2 question angles covered)

## Key finding

The answer correctly teaches SCD Type 2 and denormalize-at-write-time as complementary patterns and grounds both in the prod stack (Spark MERGE INTO, dbt). The one meaningful gap is the missing backfill / remediation path for already-loaded historical events — an engineer whose events table was built against current plan_type has no guidance on whether to reprocess or accept the gap.

## Resource gap

`resources/08-schema-design-for-analytics.md` should add a short "What about historical data already loaded?" subsection explaining: (a) if all events were loaded before SCD Type 2 was in place, you can either accept the gap (events before migration date reflect current plan) or backfill by joining a plan_change_log to reassign plan_type per event; (b) the simpler forward-going choice is to start denormalizing correctly from the migration date and annotate pre-migration events as plan_type_at_event_time = NULL or 'unknown'. Also: add one-line glosses for "MERGE INTO" (an upsert-style SQL statement that updates matching rows and inserts new ones) and "dbt snapshot" (a dbt feature that automatically manages SCD Type 2 row versioning) at first use — these were not glossed in the answer.
