# Iter1118 — Judge Feedback

**Overall verdict: 5.00 STRONG PASS (NO-OP)** (margin +1.50 above 3.5). **iter1116 Q1 ts-minus-ts slip MULTI-STEP RE-PROBE — CLEARS FULLY.** Q1 (longest streak of consecutive login days, multi-step gaps-and-islands — the EXACT shape iter1116 originally slipped on, with the gap test buried inside a window/streak layer rather than as a clean duration) was answered with `date_diff('day', LAG(login_date) OVER (...), login_date) = 1` — NOT `(login_date - LAG(login_date))`. The slip did NOT recur in the multi-step shape. Combined with iter1117's clean-duration clear, the ts-minus-ts WATCH is fully CLOSED across both shapes. Q2/Q3/Q4 also 5.00 / 5.00 / 5.00 — clean sweep across the iter1118 breadth probes (window grand-total, prefix/suffix-LIKE-vs-functions fabrication trap, Iceberg merge-on-read DELETE + 3-step reclaim sequence).

---

## Source verifications (Trino 467 docs / RAW 467 source / pinned memory)

- **Q1 date_diff gap test inside window**: trino.io/docs/current/functions/datetime.html — `date_diff(unit, timestamp1, timestamp2) -> bigint` "Returns timestamp2 - timestamp1 expressed in terms of unit". For DATE inputs (login_date), `date_diff('day', earlier_date, later_date)` returns whole-day count. Responder's `date_diff('day', LAG(login_date) OVER (PARTITION BY user_id ORDER BY login_date), login_date) = 1` is the canonical Trino gap-equals-1 test. Confirms ts/date - ts/date subtraction was NOT used. **Slip did not recur in the multi-step shape.**
- **Q1 "can't nest windows" / one-OVER-per-CTE**: trino.io/docs/current/sql/select.html — window functions cannot be nested as arguments of other window functions; computing `SUM(...) OVER (...)` over a column that itself is a window-function expression (the streak-id over the streak-start flag) requires materializing the inner window result first (CTE or subquery). Responder's 3-CTE skeleton (Layer 1 flag → Layer 2 cumulative SUM = streak_id → Layer 3 GROUP BY count → outer MAX-per-user) is the correct Trino-canonical gaps-and-islands form. Correct.
- **Q2 SUM() OVER () grand total + integer division**: trino.io/docs/current/functions/window.html — empty `OVER ()` window = full unbounded frame = grand total on every row. Trino INTEGER / INTEGER = INTEGER (truncates); `100.0 * x / total` promotes to DOUBLE/DECIMAL and avoids the 0-percent integer-truncation trap. PARTITION BY category for per-category share is correct. All correct.
- **Q3 starts_with exists / ends_with does NOT**: per pinned memory `reference_trino_starts_with_ends_with` (verified prior iters) — Trino 467 HAS native `starts_with(string, prefix) -> boolean` on string.html; does NOT have `ends_with` (Spark/Snowflake only — parse error in Trino). Responder's "no ends_with, use LIKE '%/export' or substr(s, -7) = '/export'" is correct.
- **Q3 substr negative index from end**: trino.io/docs/current/functions/string.html — "Positions start with 1. A negative starting position is interpreted as being relative to the end of the string." Verified via WebSearch this iter. `substr(s, -7)` returns the last 7 characters; '/export' is exactly 7 chars (slash + 'export' = 7), so `substr(url, -7) = '/export'` is a valid suffix test. Correct.
- **Q3 pushdown**: Trino's predicate pushdown handles literal-prefix patterns (`LIKE 'prefix%'` and `starts_with(col, 'prefix')`) by translating them to range predicates on supported connectors; suffix patterns (`LIKE '%/export'`) generally do NOT push down because they require full-string evaluation. Responder's "both starts_with and LIKE 'prefix%' push down" is correct for the prefix side; suffix isn't claimed to push down. Correct.
- **Q4 Iceberg DELETE merge-on-read**: trino.io/docs/current/connector/iceberg.html — Iceberg connector default `delete_mode` is `merge-on-read` (position-delete files written, data files NOT rewritten); EXPLAIN scans the SAME number of data files until OPTIMIZE physically rewrites them applying the deletes. Responder's "metadata-only / position-delete markers / EXPLAIN scans same data files" is correct.
- **Q4 EXECUTE optimize / expire_snapshots / remove_orphan_files all valid in 467**: trino.io/docs/current/connector/iceberg.html — all three are documented Trino 467 Iceberg EXECUTE table procedures (NOT Spark-only). `ALTER TABLE x EXECUTE optimize(file_size_threshold => '256MB')` rewrites small files AND applies position-delete files (this is what physically frees space); `ALTER TABLE x EXECUTE expire_snapshots(retention_threshold => '7d')` drops old snapshots so older data/manifest files are no longer referenced; `ALTER TABLE x EXECUTE remove_orphan_files(retention_threshold => '7d')` removes files in the table directory not linked by any snapshot. Order optimize → expire_snapshots → remove_orphan_files is canonical. Verified `remove_orphan_files` is native to Trino 467 (NOT Spark-only) via WebSearch this iter.
- **Q4 7d min-retention floor**: trino.io/docs/current/connector/iceberg.html — `iceberg.expire-snapshots.min-retention` default `7d`; `iceberg.remove-orphan-files.min-retention` default `7d`; passing a shorter threshold throws "Retention specified (Xd) is shorter than the minimum retention configured in the system (7.00d)". Responder's 7-day floor + config name is correct.

---

## Q1 multi-step recurrence verdict — CLEARS FULLY (WATCH CLOSED)

iter1116 originally slipped: when the engineer asked a multi-step sessionization question (gap test buried inside a window/streak layer), responder wrote a ts-minus-ts subtraction for the gap test instead of `date_diff('day', LAG, cur)`. iter1117 cleared the clean-duration shape (`date_diff('minute', created_at, first_response_at)` — explicit duration question) but did NOT re-test the multi-step shape where the slip originally occurred. **iter1118 Q1 specifically reconstructed the multi-step shape** (longest streak of consecutive login days, gap test on `LAG(login_date)` inside a 3-CTE gaps-and-islands skeleton) — responder used `date_diff('day', LAG(login_date) OVER (PARTITION BY user_id ORDER BY login_date), login_date) = 1`, NOT `(login_date - LAG(login_date)) = 1`. **The slip did NOT recur in the original multi-step shape. WATCH fully CLOSED across both clean-duration and multi-step shapes.**

---

## Per-question scores

### Q1 — longest streak of consecutive login days per user (multi-step gaps-and-islands)
- Accuracy: 5 — canonical 3-CTE gaps-and-islands, `date_diff('day', LAG, cur) = 1` gap test (NOT ts-ts), correct streak-id via cumulative SUM, correct "can't nest windows" / one-OVER-per-CTE materialization rule
- Completeness: 5 — Layer 1 flag → Layer 2 streak_id → Layer 3 count + outer MAX-per-user, plus nesting warning
- Clarity: 5 — explicit layer-by-layer naming, clear semantics
- Actionability: 5 — copyable 3-CTE skeleton, plug in table/columns
- Avg: **5.00**

### Q2 — each customer's share of total revenue (one query)
- Accuracy: 5 — `SUM(revenue) OVER ()` empty window = grand total; `100.0 * revenue / SUM(revenue) OVER ()` correct percent; `100.0` literal forces non-integer arithmetic
- Completeness: 5 — covers the canonical empty-OVER pattern, the integer-division trap, PARTITION BY category variant
- Clarity: 5 — explicit "empty OVER() = grand total on every row" framing
- Actionability: 5 — copy-paste ready
- Avg: **5.00**

### Q3 — URL paths starting with '/api/' OR ending with '/export' (prefix/suffix funcs in Trino vs LIKE)
- Accuracy: 5 — correctly states `starts_with` exists in Trino 467, `ends_with` does NOT (Spark/Snowflake only — would parse error); `LIKE '%/export'` works; `substr(s, -7) = '/export'` works (negative index from end, '/export' is 7 chars); both `starts_with` and `LIKE 'prefix%'` push down. Fabrication trap correctly identified
- Completeness: 5 — covers both prefix and suffix paths, the function-existence fabrication trap, the pushdown angle
- Clarity: 5 — clean "exists / does not exist" framing, no ambiguity
- Actionability: 5 — engineer has 2 working suffix forms + 1 working prefix form
- Avg: **5.00**

### Q4 — Iceberg DELETE doesn't shrink scan in EXPLAIN; did delete remove anything; how to reclaim
- Accuracy: 5 — merge-on-read DELETE writes position-delete files, data files NOT rewritten, EXPLAIN scans same data files until OPTIMIZE; optimize → expire_snapshots → remove_orphan_files all valid Trino 467 EXECUTE procedures (native, not Spark-only); 7-day min-retention floor on both expire_snapshots and remove_orphan_files
- Completeness: 5 — explains WHY EXPLAIN is unchanged + WHAT the DELETE actually did + 3-step reclaim sequence + retention floor + config knob
- Clarity: 5 — clear Step 1 / Step 2 / Step 3 structure with one-sentence rationale per step
- Actionability: 5 — three ready-to-run EXECUTE statements in correct order
- Avg: **5.00**

---

## Score table

| Q | Topic | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|---|
| Q1 | gaps-and-islands streak, multi-step date_diff gap test | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | SUM() OVER () grand-total window for share | 5 | 5 | 5 | 5 | 5.00 |
| Q3 | starts_with exists / ends_with absent; substr negative index | 5 | 5 | 5 | 5 | 5.00 |
| Q4 | Iceberg merge-on-read DELETE + optimize/expire/orphan reclaim | 5 | 5 | 5 | 5 | 5.00 |

**Iter avg: 5.00 — STRONG PASS** (margin +1.50 above 3.5; +0.08 above iter1117 4.92; clean sweep).

---

## Source-verified defects

**None.** Q1 multi-step gap test = `date_diff('day', LAG, cur) = 1` (correct), Q2 SUM() OVER () + 100.0 guard (correct), Q3 starts_with-yes / ends_with-no + substr(-7) (correct), Q4 merge-on-read + 3-step reclaim + 7d floor (all correct). No factual errors, no fabrications, no broken alternatives.

---

## Teacher guidance — NO-OP RECOMMENDED

**Do not modify any resource files this iter.** Five consecutive clean iters now (1090, 1092, 1093, 1117, 1118 all ≥ 4.9, mixed with 1091/1116 light FIX-A iters that are confirmed reaching). The multi-step ts-ts watch is closed across both shapes; no other recurring slips in flight; resources are stable.

**Risk surface to keep watching (low-priority probes, not fixes):**
- Synthesis ceiling — the gaps-and-islands skeleton answered cleanly here on a familiar (login-days) domain; the iter951-956 ceiling was domain-novel + always-zero PRE-FILTER combined. Re-probe on a fresh streak domain (consecutive monthly active months / consecutive-shift attendance) at a future breadth iter to confirm the skeleton transfers
- Responder over-warning folklore (memory pin `feedback_responder_overwarning_folklore`) — none surfaced this iter; periodic breadth probes of "is correlated subquery actually slow / is plain IN with NULL actually broken" still warranted
- Responder broken secondary alternative (memory pin `feedback_responder_broken_secondary_alternative`) — none surfaced this iter; per-instance one-off, not a resource fix

**No FIX-A, no FIX-B, no card additions. Hold the line.**
