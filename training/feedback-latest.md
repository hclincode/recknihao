# Judge Feedback — Iteration 1107 (2026-06-26)

**OVERALL: 4.203 PASS** — Breadth durability sweep with TWO source-verified responder one-off defects (Q1 mislabeled rationale, Q2 PARSE-ERROR primary worked-example SQL). Q3+Q4 clean. NO resource defect on either — both confirmed pure responder-side hallucinations (grep audit zero matches in resources). **RECOMMENDATION = NO-OP.**

## Per-question scoring

### Q1 — events partitioned by day, filtered by user_id; ~50k users; bucket on user_id ON TOP of or INSTEAD of day?
**Responder:** Bucketing hashes user_id into N buckets; use ON TOP of day partition: `partitioning = ARRAY['day(occurred_at)', 'bucket(user_id, 32)']`; stresses Trino bucket() is COLUMN-FIRST `bucket(user_id, 32)` (Spark is count-first); start N=32/64; equality filter `user_id='x'` prunes to its bucket.

**SOURCE-VERIFIED DEFECT — mislabeled rationale:**
- Responder stated: *"with 50,000 users, DAY-ONLY partitioning = 50,000 partitions per day × 365 = 18.25M partitions/year."*
- Day-only partitioning yields **ONE** partition per day, NOT 50,000. The 50,000-per-day / 18.25M-per-year explosion arithmetic correctly describes `day × user_id` (or user_id-direct) partitioning — which is the argument FOR bucketing instead of identity-partitioning the user_id. The numbers are right; the label "DAY-ONLY" is wrong. Beginner who reads literally would walk away thinking `day(occurred_at)` alone creates 50K partitions/day.

**Resource grep audit:**
- `Grep "50,000|18.25M"` in `resources/`: zero matches with the "day-only = 50K/day" framing. r10 L874 has the CORRECT counter-form `total partitions per year = tenants × days` (29,200 for 80×365), reinforcing that joint = product, not day-only.
- `Grep "DAY-ONLY"`: zero matches.
- **NOT a resource defect.** Pure responder one-off — wrong rationale label on a recommendation that is otherwise correct.

**Correct facts verified:**
- `bucket(user_id, 32)` Trino Iceberg COLUMN-FIRST syntax — verified per memory pin `reference_trino_bucket_arg_order` (Spark is count-first `bucket(32, col)`).
- ON-TOP-of-day combination + equality-filter prunes to a single bucket — correct Iceberg hidden-partitioning semantics.
- N=32/64 starting range matches r10 L71 "Stay in 16–256" guardrail.

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 3.5 | Recommendation (bucket-on-top, column-first syntax, N=32/64) fully correct. But explicit rationale sentence "day-only partitioning = 50,000 partitions per day" is mathematically false (day-only = 1/day). |
| Clarity | 3.5 | Beginner reading literally would be confused — would they think `day(occurred_at)` already creates 50K partitions per day? The mislabel undermines the "why bucket" justification. |
| Applicability | 4.5 | DDL `ARRAY['day(occurred_at)', 'bucket(user_id, 32)']` is copy-paste-runnable on Trino 467 Iceberg connector. Pruning behavior correctly described. |
| Completeness | 4.0 | Covers ON-TOP framing, bucket count starting range, prune-to-single-bucket on equality. Misses: skew check (if a few power-users dominate, bucket-skew matters), and `EXPLAIN` verification step for confirming bucket pruning. |

**Q1 = 3.875**

### Q2 — 700M events JOINed to 150-row reference table, query 4-5min; is Trino mishandling the small table; can I force it into memory on every worker?
**Responder PRIMARY DIAGNOSIS:** Trino is probably already BROADCASTing the 150-row table; the slowness is the 700M-row fact SCAN, not the join; add a partition filter on occurred_at; verify with EXPLAIN (look for BROADCAST vs PARTITIONED); force with `SET SESSION join_distribution_type = 'BROADCAST'`. **CORRECT.**

**Responder "right pattern" worked-example SQL — PARSE ERROR:**
```sql
SELECT e.user_id, COUNT(*)
FROM iceberg.analytics.events e
WHERE e.occurred_at >= TIMESTAMP '2026-06-01'
JOIN iceberg.analytics.plans r ON e.plan_id = r.id
GROUP BY e.user_id;
```

**SOURCE VERIFICATION — `FROM ... WHERE ... JOIN ... ON ...` is INVALID Trino 467 SQL:**
- Trino SELECT grammar per trino.io/docs/current/sql/select.html:
  ```
  SELECT ... FROM from_item [, ...] [ WHERE ... ] [ GROUP BY ... ] [ HAVING ... ] [ ORDER BY ... ] [ OFFSET ... ] [ LIMIT ... ]
  ```
  where `from_item` recursively includes `from_item join_type from_item ON condition`. **JOIN is part of the FROM clause and must be fully resolved BEFORE WHERE.** The responder's SQL puts WHERE between the first from_item and the JOIN — a syntax error.
- Engineer copy-pasting this hits a Trino parser error like `mismatched input 'JOIN' expecting {<EOF>, '.', ...}`.

**Resource grep audit (correct form is canonical, NOT source of defect):**
- `Grep "FROM .* WHERE .* JOIN"` in `resources/`: zero matches with the broken order on canonical worked-example SQL. The few matches are inline tables describing Oracle-to-Trino rewrites (e.g., r27 outer-join `(+)` translation) — not broken canonicals.
- All canonical join examples in resources use correct `FROM a JOIN b ON ... WHERE ...` order (verified across r18, r22, r24, r28 hundreds of times).
- **NOT a resource defect.** Pure responder hallucination on the worked-example.

**Correct facts verified:**
- `join_distribution_type` valid values per trino.io/docs/current/optimizer/cost-based-optimizations.html: `AUTOMATIC` / `BROADCAST` / `PARTITIONED` — responder cited all three correctly (cross-checked vs r18 L158, L198 invented-values defang).
- Broadcasting a 150-row table is the optimal CBO choice (single-row send, negligible memory) — correctly identified.
- Diagnosis "cost is the fact scan, add partition filter" is the right hypothesis for a 4-5min query against a 700M-row Iceberg table — matches r18 §query-perf-regression playbook.
- EXPLAIN verification suggestion correct (look for `BROADCAST` distribution marker in the join node).

**Classification:** This is a PARSE-ERROR PRIMARY worked-example, not a "broken-secondary-alternative" — more serious than the memory-pin `feedback_responder_broken_secondary_alternative` pattern (which describes BROKEN trailing alternatives after a CORRECT lead). Here the lead conceptual answer is correct, but the canonical paste-ready SQL the engineer would copy is broken. However, the broken construct (WHERE-before-JOIN) is a one-off keyword-juxtaposition slip, NOT something the resource set could be edited to prevent — every JOIN example in the resources is correctly ordered. No FIX-A.

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 2.5 | Conceptual diagnosis (broadcast already happening, fact scan is the cost, partition filter is the lever, session property right values) all correct. But the headline copy-paste SQL is a parse error. |
| Clarity | 4.0 | Diagnosis narrative is clear: "Trino is probably already broadcasting"; "verify with EXPLAIN"; "force with SET SESSION". |
| Applicability | 2.5 | Copy-paste the worked-example → parse error. Engineer must spot the bug and rearrange JOIN before WHERE. SET SESSION line works as-is. |
| Completeness | 4.0 | Covers EXPLAIN verification + session-property override + partition-filter lever. Misses dynamic-filtering callout (often the real cost driver on probe-side scans even with broadcast). |

**Q2 = 3.25**

### Q3 — VARCHAR comma-list 'web,mobile,api'; check exact token 'mobile' without matching 'mobile_beta'; cleaner than LIKE/regex?
**Responder:** `contains(split(platforms, ','), 'mobile')`; trim with `transform(split(...), x->trim(x))` if spaces; UNNEST alternative for grouping; notes `regexp_like(platforms,'(^|,)mobile(,|$)')` also works but split+contains is clearer.

**SOURCE VERIFICATION:**
- `split(varchar, varchar) -> array(varchar)` — verified trino.io/docs/current/functions/array.html.
- `contains(array(T), element T) -> boolean` exact equality match — verified array.html (returns TRUE only on `=` match, NOT pattern). This is exactly the "exact token, no substring" guarantee the engineer asked for; `LIKE '%mobile%'` would match `mobile_beta`, `contains(split(...), 'mobile')` would not.
- `transform(array(T), function(T,U)) -> array(U)` — verified array.html.
- `trim(varchar) -> varchar` — verified string.html.
- `regexp_like(varchar, varchar) -> boolean` with anchored `(^|,)mobile(,|$)` — verified regexp.html; correct workaround pattern.

**No defect. All forms valid Trino 467 and engineer-actionable.**

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 5.0 | All four forms (split+contains, transform+trim wrapper, UNNEST, regexp_like) are valid Trino 467 and correctly avoid the substring false-positive. |
| Clarity | 5.0 | Routes engineer from "cleaner than LIKE/regex" → split+contains as primary, with explicit "if spaces" upgrade path. Beginner-friendly. |
| Applicability | 5.0 | Copy-paste-runnable. Directly answers "exact token without matching mobile_beta". |
| Completeness | 5.0 | Covers primary + spaces variant + UNNEST + regex alternative. No nuance missed. |

**Q3 = 5.000**

### Q4 — revenue per customer: orders JOIN order_line_items then SUM(orders.total_amount) GROUP BY customer — inflated 5-6x
**Responder:** Classic join FANOUT (order row duplicated per line item, total_amount summed once per item); fix = pre-aggregate line items in a CTE then join (GROUP BY order_id), or divide by `COUNT(*) OVER (PARTITION BY order_id)`; verify with `COUNT(DISTINCT order_id)`.

**SOURCE VERIFICATION:**
- Fanout diagnosis correct: `orders JOIN order_line_items ON order_id` produces N rows per order (one per line item); SUM(order.total_amount) on this multiplied table sums `total_amount` N times per order → 5-6× inflation factor consistent with avg ~5-6 line items per order. Verified pattern: matches r07 join-fanout family, r28 §join-correctness guidance.
- Primary fix `WITH agg_li AS (SELECT order_id, SUM(li.amount) AS line_total FROM order_line_items GROUP BY order_id) SELECT o.customer_id, SUM(o.total_amount) FROM orders o LEFT JOIN agg_li ON ... GROUP BY o.customer_id` — correct standard pre-aggregate-in-CTE pattern.
- `COUNT(DISTINCT order_id)` verification: correct sanity check (distinct order count × avg total = expected revenue).
- Minor: responder typo `COUN(*) OVER` (missing T) — not load-bearing, engineer would spot/fix on paste.
- Minor: divide-by-COUNT-OVER alternative works but is fragile vs CTE pre-aggregation (compounding NULL cases on outer joins). Responder lists it as an alternative, not primary — acceptable.

**No defect. Diagnosis + primary fix + verification all correct.**

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 4.5 | Fanout diagnosis + CTE pre-aggregate fix + COUNT(DISTINCT) verification all correct. `COUN(*)` typo (-0.25) and divide-by-count alternative noted without caveats about NULL behavior on outer joins (-0.25). |
| Clarity | 4.75 | Maps "5-6x inflation" → "1 order × 5-6 line items" mental model directly. |
| Applicability | 4.5 | CTE fix is copy-paste-runnable. Divide-by-count alternative has the typo. |
| Completeness | 5.0 | Diagnosis + two fix forms + verification step + an implicit invitation to inspect avg line items per order. |

**Q4 = 4.6875**

## Score table

| Q | Topic | Accuracy | Clarity | Applicability | Completeness | Avg |
|---|---|---|---|---|---|---|
| Q1 | Iceberg partition design + bucketing on top of day | 3.5 | 3.5 | 4.5 | 4.0 | **3.875** |
| Q2 | CBO / join_distribution_type / broadcast vs partitioned + worked-example SQL | 2.5 | 4.0 | 2.5 | 4.0 | **3.250** |
| Q3 | SQL best practices: comma-list token-exact match (split+contains vs regex/LIKE) | 5.0 | 5.0 | 5.0 | 5.0 | **5.000** |
| Q4 | Analytical query patterns: join fanout diagnosis + CTE pre-aggregate fix | 4.5 | 4.75 | 4.5 | 5.0 | **4.6875** |

**Iteration average = (3.875 + 3.250 + 5.000 + 4.6875) / 4 = 4.203 PASS** (margin +0.703)

## Source-verified defects (both responder one-off, NEITHER is a resource defect)

1. **Q1 partition-explosion-rationale mislabel.** "DAY-ONLY partitioning = 50,000 partitions per day × 365 = 18.25M/year" — math is correct for `day × user_id` joint partitioning (50K users × 365 days), wrong label "day-only" (which would yield 1/day). Grep `resources/` for `50,000.*per day`, `DAY-ONLY`, `partitions per day` — zero matches with the mislabeled framing. r10 L874 has the CORRECT counter-form "tenants × days = 29,200 partitions/year". Pure responder rationale slip.

2. **Q2 PRIMARY worked-example SQL parse error.** `FROM events e WHERE e.occurred_at >= TIMESTAMP '2026-06-01' JOIN iceberg.analytics.plans r ON e.plan_id = r.id GROUP BY e.user_id` — JOIN must precede WHERE per Trino SELECT grammar (`from_item` recursive `from_item join_type from_item ON ...` resolves fully before WHERE). Verified vs trino.io/docs/current/sql/select.html. Grep `resources/` for broken-order canonicals — zero matches; all canonical join SQL across r18, r22, r24, r28 use correct `FROM a JOIN b ON ... WHERE ... GROUP BY ...` order. Pure responder keyword-juxtaposition slip. Distinct from `feedback_responder_broken_secondary_alternative` pattern (this is the PRIMARY worked example, not a trailing alternative); but classification is the same — per-instance one-off, not a resource-fixable defect.

## Memory-pin compliance

- `reference_trino_bucket_arg_order` (column-first `bucket(col, N)`): responder cited correctly with explicit Spark-vs-Trino contrast. PIN HOLDS.
- `feedback_responder_broken_secondary_alternative`: Q2 PRIMARY-SQL parse-error is adjacent to but distinct from this pin (primary not secondary). Same scope policy applies — per-instance one-off, no resource fix.
- `feedback_synthesis_ceiling`: residual is a Haiku copy-paste-quality ceiling, not a resource gap. Continue accepting occasional per-instance cost.

## Topic rubric updates

- **Iceberg partition design for SaaS** (Q1): 4.4451/42 → (186.6942 + 3.875)/43 = **4.4318/43 PASSED** (-0.013)
- **CBO / ANALYZE TABLE / Puffin / NDV / join ordering** (Q2 session-property + broadcast/partitioned): 4.6316/18 → (83.3688 + 3.25)/19 = **4.5556/19 PASSED** (-0.076; well above raised 4.5 threshold, margin +0.056)
- **SQL query best practices for OLAP** (Q3 + Q4 secondary): 4.471/157 → (701.947 + 5.000 + 4.6875)/159 = **4.475/159 PASSED** (+0.004)
- **Analytical query patterns Iceberg+Trino** (Q4 fanout primary): 4.4197/59 → (260.7623 + 4.6875)/60 = **4.4242/60 PASSED** (+0.005)

ALL required topics REMAIN PASSED.

## Teacher guidance

**RECOMMENDATION = NO-OP.** No resource edits.

Justification:
- Neither defect is sourced from a resource file (grep audit confirmed zero matches for both broken forms).
- Q1 "DAY-ONLY = 50K/day" is a one-off rationale label slip; resources already carry the CORRECT counter-arithmetic at r10 L874 ("tenants × days = 29,200/year"). Adding a defang card "day-only ≠ N-per-day, day-only = 1-per-day" risks the `feedback_new_card_over_attracts_adjacent` regression on neighboring partition questions and would not durably block a keyword-juxtaposition slip.
- Q2 PRIMARY-SQL parse error (WHERE-before-JOIN) is a one-off keyword-order slip; resources have hundreds of correctly-ordered FROM-JOIN-WHERE-GROUP-BY canonicals across r18, r22, r24, r28. Adding an explicit "JOIN before WHERE" router card would not help — the responder's failure is in synthesis ordering, not in finding the canonical (the canonical correct form is everywhere).
- Both defects fall under the `feedback_synthesis_ceiling_stop_churning` umbrella: Haiku synthesis quality ceiling on novel multi-step writeups; closing one specific failure mode does not durably block a different keyword-juxtaposition slip in the next domain.
- Iter average +0.703 above PASS threshold, all topics retain PASS margins (CBO row drops to +0.056 above the raised 4.5 threshold — thin but not breaching; will recover with the next clean breadth datapoint).

**Optional next-sweep probes (no edit, just probe):**
- Q1-style partition-rationale re-probe in different domain (e.g., events by `tenant_id × day` instead of `user_id × day`) to confirm the "DAY-ONLY = 50K/day" mislabel does not recur — if it does, escalate to LIGHT FIX-A.
- Q2-style broadcast/partitioned join re-probe with a NEW worked-example domain (e.g., fact JOIN small currency table) to confirm WHERE-before-JOIN parse-error does not recur — if it does, escalate to LIGHT FIX-A (likely a defang row in r18 or r28 listing the WRONG SQL inline-marked, per `feedback_defang_donotwrite_snippets` pattern).
- Federation row (4.50244/312 fragile-PASS per iter1097) — leave untouched as usual.
- Storage-tiering 7th datapoint (3.5625/6 still thinnest), dbt-model-contracts 7th angle (4.391/6), cost-considerations 21st angle (4.2129/20) — continue durability probes when convenient.

NO state.json bump (already 1107, already passed:true).
NO federation re-probe (4.50244/312 fragile-PASS per iter1097).
NO commit beyond rubric+feedback.

## Pattern observation

Two distinct responder-side defects in one sweep — both in the "synthesis quality on novel paste-ready SQL" failure class:
- Q1 = rationale arithmetic mislabel (the RIGHT numbers under the WRONG label).
- Q2 = SQL clause-order keyword juxtaposition (the RIGHT clauses in the WRONG order).

Both share the signature: conceptual answer correct, the engineer-facing artifact (the snippet they would copy) has a small but load-bearing bug. Resources can't durably block these via additive content; they are Haiku synthesis-quality ceiling. The iter avg passes because Q3 + Q4 are clean. Pattern matches `feedback_synthesis_ceiling_stop_churning` — accept the occasional Q cost, do not churn the resources.
