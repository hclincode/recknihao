# Judge Feedback — Iter 491

**Phase**: extended (end-of-iteration feedback only)
**Overall**: 4.406 PASS (+0.906 above 3.5 floor)
**Federation**: NOT probed this iter — 4.49944/310 row HELD per iter472-491+ directive

---

## Headline

**$snapshots SPLIT-QUOTE REGRESSION FINALLY FIXED on the 4th probe.** The iter491 teacher escalation — placing a CRITICAL QUOTING RULE block at the very top of r17 before all other content — CONFIRMED LANDED. Responder correctly used `iceberg.analytics."events$snapshots"` (whole-token-one-quote-pair). REGRESSION STATUS: CLOSED after 3 recurrences (iter454 fix, iter489 recurred, iter490 recurred, iter491 FIXED).

**cardinality-on-scalar TYPE ERROR CONFIRMED FIXED.** Responder used `element_at(properties,'beta_flag') IS NOT NULL` and explicitly rejected both the bracket `[]` form (strict, errors on missing key) and `cardinality(element_at(...))` (type error: element_at returns scalar VARCHAR, cardinality requires array/map). iter490 teacher DO-NOT-WRITE in r09 CONFIRMED LANDED.

**Q3 Iceberg maintenance cadence CLEAN** — procedure names, parameter names, 7d floor, and optimize-before-expire ordering all correct.

**Q4 timezone predicate has TWO SEMANTIC IMPRECISIONS** — the core AT TIME ZONE advice is sound but the specific example predicates are wrong or misleading. A BETWEEN with bare strings is a type error; >= DATE coercion is semantically misleading for local-date intent.

---

## Per-question breakdown

### Q1 — $snapshots HISTORY RE-PROBE (4.75 STRONG PASS)

**CONFIRMED FIXED — $snapshots split-quote regression FINALLY RESOLVED.**

Responder produced:
```sql
SELECT snapshot_id, committed_at, operation, summary
FROM iceberg.analytics."events$snapshots"
ORDER BY committed_at DESC
```

This is the correct whole-token-one-quote-pair form. Explicitly stated the WHOLE `events$snapshots` token goes in ONE pair of double quotes, NOT `events."$snapshots"` (split-quote, column-not-found).

Confirmed correct per trino.io/docs/current/connector/iceberg.html (doc example: `SELECT * FROM "test_table$snapshots"`).

**Regression history closed**: iter454 (first fix) → iter489 (first recurrence) → iter490 (teacher re-fixed with LEADING CANONICAL diff section) → iter490 responder STILL wrong → iter491 teacher escalated to TOP-OF-FILE block → iter491 FIXED.

- Accuracy 5.0 | Clarity 4.5 | Actionability 5.0 | Completeness 4.5
- **Q1 avg: 4.75**
- Fab status: ZERO fabrications. REGRESSION CLOSED.

### Q2 — MAP key-existence RE-PROBE (4.75 STRONG PASS)

**CONFIRMED FIXED — cardinality type error DO-NOT-WRITE LANDED.**

Responder produced `WHERE element_at(properties, 'beta_flag') IS NOT NULL` and correctly:
- Stated `element_at` returns NULL for missing key (NULL-safe) per trino.io/docs/current/functions/map.html: `element_at(map(K,V), key) -> V`
- Stated NOT to use bracket `[]` (strict, raises error on missing key)
- Stated NOT to use `cardinality(element_at(properties,'beta_flag')) > 0` (type error: element_at on MAP(VARCHAR,VARCHAR) returns scalar VARCHAR; cardinality() accepts only array/map per trino.io docs)

All three claims confirmed against trino.io/docs/current/functions/map.html.

- Accuracy 5.0 | Clarity 4.5 | Actionability 5.0 | Completeness 4.5
- **Q2 avg: 4.75**
- Fab status: ZERO fabrications. TYPE ERROR FIX CONFIRMED LANDED.

### Q3 — Iceberg maintenance routine cadence (4.625 STRONG PASS)

**ALL CLAIMS CORRECT.**

- `EXECUTE optimize(file_size_threshold => '256MB')` nightly — procedure name and param name confirmed correct per trino.io/docs/current/connector/iceberg.html (doc uses `file_size_threshold => '128MB'`; 256MB is a valid larger operational choice, not an error)
- `EXECUTE expire_snapshots(retention_threshold => '7d')` weekly — confirmed correct
- `EXECUTE remove_orphan_files(retention_threshold => '7d')` weekly — confirmed correct
- 7d minimum retention floor — CONFIRMED: "The value for `retention_threshold` must be higher than or equal to `iceberg.expire-snapshots.min-retention`" (default 7d) per docs + WebSearch
- optimize-before-expire-before-orphan ordering — CORRECT: compact files first so orphan detection has cleaner picture
- Automation via CronJob/Airflow — appropriate for on-prem K8s prod setup (prod_info.md)

- Accuracy 4.5 | Clarity 4.5 | Actionability 5.0 | Completeness 4.5
- **Q3 avg: 4.625**
- Fab status: ZERO fabrications.

### Q4 — Postgres TIMESTAMP WITH TIME ZONE → Trino, off-by-hours (3.5 PASS)

**Core advice correct; TWO imprecisions in example predicates.**

CORRECT claims:
- AT TIME ZONE is real Trino syntax — CONFIRMED: `at_timezone(timestamp(p) with time zone, zone) → timestamp(p) with time zone` per trino.io/docs/current/functions/datetime.html
- AT TIME ZONE returns the same instant rendered in the given zone (same underlying UTC moment, different zone label) — CORRECT
- Don't rely on JVM `-Duser.timezone`; use AT TIME ZONE in the query — CORRECT and actionable

**IMPRECISION A (load-bearing SQL type error)**:
```sql
created_at AT TIME ZONE 'America/New_York' BETWEEN '2026-06-01' AND '2026-06-30'
```
The `BETWEEN` bounds are bare VARCHAR strings `'2026-06-01'` and `'2026-06-30'`. Trino has NO implicit VARCHAR → TIMESTAMP WITH TIME ZONE coercion. This is a SQL type error at analysis time — Trino will reject the query. Correct syntax requires explicit TIMESTAMP literals:
```sql
created_at AT TIME ZONE 'America/New_York'
  BETWEEN TIMESTAMP '2026-06-01 00:00:00 America/New_York'
    AND TIMESTAMP '2026-06-30 23:59:59.999 America/New_York'
```
Source: trino.io/docs/current/functions/datetime.html + trino.io/docs/current/language/types.html

**IMPRECISION B (semantically misleading, non-load-bearing)**:
```sql
created_at AT TIME ZONE 'America/New_York' >= DATE '2026-06-02'
```
`AT TIME ZONE` returns `timestamp(p) with time zone`. Comparing to `DATE '2026-06-02'` involves implicit DATE→timestamp coercion where the DATE is treated as midnight UTC (not midnight NYC time). The predicate does NOT filter by "local NYC date >= June 2" as an engineer would expect — it filters by the UTC instant equivalent, which is offset by the NYC UTC offset (-4 or -5 hours). Engineers who want "rows on/after June 2 in NYC time" need to compare against a zone-aware timestamp boundary, not a plain DATE literal. The comparison technically works without a parse error (Trino has DATE↔timestamp coercion rules) but produces semantically wrong results for the stated intent.
Source: trino.io/docs/current/functions/datetime.html; github.com/trinodb/trino/issues/12729 (cast from TIMESTAMP WITH TIME ZONE to DATE round-trip issue)

**MINOR ODD EXAMPLE**: `created_at >= current_timestamp AT TIME ZONE 'America/New_York'` used as a lower bound is operationally odd — `current_timestamp AT TIME ZONE 'X'` is the same instant as `current_timestamp`; using it as a lower bound for historical filtering returns zero rows.

- Accuracy 3.0 | Clarity 4.0 | Actionability 3.0 | Completeness 4.0
- **Q4 avg: 3.5**
- Fab status: ONE load-bearing type error (BETWEEN + bare strings); ONE semantically misleading predicate (>= DATE coercion); one odd example (current_timestamp lower bound).

---

## Overall score

| Q | Topic | Acc | Clarity | Action | Complete | Avg |
|---|---|---|---|---|---|---|
| Q1 | Iceberg $snapshots history quoting (re-probe) | 5.0 | 4.5 | 5.0 | 4.5 | 4.75 |
| Q2 | Trino MAP element_at IS NOT NULL (re-probe) | 5.0 | 4.5 | 5.0 | 4.5 | 4.75 |
| Q3 | Iceberg maintenance cadence | 4.5 | 4.5 | 5.0 | 4.5 | 4.625 |
| Q4 | Postgres TIMESTAMPTZ → Trino timezone filtering | 3.0 | 4.0 | 3.0 | 4.0 | 3.5 |
| **Overall** | | **4.375** | **4.375** | **4.5** | **4.375** | **4.406** |

**PASS** (4.406 > 3.5, margin +0.906)

---

## Regression / fabrication inventory (iter491)

| # | Q | Class | Severity | Correct fact | Source |
|---|---|---|---|---|---|
| 1 | Q4 | TYPE ERROR — `BETWEEN '2026-06-01' AND '2026-06-30'` with bare VARCHAR strings on TIMESTAMP WITH TIME ZONE | LOAD-BEARING — SQL type error at analysis time | Use explicit TIMESTAMP literals with zone: `BETWEEN TIMESTAMP '2026-06-01 00:00:00 America/New_York' AND TIMESTAMP '...'` | trino.io/docs/current/functions/datetime.html |
| 2 | Q4 | SEMANTIC IMPRECISION — `AT TIME ZONE 'America/New_York' >= DATE '2026-06-02'` coercion is misleading | NON-LOAD-BEARING but produces wrong rows | AT TIME ZONE returns timestamp(p) with time zone; DATE coercion treats DATE as midnight UTC, not midnight NYC time; result does NOT filter by "local NYC date >= June 2" as implied | trino.io/docs/current/functions/datetime.html; github.com/trinodb/trino/issues/12729 |
| 3 | Q4 | ODD EXAMPLE — `current_timestamp AT TIME ZONE 'X'` as lower bound | NON-LOAD-BEARING | Same instant as `current_timestamp`; used as lower bound returns zero rows for historical data | trino.io/docs/current/functions/datetime.html |

Q1: ZERO fabrications — $snapshots split-quote FINALLY FIXED.
Q2: ZERO fabrications — cardinality-on-scalar type error FIXED.
Q3: ZERO fabrications.

---

## Fix status (iter490 regressions / primary actions)

| Regression / Action | Status |
|---|---|
| $snapshots split-quote 3x-recurring regression | CONFIRMED FIXED — iter491 teacher TOP-OF-FILE CRITICAL QUOTING RULE block in r17 LANDED. Responder used `"events$snapshots"` (whole-token-one-quote-pair). REGRESSION CLOSED. |
| cardinality-on-scalar TYPE ERROR (`cardinality(element_at(map,key))`) | CONFIRMED FIXED — iter490 teacher DO-NOT-WRITE for `cardinality(element_at(...))` in r09 LANDED. Responder used `IS NOT NULL` form only. |

---

## Topic average updates (iter491)

| Topic | Before | After | Delta | Probed |
|---|---|---|---|---|
| Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup | 4.4835/144 | **4.4863/146** | +0.0028 | Q1 (snapshot history, 4.75) + Q3 (maintenance cadence, 4.625) |
| Analytical query patterns on Iceberg+Trino | 4.5005/17 | **4.5144/18** | +0.0139 | Q2 (MAP existence, 4.75) |
| Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling | 4.5046/163 | **4.4985/164** | -0.0061 | Q4 (TIMESTAMPTZ filtering, 3.5) |
| Trino federation / cross-source connectors | 4.49944/310 | **4.49944/310 UNCHANGED** | NOT PROBED | — |

---

## Teacher actions for iter492

### PRIMARY — Add a canonical timezone-filtering pattern to resources

The responder's AT TIME ZONE advice is directionally correct but the example predicates are broken. Add a CANONICAL TIMEZONE FILTERING block to the relevant resource (likely r17 or r23, wherever Trino timestamp types are covered):

```
CORRECT — filter by local-date range in a given timezone:
  WHERE created_at >= TIMESTAMP '2026-06-01 00:00:00 America/New_York'
    AND created_at <  TIMESTAMP '2026-07-01 00:00:00 America/New_York'

ALSO CORRECT — using AT TIME ZONE to extract local date for comparison:
  WHERE CAST(created_at AT TIME ZONE 'America/New_York' AS date) >= DATE '2026-06-01'

DO NOT WRITE:
  WHERE created_at AT TIME ZONE 'America/New_York' BETWEEN '2026-06-01' AND '2026-06-30'
  -- TYPE ERROR: bare strings are VARCHAR; Trino has no VARCHAR→TIMESTAMP WITH TIME ZONE coercion

DO NOT WRITE:
  WHERE created_at AT TIME ZONE 'America/New_York' >= DATE '2026-06-02'
  -- SEMANTICALLY MISLEADING: AT TIME ZONE returns timestamp(p) with time zone;
  -- comparing to DATE '...' implicitly casts the DATE to midnight UTC, NOT midnight NYC time;
  -- result does NOT filter by "NYC local date >= June 2" as intended
```

Key semantics to state:
- AT TIME ZONE changes the zone label but NOT the underlying instant (same UTC moment)
- `CAST(ts AT TIME ZONE 'America/New_York' AS date)` IS the correct way to get the local date for comparison
- For a range filter by local date, either use explicit zone-aware TIMESTAMP literals OR CAST to date after AT TIME ZONE
- Don't rely on JVM -Duser.timezone (env tz can vary between workers, session tz is the reliable lever)

Sources: trino.io/docs/current/functions/datetime.html + trino.io/docs/current/language/types.html

### SECONDARY — breadth design for iter492

- Federation 4.49944/310 row HELD per iter472-491+ directive. DO NOT probe.
- $snapshots split-quote regression is CLOSED — no need to probe again unless a new regression surface (e.g., $history or $files) is suspected.
- cardinality-on-scalar type error is CLOSED.
- Low-count topics worth additional probes:
  - dbt sources / source freshness (4.219/3) — e.g., "what happens to downstream dbt models when source freshness check fails?"
  - dbt model contracts (4.1146/3) — e.g., "how do I enforce that a column exists and has the right type at build time?"
  - Storage tiering (4.25/2) — e.g., "how do I set up MinIO lifecycle rules to move old Iceberg data to cold storage?"
- Q4 timezone topic (Postgres-to-Iceberg ingestion) dropped from 4.5046 to 4.4985 — one timezone re-probe after the teacher fix would confirm the canonical form lands.

### Schedule note

5-min cadence — `delaySeconds=300`.

---

## Streak / margin status

- **90th consecutive overall PASS in extended phase.**
- Margin at 4.406 — +0.906 above 3.5 floor. Strong margin.
- **$snapshots split-quote RECURRING REGRESSION is now CLOSED** (4 probes, 3 recurrences, fixed on 4th probe via TOP-OF-FILE escalation).
- **cardinality-on-scalar type error CLOSED** (fixed on 2nd re-probe after iter490 teacher fix).
- **OPEN NEW ISSUE: timezone-predicate-examples** — Q4 has a load-bearing BETWEEN+bare-strings type error and a semantically misleading >= DATE predicate. Teacher must add a canonical timezone filtering block with correct Trino syntax.
- Citation hygiene: Q1/Q2/Q3 ZERO fabrications. Q4 has 1 load-bearing type error + 1 semantic imprecision.
