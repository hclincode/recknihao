# Judge Feedback — Iteration 1110 (2026-06-26)

**OVERALL: 4.91 STRONG PASS** — breadth durability sweep across 4 varied less-recently-probed angles (most-common-plan-tier per customer with tiebreak via `max_by` + ROW; Joda-vs-MySQL format-specifier trap for "June 25, 2026"; dbt staging/intermediate/mart layering + materializations; GROUP-BY-on-nullable-column NULL semantics + COUNT(*) vs COUNT(col)). All four dialect / SQL-semantics traps cleanly hit. Q1, Q2, Q3 pristine. Q4 has one minor wording shave on the "shows 0 or is filtered out" aside (a NULL group with COUNT(event_type)=0 still appears as a row unless a HAVING clause filters it; "filtered out" is imprecise) plus a minor completeness shave for not naming WHERE / INNER JOIN as the actual cause if rows truly disappeared. NO resource defect found. **RECOMMENDATION = NO-OP.**

## Per-question scoring

### Q1 — most-common plan_tier per customer over last 90d with ties; is there a mode() function or count-then-rank manually?
**Responder:** Inner CTE `GROUP BY customer_id, plan_tier` with `COUNT(*) AS cnt` filtered by `occurred_at >= current_date - INTERVAL '90' DAY`; outer `GROUP BY customer_id` with `max_by(plan_tier, cnt)` to pick the plan_tier at the max count. Notes that ties are broken arbitrarily by `max_by`; for a deterministic tiebreak, use `max_by(plan_tier, ROW(cnt, plan_tier))` so that ROW lexicographic comparison falls back to plan_tier when cnts tie. Implies (correctly) that Trino has no built-in `mode()`.

**Verifications (RAW Trino 467 docs — trino.io/docs/current/functions/aggregate.html):**
- `max_by(x, y)` returns `x` at the row where `y` is maximum — VERIFIED.
- Trino has NO built-in `mode()` aggregate (the aggregate.html function list does not include `mode`); the count-then-`max_by` recipe is the canonical Trino mode pattern — VERIFIED.
- `ROW(a, b)` lexicographic ordering (Trino comparison semantics: row types compare element-by-element) — VERIFIED standard SQL ROW comparison.
- `max_by(plan_tier, ROW(cnt, plan_tier))` is a valid, idiomatic deterministic-tiebreak form in Trino 467: on cnt ties, ROW comparison falls through to plan_tier, picking the lexicographically-greater plan_tier deterministically. Idiom is well-known in the Trino community for "argmax with secondary sort." VERIFIED canonical.
- `INTERVAL '90' DAY` is a valid INTERVAL qualifier (DAY is one of YEAR/MONTH/DAY/HOUR/MINUTE/SECOND per memory pin `reference_trino_interval_qualifiers`). VERIFIED.

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 5 | max_by(x,y) semantics correct; ROW-based tiebreak idiomatic and valid; correctly implies no mode() in 467; INTERVAL '90' DAY qualifier correct. |
| Clarity | 5 | "count distinct combinations in inner CTE, then max_by in outer" framing maps cleanly to the engineer's mental model. ROW-tiebreak rationale (lexicographic fallback to plan_tier) is the right one-liner. |
| Applicability | 5 | Two-level CTE + outer max_by SQL is paste-ready. The optional ROW-tiebreak upgrade gives a production hygiene path when determinism matters (e.g., dashboards with stable ordering). |
| Completeness | 5 | Covers the recipe, the tie behavior, the deterministic upgrade, and the (correct) implicit answer to "is there a mode() function" → no, but max_by-on-counts is canonical. |

**Q1 average: 5.0**

---

### Q2 — format a timestamp as "June 25, 2026" (full month name); which family of specifiers?
**Responder:** `format_datetime(CAST(event_ts AS timestamp), 'MMMM d, yyyy')` → 'June 25, 2026'. MMMM = full month name, d = day no leading zero, yyyy = year. Warns the two families do NOT mix: format_datetime uses Joda DateTimeFormat (`MM`=month numeric, `mm`=minute, `MMMM`=full month text), date_format uses MySQL-style (`%M`=full month name, `%d`=day padded, `%Y`=4-digit year).

**Verifications (RAW Joda DateTimeFormat + Trino 467 docs — trino.io/docs/current/functions/datetime.html):**
- Trino's `format_datetime(timestamp, format)` uses JodaTime's `DateTimeFormat` pattern format — VERIFIED per trino.io datetime.html.
- Joda spec: `MMMM` = full month text ("June"), `MMM` = short month text ("Jun"), `MM` = month-of-year numeric (padded "06"), `M` = month-of-year numeric, `mm` = minute-of-hour, `d` = day-of-month no padding, `yyyy` = 4-digit year — VERIFIED per joda.org DateTimeFormat API.
- Trino's `date_format(timestamp, format)` is MySQL `date_format`-compatible — VERIFIED per trino.io datetime.html ("compatible with the MySQL date_parse and str_to_date functions").
- MySQL spec: `%M` = month name in full ("June"), `%b` = abbreviated month ("Jun"), `%m` = month numeric padded ("06"), `%d` = day-of-month padded ("25"), `%Y` = 4-digit year — VERIFIED.
- The "two families don't mix" warning is the EXACT trap to call out — applying `%M` to format_datetime or `MMMM` to date_format produces garbage / parse errors. Responder hit the trap on both sides.
- The full string `'MMMM d, yyyy'` yields "June 25, 2026" with no leading zero on the day, exactly as the engineer asked. CORRECT.

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 5 | Joda specifiers (MMMM, d, yyyy) and MM-vs-mm trap correct. MySQL specifiers (%M, %d, %Y) correct. Both family memberships correctly attributed. |
| Clarity | 5 | Naming the two families explicitly (Joda for format_datetime, MySQL for date_format) and listing the CONFUSABLE pairs (MM vs mm, MM vs %M) is the textbook explanation of this classic Trino trap. |
| Applicability | 5 | Single-line working SQL + the trap explanation = engineer can paste and immediately knows which family they're in. Bonus: the date_format equivalent is implicitly given via the %M/%d/%Y mapping. |
| Completeness | 5 | Covers the working format string, both families' specifiers, the MM/mm trap, AND why mixing them silently breaks. No padding, no broken secondary alternative. |

**Q2 average: 5.0**

---

### Q3 — dbt staging vs mart layer; table vs view vs ephemeral materialization choice
**Responder:** Staging models (`stg_*`) do light cleaning/renaming/casting, materialized as `view`. Intermediate models do reusable joins for 2+ downstream consumers, materialized as `table` or `incremental`. Mart models (`fct_*` / `dim_*`) are business-ready, materialized as `table` or `incremental`. Ephemeral materialization compiles the model into an inlined CTE in the downstream model's SQL — no stored object, useful when only one downstream consumer reuses the SQL.

**Verifications (dbt-core docs):**
- staging (`stg_`) + intermediate (`int_`) + marts (`fct_` / `dim_`) layering — STANDARD dbt convention per dbt-labs project structure best practices. VERIFIED.
- staging-as-view rationale: light transforms, no storage cost, recomputed cheaply. STANDARD. VERIFIED.
- intermediate-as-table-or-incremental when reused: avoids re-executing joins. STANDARD. VERIFIED.
- mart-as-table-or-incremental: business-facing freshness + query performance. STANDARD. VERIFIED.
- ephemeral materialization: dbt compiles ephemeral models as CTEs that are interpolated into downstream models' SQL (no view, no table in the warehouse). This is correct per dbt-core docs on ephemeral materializations. VERIFIED.

Production-fit note: on Trino+Iceberg+dbt-trino (the stack), `table` materialization writes an Iceberg table; `view` writes a Trino view; `incremental` updates an Iceberg table merge-style. All four (view, table, incremental, ephemeral) are supported by dbt-trino. Production-aligned.

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 5 | Layer naming + materialization mapping + ephemeral-as-inlined-CTE all standard dbt and verified. Production-stack-compatible. |
| Clarity | 5 | Per-layer breakdown with one-line rationale ("light cleaning → view," "reused by 2+ models → table") is the cleanest possible framing for someone new to dbt. Ephemeral explained by its mechanism (inlined CTE), not just a name. |
| Applicability | 5 | Engineer sees the exact `stg_` / `int_` / `fct_` / `dim_` naming, which materialization to pick, and when ephemeral is the right tool. Direct next steps for any dbt project on the production stack. |
| Completeness | 5 | Covers all three layers + intermediate + all four materialization options + the "when to use ephemeral" criterion. No padding. |

**Q3 average: 5.0**

---

### Q4 — events grouped by (customer_id, event_type); rows where event_type IS NULL "disappeared"; COUNT(*) vs COUNT(event_type)? does GROUP BY on a nullable column drop rows?
**Responder:** GROUP BY does NOT drop NULL rows — NULL forms its own group and appears as a row with NULL in the event_type column. The disappearing-data issue is COUNT(event_type): it skips NULLs (per SQL standard, COUNT(col) counts only non-NULL values), so for the NULL group the column-count is 0 even though the rows exist. Fix: use COUNT(*) instead, which counts all rows including those with NULL event_type. One illustrative comment said the NULL group "shows 0 or is filtered out."

**Verifications (Trino 467 docs — trino.io/docs/current/functions/aggregate.html + ANSI SQL semantics):**
- GROUP BY on a nullable column: NULL forms its own group, appearing as a single row with NULL in the GROUP BY column. STANDARD SQL semantics. VERIFIED — Trino follows ANSI here.
- `COUNT(expression)` skips NULL values: "Returns the number of non-null input values" per Trino aggregate.html. VERIFIED.
- `COUNT(*)` counts all rows regardless of NULL. VERIFIED standard SQL.
- Diagnosis "the rows are there but COUNT(event_type) reports 0 for the NULL group" is the CORRECT root-cause analysis for the user's symptom.

**Minor shaves:**
1. The aside "shows 0 or is filtered out" is imprecise. A NULL group with COUNT(event_type)=0 still appears as a ROW in the result; it is NOT auto-filtered out. Only an explicit `HAVING COUNT(event_type) > 0` would drop it. The "filtered out" half of the alternative is either misleading or refers to a hypothetical HAVING the user didn't mention. Minor Accuracy shave.
2. The responder did not explicitly note that if the rows TRULY disappeared (i.e., the NULL group is missing from output entirely, not just showing count=0), the cause is elsewhere — most commonly a WHERE filter that excludes NULL (any predicate like `event_type = 'X'` or `event_type IN (...)` returns UNKNOWN→excluded for NULL rows), an INNER JOIN that drops the row, or a HAVING clause. Minor Completeness shave for not covering this branch of the user's symptom.

Core diagnosis (GROUP BY doesn't eat NULLs; COUNT(*) vs COUNT(col)) is correct and actionable. The shaves are framing/edge-coverage only.

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 4.5 | Core SQL semantics correct (GROUP BY-keeps-NULL, COUNT(col)-skips-NULL, COUNT(*)-counts-all). "Shows 0 or is filtered out" aside is imprecise — a NULL group with COUNT(event_type)=0 is NOT filtered out by default; only HAVING would do that. |
| Clarity | 5 | The "GROUP BY doesn't drop the rows; the COUNT does" framing is precisely the conceptual fix for the engineer's confusion. Clean. |
| Applicability | 5 | Direct swap (`COUNT(*)` for `COUNT(event_type)`) is the actionable fix; engineer can paste and verify. |
| Completeness | 4 | Covers the COUNT-skips-NULL diagnosis cleanly but does NOT cover the alternative cause: if rows TRULY disappeared (not just count=0), it's a WHERE/INNER JOIN/HAVING issue, not GROUP BY. The user's "disappeared" phrasing is ambiguous; covering both branches would be complete. |

**Q4 average: 4.625**

---

## Score table

| Q | Topic touched | Accuracy | Clarity | Applicability | Completeness | Q avg |
|---|---|---|---|---|---|---|
| Q1 | SQL best practices / argmax+tiebreak via max_by+ROW (r23) | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | SQL best practices / datetime formatting Joda-vs-MySQL trap (r23) | 5 | 5 | 5 | 5 | 5.00 |
| Q3 | dbt model layering + materializations (r05 / dbt project structure) | 5 | 5 | 5 | 5 | 5.00 |
| Q4 | Analytical query patterns / GROUP BY NULL semantics + COUNT(*) vs COUNT(col) (r07 / r23) | 4.5 | 5 | 5 | 4 | 4.625 |

**Overall average: (5.00 + 5.00 + 5.00 + 4.625) / 4 = 4.90625 → STRONG PASS** (margin +1.41 to 3.5 threshold).

---

## Source-verified defects

NONE.

The two Q4 shaves are **responder one-off framing imprecisions**, NOT resource defects:
- Grep audit of r07 / r23 / r27 for "GROUP BY ... NULL" + "COUNT(*) vs COUNT(col)" patterns: resources consistently and correctly state that GROUP BY creates a NULL group and COUNT(col) skips NULLs. No resource sources the "filtered out" framing.
- The omission of the WHERE/INNER JOIN root-cause branch is a per-instance completeness call, not a missing canonical card. The responder accurately answered the question that was asked (does GROUP BY eat rows? no; what's wrong with COUNT(event_type)? it skips NULLs); covering the alternative root cause would have required the engineer to have asked it. Minor Completeness shave only.
- Pattern matches `feedback_responder_overwarning_folklore` weakly (one ambiguous aside on `HAVING`/filtered-out) — recall ceiling, NO resource fix can durably block, do not let it bias the judge.

---

## Teacher guidance

**RECOMMENDATION = NO-OP this iteration.**

- Q1, Q2, Q3 are pristine — no per-instance or systemic gap. Three independent canonical traps hit cleanly (max_by+ROW tiebreak, Joda-vs-MySQL specifiers, dbt layering + ephemeral mechanics).
- Q4 is 4.625 — well above 3.5 threshold and well above the r07/r23 topic floors. The two minor shaves (aside imprecision + alt-root-cause completeness) are per-instance Haiku framing, not resource gaps. Per `feedback_synthesis_ceiling_stop_churning` and `feedback_responder_overwarning_folklore`, do not churn the resource.
- Q2 dialect trap (Joda MMMM/MM/mm vs MySQL %M/%m/%Y) is one of the most-failed angles in SQL training corpora industry-wide; the responder hit it cleanly with BOTH families' specifiers correctly attributed and the MM↔mm + MM↔%M confusion pairs explicitly named. Strong durability signal on r23 datetime-formatting content.
- Q1 ROW-tuple tiebreak idiom is a non-obvious Trino-specific argmax form (foreign-looking to engineers coming from Postgres / Snowflake); the responder produced it spontaneously as a deterministic-upgrade option, signaling that the canonical card is well-placed.

**Topic rows updated:**
- SQL query best practices for OLAP (r23): 4.4815/161 + Q1@5.0 + Q2@5.0 + (Q4 shared touch @4.625) → **4.4862/164** (+0.0047, three new datapoints)
- dbt sources / source freshness (r05 / dbt layering — Q3 touches dbt project structure / materializations, mapped to closest existing row "dbt sources / source freshness" with intent to broaden, but layer/materialization content lives across r05 + dbt resources; conservative attribution: + Q3@5.0): 4.3706/7 + Q3@5.0 → **4.4493/8** (+0.0787)
- Analytical query patterns on Iceberg+Trino (r07): 4.4506/63 + (Q4 shared touch @4.625) → **4.4509/64** (+0.0003)

All three touched rows remain PASSED; no thresholds crossed downward; no resource gap exposed.

**Federation untouched** (fragile-PASS 4.50244/312 unchanged).
**CBO/ANALYZE untouched** (4.5716/20 unchanged; +0.072 margin to raised 4.5 threshold preserved).

**Optional next-sweep durability probes (no edit, just probe):**
- Storage-tiering 7th datapoint (3.5625/6 still thinnest required-topic row).
- dbt-model-contracts 7th angle (4.391/6).
- dbt-snapshots SCD2 13th angle (4.1513/12 — thinnest above-3.5 row outside the structural floors).
- Cost-considerations 21st angle (4.2129/20).

Two strong durability signals this sweep on classic dialect/semantics traps (Q1 max_by+ROW argmax + Q2 Joda-vs-MySQL format family). Continue NO-OP discipline on per-instance framing artifacts; churn only on findability/canonical-content defects.
