# Judge Feedback — iter928 (EXTENDED PHASE, re-probe sweep)

## Verdict: PASS — overall 4.969 (per-Q 5.00 / 4.875 / 5.00 / 5.00 = 19.875/4); margin +1.469. DEFAULT NO-OP. Teacher ZERO edits.

Overall average governs (no per-Q veto). FEDERATION NOT PROBED this sweep (4.49944/310 row UNCHANGED — still the only un-passed row; probe bulletproofed angles only).

---

## ★ Q1 BARE-STRING-DATE-LITERAL SLIP VERDICT = ONE-OFF CONFIRMED / SLIP CLOSED — NO FIX-A

The iter927 Q4 bare-string-date-literal defect did **NOT recur**. A1 wrote:

```sql
SELECT
  SUM(CASE WHEN signup_date <  DATE '2026-03-01' THEN 1 ELSE 0 END) AS signups_before,
  SUM(CASE WHEN signup_date >= DATE '2026-03-01' THEN 1 ELSE 0 END) AS signups_on_or_after
FROM signups
```

The responder used the **CORRECT `DATE '2026-03-01'` literal** (DATE keyword present) on BOTH comparison branches — the iter927 bare-string `'2026-03-01'` slip did NOT repeat.

- VERIFIED Trino 467 does NOT implicitly coerce varchar→date in comparisons (trino.io/docs/467 functions/comparison.html + WebSearch 2026-06-10: "Trino does not do implicit type coercion … will not convert between character and numeric types"; bare `date < varchar` raises `Cannot apply operator`). The DATE keyword is REQUIRED — and the responder supplied it. Query RUNS.
- SUM(CASE WHEN cond THEN 1 ELSE 0 END) two-bucket before/after conditional-count is CORRECT (pinned valid). `<` cutoff vs `>=` cutoff cleanly partitions every non-NULL signup_date into exactly one of the two buckets; the boundary 2026-03-01 falls into `signups_on_or_after` (correct "on/after" semantics). NULL signup_date counts in neither (reasonable).

**→ iter927 bare-string slip = ONE-OFF CONFIRMED, slip CLOSED, NO findability-anchor FIX-A, NO "wrong" card.** Resources are clean (r28 already WRONG-marks the bare-string form; `DATE '20YY-MM-DD'` canon appears ~189× across 16 files). The iter927 occurrence was a responder synthesis slip; one clean re-probe confirms it does not need a teacher edit.

**Q1 = 5.0** (Acc 5.0 / Comp 5.0 / Clar 5.0 / Act 5.0).

---

## ★ Q2 INTERPRETATION-NUANCE VERDICT = TECHNIQUE DIALECT-CORRECT, INTERPRETATION NARROW (completeness nuance, NOT a defect)

A2:
```sql
WITH ticket_sequence AS (
  SELECT ticket_id, event_type, event_at,
         LAG(event_type) OVER (PARTITION BY ticket_id ORDER BY event_at) AS prev_event_type
  FROM ticket_events
)
SELECT COUNT(DISTINCT ticket_id)
FROM ticket_sequence
WHERE event_type = 'reopened' AND prev_event_type = 'closed'
```

- (a) **`LAG(...) OVER (PARTITION BY ticket_id ORDER BY event_at)` is dialect-VALID** in Trino 467 (standard ANSI window function; pinned valid, window.html). Per-ticket ordering by event_at, prior event type = correct mechanism.
- (b) Detects an **ADJACENT** closed→reopened transition (the event IMMEDIATELY preceding a 'reopened' is 'closed'). COUNT(DISTINCT ticket_id) correctly collapses tickets with multiple such transitions to one.

**Interpretation nuance:** the question is "ever reopened after being closed at least once." The LAG-adjacent approach catches the common direct close→reopen, but would MISS a 'reopened' with intervening events between the close and the reopen (e.g. closed→escalated→reopened). A broader reading (reopen with ANY prior close) would need EXISTS / a running-count-of-prior-closes.

This is a **minor COMPLETENESS / interpretation nuance**, NOT a dialect/accuracy error: LAG-adjacent is a defensible reading of "reopened after closed" and the technique is dialect-correct. Weighed proportionally — small Comp ding only.

**Q2 = 4.875** (Acc 5.0 / Comp 4.5 / Clar 5.0 / Act 5.0).

---

## Q3 = 5.0 — `AVG(cardinality(tags))`

VERIFIED trino.io/docs/467 functions/array.html: `cardinality(x) → bigint` returns the array element count. AVG over rows = average tags per article. NULL/empty-array handling reasonable: `cardinality(NULL)=NULL` (skipped by AVG), empty array `=0` (counted). Correct.

**Q3 = 5.0** (Acc 5.0 / Comp 5.0 / Clar 5.0 / Act 5.0).

---

## Q4 = 5.0 — `COUNT(DISTINCT user_id)`

Correct for a one-row-per-change table — COUNT(DISTINCT user_id) gives the number of distinct users who made ≥1 plan change. Responder's caveat that COUNT(DISTINCT) is essential if the table is one-row-per-change (vs COUNT(*) which would count changes, not users) is apt. COUNT(DISTINCT) verified valid (aggregate.html, pinned).

**Q4 = 5.0** (Acc 5.0 / Comp 5.0 / Clar 5.0 / Act 5.0).

---

## Source verification (NOT against resources/; iter882 verify-first BOTH directions, PIN 467)

- DATE literal vs DATE column: VERIFIED no implicit varchar→date coercion → `DATE '2026-03-01'` required (comparison.html + WebSearch 2026-06-10) ⇒ Q1 CORRECT, slip did NOT recur.
- `cardinality(array) → bigint` element count: VERIFIED array.html ⇒ Q3 CORRECT.
- LAG OVER PARTITION/ORDER BY: standard window fn, pinned valid ⇒ Q2 technique CORRECT (interpretation narrow, not a defect).
- COUNT(DISTINCT): pinned valid ⇒ Q4 CORRECT.
- No doc-CORRECT claim falsely flagged; no doc-WRONG form blessed.

---

## iter929 directive — DEFAULT NO-OP

- **NO-OP. Teacher ZERO edits. NO FIX-A. NO "wrong" card. NO escalation.**
- Q1 bare-string-date-literal slip = ONE-OFF CONFIRMED / CLOSED (responder emitted `DATE '...'` correctly). Do NOT add a findability anchor — resources already correct (r28 WRONG-marks bare-string, DATE-canon ×189). Do NOT re-probe this exact angle again unless a NEW bare-string occurrence surfaces (would be 2nd instance → only then escalate).
- Q2 LAG-adjacent vs reopen-after-any-prior-close = interpretation nuance on a DEFENSIBLE reading + dialect-correct technique. RESPONDER synthesis interpretation, NOT a resource gap. NO card (count-of-entities / interpretation-shape family already pinned). OPTIONAL low-priority re-probe (SKIP if duplicative): "reopened after being closed at ANY earlier point (intervening events allowed)" to see if responder reaches for EXISTS / running-count-of-prior-closes vs LAG-adjacent.
- Do NOT mark Q1 SUM(CASE)+DATE-literal two-bucket, Q2 LAG-adjacent closed→reopened detection, Q3 AVG(cardinality), or Q4 COUNT(DISTINCT) wrong — all correct.
- Federation (4.49944/310) only un-passed row — bulletproofed angles only. Do NOT touch any iter534-927 pin. PIN 467. NO federation edits.
- **DO NOT bump training/state.json** (already passed; overall 4.969 PASS holds).
