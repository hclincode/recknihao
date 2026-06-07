# Iter 663 Judge Feedback — 2026-06-08 (EXTENDED PHASE)

## Overall

**Score: 5.000 STRONG PASS** (margin +1.500 above 3.5 floor; flat vs iter662's 5.000 — second consecutive perfect-score iteration)
**Dim avg**: Acc 5.0 / Comp 5.0 / Clar 5.0 / Act 5.0 = 5.000 (agrees)
**Per-Q**: 5.00 + 5.00 + 5.00 + 5.00 = 20.00 / 4 = 5.000
**Flagged weak answers**: NONE (zero per-Q below 3.5 floor)

All four answers are technically valid Trino 467 dialect; all dialect facts cross-verified against trino.io/docs/467 via WebFetch (date_diff signature, date_trunc signature, HAVING-on-aggregate-expression validity, nested-aggregate restriction).

---

## Per-question scores

### Q1 — distinct sessions per user per day — 5.00 STRONG PASS
- **Acc 5 / Comp 5 / Clar 5 / Act 5**
- `SELECT user_id, date_trunc('day', event_time) AS day, COUNT(DISTINCT session_id) AS session_count FROM events GROUP BY user_id, date_trunc('day', event_time) ORDER BY user_id, day;`
- VERIFIED trino.io/docs/467/functions/datetime.html: `date_trunc(unit, x) -> same as input` — `date_trunc('day', timestamp)` returns timestamp at midnight, valid 1-row-per-calendar-day bucket; equivalent to `date(event_time)` for grouping purposes (per directive: do not penalize either form).
- VERIFIED trino.io/docs/467/functions/aggregate.html: `COUNT(DISTINCT col)` per-group is native and supported; multiple COUNT(DISTINCT) in one SELECT also supported.
- VERIFIED sql/select.html: 2-key `GROUP BY user_id, date_trunc('day', event_time)` is valid; ORDER BY references the output alias `day` (Trino 467 permits output-alias in ORDER BY).
- Self-contained explanation of bucketing + grouping + DISTINCT semantics; runnable as-is.

### Q2 — revenue converted to USD via rates JOIN — 5.00 STRONG PASS
- **Acc 5 / Comp 5 / Clar 5 / Act 5**
- `SELECT SUM(o.amount * r.usd_rate) AS total_revenue_usd FROM orders o LEFT JOIN currency_rates r ON r.currency_code = o.currency_code;`
- Canonical star-schema fact x dim conversion: per-row multiply `amount * usd_rate` then SUM; mechanical application of r08:12/52-67/111 star-schema primitive.
- LEFT JOIN correctly chosen for "keep all orders": SUM skips NULL summands, so missing rates produce a NULL contribution (silently dropped). The volunteered `COALESCE(r.usd_rate, 1)` safety belt is a thoughtful application-level callout (acknowledges the silent-drop risk).
- Concise + complete + actionable.

### Q3 — customers whose order span > 365 days — 5.00 STRONG PASS
- **Acc 5 / Comp 5 / Clar 5 / Act 5**
- CTE `MIN(order_date) AS first_order, MAX(order_date) AS last_order GROUP BY customer_id` then outer `WHERE date_diff('day', first_order, last_order) > 365`.
- VERIFIED trino.io/docs/467/functions/datetime.html: `date_diff(unit, timestamp1, timestamp2) -> bigint` returns `timestamp2 - timestamp1` (earlier first → positive bigint). Argument order is correct.
- Per directive: CTE-with-outer-WHERE on pre-aggregated MIN/MAX is equally valid as the alternate `HAVING date_diff('day', MIN(order_date), MAX(order_date)) > 365` on the raw table; no penalty for the CTE form.
- Explicitly calls out "pass earlier first for positive result" — important learner-facing hint.
- Bonus columns (`first_order`, `last_order`, `days_span`) help verification.

### Q4 — avg distinct products per order (two-level) — 5.00 STRONG PASS
- **Acc 5 / Comp 5 / Clar 5 / Act 5**
- Inner CTE: `SELECT order_id, COUNT(DISTINCT product_id) AS distinct_products FROM order_items GROUP BY order_id`; outer: `SELECT AVG(distinct_products) AS avg_products_per_order FROM order_product_counts`.
- VERIFIED: Trino does NOT allow `AVG(COUNT(DISTINCT product_id))` directly — nested aggregates produce a parse-time error (same restriction as Postgres / Snowflake / Calcite-family engines). The required rewrite is exactly the inner-CTE-then-outer-aggregate pattern shown.
- The responder **proactively explained the nested-aggregate error** AND gave the canonical two-step rewrite — exactly the teaching moment this class of question is designed to surface.
- Cleanest possible answer for this pattern.

---

## Teacher feedback

**No corrective action required for iter663.** Second consecutive perfect-score iteration (5.000 after iter662's 5.000). All four answers:
1. Use valid Trino 467 dialect (verified against trino.io/docs/467).
2. Compose mechanically from documented primitives (r23:77 multi-COUNT-DISTINCT, r23:636 first-AND-last MIN/MAX, r23:1187 date_diff canonical, r23:1643 HAVING-aggregate rule, r08:12/52-67/111 star-schema dim-JOIN, r07:999 two-level CTE-then-outer-aggregate).
3. Volunteer relevant safety-belt callouts unprompted (LEFT JOIN NULL-skip + COALESCE in Q2; pass-earlier-first in Q3; nested-aggregate error explanation in Q4).

### Recommended iter664 directive: DEFAULT NO-OP / DURABILITY-BREADTH

- ZERO per-Q below floor; perfect 5.000.
- The iter663 6-fresh-area pre-probe analysis (state.json notes) accurately predicted all four routes as FINDABLE — confirmed correct on probe.
- Suggested fresh-area probes for iter664 (synthesizable from primitives, DO NOT pre-probe):
  - (a) Two-level macro-average sibling: median per-group then average across groups (forces `approx_percentile` per-group in CTE, AVG outer; tests two-level CTE pattern recall with different inner aggregate).
  - (b) Multi-key dim-JOIN with conversion + filter: `WHERE order_date >= ...` pushed down through the JOIN (tests JOIN + filter + SUM composition).
  - (c) HAVING-on-aggregate-expression direct form for Q3-class question (re-probe whether responder picks HAVING vs CTE based on phrasing — both correct, but tests dialect-flexibility).
  - (d) Nested-aggregate error re-probe with `MAX(COUNT(*))` framing (different outer aggregate to confirm pattern recognition, not just `AVG(COUNT(DISTINCT))` memorization).
  - (e) Bulletproofed federation predicate-pushdown re-probe IF opted-in (ZERO probe streak now 19 iterations — 4.49944/310 federation row at thin margin).

### DO NOT (per existing locks):
- Touch r22 §13.x federation guardrails (4.49944/310 thin, ZERO probe 19-iter streak).
- Re-edit r07:1351 ORDER-BY-in-grouped-output FIX-A block (proven durable on 3 entity framings iter661-662).
- Rewrite iter534-662 locks.
- Add `::`-casts (iter571 PIN), QUALIFY, RLIKE (iter623 ban), PERCENTILE_CONT/MEDIAN (iter611 ban), EXTRACT(EPOCH) (iter562 ban).
- Fabricate `dayname()` / `initcap()` (iter659 inoculation HELD).
- DISTINCT-ON Postgres-leak (iter634 ban).
- Bump training/state.json (per directive — teacher already set to 663).

### Topic average updates (iter663):
- **Analytical query patterns on Iceberg+Trino / r07** — Q1 (date_trunc + 2-key GROUP BY + COUNT(DISTINCT) per-group) durability +0.25; Q3 (first-AND-last CTE + date_diff outer WHERE) durability +0.25; Q4 (two-level CTE-then-outer-AVG + nested-aggregate explanation) durability +0.5 BIG win — net UP.
- **SQL query best practices for OLAP / r23** — Q2 (fact x dim JOIN SUM(amount*rate) + LEFT JOIN NULL-skip + COALESCE safety belt) durability +0.25; Q4 nested-aggregate error proactive callout durability +0.25 — net UP.
- **Schema design — Lakehouse fact/dim (r08)** — Q2 confirms star-schema dim-JOIN primitive at r08:12/52-67/111 routes correctly for currency-rate conversion variant — durability +0.25.
- **Federation NOT probed** — 4.49944/310 row UNCHANGED (consecutive non-probe count +1 → 313; ZERO probe iter645-663 streak = 19 iterations).

### Trajectory iter651→663
4.9375 → 4.96875 → 4.6875 → 5.00 → 4.00 → 4.625 → 4.375 → 5.00 → 4.875 → 4.21875 → 4.875 → 5.000 → **5.000** — second consecutive perfect score; bedrock SQL-pattern coverage (multi-COUNT-DISTINCT-per-group, star-schema-dim-JOIN, MIN/MAX-per-group + date_diff, two-level CTE-then-outer-aggregate with nested-aggregate explanation) all durably locked.

## OVERALL: 5.000 STRONG PASS — second consecutive perfect-score iteration; ALL FOUR Q's perfect 5.0; iter664 recommended DEFAULT NO-OP / durability-breadth continuation.
