# Iter1139 Judge Feedback

**Verdict: 3.8750 PASS + DOUBLE LIGHT FIX-A.** Q1 truncate-2-arg FIX-A REACHED CLEANLY (responder used `truncate(amount, 2)` direct 2-arg, no "1-arg only" claim; iter1138 r27 §4.4C correction CLOSES the watch). Q2 clean 5.0 breadth. **Q3 SILENT-WRONG DEFECT (responder one-off + resource-gap defang missing)** — responder recommended `WHERE status IS NOT DISTINCT FROM 'unknown'` and asserted it is "TRUE when status is NULL OR status='unknown'", which is FLAT FALSE: `NULL IS NOT DISTINCT FROM 'unknown'` returns FALSE (verified at trino.io/docs/current/functions/comparison.html), so the recommended form filters OUT all NULL rows and is NOT equivalent to `NVL(status,'unknown')='unknown'`. Engineer who ships this gets a silent-wrong query that misses every NULL-status row. **Q4 SCD-2 FINDABILITY MISS** — responder reached r27, cited SCD-1 merge, then BAILED on SCD-2 with "I DON'T HAVE ENOUGH INFORMATION IN THE RESOURCES" despite the canonical dbt-snapshot pattern existing in r09 §SCD and an explicit signpost from r27 TL;DR pt4. Routing failed because the question phrasing ("build change history", "what plan in February", "Oracle table updated in place no history", "track tier changes over time") did not match the signpost's anchor wording closely enough.

Two LIGHT FIX-As land this iter: (a) r23 §INDF inline-WRONG defang against the NVL-substitute misuse; (b) r27 TL;DR pt4 + r09 SCD anchor keyword-anchor strengthening for SCD-2-need phrasings without the literal word 'snapshot'.

---

## Score table

| Q | Topic | Acc | Clar | App | Compl | Avg |
|---|---|---|---|---|---|---|
| Q1 | Oracle `TRUNC(line_amount, 2)` → Trino `truncate(amount, 2)` 2-arg direct (FIX-A re-probe) | 5.0 | 5.0 | 5.0 | 5.0 | **5.0000** |
| Q2 | Accounts active 30d-BEFORE cutoff but ZERO events 30d-AFTER — two CTE windows + LEFT JOIN … WHERE IS NULL anti-join | 5.0 | 5.0 | 5.0 | 5.0 | **5.0000** |
| Q3 | Oracle `NVL(status,'unknown')='unknown'` → Trino — responder recommended `IS NOT DISTINCT FROM 'unknown'` (WRONG: filters out NULL rows, NOT NVL-equivalent) | 1.5 | 4.0 | 1.5 | 3.0 | **2.5000** |
| Q4 | Mutable Oracle dim with no history → dbt SCD-2 change-history pattern — responder BAILED on SCD-2 despite canonical living in r09 with r27 TL;DR pt4 signpost | 3.5 | 4.0 | 2.5 | 2.0 | **3.0000** |
| **Iter avg** | | | | | | **3.8750 PASS** |

Margin = +0.3750 above 3.5 pass threshold — thin compared to recent 4.6-4.9 band. Q3 and Q4 both pulled by ~1.5 each off the 5.0 baseline; if either had hit the 5.0 band the iter would have been STRONG PASS.

---

## Per-question detail

### Q1 — Oracle TRUNC(line_amount, 2) → Trino — **5.0000** — FIX-A CONFIRMED REACHED

Question: "Oracle code uses `TRUNC(line_amount, 2)` for numeric truncation. What's the Trino form — a single function or do I have to do `FLOOR(amount*100)/100`?"

Responder answer:
- **"Use `truncate(amount, 2)` — your one-liner, maps directly to Oracle `TRUNC(amount, 2)`"** — CORRECT, 2-arg direct form.
- Behavior note: drops digits toward zero without rounding; 12.349 → 12.34; -12.349 → -12.34 (toward-zero on negatives) — CORRECT.
- Defang against `round()`: explicitly warns it does HALF_UP rounding not truncation — CORRECT.
- No "1-arg only" claim, no "2-arg form does NOT exist" assertion, no `truncate(amount*100)/100` workaround offered as canonical — CLEAN.

**FIX-A reach verdict: CONFIRMED CLEAN.** iter1138 r27 §4.4C correction (removed the false "1-arg only" claim and the fabricated wrong-arity error message at lines 1628 / 1657 / 1665) has reached the responder's recall. The Oracle-`TRUNC(x,n)`-to-Trino watch **CLOSES** this iter. Joins the closed-watch ledger alongside ADD-COLUMN, partition-COUNT-folklore, population-percentile, dedup-tied-tuple, SELECT-*-EXCEPT, `{% if execute %}`, percent_rank-DESC-direction.

Verified against [trino.io/docs/current/functions/math.html](https://trino.io/docs/current/functions/math.html): `truncate(x, d)` 2-arg signature documented with explicit example `truncate(REAL '12.333', 1) → 12.3`. Decimal overload `function truncate(decimal(p, s), bigint) returns decimal(p, s)` also confirmed.

### Q2 — Accounts active before cutoff but ZERO events after — **5.0000**

Question (paraphrased): "I want accounts that were active in the 30 days BEFORE a cutoff date but had ZERO events in the 30 days AFTER. How do I structure this on Iceberg+Trino?"

Responder gave the canonical two-window anti-join shape:
```sql
WITH active_before AS (
  SELECT DISTINCT account_id
  FROM events
  WHERE occurred_at >= DATE '2025-09-01' - INTERVAL '30' DAY
    AND occurred_at <  DATE '2025-09-01'
),
active_after AS (
  SELECT DISTINCT account_id
  FROM events
  WHERE occurred_at >= DATE '2025-09-01'
    AND occurred_at <  DATE '2025-09-01' + INTERVAL '30' DAY
)
SELECT b.account_id
FROM active_before b
LEFT JOIN active_after a
  ON b.account_id = a.account_id
WHERE a.account_id IS NULL;
```
+ NOT EXISTS alternative for the second window + correct callout that the half-open `>=`/`<` bounds on raw `occurred_at` get partition-pruned if the events table is partitioned by `day(occurred_at)`.

This is the canonical "active in window A but not window B" churn/lapsed-user pattern. The LEFT JOIN + WHERE IS NULL anti-join shape is recommended over `NOT IN` because `NOT IN` mis-handles NULLs (any NULL in the inner result returns no rows on the outer side per three-valued logic). The half-open interval form `>= start AND < end + 1` avoids the off-by-one trap of `BETWEEN ... AND ...` on timestamps that include time. Both CTEs use `SELECT DISTINCT account_id` to avoid join-fan-out, which is the right pre-aggregation for anti-join.

Clean canonical answer. Partition pruning note bonus.

### Q3 — Oracle NVL replacement: IS NOT DISTINCT FROM misuse — **2.5000** — SILENT-WRONG DEFECT

Question: "Oracle code is `WHERE NVL(status, 'unknown') = 'unknown'` — they want to treat NULL rows the same as the literal 'unknown'. The literal Trino rewrite is `WHERE status IS NULL OR status = 'unknown'`. Is `IS NOT DISTINCT FROM` cleaner?"

Responder answer (the DEFECT):
> "Use `IS NOT DISTINCT FROM` — clean purpose-built operator: `WHERE status IS NOT DISTINCT FROM 'unknown'` -- TRUE when status is NULL OR status = 'unknown'"
> Calls it idiomatic, says it eliminates the COALESCE sentinel pattern, claims it preserves pruning.
> Cites r23 §2923-2948.

**THIS IS FACTUALLY WRONG.** Verified at [trino.io/docs/current/functions/comparison.html](https://trino.io/docs/current/functions/comparison.html):

| Case | `a IS NOT DISTINCT FROM b` |
|---|---|
| a and b non-null and equal | TRUE |
| a and b non-null and unequal | FALSE |
| BOTH NULL | TRUE (the one case where INDF differs from `=`) |
| a IS NULL, b is non-null literal | **FALSE** |
| a is non-null literal, b IS NULL | **FALSE** |

The Trino docs verbatim: "NULL IS NOT DISTINCT FROM NULL; -- true" and "treat NULL as a known value and both operators guarantee either a true or false outcome even in the presence of NULL input."

With b fixed at the non-null literal `'unknown'`, the both-NULL branch CAN NEVER fire (b is never NULL). So:
- `status IS NOT DISTINCT FROM 'unknown'` is TRUE iff `status = 'unknown'`.
- When `status IS NULL`, the result is **FALSE** (NULL is DISTINCT FROM 'unknown' because exactly one side is NULL).

**`IS NOT DISTINCT FROM` against a non-null literal is just `=`. It is NOT NVL-equivalent. It silently FILTERS OUT all NULL-status rows.**

The engineer's intent — match BOTH literal-'unknown' status AND NULL status — is broken. The correct Trino equivalents are:
- `COALESCE(status, 'unknown') = 'unknown'` (direct NVL → COALESCE rewrite)
- `status IS NULL OR status = 'unknown'` (the literal expansion the engineer already had)

`IS NOT DISTINCT FROM` is the right operator for null-safe equality between **TWO possibly-NULL operands** — e.g., a join key where both sides can be NULL and you want NULL-vs-NULL to match (the canonical dedup / MERGE-key use case in r23 §2929-2935). It is NOT a substitute for "treat NULL as a chosen literal value".

**Severity classification: silent-wrong correctness defect.** This is materially worse than the iter1138 r27 truncate misclaim:
- iter1138 truncate workaround `truncate(price*100)/100` was VERBOSE but produced the CORRECT VALUE — user-facing breakage bounded to verbose code.
- iter1139 INDF misuse produces the WRONG ROW SET — every NULL-status row is silently dropped. No parse error, no warning, just missing rows in downstream reports.

The engineer's question explicitly framed the goal: "treat NULL and the literal the same". The responder's recommendation does the OPPOSITE for NULL rows.

**Source root cause: HYBRID — responder one-off over-extrapolation + resource missing a defang.**

Greppable to `resources/23-sql-best-practices-olap.md` §2923-2947:
- §2927 explicitly states "NULL IS NOT DISTINCT FROM 'x' → FALSE" — the resource HAS the correct truth-table fact.
- §2941 worked example correctly uses two-column form `col_a IS NOT DISTINCT FROM col_b` for two-nullable-operands.
- §2945 "prefer it" guidance is scoped to the "treat NULL as equal to NULL" case — correct.
- **MISSING: explicit inline-WRONG defang against `col IS NOT DISTINCT FROM 'literal'` as an NVL-substitute pattern.** The resource correctly says NULL-vs-non-null returns FALSE, but does not put up a guard rail against the engineer who reads "null-safe equality" too loosely and applies INDF as a generic "treat NULL as this literal" shortcut.

The responder had the correct truth-table fact available (§2927) but over-extrapolated past it — read "null-safe equality" as "handles NULL same as the other side" without checking the truth table for the asymmetric NULL-vs-literal case. This is a classic over-extrapolation slip; the resource is correct but porous against the specific misuse this question's phrasing invites.

**Classification: responder one-off slip ON a resource-coverage gap.** The resource is technically correct; the missing piece is a positive defang against the named misuse pattern.

**LIGHT FIX-A SPEC (single resource, ~5-8 line addition):**

`resources/23-sql-best-practices-olap.md` §2923-2947 — add an inline-WRONG defang block between §2941 and §2945 (before the "Why not the workarounds?" paragraph):

```
> **DO NOT WRITE — INDF against a non-null literal is NOT an NVL-substitute.**
> `WHERE col IS NOT DISTINCT FROM 'unknown'` is **equivalent to `WHERE col = 'unknown'`** when the right side is a non-null literal. The `NULL IS NOT DISTINCT FROM <literal>` case returns **FALSE** (not TRUE) — exactly one side is NULL, so the values ARE distinct. This means `col IS NOT DISTINCT FROM 'unknown'` **silently filters out every NULL row**, the opposite of what an Oracle `NVL(col,'unknown')='unknown'` migration needs.
>
> Use INDF only when **BOTH sides can be NULL** (the null-safe-equality use case: two nullable columns, a join key, a dedup key).
>
> To "treat NULL as a chosen literal value" — Oracle `NVL(col, sentinel) = sentinel` — use one of:
> - `COALESCE(col, 'unknown') = 'unknown'` (direct NVL → COALESCE rewrite)
> - `col IS NULL OR col = 'unknown'` (literal expansion)
>
> The two patterns produce different rows because INDF's null-rule is **symmetric** (both sides NULL → TRUE) while NVL's null-rule is **asymmetric** (one side is the constant, the other gets NULL-coerced).
```

After landing, re-probe within 2-3 iters with a different NVL-substitute phrasing — e.g., "Oracle code is `WHERE NVL(plan_tier, 'FREE') IN ('FREE', 'TRIAL')`; can I use `IS NOT DISTINCT FROM` for this?" — to confirm the responder reaches the COALESCE form, not INDF.

### Q4 — dbt SCD-2 change history for mutable Oracle dim — **3.0000** — FINDABILITY MISS + BAIL

Question (paraphrased): "Our Oracle `customer_accounts` is mutable — updated in place, no history. Analysts now want to ask 'what plan was this customer on in February?' and 'how many customers upgraded tier last quarter?'. How does dbt + Trino + Iceberg build that change history?"

Responder answer:
- Correctly diagnosed: this is an SCD-1 (current-state-only) → SCD-2 (full history) shift — CORRECT framing.
- Showed the SCD-1 dbt incremental merge from r27 §6 (`materialized='incremental'`, `incremental_strategy='merge'`, `unique_key='customer_id'`) — CORRECT but answers only the CURRENT state, not the analyst's "what plan in February" need.
- Then: **"For building full change history (SCD-2), I DON'T HAVE ENOUGH INFORMATION IN THE RESOURCES"** / **"SCD-2 implementation with dbt on Trino would need... I don't have detailed guidance"** / **"Next step: document this in the resources."**

**The bail is wrong.** The canonical dbt SCD-2 pattern IS in the resources:
- `resources/09-lakehouse-schema-design.md` §305-450 — full dbt SNAPSHOT canonical:
  - SCD Type 2 conceptual diagram (§309-337).
  - Option 1 dbt snapshot (§353-414) with both `strategy='timestamp'` and `strategy='check'` worked examples.
  - `dbt_valid_from` / `dbt_valid_to` / `dbt_scd_id` metadata columns.
  - As-of point-in-time query (§341-347): `WHERE TIMESTAMP '2025-08-10' >= valid_from AND (valid_to IS NULL OR TIMESTAMP '2025-08-10' < valid_to)`.
  - `unique_key` alias rule, `hard_deletes` config, `check_cols` LIST vs `'all'` STRING.
- `resources/27-oracle-plsql-to-dbt-trino.md` §9 TL;DR pt4 (line 14) — explicit signpost: *"If you instead need SCD-2 HISTORY — keep every change with effective dates and answer 'what plan/price/status was this entity on as of <date>' — that's a **dbt SNAPSHOT**, NOT an incremental merge model: see **[resource 09 § Slowly Changing Dimensions — Option 1 dbt snapshot]**"*.
- This routing signpost was added at **iter1112** as part of the SCD-2 → r09 routing layer.

The question's analyst-need phrasing — **"what plan was this customer on in February?"** — matches the signpost's anchor wording — *"answer 'what plan/price/status was this entity on as of <date>'"* — almost verbatim. The responder reached r27 (cited the SCD-1 merge from §6) but did not follow pt4 of the TL;DR over to r09.

**Source root cause: findability / routing miss.** The content exists; the responder's keyword-routing didn't land on it. Possible causes (each compounds):
1. **TL;DR pt4 is BURIED.** It's the 4th of 7 TL;DR sentences in r27. The responder may have skimmed pt4 looking for SCD-1 content (which is there) and not re-read it for SCD-2.
2. **Signpost wording doesn't include the question's literal phrases.** The question used "**build change history**", "track plan/tier changes **over time**", "Oracle table **updated in place no history**" — none of these appear verbatim in the pt4 signpost. The signpost says "SCD-2 HISTORY" / "keep every change with effective dates" / "what plan/price/status was this entity on as of <date>". The "what plan in February" part of the question matches; the "build change history" framing does not.
3. **The question does NOT contain the literal word "snapshot".** All of r09's strong keyword anchors (§355) are anchored on the word "snapshot" or on schema field names like `dbt_valid_from`. The question is one level upstream of those anchors — it describes the NEED ("how does dbt build change history") without using the dbt-side noun ("snapshot") that names the solution.

**Classification: routing/findability miss with no responder-side fix possible — content is correct, anchors are insufficient for the SCD-2-need-without-the-word-snapshot phrasing class.**

**LIGHT FIX-A SPEC (two-touch keyword-anchor strengthening, ~6-10 lines total):**

(a) `resources/27-oracle-plsql-to-dbt-trino.md` TL;DR pt4 (line 14) — extend the parenthetical anchor list. Current end of pt4:
> *"…that's a **dbt SNAPSHOT**, NOT an incremental merge model: see **[resource 09 § Slowly Changing Dimensions — Option 1 dbt snapshot](09-lakehouse-schema-design.md#slowly-changing-dimensions-scd)** (creates `dbt_valid_from`/`dbt_valid_to`/`dbt_scd_id`; as-of query `WHERE dbt_valid_from <= TIMESTAMP '<date>' AND (dbt_valid_to IS NULL OR dbt_valid_to > TIMESTAMP '<date>')`)."*

Add an immediately-following keyword-anchor sentence:
> *"**Keywords this signpost serves**: 'build change history from a mutable source', 'how does dbt build change history', 'track plan/tier/price changes over time', 'version history of a dimension', 'Oracle dimension updated in place no history', 'mutable source no history', 'what was the value on a past date', 'point-in-time dimension lookup', 'as-of query', 'time-travel a dimension', 'how many customers upgraded tier last quarter', 'how many records changed X last month' — ALL of these route to r09 § dbt snapshot, NOT to the SCD-1 incremental merge in §6."*

(b) `resources/09-lakehouse-schema-design.md` §305 (the SCD section opener) — prepend a keyword anchor BEFORE the existing "Dimension tables describe entities…" paragraph:
> *"**This section answers questions of the shape: 'how does dbt build change history from a mutable source table', 'how do I track plan/tier/status changes over time when the source dimension is updated in place', 'what plan/price/status was customer X on in February / on as-of date Y', 'how many records changed X over a period', 'version history of a dimension', 'Oracle table updated in place no history' — the answer is dbt SNAPSHOTS (the dbt-trino-native SCD-2 mechanism), covered in Option 1 below. The dbt INCREMENTAL MERGE in r27 §6 is SCD-1 only (current state, no history) — if you need point-in-time lookup or change history, you need SNAPSHOT not incremental-merge."*

After landing, re-probe within 2-3 iters with the **without-the-word-snapshot** phrasing — e.g., "Our Postgres `users` table is mutated in place with no audit log; analysts want to query what plan a user was on last quarter. How do we build that on dbt + Trino + Iceberg?" — to confirm routing now lands on r09 §SCD Option 1, NOT bail.

**The bail itself is a partial-credit answer.** The responder DID flag the SCD-1/SCD-2 distinction correctly (engineer is told their problem is well-known and the answer exists in the SCD-2 literature). The applicability dimension is hurt because the engineer can't ship; the completeness dimension is hurt because the second half of the question is unanswered. But the framing-half of the answer was correct, which keeps this from a sub-2.5 score.

---

## Topics updated

- **Oracle PL/SQL → dbt + Trino SQL migration** (Q1 + Q3 both touch): 4.4500/116 → (4.4500×116 + 5.0 + 2.5)/118 = (516.20 + 7.5)/118 = **4.4381/118 PASSED** (−0.0119). Margin +0.9381 — still safely above threshold. Q1 was the FIX-A re-probe lift; Q3 was the silent-wrong INDF defect drag.
- **Analytical query patterns on Iceberg+Trino** (Q2): 4.4631/90 → (4.4631×90 + 5.0)/91 = (401.679 + 5.0)/91 = **4.4690/91 PASSED** (+0.0059, Q2 lift on two-window anti-join canonical).
- **SQL query best practices for OLAP** (Q3 secondary touch — INDF canonical lives in r23 §2923-2948): 4.5629/201 → (4.5629×201 + 2.5)/202 = (917.143 + 2.5)/202 = **4.5527/202 PASSED** (−0.0102, Q3 INDF-misuse drag).
- **dbt snapshots / SCD2** (Q4): 4.1526/16 → (4.1526×16 + 3.0)/17 = (66.4416 + 3.0)/17 = **4.0848/17 PASSED** (−0.0678, Q4 routing-miss drag; thinnest-margin required-topic now at +0.5848).

ALL required topics REMAIN PASSED. No topic drops below threshold. dbt-snapshots SCD2 is now the thinnest required-topic margin (overtaking storage-tiering after this drag).

---

## Source-verified defects this iter

**1 silent-wrong responder defect on a resource-gap (Q3):** Responder recommended `WHERE status IS NOT DISTINCT FROM 'unknown'` as an NVL-substitute and claimed it is "TRUE when status is NULL OR status='unknown'". Verified WRONG at [trino.io/docs/current/functions/comparison.html](https://trino.io/docs/current/functions/comparison.html): `NULL IS NOT DISTINCT FROM <non-null literal>` returns FALSE, so the form filters OUT all NULL rows and is NOT NVL-equivalent. Responder one-off (the resource at r23 §2927 explicitly states "NULL IS NOT DISTINCT FROM 'x' → FALSE") on top of a resource-coverage gap (r23 has no positive defang against the named NVL-substitute misuse). LIGHT FIX-A: add inline-WRONG defang block to r23 §2923-2947.

**1 findability / routing miss (Q4):** Responder reached r27 §6 (SCD-1 merge) but did not follow r27 TL;DR pt4 signpost to r09 §SCD Option 1 dbt snapshot. Canonical content EXISTS in r09 §305-450; signpost EXISTS in r27 TL;DR pt4. Routing failed on SCD-2-need-without-the-word-snapshot phrasings ("build change history", "track changes over time", "updated in place no history"). LIGHT FIX-A: extend keyword anchors at r27 TL;DR pt4 and r09 §305 SCD section opener.

**0 resource-sourced factual errors this iter.** (Both defects are coverage/routing gaps, not factual errors in existing content.)

---

## Watch streams

**Q1 truncate-2-arg FIX-A: CLOSED.** iter1138 r27 §4.4C correction reached the responder; iter1139 Q1 used `truncate(amount, 2)` direct form with no "1-arg only" claim. Watch joins the closed-watch ledger.

**No new watch streams opened.** Q3 INDF-misuse and Q4 SCD-2-routing each get a LIGHT FIX-A that is expected to land and self-verify on the re-probe. If either re-probe fails (Q3 INDF reaches the wrong form again post-defang, OR Q4 SCD-2 routing fails to reach r09 post-anchor-strengthening), open a watch then.

---

## Thinnest-margin order after iter1139

1. **dbt-snapshots SCD2 4.0848/17 (+0.5848, NEW thinnest required-topic, Q4 routing-miss drag)**
2. storage-tiering 4.0739/11 (+0.5739, untouched — actually still thinnest by 0.011, but Q4 drag puts dbt-snapshots within 0.011 of it)
3. query-perf-basics 4.1771/23 (+0.6771, untouched)
4. cost-considerations 4.3074/23 (+0.8074, untouched)
5. query-perf-regression-diagnosis 4.3436/21 (+0.8436, untouched)
6. Oracle-migration 4.4381/118 (+0.9381, Q1 FIX-A reach lift + Q3 INDF drag net negative)
7. Iceberg-partition-design 4.4616/47 (+0.9616, untouched)
8. Analytical-query-patterns 4.4690/91 (+0.9690, Q2 lift)
9. Iceberg-maintenance 4.4800/179 (untouched)
10. federation 4.5024/312 (untouched, fragile-PASS preserved)
11. SQL-best-practices-OLAP 4.5527/202 (+1.0527, Q3 INDF drag)
12. CBO/ANALYZE 4.6105/22 (untouched)
13. improving-complex-SQL-perf-dbt 4.6111/25 (untouched)

dbt-snapshots SCD2 and storage-tiering are now near-tied for thinnest margin. Re-probe priority should ROTATE between them.

---

## RECOMMENDATION = DOUBLE LIGHT FIX-A

**FIX-A #1** (Q3 INDF-misuse defang, single-file ~5-8 lines):
- `resources/23-sql-best-practices-olap.md` §2923-2947 — insert inline-WRONG defang block between §2941 (worked example) and §2945 ("Why not the workarounds?") covering: INDF-against-non-null-literal is `=`, silently filters NULL rows, NOT NVL-equivalent, use `COALESCE(col, lit) = lit` or `col IS NULL OR col = lit`; INDF is for both-sides-nullable null-safe equality only.

**FIX-A #2** (Q4 SCD-2 routing keyword anchors, two-file ~6-10 lines total):
- `resources/27-oracle-plsql-to-dbt-trino.md` TL;DR pt4 (line 14) — append keyword-anchor sentence covering: "build change history from a mutable source", "track plan/tier/price changes over time", "version history of a dimension", "Oracle dimension updated in place no history", "what was the value on a past date", "point-in-time dimension lookup", "how many records changed X last month".
- `resources/09-lakehouse-schema-design.md` §305 SCD section opener — prepend keyword-anchor sentence covering the same phrasings, plus an explicit "incremental-merge is SCD-1 only; if you need history use SNAPSHOT" routing line.

**Re-probe queue** (priority order):
1. **Q3 INDF NVL-substitute re-probe** with a different literal/IN phrasing — e.g., "Oracle code is `WHERE NVL(plan_tier, 'FREE') IN ('FREE', 'TRIAL')`; can I use `IS NOT DISTINCT FROM`?" — confirm responder reaches COALESCE form, NOT INDF.
2. **Q4 SCD-2 routing re-probe** with the **without-the-word-snapshot** phrasing — e.g., "Our Postgres `users` table is mutated in place with no audit log; analysts want to query what plan a user was on last quarter on dbt + Trino + Iceberg." — confirm routing lands on r09 §SCD Option 1.
3. **Q1 truncate sustain re-probe** — third instance with a different decimal-places arg — e.g., "Oracle code uses `TRUNC(amount, 4)`; what's the Trino form?" — confirm the FIX-A reach is durable, not iter-1138-specific.
4. Storage-tiering 12th angle (now joint-thinnest required-topic, untouched 5 iters).
5. Q2 two-window anti-join 2nd-instance generative re-probe to sustain the canonical.

---

## Pattern observation

22-iter sustainment band: STRONG PASS iters 1090/1092/1093/1117/1118/1119/1121/1122/1125/1127/1128/1131/1133/1134/1137 + LIGHT FIX-A iters 1091/1116/1124/1129/1132/1136/1138 + NO-OP+WATCH iters 1120/1123/1126/1130/1135 + **PASS+DOUBLE-LIGHT-FIX-A iter 1139**.

iter1139 3.8750 is the THINNEST PASS margin in 22 iters (recent band has been 4.4-4.9). The thinness traces to TWO distinct defects on a single iter:
- Q3 is a NEW dimension defect (silent-wrong NVL-substitute misuse of IS NOT DISTINCT FROM) on a resource (r23 §INDF) that has the correct truth-table fact but no positive defang against the named misuse pattern. This is a NEW micro-class — "responder over-extrapolates a null-handling operator past its truth-table scope".
- Q4 is a routing/findability miss on a CANONICAL THAT EXISTS in r09 with a signpost in r27 TL;DR pt4. The miss tracks the documented `Responder Findability` memory pin — Haiku routes on keyword overlap, and the question's "build change history / track changes over time / updated in place no history" phrasings did not overlap with the signpost's "SCD-2 HISTORY / keep every change with effective dates / what plan was X on as-of date Y" wording closely enough.

Both are LIGHT FIX-A and tractable. Neither suggests a deeper architectural problem; the resources have the right content, they just need (a) a positive defang against a NEW operator-overreach misuse class (Q3) and (b) wider keyword anchors for a SCD-2-need-without-the-word-snapshot phrasing class (Q4).

Q1 FIX-A reach (the truncate-2-arg correction landing cleanly) is the iter-positive — it confirms that iter1138's surgical r27 §4.4C reconciliation worked exactly as designed. The Oracle-TRUNC-to-Trino watch closes after a single re-probe, which is the expected pattern when a resource-sourced factual claim is corrected in-place (vs the longer multi-iter cycles needed when the issue is a Haiku synthesis ceiling).

The iter is informative without being alarming. Margin +0.3750 is thin but the FIX-A spec is concrete and bounded; expectation is iter1140 returns to the 4.4-4.9 band once both FIX-As land.
