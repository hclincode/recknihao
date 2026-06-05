# Iter 507 Judge Feedback — 2026-06-06 (EXTENDED PHASE)

## Overall: 4.4375 PASS

(4.875 + 4.9375 + 3.0625 + 4.875) / 4 = 17.75 / 4 = **4.4375**

Above the 3.5 floor by +0.9375. **106th consecutive overall PASS in extended phase.** One load-bearing Q3 accuracy error (`old name still works` claim) drags ~0.5 below what would otherwise be a 4.9+ STRONG PASS cluster.

Federation NOT probed per directive — `4.49944/310` row UNCHANGED.

---

## Per-question breakdown

### Q1 — ADD_MONTHS month-end RE-PROBE (Oracle → Trino) — 4.875 STRONG PASS

**iter506 `end_of_month` fab FIX LANDED. Confirmed.**

- Accuracy: 5.0 — Core forms `date_add('month', n, d)` and `d + INTERVAL 'n' MONTH` both valid Trino 467. Month-end wrapper now correctly uses `last_day_of_month(...)` in BOTH positions of the CASE expression (the exact iter506 fab `end_of_month(...)` does NOT reappear). Verified via WebFetch trino.io/docs/current/functions/datetime.html: `last_day_of_month(x) -> date` is present and documented as "Returns the last day of the month"; `end_of_month` is NOT present on the page. Divergence example also accurate: Trino `date_add('month', 1, DATE '2026-02-28')` = 2026-03-28 (does NOT snap to month-end), while Oracle `ADD_MONTHS` = 2026-03-31 — this is the exact behavioral gap the wrapper closes.
- Clarity: 4.75 — Concrete Oracle-vs-Trino example contrast; CASE wrapper spelled out inline.
- Actionability: 5.0 — Engineer pastes the wrapper and it parses on Trino 467 first try.
- Completeness: 4.75 — Mentions canonical form + wrapper + divergence + cites docs; minor -0.25 for not separately calling out that the integer-month overflow case (e.g., Jan 31 → Feb) lands on Feb 28 naturally without the wrapper.

**Verdict on the iter506 fab fix: LANDED.** The reconcile-in-place fix at r27 §4.x DO-NOT-WRITE matrix steered correctly: the responder used `last_day_of_month` in BOTH positions, NEVER wrote `end_of_month`. 17th leading-canonical bulletproofing instance + 10th findability/canonical-addition fix to land cleanly on re-probe.

### Q2 — Count paid vs unpaid in ONE pass — 4.9375 STRONG PASS

- Accuracy: 5.0 — Both `SUM(CASE WHEN paid=true THEN 1 ELSE 0 END)` and `COUNT(*) FILTER (WHERE paid=true)` are valid Trino 467 conditional-aggregation forms. Verified at trino.io/docs/current/functions/aggregate.html: FILTER clause documented as "supported for all aggregate functions"; example shown for COUNT. "Identical plans on Trino 467" claim — both forms compile to a CASE-based partial aggregation in Trino so the plan-equivalence claim is reasonable and accurate.
- Clarity: 5.0 — Both forms shown side-by-side, no jargon.
- Actionability: 5.0 — Engineer can pick either and ship.
- Completeness: 4.75 — Two canonical idioms covered; minor -0.25 for not noting that FILTER is slightly more readable / standard-SQL-portable.

### Q3 — Iceberg RENAME / DROP COLUMN safety — 3.0625 FAIL

**LOAD-BEARING ACCURACY ERROR.** This drags the whole iter.

- Accuracy: **2.5** — Most of the answer is correct, BUT the load-bearing claim "A dbt model written before the rename can still reference the column by its original name OR the new name — they both map to the same field ID and read the same bytes" is **factually wrong and internally inconsistent with the user's own premise** (the user explicitly said their dbt models referencing the old name BROKE).

  **Correction**: Iceberg's field-ID model means that after `ALTER TABLE ... RENAME COLUMN old TO new`:
  - OLD DATA FILES on disk keep their field IDs, so reads of those files under the NEW name return the same bytes WITHOUT requiring a rewrite. This part of the answer is correct.
  - The SQL-facing schema exposes ONLY the NEW name. Querying `SELECT old_name FROM tbl` after the rename FAILS with a column-not-found error (the Trino analyzer resolves identifiers against the current schema, which has only `new_name`).
  - The "transparent to historical reads" framing conflates two distinct ideas: (a) old data files remain readable under the new name — TRUE, no rewrite needed; (b) old NAME remains queryable — FALSE, only the new name is queryable.
  - This is exactly why the user's dbt models broke: their SQL referred to the old name, which the analyzer no longer recognizes.

  Correct safe practice for dbt: bump the model SQL to the new name in the same commit, OR keep the old name as a view alias / select-alias for a deprecation window, OR avoid the rename entirely and add a new column + sunset the old one.

  Other parts of the answer ARE correct and earn partial credit:
  - Field-ID-not-name tracking: TRUE.
  - RENAME COLUMN is metadata-only, no Parquet rewrite: TRUE.
  - DROP COLUMN is metadata-only (retires the field ID), storage reclaim needs `optimize` + `expire_snapshots` + `remove_orphan_files`: TRUE per Trino 467 Iceberg connector docs.
  - Partition-column-drop edge case (evolve spec first): TRUE.

  Net Accuracy: 2.5 — the load-bearing claim is wrong and contradicts the user's own observation, but the surrounding mechanics are correct.

- Clarity: 4.0 — Reasonably structured; the "both names work" claim is stated confidently which makes it more dangerous (engineer would not double-check).
- Actionability: 2.0 — Engineer following this advice would NOT fix their dbt-models-broken problem because the answer tells them the old name should still work (so they'd hunt for some other issue and waste time). The DROP COLUMN maintenance sequence is actionable for that subquestion.
- Completeness: 3.75 — Covers field-ID + metadata-only + DROP storage reclaim + partition-column edge case; misses the actual safe-rename-with-dbt playbook (bump SQL in same PR, or use view aliases as a deprecation step, or prefer add-new + sunset-old over rename for tables with downstream consumers).

### Q4 — date_trunc for week/month buckets — 4.875 STRONG PASS

- Accuracy: 4.75 — `date_trunc('week', event_time)` and `date_trunc('month', event_time)` are valid Trino 467. Verified at trino.io/docs/current/functions/datetime.html: signature is `date_trunc(unit, x) -> [same as input]` — the return type matches the input type (timestamp in → timestamp out, date in → date out; NOT always a DATE). The answer is INTERNALLY INCONSISTENT: states "returns a DATE" early then later corrects to "returns the same type as the input." The latter is correct; the former is wrong. Minor nit, but visible to a careful reader. The `time_bucket` "not in Trino, that's PostgreSQL/TimescaleDB" disclaimer is correct. The GROUP-BY-must-repeat-expression rule (Trino #16533) is correct — verified the issue exists at github.com/trinodb/trino/issues/16533 ("Using alias in group by is not supported by Trino").
- Clarity: 5.0 — Both `'week'` and `'month'` units shown; the GROUP BY repeat-expression caveat is the right gotcha to surface for engineers used to Postgres/BigQuery alias-in-GROUP-BY.
- Actionability: 5.0 — Engineer pastes and it works.
- Completeness: 4.75 — Covers `date_trunc` + units + GROUP-BY caveat + `time_bucket` clarification; could mention that week truncation in Trino starts on Monday (ISO 8601) for engineers used to Sunday-start, but minor.

**Minor nit to fix**: the responder contradicts itself about `date_trunc` return type within the same answer. The "same type as input" sentence wins, but the earlier "returns a DATE" sentence is misleading. Reconcile-in-place at the `date_trunc` canonical to remove the misleading "returns a DATE" framing — return type is ALWAYS [same as input].

---

## iter506 fab fix outcome

- `end_of_month(...)` fab: **FIX LANDED** (Q1, see above). The reconcile-in-place at r27 §4.x DO-NOT-WRITE matrix (2 new rows + keyword anchor) steered the responder to `last_day_of_month` cleanly. 17th leading-canonical bulletproofing instance + 10th findability/canonical-addition fix to land cleanly on first re-probe.

## NEW iter507 load-bearing accuracy error

- **Q3 Iceberg RENAME COLUMN "old name still queryable" fab.** This is the new load-bearing error. The responder correctly explained field-ID-not-name tracking for OLD DATA FILES but then OVER-EXTENDED that to mean the OLD NAME remains queryable in SQL — which is false. The analyzer resolves identifiers against the current schema; only the NEW name is exposed. The user's own observation (their dbt models referencing the old name BROKE) directly contradicts the responder's claim, so the responder failed to reconcile their answer with the question premise.

## Other fabrication scan

- Q1: clean (last_day_of_month real, no end_of_month).
- Q2: clean (FILTER + SUM(CASE) both real).
- Q3: load-bearing claim (above); rest of mechanics accurate.
- Q4: internal inconsistency (DATE vs same-as-input return type) — minor nit; not a fab per se, but reconcile.

## iter508 teacher recommendations

**HIGH PRIORITY — Q3 reconcile-in-place at Iceberg RENAME COLUMN canonical (r13 / r03 / wherever Iceberg schema evolution lives).**

The fix is conceptual reconciliation, not a new canonical. Find the existing Iceberg RENAME COLUMN section and add (or strengthen if already present):

1. **DO-NOT-WRITE row**: "After RENAME COLUMN, the OLD NAME is NOT queryable. Trino's analyzer resolves identifiers against the CURRENT SCHEMA, which exposes only the NEW name. `SELECT old_name FROM tbl` after a rename fails with `Column 'old_name' cannot be resolved`. Do NOT claim both names work — only the new name works."
2. **Mechanics callout** (disambiguate two distinct concepts):
   - **Old DATA FILES** keep their field IDs and are read transparently under the new column name (no Parquet rewrite needed). This is what "metadata-only / lossless" means.
   - **Old NAME** is dropped from the SQL-facing schema at the moment of rename. Only the new name is exposed.
3. **Safe-rename playbook for dbt downstream consumers**:
   - Bump dbt model SQL to the new name in the SAME PR / commit as the `ALTER TABLE ... RENAME COLUMN`.
   - Or: keep a transitional VIEW that aliases new name back to old name for a deprecation window (`CREATE VIEW v AS SELECT new_name AS old_name FROM t`), then drop the view after consumers migrate.
   - Or: skip the rename entirely — add new column, dual-write or backfill, then sunset old column (preferred for tables with many downstream consumers).
4. **Keyword anchors**: "iceberg rename column old name not found, alter table rename column dbt broke, iceberg rename column safe, rename column field id, iceberg schema evolution column not found, iceberg rename column old name still works (NO — only new name is queryable)."

**MEDIUM PRIORITY — Q4 `date_trunc` return type reconcile-in-place.**

Find the `date_trunc` canonical (likely r07 or r05) and ensure the return-type framing is unambiguous: "ALWAYS returns the SAME TYPE as the input — timestamp → timestamp, date → date. Does NOT downcast to date." Strike any "returns a DATE" framing.

## iter508 judge probe targets

1. **HIGH — Iceberg RENAME COLUMN re-probe** (different angle): "I renamed `customer_email` to `email`, my Trino query `SELECT customer_email FROM customers` now fails with column-not-found, but the docs said rename is metadata-only — what's the fix?" Verify the iter507 Q3 fix lands: responder must say only the NEW name is queryable + bump SQL / view alias / dual-column playbook.
2. **HIGH — Iceberg RENAME COLUMN 3rd angle**: "Is there a way to keep the old column name working as an alias after RENAME COLUMN?" Verify response routes to view-aliasing or add-new-then-sunset patterns, NOT to "both names work."
3. **MEDIUM — date_trunc return type re-probe**: "I did `date_trunc('month', event_timestamp)` and compared to a DATE column — type mismatch. Why?" Verify responder says return type is `timestamp` (same as input), NOT date.
4. **MEDIUM — ADD_MONTHS 3rd angle re-probe**: Jan 30 input to ADD_MONTHS(_, 1). Verify wrapper still uses `last_day_of_month` in both positions and explains the Jan 30 → Feb 28 case (Oracle clamps to Feb-end because target month has no day 30; Trino `date_add` also lands on Feb 28 — but for a different reason: month-end overflow, NOT month-end snap).
5. **LOW — conditional aggregation 3rd angle**: paid sum and unpaid count in one pass (mixed aggregates with FILTER).
6. **Federation stays UNPROBED** per directive (4.49944/310 row UNCHANGED).

## Topic averages updated

- **Common analytical query patterns**: Q4 date_trunc maps here. 4.6716/11 → (4.6716*11 + 4.875)/12 = 56.2626/12 = **4.6886/12** (+0.0170).
- **Oracle PL/SQL→dbt/Trino migration**: Q1 ADD_MONTHS maps here. 4.5232/72 → (4.5232*72 + 4.875)/73 = 330.5454/73 = **4.5280/73** (+0.0048 — clean recovery; iter506 Q3 fab drag fully unwound).
- **SQL query best practices for OLAP**: Q2 conditional aggregation maps here. 4.5425/57 → (4.5425*57 + 4.9375)/58 = 263.8600/58 = **4.5493/58** (+0.0068).
- **Iceberg table maintenance**: Q3 RENAME / DROP COLUMN maps here (closest match — schema evolution is a maintenance op). 4.4957/149 → (4.4957*149 + 3.0625)/150 = 672.8218/150 = **4.4855/150** (-0.0102 — Q3 FAIL drags but stays above 4.0 floor and above 3.5 pass).
- **Federation**: UNCHANGED at 4.49944/310 per directive.

## Headline

- **PASS overall (4.4375)** — 106th consecutive extended-phase PASS, margin +0.9375 above floor.
- **iter506 `end_of_month` fab FIX LANDED** (Q1 — `last_day_of_month` used in both wrapper positions, no `end_of_month` regression). 17th leading-canonical bulletproofing instance + 10th findability/canonical-addition fix to land cleanly on first re-probe.
- **NEW load-bearing Q3 accuracy error**: "old column name still queryable after RENAME COLUMN" claim is factually wrong AND internally inconsistent with the question's own premise. Needs iter508 reconcile-in-place at the Iceberg RENAME COLUMN canonical.
- **NEW minor Q4 nit**: `date_trunc` return-type internal inconsistency (DATE vs same-as-input). Reconcile-in-place.
- Federation guardrails / rubric row UNTOUCHED per directive.
