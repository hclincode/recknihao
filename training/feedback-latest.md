# Iter670 — Judge Feedback

**Iteration:** 670
**Phase:** extended
**Overall avg:** 4.125 / 5 → **PASS** (≥ 3.5)

## Per-question scores

### Q1 — MoR vs CoW re-probe (Iceberg UPDATE/DELETE storage behavior + maintenance)
- **Accuracy: 4** — Correctly frames Trino 467 Iceberg UPDATE/DELETE as **Merge-on-Read by default** (position-delete files; original data files untouched for DELETE). Maintenance recipe (`ALTER TABLE ... EXECUTE optimize(file_size_threshold => '256MB')` then `EXECUTE expire_snapshots(retention_threshold => '7d')`) is valid Trino 467 syntax — DataSize unit-suffixed and retention_threshold confirmed against trino.io/docs/467/connector/iceberg. Does NOT claim "CoW default" (the iter669 regression). One overstatement: blanket "Iceberg never rewrites data files" is slightly too strong — Trino-executed UPDATE writes NEW data files for changed rows alongside position-delete files for the old rows, and `optimize` itself rewrites. Minor framing issue; doesn't materially mislead but loses one point.
- **Completeness: 4** — Covers storage-file behavior, perf-degradation mechanism (many small delete files), and the two key maintenance procedures. Could have mentioned the #24086 nuance (Trino EXECUTE optimize compacts position deletes only with whole-partition predicates) or the Spark-only rewrite_position_delete_files path — nice-to-haves, not required.
- **Clarity: 4** — Clear flow: what happens on storage → why perf degrades → what to run. Position-delete-file concept introduced cleanly.
- **Actionability: 4** — Engineer can copy the two ALTER TABLE EXECUTE statements directly. Concrete thresholds given.
- **Q1 avg: 4.00**

**MoR-vs-CoW FIX-A (Q1) verdict: CLOSED.** The responder no longer says "CoW default" for Trino 467 Iceberg. Framing now correctly identifies MoR-default + position-delete files, which was the exact iter669 regression that FIX-A targeted. The "never rewrites data files" overstatement is a separate (smaller) framing nit, not a CoW-default regression. **FIX-A held.**

---

### Q2 — INSERT INTO ... SELECT nightly append
- **Accuracy: 5** — `INSERT INTO iceberg.analytics.orders SELECT * FROM iceberg.analytics.staging_orders` is the canonical Trino 467 Iceberg atomic-snapshot append. `CREATE OR REPLACE TABLE AS` confirmed as a valid Trino 467 alternative for full clear-and-load (verified via trino.io/docs/467/connector/iceberg).
- **Completeness: 5** — Core append + DELETE staging cleanup + alternative pattern covered.
- **Clarity: 5** — Direct, copy-paste-ready.
- **Actionability: 5** — Engineer runs it as-is.
- **Q2 avg: 5.00**

---

### Q3 — Sessionization 30-min gap (gaps-and-islands on timestamps)
- **Accuracy: 1** — **CRITICAL DIALECT BUG.** The gap test uses direct timestamp subtraction: `event_time - LAG(event_time) OVER (...) > INTERVAL '30' MINUTE`. **Trino 467 does NOT support `timestamp - timestamp`.** Verified against trino.io/docs/current/functions/datetime: the `-` operator on timestamps only accepts an interval on the right side (e.g., `timestamp - interval`), never timestamp-minus-timestamp. Correct Trino 467 idiom:
  ```sql
  date_diff('minute', LAG(event_time) OVER (PARTITION BY user_id ORDER BY event_time), event_time) > 30
  ```
  Submitted query fails with a type/parse error at planning time. The gaps-and-islands STRUCTURE (LAG + CASE → is_new_session → running SUM = session_id → COUNT DISTINCT session_id per user) is conceptually correct and the right pattern, but the gap-comparison expression does not parse on Trino 467. Engineer cannot run as-is.
- **Completeness: 4** — Both halves answered (assign session_id per event + count sessions per user); two CTEs as expected. Pattern correct.
- **Clarity: 4** — CTE structure readable; logic explained.
- **Actionability: 1** — Will fail at runtime. Engineer has to debug and rewrite the gap expression.
- **Q3 avg: 2.50**

**Q3 timestamp-subtraction verdict: INVALID on Trino 467.** Correct form: `date_diff('minute', LAG(event_time) OVER (PARTITION BY user_id ORDER BY event_time), event_time) > 30`.

---

### Q4 — Status pivot (one row per day, side-by-side counts)
- **Accuracy: 5** — `COUNT(CASE WHEN status='completed' THEN 1 END)` is correct (CASE returns 1 or NULL; COUNT ignores NULL). `COUNT(*) FILTER (WHERE status='completed')` confirmed as Trino 467 standard-SQL conditional aggregation. Both forms valid.
- **Completeness: 5** — All three statuses pivoted; alternative idiom offered; GROUP BY + ORDER BY correct.
- **Clarity: 5** — Pivot pattern clearly demonstrated.
- **Actionability: 5** — Copy-paste-ready.
- **Q4 avg: 5.00**

---

## Overall

| Q | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|----------|--------------|---------|---------------|-----|
| Q1 (MoR/CoW re-probe) | 4 | 4 | 4 | 4 | 4.00 |
| Q2 (INSERT SELECT) | 5 | 5 | 5 | 5 | 5.00 |
| Q3 (sessionization) | 1 | 4 | 4 | 1 | 2.50 |
| Q4 (status pivot) | 5 | 5 | 5 | 5 | 5.00 |
| **Overall** | | | | | **4.125** |

**PASS/FAIL: PASS (4.125 ≥ 3.5).**

**Flagged weak answer:** Q3 contains an invalid Trino 467 expression that will fail at parse/plan time. Overall PASS driven by Q2/Q4 perfect scores and a closed iter669 FIX-A on Q1. Per the run-prompt instruction, no per-question quality-gate override applied — overall average governs.

---

## Critical findings

1. **iter669 MoR-vs-CoW FIX-A (Q1): CLOSED.** Responder correctly frames Trino 467 Iceberg writes as MoR-default-with-position-delete-files. No "CoW default" claim. The 16-edit teacher patch across r17/r05/r11/r13/r14/r16 successfully inoculated the keyword routes. Hold the line — do not let this regress.

2. **NEW gap on Q3 (sessionization):** Direct `timestamp - timestamp` subtraction is invalid Trino 467 dialect. Trino docs only allow `-` between timestamp and interval (not timestamp and timestamp). Engineer-impact is high — the query won't run. Likely the resource that backed this answer has the stale form embedded in a sessionization / gaps-and-islands snippet.

3. **Trino 467 dialect facts verified:** `optimize(file_size_threshold => '256MB')` confirmed; `expire_snapshots(retention_threshold => '7d')` confirmed; `INSERT INTO ... SELECT` atomic append confirmed; `CREATE OR REPLACE TABLE AS` confirmed; `COUNT(CASE WHEN ... THEN 1 END)` and `COUNT(*) FILTER (WHERE ...)` confirmed.

---

## Recommended iter671 — FIX-A: timestamp-difference-needs-date_diff inoculation

**Target:** sessionization, gaps-and-islands, time-bucketing, "events more than N minutes apart" routes across `resources/`.

**The inoculation rule to add at every relevant keyword anchor:**

> **Trino 467 does NOT support `timestamp - timestamp`.** The `-` operator on timestamps works only with an interval on the right (`timestamp - INTERVAL '30' MINUTE` returns a timestamp). To compute the duration between two timestamps, use `date_diff(unit, ts1, ts2)`, which returns `ts2 - ts1` in the requested unit.
>
> **DO-NOT-WRITE:** `event_time - LAG(event_time) OVER (...) > INTERVAL '30' MINUTE` — parse/type error on Trino 467.
>
> **CORRECT IDIOM:** `date_diff('minute', LAG(event_time) OVER (PARTITION BY user_id ORDER BY event_time), event_time) > 30`

**Keyword anchors to update / add:**
- Sessionization / "30-minute gap" / "session window" patterns
- Gaps-and-islands timestamp patterns (LAG-based gap detection)
- Time-difference SQL idioms ("time between events", "duration", "elapsed", "minutes between")
- Existing "date-minus-date is invalid" DO-NOT-WRITE banners — extend to "timestamp-minus-timestamp ALSO invalid", same fix (`date_diff`)

**Search-then-fix sweep:** grep `resources/` for `event_time -`, `ts -`, `timestamp - LAG`, and any LAG-based gap snippets. Replace any direct subtraction with `date_diff('minute', ..., ...)`. Reconcile-don't-append: fix in place; don't leave the stale form anywhere — responder may cite the wrong one.

**Why this is the right FIX-A for iter671:** Q3 is a near-canonical SaaS analytical question (sessionization), and the gap-comparison error is a single-line fix the responder will absorb cleanly if the inoculation lands at the right keyword route. Without this fix, the next sessionization probe will fail again.

---

## Resources to audit
- `resources/04-common-analytical-query-patterns.md` and `resources/06-analytical-query-patterns-iceberg-trino.md` (likely homes for sessionization / gaps-and-islands snippets) — audit for `timestamp - timestamp` patterns.
- Any "time-series SQL" or "funnel" sections that compute event-to-event durations.
- The "date-minus-date is invalid" banners (already established) — extend them to cover the timestamp case explicitly.

## What's holding (preserve)
- iter669 MoR-vs-CoW FIX-A (16-edit teacher patch) — CONFIRMED HELD via Q1.
- iter668 r27 rollback-CALL form fix.
- iter667 DataSize-unit-suffix anchors (r17/r12/r11) — verified intact via Q1 maintenance recipe.
- iter666 Spark-CALL→Trino-ALTER-TABLE-EXECUTE engine-dialect fix.
- Federation HARD LOCK on r22.

## Sources verified
- [Trino datetime functions and operators (current docs)](https://trino.io/docs/current/functions/datetime.html) — confirms no timestamp-minus-timestamp operator; `date_diff(unit, ts1, ts2)` is the required idiom.
- [Trino 467 Iceberg connector](https://trino.io/docs/467/connector/iceberg.html) — confirms INSERT, CREATE OR REPLACE TABLE AS, optimize/expire_snapshots procedure syntax with DataSize unit suffixes and retention_threshold duration format.
