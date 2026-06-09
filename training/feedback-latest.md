# Judge Feedback — Iter 835 (EXTENDED PHASE)

DEFAULT NO-OP durability sweep (teacher made ZERO resource edits). 4 SQL-fundamentals probes. Federation NOT probed (row stays 4.49944/310, FAIL).

All dialect claims verified against trino.io/docs/467 (string / conditional / comparison / datetime .html) on 2026-06-09.

---

## Per-Q scores

### Q1 — zero-pad order id to 8 chars ('00000042') — `lpad(CAST(order_id AS VARCHAR), 8, '0')`
- Accuracy: **4** — Core canonical `lpad(CAST(order_id AS VARCHAR), 8, '0')` is CORRECT and VERIFIED (lpad(string,size,padstring) left-pads; CAST numeric→VARCHAR required, no implicit coercion). BUT the gloss "order 1234567 stays '1234567' (doesn't add padding if already 8+ characters)" is WRONG on two counts: (1) `1234567` is only 7 digits, so it would become `'01234567'` (8 chars) — the example is internally inconsistent and self-contradicting; (2) lpad **TRUNCATES** when input length > size (VERIFIED docs: "If size is less than the length of string, the result is truncated to size characters") — so a 9+ digit order id like `123456789` silently becomes `'12345678'`, **losing the leading digit**. For an ID column this is a real data-integrity risk that was omitted, and the "stays unchanged if 8+" framing actively misleads (it implies no-op, when reality is truncation).
- Completeness: **3.5** — Answers the literal ask (42→'00000042') and flags the CAST requirement, but omits the truncate-if-longer behavior that matters specifically for IDs (the exact column type asked about).
- Clarity: **4.5** — Clear, concise, good worked example for the 42 case.
- Actionability: **4.5** — Engineer can paste it and it works for the stated case; the misleading 8+ claim slightly undercuts trust.
- **Q1 avg: 4.125**

### Q2 — percent change with divide-by-zero guard — `(current - previous) * 100.0 / NULLIF(previous, 0)`
- Accuracy: **5** — VERIFIED. NULLIF(previous,0)→NULL when previous=0, so division yields NULL (no error, no abort); `*100.0` forces decimal (avoids integer truncation); (250-200)*100.0/200 = 25.0. All correct.
- Completeness: **5** — Fully addresses divide-by-zero safety; also offers the "cleaner than CASE WHEN" framing.
- Clarity: **5** — Explains each piece.
- Actionability: **5** — Drop-in.
- **Q2 avg: 5.00**

### Q3 — extract hour 0-23 for peak-usage grouping — `EXTRACT(HOUR FROM recorded_at)`
- Accuracy: **5** — VERIFIED. EXTRACT(HOUR FROM ts)→integer 0-23; '...14:32:09'→14. EPOCH and MICROSECOND exclusion claim is CORRECT — Trino 467 EXTRACT fields are YEAR/QUARTER/MONTH/WEEK/DAY/DAY_OF_MONTH/DAY_OF_WEEK/DOW/DAY_OF_YEAR/DOY/YEAR_OF_WEEK/YOW/HOUR/MINUTE/SECOND/TIMEZONE_HOUR/TIMEZONE_MINUTE; EPOCH and MICROSECOND are NOT supported (Postgres-only), so they would parse-error in Trino as the responder stated.
- Completeness: **4.75** — Includes the GROUP BY usage. Minor: did not offer the equivalent one-token `hour(recorded_at)` convenience function (not required, no ding to accuracy).
- Clarity: **5** — Clean.
- Actionability: **5** — Directly usable for the group-by-hour goal.
- **Q3 avg: 4.9375**

### Q4 — later of two dates per row, no subquery — `greatest(trial_ended_at, subscription_started_at)`
- Accuracy: **5** — VERIFIED. greatest() returns the largest arg row-wise; returns NULL if ANY arg is NULL (docs: "Like most other functions in Trino, they return null if any argument is null" — explicitly differs from Postgres). Responder surfaced the NULL caveat proactively and offered a COALESCE sentinel workaround. Correct.
- Completeness: **5** — NULL caveat + workaround; no subquery as asked.
- Clarity: **5** — Clear.
- Actionability: **5** — Drop-in, with the sentinel guard.
- **Q4 avg: 5.00**

---

## Overall

| Q | Accuracy | Completeness | Clarity | Actionability | Q avg |
|---|---|---|---|---|---|
| Q1 | 4 | 3.5 | 4.5 | 4.5 | 4.125 |
| Q2 | 5 | 5 | 5 | 5 | 5.00 |
| Q3 | 5 | 4.75 | 5 | 5 | 4.9375 |
| Q4 | 5 | 5 | 5 | 5 | 5.00 |

**Overall avg = (4.125 + 5.00 + 4.9375 + 5.00) / 4 = 19.0625 / 4 = 4.766**

**Result: STRONG PASS** (overall avg 4.766 ≥ 3.5; margin +1.266; overall average governs, no per-Q veto).

---

## Defect / gap analysis

ONE real defect surfaced, and it is in covered content (the lpad/rpad fixed-width pad card at r23). The card is verified-correct on truncate-if-longer at the resource level (iter823 note confirms "rpad/lpad truncate" was verified), but the **responder DID NOT surface the truncate-if-longer behavior** and instead invented the misleading "stays unchanged if already 8+ characters" claim with an internally-inconsistent 7-digit example. This is a responder-slip + minor findability issue: the lpad card teaches the pad use-case but the truncate-on-overflow gotcha may not be prominent/keyword-anchored where a "zero-pad an ID to N chars" question lands. For an ID column (the exact ask), silent truncation of a 9+ digit value is a data-correctness hazard worth a copy-attractive one-liner.

This is NOT an accuracy FAIL of the canonical (the SQL is correct), but it is a genuine completeness/precision gap, so iter835 is **not fully clean**.

## iter836 directive — LIGHT FIX-A (truncate-on-overflow inoculation at the lpad pad card)

Reconcile IN-PLACE at the r23 lpad/rpad fixed-width pad card (around r23:586-604, the iter823-touched card). Do NOT churn the verified `lpad(CAST(x AS VARCHAR), N, '0')` zero-pad canonical. ADD a compact FENCED block (pipe-escape trap — no tables for any pipe content):
1. A TRUNCATE-ON-OVERFLOW warning specifically for ID zero-padding: `lpad('123456789', 8, '0')` -> `'12345678'` (input is 9 chars > 8, so the result is TRUNCATED to 8 chars and the LEADING digit is dropped — silent data loss for IDs).
2. The correct mental model: lpad only ADDS padding when input is SHORTER than size; when input is LONGER it CUTS to size (left side preserved, length-clamped). State plainly: lpad/rpad is "pad-OR-truncate to exactly N", not "pad up to at least N".
3. A guard idiom if IDs may exceed the width: size the pad target to the real max id width, or detect overflow before formatting.
4. Inline-DEFANG, each on its own un-copyable fenced line: the WRONG claim "an 8+ char value stays unchanged (lpad does nothing)" and the inconsistent "1234567 stays '1234567'" framing.
5. Keyword anchors: zero-pad id to N chars, lpad truncates if longer, pad id loses digits, fixed-width id format, lpad does nothing if already long, pad or truncate to exactly N.

VERIFIED for the teacher (trino.io/docs/467/functions/string.html, 2026-06-09): "Left pads string to size characters with padstring. If size is less than the length of string, the result is truncated to size characters." Confirms truncation. PIN Trino 467.

NO federation edits (r22 §13.x ZERO edits; federation row stays 4.49944/310, FAIL). HOLD all iter534-834 locks. DO NOT bump training/state.json (already 835).

Fresh adjacent probe suggestions: rpad truncate-on-overflow (right side), lpad with multi-char padstring cycling, `format('%08d', n)` numeric-native zero-pad alternative (no CAST, never truncates significant digits), substr-based width clamp.
