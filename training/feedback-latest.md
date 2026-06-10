# iter955 Judge Feedback — LIGHT FIX-A2 verify sweep (B-Streak filter-then-count STRENGTHENED defang + RE-PROBE #5)

## Overall verdict

**PASS — overall avg 4.34375** (per-Q Q1 3.75 / Q2 5.00 / Q3 4.75 / Q4 3.875 = 17.375 / 4 = 4.34375; margin +0.84375 ABOVE threshold; OVERALL AVERAGE governs).

FEDERATION NOT PROBED (4.49944 / 310 row UNCHANGED).

All dialect verified vs trino.io/docs/467 (functions/window.html, functions/datetime.html, functions/teradata.html, functions/aggregate.html, sql/select.html) + WebSearch 2026-06-10. Verify-in-BOTH-directions discipline (iter882) applied to Q1 frame semantics and to_char/format_datetime claim.

## TEACHER FIX-A2 verdict — STRENGTHENED DEFANG IS DIALECT-CORRECT AND PRESERVED THE B-STREAK SKELETON

Read r07 L3223-3262 (LIGHT FIX-A2 strengthen-in-place):

- **Findability router (L3228)** — domain-neutral keyword anchors covering customer/agent, declined/paid, failed/success, scan/delivered, miss/goal, "I keep getting zero / it returns 0 every time" + explicit "SAME pattern no matter what the two event values are called". Solves the iter954 routing-failure root cause (defang's declined/paid keywords did not match customer/agent rephrase).
- **Streak-association paragraph (L3232-3237)** — explicit "target/boundary row lands in its OWN streak N while the preceding run is streak N-1" + the two always-zero traps (WHERE-to-target-before-counting AND counting-within-target's-own-streak). Verified-in-both-directions: select.html ("HAVING filters after groups and aggregates are computed") + window.html ("[window functions] run after the HAVING clause but before the ORDER BY clause") => WHERE runs before GROUP BY/HAVING AND before window functions. CORRECT.
- **CORRECT block LEADS (L3239-3251, copy-attractive)** — `per_streak` CTE: `COUNT(*) FILTER (WHERE status='declined')` over the FULL run + `max_by(status, event_time) AS ending_status`, GROUP BY streak_id, NO pre-filter; outer SELECT applies `WHERE ending_status='paid'` after the per-streak aggregate. `max_by(x, y)` valid SINGLE aggregate per functions/aggregate.html (2nd arg plain column, NOT nested aggregate). Did NOT re-introduce the nested-aggregate `arbitrary(...) FILTER` form that iter953's verification flagged. CLEAN.
- **WRONG #1 + WRONG #2 inline-marked DO NOT COPY (L3253-3259)** — WRONG #1 covers WHERE-to-target before GROUP BY OR before window (parenthetical "same bug if you swap GROUP BY for COUNT(*) OVER..."). WRONG #2 covers counting within the target's own streak (the streak-association trap). Both inline-WRONG-marked per `feedback_defang_donotwrite_snippets.md` (no isolated DO-NOT-WRITE backfire-prone snippets).
- **B-Streak skeleton (L3187-3221) UNTOUCHED** — Layer-1/2/3 + NESTED_WINDOW WRONG #1 / two-GROUP-BY WRONG #2 defangs intact. Reconcile-adjacent edit per `feedback_reconcile_dont_append.md`, no append-to-end bloat.

**Construction VERDICT = STRENGTHENED DEFANG IS DIALECT-CORRECT, FINDABILITY GAP CLOSED, NO SKELETON CORRUPTION.**

## Q1 verdict — STRENGTHENED DEFANG HELD ON THE ALWAYS-ZERO AXIS (major recovery from iter954); secondary cumulative-vs-consecutive frame imperfection remains

**Q1 (Acc 3.5 / Comp 3.5 / Clar 4.0 / Act 4.0 = 3.75)**

Responder's query (no WHERE filter, `SUM(CASE WHEN event_type='miss' THEN 1 ELSE 0 END) OVER (... ROWS UNBOUNDED PRECEDING AND 1 PRECEDING)` wrapped in `CASE WHEN event_type='goal'`):

TRACE on [miss, miss, goal, miss, goal] one match_id ordered by occurred_at:
- row1 (miss): frame {} -> 0, output NULL (event_type='miss', CASE returns NULL)
- row2 (miss): frame {miss} -> 1, output NULL
- row3 (goal #1): frame {miss, miss} -> 2, output = 2  (CORRECT for "consecutive misses right before goal #1")
- row4 (miss): frame {miss, miss, goal} -> 2, output NULL
- row5 (goal #2): frame {miss, miss, goal, miss} -> 3, output = 3 (TRUE consecutive run = 1; cumulative over-count)

**ALWAYS-ZERO AXIS — DEFANG HELD (MAJOR RECOVERY FROM iter954 0-EVERY-TIME):**
- responder used NO WHERE filter — keeps BOTH 'miss' and 'goal' rows in the window's input
- `SUM(CASE WHEN event_type='miss' THEN 1 ELSE 0 END) OVER (...)` correctly counts misses with both types present (goal rows contribute 0 to the SUM, not absence from the window)
- goal #1 -> 2 (correct, non-zero)
- diagnostic prose "you filtered to misses and lost the goal rows; window functions preserve the row set" matches the defang RULE one-for-one
- 5th-domain rephrase (miss/goal — NOT declined/paid OR customer/agent OR scan/delivered OR failed/success) routed correctly via the strengthened domain-neutral router. Findability gap CLOSED for this surface.

**FRAME AXIS (secondary imperfection):** `ROWS UNBOUNDED PRECEDING AND 1 PRECEDING` is CUMULATIVE across the partition's prior rows, NOT the consecutive-run since the last goal. For goal #2, the true "consecutive misses right before it" = 1 (just miss3 between goal #1 and goal #2), but the responder's frame returns 3 (cumulative miss count across the whole partition history). The user's wording — "consecutive miss shots in the run right before it" — explicitly asks for the run-since-last-boundary, which requires a streak_id reset at each goal (the CORRECT block of the strengthened defang uses precisely that shape: shared streak_id between run + ending target, COUNT over full streak, max_by to read the ending status). The frame is correct only when there is a single goal per match or no intervening goal between misses — over-counts on matches with multiple goals.

**Q1 SCOPE:** filter-then-count ALWAYS-ZERO bug RESOLVED — defang HELD on the FAIL-causing axis from iter954. Secondary cumulative-vs-consecutive frame imperfection remains (plausible-but-wrong non-zero numbers for repeated goals, MUCH less severe than always-zero silent wrong result). Responder also explicitly diagnosed the user's "I keep getting zero" complaint, demonstrating the diagnostic prose lands. Score 3.75 reflects the recovery on the always-zero axis (the principal failure mode) with the secondary frame defect docked on Acc/Comp.

## Q2 verdict — format_datetime is the RIGHT 467 choice for month-NAME labels; CLEAN

**Q2 (Acc 5.0 / Comp 5.0 / Clar 5.0 / Act 5.0 = 5.00)**

Responder: `format_datetime(CAST(placed_at AS timestamp), 'MMMM yyyy') AS month_label` -> "January 2025".

- VERIFIED vs trino.io/docs/467/functions/datetime.html (WebSearch 2026-06-10): `format_datetime(timestamp, format)` formats a timestamp as a string using Joda DateTimeFormat patterns. `MMMM` = full month name ("January"), `yyyy` = 4-digit year. CORRECT.
- Responder explicitly notes: `MMMM` = full name, `MMM` = abbreviated, `MM` = zero-padded number, lowercase `mm` = minutes (the iter954-flagged dialect trap, now correctly disambiguated). CORRECT.
- Responder did NOT use `to_char(...)`. This is the RIGHT choice — per trino.io/docs/467/functions/teradata.html, Trino 467 DOES have `to_char(timestamp, format)` but format codes are lowercase numeric-only Teradata-style (`mm`, `yyyy`, `hh24`, `mi`, `ss`); month NAMES (`MMMM` for "January") are NOT in the Teradata spec. The corrected memory from iter954 (to_char exists but lowercase-numeric-only, no month names) — responder's choice of `format_datetime` for a month-NAME label is the dialect-correct path. CORRECT.
- `GROUP BY date_trunc('month', placed_at)` secondary form mentioned for aggregation grain. Valid 467 per sql/select.html (GROUP BY repeats expression, returns timestamp). CORRECT.
- `CAST(placed_at AS timestamp)` is optional (TIMESTAMP coercion is implicit per `reference_trino_timestamp_tz_coercion.md`) but not wrong. CORRECT.

**Q2 SCOPE:** CLEAN. The format_datetime-vs-to_char dialect distinction landed correctly on a 2nd-angle re-probe after iter954's broken-secondary slip — the corrected directive memory took.

## Q3 verdict — canonical COUNT(*) GROUP BY rating + NULL caveat + histogram alternative, CLEAN

**Q3 (Acc 5.0 / Comp 5.0 / Clar 4.5 / Act 4.5 = 4.75)**

Responder: `SELECT rating, COUNT(*) FROM reviews GROUP BY rating ORDER BY rating` + NULL-as-its-own-group caveat + `histogram(rating)` alternative producing `map<rating, bigint>`.

- COUNT(*) GROUP BY rating ORDER BY rating — textbook canonical. Valid 467 per sql/select.html.
- NULL-group caveat correct: GROUP BY treats NULL as its own bucket (standard SQL behavior, also documented in r23). Engineer needs to know NULL appears as a separate row.
- `histogram(rating)` returns `map<rating, bigint>` per trino.io/docs/467/functions/aggregate.html — valid 467 single-call alternative producing a map of value -> count. Useful when the engineer wants one-row-per-table output. CORRECT.

Minor knock on Clar/Act for the histogram alternative being mentioned without explicit scoping guidance (when is map output preferred over the canonical group-count table). NOT a correctness issue.

**Q3 SCOPE:** CLEAN.

## Q4 verdict — two-level CTE for AVG(COUNT(DISTINCT ...)), explicit anti-nesting call-out, CLEAN

**Q4 (Acc 4.5 / Comp 4.0 / Clar 3.5 / Act 3.5 = 3.875)**

Responder:
```sql
WITH cart_product_counts AS (
  SELECT user_id, cart_id, COUNT(DISTINCT product_id) AS distinct_products
  FROM cart_items
  GROUP BY user_id, cart_id
)
SELECT user_id, AVG(distinct_products)
FROM cart_product_counts
GROUP BY user_id
```
+ explicit "can't write AVG(COUNT(DISTINCT product_id)) — Trino forbids nesting aggregates, materialize inner counts first".

- Inner CTE: COUNT(DISTINCT product_id) per (user_id, cart_id) — single-arg COUNT(DISTINCT) valid 467 per functions/aggregate.html (the count_distinct_single_arg pin holds — NOT multi-arg). CORRECT.
- Outer SELECT: AVG(distinct_products) GROUP BY user_id — references the CTE column as a plain column (no nested aggregate). CORRECT.
- "can't nest AVG(COUNT(DISTINCT ...))" anti-nesting claim CORRECT per Trino analyzer (nested aggregations illegal — r07 anti-nesting busiest-weekday card pins this).
- NO broken single-level alternative offered (contrast iter950 Q3 MAX_BY(x, SUM(y)) nested footgun); responder did NOT ship a "simpler form" that would re-introduce the nested-aggregate bug. The broken-secondary-alternative meta-pattern did NOT recur on this surface.

Minor knock on Clar/Act for not explicitly naming "this is the canonical AVG-OF-GROUP-COUNT pattern" or mentioning the user might want `AVG(distinct_products) OVER ()` as a single-row-summary alternative. NOT a correctness issue.

**Q4 SCOPE:** CLEAN. Two-level CTE is the textbook 467 shape, anti-nesting call-out is dialect-correct.

## Scope summary

- Q1: filter-then-count always-zero bug RESOLVED — STRENGTHENED defang HELD on the FAIL-causing axis (5th-domain rephrase routed correctly via domain-neutral router; diagnostic prose matched the defang RULE). Secondary cumulative-vs-consecutive frame imperfection remains (plausible-but-wrong non-zero for matches with multiple goals; much less severe than always-zero).
- Q2: format_datetime-not-to_char dialect distinction landed on a 2nd-angle re-probe — corrected directive memory took.
- Q3: canonical clean.
- Q4: two-level CTE for AVG-OF-GROUP-COUNT clean, anti-nesting call-out dialect-correct, NO broken-secondary alternative offered.

NO new resource defect. NO findability gap on the always-zero axis (router took). The strengthened defang is functioning as designed.

## iter956 recommendation — DEFAULT NO-OP / RE-PROBE-DON'T-CHURN

**Reasoning:**

1. The strengthened defang (iter955 LIGHT FIX-A2 at r07 L3223-3262) is 1 iteration old and TOOK on the always-zero axis for the 5th-domain rephrase (miss/goal). Per re-probe-don't-churn doctrine, do NOT escalate on 1-iteration-old additive content.
2. The secondary cumulative-vs-consecutive frame imperfection on Q1 is a SEPARATE defect family — it is a window-frame choice (UNBOUNDED PRECEDING vs streak_id-reset-at-boundary), NOT the filter-then-count always-zero bug. The strengthened defang's CORRECT block already uses streak_id sharing between run + target, but the responder chose a cumulative window instead of routing to the streak_id apparatus. This is 1st-instance frame-choice imperfection; address only if recurs on 2+ further sweeps WITHOUT the always-zero bug noise.
3. RE-PROBE next sweep with a 6th-domain filter-then-count phrasing (e.g., "for each session-end event count clicks in the session leading up to it", "for each shipped order count the tracking events leading up to it") to verify the always-zero resolution holds across more surfaces. ALSO probe a MULTIPLE-BOUNDARY-PER-PARTITION frame question to test whether the cumulative-vs-consecutive frame imperfection recurs.
4. Do NOT touch r07 L3223-3262 (newly-strengthened defang, 1 iter old, holding) / r07 L37 (HAVING-perf reword) / r07 L1624 (anti-nesting) / r07 NESTED_WINDOW WRONG #1+#2 / r23 §3.1G argmax / federation row / percentile cards / INTERVAL qualifier cards / COUNT(DISTINCT) single-arg pin / PARTITIONED-BY guidance / format_datetime-vs-to_char card.
5. If filter-then-count always-zero bug recurs on a 6th-domain rephrase next sweep, ESCALATE to LIGHT FIX-A3 (likely a meta-card warning against "alternative" framings that ship the defanged shape, OR consider that the streak-association part is too long and needs to be split into a separate Layer-3 sub-card). Also consider whether Haiku synthesis limit is being reached — if the always-zero is resolved but frame imperfection persists, scoping as Haiku synthesis ceiling rather than resource gap is appropriate.

**Federation (4.49944 / 310) only un-passed row — bulletproofed angles only. Do NOT probe federation; resources/22 §13.x hard-locked.**

## Pins reinforced

- **filter-then-count always-zero bug** = WHERE-to-target before count OR count-in-target's-own-streak. WHERE runs before GROUP BY AND before window functions (select.html + window.html, WebSearch 2026-06-10 RE-CONFIRMED).
- **correct shape** = keep both types, count other-type over the FULL streak (no pre-filter), associate via shared streak_id (run + target carry one id), reduce to target-ending streaks via `max_by(status, event_time)`.
- **ROWS UNBOUNDED PRECEDING AND 1 PRECEDING** = cumulative across partition's prior rows, NOT consecutive-run since last boundary; consecutive-run-reset-at-each-boundary requires streak_id apparatus.
- **max_by(x, y)** = valid SINGLE aggregate (2nd arg plain column, NOT nested aggregate) per functions/aggregate.html.
- **nested aggregation** (`AVG(COUNT(...))`, `MAX_BY(x, SUM(y))`, agg-in-FILTER) illegal — materialize inner aggregates in a CTE/subquery first.
- **format_datetime(timestamp, Joda)** is the dialect-correct 467 way to produce month-NAME labels ("MMMM yyyy" -> "January 2025"). `to_char(timestamp, format)` EXISTS in 467 as Teradata-compat but lowercase numeric-only — no month names; case-sensitive.
- **histogram(x)** returns `map<x, bigint>` valid 467.
- **date_trunc('month', timestamp)** returns timestamp valid GROUP BY grain.
- **COUNT(DISTINCT col)** single-arg only; combinations via COUNT(DISTINCT (a, b)) ROW-wrap.
- **GROUP BY repeats expression** not alias.
- **default NULLS LAST** in 467 per `reference_trino_null_ordering_default.md`.
- **HAVING after aggregation** per sql/select.html.

PIN 467. DO NOT bump training/state.json (already iter955; passed=true preserved; overall 4.34375 PASS).
