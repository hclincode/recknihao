# Iter1143 Judge Feedback

**Verdict: 4.594 PASS + LIGHT FIX-A — Q1 EXPOSES A THIRD-SURFACE INTERVAL-QUALIFIER BLIND SPOT. The rolling-4-week revenue answer is architecturally right (per-(account,week) pre-aggregation + window with RANGE frame) but writes `RANGE BETWEEN INTERVAL '3' WEEK PRECEDING AND CURRENT ROW` — `INTERVAL '3' WEEK` is a PARSE ERROR in Trino 467 (qualifier grammar = YEAR/MONTH/DAY/HOUR/MINUTE/SECOND ONLY). The r07 §3543 INTERVAL-qualifier defang already names WEEK/QUARTER as parse errors, but its examples are scoped to the date-arithmetic surface (`some_date + INTERVAL '1' WEEK`) and the TWO-SURFACES warning only contrasts INTERVAL literal vs unit-string (date_trunc/date_add/date_diff). The third surface — window-frame `RANGE BETWEEN INTERVAL …` — is not explicitly covered, and r07 even has multiple `RANGE BETWEEN INTERVAL '6' DAY PRECEDING` exemplars (legitimately valid because DAY IS a qualifier) that the responder over-generalized to WEEK. Q2/Q3/Q4 clean. Recommend LIGHT FIX-A: extend r07 §3543 defang block + add a window-frame-specific row to the DO-NOT-WRITE table + add the `RANGE BETWEEN INTERVAL '21' DAY PRECEDING` (3 weeks via DAY) canonical to the rolling-window section.**

---

## Score table

| Q | Topic | Acc | Clar | App | Compl | Avg |
|---|---|---:|---:|---:|---:|---:|
| Q1 | Analytical query patterns — rolling 4-week revenue per account (RANGE-frame INTERVAL WEEK parse error) | 3.0 | 4.5 | 3.0 | 4.0 | **3.625** |
| Q2 | SQL best practices — SIGN + `%` modulo for sign-bucket + leftover-units | 5.0 | 5.0 | 5.0 | 4.5 | **4.875** |
| Q3 | Iceberg maintenance — query `$files` metadata to inspect file count/sizes for compaction decision | 5.0 | 5.0 | 5.0 | 4.5 | **4.875** |
| Q4 | SQL best practices — BETWEEN inclusive midnight upper bound undercounts last day; half-open `>= start AND < next-day` fix | 5.0 | 5.0 | 5.0 | 5.0 | **5.000** |

**Iter average: (3.625 + 4.875 + 4.875 + 5.000) / 4 = 18.375 / 4 = 4.594 PASS**

Margin above 3.5 threshold: **+1.094** (well above the bar — Q1 is a single-quarter parse-error miss not a topic-level concern).

Per the standard rubric (overall average governs, NO per-question veto), the iteration passes even with Q1 = 3.625.

---

## Per-question analysis

### Q1 (3.625) — rolling 4-week revenue per account (current week + 3 prior weeks); single query?

**Responder answer (paraphrased)**: window over a per-(account, week) pre-aggregation —
```sql
SELECT account_id,
       week_start,
       SUM(weekly_revenue) OVER (
         PARTITION BY account_id
         ORDER BY week_start
         RANGE BETWEEN INTERVAL '3' WEEK PRECEDING AND CURRENT ROW
       ) AS rolling_4_week_revenue
FROM (
  SELECT account_id,
         date_trunc('week', transaction_date) AS week_start,
         SUM(revenue) AS weekly_revenue
  FROM ...
  GROUP BY account_id, date_trunc('week', transaction_date)
)
```

**THE DEFECT — `INTERVAL '3' WEEK` IS A PARSE ERROR IN TRINO 467.** Verified against:
- Trino 467 grammar `core/trino-grammar/src/main/antlr4/io/trino/grammar/sql/SqlBase.g4` — rule `intervalField : YEAR | MONTH | DAY | HOUR | MINUTE | SECOND ;` (exactly six qualifiers, no `WEEK`, no `QUARTER`).
- [trinodb/trino#17357 — "Support week in interval literals"](https://github.com/trinodb/trino/issues/17357) — open feature request explicitly stating `select interval '1' week` is NOT supported; "this is not part of the SQL specification" (it IS in PostgreSQL, MySQL, Calcite, SparkSQL, BigQuery, Snowflake — Trino is the outlier).
- Pinned reference memory: "Trino INTERVAL Qualifiers — Trino 467 INTERVAL literals support ONLY YEAR/MONTH/DAY/HOUR/MINUTE/SECOND … INTERVAL '1' QUARTER + INTERVAL '1' WEEK are PARSE errors".

Running the responder's SQL produces `mismatched input 'WEEK'. Expecting: 'DAY', 'HOUR', 'MINUTE', 'MONTH', 'SECOND', 'YEAR'`. The engineer copy-pastes and the query never runs.

**Architecture IS correct (don't over-penalize):**
- Per-(account, week) pre-aggregation in a CTE — correct (so the window's "row" is a week, not a transaction).
- `date_trunc('week', transaction_date)` — correct (Monday-aligned ISO week; `week` IS a valid `date_trunc` unit string — the very TWO-SURFACES distinction r07 §3562 warns about).
- `PARTITION BY account_id ORDER BY week_start` — correct.
- Using a **RANGE** frame instead of ROWS — correct intent for gap-safety. A value-based frame on `week_start` correctly handles weeks where some account had zero revenue (no row), whereas `ROWS BETWEEN 3 PRECEDING` would reach back across calendar weeks if rows are missing.

**The fix is at the dialect-token level. Two correct options:**

```sql
-- (A) Value-based RANGE on DAY (preferred — gap-safe, calendar-exact, 3 weeks = 21 days):
RANGE BETWEEN INTERVAL '21' DAY PRECEDING AND CURRENT ROW

-- (B) Positional ROWS frame (works ONLY if you've densified the pre-aggregation to one row
--     per (account, week) for EVERY week the account exists, including zero-revenue weeks):
ROWS BETWEEN 3 PRECEDING AND CURRENT ROW
```

The (B) form would silently include weeks further back than 4 calendar weeks for any account that has a gap week — a real risk on sparse-traffic accounts. The (A) value-based form is what the responder INTENDED and is gap-safe. The responder did NOT call out the gap-safety reasoning, so the difference between (A) and (B) is not in the answer — a completeness shave on top of the parse error.

**Resource defang status — r07 §3543 already names this exact parse error, but for a DIFFERENT surface:**

The existing `r07 §3543 — ADD-A-QUARTER / ADD-A-WEEK` block (added iter933 LIGHT FIX-A) reads:
> Trino 467 INTERVAL literals accept **only 6 qualifiers**: YEAR, MONTH, DAY, HOUR, MINUTE, SECOND … There is **no QUARTER and no WEEK interval qualifier** — writing `+ INTERVAL '1' QUARTER` or `+ INTERVAL '1' WEEK` fails to parse with `mismatched input 'QUARTER'` (resp. `'WEEK'`).

Its DO-NOT-WRITE row only shows the date-arithmetic surface (`some_date + INTERVAL '1' WEEK`) and the THIS-QUARTER half-open range. The TWO-SURFACES paragraph immediately below contrasts INTERVAL LITERAL surface vs UNIT-STRING surface (`date_trunc('week', x)` / `date_add('week', n, x)` / `date_diff('week', a, b)` all valid).

**The third surface — window-frame `RANGE BETWEEN INTERVAL … PRECEDING / FOLLOWING` — uses the SAME INTERVAL-literal grammar and is therefore SAME-LAW restricted, but the resource never explicitly names this surface.** Worse, r07 §1233 / §2599 / §4748 / §4767 have multiple valid `RANGE BETWEEN INTERVAL '6' DAY PRECEDING AND CURRENT ROW` exemplars (legitimately valid because `DAY` IS a qualifier) — the responder pattern-matched these as "weeks should work the same way".

This is RESOURCE-SOURCED FINDABILITY — the warning exists but is anchored to a different surface, so on a window-frame question the keyword-magnet for "rolling 4 weeks + RANGE frame" pulls the responder toward the §4748 daily-rolling-window canonical (which uses `DAY`) and then it cargo-cults `WEEK` in.

**LIGHT FIX-A recommended (additive, in-place reconcile):**

1. **Extend the r07 §3543 DO-NOT-WRITE table** with a new row:

   | DO NOT write | Why it's wrong | Use instead |
   |---|---|---|
   | `RANGE BETWEEN INTERVAL '3' WEEK PRECEDING AND CURRENT ROW` (or `INTERVAL '1' QUARTER PRECEDING`) in a **window frame** | Same parse error as the date-arithmetic surface — the window-frame `RANGE BETWEEN INTERVAL …` clause uses the SAME INTERVAL-literal grammar, so `WEEK` / `QUARTER` qualifiers fail with `mismatched input 'WEEK'`. | `RANGE BETWEEN INTERVAL '21' DAY PRECEDING AND CURRENT ROW` (3 weeks = 21 days), OR `ROWS BETWEEN 3 PRECEDING AND CURRENT ROW` if the CTE has exactly one row per week (gap-densified). |

2. **Add a sentence to the TWO-SURFACES paragraph** naming the THREE surfaces (the resource currently says "TWO"):
   > **THREE-SURFACES rule.** The qualifier restriction applies in **(a) interval literals in date arithmetic** (`d + INTERVAL '7' DAY`), **(b) interval literals in window frames** (`RANGE BETWEEN INTERVAL '21' DAY PRECEDING`), and **(c) interval literals anywhere else they appear** (`WHERE ts > current_timestamp - INTERVAL '1' HOUR`). The same six qualifiers apply to ALL THREE. By contrast, `week` / `quarter` ARE valid as the FIRST ARGUMENT (unit-string) to `date_trunc` / `date_add` / `date_diff` — that's a totally different surface where the unit list is broader (`'second'`, `'minute'`, `'hour'`, `'day'`, `'week'`, `'month'`, `'quarter'`, `'year'`).

3. **Add a rolling-4-week-revenue canonical** to the rolling-window section (somewhere near §4748 daily-DAU canonical), keyword-anchored on "rolling 4 week revenue", "trailing 4 weeks", "current week plus 3 prior weeks", "4 week rolling sum", "rolling weekly aggregate":
   ```sql
   -- Rolling 4-week revenue per account (current week + 3 prior calendar weeks).
   -- Pre-aggregate to one row per (account, week), then RANGE-frame on DAY (3 weeks = 21 days).
   WITH weekly AS (
     SELECT account_id,
            date_trunc('week', transaction_date) AS week_start,
            SUM(revenue) AS weekly_revenue
     FROM iceberg.analytics.transactions
     GROUP BY account_id, date_trunc('week', transaction_date)
   )
   SELECT account_id, week_start,
          SUM(weekly_revenue) OVER (
            PARTITION BY account_id
            ORDER BY week_start
            RANGE BETWEEN INTERVAL '21' DAY PRECEDING AND CURRENT ROW
          ) AS rolling_4_week_revenue
   FROM weekly;
   ```
   Pair with a brief "WHY DAY not WEEK" note pointing back to §3543.

**Classification: RESOURCE-SOURCED FINDABILITY GAP at a third surface, NOT a responder synthesis ceiling.** The exact fact (`INTERVAL '1' WEEK` fails) is in the resource at §3543; the responder didn't reach it because the context (window-frame RANGE) is different from the context the defang block sits in (date arithmetic). This is the same pattern as the iter933 root fix — additive defang at the surface the keyword path actually lands on.

**Watch label: `r07 INTERVAL-qualifier WEEK in window-frame iter1143`.** Re-probe next sweep with a quarterly variant ("rolling 4 quarter revenue") AND a calendar-aware monthly variant to confirm both extension surfaces are covered, not just weekly.

**Scoring justification:**
- **Acc 3.0** — Architecture correct, but the load-bearing token (`INTERVAL '3' WEEK`) is a parse error. Copy-pasted SQL fails at planning. Not a silent-wrong but a hard-stop wrong.
- **Clar 4.5** — Explanation is clear and well-structured; minor shave for not explaining gap-safety reasoning behind RANGE vs ROWS.
- **App 3.0** — Engineer hits a parse error on first run, has to figure out the qualifier-grammar issue themselves (likely from a Stack Overflow search). The architecture is recoverable but the answer doesn't get them to a working query.
- **Compl 4.0** — Pre-aggregation step, window function, RANGE frame, week truncation all addressed; gap-safety reasoning not addressed; no fallback if INTERVAL '3' WEEK fails (no defensive alternative offered).

---

### Q2 (4.875) — balance sign positive/negative/zero + leftover units after dividing by 30; built-ins or CASE?

**Responder answer (CORRECT)**:
- `SIGN(balance)` — returns `-1` for negative, `0` for zero, `+1` for positive. Direct built-in.
- `balance % 30` — leftover units (modulo). Built-in operator.
- No CASE needed for either.

Verified at [trino.io/docs/current/functions/math.html](https://trino.io/docs/current/functions/math.html):
- `sign(x)` — "Returns the signum function of `x`, that is: 0 if the argument is 0, 1 if the argument is greater than 0, -1 if the argument is less than 0."
- `mod(n, m)` — modulo function; the `%` operator is the infix form of the same operation.

Cross-referenced at r27 §1259-1260 (Oracle PL/SQL → Trino translation table): `MOD(a, b)` → `mod(a, b)` or `a % b` (identical), `SIGN(n)` → `sign(n)` (identical, all-lowercase in Trino).

**Both pieces are exactly right.** The "no CASE needed" framing is the load-bearing answer to the question — engineer was asking whether to roll their own CASE expression, and the responder correctly says no, two direct primitives.

**Minor completeness shave (-0.5 on Compl):** the responder did not mention the `mod(n, m)` function form alongside the `%` operator. Both are valid and both appear in the Trino docs. For an engineer porting from a dialect where `MOD()` is the only form (Oracle, some ANSI environments), naming both reduces "is this Trino-specific" friction. Not a defect — the question phrasing called for "leftover units after dividing by 30" and `%` is the canonical form — but a fully complete answer would list both.

**Recommendation: NO-OP.** Topic durability sustained.

---

### Q3 (4.875) — how many files, sizes, is compaction working, query the table or poke S3?

**Responder answer (CORRECT)**:
```sql
SELECT file_path,
       file_size_in_bytes/(1024*1024) AS file_size_mb,
       record_count,
       partition
FROM iceberg.schema."table$files"
ORDER BY file_size_in_bytes DESC
```
- Whole-token `"table$files"` in ONE quote pair — correct (matches r17 §70-150 CRITICAL QUOTING RULE).
- Many tiny files (<64MB) ⇒ compaction overdue, run `ALTER TABLE ... EXECUTE optimize`.
- Also mentions `"table$snapshots"` for snapshot history.
- Answers the "query or poke S3" framing: query the table, NOT MinIO directly.

Verified against:
- r17 §70-150 — canonical quoting form `iceberg.<schema>."<table>$files"` (one quote pair around the whole token), explicitly contrasted with the broken split-quote `iceberg.schema.events."$files"` form.
- r17 §107-110 — exact column list: `file_path, file_size_in_bytes, record_count`, and `partition` columns documented.
- r13 §3066 — `content` column for distinguishing data files (0) from delete files (1/2).
- [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html) (Metadata tables section) — confirms `$files`, `$snapshots`, `$partitions`, `$manifests`, `$refs`, `$history`, `$properties` all use the same one-quote-pair form.

**The answer hits all three key elements:**
1. Use the metadata table, not S3 inspection (correct — `$files` exposes the live snapshot's file inventory; S3 ls would also return orphaned files from expired snapshots and would not show record_count).
2. Correct quoting (`"table$files"` whole-token).
3. Correct diagnostic threshold (<64MB tiny-files trigger).
4. Correct remediation (`EXECUTE optimize`).

**Minor completeness shave (-0.5 on Compl):**
- Did not mention the `content` column for filtering out delete files (`WHERE content = 0` gives ONLY data files; without it, delete files inflate the file count for MoR tables).
- Did not mention the more specific `optimize(file_size_threshold => ...)` parameter (default threshold = 100MB, raise it to force compaction of larger files).
- Did not mention pairing with `"table$partitions"` to spot per-partition skew (one partition with many tiny files vs another with a few large ones).

None of these are load-bearing for the engineer's "is compaction working" question — the primary answer gets them to the right diagnostic in one query.

**Recommendation: NO-OP.** Topic durability sustained on the metadata-table angle (passed many times; the 64MB heuristic + EXECUTE optimize framing is well-pinned).

---

### Q4 (5.000) — BETWEEN inclusive but `BETWEEN TIMESTAMP '2024-03-01 00:00:00' AND TIMESTAMP '2024-03-31 00:00:00'` undercounts March

**Responder answer (CORRECT)**:
- BETWEEN IS inclusive on BOTH ends — that's not the bug.
- The upper bound is March 31 at **midnight** (00:00:00), so it includes only that one instant of March 31 and excludes the rest of the day (everything after 00:00:01 through 23:59:59).
- Fix: half-open range `occurred_at >= TIMESTAMP '2024-03-01 00:00:00' AND occurred_at < TIMESTAMP '2024-04-01 00:00:00'`.
- Additional note: half-open ranges prune partitions better.

Verified against:
- [trino.io/docs/current/functions/comparison.html](https://trino.io/docs/current/functions/comparison.html) — `BETWEEN AND` is inclusive: "`x BETWEEN min AND max` is equivalent to `x >= min AND x <= max`".
- Standard half-open `[start, next-start)` convention is the OLAP canonical (avoids end-of-day-23:59:59.999 traps, handles fractional-second timestamps cleanly, partition-prunes equivalently to bare-column form).

**The answer correctly identifies the user's misconception** (engineer thought BETWEEN was somehow exclusive on the upper bound) AND gives the correct mental model (it IS inclusive — that's exactly why writing midnight excludes the rest of the day).

The partition-pruning bonus note is well-placed — half-open is what `date_trunc` boundaries naturally produce, what r07 / r23 partition-pruning canonicals consistently use, and what Iceberg hidden-partition transforms unwrap cleanly.

Clean 5.0 across all dimensions. **Recommendation: NO-OP.**

---

## Source-verified defects this iteration

| Q | Defect | Status | Citation |
|---|---|---|---|
| Q1 | `RANGE BETWEEN INTERVAL '3' WEEK PRECEDING AND CURRENT ROW` parse error | CONFIRMED | Trino 467 `SqlBase.g4` `intervalField : YEAR \| MONTH \| DAY \| HOUR \| MINUTE \| SECOND ;` + [trinodb/trino#17357](https://github.com/trinodb/trino/issues/17357) + pinned reference memory `reference_trino_interval_qualifiers.md` |
| Q2 | None | CLEAN | sign + `%` verified at [trino.io/docs/current/functions/math.html](https://trino.io/docs/current/functions/math.html) |
| Q3 | None | CLEAN | $files schema + one-quote-pair form verified at [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html) |
| Q4 | None | CLEAN | BETWEEN inclusive verified at [trino.io/docs/current/functions/comparison.html](https://trino.io/docs/current/functions/comparison.html) |

---

## Q1 INTERVAL-qualifier classification

**RESOURCE-SOURCED FINDABILITY GAP at a third surface — NOT a responder synthesis ceiling.**

- The fact is in r07 §3543 (added iter933 LIGHT FIX-A).
- The fact is scoped to date-arithmetic surface (`d + INTERVAL '1' WEEK`).
- The TWO-SURFACES paragraph contrasts INTERVAL literal vs unit-string surfaces.
- The window-frame `RANGE BETWEEN INTERVAL …` surface is a third, unaddressed surface that uses the SAME INTERVAL-literal grammar.
- r07 has multiple valid `RANGE BETWEEN INTERVAL '6' DAY PRECEDING` exemplars (legitimately valid — DAY IS a qualifier) that pattern-match-attract the responder to extend by analogy.

This is the same shape as the iter933 root fix (additive defang at the surface the keyword path actually lands on), one surface further out.

**Recommendation: LIGHT FIX-A** (not NO-OP+WATCH) because:
1. The fix is purely additive (extend existing defang block; no rewrite/reconcile of contradictory content).
2. The defect is a clear dialect parse error, not a synthesis ceiling — the resource just needs to name the third surface explicitly.
3. The follow-up canonical (`RANGE BETWEEN INTERVAL '21' DAY PRECEDING`) is the natural fix and reinforces the existing "DAY is the universal-purpose qualifier; convert weeks/quarters into days/months" mental model.
4. Recurrence likelihood is non-trivial: rolling-N-week revenue / rolling-N-quarter revenue are extremely common SaaS analytics shapes; the same parse error will be hit again on the next variant if left as a WATCH.

---

## Teacher guidance (LIGHT FIX-A spec)

**File:** `resources/07-analytical-query-patterns.md`

**Edits (additive only, in-place reconcile of the existing §3543 block):**

1. **§3543 DO-NOT-WRITE table** — add a row for window-frame surface:
   ```
   | RANGE BETWEEN INTERVAL '3' WEEK PRECEDING (or '1' QUARTER PRECEDING) in a window frame | Same parse error as date-arithmetic — window-frame INTERVAL literals use the SAME 6-qualifier grammar | RANGE BETWEEN INTERVAL '21' DAY PRECEDING (3 weeks = 21 days), OR ROWS BETWEEN 3 PRECEDING (positional, gap-densified CTE only) |
   ```

2. **§3562 TWO-SURFACES paragraph** — rename to THREE-SURFACES and add the window-frame surface explicitly:
   > **THREE-SURFACES rule.** The qualifier restriction applies in all places where INTERVAL literals appear: (a) date arithmetic (`d + INTERVAL '7' DAY`), (b) window frames (`RANGE BETWEEN INTERVAL '21' DAY PRECEDING`), (c) standalone literal expressions (`WHERE ts > current_timestamp - INTERVAL '1' HOUR`). Same 6 qualifiers, all three surfaces. By contrast, `week` / `quarter` ARE valid unit strings for `date_trunc`/`date_add`/`date_diff` — different surface, different (broader) unit list.

3. **§4748 Pattern D rolling-window section** — add a rolling-N-week revenue canonical right next to the existing daily DAU canonical:
   - Keyword anchors: rolling 4 week revenue, trailing 4 weeks, current week plus 3 prior weeks, rolling weekly sum, week-over-week trailing window, 4-week rolling aggregate, rolling quarterly revenue.
   - SQL: pre-aggregate to one row per (account, week) in a CTE using `date_trunc('week', ...)`, then `RANGE BETWEEN INTERVAL '21' DAY PRECEDING AND CURRENT ROW` in the outer window.
   - Brief "WHY DAY not WEEK in the frame" note pointing back to §3543.
   - Brief gap-safety note: RANGE on a value column (week_start) is gap-safe; ROWS BETWEEN 3 PRECEDING requires the CTE to be densified to one row per week per account, which the GROUP BY alone does NOT produce.

**File:** `resources/23-sql-best-practices-olap.md` — NO EDIT (the defang lives in r07, that's the right home).

**Watch label:** `r07 INTERVAL-qualifier WEEK in window-frame iter1143` — re-probe next sweep with: (a) "rolling 4 quarter revenue" to confirm QUARTER extension reaches, (b) a calendar-aware monthly rolling form ("trailing 3 calendar months") to confirm DAY-as-universal-qualifier guidance generalizes.

---

## Topic impact summary

| Topic | Pre-iter avg | Q | Score | Post-iter avg | Margin | Δ |
|---|---:|---|---:|---:|---:|---:|
| Analytical query patterns on Iceberg+Trino: funnels, cohorts, time-series SQL | 4.4753/94 | Q1 | 3.625 | 4.4664/95 | +0.9664 | -0.0089 |
| SQL query best practices for OLAP | 4.5519/205 | Q2, Q4 | 4.875, 5.000 | 4.5557/207 | +1.0557 | +0.0038 |
| Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup | 4.4800/179 | Q3 | 4.875 | 4.4822/180 | +0.9822 | +0.0022 |

No topic crosses the 3.5 threshold downward. Margin on the "analytical query patterns" row shrinks slightly but remains comfortably above pass; the LIGHT FIX-A is forward-looking durability work, not a topic-level rescue.

---

## Final verdict

**4.594 PASS + LIGHT FIX-A.** Three of four answers clean; Q1 exposes a real dialect parse error sourced from a findability gap at a third INTERVAL-literal surface that the existing §3543 defang does not explicitly cover. Recommend LIGHT FIX-A (additive only, no rewrite of contradictory content) to extend the qualifier defang to the window-frame surface and add a rolling-N-week canonical. Set watch `r07 INTERVAL-qualifier WEEK in window-frame iter1143` for next-sweep re-probe on QUARTER and calendar-monthly variants.
