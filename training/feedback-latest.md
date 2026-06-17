# Judge Feedback — iter1036

**Overall: 4.375 PASS** (17.5 / 4; margin +0.875; overall average governs, no per-Q veto)

Verified BOTH directions against RAW git-tag 467 source (raw.githubusercontent.com/trinodb/trino/467/...) + WebSearch on official docs/blog — NOT against resources/. Prod stack (Trino 467 + Iceberg + Hive Metastore, on-prem MinIO) fits all 4; no federation/auth angle this sweep.

---

## Q1 — return per-account features starting with literal "beta_" without exploding to rows

**filter(enabled_features, f -> f LIKE 'beta_%') AS beta_features**

Scores: **Accuracy 3.0 / Completeness 4.0 / Clarity 4.25 / Applicability 3.5 → 3.6875**

- STRUCTURE CORRECT: `filter(array(T), function(T,boolean)) -> array(T)` EXISTS in 467 (array.md: "Constructs an array from those elements of `array` for which `function` returns true"). Using filter() + a lambda to keep matching elements in-place, no UNNEST, is exactly the right approach for "without exploding to rows." Credit this.
- **PREDICATE BUGGY — LIKE-underscore-literal-prefix defect.** In Trino LIKE, `_` is a SINGLE-CHARACTER WILDCARD. Verified comparison.md (467 RAW): "`_` matches any single character" and "`%` matches zero or more characters"; "The wildcard characters `_` and `%` must be escaped to allow you to match them as literals. This can be achieved by specifying the `ESCAPE` character." So `f LIKE 'beta_%'` matches `"beta"` + ANY single char + anything — it would keep `"betaX9"`, `"betamax"`, `"betatron"`, NOT specifically the literal-underscore prefix `"beta_foo"`. The answer therefore returns WRONG elements for the stated requirement.
- FIX: `filter(enabled_features, f -> starts_with(f, 'beta_'))` (string.md: starts_with tests a literal prefix, no wildcard) OR `filter(enabled_features, f -> f LIKE 'beta\_%' ESCAPE '\')` (escaped underscore per comparison.md example `'South_America' LIKE 'South\_America' ESCAPE '\'`).
- **RECURRENCE FLAG:** this is the SAME LIKE-underscore-literal-prefix misconception as iter1028 Q2 / iter1029 Q1 (the iter1029 §651/§653 FIX-A topic). iter1030 confirmed the FIX-A working for a BARE-COLUMN prefix-validation question. Now it has relapsed inside a `filter()` ARRAY-LAMBDA context — a NEW surface where the §653 caveat's keywords (starts_with / LIKE prefix) may not be reaching the responder because the question framing is array/filter-centric, not "validate a code prefix." Orchestrator: grep resources to classify findability-gap (filter/array-lambda locus lacks the literal-underscore caveat cross-ref) vs recall-ceiling.

## Q2 — 28-day (4-week) TIME-window moving average of daily order count

**CTE daily_counts(CAST date, COUNT(*)) then AVG(daily_orders) OVER (ORDER BY order_date RANGE BETWEEN INTERVAL '27' DAY PRECEDING AND CURRENT ROW)**

Scores: **Accuracy 3.75 / Completeness 4.5 / Clarity 4.5 / Applicability 4.0 → 4.1875**

- WINDOW LOGIC CORRECT. Trino supports RANGE frames with an INTERVAL offset over a date/timestamp ORDER BY column (since v346; trino.io blog "Introducing new window features" example: `avg(totalprice) OVER (... ORDER BY orderdate RANGE BETWEEN interval '1' month PRECEDING AND CURRENT ROW)`). `INTERVAL '27' DAY PRECEDING` + `CURRENT ROW` = 28 calendar days inclusive = correct for "4-week / last 28 days" as a TIME window (not a fixed row count). Pre-aggregating to a daily CTE then applying the RANGE frame is the sound canonical pattern and correctly handles missing/sparse days (a ROWS frame would not).
- **`::` CAST DEFECT (minor, isolated).** The CTE uses `created_at::date`. The PostgreSQL-style `::` cast operator is NOT valid Trino — it is a parse error (conversion.md documents only `CAST(value AS type)` and `TRY_CAST`; issue #23795). Must be `CAST(created_at AS date)`. This slip is confined to the CTE projection; the window-frame logic (the hard part of the question) is correct. Accuracy dinged for the parse-error slip, not the core approach.

## Q3 — pull nested device.os from JSON in ONE shot

**json_extract_scalar(properties, '$.device.os') AS device_os**

Scores: **Accuracy 5 / Completeness 4.75 / Clarity 4.75 / Applicability 4.75 → 4.8125**

- FULLY CORRECT. json.md (467 RAW): `json_extract_scalar` "Like json_extract, but returns the result value as a string... The value referenced by json_path must be a scalar"; documented example `json_extract_scalar(json, '$.store.book[0].author')` confirms nested dot-path traversal. `'$.device.os'` resolves the nested value in a single call and returns VARCHAR — exactly "one shot, not two extracts." Correctly contrasts json_extract (returns the whole object as JSON) for the non-scalar case.

## Q4 — label day-of-week NAME (Monday..Sunday), not a number

**format_datetime(CAST(plan_start_date AS timestamp), 'EEEE') → full name; 'EEE' short; cast optional via DATE→TIMESTAMP coercion; dayname() does NOT exist in 467**

Scores: **Accuracy 5 / Completeness 4.75 / Clarity 4.75 / Applicability 4.75 → 4.8125**

- FULLY CORRECT. datetime.md (467 RAW): `format_datetime(timestamp, format) -> varchar` "Formats timestamp as a string using format"; "compatible with JodaTime's DateTimeFormat pattern format." `EEEE` (full weekday name) / `EEE` (short) are standard JodaTime day-of-week patterns. `dayname()` is correctly identified as ABSENT in 467 (no such function in datetime.md); the numeric alternative `day_of_week(x)->bigint` "ranges from 1 (Monday) to 7 (Sunday)" is a number, which the user explicitly did NOT want — so steering to format_datetime is right. DATE→TIMESTAMP implicit coercion making the CAST optional is accurate (the cast is harmless/explicit, fine to keep).

---

## TICS check
- `::` present in Q2 ONLY (defect flagged). Absent Q1/Q3/Q4.
- All functions real & verified: filter, json_extract_scalar, json_extract, format_datetime, day_of_week. dayname() correctly called absent.
- No QUALIFY / false-semi-join / regex-backslash / INTERVAL-quarter-week / OFFSET-before-LIMIT / broken-secondary / over-warning.
- Q1 LIKE-underscore is the one accuracy defect of substance; Q2 `::` is a minor isolated parse-error slip.

## Recommendation
PASS at 4.375 (margin +0.875). TWO source-verified defects this sweep:
1. **Q1 LIKE-underscore-literal-prefix RELAPSE** — now inside a `filter()` array-lambda (new surface vs the bare-column prefix questions iter1028/1029/1030). Orchestrator: grep resources to decide findability-gap (add literal-`_`/`%`-prefix caveat + starts_with/ESCAPE cross-ref at the filter/array-lambda + LIKE-in-lambda locus, not just the bare-column prefix-validation card) vs recall-ceiling. This is the recurring §653 family on a new framing — worth a LIGHT findability nudge if a grep shows the array-lambda path lacks the cross-ref.
2. **Q2 `::` cast slip** — isolated to the CTE; the §1154/§3247/§1394/§659 `::`-lock canon exists. Likely a per-instance responder slip rather than a resource gap; classify via grep but do not churn the `::` lock if it is intact and findable.

Do NOT bump state.json (teacher already handled; orchestrator commits).
