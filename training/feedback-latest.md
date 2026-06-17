# Judge Feedback — iter1017

**OVERALL: 4.078125 (65.25/16) — PASS** (threshold 3.5; margin +0.578). OVERALL AVERAGE governs; NO per-question veto.

Verified BOTH directions against trino.io/docs/467 (functions/window.html, functions/math.html, functions/string.html) + WebSearch on SQL 3-valued-logic IN-vs-NOT-IN NULL semantics and Trino default window frame (RANGE UNBOUNDED PRECEDING) — NOT resources/. Prod stack (Trino 467 Iceberg + Hive Metastore on-prem MinIO + Spark + dbt) — all 4 fit; no federation/auth angle.

This iter carries TWO genuine responder errors (Q1 + Q4), both of which the OVERALL AVERAGE still clears because the mechanics/alternatives are sound and Q3 is clean.

---

## Per-question scores

### Q1 — IN(subquery) for "customer has >=1 enterprise subscription" — 3.50 (14.0/16)
- Accuracy **2.5** / Completeness **4.0** / Clarity **4.0** / Actionability **3.5**
- CORRECT: `WHERE customer_id IN (SELECT ...)` answers the ask; Trino decorrelates it to a **SemiJoin** (one pass over the outer row, no fan-out); the EXISTS rewrite is a valid equivalent.
- **DEFECT (KEY):** The responder claims plain `IN` "risks zero results / the whole filter can fail" if a `customer_id` in the subquery is NULL, and recommends EXISTS to avoid this. **This is WRONG — it conflates `IN` with `NOT IN`.**
  - Per SQL three-valued logic (`IN` = `= ANY`): a row whose `customer_id` matches a non-null value in the subquery still evaluates TRUE and is KEPT, even if the subquery also contains NULLs. A NULL in the list only makes NON-matching rows UNKNOWN (excluded) — the SAME outcome as without the NULL. So plain `IN` returns the correct matching rows; it does **NOT** collapse to zero rows.
  - The "any NULL → zero rows" trap is specific to **`NOT IN`** (`NOT (= ANY)` → every outer row becomes UNKNOWN → WHERE drops all). Confirmed via WebSearch (SQL-standard 3VL: "1 IN (1,2,NULL) is true"; "NOT IN can never succeed if there are any nulls returned by the sub-select").
  - Net: the EXISTS recommendation is HARMLESS, but the STATED REASON is false. An engineer reading this would believe `IN` is unsafe for matching and may rewrite working queries to chase a non-existent bug.

### Q2 — `user_id % 4` for consistent A/B bucketing into 0–3 — 4.50 (18.0/16)
- Accuracy **4.0** / Completeness **4.5** / Clarity **4.75** / Actionability **4.75**
- CORRECT: `%` works in Trino 467; `user_id % 4` is deterministic and stable (same id → same bucket); CASE for human labels; buckets 0,1,2,3.
- **OVERSTATEMENT:** "No gotchas — remainder is ALWAYS non-negative when the divisor is positive." **Wrong in general.** Trino's `%`/`mod` uses truncated division (Java semantics) → the result takes the **sign of the DIVIDEND**, so `-7 % 4 = -3` (negative even though the divisor 4 is positive). The claim only holds for **non-negative `user_id`** — the realistic case for an ID column, so the actual bucketing is fine, but the universal "always non-negative" framing is incorrect. Light Accuracy deduct only; the recommended SQL is correct for the use case.

### Q3 — strip 'REF-' prefix from 'REF-abc123' — 4.81 (19.25/16)
- Accuracy **5.0** / Completeness **4.75** / Clarity **4.75** / Actionability **4.75**
- CLEAN. `replace(referral_codes, 'REF-', '')` → 'abc123' is correct. Trino 467 has both 2-arg `replace(string, search)` (removes ALL occurrences) and 3-arg `replace(string, search, replacement)`. Responder correctly noted "removes all instances" (acceptable here since the prefix appears once) and correctly pointed to `regexp_replace` for anchored/complex cases. No defect.

### Q4 — each user's MOST RECENT plan; LAST_VALUE "only sees current row" — 3.50 (14.0/16)
- Accuracy **2.5** / Completeness **4.0** / Clarity **4.0** / Actionability **3.5**
- CORRECT DIAGNOSIS: the symptom is the **default window frame**. With `ORDER BY changed_at` and no explicit frame, Trino applies `RANGE UNBOUNDED PRECEDING AND CURRENT ROW` (frame ends at the current row / its last peer), so LAST_VALUE returns the current row's value, not the partition's last.
- **DEFECT (KEY):** The prescribed PRIMARY fix — `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` — **does NOT fix the problem.** That frame still ends at the current row, so LAST_VALUE still returns the current row's value (functionally identical to the default). To get the partition-latest plan, the frame must extend forward:
  - `LAST_VALUE(plan_name) OVER (PARTITION BY user_id ORDER BY changed_at ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING)`, or
  - `... ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING`.
  - Verified vs Trino default-frame behavior (RANGE UNBOUNDED PRECEDING = BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW).
- RESCUE: the responder's ALTERNATIVE — `ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY changed_at DESC)` then `WHERE rn = 1` — **IS correct** for "each user's most recent plan" (idiomatic Trino, since QUALIFY is not in 467). This is what keeps Actionability above floor: an engineer who uses the alt gets the right answer; one who copies the lead frame fix does not.

---

## Tic scan
`::` cast ABSENT all 4. No QUALIFY / false-semi-join-mechanism / MAX-varchar / GREATEST-LEAST-NULL / fabricated-fn (replace/mod/LAST_VALUE/ROW_NUMBER all real & verified) / regex-backslash / INTERVAL-quarter-week / OFFSET-before-LIMIT / generate_subscripts / broken-secondary. The two defects are SEMANTIC (wrong reason / ineffective frame), not parse errors.

## Resource diagnosis (for PHASE-6 grep)
- **Q1 (IN-vs-NOT-IN NULL):** r23 teaches the NOT-IN-with-NULL 3VL gotcha CORRECTLY (NOT-IN → UNKNOWN → empty result; NOT EXISTS NULL-safe). The responder appears to have **mis-applied that correct NOT-IN gotcha to plain IN** — a responder slip (over-generalizing the NULL trap to the wrong operator), NOT a resource defect. Recommend orchestrator grep r23 for any prose that could read as "IN (not just NOT IN) breaks on NULL"; if r23 only attaches the trap to NOT IN, this is responder over-application — do NOT churn. If r23 prose is ambiguous about WHICH operator the trap attaches to, a LIGHT in-place disambiguation (pin: trap is NOT-IN-only; plain IN returns matches NULL-safely) is warranted.
- **Q4 (LAST_VALUE frame):** r07/r23 teach the default-frame trap and the partition-latest pattern. The responder correctly recalled "default frame = current row" but prescribed the WRONG corrective frame (PRECEDING..CURRENT instead of CURRENT..FOLLOWING). The correct ROW_NUMBER alt was also produced. Recommend grep r07/r23 for the LAST_VALUE fix: if the canonical correct frame (`CURRENT ROW AND UNBOUNDED FOLLOWING` / `UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING`) is present and findable, this is a responder slip (recalled the diagnosis, fumbled the prescription) — monitor, don't churn. If the resource only shows the diagnosis without a copy-attractive correct-frame canonical, a LIGHT findability nudge is warranted.

## Recommendation
**DEFAULT NO-OP this iter** (overall PASS, margin +0.578; Q3 clean; Q2 overstatement immaterial for non-negative IDs; Q1 + Q4 each have a correct mechanic/alternative that limits harm). Both Q1 and Q4 are FIRST-occurrence semantic slips against resources that (apparently) teach the correct form — per-instance one-offs, not yet source-verified findable gaps. PHASE-6 grep should confirm r23 (IN-vs-NOT-IN) and r07/r23 (LAST_VALUE frame) before any edit. **WATCH for 2-in-2 recurrence:**
- (a) IN-subquery NULL: if responder again says plain `IN` (not NOT IN) gives zero rows on NULL → grep r23, LIGHT disambiguation (NULL trap is NOT-IN-only; IN is NULL-safe for returning matches).
- (b) LAST_VALUE/FIRST_VALUE partition-latest: if responder again prescribes a current-row-ending frame for "most recent per partition" → grep r07/r23, LIGHT findability nudge (pin `ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING` as the copy-attractive fix; ROW_NUMBER DESC rn=1 as the idiomatic alt).
- (c) mod-sign overstatement: monitor only; harmless for ID columns.

Federation r22 §13.x hard-locked NOT probed (stays 4.49944/310). MUST NOT bump state.json (already 1017; orchestrator commits).
