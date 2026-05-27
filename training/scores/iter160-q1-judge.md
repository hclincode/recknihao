# Judge Report — Iter 160 Q1

**Question topic**: Cross-catalog Trino join (Iceberg 500M × Postgres 8M), 20-minute runtime / timeouts. What else can be done? Can Trino be "smarter" about how much each side reads?

**Topic checklist tag**: Trino federation / cross-source connectors (PostgreSQL connector, predicate pushdown, cross-catalog join limits, when to federate vs ingest)

---

## Scores

| Dimension | Score | Notes |
|---|---|---|
| Technical accuracy | 4 | Core concepts (dynamic filtering, ScanFilterProject, dynamicFilters annotation, build vs probe) are correct and verifiable against trino.io. Two small accuracy issues — see below. |
| Beginner clarity | 4 | Clear, well-paced, jargon is introduced with definitions ("build side = smaller side", "probe side"). Mild assumption that the reader can read EXPLAIN output, but the answer tells them exactly which lines to look for. |
| Practical applicability | 5 | Crisp 4-step recipe (add selective Postgres WHERE → verify pushdown via ScanFilterProject → verify dynamicFilters fires on Iceberg side → check join direction). Engineer knows exactly what to do next. Includes a useful "when federation is the wrong tool" escape hatch. |
| Completeness | 4 | Addresses both parts of the question (what else to do AND can Trino be smarter about read volume). Covers dynamic filtering, predicate pushdown, build/probe, EXPLAIN verification, and the "ingest instead" fallback. Missing: explicit mention that the PostgreSQL connector waits up to ~20 s for dynamic filters by default (relevant to "timeouts"); no mention of broadcast vs partitioned join behavior or `join_distribution_type` session property; no mention of the prod stack's on-prem Trino 467 / Iceberg specifics, but those aren't strictly required here. |

**Weighted average**: (4×2 + 4 + 5 + 4) / 5 = **4.20**

**Pass threshold for this topic**: ≥ 4.5 (overridden — see rubric). **This answer does NOT meet the topic-specific bar of 4.5**, though it would pass the default 3.5 bar comfortably.

---

## Technical verification

### Verified correct via WebSearch (trino.io/docs/current/admin/dynamic-filtering.html, .../optimizer/pushdown.html, .../connector/postgresql.html):

1. **Dynamic filtering pushes build-side keys back to probe-side scan** — CORRECT. Trino collects candidate values from the dimension (build) side and pushes runtime predicates into the local table scan on the probe side. The answer's framing ("Trino builds a small list of join keys from the Postgres side and pushes that list back into the Iceberg scan") matches the official mechanism.

2. **`EXPLAIN (TYPE DISTRIBUTED)` is the right command** — CORRECT. This is the standard way to inspect distributed plan and see dynamic-filter assignments.

3. **`ScanFilterProject` is the correct node name** — CORRECT. Trino docs and Starburst docs both reference dynamic-filter annotations appearing on `ScanFilterProject` operators.

4. **`dynamicFilters = {...}` is the correct annotation** — CORRECT. Documented as `dynamicFilter` / `dynamicFilters` predicate on the operator in the EXPLAIN output.

5. **PostgreSQL connector range predicate on string types is NOT pushed down by default** — CORRECT (this is the underlying mechanism behind the answer's "string-range predicates won't push down by default" claim). Per trino.io PostgreSQL connector docs: "The connector does not support pushdown of range predicates, such as >, <, or BETWEEN, on columns with character string types like CHAR or VARCHAR." Equality (=, IN, !=) IS pushed down. The answer applies this concept to the *Iceberg* side as well, which deserves a closer look (see issue #1 below).

6. **"Postgres join index doesn't reduce Iceberg rows" reasoning** — CORRECT. The index helps Postgres serve lookups quickly but does not propagate into Iceberg-side pruning unless dynamic filtering bridges the two.

7. **Build side = smaller side for dynamic filtering** — CORRECT. Per docs: "In order for dynamic filtering to work, the smaller dimension table needs to be chosen as a join's build side." The answer's step 4 correctly nudges the engineer to verify this.

### Two accuracy issues:

**Issue 1 — string-range pushdown example is misapplied to Iceberg.**
The answer says: *"If your WHERE clause on the Iceberg side is something like `WHERE event_timestamp LIKE '2026-05%'` (a string range), that won't push down to Iceberg by default — Trino will filter in-memory after pulling rows."*

- The "string range won't push down" rule is a documented limitation of the **PostgreSQL/JDBC connector**, not a hard rule of the **Iceberg connector**. The Iceberg connector handles LIKE pushdown differently and the broader issue with `LIKE '2026-05%'` on an `event_timestamp` column is actually that the column is presumably a TIMESTAMP type (so the LIKE wouldn't even apply without casting), not that string-range pushdown is the limiter.
- The corrective advice ("use an exact timestamp range with `TIMESTAMP '2026-05-01'` boundaries to enable partition/file pruning") is still **good practice** and matches the Trino blog "Just the right time date predicates with Iceberg." So the recommendation is right, but the stated reason is muddled — the real reason is that a timestamp-typed comparison enables Iceberg's partition transform pruning (e.g., `day(ts)`), whereas a LIKE on a string would not.

**Issue 2 — slight over-claim on the "20 minutes is almost certainly Trino scanning all 500M rows."**
The answer leads with this as the diagnosis. It's a plausible top hypothesis but not the only one — JDBC pull of 8M Postgres rows over a single split, lack of broadcast join, or PostgreSQL connector's dynamic-filter wait timeout (~20 s) all contribute. The answer recovers later by acknowledging "if the Postgres result set is large," but the opening sentence is overly confident.

### Missing nuance (would lift completeness from 4 to 5):

- **PostgreSQL connector dynamic-filter wait** — the connector waits up to 20 s for dynamic filters before launching the JDBC query (`dynamic-filtering.wait-timeout`). Worth a one-liner since the user mentioned 20-minute runtimes and timeouts.
- **`enable-large-dynamic-filters` / domain-compaction-threshold** — if the build side is moderately large (a few hundred thousand keys), dynamic filtering can degrade to min/max ranges. The answer hints at this ("over ~1,000 distinct join keys") but doesn't name the property the prod team could tune.
- **Broadcast vs partitioned join** — dynamic filtering with full per-value predicates is most effective with broadcast joins; with partitioned (distributed hash) joins, filters degrade to min/max. The answer's "check your join direction" hand-waves this; could name `join_distribution_type`.
- **Prod stack fit** — the user is on Trino 467 on-prem with Iceberg + MinIO. The answer is stack-agnostic. Everything it recommends works on 467, but a one-line "all of this is available on Trino 467, no config changes required — dynamic filtering is on by default" would add confidence.

---

## Recommendation to teacher (since topic is still NEEDS WORK and threshold is 4.5)

The topic now has 2 questions asked (iter158 Q1 and iter160 Q1) and the running average is `(4.0 + 4.2) / 2 = 4.10`. Still below the 4.5 override threshold, so the topic remains **NEEDS WORK**.

To get the next answer over 4.5, the resources/22 file should:

1. **Disambiguate string-range pushdown by connector.** Make explicit that the "no range pushdown on strings" rule applies to the **JDBC family (PostgreSQL, MySQL, SQL Server)**, not Iceberg. For Iceberg, the corresponding caveat is *partition-transform-aware predicate shape* (use `TIMESTAMP` literals matching the partition transform granularity).

2. **Add the PostgreSQL connector dynamic-filtering wait timeout** (`dynamic-filtering.wait-timeout`, default 20 s) and the `enable-large-dynamic-filters` / `domain-compaction-threshold` knobs. These are exactly the levers an oncall engineer needs when "the Postgres side is a bit too big for default DF."

3. **Add broadcast vs partitioned join behavior of dynamic filtering** — broadcast preserves per-value predicates; partitioned degrades to min/max. Reference `join_distribution_type` session property.

4. **One worked example with Trino 467 specifically named** so future answers can ground recommendations in the prod stack.

---

## Final score: **4.20 (weighted)** — fails the 4.5 topic-specific bar; passes the default 3.5.

Topic status: remains **NEEDS WORK**. Running 2-question average for the topic: **4.10**.
