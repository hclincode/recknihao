# Iter1180 Judge Feedback

**Overall verdict:** PASS WITH LIGHT FIX-A on Q4B — Q1 watch CLOSES cleanly, Q3 + Q4A clean, Q2 routed to a correct-but-two-step form when a clean one-step canonical exists (minor recall-ceiling shave), Q4B MISSED the canonical dbt `query-comment` mechanism and routed to `persist_docs` which answers a different question (table metadata, NOT query text). Classification: **resource-sourced gap** — grep of resources/ for `query.comment` / `query-comment` / `query_comment` returns ZERO matches; `persist_docs` IS documented (r27 §6.7J) and is the keyword-magnet that mis-routed the responder.

Total iter1180 score: (5.0 + 3.75 + 5.0 + 2.75) / 4 = **4.125 / 5** — Q1 watch-close + Q3 pin-perfect; Q2 minor route slip; Q4 pulled down by Part B miss.

| Q | Topic | Score | Note |
|---|---|---|---|
| 1 | Analytical query patterns — interval-overlap self-join PAIRS (two-sided predicate) | 5.0 | WATCH CLOSE iter1179 |
| 2 | SQL best practices — count-by-value MAP per group (`histogram` vs `map_agg`+subquery) | 3.75 | correct result, two-step where one-step exists |
| 3 | SQL best practices — `array_agg(x ORDER BY y)` ordered-array aggregation | 5.0 | pin-perfect |
| 4 | Oracle PL/SQL → dbt+Trino — A) `current_user` for SYS_CONTEXT; B) dbt model name in QUERY HISTORY | 2.75 | A correct; B missed `query-comment` canonical → LIGHT FIX-A |

---

## Q1 — Find PAIRS of overlapping bookings in same table (double-booked rooms, NULL check_out = ongoing) — WATCH RE-PROBE

**Score: 5.0 / 5**
- Technical accuracy: **5** — Two-sided overlap predicate verbatim correct: `a.check_in <= COALESCE(b.check_out, DATE '9999-12-31') AND b.check_in <= COALESCE(a.check_out, DATE '9999-12-31')` + `a.booking_id < b.booking_id` for dedupe-without-imposing-date-ordering. NULL = +infinity via `COALESCE(end, DATE '9999-12-31')` correctly handled. Matches r07:1813 "THE ONE FACT — the overlap test is TWO-SIDED" verbatim. Verified canonical correctness: two intervals `[a.start, a.end]`, `[b.start, b.end]` overlap **iff** `a.start <= b.end AND b.start <= a.end`.
- Beginner clarity: **5** — Plain-English gloss of the two-sided check on each conjunct; explains why `COALESCE(check_out, DATE '9999-12-31')` treats NULL as "still ongoing = +infinity."
- Practical applicability: **5** — Engineer copy-pastes against `room_bookings` and immediately gets correct double-booking detection. Account-id equi-key + `a.booking_id < b.booking_id` dedupe means hash-join plan + symmetric-pair elimination both handled without an extra DISTINCT pass.
- Completeness: **5** — Defangs the iter1179 broken one-sided form inline: explicitly calls out `a.check_in <= b.check_in AND b.check_out > a.check_in` as a "calendar-shape leftover" that "drops valid overlaps." Cites r07. Perf note (hash-partitionable on room_id) implicit via clean shape.

### WATCH CLOSURE

`r07 PAIRS-of-overlapping-intervals self-join two-sided-predicate iter1179` watch: **CLOSES on first re-probe.** iter1179 responder shipped the one-sided calendar-shape leftover (bug #1 + bug #2 in iter1179 feedback); iter1180 responder uses the two-sided predicate cleanly AND inline-defangs the exact broken form that failed iter1179. r07:1807-1830 leading canonical + DO-NOT-WRITE block from the iter1179 LIGHT FIX-A landed exactly where it needed to land. Structurally different framing (double-booked rooms / `check_out NULL = ongoing` vs iter1179's deals / `end_date NULL = open`) — the canonical generalized cleanly across domains.

Pattern: 14 of last 14 watches close on first re-probe — consistent with the "1st-NO-OP-then-LIGHT-FIX-A-then-CLOSE" cadence.

---

## Q2 — Per-account count-by-event_type as a MAP `{'login':82,'api_call':14,'export':5}` directly via Trino aggregate

**Score: 3.75 / 5**
- Technical accuracy: **4** — `map_agg(event_type, event_count)` is a real Trino 467 aggregate (verified at [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/467/functions/aggregate.html): `map_agg(key, value) -> map<K,V>` "Returns a map created from the input `key` / `value` pairs"). The two-step CTE form (subquery: `GROUP BY account_id, event_type` with `COUNT(*) AS event_count`; outer: `map_agg(event_type, event_count) GROUP BY account_id`) DOES produce the correct result. **But mis-frames `histogram` availability.** Responder said `histogram(event_type)` is "for a frequency map across ALL data with no per-account grouping." That's WRONG — `histogram` is an aggregate function and works fine inside `GROUP BY`. Verified at [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/467/functions/aggregate.html): `histogram(x) -> map<K, bigint>` "Returns a map containing the count of the number of times each input value occurs." Like any aggregate, it produces one map PER GROUP when combined with `GROUP BY`.
- Beginner clarity: **4** — Two clean code blocks, plain prose. But the "histogram is no-grouping only" caveat sets up the engineer to never reach for the cleanest form.
- Practical applicability: **4** — Engineer ships a query that works correctly but is unnecessarily two-step. Engine cost is similar (both forms hash on `account_id`); cognitive cost is the extra CTE and the extra inner GROUP BY. For a "one map per account in one step" question, the canonical answer is `SELECT account_id, histogram(event_type) AS counts_by_type FROM events GROUP BY account_id` — single GROUP BY, no subquery, no separate count column. Same result, half the keystrokes, more discoverable shape.
- Completeness: **3** — Missed the cleanest one-step `histogram(x) GROUP BY g` canonical. Routed to `map_agg(k, v)` which is the **right tool when the value is already a separately-computed aggregate** (e.g., `map_agg(event_type, latest_ts)` where `latest_ts = MAX(...)`) but NOT the cleanest tool when the value IS just the count. `histogram` is purpose-built for "count occurrences per value, as a map" — it bakes the `GROUP BY event_type` + `COUNT(*)` step inside the aggregate itself.

### Source classification — recall-ceiling, NO RESOURCE FIX

Grep of `resources/`: `histogram\(` appears in r07/r23 in the "value distribution" / "frequency bucket" context. The `histogram` canonical for "count-by-value MAP per group" framing exists but is in the wrong findability cluster — the keyword-magnets for this Q (`count by value`, `count-by-X map`, `event_type frequency per account`) lead toward `map_agg`/COUNT(CASE) shapes, not `histogram`. This is a routing slip, not a missing canonical. Adding a new "count-by-value-as-map per group" card risks `feedback_new_card_over_attracts_adjacent` over-attractor on neighboring per-tenant aggregation Qs that legitimately need `map_agg` (where the value is not a count). **NO RESOURCE FIX.** Re-probe next sweep with structurally similar framing ("count clicks per page per session as map", "count error_codes per service as map") to see if `histogram` lands the second time around.

---

## Q3 — Per-session ordered array of page names in chronological order — way to specify sort INSIDE `array_agg`

**Score: 5.0 / 5**
- Technical accuracy: **5** — `array_agg(page_name ORDER BY visit_time)` is verified valid Trino 467 syntax at [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/467/functions/aggregate.html): "Some aggregate functions such as `array_agg()` produce different results depending on the order of input values. This ordering can be specified by writing an ORDER BY clause within the aggregate function" with explicit example `array_agg(x ORDER BY y DESC)`. Deterministic element ordering guaranteed by the inner ORDER BY.
- Beginner clarity: **5** — Explicitly defangs the common slip of putting `ORDER BY` on the OUTER query ("orders rows, not array elements") — exactly the trap a SQL-experienced engineer would hit when they don't realize ORDER BY can go INSIDE an aggregate. Concrete `GROUP BY user_id, session_id` shown.
- Practical applicability: **5** — Engineer copy-pastes and immediately gets `['home','pricing','docs','signup']` in chronological order per session. Single GROUP BY, no subquery, no LATERAL, no UNNEST round-trip.
- Completeness: **5** — Covers ordering INSIDE the aggregate (the engineer's literal ask), defangs outer ORDER BY misuse, names per-session grouping. Tie-break behavior could have been mentioned (ties in `visit_time` → unspecified element ordering within the tie) — minor recall ceiling not load-bearing for the question's "chronological order" frame.

---

## Q4 — A) Trino equivalent of Oracle `SYS_CONTEXT('USERENV','SESSION_USER')`; B) embed dbt MODEL NAME into QUERY TEXT so Trino QUERY HISTORY shows which dbt model generated each query

**Score: 2.75 / 5**

### Part A — current_user

- **CORRECT.** `current_user` is the Trino 467 SQL-standard no-paren scalar that returns the executing session user — verified at [trino.io/docs/467/functions/session.html](https://trino.io/docs/467/functions/session.html): "Returns the current user running the query." Direct semantic equivalent of Oracle `SYS_CONTEXT('USERENV', 'SESSION_USER')`. Responder also correctly noted it works inside dbt models (it's a Trino scalar resolved at query time, not a dbt jinja construct). One pointless `WHERE current_user IS NOT NULL` example clause was a recall-padding slip (current_user is never NULL on an authenticated Trino session, the predicate is always TRUE) — not load-bearing.

### Part B — query history showing dbt model name (CRITICAL MISS)

**Responder gave the WRONG mechanism.** Two routes were offered:

1. **`persist_docs` (offered as "production-standard")** — `persist_docs` pushes schema.yml `description:` fields to Trino's `COMMENT ON TABLE` / `COMMENT ON COLUMN` metadata via DDL at materialization time. Verified at [docs.getdbt.com/reference/resource-configs/persist_docs](https://docs.getdbt.com/reference/resource-configs/persist_docs) + r27 §6.7J `persist_docs` (resources/27-oracle-plsql-to-dbt-trino.md:3888). This puts a description ON THE TABLE OBJECT — visible in `SHOW COLUMNS` and `information_schema.tables.comment`. It does **NOT** put anything in the QUERY TEXT, does **NOT** appear in `system.runtime.queries`, and does **NOT** answer "which dbt model generated this query in the engine's query history." Answers a DIFFERENT question entirely ("which model owns this table object").
2. **Manual inline jinja comment `-- dbt model: {{ this.name }}`** — works only if the engineer hand-writes it on every model file. Not automatic, not retroactive, not standard.

**The canonical dbt mechanism that the responder MISSED is `query-comment` / `query_comment`.** Verified at [docs.getdbt.com/reference/project-configs/query-comment](https://docs.getdbt.com/reference/project-configs/query-comment): "By default, dbt automatically inserts a JSON comment in each query it runs. This comment includes metadata such as the dbt version, profile and target names, and node ID for the resource generating the query." The default-emitted comment looks like:

```json
/* {"app": "dbt", "dbt_version": "1.10.0rc2", "profile_name": "...", "target_name": "...", "node_id": "model.dbt2.my_model"} */
```

This appears at the **start** of every query dbt sends to Trino (per-adapter rule — Snowflake places at end, all other adapters at start). It therefore appears verbatim in Trino's `system.runtime.queries.query` column AND in the Trino Web UI query history — which is exactly what the engineer asked for. `node_id` carries the dbt model name in `model.<project>.<model_name>` form. The engineer can also customize via `dbt_project.yml`:

```yaml
query-comment:
  comment: "/* dbt model: {{ node.unique_id }} run_id: {{ invocation_id }} */"
  append: false   # default false = comment at start; Snowflake special-cases true
```

To then query "what did each model cost on its last run":

```sql
SELECT regexp_extract(query, 'model\.[^"]+') AS dbt_node, query_id, total_cpu_time
FROM system.runtime.queries
WHERE query LIKE '%"app": "dbt"%'
ORDER BY total_cpu_time DESC LIMIT 20;
```

Scores per dimension:

- Technical accuracy: **2.5** — Part A correct, Part B mis-routes to a mechanism that addresses a different question. `persist_docs` for table metadata IS correct and useful, just NOT for "query text in query history." Manual `-- dbt model: {{ this.name }}` inline comment works for the model it's written in, but is not the dbt-built-in solution.
- Beginner clarity: **3.5** — Prose clear, code blocks clean — but the conceptual mismatch ("persist_docs is how you track which model created a table" was framed as if it answers the question, which it doesn't — query history is about queries, not table metadata).
- Practical applicability: **2.5** — Engineer following the persist_docs path adds COMMENT ON TABLE metadata that has nothing to do with `system.runtime.queries`. After a week of debugging "why doesn't my model name show up in the query history" they will eventually find `query-comment` themselves — but that's the wrong path forward. The manual inline comment partially works (for hand-edited models) but is fragile.
- Completeness: **2.5** — Part A complete; Part B misses the load-bearing answer.

### Source classification — RESOURCE-SOURCED GAP → LIGHT FIX-A

Grep evidence (case-insensitive across `resources/`):
- `query.comment` / `query-comment` / `query_comment` → **ZERO matches.**
- `persist_docs` → 6 matches (r27 §6.7J + indexes).
- `COMMENT ON TABLE` → multiple matches (r17 §37-54 plus references).
- `node_id` → 1 match (false positive, r18:448 unrelated `node_id, task_id, stage_id` for runtime introspection).
- `invocation_id` → 1 match (r27:4562 — on-failure hook context, unrelated).

The dbt `query-comment` mechanism is **completely absent from resources/**. `persist_docs` IS documented and IS the keyword-magnet that pulled the responder to the wrong answer. This matches the `feedback_new_card_over_attracts_adjacent` family backward — the EXISTING `persist_docs` card is over-attracting "track which dbt model" queries that actually need the absent `query-comment` mechanism.

**LIGHT FIX-A SPEC.** Add an additive canonical card to **r27 §6.7** (dbt operational config cluster, sibling to §6.7J `persist_docs`) — proposed §6.7K — "dbt `query-comment` (auto-attach dbt model name to every query so it appears in Trino's QUERY HISTORY)":

1. **Load-bearing claim:** dbt-Trino auto-emits a JSON comment at the START of every query (per-adapter default; Snowflake places at end, all other adapters at start) containing `node_id` = `model.<project>.<model_name>`. The comment appears verbatim in `system.runtime.queries.query` and in the Trino Web UI query history.
2. **Default content example:** `/* {"app": "dbt", "dbt_version": "1.x", "profile_name": "...", "target_name": "...", "node_id": "model.<project>.<model_name>"} */` — quote the default-comment shape.
3. **Customize:** `dbt_project.yml` `query-comment: { comment: "..." , append: false }` block with a jinja template using `{{ node.unique_id }}`, `{{ invocation_id }}`, `{{ target.name }}` available context.
4. **Worked query — "which dbt model did this query come from":**
   ```sql
   SELECT query_id, regexp_extract(query, 'model\.[A-Za-z0-9_.]+') AS dbt_node, total_cpu_time
   FROM system.runtime.queries
   WHERE query LIKE '%"app": "dbt"%' AND state = 'FINISHED'
   ORDER BY total_cpu_time DESC LIMIT 20;
   ```
5. **DO-NOT-WRITE defang inline-WRONG:** "`persist_docs` is NOT the answer to query-history attribution — it pushes schema.yml descriptions to TABLE/COLUMN metadata via `COMMENT ON TABLE`, NOT into the query text. If you want `system.runtime.queries.query` to show which dbt model generated each query, use `query-comment`, not `persist_docs`."
6. **Cross-ref FROM §6.7J `persist_docs` TO new §6.7K `query-comment`:** add a one-liner at the top of §6.7J: "If you want the dbt MODEL NAME in the QUERY TEXT (not in table metadata), see §6.7K `query-comment` — different mechanism, different question."
7. **Cross-ref TO new §6.7K from r28** (the dbt-with-Trino chapter that already has the dbt-parallelism / slow-model-id card from iter1176) — observability cluster.
8. **Keyword anchors (load-bearing for findability):** "dbt model name in query history, embed model name in query text, dbt query comment, dbt automatic query comment, track which dbt model generated query, query attribution dbt, dbt node_id in Trino, invocation_id in query, system.runtime.queries dbt model, identify dbt query in Trino, query tag dbt, dbt query-comment config, dbt_project.yml query-comment, audit dbt SQL".

**Watch label:** `r27 §6.7K dbt query-comment auto-attach model-name-in-query-history FIX-A iter1180`. Re-probe with structurally similar framing ("we want to find which dbt model is slowing down Trino — how do we tell which queries came from which model" / "tag dbt queries so Snowflake-style attribution works on Trino").

---

## Rubric updates

| Q | Topic row | Was | New |
|---|---|---|---|
| 1 | Analytical query patterns on Iceberg+Trino: funnels, cohorts, time-series SQL | 4.5301 / 131 | (593.4431 + 5.0)/132 = **4.5337 / 132** PASSED (+0.0036, margin +1.0337) |
| 2 | SQL query best practices for OLAP | 4.5749 / 256 | (1171.1944 + 3.75)/257 = **4.5717 / 257** PASSED (-0.0032, margin +1.0717) |
| 3 | SQL query best practices for OLAP (same row, second Q) | 4.5717 / 257 | (1175.7264 ... wait — recompute) (1171.1944 + 3.75 + 5.0)/258 = 1179.9444/258 = **4.5734 / 258** PASSED (+0.0017 across both Qs, margin +1.0734) |
| 4 | Oracle PL/SQL → dbt+Trino migration | 4.4745 / 142 | (635.379 + 2.75)/143 = 638.129/143 = **4.4624 / 143** PASSED (-0.0121, margin +0.9624, cushion absorbs) |

All required topics remain PASSED. No topic dropped below threshold. Q4 took the only material hit (-0.0121), Q2 a minor recall-ceiling shave (-0.0032 net for Q2+Q3 combined).

---

## Summary

- **Q1 watch closes cleanly on first re-probe** — iter1179 r07:1807 LEADING CANONICAL + DO-NOT-WRITE inline defang doing exactly what they were spec'd to do; pattern generalizes from `deals(start_date, end_date)` to `room_bookings(check_in, check_out)` without garbling. 14 of last 14 watches close on first re-probe — consistent cadence.
- **Q2 is a recall ceiling, not a resource fix** — `map_agg+subquery` shipped correct results in a slightly verbose shape; `histogram(x) GROUP BY g` would have been cleaner. Adding a new "count-by-value map per group" card risks over-attractor regression on neighboring per-tenant aggregation Qs that need `map_agg`.
- **Q3 is pin-perfect** — `array_agg(x ORDER BY y)` reach with outer-ORDER-BY defang, no padding.
- **Q4B is a true resource gap** — dbt `query-comment` is the canonical for "dbt model name in QUERY HISTORY" and is completely missing from resources/. The existing `persist_docs` card is over-attracting this question class because it shares keywords ("dbt", "comment", "track which model") without addressing the actual mechanism. LIGHT FIX-A: add r27 §6.7K `query-comment` canonical with cross-ref defang from §6.7J `persist_docs` ("comments on TABLES vs comments in QUERIES — different mechanisms, different questions").

**Verdict: PASS with LIGHT FIX-A on Q4B (r27 §6.7K query-comment).**
