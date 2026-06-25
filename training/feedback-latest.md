# Judge Feedback — Iteration 1109 (2026-06-26)

**OVERALL: 4.92 STRONG PASS** — breadth durability sweep across 4 varied less-recently-probed angles (week-over-week LAG; Iceberg snapshots/rollback after compaction; MAP subscript vs element_at; default window-frame peer-lumping). All four dialect traps cleanly hit. Q3 + Q4 are pristine. Q2 has one minor cautious-hedge shave on `FOR VERSION AS OF` (Trino 467 DOES support it; responder hedged "if supported"). NO resource defect found. **RECOMMENDATION = NO-OP.**

## Per-question scoring

### Q1 — week-over-week event count per customer; can LAG jump back over a week of aggregated data or need a self-join?
**Responder:** Pre-aggregate per (customer_id, week_start) in a CTE using `date_trunc('week', event_date)` + `COUNT(*)`, then `LAG(events_this_week, 1) OVER (PARTITION BY customer_id ORDER BY week_start)` for prior week; `change = cur - prev`, `pct_change = ROUND(100.0*(cur-prev)/NULLIF(prev,0), 2)`. LAG returns NULL for the first week per customer (no prior). No self-join needed.

**Verifications:**
- LAG over a pre-aggregated weekly CTE is the canonical pattern. The LAG "jump" is row-level over the partitioned/ordered sequence of WEEKLY rows in the CTE — there is no "jump over a week of raw data" question because the CTE has ONE row per (customer, week). VERIFIED canonical.
- `NULLIF(prev, 0)` guard CORRECT — per `reference_trino_division_by_zero` memory pin, Trino 467 INTEGER/DECIMAL `/` by zero THROWS `DIVISION_BY_ZERO`; the NULLIF guard converts the zero divisor to NULL and the result becomes NULL (clean). Without it, the query would fail when a customer had 0 events the prior week.
- `date_trunc('week', ...)` returns the Monday of the week (ISO-8601, Trino 467 documented). Correct for week-start anchoring.
- LAG default offset is 1 and default return for "no prior row" is NULL (Trino window functions). Correct.

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 5 | Pre-aggregate-then-LAG pattern is textbook. NULLIF-guard correct (would throw on integer div-by-zero otherwise). date_trunc('week', ...) correct. |
| Clarity | 5 | "LAG jumps back one row in the partitioned/ordered sequence — but the rows here are weekly aggregates, so LAG(1) IS the prior week" framing answers the engineer's mental-model confusion head-on. |
| Applicability | 5 | Copy-paste CTE + window block is runnable as-is. NULLIF + ROUND(., 2) are paste-ready production hygiene. |
| Completeness | 5 | Covers WHY no self-join (pre-aggregation collapses to one row per customer-week), pct_change formula with div-by-zero guard, and first-week NULL handling. No padding. |

**Q1 average: 5.0**

---

### Q2 — bad write a few days ago, compaction already run since; can I still query pre-bad-write state and list all historical versions to restore from?
**Responder:** List `"events$snapshots"` (snapshot_id, committed_at, operation, summary) ORDER BY committed_at DESC; identify the last-good snapshot just before the bad write; then `CALL iceberg.system.rollback_to_snapshot('analytics','events', <id>)` metadata-only. Explains Iceberg never modifies files in place, every write (including compaction) is a new snapshot — so old snapshots remain queryable until `expire_snapshots` runs. Mentions `FOR VERSION AS OF <snapshot_id>` "if Trino's Iceberg connector supports it" as a read-only inspection alternative.

**Verifications (RAW Trino 467 / Iceberg connector docs):**
- `"events$snapshots"` metadata table with columns `(committed_at, snapshot_id, parent_id, operation, manifest_list, summary)` — VERIFIED per trino.io/docs/467 Iceberg connector metadata-tables section.
- `CALL iceberg.system.rollback_to_snapshot('schema_name', 'table_name', <bigint snapshot_id>)` 3-arg form — VERIFIED for Trino 467 per memory pin `reference_trino_rollback_snapshot_form` (the ALTER TABLE ... EXECUTE rollback_to_snapshot table-procedure form is 469+; the CALL system-procedure form is the correct one for 467).
- "Iceberg never modifies in place / every write is a new snapshot" framing IMPLICITLY addresses the engineer's compaction-since-bad-write concern — compaction (OPTIMIZE) creates a NEW snapshot but the old data files referenced by pre-compaction snapshots are NOT deleted; time travel and rollback to a pre-bad-write snapshot still work until `expire_snapshots` (or `remove_orphan_files`) runs. Could be MORE EXPLICIT but it's not wrong.
- `FOR VERSION AS OF <snapshot_id>` / `FOR TIMESTAMP AS OF <timestamp>` — VERIFIED Trino 467 Iceberg connector DOES support both. Documented in 9 resources/ files (grep). The responder's "if Trino's Iceberg connector supports it" hedge is UNNECESSARILY WEAK — it does support it, definitively. This is a responder cautious-padding artifact, NOT a resource defect (resources state it firmly).

**Defect classification:** "if supported" hedge on FOR VERSION AS OF — RESPONDER ONE-OFF caution, NOT resource-sourced (grep confirms no "if supported"/"if connector supports" hedge string in any resource). Pattern matches `feedback_responder_overwarning_folklore` (Haiku over-cautions a feature that resources cover firmly). NO resource fix needed.

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 4.5 | `"events$snapshots"` columns correct. CALL 3-arg form correct for 467 (NOT the 469+ EXECUTE form). "Iceberg never modifies in place" framing correct. Shave: "FOR VERSION AS OF if supported" hedge is unnecessarily weak — 467 supports it definitively. |
| Clarity | 4.75 | Step-by-step (list snapshots → identify good one → rollback) maps to the engineer's mental model. "Every write is a new snapshot" sentence connects compaction directly to "old snapshots still queryable" but doesn't NAME `expire_snapshots` as the only thing that would have removed them. |
| Applicability | 5 | Both SQL blocks (snapshots query + CALL rollback) are copy-paste runnable as-is for the production stack. The engineer knows the next step. |
| Completeness | 4.5 | Covers list-then-rollback core. Compaction-since-bad-write concern implicitly addressed by "every write is a new snapshot" framing but would benefit from one sentence explicitly stating "compaction's new snapshot does NOT remove pre-compaction snapshots — only `expire_snapshots` does." Minor gap. |

**Q2 average: 4.6875**

---

### Q3 — `properties` is a MAP; `GROUP BY properties['plan_id']` — is bracket valid, what if key missing?
**Responder:** Bracket `properties['plan_id']` IS valid syntactically BUT THROWS a runtime error if the key is absent ("Key not present in map"). Use `element_at(properties, 'plan_id')` for NULL-safe access (returns NULL for missing key). GROUP BY on the element_at expression is fully valid; rows with missing key group under NULL.

**Verifications (RAW Trino 467 docs — trino.io/docs/current/functions/map.html):**
- Subscript operator `m[key]` on map: "throws an error if the key is not contained in the map" — VERIFIED. Historical context: an earlier release changed this from NULL-returning to throwing; `deprecated.legacy-map-subscript` can restore NULL behavior but is deprecated.
- `element_at(map, key)`: "Returns value for given key, or NULL if the key is not contained in the map" — VERIFIED.
- GROUP BY on an expression returning NULL groups all NULL-keyed rows into a single NULL group — VERIFIED standard SQL semantics; Trino supports `GROUP BY <expression>` not just column names.

Responder's "bracket throws, element_at returns NULL" mapping is EXACTLY correct.

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 5 | Bracket-throws / element_at-returns-NULL mapping is verbatim correct per Trino 467 docs. GROUP BY on element_at expression valid. Missing-key rows group under NULL — correct. |
| Clarity | 5 | Two-line "bracket THROWS, element_at RETURNS NULL" framing is the cleanest possible phrasing of the trap. Engineer immediately knows which to use. |
| Applicability | 5 | Direct rewrite of the engineer's query (swap brackets for element_at) is the actionable next step. Production-ready. |
| Completeness | 5 | Covers syntactic validity, runtime behavior, NULL-safe alternative, AND group-by-NULL semantics. No padding, no broken secondary alternative. |

**Q3 average: 5.0**

---

### Q4 — running total `SUM(amount) OVER (PARTITION BY customer_id ORDER BY event_date)` gives the SAME cumulative to rows sharing an event_date instead of incrementing
**Responder:** When ORDER BY is present and no explicit frame is specified, the default frame is `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`. RANGE-CURRENT-ROW includes ALL peer rows (rows with equal ORDER BY values) up to the LAST peer — so rows sharing an event_date all see the same end-of-group cumulative (the value after all peers are summed). Fix: add explicit `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` (row-positional, no peer-lumping) AND a unique tiebreaker in ORDER BY (e.g., `ORDER BY event_date, event_id`) so the row order within a same-event_date tie is deterministic.

**Verifications (RAW Trino 467 docs — trino.io/docs/current/functions/window.html):**
- Default window frame: "If the window frame is not specified, it defaults to RANGE UNBOUNDED PRECEDING, which is the same as RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW" — VERIFIED.
- RANGE-CURRENT-ROW peer semantics: "UNBOUNDED PRECEDING includes all rows since the partition start, while CURRENT ROW includes all rows where values of the sort key are the same as in the current row — these are called peer rows" — VERIFIED. Peer rows share the same per-group cumulative because the frame extends to the last peer.
- ROWS-CURRENT-ROW: row-positional, no peer-lumping (each row sees only itself + prior rows). VERIFIED standard SQL frame semantics.
- ORDER BY tiebreaker advice: necessary because without a unique ORDER BY, the row-positional order within a same-event_date tie is non-deterministic, so even the ROWS frame would produce engine-dependent partial sums. VERIFIED best practice.

Responder's diagnosis + fix is the canonical answer.

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 5 | RANGE-default + peer-lumping mechanism explained correctly. ROWS frame + unique tiebreaker = the canonical fix, both necessary (ROWS alone w/o tiebreaker is non-deterministic; tiebreaker alone doesn't change RANGE-peer semantics). |
| Clarity | 5 | Names the exact default frame, explains WHY peer-lumping happens (frame extends to LAST peer), and gives a two-part fix that maps to the cause. Beginner sees the bug → mechanism → fix chain. |
| Applicability | 5 | The single-line frame change + ORDER BY tiebreaker is paste-ready. Engineer knows exactly what to do. |
| Completeness | 5 | Diagnoses surprising-default (peer-lumping in RANGE), gives ROWS-frame fix AND the tiebreaker hygiene. No padding. |

**Q4 average: 5.0**

---

## Score table

| Q | Topic touched | Accuracy | Clarity | Applicability | Completeness | Q avg |
|---|---|---|---|---|---|---|
| Q1 | Analytical query patterns / time-series SQL on Iceberg+Trino (r07) | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | Iceberg table maintenance: snapshots / rollback / compaction (r17) | 4.5 | 4.75 | 5 | 4.5 | 4.6875 |
| Q3 | SQL query best practices for OLAP — MAP subscript vs element_at (r23) | 5 | 5 | 5 | 5 | 5.00 |
| Q4 | Analytical query patterns: window frames / cumulative (r07) | 5 | 5 | 5 | 5 | 5.00 |

**Overall average: (5.00 + 4.6875 + 5.00 + 5.00) / 4 = 4.9219 → STRONG PASS**

---

## Source-verified defects

NONE.

The only score shave (Q2 `FOR VERSION AS OF` "if supported" hedge) is a **responder one-off caution**, NOT a resource defect:
- Grep of `resources/` for "if connector supports" / "if supported" + variants returns ZERO matches in any time-travel context.
- 9 resources/ files (r13, r05, r17, r10, r15, r22, r11, r21, r23, r26) document FOR VERSION AS OF / FOR TIMESTAMP AS OF firmly.
- The hedge matches the `feedback_responder_overwarning_folklore` pattern (Haiku over-cautions a fine feature) — recall ceiling, NO resource fix can durably block, do not let it bias the judge.

---

## Teacher guidance

**RECOMMENDATION = NO-OP this iteration.**

- Q1, Q3, Q4 are pristine — no per-instance or systemic gap.
- Q2 is 4.69 — well above 3.5 threshold and well above the r17 topic floor (4.4639). The minor `FOR VERSION AS OF` hedge is responder over-caution per the responder-over-warning pattern; resources cover the feature firmly; no additive content can durably stop Haiku from inserting an "if supported" qualifier. Per `feedback_synthesis_ceiling_stop_churning`, do not churn.
- Compaction-since-bad-write angle: responder IMPLICITLY answered correctly via "every write is a new snapshot." If a future re-probe explicitly asks "does OPTIMIZE delete old snapshots?" and the responder slips, that would be the trigger to add a tight canonical card in r17 ("OPTIMIZE/compaction CREATES new snapshot, NEVER deletes old ones — only `expire_snapshots` does"). This iter, the implicit framing was sufficient.

**Topic rows updated:**
- Analytical query patterns on Iceberg+Trino (r07): 4.4326/61 + Q1@5.0 + Q4@5.0 → **4.4506/63**
- Iceberg table maintenance (r17): 4.4639/171 + Q2@4.69 → **4.4652/172**
- SQL query best practices for OLAP (r23): 4.4783/160 + Q3@5.0 → **4.4815/161**

All three topic rows remain PASSED; no thresholds crossed downward; no resource gap exposed.

**Federation untouched** (fragile-PASS 4.50244/312 unchanged).
**CBO/ANALYZE untouched** (4.5716/20 unchanged; +0.072 margin to raised 4.5 threshold preserved).
