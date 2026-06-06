# Iter 577 — Judge Feedback (2026-06-07, EXTENDED PHASE)

## Verdict

**Overall avg = (1.75 + 3.00 + 4.9375 + 3.50) / 4 = 13.1875 / 4 = 3.297 — FAIL**

Margin: -0.203 below the 3.5 floor. Soft FAIL driven by Q1 + Q4. Q1 is the load-bearing miss: the responder did NOT apply the iter575 r07 §4 interval-overlap H3 to the reservations/rooms domain framing and instead reached for a START-DAY GROUP BY (counts each reservation once on its check-in day, NOT on every day it covers). The iter577 trap card (LEFT-JOIN + COUNT(*) → padded row counts as 1) was NOT exercised (the pre-aggregation form sidestepped it), so this iteration's NEW lock is unverified; the failure is the deeper interval-overlap APPLICATION miss carrying over from iter574/575. Q4 was honest (no fabrication) but missed retrievable content that exists in r27 §6.7 / §6.7A.

---

## Per-question scores

### Q1 — Reservations active per (room, day) this week, with zero-rows (interval-overlap re-probe)

**1.75 = avg(Accuracy 1, Completeness 2, Clarity 3, Actionability 1) — FAIL**

**Verdict: WRONG QUESTION ANSWERED.** The responder computed *reservations STARTING* per (room, day), not *reservations ACTIVE* per (room, day). A reservation that checks in Monday and checks out Friday is active on Mon/Tue/Wed/Thu (half-open `[check_in, check_out)`); the responder's `reservation_counts` CTE groups by `DATE(r.check_in)` and so credits the reservation only on Monday. Every subsequent day (Tue/Wed/Thu) gets 0 instead of 1.

Additional accuracy defects in the same CTE:
- `WHERE r.check_in >= CURRENT_DATE - INTERVAL '6' DAY` ALSO filters out the very reservations that should be counted as "active this week" — any reservation that checked in BEFORE this week but is still ongoing this week is silently dropped. The overlap predicate must use the calendar day `c.day` inside the join, not a static `CURRENT_DATE - INTERVAL '6' DAY` floor on `check_in`.
- `all_rooms AS (SELECT DISTINCT room_id FROM reservations)` will miss any meeting room that has had ZERO reservations ever — they will be absent from the grid. If "every (room, day)" includes never-reserved rooms, the source-of-truth for rooms must be the `rooms` (or `meeting_rooms`) table, NOT `DISTINCT room_id FROM reservations`.

**Irony / iter577 trap card not exercised.** Because the responder PRE-AGGREGATED `reservation_counts` first and then LEFT JOIN'd those pre-counted rows to the `calendar × all_rooms` grid with `COALESCE(rc.active_reservations, 0)`, the COUNT(*) is INSIDE the pre-agg (not across the LEFT JOIN), so the iter577 LEFT-JOIN-+COUNT(*) padded-row trap was incidentally avoided. The trap card from iter577 (r07 §4 line 958-986) is unverified by this answer — Q1's failure is the deeper iter574/575 interval-overlap APPLICATION miss on a NEW domain framing (reservations/rooms), not the iter577 LEFT-JOIN trap.

**Corrected query (range-join form per r07 §4 line 904-933):**
```sql
WITH calendar AS (
  SELECT d AS day
  FROM UNNEST(sequence(date_trunc('week', current_date),
                       date_trunc('week', current_date) + INTERVAL '6' DAY,
                       INTERVAL '1' DAY)) AS t(d)
)
SELECT c.day, ar.room_id, COUNT(r.reservation_id) AS active_reservations
FROM calendar c
CROSS JOIN meeting_rooms ar                                   -- source rooms from the rooms table, not from reservations
LEFT JOIN reservations r
  ON r.room_id = ar.room_id
 AND r.check_in <= c.day                                      -- interval started on or before c.day
 AND (r.check_out IS NULL OR r.check_out > c.day)             -- AND has not ended by c.day (half-open [check_in, check_out))
GROUP BY c.day, ar.room_id
ORDER BY c.day, ar.room_id;
```
This is the LEFT-JOIN-for-zero-rows variant explicitly called out at r07 line 911 ("Switch to LEFT JOIN + COALESCE(active_count, 0) if you need a row for every (day, plan_type) even when zero.") AND uses `COUNT(r.reservation_id)` (non-null right-table column) per the iter577 trap card at r07 lines 958-986, so empty (room, day) buckets return 0 (per trino.io/docs/467/functions/aggregate.html: `count(x)` *"Returns the number of non-null input values"* AND `count()` is in the exception list returning 0 not NULL for zero non-null values).

**Verifications.**
- Trino 467 aggregate page (cited by r07 §4 trap card already verbatim): `count(*)` *"Returns the number of input rows"* AND `count(x)` *"Returns the number of non-null input values"*, with the exception-list rule that `count()` returns 0 for zero non-null values.
- Interval-overlap range-join shape verified against the canonical at /Users/hclin/github/recknihao/resources/07-analytical-query-patterns.md lines 894-986.

**Root cause.** The r07 §4 keyword anchor list (line 896) reads: *"active subscribers per day, open tickets per day, concurrent sessions per day, count active intervals as of each day, how many were active on each date, range join calendar to intervals, point-in-time count per day, subscriptions active on day, headcount per day, occupancy per day, active members each day, open positions per day, count overlapping intervals, intervals covering each day, as-of count per day, daily snapshot count of in-progress entities."* It includes "occupancy per day" but does NOT include "reservations", "check_in", "check_out", "rooms", "meeting rooms", "bookings", "active reservations per day per room", "room occupancy". The Haiku responder finds answers by keyword→resource matching (per CLAUDE.md project memory `feedback_responder_findability.md`); the reservations/rooms domain framing fell THROUGH the keyword net even though the underlying pattern is identical.

---

### Q2 — Positive/contrast: INNER + COUNT(*) when zero-rows not needed

**3.00 = avg(Accuracy 3, Completeness 3, Clarity 3, Actionability 3) — partial credit**

**Conceptual answer (COUNT(*) is safe without a LEFT JOIN) is correct.** Verified against r07 §4 line 986: *"The trap is specifically the LEFT JOIN-for-zero-rows + COUNT(*) pairing. The canonical INNER JOIN query at the top of this H3 uses COUNT(*) safely because INNER JOIN drops the zero-match bucket entirely."* That is exactly the principle Q2 asked about and the responder got the principle right.

**BUT the worked SQL repeats Q1's semantic miss.** `SELECT room_id, DATE(check_in) AS day, COUNT(*) ... GROUP BY room_id, DATE(check_in)` is a START-DAY group-by, NOT an interval-overlap count. The (room, day) pairs it returns are "pairs where AT LEAST ONE reservation STARTED" — not "pairs where AT LEAST ONE reservation was ACTIVE." A room that was occupied Mon-Fri by a single reservation that started on Mon would yield only one (room, day=Mon) row, even though Tue/Wed/Thu also "had at least one reservation active." That contradicts what Q2 literally asks for.

**Correct INNER form (interval-overlap, no zero-row padding):**
```sql
SELECT c.day, ar.room_id, COUNT(*) AS active_reservations
FROM calendar c
CROSS JOIN meeting_rooms ar
JOIN reservations r                                            -- INNER JOIN drops zero-match (room, day) buckets
  ON r.room_id = ar.room_id
 AND r.check_in <= c.day
 AND (r.check_out IS NULL OR r.check_out > c.day)
GROUP BY c.day, ar.room_id
ORDER BY c.day, ar.room_id;
```

Partial credit because the conceptual point (COUNT(*) safe without LEFT JOIN, per r07 §4 line 986) was stated correctly even though the example SQL still answers the wrong question.

---

### Q3 — Conditional-aggregation pivot (CASE WHEN inside COUNT and FILTER form)

**4.9375 = avg(Accuracy 5, Completeness 5, Clarity 4.75, Actionability 5) — STRONG PASS**

Both forms are valid Trino 467:

- `COUNT(CASE WHEN status='paid' THEN 1 END) AS paid_orders` — standard single-pass conditional COUNT. `COUNT` ignores NULLs (per trino.io/docs/467/functions/aggregate.html: *"count(x) — Returns the number of non-null input values"*), so the CASE-without-ELSE returns NULL for non-paid rows and they are not counted. Correct.
- `COUNT(*) FILTER (WHERE status='paid') AS paid_orders` — also correct. Verified at trino.io/docs/467/functions/aggregate.html: *"The FILTER keyword can be used to remove rows from aggregation processing with a condition expressed using a WHERE clause. This is evaluated for each row before it is used in the aggregation and is supported for all aggregate functions."* Per the SELECT/aggregate FILTER reference, the syntax `aggregate_function(expression) FILTER (WHERE condition)` applies the WHERE before aggregation.

Both forms collapse to a single GROUP BY customer_id with three output columns — no three-way self-join required, no subquery joins. The responder correctly noted both are single-pass.

Minor -0.25 clarity nit for not explicitly noting that the CASE form would also work with `THEN 1 ELSE 0 END` + `SUM(...)` as an equivalent rewrite (some engines/users prefer the SUM-of-1-or-0 form), but neither approach is wrong and the responder's chosen forms are the cleaner Trino-idiomatic shapes.

---

### Q4 — dbt generic tests (unique / not_null, schema.yml, fail-build-on-violation)

**3.50 = avg(Accuracy 5, Completeness 1, Clarity 4, Actionability 4) — borderline FAIL on findability**

**Honesty credit.** The responder did NOT fabricate. Pointing to docs.getdbt.com is materially better than inventing wrong syntax. The honesty discipline (iter400+ no-fabrication lock) HELD. Accuracy 5.

**BUT this is a FINDABILITY MISS, NOT a coverage gap.** r27 §6.7 / §6.7A contains a substantial dbt generic-tests canonical with all the elements the question asked for:

- /Users/hclin/github/recknihao/resources/27-oracle-plsql-to-dbt-trino.md lines 2264-2283 has the exact schema.yml form the user wanted:
  ```yaml
  models:
    - name: fct_orders_daily
      tests:
        - dbt_utils.unique_combination_of_columns:
            combination_of_columns: [tenant_id, order_date]
      columns:
        - name: tenant_id
          tests: [not_null]
        - name: order_date
          tests: [not_null]
  ```
  And the immediately-following sentence (line 2283): *"These tests run after `dbt run`. A failure breaks the pipeline — same semantic role as `EXCEPTION WHEN ...` in the Oracle procedure"* — directly answers "fail the build on violation."

- §6.7A (lines 2287-2340+) covers severity: error vs warn explicitly:
  - *"`severity: error` (default) — test failure exits `dbt test` / `dbt build` non-zero; the pipeline halts. Use for hard data-quality guarantees."* (line 2305)
  - *"`severity: warn` — test failure emits a WARNING and the pipeline continues."* (line 2306)
  - Per-test YAML example at lines 2310-2320 + project-wide default at lines 2324-2328.

- r13 line 4180 also references the dbt `not_null` test as a recommended pattern.

**Verified at docs.getdbt.com.** Per [docs.getdbt.com/docs/build/data-tests](https://docs.getdbt.com/docs/build/data-tests): *"If the data test returns zero failing rows, it passes, and your assertion has been validated."* Per [docs.getdbt.com/reference/resource-configs/severity](https://docs.getdbt.com/reference/resource-configs/severity): tests with `severity: error` (the default) fail the build on violation. Per [docs.getdbt.com/reference/commands/build](https://docs.getdbt.com/reference/commands/build): *"dbt build orchestrates models, seeds, snapshots, and tests in DAG order, with unit tests before model materialization and data tests after"* — `dbt build` is the command that runs models + tests as one pipeline and fails on test error. dbt ships with `not_null`, `unique`, `relationships`, and `accepted_values` as built-in generic tests; declaring them in `schema.yml` is the canonical way to enforce data contracts at build time.

So the CORRECT one-paragraph answer was retrievable from r27 §6.7:

> "Yes — declare them as dbt generic tests in `schema.yml` (or `<model>.yml`). dbt ships `unique`, `not_null`, `relationships`, and `accepted_values` out of the box. Example for a `dim_users` model with `user_id` and `email`:
> ```yaml
> # models/marts/dim_users.yml
> version: 2
> models:
>   - name: dim_users
>     columns:
>       - name: user_id
>         tests: [unique, not_null]
>       - name: email
>         tests: [not_null]
> ```
> Run `dbt build` (NOT `dbt run`) — `dbt build` runs models then tests in DAG order; a failing test with the default `severity: error` exits non-zero and blocks downstream models. See resource 27 §6.7 / §6.7A for severity: warn vs error, `store_failures`, and the `dbt_utils.unique_combination_of_columns` composite-key form."

The responder's decline-and-point-to-docs is honest but leaves the engineer to re-discover content that's already in the repo and verbatim-correct.

**Why this matters per project memory** (`feedback_responder_findability.md`): the Haiku responder finds answers by keyword→resource matching. The question contained `dbt`, `unique`, `not_null`, `schema.yml`, `fail the build`, `data quality` — the §6.7A routing anchor (line 2244-2262) is keyworded for `dbt test severity`, `severity: warn`, `store_failures`, `_dbt_test__audit`, `expression_is_true`, `not_null_proportion` BUT NOT for the simpler/more-frequent phrases this question used: "no duplicate user IDs", "no NULL emails", "catch at build time", "fail the build on violation", "declare those rules in dbt", "data quality rules", "data contract." The §6.7 sub-cluster ALSO sits under a file titled "Oracle PL/SQL → dbt+Trino migration" — a fresh question with no Oracle context is unlikely to route there even when the dbt-ops H2 disclaimer (line 2262) explicitly says the dbt-ops canonicals apply to ALL dbt-trino setups. The H2-disclaimer footer note is too deep to trigger keyword-first retrieval.

---

## Iter578 directive

### Fix A — HIGH (PRIMARY) — r07 §4 interval-overlap H3 keyword-anchor EXPANSION for reservations/bookings/rooms domain

**Goal.** Make the reservations/rooms domain framing route to the iter575 interval-overlap canonical instead of triggering a start-day GROUP BY synthesis.

**Action.** Edit /Users/hclin/github/recknihao/resources/07-analytical-query-patterns.md line 896 (the keyword-anchors block at the top of the LEADING CANONICAL "count active/open intervals on each day" H3). ADD reservations/bookings/rooms vocabulary to the existing anchor list — do NOT rewrite the canonical SQL, do NOT touch the existing 3-pattern CONTRAST card at line 1019, do NOT touch the iter577 trap card at lines 958-986. Add these anchors after "occupancy per day" or as a separate clause at the end of the list:

```
reservations active per day per room, active reservations per day, room occupancy per day, bookings active each day, how many reservations were active in each room on each day, meeting room occupancy, check-in / check-out interval, [check_in, check_out) half-open, reservations covering each day per room, hotel/room/conference booking range, room-day occupancy grid, who was checked in on day X, count reservations spanning day d, reservations per room per day (active not started), bookings overlapping each calendar day.
```

**Also add a 1-paragraph "reservations/rooms domain example" worked variant** immediately after the canonical worked SQL at lines 904-933 (BEFORE the existing DO-NOT-WRITE cards). The variant should:
- Frame: "How many reservations were ACTIVE in each meeting room on each day this week."
- Use a bounded `calendar` CTE (`sequence(date_trunc('week', current_date), date_trunc('week', current_date) + INTERVAL '6' DAY, INTERVAL '1' DAY)`) — reuses the iter577 bounded-window spine card.
- Use `CROSS JOIN meeting_rooms ar` (source rooms from the rooms table, NOT `DISTINCT room_id FROM reservations` — that misses never-reserved rooms).
- Use `LEFT JOIN reservations r ON r.room_id = ar.room_id AND r.check_in <= c.day AND (r.check_out IS NULL OR r.check_out > c.day)` — half-open, calendar day in predicate.
- Use `COUNT(r.reservation_id)` (NOT `COUNT(*)`) — this exercises BOTH the iter575 interval-overlap pattern AND the iter577 LEFT-JOIN-COUNT trap card in one example.
- Add an explicit DO-NOT-WRITE bullet adjacent to the existing iter574 + BETWEEN pair:
  > *"DO NOT GROUP BY `DATE(check_in)` or `DATE(start_ts)` when the question asks 'how many were ACTIVE on each day' — that counts each interval ONCE on its check-in day only, NOT on the days it covers. A reservation Mon-Fri active 4 days must contribute to 4 (room, day) rows, not just to (room, Monday). The calendar day must enter the JOIN predicate via `start <= c.day AND (end IS NULL OR end > c.day)`."*
- Add the WRONG-FORM verbatim so it's grep-findable: `WHERE r.check_in >= CURRENT_DATE - INTERVAL '6' DAY ... GROUP BY r.room_id, DATE(r.check_in)` ❌

**Why this is the right fix.** The pattern canonical is correct and verbatim-verified at trino.io — the problem is purely findability. The Haiku responder DID find the H3 (or at least its surrounding content) on iter575 with subscription framing but did NOT route to it for reservations framing despite identical mathematical shape. Domain-vocabulary anchors close that retrieval gap. The reservations/rooms variant ALSO doubles as the iter577 LEFT-JOIN-COUNT trap card's first realistic worked example (the current trap card is abstract `(c.bucket, COUNT(s.subscription_id))` — a reservations grid makes the trap concrete).

### Fix B — HIGH — Surface dbt generic-tests canonical OUT of the Oracle-migration file OR add a top-level findability anchor

**Goal.** Make `dbt unique`, `dbt not_null`, `schema.yml`, `fail the build`, `data quality tests`, `no duplicates`, `no NULLs` route to r27 §6.7 — OR mirror a short canonical somewhere file-name-discoverable for fresh (non-Oracle-migration) questions.

**Recommended action (LOW-RISK, NO RECONCILE NEEDED).** Add a top-of-file "Universal dbt-Trino routing block" in r28 (complex-sql-performance-trino-dbt.md) — a SHORT H2/H3 with keyword anchors that point readers to r27 §6.7 / §6.7A. Something like:

```
## dbt generic data tests (unique / not_null / accepted_values / relationships) — fail the build on violation

> Keyword anchors: dbt unique test, dbt not_null test, dbt accepted_values, dbt relationships test, schema.yml tests block, dbt fail build on test failure, dbt build vs dbt test, data quality test in dbt, no duplicate IDs dbt, no NULL emails dbt, declare data contract dbt, severity error vs warn, dbt test data contract, dbt generic tests catalog, dbt built-in tests, fail pipeline on data quality violation, prevent bad data downstream, post-build data validation, dbt test framework.

dbt ships four built-in generic data tests: `unique`, `not_null`, `accepted_values`, and `relationships`. Declare them in `schema.yml` under `columns: ... tests: [...]`. Run with `dbt build` (preferred — runs models + tests in DAG order) or `dbt test` standalone. A failing test with default `severity: error` exits non-zero, blocks downstream models, and fails the pipeline.

> **For the FULL canonical** — severity: error vs warn, store_failures, expression_is_true, not_null_proportion, dbt_utils.unique_combination_of_columns composite keys, and the warn_if / error_if threshold mechanics — see [resources/27-oracle-plsql-to-dbt-trino.md §6.7 and §6.7A](27-oracle-plsql-to-dbt-trino.md). That canonical applies to ALL dbt-Trino setups (the file title is "Oracle migration" but §6.7 is dbt-ops, not migration-specific).

Minimal example (schema.yml):
```yaml
version: 2
models:
  - name: dim_users
    columns:
      - name: user_id
        tests: [unique, not_null]
      - name: email
        tests: [not_null]
```
Run `dbt build`. If `user_id` has any duplicate or `email` has any NULL, the test FAILS the build (exit non-zero) and downstream models are SKIPPED.
```

This is purely additive — does NOT reconcile or duplicate the §6.7 canonical, just makes it routable from a question that has no Oracle context. The cross-link preserves the §6.7A as the single source of truth.

Alternative (heavier — only if Fix B-light doesn't take): rename the r27 file or split §6.7 into a dedicated `resources/29-dbt-ops-and-tests.md`. NOT recommended for iter578 — too churny; the lightweight cross-anchor in r28 should suffice.

### Fix C — NO-OP — federation

4.49944/310 row unchanged. Q1-Q4 did not probe federation. Zero edits to /Users/hclin/github/recknihao/resources/22-trino-federation-postgresql.md §13.x.

### Fix D — NO-OP — iter577 trap card itself

The iter577 LEFT-JOIN-COUNT trap card at r07 lines 958-986 is correct and well-anchored. It was NOT exercised by Q1 (because Q1's pre-aggregation form sidestepped the LEFT JOIN entirely) but that's a domain-framing issue, not a card defect. Fix A's reservations/rooms variant will exercise it on iter578 if it surfaces.

### Iter578 probe targets

- **HIGHEST — verify Fix A routes.** Re-probe interval-overlap on a fresh domain — e.g., "How many open support tickets per priority per day this month" OR "How many concurrent video calls per region per hour yesterday" — AND ALSO re-probe the reservations/rooms exact framing (with `meeting_rooms` table available) to verify the new keyword anchors catch it.
- **HIGH — verify Fix B routes dbt generic tests.** Re-probe with paraphrases that have NO Oracle context: "I want my dbt model to reject rows with NULL in `email`", "Can dbt fail the build if my `customer_id` is duplicated?", "What's the dbt equivalent of a CHECK constraint?".
- **MEDIUM — Q3 FILTER clause durability re-probe.** Verify the `COUNT(...) FILTER (WHERE ...)` form holds on a fresh angle (e.g., "show me 7-day, 30-day, and 90-day active user counts in one row per cohort").
- **LOW — iter577 trap card direct probe.** Q1 sidestepped it; a direct micro-probe ("I switched from INNER JOIN to LEFT JOIN to get zero-rows and now every empty bucket shows 1, why?") would lock in the iter577 card's first direct verification.

---

## Meta-rule observation

Directive's *"SCRUTINIZE Q1 — I the orchestrator believe the responder MISSED the interval-overlap pattern"* + *"is this a findability/application miss"* was LOAD-BEARING. Without the explicit data-flow trace (`DATE(r.check_in)` collapse → reservation credited once on check-in day → Tue/Wed/Thu rows for the same reservation = 0 → wrong question answered), the COALESCE(0) + grid-CROSS-JOIN structure could have looked superficially correct. Reading for SEMANTICS (what does this query actually compute per row?) vs reading for STRUCTURE (does it have a grid + LEFT JOIN + COALESCE?) was the discriminator.

Same meta-rule on Q4: directive's *"is this a RESOURCE GAP or a FINDABILITY miss?"* + *"Search the resources yourself conceptually"* was load-bearing. A surface read would have credited the honesty (it IS honest) without checking that the content actually exists. Grep on `not_null|unique|severity|schema.yml` in /Users/hclin/github/recknihao/resources turned up r27 §6.7 / §6.7A immediately — confirming this is a findability gap, not coverage. 38th consecutive iter (iter537-577) where meta-rule discipline materially changed the verdict — this time turning a borderline-pass into a clear FAIL on Q1 and downgrading Q4 from "honest pass" to "findability fail."

WebSearched: trino.io/docs/467/functions/aggregate.html (FILTER clause + count(x) semantics VERBATIM), docs.getdbt.com/docs/build/data-tests + docs.getdbt.com/reference/resource-configs/severity + docs.getdbt.com/reference/commands/build (dbt generic tests + severity:error fails build + dbt build runs tests after models VERBATIM).

---

## Summary

- **Q1 — 1.75 FAIL** — semantic miss; START-DAY GROUP BY instead of interval-overlap range join; iter577 LEFT-JOIN-COUNT trap NOT exercised (sidestepped by pre-agg); also drops never-reserved rooms via `DISTINCT room_id FROM reservations`.
- **Q2 — 3.00 partial** — COUNT(*)-without-LEFT-JOIN principle correct; SQL example repeats Q1's start-day group-by semantic miss.
- **Q3 — 4.9375 STRONG PASS** — both CASE-inside-COUNT and COUNT(*) FILTER (WHERE ...) forms valid Trino 467; single-pass; no fabrication.
- **Q4 — 3.50 borderline FAIL** — honest no-fabrication decline; content EXISTS in r27 §6.7 / §6.7A but did not route (findability gap, not coverage gap).
- **OVERALL 3.297 — FAIL** by overall-average rule (-0.203 below 3.5 floor).
- **PRIMARY iter578 FIX (HIGH)** — r07 §4 keyword anchors + reservations/rooms worked variant.
- **SECONDARY iter578 FIX (HIGH)** — r28 dbt generic-tests cross-anchor block pointing to r27 §6.7.
- **NO federation churn.** **NO reconciliation of locked iter575/577 content** — additive findability fixes only.
