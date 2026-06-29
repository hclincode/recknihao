# Iteration 1257 — Judge Feedback

## Verdict

**Overall: 4.734 STRONG PASS — TWO aged watches CLOSE cleanly + ONE FIX-A REACHED + ONE strpos-3-arg ceiling navigated on the function (arithmetic slip in worked example).** Q1 (4.9375) RE-PROBE of the iter1256 EXISTS WHICH-X router FIX-A — **REACHED CLEANLY, 1st re-probe close**; responder debunked the DBA myth, named the simple-equality EXISTS→SemiJoin decorrelation as reliable, kept the failing-shape list intact, gave EXPLAIN-grep decision tool. Q2 (5.0) RE-PROBE of the iter1238 broadcast-hedge watch under the SMALL-DIM shape — **CLOSES cleanly**; responder led with BROADCAST for the 5K-row dim (correct direction), surfaced join_distribution_type/AUTOMATIC/join_max_broadcast_table_size mechanics. Q3 (5.0) percent-of-grand-total via `SUM(SUM(revenue)) OVER ()` — pin-perfect canonical, NULLIF div-by-zero guard + PARTITION BY variant covered. Q4 (4.0) Trino 3-arg `strpos(s, sub, N)` for Nth-occurrence — **iter1215 strpos-3-arg CEILING navigated correctly on the FUNCTION + lead return value (8)**, but the worked-example position-arithmetic has two off-by-N slips (third_slash=9 should be 8; strpos(...,-1)=17 should be 14) — dialect-correct minus arithmetic-clarity ding.

---

## Aged-watch closure ledger

| Watch (origin iter) | Outcome | Evidence |
|---|---|---|
| iter1256 Q3 EXISTS WHICH-X router FIX-A (r28 §2 simple-equality EXISTS reliably decorrelates → leave alone) | **REACHED — 1st re-probe CLOSES** | Q1 explicitly applied the router: "DOES NOT apply to simple equality EXISTS; do not rewrite. Trino 467 RELIABLY decorrelates into a SemiJoin (PR #1415). EXISTS/IN/JOIN same plan. The DBA's blanket rule is an Oracle/Postgres row-engine habit, overly broad for Trino. Correlated subqueries ARE slow only when non-equality, aggregate, LIMIT, NOT-EXISTS." Cited r28 §2 router. NO over-warning, NO "rewrite anyway just to be safe" reversal. Verbatim per the FIX-A SPEC. |
| iter1238 Q3 broadcast-hedge on SMALL dim (PARTITIONED-safer wrong-direction recall) | **CLOSES** | Q2 (5K-row × 600M-row, the original watched shape) responder led with BROADCAST not PARTITIONED: "Broadcast the small dimension. 5K rows ~50-100KB is tiny, textbook broadcast. AUTOMATIC default. SET SESSION join_distribution_type='BROADCAST'. join_max_broadcast_table_size default 100MB. Fall back PARTITIONED only if broadcast OOMs." Direction inverted from the iter1238 hedge; small-dim canonical reached. |

**Watches still OPEN going into iter1258:** iter1255 bloom-CREATE; iter1255 INSERT-OVERWRITE-broken-secondary; iter1253 regexp_extract-2arg; iter1248 MATCH_RECOGNIZE; iter1241 concat-auto-coerces; iter1236 rn=1-within-batch; iter1215 strpos-3-arg CEILING (re-tagged this iter — function navigated, but example-arithmetic slip; downgrade severity to "soft, arithmetic-clarity" not function-recall); iter1229 @v1-Spark.

---

## Per-question detail

### Q1 — Senior DBA blanket-claim "never use correlated subqueries in Trino, rewrite to join"; simple-equality EXISTS

**Score: 4.9375** (Acc 4.75 / Clar 5.0 / Prac 5.0 / Compl 5.0)

**Pin-perfect FIX-A reach on the 1st re-probe.** The query shape:
```sql
SELECT a.account_id FROM accounts a
WHERE EXISTS (SELECT 1 FROM logins l WHERE l.account_id = a.account_id);
```
is the **textbook simple-equality EXISTS that Trino 467 reliably decorrelates to a SemiJoin**. The DBA's blanket rule is an Oracle/Postgres row-engine habit. Responder nailed every load-bearing element:

- **Direct answer**: "No. Senior's rule does NOT apply to simple equality EXISTS. Do not rewrite." — debunks the myth without inverting to "EXISTS always fine."
- **Mechanism**: Trino decorrelates EXISTS/IN with equality correlation into a `SemiJoin` operator at the same physical plan as `INNER JOIN ... DISTINCT` or `IN (SELECT ...)`. Verified at [r28 §849 conversion table](/Users/hclin/github/recknihao/resources/28-complex-sql-performance-trino-dbt.md) + [r23 §2793 physical-operators](/Users/hclin/github/recknihao/resources/23-sql-best-practices-olap.md): *"you want `SemiJoin` in your EXPLAIN output for IN / EXISTS / NOT EXISTS / NOT IN"*.
- **Failing-shape list preserved**: "Correlated subqueries ARE slow only when: non-equality correlations (<, >, BETWEEN, !=), aggregate referencing outer cols, LIMIT/TopN in subquery body → CorrelatedJoin O(N×M)." This is the FIX-A's required "rewrite ONLY when" branch, intact.
- **Verify recipe**: `EXPLAIN` → look for `SemiJoin` (fast, leave it) vs `CorrelatedJoin` (slow, rewrite). The exact decision tool from the FIX-A spec.
- **Cited r28 §2 WHICH-X ROUTER** — the new card lands and the responder routes to it cleanly.

**Minor acc nick (-0.25):** The "(PR #1415)" attribution is slightly misaimed — [trinodb/trino PR #1415](https://github.com/trinodb/trino/pull/1415) added decorrelation specifically for **`LIMIT`/TopN-clause** subqueries (verified via WebFetch of [trino.io/episodes/7.html](https://trino.io/episodes/7.html): *"PR #1415 added capability for decorrelation of a subquery containing a LIMIT or ORDER+LIMIT (i.e. TopN) clauses"*). The simple-equality EXISTS→SemiJoin transformation predates that PR and is in the core decorrelation framework (TransformCorrelatedScalarSubquery + TransformCorrelatedInPredicateToJoin + TransformCorrelatedSemiJoin family). Load-bearing fact correct (Trino reliably decorrelates simple-equality EXISTS); just the PR-number footnote points to a sibling rule. Engineer reads "PR #1415" as proof-of-existence and arrives at the right action regardless — not a defect, recall-precision shave.

**iter1256 EXISTS WHICH-X router FIX-A REACHED, watch CLOSES** — first re-probe close on the iter1256 LIGHT FIX-A. 2-instance over-warning class (iter1230 Postgres-instinct + iter1256 DBA-blanket) now defanged. Continue to re-probe under varied framings (e.g., "Postgres EXISTS with subquery filter / migrated EXISTS with multi-column equality / IN with derived list") within 4-8 iters to confirm durability.

**Verifies against:**
- [trino.io/episodes/7.html](https://trino.io/episodes/7.html) — Trino podcast ep 7 on decorrelation
- [trinodb/trino PR #1415](https://github.com/trinodb/trino/pull/1415) — LIMIT/TopN decorrelation (sibling rule)
- [trinodb/trino #21859](https://github.com/trinodb/trino/issues/21859) — NOT EXISTS slow path (the failing-shape exclusion)
- [r28 §849 conversion table](/Users/hclin/github/recknihao/resources/28-complex-sql-performance-trino-dbt.md) — correct EXISTS→SemiJoin classification
- r28 §2 WHICH-X router (iter1256 FIX-A) — responder cited

---

### Q2 — 600M orders × 5K products on product_id, spilling 40 min; broadcast or partition?

**Score: 5.0** (Acc 5.0 / Clar 5.0 / Prac 5.0 / Compl 5.0)

**Pin-perfect BROADCAST-for-small-dim canonical.** The shape (5K-row build = 50-100KB, 600M-row probe) is the textbook broadcast case. Responder reached every load-bearing element:

- **Direct answer**: "Broadcast the small dimension. 5K rows ~50-100KB is tiny, textbook broadcast."
- **Mechanics**: 100KB build << default 100MB broadcast cap → AUTOMATIC will pick BROADCAST IF the CBO sees the row count + size. Need ANALYZE on both tables to populate Iceberg Puffin stats / Hive table stats so the optimizer doesn't fall back to PARTITIONED out of caution.
- **Three forms covered**:
  1. **AUTOMATIC default** (after ANALYZE) — CBO picks broadcast for small side.
  2. **Force**: `SET SESSION join_distribution_type = 'BROADCAST'` — valid value verified at [trino.io/docs/467/admin/properties-general.html](https://trino.io/docs/467/admin/properties-general.html): *"Allowed values: AUTOMATIC, PARTITIONED, BROADCAST. Default: AUTOMATIC."*
  3. **Cap raise** (only needed if dim >100MB): `SET SESSION join_max_broadcast_table_size = '500MB'` — default 100MB verified at [trino.io/docs/467/optimizer/cost-based-optimizations.html](https://trino.io/docs/467/optimizer/cost-based-optimizations.html): *"By default, the replicated table size is capped to 100MB."* Engineer's 100KB dim is way under, so default cap is plenty.
- **Verify recipe**: `EXPLAIN (TYPE DISTRIBUTED)` → look for `Join[INNER][BROADCAST]` / `RemoteExchange[REPLICATE]` (broadcast confirmed) NOT `RemoteExchange[REPARTITION]` (partitioned).
- **Fall-back**: if broadcast OOMs (it shouldn't on 100KB but if column widths balloon the build side), `SET SESSION join_distribution_type='PARTITIONED'` then RESET. Symmetric defang.
- **Diagnoses the 40-min spill correctly**: the AUTOMATIC default may have fallen back to PARTITIONED because CBO couldn't see the dim's size (missing ANALYZE) → 600M hash-shuffled against 5K rows that should have been a broadcast → spill grind. ANALYZE both tables to fix.

**iter1238 broadcast-hedge watch CLOSES** — the SMALL-DIM shape was the OPEN direction; responder led BROADCAST correctly, no "PARTITIONED safer for both" hedge. Symmetric with iter1256 Q2's both-LARGE → PARTITIONED canonical: responder now demonstrates both directions of the join-distribution decision tree correctly under different shapes.

**Verifies against:**
- [trino.io/docs/467/admin/properties-general.html](https://trino.io/docs/467/admin/properties-general.html) — join_distribution_type allowed values + AUTOMATIC default
- [trino.io/docs/467/optimizer/cost-based-optimizations.html](https://trino.io/docs/467/optimizer/cost-based-optimizations.html) — join_max_broadcast_table_size default 100MB
- r28 join-distribution canonical
- r24 join-strategy / ANALYZE-stats coverage

---

### Q3 — Per category, % of this month's total revenue, in ONE query (not two-query sum+grand-total-join)

**Score: 5.0** (Acc 5.0 / Clar 5.0 / Prac 5.0 / Compl 5.0)

**Pin-perfect percent-of-grand-total via window-over-aggregate canonical.** Responder lifted the r07 §1890 canonical directly:

```sql
SELECT
  category,
  SUM(revenue) AS cat_revenue,
  ROUND(100.0 * SUM(revenue) / NULLIF(SUM(SUM(revenue)) OVER (), 0), 2) AS pct_of_grand_total
FROM sales
WHERE order_date >= CURRENT_DATE - INTERVAL '1' MONTH
GROUP BY category;
```

All load-bearing elements:

- **`SUM(SUM(revenue)) OVER ()` semantics correctly explained**: outer `SUM(SUM(...)) OVER ()` is a **window function evaluated over the already-grouped rows** (one row per category), producing the grand total broadcast to every per-category row. The empty `OVER ()` is the unbounded partition (= every row). Trino 467 supports window functions over aggregate expressions in the same SELECT — canonical and verified at [trino.io/docs/467/functions/window.html](https://trino.io/docs/467/functions/window.html) + r07 §1890 *"the empty-`OVER ()` window computes the grand total inline while keeping every detail row, no self-join needed."*
- **No two-query+self-join needed** — directly addresses the engineer's "two queries and a join" framing.
- **`100.0 *` for float math** — defends against integer division (`SUM(revenue)` types as integer in some Iceberg/Trino setups → `0` for any ratio <1).
- **`NULLIF(...,0)` div-by-zero guard** — defends against empty-result-set / all-zero-revenue corner.
- **`ROUND(..., 2)` for display** — clean two-decimal percent.
- **`CURRENT_DATE - INTERVAL '1' MONTH` for "this month"** — valid Trino 467 date arithmetic (verified at [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html)). NOTE: this is a "last 30 days from today" filter (rolling window), not a "current calendar month" filter (`date_trunc('month', current_date)` would be the calendar-month variant). The engineer's "this month" framing is ambiguous, but the rolling-30-days form is the more common SaaS dashboard interpretation; not a defect.
- **`PARTITION BY category` variant** — responder also covered the case where a different denominator (e.g., per-category share of intra-category total when there are subdivisions) is needed: `SUM(SUM(revenue)) OVER (PARTITION BY category)` vs `OVER ()`. Demonstrates window-frame mechanics fluency.

No imported-prior, no broken-secondary, no over-warning, no fabrication. Cites r07 percent-of-total canonical correctly.

**Verifies against:**
- [trino.io/docs/467/functions/window.html](https://trino.io/docs/467/functions/window.html) — window functions over aggregates
- [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html) — INTERVAL arithmetic
- r07 §1890 percent-of-grand-total canonical
- r28 §2002 reference table — "per-bucket totals + grand-total row" alternatives

---

### Q4 — Oracle `INSTR('/api/v2/users/profile','/',1,3)=8` (3rd slash); Trino Nth occurrence equivalent

**Score: 4.0** (Acc 3.5 / Clar 3.5 / Prac 4.5 / Compl 4.5)

**iter1215 strpos-3-arg CEILING navigated CORRECTLY on the FUNCTION/SEMANTICS** — but two arithmetic slips in the worked example create a clarity/accuracy ding.

**What's CORRECT (the dialect fact):**

- **`strpos(string, substring, instance)` 3-arg form** — Verified verbatim at [trino.io/docs/467/functions/string.html](https://trino.io/docs/467/functions/string.html): *"Returns the position of the N-th `instance` of `substring` in `string`. When `instance` is a negative number the search will start from the end of `string`. Positions start with `1`. If not found, `0` is returned."* The responder's headline `strpos('/api/v2/users/profile','/',3)` and the lead return value **"Returns 8 (the 3rd slash)"** are BOTH correct.
- **Negative `instance` = from end** — semantics correct (returns position of |instance|-th occurrence from the end).
- **0 if fewer than N occurrences** — correct return-on-absence behavior.
- **Oracle 4-arg INSTR mapping** — `INSTR(str, sub, start_pos, instance)` with `start_pos=1` collapses to Trino `strpos(str, sub, instance)` 3-arg directly; the `start_pos` argument is dropped (Trino has no start-position 4th arg, but starts-from-1 is the only common case so the simplification is fine for the engineer's query).

**What's WRONG (the worked-example arithmetic):**

The string `'/api/v2/users/profile'` has 21 characters with slashes at positions **1, 5, 8, 14** (four slashes). Let me ground-truth-walk the 3rd-slash case:

| Position | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 | 16 | 17 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Char | `/` | `a` | `p` | `i` | `/` | `v` | `2` | `/` | `u` | `s` | `e` | `r` | `s` | `/` | `p` | `r` | `o` |

Slashes at 1, 5, 8, 14.

**Responder's worked-example slips:**

1. **"third_slash = 9"** — WRONG. Correct = **8**. (The responder's LEAD said 8; the WORKED-EXAMPLE TABLE says 9. The lead and the table contradict each other within the same answer.)
   - Possible interpretation: the responder mentally substituted "position of the character AFTER the 3rd slash" (9, since chars 9-21 = `'users/profile'`) — the "everything_after_third_slash = 'users/profile'" follow-up text IS consistent with start-at-position-9. But the table header labels it as "third_slash" position, not "after_third_slash" position. Labeling slip; numerical answer for the labeled metric is off by 1.

2. **`strpos('/api/v2/users/profile','/',-1)` → "Returns 17"** — WRONG. Correct = **14** (the 4th and last slash is at position 14, not 17). Position 17 is `'o'` in `'profile'`, not a slash. Off by 3.

**Score impact**: dialect fact (the FUNCTION, the 3-arg form, the negative-from-end semantic, the lead return value of 8) is **correct** — the iter1215 strpos-3-arg ceiling IS navigated. The engineer who copies the FUNCTION CALL (`strpos(url, '/', 3)`) gets the right answer (8). But the engineer who reads the worked-example TABLE and the negative-instance example gets two off-by-N numerical positions — which they may either (a) puzzle over and re-verify themselves (mild productivity ding) or (b) blindly trust and write code expecting a wrong return value (downstream bug risk for "find the last slash" use case where they'd write `strpos(url, '/', -1)` and expect 17).

The strpos-3-arg ceiling is a function-recall ceiling. iter1257 navigates the function correctly but reveals an **arithmetic-precision sub-axis** of the same ceiling: counting positions in worked examples without checking them against the string. This is a **responder synthesis slip**, not a resource defect — r23/r27 string-function pages already have correctly-counted examples (verified by grep on `strpos.*3` in resources: no wrong-numbered examples). NOT a FIX-A target; per `feedback_responder_broken_secondary_alternative.md` and `feedback_synthesis_ceiling_stop_churning.md`, scope as **per-instance one-off re-probe**.

**iter1215 strpos-3-arg watch reframed**: function/semantics navigated cleanly → ceiling on the FUNCTION direction is closing. The new sub-axis is "worked-example position arithmetic" (NOT a resource defect, NOT a FIX-A target — synthesis-precision recall ceiling).

**Verifies against:**
- [trino.io/docs/467/functions/string.html](https://trino.io/docs/467/functions/string.html) — strpos 2-arg + 3-arg overloads + negative-from-end semantics (verbatim)
- r23 string-function reference (correct examples)
- r27 Oracle-INSTR→Trino-strpos migration row

---

## FIX-A / watch decisions (this iter)

| Decision | Direction |
|---|---|
| **NO new FIX-A** | iter1257 has no resource defect — every load-bearing dialect/mechanism fact lands. Q4's worked-example arithmetic slip is a responder synthesis-precision ceiling, not a resource defect (resources have correctly-counted examples). |
| **iter1256 EXISTS WHICH-X router FIX-A REACHED, watch CLOSES** | Q1 lifted the router cleanly on first re-probe — debunked the DBA myth, kept the failing-shape exclusion intact, gave EXPLAIN-grep decision tool. 9th-consecutive 1st-re-probe-CLOSE in the LIGHT-FIX-A-then-CLOSE pattern. |
| **iter1238 broadcast-hedge (small-dim shape) watch CLOSES** | Q2 led BROADCAST correctly on the original watched shape (5K dim × 600M fact). Iter1256 closed the both-LARGE direction (PARTITIONED canonical); iter1257 closes the small-dim direction (BROADCAST canonical). Engineer demonstrably gets the right direction in both halves of the join-distribution decision tree now. |
| **iter1215 strpos-3-arg CEILING — partial re-frame** | Function/semantics direction navigated correctly (lead = 8 correct, 3-arg form correct, negative-from-end correct). New sub-axis: worked-example position-arithmetic slips in the SAME answer. Downgrade severity to "soft, arithmetic-clarity, no FIX-A"; re-probe in 4-8 iters under different N-th-occurrence framings to confirm function-direction durability. |
| **No new watches** | No new defects / no broken-secondaries / no over-warnings / no imported-priors / no fabrications surfaced. Q4's arithmetic slip is the only quality ding; per `feedback_responder_broken_secondary_alternative.md` + `feedback_synthesis_ceiling_stop_churning.md`, scope as per-instance one-off. |

---

## Topic-score impact (rubric updates)

| Topic | Before | This iter | After |
|---|---|---|---|
| Improving complex SQL performance on Trino with dbt | 4.4668/73 | Q1 = 4.9375 + Q2 = 5.0 | (4.4668 × 73 + 4.9375 + 5.0)/75 = (326.0764 + 9.9375)/75 = **4.4802/75** (+0.0134, margin +0.9802) |
| SQL query best practices for OLAP | 4.5878/293 | Q3 = 5.0 + Q4 = 4.0 | (4.5878 × 293 + 5.0 + 4.0)/295 = (1344.2254 + 9.0)/295 = **4.5872/295** (-0.0006, margin +1.0872) |
| Query performance basics: partitioning, indexing strategy for analytics | 4.1697/36 | (unchanged this iter — no questions hit this topic) | **4.1697/36** (margin +0.6697, STILL thinnest) |

All required topics REMAIN PASSED. Thinnest topic margin: Query performance basics at +0.6697 (no movement — re-probing partition-pruning / dynamic-filtering / EXPLAIN-driven perf questions would lift it).

---

## Open watches summary (going into iter1258)

| Watch | Origin iter | Status |
|---|---|---|
| iter1257 Q4 strpos-3-arg worked-example position-arithmetic | **1257** | **NEW — soft, arithmetic-clarity, NO FIX-A** (responder synthesis-precision; resources clean) |
| iter1255 Q1 bloom-CREATE-TABLE-syntax slip | 1255 | SOFT, re-probe next sweep |
| iter1255 Q3 INSERT-OVERWRITE-broken-secondary | 1255 | SOFT, re-probe next sweep |
| iter1255 Q4 translate-empty-to-semantic-divergence | 1255 | SOFT, re-probe next sweep |
| iter1253 Q4 regexp_extract-2arg-misrecall | 1253 | SOFT, re-probe |
| iter1253 Q2 first-order-cohort-tie | 1253 | SOFT, re-probe |
| iter1249 Q3 dbt-snapshot SCD-2 recall variance | 1249 | SOFT, re-probe |
| iter1248 Q1 opener-vs-body coherence on partition-coarsening | 1248 | SOFT, re-probe |
| iter1248 Q3 MATCH_RECOGNIZE-adjacency | 1248 | SOFT, re-probe |
| iter1241 concat-auto-coerces | 1241 | SOFT, re-probe |
| iter1236 rn=1-within-batch | 1236 | SOFT, re-probe |
| iter1215 strpos-3-arg CEILING (function direction) | 1215 | **REFRAMED — function/semantics navigated; arithmetic-precision sub-axis remains soft** |
| iter1229 @v1-Spark | 1229 | SOFT, re-probe |

**Watches CLOSED this iter:** iter1256 EXISTS WHICH-X router FIX-A REACHED + iter1238 broadcast-hedge small-dim shape.

---

## Recommended next iter (1258)

**Priority order:**

1. **Breadth-mode probing on the soft-watch backlog** — iter1255 bloom-CREATE syntax / iter1253 regexp_extract-2arg / iter1248 MATCH_RECOGNIZE-adjacency / iter1241 concat-auto-coerces / iter1236 rn=1-within-batch / iter1229 @v1-Spark all have aging soft watches that should re-probe in 4-8 iters to either close or escalate.

2. **Re-probe Q1 (EXISTS router) under different framings** — within 4-8 iters to confirm router durability. Suggested angles:
   - Postgres EXISTS with multi-column equality correlation (`a.x = b.x AND a.y = b.y`).
   - Migrated `WHERE EXISTS` with a `LIMIT 1` in the subquery body (FAILING-shape variant — should rewrite).
   - `NOT EXISTS` simple equality (failing shape per #21859 — should rewrite to anti-join).
   - `IN (SELECT ...)` with derived list — should behave identically to simple-equality EXISTS.
   These verify the router handles both the "leave it alone" AND the "rewrite" branches without over-correcting.

3. **Lift Query performance basics topic margin** — it remains the thinnest topic at +0.6697 over the 3.5 pass threshold; partitioning / dynamic-filtering / EXPLAIN-driven probes would help.

4. **Do NOT churn**: iter1256 EXISTS router FIX-A (closed cleanly) or iter1238 broadcast-hedge (closed cleanly). The strpos-3-arg arithmetic-precision sub-axis is a responder synthesis ceiling, NOT a FIX-A target.

---

## Per-instance quality slips (informational, no FIX-A)

- **Q1**: PR #1415 attribution slightly misaimed (PR #1415 is LIMIT/TopN decorrelation; simple-equality EXISTS decorrelation predates it and lives in the core decorrelation framework). Load-bearing fact (decorrelates reliably) correct; PR-number footnote points to a sibling rule. Acc -0.25; engineer arrives at the right action regardless.
- **Q4**: Two arithmetic slips in the worked-example table (third_slash labeled = 9, should be 8; strpos(...,-1) = 17, should be 14). The FUNCTION call + return value in the LEAD (`strpos(url, '/', 3)` → 8) IS correct; only the secondary worked-example positions are off. Responder synthesis-precision ceiling, not a resource defect or function-recall ceiling.
