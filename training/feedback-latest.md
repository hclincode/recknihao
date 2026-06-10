# iter954 — RE-PROBE #4 of filter-then-count gaps-and-islands bug (post-iter953 LIGHT FIX-A defang)

**OVERALL: 3.34375 FAIL** (per-Q Q1 1.50 / Q2 3.625 / Q3 3.875 / Q4 5.00 = 13.375/4 = **3.34375**; margin **-0.15625 BELOW THRESHOLD**; overall average governs, no per-Q veto.)

NO FEDERATION PROBE (4.49944/310 row UNCHANGED). All dialect verified vs trino.io/docs/467 + WebFetch 2026-06-10 — NOT against resources/; iter882 verify-BOTH-directions discipline.

---

## ★ ★ ★ Q1 VERDICT = LEAD REVERTED TO FILTER-THEN-COUNT ALWAYS-ZERO BUG + STREAK-ASSOCIATION ERROR — DEFANG DID NOT HOLD ★ ★ ★

Acc 1.0 / Comp 1.5 / Clar 2.0 / Act 1.5 = **1.50**.

### TRACE on [customer(c1), customer(c2), agent(a1), customer(c3), agent(a2)] ordered by sent_at:

**Step 1 — numbered_messages CTE**: msg_seq 1..5.

**Step 2 — customer_streaks CTE** (streak_id = running SUM of `sender != LAG(sender)`):
- c1: LAG=NULL → `c != NULL` is UNKNOWN, CASE-WHEN with ELSE 0 → 0, **streak_id = 0**
- c2: LAG=c → false → 0, **streak_id = 0**
- a1: LAG=c → true → 1, **streak_id = 1**
- c3: LAG=a → true → 1, **streak_id = 2**
- a2: LAG=c → true → 1, **streak_id = 3**

**Each agent message is in its OWN streak, SEPARATE from the customer messages preceding it** (streak 0 = {c1,c2}, streak 1 = {a1}, streak 2 = {c3}, streak 3 = {a2}).

**Step 3 — Final SELECT** `WHERE sender='agent'` + `COUNT(*) FILTER (WHERE sender='customer') OVER (PARTITION BY ticket_id, streak_id ORDER BY msg_seq ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)`:

Per **trino.io/docs/467/functions/window.html** ("window functions run after the HAVING clause but before the ORDER BY clause"), WHERE evaluates BEFORE the window. After WHERE only a1 and a2 survive — c1, c2, c3 already stripped.

- a1: partition (ticket_id, streak_id=1) contains only a1; FILTER (WHERE sender='customer') excludes a1 → **0**
- a2: partition (ticket_id, streak_id=3) contains only a2; FILTER excludes a2 → **0**

**Actual output: waiting_customer_messages = 0 for EVERY agent row.** Silent always-zero wrong result. Two compounding defects:

1. **Filter-then-count bug (window-surface)**: WHERE sender='agent' strips the customer rows BEFORE the window evaluates — the exact shape the iter953 LIGHT FIX-A defang at r07 L3223-3251 inline-marked WRONG with the parenthetical "same bug if you swap GROUP BY for COUNT(*) OVER (PARTITION BY streak_id) — windows also run AFTER WHERE".
2. **Streak-association error** (independent): even if WHERE were removed, each agent is in its OWN streak (1 and 3). The customer messages PRECEDING the agent are in streak (agent_streak - 1) = streaks 0 and 2. To count "customers right before this agent" you must associate the agent row with the PRECEDING customer streak (e.g., LAG-flag should detect transition INTO agent and assign agent rows to the preceding customer-streak's streak_id; or compute per-customer-streak counts then JOIN to the agent row that follows; or terminate the streak at the transition and store streak length on the boundary row). The responder's "each row gets its own streak when sender changes" geometry never associates the agent with the customer run.

### LEAD-REVERT VERDICT: DEFANG DID NOT HOLD FOR THIS PHRASING

Contrast iter953 where the LEAD kept both types in WHERE and was bug-free (only the secondary "simpler alternative" reverted to filter-then-count); here the **PRIMARY (only) Q1 answer** reverts to the filter-then-count always-zero shape — the iter953 defang's window-surface callout warned about EXACTLY this surface but the responder shipped it anyway. The user's prompt ("filtering to just agent rows then counting, I keep getting zeros") matches the defang's diagnostic situation perfectly, yet the responder did not connect the dots.

This is the **3rd-instance recurrence** of the underlying filter-then-count always-zero defect across distinct surfaces (iter951 Q4 GROUP-BY surface / iter952 Q1 window-surface / **iter954 Q1 window-surface PRIMARY (post-defang)**). Note: iter953 Q1 was a partial recurrence (LEAD clean, broken-secondary-alternative); iter954 is **clean recurrence in the LEAD itself, AFTER the defang**. Defang in place 1 iteration was insufficient.

### Q1 SCOPE
- Defang inline-WRONG block PRESENT and structurally correct (verified intact in state.json read-only check).
- Responder did NOT route to it — possible reasons: (a) Q1 phrasing "consecutive customer messages right before agent reply" does not surface the user-suggested filter-then-count phrasing the defang's WRONG block uses (declined/paid); (b) the responder constructed multi-CTE gaps-and-islands scaffolding that LOOKS sophisticated (NUMBERED + STREAKS + final window) and may have masked the bug from keyword-matching against the defang shape; (c) `COUNT(*) OVER (PARTITION BY streak_id) FILTER ...` is the literal anti-shape called out by the defang parenthetical but it still got shipped, suggesting the parenthetical alone is too subtle when wrapped in the multi-CTE form.

---

## Q2 — TO_CHAR FABRICATION VERDICT: NUANCED (function exists but format string is broken)

Acc 3.0 / Comp 4.0 / Clar 4.0 / Act 3.5 = **3.625**.

### Primary form (DATE_TRUNC + AVG): CORRECT

`SELECT DATE_TRUNC('month', created_at) AS month, ROUND(AVG(total_amount),2) FROM orders WHERE created_at >= DATE '2025-01-01' GROUP BY DATE_TRUNC('month', created_at) ORDER BY month` — clean and 467-valid. DATE_TRUNC('month', timestamp) returns timestamp at month-start, valid in GROUP BY (repeats the expression, not the alias, which is correct per sql/select.html). AVG ignores NULL. ROUND(decimal, 2) valid.

### "Month label" variant: TO_CHAR VERDICT NUANCED

**CRITICAL CORRECTION TO DIRECTIVE PREMISE**: The judge directive asserted "Trino does NOT have TO_CHAR — that's Postgres/Oracle... TO_CHAR(...) is a FABRICATION — function-not-found error in Trino 467". **This is incorrect.** Per **trino.io/docs/467/functions/teradata.html** (WebFetch 2026-06-10), Trino 467 DOES have a `to_char(timestamp, format) → varchar` function as a Teradata compatibility function: "Formats `timestamp` as a string using `format`."

**HOWEVER**, the responder's call `TO_CHAR(DATE_TRUNC('month', created_at), 'MMMM YYYY')` is STILL BROKEN because the format string is wrong:
- Trino 467's `to_char` uses **Teradata-style format codes** (lowercase: `dd`, `mm`, `yyyy`, `hh24`, `mi`, `ss`), NOT Joda-Time/SimpleDateFormat patterns (`MMMM yyyy`).
- Documented constraint: "Case insensitivity is not currently supported. All specifiers must be lowercase" — `MMMM YYYY` (uppercase) would not be recognized as the responder intends.
- Critically, **month names (`MMMM` → "January") are not in the Teradata-compatible format spec** — only numeric month `mm`. So even with `'mmmm yyyy'` it would not produce "January 2025"; it would not produce a sensible label.

**Correct shapes for a month label in Trino 467**:
- `format_datetime(ts, 'MMMM yyyy')` (Joda pattern) → "January 2025"
- `date_format(ts, '%M %Y')` (MySQL pattern) → "January 2025"

So the secondary form is broken (wrong format-pattern dialect), but the **directive's specific framing (fabrication / function-not-found)** is inaccurate. The actual error mode would likely be either a runtime format-parse error (depending on parser strictness) or a non-sensical string output. Either way, the secondary is shippable-broken on the user side.

### Q2 SCOPE
Primary is clean; the secondary is broken-via-wrong-format-codes. **Broken-secondary-alternative meta-pattern recurrence** (6th instance over ~18 iters; iter936/943/948/950/953/954). Independent defect family from Q1's defang miss. Score reflects clean primary + broken secondary, NOT the directive's overstated fabrication claim.

---

## Q3 — PERF CLAIM ASSESSMENT: OVER-OPTIMISTIC for column-vs-column predicate

Acc 3.5 / Comp 4.0 / Clar 4.0 / Act 4.0 = **3.875**.

`SELECT product_id, stock_quantity, reorder_threshold FROM products WHERE stock_quantity < reorder_threshold ORDER BY stock_quantity` — query itself is **correct and valid 467**. "Keep the column bare (no function wrap)" is generically sound sargability advice.

**Perf claim assessment** (verified via WebSearch 2026-06-10 + iceberg connector docs):
- Trino Iceberg's predicate-pushdown / file-skipping mechanism uses per-column **min/max bounds compared against a LITERAL**: "a query filtering on `amount > 500` can skip every file whose amount column has a maximum value below 500" / "a query filtering on `status = 'shipped'` can skip files where the min and max of the status column are both 'pending'". This is **column-vs-LITERAL pruning**.
- For a **column-vs-column predicate** (`stock_quantity < reorder_threshold`, both columns from the same row), per-column min/max bounds generally CANNOT be combined to safely skip a file. To skip you would need to prove `max(stock_quantity_in_file) < min(reorder_threshold_in_file)` for ALL rows in the file — but per-column file-level min/max only give you per-column extremes (independent), not joint row-level relationships. Trino's planner can in some cases derive bounds from one side, but a generic column-vs-column comparison is **not file-skippable via the standard min/max pruning path**.
- Net: responder's "Trino pushes this predicate down... does NOT do a full scan" and "if partitioned or has column min/max stats Trino can skip files" is **over-optimistic for THIS predicate shape**. The query will most likely scan all data files (the row-level filter still benefits from columnar projection — only the two columns are read — but file-level skipping does not apply).
- "Keep the column bare" advice is **correct in spirit** (avoids unsargable function-wrap) but does not save you when both sides are columns.

### Q3 SCOPE
**Minor perf over-claim, NOT a dialect or correctness error** (the query is fine and will return correct results; the engineer just won't get the "skip files" benefit the responder promised). Engineer's worry about "full scan on 100Ks of products" is largely justified — they should consider: (a) clustering/sorting by `stock_quantity` and using a materialized check, (b) a small `low_stock` derived/MV table, or (c) accepting the scan (100K rows is tiny for Trino columnar — likely sub-second anyway). Responder did not raise these. Loss of 1.0-1.5 points spread across Acc/Completeness.

---

## Q4 — CLEAN ★

Acc 5.0 / Comp 5.0 / Clar 5.0 / Act 5.0 = **5.00**.

`SELECT COUNT(*) FILTER (WHERE shipping_method='free') AS free_count, COUNT(*) - COUNT(*) FILTER (WHERE shipping_method='free') AS paid_count, COUNT(*) AS total FROM orders` — textbook single-pass conditional aggregation, valid 467 per functions/aggregate.html (COUNT(*) FILTER (WHERE pred) supported). CASE-WHEN equivalent `SUM(CASE WHEN shipping_method='free' THEN 1 ELSE 0 END)` is the standard equivalent (verified single-pass — same physical scan). Engineer gets two named columns + total in one query, exactly what they asked. Clean.

---

## SCORE SUMMARY

| Q | Acc | Comp | Clar | Act | Avg |
|---|---|---|---|---|---|
| Q1 | 1.0 | 1.5 | 2.0 | 1.5 | **1.50** |
| Q2 | 3.0 | 4.0 | 4.0 | 3.5 | **3.625** |
| Q3 | 3.5 | 4.0 | 4.0 | 4.0 | **3.875** |
| Q4 | 5.0 | 5.0 | 5.0 | 5.0 | **5.00** |

**Overall avg: (1.50 + 3.625 + 3.875 + 5.00) / 4 = 13.375 / 4 = 3.34375 → FAIL (margin −0.15625 below 3.5).**

---

## DEFECT SCOPING

**Primary defect (Q1)**: 3rd-instance recurrence of filter-then-count always-zero defect on **window-surface PRIMARY answer AFTER iter953 LIGHT FIX-A defang placement**. iter953 defang was in place exactly 1 iteration before this surface re-emerged in the LEAD (not just a secondary alternative). Critically the responder built a structurally-elaborate 2-CTE gaps-and-islands scaffold (LAG-flag + running-SUM streak_id) AND THEN applied `WHERE sender='agent'` + count-other-type, which means the responder has internalized the streak-construction machinery but NOT the rule "do not pre-filter the counted type before aggregating". Compounded by streak-association error: agent rows are in their own streak (not the preceding customer streak), so even without the WHERE the count would be 0.

**Secondary defect (Q2)**: broken-secondary-alternative meta-pattern recurrence — `TO_CHAR(ts, 'MMMM YYYY')` is broken not because the function doesn't exist (it does, as Teradata compat) but because the format codes are wrong dialect (uppercase Joda not lowercase Teradata; no month-name code in Teradata spec). Engineer copying it gets either a parse error or wrong output. 6th instance of broken-secondary meta-pattern.

**Tertiary defect (Q3)**: minor perf over-claim — column-vs-column predicate is not file-skippable via per-column min/max. Generic correctness OK.

---

## iter955 RECOMMENDATION = LIGHT FIX-A2 (strengthen defang) + r28 TO_CHAR FORMAT-CODE CARD

iter954 establishes that the iter953 LIGHT FIX-A defang was insufficient to suppress the filter-then-count bug on the LEAD when the question is phrased without the defang's exact keywords (declined/paid). Per the iter953 criterion ("escalate to LIGHT FIX-A2 ONLY if broken-secondary-alternative recurs on 2+ further sweeps") — though that criterion was for broken-secondary, **iter954 is a stronger signal: the LEAD itself reverted to the bug, which is a more serious failure than a broken-secondary**. This crosses the escalation threshold.

### LIGHT FIX-A2 PROPOSAL (additive sub-card at r07 near L3223-3251 defang):

Add **right above the existing inline-WRONG block** a **WHICH-X router** that triggers on the question's STRUCTURAL keywords ("for each X count consecutive Y right before it", "count Y leading up to X", "Y immediately preceding X") regardless of the X/Y domain:

```
-- WHICH PATTERN: "for each <boundary event X> count consecutive <other event Y> right before it"?
--   STEP 1: Build per-row streaks over the FULL UNFILTERED stream (LAG-flag + running-SUM streak_id keeps both X and Y).
--   STEP 2: Count Y per streak with NO WHERE on event type yet.
--   STEP 3: Associate each X row with the PRECEDING streak's count (streak_id - 1 or a JOIN on streak_end → next_boundary).
--   ANTI-PATTERN (returns 0 for every X): WHERE event_type = X first, then COUNT(*) FILTER (WHERE event_type = Y) OVER (PARTITION BY streak_id ...). Window runs AFTER WHERE, and X is in its own streak — separate from Y's streak.
```

Plus a second WRONG-block instance using **consumer-domain wording** (customer/agent or scan/delivered or click/checkout) to neutralize the "different keywords mask the same shape" findability issue (responder reads RAW markdown — same-shape anti-patterns must be present in BOTH the user-domain phrasing AND the canonical declined/paid phrasing per `feedback_responder_findability.md`).

### r28 / r05 TO_CHAR FORMAT-CODE CARD (light additive):

Single short card pinning: **`to_char(ts, format)` EXISTS in Trino 467 (Teradata compat) but uses lowercase numeric codes (`mm`, `yyyy`, `hh24`, `mi`, `ss`) — month NAMES (`MMMM` for "January") are NOT supported; use `format_datetime(ts, 'MMMM yyyy')` (Joda) or `date_format(ts, '%M %Y')` (MySQL) for month-name labels.** This corrects two distinct slips: (a) the directive's "TO_CHAR is a fabrication" pin (which I just refuted — the function exists), and (b) the responder's broken format string. Keep brief; do not bloat the date-formatting neighborhood (New-Card-over-attracts-adjacent risk).

### Q3 perf over-claim — RE-PROBE-DON'T-CHURN

1st-instance perf over-claim on column-vs-column predicate file-skipping; do NOT add a card. Re-probe next sweep with explicit column-vs-column / column-vs-column-arithmetic comparison Qs to verify whether responder leads with correct min/max-on-literal scoping. Escalate only on 2nd recurrence.

### Do NOT touch

- r07 L37 (HAVING-perf reword durable)
- r07 L3187-3221 (B-Streak Layer-1/2/3 skeleton + NESTED_WINDOW + two-GROUP-BY defangs)
- federation row (4.49944/310 — bulletproofed angles only)
- percentile / INTERVAL / COUNT(DISTINCT) / PARTITIONED-BY / argmax / max_by cards

### PINS REINFORCED

- **Window functions evaluate AFTER WHERE per functions/window.html** (RE-CONFIRMED WebFetch 2026-06-10) — filter-to-target-event-then-count-OTHER-type via WHERE + COUNT(*) FILTER OVER returns 0 every time **regardless of how elaborate the upstream streak-construction CTEs are**.
- Each transition row joins its OWN streak under standard LAG-flag + running-SUM streak_id construction — the **boundary row is in streak N; the preceding run is in streak N-1**. Association requires explicit streak_id-1 join or alternative streak design (e.g., assign target rows to the preceding streak by computing streak_id from `LAG(sender) != sender` ONLY when current = target type).
- **Trino 467 HAS `to_char(timestamp, format)`** as Teradata compatibility function, BUT format codes are lowercase Teradata-style (`mm`, `yyyy`, `hh24`); month names (`MMMM`) NOT supported; case-sensitive (uppercase fails). For month-name labels use `format_datetime(ts, 'MMMM yyyy')` (Joda) or `date_format(ts, '%M %Y')` (MySQL). **Correction to memory/prior**: do NOT state "Trino has no TO_CHAR" — the function exists; the GOTCHA is the format-code dialect.
- **File-skipping via per-column min/max** requires **column-vs-LITERAL** comparison; **column-vs-column** predicates (both sides columns from same row) generally CANNOT be file-skipped via per-column min/max bounds.
- COUNT(*) FILTER (WHERE pred) valid single-pass conditional count in 467; CASE-WHEN equivalent.
- DATE_TRUNC('month', timestamp) returns timestamp; GROUP BY repeats expression, not alias.

### DEADLINE / FED / STATE

Loop runs through 2026-06-30. Federation un-edited. **DO NOT bump training/state.json** (already 954; passed=true preserved; overall 3.34375 FAIL holds; per-Q veto N/A under overall-average-governs).
