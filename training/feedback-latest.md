# iter957 Feedback — DEFAULT NO-OP breadth sweep (teacher ZERO edits)

**Overall: 4.71875 STRONG PASS** (per-Q 5.00 / 4.875 / 4.625 / 5.00 = 18.875/4); margin +1.21875 above 3.5. OVERALL AVERAGE governs.

PIN Trino 467. Verified vs trino.io/docs/467 (functions/datetime.html, functions/aggregate.html, sql/select.html, functions/comparison.html) + git-tag 467 + WebSearch 2026-06-10 — NOT against resources/. Verify-BOTH-directions discipline.

FEDERATION NOT PROBED — 4.49944/310 row UNCHANGED per directive (r22 §13.x hard-locked).

---

## Per-question scores

### Q1: Count single-page-view sessions (sessions.page_count) — 5.00 CLEAN
- Acc 5 / Comp 5 / Clar 5 / Act 5
- Answer: `SELECT COUNT(*) AS single_page_sessions FROM sessions WHERE page_count = 1`. Plus per-user breakdown via GROUP BY. WHERE-before-aggregation note.
- **Verify**: COUNT(*) filtered by WHERE is canonical, valid 467 per sql/select.html. Filter-then-count distinction is THE correct pedagogy (and the right answer here — we WANT to filter, not aggregate-then-HAVING). No confusion with the gaps-and-islands filter-then-count always-zero bug (that bug is filter-to-target-event-then-count-OTHER-type over a window; this is filter-to-condition-then-count-rows, a totally different shape). Per-user breakdown adds practical value without bloat.
- No defect.

### Q2: Average days in inventory received_at to sold_at, handle unsold (sold_at NULL) — 4.875 CLEAN
- Acc 5 / Comp 5 / Clar 5 / Act 4.5
- Answer: `SELECT AVG(date_diff('day', received_at, sold_at)) AS avg_days_in_inventory FROM inventory WHERE sold_at IS NOT NULL`. Notes (a) `date_diff('day', earlier, later)` returns whole days (day-aware per `reference_trino_datediff_dayaware.md` and trino.io/docs/467/functions/datetime.html); (b) AVG ignores NULL inputs naturally, but the explicit `WHERE sold_at IS NOT NULL` clarifies intent; (c) suggests counting unsold separately.
- **Verify**: `date_diff(unit, ts1, ts2)` argument order = unit-first then earlier-then-later, returns positive integer days when ts2 > ts1 per functions/datetime.html; AVG skips NULL per functions/aggregate.html. Excluding unsold rows is correct (cannot compute days-in-inventory without a sold-at). Scoping to SOLD items is the right framing.
- Optional nuance NOT a defect: a still-in-stock "age so far" via `date_diff('day', received_at, current_date)` is a DIFFERENT metric (current age, not days-in-inventory-until-sold) — the responder correctly chose to NOT conflate.
- Minor knock on Act (-0.5): could have explicitly mentioned the alternative metric as a sister query for inventory-aging reports; trivial.

### Q3: Count orders where billing_zip != shipping_zip + NULL handling — 4.625 MINOR COMPLETENESS NUANCE
- Acc 5 / Comp 4.0 / Clar 4.5 / Act 5
- Answer: `SELECT COUNT(*) FROM orders WHERE billing_zip != shipping_zip`. Notes: if EITHER operand is NULL, `!=` evaluates UNKNOWN, row dropped (standard 3VL). Gives an OR-form `billing != shipping OR billing IS NULL OR shipping IS NULL` for "differ OR missing" intent. Says simple `!=` is usually what's wanted.
- **Verify**: `!=` with any NULL operand returns NULL/UNKNOWN per Trino comparison.html; WHERE drops rows where the predicate is not TRUE, so NULL/UNKNOWN excluded. Correct 3VL claim. The OR-form (`!= OR billing IS NULL OR shipping IS NULL`) does correctly count "either differ OR at least one missing" — a defensible alternate intent, correctly scoped.
- **Completeness nuance (NOT a defect)**: Trino 467 provides `IS DISTINCT FROM` as the canonical NULL-safe inequality (TRUE when values differ INCLUDING NULL-vs-nonNULL, FALSE when both equal or both NULL) per trino.io/docs/467/functions/comparison.html (WebSearch 2026-06-10 confirmed: "treat NULL as a known value... guarantee either a true or false outcome even in the presence of NULL input"). The responder did NOT mention `IS DISTINCT FROM`, which is THE cleanest idiom for "strictly differ, NULL-vs-nonNULL counts as different but NULL-vs-NULL counts as same". Per directive: this is a MINOR completeness nuance, NOT a defect — the `!=` + 3VL caveat + defensible OR-variant covers the typical intent correctly. Knock Comp -1.0, Clar -0.5.
- No defect; just a small completeness gap on the most-elegant 467-native idiom.

### Q4: Average tags per article (AVG(COUNT(...)) nested-aggregate error) — 5.00 CLEAN
- Acc 5 / Comp 5 / Clar 5 / Act 5
- Answer:
  ```sql
  WITH article_tag_counts AS (
    SELECT article_id, COUNT(*) AS tag_count
    FROM article_tags GROUP BY article_id
  )
  SELECT AVG(tag_count) AS avg_tags_per_article FROM article_tag_counts
  ```
  Explicit: cannot nest `AVG(COUNT(...))`; two-level CTE (or subquery) required. Generalizes to "average of a count / sum of a sum."
- **Verify**: Nested aggregates are an analyzer-time error in Trino 467 per sql/select.html and r07 anti-nesting card (L1624 busiest-weekday pin); materialize-in-CTE is the canonical fix; subquery equivalent valid. NO broken single-level "shortcut" offered (contrast iter950 Q3 MAX_BY-nested footgun / iter936/943/948/950/953 broken-secondary-alternative meta-pattern). Generalization to "average-of-a-group-count / sum-of-a-group-sum" is the right teaching move.
- Clean.

---

## Defect scoping

- **Q1**: NO defect.
- **Q2**: NO defect; trivial optional nuance (sister "still-in-stock age" query) not required.
- **Q3**: MINOR COMPLETENESS NUANCE only — missing `IS DISTINCT FROM` mention. NOT a RESOURCE DEFECT (the `!=` + 3VL answer is correct for "both present and differ"). NOT a RESPONDER SLIP (no false claim). Borderline FINDABLE GAP — the IS-DISTINCT-FROM idiom should be findable for NULL-safe-inequality questions, but the `!=` answer here was correct and the responder explicitly handled NULL behavior; this is the cleanest-idiom-omission family, not a wrong-answer family.
- **Q4**: NO defect.

---

## iter958 recommendation: DEFAULT NO-OP + optional LIGHT FIX-A (additive IS DISTINCT FROM card)

**Primary recommendation: DEFAULT NO-OP**. Reasoning:
1. iter957 was a NO-OP DEFAULT breadth sweep (teacher ZERO edits per iter956 RECOMMENDATION's "RETURN TO BREADTH") and overall 4.71875 STRONG PASS confirms the pivot away from gaps-and-islands re-probes was correct.
2. Q1/Q2/Q4 all 5.00 clean across distinct families (filter-count / temporal-diff + NULL-skip / nested-aggregate anti-pattern + two-level CTE). All four ALL-PIN dialect facts (WHERE-before-aggregation, date_diff day-aware unit-first earlier-later, AVG ignores NULL, nested aggregation illegal materialize-in-CTE) confirmed against trino.io/docs/467 and git-tag 467.
3. Q3 minor completeness nuance on `IS DISTINCT FROM` is the only soft spot, and the `!=` + 3VL answer is correct.
4. Margin +1.21875 — no urgency. Per `feedback_new_card_over_attracts_adjacent.md`, additive churn on a STRONG PASS risks pulling adjacent NULL-handling questions to the wrong canonical (e.g., a "find orders with billing_zip = shipping_zip including both-NULL" question might get mis-routed to `IS NOT DISTINCT FROM` when straight `=` was intended). Re-probe-don't-churn doctrine applies.

**Optional LIGHT FIX-A (only if 2nd recurrence of NULL-safe-inequality omission on a different surface in next 2 sweeps)**: add a brief one-card mention of `IS DISTINCT FROM` / `IS NOT DISTINCT FROM` in r23 near §3262-3306 regexp_like neighborhood or near the existing NULLS-LAST canonical L3260 — explicitly: "NULL-safe inequality: `a IS DISTINCT FROM b` returns TRUE when values differ OR exactly one is NULL, FALSE when both equal or both NULL. Use when `!=` would drop NULL-vs-nonNULL rows you want to count as different." With explicit WHICH-X router distinguishing it from straight `!=` (which is correct for "both present and differ — drop NULL rows"). Keep BRIEF.

**Next sweep probes**:
- Other under-exercised topics per iter956 candidates: window-frame BETWEEN variants (specifically `BETWEEN N PRECEDING AND N FOLLOWING`), GROUPING SETS / ROLLUP / CUBE, lateral JOIN UNNEST, qualified-name resolution.
- Federation: bulletproofed angles ONLY (4.49944/310 row hard-locked).
- One null-safe-comparison angle (e.g., "find rows where field_a changed across two snapshot tables, including NULL-to-value and value-to-NULL transitions") to test if IS DISTINCT FROM omission recurs.
- Do NOT re-probe gaps-and-islands streak-construction yet (iter957 already pivoted away; let the strengthened defang at r07 L3226-3263 continue settling).

**Do NOT touch**:
- r07 L3226-3263 (strengthened B-Streak filter-then-count defang, 2-3 iters old, holding per iter956 confirmation)
- r07 L37 (HAVING-perf reword)
- r07 L1624 (anti-nesting MAX(COUNT(*)) parse-error card — Q4 verified it lands)
- r07 NESTED_WINDOW WRONG #1+#2 / two-GROUP-BY WRONG #2
- r23 §3.1G argmax / COUNT(DISTINCT) canonical / HAVING-vs-WHERE / QUALIFY-not-Trino / regexp_like card / NULLS-LAST default / geometric/harmonic mean cards
- r09 partition DDL strings + bucket(col,N) column-first
- r28 DATE-literal + date_trunc-to-range nuance
- r13 json_exists strict path
- r22 §13.x federation (all rows hard-locked)
- Percentile cards / INTERVAL qualifier cards / format_datetime-vs-to_char card / PARTITIONED-BY guidance / price-suffix canonical / MAX_BY-nested defang

---

## Pins reinforced

- **WHERE before GROUP BY / aggregation** per sql/select.html — filter-count is the canonical row-level filter pattern, distinct from filter-then-count gaps-and-islands always-zero bug (which is about windows/streak partitions, NOT row-level COUNT(*) WHERE).
- **`date_diff(unit, earlier, later)` is unit-first then chronological**, day-aware / complete-units per `reference_trino_datediff_dayaware.md` and functions/datetime.html — returns whole days, no fractional, no timestamp-minus-timestamp subtraction.
- **AVG ignores NULL inputs naturally** per functions/aggregate.html; explicit `WHERE x IS NOT NULL` is redundant for AVG but clarifies intent (and matters for COUNT(x)).
- **`!=` with NULL operand → UNKNOWN → row dropped** (3VL) per functions/comparison.html.
- **`IS DISTINCT FROM` / `IS NOT DISTINCT FROM` = NULL-safe (in)equality** per functions/comparison.html (WebSearch 2026-06-10 confirmed): NULL treated as a known value, guarantees TRUE/FALSE outcome. `a IS DISTINCT FROM b` → TRUE when differ (incl. NULL-vs-nonNULL), FALSE when equal or both-NULL. `NULL IS NOT DISTINCT FROM NULL` → TRUE; `NULL IS DISTINCT FROM NULL` → FALSE.
- **Nested aggregation illegal in 467** — `AVG(COUNT(...))` is an analyzer parse-time error; materialize inner aggregates in a CTE or subquery first; two-level pattern is the canonical fix. Generalizes to MAX_BY(x, COUNT(...)), SUM(SUM(...)), etc.
- **Default NULLS LAST in 467** per `reference_trino_null_ordering_default.md`.
- **HAVING after aggregation** per sql/select.html; HAVING does NOT cut GROUP BY memory per r07 L37.
- **COUNT(*) GROUP BY g valid**, NULL gets its own group, ORDER BY alias resolves per sql/select.html.

Federation (4.49944/310) only un-passed row — bulletproofed angles only. PRESERVE full iter534-956 pin inventory; NO federation edits, NO percentile-card edits, NO PARTITIONED-BY defang card, NO INTERVAL-qualifier edits, NO HAVING-perf defang card, NO price-suffix canonical card, NO MAX_BY-nested defang card, NO B-Streak defang edits. PIN 467. DO NOT bump training/state.json (already 957; passed=true preserved; overall 4.71875 STRONG PASS holds; final_iterations_remaining 0).

Sources:
- [Trino Comparison functions and operators](https://trino.io/docs/current/functions/comparison.html)
- [Trino 467 Datetime functions](https://trino.io/docs/467/functions/datetime.html)
- [Trino 467 Aggregate functions](https://trino.io/docs/467/functions/aggregate.html)
- [Trino 467 SELECT statement](https://trino.io/docs/467/sql/select.html)
