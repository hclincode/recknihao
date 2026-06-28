# Iter1200 Judge Feedback

**Overall: 4.625 / 5.0 — PASS. Q1 PRIORITY WATCH CLOSES. Q4 soft WATCH CLOSES on the lead BUT with a broken-secondary slip (timestamp-minus-timestamp).** Two clean 5.0s (Q1 format_version dialect canonical, Q3 dbt hard_deletes), one 4.5 (Q2 two-level-aggregation pattern correct but inner CTE column reference sloppy), one 4.0 (Q4 lead correct but age example uses `timestamp - timestamp` which Trino does NOT support per `-` operator). Q4 slip is a per-instance responder lapse, NOT resource-sourced — r27 §4.2 L771 explicitly bans `dt - SYSDATE`-style timestamp subtraction and routes to `date_diff`. No FIX-A. Carry-forward watches NOT exercised this iter: soft iter1197 generate_schema_name macro; light-monitor iter1199 r17 position-delete adjacent.

---

## Q1 (PRIORITY WATCH) — Trino 467 `format_version` upgrade after Hive→Iceberg migrate

**Score: 5 / 5 / 5 / 5 = 5.0**

### What the responder said
- Trino form: `ALTER TABLE iceberg.analytics.accounts SET PROPERTIES format_version = 2;`
- Three load-bearing dialect distinctions correctly named:
  1. **`SET PROPERTIES`** (Trino), NOT `SET TBLPROPERTIES` (Spark/Hive).
  2. **Underscored `format_version`** (Trino), NOT hyphenated `'format-version'` (Spark/Iceberg-native).
  3. **Unquoted integer `2`** (Trino), NOT quoted string `'2'` (Spark).
- Routing: migrated tables default to v1 (no row-level deletes → MERGE / dbt incremental MERGE fails); new Trino-created tables already default to v2; v1→v2 bump enables MERGE.

### Verification (primary sources)
- [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html) — verbatim ALTER form: `ALTER TABLE table_name SET PROPERTIES format_version = 2;` (unquoted name, unquoted integer; CONFIRMED via WebFetch this iter).
- The Spark/Iceberg-native form `ALTER TABLE ... SET TBLPROPERTIES ('format-version'='2')` is the recognized Iceberg PROCEDURE / Spark Iceberg connector form and is documented by Iceberg, not Trino. Pasting Spark's hyphenated quoted form into Trino yields a parse / unknown-property error — the responder's framing is correct.
- r21 §137 / §159 already carries this canonical with the exact same dialect contrast — responder cleanly reached the right card.

### PRIORITY WATCH STATUS: **CLOSES** (1st re-probe)

Watch label: `iter1196 r21 format_version SET PROPERTIES` — the iter1196 r21 §137-159 reconcile (Trino-form FIRST, Spark-form clearly defanged as wrong-engine) lands on first re-probe. All three dialect axes (statement, property name, value type) verbalized by the responder.

### Verdict
Pin-perfect canonical for the v1→v2 post-migrate upgrade. No defect, no FIX-A.

---

## Q2 — Two-level aggregation (busy-hour heatmap: average per day, NOT total)

**Score: 4.5 / 5 / 4 / 4.5 = 4.5**

### What the responder said
```sql
WITH tickets_per_cell AS (
  SELECT event_date,
         day_of_week(event_date) AS dow,
         hour(created_at)         AS hour_of_day,
         COUNT(*)                 AS ticket_count
  FROM tickets
  WHERE created_at >= current_timestamp - INTERVAL '90' DAY
  GROUP BY event_date, day_of_week(event_date), hour(created_at)
)
SELECT dow, hour_of_day, CAST(AVG(ticket_count) AS BIGINT) AS avg_tickets_per_day
FROM tickets_per_cell
GROUP BY dow, hour_of_day
ORDER BY ...
```

The **PATTERN** is correct: inner GROUP BY produces one row per (date, dow, hour) tuple with that day's count; outer GROUP BY averages across the ~13 occurrences of each (dow, hour) cell over the 90-day window. This is the canonical two-level fix for "AVG per day" vs "raw COUNT" heatmaps.

### Verification (primary sources)
- [trino.io/docs/current/functions/datetime.html](https://trino.io/docs/current/functions/datetime.html) (verified via WebFetch): `day_of_week(x)` returns ISO day 1=Monday…7=Sunday; `hour(x)` returns 0…23. Both accept date/timestamp/timestamp-with-tz.
- Two-level aggregation pattern is standard Trino: inner pre-aggregate → outer aggregate over inner results. Single-pass `AVG(COUNT(*) OVER (...))` does NOT exist (nested aggregates illegal); CTE form is the canonical fix.

### Accuracy nit (-0.5 Acc, -1 App)
**`event_date` is ungrounded.** The inner SELECT references `event_date` and groups by `event_date`, but the source table (per the engineer's framing) has only `created_at` TIMESTAMP. As written the query throws `Column 'event_date' cannot be resolved`. The intended form is one of:
```sql
SELECT CAST(created_at AS DATE) AS event_date, ...
GROUP BY CAST(created_at AS DATE), day_of_week(CAST(created_at AS DATE)), hour(created_at)
```
or
```sql
SELECT date_trunc('day', created_at) AS event_date, ...
GROUP BY date_trunc('day', created_at), day_of_week(date_trunc('day', created_at)), hour(created_at)
```

Per the eval directive, the load-bearing thing is the **PATTERN** (this two-level-average heatmap was historically a synthesis-ceiling FAIL — see `feedback_synthesis_ceiling_stop_churning.md` family). The responder reaches the pattern cleanly, which is the recall win. Engineer copy-pastes, hits the missing-column error, infers `event_date` is meant to be derived, and adds the CAST in ~10 seconds. Not catastrophic, but the SQL as printed is not directly runnable.

### Verdict
Pattern-level recall is the historically-hard part and the responder lands it. The `event_date` derivation slip is a per-instance copy-trap, NOT a resource defect — r07 two-level-aggregate canonicals consistently show explicit `CAST(... AS DATE)` derivations. Recall ceiling, NO FIX-A. Per `feedback_responder_broken_secondary_alternative.md` adjacent family (broken-secondary in-line in a otherwise-correct primary block).

---

## Q3 — dbt snapshots: detecting hard deletes via `hard_deletes` config

**Score: 5 / 5 / 5 / 5 = 5.0**

### What the responder said
- Config: `hard_deletes='invalidate'` — when a row disappears from source, dbt stamps `dbt_valid_to = run time` so the row no longer matches `WHERE dbt_valid_to IS NULL` (no longer looks "current").
- Alternative: `hard_deletes='new_record'` inserts a marker row with `dbt_is_deleted=True` (explicit deletion audit trail).
- Shows the snapshot config block with `strategy='timestamp'`, `updated_at`, `unique_key`.

### Verification (primary sources)
- [docs.getdbt.com/reference/resource-configs/hard-deletes](https://docs.getdbt.com/reference/resource-configs/hard-deletes) (verified via WebFetch): three valid values
  - `ignore` (default) — no action on disappeared rows; the engineer's stuck-as-current symptom.
  - `invalidate` — "Invalidates the deleted records by setting `dbt_valid_to` to the current time" — matches responder's framing verbatim.
  - `new_record` — "Tracks deleted records as new rows using the `dbt_is_deleted` meta field" — matches responder's framing.
- Introduced in **dbt 1.9** (or "Latest" track). The legacy field name is `invalidate_hard_deletes=true` for pre-1.9; responder doesn't mention the legacy name but didn't have to — engineer is on a current dbt + dbt-trino setup (production stack).
- The marker row example from docs:
  ```
  id | dbt_is_deleted | dbt_valid_from | dbt_valid_to
  1  | True           | 2024-05-20...  | 2024-06-03...
  1  | False          | 2024-06-03...  | NULL
  ```
  confirms the `new_record` insert-on-delete semantics the responder described.

### Verdict
Pin-perfect dbt 1.9+ canonical. Engineer copies the `hard_deletes='invalidate'` line into the snapshot config and the missing-validity-window bug is fixed. No defect, no FIX-A.

---

## Q4 (SOFT WATCH) — Trino SYSDATE equivalent (no-TZ "now")

**Score: 3.5 / 4.5 / 3.5 / 4.5 = 4.0**

### What the responder said
- **Lead (correct):** "The Trino function is `localtimestamp`" — returns `TIMESTAMP` (no TZ) = session local wall clock, matches Oracle SYSDATE.
- **Lead example (correct):** `WHERE event_time > localtimestamp - INTERVAL '1' DAY` — `TIMESTAMP - INTERVAL` is supported in Trino.
- **Lead disambiguation (correct):** `current_timestamp` returns TIMESTAMP WITH TIME ZONE.
- **Broken secondary:** "For age: `(localtimestamp - created_at) AS age_since_creation`" — **INCORRECT in Trino 467**.
- Side note: AT TIME ZONE to strip tz (acceptable framing).

### Verification (primary sources)

**Lead verified (WATCH CLOSES):**
- [trino.io/docs/current/functions/datetime.html](https://trino.io/docs/current/functions/datetime.html) (WebFetch this iter): "`localtimestamp` — Returns the current timestamp as of the start of the query, with 3 digits of subsecond precision." Returns `TIMESTAMP` without time zone (vs. `current_timestamp` → `TIMESTAMP WITH TIME ZONE`). Matches Oracle SYSDATE no-TZ semantics.
- r27 §4.2-NOW (L815-L817) carries this verbatim: `localtimestamp` → `TIMESTAMP` (no TZ) — session-local wall clock. Responder reached the right card.

**Broken secondary — `TIMESTAMP - TIMESTAMP` with `-` operator is NOT supported in Trino:**
- [trino.io/docs/current/functions/datetime.html](https://trino.io/docs/current/functions/datetime.html) operators table (WebFetch verified): only `timestamp - interval` is listed; `timestamp - timestamp` is NOT a supported binary operator. The example `timestamp '2012-08-08 01:00' - interval '29' hour` is the only subtraction form documented.
- **`(localtimestamp - created_at)` throws** in Trino — the engine has no rewrite for raw timestamp-minus-timestamp into INTERVAL DAY TO SECOND (that's a Postgres/Oracle interval-arithmetic semantic; Postgres does it natively, Trino does not).
- The canonical Trino form is `date_diff('day', created_at, localtimestamp)` (returns bigint days) or another unit (`'second'`, `'millisecond'`) per use case.

### Source-anchor check — RESPONDER SLIP, NOT RESOURCE-SOURCED

`grep -n` on `resources/27-oracle-plsql-to-dbt-trino.md`:
- **L771 explicitly bans it:** `| dt - SYSDATE (interval) | date_diff('day', current_timestamp, dt) returns bigint | Trino doesn't subtract timestamps to get a bare number; use date_diff. |`

The resource carries the exact translation row that would have prevented this slip. The responder reached the `localtimestamp` card for the lead but produced the broken `timestamp - timestamp` example independently. Per `feedback_responder_broken_secondary_alternative.md` family — recurring pattern of a correct lead followed by an in-line broken "for completeness" example. **Per-instance one-off, NO resource fix.**

### SOFT WATCH STATUS: **CLOSES on the lead** (1st re-probe)

Watch label: `soft iter1197 localtimestamp SYSDATE`. The primary question was "Trino function for current date+time WITHOUT tz (like SYSDATE)?" — responder named `localtimestamp` directly with correct return type, contrasts with `current_timestamp`. Watch closes on the lead. The age-example slip is a separate broken-secondary that does NOT reopen the watch but earns a -1 on Acc and -1.5 on App because the engineer copies the broken form and hits a runtime / type error.

### Score breakdown
- **Accuracy 3.5:** Lead correct; broken `timestamp - timestamp` example is a factual error in Trino.
- **Beginner clarity 4.5:** Clear contrast `localtimestamp` vs `current_timestamp`; jargon explained.
- **Practical applicability 3.5:** Engineer pastes the age example, hits parse / type error, re-derives via `date_diff`. The lead-only piece is directly actionable; the age piece is not.
- **Completeness 4.5:** Covers the lead, the contrast, the WHERE form, AT TIME ZONE strip; broken age form pulls Compl from 5 to 4.5.

### Verdict
Lead is the answer to the question as asked and it lands. The age example is the recurring `feedback_responder_broken_secondary_alternative.md` pattern — secondary form unsolicited, broken, ignored by skilled engineers but a copy-trap for new ones. **NO resource fix** (r27 §4.2 L771 already carries the exact ban); responder slip only. Re-probe in 3-6 iters under a structurally similar framing ("age in days from created_at vs SYSDATE") to confirm the slip is per-instance and not recurring.

---

## Cross-cutting observations

- **Two clean 5.0s on two distinct dialect canonicals** (Q1 Trino format_version, Q3 dbt 1.9+ hard_deletes). Both reached the right card with all dialect distinctions verbalized.
- **Q2 synthesis-ceiling stays closed** — the two-level-aggregation pattern (historically a FAIL family per `feedback_synthesis_ceiling_stop_churning.md`) was reached cleanly. Only the column-derivation in the inner CTE was sloppy; the load-bearing pattern is correct.
- **Q4 broken-secondary recurs** — `feedback_responder_broken_secondary_alternative.md` family active again. 9th-or-10th instance in this rolling pattern: correct lead + uninvited broken alternative. Continue per-instance scoring, do NOT churn resources (no single resource fix addresses responder padding).
- **No imported-prior slips this iter.** No over-warning folklore.
- **No FIX-A this iter.** All four answers either pin-perfect (Q1, Q3) or recoverable recall-ceiling/copy-trap (Q2 event_date, Q4 timestamp-minus-timestamp).

### Carry-forward watches
- **CLOSED THIS ITER:** `iter1196 r21 format_version SET PROPERTIES` (Q1, 1st re-probe). `soft iter1197 localtimestamp SYSDATE` (Q4 lead, 1st re-probe).
- **NEW LIGHT-MONITOR:** Q4 broken-secondary `localtimestamp - created_at` — responder slip, NOT resource defect; r27 §4.2 L771 already bans it. Re-probe in 3-6 iters under similar framing to confirm per-instance.
- **NOT EXERCISED:** soft `iter1197 generate_schema_name` macro surface. Light-monitor `iter1199 r17 position-delete adjacent` (Spark `rewrite_position_delete_files` vs Trino optimize tradeoff framing).

### Topic score updates
| Topic | Prev avg / N | This iter Q-score | New avg / N |
|---|---|---|---|
| Iceberg table maintenance | 4.4350 / 212 | Q1 5.0 | 4.4377 / 213 |
| Analytical query patterns on Iceberg+Trino | 4.5295 / 146 | Q2 4.5 | 4.5293 / 147 |
| dbt snapshots SCD2 | 4.2294 / 21 | Q3 5.0 | 4.2644 / 22 |
| Oracle PL/SQL → dbt + Trino | 4.4737 / 161 | Q4 4.0 | 4.4708 / 162 |

All four topics remain PASSED with healthy margins. No topic flips status. dbt snapshots SCD2 stays thinnest (4.2644).
