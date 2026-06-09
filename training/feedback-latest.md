# Judge Feedback — iter796 (FINDABILITY FIX-A re-check: regexp_extract first-digit-run)

**Phase:** extended / final-style (end-of-iteration feedback)
**Verification date:** 2026-06-09 — all dialect claims verified vs trino.io/docs/467 (regexp / datetime / aggregate .html) + WebSearch (alias-not-allowed-in-WHERE).
**Production fit:** Trino 467 + Iceberg, on-prem. All four answers are pure SQL within stack constraints. No auth/authz scope.

---

## Per-question scores

### Q1 — Extract numeric part of reference_code as integer (FIX-A KEY CHECK)
**Answer:** `CAST(regexp_extract(reference_code, '[0-9]+') AS INTEGER) AS order_num` — 'ORD-000123-X'→123, 'INV-4567-A'→4567; cites new r23 §3.2 card.

- **Verified vs regexp.html:** `regexp_extract(string, pattern)` returns "the first substring matched by the regular expression pattern in string." `regexp_extract('ORD-000123-X','[0-9]+')` = `'000123'` → `CAST AS INTEGER` = `123`; `'INV-4567-A'` → `'4567'` → `4567`. CORE ANSWER CORRECT.
- **FIX CONFIRMED:** Responder LED with `CAST(regexp_extract(s,'[0-9]+') AS INTEGER)` — did NOT use the iter795 broken `regexp_replace('[^0-9].*','')` form, did NOT repeat the false "no digit-extraction function" claim, and cited the new r23 §3.2 fenced canonical. The iter796 FINDABILITY FIX-A WORKED. **regexp_extract → CLOSED (1st post-fix datapoint, clean).**
- **SECONDARY SLIP (minor, example-only):** the example query has `... WHERE order_num > 100 ORDER BY order_num`, where `order_num` is a SELECT alias. Verified vs Trino SELECT semantics (WebSearch + Trino SELECT docs): WHERE is evaluated BEFORE SELECT, so a SELECT alias is NOT resolvable in WHERE → `WHERE order_num > 100` would ERROR ("column 'order_num' cannot be resolved"). Correct forms: repeat the expression in WHERE, or wrap in a subquery/CTE. (`ORDER BY order_num` IS valid — alias allowed in ORDER BY.) This is an example imprecision, NOT a defect in the tested core answer.

- Accuracy: **4** (core regexp_extract+CAST fully correct & verified; alias-in-WHERE example would not compile)
- Completeness: **5** (digit-run semantics, first-match behavior, CAST, sort/join use all covered)
- Clarity: **5** (clear walkthrough, `[0-9]+`/first-match explained, worked on both examples)
- Actionability: **4** (copy-pasteable core; the example's `WHERE order_num` line would need a fix before it runs)
- **Q1 avg = 4.50**

### Q2 — Truncate timestamp to day for GROUP BY
**Answer:** `date_trunc('day', event_time) AS day ... GROUP BY date_trunc('day', event_time)`. Cites r07 + r13.

- **Verified vs datetime.html:** `date_trunc('day', timestamp)` truncates to start of day (midnight); docs example `date_trunc('day', TIMESTAMP '2022-10-20 05:10:00')` → `2022-10-20 00:00:00.000`. CORRECT. Repeating the expr in SELECT and GROUP BY is the right idiom (GROUP BY-by-ordinal or by-expression both valid).
- Accuracy **5** / Completeness **5** / Clarity **5** / Actionability **5**
- **Q2 avg = 5.00**

### Q3 — SUM of refunds → 0 instead of NULL
**Answer:** `COALESCE(SUM(refund_amount), 0) AS total_refunds`. Cites r07 §1a SUM gotcha.

- **Verified vs aggregate.html:** "all of these aggregate functions ignore null values and return null for no input rows or when all values are null" — `sum()` returns null, not zero, over zero/all-NULL input. `COALESCE(..., 0)` → 0. CORRECT (standard COALESCE-SUM-0 idiom; same fix also covers a group with rows but all-NULL values).
- Accuracy **5** / Completeness **5** / Clarity **5** / Actionability **5**
- **Q3 avg = 5.00**

### Q4 — Fold attr_key/attr_value rows into one map per user
**Answer:** `map_agg(attr_key, attr_value) AS user_attributes GROUP BY user_id`; lookup via `element_at(map,'plan')` (NULL if missing) or `map['plan']` (errors if missing). Cites r07 §1a.

- **Verified vs aggregate.html:** `map_agg(key, value) -> map<K,V>` aggregates key/value pairs over the group → one map per `user_id`. CORRECT. The `element_at` (NULL-safe) vs subscript `[]` (fails on missing key) distinction is accurate (matches the map element_at pin). Minor optional caveat not raised: duplicate keys within a group yield an arbitrary/erroring value — not required for a key/value-row fold.
- Accuracy **5** / Completeness **5** / Clarity **5** / Actionability **5**
- **Q4 avg = 5.00**

---

## Overall

| Q | Acc | Compl | Clar | Action | Avg |
|---|---|---|---|---|---|
| Q1 | 4 | 5 | 5 | 4 | 4.50 |
| Q2 | 5 | 5 | 5 | 5 | 5.00 |
| Q3 | 5 | 5 | 5 | 5 | 5.00 |
| Q4 | 5 | 5 | 5 | 5 | 5.00 |

**Overall avg = (4.50 + 5.00 + 5.00 + 5.00) / 4 = 4.875 → PASS** (threshold 3.5).

---

## Teacher feedback

**(a) Is regexp_extract CLOSED?** YES. The iter796 FIX-A worked on its first re-probe. Q1 led with `CAST(regexp_extract(reference_code,'[0-9]+') AS INTEGER)`, produced correct outputs (123, 4567), avoided the iter795 broken `regexp_replace('[^0-9].*','')` workaround, dropped the false "no digit-extraction function" premise, and cited the new fenced r23 §3.2 canonical. **regexp_extract first-digit-run = CLOSED (1st clean post-fix datapoint).** A 2nd re-probe from a different phrasing (e.g., "strip the prefix and parse the trailing number") in a future durability sweep would bulletproof it before fully retiring attention.

**(b) Q1 alias-in-WHERE slip — warrants what?** Just a NOTE, no FIX-A. The slip is in the *example* (`WHERE order_num > 100` references a SELECT alias, which Trino cannot resolve in WHERE — would error), not in the core regexp_extract answer that the re-probe tested. It cost a 1-point ding each on Accuracy and Actionability for Q1, no more. This is a general SQL-evaluation-order imprecision, not a Trino dialect/resource defect, and it does not negate the fix. If the responder repeats "alias usable in WHERE" 2+ times across questions, consider a small one-line note in r07/r23 ("a SELECT alias is usable in GROUP BY/HAVING/ORDER BY but NOT in WHERE — repeat the expression or wrap in a subquery"). One occurrence = monitor only; do not churn resources for it now.

**(c) iter797 designation:** **DEFAULT NO-OP / durability-breadth sweep.** No open resource defect. regexp_extract is now closed; Q2/Q3/Q4 are clean standing pins (date_trunc, COALESCE-SUM-0, map_agg/element_at). Teacher should make ZERO edits and probe 4 fresh adjacent angles (suggestions: 2nd regexp_extract re-probe with different phrasing to bank a 2nd datapoint / array of distinct values per group via `array_agg(DISTINCT ...)` / `from_unixtime` epoch→timestamp / `multimap_agg` vs `map_agg` for duplicate-key folding). PRESERVE r23 §3.2 regexp_extract canonical, r07 date_trunc/COALESCE-SUM/map_agg cards — all verified clean 2026-06-09, churn risk.

**Do NOT touch training/state.json** (already at 796).
