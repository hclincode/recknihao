# Iter 564 Judge Feedback — 2026-06-07 (EXTENDED PHASE) — 4.96875 STRONG PASS

## HEADLINE

**OVERALL 4.96875 STRONG PASS — BOTH iter563 defects FIXED on first re-probe.** Q1 TRUNCATE fabricated-feature CLOSED + Q2 multiple-COUNT(DISTINCT) buried-answer CLOSED. Q3 + Q4 strong (5.00 + 4.875). iter563 -> iter564 swing +1.09375 (3.875 -> 4.96875). All four answers >= 4.875. Zero new slips. iter565 = polish + proactive durability re-probes (2nd-angle TRUNCATE / multi-COUNT-DISTINCT) + continued cross-engine-parity + fabricated-feature audits.

## Per-question scores

### Q1 — Wipe staging Iceberg table nightly: TRUNCATE vs DELETE FROM no-WHERE — PRIMARY WIN CHECK (iter564 r17 LEADING CANONICAL)

**Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 = 5.00 STRONG PASS — iter563 Q4 fabricated-feature FULLY FIXED on first re-probe.**

Responder said:
- TRUNCATE TABLE is NOT supported on Trino 467 Iceberg (errors); added in Trino 481.
- DELETE FROM tbl (no WHERE) is metadata-only + atomic — new snapshot drops all data-file references; zero data files scanned; position-delete files NOT written for whole-table deletes (only partial WHERE row-level deletes write position-deletes on v2/MoR tables).
- CREATE OR REPLACE TABLE AS is preferred for atomic clear-and-reload (one snapshot, no empty middle state between two statements).
- Cited r17 L143-156 (the new LEADING CANONICAL block).

Verified at trino.io/docs/467/connector/iceberg.html VERBATIM:
- DML support list: "The Data management functionality includes support for INSERT, UPDATE, DELETE, and MERGE statements." -- **TRUNCATE is NOT in that list.**
- Compared against trino.io/docs/current/connector/iceberg.html which DOES list TRUNCATE (added Trino 481).
- CREATE OR REPLACE: "The connector supports replacing an existing table, as an atomic operation. Atomic table replacement creates a new snapshot with the new table definition."
- Partition-level DELETE metadata-only: "For partitioned tables, the Iceberg connector supports the deletion of entire partitions if the WHERE clause specifies filters only on the identity-transformed partitioning columns."

The iter563 Q4 hard fail (FABRICATED that TRUNCATE works on 467 + MISCHARACTERIZED whole-table DELETE as writing position-delete files) is closed on first re-probe. r17 LEADING CANONICAL routed cleanly; the 4 bullets each load-bearing; DO-NOT-WRITE banned forms block reinforced the truth via negation.

### Q2 — Multiple COUNT(DISTINCT) side by side or two subqueries — PRIMARY WIN CHECK (iter564 r23 §3 LEADING CANONICAL)

**Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 = 5.00 STRONG PASS — iter563 Q3 buried-answer FULLY FIXED on first re-probe.**

Responder LED with the direct answer: "Yes, side by side — Trino natively supports multiple COUNT(DISTINCT) on different columns in ONE SELECT; no subqueries/join." Then layered:
- FILTER (WHERE ...) for conditional distinct in same SELECT.
- approx_distinct fallback (2.3% RSD) when exactness optional.
- SET SESSION distinct_aggregations_strategy named all FIVE values: automatic (default), single_step, mark_distinct, pre_aggregate, split_to_subqueries.
- Acknowledged multi-distinct is more expensive than single distinct (one shuffle per distinct expression) but does NOT require manual subquery + join.

Verified at trino.io/docs/467/admin/properties-optimizer.html — all 5 values present verbatim (SINGLE_STEP, MARK_DISTINCT, PRE_AGGREGATE, SPLIT_TO_SUBQUERIES, AUTOMATIC) with their descriptions. The iter563 Q3 routing issue (answer buried inside a "why expensive" paragraph at the bottom of §3) is closed: the new H3 sits IMMEDIATELY AFTER the `## 3. Use approximate functions ...` header, leading with the worked SQL example before the cost explanation. Responder's lead sentence ("Yes, side by side ...") IS the canonical's first sentence -- routing is clean.

### Q3 — CASE WHEN no ELSE, row matches nothing: error or NULL?

**Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 = 5.00 STRONG PASS.**

Responder: "CASE with no ELSE -> returns NULL silently (no error); equivalent to ELSE NULL; downstream `WHERE status_code = 1` silently drops the NULL rows; add ELSE for a fallback." Cited r23.

Verified at trino.io/docs/467/functions/conditional.html VERBATIM: "If no conditions are true, the result from the ELSE clause is returned if it exists, otherwise null is returned." Matches responder's answer 1:1.

Bonus correctness: responder named the silent-NULL filter trap (downstream WHERE drops NULLs) -- this is the real production gotcha, not just the language semantics. Actionability win: prescribes `ELSE 'unknown'` (or `ELSE 0`) as the explicit fallback.

### Q4 — dbt incremental, late-arriving event (day-3 event lands day-5): backfilled or missed?

**Accuracy 5 / Completeness 5 / Clarity 4.5 / Actionability 5 = 4.875 STRONG PASS.**

Responder:
- Default watermark `WHERE occurred_at >= (SELECT MAX(occurred_at) FROM {{this}})` MISSES late events -- the late event's occurred_at is < the prior MAX(occurred_at) so it's filtered out and never inserted.
- Fix = lookback: `WHERE occurred_at >= date_add('day', -3, (SELECT MAX(occurred_at) FROM {{this}}))` -- re-process the trailing N days every run.
- REQUIRE `incremental_strategy='merge'` + `unique_key='event_id'` -- otherwise the lookback window re-inserts every event in that window as a duplicate.
- Cited r28.

Verified at docs.getdbt.com/docs/build/incremental-models -- the standard watermark + late-arriving-data gap + merge-on-unique_key idempotency story is the documented pattern. Verified at trino.io/docs/467/functions/datetime.html -- `date_add(unit, value, timestamp)` accepts negative value for subtraction (docs example: "date_add('day', -1, TIMESTAMP '2020-03-01 ...')").

Clarity -0.5: could have spelled out the day-3-lands-day-5 worked timeline (day-5 run sees MAX = day-4, watermark predicate `>= day-4` skips day-3 event entirely; with -3-day lookback, watermark `>= day-1` catches it; merge on event_id de-dupes day-2/3/4 re-processed rows). The mechanism is correct; the worked-numbers walkthrough would have made it a 5.

## Overall

**(5.00 + 5.00 + 5.00 + 4.875) / 4 = 19.875 / 4 = 4.96875 STRONG PASS** (overall-average rule). Margin +1.46875 above 3.5 floor; +1.09375 swing from iter563's 3.875 thin PASS.

## Topic average updates

- Lakehouse table operations / maintenance (Q1 TRUNCATE vs DELETE -> r17 new LEADING CANONICAL): Q1 at 5.00 lifts the topic avg.
- SQL query best practices for OLAP (Q2 multiple COUNT(DISTINCT) -> r23 §3 new LEADING CANONICAL + Q3 CASE no ELSE NULL semantics -> r23 §IF/CASE): Q2+Q3 both 5.00 lift topic avg.
- dbt incremental modeling on Iceberg (Q4 late-arriving + merge idempotency -> r28 contextual): Q4 at 4.875 lifts topic avg.
- Federation NOT probed -- **4.49944 / 310 row UNCHANGED** per iter472-563 directive + iter564 task constraint.

## Confirmed defect closures

1. **iter563 Q4 TRUNCATE FABRICATED-FEATURE SLIP -- CLOSED on first re-probe.** Q1 hits 5.00. The r17 LEADING CANONICAL (inserted between L141 `---` and L143 `## Common myths`) routed cleanly. The 4-bullet structure (TRUNCATE-unsupported quote + DELETE-metadata-only mechanism + CREATE-OR-REPLACE-atomic quote + time-travel/expire_snapshots cross-ref) covers every angle the responder needed. The DO-NOT-WRITE block's 3 banned forms (TRUNCATE works on 467 -- FALSE; whole-table DELETE writes position-deletes -- FALSE; DELETE FROM scans every row -- FALSE) gave the responder the negation framing it used verbatim.

2. **iter563 Q3 multiple-COUNT(DISTINCT) BURIED-ANSWER SLIP -- CLOSED on first re-probe.** Q2 hits 5.00. The r23 §3 LEADING CANONICAL (inserted IMMEDIATELY after `## 3. Use approximate functions when exactness isn't required` header and BEFORE the existing "Why COUNT(DISTINCT) is expensive" paragraph) leads with the inline-supported answer; the responder's lead sentence "Yes, side by side -- Trino natively supports multiple COUNT(DISTINCT) ..." mirrors the canonical's opening. All 5 distinct_aggregations_strategy values surfaced -- no buried-answer pattern.

## New iter565 fix targets

All 4 answers strong (>= 4.875). No new failures to fix. iter565 is a polish + durability iter.

1. **(MEDIUM -- durability re-probes for iter564 fixes)**
   - Q1 TRUNCATE 2nd-angle re-probe: try a Spark-vs-Trino TRUNCATE framing ("Spark TRUNCATE works, Trino errors -- why?") or a multi-statement DELETE; INSERT atomicity probe ("readers see empty table between commits"). Verify r17's "CREATE OR REPLACE for atomic rebuild" guidance routes from those angles.
   - Q2 multiple-COUNT(DISTINCT) 2nd-angle re-probe: try a 3+ distinct columns probe, or a conditional/FILTER probe, or the `COUNT(DISTINCT ROW(a,b))` composite-key probe (test the new DO-NOT-WRITE row #3 about composite-key vs multi-independent-distinct).

2. **(MEDIUM -- proactive cross-engine-parity audit continued)**
   - r23 candidates: `string_agg`(Postgres) / `listagg`(Trino) / `array_agg + array_join`; `date_trunc('week', ...)` Monday-vs-Sunday across engines; `RANK() vs DENSE_RANK() vs ROW_NUMBER()` deterministic-tiebreak across engines.
   - r27 candidates: Oracle `NVL2` -> Trino `IF(col IS NOT NULL, a, b)`; Oracle `LISTAGG ... WITHIN GROUP` -> Trino `array_join(array_agg(... ORDER BY ...), ',')`.

3. **(MEDIUM -- proactive fabricated-feature audit continued)**
   - r17 / r10 / r24 candidates: which Iceberg/Trino procedures or syntax forms exist on 467 vs 470+ / 477+ / 479+ / 481+? Walk for "use X on Trino 467" claims that are version-pinned to a later release. Recent fabricated-feature catches: TRUNCATE (481), `retain_last` / `clean_expired_metadata` args on expire_snapshots (479), `optimize_manifests` (470), `ADD COLUMN ... DEFAULT` (477). Pattern: any feature appearing in trino.io/docs/current/ but absent in trino.io/docs/467/ is a fabrication risk.

4. **(LOW -- DO NOT TOUCH)**
   - Federation rubric row stays 4.49944 / 310; no edits to resources/22 §13.x.
   - r17 LEADING CANONICAL block (L143-156) -- DURABLE on first re-probe, do NOT churn.
   - r23 §3 multi-distinct LEADING CANONICAL block (L77-116) -- DURABLE on first re-probe, do NOT churn.
   - r23 §IF/CASE LEADING CANONICAL (L501+) -- routed correctly for Q3, do NOT churn.

## Meta-rule observation

Directive's "verify YOUR OWN corrections + PIN TRINO 467 + watch for FABRICATED FEATURES/ABSENCES, MISCHARACTERIZATIONS, OVERSTATEMENTS" caveat held. WebSearched trino.io/docs/467/connector/iceberg.html (DML list + CREATE OR REPLACE + partition-DELETE metadata-only -- VERBATIM match), trino.io/docs/467/functions/conditional.html (CASE no ELSE -> NULL -- VERBATIM match), trino.io/docs/467/admin/properties-optimizer.html (5 distinct_aggregations_strategy values -- VERBATIM match), trino.io/docs/467/functions/datetime.html (date_add negative-value subtraction -- VERBATIM example), docs.getdbt.com/docs/build/incremental-models (late-arriving + merge unique_key idempotency -- documented gap + standard fix). Every responder claim cross-verified against primary source.

26th consecutive iter (iter537-564) where meta-rule discipline prevented false-positive judgment OR confirmed a real fix landed clean.

## NOTES

- did NOT bump training/state.json (teacher already set iteration=564).
- Federation rubric row 4.49944 / 310 UNCHANGED.
- Did NOT touch resources/22 §13.x.

**OVERALL: 4.96875 STRONG PASS -- BOTH iter563 defects (TRUNCATE fabricated-feature + multi-COUNT(DISTINCT) buried-answer) CLOSED on first re-probe; Q3 CASE-no-ELSE + Q4 dbt-incremental-late-arriving both strong; iter565 = durability 2nd-angle re-probes for Q1+Q2 fixes + continued cross-engine-parity + fabricated-feature audits + NO-CHURN discipline on the two new iter564 canonical blocks.**
