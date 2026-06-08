# Iter 688 — Judge Feedback (EXTENDED PHASE)

## Scoring table (per-Q, 1-5)

| Q | Topic | Acc | Comp | Clar | Act | Per-Q avg |
|---|---|---|---|---|---|---|
| Q1 | storage-tiering FINDABILITY re-probe (MinIO mc-ilm-tier) | 5 | 5 | 5 | 5 | **5.00** |
| Q2 | dbt exposures-native re-probe (downstream consumer registration) | 5 | 5 | 5 | 5 | **5.00** |
| Q3 | running cumulative percent of month total (Trino window) | 2 | 4 | 4 | 2 | **3.00** |
| Q4 | Iceberg RENAME COLUMN amt → amount (field-id metadata-only) | 5 | 5 | 5 | 5 | **5.00** |

**Overall per-Q avg = (5.00 + 5.00 + 3.00 + 5.00) / 4 = 18.00 / 4 = 4.500**

**Dim-avg cross-check.** Acc (5+5+2+5)/4 = 4.25; Comp (5+5+4+5)/4 = 4.75; Clar (5+5+4+5)/4 = 4.75; Act (5+5+2+5)/4 = 4.25; mean of dim-avgs = (4.25+4.75+4.75+4.25)/4 = 4.500. Agrees with per-Q.

**GOVERNING LABEL = PASS** (overall 4.500 >= 3.5 floor by margin +1.000; per-Q quality-gate override NOT applied per directive; Q3 3.00 flagged in prose only because the SQL has a literal off-by-100x defect contradicting its own example output.)

---

## Per-Q verdicts and dialect verification

### Q1 — storage-tiering FINDABILITY FIX-A RE-PROBE: **CLOSED**

Responder delivered the concrete MinIO mc-ilm-tier recipe: `mc ilm tier add minio <ALIAS> COLD_POOL ...` to register the cold tier + `mc ilm rule add --transition-days 180 --transition-tier COLD_POOL --prefix data/` for age-based transition, correctly stated transitions are by OBJECT AGE (not access time), correctly scoped the prefix to `data/` to keep Iceberg `metadata/` hot, correctly stated Trino sees nothing (transparent, only slower cold reads), and correctly stated Trino 467 has NO `SET STORAGE TIER` DDL + Iceberg has no tiering concept. Cited r16:499-628. This is exactly the LEADING CANONICAL three-mechanism content the iter687 FIX-A added inbound keyword anchors to at r16:501.

VERIFIED MinIO docs (WebSearch docs.min.io/enterprise/aistor-object-store): `mc ilm tier add <TIER_TYPE> <TARGET_ALIAS> <TIER_NAME>` creates the remote tier target; `mc ilm rule add --transition-days N --transition-tier <TIER_NAME>` attaches an age-based lifecycle transition; `--transition-days` is "calendar days from object creation," NOT last-access — all responder claims align with docs. VERIFIED trino.io/docs/467/connector/iceberg.html: no `SET STORAGE TIER`, no `storage_tier`/`storage_class`/`tier` table property, no `iceberg.storage-tier.*` catalog property — all correctly negated by responder.

**Storage-tiering FINDABILITY FIX-A VERDICT: CLOSED** — from the same question shape that produced iter687's "consult external docs / outside scope" non-answer (LANDING-POINT MISS to r17), the responder now lands on r16:499 and delivers the concrete mc-ilm-tier recipe. The iter687 FIX-A keyword-anchor broadening at r16:501 + the new r17:63-65 cross-ref callout both worked.

### Q2 — exposures-native FIX-A RE-PROBE: **CLOSED**

Responder opened with "dbt EXPOSURES are the native, first-class feature for exactly this" — directly inoculating against the iter687 Q2 contradictory-framing miss ("dbt doesn't have a native feature, work around it"). Delivered minimal `exposures.yml` worked example with name/label/type(dashboard|notebook|ml|application)/url/owner/depends_on: [ref('fct_orders'), ref('dim_customers')], correctly noted `dbt docs generate` renders the exposure as a downstream leaf node in lineage, listed selection syntax `dbt ls --select +exposure` for impact analysis and `dbt build --select +exposure:...` for selective CI, and correctly noted metadata-only (no SQL execution). Cited r27:3421-3472.

VERIFIED docs.getdbt.com/docs/build/exposures + docs.getdbt.com/reference/exposure-properties (WebSearch): exposures are a native dbt-core resource type, exposures.yml shape with name/type/owner/depends_on:[ref(),source(),metric()], rendered as downstream nodes in `dbt docs generate` lineage. Five `type:` values include dashboard, notebook, analysis, ml, application — responder's enumeration is correct. NOT a workaround, NOT a package, NOT an external plugin.

**Exposures-native FIX-A VERDICT: CLOSED** — the iter687 contradictory-framing miss is gone; responder now frames exposures as the native first-class feature in the opening sentence and never drifts to "work around it." The iter687 FIX-A new §6.7H2 at r27:3420 with the explicit native-feature framing + 6-row DO-NOT-WRITE table catching wrong-framing claims worked.

### Q3 — running cumulative percent of month total: **DOUBLE-100 BUG CONFIRMED (responder-drift, NOT resource-defect)**

Structure is sound:
- `SUM(amount) OVER (ORDER BY order_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` for the running cumulative sum.
- `SUM(amount) OVER ()` empty-window for the grand total denominator.
- `GROUP BY order_date` to collapse to one row per day.
- `WHERE order_date >= date_trunc('month', CURRENT_DATE) AND order_date < date_trunc('month', CURRENT_DATE) + INTERVAL '1' MONTH` correctly scopes to the current month — all valid Trino 467.

**THE DEFECT.** The literal SQL writes:

```sql
ROUND(100.0 * SUM(amount) OVER (ORDER BY order_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
              / SUM(amount) OVER ()
            * 100, 1) AS cumulative_pct_of_month
```

`*` and `/` have the same precedence and are left-associative in SQL, so this evaluates as `((100.0 * running) / grand_total) * 100` = `(running / grand_total) * 100 * 100` = `(running / grand_total) * 10000`. On the final day where `running = grand_total`, the result is **10000.0**, not the **100.0** shown in the responder's own example output table (which displayed 4.2 / 9.3 / 52.1 / 100.0 — the values the SINGLE-100 form would produce).

The SQL and the example output **contradict each other**. The leading `100.0 *` already converts the ratio to a percent (and forces decimal so integer division does not truncate to 0); the trailing `* 100` multiplies by 100 a second time. This is an off-by-100x error.

**Corrected single-100 form (use either of these, NOT both):**

```sql
-- Form A (leading 100.0 — preferred, also dodges integer-division-truncates-to-0)
ROUND(
  100.0 * SUM(amount) OVER (ORDER BY order_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
        / SUM(amount) OVER (),
  1
) AS cumulative_pct_of_month

-- Form B (trailing * 100 with a decimal cast on the numerator — equivalent, less common)
ROUND(
  CAST(SUM(amount) OVER (ORDER BY order_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS DOUBLE)
  / SUM(amount) OVER ()
  * 100,
  1
) AS cumulative_pct_of_month
```

**Pick ONE of `100.0 *` (leading) or `* 100` (trailing). Never both.**

**Resource check (where the responder should have landed):** r07:1229 row of the H3 patterns table teaches the correct `100.0 * x / SUM(x) OVER ()` shape; r07:1241 worked example uses correct single-100 form `ROUND(100.0 * revenue / SUM(revenue) OVER (), 2)`; r07:1269 / 1277 / 1292 all use correct single-100 conditional-SUM / FILTER forms; r07:1326 / 1327 / 1328 quick-reference rows all show correct single-100 shapes. **No resource teaches a "running cumulative percent of grand total" worked example with double-100** (there is no card specifically for the combination `running SUM() OVER (ORDER BY ... ROWS UNBOUNDED PRECEDING) / grand-total SUM() OVER ()` as a percent — only the static `SUM(x) OVER ()` share-of-grand-total card and the cumulative-sum cards separately).

**VERDICT: RESPONDER-DRIFT, not resource-defect.** The responder composed the running-cumulative-sum shape (r07:1228 / §5 Pattern A1) with the share-of-grand-total shape (r07:1229 / 1241) and double-multiplied by 100 in the fusion — neither source taught that. The example output table even shows the correct expected values, so the responder "knew" the right answer but the literal SQL string is wrong.

Penalty: Acc 2 (SQL produces values 100x too large), Comp 4 (covers structure + window + month boundary correctly), Clar 4 (explanation is fine; the bug is in the executable artifact), Act 2 (engineer who copy-pastes gets 10000.0 not 100.0).

### Q4 — Iceberg RENAME COLUMN amt -> amount: **VALID**

`ALTER TABLE iceberg.analytics.orders RENAME COLUMN amt TO amount;` — metadata-only on Iceberg because the connector tracks columns by FIELD ID, not by name; old Parquet files readable under the new name instantly with zero rewrites. Responder correctly warned that the old name stops resolving (`Column 'amt' cannot be resolved`) and offered the three-option safe-rename playbook: (A) atomic rename + downstream update in one PR; (B) expand/contract (ADD amount + UPDATE backfill + migrate readers + DROP amt); (C) compatibility view (rename + `CREATE VIEW orders_compat AS SELECT *, amount AS amt FROM orders`). Cited r17:295-439.

VERIFIED trino.io/docs/467/sql/alter-table.html + trino.io/docs/467/connector/iceberg.html: `ALTER TABLE name RENAME COLUMN column_name TO new_column_name` is documented and supported on the Iceberg connector; Iceberg's field-ID model preserves the field ID across renames so all historical Parquet remains readable under the new name without rewrite. Matches r17:295-439 LEADING CANONICAL exactly.

---

## Overall verdict

**OVERALL: 4.500 PASS — both iter687 FIX-A's CLOSED, one new responder-drift defect on Q3 (double-100 in the cumulative-percent SQL contradicts the SQL's own example output).**

- Q1 storage-tiering FINDABILITY FIX-A: **CLOSED** (responder now lands on r16:499 with concrete mc-ilm-tier recipe; iter687 keyword-anchor + r17->r16 cross-ref worked).
- Q2 exposures-native FIX-A: **CLOSED** (responder now opens with "exposures are the native first-class feature"; iter687 r27:3420 §6.7H2 + DO-NOT-WRITE table worked).
- Q3 cumulative-percent: **double-100 off-by-100x bug** in the literal SQL contradicts the responder's own example output table — resource teaches the correct single-100 form (r07:1229 / 1241 / 1269 / 1277 / 1292 all correct). **RESPONDER-DRIFT**, not resource-defect.
- Q4 RENAME COLUMN: clean — metadata-only / field-id-stable / old-name-stops-resolving / three-option playbook.

---

## iter689 recommendation

**Q3 is responder-drift, not resource-defect.** Per the directive's branch logic ("if the resource percent-of-total card r07:1234-1256 / share-of-grand-total r07:1068 is correct and only the responder drifted to double-100, note it as responder-drift and recommend iter689 = DEFAULT NO-OP unless a findable-but-wrong resource claim exists"):

The resource is correct on every percent-of-total card tested:
- r07:1241 worked example uses single-100 `ROUND(100.0 * revenue / SUM(revenue) OVER (), 2)` — OK
- r07:1229 H3-table row teaches `100.0 * x / SUM(x) OVER ()` — OK
- r07:1269, 1277, 1292 single-pass conditional-SUM / FILTER forms all single-100 — OK
- r07:1326, 1327, 1328 quick-reference rows all single-100 — OK
- r07:2519 share-of-grand-total cross-ref row repeats `100.0 * x / SUM(x) OVER ()` — OK

No resource teaches the double-100 form. The responder composed a running-cumulative-sum + share-of-grand-total fusion that no resource models as a single worked example, and double-multiplied in the fusion. This is stochastic Haiku drift.

### iter689 directive: OPTIONAL belt-and-suspenders FIX-A (LOW PRIORITY) or DEFAULT NO-OP

**The Q3 question shape — "daily revenue + cumulative percent of the month total" — is a natural and common shape that fuses two existing canonicals (running-sum + share-of-grand-total) but is not modeled as a single end-to-end worked example anywhere in r07.** Adding one small worked-example card (e.g., a new H3 "Running cumulative percent of grand total" or a 5-line card inside §5 Pattern A2 Bucketed running total) with:

1. The correct **single-100** literal SQL (one of Form A or Form B above).
2. The expected example-output table showing values monotonically rising to **100.0** on the last day (NOT 10000.0).
3. A 2-row DO-NOT-WRITE catching `100.0 * x / y * 100` (double-multiply 100) and `x / y * 100` without a decimal cast/literal (integer-division-truncates-to-0).
4. Keyword anchors: "running cumulative percent of month total," "running percent of total to date," "cumulative percent by day," "percent of grand total accumulated by each day," "running share of grand total."

— would inoculate against this specific fusion-drift surface. **But it is OPTIONAL.** The overall iter688 4.500 is a solid PASS, both iter687 FIX-A's CLOSED, and the underlying components (running sum, empty-OVER() grand total, single-100 share-of-total) are all docs-truth-correct in r07 already. The drift is in the responder's composition, not the resource.

**Primary recommendation: iter689 = OPTIONAL FIX-A** (small running-cumulative-percent worked example with DO-NOT-WRITE for double-100, added near §5 Pattern A2 or as a new H3 in the time-series carry-forward family at r07:~1232). **Fallback recommendation: iter689 = DEFAULT NO-OP** (the resource is internally correct; pick a re-probe target instead).

**Adversarial pick options for iter689 if going DEFAULT NO-OP:**
- Storage-tiering one more datapoint (now 3 datapoints with iter687 2.75 + iter688 5.00 in latest pair; running avg ~4.083; one more high-confidence probe would lock the FINDABILITY FIX-A durability claim).
- Exposures third datapoint (iter687 3.50 + iter688 5.00; one more probe locks the native-feature framing durability).
- Federation re-probe still optional high-risk thin-margin (44-iter ZERO probe streak, 4.49944 vs 4.5 threshold — only on bulletproofed angles).

---

## Topic avg updates

- **Storage tiering on Trino+Iceberg+MinIO** (Q1 FIX-A re-probe CLOSED canonical durability +0.40 — concrete mc-ilm-tier recipe with --transition-days/--transition-tier, by-AGE-not-access, scope to data/ keep metadata hot, no Trino SET STORAGE TIER DDL): running avg (4.25 × 2 + 2.75 + 5.00) / 4 = 17.25 / 4 = **4.3125** — recovers from iter687's 3.75 dip; topic now durably above threshold with 4 datapoints.
- **dbt exposures** (Q2 FIX-A re-probe CLOSED canonical durability +0.40 — exposures-as-native-first-class-feature framing + exposures.yml shape + dbt docs lineage + selection syntax): canonical durability secured; folded into dbt sources/freshness or a new dbt-exposures row depending on rubric organization.
- **Analytical query patterns on Iceberg+Trino** (Q3 cumulative percent: responder-drift on fusion of running-sum + share-of-grand-total to double-100; resource correct on both components separately): -0.20 on canonical durability for the unmodeled fusion shape; logged as responder-drift, optional FIX-A noted.
- **Iceberg schema evolution / RENAME COLUMN** (Q4 canonical durability +0.30 — metadata-only field-id-stable, old name stops resolving, three-option safe-rename playbook): r17:295-439 confirmed durable; lock holds.

## DO NOT

- bump training/state.json (teacher already set to 688);
- rewrite r16:499-628 storage-tiering LEADING CANONICAL (docs-truth-correct, iter687 FIX-A landing CONFIRMED on iter688 Q1 re-probe — HELD);
- rewrite r27:3421+ §6.7H2 exposures LEADING CANONICAL (docs-truth-correct, iter687 FIX-A landing CONFIRMED on iter688 Q2 re-probe — HELD);
- rewrite r17:295-439 RENAME COLUMN LEADING CANONICAL (docs-truth-correct, Q4 confirmed durable — HELD);
- rewrite r07:1229 / 1241 / 1269 / 1277 / 1292 / 1326-1328 share-of-grand-total cards (all correct single-100 — HELD);
- touch r22 federation guardrails (44-iter ZERO probe streak; 4.49944 vs 4.5 threshold THIN);
- rewrite iter534-687 locks (iter686 r07:1594 CAST-trap HELD; iter685 r07:1594 dual-destination HELD; iter684 r09:366/386/401/410 snapshot unique_key HELD; iter682 dbt-incremental/EXPLAIN/tests HELD; iter681 CREATE-TABLE-no-PRIMARY-KEY HELD; iter679 max_recursion_depth HELD; iter676 slice() HELD; iter674 string/array_join/reduce HELD; iter673 MAP/JSON/greatest/width_bucket HELD; iter671 ts-diff HELD; iter670 MoR-vs-CoW HELD; iter668 r27:4122 rollback-CALL HELD; iter667 DataSize/ROWS-vs-RANGE HELD; iter666 r12 maintenance HELD; iter665 day_of_week-name HELD; iter658/656/638 min_by/max_by HELD);
- add `::`-casts (iter571 PIN), QUALIFY, RLIKE (iter623), PERCENTILE_CONT/MEDIAN (iter611), EXTRACT(EPOCH) (iter562); fabricate dayname()/initcap (iter659/665); DISTINCT-ON Postgres-leak (iter634); 0=Sunday Postgres carryover (iter665); WRITE `timestamp - timestamp` ANYWHERE; present `array_contains`/`array_slice` as Trino forms (iter676); WRITE "max_recursion_depth defaults to 1000/100" (iter679); WRITE that Trino accepts PRIMARY KEY/FOREIGN KEY/UNIQUE in CREATE TABLE (iter681); WRITE that dbt snapshot unique_key resolves against source-table columns (iter683/684); fabricate native Trino/Iceberg storage-tiering DDL (iter683); WRITE bare `MAX(col)` in WHERE clause (iter684); WRITE `CAST(naive_timestamp AS TIMESTAMP WITH TIME ZONE)` claiming it attaches UTC (iter685/686);
- **NEW iter688 ban: WRITE `100.0 * x / y * 100` (double-multiply by 100) in any percent-of-total worked example — the leading `100.0 *` already produces a percent; the trailing `* 100` multiplies by 100 a second time, yielding values 100x too large. Pick ONE of leading `100.0 *` OR trailing `* 100` with a decimal cast on the numerator; never both.**

## Meta-note

iter688 demonstrates that both iter687 FIX-A's landed cleanly: the storage-tiering FINDABILITY broadening at r16:501 + the r17->r16 cross-ref callout (iter687 FIX-A1) successfully routed the Q1 re-probe from r17 to r16:499 with full mc-ilm-tier recipe delivery; the new r27:3420 §6.7H2 exposures-as-native LEADING CANONICAL with explicit native-feature framing + DO-NOT-WRITE wrong-framing table (iter687 FIX-A2) successfully inoculated the Q2 re-probe against contradictory-framing drift. Q3 is the new defect — a responder-drift on a fusion shape (running-sum + share-of-grand-total composed into running cumulative percent) that no resource models as a single worked example. The literal SQL produces values 100x too large despite the example output showing the correct values, so the responder "knew" the answer but the executable artifact is wrong. Q4 RENAME COLUMN clean. Resources correct on every dialect fact tested.

Trajectory iter660-688 (5.00 → 4.5625 → 5.000 → 3.656 → 4.5625 → 4.5625 → 4.375 → 4.125 → 4.9375 → 5.000 → 4.9375 → 5.000 → 4.500 → 4.875 → 4.78 → 4.5625 → 4.875 → 4.375 → 5.000 → 4.8125 → 4.500 → 4.9375 → 4.3125 → 4.9375 → 4.0625 → **4.500**) — sustained 4.0+ across 31 of last 32 iterations; recovery to mid-4.5 from iter687's 4.0625 dip via both FIX-A's landing.

**OVERALL: 4.500 PASS — both iter687 FIX-A's (storage-tiering FINDABILITY + exposures-native framing) CLOSED; Q1/Q2/Q4 all 5.00; Q3 3.00 with a double-100 off-by-100x SQL defect that contradicts its own example output (responder-drift on running-cumulative-percent fusion shape, NOT resource-defect — r07 percent-of-total cards all teach correct single-100 form); iter689 recommendation = OPTIONAL FIX-A for a running-cumulative-percent worked example with DO-NOT-WRITE for double-100 at r07 (LOW PRIORITY), or DEFAULT NO-OP with adversarial pick on storage-tiering / exposures third-datapoint lock; federation still untouched (44-iter ZERO streak, 4.49944 vs 4.5 thin).**
