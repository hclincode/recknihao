# Iter570 Judge Feedback

**Phase**: extended. **State.json**: NOT bumped (teacher already set iteration=570).

---

## Q1 — forward-fill + date-spine COMPOSITION re-probe (PRIMARY iter570 fix verification)

**Question**: Row for EVERY hour for EVERY server incl. hours with no log, each showing last-known CPU state. Build end to end in Trino.

**Answer summary**: CTE chain `bounds → hour_spine (sequence+UNNEST) → servers (DISTINCT) → dense_grid (CROSS JOIN) → sparse_logs → final SELECT`. `sparse_logs` precomputes `LAST_VALUE(cpu_percent) OVER (PARTITION BY server_id ORDER BY logged_at ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS latest_cpu`. Final SELECT uses `COALESCE(l.latest_cpu, LAST_VALUE(l.latest_cpu) IGNORE NULLS OVER (PARTITION BY g.server_id ORDER BY g.ts ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW))`.

### Verification

**Point (i) — IGNORE NULLS placement (iter569 syntax fix)**: CONFIRMED FIXED.
- The grammar rule from PR #1244 (`SqlBase.g4`): `functionCall: name '(' args ... ')' nullTreatment? filter? over?`. The clause sits AFTER `')'` and BEFORE `OVER`. The answer's form `LAST_VALUE(l.latest_cpu) IGNORE NULLS OVER (...)` matches this. Iter569's `LAST_VALUE(... IGNORE NULLS)` parse error is GONE.
- Source: Trino PR #1244 grammar + Trino 467 window-functions doc ("If IGNORE NULLS is specified, all rows where x is null are excluded from the calculation").

**Point (ii) — final forward-fill frame**: CONFIRMED CORRECT.
- The outer window `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` is a strict look-BACK frame. Applied AFTER the LEFT JOIN, the window sees the post-join NULL gaps in `l.latest_cpu` and IGNORE NULLS skips them, taking the last non-null value at-or-before the current hour. This matches the iter570 COMBINED CANONICAL Step 3 recipe.

**Point (iii) — pre-join `sparse_logs` UNBOUNDED FOLLOWING window (NEW DEFECT)**: CONFIRMED SEMANTICALLY WRONG.
- The frame `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` with PARTITION BY `server_id` ORDER BY `logged_at` covers the ENTIRE partition. By LAST_VALUE semantics over a fully unbounded frame, `LAST_VALUE(cpu_percent)` returns the cpu_percent of the chronologically LAST row in the partition — the SAME global-latest value for every row in `sparse_logs` for that server.
- Trino 467 window-functions doc: "`last_value(x)` Returns the last value of the window." The "window" here is the active frame; for `ROWS UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` the frame is the whole partition. (Frame-defaults aside: Trino's default frame is `RANGE UNBOUNDED PRECEDING` = `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` — not relevant here because the frame is explicit, but reinforces that frame choice drives the result.)
- Consequence: `latest_cpu` is a CONSTANT (the global-last cpu) on every matched grid row. The final SELECT then "forward-fills" a constant — every hour (data row or gap) shows the global-latest CPU, not the last-known cpu as-of-that-hour. Semantically WRONG result on every row. This is exactly the "future-fill anti-pattern" the iter570 COMBINED CANONICAL "DO-NOT-WRITE" block warns against — re-introduced in a different place (a pre-join CTE instead of the outer SELECT).

**Point (iv) — fanout**: CONFIRMED. `sparse_logs` is NOT aggregated to one row per (server_id, hour). If a server logs N times in an hour, the LEFT JOIN on `l.hour = g.ts` produces N duplicate rows for that (server, hour). The teacher's canonical Step 1/2 implicitly assumes one-row-per-(entity, bucket) but does not say so explicitly.

### Corrected minimal composition

```sql
WITH bounds AS (
  SELECT min(date_trunc('hour', logged_at)) AS lo,
         max(date_trunc('hour', logged_at)) AS hi
  FROM server_metrics
  WHERE logged_at >= current_timestamp - INTERVAL '7' DAY
),
hour_spine AS (
  SELECT t AS hour
  FROM bounds, UNNEST(sequence(lo, hi, INTERVAL '1' HOUR)) AS u(t)
),
servers AS (
  SELECT DISTINCT server_id FROM server_metrics
  WHERE logged_at >= current_timestamp - INTERVAL '7' DAY
),
dense_grid AS (
  SELECT s.server_id, h.hour
  FROM servers s CROSS JOIN hour_spine h
),
-- Step 2 prep: ONE row per (server, hour) from the raw facts
hourly_obs AS (
  SELECT server_id,
         date_trunc('hour', logged_at) AS hour,
         max_by(cpu_percent, logged_at) AS cpu_at_hour   -- last reading inside the hour
  FROM server_metrics
  WHERE logged_at >= current_timestamp - INTERVAL '7' DAY
  GROUP BY server_id, date_trunc('hour', logged_at)
)
SELECT g.server_id,
       g.hour,
       COALESCE(
         o.cpu_at_hour,
         LAST_VALUE(o.cpu_at_hour) IGNORE NULLS OVER (
           PARTITION BY g.server_id
           ORDER BY g.hour
           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
         )
       ) AS cpu_state
FROM dense_grid g
LEFT JOIN hourly_obs o
  ON o.server_id = g.server_id AND o.hour = g.hour
ORDER BY g.server_id, g.hour;
```

Key differences vs the responder:
- NO pre-join LAST_VALUE window — the join column `cpu_at_hour` is a real per-hour reading that is NULL on gap rows.
- Aggregation `GROUP BY server_id, date_trunc('hour', logged_at)` with `max_by(cpu_percent, logged_at)` collapses multiple logs in one hour to one row (no fanout).
- The look-back IGNORE NULLS window runs ONLY in the final SELECT over post-join rows — exactly what the iter570 COMBINED CANONICAL says.

**Scores**: Accuracy 2 / Completeness 3 / Clarity 3 / Actionability 2. **Avg 2.50**.
*Reasoning*: syntax/final-frame correct (partial credit), but the pre-join UNBOUNDED FOLLOWING window makes the result semantically wrong on EVERY row, and the LEFT JOIN can fanout. An engineer running this verbatim gets a wrong dashboard.

---

## Q2 — no-unique-column tiebreaker re-probe (FIX B findability)

**Question**: Two rows tie on the sort timestamp picking latest per account; nothing unique to break the tie. Options?

**Answer summary**: (A) `max_by(status, (updated_at, event_id))` composite-tuple tiebreaker; (B) `arbitrary(status)` for "any tied row is fine"; (C) `ROW_NUMBER ... ORDER BY updated_at DESC, event_id DESC`; mention adding sequence_id / insertion_timestamp at ingest. No nested window in ORDER BY.

### Verification
- Tuple `(updated_at, event_id)` as `max_by` second arg: Trino ROW types are comparable when all fields are comparable, and Trino compares ROWs lexicographically (field-by-field). `max_by(x, y)` requires `y` to be orderable; an anonymous ROW of two orderable timestamp/bigint fields qualifies. VALID Trino 467.
- `arbitrary(status)`: VALID, documented Trino aggregate (returns an arbitrary non-null value).
- `ROW_NUMBER() OVER (PARTITION BY account_id ORDER BY updated_at DESC, event_id DESC)`: standard, deterministic when (updated_at, event_id) is unique.
- "Add a sequence_id / insertion_timestamp at ingest" is the canonical structural fix and is honest.
- Iter570 FIX B keyword anchor on r23 §3.1G is doing its job — the responder surfaced the right paragraph and didn't nest a window inside ORDER BY (iter568 ban respected).

**Scores**: Accuracy 5 / Completeness 5 / Clarity 4 / Actionability 5. **Avg 4.75**.

---

## Q3 — month-over-month self-join

**Question**: MoM revenue change per customer in one query; one table, one row per transaction.

**Answer summary**: `monthly_revenue` CTE `GROUP BY customer_id, date_trunc('month', tx_date)`, self LEFT-JOINed on `prev.month = date_add('month', -1, cur.month)`, `cur.revenue - COALESCE(prev.revenue,0)` for delta, `ROUND(100.0*(...)/NULLIF(COALESCE(prev.revenue,1),0),1)` pct, `WHERE cur.month >= date_add('month',-12,current_date)`.

### Verification
- `date_add(unit, value, timestamp)` signature: confirmed at trino.io/docs/current/functions/datetime.html — "Adds an interval value of type unit to timestamp." `date_add('month', -1, cur.month)` is valid Trino 467.
- Self-join MoM pattern is a standard, correct alternative to LAG (window LAG would be more idiomatic but the self-join is correct).
- NULLIF divide-by-zero guard: correctly placed. (Minor: `COALESCE(prev.revenue, 1)` then `NULLIF(..., 0)` — if prev.revenue is NULL the divisor becomes 1, sidestepping the 0; if 0 then NULLIF returns NULL. The "new customer with no prev" row produces a pct of `100.0 * cur.revenue / 1` which is a misleading "percent" — minor analytic-semantics nit, not a Trino dialect bug.)
- Type nuance: `date_trunc('month', tx_date)` returns the same type as input (date → date, timestamp → timestamp); comparing to `current_date` is type-compatible only if tx_date is DATE. If tx_date is TIMESTAMP, coercion handles it — minor nit.

**Scores**: Accuracy 4 / Completeness 4 / Clarity 4 / Actionability 4. **Avg 4.00**.

---

## Q4 — dbt incremental late-arriving data

**Question**: Hourly incremental model misses events that arrive late (occurred 2pm, landed 5pm). Handle without full reprocess.

**Answer summary**: Watermark on `updated_at` (landing time) NOT occurred_at; backfill/lookback `updated_at >= (SELECT COALESCE(MAX(updated_at),'1900-01-01'::timestamp) FROM {{ this }}) - INTERVAL '24' HOUR`; idempotent `unique_key='event_id'` with MERGE. Also a Spark snippet.

### Verification — CROSS-ENGINE DIALECT SLIP CONFIRMED
- `'1900-01-01'::timestamp` uses the PostgreSQL `::` cast operator. **Trino 467 does NOT support this syntax.**
- Verified at GitHub issue #23795 ("Cast operator `::`") and PR #25259: the PR to add `x::type` is OPEN, not merged. Opened March 2025, marked "stale-ignore", awaiting final review. **Not in Trino 467.** Trino cast syntax remains `CAST(x AS type)` / `TRY_CAST(x AS type)` — see trino.io/docs/current/language/types.html.
- Running this in a dbt-trino model compiles to a Trino query and **raises a parse error** on `::timestamp`. Cross-engine slip — PostgreSQL syntax leaked into a Trino-compiled model.
- The correct form is `CAST('1900-01-01' AS TIMESTAMP)` (or `TIMESTAMP '1900-01-01 00:00:00'` literal).
- The rest of the pattern (landing-time watermark, 24h lookback, `unique_key='event_id'` for MERGE idempotence) is correct and matches r28 incremental canonical.
- The Spark snippet is off-topic given the production stack is Trino+dbt for transformation (Spark is ingestion-only per prod_info.md), but it doesn't actively harm the answer.

**Scores**: Accuracy 3 / Completeness 4 / Clarity 4 / Actionability 3. **Avg 3.50**.
*Reasoning*: pattern is right, but the literal `'1900-01-01'::timestamp` is a parse error in Trino and the engineer would hit it on first dbt run.

---

## Overall

| Q | Acc | Comp | Clar | Act | Avg |
|---|---|---|---|---|---|
| Q1 forward-fill+spine | 2 | 3 | 3 | 2 | 2.50 |
| Q2 tie-break no-unique | 5 | 5 | 4 | 5 | 4.75 |
| Q3 MoM self-join | 4 | 4 | 4 | 4 | 4.00 |
| Q4 dbt late-arriving | 3 | 4 | 4 | 3 | 3.50 |

**Overall avg = (2.50 + 4.75 + 4.00 + 3.50) / 4 = 14.75 / 4 = 3.6875**

**Verdict: PASS** (≥3.5), but THIN. Q1 is failing — the iter570 PRIMARY fix is HALF-LANDED: the syntax bug is gone but the responder migrated the UNBOUNDED FOLLOWING anti-pattern from the outer SELECT into a pre-join CTE, which produces semantically wrong rows. Q4 has a clean cross-engine `::` slip.

---

## Iter571 directive (next teacher actions)

**FIX A (HIGH, PRIMARY — tighten r07 §4 COMBINED CANONICAL "DO-NOT-WRITE" so the spurious pre-join window is explicitly banned)**:
- In `resources/07-analytical-query-patterns.md` §4 COMBINED CANONICAL "DO-NOT-WRITE" block, ADD a new bullet alongside the existing "IGNORE NULLS inside paren" and "pre-join LAST_VALUE leaves gaps NULL" bullets:
  - "**Do NOT compute a LAST_VALUE window inside a pre-join CTE — even one with `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`. The forward-fill window MUST run AFTER the LEFT JOIN onto the dense grid, because the gap rows you need to fill don't exist until the join manufactures them. Special case: a pre-join `LAST_VALUE(metric) OVER (PARTITION BY entity ORDER BY ts ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)` is doubly wrong — over a fully unbounded frame it collapses to the partition-global LAST value (a constant per partition), so every matched grid row shows the entity's globally-latest metric, not the as-of-that-bucket reading.**"
- Include a paste-ready WRONG / RIGHT block exactly mirroring the responder's iter570 defect: WRONG `sparse_logs` CTE with the unbounded-following window then LEFT JOIN, vs RIGHT `hourly_obs` CTE with `GROUP BY entity, bucket` + `max_by(metric, ts)` to get one row per (entity, bucket) with NO pre-join window.

**FIX B (HIGH — Step 2 one-row-per-(entity, bucket) explicit aggregation)**:
- Same H3, Step 2 of the 3-step recipe currently says "LEFT JOIN sparse facts onto the dense grid" — clarify: "**Step 2a: first collapse the sparse facts to ONE row per (entity_id, bucket) via `GROUP BY entity_id, bucket` + `max_by(metric, ts)` (or your preferred per-bucket pick). Step 2b: LEFT JOIN that collapsed source onto the dense grid on (entity_id, bucket).**" This prevents the LEFT-JOIN fanout the responder produced. Add a one-line keyword anchor: "fanout from multiple events per bucket, dedupe per hour before forward-fill, one row per device per minute before LOCF".

**FIX C (HIGH — Trino `::` cast ban explicit, place in BOTH r23 §3.1 and r28 incremental canonical)**:
- In `resources/23-sql-best-practices-olap.md` §3.1 add a DO-NOT-WRITE entry: "**Do NOT use the PostgreSQL `x::type` cast shorthand in any Trino-compiled SQL (queries, dbt models, etc.). Trino 467 does NOT implement `::`; the feature request (issue #23795, PR #25259) is OPEN and unmerged as of mid-2025. Use `CAST(x AS type)` or `TRY_CAST(x AS type)`. WRONG: `'1900-01-01'::timestamp`. RIGHT: `CAST('1900-01-01' AS TIMESTAMP)` or `TIMESTAMP '1900-01-01 00:00:00'`. This is a common Postgres→Trino dialect slip in dbt incremental models.**" Include a keyword anchor: "Postgres double-colon cast Trino, ::timestamp Trino, dbt incremental cast literal, watermark default timestamp dbt-trino".
- In `resources/28-improving-complex-sql-trino-dbt.md` incremental canonical, audit any `::` literals and convert to CAST/typed-literal form; add a one-line warning in the incremental section: "**Watermark default: `COALESCE(MAX(updated_at), TIMESTAMP '1900-01-01 00:00:00')` — never `'1900-01-01'::timestamp` (Postgres syntax; not valid Trino 467).**"

**FIX D (LOW — Q3 MoM polish, optional)**:
- Add a `LAG`-based one-pass MoM variant alongside the self-join pattern in r07 (or wherever MoM lives) as the "idiomatic Trino" alternative; keep self-join as the explanatory baseline. Optional, non-blocking.

**LOCKS to preserve next iter** (do not regress): all iter534-570 locks per state.json notes; especially iter566 standalone forward-fill H3, iter569 IGNORE-NULLS-paren grammar DO-NOT-WRITE, iter568 tie-break-determinism + nested-window-ban, r07 §1a-§1a.5, r28 incremental + unique_key, r09 SCD2 4-default-cols + dbt-snapshot-as-of single-instant point-in-time, r22 §13.x federation guardrails (ZERO edits).

**Do not bump state.json this iter** — teacher already set iteration=570.
