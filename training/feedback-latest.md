# Judge Feedback — Iter 512 (Extended Phase, 2026-06-06)

## Overall: 4.234 PASS — narrow margin (+0.734 above 3.5 floor)

| Q | Topic | Acc | Clar | Appl | Comp | Avg | Verdict |
|---|---|---|---|---|---|---|---|
| Q1 | INTERSECT/EXCEPT plan re-probe (SemiJoin) | 4.0 | 4.5 | 4.5 | 4.5 | **4.375** | PASS (fix LANDED + one fabricated annotation) |
| Q2 | SUM of DECIMAL over 400M rows | 1.5 | 4.0 | 3.5 | 3.0 | **3.000** | **FAIL** (core diagnosis wrong) |
| Q3 | 7-day rolling avg with window frame | 5.0 | 5.0 | 5.0 | 4.5 | **4.875** | STRONG PASS clean |
| Q4 | dbt --full-refresh on incremental + schema change | 4.5 | 4.75 | 4.75 | 4.75 | **4.6875** | STRONG PASS (one mechanism nit) |

OVERALL AVG = (4.375 + 3.000 + 4.875 + 4.6875) / 4 = 16.9375 / 4 = **4.234** PASS (above the 3.5 floor; Q2 drags hard but Q3+Q4 absorb).

---

## Q1 — INTERSECT/EXCEPT plan terminology — 4.375 PASS

**THE ITER511 ANTI-JOIN TERMINOLOGY FIX LANDED.** The responder no longer calls INTERSECT an anti-join. It now correctly states:
- SemiJoin IS the correct/expected plan node for INTERSECT (rows in both inputs = semi-join semantics, like `WHERE EXISTS` / `IN`).
- EXCEPT has anti-join semantics (rows in left NOT in right).
- Seeing `SemiJoin` in `EXPLAIN` of an INTERSECT/EXCEPT is correct, not a bug.

This is the **22nd leading-canonical bulletproofing instance** to land on first re-probe and confirms the iter512 teacher's r27 §4.5 set-op rows reconcile-in-place edit at lines 1131-1133 hit. The "INTERSECT = anti-join" iter511 Q2 mislabel is GONE.

**FABRICATED ANNOTATION — citation hygiene nit (-0.5 Accuracy, -0.5 Completeness):** The answer claims EXPLAIN renders `SemiJoin[..., FilterMode = ANTI]` on the plan node. **This annotation does not exist in Trino's EXPLAIN output.** Verified against trinodb/trino wiki Plan-nodes page + trino.io/docs/current/sql/explain.html:
- Trino's actual SemiJoin node renders as `SemiJoin[joinkey = joinkey_n]` with output symbols including a boolean `semijoinoutput` column.
- Anti-join semantics for EXCEPT/NOT EXISTS/NOT IN come from a **downstream Filter on `NOT semijoinoutput`**, not from a `FilterMode = ANTI` token on the SemiJoin node itself.
- The literal string `FilterMode = ANTI` appears nowhere in Trino's plan-renderer source or docs.

The conceptual semi-join-vs-anti-join distinction is correct, so this is a partial deduction (fabricated internal EXPLAIN syntax — same failure-class as past r17 `file_size_in_bytes` $partitions fabrication). An engineer searching plan output for the literal "FilterMode = ANTI" will not find it and will be confused.

---

## Q2 — SUM of DECIMAL over 400M rows — 3.000 FAIL (sub-threshold individually; core diagnosis WRONG)

**CRITICAL ACCURACY ERROR — verified against trino.io/docs/current/functions/aggregate.html + Trino issues #20227 / #10732:**

The answer claims:
> "Trino's aggregate does NOT automatically widen the result type — it stays the same precision/scale as the input."

This is **FALSE**. The correct behavior:
- `sum(decimal(p, s))` returns **`decimal(38, s)`** — Trino DOES auto-widen the result to precision 38, retaining the input scale. Verified verbatim via aggregate-functions docs ("For decimal input of decimal(p, s), the return type is decimal(38, s)").
- A `DECIMAL(10, 2)` summed across 400M rows yields max `~4 × 10^16` (~17 digits) — **comfortably under precision 38**, no overflow risk from row count alone.
- On true overflow, Trino raises an **error** (`NUMERIC_VALUE_OUT_OF_RANGE` / "Value is out of range"), per trinodb/trino #20227 + #10732 — it does **NOT** "truncate silently."

The answer's core diagnosis (no auto-widen + silent truncation + likely overflow on 400M `DECIMAL(10,2)` rows) is largely wrong. The user's "too small" symptom is almost certainly something else:
- A filtered subset (a WHERE clause that excludes more than expected).
- A JOIN fan-out that's dropping rows, not duplicating them.
- Scale rounding from an upstream CAST/divide that shaved the scale.
- A NULL-heavy column with `SUM` ignoring NULLs (legitimate but unexpected).

The mitigation `SUM(CAST(revenue AS DECIMAL(18, 2)))` is harmless but **redundant** — the SUM result is `decimal(38, 2)` regardless of whether you cast input to `DECIMAL(18, 2)` or leave it `DECIMAL(10, 2)`. The DECIMAL(18, 2) default for currency advice is reasonable but doesn't address the actual problem.

`SHOW CREATE TABLE` to check column precision/scale is a fine practice — but won't reveal the real root cause if it's a filter/join issue.

**Scoring:**
- Accuracy 1.5 — load-bearing "no auto-widen" + "silent truncate" claims are both factually wrong; user is sent down a wrong-fix path.
- Clarity 4.0 — well-written and easy to follow (which makes the wrongness worse — confidently wrong).
- Applicability 3.5 — the mitigation runs and won't error, but doesn't fix the symptom.
- Completeness 3.0 — misses the actually-likely causes (filter/join/scale/NULL).

---

## Q3 — 7-day rolling average — 4.875 STRONG PASS clean

Verified against trino.io/docs/current/functions/window.html + trinodb/trino #5162 (RANGE BETWEEN support shipped in version 346):
- `AVG(dau) OVER (PARTITION BY tenant_id ORDER BY day RANGE BETWEEN INTERVAL '6' DAY PRECEDING AND CURRENT ROW)` is **valid Trino 467** syntax.
- RANGE-with-INTERVAL is **value/calendar-based** — frame is "all rows whose ORDER BY value is within 6 days of current" — gap-correct (missing days don't shift the window).
- ROWS is **position-based** — frame is "the previous 6 rows" — wrong on missing days because it counts rows, not calendar dates.
- Empty-frame day → AVG returns NULL → COALESCE/stakeholder discussion is correct production guidance.

Minor -0.5 Completeness: no callout that the source data must already be at one-row-per-tenant-per-day grain (with explicit zeroes for no-activity days) for the rolling avg to be true rolling 7-day; otherwise pre-aggregate via `GROUP BY tenant_id, day` first or use a calendar-spine LEFT JOIN. Non-load-bearing.

---

## Q4 — dbt --full-refresh on incremental with schema change — 4.6875 STRONG PASS (one minor mechanism nit)

Verified against docs.getdbt.com/reference/resource-configs/full_refresh + docs.getdbt.com/docs/build/incremental-models:
- `--full-refresh` makes `is_incremental()` return FALSE, skipping the WHERE filter and rebuilding from scratch — CORRECT.
- Required-after list (changed WHERE/watermark logic, structural column changes like widened DECIMAL or NOT NULL flip, changed unique_key, manual data corruption) is **accurate and well-scoped**.
- `on_schema_change='append_new_columns'` handling nullable-add without full-refresh — CORRECT.

**Minor mechanism nit (-0.25 Accuracy):** Answer says rebuild happens via "INSERT OVERWRITE (operation='overwrite')". For **dbt-trino on Iceberg**, the actual mechanism is closer to **DROP + CREATE TABLE AS** (or `CREATE OR REPLACE TABLE`) — the docs explicitly say "drop cascade the existing table before rebuilding it." `INSERT OVERWRITE` is more of a Hive/Spark idiom and is not the literal Trino-Iceberg path. The conceptual outcome (table fully replaced with rebuilt rows) is identical, so this is a minor terminology nit, not a correctness break.

---

## Iter-wide patterns and next-teacher actions

**Wins:**
- Iter511 INTERSECT-anti-join fix LANDED on first re-probe (Q1) — r27 §4.5 lines 1131-1133 reconcile-in-place confirmed effective. **22nd consecutive leading-canonical bulletproofing landing.**
- Q3 (rolling window) and Q4 (full-refresh) both STRONG PASS clean against authoritative docs.
- Zero federation probing — 4.49944/310 row untouched per directive.

**New gap (iter513 HIGH-PRIORITY reconcile target):**
- Q2 **DECIMAL SUM auto-widen** is a **load-bearing technical error**. Two false claims:
  1. "Trino does NOT automatically widen the SUM result" — FALSE. `sum(decimal(p,s)) → decimal(38, s)`.
  2. "Trino will either truncate silently or throw an overflow error" — FALSE. Trino raises an error on decimal overflow (`NUMERIC_VALUE_OUT_OF_RANGE`); it does NOT truncate silently.

**Iter513 teacher reconcile-in-place target — DECIMAL aggregate behavior canonical:**
- File: likely `resources/23-sql-best-practices-olap.md` or `resources/03-column-storage.md` or wherever DECIMAL precision/scale is taught (grep `sum(decimal` / `DECIMAL.*overflow` / `decimal.*precision`).
- Add (or reconcile) a callout: **`sum(decimal(p,s))` returns `decimal(38, s)` in Trino 467 — the result auto-widens to maximum precision 38, retaining the input scale. A `DECIMAL(10,2)` summed across billions of rows will not overflow until the accumulated value exceeds ~`10^36`. Overflow raises `NUMERIC_VALUE_OUT_OF_RANGE`, not silent truncation. If a SUM "looks too small," the cause is almost always (1) an unintended WHERE filter, (2) JOIN row loss / fan-out, (3) scale truncation from an upstream CAST, or (4) NULL-heavy column with SUM ignoring NULLs — NOT precision overflow.**
- DO-NOT-WRITE bans: "Trino does not widen the SUM result"; "SUM of DECIMAL truncates silently on overflow"; "you need `SUM(CAST(x AS DECIMAL(38,...)))` to avoid overflow".
- Verified against trino.io/docs/current/functions/aggregate.html + trinodb/trino issue #20227.

**Iter513 teacher MEDIUM-PRIORITY citation-hygiene nit:**
- Q1 fabricated `SemiJoin[..., FilterMode = ANTI]` annotation. The conceptual answer (SemiJoin is correct, anti-semantics via downstream Filter) is right, but the literal annotation is invented. Recommend r27 §4.5 set-op rows (or r23 §10 semi/anti jargon gloss) clarify that:
  - Trino's plan-renderer shows `SemiJoin[joinkey = joinkey_n]` with output symbol `semijoinoutput:boolean`.
  - Anti-semantics for EXCEPT come from a **`Filter[NOT semijoinoutput]`** node downstream of the SemiJoin — not from a `FilterMode = ANTI` token on the SemiJoin itself.
  - DO-NOT-WRITE: any literal `FilterMode = ANTI` plan-node annotation that isn't taken verbatim from a real EXPLAIN output.

**Iter513 teacher MINOR Q4 nit (optional):**
- `dbt-trino` full-refresh mechanism on Iceberg uses `DROP` + `CREATE TABLE AS`, not `INSERT OVERWRITE`. Worth a callout if there's a natural place at r27 §6.7 or wherever full-refresh is taught.

**Iter513 probe targets:**
- **DECIMAL SUM re-probe (HIGH)**: "I summed a `DECIMAL(8,2)` revenue column across 2B rows and the total looks suspiciously rounded — is Trino's SUM precision-limited? do I need to cast?" — verifies the auto-widen + error-not-truncate fix lands.
- **DECIMAL overflow second angle (HIGH)**: "What happens if a SUM(DECIMAL) result exceeds `10^38`? does Trino error out or wrap?" — verifies "error not silent" claim is corrected in resources.
- **INTERSECT/EXCEPT plan EXPLAIN annotation 3rd angle (MEDIUM)**: "I ran EXPLAIN on `a EXCEPT b` and don't see any `FilterMode = ANTI` — is the EXCEPT being optimized away?" — verifies fabricated annotation does not reappear.
- **dbt full-refresh on Iceberg mechanism (MEDIUM)**: "Does dbt --full-refresh on a dbt-trino Iceberg model `INSERT OVERWRITE` or `DROP+CREATE`?" — verifies Q4 mechanism nit.
- **RANGE vs ROWS frame on a gappy series (LOW)**: "If my DAU table has missing days, does ROWS 6 PRECEDING give wrong rolling avgs?" — confirms Q3 robustness.
- **Federation stays UNPROBED (LOW)** per iter472-512 directive.

**Margin:** +0.734 above 3.5 floor (4.234 iter avg). This is the **narrowest extended-phase margin in recent memory** and the **first FAIL-grade individual answer (Q2 = 3.000) in many iters**. The iter-wide PASS is preserved by Q1/Q3/Q4 strength, but Q2's confidently-wrong DECIMAL diagnosis is a real production-risk error — an engineer following Q2 ships the wrong mitigation and never finds the real cause. **This is the iter513 primary fix target.**

**111th consecutive overall PASS in extended phase**, but the narrowest in 10+ iters. Recommend teacher prioritize the DECIMAL SUM canonical fix above all other adjustments for iter513.
