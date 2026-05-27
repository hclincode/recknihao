# Iter 163 Q1 — Judge Report

**Question**: User ran ANALYZE weeks ago, recently re-ran column-targeted ANALYZE on new filter columns, queries still slow. Wants to know (a) how to see what stats Trino has, (b) how to verify CBO is using them.

**Answer file**: /Users/hclin/github/recknihao/training/answers/iter163-q1.md

---

## Technical accuracy: 5

WebSearch verification against official trino.io docs:

1. **`SHOW STATS FOR <table>`** — Confirmed correct. trino.io/docs/current/sql/show-stats.html lists `distinct_values_count`, `nulls_fraction`, `row_count`, `low_value`, `high_value`, and `data_size` as the standard columns. NULL means stat not collected/unavailable. Answer is exactly right.

2. **`ALTER TABLE ... EXECUTE drop_extended_stats`** — Confirmed correct for Iceberg connector. trino.io/docs/current/connector/iceberg.html explicitly documents this: "If statistics were previously collected for all columns, they must be dropped using the drop_extended_stats command before re-analyzing." The answer's identification of this as the user's exact bug is spot on — this is the documented gotcha, not a guess.

3. **`ANALYZE iceberg.analytics.events WITH (columns = ARRAY[...])`** — Correct syntax. Trino's ANALYZE statement does NOT use the `TABLE` keyword (unlike Postgres/MySQL). Iceberg docs show this exact pattern.

4. **`EXPLAIN (TYPE LOGICAL)`** — Valid command. Shows `Estimates: {rows: ..., cpu: ..., memory: ..., network: ...}` format. NOTE: Trino docs flag that `TYPE LOGICAL` is being deprecated in favor of `TYPE DISTRIBUTED`, but it still works in Trino 467 (production version). Both show estimates. Minor: answer could have mentioned DISTRIBUTED as an alternative, but TYPE LOGICAL is still correct and arguably more readable for the user's purpose. Not a deduction.

5. **"ANALYZE only helps with join ordering, not table scans"** — Mostly correct but slightly oversimplified. ANALYZE-collected stats primarily drive join reordering and build/probe side selection. They also feed cardinality estimates for filter selectivity which can affect plan choices (broadcast vs partitioned joins, aggregation strategy). The answer's framing — that ANALYZE won't make a raw single-table filtered scan faster on its own, and that partition design / file layout matter more for scan speed — is the practically correct framing for this user's symptom. The follow-up advice (look at partition pruning and data layout for scan-heavy queries) is exactly right.

6. **"Trino keeps the old per-column Puffin entries around"** — Correct. Iceberg stats are stored in Puffin files; full-table ANALYZE writes a Puffin blob, and subsequent column-targeted ANALYZE without dropping prior stats can leave stale entries. This is the documented behavior.

No factual errors found. Technical accuracy = 5.

## Beginner clarity: 5

- Explains `distinct_values_count` parenthetically as "NDV (number of distinct values)".
- Defines "build" and "probe" sides in a join inline ("hashed in memory" vs "streamed") — crucial for a SaaS engineer who has never read a Trino plan.
- Calls out the "footgun" plainly and tells the user this is exactly what's happening to them.
- "Estimates: {rows: ?}" interpretation is concrete — user knows what to look for.
- No unexplained jargon (Puffin is mentioned but in context that doesn't require understanding it).

Clarity = 5.

## Practical applicability: 5

- Two-step copy-paste recipe (drop_extended_stats then ANALYZE) directly resolves the user's bug.
- Tells the user exactly what to look for in SHOW STATS output (NULL = bad).
- Tells the user exactly what to look for in EXPLAIN output (rows: ? = bad, round numbers like 1000 = bad).
- Diagnostic loop is complete: "run SHOW STATS → if NULL, drop + re-analyze → verify with EXPLAIN".
- Fits production stack (Trino 467 + Iceberg connector + Hive Metastore on-prem). No cloud-only or unsupported features referenced.
- Anticipates the next question ("queries still slow even with good stats") and redirects to partition strategy.

Practical = 5.

## Completeness: 5

The question has three parts:
1. Are new stats taking effect, or are old stats being used? → Answered: most likely old stats are sticking because of the drop_extended_stats issue.
2. How to check what stats Trino has? → Answered: SHOW STATS, with column interpretation.
3. How to verify CBO is using them in the plan? → Answered: EXPLAIN (TYPE LOGICAL) with two specific things to look for (row estimates, join order/build-probe side).

Bonus: explains why ANALYZE may not fix scan-bound queries and points at partition design as the next investigation. This is exactly the kind of nuance the user needs.

Completeness = 5.

---

## Weighted score

(Technical×2 + Clarity + Practical + Completeness) / 5
= (5×2 + 5 + 5 + 5) / 5
= 25 / 5
= **5.0**

**Pass**: YES (threshold for this topic is 4.5; raised threshold met).

---

## Key findings

- This is a textbook-quality answer. The teacher's iter163 resource fixes (making drop_extended_stats prominent in section 4.5, adding it to TL;DR and troubleshooting checklist) clearly landed — the responder identified the user's exact bug from the question's narrative and gave the documented two-step fix.
- SHOW STATS column interpretation, EXPLAIN row-estimate interpretation, and build/probe side terminology are all explained at the right level for a SaaS engineer with no OLAP background.
- The "ANALYZE doesn't speed up table scans" caveat is correctly framed and redirects the user to partition design for scan-bound symptoms — preventing a follow-up cycle.
- Minor opportunity (NOT a deduction): could mention that `TYPE LOGICAL` is being phased out in favor of `TYPE DISTRIBUTED` in newer Trino versions, but Trino 467 still supports it.

## Topic update

- *Trino CBO / ANALYZE TABLE / Puffin statistics / NDV / join ordering*: previously 1 question at avg 4.400 (NEEDS WORK, threshold 4.5). This is question #2 at 5.0. New average = (4.400 + 5.0) / 2 = **4.700**. Threshold met (≥4.5) AND tested from 2 angles. Status moves to **PASSED**.
