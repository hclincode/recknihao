# Judge Feedback — iter1032

**Phase**: extended (passed=true). Overall average governs; NO per-question veto. No federation/auth angle in any of the 4 questions; all 4 fit the prod stack (Trino 467 + Iceberg + MinIO + Hive Metastore).

Verified BOTH directions against RAW git-tag 467 source (raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/...), NOT resources/.

---

## Q1 — last-30-days cutoff: `created_at >= current_timestamp - 30`?

**Answer**: Use `date_add('day', -30, current_timestamp)`; says `current_timestamp - 30` does NOT parse (no timestamp-minus-integer operator), must name the unit.

**Verified (functions/datetime.md, git-tag 467):**
- `date_add(unit, value, timestamp)` — "Adds an interval `value` of type `unit` to `timestamp`. Subtraction can be performed by using a negative value." Returns same type as input. Responder's `date_add('day', -30, current_timestamp)` is the correct signature and correct negative-value-for-subtraction idiom.
- Temporal arithmetic uses INTERVAL only (e.g. `date '2012-08-08' + interval '2' day`). There is NO timestamp-minus-bare-integer operator. The responder's "does not parse" claim is ACCURATE — `timestamp - 30` is not valid Trino.
- Minor completeness point only: `current_timestamp - INTERVAL '30' DAY` is an equally valid form the responder could have mentioned. Its absence is not a defect; the lead form is correct and idiomatic.

**Scores** — Accuracy 5 / Clarity 4.75 / Applicability 4.75 / Completeness 4.5 → **4.75**
Reasoning: lead fully correct and verified; "does not parse" diagnosis right; only the unmentioned INTERVAL alternative trims completeness slightly.

---

## Q2 — spend-tier labeling (low <$50 / medium $50–$200 / high >$200)

**Answer**: `CASE WHEN ... < 50 'low' / BETWEEN 50 AND 200 'medium' / ELSE 'high' END`, grouped by user with `SUM(order_total)`; mentions `if()` for 2-outcome case; says CASE/if() same plan.

**Verified (functions/conditional.md, git-tag 467):**
- Docs state "The following `IF` and `CASE` expressions are equivalent" — the CASE/if() "same plan" characterization is sound, not worth dinging.
- `if()` is 2-arg `if(condition, true_value)` or 3-arg `if(condition, true_value, false_value)` — responder's 2-outcome `if()` mention is accurate.
- BETWEEN is inclusive. Boundary check: `< 50` → low; `BETWEEN 50 AND 200` → medium (exactly $50 and exactly $200 both land in medium); `ELSE` (> 200) → high. NO gap, NO overlap. Bucket logic is sound for the stated spec.

**Scores** — Accuracy 5 / Clarity 4.75 / Applicability 4.75 / Completeness 4.75 → **4.8125**
Reasoning: correct, clean boundaries, useful SUM-per-user framing, accurate if()-vs-CASE nuance.

---

## Q3 — discover all DISTINCT keys across an `events.metadata` MAP column

**Answer**: `SELECT DISTINCT key FROM events CROSS JOIN UNNEST(map_keys(metadata)) AS t(key) ORDER BY key`; explains `map_keys`→array(varchar), UNNEST explodes, DISTINCT dedups.

**Verified:**
- functions/map.md: `map_keys(x(K,V)) -> array(K)` — returns an array of the keys. Confirmed.
- sql/select.md: CROSS JOIN UNNEST(array) AS t(col) is the canonical pattern ("UNNEST is normally used with a JOIN"; example `CROSS JOIN UNNEST(scores) AS t(score)`). Confirmed.
- DISTINCT across the exploded rows correctly dedups keys; ORDER BY key is fine.
- More efficient alt exists (`array_distinct(flatten(array_agg(map_keys(metadata))))`) but the UNNEST form is correct and most beginner-readable; its absence is not a defect.

**Scores** — Accuracy 5 / Clarity 4.75 / Applicability 4.75 / Completeness 4.75 → **4.8125**
Reasoning: fully correct, each step explained for a beginner, directly runnable.

---

## Q4 — users who signed up in January but never ordered

**Answer**: `SELECT user_id FROM users WHERE signup_month='January' EXCEPT SELECT user_id FROM orders`; says EXCEPT is set-difference, NULL-safe, requires same column count/types; LEFT JOIN + IS NULL also works but more error-prone.

**Verified (sql/select.md, git-tag 467):**
- "If neither is specified, the behavior defaults to `DISTINCT`." EXCEPT defaults to DISTINCT — responder's set-difference + dedup characterization is correct.
- NULL handling: set operations treat NULLs as equal for dedup/difference purposes (standard SQL DISTINCT semantics). The "NULL-safe" characterization is accurate — EXCEPT does NOT carry the NOT IN (subquery-with-NULL) zero-rows footgun. Matches r23 §10 anti-join / EXCEPT NULL-safe canonical.
- Same column count / compatible types requirement is correct.
- Note: EXCEPT dedups the left side, so duplicate January signups collapse — fine for a user_id list, exactly the ask.

**Scores** — Accuracy 5 / Clarity 4.75 / Applicability 4.75 / Completeness 4.75 → **4.8125**
Reasoning: correct, NULL-safe claim verified, good contrast with the error-prone LEFT JOIN + IS NULL path. EXCEPT is the cleaner lead for this question.

---

## Overall

| Q | Accuracy | Clarity | Applicability | Completeness | Avg |
|---|---|---|---|---|---|
| Q1 | 5 | 4.75 | 4.75 | 4.5 | 4.75 |
| Q2 | 5 | 4.75 | 4.75 | 4.75 | 4.8125 |
| Q3 | 5 | 4.75 | 4.75 | 4.75 | 4.8125 |
| Q4 | 5 | 4.75 | 4.75 | 4.75 | 4.8125 |

**Overall average = (4.75 + 4.8125 + 4.8125 + 4.8125) / 4 = 4.796875 → PASS** (margin +1.296875 over 3.5).

`::` cast ABSENT all 4. TICS CLEAN: all functions real & verified (date_add, map_keys, UNNEST, if/CASE, EXCEPT); no QUALIFY / no false semi-join / no regex-backslash / no INTERVAL quarter-week / no OFFSET-before-LIMIT / no broken "for completeness" secondary alternative / no over-warning folklore.

**Source-verified defects: NONE.** All four answers correct in both directions.

**RECOMMENDATION = DEFAULT NO-OP.** No resource edit, no FIX-A, no git commit. No source-verified resource defect and no 2-in-2 same-shape slip. Margin is comfortable.

Re-probe (monitor only, no action):
- (a) date_add('day',-N,ts) negative-value + "timestamp - integer does not parse" + optionally INTERVAL '30' DAY form
- (b) CASE bucket boundaries inclusive-BETWEEN no-gap/overlap + if() 2/3-arg + CASE/if() same-plan
- (c) map_keys→array + CROSS JOIN UNNEST AS t(key) + DISTINCT; watch for array_distinct(flatten(array_agg)) alt
- (d) EXCEPT defaults-DISTINCT + NULL-safe vs NOT IN footgun + LEFT JOIN+IS NULL contrast

Federation r22 §13.x hard-locked, NOT probed (4.49944/310). MUST NOT bump state.json (already 1032; orchestrator commits once after judge).
