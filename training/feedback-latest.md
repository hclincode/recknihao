# Judge Feedback — Iter 414 (EXTENDED PHASE — end-of-iteration only)

**Overall: 4.0625 PASS** (Q1 4.75 + Q2 3.75 + Q3 3.25 + Q4 4.5) — above the 3.5 overall PASS threshold, but **step-DOWN of 0.156 from iter413 4.21875**, second consecutive iteration decline. Thirteenth consecutive overall PASS in the iter402-414 window, but the iter414 Q3 NEW critical inaccuracy on a DIFFERENT topic (Iceberg branches/expire_snapshots) replaces last iteration's Q2 federation TopN failure — same failure-mode CLASS (confident inaccuracy on load-bearing topic-specific claim), different topic.

**Headline:**
1. **WIN — Q1 TopN-pushdown re-probe (4.75 STRONG).** Iter413 inaccuracy FULLY RESOLVED. Responder now correctly leads with affirmative "Top-N pushdown supported in OSS Trino 467 PostgreSQL connector since release 353/354" + canonical pushed-down EXPLAIN signature (sortOrder + limit inside TableScan, no TopN operator above). Teacher's iter414 §13.5 rewrite (lead with affirmative + myth-buster table) landed cleanly.
2. **PASS with quality flag — Q2 aggregate TopN does NOT push (3.75).** Right conclusion via right mechanism (ORDER BY on Trino-computed aggregate can't push because connector can't sort on values it hasn't produced), but mid-answer COPY-PASTE BLEED of MERGE-broadcast-join phrasing ("the staging table contains all today's events", "the MERGE is joining every source row") that belongs to Q4, not the Postgres GROUP BY query. Bleed doesn't change conclusion but muddies mechanism explanation.
3. **CRITICAL — Q3 NEW accuracy defect (3.25 FAIL).** Responder claims "expire_snapshots CAN orphan files a branch points to" and frames branch retention as governing "snapshots WITHIN branch not data-file protection". **VERIFIED WRONG** against iceberg.apache.org/docs/latest/branching/ + maintenance/ + spark-procedures/: "Snapshots that are still referenced by branches or tags won't be removed" + "expire_snapshots procedure will never remove files which are still required by a non-expired snapshot". The team's own resource 17 line 1657 explicitly states "A snapshot referenced by any named tag or branch is protected from expire_snapshots regardless of its age." Same failure-mode CLASS as iter411 Q2 (QUALIFY-on-Trino), iter413 Q2 (TopN can't push), iter407 Q2 (branches-Spark-only).
4. **WIN — Q4 MERGE slow / pre-filter source (4.5 STRONG).** Broadcast-join + target-table-scan + partition-pruning via source dynamic-filter is the canonical Trino-Iceberg MERGE explanation; pre-filter fix + EXPLAIN diagnostic correct.

**Trino federation topic status:**
- **Previous: 4.4892 / 269 (NEEDS WORK, 0.0108 below 4.5 threshold)**
- **NEW: 4.4874 / 271 (NEEDS WORK, 0.0126 below 4.5 threshold) — REGRESSED 0.0018 further**
- The Q1 strong landing (4.75) was offset by Q2 quality penalty (3.75 below 4.5). Topic remains stuck below threshold for the 14th consecutive iteration. **Does NOT cross 4.5.**

**Pattern note:** Fourth confident-inaccuracy-on-load-bearing-claim failure in eight iterations across DIFFERENT topics:
- iter407 Q2: "branches are Spark-only" (federation/Iceberg) → fixed iter408.
- iter411 Q2: QUALIFY recommended on Trino (federation/dbt) → fixed iter412.
- iter413 Q2: "OSS Trino can't push TopN" (federation) → fixed iter414 (DURABLE — confirmed in iter414 Q1).
- iter414 Q3: "expire_snapshots can orphan branch-referenced files" (Iceberg table maintenance) → needs fix iter415.

The teacher's recovery pattern remains tight (each previous instance recovered within one iteration), but the **structural risk** is that the responder produces confident factual claims about TOPIC-SPECIFIC semantics that contradict both official docs AND the team's own resources. For Iceberg-branches specifically, the correct framing IS in resource 17 (line 1657), but the responder didn't find/apply it — suggesting a findability gap, not a content gap.

---

## Q1 — Plain TopN pushdown to Postgres (FEDERATION re-probe)

**Scores: 5.0 / 4.5 / 5.0 / 4.5 — avg 4.75 STRONG PASS**

### What landed
- **Leads with affirmative**: "Top-N pushdown supported in OSS Trino 467 PostgreSQL connector since release 353 (March 2021), enabled by default in release 354 after VARCHAR fix" — VERIFIED against trino.io/docs/current/release/release-353.html + release-354.html + optimizer/pushdown.html.
- **EXPLAIN signature**: "sortOrder=[created_at DESC NULLS LAST] limit=100 INSIDE TableScan, NO TopN operator above the scan = pushed" — VERIFIED canonical signature.
- **Postgres index-on-created_at returns 100 rows directly** — CORRECT mechanism (no 50M-row pull; PG btree handles ORDER BY+LIMIT).
- **Contrast case**: "TopN operator above TableScan = failed/local sort in Trino" — CORRECT diagnostic.

### Verdict
STRONG PASS. **Iter413 inaccuracy resolved durably.** Teacher's iter414 §13.5 rewrite (lead with affirmative + myth-buster + cite release notes) confirmed effective.

---

## Q2 — Aggregate TopN does NOT push (FEDERATION contrast)

**Scores: 4.5 / 3.0 / 3.5 / 4.0 — avg 3.75 PASS (below STRONG)**

### What landed
- **Core technical claim CORRECT**: GROUP BY customer_id ORDER BY COUNT(*) DESC LIMIT 20 does NOT match the Top-N pushdown pattern. Postgres must materialize the full GROUP BY aggregate result before sorting by count + LIMIT picks top 20.
- **Mitigation options sound**: pre-filter via WHERE on indexed col, load to Iceberg for parallel agg with Trino-native partition pruning, materialized view for nightly precompute.

### Quality defect (the deduction)
- Mid-answer the responder discusses **"the staging table contains all today's events"** and **"the MERGE is joining every source row"** — content that belongs to Q4 (MERGE broadcast join), not a Postgres GROUP BY query.
- This conflates a Postgres GROUP BY semantic (single-source agg pushdown failure) with a MERGE broadcast-join semantic (target-table-scan + partition pruning).
- An engineer reading mid-answer may think their Postgres query involves a MERGE or that the fix involves a join-strategy change — both wrong for this query shape.
- Bleed didn't change the BOTTOM-LINE conclusion, but it muddies the mechanism explanation. Not as severe as iter413's wrong-general-claim (which actively misled with a false absolute).

### Verdict
PASS but below STRONG. Right conclusion with mechanism-muddle. Score reflects clarity penalty for cross-question bleed.

---

## Q3 — Branch retention vs expire_snapshots (NON-FED, Iceberg maintenance)

**Scores: 2.5 / 4.0 / 3.0 / 3.5 — avg 3.25 FAIL**

### Critical accuracy defect (the headline issue)
- Responder claims **"expire_snapshots CAN orphan files a branch points to"** and frames branch retention (max_snapshot_age_in_ms / min_snapshots_to_keep) as governing "snapshots WITHIN branch not data-file protection on main expiry".
- **VERIFIED WRONG** against:
  - iceberg.apache.org/docs/latest/branching/: "Snapshots that are still referenced by branches or tags won't be removed".
  - iceberg.apache.org/docs/latest/maintenance/ + spark-procedures/: "The expire_snapshots procedure will never remove files which are still required by a non-expired snapshot".
  - **The team's own resources/17-iceberg-table-maintenance.md line 1657 states: "A snapshot referenced by any named tag or branch is protected from expire_snapshots regardless of its age. Iceberg will not physically delete a snapshot (or its exclusively-owned data files) while a live ref points at it."**
- There IS a known bug (apache/iceberg issue #13568) where expire_snapshots in multi-ref edge cases can erroneously delete data files referenced by active branches, but: (a) affects Iceberg 1.6.1+ (prod runs 1.5.2 per prod_info.md), (b) it is documented as a BUG not the design, (c) the responder did not frame it as such — presented as default behavior.

### Right framing the responder should have given
- **"Branches and tags ARE protective by default — they are the canonical mechanism for keeping snapshots safe from expire_snapshots."**
- Legitimate operational risks: (i) forgotten refs hold old data indefinitely (resource 17 already covers this well), (ii) Iceberg 1.6.1+ multi-ref bug (NOT prod on 1.5.2), (iii) ALTER TABLE EXECUTE expire_snapshots(older_than=>ts) does NOT bypass ref protection in normal code paths.
- "Create TAG with max_reference_age_in_ms" is a real Iceberg feature, but it's a HARDENING pattern (auto-expire-the-ref-itself-after-N), not a fix for a non-existent default-deletion problem.

### Verdict
FAIL. Load-bearing factual claim wrong. Same failure-mode class as iter411 Q2 / iter413 Q2 / iter407 Q2 (confident-inaccuracy-on-load-bearing-claim). The right info IS in resource 17 — this looks like a findability gap not a content gap.

---

## Q4 — MERGE slow / pre-filter source (NON-FED, Ingestion topic)

**Scores: 4.5 / 4.5 / 5.0 / 4.0 — avg 4.5 STRONG PASS**

### What landed
- **Broadcast-join mechanism for MERGE** (small staging side broadcast to all workers) — CORRECT for typical small-source case.
- **"Reads staging small but scans main table target partitions for matches"** — CORRECT canonical pattern (verified against starburst.io/blog Iceberg-partitioning-and-performance-optimizations-in-trino + community Medium posts: "During a MERGE operation, Trino scans the entire target table to find matching records, even if your source data only corresponds to a single partition").
- **Pre-filter source narrows broadcast set + flows partition pruning to target via dynamic filtering** — CORRECT mechanism.
- **EXPLAIN diagnostic for main TableScan constraint on partition column** (present = pruned, absent = full scan) — CORRECT verification pattern.
- **Fix: add partition filter matching ON clause / source WHERE on partition col** — CORRECT canonical workaround.

### Minor (not gating)
- Could mention the $partition hidden column pattern as a backup when source-side filtering alone is insufficient.
- Could note that the ON clause itself doesn't trigger partition pruning on target without dynamic filtering / explicit predicate.

### Verdict
STRONG PASS. Solid mechanism + diagnostic + fix sequence.

---

## Pattern across all four answers

| Q | Score | Verdict |
|---|---|---|
| Q1 | 4.75 | STRONG PASS — TopN-pushdown affirmative + EXPLAIN signature + release 353/354 (iter413 inaccuracy RESOLVED) |
| Q2 | 3.75 | PASS — Aggregate TopN correctly explained but MERGE-broadcast-join bleed muddies mechanism |
| Q3 | 3.25 | FAIL — "expire_snapshots can orphan branch-referenced files" CONTRADICTS Iceberg docs + own resource 17 |
| Q4 | 4.5 | STRONG PASS — MERGE-broadcast-join + pre-filter + EXPLAIN partition-pruning verification |

**Average 4.0625 PASS** — thirteenth consecutive overall PASS in the iter402-414 window, but second consecutive step-DOWN (iter412 4.625 → iter413 4.21875 → iter414 4.0625).

**Trajectory iter394-414:** `4.75P/3.125F/4.3125P/4.375P/4.34375P/4.09375P/4.0625P/3.8125F/4.59375P/3.875F/4.25P/4.6875P/4.40625P/4.625P/4.0625P/4.125P/4.5625P/4.0P/4.219P/4.625P/4.21875P/**4.0625P**`.

**Topic status table:**
- Postgres-to-Iceberg ingestion: 4.4926/146 -> 4.4927/147 — PASSED (above threshold; Q4 nudges marginally up).
- Iceberg table maintenance: 4.4102/77 -> 4.3953/78 — PASSED but DROPPED 0.0149 in one question (Q3 FAIL drag); the largest single-Q topic-avg movement in recent iterations.
- **Trino federation / cross-source: 4.4892/269 -> 4.4874/271 — NEEDS WORK (REGRESSED 0.0018; now 0.0126 below 4.5 raised threshold; 14th consecutive iteration stuck below threshold).**

---

## Did the iter413 inaccuracy resolve?

**YES — iter413 Q2 TopN-pushdown inaccuracy is RESOLVED.** Responder now leads with the correct affirmative claim ("OSS Trino 467 PostgreSQL connector supports TopN pushdown since release 353/354"), gives the canonical pushed-down EXPLAIN signature (sortOrder + limit inside TableScan, no TopN operator above), and correctly explains the aggregate-ORDER-BY non-push case in Q2. The teacher's iter414 §13.5 rewrite (lead with affirmative + myth-buster table + cite release notes) landed cleanly. **Durability confirmed via the Q1 re-probe.**

## Did the Trino federation topic cross 4.5 threshold?

**NO — federation topic remains NEEDS WORK at 4.4874/271, 0.0126 below threshold.** The Q1 4.75 STRONG was offset by Q2 3.75 quality penalty (bleed defect). Net effect: -0.0018 regression. Topic is now slightly FURTHER from threshold than at end of iter413. **14th consecutive iteration stuck below the 4.5 raised threshold.**

---

## Teacher actions next (iter 415)

1. **HIGH — Iceberg expire_snapshots vs branches accuracy correction in resources/17-iceberg-table-maintenance.md.** Existing line 1657 already states the correct framing, but the responder did NOT internalize it for Q3. Likely cause: there is no SECTION DEDICATED to the "branches vs expire_snapshots" question shape, and the engineer's framing biased the responder toward agreeing with the framing rather than correcting it. Add a dedicated "Branches/tags are protective by default — common myths" callout block to resource 17 with:
   - Lead with affirmative: "expire_snapshots NEVER removes data files referenced by an active branch or tag in normal operation (Iceberg's documented design)."
   - Myth-buster table listing 3 common wrong claims with corrections:
     - WRONG: "branch retention controls only snapshots WITHIN the branch — it does NOT protect data files" → RIGHT: branches are top-level refs; while a ref points at a snapshot, that snapshot and its data files are protected.
     - WRONG: "expire_snapshots can orphan branch-referenced files" → RIGHT: it cannot in normal operation; only a known bug (Iceberg 1.6.1+ #13568) on multi-ref edge cases.
     - WRONG: "you need to tag-protect or tighten retention to keep branch data safe" → RIGHT: an active branch IS the protection; tag-with-max_reference_age is a hardening pattern, not a fix.
   - Legitimate ops risks: (i) forgotten refs hold old data indefinitely, (ii) Iceberg 1.6.1+ multi-ref bug (not prod on 1.5.2), (iii) ALTER TABLE EXECUTE expire_snapshots respects ref protection.
   - Cite iceberg.apache.org/docs/latest/maintenance/, branching/, spark-procedures/.

2. **MEDIUM — Q2 copy-paste bleed prevention in resources/22-trino-federation-postgresql.md §13.5.** The bleed in Q2 (MERGE-broadcast-join phrasing in a Postgres GROUP BY answer) suggests resource 22 §13.5 may be cross-linking too aggressively with the MERGE pattern from resource 13/17. Audit §13.5 + §3.3A for any inline MERGE/staging-table phrasing that could leak into a non-MERGE federation answer; isolate the TopN-failure-shape explanation to single-source Postgres GROUP BY context.

3. **LOW carry-forward backlog**: HMS->Nessie write-freeze alternative + Hive-views-don't-migrate gotcha (deferred); equality-perf-regression caveat for enable-string-pushdown-with-collate; MERGE rollback; OPA-override timeout; schema registry compat; JWT+OPA concurrency; Iceberg tagging 3rd-angle; fs.cache JMX 3rd-angle; Iceberg v3 deletion vectors timeline; snapshot vs serializable phantom-row 3rd-angle.

---

## Judge probe targets next (iter 415)

1. **CRITICAL — Iceberg branches-vs-expire_snapshots 2nd-angle (durability of iter415 fix).** Different phrasing, e.g.:
   - "Our nightly expire_snapshots job runs with retention_threshold=7d but we want to keep a snapshot from 30 days ago for audit — can a branch protect it?" — confirms responder NOW affirms branches ARE protective by default and points to creating/keeping a branch or tag as the canonical mechanism.
   - Or: "After running expire_snapshots, an old snapshot I thought was branch-protected is gone — why?" — probes the legitimate failure modes (forgotten ref dropped, bug #13568, manual ref-retention tightening).

2. **HIGH — Trino federation topic threshold-push continuation.** After iter414's 0.0018 regression, topic is 0.0126 below threshold. ONE more 4.6+ federation answer pushes to ~4.4878 (still below), THREE consecutive 4.6+ at ~4.4888 (still below), need sustained sequence of 4.7+ scores to cross. **Probe federation in iter415 consistently.**

3. **Window NULL 2nd-angle still pending**: "Rolling 7-day metric shows NULL gaps but I need zero-fill — what's the right pattern?" — probes the calendar-dim LEFT JOIN densification alternative as the only semantically-clean fix.

4. **Snapshot vs serializable phantom-row 3rd-angle** — still pending durability re-probe from iter412 teacher's resource 26 §8.1/8.2 fix.

5. **HMS->Nessie 2nd-angle for write-freeze alternative** — still pending.

6. **Iceberg v3 deletion vectors timeline** carry-forward (long-standing backlog item).

---

## Critical message to teacher for iter 415: the Iceberg branches-as-protection truth

The right mental model the teacher must instill in resources/17 (the existing line 1657 statement needs to be elevated to a leading callout):

> **Branches and tags ARE the Iceberg-native mechanism for protecting snapshots from expire_snapshots — by design, not by accident.**
>
> **DEFAULT BEHAVIOR (documented):**
> - "Snapshots that are still referenced by branches or tags won't be removed" (iceberg.apache.org/docs/latest/branching/).
> - "The expire_snapshots procedure will never remove files which are still required by a non-expired snapshot" (spark-procedures/).
> - **An active branch IS the protection. You do NOT need to create a tag to protect a snapshot that an active branch already references.**
>
> **WHAT branch retention (max-snapshot-age-ms / min-snapshots-to-keep) controls:**
> - These properties control which snapshots within the branch's ancestor history are eligible for expiry.
> - They do NOT cause data files of currently-referenced snapshots to be deleted while the ref is alive.
> - max-ref-age-ms controls when the BRANCH ITSELF expires (the ref is removed); once the ref is gone, snapshots not referenced elsewhere become expire-eligible.
>
> **LEGITIMATE OPS RISKS:**
> 1. Forgotten refs hold old snapshots/data files indefinitely → monitor $refs and drop unused refs.
> 2. Iceberg 1.6.1+ bug #13568 — multi-ref edge cases can erroneously delete branch-referenced files (NOT prod on 1.5.2 but worth flagging for future upgrades).
> 3. Explicitly dropping a ref (DROP BRANCH / ALTER TABLE...DROP) makes its previously-protected snapshots expire-eligible.

The wrong framing the responder produced ("expire_snapshots can orphan branch-referenced files; you need tag-protection / retention-tightening to protect data files") inverts the default semantic. The right framing leads with the affirmative protection-by-default + enumerates the legitimate-but-narrow exceptions. The wrong framing presents the rare bug case as the default.

This is the fourth confident-inaccuracy-on-load-bearing-claim failure in eight iterations across the iter402-414 window — three on federation (iter407, iter411, iter413) and now one on Iceberg-branches (iter414). The same recovery-within-one-iteration pattern should apply, but the structural risk persists.
