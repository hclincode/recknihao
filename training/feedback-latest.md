# Judge Feedback — iter885 (EXTENDED PHASE)

**Overall: 4.50 PASS** (per-Q averages 4.94 / 4.875 / 3.50 / 5.00 = 18.3125 / 4 = **4.578**) — margin +1.08 over the 3.5 threshold. Overall average governs; NO per-Q veto. ONE real Q3 explanation defect (FIRST_VALUE/LAST_VALUE default-frame conflation) that the EXISTING resource card already contradicts → **iter886 = NO-OP (resource is correct; responder synthesis slip)**.

**Federation NOT probed** — all 4 questions are window-function / regexp topics. The federation row (4.49944/310) is UNCHANGED this iteration.

PIN: Trino 467. All dialect facts VERIFIED against trino.io/docs/467 (window.html, sql/select.html window-frame section, functions/regexp.html) via WebFetch on 2026-06-10 — NOT from resources/.

---

## Verification log (trino.io/docs/467)

- **sql/select.html (window frame):** "The default frame is RANGE UNBOUNDED PRECEDING, which is the same as RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW" — frame "encompasses all rows from the start of the partition up to the last peer of the current row." With NO ORDER BY, all rows are peers so the default RANGE frame = the whole partition.
- **window.html:** first_value(x) "Returns the first value of the window"; last_value(x) "Returns the last value of the window"; row_number() "Returns a unique, sequential number for each row, starting with one, according to the ordering"; rank() ties "produce gaps in the sequence".
- **regexp.html:** "All of the regular expression functions use the Java pattern syntax" → `|` alternation supported (java.util.regex). regexp_like is a *contains* op: "The pattern only needs to be contained within string, rather than needing to match all of string." `(?i)` inline flag: "Case-insensitive matching (enabled via the (?i) flag) is always performed in a Unicode-aware manner."

---

## Per-question scoring

### Q1 — running account balance (cumulative SUM of signed amounts per user)
`SUM(amount) OVER (PARTITION BY user_id ORDER BY transaction_date) AS account_balance`

- Accuracy **5** — Correct. Default frame for `SUM(x) OVER (... ORDER BY ...)` is RANGE UNBOUNDED PRECEDING..CURRENT ROW = cumulative through the current row's peer group. The responder's **peer/RANGE-default explanation is ACCURATE and a genuinely subtle, correct nuance**: same-date rows are peers under RANGE, so all transactions on the same date show the cumulative total *through end of that date*; adding a unique tiebreaker (`ORDER BY transaction_date, transaction_id`) collapses the peer group to one row each → true per-transaction running total. Verified vs sql/select.html ("up to the last peer of the current row").
- Completeness **5** — Covers PARTITION isolation, ORDER BY accumulation, the peer/tie nuance, and the tiebreaker fix.
- Clarity **4.75** — Clear; "peers" defined in context.
- Actionability **5** — Engineer can paste and knows exactly how same-date rows behave and how to change it.
- **Per-Q avg 4.94.** No defect.

### Q2 — second-cheapest item per category
`ROW_NUMBER() OVER (PARTITION BY category ORDER BY price ASC)` in subquery, outer `WHERE price_rank = 2`

- Accuracy **5** — Correct. ROW_NUMBER assigns a unique sequential rank per partition by ascending price; `= 2` yields the 2nd-cheapest per category. Window fn can't sit in WHERE (no QUALIFY in 467) so the subquery is required — handled. RANK/DENSE_RANK aside is loosely worded but accurate enough (ROW_NUMBER is the right pick for "exactly the 2nd row" semantics; RANK/DENSE_RANK change behavior on price ties — the responder noted this).
- Completeness **5** — Subquery requirement + tie-handling variants covered.
- Clarity **4.5** — The RANK/DENSE_RANK aside is slightly hand-wavy but not wrong.
- Actionability **5** — Directly usable.
- **Per-Q avg 4.875.** No defect.

### Q3 — change since first / onboarding score (each row minus the customer's FIRST score) — **DEFECT (false explanation)**
`score - FIRST_VALUE(score) OVER (PARTITION BY customer_id ORDER BY metric_date ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS change_since_first`

**(c) DISPOSITIVE FACT:** `FIRST_VALUE(x) OVER (PARTITION BY p ORDER BY o)` with the **DEFAULT frame** (RANGE UNBOUNDED PRECEDING AND CURRENT ROW) **ALREADY returns the partition's FIRST value for every row.** FIRST_VALUE returns the value at the *first row of the frame*; the default frame STARTS at `UNBOUNDED PRECEDING` (the partition's first row), so the first-in-frame row never changes as the current row advances. The explicit `... AND UNBOUNDED FOLLOWING` only extends the *end* of the frame — which FIRST_VALUE does not read — so it is **harmless but unnecessary** and does NOT change FIRST_VALUE's result.

The responder's claim — *"Without [the explicit UNBOUNDED FOLLOWING frame], Trino defaults to a smaller frame that can give you the current row's value instead of the true first row, which would make the change always zero"* — **is FALSE.** That is the **LAST_VALUE default-frame trap MIS-ATTRIBUTED to FIRST_VALUE**: LAST_VALUE's default frame ENDS at the current row, so *LAST_VALUE* returns the current row's value and needs the explicit frame. FIRST_VALUE has the opposite property. The responder inverted the two functions' frame behavior — a wrong mental model.

- **QUERY RESULT: CORRECT** (the redundant frame is harmless for FIRST_VALUE; the math `score - first_score` is right).
- **EXPLANATION: FALSE** (FIRST_VALUE does NOT return the current row / "change always zero" by default — that is LAST_VALUE).

- Accuracy **2.5** — Correct result, but a confidently-stated false causal claim about FIRST_VALUE's default-frame behavior. A SaaS engineer who internalizes "FIRST_VALUE needs UNBOUNDED FOLLOWING or it gives the current row" will mis-debug future window queries. Verified false vs window.html ("Returns the first value of the window") + sql/select.html (default frame starts at UNBOUNDED PRECEDING).
- Completeness **4** — Pattern, partition, ordering, the subtraction all present; the "critical piece" framing is the part that's wrong.
- Clarity **4** — Reads clearly; the clarity makes the false claim *more* likely to mislead.
- Actionability **3.5** — The query is copy-runnable and produces correct output, so the engineer can ship it; the false rationale costs a point.
- **Per-Q avg 3.50.** DEFECT (false explanation, correct result).

**Diagnosis — is there a resource card, and is it correct?** YES, and it is CORRECT. `resources/07-analytical-query-patterns.md` **Pattern B3** (~L3644-3696, "first_value / last_value / nth_value — the default-frame footgun") already distinguishes the two exactly right:
- L3654: *"`first_value(x) OVER (PARTITION BY p ORDER BY o)` — Returns the first row's value in the partition. **Safe with the default frame** — the frame starts at `UNBOUNDED PRECEDING`, so the first row is always in-frame. (use default frame — works)"*
- L3655: *"`last_value(x) ...` — **Returns the CURRENT row's value** ... NOT the partition's last value. The frame ENDS at current row ... **You MUST set the frame explicitly:** `... ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING`."*
- L3693 DO-NOT-WRITE row reinforces the LAST_VALUE silent-wrong trap.

The card teaches the **OPPOSITE** of the responder's false claim. So this is a **RESPONDER SYNTHESIS SLIP**, not a resource gap — the responder either didn't land on B3 or conflated the two rows of its table. The resource is already accurate, copy-attractive, and correctly anchored.

### Q4 — filter tickets whose subject contains ANY of several keywords
`regexp_like(subject, 'payment|invoice|billing')`; `(?i)` for case-insensitivity

- Accuracy **5** — Fully correct. regexp_like uses Java pattern syntax (verified) → `|` alternation works; it's a *contains*/partial match (verified verbatim) so any keyword anywhere in the subject matches; `(?i)` inline case-insensitive flag is supported (verified verbatim, Unicode-aware). Far cleaner than chained `OR LIKE '%...%'`.
- Completeness **5** — Alternation + partial-match + case-insensitivity all addressed.
- Clarity **5** — Plain explanation of `|` and `(?i)`.
- Actionability **5** — Drop-in replacement for the OR-LIKE chain.
- **Per-Q avg 5.00.** No defect.

---

## Overall

| Q | Acc | Comp | Clar | Act | Avg |
|---|---|---|---|---|---|
| Q1 running balance + peer/RANGE | 5 | 5 | 4.75 | 5 | 4.94 |
| Q2 ROW_NUMBER 2nd-cheapest | 5 | 5 | 4.5 | 5 | 4.875 |
| Q3 FIRST_VALUE change-since-first | 2.5 | 4 | 4 | 3.5 | 3.50 |
| Q4 regexp_like alternation + (?i) | 5 | 5 | 5 | 5 | 5.00 |
| **Overall** | | | | | **4.578 → 4.50** |

**Verdict: PASS** (overall 4.50, threshold 3.5, margin +1.08). Three clean answers; one correct-result/false-explanation defect on Q3.

## iter886 recommendation — **NO-OP** (NOT FIX-A)

The directive's FIX-A condition was *"if Q3's FIRST_VALUE/LAST_VALUE default-frame explanation is a real defect AND a card distinguishing them needs to exist."* The explanation **IS** a real defect — but **the card already exists and is already correct** (Pattern B3, r07 L3644-3696). Adding/editing a card would CHURN a correct pin for what is a responder synthesis slip, not a content gap. Per the iter882 lesson (do NOT flag/repair correct content) and the reconcile-don't-append memory, **iter886 = DEFAULT NO-OP.**

- Do NOT add a new FIRST_VALUE/LAST_VALUE card — B3 covers it correctly.
- Do NOT mark B3 (or any iter534-884 pin) as defective; it is verified-accurate vs window.html + sql/select.html.
- OPTIONAL micro-polish ONLY (skip if it churns any pin): the B3 first_value row could grow ONE keyword anchor so the responder lands there on "change since first / since onboarding / minus the first score / baseline delta" phrasings — e.g. add to the B3 keyword-anchor line: *"change since first value, delta from baseline/onboarding score, value minus partition's first, FIRST_VALUE default frame is safe (do NOT add UNBOUNDED FOLLOWING for first_value)."* This is a findability nudge, not a correctness fix.
- PIN 467. NO federation edits. DO NOT bump training/state.json (already passed).

**EXPLICIT answer to (c):** `FIRST_VALUE(x) OVER (PARTITION BY p ORDER BY o)` with the default frame (RANGE UNBOUNDED PRECEDING AND CURRENT ROW) returns the **partition's FIRST value** for every row (frame starts at UNBOUNDED PRECEDING; first-in-frame row is fixed). The responder's claim that without the explicit `UNBOUNDED FOLLOWING` frame FIRST_VALUE returns the current row's value / "change always zero" is **FALSE** — it is the **LAST_VALUE** default-frame trap mis-attributed to FIRST_VALUE. The query result is correct (the explicit frame is harmless for FIRST_VALUE); the explanation is a genuine false claim = the Q3 defect.
