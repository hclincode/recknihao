# Judge Feedback — iter738

All dialect claims verified against trino.io/docs/467 (datetime / window / string / array .html) on 2026-06-09. NOT verified against resources/. Production stack: Trino 467 + Iceberg, on-prem; none of these answers touch auth/authz, so no prod-fit concerns. state.json NOT bumped.

## Per-question scores

### Q1 — first + last day of month from a TIMESTAMP (2nd-angle re-probe)
- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 → **5.00**
- `CAST(date_trunc('month', created_at) AS DATE)` — docs-verified: `date_trunc('month', TIMESTAMP '2022-10-20 05:10:00')` → `2022-10-01 00:00:00.000` (first-of-month timestamp), CAST AS DATE → plain date. Correct.
- `last_day_of_month(created_at)` — docs signature is `last_day_of_month(x) → date`, the generic temporal `x` (same pattern as `quarter(x)`/`year(x)`) accepts a timestamp and returns a date. Correct; directly answers "both as plain dates" — first is explicitly CAST to date, last returns date natively. Single tidy SELECT, billing-window framing matches the use case.
- **VERDICT: last_day_of_month STAYS CLOSED → now BULLETPROOFED.** 2nd consecutive clean datapoint (iter737 fresh date-arg 4.9375 → iter738 explicit-timestamp-arg 5.00). The iter737 -0.25 nit (didn't state timestamp input works) is resolved by exercising exactly the timestamp angle. Stop re-probing.

### Q2 — RANK vs DENSE_RANK vs ROW_NUMBER tie-handling (fresh)
- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 → **5.00**
- Docs-verbatim window.html: rank() "tie values in the ordering will produce gaps in the sequence" → (1,1,3) correct; dense_rank() "tie values do not produce gaps" → (1,1,2) correct; row_number() "unique, sequential number for each row" → (1,2,3) correct.
- The 6-row sequences (1,1,3,4,4,6 / 1,1,2,3,3,4 / 1,2,3,4,5,6) all correct. Directly answers "2nd then skip to 4th, or move to 3rd?": RANK skips (2,2,4).
- Top-N implications consistent with the standing iter714 top-N-with-ties lock: RANK()<=N includes ties at the cutoff, DENSE_RANK()<=N = top-N distinct value tiers, ROW_NUMBER()<=N = exactly N rows. Worked $100/$100/$90/$80×3/$70 example correct. Recommends RANK() for leaderboard — right default. **Confirmed.**

### Q3 — position of LAST occurrence / file extension — SCRUTINIZED
- Accuracy 5 / Completeness 4 / Clarity 5 / Actionability 4 → **4.50**
- (a) Extension answer `element_at(split(file_path, '.'), -1)` is CORRECT and idiomatic. `split(string, delimiter)`→array (docs-verbatim string.html); `element_at(array, -1)` returns the last element (array.html "If index < 0, element_at accesses elements from the last to the first"). For `q1-summary.pdf` → `'pdf'`. Best answer for the actual stated use case.
- (b) **CRITICAL FINDING — missed cleaner native form.** The workaround `LENGTH(file_path) - strpos(REVERSE(file_path), '.') + 1` is functionally correct (REVERSE and LENGTH both confirmed). BUT Trino 467's `strpos` HAS a 3-argument form: docs-verbatim string.html "strpos(string, substring, instance) — Returns the position of the N-th instance of substring in string. **When instance is a negative number the search will start from the end of string.**" So `strpos(file_path, '.', -1)` directly returns the position of the LAST dot — no REVERSE/LENGTH arithmetic needed. The responder MISSED this cleaner native canonical.
- Severity: the user explicitly asked "how to find the LAST occurrence of a character" — `strpos(s, sub, -1)` is the direct native answer to that literal question. The element_at(split,-1) extension answer is still correct and best for the extension use case, so this is a Completeness/Actionability gap (-1 each), NOT an accuracy error. The REVERSE workaround produces the right number.
- **iter739 FLAG (genuine, real missed canonical): add a `strpos(string, substring, -1)` = position-of-last-occurrence canonical.** Anchors: "position of the last occurrence", "find the last dot/character", "last index of a substring", "strpos from the end". Lead with `strpos(file_path, '.', -1)` for the literal position; keep `element_at(split(...), -1)` as the extension-extraction answer; demote the `LENGTH - strpos(REVERSE(...))` arithmetic to a fallback note. Pure ADDITION — no contradictory content to reconcile.

### Q4 — quarter / EXTRACT(QUARTER) (fresh)
- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 → **5.00**
- `quarter(transaction_date)` — docs-verbatim "Returns the quarter of the year from x. The value ranges from 1 to 4." Correct, no CASE needed.
- `EXTRACT(QUARTER FROM x)` equivalence accurate (extraction table maps QUARTER → quarter()). `year(x)` exists (→bigint). `CONCAT('Q', quarter(...), ' ', CAST(YEAR(...) AS VARCHAR))` label valid Trino. GROUP BY repeating the `quarter(transaction_date)` expression valid. Month ranges correct. **Confirmed.**

## Overall

| Q | Acc | Compl | Clar | Act | Avg |
|---|---|---|---|---|---|
| Q1 | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | 5 | 5 | 5 | 5 | 5.00 |
| Q3 | 5 | 4 | 5 | 4 | 4.50 |
| Q4 | 5 | 5 | 5 | 5 | 5.00 |

**Overall average = 4.875 → PASS** (well above 3.5; overall average governs, no per-Q override).

## Teacher actions for iter739
1. **Q1 verdict: last_day_of_month BULLETPROOFED** (2nd consecutive clean datapoint). Stop re-probing. Do NOT edit the resource (iter693 churn-risk).
2. **Q3 genuine gap — ADD strpos negative-instance canonical.** Only real finding. Trino 467 `strpos(string, substring, -1)` gives position of last occurrence natively; responder fell back to a clunky REVERSE/LENGTH workaround and missed it. Add a small leading canonical (anchors above), pure addition, no reconciliation. Keep `element_at(split(s,d),-1)` as the extension-extraction answer.
3. Q2 and Q4 fully correct, consistent with standing locks (iter714 top-N-with-ties). No action.
4. Did NOT bump training/state.json.
