# Iteration 1244 — Judge Feedback

## Verdict

**Overall: 4.328 — PASS (BUT Q2 IS A REAL FAIL — wrong lead recommendation on top-N-with-ties).** Per-Q scores: Q1=4.875, Q2=2.875, Q3=4.75, Q4=4.8125. Average (4.875+2.875+4.75+4.8125)/4 = 17.3125/4 = **4.328**.

**Watch closure update**: `iter1243 date_trunc-DATE-literal-pruning fragility-overstatement` watch **CLOSES** on first re-probe (Q1 this iter responder LED with "RELIABLY prunes" — the iter1243 corpus-reconcile FIX-A REACHED).

**New issue**: Q2 responder applied the WRONG canonical (DENSE_RANK ≤ N) to a top-N-with-ties shape that has an explicit defang at r23 §2163. **LIGHT FIX-A WARRANTED** — cross-link strengthening at r23 §2011 to route "top-N range per group with ties at cutoff" → §2098 (see §4 below).

---

## Q1 — date_trunc('month', order_ts) on day(order_ts)-partitioned table: still prunes or full scan?

**Score: 4.875** (Acc 5.0 / Clar 4.5 / Prac 5.0 / Compl 5.0)

**Verdict: CORRECT — watch CLOSES.** Responder LED with "Yes, Trino 467 STILL prunes — NOT a full scan" and correctly identified default-on UnwrapDateTruncInComparison / UnwrapYearInComparison / UnwrapCastInComparison as the rewrite rules that turn `date_trunc('month', order_ts) = DATE '2026-06-01'` into a bare-range `order_ts >= TIMESTAMP '2026-06-01' AND order_ts < TIMESTAMP '2026-07-01'` which then pushes to Iceberg pruning. EXPLAIN verification (look for `constraint=` on TableScan) is the correct diagnostic. Genuine pruning-killers correctly named (LOWER/SUBSTR/UDFs on partition column).

**Verification**: matches pinned `reference_trino_unwrap_temporal_predicates.md` (467-tag UnwrapDateTruncInComparison.java verified, SupportedUnit = HOUR/DAY/MONTH/YEAR). The iter1243 corpus-reconcile FIX-A (r22 §3261, r28 §710/§1093/§1097/§1319) succeeded — responder lifted the correct framing this iter, not the stale fragility framing.

**Iter1243 date_trunc-pruning fragility-overstatement watch: CLOSES on first re-probe (24th consecutive 1st-re-probe-CLOSE).**

---

## Q2 — Top-5 accounts by revenue per plan_tier, include boundary ties: which ranking function?

**Score: 2.875** (Acc 2.5 / Clar 3.5 / Prac 2.5 / Compl 3.0)

**Verdict: WRONG LEAD RECOMMENDATION.** Responder recommended **DENSE_RANK() OVER (PARTITION BY plan_tier ORDER BY total_revenue DESC) ≤ 5** as the canonical "top 5 including ties" answer. This is wrong — it returns the top-5 DISTINCT REVENUE VALUES per group, NOT the top-5 ACCOUNTS-by-position including ties at the cutoff. The two are different shapes:

| Shape | Correct function | Why |
|---|---|---|
| **Top N rows INCLUDING everyone tied at the Nth position** (the asked shape — "top 5 accounts; both tied accounts at the boundary should appear") | **`FETCH FIRST 5 ROWS WITH TIES`** OR **`RANK() OVER (...) ≤ 5`** | RANK sequence `1,2,3,4,5,5,7,...` — both tied rows at position 5 pass `≤ 5`; gap-after-ties at rank 6/7 is HARMLESS for a `≤ N` range filter. |
| **Top N DISTINCT value-tiers** (e.g. "top 3 price tiers") | `DENSE_RANK() ≤ N` | DENSE_RANK sequence `1,1,2,3,3,4` — returns ALL rows whose value lands in one of the top N distinct values; row count can be much larger than N. |
| **The Nth-largest DISTINCT value** (e.g. "second-highest amount") | `DENSE_RANK() = N` | This is the §2011 LEADING CANONICAL — but it's the EXACT case, not the range case. |

**The responder's reasoning is muddled**: it claimed "RANK() with rank ≤ 5 would get rows at ranks 1,1,3,4,5 (7 rows, skipping rank 2)". That's mathematically wrong — five ranks `{1,1,3,4,5}` is 5 rows, not 7, and the gap at rank 2 is BEFORE the filter cutoff so it doesn't drop anything. The responder also claimed DENSE_RANK ≤ 5 in the 5-account boundary-tie example returns 6 rows — that count happens to be right for the BOUNDARY case but the responder fails to surface the danger case: when ties exist ABOVE the boundary, DENSE_RANK ≤ 5 returns MORE than the true top-5-by-position. E.g. with revenues `1000,1000,800,700,600,500,500`:
- RANK ≤ 5: `1,1,3,4,5` → 5 rows = the true top-5 positions (including the boundary case naturally).
- DENSE_RANK ≤ 5: `1,1,2,3,4,5,5` → 7 rows — returns the top-5 DISTINCT values, which over-fires beyond "top 5 accounts."

**Resource check — the canonical IS already correctly authored:**
- **r23 §2098 LEADING CANONICAL** (iter714 PIN — FIX-A2): *"TOP-N INCLUDING TIES AT THE CUTOFF — use `FETCH FIRST n ROWS WITH TIES` or `RANK() ≤ N` (NOT `DENSE_RANK() ≤ N`, NOT `ROW_NUMBER() ≤ N`)"*.
- **r23 §2163 DEFANG** explicitly bans `DENSE_RANK() OVER (ORDER BY sales DESC) ≤ 10` for "top 10 leaderboard with ties at the 10th spot" with the exact wrong-shape reason.
- **r23 §2134 table** has the side-by-side disambiguation of "top N rows incl. ties" vs "top N distinct value-tiers".

So the resource is RIGHT and the responder mis-routed. The likely failure mode: Haiku keyword-matched "Nth-largest per group" / "ties consume the slot" at r23 §2011 (the LEADING CANONICAL for Nth-largest DISTINCT VALUE → DENSE_RANK = N) and over-applied DENSE_RANK to a top-N range case at §2098 — even though §2098 explicitly defangs that.

**Verified via WebFetch of [trino.io/docs/current/functions/window.html](https://trino.io/docs/current/functions/window.html) + [Microsoft Learn RANK](https://learn.microsoft.com/en-us/sql/t-sql/functions/rank-transact-sql) + [Erik Darling TOP WITH TIES](https://erikdarling.com/a-little-about-top-with-ties-in-sql-server/)**: SQL Server's `TOP N WITH TIES` semantic — the canonical interpretation of "top 5 accounts including ties at the boundary" — is implemented in standard SQL as `RANK() ≤ N`, NOT `DENSE_RANK() ≤ N`. Trino's native ANSI form is `FETCH FIRST n ROWS WITH TIES` (with required `ORDER BY`).

**LIGHT FIX-A RECOMMENDED** (per §4 below) — strengthen the routing path from §2011 to §2098 so Haiku doesn't lift "DENSE_RANK = N for Nth-largest" and over-generalize to "DENSE_RANK ≤ N for top-N range with ties". This is a real risk pattern, not a one-off — the keyword overlap ("ties", "per group") between §2011 and §2098 makes the wrong route plausible.

---

## Q3 — dbt model contracts: does enforced contract actually FAIL the build on type mismatch?

**Score: 4.75** (Acc 5.0 / Clar 4.5 / Prac 4.75 / Compl 4.75)

**Verdict: CORRECT.** Responder said "Yes, ACTUALLY FAILS the build" with the correct config (`contract: {enforced: true}` + `columns:` with `name` + `data_type`), the correct error message shape ("This model has an enforced contract that failed" + mismatch table, "No changes were applied to the warehouse"), the correct mechanism (warehouse-interactive preflight — dbt issues `SELECT ... WHERE 1=0` introspection to Trino, reads ACTUAL result-set types, compares to YAML — REQUIRES a live Trino connection; dbt parse/compile offline won't catch it), and the correct runtime-vs-declared split (only `not_null` enforced at write time on dbt-trino+Iceberg; `primary_key`/`unique`/`foreign_key` definable but NOT runtime-enforced — pair with dbt tests).

**Verification via WebFetch of [docs.getdbt.com/reference/resource-configs/contract](https://docs.getdbt.com/reference/resource-configs/contract)**: confirms validation at compile/build time before materialization, requires live warehouse connection to execute introspection query that reports actual returned dataset, fails with compilation error if column names/data types don't match, build halts before any table create/replace, and constraint enforcement varies by platform. Matches pinned `reference_dbt_contract_needs_live_connection.md` (iter1194 reconcile that fixed an older r27 §6.7C + r28 §282 claim of "compile time / SQL never sent to Trino"). Resource r27 §6.7C is correctly authored and the responder lifted it cleanly.

Minor Compl shave: didn't surface the `dbt-trino` specific note that contracts work even on incremental/views (not just tables), but that's recall-ceiling not a defect.

---

## Q4 — Oracle SUBSTR(error_code, -3) returns NULL in Trino — does Trino support negative SUBSTR?

**Score: 4.8125** (Acc 5.0 / Clar 4.5 / Prac 5.0 / Compl 4.75)

**Verdict: CORRECT.** Responder said "Trino DOES support negative start positions — ports directly" with the canonical example `substr('Quadratically', -5) = 'cally'` and the right NULL-diagnostic checklist (NULL input / shorter-than-3 input / non-VARCHAR type). Safe last-N form `CASE WHEN LENGTH(s) < 3 THEN s ELSE substr(s, -3) END` is appropriate for short-input safety.

**Verification via [trino.io/docs/current/functions/string.html](https://trino.io/docs/current/functions/string.html)**: verbatim *"Positions start with 1. A negative starting position is interpreted as being relative to the end of the string."* Matches r27 §993 SUBSTR canonical (the iter Oracle→Trino string row explicitly anchored on "NEGATIVE START SUPPORTED" + "Oracle `SUBSTR(s, -n)` ports DIRECTLY to Trino `substr(s, -n)` — no rewrite needed" + "NO `right()` / `left()` IN TRINO. Use `substr(s, -n)` for the LAST n chars"). Engineer arrives at the right diagnosis: silent NULLs are NOT from the negative index (it works); they're from NULL input or non-VARCHAR type.

Minor Compl shave: could have mentioned that `substr(s, -3)` with `LENGTH(s) < 3` returns the whole string (not NULL) — clarifying this would have explained why the CASE wrapper is optional for the "string shorter than N" case (Trino simply returns whatever's available, not NULL). Not load-bearing for the asked question.

---

## Resource-source check

| Q | Resource | Status | Source-correct? | Responder slip? |
|---|---|---|---|---|
| Q1 | r28 §1072 lead + r22/r28 reconciled (iter1243 FIX-A) | Correct | Yes — RELIABLY prunes for HOUR/DAY/MONTH/YEAR units, identity/day/month/year transforms | None — clean lift |
| Q2 | r23 §2098 (top-N with ties) + §2163 (defang) | Correct | Yes — explicitly says RANK ≤ N or FETCH FIRST, NOT DENSE_RANK ≤ N | **YES — mis-routed to §2011 (Nth-largest DISTINCT) and applied DENSE_RANK ≤ N** |
| Q3 | r27 §6.7C dbt model contracts | Correct | Yes — warehouse-interactive preflight, SELECT...WHERE 1=0, live connection, not_null-only write-time | None — clean lift |
| Q4 | r27 §993 SUBSTR negative-index row | Correct | Yes — negative start supported, no rewrite needed | None — clean lift |

---

## FIX-A recommendation for Q2

**LIGHT FIX-A — TARGETED CROSS-LINK STRENGTHENING (no new card).**

**Where**: `resources/23-sql-best-practices-olap.md`

**Edit 1 — at §2011 (LEADING CANONICAL for Nth-LARGEST distinct value)**: add an inline router at the TOP of the section that reads roughly:

> **Router — which shape do you have?**
> - **"Nth-LARGEST distinct VALUE per group"** (e.g. second-highest amount, third-distinct revenue tier — exact `= N`) → THIS section, `DENSE_RANK() = N`.
> - **"Top N ROWS per group INCLUDING ties at the Nth boundary"** (e.g. top 5 accounts per plan_tier with both boundary-tied accounts shown — range `≤ N`) → see **§2098** TOP-N INCLUDING TIES AT THE CUTOFF, use `RANK() ≤ N` or `FETCH FIRST n ROWS WITH TIES`. **`DENSE_RANK() ≤ N` is the WRONG shape for the range case** — returns top-N distinct VALUES, not top-N ROWS.
> - **"Exactly one row per group at position N"** (a specific record, not a tie-handling question) → ROW_NUMBER subquery.

**Edit 2 — at §2098 LEADING CANONICAL header**: extend the keyword-anchor list to include "top 5 accounts per plan_tier with both boundary-tied accounts shown" / "top N per group including ties" / "PARTITION BY ... ORDER BY ... DESC, want all rows tied at the Nth" so the per-group ranking-with-ties framing is keyword-routable directly.

**Why this is the right FIX-A shape (not a new card)**:
- Per `feedback_new_card_over_attracts_adjacent.md` — adding another standalone canonical for "top-N-with-ties per group" risks over-attracting the §2011 Nth-largest distinct questions.
- The resource ALREADY has the correct content at §2098 + the correct defang at §2163. The gap is purely findability — Haiku reached §2011 (Nth-largest distinct) and stopped, missing §2098. Cross-linking at §2011 fixes the routing.
- Per `feedback_reconcile_dont_append.md` — edit in place, don't add.
- Per `feedback_responder_overwarning_folklore.md` family logic — this is NOT a content gap; the wrong rec was confidently authoritative-sounding. A cross-link router IS the right corrective shape.

**Not recommended**: a "DO-NOT-WRITE DENSE_RANK ≤ N for top-N range" defang inside §2011 itself — that's redundant with §2163 and risks the defanged form being copy-attractive per `feedback_defang_donotwrite_snippets.md`.

---

## Pattern summary across the 4 answers

- **Two clean re-probe closures**: Q1 closed the iter1243 date_trunc-pruning watch on first re-probe (24th consecutive 1st-re-probe-CLOSE in the loop history); Q3 implicitly closes the iter1243 --full-refresh-atomicity soft watch (responder showed clean dbt + Iceberg + dbt-trino understanding under the contract-mechanism framing).
- **One responder-side failure on a maximally-anchored resource**: Q2 wrong lead recommendation despite §2098 + §2163 being correctly authored. Mirrors the iter1242 cumulative-distinct slip pattern (responder reached the wrong canonical despite the right one being anchored). Distinction: iter1242 was recall-ceiling on an isolated DO-NOT-WRITE form; this iter Q2 is mis-routing between TWO neighbor canonicals with overlapping keyword anchors — a routing gap that a cross-link CAN fix.
- **Q4 imported-prior calibration continues to land**: responder did NOT claim Trino lacks negative-substr or recommend a workaround — the `reference_trino_to_char_exists.md` family lesson ("verify existence before asserting absence") continues to land for negative-index variants.

## Watches

**CLOSING this iter**:
- `iter1243 date_trunc-DATE-literal-pruning fragility-overstatement` — Q1 LED with "reliably prunes" + UnwrapDateTruncInComparison + correct EXPLAIN diagnostic. **CLOSED on first re-probe.**

**Soft CLOSING** (implicit):
- `iter1243 Q3 dbt-trino-on-Iceberg --full-refresh atomicity-mechanism` — Q3 this iter showed clean dbt-trino + Iceberg + contract mechanism with warehouse-interactive preflight, demonstrating the adapter understanding the soft watch was probing. Soft watch can be considered light-CLOSED.

**OPENING this iter**:
- `iter1244 Q2 top-N-with-ties-per-group mis-route DENSE_RANK<=N from §2011 instead of RANK<=N from §2098` — **PRIMARY post-FIX-A watch**. Re-probe under "top N per group including ties at boundary" / "leaderboard per group with ties" / "want both tied accounts at the Nth position to appear" framings 4-8 iters after the §2011 router edit lands. If responder STILL recommends DENSE_RANK ≤ N for the range-with-ties shape, escalate to in-place strengthening at §2098 with explicit per-group worked example.

**STILL OPEN** (carried):
- iter1242 cumulative-distinct (closed at iter1243 re-probe, monitoring); iter1241 concat-auto-coerces (soft); iter1240 orphans-$files (soft); iter1239 DF-wait-timeout; iter1238 broadcast-hedge; iter1236 rn=1-within-batch; iter1234 ROLLUP-date_trunc-expr; iter1231 NEXT_DAY-note; iter1230 EXISTS-overwarning/::cast; iter1215 strpos-3-arg CEILING; iter1213 session_properties/(+); iter1229 @v1-Spark; iter1208 width_bucket boundary label.

## Topic score updates (delta this iter)

| Topic | Q | Score | Old avg/N | New avg/N | Δ |
|---|---|---|---|---|---|
| SQL query best practices for OLAP | Q1 | 4.875 | 4.5823/287 | 4.5833/288 | +0.0010 |
| Analytical query patterns on Iceberg+Trino | Q2 | 2.875 | 4.5375/176 | 4.5281/177 | -0.0094 |
| Improving complex SQL performance on Trino with dbt | Q3 | 4.75 | 4.4979/61 | 4.5020/62 | +0.0041 |
| Oracle PL/SQL → dbt + Trino SQL migration | Q4 | 4.8125 | 4.4684/211 | 4.4700/212 | +0.0016 |

All four topics REMAIN PASSED. Net iteration score 4.328 — standard PASS (above 3.5 threshold), Q2 drags the iteration average significantly but the FIX-A cross-link addresses the root cause.
