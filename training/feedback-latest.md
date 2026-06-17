# Judge Feedback — iter989 (EXTENDED PHASE breadth sweep)

**OVERALL 4.3672 — PASS** (Q1 3.125 / Q2 4.8125 / Q3 4.6875 / Q4 4.84375 = 17.46875/4 = 4.3672; margin +0.867; OVERALL AVERAGE governs, no per-Q veto — Q1 folklore does NOT sink the iter).

All 4 questions verified BOTH directions against trino.io/docs/467 + Trino source / GitHub issues (sql/select.html DISTINCT semantics + optimizer hash-aggregation planning; functions/string.html split_part/split; functions/array.html element_at; functions/comparison.html BETWEEN + VARCHAR↔TIMESTAMP coercion; trinodb/trino #7334 timestamp<varchar type error; Querify Labs distinct-aggregation plan note) — NOT against resources/. Prod stack (Trino 467 Iceberg + Hive Metastore on-prem MinIO + Spark ingestion + dbt): all four answers fit; NO federation drag-in.

---

## ★ Q1 — DISTINCT vs GROUP BY for unique customer/month combos — **3.125 — ACCURACY DEFECT (FALSE PERFORMANCE FOLKLORE)**

The engineer asked a precise question: "Real difference, or interchangeable for unique combinations?" **The correct answer is: YES, they are interchangeable.** For a pure unique-combination query with NO aggregate functions, `SELECT DISTINCT customer_id, month FROM invoices` and `SELECT customer_id, month FROM invoices GROUP BY customer_id, month` are SEMANTICALLY EQUIVALENT and Trino plans them essentially IDENTICALLY — both lower to an `AggregationNode` whose grouping keys are the selected columns, with no aggregate functions. Same operator, same hash-aggregation, no meaningful performance difference. Use whichever is clearer.

**The responder's answer is WRONG on the central claim.** It said:
- "They are NOT interchangeable in Trino 467" — **FALSE** (they are interchangeable here).
- "GROUP BY can leverage Trino's hash aggregation and cost-based optimizer better than DISTINCT" — **FALSE**; SELECT DISTINCT uses the same hash aggregation.
- "DISTINCT is more of a dedup-rows-after-fetching-everything operation" — **FALSE MECHANISM**; DISTINCT does not "fetch everything then dedup" — it is an aggregation over the distinct columns, identical to GROUP BY.
- "GROUP BY signals intent to the optimizer and will perform better" — **FALSE FOLKLORE**.

The verification nuance the responder confused: COUNT(DISTINCT x) / MULTIPLE distinct aggregations (MarkDistinct operator) CAN have plan/perf differences vs GROUP BY-based rewrites — but that is a DIFFERENT case (distinct *aggregation*), NOT the bare `SELECT DISTINCT a, b` row-dedup the engineer asked about. The responder appears to have imported the "GROUP BY beats DISTINCT" folklore (a common SQL-Server/MySQL-era myth) and mis-applied it.

★ **CLASSIFICATION:** This reads like a RESPONDER PERFORMANCE-FOLKLORE slip (broken-justification / unsupported-perf-claim family), NOT obviously a resource quote — the false mechanism ("DISTINCT fetches everything then dedups") and the vague "signals intent / CBO leverages it better" are classic invented justifications. **HOWEVER it must be root-caused: orchestrator PHASE 6 must GREP resources/ for any "GROUP BY faster than DISTINCT" / "DISTINCT dedups after fetching" / "DISTINCT is slower" content.** If a resource asserts this → RESOURCE DEFECT, reconcile-in-place (state DISTINCT vs GROUP BY are equivalent for pure dedup; only COUNT(DISTINCT)/multi-distinct aggregation differs). If no resource says it → confirmed responder folklore slip; re-probe-don't-churn, but if it recurs 2-in-2 a LIGHT additive note is warranted ("`SELECT DISTINCT a,b` == `GROUP BY a,b`, same plan; no perf winner; the DISTINCT-vs-GROUP-BY perf story only applies to COUNT(DISTINCT) aggregations").

Partial credit: the recommended query itself is valid Trino and returns the correct result, and the engineer would not be harmed operationally — but they were given a wrong mental model and a false "your teammate is right for perf reasons" verdict. Acc 2.0 / Clar 3.75 / App 3.25 / Comp 3.5.

---

## Q2 — Cast dirty CSV `amount` ('N/A'/blank) without killing query — **4.8125 CLEAN**

VERIFIED CORRECT. `TRY_CAST(amount AS DECIMAL(10,2))` returns NULL on any value that cannot be cast (blanks, 'N/A'), and the query completes — whereas plain `CAST` throws and aborts the whole query. Confirmed Trino 467 semantics (TRY_CAST = CAST that returns NULL instead of raising on failure). The TRY_CAST-vs-CAST contrast table is accurate and directly actionable. Exactly the right tool for dirty-CSV ingestion. Acc 5.0 / Clar 4.75 / App 4.75 / Comp 4.75.

---

## Q3 — BETWEEN inclusivity + TIMESTAMP-vs-date-string — **4.6875 — LARGELY CORRECT, minor wording imprecision**

Both core claims VERIFIED:
- ★ **BETWEEN is inclusive of both endpoints** (`value BETWEEN min AND max` == `value >= min AND value <= max`) — CONFIRMED comparison.html.
- ★ **VARCHAR-vs-TIMESTAMP type error CONFIRMED.** Trino 467 does NOT implicitly coerce a bare quoted string ('2024-03-01' = VARCHAR) to TIMESTAMP/DATE in a comparison; `timestamp_col BETWEEN '2024-03-01' AND '2024-03-31'` raises a type-mismatch error ("Cannot apply operator: timestamp < varchar", trinodb/trino #7334). Trino coerces numeric↔numeric and char↔char but NOT char↔temporal. The responder's "the query will fail with a type error" is CORRECT.
- ★ **Half-open fix CORRECT and is the right recommendation for a TIMESTAMP column:** `billing_period_end >= DATE '2024-03-01' AND billing_period_end < DATE '2024-04-01'` avoids the midnight-fencepost bug where `BETWEEN ... DATE '2024-03-31'` (inclusive right endpoint at 00:00:00) silently drops March-31 rows with a time-of-day after midnight. Strong, production-correct guidance.

Minor (the only ding): the responder wrote "Trino does NOT implicitly coerce VARCHAR to TIMESTAMP **WITH TIME ZONE**." The column is plain `TIMESTAMP`, not `TIMESTAMP WITH TIME ZONE`; the "WITH TIME ZONE" qualifier is gratuitous/imprecise. The no-coercion conclusion holds regardless of which timestamp type the column is, so this is a cosmetic wording slip, not a logic error. Acc 4.5 / Clar 4.75 / App 4.75 / Comp 4.75.

---

## Q4 — Extract last path segment (Postgres negative split_part index) — **4.84375 CLEAN**

VERIFIED CORRECT both ways:
- ★ **split_part requires a POSITIVE 1-based index in Trino 467** — "Field indexes start with 1"; no negative index support (out-of-range returns NULL, negative is invalid). Postgres' `split_part(url,'/',-1)` does NOT work in Trino — CONFIRMED. Correctly attributed to Postgres-only.
- ★ **`element_at(split(referrer_url, '/'), -1)` is the correct idiom.** `split(string, delim)` returns an array (CONFIRMED string.html); `element_at(array, -1)` returns the LAST element — element_at supports negative indices ("If index < 0, element_at accesses elements from the last to the first", array.html). CONFIRMED.
- The worked trace `split(url,'/') = ['https:','','partner.example.com','promo','SUMMER2024'] → element_at(...,-1) = 'SUMMER2024'` is accurate (note the empty string at index 2 from the `//` — correctly shown, does not affect the last-segment result).
- Bonus `element_at(split(file_path,'.'),-1)` for file extension is a correct, useful generalization.

Acc 5.0 / Clar 4.75 / App 4.75 / Comp 4.875.

---

## Scope notes / tic audit

- ★ **Q1 DISTINCT-vs-GROUP-BY "not interchangeable / GROUP BY faster" = FALSE PERFORMANCE FOLKLORE accuracy defect.** They ARE equivalent for pure unique-combination dedup in Trino 467 (same AggregationNode plan, no perf winner). False mechanism ("DISTINCT fetches everything then dedups") + invented justification ("signals intent / CBO leverages it better"). Reads like a RESPONDER folklore slip (unsupported-perf-claim / broken-justification family) — **FLAGGED FOR ORCHESTRATOR PHASE-6 resource grep** ("GROUP BY faster than DISTINCT" / "DISTINCT dedups after fetching" / "DISTINCT is slower"). If found in a resource → RESOURCE DEFECT reconcile-in-place; if not → responder folklore, re-probe-don't-churn (2-in-2 → LIGHT additive note: DISTINCT==GROUP BY for row-dedup; perf story is COUNT(DISTINCT)-only).
- **Q2** TRY_CAST-returns-NULL / CAST-throws CLEAN.
- **Q3** BETWEEN-inclusive (>=AND<=) CONFIRMED + VARCHAR-vs-TIMESTAMP type-error CONFIRMED (#7334, no char↔temporal coercion) + half-open `>= DATE ... AND < DATE ...` fix CORRECT for the midnight fencepost; only "WITH TIME ZONE" wording imprecise (column is plain TIMESTAMP, point holds).
- **Q4** split_part-no-negative-index (1-based, Postgres-only negative) CONFIRMED + `element_at(split(),-1)` last-segment idiom CONFIRMED (element_at negative-index from tail, split→array).

TICS otherwise CLEAN: no QUALIFY / false-mechanism-semi-join-mislabel / MAX-varchar / percent_rank-inversion / fabricated-fn-or-rule (TRY_CAST, split, element_at, BETWEEN all real & correctly described; split_part-negative correctly ABSENT) / PARTITIONED-BY-foreign-DDL / aggregate-in-GROUP-BY / broken-secondary / ILIKE-conflation / mid-churn / missing-CTE-col / JOIN-fan-out / ts-minus-ts / column-scope. The ONE accuracy defect is Q1's DISTINCT-vs-GROUP-BY perf folklore (unsupported-perf-claim family).

**iter990 RECOMMENDATION = DEFAULT NO-OP pending PHASE-6 grep on Q1 DISTINCT-vs-GROUP-BY folklore** (overall margin +0.867 PASS; Q2/Q3/Q4 all leads correct & verified both directions; Q1 is the sole defect and reads responder-side, but MUST be resource-grepped before disposition). Re-probe: (a) another DISTINCT vs GROUP BY / dedup-vs-aggregate Q — watch the "GROUP BY faster" folklore recur (2-in-2 → reconcile resource or LIGHT additive note: they're the same plan for pure dedup); (b) another temporal-predicate-on-TIMESTAMP Q — confirm half-open `>= DATE ... AND < DATE ...` lead + VARCHAR-no-coercion stay correct, watch "WITH TIME ZONE" over-qualification. Federation r22 §13.x hard-locked NOT probed (OVERRIDDEN). NO resource edits. DO NOT bump training/state.json (already 989; passed=true preserved; final_iterations_remaining 0).
