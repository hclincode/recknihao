# Judge Feedback — Iteration 1284

**Overall**: 4 questions, average **3.734 PASS-marginal** (Q1 2.00 FAIL / Q2 4.875 STRONG PASS / Q3 3.125 FAIL / Q4 4.9375 STRONG PASS).

**Headline**: Two failing answers — but they fail for **structurally different reasons**, and the recommendation diverges.
- **Q1 = 4th CONSECUTIVE NON-REACH** on the `system.runtime.queries` JOIN `system.runtime.tasks` perf-triage recipe. The iter1283 2-part FIX-A (affirmative-first hoist at r18 §404 + L127 pointer) DID land the right shape on the resource — the recipe sits at the TOP of §404 with copy-pasteable SQL, and the L127 myth row now says "DON'T stop here — see §Finding expensive queries below." The responder still didn't reach it. This iter it landed at a THIRD different decoy (r27 §6.7L query-comment example, L4333) and regenerated the same base-training "bytes aren't in the system tables → use EXPLAIN ANALYZE" myth. **The recipe is correct. The responder cannot assemble it.** Source-verified: `system.runtime.tasks` does expose `physical_input_bytes` + `split_cpu_time_ms` columns on Trino 467 (raw `TaskSystemTable.java` 467 tag), and the JOIN on `query_id` to `system.runtime.queries` is the documented way to get per-query bytes + CPU without an event listener. **My decision: RECALL-CEILING STOP** (details below).
- **Q3 = responder slip on correct + present content.** Resources r27 §3.2 L322-326 + r28 L402 + L1679/L1692 explicitly list `delete+insert` as one of the four built-in dbt-trino `incremental_strategy` values, with the exact SQL it emits. Verified at [docs.getdbt.com/reference/resource-configs/trino-configs](https://docs.getdbt.com/reference/resource-configs/trino-configs) verbatim: dbt-trino supports `append` (default), `delete+insert`, and `merge`. The responder said *"delete+insert — Not a built-in dbt strategy; you'd write it manually"* — FALSE. NOT a resource gap. Per-instance per `feedback_synthesis_ceiling_stop_churning.md` discipline → NO FIX.
- **Q2 + Q4 are clean STRONG PASSES.**

| Q | Topic | Score | Status | Verdict |
|---|---|---|---|---|
| Q1 | Perf-triage RE-PROBE #4 (LIVE system tables for CPU + bytes) | **2.00** | **FAIL** | 4th consecutive NON-REACH; recipe at r18 §404 IS correct + hoisted + L127-pointed; responder landed at r27 §6.7L (3rd different decoy) and regenerated the "bytes need EXPLAIN ANALYZE" base-training myth |
| Q2 | Above-group-average (correlated subquery vs window) | **4.875** | STRONG PASS | `AVG(amount) OVER (PARTITION BY account_id)` led + filter; correlated-subquery framing accurate (Trino decorrelates; EXPLAIN-for-CorrelatedJoin caveat sound) |
| Q3 | dbt incremental strategies (append/merge/delete+insert) | **3.125** | **FAIL** | LOAD-BEARING wrong claim: "delete+insert is not built-in." It IS built-in in dbt-trino (r27 §3.2 + r28 L402 both teach this verbatim) |
| Q4 | Oracle TO_CHAR/TO_DATE + `'Invoice #' \|\| number` → Trino | **4.9375** | STRONG PASS | TO_CHAR/TO_DATE absence + `date_format`/`format_datetime` mask mapping correct; `to_char` Teradata lowercase-numeric-only caveat correct; `\|\|` varchar-only with CAST(number AS VARCHAR) / `format()` fix correct |

**Iter average**: (2.00 + 4.875 + 3.125 + 4.9375) / 4 = **3.734** (margin +0.234 over 3.5; thinnest pass since iter1254 3.8125).

---

## Q1 — perf-triage recipe (4th non-reach) — DECISION: RECALL-CEILING STOP

### Confirm: recipe IS correct
Source-verified this iter against raw Trino 467 source:
- `system.runtime.tasks` columns (from [TaskSystemTable.java @ 467 tag](https://raw.githubusercontent.com/trinodb/trino/467/core/trino-main/src/main/java/io/trino/connector/system/TaskSystemTable.java)): includes `query_id`, `physical_input_bytes`, `split_cpu_time_ms`, `output_bytes`, `output_rows`, `physical_written_bytes`, lifecycle (`created`/`start`/`end`), etc.
- `system.runtime.queries` columns: `query_id`, `state`, `"user"`, `source`, `query` (full SQL text), `resource_group_id`, `queued_time_ms`, etc. — but **no `physical_input_bytes` or `split_cpu_time_ms` directly** (those live on `tasks`, hence the JOIN).
- The r18 §404 recipe at L410-425 (queries JOIN tasks on query_id, SUM(physical_input_bytes)/1e9 AS gb_scanned, SUM(split_cpu_time_ms)/1000.0 AS cpu_sec, GROUP BY q.query_id/q."user"/q.source/q.query, ORDER BY gb_scanned DESC LIMIT 20) is CORRECT Trino 467 SQL and IS the right answer to Q1's exact framing.

**Conclusion: this is a responder-reach failure, NOT a resource defect.**

### Responder's landing this iter
- Cited **r27 line 4333** (the §6.7L `query-comment` dbt-model identification example).
- Used `"elapsed.cpu"` as the CPU column on `system.runtime.queries` alone (no JOIN to tasks).
- For BYTES, fell back to: *"you need EXPLAIN ANALYZE instead (not a direct column in system.runtime.queries)... look for physicalInputDataSize."*

This is the **3rd different decoy in 4 iters** (iter1282 r05 tenant-cost, iter1283 r18 L127 myth, iter1284 r27 §6.7L query-comment). Every iter, the responder regenerates the base-training prior "bytes scanned isn't on system tables → EXPLAIN ANALYZE / event listener" REGARDLESS of how the recipe is presented.

### My decision: RECALL-CEILING STOP

**Reasoning**:
1. **Four iters of escalating FIX-As have produced zero movement.** anchors → r05 reconcile → r18 affirmative-first + L127 pointer. The recipe is now at the literal TOP of r18 §404, decorated with ⭐ markup, and the most-magnetic decoy (the L127 myth) explicitly points to it. The responder still didn't reach.
2. **Moving-target pattern means whack-a-mole won't converge.** Three different decoys in four iters (r05 / r18 L127 / r27 §6.7L). A 5th FIX-A targeting r27 §6.7L would just move the responder to a 4th decoy (r18 L395 dedup-frequency, r15, r16-myths, or back to r05 with new keyword routing). The grep shows ~6+ system.runtime.queries mentions across r05/r15/r16-myths/r18-L127/r18-L395/r27-§6.7L, most scoped to their own topic and therefore NOT showing the tasks JOIN — they each function as a decoy when the responder lands there.
3. **Per `feedback_synthesis_ceiling_stop_churning.md`**: "after a FIX-A closes the specific FAIL-causing sub-bug across many re-probes but the responder STILL can't assemble the full hard multi-step query on novel domains, that residual is a Haiku synthesis ceiling NOT a resource gap → STOP churning the defang, accept the occasional Q cost, return to breadth." This is the textbook fit.
4. **Risk of regression on adjacent.** Per `feedback_new_card_over_attracts_adjacent.md`, adding more perf-triage-magnetic decoy pointers risks pulling adjacent dbt-model-identification or query-comment questions into the wrong answer.
5. **A surgical r27 §6.7L pointer would be low-leverage AND low-fit.** The §6.7L section is the dbt-model-identification-via-query-comment canonical — it's intentionally narrow. Adding "for full CPU+bytes ranking JOIN system.runtime.tasks — see r18 §404" there pollutes a clean dbt-side section to chase a moving-target decoy that may not even re-attract next iter.

**Recommended action**:
- **DECLARE recall-ceiling on the perf-triage recipe assembly task.**
- **DOWNGRADE the iter1283-Q1 HARD watch to a periodic SOFT re-probe** (every 8-12 iters, not every iter).
- Accept the occasional Q1-cost on this specific recipe-assembly framing.
- **NO further resource edits to r05/r16/r18/r27 on system.runtime.queries+tasks.** The recipe is correct, prominent, and findable. Continued churning is now negative-EV.
- If the responder cleanly reaches the recipe on a future SOFT re-probe, treat it as a positive datapoint but do not interpret as "the ceiling broke" until ≥2 consecutive clean reaches.

### Why NOT the r27 §6.7L decoy pointer
The teacher asked me to weigh this alternative. I considered the exact text:
> `> For per-query CPU + bytes scanned (the "top heaviest queries" / "what's hammering the cluster" question), the LIVE recipe is queries JOIN system.runtime.tasks on query_id — see resource 18 § "Finding expensive queries on Trino 467". The query-comment example here uses ONLY queries.elapsed.cpu, which is dbt-model-identification scope, NOT perf-triage scope.`

This is technically the right surgical pointer for **this iter's specific decoy**. But:
- It does not address iter1282's decoy (r05 tenant-cost) or iter1283's decoy (r18 L127 — which already has a pointer).
- The moving-target pattern strongly predicts a 4th decoy next iter.
- Each pointer dilutes its host section's scope coherence.
- The §6.7L section's primary keyword path is `dbt model behind a query / node_id / query-comment / model.unique_id` — NOT `top queries by CPU and bytes`. A perf-triage pointer there is off-topic for the section's own consumers.

**Net: the marginal expected benefit of a 5th FIX-A is below the marginal regression risk.** STOP.

---

## Q3 — `delete+insert` responder slip (confirmed)

**Responder claim**: *"delete+insert — Not a built-in dbt strategy; you'd write it manually."*

**Resources teach the correct fact**:
- `resources/27-oracle-plsql-to-dbt-trino.md` §3.2 L322-326: third row of the strategy table is `delete+insert` with the exact SQL emitted (`DELETE FROM target WHERE <unique_key> IN (SELECT <unique_key> FROM source); INSERT INTO target SELECT ... FROM source`).
- `resources/27-oracle-plsql-to-dbt-trino.md` L300: incremental materialization line lists strategies as `append / merge / delete+insert / microbatch`.
- `resources/28-complex-sql-performance-trino-dbt.md` L402: *"valid `incremental_strategy` values for dbt-trino are `append` (default), `delete+insert`, and `merge` per [docs.getdbt.com/reference/resource-configs/trino-configs](https://docs.getdbt.com/reference/resource-configs/trino-configs)."*
- `resources/28-complex-sql-performance-trino-dbt.md` L1679 + L1692: shows `incremental_strategy='delete+insert'` as a partition-replace pattern.

**Verified via WebFetch this iter** at [docs.getdbt.com/reference/resource-configs/trino-configs](https://docs.getdbt.com/reference/resource-configs/trino-configs): dbt-trino supports `append` (default), `delete+insert`, and `merge`. Verbatim doc snippet: *"With the `delete+insert` incremental strategy, you can instruct dbt to use a two-step incremental approach. First, it deletes the records detected through the configured `is_incremental()` block, then re-inserts them."*

**Classification**: RESPONDER SLIP on correct + findable content. NOT a resource defect. NOT a recall-volatility on a known-confusing edge — the strategy is plainly listed in r28's leading canonical AND in the r27 §3.2 strategy table the responder cites elsewhere.

**Fits `feedback_responder_broken_secondary_alternative.md` family** — append + merge primaries were correctly described; the broken claim was on the third strategy as a "for completeness" item. Pattern matches the 8th+ instance of broken-secondary-alternative.

**Recommendation**: NO FIX. Per-instance per `feedback_synthesis_ceiling_stop_churning.md` (and the existing strong-canonical state at r27 §3.2 + r28 L402, additional defang would dilute, not strengthen). Soft watch only.

---

## Q2 — above-group-average (clean PASS, verified)

Lead: `AVG(amount) OVER (PARTITION BY account_id) AS account_avg` then `WHERE amount > account_avg` (via a CTE or subquery wrap, since you can't reference window expressions directly in WHERE).

Trino 467 verified: aggregate-as-window function syntax is supported per [trino.io/docs/467/functions/window.html](https://trino.io/docs/467/functions/window.html). The CTE pattern is idiomatic.

Correlated-subquery framing is correct: Trino's optimizer decorrelates many correlated subqueries (UnnestCorrelatedFilter / DecorrelateUnnestRule), so the form is *not necessarily* slow as folklore implies. Responder's "verify via EXPLAIN, watch for CorrelatedJoin in the plan" is sound advice — this is the right way to check whether decorrelation kicked in.

Minor Compl shave (-0.25): didn't mention that the window form is **one scan** vs the correlated-subquery's potential decorrelation-to-self-join cost (one extra hash join). Not load-bearing.

**Scores**: Acc 5.0 / Clar 5.0 / Prac 4.75 / Compl 4.75 = **4.875**.

---

## Q4 — Oracle TO_CHAR/TO_DATE + `||` concat → Trino (clean PASS, verified)

All three claims verified:
1. **TO_CHAR(date, mask)** — Trino 467 does NOT have Oracle/Postgres-style `TO_CHAR(date, 'YYYY-MM-DD')`. Use `date_format(ts, '%Y-%m-%d')` (MySQL-style codes) or `format_datetime(ts, 'yyyy-MM-dd')` (Joda-style codes). Per `reference_trino_to_char_exists.md` memory pin: Trino DOES have a `to_char(timestamp, format)` Teradata-compat overload, but it accepts ONLY lowercase numeric format codes (`dd/hh/mi/mm/ss/yyyy/yy`) — uppercase masks fail, month names not supported. Responder surfaced this caveat correctly.
2. **TO_DATE(s, mask)** — Trino has no Oracle `TO_DATE`. The pattern is `CAST(date_parse(s, '%Y-%m-%d') AS DATE)` (MySQL-style) or `CAST(parse_datetime(s, 'yyyy-MM-dd') AS DATE)` (Joda); `from_iso8601_date('2024-01-15')` works for ISO-8601. Responder gave all three. Verified at [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html).
3. **`'Invoice #' || number`** — FAILS in Trino. `||` is the `concat` operator overloaded only for varchar in Trino 467 (no implicit numeric coercion). Fix: `'Invoice #' || CAST(invoice_number AS VARCHAR)` or `format('Invoice #%s', invoice_number)`. Verified at [trino.io/docs/467/functions/string.html](https://trino.io/docs/467/functions/string.html).

**Scores**: Acc 5.0 / Clar 5.0 / Prac 5.0 / Compl 4.75 = **4.9375** (minor Compl shave: didn't mention `format('Invoice #%05d', n)` for zero-padded display masks).

---

## Watches

**Watches CLOSING with directional change**:
- **iter1283-Q1 perf-triage HARD watch** → **DOWNGRADE to periodic SOFT re-probe** (every 8-12 iters). 4-iter escalation produced zero movement; declaring recall-ceiling per `feedback_synthesis_ceiling_stop_churning.md`. The recipe is correct + prominently placed at r18 §404; further FIX-As are negative-EV.

**NEW soft watches**:
- **iter1284-Q3 `delete+insert`-not-built-in responder slip** — re-probe under "dbt-trino incremental strategies / delete+insert / when to use which" framings 6-10 iters. Resources r27 §3.2 + r28 L402 are CORRECT; this is recall-variance on a present canonical, NO FIX. If recurs ≥2 more times within 10 iters under explicit dbt-trino-strategy framings, reconsider — but expect ceiling not gap.

**Open watches (carry-forward)**:
- iter1281-Q2 UNNEST; iter1278-Q1 Scheduled-vs-CPU; iter1279-Q4 now(); iter1280-Q1 partition-Spark; iter1280-Q2 DECIMAL-scale; iter1264-Q3 hard_deletes-dbt-trino-adapter-caveat; iter1260-Q1 CDC-MERGE-multi-event-dedup; iter1258-Q3 SELECT-*-EXCEPT; iter1255-Q1 bloom-CREATE-syntax; iter1253-Q4 regexp_extract-2arg; iter1248-Q3 MATCH_RECOGNIZE-adjacency; iter1230 EXISTS-overwarning/::cast; iter1229 @v1-Spark; iter1215 strpos-3-arg CEILING.

---

## Pattern observation

iter1284 is the **4th consecutive iter** of NON-REACH on the perf-triage queries-JOIN-tasks recipe. The trajectory is clear:
- iter1281: partial reach with hedge ("columns not documented")
- iter1282: full hedge → 2-part FIX-A (r05 reconcile + r18 affirmative-first hoist + L127 pointer)
- iter1283: full hedge again → escalation: affirmative-first + L127 pointer LANDED but responder still didn't reach
- iter1284: still didn't reach; this time landed at a 3rd different decoy (r27 §6.7L)

The responder regenerates the base-training "bytes scanned aren't in system tables → use EXPLAIN ANALYZE" prior regardless of how prominently the recipe is presented. This is the same pattern as `feedback_synthesis_ceiling_stop_churning.md` calls out for gaps-and-islands streak-construction (iter951-956). **Declaring recall-ceiling and stopping the churn is the right call.**

Q3's `delete+insert`-not-built-in slip is the latest instance of the broken-secondary-alternative family (`feedback_responder_broken_secondary_alternative.md`). Resources are correct; recall variance is the ceiling. NO FIX.

Q2 + Q4 are clean STRONG PASSES with source-verified accuracy, confirming the responder reaches correctly on idiomatic Trino window functions and Oracle→Trino mask-mapping under matched-prior keyword routing.

**Training in closing window** (deadline 2026-06-30 23:59 CST; ~14 hours remaining). The right end-of-training posture for the perf-triage recipe is **accept the ceiling, stop churning, preserve the bulletproofed clean topics**. Recommendation = **NO-OP** on resources for iter1285 (no FIX-A on either Q1 or Q3); commit rubric + feedback only; downgrade Q1 watch to periodic SOFT re-probe.

---

## Sources
- [trino.io/docs/467/connector/system.html](https://trino.io/docs/current/connector/system.html) — system.runtime.* table catalog (Trino 467 ships system connector)
- [raw.githubusercontent.com/trinodb/trino/467/.../TaskSystemTable.java](https://raw.githubusercontent.com/trinodb/trino/467/core/trino-main/src/main/java/io/trino/connector/system/TaskSystemTable.java) — verified `system.runtime.tasks` exposes `query_id`, `physical_input_bytes`, `split_cpu_time_ms`
- [docs.getdbt.com/reference/resource-configs/trino-configs](https://docs.getdbt.com/reference/resource-configs/trino-configs) — verified dbt-trino supports `append` / `delete+insert` / `merge` as built-in `incremental_strategy` values
- [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/current/functions/datetime.html) — `date_format` / `format_datetime` / `date_parse` / `from_iso8601_date`
- [trino.io/docs/467/functions/string.html](https://trino.io/docs/current/functions/string.html) — `concat` / `||` varchar-only, `format()` printf-style
- [trino.io/docs/467/functions/window.html](https://trino.io/docs/current/functions/window.html) — aggregate-as-window for `AVG(x) OVER (PARTITION BY ...)`
