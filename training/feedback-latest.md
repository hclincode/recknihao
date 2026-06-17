# iter982 Judge Feedback — EXTENDED PHASE breadth sweep

**OVERALL 4.5547 STRONG PASS** (Q1 4.3125 / Q2 4.59375 / Q3 4.5625 / Q4 4.75 = 18.21875/4 = 4.5547; margin +1.05). OVERALL AVERAGE governs — NO per-Q veto.

All dialect/DDL/logic claims VERIFIED BOTH DIRECTIONS vs trino.io/docs/467 (NOT resources/):
- connector/iceberg.html — CREATE uses `WITH (partitioning = ARRAY[...])`, ALTER uses `SET PROPERTIES partitioning = ARRAY[...]`, bucket transform `bucket(col, N)` column-first. `PARTITIONED BY (...)` is Spark/Hive and does NOT parse in Trino. CONFIRMED.
- functions/array.html — `contains(x, element) → boolean` "Returns true if the array x contains the element." CONFIRMED.
- functions/datetime.html — `date_diff(unit, ts1, ts2)` returns `ts2 - ts1` in whole units (day-aware, complete units); later arg third → positive. CONFIRMED.
- ANY() array-membership (Postgres) is NOT Trino — Trino's `= ANY (SELECT...)` is a quantified subquery comparison, not array membership; `col = ANY(array_col)` is a parse error. Responder's "not Trino" is correct.

Prod stack (Trino 467 Iceberg + Hive Metastore on-prem MinIO + Spark ingestion + dbt) — all answers fit.

---

## Q1 — slow `GROUP BY user_id COUNT(*)` — 4.3125 — THE KEY CHECK (PARTITIONED-BY foreign-DDL, aside slip)
PERF LEAD CORRECT: "COUNT(*) is NOT the problem — it's the full scan"; filter raw cols in WHERE before GROUP BY (`WHERE occurred_at >= current_date - INTERVAL '30' DAY` → partition pruning); EXPLAIN `constraint=` check. All accurate.

**DEFECT (aside only): twice writes the CREATE-table partition form as `PARTITIONED BY day(occurred_at)`** ("If your events table is partitioned by day (PARTITIONED BY day(occurred_at))..." and "start with PARTITIONED BY day(occurred_at)"). VERIFIED FOREIGN DDL — Trino 467 Iceberg CREATE uses `WITH (partitioning = ARRAY['day(occurred_at)'])`; `PARTITIONED BY (...)` is Spark/Hive and would NOT parse.

- **RESOURCE-vs-SLIP = RESPONDER imported-Spark-prior SLIP, NOT a resource defect.** r09 L127 DO-NOT-WRITE bans `PARTITIONED BY` findably; r09 L73 teaches `WITH(partitioning=ARRAY[...])`.
- **3rd lifetime PARTITIONED-BY instance (iter945 Q2 + iter977 Q2 + iter982 Q1), NON-CONSECUTIVE** (iter978 partition-DDL re-probe was CLEAN — used correct ALTER SET PROPERTIES).
- **INTERNAL INCONSISTENCY confirmed: Q3 of THIS SAME response uses the CORRECT `ALTER TABLE ... SET PROPERTIES partitioning = ARRAY['identity(plan_name)']` form.** The responder knows the right syntax; it slipped only on the CREATE form in Q1's aside. Reinforces this is an intermittent imported-prior slip, not a knowledge/resource gap.
- Acc 3.75 / Clar 4.5 / App 4.5 / Comp 4.5.

## Q2 — "event B within N days of event A" without slow self-join — 4.59375 CLEAN (modulo minor comp)
`(SELECT user_id, MIN(occurred_at) AS signup_ts FROM events WHERE event_type='signup' GROUP BY user_id) s INNER JOIN events p ON s.user_id=p.user_id AND p.event_type='purchase' AND date_diff('day', s.signup_ts, p.occurred_at) BETWEEN 0 AND 7`.
- **date_diff('day', signup_ts, purchase_ts) BETWEEN 0 AND 7 VERIFIED CORRECT** — day-aware, later-arg-third → positive, BETWEEN inclusive, NO ts-minus-ts (correctly avoided). MIN-signup subquery + INNER JOIN is sound and avoids the slow N×N self-join the engineer feared.
- **Minor comp ding (NOT a defect):** the Q asked "how many users" (a single count / `COUNT(DISTINCT user_id)`), but the answer returns per-user purchase counts. The date_diff windowing logic — the engineer's actual concern — is fully correct.
- Acc 4.75 / Clar 4.75 / App 4.625 / Comp 4.25.

## Q3 — ACTIVE subscriptions by plan_name scans too much — 4.5625 CLEAN (modulo minor comp)
`GROUP BY plan_name COUNT(*)` + scan diagnosis (partition pruning works only on partition cols; file-level min/max less effective on a non-partition col with random row order) + fixes: `ALTER TABLE iceberg.subscriptions SET PROPERTIES partitioning = ARRAY['identity(plan_name)']` (low cardinality) or `bucket(plan_name, 16)` (high), or `ARRAY['day(created_at)', 'identity(plan_name)']`, or a daily rollup.
- **ALTER SET PROPERTIES partitioning form VERIFIED CORRECT Trino 467** (contrast Q1's wrong PARTITIONED BY — same response, right form here). bucket(plan_name,16) column-first correct. Diagnosis is accurate.
- **Minor comp ding:** dropped the `WHERE status='active'` the question implied ("ACTIVE subscriptions"). The partition/scan reasoning is the substance and is correct.
- Acc 4.75 / Clar 4.625 / App 4.625 / Comp 4.25.

## Q4 — array `tags` membership; does Trino-on-Iceberg understand arrays? — 4.75 CLEAN
`WHERE contains(tags, 'electronics')`.
- **`contains(array, element) → boolean` VERIFIED valid 467.** Postgres `col = ANY(array)` correctly noted as NOT Trino (parse error). Multi-tag AND/OR composition correct. `CROSS JOIN UNNEST(tags) AS t(tag)` per-tag-row alternative correct.
- Acc 4.75 / Clar 4.75 / App 4.75 / Comp 4.75.

---

## SCOPE / TICS
- **Q1 PARTITIONED-BY foreign-DDL = RESPONDER imported-Spark-prior SLIP (aside only), NOT a resource defect** — r09 L127 bans it findably, r09 L73 teaches the correct WITH(partitioning=ARRAY[...]). 3rd lifetime instance (iter945 Q2 + iter977 Q2 + iter982 Q1), NON-CONSECUTIVE. INTERNAL INCONSISTENCY: Q3 same response uses the correct ALTER SET PROPERTIES form → responder knows the syntax, slipped on the CREATE aside.
- All other tics CLEAN: no QUALIFY / false-mechanism-semi-join-mislabel / MAX(varchar)-as-latest / percent_rank-inversion / fabricated-fn-or-rule / broken-secondary / false-justification / unsupported-perf-claim / mid-churn / missing-CTE-col / JOIN-fan-out (Q2 used a deliberate constrained JOIN, not a fan-out bug) / ts-minus-ts (Q2 correctly uses date_diff).

## RECOMMENDATION = DEFAULT NO-OP
Margin +1.05; both non-clean items are responder slips/minor-comp, no resource or findability gap. The PARTITIONED-BY slip is the 3rd lifetime instance but NON-CONSECUTIVE and confined to a CREATE-form aside while the response simultaneously demonstrates the correct ALTER form — re-probe-don't-churn. Consider a LIGHT defang near r09 L127 ONLY if PARTITIONED-BY recurs CONSECUTIVELY (2-in-2) on the next sweep.

Re-probe next sweep: (a) another CREATE-partitioned-table / "how do I partition this table" Q — watch whether `WITH (partitioning = ARRAY[...])` is emitted unaided vs the PARTITIONED-BY slip; (b) another array-membership / array-column Q (contains / UNNEST stay correct).

Federation r22 §13.x hard-locked — NOT probed (OVERRIDDEN). NO resource edits. DID NOT bump training/state.json (already 982; passed=true preserved; final_iterations_remaining 0).
