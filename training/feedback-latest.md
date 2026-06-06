# Judge Feedback — Iter 551 (2026-06-06)

## HEADLINE

**iter551 PASS at 4.375 (overall avg of 4 questions).** Three iter551 LEADING CANONICAL gaps (§1a.2A array_agg ORDER BY, §1b WITH/CTE semantics, §3.1G DISTINCT ON) all pre-empted as designed — Q1/Q2/Q3 land at perfect 5.00. **Q4 introduced a NEW fabricated-absence regression: the responder asserted `now()` does NOT exist in Trino. This is FALSE — `now()` IS a documented Trino function and an alias for `current_timestamp` (trino.io/docs/467/functions/datetime.html).** Q4 also got the Iceberg `timestamptz` UTC-storage nuance wrong. iter552 PRIMARY fix: add a `now()` / `current_timestamp` / Iceberg-timestamptz-UTC-normalization LEADING CANONICAL.

---

## Per-question scoring

### Q1. array_agg — control element order + dedupe?

**Answer summary**: `array_agg(event_name ORDER BY occurred_at)` for order; `array_agg(DISTINCT event_name ORDER BY event_name)` to dedupe; ORDER BY must be INSIDE the aggregate; outer ORDER BY orders rows not elements; non-deterministic without it. Cited r07 §1a.2A.

**Doc verification** (trino.io/docs/467/functions/aggregate.html):
> "array_agg(x ORDER BY y DESC)" and "array_agg(x ORDER BY x, y, z)" — under the "Ordering during aggregation" section.

| Dim | Score | Notes |
|---|---|---|
| Accuracy | 5 | Matches Trino docs verbatim. |
| Completeness | 5 | Hits inline ORDER BY, DISTINCT, outer-ORDER-BY trap. |
| Clarity | 5 | Clean, beginner-friendly. |
| Actionability | 5 | Worked SQL the engineer can paste. |

**Q1 avg: 5.00 — iter551 §1a.2A canonical WIN — gap pre-empted.**

---

### Q2. CTE referenced 3 times — computed once / cached or re-executed?

**Answer summary**: "Trino re-executes it every time, no caching; WITH is INLINED anywhere the named relation is used; referenced N times = runs N times; materialize to a real table/dbt model if reused." Quoted the Trino "WITH clause will be inlined" doc line. Cited r07 §1b.

**Doc verification** (trino.io/docs/467/sql/select.html):
> "Currently, the SQL for the WITH clause will be inlined anywhere the named relation is used. This means that if the relation is used more than once and the query is non-deterministic, the results may be different each time."

| Dim | Score | Notes |
|---|---|---|
| Accuracy | 5 | Verbatim doc quote; semantics correct. |
| Completeness | 5 | Inlining + materialize-instead path (dbt model / CTAS). |
| Clarity | 5 | The "runs N times" framing demolishes the materialization myth. |
| Actionability | 5 | Engineer knows to use a dbt model with materialized='table' or CTAS for expensive CTEs hit >= 2x. |

**Q2 avg: 5.00 — iter551 §1b canonical WIN — gap pre-empted.**

---

### Q3. Postgres DISTINCT ON (user_id) ORDER BY ... — Trino equivalent?

**Answer summary**: "Trino does NOT support DISTINCT ON (parse error); use ROW_NUMBER() OVER (PARTITION BY ... ORDER BY ... DESC) in a subquery, outer WHERE rn=1; rn<=N for top-N; max_by for a single column." Cited r23 §3.1G.

**Doc verification** (trino.io/docs/467/sql/select.html):
> "SELECT [ ALL | DISTINCT ] select_expression [, ...]" — `DISTINCT ON` is NOT in the Trino SELECT grammar. QUALIFY also not present.

| Dim | Score | Notes |
|---|---|---|
| Accuracy | 5 | DISTINCT ON parse-error confirmed; ROW_NUMBER()=1 rewrite confirmed; max_by for single-column pick is right. |
| Completeness | 5 | Hits top-N variant + max_by single-column alternative. |
| Clarity | 5 | Side-by-side Postgres-vs-Trino structure. |
| Actionability | 5 | Engineer can do a 1-to-1 rewrite immediately. |

**Q3 avg: 5.00 — iter551 §3.1G canonical WIN — gap pre-empted.**

---

### Q4. now() vs CURRENT_TIMESTAMP in Trino — same? + does Trino auto-store UTC / timezone handling?

**Answer summary**: ***Claimed "Trino has CURRENT_TIMESTAMP but NOT NOW() — NOW() doesn't exist and will raise a function-not-found error."*** Also: CURRENT_TIMESTAMP returns TIMESTAMP WITH TIME ZONE tied to session zone; `AT TIME ZONE` converts; "Trino does NOT auto-convert to UTC on storage — you get exactly what you stored." Cited r27 §4.2B.

**Doc verification (a) — FABRICATED ABSENCE** (trino.io/docs/467/functions/datetime.html):
> "now() → timestamp with time zone — This is an alias for current_timestamp."
> "current_timestamp — Returns the current timestamp with time zone as of the start of the query, with 3 digits of subsecond precision"

`now()` IS a real, documented Trino function. It IS an alias for `current_timestamp`. Both return TIMESTAMP(3) WITH TIME ZONE. The responder's "Trino has NOT NOW(), raises function-not-found error" is a **FABRICATED ABSENCE of a real function**. If the SaaS engineer follows this guidance they will avoid a perfectly valid Trino primitive and write more verbose / less idiomatic SQL; worse, they may "fix" working Trino code that uses `now()` because they trust the responder's confident assertion. This is a real harm category.

**Doc verification (b) — TZ semantics**: CURRENT_TIMESTAMP returning timestamp with time zone tied to the SESSION zone is **CORRECT**. `AT TIME ZONE` for explicit conversion is **CORRECT**.

**Doc verification (c) — UTC-storage claim**: Per the Iceberg spec (iceberg.apache.org/spec) and confirmed by web search:
> "Timestamptzs in Iceberg are stored as UTC and include a date and a time of day with a timezone... values at microsecond precision."

For Iceberg `timestamptz` (timestamp with time zone) columns on this stack, the on-disk storage IS normalized to a UTC instant (microseconds from epoch UTC); the per-value session zone is NOT preserved on disk. The SQL-level value carries a zone at query time, but the storage layer normalizes to UTC. The responder's blanket "you get exactly what you stored, not normalized to UTC" is **WRONG for Iceberg timestamptz** — exactly the connector this prod stack uses (Trino 467 + Iceberg connector). The correct nuance: `timestamp WITHOUT time zone` (Iceberg `timestamp`) is stored as a wall-clock value with no zone normalization; `timestamp WITH time zone` (Iceberg `timestamptz`) IS UTC-normalized on disk per the Iceberg spec.

| Dim | Score | Notes |
|---|---|---|
| Accuracy | 1 | Two factual errors: (a) FABRICATED ABSENCE of `now()` — it's a documented alias; (b) wrong on Iceberg timestamptz UTC normalization. The session-zone + AT TIME ZONE parts are correct, which is why this isn't 0. |
| Completeness | 3 | Covered AT TIME ZONE, session-zone tied semantics; missed `now()` entirely; missed the timestamp-vs-timestamptz storage split. |
| Clarity | 4 | Prose is clear and confident — which makes the error MORE dangerous, not less. |
| Actionability | 2 | Engineer who follows it will avoid a real primitive and will mis-reason about UTC storage on Iceberg timestamptz columns; could cause silent timezone bugs in dashboards. |

**Q4 avg: 2.50 — iter552 PRIMARY FIX.**

---

## Overall

**Per-question averages**: Q1=5.00, Q2=5.00, Q3=5.00, Q4=2.50
**Iter551 overall average**: (5.00 + 5.00 + 5.00 + 2.50) / 4 = **4.375 — PASS**

Pass is comfortable on the math but the Q4 fab-absence is a category-1 finding (responder confidently asserts a real function does not exist). The three Q1/Q2/Q3 wins prove the LEADING CANONICAL strategy works; the same strategy is needed for `now()`/`current_timestamp`/Iceberg-timestamptz-UTC.

---

## iter552 PRIMARY FIX (teacher must address)

Add a LEADING CANONICAL H3 in the date/time family location (grep first for where `date_trunc`, `from_unixtime`, and the existing time-function canonicals live — likely r07 date/time area or r27 §4.2B area) covering ALL of:

1. **`now()` IS a Trino function — alias for `current_timestamp`.**
   - Doc quote (verbatim): "now() → timestamp with time zone — This is an alias for current_timestamp."
   - Both return TIMESTAMP(3) WITH TIME ZONE tied to the session zone.
   - DO-NOT-WRITE: "Trino has no now()" / "now() raises function-not-found" — FALSE; it is documented.

2. **Keyword-anchor blockquote**: now() Trino, NOW() vs CURRENT_TIMESTAMP, does Trino have now(), Trino now function exists, current_timestamp Trino, current timestamp alias, what is the difference between now and current_timestamp in Trino, Trino session timezone, sysdate Trino.

3. **Iceberg `timestamptz` UTC-storage nuance** (the second Q4 error):
   - `timestamp WITH time zone` (Iceberg `timestamptz`) IS UTC-normalized on disk per the Iceberg spec — the per-value session zone is NOT preserved on disk; the stored value is a UTC instant at microsecond precision.
   - `timestamp WITHOUT time zone` (Iceberg `timestamp`) IS stored as a wall-clock value with no zone normalization.
   - Doc-anchor: iceberg.apache.org/spec — "timestamptz: Timestamp with microsecond precision, with timezone... stored as UTC."
   - DO-NOT-WRITE: "Trino + Iceberg does not normalize to UTC on storage" — FALSE for timestamptz; TRUE only for plain timestamp.

4. **Worked example**: `SELECT now(), current_timestamp;` — both return the same TIMESTAMP(3) WITH TIME ZONE in the session zone. `INSERT INTO iceberg.x.t (ts_tz) VALUES (now())` — stored value normalizes to UTC; `SELECT ts_tz FROM iceberg.x.t` — display reconverts to session zone. Contrast with `ts` column declared `timestamp` (no zone) — stored as wall-clock, no normalization.

5. **Cross-refs**: any existing date_trunc / from_unixtime / AT TIME ZONE canonicals in r07 / r27; the Iceberg type-mapping table in r09 (if it exists); the session.timezone property reference.

---

## Confirmation of iter551 wins (3 of 3)

- §1a.2A array_agg ORDER BY — Q1 lands as 5.00. **WIN CONFIRMED.**
- §1b WITH/CTE semantics — Q2 lands as 5.00 with verbatim doc quote. **WIN CONFIRMED.**
- §3.1G DISTINCT ON — Q3 lands as 5.00 with the ROW_NUMBER()=1 + max_by full rewrite path. **WIN CONFIRMED.**

These three iter551 canonicals are doing exactly what they should: preempting the question, anchoring the keyword, supplying the doc-verified rewrite, and citing cleanly.

---

## Other flags

- The Q4 fab-absence is the LATEST instance of a "real Trino primitive declared not-to-exist" pattern. iter552 should consider a quick audit pass: grep resources/ for "does not exist", "not supported", "parse error", "function-not-found", "raises an error" and cross-check against Trino 467 docs to surface any other such fabrications BEFORE they get re-probed.
- The Iceberg UTC-normalization nuance is subtle and worth its own H4 — many engineers conflate `timestamp` and `timestamptz` and assume neither normalizes.

## Rubric updates

- Common analytical query patterns (Q1, Q2): +5.00 each — strong reinforcement.
- SQL query best practices for OLAP (Q3): +5.00 — DISTINCT ON rewrite is a SQL-best-practices win.
- SQL query best practices for OLAP (Q4): +2.50 — drags the row down; flag as iter552 fix.
- Federation rubric row (4.49944/310): UNTOUCHED per instructions.
- Score line appended to training/rubric.md.
