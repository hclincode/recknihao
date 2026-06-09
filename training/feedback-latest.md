# Judge Feedback — iter826

RE-PROBE of bool_or/bool_and NULL semantics (2nd-angle bulletproof check after iter825 FIX-A). All dialect claims VERIFIED against trino.io/docs/467 (aggregate.html, datetime.html). PIN Trino 467.

## Per-question scores

### Q1 — bool_or, all-NULL group must return FALSE not NULL  [DEFECT]
- **Accuracy: 2** — The PRIMARY recommendation `bool_or(severity='critical')` plus the explicit claim *"If all severities are NULL, bool_or() returns FALSE (not NULL)"* is WRONG. Verified vs trino.io/docs/467/functions/aggregate.html: the general rule states "Except for count(), count_if(), max_by(), min_by() and approx_distinct(), all of these aggregate functions ignore null values and return null for no input rows or when all values are null." bool_or/bool_and are NOT in that exception list. `severity='critical'` yields NULL when severity IS NULL, so an all-NULL group feeds `bool_or` over [NULL, NULL, ...] = **NULL, not FALSE**. The primary form therefore FAILS the engineer's explicit all-NULL edge case. The responder DID offer a correct secondary form `bool_or(COALESCE(severity,'unknown')='critical')` (forces NULL row to compare FALSE, so bool_or over all-FALSE returns FALSE) — but it is buried as "for extra safety" while the headline claim mis-answers the precise requirement that was asked.
- **Completeness: 3** — Covers TRUE/FALSE/NULL-per-row behavior and offers the COALESCE-input form, but does not state the correct all-NULL/empty-group=NULL rule, nor offer the wrap form COALESCE(bool_or(pred), false).
- **Clarity: 4** — Readable, concrete, explains NULL=NULL comparison.
- **Actionability: 3** — An engineer who copies the headline `bool_or(severity='critical')` ships a query that returns NULL on all-NULL groups — the exact bug they asked to avoid. Only by following the "extra safety" aside do they get correct behavior.
- **Q1 avg: (2+3+4+3)/4 = 3.00**

### Q2 — sum positives and negatives separately, one pass  [CLEAN]
- **Accuracy: 5** — `SUM(CASE WHEN response_time_ms>0 THEN response_time_ms ELSE 0 END)` / `<0` correct. `SUM(...) FILTER (WHERE ...)` verified as valid Trino 467 single-pass aggregate filter (aggregate.html: "supported for all aggregate functions", evaluated per row before aggregation). count_if note correct.
- **Completeness: 5** — Both one-pass forms + count_if for counts; notes identical plans.
- **Clarity: 5** — Clear, single scan emphasized.
- **Actionability: 5** — Copy-paste ready.
- **Q2 avg: 5.00**

### Q3 — bucket events by the hour  [CLEAN]
- **Accuracy: 5** — `date_trunc('hour', last_updated_at)` verified to floor to hour start (2:47:59 -> 2:00:00), returns same type, session-tz. The GROUP-BY-no-alias rule (repeat the expr or GROUP BY 1; Trino rejects SELECT alias in GROUP BY, GH#16533) is correct — good propagation of the iter824 fix.
- **Completeness: 5** — Floor semantics, GROUP BY form, ORDER BY, result type/tz all covered.
- **Clarity: 5** — Worked example clear.
- **Actionability: 5** — Runnable, avoids the alias trap.
- **Q3 avg: 5.00**

### Q4 — treat NULL discount as 0 in arithmetic  [CLEAN]
- **Accuracy: 5** — `price * (1 - COALESCE(discount_pct, 0)/100.0)` correct. Verified: NULL propagates through arithmetic in Trino 467; COALESCE(discount_pct,0) forces 0 so factor = (1-0) = no discount.
- **Completeness: 5** — Explains propagation + neutral-element idiom.
- **Clarity: 5** — Clear.
- **Actionability: 5** — Copy-paste ready.
- **Q4 avg: 5.00**

## Overall

| Q | Acc | Comp | Clar | Act | Avg |
|---|-----|------|------|-----|-----|
| Q1 | 2 | 3 | 4 | 3 | 3.00 |
| Q2 | 5 | 5 | 5 | 5 | 5.00 |
| Q3 | 5 | 5 | 5 | 5 | 5.00 |
| Q4 | 5 | 5 | 5 | 5 | 5.00 |

**Overall avg = (3.00 + 5.00 + 5.00 + 5.00) / 4 = 4.50 — PASS** (overall average governs; no per-Q veto).

## Q1 VERDICT — bool_or/bool_and-NULL is NOT bulletproofed; needs another FIX-A

The all-NULL -> FALSE claim IS A REAL DEFECT. Verified vs trino.io/docs/467: bare `bool_or(pred)` over an all-NULL/empty group returns **NULL, not FALSE**. The responder's headline recommendation directly fails the engineer's explicit "all-NULL must be FALSE" requirement, even though it accidentally embedded a correct alternative as an aside. This is the same class of slip iter824/825 targeted (NULL result of a boolean aggregate), now surfacing from the bool_or angle.

Note: the iter825 FIX-A r23 §3.1 card content is CORRECT (it states all-NULL/empty -> NULL not FALSE and offers the COALESCE wrap). The defect is FINDABILITY/landing: the Q1 "did any incident was critical" framing landed the responder on the bool_or summary line ("Returns TRUE if any input value is TRUE, otherwise FALSE") and it wrongly extrapolated that an all-FALSE-OR-NULL group returns FALSE, instead of reaching the NULL-semantics block. The fix must put the all-NULL=NULL correction + the two guaranteed-FALSE forms directly where the "any X / did any incident" / bool_or landing routes.

## iter827 DIRECTIVE — FIX-A (bool_or/bool_and all-NULL semantics, 2nd touch)

At the bool_and/bool_or card (r23 §3.1) AND the r07 boolean-flag-pivot card landing:
1. Sharpen, in a FENCED block keyword-anchored to "did any X", "any critical", "bool_or all null", "all-null group returns null", that a BARE `bool_or(pred)` / `bool_and(pred)` over an ALL-NULL or EMPTY group returns **NULL — NOT FALSE — NOT TRUE** (cite the aggregate.html exception-list rule: bool_or/bool_and are NOT in {count, count_if, max_by, min_by, approx_distinct}, so they ignore NULLs and return NULL when all inputs are null).
2. Make the COPY-ATTRACTIVE canonical the guaranteed-FALSE forms — provide BOTH:
   - wrap the aggregate result: `COALESCE(bool_or(severity='critical'), false) AS has_critical`
   - coalesce the input to a non-null sentinel: `bool_or(COALESCE(severity,'') = 'critical') AS has_critical`
   Explain each returns FALSE (not NULL) on an all-NULL group.
3. INLINE-DEFANG, on its own un-copyable line, the wrong claim: "all NULL -> bool_or returns FALSE" (bare bool_or over all-NULL returns NULL). Do NOT leave a copyable bare `bool_or(severity='critical')` as the headline answer to a "must be FALSE not NULL" framing.
4. Keep all pipe-bearing/check content in FENCED blocks (pipe-escape trap). PIN Trino 467. NO federation edits (r22 §13.x ZERO edits; federation row stays 4.49944/310). Preserve iter824 GROUP-BY-alias + split_part fixes and iter825 reconciliation text — sharpen/relocate the landing, do not churn the function-choice canonical.

(If a future 2nd-angle probe lands cleanly on the NULL=NULL block and states it correctly in its PRIMARY recommendation, downgrade to a findability-anchor-only touch. Until then the bool_or/bool_and-NULL topic is NOT bulletproofed.)
