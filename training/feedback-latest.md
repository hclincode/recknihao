# Iter1181 Judge Feedback

**Overall verdict:** STRONG PASS — Q1 WATCH CLOSES cleanly (responder now correctly routes "which dbt model in query history" to `query-comment` / `node_id` JSON, NOT to `persist_docs`); Q3 + Q4 pin-perfect on the primary; Q2 PRIMARY (`histogram(order_status) GROUP BY product_id`) is correct, but the appended "Alternative" `map_agg(order_status, COUNT(*)) ... GROUP BY product_id, order_status GROUP BY product_id` snippet is **broken as written** (TWO `GROUP BY` clauses in one SELECT = parse error; even with one `GROUP BY`, `map_agg(order_status, COUNT(*))` mixes a key column with a nested aggregate without a sub-aggregation step). Engineer copies the PRIMARY and ships; the broken padding is the recurring `feedback_responder_broken_secondary_alternative` pattern (Nth instance, NO-OP).

**Iter1181 watch:** `r27 §6.7L dbt query-comment model-name-in-query-history FIX-A iter1180` — **CLOSED** on first re-probe (1st-NO-OP-then-LIGHT-FIX-A-then-CLOSE pattern; 9th consecutive watch closure).

Total iter1181 score: (4.875 + 4.0 + 4.875 + 4.875) / 4 = **4.6563 / 5**

| Q | Topic | Score | Note |
|---|---|---|---|
| 1 | Oracle PL/SQL → dbt+Trino — dbt `query-comment` for query-history attribution | 4.875 | WATCH CLOSE iter1180 — `node_id` JSON + `regexp_extract(query, 'model\.[A-Za-z0-9_.]+')` against `system.runtime.queries` correctly routed |
| 2 | SQL best practices — per-group value→count MAP (`histogram` per group) | 4.0 | PRIMARY correct (`histogram` ships); secondary `map_agg` "Alternative" BROKEN-AS-WRITTEN (two `GROUP BY` clauses) |
| 3 | SQL best practices — `typeof(expr)` introspection | 4.875 | pin-perfect; all 6 example return strings accurate per trino.io/docs/current/functions/conversion.html |
| 4 | Trino CBO / planner steering — no `/*+ */` hints, session properties + ANALYZE | 4.875 | `join_distribution_type` AUTOMATIC/PARTITIONED/BROADCAST + `join_reordering_strategy` AUTOMATIC/ELIMINATE_CROSS_JOINS/NONE both verified verbatim; fabricated-name defang accurate |

---

## Q1 — dbt `query-comment` for "which dbt model generated this query in Trino's history" — WATCH CLOSE

**Score: 4.875** (Tech 5 / Clarity 5 / Practical 5 / Completeness 4.5)

**WATCH `r27 §6.7L dbt query-comment model-name-in-query-history FIX-A iter1180` — CLOSED on first re-probe.**

Iter1180 Q4 the responder routed the same question to `persist_docs` (table/column COMMENTs — wrong mechanism); iter1180 FIX-A added r27 §6.7L LEADING CANONICAL with keyword anchors ("which dbt model generated this query", "dbt model in Trino query history", "tag queries with the dbt model name", "find the dbt model behind a slow query in the Web UI") + an explicit DO-NOT-WRITE defang at r27 §6.7J (line 3922) cross-referencing §6.7L. This iter the responder routed cleanly to `query-comment` and gave every load-bearing fact:

1. dbt auto-injects a JSON comment in every query — VERIFIED at [docs.getdbt.com/reference/project-configs/query-comment](https://docs.getdbt.com/reference/project-configs/query-comment) — default comment: `/* {"app": "dbt", "dbt_version": "...", "profile_name": "...", "target_name": "...", "node_id": "model.<project>.<name>"} */`
2. Customizable via `dbt_project.yml` `query-comment: comment: "..." append: true` — accurate
3. `append: true` recommended for Trino (leading comments occasionally trip statement parsing) — matches r27 §6.7L line 3950
4. Lookup query `SELECT query_id, regexp_extract(query, 'model\.[A-Za-z0-9_.]+') AS dbt_model, state, "elapsed.cpu" FROM system.runtime.queries WHERE query LIKE '%"node_id"%' ORDER BY created DESC` — directly matches r27 §6.7L lines 3942-3946; the regex `model\.[A-Za-z0-9_.]+` correctly anchors on the `node_id` value prefix
5. NO Trino-side config needed — accurate (it's a dbt-adapter-side behavior)
6. NOT `persist_docs` (which writes table/column COMMENTs, a different mechanism for which-model-CREATED-the-TABLE) — explicit disambiguation given

Completeness shave (-0.5): didn't mention the JSON comment is on by default (engineer might worry they need to enable it); didn't mention the Web UI source/clientInfo column doesn't pick this up (it's in the query text itself). Not load-bearing — engineer arrives at `dbt_project.yml` + the `regexp_extract` history query and ships.

Topic: **Oracle PL/SQL → dbt + Trino SQL migration** — 4.4624/143 → (4.4624×143 + 4.875)/144 = **4.4653/144 PASSED** (+0.0029, margin +0.9653).

---

## Q2 — Per-group value→count MAP — PRIMARY correct, BROKEN secondary alternative

**Score: 4.0** (Tech 3.5 / Clarity 4.5 / Practical 4 / Completeness 4)

**PRIMARY answer correct and ships:**
```sql
SELECT product_id, histogram(order_status) AS counts_by_status
FROM orders
GROUP BY product_id
```
- `histogram(x) → map<K,bigint>` verified at [trino.io/docs/current/functions/aggregate.html](https://trino.io/docs/current/functions/aggregate.html): "Returns a map containing the count of the number of times each input value occurs."
- One-step per-group form — exactly what was asked. The iter1180 routing miss (engineer arrived at a `map_agg`+subquery two-step instead of the one-step `histogram`) is now FIXED.

**BROKEN secondary "Alternative" — DO NOT COPY:**

The responder appended an "Alternative (if you need a different value column)" snippet (paraphrased): `SELECT product_id, map_agg(order_status, COUNT(*)) ... FROM orders GROUP BY product_id, order_status GROUP BY product_id`. This is a **parse error as written** for two reasons:

1. A single SELECT cannot have two `GROUP BY` clauses — Trino parser rejects.
2. Even with one `GROUP BY product_id`, `map_agg(order_status, COUNT(*))` would require `order_status` to be either grouped or inside an aggregate; you can't have a bare key column passed to `map_agg` when its grain doesn't match the GROUP BY grain.

The CORRECT `map_agg` form (for the "if you need a different value column" case) is a subquery that pre-aggregates per `(product_id, order_status)`:
```sql
SELECT product_id, map_agg(order_status, cnt) AS counts_by_status
FROM (
  SELECT product_id, order_status, COUNT(*) AS cnt
  FROM orders
  GROUP BY product_id, order_status
)
GROUP BY product_id
```

**Classification: one-off responder slip — NO-OP (broken-secondary-alternative pattern).** Per `feedback_responder_broken_secondary_alternative` memory: the responder reliably nails the LEAD then appends a broken "for completeness" alternative form (iter936 window-in-GROUP-BY, iter943 PERCENTILE_CONT, iter948 price-suffix menu, iter950 nested-aggregate `max_by`, iter954 TO_CHAR-wrong-codes, iter1013 ORDER-BY-ungrouped, iter1019 TABLESAMPLE-after-WHERE, iter1020 regexp_extract-comma; this is the 9th instance). Leads pass, scope each as per-instance one-off re-probe NOT a resource defect, don't churn — no single resource fix addresses responder padding. The PRIMARY `histogram` is correct, keyword-magnetic, and ships; engineer would not copy the obviously-malformed secondary.

Topic: **SQL query best practices for OLAP** — 4.5734/258 → (4.5734×258 + 4.0)/259 = **4.5712/259 PASSED** (-0.0022, essentially flat, margin +1.0712).

---

## Q3 — `typeof(expr)` to inspect an expression's data type

**Score: 4.875** (Tech 5 / Clarity 5 / Practical 5 / Completeness 4.5)

Pin-perfect. Verified at [trino.io/docs/current/functions/conversion.html](https://trino.io/docs/current/functions/conversion.html): `typeof(expr) → varchar` — "Returns the name of the type of the provided expression." Docs examples: `typeof(123)` → `integer`, `typeof('cat')` → `varchar(3)`, `typeof(cos(2) + 1.5)` → `double`.

Responder's example return strings all accurate:
- `varchar(20)` — correct (typeof returns parameterized varchar)
- `bigint`, `double` — correct
- `json` — correct (e.g., on output of `json_parse`)
- `array(integer)` — correct (Trino's lowercase parameterized notation)
- `map(varchar,varchar)` — correct

Worked examples on a column, on `json_extract` output, and on `CAST(... AS DECIMAL)` are realistic SaaS use cases (verify before casting in a generated SQL pipeline).

Minor completeness shave (-0.5): didn't mention that `typeof` evaluates at PLANNING TIME so the answer doesn't depend on row data (which makes it useful for catching cast surprises BEFORE running a heavy query) — but this is a nice-to-have, not load-bearing.

Topic: **SQL query best practices for OLAP** — 4.5712/259 → (4.5712×259 + 4.875)/260 = **4.5724/260 PASSED** (+0.0012, margin +1.0724).

---

## Q4 — Trino has no `/*+ */` optimizer hints; use session properties + ANALYZE

**Score: 4.875** (Tech 5 / Clarity 5 / Practical 5 / Completeness 4.5)

All load-bearing facts verified:

1. **No hint syntax** — Trino has no `/*+ ... */` recognized hint mechanism. Oracle-style `/*+ USE_HASH(a b) */` and `/*+ FULL(orders) */` are parsed as plain comments and silently ignored (no error, no effect). Accurate.
2. **`join_distribution_type`** — verified at [trino.io/docs/current/admin/properties-general.html](https://trino.io/docs/current/admin/properties-general.html): valid values `AUTOMATIC` (default) / `PARTITIONED` / `BROADCAST`. Responder's three values match exactly.
3. **`join_reordering_strategy`** — verified at [trino.io/docs/current/admin/properties-optimizer.html](https://trino.io/docs/current/admin/properties-optimizer.html): valid values `AUTOMATIC` (default) / `ELIMINATE_CROSS_JOINS` / `NONE`. Responder's three values match exactly.
4. **Fabricated-name defang accurate** — `distributed_joins`, `broadcast_join_strategy`, `join_strategy` are NOT real Trino 467 session properties (only `join_distribution_type` is). The caveat names the correct trap. (Note: `distributed_join` was a legacy Presto session property removed long before Trino 467 — replaced by `join_distribution_type`.)
5. **`ANALYZE TABLE` for CBO stats** — accurate; the CBO uses NDV / row-count / per-column min-max-null stats populated by `ANALYZE` (and by `INSERT` for Iceberg automatic stats). On Iceberg+Trino 467 production stack, `ANALYZE catalog.schema.table` writes a Puffin file with `apache-datasketches-theta-v1` NDVs.
6. **`dbt pre_hook` to `SET SESSION join_distribution_type = 'BROADCAST'`** — correct mechanism for per-model planner steering on dbt-trino.

Minor completeness shave (-0.5): didn't mention dynamic filtering as a complementary "planner already does this for you" lever (often the biggest CBO win on partitioned Iceberg fact tables without any session property change) — but the question was specifically about hint replacement, not full CBO tuning.

Topic: **Trino CBO / ANALYZE TABLE / Puffin statistics / NDV / join ordering** — 4.6247/23 → (4.6247×23 + 4.875)/24 = **4.6351/24 PASSED** (+0.0104, margin +0.1351 above the elevated 4.5 threshold).

---

## Summary

- **Iter1181 watch CLOSED**: `r27 §6.7L dbt query-comment model-name-in-query-history FIX-A iter1180` reached cleanly on first re-probe — 9th consecutive watch closure in the 1st-NO-OP→LIGHT-FIX-A→CLOSE pattern.
- **No new FIX-A**: Q2 broken secondary is the recurring `feedback_responder_broken_secondary_alternative` Haiku padding pattern (9th instance); scope as one-off NO-OP, don't churn.
- **All four touched rubric topics remain PASSED** with positive or flat margin movement.
- **Iter average 4.6563 / 5 → STRONG PASS.**
