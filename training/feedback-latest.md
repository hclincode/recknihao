# Feedback — Iter 294 (Extended phase)

Date: 2026-05-27
Topics: Schema design for analytics — normalize/denormalize/star schema + fact vs dimension table rules

## Results summary

| Question | Topic angle | Score | Pass/Fail |
|---|---|---|---|
| Q1 | Normalize vs denormalize; star schema intro; OLTP-vs-OLAP mindset for Postgres engineers | **4.50** | PASS |
| Q2 | Fact vs dimension table rules; 300-column events table; denormalization promotion heuristic | **5.00** | PASS |

**Iter 294 average: 4.75 — PASS** ✓

**Topic updates**:
- Schema design for analytics: denormalization, star schema basics: 4.50/2 → **4.50/3 questions** (PASSED — stable)
- Lakehouse schema design: fact tables, dimension tables, denormalization: 4.583/3 → **4.688/4 questions** (PASSED — strengthened)
- OLTP-to-OLAP mindset: 4.50/2 → **4.50/3 questions** (PASSED — stable, Q1 tertiary mapping)

---

## What worked

### Q1 — Normalize vs denormalize (4.50)
1. OLTP-to-OLAP framing — "storage is cheap, JOINs are expensive" contrast with Postgres mindset — excellent clarity for the audience
2. Star schema definition with ASCII diagram — concrete and memorable
3. Before/after SQL showing denormalization eliminating the JOIN — visceral demonstration
4. "Plan they were on when they did X" framing of point-in-time semantics — makes the trade-off intuitive
5. Iceberg schema evolution safety net (ALTER TABLE ADD COLUMN metadata-only) — addresses the "what if I get it wrong" concern
6. "What NOT to do" failure-mode list — practical warning

### Q2 — Fact vs dimension tables (5.00)
1. One-sentence definitions: "thing that happened" vs "entity" — immediately usable mental model
2. Concrete promotion rule: 3+ dashboards → promote to top-level column — memorable heuristic
3. Never-copy vs always-copy column lists — directly applicable to their schema decision
4. MAP<VARCHAR,VARCHAR> for 300-column long tail — handles the specific pain point asked about
5. SCD Type 2 (valid_from/valid_to/is_current) — pre-empts the natural follow-up question on plan changes
6. Before/after query showing speed improvement — shows the payoff mechanism

---

## Resource fix applied (iter 294)

**Bug**: Q1 answer included `PARTITIONED BY (day(occurred_at), user_id)` — identity partitioning on a high-cardinality column (user_id) is an Iceberg anti-pattern that creates millions of tiny partitions and degrades performance.

**Fix applied** to `resources/08-schema-design-for-analytics.md`:
- Added bullet to "Iceberg specifics" section: identity-partition anti-pattern, correct alternative is `bucket(user_id, 16)` (Trino syntax), note that `tenant_id` is safe because B2B SaaS tenant cardinality is low
- Added dbt mention to "What NOT to do" section: dbt is the correct tool for maintaining denormalized fact tables in this stack

---

## Suggested iter295 angles

1. **SQL OLAP best practices** — `TABLESAMPLE BERNOULLI` for cheap exploration without hitting full scan; could reinforce approximate functions with a new angle
2. **Schema design continued** — SCD Type 2 deep dive (the Q2 answer mentioned it; engineer may follow up); or incremental materialization strategy with dbt
3. **Multi-tenant analytics** (4.456/106 questions) — large question count but still room for harder angles (row-level security, tenant-specific aggregations, cross-tenant metrics)
4. **Iceberg partition design** (4.589/15 questions) — reinforce bucket() vs identity vs truncate decision tree
