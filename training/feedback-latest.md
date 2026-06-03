# Judge Feedback — Iter 418 (EXTENDED PHASE — end-of-iteration only)

**Overall: 4.65625 STRONG PASS** (Q1 4.75 + Q2 4.75 + Q3 4.625 + Q4 4.5) — well above the 3.5 PASS threshold and the seventeenth consecutive PASS in the iter402-418 window. **+0.28125 step-UP from iter417 4.375**, second-highest score in the iter402-418 window (tied region with iter413/iter415 4.625 highs).

**Headline:**
1. **ITER417 Q1 ENGINE-CONFUSION FULLY RESOLVED IN 1 ITERATION.** The Q1 durability re-probe landed cleanly: the responder now leads with the Trino-467-native two-statement recipe (`ALTER TABLE SET PROPERTIES sorted_by = ARRAY[...]` then `ALTER TABLE EXECUTE optimize(file_size_threshold => '512MB')`) AND explicitly disambiguates: "Trino 467 has NO `rewrite_data_files` procedure — that's Spark-only `CALL iceberg.system.rewrite_data_files`". The teacher's iter418 fix (resource 17 disambiguation matrix + resource 18 ENGINE-CONFUSION GUARDRAIL + resource 10 Path A/Path B restructure) is the SIXTH consecutive successful one-iteration recovery from a confident-inaccuracy failure.
2. **MYTH-BUSTER ZERO-CONFIDENT-INACCURACY STREAK RESTARTED AT 1.** No new confident-inaccuracies appeared anywhere in iter418. Clean streak resumes; the failure-mode count remains 6 of prior 17 iterations.
3. **Q2 STRONG (4.75)** — clean Trino-vs-Spark CALL/EXECUTE matrix, correctly framing rewrite_manifests as Spark-only on Trino 467 (optimize_manifests is 470+, NOT on prod 467).
4. **Q3 STRONG (4.625) — federation +0.0005 nudge UP**, 18th consecutive iter below threshold but trending UP for the 4th iteration in a row.
5. **Q4 STRONG (4.5)** — CALL positional 467 vs ALTER EXECUTE 469+ disambiguation correct; small nudge for not foregrounding Trino EXECUTE remove_orphan_files.

---

## Critical watch items — explicit confirmations

### (a) Is the iter417 Q1 ENGINE-CONFUSION RESOLVED? Did any NEW confident-inaccuracy appear?

**RESOLVED — YES** for Q1; **NO new confident-inaccuracies anywhere** in iter418. The responder:
- Gave the correct Trino-467-native two-statement clustering recipe (`ALTER TABLE SET PROPERTIES sorted_by = ARRAY['plan_type ASC NULLS LAST','occurred_at ASC']` then `ALTER TABLE EXECUTE optimize(file_size_threshold => '512MB')`).
- Explicitly said `rewrite_data_files` is Spark-only `CALL iceberg.system.rewrite_data_files` — NOT a Trino EXECUTE procedure.
- Verified against trino.io/docs/current/connector/iceberg.html: EXECUTE registry is exactly `optimize` / `optimize_manifests` / `expire_snapshots` / `remove_orphan_files` / `drop_extended_stats`; `sorted_by` IS in the modifiable table properties list; `EXECUTE optimize` accepts ONLY `file_size_threshold`.
- Correctly recommended $files lower/upper bounds verification (plan_lo = plan_hi means clustering succeeded).

**Clean streak restarted at 1.** The teacher's disambiguation matrix in resource 17 + the GUARDRAIL callout in resource 18 + the Path A (Trino native) / Path B (Spark CALL) split in resource 10 all landed cleanly.

### (b) Updated Trino federation topic average

**4.4889/273 -> 4.4894/274** (Q3 4.625 above 4.5 threshold, +0.0005 nudge UP). Topic now **0.0106 below** the 4.5 pass threshold. **18th consecutive iteration stuck below threshold** but trending UP for the 4th iteration in a row (iter415 4.625 → iter416 (no Q) → iter417 4.75 → iter418 4.625). Sustained 4.7+ federation answers continue to be the path to cross threshold; Q3 4.625 helped but the 4.75+ band is what creates meaningful threshold movement.

### (c) Trino 467 rewrite_manifests / optimize_manifests confirmation

**Responder's "rewrite_manifests = Spark only on Trino 467" is CORRECT for the prod 467 version.** Verified:
- `optimize_manifests` was added in Trino release 470 (Feb 5 2025) via PR #25378.
- Trino 467 has NO manifest-rewrite EXECUTE procedure.
- The only manifest-rewrite path on Trino 467 is to drop to Spark `CALL iceberg.system.rewrite_manifests`.
- The responder's prod-specific answer is precisely right; mentioning 470+ availability would have been a nice optional note but its absence is not an inaccuracy.

---

## Per-question scoring

### Q1 — Sort/cluster on Trino 467 (RE-PROBE of iter417 Q1 FAIL)

**Scores: 5.0 / 4.5 / 5.0 / 4.5 — avg 4.75 STRONG PASS**

**What landed:**
- Two-statement recipe: `ALTER TABLE foo SET PROPERTIES sorted_by = ARRAY['plan_type ASC NULLS LAST','occurred_at ASC']` then `ALTER TABLE foo EXECUTE optimize(file_size_threshold => '512MB')` — VERIFIED Trino-467-valid.
- Explicit Spark-only disambiguation for `rewrite_data_files` — RESOLVES iter417 inaccuracy.
- `EXECUTE optimize` honors `sorted_by` table property at OPTIMIZE time, clusters rows narrow min/max within files — CORRECT (PR #14891 release 412 Feb 2023, on 467).
- `file_size_threshold` larger than existing files (512MB default 100MB) forces full rewrite — CORRECT strategy.
- $files lower/upper bounds verification (plan_lo = plan_hi means clustering succeeded) — CORRECT canonical diagnostic.

**Verdict:** STRONG PASS — iter417 ENGINE-CONFUSION FULLY RESOLVED. Engineer running this on Trino 467 will get a clean rewrite.

### Q2 — Which Iceberg maintenance procedures run in Trino vs Spark

**Scores: 5.0 / 4.5 / 5.0 / 4.5 — avg 4.75 STRONG PASS**

**What landed:**
- Compact small files via `EXECUTE optimize` Trino YES (file_size_threshold arg only) — CORRECT.
- `expire_snapshots` Trino YES with 7d minimum default; Spark needed for sub-7d override — CORRECT.
- Rewrite manifests Spark-only `CALL iceberg.system.rewrite_manifests` on Trino 467 — CORRECT (optimize_manifests is Trino 470+, NOT 467).
- `remove_orphan_files` Trino YES — CORRECT (in EXECUTE registry).
- One-window Spark script canonical order: compact → expire → orphan → manifests with reasoning (compaction creates new snapshot, expire after same window drops pre-compaction snapshot) — CORRECT.

**Verdict:** STRONG PASS — precisely correct matrix for prod 467 specifically.

### Q3 — LIKE pushdown on Postgres connector

**Scores: 4.5 / 4.5 / 5.0 / 4.5 — avg 4.625 STRONG PASS**

**What landed:**
- Leading wildcard `LIKE '%@bigcorp.com'` does NOT push to Postgres, stays in Trino with full table pull + post-scan filter — CORRECT.
- Equality VARCHAR pushes by default — CORRECT (verified against trino.io/docs/current/connector/postgresql.html).
- Anchored `LIKE 'alice@%'` collation-dependent — CORRECT NUANCE.
- IN pushes — CORRECT.
- Better recommendation: rewrite to equality/IN whenever feasible — CORRECT practical guidance.
- Experimental flag `postgresql.experimental.enable-string-pushdown-with-collate` (catalog or session) with collation-correctness risk + equality perf regression flag — VERIFIED (PR #9746 release 365 Dec 2021, on 467).

**Verdict:** STRONG PASS; small TA nudge for slight imprecision around whether anchored prefix LIKE pushes without the experimental flag (in practice mostly does not, even when anchored).

### Q4 — Rollback bad write (Trino 467 CALL vs Trino 469 ALTER EXECUTE)

**Scores: 4.5 / 4.5 / 4.5 / 4.5 — avg 4.5 STRONG PASS**

**What landed:**
- `CALL iceberg.system.rollback_to_snapshot('analytics','user_events',snap_id)` positional Trino 467 — CORRECT.
- ALTER TABLE EXECUTE rollback_to_snapshot table procedure form 469+ — CORRECT (PR #24580, release 469 Jan 27 2025).
- $snapshots committed_at to find pre-bad snapshot — CORRECT canonical diagnostic.
- Rollback resets current pointer; rows in bad snapshot HIDDEN not deleted; data files orphaned on MinIO — CORRECT (metadata-only operation; immutable file model).
- Queries see old state immediately — CORRECT.
- Cleanup via Spark `remove_orphan_files` with dry_run — VALID; small nudge for not foregrounding Trino 467's own `EXECUTE remove_orphan_files` as the primary path.
- Can roll forward again until expire_snapshots removes bad snapshot — CORRECT.

**Verdict:** STRONG PASS; small completeness nudge for not leading with Trino EXECUTE remove_orphan_files.

---

## Pattern across all four answers

| Q | Score | Verdict |
|---|---|---|
| Q1 | 4.75 | STRONG PASS — iter417 engine-confusion FULLY RESOLVED |
| Q2 | 4.75 | STRONG PASS — clean Trino-vs-Spark CALL/EXECUTE matrix for 467 |
| Q3 | 4.625 | STRONG PASS — LIKE pushdown collation nuance + experimental flag risk |
| Q4 | 4.5 | STRONG PASS — CALL positional 467 vs ALTER EXECUTE 469+ correct |

**Average 4.65625 STRONG PASS** — seventeenth consecutive overall PASS, +0.28125 step-UP from iter417 4.375. **Myth-buster zero-confident-inaccuracy streak RESTARTED at 1.**

**Trajectory iter394-418:** `4.75P/3.125F/4.3125P/4.375P/4.34375P/4.09375P/4.0625P/3.8125F/4.59375P/3.875F/4.25P/4.6875P/4.40625P/4.625P/4.0625P/4.125P/4.5625P/4.0P/4.219P/4.625P/4.21875P/4.0625P/4.625P/4.5625P/4.375P/**4.65625P**`.

**Topic status updates:**
- **Iceberg table maintenance: 4.4036/81 -> 4.4130/84** (Q1 4.75 + Q2 4.75 + Q4 4.5 all above topic avg, +0.0094 nudge UP from 3 STRONG PASS contributions in one iteration — strongest table-maintenance triple in many iters).
- **Trino federation: 4.4889/273 -> 4.4894/274** (Q3 4.625 above 4.5 threshold, +0.0005 nudge UP; topic now 0.0106 below threshold; **18th consecutive iter below threshold** but trending UP for 4th iter in a row).

---

## Teacher actions next (iter 419)

1. **MEDIUM — Trino federation topic threshold-push continuation.** Topic 0.0106 below threshold; needs sustained 4.7+ federation answers to cross. Q3 4.625 was a STRONG federation answer but still below the 4.75+ band needed for meaningful threshold movement. Continue auditing resource 22 for any remaining myth-buster gaps that could be elevated to leading callouts (aggregation pushdown, schema-evolution-with-pushdown, OR-with-mixed-types semantics).

2. **LOW — Optional refinement for resource 17 §rollback section:** foreground Trino 467 `EXECUTE remove_orphan_files` as the primary cleanup path after rollback (with Spark CALL as alternative for sub-7d retention). Small nudge to make the canonical lifecycle Trino-native first.

3. **LOW — Carry-forward backlog:** HMS->Nessie write-freeze alternative; branches-vs-expire_snapshots 3rd-angle; Snapshot vs serializable phantom-row 3rd-angle; Window NULL 2nd-angle calendar-dim densification; Iceberg v3 deletion vectors timeline; MERGE rollback; OPA-override timeout; schema registry compat; JWT+OPA concurrency.

---

## Judge probe targets next (iter 419)

1. **HIGH — Trino federation threshold-push 5th-angle** (different shape than iter417 DF / iter418 LIKE pushdown): cross-catalog 3-way JOIN execution location; schema-evolution-with-pushdown when Postgres ADDs a new column mid-query; OR-with-mixed-types pushdown; aggregation pushdown to Postgres semantics.

2. **MEDIUM — Iceberg branches-vs-expire_snapshots 3rd-angle** — still pending: "After running expire_snapshots, an old snapshot I thought was branch-protected is gone — why?" probes legitimate failure modes.

3. **MEDIUM — Snapshot vs serializable phantom-row 3rd-angle** — still pending.

4. **MEDIUM — HMS->Nessie 2nd-angle for write-freeze alternative** — still pending.

5. **MEDIUM — Window NULL 2nd-angle (calendar-dim LEFT JOIN densification)** — still pending.

6. **LOW — Iceberg v3 deletion vectors timeline** carry-forward.

7. **OPTIONAL — durability re-probe of iter418 Q1 engine-confusion fix in a NEW shape**: e.g., "I want to z-order by 3 columns on Trino 467 — what's the syntax?" probes whether responder correctly answers "Trino has no z-order at any release, drop to Spark CALL rewrite_data_files(strategy=>'sort') for sort-order" — confirms the disambiguation matrix holds under a different angle.

---

## Critical message to teacher for iter 419: the engine-confusion sub-flavor is now durably resolved; federation threshold continues to be the only structural gap

The iter418 result is a clean recovery from the iter417 setback. The Q1 inaccuracy was the engine-confusion sub-flavor of the recurring confident-inaccuracy pattern (Spark CALL syntax presented as Trino EXECUTE) — and the teacher's disambiguation matrix in resource 17, the GUARDRAIL callout in resource 18, and the Path A/Path B restructure in resource 10 all landed cleanly in the durability re-probe. The myth-buster zero-confident-inaccuracy streak restarts at 1. The structural risk of NEW confident-inaccuracy failures persists (6 of prior 17 iters had one) but the recovery-within-one-iteration pattern is durable across SIX consecutive cases (iter407→408, iter411→412, iter413→414, iter414 Q3→iter415 Q1, iter417 Q1→iter418 Q1).

The only structural gap that remains is the Trino federation topic threshold-push: 18 consecutive iterations stuck below the 4.5 threshold, currently 0.0106 below. The 4-iter upward trend (iter415→416→417→418) is encouraging but the 4.75+ band is what creates meaningful threshold movement. Q3's 4.625 nudged the topic UP by 0.0005 — needs sustained 4.75+ federation answers (not 4.625) to cross within the next ~20 iters.
