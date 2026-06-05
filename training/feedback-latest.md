# Iter 493 Judge Feedback — 2026-06-06 (EXTENDED PHASE)

## Overall: 4.7813 STRONG PASS (+1.281 above 3.5 floor)

YoY CANONICAL HELD. iter492 Q2 load-bearing semantic mismatch (MoM-labeled-as-YoY) FULLY RESOLVED. Responder pattern-matched the leading canonical example in r07 §B2 FORM A self-join verbatim. No fabrications, no internal inconsistencies, no new failure modes surfaced. Margin to threshold larger than any iter in the iter460+ window.

---

## Per-question scores

### Q1 — YoY current-month vs same-month-last-year, newer customers preserved (Analytical query patterns on Iceberg+Trino — the YoY re-probe)

Scores: **Accuracy 5.0 / Clarity 4.75 / Actionability 5.0 / Completeness 5.0 → avg 4.9375 STRONG PASS**

**YoY canonical HELD — this is the load-bearing check for iter493.**

Verified elements (all match r07 §5 Pattern B2 FORM A verbatim):
- `date_trunc('month', occurred_at) AS month` + `COUNT(*) AS usage_count` in monthly CTE — CORRECT grain.
- `LEFT JOIN monthly prev ON prev.customer_id = cur.customer_id AND prev.month = date_add('month', -12, cur.month)` — EXACT canonical join predicate; gap-safe by construction.
- Outer filter `WHERE cur.month = date_trunc('month', current_date)` — yields one row per customer for the current month.
- YoY growth formula `(cur.usage_count - prev.usage_count) * 1.0 / NULLIF(prev.usage_count, 0) * 100` — divide-by-zero-safe.
- Explicitly explains: **LEFT JOIN preserves newer customers (no prior-year row -> prev = NULL); NULLIF makes yoy_growth_pct NULL for them; they are NOT dropped** — directly answers the load-bearing requirement.
- Calls out that this self-join form **avoids the LAG(12)-on-sparse-series wrong-month bug** — meta-correct; shows the responder absorbed the GAP-FILL CAVEAT framing from Pattern B2.
- Uses `date_add('month', -12, cur.month)` — type-safe (not the banned `cur.month - 12` bare integer subtraction).

**Forbidden forms NOT used:**
- NOT `LAG(metric)` default-offset-1 labeled as YoY (the exact iter492 Q2 fail form) — AVOIDED.
- NOT MoM mislabeled as YoY — AVOIDED.
- NOT `usage_last_month` column fed into `yoy_growth_pct` — AVOIDED.
- NOT bare integer subtraction on TIMESTAMP — AVOIDED.

WebSearch-VERIFIED at trino.io/docs/current/functions/window.html (`lag(x[, offset[, default_value]])`, default offset = 1) and trino.io/docs/current/functions/datetime.html (`date_add(unit, value, timestamp)`).

Clarity nick (4.75 not 5.0): the answer is technically complete but the *why* of "LEFT JOIN keeps newer customers" lands more as a one-line note than as an explicit worked example showing a newer-customer row with `prev.usage_count = NULL` and `yoy_growth_pct = NULL`. A one-line illustrative row would push to 5.0.

### Q2 — Subdomain parse via split_part / regex (SQL query best practices for OLAP)

Scores: **Accuracy 4.0 / Clarity 4.5 / Actionability 4.75 / Completeness 4.5 -> avg 4.4375 PASS**

- `split_part(url, '.', 1)` -> 'acme' for `'acme.ourapp.com'` — CORRECT (1-indexed, verified at trino.io/docs/current/functions/string.html).
- Signature `split_part(string, delimiter, part_index)` — CORRECT.
- `regexp_extract(url, '([a-z0-9-]+)\.ourapp\.com')` alternative for full URLs — CORRECT.
- Cross-references Oracle REGEXP_SUBSTR — useful framing for the Oracle-migration audience.

**One minor accuracy nick:** the answer says "empty string if index missing." Official Trino docs (and GitHub issue #14460) state that when the index is **larger than the number of fields, NULL is returned**, not empty string. (Empty strings are returned for empty fields *within* the field count, e.g. consecutive delimiters; that is a different case.) Mostly harmless because part_index = 1 always exists, but the doc-claim itself is inaccurate. Knock 1.0 off accuracy.

### Q3 — Iceberg snapshot retention after 8 months of no cleanup (Iceberg table maintenance)

Scores: **Accuracy 5.0 / Clarity 4.5 / Actionability 5.0 / Completeness 5.0 -> avg 4.875 STRONG PASS**

- `ALTER TABLE ... EXECUTE expire_snapshots(retention_threshold => '7d')` — CORRECT Trino 467 syntax.
- 7-day Trino min-retention floor — VERIFIED (trino.io/docs/current/connector/iceberg.html + Starburst forum).
- Expire deletes snapshot metadata AND data files referenced only by expired snapshots — CORRECT.
- Cannot time-travel to expired snapshots — CORRECT.
- `FOR TIMESTAMP AS OF` / `FOR VERSION AS OF <snapshot_id>` — CORRECT Trino syntax for time travel.
- Query `"<table>$snapshots"` for ids — CORRECT metadata table.
- 7d floor vs 30d recommended retention — sound prod guidance.
- Named refs (tags) protect snapshots from expiry regardless of age — CORRECT (Iceberg refs spec).
- **"On 467 expire_snapshots takes ONLY retention_threshold; retain_last/clean_expired_metadata are 479+, use Spark CALL for those"** — VERIFIED at trino.io/docs/current/release/release-479.html ("Add `retain_last` and `clean_expired_metadata` options to `expire_snapshots` command"). This is exemplary prod-environment awareness: the responder correctly avoided recommending parameters that don't exist on the user's Trino 467 deployment and gave the Spark-CALL escape hatch.

Clarity nick (4.5 not 5.0): the answer is dense — a worked example "table has 240 daily snapshots, run with 7d -> keeps last 7 days, deletes 233" would help a beginner picture the effect.

### Q4 — Oracle DECODE -> Trino CASE with NULL nuance (Oracle PL/SQL->dbt/Trino migration)

Scores: **Accuracy 5.0 / Clarity 4.75 / Actionability 5.0 / Completeness 4.75 -> avg 4.875 STRONG PASS**

- Simple CASE only when NOT NULL — CORRECT.
- **DECODE NULL=NULL matching nuance:** Oracle DECODE treats NULL=NULL as a match (documented exception to SQL three-valued logic) but Trino simple-CASE `WHEN NULL` never matches (standard 3VL — NULL = NULL evaluates to UNKNOWN, not TRUE) — VERIFIED via Oracle docs + trino.io/docs/current/functions/conditional.html.
- Fix: searched CASE `WHEN status IS NULL THEN ...` — CORRECT.
- Audit checklist for `DECODE(col, NULL, ...)` calls during migration — actionable.
- "Use searched CASE when in doubt" — sound default.

Small completeness nick (4.75 not 5.0): a worked side-by-side `DECODE(status, NULL, 'Missing', 'A', 'Active', 'Unknown')` -> `CASE WHEN status IS NULL THEN 'Missing' WHEN status = 'A' THEN 'Active' ELSE 'Unknown' END` would crystallize the rewrite mechanically. The answer states the rule clearly but the example shown is the no-NULL variant.

---

## YoY canonical hold-check — PASSED

The load-bearing iter492 -> iter493 fix:

| Criterion | Required | Actual |
|---|---|---|
| Uses LAG(metric, 12) over gap-filled series OR self-join on month - 12 | YES | YES (self-join form) |
| Does NOT use LAG(metric) default offset 1 labeled as YoY | YES | YES (avoided) |
| Does NOT mislabel MoM as YoY | YES | YES (avoided) |
| Keeps newer customers (no full year of data) in result | YES | YES (LEFT JOIN -> prev=NULL) |
| Internal consistency between column names and downstream metric | YES | YES (no `usage_last_month` fed into yoy_growth_pct) |
| Type-safe TIMESTAMP arithmetic (date_add, not bare integer) | YES | YES (date_add) |
| Divide-by-zero guard | NICE-TO-HAVE | YES (NULLIF) |

**iter493 teacher fix LANDED CLEANLY.** The leading-canonical-example strategy worked: responder hit r07 §B2 FORM A as the first match for the keywords "year over year" / "same month last year" / "YoY" and pattern-matched it verbatim. ZERO recurrence of the iter492 LAG(default-offset)-labeled-as-YoY error.

---

## New fabrications / inaccuracies surfaced

1. **Q2 split_part missing-index return value** — responder said "empty string if index missing"; official Trino docs say **NULL**. Minor (the example case where part_index=1 always exists masks the bug). Teacher action low-priority.

No other new fabrications. No internal contradictions. No prod-environment misfits. No federation-topic claims (federation NOT probed this iter, per directive).

---

## Topic score updates

- **Analytical query patterns on Iceberg+Trino** (Q1 YoY re-probe maps here): 4.4018/19 -> (4.4018*19 + 4.9375)/20 = (83.6342 + 4.9375)/20 = 88.5717/20 = **4.4286/20** (+0.0268 — YoY fix delivered, biggest single-iter topic bump in iter460+).
- **SQL query best practices for OLAP** (Q2 split_part maps here): 4.5236/54 -> (4.5236*54 + 4.4375)/55 = (244.2744 + 4.4375)/55 = 248.7119/55 = **4.5220/55** (-0.0016 — tiny dip from minor null-vs-empty-string accuracy nick).
- **Iceberg table maintenance** (Q3 maps here): 4.4863/146 -> (4.4863*146 + 4.875)/147 = (655.0998 + 4.875)/147 = 659.9748/147 = **4.4896/147** (+0.0033).
- **Oracle PL/SQL->dbt/Trino migration** (Q4 DECODE NULL maps here): 4.4958/63 -> (4.4958*63 + 4.875)/64 = (283.2354 + 4.875)/64 = 288.1104/64 = **4.5017/64** (+0.0059 — crosses 4.5 for first time on this topic).
- **Trino federation** UNTOUCHED per directive: **4.49944/310 row unchanged**.

---

## Pattern across iter488-493

iter488 -> 493: 3.875F / 4.25P / 4.59P / 3.81F / 4.06P / 4.156P / 4.7813P. **iter493 = best overall score since iter400 STRONG PASS (4.59).** YoY canonical fix delivered the highest single-question accuracy of the iter480+ window.

The leading-canonical-example pattern (proven on r13 Spark writeTo in iter420 and on r07 GROUP-BY-expression rule in iter485) has now bulletproofed YoY/MoM/period-over-period on r07 §B2. This is the **third successful instance** of the strategy: install a leading canonical worked example at the keyword anchor and the Haiku responder pattern-matches it verbatim instead of confabulating.

---

## Teacher actions next (iter 494)

### LOW priority

1. **Q2 split_part return-value-on-out-of-range claim**: In r07 / r28 (whichever has the split_part keyword anchor), add a one-liner: "When `index > number_of_fields`, `split_part` returns **NULL** (not empty string)." This was the only new inaccuracy iter493 surfaced and it's load-bearing-low (most users never hit out-of-range with part_index=1 patterns) so it's a non-urgent fix.

2. **Q3 worked-example crystallization**: r24 (Iceberg maintenance) could add a one-row before/after for the user's scenario ("table at 240 daily snapshots; `expire_snapshots(retention_threshold => '7d')` keeps the most recent 7 days, deletes ~233"). Pushes Q3 clarity from 4.5 -> 5.0 if probed again.

3. **Q4 DECODE-with-NULL side-by-side**: r27 §DECODE->CASE could add the exact migration pattern `DECODE(status, NULL, 'Missing', 'A', 'Active', 'Unknown')` -> `CASE WHEN status IS NULL THEN 'Missing' WHEN status = 'A' THEN 'Active' ELSE 'Unknown' END` side-by-side. Pushes Q4 completeness from 4.75 -> 5.0 if probed again.

### HOLD

4. Federation r22 §13.x guardrails — **DO NOT TOUCH** per persistent directive. 4.49944/310 row stays.

5. YoY/MoM Pattern B2 in r07 §5 — **DO NOT DISTURB**. The block landed cleanly; responder pattern-matched it on first re-probe. Leave it as the leading canonical for the keyword set.

## Judge probe targets next (iter 494)

1. **MEDIUM** — YoY 3rd-angle / FORM B re-probe: probe whether the responder can reach for FORM B (LAG(12) over gap-filled spine) when the question requires the YoY column AND a running total in one window pass. Pattern B2 has both forms; we've validated FORM A only this iter.

2. **MEDIUM** — Same-week-last-year edge case (ISO-week-53 caveat): Pattern B2 §weekly grain mentions ISO-week-53 — does the responder surface it when asked?

3. **MEDIUM** — Oracle DECODE 2nd-angle: a DECODE with `NULL` as a **search value** (e.g., `DECODE(status, NULL, 'Missing', 'A', 'Active', 'Unknown')`) to confirm the responder writes the searched-CASE form with `WHEN status IS NULL` and does NOT write `WHEN status = NULL` (which would never match in Trino).

4. **MEDIUM** — split_part out-of-range angle: e.g., parse the 4th field from a 3-field URL; does the responder say NULL (correct) or empty string (the iter493 inaccuracy)?

5. **HOLD** — Federation: continue NOT probing per iter472+ directive.
