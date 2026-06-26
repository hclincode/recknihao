# Iter1135 Feedback — 4.4844 PASS NO-OP+WATCH: Q2 PERCENT_RANK-DESC-direction misapplication = RESPONDER ONE-OFF (canonical present in r07 §3939-3956 + §3962-4023, first-instance on "spent more than X% of peers" phrasing)

## Verdict summary

| Item | Status |
|---|---|
| Iter average | 4.4844 PASS (margin +0.9844 above 3.5 floor) |
| Q1 ADD_MONTHS → date_add + last_day_of_month + clamp wrapper | CLEAN 4.9375 — EXACT r27 §666 LEADING CANONICAL match (clamp-up rule replicated correctly) |
| Q2 PERCENT_RANK DESC + "spent more than 73% of peers" | DEFECT 3.0000 — direction misapplication; **labeling backwards** |
| Q3 flatten(array(array(T))) + CROSS JOIN UNNEST | CLEAN 5.0000 — source-verified single-level collapse |
| Q4 Iceberg time travel FOR VERSION/TIMESTAMP AS OF + `$snapshots` lookup | CLEAN 5.0000 — syntax + retention caveat correct |
| New defects this iter | 1 (Q2 only — direction misapplication) |
| Resource defects discovered | 0 (canonicals present and correct) |
| Recommendation | **NO-OP + WATCH** (Q2 first instance; canonicals present; re-probe next sweep) |

## Per-question scoring

### Q1 (4.9375) — Oracle `ADD_MONTHS(invoice_date, 3)` + `LAST_DAY(invoice_date)` → Trino

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 5.0 | `date_add('month', 3, invoice_date)` verified at [trino.io/docs/current/functions/datetime.html](https://trino.io/docs/current/functions/datetime.html). `last_day_of_month(x) → date` verified (accepts date/timestamp/timestamp with tz). Oracle ADD_MONTHS clamp-up rule verified at [docs.oracle.com/en/database/oracle/oracle-database/26/sqlrf/ADD_MONTHS.html](https://docs.oracle.com/en/database/oracle/oracle-database/26/sqlrf/ADD_MONTHS.html): "If date is the last day of the month or if the resulting month has fewer days than the day component of date, then the result is the last day of the resulting month." The responder's wrapper `CASE WHEN invoice_date = last_day_of_month(invoice_date) THEN last_day_of_month(date_add('month',3,invoice_date)) ELSE date_add('month',3,invoice_date) END` matches r27 §666-701 LEADING CANONICAL exactly, including the rationale ("Oracle ADD_MONTHS clamps last-day-of-month while Trino preserves day-number"). |
| Clarity | 4.75 | Clean three-part structure (function 1 / function 2 / wrapper for semantic mismatch). |
| Applicability | 5.0 | Engineer can drop the wrapper into the migrated SQL verbatim. |
| Completeness | 5.0 | Covers both functions AND the silent-divergence trap. |

**Source-verified**: r27 §666-701 LEADING CANONICAL "Oracle ADD_MONTHS → Trino (END-OF-MONTH CLAMP SEMANTICS DIFFER)" hit cleanly. The responder reached the canonical via the keyword path and produced its wrapper form. Oracle migration content lineage durable.

### Q2 (3.0000) — "you spent more than 73% of your peers" — DIRECTION MISAPPLICATION

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 2.5 | **Internally inconsistent.** The responder correctly states the math: "PERCENT_RANK = (rank-1)/(rows-1)", "0 for the highest row when sorted DESC and increases toward 1.0". But the example labeling contradicts the math: under `ORDER BY total_spent DESC`, a customer with `percent_rank = 0.73` is at rank ≈ `0.73*(N-1)+1` — that is, 73% of the way DOWN the DESC list, meaning ~73% of peers spent MORE than them, NOT less. The responder labeled this row "spent more than 73% of peers" — that interpretation is BACKWARDS for the DESC ordering they used. For "spent more than X% of peers", the correct shapes are: (a) `percent_rank() OVER (ORDER BY total_spent ASC)` (with ASC, 0.73 means 73% are below = beat 73%); OR (b) `cume_dist() OVER (ORDER BY total_spent ASC)` for the at-or-below fraction; OR (c) keep DESC and change the label to "73% of peers spent MORE than you". |
| Clarity | 4.0 | Writing is clean; CUME_DIST contrast mentioned. But the labeled example actively misleads. |
| Applicability | 2.5 | Engineer who copies the answer ships a customer-facing dashboard message saying "you spent more than 73% of peers" to a customer who actually beat only ~27% — a real SaaS-product-shipping bug on the percentile direction. |
| Completeness | 3.5 | Touches function and ORDER BY shape; misses the direction-to-semantic mapping discipline. Does not engage r07 §3939-3956 at-or-below `cume_dist` canonical or §3962+ direction guardrail. |

**Defect verified.** PERCENT_RANK semantics per [trino.io/docs/current/functions/window.html](https://trino.io/docs/current/functions/window.html): `(r - 1) / (n - 1)` where r is the rank in window-ordering. Under `ORDER BY metric DESC`: first row (highest metric) gets rank 1 → percent_rank 0.0; last row gets 1.0. A row with percent_rank 0.73 sits at rank ≈ 73% of the way through the DESC ordering = far down the metric distribution = beat only ~27% of peers. Responder's "$45k → 0.73 'spent more than 73% of peers'" annotation under DESC is BACKWARDS.

**Classification: RESPONDER ONE-OFF on direction-to-semantic mapping.** Resource canonicals ARE present and correct:
- r07 §3939-3956 (LEADING CANONICAL "fraction at or below / what percentile does this value sit at"): "**`cume_dist() OVER (ORDER BY value)`** — fraction of rows AT OR BELOW (lowest ≈ `1/N`, top = `1.0`, ties included). This is the answer for 'fraction at or below / what percentile does this value sit at'." Plus explicit DO-NOT-WRITE: "`percent_rank() OVER (ORDER BY value)` for 'fraction of rows at or below' — **WRONG**: `percent_rank`'s lowest row = `0.0` (it measures rank POSITION `(rank-1)/(n-1)`, NOT the at-or-below fraction); use `cume_dist()` — DO NOT COPY for at-or-below."
- r07 §3962-4023 LEADING CANONICAL "PERCENT_RANK / NTILE direction guardrail" with decision table + DO-NOT-WRITE inverted-prose defang ("`PERCENT_RANK = 0.0` means the bottom, `1.0` means the top is WRONG in general — it is true only under ORDER BY metric ASC. Under ORDER BY metric DESC, 0.0 is the TOP and 1.0 is the BOTTOM").

The canonical correctly states both the function-choice rule (cume_dist for at-or-below) AND the direction discipline (always pair threshold with sort direction). Responder failed to navigate to either canonical despite the question phrasing ("spent more than 73% of peers" = at-or-below semantics) being keyword-magnetic to the cume_dist canonical AND the direction guardrail. Synthesis slip, not a resource gap.

**First instance on this specific question phrasing.** Memory log enumerates many prior responder-direction slips on percentile (iter635 inversion → resource defangs added; iter1127 population-vs-per-group), but this specific "spent more than X% of peers" customer-facing-percentile-message phrasing has not surfaced before. Per first-instance NO-OP discipline (iter1116/1120/1123/1126/1130/1132 precedent), classify as RESPONDER ONE-OFF and watch.

**Recommendation: NO-OP + WATCH.** Re-probe within 2-3 iters with another "you spent more than X% of your peers" / "you beat X% of customers" / "you're in the top X%" customer-facing-percentile-message phrasing to confirm direction-to-semantic mapping is durable. If RECURS → LIGHT FIX-A adding a keyword-magnetic LEAD card on the "spent more than X% of peers" / "you beat X%" phrasing pointing to the §3939-3956 cume_dist canonical + §3962+ direction guardrail with a question-shape match line ("when the customer-facing message reads 'you spent more / beat X% of peers', you want the AT-OR-BELOW semantic = `cume_dist() OVER (ORDER BY metric ASC)`, NOT `percent_rank DESC`").

### Q3 (5.0000) — flatten(array(array(T))) → array(T)

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 5.0 | `flatten(x) → array` verified at [trino.io/docs/current/functions/array.html](https://trino.io/docs/current/functions/array.html): "Flattens an `array(array(T))` to an `array(T)` by concatenating the contained arrays." Single-level collapse (NOT recursive — fine for the 2-level "permission groups" shape). `CROSS JOIN UNNEST(flatten(...))` correct downstream pattern. |
| Clarity | 5.0 | Direct, single-built-in answer. |
| Applicability | 5.0 | Drop-in for the Iceberg array(array(varchar)) → array(varchar) collapse. |
| Completeness | 5.0 | Covers the flatten + downstream UNNEST flow. |

### Q4 (5.0000) — Iceberg time travel for "before the bad write 4h ago"

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 5.0 | `FOR VERSION AS OF <snapshot_id>` and `FOR TIMESTAMP AS OF TIMESTAMP '...'` syntax verified at [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html). `"tbl$snapshots"` metadata table with `committed_at` (TIMESTAMP(3) WITH TIME ZONE) verified. `WHERE committed_at < bad-run-time` lookup pattern correct (then ORDER BY committed_at DESC LIMIT 1 gives the latest at-or-before snapshot). Retention caveat ("snapshots past expire_snapshots retention are gone, ~7d typical, 4h is fine") accurate. |
| Clarity | 5.0 | Clear sequence: find snapshot via metadata table → query at version/timestamp. |
| Applicability | 5.0 | Engineer runs the lookup, gets snapshot_id, queries with FOR VERSION AS OF — exact recovery path. |
| Completeness | 5.0 | Both VERSION and TIMESTAMP forms shown, retention boundary called out. |

## Iter summary table

| Q | Accuracy | Clarity | Applicability | Completeness | Avg |
|---|---|---|---|---|---|
| Q1 | 5.0 | 4.75 | 5.0 | 5.0 | 4.9375 |
| Q2 | 2.5 | 4.0 | 2.5 | 3.5 | 3.0000 |
| Q3 | 5.0 | 5.0 | 5.0 | 5.0 | 5.0000 |
| Q4 | 5.0 | 5.0 | 5.0 | 5.0 | 5.0000 |
| **Iter avg** | | | | | **4.4844 PASS** |

## Topics updated

- **Oracle PL/SQL → dbt+Trino migration** (Q1, ADD_MONTHS canonical): 4.4519/114 → (4.4519×114 + 4.9375)/115 = (507.5166 + 4.9375)/115 = **4.4561/115 PASSED** (+0.0042, margin +0.9561).
- **Analytical query patterns on Iceberg+Trino** (Q2, percentile direction): 4.4948/86 → (4.4948×86 + 3.0)/87 = (386.5528 + 3.0)/87 = **4.4776/87 PASSED** (−0.0172, drag from Q2 direction misapplication; margin +0.9776 still safely above 3.5).
- **SQL query best practices for OLAP** (Q3, array flatten built-in): 4.5527/195 → (4.5527×195 + 5.0)/196 = (887.7765 + 5.0)/196 = **4.5550/196 PASSED** (+0.0023).
- **Iceberg table maintenance** (Q4, snapshot time travel): 4.4771/178 → (4.4771×178 + 5.0)/179 = (796.9238 + 5.0)/179 = **4.4800/179 PASSED** (+0.0029).

ALL required topics REMAIN PASSED.

## Source-verified absences / non-defects this iter

- Zero ::/QUALIFY/false-semi-join/fabricated-fn/regex-backslash/INTERVAL-quarter-week/OFFSET-before-LIMIT/CAST-truncate/EXECUTE-rollback-on-467/Spark-Oracle-spillover/imported-prior/GREATEST-NULL-Postgres/array_sum/`->`/`->>`-JSON/DATEDIFF-dialect-import/multi-arg-COUNT-DISTINCT/ts-minus-ts/over-warning/multi-clause-ADD-COLUMN/contains_sequence-array_position-arithmetic/partition-column-COUNT-data-file-folklore/population-vs-per-group-percentile/dedup-tied-tuple/SELECT-*-EXCEPT/`CAST(md5 AS VARCHAR)`-mis-hex/`{% if execute %}`/$snapshots-CROSS-JOIN-LATERAL recurrence.
- Q1 r27 §666 ADD_MONTHS LEADING CANONICAL = reach confirmed (clamp-up wrapper verbatim).
- Q3 flatten() single-level collapse + downstream UNNEST = reach confirmed.
- Q4 FOR VERSION/TIMESTAMP AS OF + `$snapshots` committed_at lookup + retention caveat = reach confirmed.

## NEW WATCH STREAM (Q2)

**Stream**: PERCENT_RANK direction-to-semantic misapplication on customer-facing "spent more than X% of peers" / "you beat X% of customers" phrasing.

**Symptom**: responder uses `PERCENT_RANK() OVER (ORDER BY metric DESC)` and labels the 0.73 row as "spent more than 73% of peers" — under DESC that row beats only ~27%; the label is backwards.

**Correct shapes**:
1. `cume_dist() OVER (ORDER BY metric ASC)` — fraction at-or-below; 0.73 → "spent more than ~73% of peers" (this is r07 §3939-3956 LEADING CANONICAL for at-or-below semantics).
2. `percent_rank() OVER (ORDER BY metric ASC)` — 0.73 → ~73% of peers below.
3. Keep DESC, flip the label to "73% of peers spent MORE than you".

**Watch action**: re-probe within 2-3 iters with another customer-facing percentile-message phrasing — e.g., "show each customer 'you beat X% of all customers this month' on the dashboard", or "we want to label users with 'you used the product more than 80% of teams this week'". Force the customer-facing-percentile semantic.

**Escalation rule**: if RECURS → LIGHT FIX-A adding a keyword-magnetic LEAD card at r07 (near §3939 or §3962) on the "spent more than X% / beat X% / above X% of peers" customer-facing phrasing, with a one-line question-shape→function-choice→direction mapping. Don't preemptively edit — r07 already has both cume_dist-at-or-below LEADING CANONICAL and PERCENT_RANK direction guardrail; the question is whether the responder navigates there on the customer-facing-message phrasing.

## Thinnest-margin order after iter1135

| Topic | Avg / N | Margin to 3.5 |
|---|---|---|
| Storage-tiering | 4.0739 / 11 | +0.5739 (thinnest required-topic; untouched) |
| dbt-snapshots SCD2 | 4.1526 / 16 | +0.6526 (untouched) |
| Query-perf-basics | 4.1771 / 23 | +0.6771 (untouched) |
| Cost-considerations | 4.2759 / 22 | +0.7759 (untouched) |
| Query-perf-regression-diagnosis | 4.3108 / 20 | +0.8108 (untouched) |
| Oracle-migration | **4.4561 / 115** | +0.9561 (Q1 lift) |
| Analytical-query-patterns | **4.4776 / 87** | +0.9776 (Q2 drag, still safely PASS) |
| Iceberg-maintenance | **4.4800 / 179** | +0.9800 (Q4 lift) |
| Federation | 4.5024 / 312 | +1.0024 (untouched, fragile-PASS preserved) |
| SQL-best-practices-OLAP | **4.5550 / 196** | +1.0550 (Q3 lift) |
| CBO/ANALYZE | 4.6105 / 22 | +1.1105 (untouched) |
| Improving-complex-SQL-perf-dbt | 4.6111 / 25 | +1.1111 (untouched) |

## RECOMMENDATION = NO-OP + WATCH

Commit rubric + feedback only. No resource edits.

Reasoning:
- Q2 defect is RESPONDER ONE-OFF on direction-to-semantic mapping (NOT resource-sourced).
- r07 §3939-3956 cume_dist-at-or-below LEADING CANONICAL is present AND correct.
- r07 §3962-4023 PERCENT_RANK direction guardrail is present AND correct (with DO-NOT-WRITE inverted-prose defang).
- First instance of this specific "spent more than X% of peers" customer-facing-message phrasing → per first-instance NO-OP discipline (iter1116/1120/1123/1126/1130/1132 precedent — 6 prior cases, 5 closed on first re-probe).
- Q1, Q3, Q4 all clean canonical reaches; content lineage durable.
- Iter avg 4.4844 well above PASS floor (+0.9844 margin).
- No new defect classes; no recurring defect class re-opened.

## Re-probe queue

1. **Q2 customer-facing percentile-message** (PRIORITY 1, NEW WATCH): re-probe with phrasing like "we want to label users with 'you logged more sessions than X% of teams this week'" — must FORCE the at-or-below customer-facing-message semantic and see if responder reaches cume_dist or stays on percent_rank DESC.
2. Storage-tiering 12th angle (thinnest required-topic at 4.0739; tiering-keyword-only phrasing without MV hint — confirm iter1134's LIGHT FIX-A cross-ref reach).
3. Q4 dbt-table-rebuild generative re-probe to confirm iter1134's $snapshots-CROSS-JOIN-LATERAL broken-secondary was one-off.
4. dbt-snapshots SCD2 17th angle.
5. Cost-considerations 23rd angle.
6. Query-perf-regression-diagnosis 21st angle.

## Pattern observation

18-iter sustainment band shape:
- STRONG PASS: iters 1090/1092/1093/1117/1118/1119/1121/1122/1125/1127/1128/1131/1133/**1134**
- LIGHT FIX-A: iters 1091/1116/1124/1129/1132
- NO-OP + WATCH (this iter pattern): iters 1120/1123/1126/1130/**1135**

iter1135 4.4844 PASS+NO-OP+WATCH matches the iter1130 4.5469 / iter1126 4.5 PASS+NO-OP+WATCH profile — single Q with a real synthesis defect on novel question phrasing, responder-one-off classification, first-instance discipline preserved, three breadth angles clean with two canonical reaches (Q1 r27 §666 ADD_MONTHS clamp, Q4 Iceberg time travel) and one trivial built-in (Q3 flatten). The Q2 defect is informative — the at-or-below cume_dist canonical and the direction guardrail are both present in r07 BUT the customer-facing "you spent more than X% of peers" phrasing variant didn't pull the responder to either canonical. Whether this represents a true findability gap or a per-instance synthesis slip will be settled by the next re-probe on similar phrasing. No content-lineage erosion; no recurring defect class re-opened; one new watch stream opened (Q2 customer-facing percentile-message direction misapplication).

## Source citations

- [trino.io/docs/current/functions/window.html](https://trino.io/docs/current/functions/window.html) — PERCENT_RANK `(r-1)/(n-1)` formula; CUME_DIST "preceding or peer ... divided by total" definition. Confirms Q2 direction semantics.
- [trino.io/docs/current/functions/datetime.html](https://trino.io/docs/current/functions/datetime.html) — `last_day_of_month(x) → date`, `date_add(unit, value, timestamp)`. Confirms Q1 function signatures.
- [docs.oracle.com/en/database/oracle/oracle-database/26/sqlrf/ADD_MONTHS.html](https://docs.oracle.com/en/database/oracle/oracle-database/26/sqlrf/ADD_MONTHS.html) — Oracle ADD_MONTHS clamp-up rule. Confirms Q1 semantic-difference rationale.
- [trino.io/docs/current/functions/array.html](https://trino.io/docs/current/functions/array.html) — `flatten(x) → array` single-level collapse "Flattens an array(array(T)) to an array(T)". Confirms Q3.
- [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html) — `FOR VERSION AS OF <snapshot_id>`, `FOR TIMESTAMP AS OF TIMESTAMP '...'`, `"tbl$snapshots"` metadata table with `committed_at` column. Confirms Q4.
- r07 §3939-3956 LEADING CANONICAL cume_dist at-or-below; §3962-4023 PERCENT_RANK direction guardrail. Resource canonicals confirmed present and correct.
- r27 §666-701 LEADING CANONICAL "Oracle ADD_MONTHS → Trino (END-OF-MONTH CLAMP SEMANTICS DIFFER)". Resource canonical exactly matches the responder's Q1 wrapper.
