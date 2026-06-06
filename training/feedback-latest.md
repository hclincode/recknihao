# Iter 565 Judge Feedback — 2026-06-07 (EXTENDED PHASE) — 4.40625 PASS

## HEADLINE

**OVERALL 4.40625 PASS** (margin +0.90625 above 3.5 floor; -0.5625 swing from iter564's 4.96875 STRONG PASS). **Q1 forward-fill is a hard accuracy failure (2.75/5)**: responder used `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` — that returns the LAST non-null in the ENTIRE partition (past AND future) for EVERY row, NOT the most recent non-null at or before the current row. **Forward-fill requires the look-BACK-only frame `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`** AND **Trino 467 supports `IGNORE NULLS`** on value window functions — the idiomatic forward-fill is `coalesce(metric, last_value(metric) IGNORE NULLS OVER (PARTITION BY id ORDER BY day ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW))`. Responder used a CASE-WHEN-inside-LAST_VALUE workaround AND missed `IGNORE NULLS` entirely. The "cleaner alternative" `PARTITION BY id, CASE WHEN metric IS NOT NULL THEN 1 ELSE 0 END` is also broken — it splits null rows and non-null rows into SEPARATE partitions, which cannot forward-fill. Q2/Q3/Q4 all strong (4.875-5.0). **iter566 PRIMARY FIX**: write a forward-fill / value-gap-fill LEADING canonical in r07 with the correct look-back frame + IGNORE NULLS idiom + the "split-partition is broken" anti-pattern.

## Per-question scores

### Q1 — Forward-fill (carry most recent non-null forward day by day) — Acc 2.0 / Comp 3.0 / Clar 3.0 / Act 3.0 = **2.75 FAIL**

**Verdict: SEMANTIC ERROR — wrong frame + missed IGNORE NULLS + broken "alternative"**

Three problems, each independently wrong:

(a) **Wrong frame for forward-fill.** Responder wrote:
```sql
LAST_VALUE(CASE WHEN metric_value IS NOT NULL THEN metric_value END)
OVER (PARTITION BY customer_id ORDER BY event_date
      ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)
```
With `UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING`, the frame spans the ENTIRE partition for EVERY row. `LAST_VALUE(CASE WHEN x IS NOT NULL THEN x END)` over that frame returns the **globally last non-null in the partition** for every row — including rows BEFORE the first recorded value, which get filled with a FUTURE value. That is **future-fill, not forward-fill**. Forward-fill = "for each row, the most recent non-null value AT OR BEFORE that row" = look-BACK only.

**Correct frame**: `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`. Verified at trino.io/docs/467/sql/select.html VERBATIM: "If the frame is not specified, it defaults to `RANGE UNBOUNDED PRECEDING`, which is the same as `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`" — and a deliberate `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` is the standard look-back frame. Responder's claim that "you MUST use UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING" is FALSE — it's the opposite of what forward-fill needs.

(b) **Missed `IGNORE NULLS`** — the canonical idiom. Verified at trino.io/docs/467/functions/window.html VERBATIM: **"By default, null values are respected. If `IGNORE NULLS` is specified, all rows where `x` is null are excluded from the calculation."** Trino 467 supports `IGNORE NULLS` on value window functions (`first_value`, `last_value`, `nth_value`, `lag`, `lead`). The idiomatic forward-fill is:
```sql
COALESCE(
  metric_value,
  LAST_VALUE(metric_value) IGNORE NULLS OVER (
    PARTITION BY customer_id ORDER BY event_date
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
  )
) AS metric_filled
```
The responder's CASE-WHEN-inside-LAST_VALUE workaround is what you write when your engine LACKS `IGNORE NULLS` — but Trino HAS it. Workaround documented; canonical idiom missed.

(c) **"Cleaner alternative" is broken.** Responder offered: `PARTITION BY customer_id, CASE WHEN metric_value IS NOT NULL THEN 1 ELSE 0 END`. Adding the CASE expression to `PARTITION BY` puts all NULL rows in one partition and all non-null rows in a DIFFERENT partition for the same customer. A value window function CANNOT cross partitions, so this cannot forward-fill — it leaves NULL rows still NULL. The intended Postgres-style gap-fill via running sum of "is-non-null" to label groups requires the running sum to be in a CTE column (then used in `PARTITION BY` in a downstream step), not directly in `PARTITION BY` over the raw boolean. As written, the alternative is broken.

**Resource gap**: `grep -rn "IGNORE NULLS|forward.fill|fill.forward|carry forward" resources/07-analytical-query-patterns.md` returns ZERO hits for IGNORE NULLS and only one tangential carry-forward mention (r07 L1478, a rolling-avg LAG persistence-semantic note — not a forward-fill canonical). r07 §4 covers time-series gap-fill via UNNEST(sequence(...)) DATE spines, but has no canonical for value-gap (last-non-null) forward-fill. NO IGNORE NULLS anywhere in resources/ — searched.

Scores:
- Accuracy 2.0/5 — wrong frame (future-fill, not forward-fill) + broken "alternative" partition trick
- Completeness 3.0/5 — answered the shape (LAST_VALUE + window) but missed IGNORE NULLS canonical and trapped engineer with an incorrect alternative
- Clarity 3.0/5 — explained frames in detail but DEFENDED the wrong frame ("must use UNBOUNDED FOLLOWING") — clear but wrong
- Actionability 3.0/5 — if engineer runs this SQL, they get future-fill (rows before first non-null filled with a FUTURE value); the cleaner alternative produces NULL-still rows

### Q2 — Inspect Iceberg table partitioning + properties from Trino (no dbt files) — 5.0/5.0/5.0/5.0 = **5.00 STRONG PASS**

Responder: `SHOW CREATE TABLE iceberg.analytics.events` shows `partitioning=ARRAY[...]` + `WITH` properties; `"events$properties"` for key/value metadata; `"events$partitions"` for per-partition stats; partitioning displayed with transform-aware field names (e.g. `occurred_at_day`, `tenant_id_bucket`); `DESCRIBE` shows only columns (not partitioning/properties); whole-token `"$..."` quoting required. Cited r17/r10.

Verified at trino.io/docs/467/connector/iceberg.html VERBATIM:
- **"The current values of a table's properties can be shown using SHOW CREATE TABLE"**
- **"The `$properties` table provides access to general information about Iceberg table configuration and any additional metadata key/value pairs that the table is tagged with"**
- **"The `$partitions` table provides a detailed overview of the partitions of the Iceberg table"**

Whole-token `"$..."` quoting + transform field names align with table-write recipes from r10/r17. DESCRIBE-shows-only-columns is correct (DESCRIBE is metadata read but doesn't expose connector-level WITH properties). Clean answer; routes to existing canonical.

### Q3 — dbt run vs dbt build vs dbt test, right order — 5.0/5.0/5.0/5.0 = **5.00 STRONG PASS**

Responder: `dbt run` = builds models only (executes model SQL); `dbt test` = runs generic + singular tests (typically AFTER run, against built tables); `dbt build` = run + test + seed + snapshot in DAG dependency order with test-blocking semantics (failed test on upstream skips downstream); dev typical = `dbt run` then `dbt test`; prod typical = `dbt build` (one command, intelligent blocking); `dbt source freshness` is a separate step (not part of build). Cited r28.

Verified at docs.getdbt.com/reference/commands/build VERBATIM: **"The dbt build command will: run models, test tests, snapshot snapshots, seed seeds... In DAG order, for selected resources or an entire project."** AND **"Tests on upstream resources will block downstream resources from running, and a test failure will cause those downstream resources to skip entirely. E.g. If `model_b` depends on `model_a`, and a `unique` test on `model_a` fails, then `model_b` will `SKIP`."** Source freshness is indeed separate (`dbt source freshness` command). Order and semantics map 1:1. Clean answer.

### Q4 — Rate = events/users — clean guard for division-by-zero — 5.0/5.0/4.5/5.0 = **4.875 STRONG PASS**

Responder: `numerator / NULLIF(denominator, 0)` returns NULL (not error) when denominator = 0 — preferred clean idiom; `try(expr)` for complex/buried divisions (returns NULL on any runtime error); `COALESCE(try(numerator/denominator), 0)` for an explicit default value; CASE-WHEN is verbose and discouraged.

Verified at trino.io/docs/467/functions/conditional.html VERBATIM:
- NULLIF: **"Returns null if `value1` equals `value2`, otherwise returns `value1`"** — so `NULLIF(0, 0)` returns NULL, and `x / NULL` returns NULL (no error, by ANSI semantics Trino follows). `numerator / NULLIF(denom, 0)` cleanly returns NULL on zero — confirmed.
- TRY: handles divide-by-zero (documented category), with the canonical docs example **`SELECT COALESCE(TRY(total_cost / packages), 0) AS per_package FROM shipping`**.

Both idioms correct; NULLIF is the lightweight guard, TRY is for "any-arithmetic-error" robustness. Clarity -0.5 for not contrasting WHEN to pick NULLIF (cheap, scoped to one denominator) vs TRY (catches overflow / cast errors too) — but the mechanism is 100% correct and actionable.

## Overall

**Average = (2.75 + 5.00 + 5.00 + 4.875) / 4 = 17.625 / 4 = 4.40625 PASS**

Margin +0.90625 above 3.5 floor. Swing -0.5625 from iter564's 4.96875.

## TOPIC AVG UPDATES

- **Analytical query patterns on Iceberg+Trino (Q1 forward-fill r07 — no canonical found)** 4.4123/22 → (4.4123·22 + 2.75)/23 = 99.82/23 = **4.3401/23** (-0.0722 — well below topic avg, drags hard).
- **Iceberg table maintenance (Q2 SHOW CREATE TABLE + $properties / $partitions — r17/r10 canonicals route)** 4.4474/171 → (4.4474·171 + 5.00)/172 = 765.50/172 = **4.4506/172** (+0.0032 — well above topic avg).
- **dbt model contracts / dbt build commands** — Q3 maps to dbt-command-semantics; nearest topic is "dbt sources / source freshness" 4.3706/7 (Q3 touched the run/build/test/freshness distinction). (4.3706·7 + 5.00)/8 = 35.59/8 = **4.4490/8** (+0.0784).
- **SQL query best practices for OLAP (Q4 NULLIF / TRY divide-by-zero — r23 canonicals route)** 4.4745/150 → (4.4745·150 + 4.875)/151 = 675.93/151 = **4.4771/151** (+0.0027 — slightly above topic avg).
- Federation NOT probed — **4.49944/310 row UNCHANGED** per iter472-564 directive + iter565 task constraint.

## iter566 fix targets

**Fix 1 — HIGHEST PRIORITY — Forward-fill / value-gap-fill LEADING canonical (r07)**

Add an H2/H3 block in `resources/07-analytical-query-patterns.md` titled e.g. "Forward-fill (carry-forward) the last non-null value — Trino 467 idiom" with:

- Lead sentence (verbatim-ready): "The idiomatic forward-fill in Trino 467 uses `LAST_VALUE(...) IGNORE NULLS` over a look-BACK-only frame `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`."

- Canonical SQL:
  ```sql
  SELECT
    customer_id,
    event_date,
    COALESCE(
      metric_value,
      LAST_VALUE(metric_value) IGNORE NULLS OVER (
        PARTITION BY customer_id
        ORDER BY event_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
      )
    ) AS metric_filled
  FROM weekly_metric
  ```

- Verbatim trino.io/docs/467/functions/window.html quote: "By default, null values are respected. If `IGNORE NULLS` is specified, all rows where `x` is null are excluded from the calculation."

- Frame explanation: `UNBOUNDED PRECEDING AND CURRENT ROW` = look-BACK only = most recent non-null AT OR BEFORE the current row. **`UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` is WRONG for forward-fill** — it produces FUTURE-fill (early rows filled with a future value).

- DO-NOT-WRITE row 1: `LAST_VALUE(x) OVER (... ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)` for forward-fill — produces future-fill, not forward-fill. Fix: change frame to `... AND CURRENT ROW`.

- DO-NOT-WRITE row 2: `PARTITION BY id, CASE WHEN x IS NOT NULL THEN 1 ELSE 0 END` "cleaner alternative" — BROKEN: splits null rows and non-null rows into SEPARATE partitions, value window function cannot cross partitions, NULL rows stay NULL.

- DO-NOT-WRITE row 3: `LAST_VALUE(CASE WHEN x IS NOT NULL THEN x END) OVER (...)` as the canonical idiom — works as workaround, but Trino 467 has native `IGNORE NULLS`; prefer the idiomatic form.

- Cross-engine note: Postgres/SQLite/some-MySQL lack `IGNORE NULLS` and require the running-sum-group-label trick (the correct version, running sum in a CTE column, then PARTITION BY that column in the next CTE) — Trino does NOT need that workaround.

- Keyword anchors (place in header/lead): forward-fill, fill forward, carry forward, carry-forward, last non-null, IGNORE NULLS, gap fill values, fill missing values, weekly metric daily, last_value ignore nulls, sparse data forward fill, persistence forward-fill.

**Fix 2 — MEDIUM — durability re-probes (Q2/Q3/Q4)**

- Q2 2nd-angle: "how do I see if a table is sorted (sort_order) from Trino without dbt files?" → should route to `SHOW CREATE TABLE` `sorted_by` property + `$properties`.
- Q3 2nd-angle: "I have a dbt test failing — does `dbt build --select state:modified+` skip downstream? Or do I need `--fail-fast`?" → tests test-blocking semantics depth.
- Q4 2nd-angle: "rate = sum(x)/sum(y) where sum(y) inside a window function might be 0" → should test that NULLIF still works inside `OVER(...)` aggregations.

**Fix 3 — LOW DO NOT TOUCH**

- federation row stays 4.49944/310; no edits to resources/22 §13.x.
- r17 L143-156 LEADING CANONICAL (TRUNCATE/CREATE OR REPLACE / metadata-only DELETE) — DURABLE, do NOT churn.
- r23 §3 multi-COUNT(DISTINCT) LEADING CANONICAL — DURABLE.
- r07 existing UNNEST(sequence) date-gap-fill content (§4) — DURABLE; the new value-gap-fill canonical should NOT touch the date-gap-fill section.

## Meta-rule observation

WebSearch on `trino.io/docs/467/functions/window.html` was DECISIVE on Q1 — without confirming `IGNORE NULLS` is real in Trino 467 (it is, verbatim), the judge could have let the responder's CASE-WHEN workaround slide as merely verbose instead of catching the missed canonical idiom. Pin-Trino-467 + WebFetch-the-docs caught BOTH the wrong-frame error AND the missed IGNORE NULLS canonical. Additionally, the directive's explicit callout "the forward-fill window-frame question is exactly where careful verification matters" was load-bearing — without that priming, easy to miss the past-vs-future-fill semantic distinction. 27th consecutive iter (iter537-565) where meta-rule discipline materially affected the verdict.

Did NOT bump training/state.json (teacher already set iteration=565). Federation rubric row 4.49944/310 unchanged. Did NOT touch resources/22 §13.x.

## SUMMARY

**OVERALL: 4.40625 PASS** — Q2/Q3/Q4 strong (5.00/5.00/4.875), Q1 forward-fill 2.75 FAIL pulls average down. iter566 PRIMARY FIX = new LEADING canonical in r07 for forward-fill with correct look-back frame + IGNORE NULLS idiom + two anti-patterns (UNBOUNDED FOLLOWING wrong frame + split-partition broken alternative). NO churn on iter564 canonicals (r17, r23 §3) — they remain durable.
