# Judge Feedback — iter1029

**OVERALL: 4.609375 (73.75/16) — PASS** (threshold 3.5; margin +1.109375). OVERALL AVERAGE governs — NO per-Q veto.

Verified BOTH directions vs trino.io/docs/467 (functions/string.html starts_with/ends_with, functions/comparison.html LIKE underscore-wildcard + ESCAPE, functions/conditional.html COALESCE, functions/array.html contains, functions/datetime.html format_datetime JodaTime) — NOT resources/. Prod stack (Trino 467 + Iceberg + MinIO, Hive Metastore) all 4 fit; no federation/auth angle.

## Per-question scores

| Q | Accuracy | Completeness | Clarity | Actionability | Subtotal |
|---|---|---|---|---|---|
| Q1 starts_with literal prefix | 3.25 | 4.25 | 4.5 | 4.0 | 16.0 |
| Q2 COALESCE first-non-null | 5.0 | 4.75 | 4.75 | 4.75 | 19.25 |
| Q3 contains() array membership | 5.0 | 4.75 | 4.75 | 4.75 | 19.25 |
| Q4 format_datetime month-year | 5.0 | 4.75 | 4.75 | 4.75 | 19.25 |

**Total 73.75 / 16 = 4.609375 PASS.**

## Resolved verdicts (with citations)

**Q1 (KEY) — starts_with lead CORRECT; "LIKE 'ff_%' works equally well" endorsement INCORRECT (DEFECT).**
- LEAD `starts_with(event_code, 'ff_')` is CORRECT and the safest form: string.html — `starts_with(string, substring) → boolean`, "Tests whether `substring` is a prefix of `string`." Literal prefix match, no wildcard interpretation. This is the right answer to "starts with literal `ff_`".
- The appended claim "You can also use `LIKE 'ff_%'` (anchored prefix), which works equally well and is also fine" is WRONG. comparison.html: LIKE `_` "matches any single character" (it is a single-char WILDCARD). So `'ff_%'` matches "ff" + ANY one character + the rest — e.g. "ffx_test", "ffabc", "ff9zzz" — it does NOT require a literal underscore as the 3rd char. It is NOT equal to "starts with literal `ff_`".
- The correct LIKE form needs the underscore ESCAPED: `LIKE 'ff\_%' ESCAPE '\'` (comparison.html confirms ESCAPE is required to match a literal `_`). The responder's endorsement re-asserts the underscore-is-literal misconception.
- Classification: starts_with LEAD correct; the LIKE 'ff_%' "equally well" claim is the defect. Acc 3.25 (lead correct but explicitly endorses a buggy form as equivalent), Comp 4.25, Clar 4.5, App 4.0.
- **RECURRENCE — NOW 2-IN-2:** iter1028 Q2 used a bare `LIKE 'ff_%'` predicate inside `all_match(...)` as the answer (scored 3.875, flagged underscore-wildcard). iter1029 Q1 leads correctly with starts_with but appends `LIKE 'ff_%'` as "works equally well". Same underscore-wildcard misconception two consecutive iterations. This is **2-IN-2** for the LIKE-underscore-is-literal misconception → orchestrator should grep-classify in PHASE 6 and the teacher should add a LIGHT findability nudge (canonical: LIKE `_` = single-char wildcard; for a literal prefix use `starts_with(s,'ff_')` or `LIKE 'ff\_%' ESCAPE '\'`).

**Q2 — COALESCE CLEAN.** `COALESCE(usd_amount, eur_amount, gbp_amount) AS amount` returns first non-null. conditional.html: "Returns the first non-null `value` in the argument list." All three are DOUBLE so no coercion concern; short-circuit evaluation. Correctly distinguishes null-fallback (COALESCE) from conditional logic (IF/CASE). Acc 5 / Comp 4.75 / Clar 4.75 / App 4.75.

**Q3 — contains() CLEAN.** `contains(tags, 'trial')` in WHERE for array membership, no UNNEST needed. array.html: "Returns true if the array `x` contains the `element`" → boolean. Correctly notes EXISTS(UNNEST(...)) as a verbose alternative. Acc 5 / Comp 4.75 / Clar 4.75 / App 4.75.

**Q4 — format_datetime CLEAN.** `format_datetime(CAST(shipped_at AS timestamp), 'MMMM yyyy')` → 'March 2025'. datetime.html: format strings are "compatible with JodaTime's DateTimeFormat pattern format". JodaTime: `MMMM` = full month name, `MMM` = abbreviated month, `MM` = 2-digit month number, lowercase `mm` = MINUTE (the gotcha) — responder flagged all four distinctions correctly incl. the mm=minute trap. CAST correctly noted optional when already a timestamp. Acc 5 / Comp 4.75 / Clar 4.75 / App 4.75.

## TICS / defect scan
- `::` cast shorthand ABSENT all 4 (good).
- No QUALIFY, no false semi-join, no fabricated functions (starts_with/COALESCE/contains/format_datetime all real & verified; ends_with correctly flagged absent in Q1 aside, use LIKE '%.csv'/substr), no regex-backslash issue, no INTERVAL quarter/week, no OFFSET-before-LIMIT, no generate_subscripts, no broken-secondary in Q2–Q4.
- ONE defect: Q1 LIKE 'ff_%' "works equally well" endorsement (underscore-wildcard misconception), **2-in-2 with iter1028 Q2**.

## Recommendation
**PASS at 4.609375.** 3/4 clean; Q1 lead correct, defect is the appended LIKE-equivalence claim. The LIKE-underscore-is-literal misconception is now **2-IN-2 (iter1028 Q2 + iter1029 Q1)** — this crosses the 2-in-2 threshold and is NO LONGER a per-instance one-off. Orchestrator: classify in PHASE 6; teacher should add a LIGHT findability nudge so the responder stops endorsing `LIKE 'x_%'` for literal-prefix matches:
- canonical: literal prefix `ff_` → `starts_with(event_code, 'ff_')` (literal, no wildcard);
- if LIKE is required: `event_code LIKE 'ff\_%' ESCAPE '\'` (escape the underscore);
- defang note: `LIKE 'ff_%'` is WRONG for a literal underscore — `_` is the single-character wildcard (comparison.html), so it matches "ff"+any-char+rest.

Place it where the prefix-match / starts_with / LIKE keywords lead (string.html-adjacent prefix card + the LIKE bracket/wildcard row at r23 §3256). Federation r22 §13.x hard-locked, NOT probed (stays 4.49944/310). MUST NOT bump state.json (already 1029; orchestrator commits).
