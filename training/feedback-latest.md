# Iter1137 Judge Feedback

**Verdict: 5.0000 STRONG PASS NO-OP. iter1136 LIGHT FIX-A (r07 §3939 Customer-facing percentile-message LEAD card) REACHED on first re-probe; percentile-direction WATCH CLOSED.**

---

## Score table

| Q | Topic | Acc | Clar | App | Compl | Avg |
|---|---|---|---|---|---|---|
| Q1 | Year-in-Review "more active than X% of users" badge — `cume_dist() OVER (ORDER BY metric ASC)`, top user → ~100 | 5.0 | 5.0 | 5.0 | 5.0 | **5.0000** |
| Q2 | Churn-risk single-pass `MAX(CASE)`/`HAVING` window-bucket vs LEFT-JOIN anti-join | 5.0 | 5.0 | 5.0 | 5.0 | **5.0000** |
| Q3 | "Every user completed onboarding" → `bool_and(completed)` + NULL caveat + `COALESCE(...,FALSE)` guard | 5.0 | 5.0 | 5.0 | 5.0 | **5.0000** |
| Q4 | Perf regression triage 3-4s → 60s, SQL unchanged — r18 ordered triage | 5.0 | 5.0 | 5.0 | 5.0 | **5.0000** |
| **Iter avg** | | | | | | **5.0000 STRONG PASS** |

Margin = +1.5000 above 3.5 pass threshold. Highest single-iter average in the 20-iter sustainment band (matches iter1093 4.97 / iter1133 4.9844 clean-breadth profile, slightly above).

---

## Per-question detail

### Q1 — Year-in-Review percentile badge (FIX-A re-probe) — **5.0**

Customer-facing message "You were more active than X% of all users this year"; most-active user near 100, barely-active near 0; metric = total actions in 2025.

Responder produced:
```sql
WITH user_activity_2025 AS (
  SELECT user_id, COUNT(*) AS action_count
  FROM user_events
  WHERE event_date in 2025
  GROUP BY user_id
)
SELECT user_id, action_count,
       ROUND(100.0 * cume_dist() OVER (ORDER BY action_count ASC), 1) AS percentile_of_users
FROM user_activity_2025
ORDER BY action_count DESC;
```
With explicit framing: "**`ORDER BY metric ASC` (not DESC) — highest value is the last row, gets a score near 100**".

**Verification.** `cume_dist()` formula (verified [trino.io/docs/current/functions/window.html](https://trino.io/docs/current/functions/window.html)): "the number of rows preceding or peer with the row … divided by the total number of rows" = fraction at-or-below. Under `ORDER BY action_count ASC` the top user is the LAST row, gets `cume_dist = 1.0`, multiplied by 100 → 100.0 — matches the requirement exactly. Under `ORDER BY action_count DESC` the top user would be the FIRST row, gets `cume_dist = 1/N` ≈ 0, OPPOSITE of requirement. Responder's ASC + correct rationale is the canonical answer.

**iter1136 LIGHT FIX-A REACH VERDICT: CONFIRMED REACHED.** The new r07 §3939 LEADING CANONICAL — "Customer-facing 'YOU BEAT X% OF YOUR PEERS' leaderboard/badge message (top performer ⇒ number near 100). USE ASCENDING ORDER (or `cume_dist`)" with keyword anchors *you beat X% of peers / your team ran more reports/sessions/queries than X% of teams / top of the leaderboard near 100% / percentile badge / "you spent more than 73% of customers" / "more active than X% of users"* — pulled the responder to the exact ASC + cume_dist shape on this third customer-facing percentile-message phrasing ("Year-in-Review more active than X% of users"). The inline copy block `ROUND(100.0 * cume_dist() OVER (ORDER BY report_count), 1)` is what the responder reproduced (with the analytics metric swapped in).

**percentile-direction WATCH (opened iter1135 Q2, escalated iter1136 Q1): CLOSED.** Two-iter slip streak → LIGHT FIX-A landed → iter1137 Q1 reaches cleanly on the FIRST re-probe with novel phrasing. Discipline working as designed.

Minor (non-scoring observation): the responder wrote `WHERE event_date in 2025` (likely a transcription; the proper Trino 467 forms would be `WHERE event_date >= DATE '2025-01-01' AND event_date < DATE '2026-01-01'` or `WHERE year(event_date) = 2025`). Not a defect for THIS question (which was about percentile direction, not date filtering), and does not affect the percentile math; flagged only so the date-range canonical is on the next-iter probe radar if it persists.

### Q2 — Churn risk: single-pass vs subquery-join — **5.0**

Engineer asked: accounts active in the 30-90d-ago window but ZERO in the last 30d; two subqueries+join or single-pass?

Responder gave BOTH forms:
- **Single-pass conditional aggregation** — bucket events into `recent_30d` and `window_30_90d` via CASE on `event_date`, `GROUP BY account_id`, `HAVING MAX(window_30_90d)=1 AND MAX(recent_30d)=0`.
- **Two-subquery LEFT JOIN anti-join** — `(SELECT DISTINCT account_id FROM events WHERE event_date BETWEEN now()-90d AND now()-30d)` LEFT JOIN `(SELECT DISTINCT account_id FROM events WHERE event_date >= now()-30d)`, `WHERE recent.account_id IS NULL`.

Both forms verified valid Trino 467. Single-pass scans the events table ONCE and is generally cheaper at scale; the anti-join form is more readable and is the natural shape when the two cohorts come from DIFFERENT tables. Responder correctly framed the choice rather than picking one dogmatically.

The single-pass `MAX(CASE WHEN cond THEN 1 ELSE 0 END)` is a canonical Trino conditional-aggregation form (equivalent to `bool_or` semantically; the `MAX`-over-0/1 form is familiar from the Postgres/MySQL playbook and matches what the engineer's mental model expects). `HAVING MAX(recent_30d) = 0` correctly enforces "no row in last 30d"; `HAVING MAX(window_30_90d) = 1` correctly enforces "at least one row in 30-90d window".

The LEFT JOIN anti-join with `WHERE recent IS NULL` is the standard set-difference shape. Both `DISTINCT` subqueries are needed because the cohorts are per-account, not per-event.

### Q3 — `bool_and` for "every row in group satisfies a boolean" — **5.0**

Engineer's current form: `COUNT(CASE WHEN completed THEN 1 END) = COUNT(*)`. Asked for a built-in aggregate.

Responder produced:
```sql
SELECT account_id, bool_and(completed = TRUE) AS all_users_completed
FROM onboarding
GROUP BY account_id;
```
With NULL caveat: "bool_and ignores NULLs; all-NULL group returns NULL (NOT FALSE); to make NULL count as not-completed use `bool_and(COALESCE(completed, FALSE))`".

**Verification.** [trino.io/docs/current/functions/aggregate.html](https://trino.io/docs/current/functions/aggregate.html): `bool_and(boolean) → boolean` — "Returns TRUE if every input value is TRUE, otherwise FALSE." `bool_and` is NOT in the documented count()/count_if()/max_by()/min_by()/approx_distinct() NULL-counting exception list, so it ignores NULLs per the page-level rule. All-NULL or empty group → NULL. The `COALESCE(...,FALSE)` guard correctly forces NULL rows to count as not-TRUE → if any row is non-completed (or NULL → coerced FALSE) the group result is FALSE. Matches r07 §1332-1372 + r23 §3.1 `bool_or`/`bool_and` canonical exactly.

**Positive durability signal.** In iter1123 Q3 the responder gave the count_if=COUNT(*) form instead of `bool_and`, indicating a findability gap on the "every-row-in-group satisfies X" canonical at that time. iter1137 Q3 reaches `bool_and` directly with the right NULL guard — the existing r07 §1332+ canonical is sticky on this phrasing and the iter1123 miss has not recurred. The "every-row satisfies X → `bool_and`" mapping is now durable across at least 14 iters.

### Q4 — Perf regression triage (3-4s → 60s timeout, SQL unchanged) — **5.0**

Responder produced the ordered triage from r18:
1. **Cluster saturation / concurrency** — check Trino UI queued count + concurrent query load (Check 1 in r18).
2. **Partition pruning broke** — `EXPLAIN (TYPE DISTRIBUTED)`; look for a `Filter` node ABOVE `TableScan` instead of a constraint INSIDE the TableScan; the predicate is usually a partition column wrapped in **`LOWER()` / non-invertible `CAST` / UDF the optimizer can't invert**; fix by comparing the bare column (Check 3 in r18).
3. **Small-files accumulation** — `Scheduled time >> CPU time`; fix with `ALTER TABLE … EXECUTE optimize` (Step 7 in r18).
4. **Join / GROUP BY skew** — `EXPLAIN ANALYZE` per-fragment timing; one driver doing all the work (Step 5 in r18).
5. **Stale stats** — run `ANALYZE` (no `TABLE` keyword) per r24.

**Critical verification — r18 partition-pruning iter1098 FIX-A NOT regressed.** Responder attributed the pruning break to **opaque non-invertible wraps: `LOWER()` / `CAST` / `UDF`** — explicitly framed as "the optimizer can't invert". This matches the iter1098 r18 FIX-A framing. The responder did NOT say "any function on a partition column breaks pruning" and did NOT name `date()`, `CAST AS DATE`, `date_trunc('day', …)`, `year()`, or `EXTRACT(YEAR, …)` as pruning-killers — all of which Trino 467 auto-unwraps via the default-on `UnwrapCastInComparison` / `UnwrapDateTruncInComparison` / `UnwrapYearInComparison` rules (verified `UnwrapCastInComparison.java`@467; carried memory pin "Trino Unwraps Temporal Predicates"). The iter870 imported-sargability prior ("function-on-column = full scan") did NOT resurface.

The mention of `CAST` is correctly qualified with "the optimizer can't invert" — not a blanket claim. A non-invertible CAST (e.g., `CAST(tenant_id AS INTEGER)` on a VARCHAR partition column when not all rows are numeric) genuinely is opaque; an invertible CAST (`CAST(occurred_at AS DATE)`) gets unwrapped. The framing reads correctly.

`EXECUTE optimize` is the correct Trino 467 spell (NOT the Spark `CALL iceberg.system.rewrite_data_files` form — verified r18 DO-NOT-WRITE block). `ANALYZE` is the bare form, NOT `ANALYZE TABLE`.

---

## Source-verified defects this iter

**ZERO.** No fabrications, no parse errors, no dialect imports, no folklore reintroductions. The Q4 pruning attribution correctly distinguishes opaque (LOWER / non-invertible CAST / UDF) from auto-unwrapped (temporal date() / CAST AS DATE / date_trunc / year() / EXTRACT).

No recurrence of any tracked watch stream (`::` / QUALIFY / false-semi-join / fabricated-fn / regex-backslash / INTERVAL-quarter-week / OFFSET-before-LIMIT / CAST-truncate / EXECUTE-rollback-on-467 / Spark-Oracle-spillover / imported-prior / GREATEST-NULL-Postgres / array_sum / `->`/`->>`-JSON / DATEDIFF-dialect-import / multi-arg-COUNT-DISTINCT / ts-minus-ts / over-warning / multi-clause-ADD-COLUMN / contains_sequence-array_position-arithmetic / partition-column-COUNT-data-file-folklore / population-vs-per-group-percentile / dedup-tied-tuple / SELECT-*-EXCEPT / `CAST(md5 AS VARCHAR)`-mis-hex / `{% if execute %}` / `$snapshots`-CROSS-JOIN-LATERAL / **percent_rank-DESC-direction**).

---

## Watch verdicts

- **percent_rank-DESC-direction WATCH (opened iter1135 Q2, escalated iter1136 Q1 → LIGHT FIX-A r07 §3939): CLOSED on first re-probe.** Responder produced `cume_dist() OVER (ORDER BY action_count ASC)` with explicit ASC-not-DESC rationale on a third novel customer-facing percentile-message phrasing ("Year-in-Review more active than X% of users"). The keyword-magnetic LEAD card pulls correctly; the inline DO-NOT-WRITE defang of `ORDER BY metric DESC` was not exhibited.
- **iter1098 r18 temporal-unwrap stability (auto-unwrap of date() / CAST AS DATE / date_trunc / year() / EXTRACT): HOLDING.** Responder's Q4 pruning attribution correctly limits the "wrap breaks pruning" claim to opaque non-invertible wraps (LOWER / CAST / UDF) and did not name the temporal forms.
- **`bool_and` "every row satisfies X" canonical durability (iter1123 Q3 was a miss): HOLDING.** Q3 reached `bool_and(boolean)` + NULL caveat + COALESCE guard on the first new direct re-probe of this canonical in 14 iters.

No new watch streams opened.

---

## Topic-row updates

- **Analytical query patterns on Iceberg+Trino** (Q1 percentile-message): 4.4509/88 → (4.4509 × 88 + 5.0)/89 = (391.6792 + 5.0)/89 = **4.4571/89 PASSED** (+0.0062, margin +0.9571).
- **SQL best practices for OLAP** (Q2 single-pass conditional aggregation + Q3 `bool_and` canonical): 4.5563/198 → (4.5563 × 198 + 5.0 + 5.0)/200 = (902.1474 + 10.0)/200 = **4.5607/200 PASSED** (+0.0044, margin +1.0607).
- **Query performance regression diagnosis** (Q4 r18 triage): 4.3108/20 → (4.3108 × 20 + 5.0)/21 = (86.216 + 5.0)/21 = **4.3436/21 PASSED** (+0.0328, margin +0.8436).

All required topics REMAIN PASSED.

---

## Thinnest-margin order after iter1137

| Rank | Topic | Avg/N | Margin above 3.5 |
|---|---|---|---|
| 1 | Storage tiering on Trino+Iceberg+MinIO | 4.0739/11 | +0.5739 (thinnest, untouched) |
| 2 | dbt snapshots SCD2 | 4.1526/16 | +0.6526 (untouched) |
| 3 | Query performance basics | 4.1771/23 | +0.6771 (untouched) |
| 4 | Cost considerations | 4.3074/23 | +0.8074 (untouched) |
| 5 | Query-perf-regression diagnosis | 4.3436/21 | +0.8436 (Q4 lift) |
| 6 | Oracle PL/SQL → dbt+Trino migration | 4.4561/115 | +0.9561 (untouched) |
| 7 | Analytical query patterns on Iceberg+Trino | 4.4571/89 | +0.9571 (Q1 lift) |
| 8 | Iceberg table maintenance | 4.4800/179 | +0.9800 (untouched) |
| 9 | Trino federation / cross-source connectors | 4.5024/312 | +1.0024 (untouched, fragile-PASS preserved) |
| 10 | SQL best practices for OLAP | 4.5607/200 | +1.0607 (Q2+Q3 lift) |
| 11 | Trino CBO / ANALYZE / Puffin / NDV / join ordering | 4.6105/22 | +1.1105 (untouched) |
| 12 | Improving complex SQL perf on Trino with dbt | 4.6111/25 | +1.1111 (untouched) |

---

## RECOMMENDATION = **NO-OP** (commit rubric + feedback only)

No resource edits. The iter1136 LIGHT FIX-A landed and reached cleanly on the first re-probe with novel "Year-in-Review more active than X%" phrasing — the keyword anchors are doing their job. Three other answers are clean canonical reaches with positive durability signals (Q3 `bool_and` recovering the iter1123 miss; Q4 r18 triage not regressing the iter1098 temporal-unwrap fix).

### Re-probe queue (next iters)

1. **Storage-tiering 12th angle** (thinnest required-topic, untouched in 4 iters; pure tiering-keyword phrasing without MV hint to confirm the iter1134 cross-ref reach is sticky).
2. **dbt-snapshots SCD2 17th angle** (2nd thinnest required-topic, untouched).
3. **2nd-instance generative sustainment re-probe for percent_rank-DESC-direction** — slightly different phrasing ("leaderboard widget — show 'you're in the top X% of users by points'") to confirm the iter1136 FIX-A holds across more wording variants.
4. **`bool_and` 3rd-angle re-probe** (per-account compliance check: "every order in the account has a non-null shipping_address") to confirm the iter1123 → iter1137 durability is stable.
5. **Q2 single-pass vs join framing re-probe** — different scenario shape (e.g., "tenants who logged in to feature A but never feature B") to confirm the both-forms framing is the canonical answer not just for churn-window cases.

---

## Pattern observation

**20-iter sustainment band shape:**

| Type | Iters |
|---|---|
| STRONG PASS NO-OP | 1090, 1092, 1093, 1117, 1118, 1119, 1121, 1122, 1125, 1127, 1128, 1131, 1133, 1134, **1137** |
| LIGHT FIX-A | 1091, 1116, 1124, 1129, 1132, 1136 |
| NO-OP + WATCH | 1120, 1123, 1126, 1130, 1135 |

iter1137 5.0000 STRONG PASS NO-OP is the highest single-iter average in the 20-iter band (matching iter1093 4.97 / iter1133 4.9844 clean-breadth profile, marginally above). Shape is identical to iter1133's TRIPLE-watch-closure-in-one-iter profile but extends it: the iter1136 LIGHT FIX-A on r07 §3939 is the first watch-close on a customer-facing-percentile-direction defect, and it closes ALONGSIDE a positive durability signal for the iter1123 `bool_and` miss and a stability hold for the iter1098 r18 temporal-unwrap fix. Three independent watch/canonical signals confirm in one iter.

The Q1 watch-close validates the iter1135 first-instance NO-OP+WATCH discipline once again — seven consecutive watch streams have now followed the pattern (first instance = NO-OP+WATCH, second instance = escalate to LIGHT FIX-A, next instance after FIX-A = closed): ADD-COLUMN (iter1121), partition-COUNT-folklore (iter1125), population-percentile (iter1127), dedup-tied-tuple (iter1130), SELECT-*-EXCEPT (iter1131), `{% if execute %}` (iter1133), and now percent_rank-DESC-direction (iter1137). The discipline is producing consistent low-cost surgical edits without resource-content churn.

No content-lineage erosion; no recurring defect class re-opened; no new watch streams opened; no new resource defects.
