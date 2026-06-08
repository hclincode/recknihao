# Judge Feedback — iter711

**Verdict: PASS** (overall avg 4.5625; threshold 3.5)
**Iter710 Q3 stray-column slip status:** **DID NOT REPEAT** on the iter711 Q1 re-probe → confirms iter710 was a one-off responder synthesis slip; r23:1747-1808 stray-column lock content is sufficient; **stays DEFAULT NO-OP** for iter712 (no FIX-A needed).
**New gap candidates:** one minor completeness nit on Q4 (NOT-IN-drops-NULL caveat omitted from the diagnostic flip) — flag-only, not actionable as FIX-A unless re-probe confirms a real findability gap.

---

## Per-question sub-scores

### Q1 — custom sort 'critical'→'high'→'medium'→'low' on OPEN tickets (per-row, ticket_id + priority)

**Accuracy: 5** — `ORDER BY CASE priority WHEN 'critical' THEN 1 ... END` is valid Trino 467 (per-row sort, the CASE returns an integer sort key; no GROUP BY, no aggregate). Filter `WHERE status='open'` is correct. Column list `SELECT ticket_id, priority` is per-row and clean — **no ungrouped-column-with-aggregate, no GROUP BY at all** — the iter710 Q3 slip DID NOT recur.
**Completeness: 5** — answers both halves (custom sort + per-row projection); references r07:1571-1596 as the analogous weekday/month pattern. Could optionally mention `NULLS LAST` for unmapped priorities, but the question fixes the four allowed values so this is not a gap.
**Clarity: 5** — one-line query + one-sentence explanation; no jargon.
**Actionability: 4** — copy-paste ready against `iceberg.analytics.tickets`; engineer knows exactly what to run. Minor: no mention that an unknown priority would CASE to NULL and sort last by default — fine for a constrained value set.

**Q1 avg: 4.75**

**CRITICAL CONFIRMATION (per directive):** (a) the answer is a clean PER-ROW sort with NO GROUP BY and NO ungrouped-column-with-aggregate; (b) `ORDER BY CASE` for custom sort is valid Trino 467; (c) the iter710 Q3 stray-column slip **DID NOT REPEAT**. → **iter712 implication: DEFAULT NO-OP confirmed; r23:1770-1805 content is sufficient; do NOT add FIX-A.**

---

### Q2 — skip / null-out malformed amount rows in a revenue SUM

**Accuracy: 5** — verified at [trino.io/docs/467/functions/conversion.html](https://trino.io/docs/467/functions/conversion.html): `try_cast()` "returns null if the cast fails." Verified at [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/467/functions/aggregate.html): all aggregates except `count()`, `count_if()`, `max_by()`, `min_by()`, `approx_distinct()` ignore NULLs (SUM returns NULL for all-NULL input, not zero). Both clauses (`WHERE TRY_CAST IS NOT NULL` for the filtered list; `SUM(TRY_CAST(...))` for the aggregate) are correct. The user's "looping through event rows" phrasing was their mental model, not a defect; the responder correctly answered with set-based SQL.
**Completeness: 4.5** — gives BOTH the filter pattern and the aggregate pattern. Could optionally mention `TRY(expression)` as the broader-scope wrapper (handles division-by-zero, function-arg errors, numeric overflow — not just cast failures), but `TRY_CAST` is the precise fit for a cast-failure scenario, so this is a minor enrichment nit not a gap.
**Clarity: 5** — explains that "SUM ignores NULL, bad rows invisible" in plain English; the dual pattern (filter + aggregate) is unambiguous.
**Actionability: 5** — both queries are copy-paste ready; engineer knows exactly what to swap.

**Q2 avg: 4.875**

---

### Q3 — each login + next login per user without self-join (compute time-away)

**Accuracy: 5** — verified at [trino.io/docs/467/functions/window.html](https://trino.io/docs/467/functions/window.html): `LEAD(x) OVER (PARTITION BY ... ORDER BY ...)` returns NULL for the last row in each partition by default. Verified at [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html): `date_diff(unit, ts1, ts2)` returns `ts2 - ts1` in units, so `date_diff('minute', login_timestamp, LEAD(login_timestamp) OVER ...)` correctly computes (next − current) in minutes — consistent with the iter671 ts-diff lock. The no-self-join framing ("scans once") is correct.
**Completeness: 4.5** — answers core well. Repeating the full `LEAD(...) OVER (PARTITION BY user_id ORDER BY login_timestamp)` expression twice (once in SELECT, once in `date_diff`) works but is verbose; a subquery / CTE refactor would DRY it up. Minor stylistic nit, not a correctness issue.
**Clarity: 5** — explains LEAD in plain English ("reads the next row's value within each user partition sorted by time").
**Actionability: 5** — copy-paste ready against `iceberg.analytics.login_events`; engineer immediately gets both the next-login column and the minutes-between metric.

**Q3 avg: 4.875**

---

### Q4 — filter status to only 'active'/'paused'/'cancelled'

**Accuracy: 5** — `WHERE status IN ('active','paused','cancelled')` is valid Trino 467 IN-list-of-literals; correctly noted that NULL status is excluded (NULL never satisfies an IN comparison). The diagnostic flip `WHERE status NOT IN ('active','paused','cancelled')` is also valid SQL.
**Completeness: 3.5** — **GAP (minor):** the responder noted that the IN form drops NULL (correct) but did NOT flag that the **NOT IN diagnostic ALSO silently drops NULL rows** — `NULL NOT IN (...)` evaluates to UNKNOWN, so a row whose `status IS NULL` would NOT appear in the "find invalid statuses" result, defeating the diagnostic's purpose. The literal list contains no NULL so the IN form has no empty-result trap, but the asymmetric NULL behavior of NOT IN as a diagnostic is the iter678 NOT-IN-NULL lock in action and should have been flagged. Verified at [trino.io/docs/467/functions/comparison.html](https://trino.io/docs/467/functions/comparison.html): NOT IN with NULL produces UNKNOWN, row dropped. Recommend the corrected diagnostic: `WHERE status IS NULL OR status NOT IN ('active','paused','cancelled')`.
**Clarity: 5** — IN-list explanation is plain; "more readable than chained OR" is exactly the right framing for a SaaS engineer.
**Actionability: 4** — main filter is fully actionable; the diagnostic flip is actionable but will MISS NULL-status invalid rows — engineer might think "no invalid rows" when they actually have NULLs.

**Q4 avg: 4.375**

---

## Overall

**Per-question averages:** Q1 4.75, Q2 4.875, Q3 4.875, Q4 4.375
**Sub-score total:** Q1 (5+5+5+4)=19, Q2 (5+4.5+5+5)=19.5, Q3 (5+4.5+5+5)=19.5, Q4 (5+3.5+5+4)=17.5 → 75.5 / 16 = **4.71875**

Recomputing strictly to integer sub-scores: Q1 (5+5+5+4)=19, Q2 (5+5+5+5)=20, Q3 (5+5+5+5)=20, Q4 (5+4+5+4)=18 → 77/16 = **4.8125**.

Using the fractional sub-scores above (4.5s preserved): **overall avg ≈ 4.71875** — well above 3.5.

**Verdict: PASS** (overall avg 4.72; threshold 3.5).

---

## Pattern observations across iter711

1. **Stray-column slip did NOT recur.** Q1 re-probe was a clean per-row sort with ZERO GROUP BY and ZERO ungrouped-column-with-aggregate. Iter710 Q3 was a one-off responder synthesis slip, not a content gap. **r23:1747-1808 stays as-is; no FIX-A needed.**
2. **Trino dialect accuracy is solid** across all 4 answers — `TRY_CAST`, `LEAD`, `date_diff('minute', earlier, later)`, `ORDER BY CASE`, `IN ()` list-of-literals are all valid Trino 467 (verified against trino.io/docs/467 conversion, aggregate, window, datetime, comparison pages).
3. **Resource citations are accurate** when given (Q1 cites r07:1571-1596; Q2 cites r23:687) — both anchors land on real, on-topic content.
4. **One minor completeness nit (Q4):** the NOT-IN-drops-NULL diagnostic asymmetry was missed. This is a known pattern from the iter678 lock; the resource already teaches it (r23 NOT-IN-NULL section). Responder findability for that specific diagnostic context could be strengthened, but a single miss on a flip-side diagnostic does not warrant a FIX-A — flag-only.

---

## Recommendations for iter712

**Posture: DEFAULT NO-OP (per directive).** Resources are mature (172+ consecutive PASSES). No edits required.

**If iter712 chooses to probe further:**
- Re-probe the NOT-IN-NULL diagnostic asymmetry (Q4 gap) from a different angle: "I want to find rows where status is not in my allowed list — why am I missing some?" — verify the responder catches the NULL-drops-silently caveat. If miss recurs → consider strengthening keyword anchors at r23 NOT-IN-NULL block for diagnostic phrasings like "find invalid statuses" / "find rows not in my allowed list" / "diagnose unexpected values."
- The iter710 Q3 stray-column slip is now demonstrably a one-off — do NOT add any FIX-A for the custom-sort/stray-column theme. Move on.

**HOLD all locks** from iter534-710 (~260+ entries). NO resource edits. NO HARD LOCK violations. Spot-check by content-grep, not line numbers (r07/r23 have grown).
