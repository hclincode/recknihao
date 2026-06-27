# Iteration 1177 — Judge Feedback

## Overall verdict: STRONG PASS NO-OP — all 3 watches CLOSE on first re-probe

- Q1: 5.00 — categorical-dim-spine static VALUES + LEFT JOIN + COALESCE, CONFIDENT (no bail) — `r07 categorical-dim-spine FIX-A iter1176` **CLOSES**
- Q2: 5.00 — quarter label built via EXTRACT(QUARTER FROM ts) + concat / format('Q%d %d', ...), NO Joda-Q fabrication — `r07/r27 Joda-Q quarter-pattern fabrication iter1176` **CLOSES**
- Q3: 4.625 — dbt threads vs Trino resource-group hardConcurrencyLimit, run_results.json slow-model id, REACHED — `r28 dbt-parallelism FIX-A iter1176` **CLOSES** (minor: did not name dedicated dbt resource group despite "shared cluster, other teams" framing)
- Q4: 4.9375 — UNNEST on MAP → two-alias key/value, CROSS JOIN form + LEFT JOIN ON TRUE for NULL-map preservation, pin-perfect

Overall iteration average: **4.891** — strong pass.

---

## Q1 — Status board, 'waiting' has zero rows, must still show 5

**Score: 5.00** (Acc 5 / Clar 5 / App 5 / Compl 5)

**WATCH RE-PROBE — `r07 categorical-dim-spine FIX-A iter1176` CLOSES on first re-probe.**

Responder gave the canonical static-VALUES + LEFT JOIN + COALESCE answer with full confidence (NO bail prefix like iter1176 had):

```sql
WITH all_statuses(status) AS (
  VALUES ('open'),('in_progress'),('waiting'),('resolved'),('closed')
),
status_counts AS (
  SELECT status, COUNT(*) AS ticket_count
  FROM support_tickets
  WHERE created_at >= ...
  GROUP BY status
)
SELECT s.status, COALESCE(c.ticket_count, 0) AS ticket_count
FROM all_statuses s
LEFT JOIN status_counts c ON c.status = s.status
ORDER BY s.status;
```

- VALUES table source verified valid Trino 467 per [trino.io/docs/467/sql/values.html](https://trino.io/docs/467/sql/values.html).
- LEFT JOIN + COALESCE(c.ticket_count, 0) correctly preserves 'waiting' as 0 even when GROUP BY drops it.
- Framing "categorical sibling of date-spine zero-fill" demonstrates the engineer-mental-model anchor we wanted.
- Confidence shift from iter1176 ("I don't have complete information...") to direct answer at iter1177 = exactly the findability improvement the iter1176 LIGHT FIX-A targeted.

Cites r07. **Watch CLOSES**, no churn.

---

## Q2 — Quarterly chart labels like "Q2 2025" from a timestamp

**Score: 5.00** (Acc 5 / Clar 5 / App 5 / Compl 5)

**WATCH RE-PROBE — `r07/r27 Joda-Q quarter-pattern fabrication iter1176` CLOSES on first re-probe.**

Responder gave TWO correct forms, NEITHER using a fabricated Joda `Q` pattern letter:

```sql
-- Form 1: concat with CAST
concat('Q', CAST(EXTRACT(QUARTER FROM ts) AS varchar), ' ',
            CAST(EXTRACT(YEAR FROM ts) AS varchar))
-- 'Q2 2025'

-- Form 2: format() printf-style (responder's preferred)
format('Q%d %d', EXTRACT(QUARTER FROM ts), EXTRACT(YEAR FROM ts))
-- 'Q2 2025'
```

Verifications:
- `EXTRACT(QUARTER FROM ts)` is valid Trino 467: docs table lists `QUARTER` field returning quarter() (1–4), per [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html) Convenience extraction functions section.
- `quarter(ts) → bigint` also exists ("Returns the quarter of the year from x. The value ranges from 1 to 4") — equivalent function form, responder named both.
- `format(format, args...) → varchar` uses Java Formatter syntax (`%d`, `%s`, `%f`) per [trino.io/docs/467/functions/conversion.html](https://trino.io/docs/467/functions/conversion.html). Example from docs: `format('%03d', 8) → '008'`.
- No Joda `Q` pattern letter appears anywhere in the answer. The iter1176 fabrication (`'yyyy'Q'Q'`) is explicitly NOT recurring.

Cites r23. **Watch CLOSES**, no churn.

---

## Q3 — 90-min nightly dbt run, shared cluster, find slow models

**Score: 4.625** (Acc 5 / Clar 4.5 / App 4.5 / Compl 4.5)

**WATCH RE-PROBE — `r28 dbt-parallelism FIX-A iter1176` CLOSES on first re-probe (with minor shave).**

Responder reached the iter1176 r28 §6.5 canonical without bailing:

- (a) **dbt threads** named correctly — `profiles.yml` `threads: 4` default (per [docs.getdbt.com/docs/running-a-dbt-project/using-threads](https://docs.getdbt.com/docs/running-a-dbt-project/using-threads); doc actually says "We recommend setting this to 4 to start with"; dbt-trino adapter init templates default to 4; treat the 4 as recommended-start not strict default — Acc nit, not load-bearing).
- (b) **Each thread = one Trino query** at a time — matches dbt docs "a thread is an open connection to your data warehouse".
- (c) **Trino resource-group `hardConcurrencyLimit`** correctly named as the real ceiling — verified at [trino.io/docs/467/admin/resource-groups.html](https://trino.io/docs/467/admin/resource-groups.html) "maximum number of running queries; new queries become queued" once reached.
- (d) **Safe sizing** — start threads:4, monitor resource-group queue depth + memory, raise to 8 if underutilized but check hardConcurrencyLimit cap. Practical guidance.
- (e) **Slow-model identification** — `target/run_results.json` per-node `execution_time` + jq sort top 15; focus on full-refresh table / wide-join models. Matches the iter1176 spec.

**Minor shave on shared-cluster concern (Compl/App -0.5)**: question explicitly framed *"worried about overloading the SHARED Trino cluster (other teams)"* — the load-bearing organizational lever for protecting other teams is **isolating dbt in its own Trino resource group** with a fixed hardConcurrencyLimit cap (so even if dbt over-runs threads, it can only burn its own quota slots, not crowd out other teams' queries). Responder named hardConcurrencyLimit as a ceiling but did not say "give dbt its own resource group" — engineer following the answer literally would still share the default resource group with other teams. The iter1176 r28 §6.5 spec called this out as a card recommendation; landing it would have made this a clean 5.0.

Cites r28. **Watch CLOSES**, recall ceiling on the team-isolation sub-point.

---

## Q4 — Explode a MAP column into one row per key-value pair

**Score: 4.9375** (Acc 5 / Clar 5 / App 5 / Compl 4.75)

Pin-perfect UNNEST-on-MAP canonical:

```sql
SELECT property_name, COUNT(*) AS event_count
FROM events
CROSS JOIN UNNEST(properties) AS t(property_name, property_value)
GROUP BY property_name;
```

Verifications against [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html) UNNEST section:
- UNNEST on a MAP expands to TWO columns (key, value) with TWO aliases — docs verbatim example:
  ```sql
  SELECT * FROM UNNEST(
    map_from_entries(ARRAY[('SQL',1974),('Java',1995)])
  ) AS t(language, first_appeared_year);
  ```
- Responder's `CROSS JOIN UNNEST(properties) AS t(property_name, property_value)` is exactly that shape with `t(key_alias, value_alias)` — correct.
- `LEFT JOIN UNNEST(...) ON TRUE` for NULL/empty-map row preservation correctly named — docs verbatim: "LEFT JOIN is preferable in order to avoid losing the row containing the array/map field in question when referenced columns from relations on the left side of the join can be empty or have NULL values" + "in case of using LEFT JOIN the only condition supported by the current implementation is ON TRUE".
- Correctly noted no `map_entries()` pre-step needed — UNNEST handles MAP directly.

**Minor completeness shave (-0.25 Compl)**: did not name `map_entries(properties)` ROW-based alternative (returns `array(row(k,v))` which can be UNNESTed and accessed via `.key/.value`), useful when downstream needs a single ROW column instead of two split columns. Recall ceiling, not a defect — direct UNNEST(map) is the cleaner canonical for the engineer's GROUP-BY-property-name use case.

Cites r07.

---

## Rubric score updates

- **Analytical query patterns on Iceberg+Trino**: Q1 (5.0) + Q4 (4.9375) — (577.0636 + 5.0 + 4.9375)/129 = **4.5504/129** PASSED (+0.0066, margin +1.0504).
- **SQL query best practices for OLAP**: Q2 (5.0) — (1152.202 + 5.0)/253 = **4.5739/253** PASSED (+0.0016, margin +1.0739).
- **Improving complex SQL performance on Trino with dbt**: Q3 (4.625) — (127.7141 + 4.625)/29 = **4.5634/29** PASSED (+0.0022, margin +1.0634, recovers from iter1176 -0.0671 dip after FIX-A reached).

All three watches **CLOSED on first re-probe**. Pattern of "first NO-OP/LIGHT-FIX-A → CLOSE on next re-probe" continues (12+ consecutive watches in this mode through iter1176; iter1177 adds 3 more).

## Recommended teacher action

**NO-OP this iteration.** No resource defects surfaced. All three iter1176 FIX-A cards (r07 categorical-dim-spine, r07/r27 Joda-Q defang, r28 §6.5 dbt-parallelism) are reaching correctly across novel domain framings (ticket statuses vs account tiers; Q2-2025 chart label vs fiscal label; 90-min nightly vs 2-hour run).

Minor watch (do NOT add a card; just probe again):
- **r28 dbt-resource-group-isolation recall**: Q3 reached the safe-sizing + slow-model-id canonical but did not connect "shared cluster" → "give dbt its own resource group". On next dbt+parallelism re-probe, frame the question with explicit "we share a single resource group with marketing's BI dashboards" to test whether the resource-group-isolation recommendation lands. If recurs as a miss → consider light additive sub-point to r28 §6.5; if lands on next probe → recall ceiling, no fix.

Continue breadth probing on weaker rows (Query performance basics 4.1869, dbt snapshots SCD2 4.1549, Storage tiering 4.1779 — thinnest-3 band).
