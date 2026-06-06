# Iter 524 Judge Feedback — 2026-06-06 (EXTENDED PHASE)

## Overall: 3.469 FAIL (margin -0.031 below 3.5 floor)

Two fabricated-absences in one iter (Q1 `UNNEST WITH ORDINALITY` + Q4 `approx_distinct(x, e)` second-arg precision control) on questions whose literal phrasing pointed straight at the missing canonical. Combined with Q2's NEXT_DAY honest-punt under-answer, the iter could not absorb the three drags despite Q3 dbt-seeds' strong 4.75. First FAIL of the extended-phase streak since iter519.

## Per-question scores

### Q1 — UNNEST with original array index — 2.50 FAIL (FABRICATED ABSENCE, load-bearing)
- Accuracy 1.5 / Clarity 3.0 / Applicability 2.5 / Completeness 3.0
- Responder hedged that `WITH ORDINALITY` is "a PostgreSQL feature" and "I don't have enough information to tell you if Trino supports it." Then offered `ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY t.tag)` workaround that the responder itself acknowledges generates NEW positions sorted by tag, NOT the original array index.
- **FABRICATED ABSENCE — load-bearing.** Trino DOES support `UNNEST(...) WITH ORDINALITY` and it directly answers the user's exact question.
- Verified at trino.io/docs/current/sql/select.html verbatim:
  > "UNNEST can optionally have a WITH ORDINALITY clause, in which case an additional ordinality column is added to the end of the result."
- Doc canonical worked example: `SELECT a, b, rownumber FROM UNNEST (ARRAY[2, 5], ARRAY[7, 8, 9]) WITH ORDINALITY AS t(a, b, rownumber);`
- **Correct answer for the user's exact question**: `SELECT user_id, tag, idx FROM users CROSS JOIN UNNEST(tags) WITH ORDINALITY AS t(tag, idx)` — `idx` is the 1-based original array position. So `'billing' at idx=2` is what the user asked for.
- Same fabricated-absence failure class as iter505 split_to_map, iter517 contains/spark.sql.iceberg.write.*, iter520 CAST(map AS JSON), iter520 string_agg, iter522 try().
- Salvage: ROW_NUMBER scaffolding is mechanically valid pattern (Clarity/Completeness not 1.0), but answers the wrong question (sort rank, not original index) — and the responder admits this.

### Q2 — Oracle NEXT_DAY / LAST_DAY → Trino — 3.50 PASS (CONTENT GAP, HONEST PUNT, NO FAB)
- Accuracy 4.0 / Clarity 3.5 / Applicability 3.0 / Completeness 3.5
- LAST_DAY landed cleanly: `last_day_of_month(dt)` correct Trino built-in. Verified at trino.io/docs/current/functions/datetime.html:
  > "last_day_of_month(date) returns date; last_day_of_month(timestamp(p)) returns date."
- NEXT_DAY honestly punted ("I don't have enough information to give you the exact canonical SQL... check the Trino docs"). Honest failure mode (NO fabrication), but the user is left without a working formula.
- Trino has NO built-in `next_day` function (genuine gap, NOT a fab-absence) — manual `day_of_week()` + `date_add()` recipe IS required. Responder mentioned the building blocks but stopped short of giving the worked formula.
- `day_of_week()` verified at trino.io/docs/current/functions/datetime.html: returns ISO 1=Monday..7=Sunday.
- **Correct pattern** (Monday after `dt`, strictly AFTER per Oracle's NEXT_DAY semantics):
  ```sql
  -- target_dow = 1 for Monday (ISO 1=Mon..7=Sun)
  date_add('day', ((target_dow - day_of_week(dt) - 1 + 7) % 7) + 1, dt)
  -- For Monday:
  date_add('day', ((1 - day_of_week(dt) - 1 + 7) % 7) + 1, dt)
  ```
  Off-by-one: Oracle NEXT_DAY returns the NEXT occurrence STRICTLY AFTER `dt` (if `dt` is itself a Monday, returns the NEXT Monday). The `+1` enforces this.
- Partial credit: LAST_DAY fully correct, NEXT_DAY punt is honest.

### Q3 — dbt seeds CSV reference table — 4.75 STRONG PASS
- Accuracy 5.0 / Clarity 5.0 / Applicability 4.5 / Completeness 4.5
- All claims verified at docs.getdbt.com/docs/build/seeds and docs.getdbt.com/reference/resource-configs/column_types:
  - CSV in `seeds/` directory (default; configurable via `seed-paths` in dbt_project.yml — old `data/` deprecated since dbt 1.0). CORRECT.
  - `+column_types: {col: type}` under `seeds:` in dbt_project.yml. CORRECT.
  - `dbt build` runs seeds (also `dbt seed` standalone); `dbt run` does NOT load seeds. CORRECT.
  - `ref('product_codes')` for downstream model reference. CORRECT.
  - Truncate-reload each run; small/infrequent data only. CORRECT.
- -0.5 Applicability / -0.5 Completeness for no mention of `quote_columns` config (CSV columns with reserved-word names need quoting in some adapters) — non-load-bearing.

### Q4 — approx_distinct precision control — 3.125 FAIL/MARGINAL (FABRICATED ABSENCE, load-bearing)
- Accuracy 2.5 / Clarity 4.0 / Applicability 2.5 / Completeness 3.5
- `approx_distinct(user_id)` HLL + 2.3% default + ~100x less memory + approx_set/cardinality/merge sketch pre-aggregation pattern: ALL CORRECT.
- **FABRICATED ABSENCE — load-bearing.** Responder claims "You cannot control the error bound directly — Trino's approx_distinct is a fixed HyperLogLog implementation with ~2.3% error" and offers a "sample 5-10 partitions and measure error yourself" workaround.
- This is WRONG and is the **exact question the user asked** ("can I control how precise the estimate is?"). The answer is YES, via the optional second argument.
- Verified at trino.io/docs/current/functions/aggregate.html verbatim:
  > "approx_distinct(x, e) — This function should produce a standard error of no more than e, which is the standard deviation of the error distribution over all possible sets. ... The current implementation of this function requires that e be in the range of [0.0040625, 0.26000]."
- **Correct answer**: `approx_distinct(user_id, 0.01)` targets ~1% standard error (tighter than 0.023 default); `approx_distinct(user_id, 0.005)` targets ~0.5% near the lower bound. Range: `[0.0040625, 0.26000]`. Lower `e` = tighter estimate + more memory.
- Same fabricated-absence failure class as iter505/iter517/iter520/iter522 (and Q1 this iter — TWO fabs in one iteration).
- Salvage: HLL/2.3%-default/sketch parts correct, so Accuracy 2.5 not 1.0; Clarity 4.0 because writing is clear; but the headline answer to the user's literal question is denied.

## Overall avg
(2.50 + 3.50 + 4.75 + 3.125) / 4 = 13.875 / 4 = **3.46875** → **3.469 FAIL** (margin -0.031 below 3.5 floor)

## Iter524 status: FAIL (margin -0.031)
First FAIL in the extended-phase streak since iter519. Two fabricated-absences in one iter (Q1 + Q4) is a regression and demands two NEW LEADING CANONICALS in iter525.

## Topic average updates

- **SQL query best practices for OLAP** (Q1 UNNEST WITH ORDINALITY array-position + Q4 approx_distinct precision both map here per analytical-patterns + aggregate-functions cluster precedent; Q2 datetime translation maps here per datetime-functions cluster precedent):
  4.5202/79 → (4.5202·79 + 2.50 + 3.50 + 3.125)/82 = (357.0958 + 9.125)/82 = 366.2208/82 = **4.4661/82** (-0.0541 — Q1+Q2+Q4 all below topic avg drag net negative)
- **Oracle PL/SQL → dbt + Trino SQL migration** (Q2 NEXT_DAY/LAST_DAY Oracle-datetime port maps here per migration-cluster precedent; Q3 dbt seeds maps here per dbt-CLI cluster precedent):
  4.6750/16 → (4.6750·16 + 3.50 + 4.75)/18 = (74.80 + 8.25)/18 = 83.05/18 = **4.6139/18** (-0.0611 — Q2 well below topic-avg drags, Q3 just below topic-avg also drags)

Federation NOT probed — **4.49944/310 row UNCHANGED** per iter472-524 directive + iter524 task constraint.

## Iter525 PRIMARY FIX TARGETS (TWO LEADING CANONICALS)

### FIX A — `UNNEST(...) WITH ORDINALITY` NEW LEADING CANONICAL (r07 §1a UNNEST canonical block)
- ONE-LINE RULE: "Trino supports `UNNEST(array) WITH ORDINALITY AS t(elem, idx)` to expose the 1-based original array position. Do NOT use `ROW_NUMBER() OVER (ORDER BY elem)` — that generates a sort-order rank, NOT the original array index."
- Signature: `UNNEST(array_expr) WITH ORDINALITY AS alias(elem_col, ordinality_col)` — ordinality column is appended to the LAST column position; 1-based.
- Multi-array form: `UNNEST(arr1, arr2) WITH ORDINALITY AS t(a, b, idx)` — when arrays have different lengths, shorter arrays NULL-pad.
- Worked example 1 (the user's exact case): `SELECT user_id, tag, idx FROM users CROSS JOIN UNNEST(tags) WITH ORDINALITY AS t(tag, idx)` returns `(user_42, 'billing', 2)` when `'billing'` is at position 2 in the `tags` array.
- Worked example 2 (multi-array): `SELECT a, b, rownumber FROM UNNEST(ARRAY[2,5], ARRAY[7,8,9]) WITH ORDINALITY AS t(a, b, rownumber);`
- DO-NOT-WRITE bans (negative anchors): "WITH ORDINALITY is a PostgreSQL feature, not in Trino" (FALSE — Trino supports it); "use ROW_NUMBER() OVER (ORDER BY elem) for array position" (WRONG — produces sort rank not original index); "you need a generate_series + JSON workaround" (UNNECESSARY); "Trino UNNEST cannot expose array index" (FALSE).
- Verified-source: trino.io/docs/current/sql/select.html (SELECT § UNNEST).
- Keyword anchors: "Trino unnest array index / unnest with ordinality / array position Trino / preserve element order Trino / UNNEST ordinality / Trino array index original / WITH ORDINALITY Trino / array_position vs UNNEST / Trino element position / explode array keep index Trino."

### FIX B — `approx_distinct(x, e)` second-argument precision control LEADING CANONICAL (r07 aggregate-functions block or wherever approx_distinct currently lives)
- ONE-LINE RULE: "Trino's `approx_distinct(x, e)` accepts an OPTIONAL second argument `e` — the maximum standard error. Default `e = 0.023` (2.3%). Range: `[0.0040625, 0.26000]`. Lower `e` = tighter estimate + more memory."
- Signature: `approx_distinct(x)` (default 2.3% error) | `approx_distinct(x, e)` where `e ∈ [0.0040625, 0.26000]`.
- Trade-off block: lower `e` → larger HLL sketch → more memory + more CPU, but tighter accuracy bound. The 2.3% default uses HLL `b=11` (2048 registers); tighter `e` uses larger sketch.
- Worked examples:
  - `approx_distinct(user_id, 0.01)` — target ~1% standard error
  - `approx_distinct(user_id, 0.005)` — target ~0.5%, near lower bound
  - `approx_distinct(user_id, 0.05)` — target ~5%, looser but cheaper
- Out-of-range hard error: `approx_distinct(user_id, 0.001)` will FAIL — `e` below 0.0040625 rejected.
- Sketch composition: `approx_set(x, e)` accepts the SAME `e` parameter; daily-rollup sketches that will be merged via `merge(...)` then `cardinality(...)` MUST use the SAME `e` to be mergeable.
- DO-NOT-WRITE bans (negative anchors): "approx_distinct error is fixed at 2.3%" (FALSE — 2.3% is the DEFAULT, not the only option); "Trino approx_distinct is a fixed HyperLogLog with no precision control" (FALSE); "to control precision you must sample partitions and measure error yourself" (FALSE — wasteful when the 2nd arg exists); "approx_distinct(x, e) where e is the bucket count" (WRONG semantics — `e` is standard error fraction).
- Verified-source: trino.io/docs/current/functions/aggregate.html.
- Keyword anchors: "approx_distinct precision Trino / approx_distinct second argument / HyperLogLog standard error Trino / approx_distinct accuracy control / approx_distinct error bound / approx_set precision parameter / Trino HLL precision / Trino approximate distinct configurable error / approx_distinct e parameter range / tighter than 2.3 Trino HLL."

### FIX C — Oracle NEXT_DAY → Trino recipe (r27 §4.x datetime cluster, MEDIUM priority)
- Natural neighbor to ADD_MONTHS / LAST_DAY ports in r27 datetime cluster.
- ONE-LINE RULE: "Trino has NO built-in `next_day(date, day_name)` — port Oracle NEXT_DAY via `date_add('day', N, dt)` where N is computed from `day_of_week(dt)`. Use ISO convention 1=Mon..7=Sun."
- Worked formula (Oracle semantics — strictly AFTER):
  ```sql
  -- target_dow: 1=Mon, 2=Tue, ..., 7=Sun (ISO)
  date_add('day',
           ((target_dow - day_of_week(dt) - 1 + 7) % 7) + 1,
           dt)
  -- For Monday after dt:
  date_add('day', ((1 - day_of_week(dt) - 1 + 7) % 7) + 1, dt)
  ```
- Off-by-one callout: Oracle NEXT_DAY returns the NEXT occurrence STRICTLY AFTER `dt` (if `dt` is itself a Monday, returns the FOLLOWING Monday). The `+1` enforces this.
- `day_of_week()` ISO convention: 1=Monday..7=Sunday. Document explicitly (Postgres EXTRACT(DOW) uses 0=Sunday..6=Saturday — common porting trap).
- Pair with LAST_DAY canonical: `last_day_of_month(dt)` (verified Trino built-in, returns DATE).
- Verified-source: trino.io/docs/current/functions/datetime.html.
- Keyword anchors: "Oracle NEXT_DAY Trino / next Monday Trino / day of week Trino / Oracle to Trino datetime port / next occurrence weekday Trino / date_add weekday calc."

## Iter525 probe targets

- **HIGH — Q1 UNNEST WITH ORDINALITY RE-PROBE**: "I have an `events` table with an array column `actions`; I want one row per action AND know which position in the array it came from. How do I do that in Trino?" Verifies FIX A `WITH ORDINALITY` canonical lands and fabricated-absence does NOT reappear.
- **HIGH — Q4 approx_distinct precision RE-PROBE**: "I'm using `approx_distinct(user_id)` and the 2.3% error is too loose — I need around 1%. Can I tighten it without going to exact COUNT DISTINCT?" Verifies FIX B `approx_distinct(x, e)` 2nd-arg canonical lands and the "cannot control precision" fab GONE.
- **HIGH — UNNEST ORDINALITY 2nd angle**: "I want to keep the array index when I flatten a JSON array — does Trino UNNEST preserve element position?" Verifies FIX A keyword anchors catch the JSON/array variant.
- **MEDIUM — approx_distinct 2nd angle**: "What's the lowest possible standard error in Trino's approx_distinct?" Verifies FIX B range `[0.0040625, 0.26000]` lands.
- **MEDIUM — approx_set / merge with custom e**: "I'm pre-aggregating daily HLL sketches with `approx_set(user_id, 0.01)`; can I `merge()` sketches across days?" Verifies FIX B mergeability-requires-same-e nuance.
- **MEDIUM — Oracle NEXT_DAY RE-PROBE**: "How do I port Oracle `NEXT_DAY(order_date, 'FRIDAY')` to Trino?" Verifies FIX C worked formula + off-by-one + ISO day_of_week convention.
- **LOW — dbt seeds 2nd angle**: "Can I make a seed with a typed `decimal(18,4)` column?" Verifies `+column_types` canonical extends to numeric precision.
- **LOW — federation stays UNPROBED** — row stays 4.49944/310.

## Notes for teacher

- Two fabricated-absences in one iter is a regression worth flagging. The pattern is consistent (recurring class — split_to_map, contains, CAST(map AS JSON), string_agg, try(), now WITH ORDINALITY + approx_distinct second arg). Both involve a real Trino feature/function that exists but the responder denies. The fix recipe (NEW LEADING CANONICAL with explicit "DO-NOT-WRITE" negative-anchor block including the specific false claim — e.g. "WITH ORDINALITY is a PostgreSQL feature, not in Trino" and "approx_distinct error is fixed at 2.3%") has worked 34 consecutive times for prior fabs; should work again here.
- Q3 dbt seeds and Q2 LAST_DAY were both clean — no regressions in established canonicals.
- Resources/22 §13.x federation guardrails UNTOUCHED — federation NOT probed; row stays 4.49944/310.
- META-RULE applied: WebSearch-verified both Q1 and Q4 fab-absence claims against official trino.io docs BEFORE flagging (quoted verbatim above). Verified Q2 LAST_DAY/day_of_week semantics. Verified Q3 dbt seeds across docs.getdbt.com.
