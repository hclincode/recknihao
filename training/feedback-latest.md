# Iter654 Judge Feedback — 2026-06-08

## Verdict: PASS (STRONG) — Overall 5.00

Mode: extended phase / DURABILITY-BREADTH probe iteration. All four probes returned clean, docs-correct, drop-in answers verified against Trino 467 documentation. The two critical lock checks both held: (1) iter649 rolling-N-day pre-aggregate-first grain rule GENERALIZED cleanly from AVG to SUM (Q1); (2) AT-TIME-ZONE attach-vs-convert distinction explicitly handled in the responder's own words (Q4).

---

## Per-question scoring

### Q1 — 7-day ROLLING TOTAL of daily new signups (DURABILITY check: iter649 rule generalizes AVG→SUM)

**Answer recap**: Inner CTE pre-aggregates raw `signups` to one-row-per-day via `COUNT(*) GROUP BY DATE(signup_at)`, then outer SELECT applies `SUM(daily_signups) OVER (ORDER BY signup_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW)` over the daily grain.

**Docs verification (trino.io/docs/current/functions/window.html)**: "All Aggregate functions can be used as window functions by adding the OVER clause." SUM-OVER-ROWS-BETWEEN-6-PRECEDING-AND-CURRENT-ROW is valid Trino 467 syntax (documented example uses `sum(totalprice) OVER (PARTITION BY clerk ORDER BY orderdate)`).

**DURABILITY CHECK — PASS**: The iter649 rolling-N-day grain rule (pre-aggregate to one-row-per-day FIRST, then window over the daily grain) GENERALIZED CLEANLY from AVG to SUM. The responder did NOT apply a ROWS window straight over raw per-signup rows (which would window the last 6 signups, NOT the last 6 days). The inner aggregation collapses raw per-signup rows to daily totals; the outer trailing-7-rows frame correctly sums the 7 daily totals. This is the durability win iter649 was designed to lock — confirmed working for the SUM variant.

- Accuracy: 5 (DATE() + COUNT(*) GROUP BY + SUM OVER ROWS BETWEEN 6 PRECEDING AND CURRENT ROW all valid Trino 467; grain decision correct)
- Completeness: 5 (preserves daily_signups column + rolling_7day_total side-by-side; ORDER BY signup_date for stable display)
- Clarity: 5 (CTE/derived-table style makes the two-step grain logic visually explicit)
- Actionability: 5 (drop-in shape; swap table and date column to ship)
- **Q1 avg: 5.00**

### Q2 — most common plan_type (mode)

**Answer recap**: PRIMARY `SELECT plan_type FROM subscriptions GROUP BY plan_type ORDER BY COUNT(*) DESC LIMIT 1`. TIE form using `HAVING COUNT(*) = (SELECT MAX(cnt) FROM (...))`. Mentioned `approx_most_frequent(buckets, plan_type, capacity)`.

**Docs verification (trino.io/docs/current/functions/aggregate.html)**: `approx_most_frequent(buckets, value, capacity) → map<[same as value], bigint>` — 3-arg signature exactly as cited. Returns a MAP from value to estimated frequency. The exact GROUP BY + ORDER BY COUNT(*) DESC + LIMIT 1 form is the docs-canonical exact-mode pattern.

- Accuracy: 5 (exact form correct; tie-handling subquery correct; approx_most_frequent signature matches docs verbatim)
- Completeness: 5 (covers exact, tie-aware, and approximate variants — three angles)
- Clarity: 5 (PRIMARY/TIE/APPROX framing helps the engineer pick)
- Actionability: 5 (drop-in; parameter-swap only)
- **Q2 avg: 5.00**

### Q3 — collapse fully-identical duplicate rows (full-row dedup)

**Answer recap**: `SELECT DISTINCT * FROM events`. Plus CTAS persist + explicit-column-list variants.

**Docs verification (trino.io/docs/current/sql/select.html)**: "If the argument DISTINCT is specified, only unique rows are included in the result set." `DISTINCT *` applies uniqueness across all columns of the row → byte-identical rows collapse. Distinct-from-latest-row-per-key (ROW_NUMBER) — the responder correctly framed this as a different problem (lock at r23:901 holds).

- Accuracy: 5 (SELECT DISTINCT * is the docs-canonical exact-whole-row-dedup form)
- Completeness: 5 (covers the one-shot SELECT, the CTAS persist shape, and the explicit-column-list variant)
- Clarity: 5 (no ambiguity with latest-row-per-key)
- Actionability: 5 (one-liner; CTAS shape productionizes it)
- **Q3 avg: 5.00**

### Q4 — convert bare UTC timestamp to US Eastern, DST-correct (CRITICAL ATTACH-vs-CONVERT semantics check)

**Answer recap**: `event_time AT TIME ZONE 'UTC' AT TIME ZONE 'America/New_York' AS event_time_eastern`. Explicit explanation that `event_time` is a bare timestamp, first AT TIME ZONE 'UTC' ATTACHES the zone (bare → timestamptz with UTC label), second AT TIME ZONE 'America/New_York' CONVERTS to NY local DST-aware. Recommended IANA names (America/New_York) over legacy US/Eastern; mentioned CAST-to-DATE variant.

**Docs verification (trino.io/docs/current/functions/datetime.html)**:
- AT TIME ZONE example: `timestamp '2012-10-31 01:00 UTC' AT TIME ZONE 'America/Los_Angeles' → 2012-10-30 18:00:00.000 America/Los_Angeles` — CONVERT semantics on a timestamptz (instant preserved, wall-clock re-rendered).
- `with_timezone(TIMESTAMP '2022-11-01 09:08:07.321', 'America/Los_Angeles') → 2022-11-01 09:08:07.321 America/Los_Angeles` — ATTACH semantics (wall-clock unchanged, zone label added).

**ATTACH-vs-CONVERT CHECK — PASS**: The double-AT-TIME-ZONE chain `bare_utc_ts AT TIME ZONE 'UTC' AT TIME ZONE 'America/New_York'` correctly:
1. ATTACHES UTC to the bare timestamp (now it's a timestamptz with the wall-clock interpreted as UTC).
2. CONVERTS that UTC instant to America/New_York wall-clock (DST-aware via IANA zone).

This handles the gotcha that a bare timestamp + a single `AT TIME ZONE 'America/New_York'` would WRONGLY attach NY (interpret the wall-clock AS IF it were NY local — same numeric reading, wrong zone) instead of converting from UTC. The equivalent alternative `with_timezone(event_time, 'UTC') AT TIME ZONE 'America/New_York'` was not named explicitly but is fully consistent with the explained semantics.

- Accuracy: 5 (chain semantically correct per Trino 467 docs; ATTACH-vs-CONVERT gotcha handled; IANA-over-legacy recommendation correct for DST)
- Completeness: 5 (two-step semantics with the WHY; named the gotcha implicitly via the explanation; included CAST-to-DATE variant)
- Clarity: 5 (the explicit ATTACHES/CONVERTS naming is exactly what a beginner needs)
- Actionability: 5 (drop-in expression; preserves DST correctness)
- **Q4 avg: 5.00**

---

## Overall

| Q | Acc | Comp | Clar | Act | Avg |
|---|-----|------|------|-----|-----|
| Q1 | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | 5 | 5 | 5 | 5 | 5.00 |
| Q3 | 5 | 5 | 5 | 5 | 5.00 |
| Q4 | 5 | 5 | 5 | 5 | 5.00 |

**Overall average: 5.00 / 5.00 — PASS (STRONG)**

---

## Durability findings

- **iter649 rolling-grain rule GENERALIZED AVG→SUM (durability win)**: Q1 confirms the pre-aggregate-to-daily-then-SUM-OVER-ROWS shape is being applied correctly for a SUM-not-AVG variant. The Pattern D rule (r07:2458) explicitly extends to SUM/COUNT per r07:2491; the responder composed it without hesitation. No edit needed.
- **AT-TIME-ZONE attach-vs-convert lock (r07:1402 / r27:837) HOLDS**: Q4 confirms the double-chain shape for bare-UTC → Eastern is being applied with the correct ATTACH-then-CONVERT explanation, NAMED in the responder's own words.
- **approx_most_frequent decision-row (r23:661) HOLDS**: Q2 surfaced the exact 3-arg docs-canonical signature alongside the exact GROUP BY + ORDER BY + LIMIT form.
- **SELECT DISTINCT * whole-row dedup (r23:882-901) HOLDS**: Q3 returned the docs-canonical one-liner plus CTAS persist shape; the distinct-from-latest-row-per-key separation at r23:901 is respected.

## Teacher action for iter655

**RECOMMENDATION: DEFAULT NO-OP / DURABILITY-BREADTH**.

No per-Q average is below 3.5 — there is no FIX-A. All four iter654 probes returned clean, docs-correct, drop-in answers covering:
1. Rolling-N-day SUM with pre-aggregate-first grain rule (durability check).
2. Mode of a column (exact + tie + approx forms).
3. Whole-row dedup with SELECT DISTINCT *.
4. UTC → local-zone conversion via double-AT-TIME-ZONE with explicit ATTACH-vs-CONVERT framing.

Continue the no-op posture into iter655. Probe BREADTH on bulletproofed surfaces (federation pushdown / OPA-deferred auth / cost basics / Iceberg compaction) rather than depth-probing the four areas just confirmed clean. Hold the iter653 watch-items (`corr`/regression aggregates; approx_most_frequent worked-card-vs-1-line) — only act on a verified-failure signal.

No edits. No commits. resources/22 UNTOUCHED.
