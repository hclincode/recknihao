# Iteration 1303 — Judge Feedback

**Phase**: extended (pass-loop)
**Overall iter score**: **4.5625 STRONG PASS** ((4.75 + 3.75 + 4.875 + 4.875) / 4)
**Pattern this iter**: iter1300-Q2 broadcast-threshold-direction FIX-A REACHED on 1st re-probe (soft watch CLOSES); Q2 broken-secondary-worked-query slip (nested-aggregate-window pattern) — 10th instance in the documented `feedback_responder_broken_secondary_alternative.md` family, per-instance NO FIX-A; Q3/Q4 strong clean passes; Oracle PL/SQL → dbt + Trino topic CROSSES 4.5.

---

## Per-question scores

### Q1 — broadcast-OOM threshold direction RE-PROBE → 4.75 STRONG PASS

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | 5.0 | "Raising `join_max_broadcast_table_size` makes OOM WORSE" CORRECT; `SET SESSION join_distribution_type='PARTITIONED'` CORRECT fix |
| Beginner clarity | 4.5 | Clear "you have the logic BACKWARDS" framing + dbt `pre_hook` form |
| Practical applicability | 5.0 | Engineer has exact next step (PARTITIONED session prop, or dbt pre_hook for per-model fix) |
| Completeness | 4.5 | PARTITIONED named; did not explicitly call out "LOWER the threshold" as the alternative threshold-direction-aware fix |

**iter1300-Q2 BROADCAST-THRESHOLD-DIRECTION FIX-A — REACHED on 1st re-probe. SOFT WATCH CLOSES.**

The iter1300-Q2 FIX-A added a DIRECTION-MATTERS callout to r28 §8A.2 (lower-not-raise + defang of the wrong "raise to 500MB to fix OOM" recommendation). The iter1303-Q1 responder now correctly states:
- Raising `join_max_broadcast_table_size` worsens the OOM (more/larger tables broadcast → more memory pressure per node).
- The correct fix is `SET SESSION join_distribution_type='PARTITIONED'` (hash-shuffle both sides, no single node bears full load).

VERIFIED via WebSearch: LOWERING the threshold reduces broadcast cap (more PARTITIONED → less per-node memory); RAISING allows MORE broadcasting → worsens OOM. PARTITIONED hash-shuffle is the canonical alternative.

The responder gave the PARTITIONED fix but did NOT explicitly mention LOWER-the-threshold as the threshold-direction-aware alternative — this is acceptable (PARTITIONED is the primary canonical answer for broadcast-OOM remediation, threshold-direction is one of several levers). Minor Clar shave for that omission.

Pattern matches 1st-re-probe FIX-A reach streak: iter1302 MOD + iter1302 BETWEEN-CrossJoin + iter1272 bloom-CREATE-467 + iter1290 ephemeral-basics.

---

### Q2 — running-total window (ROWS BETWEEN UNBOUNDED PRECEDING) → 3.75 PASS

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | 3.5 | Syntax claim CORRECT ("identical in Trino, copy from Postgres directly") BUT worked query has window-arg-not-in-GROUP-BY analysis error |
| Beginner clarity | 4.0 | "Copy from Postgres directly" framing is clear and beginner-routable for the syntax-only question |
| Practical applicability | 3.5 | Engineer who extracts only the syntax claim → fine. Engineer who copies the worked query → analysis error, debug time lost. Mixed. |
| Completeness | 4.0 | Lead correct + secondary worked example provided (but broken) |

**TEACHER FLAG CONFIRMED — NESTED-AGGREGATE-WINDOW BUG IN WORKED QUERY.**

The teacher flag is accurate. Two distinct findings:

**(A) The SYNTAX answer is correct.** ROWS-frame window syntax `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` is identical Postgres ↔ Trino 467. This is the engineer's actual stated question and the lead is right.

**(B) The WORKED QUERY has a real analysis-error bug.** The responder wrote:
```sql
SELECT customer_id, month_start,
       SUM(amount) AS monthly_spend,
       SUM(amount) OVER (PARTITION BY customer_id ORDER BY month_start
                         ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative_spend
FROM transactions
GROUP BY customer_id, month_start
ORDER BY ...
```
With `GROUP BY customer_id, month_start`, bare `amount` inside `SUM(amount) OVER(...)` is neither a group key nor an aggregate — Trino analysis fails with "amount must be an aggregate expression or appear in GROUP BY clause." Window functions evaluate AFTER grouping, so window arguments must be aggregates or group keys when GROUP BY is present.

**The CORRECT form is the NESTED-AGGREGATE WINDOW**:
```sql
SUM(SUM(amount)) OVER (PARTITION BY customer_id ORDER BY month_start
                       ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative_spend
```
Inner `SUM(amount)` = per-month group total (resolves the GROUP BY). Outer `SUM(...) OVER` = accumulates the grouped sums across months. Same pattern as iter1290 percent-of-total `SUM(SUM(mrr)) OVER ()` — already canonicalized in resources.

VERIFIED via WebSearch + Trino docs: `SUM(SUM(x)) OVER (...)` is the canonical Trino pattern for window-over-grouped-rows; alternative is a CTE/subquery pre-aggregate + window in outer (`WITH monthly AS (SELECT customer_id, month_start, SUM(amount) AS m FROM transactions GROUP BY ...) SELECT *, SUM(m) OVER (PARTITION BY customer_id ORDER BY month_start ROWS ...) FROM monthly`).

**Classification — `feedback_responder_broken_secondary_alternative.md` family (10th instance).** Same Haiku pattern: lead nailed, "for-completeness" alternative form broken. Prior instances: iter936 window-in-GROUP-BY / iter943 PERCENTILE_CONT / iter948 price-suffix menu / iter950 nested-aggregate max_by / iter954 TO_CHAR-wrong-codes / iter1013 ORDER-BY-ungrouped / iter1019 TABLESAMPLE-after-WHERE / iter1020 regexp_extract-comma / iter1302 {{this}}-INTERVAL placement.

Per the memory pin: "scope each as per-instance one-off re-probe NOT a resource defect, don't churn (no single resource fix for responder padding)."

**Per-instance broken-secondary slip — NO FIX-A on first occurrence.** Elevate to soft watch since the nested-aggregate-window form has a canonical anchor at iter1290 percent-of-total — if recurs the FIX-A should add a copy-attractive **"running total over per-group monthly aggregates"** worked card co-located with the iter1290 percent-of-total SUM(SUM(x)) OVER () canonical (only window-frame style differs: () vs ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW).

**NEW SOFT WATCH `iter1303-Q2 SUM(SUM(x)) OVER ROWS-frame running-total-over-grouped-data broken-secondary-worked-query`**: re-probe under varied "monthly aggregate + running total in one query" / "per-customer cumulative spend" / "running total over GROUP BY" framings 4-8 iters. If recurs with same window-arg-not-in-GROUP-BY error, escalate to LIGHT FIX-A.

---

### Q3 — dbt deps / packages.yml workflow → 4.875 STRONG PASS

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | 5.0 | dbt deps as the install command; dbt_packages/ gitignored; packages.yml committed; CI runs dbt deps before dbt run — all VERIFIED |
| Beginner clarity | 5.0 | node_modules analogy is exact + beginner-routable |
| Practical applicability | 5.0 | Engineer has exact next steps: run dbt deps, gitignore dbt_packages/, fix CI to run dbt deps before dbt run/build |
| Completeness | 4.5 | Missing: package-lock.yml (dbt 1.7+) commit guidance for reproducible builds — minor |

VERIFIED:
- [docs.getdbt.com/reference/commands/deps](https://docs.getdbt.com/reference/commands/deps) — dbt deps pulls dependencies from packages.yml, installs to dbt_packages/, explicit command not auto-run by dbt run.
- [docs.getdbt.com/docs/build/packages](https://docs.getdbt.com/docs/build/packages) — "by default, this directory is ignored by git to avoid duplicating code."
- [docs.getdbt.com/faqs/Git/gitignore](https://docs.getdbt.com/faqs/Git/gitignore) — canonical `.gitignore` lists `dbt_packages/` + `target/` + `logs/`.

node_modules analogy is technically apt + beginner-clear: packages.yml is source-of-truth (committed, like package.json); dbt_packages/ is installed artifact (gitignored, like node_modules). CI ordering (dbt deps → dbt run/build) is the canonical pipeline shape.

---

### Q4 — Oracle `order_date + 30` → Trino → 4.875 STRONG PASS

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | 5.0 | Both `date_add('day', 30, order_date)` and `order_date + INTERVAL '30' DAY` correct; `date + 30` correctly flagged as type error |
| Beginner clarity | 5.0 | Oracle implicit-coercion vs Trino explicit-required framing crisp |
| Practical applicability | 5.0 | Two syntax options + use-case routing (date_add for variable N, INTERVAL for constant N) |
| Completeness | 4.5 | Missing: subtraction form `date_add('day', -30, order_date)` / `current_date - INTERVAL '7' DAY` — minor |

VERIFIED via [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html):
- `date + 30` is a type error in Trino 467 (no implicit `date + INTEGER → date + days` coercion).
- `date_add(unit, value, timestamp)` canonical form: `date_add('day', 1, timestamp '2020-03-01 00:00:00')`.
- Operator form: `date '2012-08-08' + interval '2' day` valid.
- Use-case routing CORRECT: date_add accepts variable expression for value; INTERVAL literal is constant-only at parse time.

Consistent with iter1162 / iter1289 / iter1300 Oracle date-arithmetic canonical.

---

## Pattern across iter1303 answers

### Hits

- **iter1300-Q2 broadcast-threshold-direction FIX-A REACHED on 1st re-probe.** 5th consecutive 1st-re-probe FIX-A REACH in the recent streak (iter1302 MOD, iter1302 BETWEEN-CrossJoin, iter1272 bloom-CREATE-467, iter1290 ephemeral-basics, iter1303 broadcast-threshold). Soft watch CLOSES.
- **Oracle PL/SQL → dbt + Trino topic crosses 4.5** with the 2-datapoint Q3+Q4 contribution (4.4974 → 4.5001 across 280 datapoints). First crossing of 4.5 — the topic now sits comfortably above threshold.
- **No imported-prior slips, no over-warning folklore, no fabrication, no false-premise endorsement** across all 4 questions.

### Misses

- **Q2 broken-secondary-worked-query slip** — 10th instance of the documented `feedback_responder_broken_secondary_alternative.md` family. Lead correct (syntax-identity), worked query has nested-aggregate-window analysis error (`SUM(amount) OVER(...)` with GROUP BY where `amount` is not in GROUP BY and not aggregated; correct is `SUM(SUM(amount)) OVER(...)`). Per the memory pin this is per-instance NOT a resource defect — Haiku synthesis ceiling when constructing copy-pasteable examples with GROUP BY + window combinations. **NO FIX-A on 1st occurrence**, soft watch only.

### Carried watches (for teacher tracking)

- iter1302-Q3 `{{this}} - INTERVAL` placement broken-secondary (didn't recur this iter; carry forward, re-probe in 2-4 iters)
- iter1299-Q3 this-guard
- iter1298-Q2 metadata-tables
- iter1297-Q4 false-premise (positive signals accumulated; iter1300-Q4 + iter1301-Q4 + iter1302-Q4 all defended correctly)
- iter1296-Q1 / iter1296-Q3 / iter1295-Q2 / iter1294-Q4 / iter1290-Q3 / iter1289-Q2 / iter1289-Q4
- **NEW** iter1303-Q2 nested-aggregate-window-over-grouped-data broken-secondary (re-probe 4-8 iters)

### Closed watches

- **iter1300-Q2 r28 §8A.2 Pattern A raise-vs-lower threshold confusion + responder spill-causality flip** — broadcast-threshold-direction side of the watch CLOSES on 1st re-probe (Q1 this iter). Spill-causality side has not been re-probed yet; carry forward as `iter1300-Q2 spill-causality flip` for separate re-probe.

---

## Specific guidance to teacher

**No FIX-A recommended this iter.**

**Q1 (4.75)** — FIX-A from iter1300 landed cleanly; do NOT add more direction-anchors to r28 §8A.2 (over-saturation risk per `feedback_new_card_over_attracts_adjacent.md`). The single iter1300 FIX-A is sufficient; the responder now correctly says raise-worsens.

**Q2 (3.75)** — Resource-source check NEEDED but expected CLEAN. The lead syntax answer is correct (resources teach window-frame syntax accurately). The worked-query bug is a Haiku synthesis ceiling on GROUP BY + window combinations, NOT a resource defect. iter1290 percent-of-total `SUM(SUM(mrr)) OVER ()` is the canonical anchor for nested-aggregate window — keyword-magnet "running total over monthly aggregate" may not route there cleanly since iter1290 used the unframed `OVER ()` form not the ROWS-frame form. If iter1303-Q2 watch recurs in 4-8 iters, the LIGHT FIX-A should add a co-located ROWS-frame variant: **"running total over per-customer monthly aggregate: `SUM(SUM(amount)) OVER (PARTITION BY customer_id ORDER BY month_start ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)`"** near the iter1290 percent-of-total canonical, with a one-liner "for GROUP BY + window: arg of OVER must be aggregate or group key, wrap in outer aggregate" anchor.

**Q3 (4.875)** — No action. Minor opportunity: add a one-line `package-lock.yml` reference to whatever dbt-workflow card exists (commit lock + packages.yml, gitignore dbt_packages/). Non-load-bearing.

**Q4 (4.875)** — No action. The Oracle date-arithmetic canonical is well-anchored across iter1162 / iter1289 / iter1300 / iter1303.

---

## Status

- Iter score **4.5625 STRONG PASS**.
- All rubric topics PASSED with margin.
- 5 consecutive 1st-re-probe FIX-A REACHES streak intact.
- 1 new soft watch (Q2 nested-aggregate-window broken-secondary, family-typed per-instance slip).
- Pass-loop continues. No teacher action required this iter.
