# Iter 578 Judge Feedback — 2026-06-07 (EXTENDED PHASE)

## Verdict: 3.9375 PASS overall (margin +0.4375 above 3.5 floor)

Q1 1.25 hard FAIL (recurring interval-overlap miss); Q2 5.00 STRONG PASS (FIX B routed); Q3 5.00 STRONG PASS; Q4 4.50 STRONG PASS. Overall avg = (1.25 + 5.00 + 5.00 + 4.50)/4 = 15.75/4 = **3.9375 PASS**.

**HEADLINE**: FIX A (r07 §4 interval-overlap H3 anchor expansion + reservations worked variant + DO-NOT-WRITE buried in the existing H3) FAILED to route — Q1 recurred the EXACT iter577 semantic defect (start-day GROUP BY instead of interval-overlap range join). FIX B (NEW LEADING CANONICAL H2 in r28 for dbt generic data tests) WORKED — Q2 routed cleanly with correct schema.yml, default severity:error, dbt build skip-downstream, and accurate compiled-SQL shape. The lesson: **placement matters more than content**. A correct anchor BURIED inside an H3 the responder doesn't open is invisible; a NEW H2 at the level where fresh questions LAND is visible. iter579 PRIMARY FIX = move the interval-overlap steering to where the responder ACTUALLY LANDS for "every day shown" / "zero-fill" / "calendar" / "date spine" questions — that means a ROUTING SIGNPOST at the date-spine / gap-fill entry point (NOT inside the interval-overlap H3).

---

## Q1 — Co-working desks occupied per day, end_date NULL, include zero-days (PRIMARY iter578 FIX A re-probe) — 1.0/1.0/2.0/1.0 = **1.25 hard FAIL**

### The recurring semantic defect

The responder wrote:
```sql
bookings_by_day AS (
  SELECT CAST(start_date AS DATE) AS day, COUNT(DISTINCT desk_id) AS occupied_desks
  FROM your_bookings_table
  WHERE start_date <= current_date AND (end_date IS NULL OR end_date >= DATE_TRUNC('month', current_date) - INTERVAL '1' MONTH)
  GROUP BY CAST(start_date AS DATE)
)
```

This **GROUP BY `CAST(start_date AS DATE)`** credits each booking ONLY on its `start_date`. A desk booked May 1 → May 20 contributes ONLY to May 1; May 2–19 show 0 (or whatever other bookings started those days). This is the **exact same** interval-overlap miss as iter577 Q1 — wrong question answered: "desks that STARTED a booking on day d" not "desks that were ACTIVE on day d."

The WHERE-clause overlap filter (`start_date <= current_date AND (end_date IS NULL OR end_date >= last-month-start)`) is correctly written for the bookings overlapping the window — proving the responder PARTIALLY grasped overlap at the row-filter level — but then mis-attributed each overlapping booking to its start day only.

### The correct query

```sql
WITH calendar AS (
  SELECT day
  FROM UNNEST(sequence(
    DATE_TRUNC('month', CURRENT_DATE - INTERVAL '1' MONTH),
    DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '1' DAY,
    INTERVAL '1' DAY
  )) AS t(day)
)
SELECT
  c.day,
  COUNT(DISTINCT b.desk_id) AS desks_occupied
FROM calendar c
LEFT JOIN bookings b
  ON b.start_date <= c.day
 AND (b.end_date IS NULL OR b.end_date > c.day)   -- half-open [start, end); NULL = still active
GROUP BY c.day
ORDER BY c.day;
```

Key points: (1) calendar is the SPINE; (2) interval-overlap range predicate is in the LEFT JOIN ON-clause (`b.start_date <= c.day AND (b.end_date IS NULL OR b.end_date > c.day)`); (3) half-open semantics — if end_date = May 20 the booking is active May 19 but not May 20 (adjust to `>=` if your end_date is inclusive); (4) `COUNT(DISTINCT b.desk_id)` returns 0 for days with no overlapping booking (because LEFT JOIN gives NULL b.desk_id and COUNT(DISTINCT non-null) = 0); (5) no need to filter the bookings table by window — the calendar bounds do that mechanically via the ON clause.

### Verification quote

Per **trino.io/docs/467/sql/select.html** UNNEST + SELECT semantics, plus the H3 already exists at r07 §4 with the canonical SQL shape — the canonical itself is correct, but the responder didn't route there.

### Why FIX A failed to route — DIAGNOSIS

The orchestrator's hypothesis is right: the responder treats "every day shown / zero-day must read 0" as a **date-spine GAP-FILL** family question (which r07 has well-developed in §1a/§1a.5/§1b). Once it lands on gap-fill, its default move is **group the facts by their date column** (here `CAST(start_date AS DATE)`) and LEFT JOIN to the spine. It NEVER OPENS the interval-overlap H3 because the question doesn't mention "overlap" or "interval" or "range" — it mentions "every day shown" + "0 desks" which screams gap-fill.

FIX A added the worked reservations variant + DO-NOT-WRITE block **INSIDE** the interval-overlap H3. But the responder doesn't navigate into that H3 — it stops one level up at the gap-fill canonical, finds the gap-fill recipe, and applies it to the facts as-given (which happen to be intervals, not single-day events).

This is a **routing/entry-point defect, not a content defect**. The content is correct; the entry point is wrong. Compare to FIX B which succeeded because it placed a NEW H2 at the same level where fresh dbt-tests questions land — not buried inside an existing H3.

### iter579 fix: ROUTING SIGNPOST at the gap-fill / date-spine entry point

Place a **disambiguation steering block at the TOP of the date-spine / gap-fill H2** in r07 (not inside the interval-overlap H3). One short, grep-findable block:

```
ROUTING SIGNPOST — if your facts are INTERVALS (start_date/end_date, check_in/check_out, login/logout, booked_from/booked_to) and the question asks how many are ACTIVE per day (or per hour), this is NOT a date-spine gap-fill question — DO NOT GROUP BY DATE(start_date) and LEFT JOIN to the spine. That counts each interval ONCE on its start day only.

Use the interval-overlap RANGE JOIN instead: `calendar c LEFT JOIN facts f ON f.start <= c.day AND (f.end IS NULL OR f.end > c.day)` with `COUNT(DISTINCT f.entity_id)` or `COUNT(f.fact_id)`. Full canonical: §4 interval-overlap H3 [link].

Trigger phrases that route HERE not gap-fill: "active per day", "occupied per day", "who was checked in on day X", "concurrent bookings", "open tickets per day", "in-progress per day", "desks occupied", "rooms occupied", "members present", "sessions live", "subscriptions active on day d", "booking spans these days", "end_date NULL = still active / open-ended", "reservation from Mon to Fri covers Mon Tue Wed Thu".
```

Critical placement detail: this block must be **at the top of the gap-fill section, BEFORE any gap-fill SQL example**. The responder lands on the first gap-fill SQL it sees and applies it — the signpost must intercept BEFORE that landing.

Also recommend: add a sibling SECTION CROSS-REFERENCE at the END of the date-spine canonical answer ("if your facts are intervals, see interval-overlap H3 — this gap-fill won't work for that case") to catch the responder on the way OUT of gap-fill if it landed there first.

---

## Q2 — dbt generic tests: fail build on duplicates / NULLs (iter578 FIX B re-probe) — 5.0/5.0/5.0/5.0 = **5.00 STRONG PASS**

### What the responder delivered

- Correct schema.yml with `desk_id` under `data_tests: [unique, not_null]` and `start_date` under `data_tests: [not_null]`.
- Correct `dbt build` interleave semantics: materialize → test → if failing-error-severity test, downstream models SKIP.
- Correct default severity = `error`.
- Correct compiled `unique` test SQL shape: `SELECT desk_id FROM bookings WHERE desk_id IS NOT NULL GROUP BY desk_id HAVING COUNT(*) > 1`.

### Verification quotes

**docs.getdbt.com/reference/resource-configs/severity** (verbatim):
> "severity: error or warn (default: error)"

**docs.getdbt.com/reference/commands/build** (per search verbatim):
> "Tests on upstream resources will block downstream resources from running, and a test failure will cause those downstream resources to skip entirely. E.g. If model_b depends on model_a, and a unique test on model_a fails, then model_b will SKIP."

**docs.getdbt.com/docs/build/data-tests** + community-verified compiled SQL:
> The compiled `unique` test takes the canonical form `select COL as unique_field, count(*) as n_records from RELATION where COL is not null group by COL having count(*) > 1` — matches the responder's shape exactly.

### Verdict

FIX B's findability landed cleanly. The NEW LEADING CANONICAL H2 in r28 (placed between "Quick-decision cheatsheet" and the merge-degradation canonical, AT THE PROMINENCE LEVEL where fresh dbt-tests questions land) was the right intervention. The responder ANSWERED this time (vs iter577 where it honest-declined). Findability lock confirmed.

### What worked structurally about FIX B (so we know what to copy for iter579 FIX A re-do)

- NEW section, NOT buried inside an existing one
- Placed at H2 prominence, not H3 or H4
- Placed in the EARLY part of the file (responder lands on early sections first)
- Keyword anchors covered the FRESH question vocabulary ("fail the build", "no duplicate IDs", "no NULL emails", "data quality test"), not just internal/expert vocabulary ("severity", "store_failures")

The iter579 FIX A re-do should mirror these four structural moves.

---

## Q3 — HAVING vs WHERE on aggregate (FRESH) — 5.0/5.0/5.0/5.0 = **5.00 STRONG PASS**

### What the responder delivered

- Correct explanation: WHERE runs before aggregation (filters individual rows); HAVING runs after GROUP BY + aggregation (filters groups).
- Correct fix: `GROUP BY customer_id HAVING SUM(amount) > 10000`.
- Correct rule-of-thumb: WHERE for row predicates, HAVING for aggregate predicates.

### Verification quote

**trino.io/docs/current/sql/select.html** (per search):
> "The HAVING clause is used in conjunction with aggregate functions and the GROUP BY clause to control which groups are selected. A HAVING clause eliminates groups that do not satisfy the given conditions, and HAVING filters groups after groups and aggregates are computed."

Zero defects. Canonical handling.

---

## Q4 — UNNEST a MAP column into key/value rows (FRESH) — 4.5/4.5/4.5/4.5 = **4.50 STRONG PASS**

### What the responder delivered

- Correct: `CROSS JOIN UNNEST(map_entries(properties)) AS t(entry)` then `entry.key`, `entry.value`.
- Correct: `map_entries(map)` returns `array(row(K, V))`.
- Correct: UNNEST of array-of-row explodes into rows.
- Correct: `LEFT JOIN UNNEST(...)` to preserve rows with NULL/empty maps.

### Verification

**trino.io/docs/current/functions/map.html** (per search):
> `map_entries(MAP(ARRAY[1, 2], ARRAY['x', 'y']))` returns `[ROW(1, 'x'), ROW(2, 'y')]` — confirms `array(row(K, V))` shape.

**trino.io/docs/current/sql/select.html** UNNEST semantics:
> "UNNEST can be used in combination with an ARRAY of ROW structures for expanding each field of the ROW into a corresponding column" — e.g., `UNNEST(ARRAY[ROW('Java', 1995), ROW('SQL', 1974)]) AS t(language, year)`.

### Alias-form nuance (minor note, -0.5 only because not mentioned)

Both forms are valid in Trino 467:

(a) **Single ROW column alias** — `UNNEST(map_entries(m)) AS t(entry)`, then access `entry.key` / `entry.value` via ROW dot-access. (Responder's form.)

(b) **Expanded multi-column alias** — `UNNEST(map_entries(m)) AS t(k, v)`, which expands the ROW fields directly into two named columns. This is the more idiomatic Trino form for ROW-typed array elements, because Trino's UNNEST has a special rule that an `array(row(...))` argument can be aliased into one column per ROW field.

The responder chose form (a) which works and is correct. Worth mentioning form (b) too because it's cleaner and is the form most Trino docs/examples show. Minor clarity nit only, not an accuracy defect.

---

## Topic rubric updates

- **Analytical query patterns on Iceberg+Trino** (Q1 interval-overlap reservations RE-PROBE r07 §4 H3 + Q4 UNNEST map_entries r09 / r07 array+row patterns): 4.2618/35 → (4.2618·35 + 1.25)/36 = **4.1781/36** (-0.0837 Q1 hard drag; FIX A failed to route, same defect as iter577 Q1) → (4.1781·36 + 4.50)/37 = **4.1869/37** (+0.0088 Q4 modest lift).
- **Improving complex SQL performance on Trino with dbt** (Q2 dbt generic tests r28 new H2): 4.6764/18 → (4.6764·18 + 5.00)/19 = **4.6934/19** (+0.0170 Q2 strong lift; FIX B landed cleanly).
- **SQL query best practices for OLAP** (Q3 WHERE vs HAVING r07/r23 patterns): 4.4615/146 → (4.4615·146 + 5.00)/147 = **4.4652/147** (+0.0037).
- **Federation**: NOT probed — **4.49944/310 row UNCHANGED**.

---

## iter579 Directive (PRIMARY FIX)

### FIX A (CRITICAL — HIGH PRIMARY): Re-do the interval-overlap routing — PLACE THE STEER WHERE THE RESPONDER LANDS

The iter578 FIX A failed for one reason: **the steer was buried inside the H3 the responder doesn't open**. The responder lands on gap-fill / date-spine and never navigates deeper. Fix it by putting a ROUTING SIGNPOST at the gap-fill / date-spine entry point itself.

**Concrete placement** in `resources/07-analytical-query-patterns.md`:

1. Find the gap-fill / date-spine H2 (the §1a-area canonical that handles "every day shown" / "zero-day must read 0" / `sequence(start, end, INTERVAL '1' DAY)` + LEFT JOIN to facts).
2. **At the very TOP of that H2, BEFORE any gap-fill SQL example**, insert a short ROUTING SIGNPOST block (the text in the Q1 section above is a starting point — adjust to match r07's exact voice). The block must:
   - Name the trigger condition: "facts are INTERVALS (start/end), question asks active/occupied per day".
   - Name the wrong move explicitly: "DO NOT GROUP BY DATE(start) and LEFT JOIN — that credits each interval only on its start day".
   - Name the right move + link to the §4 interval-overlap H3.
   - Include grep-findable trigger phrases the responder will keyword-match against: "active per day", "occupied per day", "concurrent bookings", "open tickets per day", "in-progress per day", "desks occupied", "rooms occupied", "end_date NULL = still active", "reservation from Mon to Fri covers Mon Tue Wed Thu", "booking spans these days".
3. **At the END of the gap-fill canonical answer** (after the closing example), add a one-line cross-reference: "if your facts are INTERVALS not point events, this gap-fill is WRONG for you — see §4 interval-overlap H3."

Do NOT touch the §4 interval-overlap H3 itself this iter. Its content is correct — the problem is the responder never gets there. Do NOT rewrite the gap-fill canonical SQL. PURELY ADDITIVE — one ROUTING SIGNPOST block at the top + one cross-reference line at the bottom.

**Verification before-and-after**: search `resources/07-analytical-query-patterns.md` for any existing gap-fill ROUTING SIGNPOST — if one exists, expand it; if not, add a new one. Reconcile-in-place per the standing rule.

### FIX B (NO-OP — CONFIRMED DURABLE)

r28 NEW LEADING CANONICAL H2 for dbt generic data tests routed cleanly at Q2. Zero edits.

### FIX C (NO-OP)

No fresh resource gaps surfaced at Q3 / Q4. Do not manufacture churn.

### iter579 probe targets

- **HIGHEST**: re-probe interval-overlap on a third fresh domain framing (e.g., "open support tickets per priority per day this month", "concurrent video calls per hour", "active subscriptions per tier per day last quarter") to verify FIX A's ROUTING SIGNPOST routes. THIS IS THE THIRD ATTEMPT at the interval-overlap pattern (iter577 FAIL on reservations/rooms framing, iter578 FAIL on co-working desks framing).
- **MEDIUM**: dbt generic tests fresh paraphrase (e.g., "dbt equivalent of CHECK constraint", "make pipeline fail if any negative price") — verify FIX B durability.
- **MEDIUM**: Q3 WHERE-vs-HAVING durability angle (e.g., HAVING on COUNT, HAVING + filter on grouping column).
- **LOW**: UNNEST MAP form (b) variant — `AS t(k, v)` instead of `AS t(entry)`.
- **LOW**: federation if nudging 4.49944/310 above 4.5.

---

## Meta-rule lesson — codify for future iters

**Findability rule: place the steer where the responder LANDS, not where the answer topically belongs.**

iter578 produced a controlled experiment. Same iter, same responder, two findability fixes:

- **FIX A (FAILED)**: Correct content placed INSIDE an existing H3 (interval-overlap) that the responder doesn't navigate into. The responder lands on gap-fill instead, applies the gap-fill recipe to the interval facts, and misses the H3 entirely. Content was correct; placement was wrong.

- **FIX B (SUCCEEDED)**: Correct content placed as a NEW H2 at the prominence level where fresh dbt-tests questions land. The responder navigated to it on first attempt.

Lesson: the "topically correct" location of a routing fix is determined by **where the responder LANDS for the question's keywords**, NOT by where a domain expert would file it. For "every day shown" / "0 must appear" questions, the responder lands on gap-fill — so that's where the interval-overlap steer must live, even though intervals aren't topically "gap-fill" content.

This is the **41st consecutive iter (iter537-578)** where meta-rule discipline materially affected the verdict. Add this specific findability rule to the standing meta-rules: when a content-correct fix fails to route, the fix is in the wrong PLACE not the wrong WORDS — relocate the steer one level UP the responder's keyword-match tree.

---

## Final score

**Overall avg = (1.25 + 5.00 + 5.00 + 4.50) / 4 = 3.9375 PASS** (margin +0.4375 above 3.5 floor; +0.640 swing from iter577's 3.297). FIX B confirmed durable; FIX A failed to route, identical defect recurred — iter579 PRIMARY FIX = relocate the interval-overlap routing signpost from inside §4 H3 to the TOP of the gap-fill / date-spine H2 entry point in r07.
