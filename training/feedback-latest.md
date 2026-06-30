# Judge Feedback — Iteration 1289

**Overall**: 4 questions, average **3.547 BARELY PASS** (Q1 4.6875 PASS / Q2 4.5 PASS / Q3 **1.5 FAIL** / Q4 3.5 BORDERLINE).

**Headline**: Q3 (dbt ephemeral models — "temp table or view, downsides?") is a **HARD FAIL: responder HEDGED with "resources don't cover detailed dbt materialization docs"** when grep confirms r28 §3.3 (L940-983, LEADING CANONICAL — "what's the difference between view and ephemeral in dbt" question-shape) + §3.3A (L1021-1083, "the REAL ephemeral-at-scale failure mode — compile-time SQL bloat") + r27 §3.1 (L301 ephemeral table row, L314 cross-ref to r28 §3.3A) carry rich, question-shape-anchored coverage that EXACTLY matches Q3's phrasing. **Pure findability miss** — content is THERE, responder did not route. Q4 has a responder-INVENTED false "DIFFERENCE FROM ORACLE" framing — Oracle LPAD/RPAD truncate identically to Trino, verified via Oracle docs ([techonthenet LPAD](https://www.techonthenet.com/oracle/functions/lpad.php), [oratutorial LPAD](https://www.oracletutorial.com/oracle-string-functions/oracle-lpad/)) — the engineer's exact sub-question "same behavior when string is longer?" → correct answer is YES SAME, responder said NO DIFFERENT. Q1 + Q2 PASS cleanly with minor flags.

| Q | Topic | Score | Status | Verdict |
|---|---|---|---|---|
| Q1 CASE-bucket tiers + HAVING | Analytical query patterns on Iceberg+Trino | **4.6875** | PASS | Query CORRECT; redundant `HAVING COUNT(*) > 0` framed as the filtering mechanism (a CASE-based GROUP BY never emits empty buckets — HAVING is a no-op) — minor Clar ding |
| Q2 position vs equality deletes | Iceberg table maintenance | **4.5** | PASS | Definitions correct (file_path+row_position vs col-value tuples); content=1/2 correct; CoW default + MoR accumulation correct; $files diagnostic correct; **MISSED Trino-native `ALTER TABLE EXECUTE optimize` for clearing position-deletes** (recommended ONLY Spark `rewrite_position_delete_files`) — Spark-leaning miss against pin `reference_trino_optimize_clears_position_deletes` |
| Q3 dbt ephemeral models | Improving complex SQL perf on Trino with dbt | **1.5** | **FAIL** | Hedged "resources don't cover dbt materialization" — FALSE. r28 §3.3 + §3.3A + r27 §3.1 all have rich question-shape-anchored ephemeral content. Pure findability miss |
| Q4 Oracle LPAD/RPAD → Trino | Oracle PL/SQL → dbt+Trino migration | **3.5** | BORDERLINE | lpad/rpad exist + same arg order + CAST needed + format('%08d') safe alt — all correct. **FALSE "critical DIFFERENCE from Oracle" on truncate-when-longer** — Oracle LPAD/RPAD ALSO truncate to first N chars (verified Oracle docs). Responder-invented divergence on the EXACT sub-question asked |

---

## Q1 — CASE-bucket tiers + HAVING (4.6875 PASS)

**Acc 4.5 / Clar 4.5 / Prac 5.0 / Compl 4.75.**

Query shape correct: same CASE expression in SELECT + GROUP BY, COUNT(*) + SUM(revenue), ORDER BY. Engineer can copy-paste and it works on Trino 467.

**Minor flag — redundant HAVING explanation.** Responder added `HAVING COUNT(*) > 0` and framed it as the mechanism that filters out empty tier buckets. This is misleading:
- A `GROUP BY` on a CASE expression only emits groups for rows that EXIST in the source. If zero customers fall in `<500`, the "small" bucket is simply absent from the output — it cannot be "filtered out" because it was never produced.
- `HAVING COUNT(*) > 0` is therefore a no-op in this construction; every group emitted by `GROUP BY <CASE>` already has `COUNT(*) >= 1`.
- The "only tiers with customers" requirement is satisfied AUTOMATICALLY by the GROUP-BY-CASE shape — no HAVING needed.

The engineer's takeaway is still correct (the result has no empty buckets) but they walk away with a wrong mental model (thinking they need HAVING to suppress them). Minor Clar/Acc shave only.

**Action**: per-instance phrasing slip, NO resource fix. No card mis-teaches this — pure responder framing miss. Watch under "tier bucketing / CASE GROUP BY / HAVING" framings for 4-6 iters; only escalate if it recurs.

---

## Q2 — Position vs equality deletes (4.5 PASS)

**Acc 4.5 / Clar 4.75 / Prac 4.25 / Compl 4.5.**

Definitions accurate and matched to verified sources:
- Position deletes = (file_path, row_position) pairs — verified per [olake.io MoR vs CoW](https://olake.io/iceberg/mor-vs-cow/) + [Dremio CoW vs MoR](https://www.dremio.com/blog/row-level-changes-on-the-lakehouse-copy-on-write-vs-merge-on-read-in-apache-iceberg/).
- Equality deletes = column-value tuples with predicate semantics — verified per [RisingWave equality-delete problem](https://risingwave.com/blog/the-equality-delete-problem-in-apache-iceberg/).
- `$files.content` = 0 (data) / 1 (position-delete) / 2 (equality-delete) — correct per Iceberg spec + Trino metadata-table docs.
- CoW default; MoR opt-in via `write.delete.mode='merge-on-read'` — correct.
- "MoR accumulates many small delete files → applied at read time → slows queries" — correct, this is the textbook MoR cost.

**Flag — Spark-leaning maintenance, missed Trino-native path.** Responder's compaction recommendation was ONLY the Spark route: `CALL iceberg.system.rewrite_position_delete_files()`. On this on-prem Trino-467 + Spark-Iceberg-1.5.2 stack, the **Trino-native `ALTER TABLE ... EXECUTE optimize(file_size_threshold => '256MB')`** also APPLIES and clears position-delete files for the data files it rewrites — per pinned `reference_trino_optimize_clears_position_deletes.md` (PR [trinodb/trino #12617](https://github.com/trinodb/trino/issues/12617), [#24086](https://github.com/trinodb/trino/issues/24086), candidate selection is SIZE-only so raise threshold above the largest delete-bearing data files). The user explicitly asked about "Spark ingestion + how we do updates/deletes" so leaning Spark is reasonable, but on this stack a Trino-only maintenance loop (run optimize from a dbt macro or cron, no Spark job needed for compaction) is the simpler operational answer.

**Action**: per-instance Spark-leaning recall slip, NO resource fix (r17 + r13 §2862 + r28 §297 already document the Trino-native path). **SOFT WATCH `iter1289-Q2 position-delete maintenance Spark-vs-Trino-EXECUTE-optimize routing`** — re-probe in 4-8 iters under "position-deletes accumulating / how do I compact them" framings WITHOUT Spark-leading hint; if Trino-native EXECUTE optimize is again omitted under non-Spark framings, escalate to LIGHT FIX-A adding a Trino-native lead at the position-delete-maintenance keyword zone.

---

## Q3 — dbt ephemeral models (1.5 FAIL)

**Acc 1.0 / Clar 3.0 / Prac 1.0 / Compl 1.0.**

Responder said: "I don't have enough information; resources cover Spark ingestion / Iceberg maintenance / Trino querying but NOT detailed dbt materialization docs... consult dbt docs."

**This is FALSE.** Grep CONFIRMS rich, question-shape-anchored ephemeral content in resources:

1. **r28 §3.3 (L940-983)** — LEADING CANONICAL "the dbt materialization COST MODEL (storage + runtime + DB object)" with explicit question-shape anchors at L946: *"what's the difference between `view` and `ephemeral` in dbt", "what database object does each dbt materialization create", "dbt view vs ephemeral at scale"*. Includes the four-row table (view / table / incremental / ephemeral × DB object / storage / re-run / DDL) with the ephemeral row reading: *"NONE — no warehouse object at all... The SELECT is inlined as a CTE into every downstream model that ref()s it — at dbt COMPILE time, before any SQL is sent to Trino."* This EXACTLY answers the engineer's "temp table or view?" sub-question.

2. **r28 §3.3A (L1021-1083)** — LEADING CANONICAL "the REAL ephemeral-at-scale failure mode — compile-time SQL bloat" with question-shape anchors at L1025: *"what's the problem with `ephemeral` at scale", "does `ephemeral` slow down dbt", "ephemeral vs view at scale"*. Includes the 5-step worked example (5 downstream models × 80-line ephemeral = 400 lines duplicated SQL → planner re-parses 5×), transitive-ephemeral compounding warning, no-debuggable-object enumeration (no `SELECT COUNT(*)`, no Trino UI per-query, no GRANT, no SHOW STATS), and a threshold rule of thumb. This EXACTLY answers the engineer's "any downsides?" sub-question.

3. **r27 §3.1 (L292-316)** — the materialization-decision table with a full ephemeral row (DB object NONE, storage Zero, compile-time inlining mechanism, "use for 1-2 downstreams", "do NOT use for 3+ downstreams — compile-time bloat") + L314 cross-ref to r28 §3.3A.

**Classification**: pure FINDABILITY MISS. The content is fully in place; the responder failed to route. Likely root cause is that r28's title ("Improving complex SQL performance on Trino with dbt") does not lexically lead from a basic dbt-101 "what is ephemeral" question, and r27 §3 title ("dbt-trino: the materialization-strategy choice for migrated procedures") is similarly Oracle-migration-framed.

### FIX-A decision — **LIGHT FIX-A RECOMMENDED**

The question "what does ephemeral do differently? temp table or view? any downsides?" is a fundamental dbt-101 ask any engineer touching the lakehouse will hit. The fact that the responder hedged with a confidently-wrong "we don't cover this" disclaimer is worse than a partial answer — it teaches the engineer the resource doesn't exist.

**Recommended action** (teacher's call on exact placement):
- **Option A (preferred)**: Add a short standalone leading canonical at the **top of r27 §3** (right after the section header, BEFORE §3.1's decision table) with keyword anchors *"what is dbt ephemeral", "is ephemeral a temp table or a view", "ephemeral materialization explained", "what does ephemeral do differently", "ephemeral vs view in dbt", "downsides of ephemeral"* + a 2-sentence answer (NOT a table, NOT a temp table, NOT a view — NO warehouse object; SELECT is inlined as a CTE at compile time into every downstream's compiled SQL) + cross-ref to r28 §3.3 + §3.3A for the full canonical. This puts the answer where the basic "ephemeral" keyword zone lives (r27 §3 is the materialization-strategy section, more findable than r28).
- **Option B (alternative)**: Add an explicit r28 §3.3 keyword anchor block at the top of the LEADING CANONICAL extending the question-shape list with the basic framings: *"what does ephemeral materialization do", "is ephemeral a view in dbt", "ephemeral vs temp table", "downsides of using ephemeral models"* — these basic-dbt-101 phrasings are missing from L946's current list.

Both options together would be belt-and-suspenders.

**Watch**: NEW HARD WATCH `iter1289-Q3 dbt ephemeral basics findability` — re-probe within 2-4 iters under varied "what is ephemeral / temp table or view / downsides of ephemeral" framings; if 2+ recurrences after FIX-A, this is a deeper r28-title-discoverability issue and not just an anchor gap.

---

## Q4 — Oracle LPAD/RPAD → Trino (3.5 BORDERLINE)

**Acc 2.5 / Clar 4.0 / Prac 4.0 / Compl 3.5.**

**Correct portions**:
- Trino HAS lpad/rpad — correct, per [trino.io/docs/467/functions/string.html](https://trino.io/docs/current/functions/string.html).
- Same arg order `(string, size, padstring)` — correct.
- `CAST(account_id AS VARCHAR)` needed (Trino has no implicit number→string coercion in lpad/rpad) — correct, matches r27 L998 + r23 §716 canonical.
- `format('%08d', account_id)` never truncates, safer for over-width ids — correct, matches r23 §754.
- Trino lpad/rpad truncate when source is longer than n — correct, verified via [trino.io string-functions docs](https://trino.io/docs/current/functions/string.html).

**ACCURACY ERROR — false invented "CRITICAL DIFFERENCE from Oracle"**:
Responder framed the truncate-when-longer behavior as a "CRITICAL DIFFERENCE between Trino and Oracle" — implying Oracle LPAD/RPAD do NOT truncate.

**Verified Oracle behavior** ([techonthenet LPAD](https://www.techonthenet.com/oracle/functions/lpad.php), [oratutorial LPAD](https://www.oracletutorial.com/oracle-string-functions/oracle-lpad/), [techonthenet RPAD](https://www.techonthenet.com/oracle/functions/rpad.php), [orafaq LPAD/RPAD](https://www.orafaq.com/wiki/LPAD_and_RPAD)):
> "If the padded_length is smaller than the original string, the LPAD function will truncate the string to the size of padded_length... LPAD effectively truncates string1 — it returns only the first padded_length characters of the incoming string1." Same for RPAD.

So **Oracle LPAD/RPAD truncate identically to Trino's** — the behavior is the SAME, NOT a divergence. The engineer's sub-question "same behavior when string already longer than target width?" → correct answer is **YES, both Oracle and Trino truncate to first N chars**. Responder said NO, different — directly mis-answers the asked sub-question.

The truncation HAZARD is real and worth flagging — an Oracle engineer who's been writing `LPAD(account_id, 10, '0')` for 20 years on a column that may exceed 10 chars HAS been silently losing data the whole time. But that's a Trino-and-Oracle-share-this-trap point, not a Trino-introduces-a-new-trap point. The framing matters: the Oracle engineer who already knows their LPAD truncates is being told (incorrectly) that they need to RELEARN this for Trino, when the behavior is identical.

**Resource check**: r23 §716-758 and r27 L998 BOTH correctly describe the truncation hazard WITHOUT claiming Oracle divergence. r23 §721 reads "lpad/rpad pad OR TRUNCATE to EXACTLY `size` characters" — describes Trino-side behavior, doesn't compare to Oracle. r27 L998 LPAD/RPAD migration row mentions only the CAST-VARCHAR difference (the real divergence) — doesn't claim Trino-vs-Oracle truncate divergence.

**This is a responder-INVENTED false divergence** (matches `feedback_responder_overwarning_folklore.md` family — over-warning about a non-difference). Resources are CORRECT.

**FIX-A decision — NO FIX**: per-instance responder slip. Adding an Oracle-truncate-same-as-Trino defang to r23 §716 risks over-attracting an adjacent question per `feedback_new_card_over_attracts_adjacent.md`. 1st instance of this exact false-divergence framing on lpad/rpad.

**Watch**: NEW SOFT WATCH `iter1289-Q4 Oracle-LPAD/RPAD truncate-same-as-Trino false-divergence framing` — re-probe under Oracle-migration framings ("does Trino lpad behave like Oracle LPAD when source longer than width") within 4-8 iters; if 2+ recurrences, consider a LIGHT FIX-A at r27 L998 lpad/rpad row adding *"Truncation behavior is IDENTICAL to Oracle's — both pad-OR-truncate to exactly `n`. The only Trino-specific change is the no-implicit-numeric-coercion CAST requirement."*

---

## Summary of FIX-As and watches

| Action | Q | Where | Priority |
|---|---|---|---|
| **LIGHT FIX-A** | Q3 | r27 §3 (top, before §3.1 decision table) — add 2-sentence ephemeral-basics canonical with question-shape anchors (Option A); OR extend r28 §3.3 L946 keyword anchor list with basic dbt-101 framings (Option B); BOTH preferred | **MANDATORY** (hard fail) |
| NEW HARD WATCH | Q3 | `iter1289-Q3 dbt ephemeral basics findability` — re-probe 2-4 iters, varied "what is ephemeral / temp table or view" framings | High |
| NEW SOFT WATCH | Q2 | `iter1289-Q2 position-delete maintenance Spark-vs-Trino-EXECUTE-optimize routing` — re-probe 4-8 iters under non-Spark framings; if Trino-EXECUTE optimize omitted again, LIGHT FIX-A | Medium |
| NEW SOFT WATCH | Q4 | `iter1289-Q4 Oracle-LPAD/RPAD false-divergence framing` — re-probe 4-8 iters; if 2+ recurrences, LIGHT FIX-A at r27 L998 | Medium |
| Per-instance watch | Q1 | Redundant `HAVING COUNT(*) > 0` framing in CASE-GROUP-BY — minor clarity-only, re-probe 4-6 iters under tier-bucketing framings | Low |

**Carry watches from prior iterations** (per state.json iter1288):
- `iter1288-Q1 COUNT(*)-slow metadata-only + delete-files canonical reach-test` — HARD WATCH (not probed this iter)
- `iter1285-Q2 timestamp-tz` — carry
- `iter1283-Q4 strpos-3-arg` — carry
- `iter1284-Q3 delete+insert` — carry
- `iter1283-Q3 hard_deletes` — carry
- `perf-triage-recall-ceiling periodic SOFT` — carry

**All required topics remain PASSED**; thinnest topic (Query performance basics 4.1701) untouched this iter. The Q3 FAIL drops "Improving complex SQL performance on Trino with dbt" from 4.4856/88 to **4.4521/89** — still comfortably above 3.5 threshold, margin +0.9521.
