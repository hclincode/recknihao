# Judge Feedback — Iter 613 (EXTENDED PHASE)

**Overall: 4.875 / 5 — STRONG PASS** (margin +1.375 above the 3.5 floor). Federation NOT probed this iteration. Four query-authoring questions (ROW dot-access, MAP transform_values, EXTRACT hour, gaps-and-islands streak). All four answers are valid Trino 467 and correct. **The CRITICAL Q4 gaps-and-islands query RUNS and produces the correct longest-streak** — the responder synthesized the islands trick correctly from primitives despite there being NO dedicated streak canonical in resources. The single known content-gap (gaps-and-islands) did NOT bite.

---

## Q1 — Pull `city` out of a nested ROW/struct `address` column

**Answer:** `SELECT user_id, address.city FROM users WHERE address.state = 'CA'` — dot notation on a native ROW column; "no element_at, no json_extract, no CAST".

| Dimension | Score |
|---|---|
| Accuracy | 5 |
| Completeness | 5 |
| Clarity | 5 |
| Actionability | 5 |
| **Average** | **5.0** |

**Verification (trino.io/docs/467/language/types.html):** "Named row fields are accessed with field reference operator (`.`)." Example: `CAST(ROW(1, 2.0) AS ROW(x BIGINT, y DOUBLE)).x`. Dot-access on a native ROW column is exactly correct; `address.city` and `WHERE address.state = 'CA'` are both valid (a ROW field reference is a normal expression usable in WHERE). The disambiguation is precisely right: native ROW → dot notation (no `element_at`, which is MAP/ARRAY-only and would type-error on a ROW; no `json_extract`, which is for JSON-text columns; no CAST needed). Routed cleanly to the r09:759 native-ROW-dot canonical. Zero issues.

## Q2 — Apply a 10% increase to every value in a `MAP(region->discount)` column

**Answer:** `transform_values(regional_discounts, (k, v) -> v * 1.10) AS increased_discounts`, plus a `CAST(v AS DECIMAL(10,2)) * 1.10` money-precision variant.

| Dimension | Score |
|---|---|
| Accuracy | 5 |
| Completeness | 5 |
| Clarity | 5 |
| Actionability | 5 |
| **Average** | **5.0** |

**Verification (trino.io/docs/467/functions/map.html):** signature `transform_values(map(K, V1), function(K, V1, V2)) → map(K, V2)`, "Returns a map that applies `function` to each entry of `map` and transforms the values." The `(k, v) -> v * 1.10` lambda is the correct 2-arg shape; it returns a NEW map with every value scaled, keys untouched — exactly what "transform every value" asks for. `v * 1.10` is valid (numeric × DECIMAL literal). The optional `CAST(... AS DECIMAL(10,2)) * 1.10` variant is a sensible money-precision touch and is valid. Routed cleanly to r09:687 MAP-HOF canonical. Zero issues.

## Q3 — Extract hour-of-day (0–23) from a timestamp to GROUP BY for a heatmap

**Answer:** `EXTRACT(HOUR FROM event_timestamp) AS hour_of_day ... GROUP BY EXTRACT(HOUR FROM event_timestamp)` — returns 0–23.

| Dimension | Score |
|---|---|
| Accuracy | 5 |
| Completeness | 4.5 |
| Clarity | 5 |
| Actionability | 5 |
| **Average** | **4.875** |

**Verification (trino.io/docs/467/functions/datetime.html):** "Returns the hour of the day from `x`. The value ranges from `0` to `23`." Return type `bigint`. `EXTRACT(HOUR FROM ts)` is correct and the 0–23 claim is verbatim accurate. Repeating the full expression in GROUP BY (rather than relying on the SELECT alias) is the Trino-safe form and always works.

**Minor (Completeness −0.5):** did not mention the equivalent shorthand `hour(event_timestamp)` (also 0–23), nor `date_trunc('hour', ts)` for the truncated-timestamp form. Not required for a 24-bucket heatmap; the integer-hour answer is the right choice. No accuracy impact.

## Q4 — CRITICAL: each user's LONGEST streak of consecutive active days (gaps-and-islands)

**Answer:**
```sql
WITH daily_activity AS (
  SELECT DISTINCT user_id, DATE(event_timestamp) AS activity_date FROM events
),
streaks AS (
  SELECT user_id, activity_date,
         activity_date - INTERVAL '1' DAY * ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY activity_date) AS streak_group
  FROM daily_activity
),
streak_lengths AS (
  SELECT user_id, COUNT(*) AS streak_length FROM streaks GROUP BY user_id, streak_group
)
SELECT user_id, MAX(streak_length) AS longest_streak FROM streak_lengths GROUP BY user_id
```

| Dimension | Score |
|---|---|
| Accuracy | 5 |
| Completeness | 4.5 |
| Clarity | 4.5 |
| Actionability | 5 |
| **Average** | **4.75** |

### Q4 VERDICT: VALID + CORRECT Trino 467. The content-gap did NOT bite.

Piece-by-piece verification against Trino 467:

1. **`DATE(event_timestamp)`** — VALID. Docs (datetime.html): "`date(x) → date` — This is an alias for `CAST(x AS date)`." Truncates the timestamp to a date. Correct.
2. **`INTERVAL '1' DAY * ROW_NUMBER() OVER (...)`** — VALID. Interval × number multiplication IS supported in Trino's type system (the `IntervalDayTime` MULTIPLY operator accepts a numeric operand; `ROW_NUMBER()` returns `bigint`). NOTE: the official datetime/types doc pages do NOT explicitly *document* interval scalar multiplication — but it is implemented and is the canonical Trino gaps-and-islands idiom (corroborated by community references and StarRocks issue #55574, which cites Trino as supporting `interval * number`). It runs.
3. **Operator precedence** — CORRECT. `*` binds tighter than `-`, so the expression parses as `activity_date - (INTERVAL '1' DAY * rn)`. `date - day_interval` returns a date (docs: `date '2012-08-08' - interval '2' day → 2012-08-06`). Correct.
4. **The islands logic** — CORRECT. Within a run of consecutive days, `activity_date` increments by 1 day per row and `rn` increments by 1 per row, so `activity_date - rn*(1 day)` is CONSTANT within a run and DIFFERENT across a gap. GROUP BY `(user_id, streak_group)` + `COUNT(*)` = each streak's length; `MAX` per user = longest streak. Worked check Mon-Tue-Wed / skip-Thu / Fri-Sat → Mon/Tue/Wed share one `streak_group` (count 3), Fri/Sat share another (count 2), MAX = **3**. Correct.

**NET:** the query is valid Trino 467 and returns the correct longest-streak. The responder SYNTHESIZED the islands trick correctly from primitives (DISTINCT, DATE cast, ROW_NUMBER, interval arithmetic) even though resources have NO dedicated streak/gaps-and-islands canonical at the r07 window-pattern landing point. **Recommendation: the gaps-and-islands canonical stays an OPTIONAL/WATCH-ITEM for iter614** — do NOT add it pre-emptively (the no-churn / 22-pass durability posture holds). Add it only REACTIVELY if a future probe lands on streaks and the responder fails.

**Deductions:**
- **Clarity (−0.5):** the prose says the approach "uses ROW_NUMBER() and `date_diff`" but the SQL actually uses interval multiplication (`INTERVAL '1' DAY * ROW_NUMBER()`), not `date_diff`. The SQL is correct; the prose mislabels the mechanism. A reader copying the (correct) SQL is fine, but the explanation names the wrong primitive. Clarity nit, not an accuracy bug.
- **Completeness (−0.5):** no note that `DISTINCT` is load-bearing (without it, multiple events on the same day would inflate the count and break the `rn`-increments-by-1-per-day invariant); no empty-activity/tie edge note. Not required, but would harden the answer.

---

## Diagnosis of the one slip

- **Q4 prose "date_diff" mislabel** — NOT a content-gap, NOT a routing miss, NOT a resource defect. The SQL is correct; the responder simply narrated the wrong primitive name. Classify as a **minor self-narration slip** (the answer over-described a `date_diff` step it didn't actually emit). No teacher action required — the SQL is right and resources carry no contradictory `date_diff`-streak content the responder could have mis-cited. If a streak canonical is ever added (reactively), use the interval-multiplication form the responder already got right and name it explicitly.

No fabricated features, no `::`-cast, no invalid-clause-placement, no off-by-one, no wrong-function-choice, no interval-arithmetic invalidity found across any of the four answers.

---

## ITER614 GUIDANCE

- **HOLD NO-OP** on resources/ unless a probe fails. 22+ consecutive passes; resources are stable. Manufacturing a gaps-and-islands card for a question the responder already answers correctly is the churn risk to avoid.
- **Single WATCH-ITEM (unchanged from iter612/613):** gaps-and-islands consecutive-streak has no dedicated canonical at the r07 window-pattern landing point. It did NOT bite this iteration (responder synthesized it correctly). Keep it REACTIVE-only: add a streak canonical (interval-multiplication form, `DISTINCT` load-bearing note, avoid the `date_diff` mislabel) ONLY if a future streak probe produces an invalid or wrong query.
- **Probe suggestions for iter614:** re-probe gaps-and-islands from a different angle (e.g., "longest GAP between purchases" or "label each run of consecutive logins with a session number") to confirm the synthesis is durable across phrasings before declaring the watch-item closed. Also worth a federation re-probe (thin-margin row not exercised in 600+ iters) to keep it warm.

**Overall: (5.0 + 5.0 + 4.875 + 4.75) / 4 = 4.875 — STRONG PASS.**
