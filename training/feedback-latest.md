# Judge Feedback — iter1095 (2026-06-25)

**Overall: 4.953 STRONG PASS** (overall average governs; NO per-question veto). Clean sweep; ZERO source-verified defects. **Q1 ROOT-CAUSE FIX-A CONFIRMED REACHING THE RESPONDER CLEANLY.**

Verified BOTH directions vs RAW git-tag 467 source + Joda-Time API + official Trino docs:
- `DateTimeFunctions.java` (467) `diffDate` → Joda `getDateField(...).getDifferenceAsLong(...)` (state.json note + iter1094 chain)
- Joda-Time `DateTimeField.getDifferenceAsLong` Javadoc: "Any fractional units are dropped from the result" (re-verified via WebSearch this iter)
- `r23` L2213-2225 LEADING-CANONICAL AGE block (post-FIX-A): bare `date_diff('year', date_of_birth, current_date)`, worked example "dob 2000-06-15, today 2026-06-14 → 25 (partial 26th year dropped), today 2026-06-15 → 26"
- `r27` L766-768 MONTHS_BETWEEN mapping (post-FIX-A): "integer count of *complete*, day-aware months — drops the fractional part... NOT a count of boundary crossings"
- `functions/window.md` (LAG default offset 1, default value NULL)
- `sql/select.md` UNNEST + CROSS JOIN UNNEST drops NULL/empty arrays
- WebSearch: Joda-Time `DateTimeField` API (fractional-dropped semantics confirmed verbatim)

---

## Q1 — Loyalty: complete years subscribed (Sept-15-2021 vs Mar-3-2021) — 5.00  ← FIX-A REACHED CLEANLY

- Accuracy 5 | Completeness 5 | Clarity 5 | Actionability 5

`SELECT customer_id, signup_date, date_diff('year', signup_date, current_date) AS years_subscribed FROM subscriptions;`

**FIX-A confirmation:** the iter1095 root-cause reconciliation of r23 ~L2213 (removed the wrong "year-field subtraction, =26" canonical and the corrupting CASE-subtract-1 idiom) + r27 L732/L739/L768 (removed the "count of month boundaries crossed" narration and the wrong "=2" example) reached the responder cleanly. The responder produced:

1. **Bare `date_diff('year', signup_date, current_date)` with NO CASE adjustment** — exact match to the new canonical. No subtract-1, no boundary correction, no leap-year hand-waving. The single expression IS the answer.
2. **Day-aware / complete-units narration** — described as "returns complete years, day-aware". Matches the verified Joda contract ("Any fractional units are dropped from the result").
3. **Correct worked numbers**:
   - Sept-15-2021 → June-2025 = **3** ("4th anniversary not arrived"). True value: anniversaries 2022/2023/2024 passed, 2025 not yet → 3. ✓
   - March-3-2021 → June-2025 = **4**. True value: anniversaries 2022/2023/2024/2025 all passed → 4. ✓
4. **Quietly corrected the engineer's own arithmetic slip** — the engineer stated "2 years" for the Sept-15-2021 case but the true day-aware value is 3 (per judge-prompt instruction). The responder produced 3 (the truth) without echoing the engineer's wrong "2". This is the exact behavior FIX-A was meant to produce: the responder trusts the canonical over an off-by-one user prior.

No CASE shenanigans, no "+1 leap-year" folklore, no over-warning. Source-verified clean against RAW 467 `DateTimeFunctions.java` → Joda `yearOfEra().getDifferenceAsLong` (drops fractional). The 1094 regression (boundary-crossing narration, "=2 is what you want") is fully closed.

## Q2 — LAG(plan_name) for previous plan per user, no self-join — 5.00

- Accuracy 5 | Completeness 5 | Clarity 5 | Actionability 5

`LAG(plan_name) OVER (PARTITION BY user_id ORDER BY event_timestamp) AS previous_plan`. Verified `functions/window.md` (467): `lag(x)` returns the value at the row preceding the current row within the partition; default offset 1, default value NULL. PARTITION BY user_id scopes to per-user history; ORDER BY event_timestamp orders chronologically so the immediately-preceding row is the prior event. First row per user → NULL (no preceding row), correctly noted by the responder — flagging signup events / users with only one row. No self-join needed (the canonical motivation for window functions). Trailing `ORDER BY user_id, event_timestamp` for display readability is harmless.

Plan-change detection follow-on (`WHERE previous_plan IS NOT NULL AND previous_plan <> plan_name`) is the natural next step — responder set up the row shape correctly for it.

## Q3 — UNNEST feature_flags array, distinct users per flag — 4.9375

- Accuracy 5 | Completeness 5 | Clarity 4.75 | Actionability 5

`SELECT flag, COUNT(DISTINCT user_id) AS n_users_with_flag FROM events e CROSS JOIN UNNEST(e.feature_flags) AS t(flag) GROUP BY flag ORDER BY n_users_with_flag DESC;`

Verified `sql/select.md` (467) UNNEST: an array `ARRAY<T>` unnests into a single column of type `T`, so `AS t(flag)` (one alias) is correct. `CROSS JOIN UNNEST(arr)` is the canonical Trino flatten pattern. `COUNT(DISTINCT user_id)` per flag is the right popularity metric (counts unique users not unique events — a user with two events both flagging `dark_mode` counts once for that flag, which is what "popular by user reach" means).

**Correctly flagged caveat:** "CROSS JOIN (not LEFT JOIN) drops NULL/empty arrays" — verified. To preserve users with NULL or empty `feature_flags`, switch to `LEFT JOIN UNNEST(e.feature_flags) AS t(flag) ON true` (the `ON true` is required Trino syntax for LEFT JOIN UNNEST). The responder mentioning this nuance is a strong-signal answer; minor Clarity shave only because the LEFT JOIN UNNEST exact form wasn't spelled out (not penalized as a defect — the engineer can find it from the keyword the responder gave).

No fabricated `unnest_array` / `array_explode` / `flatten` function (the recurring foreign-prior trap); no `WITH ORDINALITY` mis-applied (orthogonal).

## Q4 — Dedup (user_id, event_type, occurred_at) before aggregating — 4.875

- Accuracy 5 | Completeness 4.5 | Clarity 5 | Actionability 5

Primary: inner `SELECT DISTINCT user_id, event_type, occurred_at FROM events` subquery, then GROUP BY + COUNT(*) on top. Alternative: bare `SELECT DISTINCT`. Both correct. "Trino 467 has no DISTINCT ON (Postgres-only)" — VERIFIED true; DISTINCT ON is a Postgres-specific extension, not in Trino 467 SQL grammar. Useful defensive note — engineers migrating from Postgres routinely try `SELECT DISTINCT ON (user_id) ...` and hit parse errors.

Pattern is the canonical Trino approach: dedup-then-aggregate via a subquery is exactly what the engineer asked for and avoids inflated counts from the 2-3x pipeline double-write. SELECT DISTINCT and GROUP BY-all-columns are semantically identical in Trino (the optimizer plans them the same way) — the responder's framing of "DISTINCT in subquery, then aggregate" is correct and clean.

**Minor completeness gap (not penalized as defect):** the responder didn't mention the `ROW_NUMBER() OVER (PARTITION BY user_id, event_type, occurred_at ORDER BY <tiebreaker>) = 1` alternative, which becomes "better than SELECT DISTINCT" only when there ARE other columns in the row that differ between duplicates and you need to keep ONE specific row (e.g., the latest ingestion). For the engineer's stated case — pure 2-3x exact-triple duplicates — SELECT DISTINCT (or GROUP BY all cols) is genuinely the right answer and ROW_NUMBER would be over-engineering. Half-point completeness shave is for not making this scope-of-use distinction explicit, NOT for an error.

No false-claim that DISTINCT is slow / forbidden / "use GROUP BY only" folklore (the Postgres folklore trap); no `OVER(PARTITION BY ... QUALIFY ...)` (QUALIFY is not in Trino 467).

---

## Scores

| Q | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|
| Q1 date_diff complete years loyalty | 5 | 5 | 5 | 5 | 5.000 |
| Q2 LAG previous plan per user | 5 | 5 | 5 | 5 | 5.000 |
| Q3 CROSS JOIN UNNEST array | 5 | 5 | 4.75 | 5 | 4.9375 |
| Q4 dedup SELECT DISTINCT subquery | 5 | 4.5 | 5 | 5 | 4.875 |

**Overall average = (5.000 + 5.000 + 4.9375 + 4.875) / 4 = 4.953 → STRONG PASS** (+1.453 above 3.5 threshold)

Source-verified defects: **NONE.**

---

## FIX-A Verdict

The iter1095 root-cause reconciliation is **CONFIRMED REACHING THE RESPONDER CLEANLY** on the first re-probe. Q1 produced:
- Bare `date_diff('year', ...)` with no CASE adjustment (matches r23 L2213 post-FIX-A canonical)
- Day-aware/complete-units narration (no "boundary crossing" folklore)
- Correct worked numbers (3 and 4), and quietly corrected the engineer's "2" arithmetic slip without echoing it

The two contradicting source-wrong canonicals (r23 ~L2213 pre-fix "=26 with subtract-1 CASE" and r27 L732/L739/L768 "boundary crossings, =2") are now both reconciled-in-place with day-aware/complete-units narration. No residual folklore artifact in the responder's Q1.

This is a clean close on the iter1094 Q2 narration defect family AND the iter641-pinned AGE under-counting defect (the subtract-1 CASE that ACTIVELY under-counted age by 1). Two long-standing source-wrong pins removed in one root-cause sweep — matches the [Trace Recurring Folklore to Resource Root Cause] pin discipline.

---

## Topic checklist updates

All four questions hit topics already at PASSED status with thick margins. Updates:

- **SQL query best practices for OLAP** (Q1 date_diff, Q3 UNNEST, Q4 SELECT DISTINCT dedup) — incremental reinforcement, already PASSED at 4.4600 / 153 Qs. New Qs touched: +3.
- **Analytical query patterns on Iceberg+Trino: funnels, cohorts, time-series SQL** (Q1 tenure/loyalty time-series, Q2 LAG plan-change cohort) — already PASSED at 4.3567 / 47 Qs. New Qs touched: +2.

No topic state-flip; no near-threshold topic touched; federation row unchanged (no federation probe this iter).

---

## Teacher guidance

**RECOMMENDATION: DEFAULT NO-OP.** Margin +1.453 above threshold, zero source-verified defects, FIX-A confirmed reaching cleanly. Do NOT churn the r23 / r27 date_diff canonical further — the reconciliation landed. Do NOT add additional defensive worked examples for date_diff (the existing AGE-canonical + Jan-15→Mar-10 month example covers both year and month axes).

**Do NOT bump state.json** (already at 1095). **Do NOT add a federation probe** — federation is still the only NEEDS-WORK row at 4.4994 / 310 Qs, but breadth-probing it on a clean iter risks re-introducing churn on a near-threshold topic right after a major FIX-A landed; let the FIX-A bake one more sweep before re-probing federation.

**Re-probe priority for next sweep (informational only, not required):**
- One more date_diff angle from a 3rd phrasing (e.g., "months since first purchase" or "weeks of inactivity") to confirm FIX-A holds across phrasings, not just loyalty/age.
- The recurring [Responder Broken Secondary Alternative] pattern did NOT fire this iter — confirm it stays quiet across at least one more sweep before considering it dormant.

**No commit needed beyond the iter1095 FIX-A already committed.** No DO-NOT-WRITE additions; the post-FIX-A canonicals are the copy-attractive forms now.
