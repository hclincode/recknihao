# Judge Feedback — iter728

Scope: 4 Q&A pairs. Every dialect claim verified against trino.io/docs/467 (math, conversion, regexp, string) plus the official "Optimizing the Casts Away" blog and Data Types page. OVERALL AVERAGE governs PASS/FAIL (no per-Q override).

---

## Q1 — boolean → per-row 1/0 (CAST(bool AS int) findability re-probe)

ANSWER: `CASE WHEN is_active THEN 1 ELSE 0 END AS is_active_int` — per-row 1/0, explicitly NOT a count.

VERIFICATION:
- `CASE WHEN bool THEN 1 ELSE 0 END` is a per-row conditional expression → emits 1/0 one row at a time. CORRECT.
- The responder correctly read the intent (per-row scalar to multiply into a scoring formula), gave a per-row form, and did NOT mis-reach for `count_if` or any aggregate. The aggregate trap was AVOIDED.
- `CAST(is_active AS integer)` → 1/0 is the shorter, more direct per-row form (CAST(true AS integer)=1, CAST(false AS integer)=0 — established Trino 467 behavior). The responder did NOT show it.

Both CASE and CAST are correct per-row forms; CAST is just shorter. Showing CASE only is fully correct and goal-meeting — it is a completeness/conciseness nit, not an error.

Scores: Accuracy 5 | Completeness 4 | Clarity 5 | Actionability 5 → **4.75**

---

## Q2 — round DOWN to whole dollar (floor)

ANSWER: `floor(amount_usd)` ($47.89 → 47.0); `CAST(floor(x) AS integer)` for integer type; caveat that "floor → -infinity (-47.89 → -48) whereas CAST(x AS integer) truncates toward zero (-47.89 → -47)."

VERIFICATION:
- `floor(x)` = "rounded down to the nearest integer" → rounds toward negative infinity. CORRECT (math.html). Primary answer is right.
- `truncate(x)` exists and drops digits after the decimal point (toward zero). The responder did not name `truncate()` but its absence is minor.
- **DEFECT — the CAST claim is WRONG.** The responder states `CAST(x AS integer)` "truncates toward zero (-47.89 → -47)." Trino 467 CAST of a DOUBLE/DECIMAL to an integer type **ROUNDS HALF-UP, it does NOT truncate.** Verified: the Data Types page narrowing-cast rule ("casting to lower precision rounds, not truncates"), the "Optimizing the Casts Away" blog (narrowing casts round), and the canonical community guidance ("CAST rounds — use floor()/truncate() to drop decimals"). Concretely: `CAST(47.89 AS integer)` = **48** (not 47), and `CAST(-47.89 AS integer)` = **-48** (not -47). Both the rounding-direction characterization AND the example values in the caveat are incorrect.
  - Irony worth noting for the teacher: the responder used the CAST caveat to argue floor() is "safer," but the comparison is backwards. Since CAST rounds half-up, CAST(-47.89) = -48 actually AGREES with floor here; the function that truly diverges (toward zero) is `truncate(-47.89)` = -47. The correct "round-down vs drop-decimals" contrast is floor() (toward -inf) vs truncate() (toward zero) — NOT floor vs CAST.

The primary deliverable (floor) is correct and the engineer gets the right result for the asked positive-dollar case. But the volunteered negatives caveat propagates a false dialect fact — exactly the failure class this loop guards.

Scores: Accuracy 2 | Completeness 4 | Clarity 4 | Actionability 4 → **3.50**

---

## Q3 — regexp_extract (pull matched substring)

ANSWER: `regexp_extract(user_agent, '(\(.*?\))')` first match; `regexp_extract(s, pattern, 1)` capture group N; mentions `regexp_extract_all`, `regexp_like`, Java regex syntax.

VERIFICATION (regexp.html, verbatim):
- `regexp_extract(string, pattern) → varchar` "Returns the first substring matched..." CONFIRMED.
- `regexp_extract(string, pattern, group) → varchar` CONFIRMED.
- `regexp_extract_all(string, pattern)` CONFIRMED.
- `regexp_like(string, pattern) → boolean` CONFIRMED.
- "All of the regular expression functions use the Java pattern syntax." CONFIRMED.

Fully correct, well-routed (extract vs match-only), names the group form and the all/like siblings. Excellent.

Scores: Accuracy 5 | Completeness 5 | Clarity 5 | Actionability 5 → **5.00**

---

## Q4 — thousands separators (format)

ANSWER: `format('%,d', api_call_count)` → '1,234,567'; `format('%,.2f', ...)`; noted ||/concat are varchar-only.

VERIFICATION (string.html / format):
- `format(format, args...)` is Trino's Java `String.format`/printf-style function. CONFIRMED.
- `%,d` = integer with thousands grouping (java.util.Formatter `,` flag). CONFIRMED → '1,234,567'.
- `%,.2f` = grouped with 2 decimals. CONFIRMED.
- ||/concat are varchar-only and do not auto-coerce numbers, so format() avoids manual CAST. CORRECT.

Fully correct and directly actionable, with the inline-comment expected output.

Scores: Accuracy 5 | Completeness 5 | Clarity 5 | Actionability 5 → **5.00**

---

## Overall

| Q | Acc | Comp | Clar | Act | Avg |
|---|----|----|----|----|----|
| Q1 | 5 | 4 | 5 | 5 | 4.75 |
| Q2 | 2 | 4 | 4 | 4 | 3.50 |
| Q3 | 5 | 5 | 5 | 5 | 5.00 |
| Q4 | 5 | 5 | 5 | 5 | 5.00 |

**OVERALL AVERAGE = 4.5625 → PASS** (threshold 3.5; overall average governs, no per-Q override).

### Q1 nudge verdict — RESOLVED
The CAST(bool AS int) findability nudge is RESOLVED for its target failure mode: the responder gave a CORRECT per-row 1/0 form (`CASE WHEN ... THEN 1 ELSE 0 END`) and did NOT fall into the count_if/aggregate trap. It used CASE rather than the shorter `CAST(is_active AS integer)`; both are correct per-row, so it does not matter for correctness — only a minor conciseness opportunity remains.

### Q2 CAST-to-integer round-vs-truncate verdict — RESPONDER IS WRONG (flag for iter729)
Verified against trino.io/docs/467 + official blog + Data Types page: **Trino 467 CAST(DOUBLE/DECIMAL AS INTEGER) ROUNDS HALF-UP; it does NOT truncate toward zero.** `CAST(47.89 AS integer)` = 48, `CAST(-47.89 AS integer)` = -48. The responder's caveat ("CAST truncates toward zero, -47.89 → -47") is a FALSE dialect claim with wrong example values. The toward-zero / drop-decimals function is `truncate(x)` — NOT CAST. floor() (primary answer) is correct regardless.

---

## Teacher action for iter729 (targeted FIX, do not churn correct content)

DEFECT (Q2): Resources lack a clear, copy-attractive canonical distinguishing the three "drop the fraction" behaviors in Trino 467, and likely fail to inoculate against the "CAST truncates toward zero" misconception. Add/repair in the numeric-rounding canonical (r07 rounding section and/or r23 §3.1B/C money-decimal):

- LEADING fact: **CAST(double/decimal AS integer) ROUNDS HALF-UP, NOT truncate** (docs-verified: Data Types page "casting to lower precision rounds, not truncates" + "Optimizing the Casts Away" blog). Worked: `CAST(47.89 AS integer)` = 48; `CAST(2.5 AS integer)` = 3.
- 3-way router with keyword anchors (chop decimals / drop the fraction / round down to whole dollar / truncate decimals without rounding / toward zero / floor vs cast):
  - `floor(x)` → toward -infinity (47.89→47, -47.89→-48) — round DOWN.
  - `truncate(x)` → toward zero, drops digits (47.89→47, -47.89→-47) — DROP decimals.
  - `CAST(x AS integer)` → ROUND half-up (47.89→48, -47.89→-48) — NOT a truncation tool.
- INLINE-MARKED DEFANG (un-copyable, per iter693/694 lesson): "❌ WRONG: CAST(x AS integer) does NOT truncate toward zero — it rounds. For toward-zero use truncate(x); for round-down use floor(x)." Keep the correct forms as the copy-attractive block.
- Additive/corrective near the existing floor/round canonical; PRESERVE the floor() and round(x,2)↔CAST(x AS DECIMAL(18,2)) canonicals (iter725) and the §4.4A DECIMAL inoculation (iter724) verbatim.

Optional (Q1, low priority): the iter728 §3.1E CAST(flag AS integer) note already exists; the responder simply chose CASE. No action required.

No issues at Q3/Q4 (regexp_extract family and format/%,d both fully docs-correct).
