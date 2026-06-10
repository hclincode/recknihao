# iter956 — Judge Feedback (DEFAULT NO-OP sweep; teacher ZERO edits; gaps-and-islands re-probe #6)

**Overall: 4.25 PASS** (Q1 2.0 / Q2 5.0 / Q3 5.0 / Q4 5.0)

## Per-question scores

| Q | Topic | Acc | Comp | Clar | Act | Avg |
|---|---|---|---|---|---|---|
| Q1 | Gaps-and-islands count-other-type-before-boundary (RE-PROBE #6, defang #2) | 1.5 | 2 | 3 | 1.5 | **2.0** |
| Q2 | COUNT(*) GROUP BY currency (columnar/NULL-bucket/spill) | 5 | 5 | 5 | 5 | **5.0** |
| Q3 | EXISTS / IN semi-join for "changed email at least once" | 5 | 5 | 5 | 5 | **5.0** |
| Q4 | EXISTS to avoid one-to-many JOIN fan-out (returned items) | 5 | 5 | 5 | 5 | **5.0** |

**Overall avg = 4.25 → PASS** (governs; Q1 below threshold but dragged up by three clean 5.0s).

---

## Q1 verdict — TRACE on [view1, view2, purchase1, view3, purchase2]

`streak_id = SUM(CASE WHEN event='purchase' THEN 1 ELSE 0 END) OVER (PARTITION BY session_id ORDER BY event_at)` is a running sum INCLUSIVE of the current row, so it increments ON each purchase row:

- view1 → 0, view2 → 0, purchase1 → 1, view3 → 1, purchase2 → 2

Streaks built: streak0={view1,view2}, streak1={purchase1,view3}, streak2={purchase2}.

per_streak reduce:
- streak0: view_count=2, MAX_BY(event,event_at)=view2='view' → filtered out
- streak1: view_count=1, MAX_BY=view3='view' → filtered out (purchase1 is NOT the latest row of its own streak)
- streak2: view_count=0, MAX_BY=purchase2='purchase' kept, but `view_count > 0` strips it

RESULT: empty / no correct rows. Correct answers (purchase1→2 preceding views, purchase2→1) NEVER produced.

### Three-axis bug verdict
- **(a) ALWAYS-ZERO PRE-FILTER bug — DID NOT RECUR.** No `WHERE event='view'` or `WHERE event='purchase'` strips rows before the count; the streaks CTE has no WHERE; `COUNT(*) FILTER (WHERE event='view')` operates over full data; the `WHERE ending_event='purchase'` is AFTER aggregation. The iter953/955 strengthened defang's PRIMARY lesson (no pre-filter → no filter-then-count always-zero) HELD. Confirm closed.
- **(b) STREAK-CONSTRUCTION / ASSOCIATION error — CONFIRMED.** The running-sum-of-target-flag opens the new streak ON the target (purchase STARTS a streak with the FOLLOWING views), so the views BEFORE a purchase sit in `streak_id - 1`. Meanwhile `MAX_BY(event, event_at)` ending-event check assumes the target ENDS the streak. Those two constructions are incompatible — together they return ~nothing. Correct association needs either (i) a LAG-change flag so the run + its terminating target share a streak_id with the target at the END (the defang's B-Streak skeleton), OR (ii) read `streak_id - 1` consistently.
- **(c) GROUP BY analysis error — CONFIRMED.** Final SELECT references `session_id` but per_streak `GROUP BY streak_id` only. `session_id` is neither in GROUP BY nor aggregated → Trino "must be an aggregate or appear in GROUP BY" parse-time error. Even if (b) were fixed, this would still throw.

### Synthesis-ceiling disposition

This is the gaps-and-islands "count-run-before-boundary" pattern at or near the Haiku **synthesis ceiling**. After 6 re-probes and the iter953/955 strengthened defang, the responder has internalized the specific defanged trap (the PRE-FILTER arc stays closed) but still cannot reliably ASSEMBLE the full correct streak query in a novel domain — it picks a target-starts-the-streak flag and pairs it with a target-ends-the-streak reduction, then adds an unrelated GROUP BY error on top.

**RECOMMENDATION: STOP churning the gaps-and-islands defang.** The B-Streak skeleton + defang teach the correct construction; further defang churning will NOT reliably fix the responder's query assembly. The always-zero arc — which was the original FAIL cause — is closed. Accept that this hard pattern occasionally costs a single Q (Q1 here cost 3.0 vs a 5.0, dropping overall from 5.0 to 4.25 — still a comfortable PASS). **Return to breadth probing.** Per iter955 NO-OP policy: no resource edit warranted; this is durable noise around a hard pattern, not a new findability gap.

---

## Q2 / Q3 / Q4 — clean

- **Q2**: `SELECT currency, COUNT(*) FROM payments GROUP BY currency ORDER BY payment_count DESC` valid Trino 467 (alias resolves in ORDER BY). Columnar single-column scan, NULL gets its own group, hash-aggregate spillable — all accurate. Clean.
- **Q3**: `SELECT DISTINCT u.user_id FROM users u WHERE EXISTS (SELECT 1 FROM user_email_history h WHERE h.user_id = u.user_id)` is correct for "changed email at least once" (every history row = a change). IN variant equivalent. SemiJoin note matches Trino 467 planner behavior. Clean.
- **Q4**: `WHERE EXISTS (... AND oi.returned = true)` correctly avoids fan-out — order with N returned items still appears once. INNER JOIN + DISTINCT alt also valid. Diagnosis of one-to-many JOIN row inflation is on-target. Clean.

---

## Rubric topic touches

- **gaps-and-islands count-other-type-before-boundary** (r07 L3226-3263 B-Streak filter-then-count defang): re-probe #6 — defang's PRE-FILTER arc HELD (no recurrence); responder broke on a DIFFERENT axis (streak-construction + session_id GROUP BY). At synthesis ceiling.
- **GROUP BY correctness**: regression on Q1 final SELECT.
- **COUNT GROUP BY basics**: Q2 clean.
- **EXISTS/IN semi-join**: Q3 clean.
- **One-to-many JOIN fan-out / EXISTS-vs-DISTINCT**: Q4 clean.

## Federation

Not probed (per directive; r22 §13.x locks intact).

## Verdict

**PASS 4.25.** No teacher action required. Recommend the loop pivot away from gaps-and-islands re-probes — the defang has done its job on the always-zero arc, and the residual streak-construction failures are synthesis-ceiling noise that won't yield to more defang churning.
