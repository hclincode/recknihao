# iter855 Judge Feedback — LIGHT FIX-A verification

**Overall: 4.97 STRONG PASS** (threshold 3.5; overall avg governs, no per-Q veto)

All dialect claims verified against trino.io/docs/467 (aggregate.html, array.html, conversion.html, math.html) + WebSearch 2026-06-10. PIN Trino 467.

## Gap-fix landing verdicts

- **(a) Q1 geometric_mean gap-fix LANDED.** iter854 Q4's flat "Trino has no geometric mean" was WRONG. Responder now LEADS with the built-in `geometric_mean(daily_return) -> double` aggregate, uses per-group `GROUP BY portfolio_id` correctly, and relegates `EXP(AVG(LN(x)))` to a *fallback used only when deliberately excluding non-positive rows* (`WHERE x > 0`, since LN undefined for x<=0). Cites r23 §3.1B-GM (confirmed present at resources/23-sql-best-practices-olap.md:928-958 with built-in canonical + fenced inline-DEFANG). VERIFIED: aggregate.html quotes verbatim "geometric_mean(x) -> double — Returns the geometric mean of all input values."
- **(b) Q2 array-subset gap-fix LANDED.** iter854 Q3's malformed `FROM users u, CROSS JOIN UNNEST(...)` (comma + CROSS JOIN parse error) and "no subset fn, must loop" misconception are GONE. Responder now gives BOTH clean one-expression forms: `all_match(ARRAY[...], x -> contains(enabled_features, x))` AND `cardinality(array_except(ARRAY[...], enabled_features)) = 0`. Cites r07 §1a.3-SUBSET (confirmed present at resources/07-analytical-query-patterns.md:633-649). VERIFIED: array.html — all_match "true if all elements match (empty array => true)", array_except "elements in x but not in y without duplicates", contains "true if x contains element". Both idioms semantically correct; direction is right (required-set as outer array, membership-in-user-array as predicate).

## Per-Q scores

**Q1 (geometric mean) — 5.00** (Acc 5 / Comp 5 / Clar 5 / Act 5)
Leads with built-in geometric_mean(x), per-group GROUP BY, fallback correctly conditioned on WHERE x>0. Zero error. Gap-fix landed cleanly.

**Q2 (array contains ALL of a set) — 5.00** (Acc 5 / Comp 5 / Clar 5 / Act 5)
Both all_match and array_except one-liners verified correct; "true iff every required element present" and "set difference empty" framings accurate. No malformed join. Gap-fix landed cleanly.

**Q3 (format seconds as 'Xm Ys') — 5.00** (Acc 5 / Comp 5 / Clar 5 / Act 5)
`format('%dm %ds', duration_seconds/60, duration_seconds%60)` verified: format()=java.util.Formatter (%d int), integer `/` truncates, `%` modulus — 155 -> '2m 35s' exact. `||`+CAST alt valid; "cleaner than CAST" framing apt.

**Q4 (sort array by string length) — 4.875** (Acc 5 / Comp 4.5 / Clar 5 / Act 5)
2-arg `array_sort(tags, (a,b) -> IF(length(a)<length(b),-1, IF(length(a)>length(b),1,0)))` verified: array_sort(array(T), function(T,T,int)) exists, comparator -1/0/1 contract correct (doc example matches form), sorts shortest-first by string length. "Swap for longest-first" correct. -0.125 comp only: did not note NULL-element placement / total-order requirement of the comparator, negligible for the asked case.

## Defect / gap flags

None. No fabrication, no parse-error risk, no crossed-family dialect slip, no findability miss, no prod-env conflict (pure SQL; on-prem Trino 467 + Iceberg + MinIO unaffected). Both iter854 gap-fix cards are present, correctly anchored, and the responder reached them.

## iter856 directive

**iter856 = DEFAULT NO-OP / durability sweep** (NOT a FIX-A — all clean, both gap-fixes landed). Teacher: ZERO resource edits.

Re-probe to bulletproof the two freshly-added cards from a 2nd angle (each needs >=2 angles before fully locked):
- geometric_mean 2nd angle: e.g. "compound annual growth / product-of-ratios mean" phrasing; re-confirm responder still leads with built-in and does NOT regress to EXP(AVG(LN)) as primary.
- array-subset 2nd angle: e.g. "does user have ANY vs ALL of these flags" (any_match vs all_match router) or superset/"required set is subset of granted" rephrase; re-confirm no malformed comma+CROSS-JOIN recurrence.
- Plus fresh adjacent: array_sort 1-arg vs 2-arg comparator / format() other specifiers (%s, %,.2f) / element-of-array membership.

PRESERVE all iter534-855 pins: iter855 geometric_mean §3.1B-GM + array-subset §1a.3-SUBSET, iter843 approx_percentile accuracy, iter842 value-vs-rank, iter840 weighted-avg §3.1B-WA, iter837 string->DATE MySQL-vs-Joda, iter836 lpad/format pad, iter831 month-name grouping, iter827 boolean-aggregate-NULL, iter824/823 split_part/GROUP-BY-alias/repeat-char, trim char-set, default-NULLS-LAST, CAST-rounds-half-up, iter744 codepoint/chr. NO federation edits (federation 4.49944/310).

DO NOT bump training/state.json (already 855).
