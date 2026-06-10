# iter952 Feedback — RE-PROBE of iter951 Q4 filter-then-count always-zero bug

**Phase**: extended | **Mode**: end-of-iteration (zero-edit re-probe sweep)
**Date**: 2026-06-10 | **Dialect pin**: Trino 467

## Per-question scores (Acc / Comp / Clar / Act → avg)

| Q | Topic | Acc | Comp | Clar | Act | Avg |
|---|---|---|---|---|---|---|
| Q1 | Consecutive prior 'declined' before each 'paid' (gaps-and-islands count-per-streak) | 1.5 | 2.0 | 2.5 | 1.5 | **1.875** |
| Q2 | coupon_discount_amount > order_subtotal filter | 5.0 | 5.0 | 5.0 | 5.0 | **5.00** |
| Q3 | Longest product_name per category (argmax by LENGTH) | 5.0 | 5.0 | 5.0 | 5.0 | **5.00** |
| Q4 | COUNT users per signup_source; double-count concern | 5.0 | 5.0 | 5.0 | 5.0 | **5.00** |

**Overall**: (1.875 + 5.00 + 5.00 + 5.00) / 4 = 16.875 / 4 = **4.21875 PASS** (margin +0.71875; overall-avg governs, no per-Q veto).

Federation row (4.49944/310) NOT probed — UNCHANGED.

---

## Q1 RECURRENCE VERDICT = 2ND-INSTANCE FILTER-THEN-COUNT ALWAYS-ZERO BUG (CONFIRMED)

Same root-cause family as iter951 Q4 (sql/select.html WHERE-runs-before-aggregation/window). Different surface (window function here, GROUP BY there), identical defect class: WHERE strips the rows being counted before the counter runs → always-zero conditional count.

### Logic trace on responder's own example [declined, declined, declined, paid, declined, paid], single subscription_id

Step 1 — WHERE status='paid' evaluates first (verified vs trino.io/docs/467/functions/window.html WebFetch 2026-06-10: "they run after the HAVING clause but before the ORDER BY clause" → window functions evaluate AFTER WHERE/GROUP BY/HAVING).

After WHERE: only the 2 paid rows remain in the partition. All 4 declined rows are filtered out before the window sees anything.

Step 2 — window `COUNT(CASE WHEN status='declined' ...) OVER (PARTITION BY subscription_id ORDER BY attempted_at ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)` evaluates over the 2-row reduced partition:
- Paid row #1 (originally pos 4): frame contains zero preceding rows → COUNT = 0.
- Paid row #2 (originally pos 6): frame contains 1 preceding row (paid #1, NOT declined) → COUNT = 0.

Actual query output for both paid rows: prior_declines = 0. Silent always-zero wrong result.

### The responder's stated example is internally INCONSISTENT

Responder claims:
- Paid #1 → prior_declines = 3
- Paid #2 → prior_declines = 0 ("recent declined broke the streak")

Neither matches:
- The actual query (WHERE kept): 0, 0 (always-zero).
- The query with WHERE removed (window over all rows, UNBOUNDED PRECEDING): 3, 4 (cumulative: paid #1 = 3 earlier declines; paid #2 = 3 earlier + 1 recent = 4). Cumulative ≠ consecutive-run.

So even the "this is what my query produces" walkthrough is wrong on its own terms — three different stories (claimed output, actual-with-WHERE, actual-without-WHERE), none consistent.

### Two compounding defects, not one

(a) WHERE-before-window strips the counted type → always-zero (same root cause as iter951 Q4 WHERE-before-GROUP-BY).

(b) Frame `ROWS UNBOUNDED PRECEDING AND 1 PRECEDING` is wrong even if WHERE were removed: it counts ALL prior declines in the subscription's history, not the consecutive run since the last paid. The user's spec ("3 declined in a row then paid → 3 prior declines") requires the streak to RESET at each paid. Correct shape needs either (i) a streak_id from gaps-and-islands LAG-flag + running-SUM grouping (count declines per streak ending in paid), or (ii) a row-level COUNT scheme that resets at each paid event.

(c) Internal inconsistency in the worked example is the most dangerous part: a reader will trust the prose ("first paid → 3, second → 0") and not realize the SQL doesn't actually produce that.

### Scope

- NOT a dialect/syntax slip: the SQL parses and executes; the failure mode is silent wrong-result.
- NOT a missing resource: r07 B-Streak L3155-3230 teaches the correct count-per-streak shape (aggregate over the FULL streak THEN reduce / filter to the boundary event). iter951 teacher state.json describes this anchor as PRESENT-WITH-LINES.
- IS a responder synthesis slip on a 2nd successive surface in the same family: filter-then-count-the-filtered-out-type now manifests on a window-function surface in addition to last sweep's GROUP-BY surface.

## Q2/Q3/Q4 = TEXTBOOK CLEAN

Q2 simple comparison filter; NULL > x → UNKNOWN → excluded handling is correct per Trino comparison semantics (no special-case needed for "no coupon" orders since UNKNOWN drops them).

Q3 ROW_NUMBER() PARTITION BY category ORDER BY LENGTH(product_name) DESC, WHERE rn=1 — canonical argmax-per-group; LENGTH(varchar) returns char count per Trino 467 functions/string.html; tie-break by product_name ASC is the standard deterministic tie-break and correctly noted. No broken-alternative menu.

Q4 COUNT(*) for one-row-per-user grain vs COUNT(DISTINCT user_id) for multi-row/SCD/event-log grain — exactly the right framing. "Run both and compare; ask the data team" is the right action for an engineer who doesn't know the table grain.

## iter953 DISPOSITION RECOMMENDATION = LIGHT FIX-A DEFANG (escalate on 2nd-instance recurrence)

Reasoning:
- iter951 Q4 explicitly RECOMMENDED "RE-PROBE-DON'T-CHURN — escalate to FIX-A ONLY if filter-then-count defect recurs in 2+ further sweeps without intervening clean answer."
- iter952 Q1 IS that recurrence. No intervening clean answer between iter951 Q4 (1st instance) and iter952 Q1 (2nd instance) — they are the two consecutive surfaces probed for this exact defect family.
- Per the re-probe-don't-churn → FIX-A-on-recurrence doctrine, this crosses the escalation threshold.
- iter952 teacher state.json confirms the correct count-per-streak final shape IS taught findably at r07 B-Streak L3155-3230 (aggregate over full streak THEN filter/reduce; the Layer 3 inner subquery `SELECT user_id, streak_id, COUNT(*) FROM streaks GROUP BY user_id, streak_id` shape is present with line numbers). The positive canonical exists — what's missing is an explicit anti-pattern defang of the "filter-on-target-event-FIRST then count the OTHER type" trap.
- A LIGHT FIX-A is justified BECAUSE the positive shape is present (low new-card-over-attracts risk: not adding a new neighborhood, just defanging within an existing dense one) AND because the recurrence is now silent-wrong-result class (worst analytics failure mode) on a distinct surface (window function), not just a synthesis blip on a single surface.

Proposed LIGHT FIX-A (near r07 B-Streak L3155-3230):
- WRONG-mark the filter-then-count anti-pattern in BOTH surface forms:
  - Surface A (WHERE-before-GROUP-BY, iter951 Q4): `SELECT streak_id, SUM(CASE WHEN status='failed' THEN 1 ELSE 0 END) FROM streaks WHERE status='success' GROUP BY streak_id` — always 0 because WHERE strips the failures before SUM sees them.
  - Surface B (WHERE-before-WINDOW, iter952 Q1): `SELECT ..., COUNT(CASE WHEN status='declined' THEN 1 END) OVER (PARTITION BY ... ORDER BY ... ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) FROM t WHERE status='paid'` — always 0 because WHERE strips the declines before the window frame sees them.
- One-sentence rule: "WHERE evaluates before GROUP BY/HAVING/window-function per sql/select.html. If you filter to your target event in WHERE and then try to count the OTHER event type via SUM(CASE) or COUNT(CASE) OVER, you get 0 every time — the other type is no longer in the row set. Aggregate over the FULL streak/frame first; THEN reduce to streaks ending in the target event."
- Lead the CORRECT shape (already present at r07 B-Streak L3187-3195): inner CTE COUNT/SUM per (user_id, streak_id) over UNFILTERED rows → outer filter to streaks whose last row is the target event.
- Defang format per `feedback_defang_donotwrite_snippets.md`: do NOT use DO-NOT-WRITE-style snippets in isolation — inline-mark the WRONG SQL with a clear WRONG marker and make the canonical block the copy-attractive one.
- Place near r07 B-Streak L3155-3230 (existing dense gaps-and-islands neighborhood; same-resource same-section reduces new-card-over-attracts-adjacent risk per `feedback_new_card_over_attracts_adjacent.md`).

Alternative (less preferred): one more re-probe before FIX-A. If the teacher judges the 2nd instance still a thin one — e.g., wants a 3rd data point with the "for each shipped order count events leading up to it" or "for each session-end count clicks in the session" surface — that is defensible but the escalation criterion stated explicitly in iter951 ("recurs in 2+ further sweeps without intervening clean answer") is already met here. My recommendation is LIGHT FIX-A now.

Do NOT touch:
- r07 L37 (HAVING-perf reword iter948 holding).
- r07 L3155 leading canonical (already correct — the FIX-A is an ADDITIVE defang sub-card adjacent to it, NOT a rewrite).
- r07 L1624 (anti-nesting).
- r23 §3.1G argmax canonical.
- Federation row.
- Percentile / INTERVAL qualifier / COUNT(DISTINCT) single-arg / partition DDL cards.

## Pins reinforced (verified vs trino.io/docs/467 + WebFetch 2026-06-10)

- Window functions evaluate AFTER WHERE/GROUP BY/HAVING per functions/window.html: "they run after the HAVING clause but before the ORDER BY clause."
- WHERE filtering on the target event before counting the OTHER event via SUM(CASE) / COUNT(CASE) OVER = always-0 silent wrong result (now confirmed on BOTH GROUP-BY surface iter951 Q4 AND window-function surface iter952 Q1 — same root cause).
- `ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING` counts CUMULATIVE prior rows in the partition, NOT a consecutive run from the last boundary event. Consecutive-run reset requires streak_id (gaps-and-islands LAG-flag + running-SUM) or per-event reset logic.
- Gaps-and-islands per-streak count canonical = aggregate over FULL streak THEN filter to streaks ending in target event (r07 B-Streak L3187-3195 anchor).
- LENGTH(varchar) returns char count per functions/string.html; ROW_NUMBER()=1 argmax-per-group canonical valid; tie-break via secondary ORDER BY column.
- NULL > x → UNKNOWN → row excluded by WHERE (standard 3VL).
- COUNT(*) vs COUNT(DISTINCT col) grain-dependent — engineer must know the table grain to choose.
- Federation (4.49944/310) only un-passed row — bulletproofed angles only; not probed iter952.

## Bottom line

Overall 4.21875 PASS (margin +0.71875). Q1 is a 2nd-instance recurrence of the iter951 Q4 filter-then-count always-zero gaps-and-islands bug, now on a window-function surface in addition to last sweep's GROUP-BY surface. The defect is silent-wrong-result class. Per the escalation criterion stated in iter951's recommendation, escalate to LIGHT FIX-A defang at r07 B-Streak L3155-3230 — additive WRONG-mark on both filter-then-count surfaces, leading with the existing-correct full-streak-then-reduce canonical. Do NOT bump state.json (already 952; passed=true preserved).
