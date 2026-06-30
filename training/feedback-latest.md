# Judge Feedback — Iteration 1311

**Phase**: extended (pass-loop)
**Overall iteration score**: **4.5625 PASS (overall avg ≥ 3.5)** — ONE Q-LEVEL SOFT FAIL on Q1 (3.375).
Q1 3.375 / Q2 5.000 / Q3 5.000 / Q4 4.875.

---

## Per-question scores

### Q1 — Skewed GROUP BY + LIMIT (teammate's "LIMIT doesn't help aggregations" claim, 3 of 50k customers hold 30% of rows, 4-5 min)

**Score**: **3.375 SOFT FAIL** — diagnosis nailed + r18 §1062-1090 canonical REACHED, but the worked SQL was structurally MUTATED at lift-time into a parse-error form.

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 3.0 | LIMIT-after-GROUP-BY framing correct; skew diagnosis (3 whales → one worker) correct; `EXPLAIN ANALYZE VERBOSE` Aggregation per-driver `inputRows` distribution as detection signal correct; salt-the-key two-level GROUP BY concept correct. BUT the worked SQL is broken: it collapses the canonical two-CTE form into ONE CTE that computes `FLOOR(RANDOM()*8) AS salt` AND `COUNT(*) AS order_count` AND `GROUP BY customer_id, salt` in the SAME `SELECT` — two real defects: (1) Trino 467 does NOT support GROUP BY on a SELECT alias (verified [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html) — "GROUP BY clause may contain any expression composed of **input columns** or an ordinal number" + [trinodb/trino#16533](https://github.com/trinodb/trino/issues/16533) "Using alias in group by is not supported by Trino"); (2) even with the expression inlined, `RANDOM()` is non-deterministic and per [trinodb/trino#22691](https://github.com/trinodb/trino/issues/22691) Trino does not guarantee the SELECT-side `RANDOM()` evaluation equals the GROUP-BY-side `RANDOM()` evaluation — semantics are undefined. Engineer copy-pasting hits parse/binding error. |
| Beginner clarity | 4.0 | Skew model ("3 whales → one worker, others idle") + LIMIT-after-GROUP-BY framing land cleanly for a beginner. The broken SQL would be visually plausible to a beginner who would not spot the alias-in-GROUP-BY constraint. |
| Practical applicability | 2.5 | Engineer cannot copy-paste the worked SQL as-is. Diagnosis steps (EXPLAIN ANALYZE VERBOSE → check `inputRows` p50 vs max) ARE actionable; the citation to r18 Step 5 lets the engineer recover the correct two-CTE canonical from the source. Partial credit. |
| Completeness | 4.0 | Covers teammate-correction + diagnosis + concept + a fix attempt + cite. Just the SQL form for the fix is mangled. |

**The teacher's flag is CORRECT**: r18 §1062-1080 canonical (verified by Read of r18 L1066-1086) is the correct THREE-stage form:

```
WITH salted AS (
  SELECT tenant_id, FLOOR(RANDOM()*8) AS salt, event_count  -- per-row salt, NO aggregation
  FROM iceberg.analytics.feature_usage
  WHERE event_date = CURRENT_DATE - INTERVAL '1' DAY
),
partial AS (
  SELECT tenant_id, salt, COUNT(*) AS partial_count          -- salt is now an INPUT column from CTE
  FROM salted
  GROUP BY tenant_id, salt
)
SELECT tenant_id, SUM(partial_count) AS total_count
FROM partial
GROUP BY tenant_id;
```

The responder MUTATED this at lift-time — collapsed salt-assignment + COUNT + GROUP BY into one SELECT. **Per-instance broken-secondary slip** (feedback_responder_broken_secondary_alternative.md family); the resource is correct, the responder mangled it. **NO RESOURCE FIX. NO FIX-A.**

**NEW LOW SOFT WATCH `iter1311-Q1 salted-two-level-GROUP-BY collapsed-to-one-CTE form (GROUP BY on RANDOM()-alias)`**: re-probe 4-8 iters under varied "fix skewed GROUP BY whale tenant" / "salt the key in Trino" / "two-level aggregation example" / "show me the salting pattern" framings; if recurs 2+ with the same collapsed form, escalate to LIGHT FIX-A (inline-defang the one-CTE form right next to the r18 §1066 canonical block with explicit "salt MUST be assigned in a separate CTE first; you cannot compute RANDOM() + GROUP BY + COUNT in one SELECT").

**Topic impact**: query-perf-regression (THINNEST required topic) 4.0107/29 → **3.9895/30 PASSED** (-0.0212, margin +0.4895 above 3.5 threshold). First sub-4 topic-average since iter1283-Q1. 3rd sub-4 SCORE on this topic in 7 iters (iter1283 1.75 / iter1305-Q3 2.375 / iter1310-Q2 2.625 / iter1311-Q1 3.375). The four failures span DIFFERENT pattern families (recipe non-reach / off-target cause / EXPLAIN-variant misroute / broken worked SQL) — not a structural ceiling, just a topic with broad failure surface.

---

### Q2 — Q1/Q2 counts one row per rep (two subqueries+join → single query)

**Score**: **5.0 STRONG PASS** — pin-perfect conditional aggregation / FILTER (WHERE …) canonical.

| Dimension | Score |
|---|---|
| Technical accuracy | 5.0 |
| Beginner clarity | 5.0 |
| Practical applicability | 5.0 |
| Completeness | 5.0 |

Responder gave both equivalent forms: portable `SUM(CASE WHEN quarter='Q1' THEN deal_amount ELSE 0 END)` AND Trino-native `SUM(deal_amount) FILTER (WHERE quarter='Q1')`; `COUNT(*) FILTER (WHERE quarter='Q1')` for counts. Single-pass, no joins/CTEs/subqueries — directly replaces the two-subquery+join shape.

**VERIFIED** via [trino.io/docs/current/functions/aggregate.html](https://trino.io/docs/current/functions/aggregate.html): "The FILTER keyword can be used to remove rows from aggregation processing with a condition expressed using a WHERE clause" + "supported for all aggregate functions". NULL semantics correct (aggregates ignore NULLs by default; FILTER skips rows where predicate is FALSE/NULL).

**Topic impact**: SQL-query-best-practices 4.5893/316 → **4.5906/317 PASSED** (+0.0013, margin +1.0906).

---

### Q3 — dbt schema.yml tests vs tests/.sql

**Score**: **5.0 STRONG PASS** — comprehensive three-way dbt-test-shape canonical.

| Dimension | Score |
|---|---|
| Technical accuracy | 5.0 |
| Beginner clarity | 5.0 |
| Practical applicability | 5.0 |
| Completeness | 5.0 |

Three shapes distinguished correctly:
- **`schema.yml` (generic tests)** = built-in `unique` / `not_null` / `accepted_values` / `relationships` attached to columns under `data_tests:` config.
- **`tests/<name>.sql` (singular tests)** = one-off SELECT returning failing rows (zero rows = pass); NO `{% test %}` wrapper.
- **`tests/generic/<name>.sql` (custom generic tests)** = parameterized `{% test %}...{% endtest %}` macro for cross-model reuse.

When-to-use guidance + worked examples + severity:error default + `dbt build` integration all correct.

**VERIFIED** via [docs.getdbt.com/docs/build/data-tests](https://docs.getdbt.com/docs/build/data-tests) verbatim + [docs.getdbt.com/best-practices/writing-custom-generic-tests](https://docs.getdbt.com/best-practices/writing-custom-generic-tests) (tests/generic/ as 1.0+ canonical placement).

**Topic impact**: complex-SQL-perf-Trino-dbt 4.4228/106 → **4.4282/107 PASSED** (+0.0054). Routed to this topic per recent iter1289-1310 dbt-question routing pattern.

---

### Q4 — Oracle `MAX(COUNT(order_id))` nested aggregate → Trino

**Score**: **4.875 STRONG PASS** — pin-perfect Trino-no-nested-aggregate canonical.

| Dimension | Score |
|---|---|
| Technical accuracy | 5.0 |
| Beginner clarity | 4.75 |
| Practical applicability | 5.0 |
| Completeness | 4.75 |

Responder: (1) Trino rejects `MAX(COUNT(...))` — nested aggregations not allowed; (2) **canonical rewrite**: CTE inner-aggregate → outer `ORDER BY ... LIMIT 1` (returns the row with max count); for scalar max-value use `SELECT MAX(order_count) FROM cte`; (3) per-group variant: `ROW_NUMBER() OVER (PARTITION BY region ORDER BY order_count DESC)` subquery + outer `WHERE rn=1`.

Minor Clar shave: did not explicitly contrast "ORDER BY DESC LIMIT 1 returns the row identity vs `SELECT MAX()` returns just the scalar — pick based on what you need." Minor Compl shave: did not defang the foreign `QUALIFY rn=1` form that an engineer porting from Snowflake/BigQuery might try (Trino 467 has no QUALIFY).

**VERIFIED** at [trino.io/docs/current/functions/aggregate.html](https://trino.io/docs/current/functions/aggregate.html) (aggregates over rows, not over aggregate outputs — must use CTE/subquery/window) + [trino.io/docs/current/sql/select.html](https://trino.io/docs/current/sql/select.html) (WITH clause supported). Oracle's nested-aggregate tolerance is the dialect outlier here.

**Topic impact**: Oracle-PL/SQL-migration 4.5023/288 → **4.5036/289 PASSED** (+0.0013, margin +1.0036).

---

## New watches this iteration

- **NEW LOW SOFT WATCH `iter1311-Q1 salted-two-level-GROUP-BY collapsed-to-one-CTE form`** — re-probe 4-8 iters; LIGHT FIX-A only at 2+ recurrences of the GROUP-BY-on-RANDOM-alias mutation. r18 canonical itself is correct; this is responder-side mutation at lift-time.

## Watches carried (active)

- **HARD WATCH `iter1305-Q3 two-queries-same-WHERE differential-scan-time → columnar projection`** (NOT exercised this iter).
- **LOW WATCH `iter1305-Q4 Oracle TO_NUMBER-mask misattributed as Teradata-ism`** (NOT exercised this iter).
- **LOW SOFT WATCH `iter1308-Q4 false-premise-endorsement-light on ASC-direction NULL-ordering`** (NOT exercised this iter).
- **LOW SOFT WATCH `iter1310-Q1 Postgres-md5-lowercase-vs-Trino-to_hex-uppercase parity`** (NOT exercised this iter).
- **LOW SOFT WATCH `iter1310-Q2 EXPLAIN-ANALYZE-recommended-when-engineer-asks-PRE-RUN-scan-estimate`** (NOT exercised this iter).

## Watches that closed positively in recent iters

- iter1281-1284 perf-triage recall-ceiling SOFT WATCH closed iter1295 (1st re-probe full reach).
- iter1289-Q3 dbt-ephemeral-basics findability HARD WATCH closed iter1290 (1st re-probe full reach).
- iter1300-Q2 broadcast-threshold-direction SOFT WATCH closed iter1303 (1st re-probe full reach).
- iter1301-Q2 non-equi-JOIN-ON CrossJoin HARD WATCH closed iter1302 (1st re-probe full reach).
- iter1304-Q3 dbt-compile pure-offline myth HARD WATCH closed iter1305 (1st re-probe full reach).
- iter1307-Q3 dbt --select/--exclude findability SOFT WATCH closed iter1308 (1st re-probe full reach).

---

## Summary signal for the teacher

**One soft-FAIL on Q1; three strong PASSes on Q2/Q3/Q4. Overall 4.5625 PASS.**

The Q1 SOFT FAIL is a per-instance broken-worked-SQL mutation — the diagnostic content is fully correct and the r18 §1062-1090 canonical IS the correct three-stage salt form. The responder lifted the right resource and mutated it at output time (collapsed two CTEs into one + used GROUP BY on a non-deterministic SELECT alias). **NO RESOURCE FIX, NO FIX-A.** This pattern matches `feedback_responder_broken_secondary_alternative.md` (Haiku nails the lead, mangles the secondary worked example) and `feedback_synthesis_ceiling_stop_churning.md` (Haiku synthesis ceiling on assembling multi-CTE skew patterns on novel domains). The diagnosis + concept + correct cite ARE the load-bearing parts; if the responder consistently reaches r18 Step 5 and the worked SQL keeps coming out mutated, the soft watch will collect the second instance and a LIGHT inline-defang next to the r18 §1066 canonical block would resolve it without a structural rewrite.

**Thinnest-topic trend note**: query-perf-regression continues to band thin (3.9895/30, now dipping below 4.0 on topic-average). Four DIFFERENT failure-family causes in 7 iters (recipe non-reach / off-target cause / EXPLAIN-variant misroute / broken worked SQL) suggest the topic has a broad failure surface rather than a structural recall ceiling — defending it iter-by-iter with targeted watches is the right posture; no top-down rewrite warranted.

**Routing pattern reconfirmed**: dbt-test-shape questions (Q3) land in the complex-SQL-perf-Trino-dbt topic line 754 per recent iter1289-1310 dbt-question pattern; SQL-conditional-aggregation (Q2) and Trino-nested-aggregate rewrites (Q4) land in their established home topics cleanly.
