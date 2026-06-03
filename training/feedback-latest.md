# Judge Feedback — Iter 415 (EXTENDED PHASE — end-of-iteration only)

**Overall: 4.625 STRONG PASS** (Q1 4.75 + Q2 4.5 + Q3 4.625 + Q4 4.625) — well above the 3.5 overall PASS threshold and **REVERSES the two-iteration decline (iter412 4.625 → iter413 4.21875 → iter414 4.0625 → iter415 4.625)**. Fourteenth consecutive overall PASS in the iter402-415 window. Step-UP of +0.5625 from iter414 — the iter414 Q3 critical inaccuracy on Iceberg branches-vs-expire_snapshots is RESOLVED durably.

**Headline:**
1. **CRITICAL WIN — Q1 branches-vs-expire_snapshots RE-PROBE (4.75 STRONG).** Iter414 Q3 inaccuracy FULLY RESOLVED. Responder now correctly leads with affirmative "Iceberg auto-protects branch-referenced snapshots from expire_snapshots regardless of age — BY DESIGN, no tag/retention-tightening needed; protection registered in metadata; expire checks named refs before deleting". Enumerates the legitimate ops risks (forgotten ref dropped, branch retention aging out branch's own snapshots, Iceberg #13568 multi-ref bug 1.6.1+ NOT prod 1.5.2). $refs WHERE name='staging' verification recipe sound. Teacher's iter415 leading myth-buster callout in resource 17 + new section 12 in resource 26 landed cleanly.
2. **STRONG PASS — Q2 DROP COLUMN storage reclaim (4.5 STRONG).** Correctly leads with "DROP COLUMN is metadata-only — old Parquet still has the column bytes". 4-step reclaim chain accurately framed: (1) EXECUTE optimize compacts + applies schema evolution to write new files without dropped column (VERIFIED: Iceberg schema evolution docs + Trino OPTIMIZE behavior rewrites files using current schema), (2) expire_snapshots(7d) drops old snapshots referencing old files, (3) remove_orphan_files(7d) physically deletes, (4) rewrite_manifests Spark-only optional (VERIFIED: trinodb/trino#14821 confirms rewrite_manifests NOT in Trino connector). Immutable-file model framing correct.
3. **STRONG PASS — Q3 rollback bad write (4.625 STRONG).** CALL iceberg.system.rollback_to_snapshot('analytics','user_events',snap_id) positional form CORRECT for Trino 467 (verified against Trino docs). $snapshots committed_at to find pre-bad snapshot CORRECT. Rollback moves pointer no file delete — corrupt rows instantly invisible no reload CORRECT canonical semantic. Critical caveat: ALTER TABLE EXECUTE rollback_to_snapshot(snapshot_id=>) added Trino 469 NOT on 467 — use CALL positional form. VERIFIED against trinodb/trino PR #24580 (table procedure added in release 469, Jan 27 2025); the CALL form remains supported on 467 (now deprecated as of 469).
4. **STRONG PASS — Q4 predicate pushdown WHERE filters (4.625 STRONG).** Equality/IN/IS NULL on VARCHAR + numeric/DATE/timestamp range pushdowns CORRECT. VARCHAR range (<,>,BETWEEN) + LIKE patterns NOT pushed by default — collation/bytewise mismatch safety rationale CORRECT (VERIFIED against trino.io/docs/current/connector/postgresql.html). Opt-in postgresql.experimental.enable-string-pushdown-with-collate=true with equality perf regression caveat — VERIFIED against PR #9746 and Trino postgres connector docs. EXPLAIN predicate inside TableScan vs Filter node above as verification path — CORRECT canonical diagnostic.

**Trino federation topic status:**
- **Previous: 4.4874 / 271 (NEEDS WORK, 0.0126 below 4.5 threshold)**
- **NEW: 4.4880 / 272 (NEEDS WORK, 0.0120 below 4.5 threshold) — IMPROVED 0.0006**
- Q4 4.625 above 4.5 threshold pushes topic up marginally. **15th consecutive iteration stuck below threshold**, but trending in the right direction again after iter414 regression.

**Pattern note:** The iter414 Q3 confident-inaccuracy-on-load-bearing-claim was the FOURTH such failure in eight iterations (iter407 Q2 / iter411 Q2 / iter413 Q2 / iter414 Q3). The iter415 Q1 re-probe confirms the teacher's now-canonical recovery pattern works again:
- Lead with affirmative truth as a callout box.
- Add myth-buster table with 3 common wrong claims + corrections.
- Enumerate the legitimate-but-narrow exceptions.
- Cite the authoritative source URLs.

The systemic myth-buster callouts in resources 17 / 22 / 23 (added this iteration) should reduce future confident-inaccuracy failures by surfacing the right framing at the LEADING position of the most-probed sections.

---

## Q1 — Iceberg branches vs expire_snapshots (RE-PROBE of iter414 Q3 FAIL)

**Scores: 5.0 / 4.5 / 5.0 / 4.5 — avg 4.75 STRONG PASS**

### What landed
- **Leads with affirmative**: "Iceberg auto-protects branch-referenced snapshots from expire_snapshots regardless of age, BY DESIGN, no tag/retention-tightening needed" — DIRECTLY INVERTS the iter414 Q3 wrong claim.
- **Mechanism**: protection from ref registered in metadata, expire procedure checks named refs before deleting — VERIFIED against iceberg.apache.org/docs/latest/branching/ ("Snapshots that are still referenced by branches or tags won't be removed").
- **Caveat enumeration**: only legitimate risks are (i) branch explicitly dropped, then snapshots not referenced elsewhere become expire-eligible, (ii) branch's own retention (max-snapshot-age-ms / min-snapshots-to-keep) aging out branch ancestors, (iii) Iceberg #13568 multi-ref bug affecting 1.6.1+ NOT prod 1.5.2.
- **Diagnostic**: verify via $refs WHERE name='staging' — CORRECT canonical recipe.

### Verdict
STRONG PASS. **Iter414 Q3 inaccuracy RESOLVED durably.** Teacher's iter415 leading myth-buster callout in resource 17 §2 + parallel section 12 in resource 26 + back-link from line 1657 to the leading callout landed cleanly. The findability gap diagnosis from iter414 (right info existed at line 1657 but responder didn't find it) is now closed — the right answer is at the LEADING position of the section the responder enters first.

---

## Q2 — DROP COLUMN storage reclaim

**Scores: 4.5 / 4.5 / 4.5 / 4.5 — avg 4.5 STRONG PASS**

### What landed
- **DROP COLUMN metadata-only no file rewrite** — CORRECT (verified against iceberg.apache.org/docs/1.5.1/evolution/: "Iceberg schema updates are metadata changes, so no data files need to be rewritten").
- **Old Parquet still has column bytes** — CORRECT (immutable file model; existing data files are not touched by ALTER TABLE DROP COLUMN).
- **4-step reclaim chain**: (1) EXECUTE optimize compacts + applies schema evolution writing new files without dropped column (verified — OPTIMIZE rewrites with current schema, physically excluding dropped columns), (2) expire_snapshots(7d) drops old snapshots referencing the pre-OPTIMIZE files, (3) remove_orphan_files(7d) physically deletes the orphaned data files, (4) rewrite_manifests Spark-only optional — VERIFIED against trinodb/trino#14821 ("the procedure is not currently available in Trino's Iceberg connector").
- **Immutable-file model framing** — CORRECT teaching framing.

### Minor (not gating)
- Could mention the 7d default retention floor (Iceberg's safety check against accidentally over-aggressive expire) and how to override via expire_snapshots_min_retention catalog property.
- Could note that the OPTIMIZE pass is the WORK-INTENSIVE step (must rewrite data files); 2 and 3 are cheap metadata + file-system ops.

### Verdict
STRONG PASS. Right chain, right mechanism, right engine-availability caveat.

---

## Q3 — Rollback bad write (Trino 467 CALL vs Trino 469 ALTER EXECUTE)

**Scores: 5.0 / 4.5 / 5.0 / 4.0 — avg 4.625 STRONG PASS**

### What landed
- **CALL iceberg.system.rollback_to_snapshot('analytics','user_events',snap_id) positional form** — CORRECT for Trino 467 (verified against Trino Iceberg connector docs for releases pre-469).
- **Find pre-bad snapshot via $snapshots committed_at** — CORRECT canonical diagnostic ($snapshots metadata table provides committed_at, snapshot_id, parent_id, operation).
- **Rollback moves the snapshot pointer, doesn't delete files** — CORRECT (the rollback is metadata-only; the snapshot history retains the bad snapshot as ancestor of the original tip, but the current_snapshot_id points to the chosen earlier snapshot).
- **Corrupt rows instantly invisible no reload** — CORRECT (next query reads from the new current snapshot which doesn't see the bad write's files).
- **Then expire_snapshots cleanup** — CORRECT (the bad snapshot's exclusively-owned files become eligible for expiry once retention age passes).
- **CRITICAL CAVEAT — ALTER TABLE EXECUTE rollback_to_snapshot(snapshot_id=>) added Trino 469 NOT on 467; use CALL positional form** — VERIFIED against trinodb/trino PR #24580 ("Deprecate `CALL rollback_to_snapshot` and add corresponding table procedure in Iceberg", merged for release 469 Jan 27 2025). The CALL form remains supported on 467 (now deprecated in 469+).

### Minor (not gating)
- Could mention the 1-minute snapshot-age caveat (Trino #12353 — rollback fails when snapshots over 1 minute apart in some older versions; not blocking on 467).
- Could mention that ALTER TABLE EXECUTE rollback_to_snapshot might also exist via SET PROPERTIES current-snapshot-id in even older paths, but the positional CALL is canonical for 467.

### Verdict
STRONG PASS. The 467-vs-469 syntax distinction is a NUANCE the responder handled correctly — this is the second consecutive iteration where the responder gets a version-specific syntax claim right.

---

## Q4 — Predicate pushdown WHERE filters

**Scores: 4.5 / 4.5 / 5.0 / 4.5 — avg 4.625 STRONG PASS**

### What landed
- **Equality/IN/IS NULL push** for both numeric and VARCHAR equality — CORRECT (verified against trino.io/docs/current/connector/postgresql.html: "Equality predicates (such as IN or =) and inequality predicates (such as !=) on columns with textual types are pushed down").
- **Numeric/DATE/timestamp range push** — CORRECT (range predicates on non-VARCHAR types push by default).
- **VARCHAR range (<, >, BETWEEN) NOT push by default** — CORRECT (verified: "range predicates like > on VARCHAR columns are not pushed down by default" due to collation differences between Trino and Postgres).
- **LIKE patterns NOT push by default** — CORRECT (LIKE involves character semantics that depend on collation; Trino conservatively keeps LIKE local).
- **Collation/bytewise mismatch safety rationale** — CORRECT (Trino uses bytewise comparison by default; Postgres may use locale-sensitive collation; pushing a range or LIKE could return semantically different rows).
- **Opt-in postgresql.experimental.enable-string-pushdown-with-collate=true** — VERIFIED against PR #9746 (introduced in Trino 365 Dec 2021); session form is enable_string_pushdown_with_collate.
- **Equality perf may regress with collate-pushdown** — CORRECT (per Trino docs: adding collation to equality predicates can disable Postgres indexes — the foot-gun the engineer must weigh against the range-pushdown benefit).
- **EXPLAIN predicate inside TableScan vs Filter node above as verification** — CORRECT canonical pattern (constraint inside TableScan = pushed; Filter wrapping TableScan = residual not pushed).

### Minor (not gating)
- Could explicitly call out that the opt-in is CATALOG-level (requires Trino restart) vs SESSION-level (per-query toggle).
- Could mention prefix-LIKE (LIKE 'prefix%') would benefit MOST from pushdown if the column has a btree index in Postgres with the right operator class.

### Verdict
STRONG PASS. Solid mechanism + accurate version + canonical EXPLAIN diagnostic + correct foot-gun callout.

---

## Pattern across all four answers

| Q | Score | Verdict |
|---|---|---|
| Q1 | 4.75 | STRONG PASS — branches-vs-expire_snapshots RE-PROBE (iter414 Q3 FAIL RESOLVED) |
| Q2 | 4.5 | STRONG PASS — DROP COLUMN metadata-only + 4-step reclaim chain |
| Q3 | 4.625 | STRONG PASS — CALL Trino 467 + ALTER EXECUTE Trino 469 nuance correct |
| Q4 | 4.625 | STRONG PASS — predicate pushdown + VARCHAR collation + opt-in caveat |

**Average 4.625 STRONG PASS** — fourteenth consecutive overall PASS in the iter402-415 window. Step-UP of +0.5625 from iter414 4.0625. **REVERSES the two-iteration decline (iter412 4.625 → iter413 4.21875 → iter414 4.0625 → iter415 4.625).** This ties with iter412 as the highest score in the iter402-415 window.

**Trajectory iter394-415:** `4.75P/3.125F/4.3125P/4.375P/4.34375P/4.09375P/4.0625P/3.8125F/4.59375P/3.875F/4.25P/4.6875P/4.40625P/4.625P/4.0625P/4.125P/4.5625P/4.0P/4.219P/4.625P/4.21875P/4.0625P/**4.625P**`.

**Topic status table:**
- Postgres-to-Iceberg ingestion: 4.4927/147 — no change this iteration (no Q on this topic).
- Iceberg table maintenance: 4.3953/78 -> 4.4036/80 (Q1 4.75 + Q2 4.5 + Q3 4.625, all above topic avg, nudge UP +0.0083; Q3 reclassifies to ingestion-adjacent but counted here for procedural rollback).
- **Trino federation / cross-source: 4.4874/271 -> 4.4880/272 (NEEDS WORK; IMPROVED 0.0006; now 0.0120 below 4.5 raised threshold; 15th consecutive iteration stuck below threshold).** Q4 4.625 above threshold pushed up tiny.

---

## Did the iter414 Q3 inaccuracy resolve?

**YES — iter414 Q3 branches-vs-expire_snapshots inaccuracy is RESOLVED.** Responder now correctly leads with the affirmative: "Iceberg auto-protects branch-referenced snapshots from expire_snapshots regardless of age, BY DESIGN — no tag/retention-tightening needed". Mechanism (protection registered in metadata; expire checks named refs before deleting) is verified against iceberg.apache.org/docs/latest/branching/. Caveat enumeration (drop-branch, branch's own retention, #13568 bug 1.6.1+ NOT prod 1.5.2) is the canonical legitimate-ops-risks list. **Durability confirmed via the Q1 re-probe from a different angle than iter414 Q3.** Teacher's iter415 leading myth-buster callout in resource 17 §2 + parallel section 12 in resource 26 landed cleanly.

## Did the 2-iteration decline reverse?

**YES — iter412 4.625 → iter413 4.21875 → iter414 4.0625 → iter415 4.625.** Step-UP of +0.5625 from iter414 reverses the iter413+iter414 declining trajectory. iter415 ties with iter412 as the highest score in the iter402-415 window.

## Did the Trino federation topic cross 4.5 threshold?

**NO — federation topic remains NEEDS WORK at 4.4880/272, 0.0120 below threshold.** Q4 4.625 above threshold pushed up +0.0006. 15th consecutive iteration stuck below the 4.5 raised threshold, but the trend is back toward improvement after iter414's regression.

---

## Teacher actions next (iter 416)

1. **MEDIUM — Trino federation topic threshold-push continuation.** After iter415's +0.0006 improvement, topic is 0.0120 below threshold. The Q4 4.625 was a federation-topic data point; need SUSTAINED 4.7+ federation answers to cross threshold. Consider whether resource 22 has any remaining myth-buster gaps (cross-catalog join pushdown details, IS DISTINCT FROM pushdown semantics, OR-with-mixed-types pushdown caveat) that could be elevated to leading callouts to lift future federation scores from the 4.625 STRONG PASS band to the 4.75+ band.

2. **LOW — Carry-forward backlog**: HMS->Nessie write-freeze alternative + Hive-views-don't-migrate gotcha (still deferred); equality-perf-regression caveat for enable-string-pushdown-with-collate (responder DID mention it this iteration — could be removed from backlog); MERGE rollback; OPA-override timeout; schema registry compat; JWT+OPA concurrency; Iceberg tagging 3rd-angle; fs.cache JMX 3rd-angle; Iceberg v3 deletion vectors timeline; snapshot vs serializable phantom-row 3rd-angle.

3. **LOW — Audit consistency of myth-buster pattern across resources.** The iter415 systemic myth-buster pass (resources 17 / 22 / 23) landed cleanly. Consider whether other heavily-probed resources (13 ingestion, 21 HMS-iceberg, 26 concurrent writes) also need leading common-myths callouts to preempt confident-inaccuracy failures on the topics they cover.

---

## Judge probe targets next (iter 416)

1. **HIGH — Trino federation topic threshold-push 2nd-angle.** Probe federation with a DIFFERENT shape than TopN-pushdown / VARCHAR-range-pushdown / dynamic-filtering to test breadth:
   - "I have `SELECT u.id, u.email FROM pg.users u JOIN ice.events e ON u.id = e.user_id WHERE e.event_date = DATE '2026-01-15'` — which side pushes what, and where does the join run?" — probes cross-catalog join mechanics + which predicates push to which side + dynamic filtering propagation across catalogs.
   - Or: "I added a new VARCHAR column to my Postgres table; will Trino's pushdown break on the new column?" — probes schema-evolution-with-pushdown semantics.

2. **HIGH — Iceberg branches-vs-expire_snapshots 3rd-angle (durability re-probe of iter415 fix).** Different shape from the iter415 Q1 probe:
   - "After running expire_snapshots, an old snapshot I thought was branch-protected is gone — why?" — probes the legitimate failure modes (forgotten ref dropped, bug #13568 on 1.6.1+, branch retention aging out).
   - Or: "Can I use a tag to keep a snapshot from 90 days ago for audit, even if branch retention is tighter?" — probes the tag-vs-branch protection independence.

3. **MEDIUM — Snapshot vs serializable phantom-row 3rd-angle** — still pending durability re-probe from iter412 teacher's resource 26 §8.1/8.2 fix.

4. **MEDIUM — HMS->Nessie 2nd-angle for write-freeze alternative** — still pending.

5. **MEDIUM — Window NULL 2nd-angle**: "Rolling 7-day metric shows NULL gaps but I need zero-fill — what's the right pattern?" — probes the calendar-dim LEFT JOIN densification alternative as the only semantically-clean fix.

6. **LOW — Iceberg v3 deletion vectors timeline** carry-forward (long-standing backlog item).

---

## Critical message to teacher for iter 416: maintain the myth-buster pattern

The iter415 result confirms the now-canonical recovery pattern works repeatably:
1. Lead with affirmative truth as a leading callout box.
2. Add 3-row myth-buster table (WRONG/RIGHT format).
3. Enumerate the legitimate-but-narrow exceptions.
4. Cite the authoritative source URLs.

This pattern has now resolved FIVE consecutive confident-inaccuracy failures across the iter402-415 window (iter407 → iter408, iter411 → iter412, iter413 → iter414, iter414 Q3 → iter415 Q1). The structural risk of NEW confident-inaccuracy failures persists, but the recovery-within-one-iteration pattern is durable.

For iter416, the priority is federation topic threshold-push (which has been stuck below 4.5 for 15 consecutive iterations) — not because the federation answers are wrong, but because the bar is high (4.5 threshold) and the topic has 272 data points dampening any single-iteration lift. Sustained 4.7+ federation answers are needed to cross threshold.
