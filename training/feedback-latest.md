# Judge Feedback — iter866 (EXTENDED PHASE)

**Overall: 4.84 STRONG PASS** (per-Q 5.00 / 5.00 / 5.00 / 4.375 = 19.375/4 = 4.84375; margin +1.34; overall average governs, no per-Q veto).

Federation NOT probed this iteration (row UNCHANGED 4.49944/310, still FAIL).

All dialect facts VERIFIED vs trino.io/docs/467 (datetime.html, string.html, regexp.html, aggregate.html) + WebSearch, 2026-06-10. PIN Trino 467.

---

## Q1 — count how many of ~8 boolean flag COLUMNS are TRUE in a SINGLE ROW (per-row, not across rows)

**THE iter865 Q3 PER-ROW-FLAG-COUNT FIX RE-PROBE.**

Scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 → **avg 5.00**

**FIX LANDED — CLEAN.** Responder gave the correct per-row shape:
`CAST(has_sso_enabled AS integer) + CAST(has_mfa_on AS integer) + ... AS features_enabled` with **NO GROUP BY**, explained CAST(boolean AS integer) → true=1/false=0, wrapped `COALESCE(flag,false)` for NULL safety, AND explicitly stated **"Do NOT use count_if() for this — that's an aggregate that counts TRUE rows per group, a different shape."**

Verified vs trino.io/docs/467:
- CAST(boolean AS integer) → 1/0 is established 467 behavior (documented in the pinned §3.1E "boolean → 1/0 scalar" card).
- aggregate.html: count_if IS an aggregate (it is one of the 5 ignore-nulls EXCEPTIONS: count, count_if, max_by, min_by, approx_distinct) — counts TRUE input ROWS per group, NOT columns in a row. The responder's shape-distinction is exactly right.

The iter866 FIX-A (per-ROW CAST-sum card + SHAPE-ROUTER + count_if defang adjacent to §3.1E/§11) **landed and routed correctly**. The misframe from iter865 (per-GROUP aggregate / "count_if cleaner") did NOT recur. No escalation to iter867.

---

## Q2 — convert milliseconds-since-epoch bigint (e.g. 1717612800000) to a readable timestamp

Scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 → **avg 5.00**

Responder: `from_unixtime(event_timestamp_ms / 1e3) AS event_timestamp`; CRITICAL gotcha — divide by `1e3` / `1000.0` NOT `1000` (integer division drops sub-second precision); from_unixtime expects SECONDS not millis (else year ~56378); can filter on converted ts or compare raw millis.

Verified vs trino.io/docs/467 datetime.html:
- from_unixtime takes UNIX **seconds** (docs: "number of seconds since 1970-01-01 00:00:00 UTC"), returns timestamp(3) with time zone. CONFIRMED seconds, not millis.
- from_unixtime_nanos(bigint) exists; there is NO direct from-millis builtin in 467 — so the `/1e3` approach is the correct idiom. CONFIRMED.
- Integer-division gotcha is real: `ms / 1000` (both bigint) truncates; `/1e3` (double divisor) promotes to seconds with sub-second fraction preserved. CONFIRMED.

Fully correct.

---

## Q3 — find rows where a free-text notes column CONTAINS a keyword like 'escalated'

Scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 → **avg 5.00**

Responder: `WHERE notes LIKE '%escalated%'`; alt `strpos(notes,'escalated') > 0` (1-based, 0 if not found); for multiple keywords `regexp_like(notes, 'escalated|critical|urgent')`.

Verified vs trino.io/docs/467:
- string.html: strpos returns 1-based starting position, 0 if not found. CONFIRMED.
- LIKE '%word%' substring match is standard. CONFIRMED.
- regexp.html: regexp_like "performs a *contains* operation rather than a *match* operation" (pattern need only be contained within string) → boolean; Java regex syntax → `|` alternation supported. CONFIRMED partial-match + alternation.

All three correct.

---

## Q4 — one query giving per-customer total revenue AND paid-only revenue

Scores: Accuracy 4 / Completeness 4 / Clarity 5 / Actionability 5 → **avg 4.375**

Responder: `SUM(revenue) AS total_revenue, SUM(CASE WHEN payment_status='paid' THEN revenue ELSE 0 END) AS paid_revenue ... GROUP BY customer_id`; alt `SUM(revenue) FILTER (WHERE payment_status='paid')`; said both produce **identical results/plans**.

Verified vs trino.io/docs/467 aggregate.html:
- FILTER is supported for all aggregate functions. CONFIRMED.
- Conditional aggregation SUM(CASE WHEN..) is valid. CONFIRMED.
- **Minor imprecision (the only ding):** the "identical results" claim is NOT precisely true for a group with NO matching rows. SUM(CASE WHEN cond THEN x ELSE 0 END) sums the ELSE-0 branch → returns **0**; SUM(x) FILTER (WHERE cond) feeds the aggregate zero rows → SUM ignores nulls / returns NULL for no input (SUM is NOT in the 5-exception list) → returns **NULL**. So on a no-match group the two forms differ 0-vs-NULL. The core question (both forms valid, both give per-customer total + paid) is fully answered correctly; "identical results/plans" overstates the equivalence. Precision nuance, not a correctness error.

Core correct; small completeness/accuracy ding for the over-broad "identical" claim.

---

## (a)-(d) Direct answers to the probe questions

- **(a) Q1 per-row CAST-sum fix LANDED?** YES. Responder gave per-row `CAST(flag AS integer)+...` with NO GROUP BY and explicitly rejected count_if as a per-group aggregate. The iter865 misframe did not recur. Fix confirmed landed.
- **(b) Q2 from_unixtime(ms/1e3) correct?** YES. from_unixtime takes SECONDS (verified datetime.html), `/1e3` converts millis→seconds, integer-division gotcha (`/1000` truncates) correctly flagged.
- **(c) Q3 LIKE / strpos / regexp_like all correct?** YES. LIKE substring, strpos 1-based-0-if-absent, regexp_like contains-with-`|`-alternation all verified.
- **(d) Q4 conditional SUM both forms correct + "identical results" precise?** Both forms correct/valid. "Identical results" is NOT strictly precise — empty-match group differs 0 (CASE/ELSE 0) vs NULL (FILTER, SUM returns null on no input). Minor nuance only.

---

## iter867 recommendation: **DEFAULT NO-OP** (durability sweep, teacher ZERO edits)

The iter866 FIX-A LANDED CLEAN — Q1 per-row CAST-sum / count_if-shape-router is durable on the re-probe, and Q2/Q3 are textbook. The Q4 0-vs-NULL nuance is a single minor precision ding on an otherwise-correct answer; it does NOT meet the bar for a FIX-A (reconcile-don't-churn — the conditional-aggregation / FILTER cards are correct; the only gap is the responder's "identical" overstatement, a synthesis slip not a content defect).

- Re-probe the per-row flag-count ONCE MORE from a 2nd phrasing ("how many of these toggles are on for each account" / "count enabled features per row") to BULLETPROOF the iter866 fix. Escalate to FIX-A only if the count_if/GROUP-BY misframe recurs.
- Optional fresh adjacents: from_unixtime_nanos for nanos / to_unixtime round-trip; multi-keyword regexp_like with anchors or case-insensitive `(?i)`; SUM(CASE..ELSE 0) vs FILTER 0-vs-NULL 2nd phrasing (COALESCE-wrap to force 0).
- If under-scoring recurs on Q4-style conditional aggregation, a light keyword cross-link noting "FILTER returns NULL on a no-match group, ELSE 0 returns 0; wrap COALESCE(..,0) to unify" would be the smallest possible touch — NOT warranted at 4.84.

HOLD all iter534-865 locks. PIN Trino 467. NO federation edits (r22 §13.x ZERO edits; federation row stays 4.49944/310, still FAIL). DO NOT bump training/state.json (already passed).
