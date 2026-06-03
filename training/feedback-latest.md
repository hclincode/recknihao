# Judge Feedback — Iter 413 (EXTENDED PHASE — end-of-iteration only)

**Overall: 4.21875 PASS** (Q1 4.875 + Q2 3.125 + Q3 4.625 + Q4 4.25) — above the 3.5 overall PASS threshold, but **step-DOWN of 0.406 from iter412 4.625**, driven entirely by Q2's federation TopN-pushdown accuracy slip. Twelfth consecutive overall PASS in the iter402-413 window, but the failure-mode pattern (confident inaccuracy on a load-bearing claim) reappears for the third time in the last seven iterations (iter407 branches-Spark-only, iter411 QUALIFY-on-Trino, iter413 OSS-Trino-can't-push-TopN).

**Headline:**
1. **CRITICAL — Q2 FEDERATION TopN-PUSHDOWN ACCURACY FAIL (3.125).** Responder claims "ORDER BY and LIMIT do NOT push down automatically in Trino 467 for the PostgreSQL connector" and frames TopN pushdown as a "later Trino version / commercial fork" feature. **VERIFIED WRONG** against trino.io/docs/current/optimizer/pushdown.html + trino.io/docs/current/connector/postgresql.html: the OSS Trino PostgreSQL connector has supported TopN pushdown (TableScan with sortOrder + limit) for years. The responder reaches the right conclusion for THIS SPECIFIC query shape (`GROUP BY ... ORDER BY COUNT(*) DESC LIMIT 50` — TopN does NOT push because ORDER BY is on a Trino-computed aggregate), but via a WRONG GENERAL CLAIM. The engineer who internalizes "Trino 467 OSS can't push TopN" will over-apply `system.query()` passthrough, rewrite already-pushed queries, and push for a commercial fork they don't need.
2. **WIN — Q1 federation dynamic filtering (4.875).** Teacher's iter413 Section 13.3 landed cleanly. dynamicFilterAssignments EXPLAIN signature, INNER/RIGHT vs LEFT/FULL OUTER restriction, VARCHAR-vs-BIGINT type-mismatch foot-gun, enable_dynamic_filtering kill switch — all verified accurate.
3. **WIN — Q3 dbt --vars parameterized backfill (4.625).** var()/--vars JSON, run_started_at + modules.datetime.timedelta, dbt_project.yml overridable by CLI — all verified against docs.getdbt.com.
4. **WIN with minor flag — Q4 window NULL fix (4.25).** COALESCE/UNBOUNDED PRECEDING/RANGE INTERVAL alternatives all syntactically correct, but responder did NOT flag that `COALESCE(avg, session_count)` SUBSTITUTES the raw current value for a true rolling average — that's a metric-semantics change the engineer should be warned about.

**Trino federation topic status (CRITICAL):**
- **Previous: 4.4925 / 267 (NEEDS WORK, 0.0075 below 4.5 threshold)**
- **NEW: 4.4892 / 269 (NEEDS WORK, 0.0108 below 4.5 threshold) — REGRESSED 0.0033 further from threshold**
- The Q2 inaccuracy actively MOVED THE TOPIC AWAY from passing despite teacher's iter413 Section 13 threshold-push effort. The Q1 STRONG PASS (4.875) lifted the topic, but the Q2 FAIL (3.125) dragged it down more.
- **The Trino federation topic does NOT cross the 4.5 threshold this iteration. It REGRESSED.**

**Pattern note:** Third confident-inaccuracy-on-load-bearing-claim failure in seven iterations:
- iter407 Q2: "branches are Spark-only" (WRONG — Trino reads branches) → fixed iter408 Q1.
- iter411 Q2: QUALIFY recommended on Trino 467 (WRONG — QUALIFY not in Trino grammar) → fixed iter412 Q1.
- iter413 Q2: "OSS Trino 467 PG connector can't push TopN" (WRONG — TopN pushdown supported since Trino 353) → needs fix iter414.

The teacher's recovery pattern remains tight (each previous instance recovered within one iteration), but the **structural risk** is that the responder produces a confident factual claim about a TOPIC-SPECIFIC connector behavior that the engineer would act on. For federation specifically, this is the third such inaccuracy on the topic (each in a different facet: branches/dialect/connector-capability), and it keeps the topic stuck below the 4.5 threshold.

---

## Q1 — Dynamic filtering federated join (FEDERATION)

**Scores: 5.0 / 4.5 / 5.0 / 5.0 — avg 4.875 STRONG PASS**

### What landed
- **DF mechanism: build hash of small PG side + extract join-key IN-list + push to Iceberg scan to prune files 10-100x** — CORRECT canonical mechanism (verified against trino.io/blog/2019/06/30/dynamic-filtering.html).
- **The shuffle is the partitioned join (expected, not a problem)** — correct framing; helps the engineer not chase a non-issue.
- **EXPLAIN (TYPE DISTRIBUTED) shows dynamicFilterAssignments in events TableScan** — VERIFIED against trino.io/docs/current/admin/dynamic-filtering.html.
- **Absent reasons enumerated correctly:**
  - VARCHAR-vs-BIGINT type mismatch disables DF — VERIFIED.
  - LEFT/FULL OUTER not supported (DF only INNER/RIGHT) — VERIFIED ("Dynamic filtering cannot be used for LEFT OUTER and FULL OUTER joins because all records from the left side must be returned at least once").
  - enable_dynamic_filtering=false session-property kill switch — CORRECT.
- **EXPLAIN ANALYZE Physical Input to confirm** — correct diagnostic.
- **Partition column must match join column to benefit** — correct semantic.

### Verdict
STRONG PASS. Teacher's iter413 Section 13.3 landed cleanly.

---

## Q2 — TopN/LIMIT pushdown to Postgres (FEDERATION)

**Scores: 2.5 / 4.0 / 3.0 / 3.0 — avg 3.125 FAIL**

### Critical accuracy defect (the headline issue)
- Responder claims **"ORDER BY and LIMIT do NOT push down automatically in Trino 467 for the PostgreSQL connector"** and frames TopN pushdown as a **"later Trino version / commercial fork"** feature.
- **VERIFIED WRONG** against:
  - trino.io/docs/current/optimizer/pushdown.html: "The combination of a LIMIT or FETCH FIRST clause with an ORDER BY clause creates a small set of records to return out of a large sorted dataset, and the pushdown for such a query is called a Top-N pushdown."
  - trino.io/docs/current/connector/postgresql.html: PostgreSQL connector explicitly listed as supporting TopN pushdown.
  - Trino release 353 (March 2021) added Top-N pushdown infrastructure; the PG connector has supported it for years.
- The right framing: **OSS Trino 467 PG connector DOES support TopN pushdown**. For a query like `SELECT * FROM pg.orders ORDER BY total DESC LIMIT 100`, the TableScan shows sortOrder + limit parameters and the TopN operator is absent from the plan — that's the pushed case.

### Right conclusion via wrong general claim
- The SPECIFIC query in the question — `SELECT account_id, event_type, COUNT(*) FROM pg.events GROUP BY account_id, event_type ORDER BY COUNT(*) DESC LIMIT 50` — TopN does NOT push because ORDER BY is on a computed aggregate (`COUNT(*)`) that Trino computes after GROUP BY rows are returned. So the **outcome** the responder predicts (all rows pulled to Trino, sort+limit in Trino) is CORRECT for THIS query.
- BUT the **mechanism** the responder cites is WRONG. The engineer who reads "OSS Trino 467 can't push TopN" will internalize that and over-apply `system.query()` passthrough, rewrite queries that would have pushed cleanly, and seek a commercial fork.

### What's accurate
- `system.query()` passthrough running GROUP BY/ORDER BY/LIMIT on PG with outer ORDER BY because passthrough doesn't preserve order — CORRECT workaround for the specific query shape (PG-side compute, return aggregated rows).
- EXPLAIN diagnostic to check TopN operator above TableScan — correct diagnostic in principle.

### Verdict
FAIL on per-question federation threshold (4.5 raised). The right outcome via the wrong general claim is exactly the iter407/iter411 confident-inaccuracy failure pattern. Engineer would act on the wrong mental model.

---

## Q3 — dbt --vars parameterized backfill (NON-FED)

**Scores: 5.0 / 4.5 / 4.5 / 4.5 — avg 4.625 STRONG PASS**

### What landed
- **var() / --vars JSON syntax** — VERIFIED against docs.getdbt.com/reference/dbt-jinja-functions/var ("--vars argument accepts a YAML dictionary as a string on the command line").
- **Model template `{% set start_date = var('backfill_start_date','default') %}` + WHERE event_date BETWEEN** — CORRECT canonical pattern.
- **CLI dbt run --vars '{...}'** — CORRECT.
- **Default 2nd arg safe** — CORRECT (var() returns 2nd arg if variable not set; useful for prod-default + CLI-override).
- **Rolling 90d via run_started_at + modules.datetime.timedelta** — VERIFIED against docs.getdbt.com/reference/dbt-jinja-functions/run_started_at (Python datetime UTC) + docs.getdbt.com/reference/dbt-jinja-functions/modules (modules.datetime exposes Python datetime module in Jinja).
- **dbt_project.yml vars defaults overridable by CLI** — CORRECT.

### Verdict
STRONG PASS. The iter413 LOW backlog item for parameterized-backfill was deferred but the responder still landed the answer cleanly from existing resources — suggests the existing resource 13 dbt incremental section already supports this pattern.

---

## Q4 — Window AVG NULL on gap day (NON-FED)

**Scores: 4.0 / 4.5 / 4.5 / 4.0 — avg 4.25 PASS (below STRONG)**

### What landed
- **AVG over empty/all-NULL frame returns NULL** — CORRECT (verified against trino.io/docs/current/functions/window.html: "if x is null for all rows ... null is returned").
- **ROWS 6 PRECEDING looks back 6 physical rows** — CORRECT.
- **UNBOUNDED PRECEDING cumulative alternative** — CORRECT but different metric (cumulative running average vs rolling).
- **RANGE INTERVAL '6' DAY PRECEDING alternative** — VERIFIED against trino.io/blog/2021/03/10/introducing-new-window-features.html.
- **Diagnostic COUNT(*) OVER rows_in_window** — useful pattern.

### Semantic flag missing (the deduction)
- Responder recommends `COALESCE(avg, session_count)` as a fallback. **This SUBSTITUTES the raw current row's `session_count` for a NULL rolling average** — on gap days the metric becomes "today's value" instead of "7-day rolling average". That defeats the purpose of the rolling metric.
- Other fallback choices have different semantic implications:
  - `COALESCE(avg, 0)` — treats gap as zero (skews downward).
  - `COALESCE(avg, current_value)` — what the responder recommended; defeats rolling intent.
  - UNBOUNDED PRECEDING — cumulative, NOT rolling (different metric).
  - RANGE INTERVAL '6' DAY PRECEDING — true calendar rolling, but still NULL when zero rows fall in window.
  - **LEFT JOIN calendar dim + densify with zero-fill** — only semantically-clean fix.
- The responder didn't explicitly flag this; the engineer would copy-paste the COALESCE pattern and silently change their metric.

### Verdict
PASS but below STRONG due to missing semantic-change flag on the recommended COALESCE fallback.

---

## Pattern across all four answers

| Q | Score | Verdict |
|---|---|---|
| Q1 | 4.875 | STRONG PASS — DF mechanism + EXPLAIN signature + INNER/RIGHT-only + type-mismatch foot-gun |
| Q2 | 3.125 | FAIL — TopN-pushdown wrong general claim (right outcome via wrong mechanism) |
| Q3 | 4.625 | STRONG PASS — dbt --vars JSON + run_started_at + modules.datetime.timedelta |
| Q4 | 4.25 | PASS — fallback options correct but semantic-change flag missing |

**Average 4.21875 PASS** — twelfth consecutive overall PASS in the iter402-413 window, but **step-DOWN of 0.406 from iter412 4.625**.

**Trajectory iter394-413:** `4.75P/3.125F/4.3125P/4.375P/4.34375P/4.09375P/4.0625P/3.8125F/4.59375P/3.875F/4.25P/4.6875P/4.40625P/4.625P/4.0625P/4.125P/4.5625P/4.0P/4.219P/4.625P/**4.21875P**`.

**Topic status table:**
- Postgres-to-Iceberg ingestion: 4.4917/145 -> 4.4926/146 — PASSED (above threshold).
- Iceberg table maintenance: 4.4102/77 — unchanged this iteration.
- Analytical query patterns Iceberg+Trino: 4.4233/11 -> 4.4214/12 — PASSED.
- **Trino federation / cross-source: 4.4925/267 -> 4.4892/269 — NEEDS WORK (REGRESSED 0.0033 further from threshold; now 0.0108 below 4.5 raised threshold).**

---

## Teacher actions next (iter 414)

1. **HIGH — TopN-pushdown accuracy correction in resources/22-trino-federation-postgresql.md Section 13.5.** The teacher's iter413 Section 13 threshold-push effort included Section 13.5 on TopN/LIMIT pushdown, but the responder still produced the wrong general claim — the Section 13.5 framing may have been read as "TopN doesn't push" rather than "TopN pushes in the canonical case and fails only in specific shapes". Rewrite Section 13.5 to lead with the **canonical pushed case**:
   - Lead: "**TopN pushdown DOES work in OSS Trino 467 PostgreSQL connector.** Example: `SELECT * FROM pg.orders ORDER BY total DESC LIMIT 100` — TableScan shows sortOrder + limit; TopN operator is ABSENT from the EXPLAIN plan (this is the pushed case)."
   - Then explicitly list **shapes where TopN does NOT push** (and why), with the GROUP BY + ORDER BY agg + LIMIT shape as the headline example: "ORDER BY is on a computed aggregate that Trino computes after GROUP BY — the connector can't sort on a value it hasn't produced yet."
   - Show what DOES push for the aggregate case: "The GROUP BY + COUNT(*) may push as aggregate pushdown if connector supports it; the LIMIT 50 may push as Limit pushdown without TopN."
   - **Add citation row to Section 13.8 mapping the TopN-pushdown claim to trino.io/docs/current/optimizer/pushdown.html#topn-pushdown.**

2. **MEDIUM — Q4 window NULL semantic-change flag in resources/07-analytical-query-patterns.md.** Add a "fallback choices change metric semantics" callout listing four options:
   - `COALESCE(avg, 0)` — treat gap as zero (skews avg downward toward 0).
   - `COALESCE(avg, current_value)` — use raw current value (gap day metric = today's metric, defeats rolling intent).
   - UNBOUNDED PRECEDING — cumulative running average (DIFFERENT metric, not rolling).
   - RANGE INTERVAL '6' DAY PRECEDING — true calendar rolling, but still NULL when zero rows fall in window.
   - **LEFT JOIN calendar dim + densify with zero-fill** — only semantically-clean fix.

3. **LOW carry-forward backlog**: HMS->Nessie write-freeze alternative + Hive-views-don't-migrate gotcha (deferred from iter412); equality-perf-regression caveat for enable-string-pushdown-with-collate; MERGE rollback; OPA-override timeout; schema registry compat; JWT+OPA concurrency; Iceberg tagging 3rd-angle; fs.cache JMX 3rd-angle; Iceberg v3 deletion vectors timeline; snapshot vs serializable phantom-row 3rd-angle.

---

## Judge probe targets next (iter 414)

1. **CRITICAL — TopN-pushdown 2nd-angle (durability of iter414 fix).** Different phrasing, e.g.:
   - "I have `SELECT order_id, total FROM pg.orders ORDER BY total DESC LIMIT 100` — does this pull all 50M rows to Trino?" — confirms responder NOW states TopN pushes cleanly for this shape (TableScan with sortOrder + limit; TopN operator absent from EXPLAIN).
   - Or: "Trino EXPLAIN shows no TopN operator on my `ORDER BY ... LIMIT 100` query — did it push?" — confirms responder reads absence-of-TopN-operator as the pushed signal.

2. **HIGH — Trino federation topic threshold-push continuation.** After iter413's 0.0033 regression, the topic is 0.0108 below threshold. To cross:
   - ONE more 4.5 federation answer puts it at ~4.4929 (still 0.0071 below).
   - TWO more at ~4.4966 (still 0.0034 below).
   - THREE more 4.6+ answers needed to cross threshold cleanly.
   - **Probe federation in iter414, iter415, iter416 consistently** — the topic needs a sustained sequence of high scores.

3. **Window NULL 2nd-angle.** "Rolling 7-day metric shows NULL gaps but I need zero-fill — what's the right pattern?" — probes the calendar-dim LEFT JOIN densification alternative as the semantically-clean fix.

4. **Snapshot vs serializable phantom-row 3rd-angle** — still pending durability re-probe from iter412 teacher's resource 26 § 8.1/8.2 fix.

5. **HMS->Nessie 2nd-angle for write-freeze alternative** — still pending.

6. **Iceberg v3 deletion vectors timeline** carry-forward (long-standing backlog item).

---

## Critical message to teacher for iter414: the TopN-pushdown nuance

The right mental model the teacher must instill in resources/22 Section 13.5:

> **TopN pushdown in OSS Trino 467 PostgreSQL connector — DOES work, but only in specific shapes.**
>
> **PUSHES (canonical case):** `SELECT * FROM pg.t [WHERE pushed_predicate] ORDER BY col LIMIT N`
> - TableScan in EXPLAIN shows `sortOrder = [...]` and `limit = N`.
> - TopN operator is ABSENT from the EXPLAIN plan (that's the pushed-down signal).
>
> **DOES NOT PUSH (common failure shapes):**
> 1. **ORDER BY on Trino-computed expression** (e.g., `ORDER BY COUNT(*)`, `ORDER BY col_a + col_b`): connector can't sort on values it hasn't produced.
> 2. **ORDER BY across multiple sources** (federated join): TopN can only push to one connector, not across.
> 3. **ORDER BY on column with non-default collation** the connector can't reproduce.
> 4. **Non-identity projection between TopN and TableScan** (Trino issue #25138): rule limitation.
>
> **For the failure shapes — the workaround tree:**
> 1. **First check what DID push** for the failure case — GROUP BY + COUNT(*) often pushes as aggregate pushdown, and a plain LIMIT (no TopN) may also push as Limit pushdown.
> 2. **`system.query()` passthrough** if you need PG-side compute end-to-end (write the GROUP BY/ORDER BY/LIMIT in passthrough SQL, accept that the outer Trino ORDER BY isn't preserved by passthrough).
> 3. **Materialize the rollup nightly** if the agg query is hot and federation overhead is unacceptable.

The wrong framing the responder produced ("OSS Trino 467 can't push TopN, that's a commercial-fork feature") is the inversion of the right framing. The right framing leads with the canonical pushed case, then enumerates exceptions. The wrong framing leads with the exception and presents it as the default.

This is the third confident-inaccuracy-on-load-bearing-claim failure on the federation topic in seven iterations. Each instance keeps the topic stuck below the 4.5 raised threshold.
