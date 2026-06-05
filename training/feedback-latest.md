# Iter 510 — Judge Feedback (EXTENDED PHASE, 2026-06-06)

## Overall result

**OVERALL AVG = (4.9375 + 4.875 + 4.9375 + 4.9375) / 4 = 19.6875 / 4 = 4.9219 — STRONG PASS** (+1.4219 above the 3.5 floor; federation NOT probed; r22 §13.x guardrails + federation rubric row untouched per directive).

Iter510 was the optional teacher polish iteration (r17:1192 `$partitions` current-spec / #12323 gotcha #3 reconciliation). The four probes this round were a fresh sweep across HAVING, Oracle→Trino LPAD/INSTR, Iceberg `sorted_by` file-skipping, and dbt graph operators — three landed at 4.9375 STRONG PASS and one at 4.875 PASS. The single accuracy nit is Q2's missing `CAST(account_id AS VARCHAR)` for numeric account columns; small enough to not depress the iter, but worth a tiny canonical bulletproofing if a future re-probe goes harder on the type-coercion angle.

## Per-question scores

### Q1 — `HAVING` vs `WHERE` (filter groups by aggregate)
**Score: 4.9375 STRONG PASS** (Accuracy 5.0, Clarity 5.0, Actionability 5.0, Completeness 4.75)

- **Verified clean against trino.io/docs/current/sql/select.html**: `HAVING` filters groups after `GROUP BY` aggregates are computed; `WHERE` filters rows before grouping; aggregates not permitted in `WHERE`. Trino 467 implements the standard SQL semantics. `GROUP BY customer_id HAVING COUNT(*) > 100` is valid Trino 467 dialect, no parse-error risk.
- **Advice to put non-aggregate filters in `WHERE` first** is the canonical optimization tip (predicate pushdown, fewer rows entering the aggregator) and correctly framed.
- **Minor -0.25 Completeness**: no mention of the `FILTER (WHERE …)` per-aggregate clause as a third tool, which would round out the "where do I put which filter?" mental model. Non-load-bearing.
- Maps to: **SQL query best practices for OLAP** topic row.

### Q2 — Oracle `LPAD` (zero-pad account numbers) + `INSTR` → Trino
**Score: 4.875 PASS** (Accuracy 4.5, Clarity 5.0, Actionability 5.0, Completeness 5.0)

- **Verified clean against trino.io/docs/current/functions/string.html**: `lpad(string, size, padstring)` signature documented as `lpad(varchar, bigint, varchar) → varchar`. `rpad` is the right-pad counterpart. `strpos(string, substring)` is 1-indexed and returns 0 if the substring is not found — exactly matches Oracle `INSTR` default semantics. The "4-arg `INSTR` has no direct equivalent — chain `strpos` + `substr` or use `regexp_extract_all`" guidance is correct for Trino 467.
- **Accuracy nit (-0.5)**: the answer says LPAD has "identical syntax" and shows `lpad(account_id, 10, '0')` without a cast. Trino does NOT auto-coerce numeric types to `varchar` (per trino.io/docs/current/language/types.html — no implicit numeric↔string conversion). Oracle's `LPAD` DOES auto-coerce a `NUMBER` argument. The question explicitly says "zero-pad account NUMBERS", so a real `account_id` column will almost always be numeric (`BIGINT`/`INTEGER`/`DECIMAL`). The correct Trino 467 form is `lpad(CAST(account_id AS VARCHAR), 10, '0')`. Without the cast the engineer will hit a function-resolution error like `Unexpected parameters (bigint, integer, varchar(1)) for function lpad. Expected: lpad(varchar, bigint, varchar)`. This is a known sister case of the r27 §4.x family canonical "Trino doesn't auto-coerce numeric to string for `||`". Not catastrophic — engineer will see the error within 30 seconds — but a clean answer should pre-empt it.
- **Otherwise STRONG**: 1-indexed/0-on-miss callout, `strpos('hello@world','@')=6` example, 4-arg INSTR routing to `strpos`+`substr` chain.
- Maps to: **Oracle PL/SQL → dbt + Trino SQL migration** topic row.

### Q3 — Iceberg `sorted_by` for file skipping on non-partition column
**Score: 4.9375 STRONG PASS** (Accuracy 5.0, Clarity 5.0, Actionability 5.0, Completeness 4.75)

- **Verified clean against trino.io/docs/current/connector/iceberg.html (WebFetched verbatim)**:
  - (i) `sorted_by` IS a real Iceberg table property on Trino 467 (added in Trino 412), settable at `CREATE TABLE` and modifiable via `ALTER TABLE SET PROPERTIES`. Confirmed in the modifiable-properties list.
  - (ii) Sort-direction qualifiers `ASC NULLS LAST` / `DESC NULLS FIRST` are VALID Trino 467 syntax in `sorted_by` array entries per the official Iceberg connector doc verbatim examples (`'order_date DESC NULLS FIRST'`, `'order_id ASC NULLS LAST'`). The answer's `sorted_by = ARRAY['customer_id ASC NULLS LAST']` is correct.
  - (iii) `SET PROPERTIES sorted_by = …` affects only future writes; existing files retain their previous arrangement, so `ALTER TABLE … EXECUTE optimize` is required to rewrite/cluster existing files per the new sort order. Confirmed correct caveat.
  - (iv) The dbt-trino `properties={'partitioning': "ARRAY[…]", 'sorted_by': "ARRAY[…]"}` Python dict shape is correct — keys are passed verbatim as Iceberg table properties (consistent with the iter495 dbt-trino partitioning-key canonical at r05).
- **Sort-clustering improves min/max data skipping** explanation is accurate: when a file's rows are clustered by `customer_id`, the per-file `min`/`max` stats in the Iceberg manifest become tight intervals, so a predicate `customer_id = 12345` lets the Iceberg connector prune any file whose `[min, max]` interval doesn't contain 12345.
- **Minor -0.25 Completeness**: no callout that `sorted_by` clustering only fully shines for high-selectivity equality / range predicates on the leading sort column, and that a second (non-correlated) sort column gives diminishing returns (sort is hierarchical, not multi-dimensional). Non-load-bearing.
- Maps to: **Iceberg partition design for SaaS** + **Query performance basics: partitioning, indexing strategy for analytics** topic rows.

### Q4 — dbt `--select` graph operators: `model+`, `+model`, `+model+`, `tag:nightly`
**Score: 4.9375 STRONG PASS** (Accuracy 5.0, Clarity 5.0, Actionability 5.0, Completeness 4.75)

- **Verified clean against docs.getdbt.com/reference/node-selection/graph-operators + /methods**:
  - `+model` = the model plus all **upstream** ancestors (feeders) — correct.
  - `model+` = the model plus all **downstream** descendants (consumers) — correct.
  - `+model+` = both directions — correct.
  - `tag:nightly` = all models with the `nightly` tag — correct per the `tag:` selector method.
  - yaml `tags:` config example + cron-driven `dbt build --select tag:nightly` usage is the canonical SaaS pattern.
- **Minor -0.25 Completeness**: no mention of the **n-plus operator** (`2+model` / `model+3`) for fine-grained ancestor/descendant depth, and no callout that comma (no space) = intersection vs space = union for combining selectors. Non-load-bearing, but the n-plus form is a known canonical follow-up for engineers building tag-based CI pipelines.
- Maps to: **Oracle PL/SQL → dbt + Trino SQL migration** topic row (dbt model selection / CI patterns family).

---

## Verification summary

| Claim | Source | Status |
|---|---|---|
| `HAVING` filters groups after `GROUP BY`, `WHERE` filters rows before, aggregates not allowed in `WHERE` | trino.io/docs/current/sql/select.html | **CLEAN** |
| `lpad(varchar, bigint, varchar) → varchar` signature | trino.io/docs/current/functions/string.html | **CLEAN signature** |
| Trino does NOT auto-coerce numeric → varchar for `lpad` first arg (cast required) | trino.io/docs/current/language/types.html | **CLEAN — but answer OMITTED the required `CAST` for numeric `account_id` (Q2 nit)** |
| `strpos` 1-indexed, returns 0 if not found | trino.io/docs/current/functions/string.html | **CLEAN** |
| 4-arg Oracle `INSTR` has no direct Trino equivalent; chain `strpos`+`substr` or `regexp_extract_all` | trino.io/docs/current/functions/string.html + /functions/regexp.html | **CLEAN** |
| `sorted_by` is a real Iceberg table property, settable at CREATE + via ALTER SET PROPERTIES | trino.io/docs/current/connector/iceberg.html | **CLEAN** |
| `ASC NULLS LAST` / `DESC NULLS FIRST` qualifiers valid in `sorted_by` array entries | trino.io/docs/current/connector/iceberg.html | **CLEAN** |
| `SET PROPERTIES sorted_by` affects future writes only; `EXECUTE optimize` rewrites existing files | trino.io/docs/current/connector/iceberg.html | **CLEAN** |
| Sort clustering tightens per-file min/max → improved file skipping | trino.io + starburst Iceberg sort blog | **CLEAN** |
| dbt-trino `properties` dict with `partitioning` + `sorted_by` keys | iter495 canonical at r05 + dbt-trino docs | **CLEAN** |
| dbt graph operators `+model` / `model+` / `+model+` semantics | docs.getdbt.com/reference/node-selection/graph-operators | **CLEAN** |
| `tag:nightly` selector method | docs.getdbt.com/reference/node-selection/methods | **CLEAN** |

**Net**: 11 of 12 verification points clean; 1 minor accuracy nit (Q2 `lpad` numeric-cast omission).

---

## Topic row updates (federation NOT touched)

- **SQL query best practices for OLAP** (Q1 HAVING vs WHERE): 4.5552/62 → (4.5552·62 + 4.9375) / 63 = (282.4224 + 4.9375) / 63 = 287.3599 / 63 = **4.5613/63** (+0.0061).
- **Oracle PL/SQL → dbt + Trino SQL migration** (Q2 LPAD/INSTR + Q4 dbt graph operators both map here): 4.5280/73 → (4.5280·73 + 4.875 + 4.9375) / 75 = (330.5440 + 9.8125) / 75 = 340.3565 / 75 = **4.5381/75** (+0.0101).
- **Iceberg partition design for SaaS** (Q3 sorted_by maps here as the sort-clustering / file-skipping cousin of partitioning): 4.4947/36 → (4.4947·36 + 4.9375) / 37 = (161.8092 + 4.9375) / 37 = 166.7467 / 37 = **4.5067/37** (+0.0120).
- **Query performance basics: partitioning, indexing strategy for analytics** (Q3 also maps here — sorted_by IS the "indexing strategy" answer for non-partition predicates): 4.3491/19 → (4.3491·19 + 4.9375) / 20 = (82.6329 + 4.9375) / 20 = 87.5704 / 20 = **4.3785/20** (+0.0294).
- **Federation row**: 4.49944/310 **UNCHANGED** (not probed; r22 §13.x guardrails untouched per directive).

---

## Concrete next-teacher actions (iter511, OPTIONAL low-priority polish)

If iter511 is another optional polish slot (extended phase, 109th+ consecutive pass), the **single** highest-value reconcile-in-place edit is:

**Candidate A (HIGHEST priority, Q2 nit fix)** — r27 §4.x Oracle→Trino LPAD/RPAD canonical: add a **one-line gotcha** under the existing LPAD migration entry stating "Trino does NOT auto-coerce numeric → varchar. Oracle `LPAD(account_id, 10, '0')` on a NUMBER column → Trino `lpad(CAST(account_id AS VARCHAR), 10, '0')`. Without the cast you get `Unexpected parameters (bigint, integer, varchar(1)) for function lpad. Expected: lpad(varchar, bigint, varchar)`." This reconciles with the existing r27 §4.x family (concat-`||` no-numeric-coercion canonical) and pre-empts the iter510 Q2 accuracy nit on any future re-probe. Estimated +2 lines, well under the iter509-style ≤8 line budget. Findability is excellent because the keyword "LPAD" routes the Haiku responder directly to r27 §4.x.

**Candidate B (LOWER priority, completeness polish)** — r17 or r05 Iceberg `sorted_by` canonical: add a one-line callout "`sorted_by` clustering is hierarchical — the leading sort column gets the tightest min/max intervals; secondary sort columns get progressively weaker file-skipping." Iter510 Q3 already STRONG PASS at 4.9375 so this is purely defensive against a future "two-column sorted_by" probe.

**Candidate C (LOWER priority, completeness polish)** — r27 dbt graph operators canonical: add an n-plus operator example (`2+model_name` / `model_name+3`) + intersection-vs-union (`,` vs space). Iter510 Q4 already STRONG PASS at 4.9375 so this is also defensive.

**Recommend Candidate A** — it's the only one with an actual accuracy gap exposed in this iter, and the fix is small + reconciles with an existing canonical family.

---

## Judge probe targets for iter511

1. **HIGH — LPAD numeric-cast re-probe**: "I have `account_id BIGINT` and need to zero-pad to 10 digits — `lpad(account_id, 10, '0')` is giving me a function-resolution error, what's wrong?" (verifies Candidate A landed if teacher edits r27).
2. **HIGH — `sorted_by` multi-column hierarchical probe**: "If I set `sorted_by = ARRAY['customer_id', 'product_id']`, will I get good file skipping on both columns?" (verifies Q3 holds under a sneakier angle).
3. **MEDIUM — dbt n-plus operator**: "I want to run a model plus its immediate parents but NOT its grandparents — can I do `1+model_name`?" (verifies Q4 holds + tests Candidate C if teacher edits).
4. **MEDIUM — `FILTER (WHERE …)` per-aggregate clause**: "Can I filter rows that go into ONE aggregate but not another in the same SELECT?" (probes the third tool beyond WHERE/HAVING that Q1 omitted — already cleanly covered in r07 §1a.2 per iter509 canonical, so this should land STRONG).
5. **LOW — federation stays UNPROBED** (r22 §13.x guardrails / federation rubric row 4.49944/310 stays locked per the iter472-510 directive chain).

---

## Pattern notes across iter510

- **109th consecutive overall PASS** in extended phase. Margin +1.4219 above the 3.5 floor (very close to iter509's +1.4375 — second-highest in recent 7-iter window).
- All four answers ≥ 4.875 — well-calibrated, no outliers, no fabrications.
- The one accuracy nit (Q2 `lpad` numeric cast) is the kind of small Trino-vs-Oracle dialect detail that benefits from a single-line canonical bulletproofing — fits the iter509-iter510 reconcile-don't-append polish cadence exactly.
- No federation drift; r22 §13.x guardrails confirmed untouched; federation rubric row 4.49944/310 unchanged.
- Teacher's iter510 r17:1192 `$partitions` current-spec / #12323 gotcha #3 reconciliation was not exercised this probe sweep (no `$partitions` question this round), so its bulletproofing payoff will land in a future iter when Q1-style `$partitions` re-probes hit.
