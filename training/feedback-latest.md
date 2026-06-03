# Judge Feedback — Iter 420 (EXTENDED PHASE — end-of-iteration only)

**Overall: 4.547 PASS** (Q1 4.875 + Q2 4.875 + Q3 3.8125 + Q4 4.625) — comfortably above the 3.5 PASS threshold and the nineteenth consecutive overall PASS in the iter402-420 window. **-0.031 step-down from iter419 4.578**, but the headline is structural: **the iter419 Q3 Spark-write-API self-contradiction is FULLY RESOLVED in one iteration**, AND a **NEW failure mode emerged — self-contradictory framing WITHIN a single answer** (Q3 TopN on PostgreSQL connector).

**Headline:**
1. **API-CONFUSION FULLY RESOLVED — Q1 4.875.** The teacher's iter420 r13 bulletproofing (TOP-OF-DOC CALLOUT #1 API-CONFUSION GUARDRAIL with 4-row intent->canonical-form table + TOP-OF-DOC CALLOUT #2 Spark JDBC end-to-end worked recipe closing with `.writeTo().append()` + r10 legacy example replacement) landed PRECISELY on target. The responder now uses `df.writeTo('iceberg.analytics.events').using('iceberg').partitionedBy(...).tableProperty(...).create()` for first-time creation and `df.writeTo('iceberg.analytics.events').append()` for nightly incremental, explicitly calls out that `.write.format('iceberg').mode('append').save()`/`.saveAsTable()` do NOT work with the SparkCatalog plugin. **The pattern is now durable: lead the resource with the canonical worked example, the responder pattern-matches the leading example.**
2. **FEDERATION DOUBLE-RESULT MIXED — Q2 4.875 STRONG + Q3 3.8125 LOW PASS.** Q2 (DF join shape) delivered a clean 4.875 on bulletproofed content; Q3 (TopN plain vs aggregate) introduced a NEW confident-inaccuracy in a previously-untested federation angle. **Net federation topic moves from 4.4922 to 4.4904 — DOWN -0.0018, regression after a 5-iter trending-up streak; topic now 0.0096 below threshold (was 0.0078).**
3. **Q4 STRONG (4.625)** — expire_snapshots retention floor: 7d default hard floor REJECTS shorter retention with clear error message, Spark = no floor escape hatch; engine-disambiguation clean; footgun assessment correctly framed as LOW (engineer gets clear error not silent loss).

---

## Critical confirmations (explicit)

### (a) Is the iter419 API-confusion RESOLVED?

**YES — FULLY RESOLVED in one iteration.** Q1 4.875 STRONG. Responder leads with the canonical Iceberg-1.5.x DataFrameWriterV2 forms (`writeTo().create()` first-time, `.append()` nightly, with `.using('iceberg').partitionedBy(...).tableProperty(...)` chain for table creation), explicitly calls out that legacy `.write.format('iceberg').mode('append').save()` and `.saveAsTable()` do NOT work cleanly with the SparkCatalog plugin, and includes the SparkCatalog+HMS config block. Zero hits on the legacy save()/saveAsTable form in the answer. Verified against iceberg.apache.org/docs/1.5.0/spark-writes/.

The teacher's iter420 strategy (TOP-OF-DOC CALLOUT #1 API-CONFUSION GUARDRAIL + TOP-OF-DOC CALLOUT #2 leading worked example closing with `.writeTo().append()` + r10 legacy example replacement) is now a proven recovery pattern for API-confusion failures.

### (b) Any NEW confident-inaccuracy or self-contradiction in iter420?

**YES — Q3 self-contradictory framing within a single answer.** For Query 1 (plain `ORDER BY created_at DESC LIMIT 50`, no WHERE) on the PostgreSQL connector:

- Responder FIRST says: "Trino pulls ALL rows, Postgres does NO work, this is slow"
- Responder THEN says: "TopN pushdown CAN fire since release 353, EXPLAIN signature = sortOrder+limit inside TableScan with no TopN operator above means it pushed"

**These two framings contradict each other.** If TopN pushdown fires, Postgres returns only 50 rows (NOT all rows); Trino does NOT pull all rows. Verified via trino.io/docs/current/release/release-353.html ("In Release 353, Trino improved performance of queries with ORDER BY ... LIMIT clause when the computation can be pushed down to the underlying database... topn-pushdown.enabled") and release-354 ("the optimization is now enabled by default"). Plain `ORDER BY created_at DESC LIMIT 50` on a PostgreSQL connector on Trino 467 SHOULD push the sort+limit to Postgres; Postgres returns only 50 rows.

This is **structurally different** from the iter419 self-contradiction-with-resource pattern: iter419's contradiction was between the responder's answer and the resource's myth box; iter420's contradiction is **within a single paragraph of the response itself**. The engineer reading this answer gets two opposite mental models about the same query and cannot tell which one is correct.

The Q2 (GROUP BY + aggregate ORDER BY + LIMIT does NOT push, Trino pulls all rows aggregates in memory) framing is correct. The fix-recommendation (add a WHERE time filter that pushes) is correct. The net answer DOES eventually land at the right place, but the leading framing for Query 1 is the WRONG mental model.

**Penalty applied:** Q3 technical accuracy 3.5; completeness 4.0; practical applicability 3.75; clarity 4.0 — avg 3.8125 LOW PASS.

### (c) Federation topic — does it cross 4.5?

**NO — federation topic moved from 4.4922 DOWN to 4.4904** (-0.0018). The Q2 4.875 contribution was strong but the Q3 3.8125 contribution dragged the topic backward. **Topic is now 0.0096 below the 4.5 threshold (was 0.0078).** This is a **regression after the 5-iter trending-up streak (iter415 4.625 → iter417 4.75 → iter418 4.625 → iter419 [Q1+Q2 4.875 each])**. **20th consecutive iteration stuck below threshold.**

The Q2 4.875 result PROVES the bulletproofing strategy still works on previously-targeted angles (DF join shape, predicate pushdown). The Q3 LOW PASS shows the topic still has unexplored angles where myth-buster gaps surface (plain ORDER BY+LIMIT TopN pushdown vs aggregate ORDER BY non-push).

---

## Per-question scoring

### Q1 — Spark write API durability re-probe (Postgres-to-Iceberg ingestion)

**Scores: 5.0 / 4.75 / 5.0 / 4.75 — avg 4.875 STRONG PASS**

What landed:
- First-time table creation: `df.writeTo('iceberg.analytics.events').using('iceberg').partitionedBy(...).tableProperty(...).create()` — VERIFIED CANONICAL against iceberg.apache.org/docs/1.5.0/spark-writes/.
- Nightly incremental: `df.writeTo('iceberg.analytics.events').append()` — VERIFIED CANONICAL.
- Explicit DO NOT callout on `.write.format('iceberg').mode('append').save()` and `.saveAsTable()` — CORRECT (these legacy forms do not work cleanly with the SparkCatalog plugin).
- SparkCatalog + HMS config block included — CORRECT (`spark.sql.catalog.iceberg=org.apache.iceberg.spark.SparkCatalog` + `spark.sql.catalog.iceberg.type=hive` + `spark.sql.catalog.iceberg.uri=thrift://hms:9083`).
- Idempotent backfill via `.overwritePartitions()`, full table replacement via `.createOrReplace()` — mentioned as the canonical forms for those intents.

**Verdict:** STRONG PASS. The iter419 API-confusion is fully resolved. The teacher's bulletproofing-via-leading-canonical-example strategy delivered exactly what it was designed to: the FIRST worked example the responder hits in r13 is the canonical `.writeTo().append()` form, and the responder pattern-matched the leading example.

### Q2 — Dynamic filtering join shape (Trino federation / cross-source connectors)

**Scores: 5.0 / 4.75 / 5.0 / 4.75 — avg 4.875 STRONG PASS**

What landed:
- Small Postgres = build side, large Iceberg = probe side — VERIFIED against trino.io/docs/current/admin/dynamic-filtering.html ("the smaller dimension table needs to be chosen as a join's build side").
- INNER and RIGHT JOIN only with =/</<=/>/>=/IS NOT DISTINCT FROM, semi-join with IN — VERIFIED verbatim.
- DF derives runtime IN-list from build keys, pushes to Iceberg scan to prune files via min/max — CORRECT canonical mechanism.
- Postgres-side equality predicate pushes first so CBO sees small side, picks small as build — CORRECT.
- EXPLAIN ANALYZE VERBOSE: `dynamicFilterSplitsProcessed > 0` + `RemoteExchange[BROADCAST]` annotation as runtime proof — CORRECT.
- `enable_dynamic_filtering` default true on Trino 467 — VERIFIED.

**Verdict:** STRONG PASS. Bulletproofed content from iter419 r22 hardening continues to deliver 4.75+ federation on this angle.

### Q3 — TopN plain vs aggregate (Trino federation / cross-source connectors)

**Scores: 3.5 / 4.0 / 3.75 / 4.0 — avg 3.8125 LOW PASS**

What landed (mixed):
- Query 1 (plain `ORDER BY created_at DESC LIMIT 50`, no WHERE): **SELF-CONTRADICTORY framing**. First says "Trino pulls ALL rows, Postgres does NO work, slow" THEN says "TopN pushdown CAN fire since release 353, EXPLAIN signature = sortOrder+limit inside TableScan, no TopN operator above". These two framings cannot both be true for the same query. Verified via trino.io/docs/current/release/release-353.html + release-354.html: plain ORDER BY+LIMIT TopN pushdown is enabled by default since 354, so plain ORDER BY+LIMIT on a PostgreSQL connector on Trino 467 SHOULD push — Postgres returns only 50 rows.
- Query 2 (GROUP BY customer_id + ORDER BY COUNT(*) DESC + LIMIT 50): does NOT push, Trino pulls all rows and aggregates in memory — CORRECT.
- Fix recommendation: add a WHERE time filter that pushes to bound the Postgres scan — CORRECT.
- EXPLAIN signature description (sortOrder+limit inside TableScan, no TopN operator above = pushed) — CORRECT in isolation, but contradicts the leading "Postgres does NO work" framing.

**Verdict:** LOW PASS. Engineer reading this gets two opposite mental models about plain ORDER BY+LIMIT. The leading "Trino pulls ALL rows" framing is the WRONG mental model and would mislead the engineer into treating plain ORDER BY+LIMIT as a federation anti-pattern when it pushes cleanly since release 354 (Mar 2021).

### Q4 — expire_snapshots retention floor (Iceberg table maintenance)

**Scores: 4.75 / 4.5 / 4.75 / 4.5 — avg 4.625 STRONG PASS**

What landed:
- 7-day default hard floor enforced by Trino 467 — VERIFIED against trino.io/docs/current/connector/iceberg.html + Starburst forum.
- Shorter retention (e.g., 1h) is REJECTED with explicit error message ("Retention specified (1.00d) is shorter than the minimum retention configured in the system (7.00d)") — VERIFIED CORRECT.
- NO silent clamping — protection is via hard reject, not silent adjustment.
- Spark has NO floor (sub-7d retention works directly) — CORRECT engine-disambiguation.
- Override path: lower `iceberg.expire-snapshots.min-retention` catalog property + Trino coordinator restart — CORRECT.
- Footgun assessment LOW — CORRECT (engineer gets a clear error, not silent loss of recent snapshots).

**Verdict:** STRONG PASS. Small nudge in completeness for not foregrounding the `retain_last` parameter (defaults to 1, preserves N most-recent ancestors regardless of retention_threshold) as an additional safety knob.

---

## Pattern across all four answers

| Q | Score | Verdict |
|---|---|---|
| Q1 | 4.875 | STRONG PASS — iter419 API-confusion FULLY RESOLVED (canonical DataFrameWriterV2 forms) |
| Q2 | 4.875 | STRONG PASS — federation DF join shape clean on bulletproofed content |
| Q3 | 3.8125 | LOW PASS — NEW self-contradiction WITHIN a single answer (plain ORDER BY+LIMIT TopN) |
| Q4 | 4.625 | STRONG PASS — expire_snapshots floor REJECT semantics correct |

**Average 4.547 PASS** — nineteenth consecutive overall PASS, -0.031 step-down from iter419 4.578. **The headline is structural:**
- The teacher's r13 bulletproofing strategy (lead with canonical worked example + DO NOT callouts on legacy forms) RESOLVED the iter419 API-confusion in one iteration.
- A NEW failure mode emerged: self-contradictory framing WITHIN a single answer (Q3 first says "Trino pulls all rows" then says "TopN pushdown fires" for the same query).
- Federation topic moved DOWN -0.0018 to 4.4904 (0.0096 below threshold, was 0.0078; 20th consecutive iter below threshold; regression after 5-iter trending-up streak).

**Failure-mode count: 7 of prior 19 iterations** (LOW PASS or worse on a federation question).

---

## Teacher actions next (iter 421)

1. **HIGH — TopN-pushdown durability fix for r22 (Trino federation).** The Q3 self-contradiction needs structural recovery: r22 must lead with a worked example "Plain ORDER BY+LIMIT on PostgreSQL connector — TopN pushdown fires by default since release 354" subsection that:
   - Closes with the canonical EXPLAIN signature (`sortOrder=[col DESC NULLS LAST], limit=50` inside the TableScan node, NO TopN operator above the scan).
   - Cites trino.io/docs/current/release/release-353.html + release-354.html verbatim ("the optimization is now enabled by default").
   - Adds an explicit DO NOT WRITE callout: "NEVER say 'Trino pulls ALL rows' for a plain ORDER BY+LIMIT on the PostgreSQL connector on Trino 467 — TopN pushdown is enabled by default since release 354 (Mar 2021); plain ORDER BY+LIMIT pushes the sort+limit to Postgres and only LIMIT rows are returned. The 'Trino pulls all rows' framing applies ONLY when GROUP BY + aggregate ORDER BY is involved (TopN cannot push through aggregation)."
   - Promotes a TopN-PUSHDOWN-vs-AGGREGATE-ORDER-BY disambiguation table to the top of the section, in the style of the iter418 ENGINE-CONFUSION GUARDRAIL and iter420 API-CONFUSION GUARDRAIL.

2. **MEDIUM — Trino federation topic threshold-push regression recovery.** Topic dropped from 4.4922 to 4.4904 (now 0.0096 below threshold, was 0.0078). One more Q3-style LOW PASS would push the topic to 0.0150+ below threshold (further from the threshold than at any point in iter410-420). Sustained 4.75+ federation answers needed for recovery; the iter420 Q2 4.875 result shows the bulletproofing strategy still works on previously-targeted angles.

3. **LOW — Carry-forward backlog:** HMS->Nessie write-freeze alternative; branches-vs-expire 3rd-angle; Snapshot vs serializable phantom-row 3rd-angle; Window NULL 2nd-angle; Iceberg v3 deletion vectors timeline; MERGE rollback; OPA-override timeout; schema registry compat; JWT+OPA concurrency.

---

## Judge probe targets next (iter 421)

1. **HIGH — TopN-pushdown durability RE-PROBE in NEW shape.** Probe whether the iter420 Q3 self-contradiction fix in r22 holds:
   - "Will `SELECT id FROM postgres.public.orders ORDER BY id DESC LIMIT 100` push the sort+limit to Postgres on Trino 467?" (direct re-probe).
   - "On Trino 467 + PostgreSQL connector, what does `SELECT customer_id, COUNT(*) FROM ... GROUP BY customer_id ORDER BY COUNT(*) DESC LIMIT 50` push to Postgres and what does it not?" (probes whether the GROUP BY + aggregate ORDER BY non-push case is correctly distinguished from plain TopN).
   - "EXPLAIN signature distinguishing pushed-TopN from in-memory-TopN — what should I look for?" (probes the EXPLAIN-reading skill).

2. **HIGH — Trino federation 6th-angle threshold-push continuation.** Topic is 0.0096 below threshold. Next federation question should target an angle where r22 is bulletproofed or where bulletproofing is feasible:
   - Aggregation pushdown to Postgres (when does SUM/COUNT/AVG push? what's the EXPLAIN signature? what's the aggregation_pushdown setting?).
   - Cross-catalog 3-way JOIN execution location (Postgres+Iceberg+Iceberg — which side dominates execution?).
   - Schema-evolution-with-pushdown (Postgres ADDs a new column mid-query — does the in-flight Trino plan still push the predicate?).
   - OR-with-mixed-types pushdown.

3. **MEDIUM — Iceberg branches-vs-expire 3rd-angle** carry-forward: "After running expire_snapshots, an old snapshot I thought was branch-protected is gone — why?"

4. **MEDIUM — Snapshot vs serializable phantom-row 3rd-angle** carry-forward.

5. **MEDIUM — HMS->Nessie 2nd-angle for write-freeze alternative** carry-forward.

6. **MEDIUM — Window NULL 2nd-angle (calendar-dim LEFT JOIN densification)** carry-forward.

7. **OPTIONAL — durability re-probe of iter420 Q1 API-confusion fix in a NEW shape**: e.g., "I want to do an idempotent backfill from Postgres to Iceberg for a single day partition — what's the Spark code?" probes whether `.overwritePartitions()` is used, NOT `mode('overwrite').save()`. "I'm bootstrapping a new Iceberg table from a Postgres dump — Spark recipe?" probes whether `.createOrReplace()` is used.

---

## Critical message to teacher for iter 421: a NEW failure mode requires a structural fix

The iter420 result is a clean **proof of concept** for the API-confusion recovery: the teacher's r13 bulletproofing (TOP-OF-DOC CALLOUTs + leading worked example + DO NOT callouts) resolved the iter419 self-contradiction in one iteration. **Q1 4.875 STRONG validates the bulletproofing-via-leading-canonical-example pattern.**

But the iter420 Q3 self-contradiction is **structurally different from any prior failure mode**: it is a self-contradiction WITHIN a single paragraph of the response itself (not a contradiction with the resource's myth box, not a contradiction with an authoritative source — a contradiction between two consecutive sentences). The recovery move must address the leading framing FIRST: the responder appears to have a default Postgres-federation mental model of "Trino pulls all rows when no WHERE clause" and only later corrects it with the TopN-pushdown nuance. The fix is to make the TopN-pushdown-fires framing the **leading mental model** for plain ORDER BY+LIMIT on the PostgreSQL connector, with the aggregate-ORDER-BY-non-push framing as the carefully-distinguished EXCEPTION.

**The pattern across iter402-420 is now durable:**
- Bulletproofed content delivers 4.75+ on the targeted angle.
- New failure modes appear in unexplored angles.
- Recovery within one iteration via leading-canonical-example bulletproofing is a proven pattern.
- The federation topic remains 0.0096 below the 4.5 threshold; sustained 4.75+ federation answers across two consecutive iterations are needed to cross.
