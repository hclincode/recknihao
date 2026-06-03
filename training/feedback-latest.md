# Judge Feedback — Iter 411 (EXTENDED PHASE — end-of-iteration only)

**Overall: 4.219 PASS** (Q1 4.875 STRONG + Q2 3.25 FAIL + Q3 4.375 STRONG + Q4 4.375 STRONG) — average clears the 3.5 PASS threshold by a comfortable margin and represents a slight up-tick from iter410 4.0. **Q1 FINDABILITY GAP FROM ITER410 IS FULLY RESOLVED.** But a NEW failure mode surfaced on Q2: SQL-dialect accuracy slip — responder recommended `QUALIFY` for a Trino 467 dedup-before-MERGE, but Trino does not support `QUALIFY` (it's a Snowflake/BigQuery/Databricks clause).

**Headline:**
1. **WIN — Q1 iter410 FINDABILITY FAILURE RESOLVED (4.875 STRONG, up from 2.625 FAIL).** Teacher's iter411 actions landed correctly: new dedicated `resources/26-iceberg-concurrent-write-conflicts.md` + bidirectional cross-links from resources 13 and 17 made the topic discoverable from BOTH likely entry points. Responder found and cited resource 26; technical content is correct and complete; the engineer gets a fully-actionable answer with literal Trino + Spark syntax.
2. **NEW FAIL — Q2 QUALIFY-not-in-Trino accuracy slip.** Recommending `QUALIFY ROW_NUMBER() ... = 1` in two places. Verified against trino.io/docs/current/sql/select.html and Starburst's 2024 feature-request thread: `QUALIFY` is NOT a supported Trino clause. Engineer would copy-paste the recommendation and get a SQL syntax error. The OTHER Q2 advice (fixed batch-window param, unique_key, pre-dedupe in source) is sound — only the dedup-pattern syntax is wrong.

**Pattern note:** tenth consecutive PASS (4.219). The Q1 fix demonstrates the teacher's findability-via-dedicated-resource-plus-cross-links pattern works durably. The Q2 failure is a NEW class — not content gap (iter408), not findability (iter410), but **SQL-dialect accuracy** (recommending non-Trino syntax on a Trino target). This is a teacher-side gap: the dbt/Iceberg/Trino dedup pattern needs a Trino-compatible literal example in resources/.

---

## Q1 — concurrent MERGE serializable vs snapshot, FINDABILITY RE-PROBE (RESOLVED)

**Scores: 5.0 / 4.5 / 5.0 / 5.0 — avg 4.875 STRONG PASS**

### Findability fix confirmed
- Responder cited `resources/26-iceberg-concurrent-write-conflicts.md` by name. The iter410 problem was that the responder searched resource 13 (ingestion) and didn't find the content buried in resource 17 (maintenance). Iter411 teacher's fix: a dedicated resource 26 with bidirectional cross-links from 13 and 17. The fix landed. The findability gap is RESOLVED.

### Technical content verified (all claims checked against official sources)
- **Two isolation levels — serializable (default) vs snapshot — CORRECT.** Verified against `iceberg.apache.org/javadoc/0.11.1/org/apache/iceberg/IsolationLevel.html` (the javadoc references serializable + snapshot as the two valid values).
- **Manifest-level min/max overlap check, conservative, false-positives on non-partition-column predicates — CORRECT.** Verified against Iceberg Apache mail-archives + Jack Vanlightly's "Iceberg Consistency Model Part 2" + AWS Glue blog on Iceberg concurrent writes (all describe the planner walking newly-added manifests and conservatively rejecting if min/max can't prove disjointness).
- **Snapshot isolation = only conflicts on actually-modified rows, phantom-row tradeoff — CORRECT.** Verified.
- **THREE properties write.delete/update/merge.isolation-level, all default 'serializable' — CORRECT.** Verified against `iceberg.apache.org/docs/latest/configuration/`. There is NO global `write.isolation-level` property.
- **ALTER TABLE SET PROPERTIES (Trino 467) and SET TBLPROPERTIES (Spark) — CORRECT** syntax for both.
- **`$properties` LIKE 'write.%.isolation-level' verification recipe — CORRECT** Trino Iceberg connector metadata table.
- **Recommendation of snapshot for append-mostly fact tables with disjoint-partition updates — CORRECT** and matches the canonical guidance in the Apache mail-archives discussion.
- **Table-level metadata read at write-plan time so applies to writes starting after commit — CORRECT.**

### Minor opportunities (not gating)
- Could mention `commit.retry.num-retries=4` default + retry semantics more explicitly (though resource 26 covers this in Section 5).
- Could call out that `ValidationException: Found conflicting files` is the diagnostic-friendly exception name.

### Verdict
**STRONG PASS. The iter410 FAIL is fully and durably recovered.** Engineer can act immediately with literal Trino syntax for the production stack.

---

## Q2 — dbt incremental MERGE duplicates after retry (NEW FAIL)

**Scores: 2.5 / 4.0 / 2.5 / 4.0 — avg 3.25 FAIL**

### What landed correctly
- **Idempotency framing is correct.** dbt incremental_strategy='merge' is idempotent only if the source SELECT is deterministic for a given param. Verified against `docs.getdbt.com/docs/build/incremental-models` and `docs.getdbt.com/best-practices/how-we-handle-real-time-data/2-incremental-patterns`.
- **Fixed batch-window date param instead of mutable watermark — CORRECT and is the canonical microbatch idempotency pattern.** Verified against dbt microbatch docs.
- **dbt unique_key native config — CORRECT.** Always set unique_key for merge strategy; columns must never be NULL — verified.
- **Pre-dedupe in the source so MERGE sees one row per key — CORRECT general practice.** Verified — the dbt community explicitly recommends `Always include deduplication in your SELECT rather than relying solely on unique_key`.

### What failed: SQL-DIALECT ACCURACY SLIP
- **Recommended `QUALIFY ROW_NUMBER() OVER (PARTITION BY key ORDER BY updated_at DESC) = 1` in two places (as a dedup pattern AND in the USING subquery).**
- **Trino 467 does NOT support the `QUALIFY` clause.** Verified against:
  - `trino.io/docs/current/sql/select.html` — no mention of QUALIFY in the SELECT grammar.
  - Starburst community forum thread "Available window functions and Qualify statement" (May 2024) — confirms QUALIFY is a feature request, not a supported clause.
  - `trino.io/docs/current/release/release-467.html` — Trino 467 release notes (December 2024) do not add QUALIFY.
- **Consequence:** the engineer copy-pastes the recommended SQL and gets a parse error. The advice is unusable on the production Trino 467 stack.
- **Correct Trino-compatible pattern** (the canonical workaround):
  ```sql
  SELECT * FROM (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY key ORDER BY updated_at DESC) AS rn
    FROM source
  )
  WHERE rn = 1
  ```
  Or equivalently a CTE-with-WHERE. This is the standard Trino dedup-before-MERGE pattern.

### Verdict
**FAIL on technical accuracy + practical applicability — the QUALIFY recommendation breaks on Trino 467.** The OTHER advice is sound, so this is a partial-fail not a total-miss, but the dedup-pattern syntax is the central deliverable of the answer and it doesn't run.

---

## Q3 — predicate pushdown Iceberg-Postgres federated join

**Scores: 4.5 / 4.0 / 4.5 / 4.5 — avg 4.375 STRONG PASS**

### What landed
- **Equality/IN/IS NULL/numeric-range pushed to Postgres by default — VERIFIED** against `trino.io/docs/current/connector/postgresql.html`.
- **VARCHAR range NOT pushed by default for collation safety — VERIFIED.** The Trino docs explicitly state range predicates on character types aren't pushed because remote data sources may sort strings differently than Trino.
- **Property name `postgresql.experimental.enable-string-pushdown-with-collate=true` — VERIFIED** against PR #9746 (`Support range predicate pushdown for string columns with collation in PostgreSQL connector`) and Trino 481 PostgreSQL connector docs.
- **Catalog property requires restart; session form `enable_string_pushdown_with_collate` exists — VERIFIED.**
- **Join runs on Trino workers with each side pushing its own per-source predicate — CORRECT** federation architecture.
- **EXPLAIN diagnostic (Filter ABOVE TableScan = residual not pushed; constraint INSIDE TableScan = pushed) — CORRECT** plan-pattern matching.

### Minor gaps
- No literal EXPLAIN output snippet showing the `TableScan[...constraint=...]` vs `ScanFilterProject -> TableScan` shapes (would help a beginner pattern-match).
- No mention of the equality-perf-regression footgun: enabling collation for range pushdown may disable PG indexes on equality predicates (per the Trino docs).

### Verdict
STRONG PASS. The property name is exact, the default-off claim is correct, and the EXPLAIN diagnostic is the canonical Trino federation pushdown verification.

---

## Q4 — system vs catalog-prefixed session properties

**Scores: 4.0 / 4.5 / 4.5 / 4.5 — avg 4.375 STRONG PASS**

### What landed
- **System props no-dot (query_max_execution_time, query_max_memory) — VERIFIED** against `trino.io/docs/current/sql/set-session.html`.
- **Catalog props dot-prefixed (catalog.property_name) — VERIFIED.**
- **SHOW SESSION reveals which is which via dot vs no-dot in the name column — CORRECT.**
- **RESET SESSION reverts — CORRECT.**
- **OPA may deny SetSystemSessionProperty — plausible and fits the prod OPA setup** (system properties change cluster-wide query behavior, so OPA policies often deny SET SYSTEM SESSION).
- **Session props apply to queries starting after SET — CORRECT.**
- **config.properties hard ceilings read-only at session — CORRECT.**

### Minor accuracy slip
- The responder cited `iceberg.expire_snapshots_min_retention` as a catalog-prefixed session property example. This is actually the catalog CONFIG property name (`iceberg.expire-snapshots.min-retention` in the catalog .properties file) — not a session-settable property. The structural claim (catalog session props use dot prefix) is still correct, but the specific example chosen is dubious. A better Iceberg session property example would be `iceberg.target_max_file_size` or `iceberg.statistics_enabled` (verified session-settable per the Iceberg connector docs).

### Verdict
STRONG PASS. Structural distinction between system and catalog session properties is correctly framed; OPA + JWT context is on-brand for the prod stack.

---

## Pattern across all four answers

| Q | Score | Verdict |
|---|---|---|
| Q1 | 4.875 | STRONG PASS — iter410 FINDABILITY FAILURE RESOLVED via resource 26 + cross-links |
| Q2 | 3.25 | FAIL — QUALIFY-not-in-Trino SQL-dialect accuracy slip |
| Q3 | 4.375 | STRONG PASS — federated pushdown property + EXPLAIN diagnostic exact |
| Q4 | 4.375 | STRONG PASS — system vs catalog session property structural distinction correct |

**Average 4.219 PASS** — clears the 3.5 threshold; tenth consecutive PASS in the iter394-411 window.

**Trajectory iter394-411:** `4.75P/3.125F/4.3125P/4.375P/4.34375P/4.09375P/4.0625P/3.8125F/4.59375P/3.875F/4.25P/4.6875P/4.40625P/4.625P/4.0625P/4.125P/4.5625P/4.0P/**4.219P**`. Slight up-tick from iter410, but a new failure mode (SQL-dialect accuracy) surfaces on Q2.

**Three distinct failure modes seen in extended phase so far:**
1. **Content gap** (iter408 Q2) — the answer was needed but no resource existed.
2. **Findability gap** (iter410 Q1) — the resource existed but in the wrong place.
3. **SQL-dialect accuracy gap** (iter411 Q2 — NEW) — the resource exists, the responder uses it, but recommends syntax from a different SQL dialect that doesn't work on Trino.

The teacher has fixed (1) and (2). The new (3) needs a resource-side fix: add a Trino-compatible dedup pattern with an explicit "QUALIFY is not supported in Trino; use this instead" note.

---

## Teacher actions next (iter 412)

1. **HIGH — Add Trino-compatible dedup pattern to dbt/Iceberg ingestion resources.** In `resources/13-postgres-to-iceberg-ingestion.md` (and/or a new dedicated dbt resource if one exists), add an explicit callout:
   - **"Trino 467 does NOT support the `QUALIFY` clause"** with a citation to `trino.io/docs/current/sql/select.html` and the Starburst forum thread.
   - **Canonical Trino dedup-before-MERGE pattern**:
     ```sql
     -- WRONG (Snowflake/BigQuery/Databricks syntax — fails on Trino):
     -- SELECT * FROM src QUALIFY ROW_NUMBER() OVER (PARTITION BY key ORDER BY updated_at DESC) = 1;

     -- RIGHT (Trino 467):
     SELECT * FROM (
       SELECT *,
              ROW_NUMBER() OVER (PARTITION BY key ORDER BY updated_at DESC) AS rn
       FROM src
     ) WHERE rn = 1;
     ```
   - Apply this pattern in the dbt incremental MERGE USING-subquery example so the literal recipe is copy-pasteable.
   - Cross-link from the dbt incremental section and any MERGE INTO section.

2. **LOW — Polish resource 26 with a Trino-compatible `$properties` example** showing the literal output rows (key/value pairs for write.delete/update/merge.isolation-level) so the engineer can pattern-match what they'll see.

3. **LOW — Q4 example polish.** In the catalog session properties section, replace `iceberg.expire_snapshots_min_retention` (which is actually a catalog CONFIG property) with a verified session-settable Iceberg example like `iceberg.target_max_file_size` or `iceberg.statistics_enabled`.

4. **LOW carry-forward backlog**: HMS->Nessie no-downtime, MERGE rollback, OPA-override timeout, schema registry compat, JWT+OPA concurrency, Iceberg tagging 3rd-angle, fs.cache JMX 3rd-angle, RANGE INTERVAL gap-day, equality delete 1.5.2 bug context, Iceberg v3 deletion vectors timeline.

---

## Judge probe targets next (iter 412)

1. **CRITICAL — Trino dedup pattern re-probe.** Same question phrasing ("dbt incremental MERGE producing duplicates after retry — how do I dedupe in the source?"). Confirms the responder NOW uses Trino-compatible `ROW_NUMBER() ... WHERE rn = 1` subquery instead of `QUALIFY`. Confirms iter411 Q2 fix lands.

2. **Trino SQL-dialect 2nd-angle** — a different question that probes SQL-dialect awareness. E.g., "how do I write a TOP-N-per-group query in Trino?" — confirms responder doesn't reach for `QUALIFY`, `TOP`, or other non-Trino syntax.

3. **write.isolation-level 3rd-angle DURABILITY** — confirms the iter411 Q1 win wasn't a one-shot. E.g., "when should I use snapshot isolation over serializable in Iceberg, and what's the phantom-row risk?" — probes the technical content directly from a different entry point.

4. **EXPLAIN TYPE IO predicate-pushdown 2nd-angle** — different phrasing of the iter410 Q3 win to confirm durability.

5. **HMS->Nessie no-downtime migration** carry-forward.

6. **Iceberg v3 deletion vectors timeline** carry-forward.

7. **Catalog vs system session property 2nd-angle** — e.g., "why does my SET SESSION work in one Trino client but get denied in another?" — probes OPA SetSystemSessionProperty deny semantics.
