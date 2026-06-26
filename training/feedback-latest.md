# Iter1138 Judge Feedback

**Verdict: 4.6875 STRONG PASS LIGHT FIX-A. Q1 surfaced a RESOURCE-SOURCED factual defect in r27 §4.4C — Trino 467 DOES have `truncate(x, n)` 2-arg form (verified at trino.io/docs/current/functions/math.html); resource explicitly asserts it does NOT exist and even fabricates a precise wrong-arity error message. Workaround `truncate(x*100)/100` still produces correct value so user-facing impact is bounded, but the function-inventory claim and fabricated error text are flat false. Q2/Q3/Q4 clean 5.0 breadth angles. Joins memory `Trino starts_with / ends_with` + `Trino to_char Exists` + `Trino listagg Native` + `Trino No array_sum` imported-prior recurring class — this time the wrong direction (assumed absence; the form IS there). NO new watch streams.**

---

## Score table

| Q | Topic | Acc | Clar | App | Compl | Avg |
|---|---|---|---|---|---|---|
| Q1 | Oracle TRUNC dual-use → Trino (no overloaded TRUNC; `truncate()` numeric + `date_trunc('day',ts)` date — but responder repeats r27's wrong "1-arg only" claim, missing direct `truncate(x, 2)` form) | 3.0 | 4.0 | 4.0 | 4.0 | **3.7500** |
| Q2 | Running per-customer MIN — `MIN(monthly_spend) OVER (PARTITION BY customer_id ORDER BY month ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)`, same framing as running SUM | 5.0 | 5.0 | 5.0 | 5.0 | **5.0000** |
| Q3 | Extract '3.12.0' from 'client/v3.12.0/release' — `regexp_extract(str, 'v([0-9.]+)', 1)`, 3-arg form, group 0=whole / 1=first capture | 5.0 | 5.0 | 5.0 | 5.0 | **5.0000** |
| Q4 | Iceberg hidden partitioning by month/day — `WITH (partitioning = ARRAY['day(occurred_at)'])`, filter on raw timestamp auto-prunes, dbt key is `partitioning` (not `partitioned_by`) for Iceberg | 5.0 | 5.0 | 5.0 | 5.0 | **5.0000** |
| **Iter avg** | | | | | | **4.6875 STRONG PASS** |

Margin = +1.1875 above 3.5 pass threshold. Q1 drag (3.75) traceable to a SINGLE resource-sourced factual claim that the responder faithfully echoed.

---

## Per-question detail

### Q1 — Oracle TRUNC dual-use → Trino — **3.7500** — RESOURCE-SOURCED FACTUAL DEFECT

Question: "Oracle's `TRUNC(decimal, 2)` truncates decimals; `TRUNC(timestamp)` strips time. Does Trino have one overloaded TRUNC, or separate functions?"

Responder answer (correct parts):
- No overloaded `TRUNC` in Trino — CORRECT.
- Numeric truncation → `truncate()` — CORRECT (function name).
- Date truncation → `date_trunc('day', ts)` — CORRECT.
- These are **separate functions** (not one overload) — CORRECT.
- `truncate(timestamp)` errors — CORRECT (math fn doesn't accept temporal types).

Responder answer (DEFECT):
> "truncate() which it claims is '1-arg only', so for 2 decimals use `truncate(price*100)/100` (general: `truncate(price*power(10,2))/power(10,2)`)"

**Trino 467 HAS BOTH `truncate(x)` 1-arg AND `truncate(x, n)` 2-arg forms.** Verified at [trino.io/docs/current/functions/math.html](https://trino.io/docs/current/functions/math.html):
- `truncate(x) → [same as input]` — "Returns `x` rounded to integer by dropping digits after decimal point."
- `truncate(x, d) → [same as input]` — "Returns `x` truncated to `d` decimal places. `d` can be negative, in which case `d` digits to the left of the decimal point are zeroed out."

Trino-481 search hit also confirms decimal signature: `function truncate(decimal(p, s), bigint) returns decimal(p, s)`. Examples per the docs: `truncate(REAL '12.333', -1)` → `10.0`; `truncate(REAL '12.333', 1)` → `12.3`.

So the simpler direct form `truncate(price, 2)` produces the same `47.89` result the workaround produces — and the responder's `truncate(price*100)/100` workaround is **functionally correct but unnecessarily verbose**, and the underlying claim that "the 2-arg form does NOT exist" is FACTUALLY WRONG.

**Severity classification: minor accuracy defect.** The workaround the responder offered produces the correct value, so user-facing breakage is bounded — engineer ships working code, just verbose. BUT:
1. Function-inventory misrepresentation pollutes the engineer's mental model.
2. The resource even fabricates a precise wrong-arity error text the engine would purportedly throw (see below) — that's a forward-credibility hit if the engineer ever tests it.

**Source root cause: resource defect, not responder slip.** Greppable to `resources/27-oracle-plsql-to-dbt-trino.md`:
- **Line 1628** (canonical table row): *"Trino's `truncate` is **1-arg only**; the 2-arg `truncate(n, d)` form **does NOT exist** in Trino 467."* — FLAT FALSE.
- **Line 1657** (DO-NOT-WRITE entry 2): *"`truncate(n, d)` — the 2-arg numeric truncation form — does NOT exist on Trino. Trino's `truncate` is **1-arg ONLY** … Writing `truncate(12.3456, 2)` produces a wrong-arity / function-resolution error of the form `Unexpected parameters (decimal(6,4), integer) for function truncate. Expected: truncate(<numeric type>)`"* — FABRICATED ERROR MESSAGE; the engine would NOT throw this because the 2-arg overload exists.
- **Line 1665** (Keyword-trap phrase): *"Anyone who writes `TRUNC(x, 2)` for Trino is using Oracle syntax — Trino has lowercase `truncate(x)` 1-arg only"* — WRONG; the lowercase 2-arg form IS available.
- **Line 1624** explicitly cites a verification date of 2026-06-05 against `trino.io/docs/current/functions/math.html`, which makes the wrong claim look authoritative.

**Classification: imported-prior recurring class — assumed-absence direction.** This joins the documented memory pins:
- "Trino starts_with / ends_with" (assumed `starts_with` was a fabrication; it isn't),
- "Trino to_char Exists" (wrongly called `to_char` a fabrication),
- "Trino listagg Native" (wrongly lumped `listagg` absent),
- "Trino No array_sum" (other direction: my pin asserted presence; the form was absent).

The class is "assume foreign-looking forms aren't in Trino without verifying" — this is the 5th instance in the catalogued series. Resource was likely written from an unverified directive prior; trino.io math docs refute it directly.

**LIGHT FIX-A SPEC (single resource, ~10-15 line reconciliation):**
- `resources/27-oracle-plsql-to-dbt-trino.md` §4.4C — reconcile in-place (do NOT just append per memory pin "Reconcile Don't Append"):
  - Line 1628 row 1 — change Trino canonical column to: *"`truncate(n, d)` — lowercase, 2-arg (Trino 467 HAS this overload, `truncate(decimal(p,s), bigint) → decimal(p,s)`). Equivalent verbose form: `truncate(n * power(10, d)) / power(10, d)`."* Drop the "1-arg only / does NOT exist" claim.
  - Line 1639-1642 canonical worked example — LEAD with `truncate(price * 1.0875, 2) AS price_with_tax` (direct 2-arg); keep `truncate(price * 1.0875 * 100) / 100` as an "equivalent verbose form" cross-reference, not the canonical.
  - Line 1657 DO-NOT-WRITE entry 2 — DELETE this entry entirely (the form is valid; defang is the inverse of truth). Replace with: *"Watch the result type: `truncate(decimal(p,s), n)` returns `decimal(p,s)` not a double; chained string formatting should still wrap in `CAST(... AS DECIMAL(18,2))` or `format()` if a fixed scale is required for display."*
  - Line 1665 Keyword-trap phrase — rewrite: *"Anyone who writes `TRUNC(x, 2)` for Trino is using Oracle syntax — Trino lowercase form is `truncate(x, 2)` (2-arg form IS supported in 467); if you only have the 1-arg form in mind, `truncate(x*100)/100` is equivalent."*
- Keep the `TRUNC` (uppercase / non-existent name) defang and the `truncate(date)` defang in entries 1, 3, 4 — those are correct.
- Add a `verification_date: 2026-06-26` comment with explicit re-verification against `trino.io/docs/current/functions/math.html` two-arg signature.
- Cross-link from r07 §4528+ (the rounding/truncating canonical) to the corrected r27 §4.4C so the rounding-vs-truncation guidance stays aligned.

After landing, re-probe within 2-3 iters with a different Oracle-TRUNC-to-Trino phrasing (e.g., "Oracle code uses `TRUNC(amount, 4)`; what's the Trino form?") to confirm the responder reaches the direct `truncate(x, n)` form instead of repeating the workaround verbatim.

### Q2 — Running per-customer MIN with OVER framing — **5.0000**

Question: "I have monthly_spend per (customer_id, month). I want to show 'lowest spend ever through this month' running per customer. Does MIN() work with the same OVER (… ROWS UNBOUNDED PRECEDING …) syntax as a running SUM?"

Responder:
```sql
SELECT customer_id, month, monthly_spend,
       MIN(monthly_spend) OVER (
         PARTITION BY customer_id
         ORDER BY month
         ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
       ) AS lowest_spend_through_month
FROM spend_by_month;
```
+ explicit "yes, same positional framing as a running SUM; MIN is an aggregate that also works as a window function — you just add OVER and a frame."

Verified at [trino.io/docs/current/functions/window.html](https://trino.io/docs/current/functions/window.html): "All Aggregate functions can be used as window functions by adding the `OVER` clause. The aggregate function is computed for each row over the rows within the current row's window frame." Documentation provides explicit rolling-sum example using the same `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` framing. MIN/MAX/AVG/SUM all behave identically as aggregates-as-window-functions under explicit ROWS framing.

Clean canonical answer, correct framing choice (ROWS not RANGE — RANGE on date/timestamp could behave differently with peers, ROWS is the cumulative-by-position framing), correct equivalence statement.

### Q3 — `regexp_extract` capture-group index — **5.0000**

Question: "Extract '3.12.0' from 'client/v3.12.0/release'. Does Trino's `regexp_extract` support a capturing-group index?"

Responder:
```sql
SELECT regexp_extract('client/v3.12.0/release', 'v([0-9.]+)', 1);  -- '3.12.0'
```
+ 2-arg form returns whole match; 3-arg form takes group index (0=whole match, 1=first capture); second example with `'action=(\S+)'` group 1.

Verified at [trino.io/docs/current/functions/regexp.html](https://trino.io/docs/current/functions/regexp.html):
- 2-arg: `regexp_extract(string, pattern) → varchar` — first substring matched by pattern.
- 3-arg: `regexp_extract(string, pattern, group) → varchar` — capturing group number `group`.

Pattern `v([0-9.]+)` against `'client/v3.12.0/release'` matches `v3.12.0` at position 7 (the literal `v` anchors, then `[0-9.]+` greedy-captures `3.12.0` until non-matching `/`). Group 1 = `'3.12.0'`. Correct.

Single-backslash `'\S'` in Trino SQL string literal works per memory pin `Trino Regex Backslash` (RAW git-tag 467 regexp.md verifies single backslash in actual SQL; double backslash is a Sphinx rendering artifact on trino.io HTML). Responder used single backslash — correct.

Clean canonical answer, both forms covered, correct group-index semantics.

### Q4 — Iceberg hidden partitioning by month-of-timestamp — **5.0000**

Question: "Can Iceberg partition by month-of-timestamp WITHOUT a separate date column? How do I define it in Trino + dbt? Does Trino auto-prune when I filter on the raw timestamp column?"

Responder:
- "Yes, Iceberg HIDDEN PARTITIONING via transforms."
- DDL: `CREATE TABLE … WITH (partitioning = ARRAY['day(occurred_at)'])` (Trino syntax `day(col)` not `days(col)`).
- Filter on raw timestamp: `WHERE occurred_at >= TIMESTAMP '…' AND occurred_at < TIMESTAMP '…'` — Iceberg applies the transform to the predicate bounds to prune.
- Transform names: `day` / `month` / `year` / `hour` / `bucket(col, N)`.
- dbt config key: `partitioning` (not `partitioned_by`) for Iceberg.

Verified at [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html): partition transforms supported include `year(ts)`, `month(ts)`, `day(ts)`, `hour(ts)`, `bucket(x, nbuckets)`, `truncate(s, nchars)`, and identity. Native Trino spelling is **singular** `day` / `month` / `year` / `hour` (Spark/Iceberg Spark uses plural `days` / `months` / `years` / `hours` — common cross-engine confusion; responder correctly distinguishes).

Auto-prune on raw-timestamp filter verified at [trino.io/blog/2023/04/11/date-predicates.html](https://trino.io/blog/2023/04/11/date-predicates.html) ("Just the right time date predicates with Iceberg") and Starburst's "Iceberg Partitioning and Performance Optimizations in Trino" — Trino applies constant-replacement optimization that pushes filters down to Iceberg, which uses the transform definition to translate raw-column bounds into partition-value bounds and prune at the metadata layer. Caveat (correctly implicit in the responder's bare-range form): a predicate that doesn't align with the partition granularity (e.g., a sub-day window inside a `day()`-partitioned table) still benefits from file-level min/max stats but not full partition elimination.

dbt-trino Iceberg `partitioning` key: Trino's native CREATE TABLE WITH property for the Iceberg connector is **`partitioning = ARRAY[...]`** (verified at iceberg.html — examples consistently use `partitioning = ARRAY['city', 'bucket(userid, 16)']` / `partitioning = ARRAY['month(order_date)']`). dbt-trino's `properties={...}` dict passes the property name through to Trino's WITH clause unchanged, so for Iceberg the correct key inside `properties` is `partitioning` (not `partitioned_by`, which is the Hive-connector property). dbt docs examples occasionally show `partitioned_by` because they target both Hive and Iceberg; responder's "for Iceberg specifically, use `partitioning`" framing is accurate for the prod_info.md stack (Trino 467 + Iceberg connector + Hive Metastore catalog).

Clean canonical answer.

---

## Topics updated

- **Oracle PL/SQL → dbt + Trino SQL migration**: 4.4561/115 → (512.4515 + 3.75)/116 = **4.4500/116 PASSED** (−0.0061, Q1 drag from r27 §4.4C `truncate(x, n)` non-existence misclaim). Margin +0.9500 — still safely above 3.5 even after the drag.
- **Analytical query patterns on Iceberg+Trino**: 4.4571/89 → (396.6819 + 5.0)/90 = **4.4631/90 PASSED** (+0.0060, Q2 lift).
- **SQL query best practices for OLAP**: 4.5607/200 → (912.14 + 5.0)/201 = **4.5629/201 PASSED** (+0.0022, Q3 lift on `regexp_extract` 3-arg canonical).
- **Iceberg partition design for SaaS**: 4.4499/46 → (204.6954 + 5.0)/47 = **4.4616/47 PASSED** (+0.0117, Q4 lift on hidden-partitioning + `day()` singular + `partitioning` key).

ALL required topics REMAIN PASSED. No topic drops below threshold.

---

## Source-verified defects this iter

**1 resource-sourced (Q1):** `resources/27-oracle-plsql-to-dbt-trino.md` §4.4C (lines 1628, 1657, 1665) asserts `truncate(x, n)` 2-arg form does NOT exist in Trino 467 and fabricates a precise wrong-arity error message. RAW Trino 467 docs at trino.io/docs/current/functions/math.html confirm BOTH 1-arg and 2-arg `truncate` overloads exist. LIGHT FIX-A required (see spec in Q1 detail).

**0 responder one-off defects.**

No new defect classes; this is the 5th instance of the documented imported-prior recurring class (assumed-absence direction: assume foreign-looking forms aren't in Trino without verifying). Joins memory pins `Trino starts_with / ends_with`, `Trino to_char Exists`, `Trino listagg Native`, `Trino No array_sum`. Pattern: verify both presence and absence of any function-existence claim against trino.io math/datetime/array/regexp pages directly before asserting.

---

## Watch streams

**No new watch streams opened.** Existing watch streams (all CLOSED as of iter1137): ADD-COLUMN, partition-COUNT-folklore, population-percentile, dedup-tied-tuple, SELECT-*-EXCEPT, `{% if execute %}`, percent_rank-DESC-direction — all remain CLOSED. iter1134 $snapshots-CROSS-JOIN-LATERAL watch: no dbt-table-rebuild Q this iter, watch continues quietly.

---

## Thinnest-margin order after iter1138

1. storage-tiering 4.0739/11 (+0.5739, thinnest required-topic, untouched)
2. dbt-snapshots SCD2 4.1526/16 (+0.6526, untouched)
3. query-perf-basics 4.1771/23 (+0.6771, untouched)
4. cost-considerations 4.3074/23 (+0.8074, untouched)
5. query-perf-regression-diagnosis 4.3436/21 (+0.8436, untouched)
6. Oracle-migration 4.4500/116 (+0.9500, Q1 drag from r27 §4.4C truncate-2-arg defect)
7. Iceberg-partition-design 4.4616/47 (+0.9616, Q4 lift)
8. Analytical-query-patterns 4.4631/90 (+0.9631, Q2 lift)
9. Iceberg-maintenance 4.4800/179 (untouched)
10. federation 4.5024/312 (untouched, fragile-PASS preserved)
11. SQL-best-practices-OLAP 4.5629/201 (+1.0629, Q3 lift)
12. CBO/ANALYZE 4.6105/22 (untouched)
13. improving-complex-SQL-perf-dbt 4.6111/25 (untouched)

---

## RECOMMENDATION = LIGHT FIX-A (single surgical reconciliation)

**FIX-A spec (~10-15 lines, in-place reconcile, no append):**
- `resources/27-oracle-plsql-to-dbt-trino.md` §4.4C lines 1628 / 1657 / 1665 — correct the false "Trino `truncate` is 1-arg only / 2-arg form does NOT exist" claim and the fabricated wrong-arity error text. Replace with the verified two-overload signature `truncate(x) → [same as input]` AND `truncate(x, d) → [same as input]`. Keep workaround as "equivalent verbose form" cross-reference, not the canonical. Keep the (correct) `TRUNC` name defang and `truncate(date)` defang in entries 1, 3, 4.
- Cross-link from r07 §4528+ rounding/truncating canonical to corrected r27 §4.4C.
- Add `verification_date: 2026-06-26` comment with explicit re-verification against trino.io math docs two-arg signature.

**Re-probe queue** (priority order):
1. Oracle-`TRUNC(x, n)`-to-Trino direct re-probe with a different phrasing after FIX-A lands ("Oracle code has `TRUNC(amount, 4)`; what's the Trino form?") — confirm responder reaches `truncate(x, 4)` direct form not the `*power(10,4)/power(10,4)` workaround verbatim.
2. Storage-tiering 12th angle (thinnest required-topic, untouched 5 iters; tiering-keyword-only without MV hint).
3. dbt-snapshots SCD2 17th angle.
4. Iceberg-partition-design follow-up: month()-partition vs day()-partition decision when query patterns are mixed (carry from Q4 hidden-partitioning canonical).
5. Q2 running-MIN 2nd-instance generative re-probe ("highest balance ever seen per account through this snapshot") to sustain MIN-as-window-function canonical.

---

## Pattern observation

21-iter sustainment band: STRONG PASS iters 1090/1092/1093/1117/1118/1119/1121/1122/1125/1127/1128/1131/1133/1134/1137 + LIGHT FIX-A iters 1091/1116/1124/1129/1132/1136/**1138** + NO-OP+WATCH iters 1120/1123/1126/1130/1135.

iter1138 4.6875 STRONG PASS + LIGHT FIX-A is a clean breadth-sweep iter that surfaced a SINGLE resource-sourced factual defect on a NEW dimension (Trino function-inventory absence claim) without any responder one-off slip. Three of four answers at 5.0 with canonical reaches verified against trino.io/docs. The defect is INFORMATIVE — it catches a fabricated wrong-arity error message that would have been a forward-credibility hit for any engineer who tested it, and it's the 5th instance in the imported-prior "assumed-absence" recurring class, suggesting the teacher should add a verification-checklist step for any future "form X does NOT exist in Trino 467" claim.

The Q1 defect does NOT regress Oracle-migration below threshold (margin still +0.9500) and the topic-history math absorbs the drag cleanly. LIGHT FIX-A is the scoped correction; no architectural changes needed; no other resources touched.

No content-lineage erosion; no recurring defect class re-opened (this is a NEW dimension of an existing class — different from the absence-of-function-inventory previous instances which were on directives, not resources); no new watch streams opened.
