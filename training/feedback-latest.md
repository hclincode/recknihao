# Iteration 1245 — Judge Feedback

## Verdict

**Overall: 3.969 — PASS BUT Q1 IS A HARD RE-PROBE FAIL — the iter1244 routing FIX-A DID NOT REACH.** Per-Q scores: Q1=2.875, Q2=4.375, Q3=4.75, Q4=3.875. Average (2.875+4.375+4.75+3.875)/4 = 15.875/4 = **3.969**.

The headline finding: **iter1244's routing FIX-A (r23 §2011 4th DECIDE-FIRST router + §2098 PER-GROUP keyword extension) did NOT reroute the responder.** Responder again recommended `DENSE_RANK() <= N` for "top N rows per group including boundary ties" AND falsely claimed `RANK() <= N` "doesn't include all tied reps at position N". Same wrong shape as iter1244 Q2, despite the FIX-A landing the day before. For the engineer's exact data the output happens to coincide (only-tied-at-boundary case), but the framing + the RANK dismissal are factually wrong general rules.

Q2/Q3 clean. Q4 has a Trino-fix-correct + Oracle-premise-FALSE issue (Oracle GREATEST also returns NULL on any NULL — does NOT ignore NULLs — engineer's premise was false and responder reinforced it).

---

## Q1 — Top-N-per-group with boundary ties (RE-PROBE of iter1244 FIX-A) — **2.875 FAIL**

**Engineer's data**: 3rd and 4th sales reps both closed 47 deals within a region; ROW_NUMBER<=3 drops one of them. Wants top-3-per-region with all boundary ties included. Which ranking function?

**Responder said**: "Use `DENSE_RANK()`, not `ROW_NUMBER()` or `RANK()`." Characterization of the three:
- ROW_NUMBER 1,2,3,4 — drops ties: correct.
- **"RANK() — ties get the same rank, then the next rank skips (1,2,2,4). Still doesn't include all tied reps at position N."** — FACTUALLY WRONG.
- DENSE_RANK 1,2,2,3 "All tied reps at rank N are included" — over-generalized.
- Recommended SQL: `DENSE_RANK() OVER (PARTITION BY region ORDER BY deals_closed DESC) AS dense_rank ... WHERE dense_rank <= 3`.

**Correct (verified at [trino.io/docs/current/functions/window.html](https://trino.io/docs/current/functions/window.html))**:
- `RANK()` returns "one plus the number of rows preceding the row that are not peer with the row. Thus, tie values in the ordering will produce gaps in the sequence." For values [60, 55, 47, 47] DESC, RANK = 1, 2, 3, 3. **`RANK() <= 3` returns all 4 rows including both tied 47s.** This IS the canonical "top N rows including boundary ties" semantic — matches SQL Server's `TOP N WITH TIES` and ANSI `FETCH FIRST n ROWS WITH TIES`.
- `DENSE_RANK()` is "similar to rank(), except that tie values do not produce gaps." For [100, 95, 95, 80, 75] DESC, DENSE_RANK = 1, 2, 2, 3, 4. **`DENSE_RANK() <= N` returns top N DISTINCT VALUE-TIERS, not top N positions.** With ties ABOVE the boundary it OVER-RETURNS rows.

**The responder's "RANK() still doesn't include all tied reps at position N" claim is the inverse of reality.** For the boundary ties at position 3 (deals=[60,55,47,47] → RANK=1,2,3,3), both 47-reps get rank 3, and rank 3 ≤ 3 → both are returned. The "gap to rank 4 after the ties" only matters for the row AFTER the ties (excluded), NOT for the tied rows themselves (included).

**For the engineer's EXACT data**: Since the tie is ONLY at the 3rd-place boundary (no ties above), DENSE_RANK<=3 and RANK<=3 happen to return the same rows. So the SQL "works" for this case. But the framing teaches the wrong general rule — if a future query has ties above the boundary (e.g. two reps tied at 1st), DENSE_RANK<=3 will over-return.

### DID THE iter1244 FIX-A REACH? — **NO**

iter1244 added:
1. A 4th DECIDE-FIRST router row at **r23 §2011** distinguishing "Nth-largest DISTINCT VALUE (=N exact) → DENSE_RANK=N" vs "TOP-N ROWS range INCLUDING boundary ties (<=N) → RANK<=N / FETCH FIRST WITH TIES, NOT DENSE_RANK<=N".
2. Extended r23 §2098 (top-N-with-ties LEADING CANONICAL) keyword anchors with PER-GROUP phrasings + per-group-vs-whole-result note.

The responder still routed to the DENSE_RANK<=N answer. Worse, this iteration the responder ACTIVELY DISMISSED RANK with a false claim. Two consecutive failures on the same canonical = real defect, not recall slip.

### WHY THE FIX-A FAILED — likely root cause

The router at §2011 was added INSIDE the Nth-largest canonical section. That section's primary rule (correct for the =N exact case: "do NOT use RANK because ties produce gaps and rank=N may match zero rows for Nth-largest DISTINCT VALUE") is over-attracting and the responder is generalizing its "avoid RANK" warning into the <=N range case. Even though the router row presumably says "for <=N range use RANK", the surrounding §2011 prose (warning against RANK for the =N case) creates a stronger negative-association than the router's scoped correction. Result: responder's gestalt = "the canonical says avoid RANK here" → answers in the same shape regardless of <=N vs =N framing.

The §2098 PER-GROUP keyword extension may also not have landed because the question used "top 3 sales reps WITHIN EACH region" framing — possibly the keyword anchors added are still narrower than the engineer's phrasing reaches.

### RECOMMEND — STRENGTHEN, do not accept as ceiling

This is the SECOND consecutive iteration on the same canonical with the same wrong recommendation. The iter1244 FIX-A was targeted but not sufficient. Recommend a stronger FIX-A:

1. **At r23 §2011** (Nth-largest section) — explicitly SCOPE the "do NOT use RANK" warning to the **=N EXACT case only**, with an immediate "BUT for <=N RANGE-with-boundary-ties, **RANK IS the right tool**" boldface counterpoint INLINE in the same prose block. The current FIX-A apparently puts the router at the top but leaves the avoid-RANK prose below; engineers/responder read the prose. Either:
   - Inline-defang the avoid-RANK prose: "do NOT use RANK = N (zero rows possible). NOTE: this avoidance is SPECIFIC to the =N exact case. For top-N rows including ties at the boundary (<=N range), RANK<=N IS the canonical correct choice — see §2098."
   - Or move §2011 to AFTER §2098 in DAG order so the responder hits the <=N canonical first when keyword-matching "top N per group".
2. **At r23 §2098** — add an explicit worked example with the EXACT engineer-shape ("top 3 sales reps per region by deals_closed; 3rd and 4th tied at 47") showing `RANK() OVER (PARTITION BY region ORDER BY deals_closed DESC) <= 3` returning all four (1st, 2nd, both 47s). Include a "RANK at the boundary: both tied rows get rank 3, both pass <=3" inline explanation to directly defang the "RANK <=N skips boundary ties" misconception the responder voiced this iter.
3. **Add a DO-NOT-WRITE row** at §2098 with the exact wrong claim ("RANK() ties get same rank then next skips — so RANK<=N doesn't include all tied reps at position N") explicitly marked WRONG, with a one-line correction. This is the responder's literal wrong sentence; banning it by name should reach next time.

If a THIRD consecutive iteration still mis-routes, then this is a Haiku synthesis ceiling on rank-function selection per `feedback_synthesis_ceiling_stop_churning.md` and we should stop churning.

**Scores**: Acc 2.0 (wrong general rule, false RANK claim), Clar 4.0 (presentation clear), Prac 2.5 (works for this exact data only), Compl 3.0 (covers three functions but wrong winner). **2.875 FAIL**.

---

## Q2 — Iceberg expire_snapshots on a streaming pipeline — **4.375 PASS**

**Verified at [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html)**:
- `ALTER TABLE iceberg.<schema>.<table> EXECUTE expire_snapshots(retention_threshold => '7d')` — exact syntax CORRECT (parameter name `retention_threshold`, value duration string — responder did NOT slip into the `retention_days => 7` form from iter1214 — clean).
- "Removes all snapshots and all related metadata and data files" — responder's claim that it deletes the actual data files from MinIO storage CORRECT.
- `iceberg.expire-snapshots.min-retention` default `7d` floor — CORRECT; values below this fail with an error.
- Time-travel-to-expired-snapshot-fails tradeoff — CORRECT.
- Idempotent — CORRECT.

**Completeness shave (Compl 4.0)**: The engineer's scenario is "5-min streaming pipeline + MinIO ballooning + thousands of snapshots + old data files never cleaned." Expire_snapshots handles the snapshot-history-bloat side. But streaming pipelines with frequent commits ALSO produce **orphan files** (files left in MinIO from crashed/aborted commits — not referenced by ANY snapshot, current or historical). `expire_snapshots` does NOT touch these per docs (orphans are "files from a table's data directory that are not linked from metadata files"). The proper hygiene for a streaming pipeline is the pair: `expire_snapshots(retention_threshold => '7d')` + `remove_orphan_files(retention_threshold => '7d')`. Responder mentioned only the first.

This is the same paired-procedure point iter1240 covered for the orphan-cleanup angle — responder reached one half cleanly but didn't surface the streaming-orphan pairing.

**Scores**: Acc 4.5 (verified facts clean), Clar 4.5 (clear command + retention floor), Prac 4.5 (engineer can copy command), Compl 4.0 (missed remove_orphan_files pairing for streaming orphans). **4.375 PASS**.

---

## Q3 — dbt ephemeral materialization — **4.75 STRONG PASS**

**Verified at [docs.getdbt.com/docs/build/materializations](https://docs.getdbt.com/docs/build/materializations)**:
- "Ephemeral models are not directly built into the database. Instead, dbt interpolates the code from an ephemeral model into its dependent models using a common table expression (CTE)." → Responder's "dbt inlines the ephemeral SELECT as a CTE into every downstream at compile time, no table created" — CORRECT.
- Identifier prefix `__dbt__cte__` — responder didn't surface but not load-bearing.
- "Since ephemeral models are not persisted in the database, the CTE logic executes each time a downstream model that references it runs" — Responder's "re-runs every downstream execution (no persisted reuse)" — CORRECT.
- Multiple downstream refs: SQL gets inlined into each, runs separately, no shared cache, no deduplication — Responder's "two downstreams ref'ing it → SQL inlined into both, runs twice, no shared cache; 3+ downstreams → compile-time bloat" — CORRECT.
- "Use for small normalization; avoid for expensive/large/3+-downstream" guidance — CORRECT, matches docs' "very light-weight transformations early in DAG / models used in only one or two downstream models".

**Minor recall ceiling (Compl 4.5)**: Could have surfaced that ephemeral models cannot be queried directly (`SELECT * FROM ephemeral_model` fails) and don't support model contracts. Not load-bearing for this question (the engineer asked about inlining, re-run cadence, multi-downstream behavior, Trino problems — responder hit all four).

**Scores**: Acc 5.0 (all verified correct), Clar 4.75 (very clear), Prac 4.75 (engineer knows when to use vs avoid), Compl 4.5 (small omissions but all asked points covered). **4.75 STRONG PASS**.

---

## Q4 — Oracle GREATEST(NULL,…) → Trino — **3.875 PASS**

### (i) Trino fix — CORRECT

**Verified at [trino.io/docs/467/functions/comparison.html](https://trino.io/docs/467/functions/comparison.html)** (and matches pinned `reference_trino_greatest_least_null.md`): Trino 467 GREATEST/LEAST RETURN NULL if ANY arg is NULL. Responder's claim CORRECT.

Responder's fix — wrap each arg in COALESCE with a floor sentinel:
```sql
GREATEST(
  COALESCE(last_login_ts, TIMESTAMP '1900-01-01'),
  COALESCE(last_purchase_ts, TIMESTAMP '1900-01-01')
)
```
For numbers, COALESCE(x, 0). Sentinel-must-not-appear-in-real-data caveat — CORRECT general approach. Engineer arrives at working Trino SQL that handles NULLs without poisoning the max.

### (ii) Oracle premise — **FALSE; responder accepted false premise**

**Verified via WebSearch** (multiple Oracle community sources: Ask TOM, Oracle Forums, OraFAQ, codestudy.net): **Oracle's GREATEST function RETURNS NULL if any argument is NULL — it does NOT "ignore" NULLs.** From the search consensus: "Unlike aggregate functions, which ignore null values, greatest and least will return a null if any of the supplied columns (or expressions) are null."

This means:
- The engineer's premise ("Oracle ignores NULL and returns the other") is **FALSE**.
- The responder's affirmation ("In Oracle, GREATEST(a, NULL, c) ignores the NULL and returns the max of non-NULL args") is **FALSE**.
- There is actually NO behavioral difference between Oracle and Trino on this point. BOTH return NULL.
- The engineer's source Oracle code probably already had NVL/COALESCE wrapping (which is the standard Oracle pattern), and what they observed as "Oracle ignored the NULL" was actually NVL-wrapping in their PL/SQL that they forgot about. The Trino migration needs the same COALESCE wrapping (which the responder correctly provided).

**Why this matters**: The responder's Trino fix is CORRECT, so the engineer arrives at working SQL. But the engineer walks away believing a false fact about Oracle (which they may carry into future migrations and miscalibrate their expectations) and the responder reinforced rather than corrected. A high-quality answer would have been: "Quick correction — Oracle GREATEST ALSO returns NULL if any arg is NULL. Your existing Oracle code likely had NVL/COALESCE wrapping that gave the appearance of ignoring NULLs. Here's the Trino equivalent with COALESCE…"

This is the SAME assumed-presence/assumed-absence verify-first family that pinned memory (`feedback_responder_overwarning_folklore`, `reference_trino_to_char_exists.md` family) keeps catching. The responder defaulted to accepting the engineer's premise without verifying.

**Scores**: Acc 3.0 (Trino fix correct but Oracle premise false), Clar 4.5 (clear), Prac 4.0 (engineer gets working SQL despite false premise about Oracle), Compl 4.0 (covers fix + sentinel caveat; missed the "Oracle behaves the same" correction). **3.875 PASS**.

**No FIX-A**: This is an Oracle-fact slip on a peripheral assertion, not a Trino-resource defect. The Trino fix the responder gave is canonical-correct. r27 §6.X (Oracle migration section) does not need to add an Oracle-GREATEST-NULL myth row — that risks over-attracting non-NULL Oracle GREATEST questions. Per `feedback_new_card_over_attracts_adjacent.md`, hold off.

**SOFT WATCH** `iter1245 Q4 responder-accepts-engineer-false-oracle-premise`: re-probe under "Oracle X behaves Y differently from Trino" framings 4-8 iters where the Oracle premise itself is suspect, see if responder verify-firsts vs accepts.

---

## Topic mapping + rubric updates

- **Q1** → "Analytical query patterns on Iceberg+Trino: funnels, cohorts, time-series SQL" (rubric line 92, current 4.5281/177). **+2.875**.
  - New: (4.5281×177 + 2.875)/178 = (801.4737 + 2.875)/178 = 804.3487/178 = **4.5188/178 PASSED** (-0.0093, margin still +1.0188).
- **Q2** → "Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup" (rubric line 214, current 4.4429/232). **+4.375**.
  - New: (4.4429×232 + 4.375)/233 = (1030.7528 + 4.375)/233 = 1035.1278/233 = **4.4426/233 PASSED** (-0.0003, margin +0.9426).
- **Q3** → "Improving complex SQL performance on Trino with dbt" (rubric line 514, current 4.5020/62). **+4.75**.
  - New: (4.5020×62 + 4.75)/63 = (279.124 + 4.75)/63 = 283.874/63 = **4.5059/63 PASSED** (+0.0039, margin +1.0059).
- **Q4** → "Oracle PL/SQL → dbt+Trino" (rubric line 397, current 4.4700/212). **+3.875**.
  - New: (4.4700×212 + 3.875)/213 = (947.64 + 3.875)/213 = 951.515/213 = **4.4673/213 PASSED** (-0.0027, margin +0.9673).

All required topics REMAIN PASSED with margin.

---

## Open watches summary

- **PRIMARY (escalated): `iter1244+1245 top-N-per-group-WITH-TIES routing FIX-A NOT REACHING`** — Q1 this iter is the RE-PROBE; failed. Strengthen the FIX-A as described above (inline-defang the avoid-RANK prose at §2011, add engineer-shape worked example at §2098, add DO-NOT-WRITE row banning the responder's exact wrong sentence). Re-probe again next iter. If 3rd consecutive failure, accept as synthesis ceiling.
- **NEW SOFT**: `iter1245 Q2 expire-snapshots-without-remove-orphan-files for streaming pipelines` — responder missed the paired-procedure point for failed-streaming-commit orphans; re-probe 4-8 iters under "streaming + MinIO bloat" framings.
- **NEW SOFT**: `iter1245 Q4 responder-accepts-false-oracle-premise on GREATEST NULL` — Oracle GREATEST ALSO returns NULL; both Oracle and Trino are identical on this, no migration difference; responder reinforced the false claim. Re-probe under similar "Oracle X vs Trino Y" Oracle-side-premise-suspect framings.
- Iter1243 date_trunc-fragility (CLOSED prior); full-refresh-atomicity (soft-closed); iter1241 concat-auto-coerces (soft); iter1240 orphans-$files (soft); iter1239 DF-wait-timeout; iter1238 broadcast-hedge; iter1236 rn=1-within-batch; iter1234 ROLLUP-date_trunc-expr; iter1231 NEXT_DAY-note; iter1230 EXISTS-overwarning/::cast; iter1215 strpos-3-arg CEILING; iter1213 session_properties/(+); iter1229 @v1-Spark; iter1208 width_bucket.

---

## Next iter recommendation

PRIMARY: re-probe top-N-per-group-with-ties under DIFFERENT phrasings (e.g. "top 5 customers by spend per region, include all customers tied at the 5th spot", or "leaderboard top 10 per category showing all boundary ties") to test whether a strengthened FIX-A reaches across phrasings. If it still mis-routes after the strengthened FIX-A, accept as Haiku synthesis ceiling on rank-function selection per `feedback_synthesis_ceiling_stop_churning.md`.

Sources:
- [Trino window functions docs (RANK / DENSE_RANK semantics)](https://trino.io/docs/current/functions/window.html)
- [Trino Iceberg connector docs (expire_snapshots / retention_threshold / min-retention / remove_orphan_files)](https://trino.io/docs/467/connector/iceberg.html)
- [dbt materializations docs (ephemeral CTE inlining)](https://docs.getdbt.com/docs/build/materializations)
- [Ask TOM — GREATEST returning NULL](https://asktom.oracle.com/ords/f?p=100%3A11%3A0%3A%3A%3A%3AP11_QUESTION_ID%3A524526200346472289)
- [codestudy.net — Handling NULL in Oracle GREATEST](https://www.codestudy.net/blog/handling-null-in-greatest-function-in-oracle/)
- [Sydney Oracle Lab — Greatest, Least and NULLs](http://blog.sydoracle.com/2013/01/greatest-least-and-nulls.html)
