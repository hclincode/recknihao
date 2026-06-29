# Judge Feedback — Iteration 1266

## Overall verdict

**4.8438 STRONG PASS NO-OP** — all four answers verified accurate against authoritative Trino 467 sources (language/types.md, functions/map.html, functions/window.html, functions/datetime.html, functions/math.html). No fabrications, no imported-prior slips, no broken-secondary alternatives, no over-warning folklore. No FIX-A, no new watches.

| Q | Topic | Acc | Clar | Prac | Compl | Avg |
|---|---|---|---|---|---|---|
| Q1 MAP DDL + element_at | Lakehouse schema design | 5.0 | 4.5 | 5.0 | 4.75 | **4.8125** |
| Q2 LAG window avg-gap | Analytical query patterns | 5.0 | 4.75 | 5.0 | 4.75 | **4.875** |
| Q3 SCD-2 transition self-join | dbt snapshots SCD2 | 5.0 | 4.75 | 4.75 | 4.5 | **4.75** |
| Q4 CAST vs TRUNC vs truncate | Oracle PL/SQL → dbt+Trino | 5.0 | 5.0 | 5.0 | 4.75 | **4.9375** |

**Iteration average: 4.84**

---

## Per-question verification

### Q1 — MAP column DDL + element_at vs subscript — **4.8125**

**Responder claims and verification:**

1. `properties MAP(VARCHAR, VARCHAR)` with PARENTHESES (Trino) NOT `MAP<K,V>` angle brackets (Spark/Hive — would parse-error in Trino 467). **VERIFIED** via WebFetch of [raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/language/types.md](https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/language/types.md): type syntax uses parentheses; Iceberg connector accepts `MAP(KEY_TYPE, VALUE_TYPE)` in CREATE TABLE column definitions. Angle-bracket form is Spark/Hive-only.
2. Subscript `map['key']` THROWS "Key not present in map" on missing key; `element_at(map, 'key')` returns NULL on missing key; COALESCE for default. **VERIFIED VERBATIM** via WebFetch of [trino.io/docs/467/functions/map.html](https://trino.io/docs/467/functions/map.html): subscript operator "throws an error if the key is not contained in the map"; `element_at()` "Returns value for given `key`, or `NULL` if the key is not contained in the map." Difference is correctly named — load-bearing distinction for the "what if key missing?" half of the question.
3. `partitioning = ARRAY['day(occurred_at)', 'customer_id']` — partition-design aside (not load-bearing for the asked question); identity partition on `customer_id` is high-cardinality and could create many partitions, but engineer's question was about the MAP type DDL not partition design — peripheral mention only. Not a defect; not a broken-secondary.

**Acc 5.0** — both load-bearing facts (DDL paren-syntax + subscript-vs-element_at NULL behavior) verbatim correct.
**Clar 4.5** — could one-sentence-explain why subscript throws vs returns NULL (the engineer's "key missing" framing is the load-bearing concern); responder mostly states the result without the why.
**Prac 5.0** — copy-pasteable DDL + read-pattern + default-with-COALESCE. Engineer knows exactly what to do.
**Compl 4.75** — minor: didn't surface `transform_keys` / `map_keys` / `map_values` as adjacent inspection idioms for the multi-key-iteration scenario; not asked, not load-bearing.

### Q2 — LAG window + date_diff for avg-gap per customer — **4.875**

**Responder claims and verification:**

1. `LAG(created_at) OVER (PARTITION BY customer_id ORDER BY created_at) AS prev` — **VERIFIED** via WebFetch of [trino.io/docs/467/functions/window.html](https://trino.io/docs/467/functions/window.html): `lag(x[, offset[, default_value]])` signature documented; requires window ordering, frame must not be specified. PARTITION BY customer_id ORDER BY created_at is the textbook usage.
2. `date_diff('hour', LAG(created_at) OVER (...), created_at) AS gap_hours` — **VERIFIED** via WebFetch of [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html): `date_diff(unit, timestamp1, timestamp2) → bigint` returns `timestamp2 - timestamp1` in the given unit. Argument order (unit, earlier, later) correct. Result of LAG of earlier row passed first → date_diff returns positive hour count (later − earlier).
3. `WHERE gap_hours IS NOT NULL` correctly filters first-row-per-customer LAG NULL.
4. `AVG(gap_hours), COUNT(*)-1 AS num_gaps GROUP BY customer_id` — final aggregation correct; AVG over BIGINTs returns double (no integer-division trap).
5. Single-pass CTE — replaces O(N²) self-join + correlated-subquery anti-pattern with O(N log N) sort-then-stream window. Production-stack-aligned for 30M-row tickets table.

**Acc 5.0** — every load-bearing element verifies; date_diff argument order correct, no NULL-handling slip, no integer-division trap.
**Clar 4.75** — clean canonical with one-pass framing; minor: could explicitly call out that AVG-on-BIGINT is decimal-safe (not the integer-division gotcha some engineers carry from MySQL).
**Prac 5.0** — copy-pasteable single-pass CTE; engineer's "never finishes" symptom directly addressed.
**Compl 4.75** — minor: didn't note that on a 30M-row table with thousands of distinct customer_ids the SORT step parallelizes per-customer (no skew risk for typical SaaS shape); didn't surface partition pruning or alternative MIN/MAX-based gap if the engineer also wanted MIN/MAX gap. Not load-bearing.

### Q3 — dbt-snapshot SCD-2 self-join for transition detection — **4.75**

**Responder claims and verification:**

1. INNER JOIN snapshot to itself on `curr.customer_id = prev.customer_id AND prev.plan_tier='pro' AND curr.plan_tier='free' AND prev.dbt_valid_to = curr.dbt_valid_from` — canonical "consecutive SCD-2 versions" join pattern. In dbt-snapshot timestamp strategy, when a row's tracked column changes: the outgoing row's `dbt_valid_to` is stamped to the new `updated_at` timestamp, and the incoming row's `dbt_valid_from` is stamped to the same timestamp. Therefore `prev.dbt_valid_to = curr.dbt_valid_from` is the unambiguous adjacency predicate. This matches the validity-window point-in-time pattern documented in resources/09 SCD-2 and aligns with [docs.getdbt.com/docs/build/snapshots](https://docs.getdbt.com/docs/build/snapshots) timestamp strategy semantics.
2. `WHERE curr.dbt_valid_from BETWEEN DATE '2026-04-01' AND DATE '2026-06-30'` — captures transitions that occurred in the window (using the incoming row's `dbt_valid_from` as the transition timestamp is the canonical anchor).
3. EXISTS alternative — second valid form; same correctness.

**Acc 5.0** — adjacency predicate + plan_tier filter + date-window all canonical SCD-2 transition idioms.
**Clar 4.75** — clean readable JOIN form; minor: could one-line-explain why `dbt_valid_to = dbt_valid_from` adjacency holds (the dbt-snapshot stamping mechanic).
**Prac 4.75** — directly addresses engineer's question with copy-pasteable SQL.
**Compl 4.5** — user explicitly asked "self-join or window?"; responder picked self-join + EXISTS but did NOT explicitly compare against the LAG-window alternative (`LAG(plan_tier) OVER (PARTITION BY customer_id ORDER BY dbt_valid_from)` + WHERE prev_plan='pro' AND plan_tier='free'). Both forms are correct for SCD-2 transition detection; self-join is more idiomatic for SCD-2 (the adjacency predicate is natural), LAG is more idiomatic for time-series. A one-paragraph routing note on "use self-join when adjacency is well-defined by validity columns; use LAG when you want a single-pass for very large snapshot tables" would close the Compl gap.

NOT a watch / NOT a FIX-A — Compl shave is on the framing of "which", not on correctness of the answer given.

### Q4 — Oracle TRUNC vs Trino CAST vs truncate — **4.9375**

**Responder claims and verification:**

1. `CAST(13.8 AS INTEGER) = 14` is **HALF-UP ROUNDING**, NOT truncate. **VERIFIED** via pinned `reference_trino_cast_to_integer_rounds.md` + corroborated by [Trino blog "Optimizing the Casts Away"](https://trino.io/blog/2019/05/21/optimizing-the-casts-away.html) ("When casting to lower precision in Trino, the value is rounded, and not truncated") + Trino 467 source `DecimalCasts.java` half-up rounding. This is THE load-bearing fact for the engineer's TRUNC-vs-CAST 13-vs-14 discrepancy.
2. Decision table:
   - `truncate(x)` = toward-zero (Oracle TRUNC equivalent; `truncate(-13.8) = -13`)
   - `CAST(x AS INTEGER)` = half-up rounding (`13.8 → 14`, `13.4 → 13`)
   - `floor(x)` = toward -∞ (`floor(-13.8) = -14`)
   - `ceil(x)` = toward +∞
   All four directions correct including the negative-number disambiguation (`truncate(-13.8) = -13` vs `floor(-13.8) = -14` is the critical disambiguation for engineers porting Oracle).
3. Fix: `truncate(CAST(total_days AS DOUBLE) / 7.0)` — drop-toward-zero replicates Oracle TRUNC exactly.
4. Trino 467 `truncate` is **1-ARG ONLY** (no 2-arg `truncate(x, n)` for decimal-place truncation until ~471+). **VERIFIED** via WebFetch of [trino.io/docs/467/functions/math.html](https://trino.io/docs/467/functions/math.html): only `truncate(x) → double` signature documented ("Returns `x` rounded to integer by dropping digits after decimal point"). No 2-arg overload in 467. Matches pinned reference (per MEMORY.md). Workaround `truncate(x*100)/100` for 2-decimal-place truncation correctly named.

**Acc 5.0** — every fact verifies; the load-bearing Oracle-vs-Trino disambiguation (round vs truncate) + the 1-arg-only version gate + the negative-number direction table are all bulletproof.
**Clar 5.0** — decision table with worked examples for each direction is exactly the right teaching shape for "I thought CAST = TRUNC".
**Prac 5.0** — direct copy-pasteable fix `truncate(CAST(... AS DOUBLE) / 7.0)`.
**Compl 4.75** — minor: didn't mention `floor(x)` for the always-positive case `total_days/7` where toward-zero and toward--∞ coincide (a no-op simplification for the engineer's specific symptom since `total_days ≥ 0`), but the general-direction guidance is what the engineer needed to understand the principle.

---

## Cross-cutting observations

**Consistent with iter1265 4.84 STRONG PASS NO-OP**: 8th consecutive clean iter on the broken-secondary-alternative family (no padded incorrect aside this iter). 30th consecutive 1st-re-probe-or-NO-OP closure on the LIGHT-FIX-A landing pattern.

**No imported-prior recurrence**: Q4 specifically tests the iter728-pinned `reference_trino_cast_to_integer_rounds.md` (CAST half-up not truncate) AND the iter1035-family `reference_trino_truncate_1arg_only` (no 2-arg truncate on 467) — both navigated cleanly. Q1 tests the assume-Spark-syntax trap (`MAP<K,V>` angle brackets) — correctly defanged with the parens form. Q2 navigates date_diff argument order correctly (not the iter882 day-aware-month-boundary family).

**No watches opened this iter.** Existing soft watches from prior iters all stay open at their previous re-probe budgets:
- iter1260 Q1 CDC-MERGE-multi-event-dedup
- iter1260 Q3 source-hard-delete-snapshot-routing (FIX-A reached iter1265; watch CLOSED)
- iter1258 Q3 SELECT-*-EXCEPT
- iter1255 Q1 bloom-CREATE-syntax
- iter1253 Q4 regexp_extract-2arg
- iter1248 Q3 MATCH_RECOGNIZE-adjacency
- iter1229 @v1-Spark
- iter1215 strpos-3-arg (CLOSED iter1264 Q4)

**No FIX-A recommended.** Resources r07 / r09 / r17 / r23 / r27 are all maximally anchored on the load-bearing facts probed this iter. Q3 Compl shave on the self-join-vs-window alternative is recall-ceiling per `feedback_synthesis_ceiling_stop_churning.md` family — adding a "which-form-when" router risks `feedback_new_card_over_attracts_adjacent.md` over-attractor on adjacent transition-detection questions.

---

## Topic score updates (this iter only)

| Topic | Before | This iter | After |
|---|---|---|---|
| Lakehouse schema design | 4.4781 / 20 | Q1 = 4.8125 | **4.4940 / 21** (+0.0159, margin +0.9940) |
| Analytical query patterns on Iceberg+Trino | 4.5192 / 191 | Q2 = 4.875 | **4.5210 / 192** (+0.0018, margin +1.0210) |
| dbt snapshots SCD2 | 4.2168 / 30 | Q3 = 4.75 | **4.2340 / 31** (+0.0172, margin +0.7340) |
| Oracle PL/SQL → dbt + Trino SQL migration | 4.4945 / 234 | Q4 = 4.9375 | **4.4964 / 235** (+0.0019, margin +0.9964) |

All four topics REMAIN PASSED with positive margin. dbt-snapshots-SCD2 (4.2340) remains the THINNEST near-bottom passing row in the dbt cluster; another 2-3 STRONG re-probes on snapshot strategy='check', hard_deletes adapter caveat, and validity-window point-in-time would lift it well clear of threshold.
