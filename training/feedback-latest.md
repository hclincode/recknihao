# Iter 615 — Judge Feedback (EXTENDED PHASE)

**Overall: 4.5625 — STRONG PASS** (margin +1.0625 above 3.5 floor). Federation NOT probed (4.49944/310 row UNCHANGED).

**HEADLINE:** FIX A (alias-in-WHERE guardrail) **RESOLVED** — Q1 repeated `date_parse(...)` directly in WHERE, no SELECT-output-alias reference; the iter614 slip did NOT recur. Q2 (7-day rolling avg) and Q4 (WITH RECURSIVE) clean and correct, with Q4's `max_recursion_depth default 10` claim docs-verified ACCURATE. **ONE real slip: Q3 lead SQL has a JSONPATH-MISMATCH** — `json_extract(metadata, '$.items')` assumes a wrapping object, but the question's data is a BARE array `["item_a",...]`, so the lead SQL returns NULL on the stated data. Prose did cover the bare-array case, so partial credit.

---

## Q1 — Parse text created_at + filter last 30 days (FIX A re-probe)

**Answer:** `SELECT * FROM audit_logs WHERE CAST(date_parse(created_at, '%Y-%m-%d %H:%i:%S') AS TIMESTAMP) >= current_timestamp - INTERVAL '30' DAY`

| Dim | Score |
|---|---|
| Accuracy | 4.5 |
| Completeness | 4.5 |
| Clarity | 5.0 |
| Actionability | 5.0 |
| **Avg** | **4.75 — PASS** |

**FIX A VERDICT: RESOLVED.** The parse expression `date_parse(created_at, '%Y-%m-%d %H:%i:%S')` is **REPEATED directly in WHERE** — no reference to a SELECT output alias. The iter614 alias-in-WHERE slip (`... AS occurred_at ... WHERE occurred_at > ...` → `Column 'occurred_at' cannot be resolved`) did NOT recur. The iter615 teacher's GOTCHA guardrail at the r27 date_parse canonical LANDED.

**Format string CORRECT:** `%Y-%m-%d %H:%i:%S` is valid MySQL-style (date_parse): `%i`=minutes, `%S`=seconds. Docs-verified: date_parse returns `timestamp(3)` WITHOUT time zone. The responder correctly noted "date_parse returns timestamp(3) without tz."

**SECONDARY TYPE-CHECK (minor nit, −0.5 Acc/Comp):** `CAST(date_parse(...) AS TIMESTAMP)` → `timestamp` (no tz); `current_timestamp` → `timestamp(3) WITH time zone` (docs verbatim: "Returns the current timestamp **with time zone** as of the start of the query, with 3 digits of subsecond precision"). **Does Trino 467 allow `timestamp >= timestamp with time zone`? VERDICT: It RUNS** — Trino implicitly coerces `timestamp` → `timestamp with time zone` using the session zone, so the query does NOT error. HOWEVER this coercion is **session-zone dependent** and a known sharp edge (trinodb/trino #5685 "incorrect query results when comparing timestamp column with timestamp with time zone constant"; #37 notes coercion result is environment-dependent). The cleaner, deterministic form is to compare against `localtimestamp` (no-tz, docs-verified) instead of `current_timestamp`. Not a paste-error (it runs), so only a −0.5 nit. The `CAST(... AS TIMESTAMP)` wrapper is also redundant since date_parse already yields timestamp.

**iter616 (LOW, reactive-only):** at the r27 date_parse canonical, add a one-liner that filtering "last N days" on a no-tz parsed timestamp should compare to `localtimestamp - INTERVAL 'N' DAY` (not `current_timestamp`) to avoid the implicit no-tz→with-tz session-zone coercion. Did not bite (query runs); inoculation only.

---

## Q2 — 7-day trailing/rolling average of DAU

**Answer:** `AVG(daily_users) OVER (ORDER BY event_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS rolling_7day_avg` over inner `SELECT event_date, COUNT(DISTINCT user_id) AS daily_users ... GROUP BY event_date`

| Dim | Score |
|---|---|
| Accuracy | 4.75 |
| Completeness | 4.5 |
| Clarity | 5.0 |
| Actionability | 5.0 |
| **Avg** | **4.8125 — PASS** |

Valid Trino 467. `ROWS BETWEEN 6 PRECEDING AND CURRENT ROW` = current row + 6 preceding = **7 rows total** — correct 7-row trailing average. Window-over-daily-aggregated-subquery is valid and is the correct structure (you cannot window over the raw COUNT(DISTINCT) without first collapsing to one row per day). The two-level pattern (inner GROUP BY event_date → outer window AVG) is exactly right.

**Minor completeness nit (−0.5 Comp, −0.25 Acc):** `ROWS` counts 7 DATA ROWS, which equals 7 CALENDAR days only if every day is present in the data. For DAU this is typically dense (every active day has a row), so acceptable; but omitting the gap-day caveat / the `RANGE BETWEEN INTERVAL '6' DAY PRECEDING` alternative (calendar-gap-correct) is a small gap. The r07 Pattern D RANGE-interval frame already exists — a one-line "if some days have zero events and are missing rows, use RANGE BETWEEN INTERVAL '6' DAY PRECEDING" would have closed it. Reactive-only; did not bite for the dense-DAU case.

---

## Q3 — Count elements in a JSON array column (BARE array)

**Answer:** `json_array_length(json_extract(metadata, '$.items')) AS item_count` (prose also covered the bare-array vs wrapped-object cases)

| Dim | Score |
|---|---|
| Accuracy | 3.5 |
| Completeness | 4.0 |
| Clarity | 4.5 |
| Actionability | 4.0 |
| **Avg** | **4.0 — PASS** |

**JSONPATH-MISMATCH in the LEAD SQL (docs-confirmed).** The question explicitly states `metadata` IS a bare JSON array `["item_a","item_b","item_c"]` — NOT wrapped in `{"items": [...]}`. The lead SQL's `json_extract(metadata, '$.items')` path assumes a WRAPPING OBJECT with an `items` key. On a bare array, `$.items` matches nothing → `json_extract` returns NULL → `json_array_length(NULL)` = NULL. **So the lead SQL returns NULL for the question's exact data.**

**CORRECT form (docs-verified):** `json_array_length(metadata)` directly — NO path extraction. Docs verbatim: `json_array_length(json) → bigint`, "Returns the array length of json (a string containing a JSON array)", with example `SELECT json_array_length('[1, 2, 3]'); -- 3`. The function accepts the JSON-array string/value directly; for a bare array you do NOT need (and must not use) a `$.items` path.

**Partial credit:** the PROSE correctly described both cases ("if your metadata is `[...]` use json_extract first; if it's `{"items":[...]}` the `$.items` reaches the array") — so the responder DID understand the distinction. But the **lead SQL contradicts the stated data**: it picked the wrapped-object form as the headline when the question showed a bare array. The prose's "if bare, use json_extract first" guidance is also slightly muddled — for a bare array the correct call is `json_array_length(metadata)` directly, not a json_extract wrapper. Accuracy dropped to 3.5 because the headline SQL does not run correctly on the given example; not lower because the prose flags the wrapped-vs-bare branch and json_array_length itself is the right function.

**Diagnosis:** copy-paste-incompleteness / wrong-default-branch — the responder led with the `$.items` wrapped-object template from the canonical instead of matching the bare-array example in the question. Findability slip: the r13 json_array_length LEADING CANONICAL likely shows the wrapped-object `$.items` form first, so the responder pasted it without reconciling to the bare-array data.

**iter616 (PRIMARY, MODERATE):** At the r13 json_array_length LEADING CANONICAL, make the **bare-array `json_array_length(metadata)` (no path) the LEAD/first worked example** (it is the most common shape and what this question asked), with the wrapped-object `json_array_length(json_extract(col, '$.items'))` as the SECONDARY "only if nested under a key" variant. Add a one-line PIN: "If the column IS the array (`[...]`), call `json_array_length(col)` directly — do NOT add a `$.items` path; `$.items` on a bare array returns NULL → length NULL." Reconcile-in-place (do not just append). Re-probe iter616-618 with a bare-array element-count question to confirm the lead form flips.

---

## Q4 — Recursive org-hierarchy walk (everyone under a VP)

**Answer:** `WITH RECURSIVE org_hierarchy AS (SELECT employee_id, manager_id, name, 1 AS depth FROM employees WHERE employee_id = :vp_id UNION ALL SELECT e.employee_id, e.manager_id, e.name, oh.depth+1 FROM employees e INNER JOIN org_hierarchy oh ON e.manager_id = oh.employee_id WHERE oh.depth < 20) SELECT employee_id, name, depth FROM org_hierarchy ORDER BY depth, employee_id`. Claimed "Trino enforces a session variable max_recursion_depth (default 10)."

| Dim | Score |
|---|---|
| Accuracy | 4.25 |
| Completeness | 4.25 |
| Clarity | 4.75 |
| Actionability | 4.5 |
| **Avg** | **4.4375 — PASS** |

**WITH RECURSIVE valid Trino 467** (docs-verified, experimental). Structure CORRECT for a top-down org walk: anchor selects the VP (`employee_id = :vp_id`, depth 1), recursive arm joins `employees e` on `e.manager_id = oh.employee_id` (children of already-found rows), `depth+1`, `UNION ALL`. The join direction is right (top-down: each iteration finds reports of the current frontier).

**`max_recursion_depth` claim ACCURATE (docs-verified).** Property name correct; default correct. Docs verbatim: "recursion depth is fixed, defaults to `10`, and doesn't depend on the actual query results" and "You can adjust the recursion depth with the session property `max_recursion_depth`." Good — a precise verified fact, not a fabrication.

**Real nuance the answer under-flags (−0.75 across Acc/Comp):** Two interacting facts the answer should have reconciled:
1. Trino's recursion depth is **FIXED** — it always expands to the configured depth regardless of whether the data has converged ("doesn't depend on the actual query results"). The `WHERE oh.depth < 20` guard is a logical filter on rows, NOT a substitute for the engine's fixed-depth cap.
2. If the actual hierarchy is deeper than `max_recursion_depth`, the query **ERRORS**: `NOT_SUPPORTED: Recursion depth limit exceeded (10). Use 'max_recursion_depth'` (verified — Trino/Athena share this message). So writing `WHERE oh.depth < 20` while the default is 10 is **internally inconsistent**: the engine errors at depth 10 before the `<20` guard ever matters, UNLESS the user first runs `SET SESSION max_recursion_depth = 20` (or higher). The answer mentioned the default-10 cap (good) but did NOT tell the engineer that `depth < 20` requires raising the session property, nor that exceeding the cap is a hard error (not a silent truncation). For a multi-level "everyone under a VP" walk on a deep org, this matters operationally.

**iter616 (LOW-MODERATE, reactive):** At the r27 §7A.1 WITH-RECURSIVE canonical, add: "Trino's recursion depth is FIXED (default `max_recursion_depth=10`) and independent of the data; if the hierarchy is deeper than the limit the query ERRORS with `Recursion depth limit exceeded (N)`. A `WHERE depth < K` guard does NOT raise the engine cap — if you need K levels, `SET SESSION max_recursion_depth = K` first. Plan growth is quadratic in depth, so set it to the realistic max org depth, not an arbitrary large number." The SQL is still valid and runs to depth 10 by default, so reactive-only.

---

## Summary

| Q | Acc | Comp | Clar | Act | Avg |
|---|---|---|---|---|---|
| Q1 parse+filter (FIX A) | 4.5 | 4.5 | 5.0 | 5.0 | 4.75 |
| Q2 7-day rolling avg | 4.75 | 4.5 | 5.0 | 5.0 | 4.8125 |
| Q3 JSON array length | 3.5 | 4.0 | 4.5 | 4.0 | 4.0 |
| Q4 WITH RECURSIVE | 4.25 | 4.25 | 4.75 | 4.5 | 4.4375 |

**Dimension averages:** Acc (4.5+4.75+3.5+4.25)/4 = 4.25; Comp (4.5+4.5+4.0+4.25)/4 = 4.3125; Clar (5.0+5.0+4.5+4.75)/4 = 4.8125; Act (5.0+5.0+4.0+4.5)/4 = 4.625.
**Overall = (4.25 + 4.3125 + 4.8125 + 4.625)/4 = 4.5 STRONG PASS.** Per-Q-avg cross-check: (4.75+4.8125+4.0+4.4375)/4 = 4.5 — agree.

**FIX A VERDICT: RESOLVED** — Q1 repeated `date_parse(...)` in WHERE, zero SELECT-output-alias reference; iter614 slip did not recur.

**Q1 type-check verdict:** `timestamp >= timestamp with time zone` **RUNS** in Trino 467 (implicit no-tz→with-tz coercion via session zone) — does NOT error; but it's session-zone dependent (#5685). Minor nit; cleaner is `localtimestamp`.

**Q3 verdict:** lead SQL's `$.items` path IS a JSONPATH-MISMATCH for the bare-array data — returns NULL. Correct form is `json_array_length(metadata)` directly. Prose covered both cases → partial credit. PRIMARY iter616 fix.

**Fabrications/slips:** NONE fabricated. `max_recursion_depth default 10` VERIFIED accurate (not a fabrication). No `::`-casts, no QUALIFY, no invalid clause placement, no off-by-one (Q2 7-row frame correct), no wrong-version pin. The only real defect is the Q3 lead-SQL path mismatch (routing/branch slip, prose-mitigated).

**iter616 directives:** (1) PRIMARY — flip the r13 json_array_length canonical so the bare-array `json_array_length(col)` no-path form is the LEAD example + add the "$.items on a bare array → NULL" PIN; re-probe bare-array count from a fresh angle. (2) LOW reactive — r27 §7A.1: fixed-depth + hard-error + `SET SESSION max_recursion_depth` note (depth<K guard ≠ raising the cap). (3) LOW reactive — r27 date_parse: "last N days" filter should use `localtimestamp` not `current_timestamp` on no-tz parsed timestamps. (4) Q2 r07 RANGE-interval gap-day one-liner (already exists at Pattern D; reactive). **DO NOT** touch r22 §13.x federation guardrails (4.49944/310 thin, ZERO probe iter615); add `::`-casts (iter571 PIN); rewrite the iter615 alias-in-WHERE GOTCHA (VALIDATED — landed); touch iter534-614 locks; bump training/state.json (already 615); git commit/push.

**Docs verified today:** trino.io/docs/467/functions/datetime.html (date_parse→timestamp(3) no-tz; current_timestamp→timestamp(3) with tz; localtimestamp no-tz), functions/json.html (`json_array_length(json)→bigint` accepts JSON-array string directly, `'[1,2,3]'`→3; json_extract→json, NULL on non-match), sql/select.html (WITH RECURSIVE fixed depth default 10, `max_recursion_depth` session property). WebSearch: trinodb/trino #5685/#37 (timestamp vs timestamp-with-tz coercion runs but session-zone dependent); Trino/Athena `Recursion depth limit exceeded (10)` hard error.
