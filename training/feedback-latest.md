# iter953 — LIGHT FIX-A verify sweep + Q1 RE-PROBE #3 of filter-then-count bug

**Overall: 3.59375 PASS** (margin +0.09375 — THIN). Per-Q: Q1 2.375 / Q2 5.00 / Q3 5.00 / Q4 5.00 = 17.375/4. OVERALL AVERAGE governs.

---

## TEACHER FIX-A VERDICT — DEFANG IS DIALECT-CORRECT AND CLEAN

Read r07 L3223-3251 (B-Streak Variants neighborhood, ADJACENT to the existing Layer-3 count-per-streak canonical L3200-3221). The teacher inserted a single new Variants bullet "Count the OTHER event type in the run right before a boundary event" with:

1. An inline-WRONG-marked fenced `-- ❌ WRONG (returns 0 every time — WHERE strips the counted 'declined' rows before GROUP BY / the window): ... WHERE status='paid' ... COUNT(*) FILTER (WHERE status='declined') ... -- DO NOT COPY` block;
2. A parenthetical pin "(same bug if you swap GROUP BY for COUNT(*) OVER (PARTITION BY streak_id) — windows also run AFTER WHERE)" — covers BOTH the GROUP-BY surface (iter951 Q4) AND the window surface (iter952 Q1);
3. A copy-attractive `-- ✅ CORRECT` block: per-streak CTE with `COUNT(*) FILTER (WHERE status='declined')`, `MAX(event_time)`, **`max_by(status, event_time) AS ending_status`** over UNFILTERED rows GROUP BY streak_id, then outer `WHERE ending_status='paid'` AFTER the aggregate;
4. A one-sentence RULE.

**Dialect verification:**
- WHERE-before-GROUP-BY-and-before-window: confirmed via WebFetch trino.io/docs/467/functions/window.html — "[window functions] run after the HAVING clause but before the ORDER BY clause" (so windows run AFTER WHERE/GROUP BY/HAVING; the iter953 state.json premise WebFetch + iter952 verify chain holds).
- `max_by(status, event_time)` — valid SINGLE aggregate per functions/aggregate.html ("Returns the value of `x` associated with the maximum value of `y` over all input values"); NOT a nested aggregate (the second arg is a plain column not another aggregate). Safe inside GROUP BY.
- The defang does NOT touch the Layer-1/2/3 skeleton (L3200-3221), the NESTED_WINDOW defang (L3206-3212), the two-GROUP-BY-stapled parse-error defang (L3214-3219), or the iter875 cross-ref prose (L3221). Pure additive sub-card in B-Streak Variants list — placement minimizes new-card-over-attracts-adjacent risk per `feedback_new_card_over_attracts_adjacent.md`.
- WRONG block uses the inline-mark-un-copyable format per `feedback_defang_donotwrite_snippets.md` (single contiguous fence with `❌ WRONG` header + `DO NOT COPY` trailer + canonical `✅ CORRECT` block adjacent), not the backfire-prone DO-NOT-WRITE-isolated form.

**Defang construction: CORRECT.** No skeleton corruption, no banner overlap, no NESTED_WINDOW collision, no skeleton dilution.

---

## Q1 RE-PROBE #3 VERDICT — DEFANG TOOK FOR THE LEAD, BUT THE SECONDARY "ALTERNATIVE" RE-COMMITS THE EXACT BUG (Acc 1.5 / Comp 3.0 / Clar 3.0 / Act 2.0 = 2.375)

This is the **broken-secondary-alternative meta-pattern** (iter936/943/948 Q4/iter950 Q3 family), NOT a clean 3rd recurrence of the underlying bug — but it IS a recurrence of "responder offers a `simpler form` that ships the exact anti-pattern the defang warns against, with a FALSE justification."

### LEAD form — TRACED CORRECT (defang lesson LANDED) but with frame imperfection

```sql
SELECT order_id, event, event_at,
       CASE WHEN event='delivered' THEN
         COUNT(*) FILTER (WHERE event='scan')
           OVER (PARTITION BY order_id ORDER BY event_at
                 ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)
       ELSE NULL END AS scans_before_delivery
FROM shipments
WHERE event IN ('scan','delivered')      -- keeps BOTH types
ORDER BY order_id, event_at
```

Trace on `[scan, scan, delivered, scan, delivered]` ordered by event_at:
1. WHERE keeps both event types → all 5 rows survive into the window evaluation.
2. Window evaluates AFTER WHERE per functions/window.html WebFetch 2026-06-10 — both types present.
3. delivered #1 (row 3): frame = rows {1,2} = [scan, scan] → FILTER counts scans → **2** (correct for that delivery).
4. delivered #2 (row 5): frame = rows {1,2,3,4} = [scan, scan, delivered, scan] → FILTER counts scans → **3**.

The LEAD AVOIDS the filter-then-count bug. Responder's diagnostic prose "you've removed all the scan rows, nothing left to count; you need to keep all rows" is CORRECT and matches the defang's RULE.

**But the frame `ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING` counts CUMULATIVE scans across the WHOLE partition history, NOT the consecutive run right before the current delivery.** The user explicitly asked for "the consecutive 'scan' events in the run right before it" — for delivered #2 the correct answer is **1** (only the single scan between deliveries 1 and 2), not 3. Resetting the run at each delivery requires the gaps-and-islands streak_id apparatus (LAG-flag at each delivery boundary + running-SUM streak_id), or `ROWS BETWEEN <reset-point> AND 1 PRECEDING` which is not directly expressible without a streak partition. **Secondary correctness imperfection** — accurate for the first delivery in each partition but over-counts on subsequent deliveries. The frame imperfection is independent of the filter-then-count defect.

### ALTERNATIVE "simpler" form — RE-COMMITS THE EXACT iter953 DEFANGED ANTI-PATTERN WITH A FALSE JUSTIFICATION

```sql
SELECT order_id, event_at,
       COUNT(*) FILTER (WHERE event='scan')
         OVER (PARTITION BY order_id ORDER BY event_at
               ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS scans_before_delivery
FROM shipments
WHERE event='delivered'    -- this is the EXACT iter953-defanged shape
```

Trace on same example:
1. WHERE event='delivered' runs FIRST — per sql/select.html WHERE runs before GROUP BY/HAVING and per functions/window.html windows run after HAVING. **All 3 scan rows are stripped before the window sees anything.**
2. Reduced partition has 2 rows: [delivered, delivered].
3. delivered #1: 0 preceding rows in reduced partition → **0**.
4. delivered #2: 1 preceding row (delivered #1) → FILTER WHERE event='scan' excludes it → **0**.

**Actual output: 0, 0 every time** (silent always-zero — worst analytics failure mode).

Responder's claim "This filters to just deliveries in the final result, but the window function still looks back across both scans and deliveries to count" is **FALSE**. Windows do NOT operate on pre-WHERE rows — windows run AFTER WHERE per functions/window.html. The scan rows were stripped by WHERE and the window sees only delivered rows.

**This is the EXACT shape the iter953 defang inline-WRONG-marks**: WHERE event='delivered' (= the defang's WHERE status='paid'), COUNT(*) FILTER (WHERE event='scan') OVER (...) (= the defang's COUNT(*) FILTER (WHERE status='declined') OVER (...)), and the defang's parenthetical "same bug if you swap GROUP BY for COUNT(*) OVER (PARTITION BY streak_id) — windows also run AFTER WHERE" directly covers this surface. The responder shipped the defanged form as a "simpler" alternative the user is invited to copy, **with a FALSE worked-prose justification that contradicts functions/window.html**.

### VERDICT — broken-secondary-alternative pattern; defang "took" for the lead but missed the secondary

- **Did the defang TAKE?** Partially. The LEAD form keeps both event types in WHERE and the diagnostic prose for the user's "filtered to just delivery rows then counting scans, I keep getting zero" problem is CORRECT — the responder explicitly says "you've removed all the scan rows, nothing left to count" matching the defang RULE. So for the primary answer, the defang's lesson is reflected.
- **But the secondary "simpler" alternative re-commits the exact anti-pattern** with a false "the window looks back across both types" justification — same broken-secondary-alternative meta-pattern as iter936/943/948 Q4/iter950 Q3 (correct lead + broken alternative menu).
- **NOT a clean 3rd recurrence** of the underlying always-zero bug (lead is bug-free) — but IS a 1st-instance recurrence of broken-alternative-after-defang. The defang did not prevent the responder from offering the defanged form as an "alternative" with a contradictory worked claim. The Haiku responder may be reading the inline-WRONG block as one possible shape rather than as banned.
- **Secondary frame imperfection** (cumulative vs consecutive-run) compounds the score loss but is independent of the defang.

Scoring: 1.5/3.0/3.0/2.0 = 2.375. Lead is correct + well-diagnosed (+) but cumulative-frame imperfection (-) + broken+falsely-justified alternative re-committing the defanged form (--). The "I keep getting zero" diagnosis is the genuine save — without it, the broken alternative would dominate.

---

## Q2/Q3/Q4 — TEXTBOOK CLEAN (5.00 each)

**Q2 5.00** — Total tax per state with zero-order-states question:
`SELECT state, SUM(tax_amount) FROM orders GROUP BY state` — clean baseline; correctly identifies that zero-order states will NOT appear because they have no rows in `orders`; correctly offers LEFT JOIN against a `reference.us_states` dimension + `COALESCE(SUM(tax_amount), 0)` to make zero-order states show as 0. Grain framing sound (one-row-per-state output regardless of order grain). NULL-safe with COALESCE wrap. Sound trade-off framing (which form depends on whether the user wants "states that have orders" vs "all 50 states including zero-tax states"). No dialect issues.

**Q3 5.00** — Subscriptions by status:
`SELECT status, COUNT(*) AS subscription_count FROM subscriptions GROUP BY status ORDER BY subscription_count DESC` — canonical group-count shape; ORDER BY references SELECT alias (valid per sql/select.html). No grain ambiguity. Clean.

**Q4 5.00** — Most expensive order per day keeping order_id:
```sql
SELECT order_date, order_id, order_total FROM (
  SELECT order_date, order_id, order_total,
         ROW_NUMBER() OVER (PARTITION BY order_date ORDER BY order_total DESC NULLS LAST) AS rn
  FROM daily_orders
) WHERE rn=1
```
Canonical argmax-per-group; `DESC NULLS LAST` explicit (sound — keeps non-NULL max at rn=1 even if NULLs exist; iter707 default-NULLS-LAST holds either way but explicit is fine). Diagnostic "GROUP BY date + MAX(order_total) loses order_id" is correct — the grouped query has no way to recover the order_id of the max-total row without argmax. Responder's phrasing "groups by date+total two columns" is a loose characterization of the GROUP-BY-pair workaround but the conclusion that it doesn't solve the problem is right. `max_by(order_id, order_total) GROUP BY order_date` is a concise alternative (single aggregate, valid per functions/aggregate.html), not required for credit.

---

## SCOPE + iter954 RECOMMENDATION

**Scope.** Defang construction is dialect-correct and well-placed. Q1 LEAD form is correct (defang's diagnostic lesson landed). Q1 ALTERNATIVE form re-commits the exact iter953-defanged form with a FALSE justification — broken-secondary-alternative meta-pattern. Q1 LEAD also has secondary frame imperfection (cumulative vs consecutive-run). Q2/Q3/Q4 textbook clean.

**iter954 = DEFAULT NO-OP / RE-PROBE-DON'T-CHURN.** Defang is brand-new (iter953); broken-secondary-alternative is a 1st-instance recurrence of the meta-pattern AFTER defang placement, not a clean 3rd recurrence of the underlying bug. Per the established re-probe-don't-churn doctrine (iter948-950-951-952 sequence), additive churn on a 1-iteration-old defang is premature. RE-PROBE next sweep with a fresh gaps-and-islands filter-then-count surface (e.g., "for each session-end event count clicks in the session", "for each shipped order count tracking events leading up to it") — verify whether the responder (a) leads with the both-types-in-WHERE shape and (b) does NOT offer the filter-to-target-only form as an alternative. Escalate to LIGHT FIX-A2 (a tighter inline anti-mark forbidding the "alternative" framing — perhaps "if a colleague suggests filtering to just the target rows in WHERE as a simpler form, that is wrong because...") ONLY if broken-secondary-alternative recurs on 2+ further sweeps. Frame imperfection (cumulative vs consecutive-run) is a SEPARATE defect family — only worth addressing if it recurs cleanly without filter-then-count noise.

**Do NOT** touch r07 L37 (HAVING-perf reword durable), r07 L3200-3221 (B-Streak Layer 1/2/3 skeleton + NESTED_WINDOW defang + two-GROUP-BY parse-error defang), r07 L3223-3251 (newly-added defang — 1 iteration old, leave to settle), r07 L1624 anti-nesting pin, r23 §3.1G argmax/min_by/max_by canonical, federation row (4.49944/310 untouched), percentile cards, INTERVAL qualifier cards, COUNT(DISTINCT) single-arg pin, PARTITIONED-BY guidance.

**PINS REINFORCED:**
- Window functions evaluate AFTER WHERE / GROUP BY / HAVING per functions/window.html ("run after the HAVING clause but before the ORDER BY clause") — WebFetch 2026-06-10 RE-CONFIRMED.
- Filter-to-target-event THEN count OTHER type (via WHERE before window or WHERE before GROUP BY) = always-0 silent wrong result on BOTH GROUP-BY surface (iter951 Q4) AND window surface (iter952 Q1, iter953 Q1 ALTERNATIVE).
- Correct gaps-and-islands per-streak count = aggregate over FULL streak (UNFILTERED, ALL TYPES KEPT) THEN reduce to streaks ending in target event via `max_by(status, event_time)` or analogous (r07 L3223-3251 anchor).
- `ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING` = cumulative across partition history; consecutive-run-since-last-boundary requires streak_id partition.
- max_by(x, y) valid single aggregate (x at max y); NOT nested aggregate (second arg plain column).
- ROW_NUMBER() OVER (PARTITION BY g ORDER BY metric DESC NULLS LAST) WHERE rn=1 = canonical argmax-per-group keeping all columns.
- SUM(...) GROUP BY dimension + LEFT JOIN dimension table + COALESCE(...,0) = canonical zero-rows-included pattern.
- Default NULLS LAST in 467 per `reference_trino_null_ordering_default.md`; explicit NULLS LAST harmless.
- COUNT(*) FILTER (WHERE pred) valid in aggregate AND window contexts.

**Broken-secondary-alternative meta-pattern recurrence note:** iter936/943/948 Q4/iter950 Q3 / iter953 Q1 — responder consistently offers a "simpler/cleaner alternative" that ships a broken form, often with false worked-prose justification. The pattern is independent of any specific bug family. Worth monitoring for cross-iteration tracking; current data is 5 instances over ~17 iterations. NO standalone defang yet — would require a meta-card that warns the responder against offering alternative menus, which is hard to instantiate findably.

Federation (4.49944/310) only un-passed row — bulletproofed angles only. PRESERVE full iter534-952 pin inventory. PIN 467.
