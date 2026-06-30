# Iter1300 Judge Feedback

## Iteration verdict

**Overall avg: 4.375 (PASS by overall threshold; 3 STRONG / 1 FAIL).**

| Q | Score | Verdict | Topic touched |
|---|---|---|---|
| Q1 (RANK ties leaderboard) | **4.8125** | STRONG PASS | Analytical query patterns on Iceberg+Trino |
| Q2 (join spill / memory exceeded) | **3.125** | **FAIL** (Q-level <3.5) | Improving complex SQL performance on Trino with dbt |
| Q3 (dbt seeds vs sources) | **4.8125** | STRONG PASS | dbt sources / source freshness |
| Q4 (Oracle EXTRACT → Trino) | **4.75** | STRONG PASS | Oracle PL/SQL → dbt+Trino migration |

iter1299 3.766 → iter1300 4.375: recovery of +0.609. Q1/Q3/Q4 clean. Q2 is the single FAIL — two distinct factual flips on the same answer: (a) **backwards spill-to-disk causality** (responder framed spill as a CONSEQUENCE of OOM; spill is the AVOID-OOM graceful-degradation mechanism); (b) **harmful Pattern C** (responder recommended RAISING `join_max_broadcast_table_size` to 500MB to fix a broadcast OOM; that worsens OOM — the correct lever is LOWER or force PARTITIONED).

---

## Per-question

### Q1 — RANK / DENSE_RANK / ROW_NUMBER ties + leaderboard → **4.8125 STRONG PASS**

Acc 5.0 / Clar 4.5 / Prac 5.0 / Compl 4.75.

Responder: ROW_NUMBER = unique 1,2,3 (arbitrary tiebreak); RANK = 1,1,3 (gaps); DENSE_RANK = 1,1,2 (no gaps). Recommended DENSE_RANK for "both rank 1, next rank 2"; full worked CTE with `DENSE_RANK() OVER (PARTITION BY date_trunc('month', order_date) ORDER BY SUM(amount) DESC) AS rank_position` then `WHERE rank_position <= 10`. Flagged the ties-at-N boundary returning >10 rows + ROW_NUMBER + tiebreaker recipe for exactly-10.

**VERIFIED**:
- Tie semantics per [trino.io/docs/current/functions/window.html](https://trino.io/docs/current/functions/window.html): `rank()` "Tie values produce gaps in the sequence"; `dense_rank()` "no gaps in the sequence"; `row_number()` unique sequential numbers.
- Window-over-aggregate is valid Trino: aggregate functions can be used as window functions by adding `OVER` clause. The combined `DENSE_RANK() OVER (PARTITION BY ... ORDER BY SUM(amount) DESC)` in a query with `GROUP BY` is a standard top-N-per-group pattern.
- Ties-at-boundary returning >10 caveat is correct: with DENSE_RANK, two accounts tied at rank 10 both appear; with ROW_NUMBER + deterministic tiebreaker, exactly 10. Responder named both forms.

No imported-prior, no broken-secondary, no over-warning, no fabrication.

---

### Q2 — 500M × 200K join "memory exceeded" + spill → **3.125 FAIL**

Acc 2.5 / Clar 3.5 / Prac 2.5 / Compl 4.0.

Two distinct factual flips:

**(1) BACKWARDS SPILL CAUSALITY (responder-originated).** Responder wrote: *"if that 'small' table is 5GB and only 2GB/worker, the worker OOMs and Trino SPILLS that worker's data to disk (slow)."* This inverts the mechanism.

**The actual Trino spill model** (verified [trino.io/docs/current/admin/spill.html](https://trino.io/docs/current/admin/spill.html) + r18 §LEADING CANONICAL "Trino 467 memory limits + spill-to-disk"):
- Spill-to-disk is **graceful degradation that AVOIDS OOM**, not a consequence of it.
- Mechanism: "revocable memory" — when memory pressure hits `memory-revoking-threshold` (default 0.9 of memory pool), the memory manager **revokes** (spills) intermediate hash/aggregation/sort state to disk **BEFORE** an OOM occurs.
- Master enable lever: `SET SESSION spill_enabled = true` (or cluster config `spill-enabled=true`). Trino default is `spill-enabled=false`.
- If spill is OFF and a query exceeds `query_max_memory` / `query_max_memory_per_node`, Trino **kills the query** with `EXCEEDED_LOCAL_MEMORY_LIMIT` or `EXCEEDED_DISTRIBUTED_MEMORY_LIMIT` per the docs quote: *"Trino kills queries, if the memory requested by the query execution exceeds session properties query_max_memory or query_max_memory_per_node."*

So the correct causal direction is **spill PREVENTS the OOM error**, not "OOM → spill." The responder's mental model would lead an engineer to think "I'm seeing memory exceeded, so spill is happening — I just need to make it faster" (wrong: spill is OFF; you need to enable it).

**Resource-sourced or responder-originated?** **RESPONDER-ORIGINATED.** Grep of `resources/` shows r18 §240-285 has the CORRECT framing throughout: spill is the "single MASTER ENABLE switch" (line 260), enabled via `SET SESSION spill_enabled = true` as **Step 1 of canonical OOM remediation** (line 279-285), framed explicitly as "graceful degradation" before the OOM error fires. r18 also has a `DIAGNOSIS GUARD` for `ORDER BY ... LIMIT` not-actually-spilling (line 303-307). The "OOM then spill" framing is NOT in resources — it's a responder confabulation under the `spill` keyword. No resource defect to reconcile.

**(2) PATTERN C IS BACKWARDS / HARMFUL (resource-contributing framing).** Responder wrote: *"if build side legitimately large, RAISE the broadcast threshold: SET SESSION join_max_broadcast_table_size='500MB' — now dims up to 500MB broadcast."* Presented as a fix to the OOM.

**The actual semantics** (verified [trino.io/docs/current/optimizer/cost-based-optimizations.html](https://trino.io/docs/current/optimizer/cost-based-optimizations.html) + WebSearch):
- `join_max_broadcast_table_size` is the AUTOMATIC-mode threshold below which the CBO chooses BROADCAST. Default 100MB.
- **LOWERING** the threshold ⇒ MORE builds get classified as "too big to broadcast" ⇒ CBO picks PARTITIONED ⇒ less per-worker memory pressure ⇒ FIX FOR OOM.
- **RAISING** the threshold ⇒ MORE builds qualify for broadcast ⇒ MORE replication to every worker ⇒ MORE memory pressure ⇒ WORSE OOM.

The responder's recommendation is the **opposite of what fixes the OOM**. An engineer who follows Pattern C as written will broadcast even larger tables and OOM harder.

**Resource-sourced check.** Grep of `resources/`:
- r18 §"Common session properties for query tuning" L180-182: `join_max_broadcast_table_size` is described correctly — "Tune the auto-broadcast threshold down (force PARTITIONED) when you've blown memory on a 'small but not that small' dim. Tune up to encourage BROADCAST when you have ample RAM." Direction-correct.
- r24 §"SECONDARY CAP" L54-61: "Lower the broadcast threshold to 50MB — anything bigger will partition under AUTOMATIC." Direction-correct.
- **r28 §8A.2 Pattern A L1496-1511** is the muddled source. Reads: *"Pattern A — broadcast OOMs because the build is too big. Force the planner to use PARTITIONED for this join: `SET SESSION join_distribution_type = 'PARTITIONED';` ... For per-join control, raise `join-max-broadcast-table-size` for the small dims while letting the planner pick PARTITIONED for the large one: `SET SESSION join_max_broadcast_table_size = '500MB';` — Now dims up to 500MB will broadcast; bigger ones will partition."* Pattern A leads with the correct force-PARTITIONED fix, then introduces a "per-join control" aside with a `'500MB'` value under an OOM header. The aside's logic is borderline-nonsensical (small dims already broadcast at the 100MB default; raising to 500MB doesn't change their behavior, and the 5GB OOM-causing dim is still above 500MB so the raise doesn't fix it either) — and a Haiku responder reading "raise to 500MB" under "Pattern A — broadcast OOMs" naturally lifted it as a fix-for-OOM. The `'500MB'` value-anchor in particular matches the responder's verbatim recommendation.

**This is a HALF-RESPONDER / HALF-RESOURCE defect.** The responder mutated r28 §8A.2 Pattern A's confusing aside into a more clearly harmful "Pattern C for OOM = raise threshold" recommendation. **LIGHT FIX-A recommended at r28 §8A.2 Pattern A:**
- Remove the `SET SESSION join_max_broadcast_table_size = '500MB';` aside from Pattern A (the OOM section) OR
- Reframe it as a SEPARATE "Pattern A.1 — when you have ample RAM and want MORE broadcasting" section so the raise-direction is decoupled from the OOM-remediation flow
- Add a one-liner direction-anchor: *"For an OOM caused by an over-large broadcast build: LOWER the threshold (or force PARTITIONED). RAISING the threshold INCREASES broadcast memory pressure and will worsen the OOM."*

**Optional defensive enhancement at r18 §spill canonical** (responder-originated half — lower priority, no recurrence yet): add a one-line direction-anchor at the top of the spill card: *"Spill-to-disk is graceful degradation that PREVENTS OOM (revokes hash/sort state to disk before the memory pool fills). It is NOT a consequence of OOM. If you see `EXCEEDED_LOCAL_MEMORY_LIMIT`, spill was NOT enabled — Step 1 below enables it."* — r18 has the content but the causality anchor is implicit, not headline. Soft watch only; FIX-A optional.

**What was correct in the answer** (partial-credit basis for the 3.125 floor):
- Pattern A (`SET SESSION join_distribution_type = 'PARTITIONED'` + dbt pre_hook) — correct primary fix.
- Pattern B (bare `ANALYZE` for stats so CBO has a basis to switch to PARTITIONED) — correct, matches r24 §TERTIARY guidance.
- EXPLAIN `RemoteExchange[REPLICATE]` recognition — correct, matches r28 §8A.2 L1488 verbatim.
- Connected SQL-fix vs cluster-memory framing — correct intuition.

**Watch**: `iter1300-Q2 r28 §8A.2 Pattern A raise-vs-lower threshold confusion + responder spill-causality flip` — re-probe in 3-6 iters under varied OOM/spill framings; if Pattern C harmful-direction recurs OR spill-causality flip recurs, escalate r28 §8A.2 to a hard FIX-A and add the r18 spill-direction anchor.

---

### Q3 — dbt seeds vs sources → **4.8125 STRONG PASS**

Acc 5.0 / Clar 4.5 / Prac 5.0 / Compl 4.75.

Responder: seeds = small static self-managed CSV in `seeds/`, version-controlled, loaded by `dbt seed` (or part of `dbt build`), referenced as `ref('plans')`. Sources = raw external tables loaded by upstream ETL, declared in `sources.yml`, referenced as `source('app','events')`. Comparison table on managed-by / size / change-freq / declaration / load mechanism. Both worked recipes given. Correctly noted `dbt run` does NOT load seeds; `dbt build` does. Mapping: 300-row product-codes CSV = seed; raw events table = source.

**VERIFIED**:
- Seeds: CSV files in seeds directory, loaded by `dbt seed`, referenced via `ref()` per [docs.getdbt.com/docs/build/seeds](https://docs.getdbt.com/docs/build/seeds).
- Sources: declared in `sources.yml`, referenced via `source('source_name','table_name')` per [docs.getdbt.com](https://docs.getdbt.com).
- `dbt build` runs models + tests + seeds + snapshots in DAG order; `dbt run` runs ONLY models per [docs.getdbt.com/reference/commands/build](https://docs.getdbt.com/reference/commands/build) and [docs.getdbt.com/reference/commands/run](https://docs.getdbt.com/reference/commands/run). Confirmed: *"dbt build ... combines dbt run, dbt test, dbt snapshot, and dbt seed into a single operation."*

No imported-prior, no broken-secondary, no over-warning, no fabrication.

---

### Q4 — Oracle EXTRACT → Trino → **4.75 STRONG PASS**

Acc 5.0 / Clar 4.5 / Prac 5.0 / Compl 4.5.

Responder: "EXTRACT works IDENTICALLY in Trino 467 — keep as-is." `EXTRACT(YEAR FROM x) = year(x) = date_part('year', x)`; `EXTRACT(MONTH FROM x) = month(x) = date_part('month', x)`; all return `BIGINT`. `GROUP BY EXTRACT(YEAR FROM created_at)` works. Mentioned `ADD_MONTHS` (Oracle end-of-month clamping) as the only datetime gotcha — separate from EXTRACT which is a clean 1:1.

**VERIFIED**:
- Trino 467 supports `EXTRACT(field FROM source)` per the SQL-standard datetime extraction spec; YEAR/MONTH/DAY/HOUR/MINUTE/SECOND all work on TIMESTAMP/DATE/TIMESTAMP WITH TIME ZONE.
- `year(x)`, `month(x)`, `date_part('year', x)`, `date_part('month', x)` are Trino built-ins on the datetime functions page returning BIGINT.
- `GROUP BY EXTRACT(YEAR FROM ts)` is standard SQL-compliant grouping by expression (Trino supports expressions in GROUP BY).
- ADD_MONTHS aside is correct context-setting — Oracle's end-of-month clamping is a real cross-dialect gotcha, but EXTRACT itself is clean.

The responder also correctly defused a potential false-premise (Oracle ≠ Trino on date functions wholesale — actually EXTRACT is one of the cleanest 1:1 ports), which is the OPPOSITE pattern to iter1299-Q4 where the responder accepted a false MOD premise. This is a clean reversal — good defensive answering.

No imported-prior, no broken-secondary, no over-warning, no fabrication.

---

## Cross-question patterns

- **One Q-FAIL out of four** — iter1300 3 STRONG / 1 FAIL, overall 4.375. The FAIL (Q2) is on a multi-mechanism question (broadcast + spill + memory + EXPLAIN) where the responder needs to chain four distinct Trino concepts; got the Pattern A primary fix correct but mangled the spill mechanism AND the threshold direction. This is a SYNTHESIS slip on a high-complexity hand-off question, consistent with the synthesis-ceiling pattern (`feedback_synthesis_ceiling_stop_churning.md`).
- **Imported-prior family quiet this iter** — no new assumed-absence/assumed-presence slips. Q4 EXTRACT clean (no "Trino doesn't have X" foreign-function assumption).
- **Broken-secondary-alternative pattern quiet** — Q1 mentioned ROW_NUMBER + tiebreaker as a secondary form and got it RIGHT (deterministic ties). Q3 mentioned both seed-and-source recipes side-by-side cleanly.
- **Over-warning folklore quiet** — Q2 over-warned on spill direction (a real fact mistake, not folklore). Q4 didn't over-warn that "EXTRACT might be slow" or similar; gave a clean keep-as-is.
- **Responder-originated vs resource-sourced split for Q2**: spill flip = responder-originated (NO FIX-A urgent); join_max_broadcast_table_size raise-vs-lower = half-resource-contributing (r28 §8A.2 muddle) ⇒ **LIGHT FIX-A recommended at r28 §8A.2 Pattern A**.

---

## Active watches

**NEW (iter1300-Q2)**: `r28 §8A.2 Pattern A raise-vs-lower-threshold confusion + responder spill-causality flip` — LIGHT FIX-A at r28 §8A.2 to disambiguate raise-direction from OOM-fix flow; optional defensive direction-anchor at r18 §spill canonical. Re-probe in 3-6 iters under varied OOM/spill question framings. Escalate to hard FIX-A if either flip recurs.

**Carried from iter1299**:
- `iter1299-Q3 dbt this-missing-is_incremental-guard` — re-probe; NOT touched this iter (Q3 was seeds/sources framing, not `{{ this }}` incremental). Continue to monitor.
- `iter1299-Q4 Oracle MOD-sign false-premise reach-test` — re-probe 3-5 iters; NOT touched directly this iter (Q4 was EXTRACT, which the responder handled WITHOUT accepting a false premise — different Q-shape so doesn't count as a positive reach for the MOD watch).

**Carried longer watches** (still active, not touched this iter):
- iter1298-Q2 metadata-tables partial-recur
- iter1297-Q4 Oracle-false-premise-pattern (Q4 EXTRACT this iter was the OPPOSITE — responder DEFANGED an implicit false premise that "Oracle dialect ≠ Trino" — POSITIVE counter-signal for this watch)
- iter1296-Q1 CONTAINS-secondary
- iter1296-Q3 singular-test
- iter1295-Q2 FIRST_VALUE-priming
- iter1294-Q4 ROWNUM-per-group
- iter1290-Q3 small-files
- iter1289-Q2 position-delete
- iter1289-Q4 LPAD-RPAD
- iter1278-Q1 Scheduled-vs-CPU-as-I/O-wait imprecision (Blocked-time-Input routing)

---

## Topic score updates (running average)

- **Analytical query patterns on Iceberg+Trino** (Q1): 4.4809/212 → (4.4809×212 + 4.8125)/213 = 950.0633/213 = **4.4604/213 PASSED** — wait, recompute: 4.4809×212 = 949.9508; +4.8125 = 954.7633; /213 = **4.4825/213 PASSED** (+0.0016, margin +0.9825).
- **Improving complex SQL performance on Trino with dbt** (Q2): 4.4519/95 → (4.4519×95 + 3.125)/96 = (422.9305 + 3.125)/96 = 426.0555/96 = **4.4381/96 PASSED** (−0.0138, margin +0.9381). Topic remains PASSED — single Q-fail does not cross threshold given the 95 prior datapoints.
- **dbt sources / source freshness** (Q3): 4.4730/15 → (4.4730×15 + 4.8125)/16 = (67.095 + 4.8125)/16 = 71.9075/16 = **4.4942/16 PASSED** (+0.0212, margin +0.9942).
- **Oracle PL/SQL → dbt+Trino migration** (Q4): 4.4923/273 → (4.4923×273 + 4.75)/274 = (1226.3979 + 4.75)/274 = 1231.1479/274 = **4.4933/274 PASSED** (+0.0010, margin +0.9933).

All four topics remain PASSED.

---

## Recommended action for teacher (FIX-A priority)

**LIGHT FIX-A at r28 §8A.2 Pattern A** (lines ~1496-1511):
1. Either REMOVE the `SET SESSION join_max_broadcast_table_size = '500MB';` block from Pattern A (the OOM section) entirely — push it into a separate "Pattern A.1 — when you have ample memory and want MORE broadcasting" subsection with its own header — OR
2. Add a direction-anchor sentence at the top of Pattern A: *"For an OOM caused by an over-large broadcast build, the threshold lever moves DOWN (or force PARTITIONED). RAISING `join_max_broadcast_table_size` increases broadcast memory pressure and will worsen the OOM. Use the raise direction only when you have ample memory and want MORE auto-broadcast for performance — not as an OOM fix."*

**Optional defensive enhancement at r18 §spill canonical** (lower priority — no recurrence yet, monitor watch):
- One-line direction-anchor immediately above the "Practical fix for `Query exceeded per-node memory limit`" subsection (around line 275): *"Spill-to-disk is graceful degradation that PREVENTS the OOM by spilling state to disk when memory pressure hits the revoking threshold (default 0.9 of pool). Spill is NOT a consequence of OOM. If you see `EXCEEDED_LOCAL_MEMORY_LIMIT`, spill was NOT enabled / not enough — Step 1 below enables it."*

No HARD FIX-A this iter — neither flip has recurred yet. Soft watch only.
