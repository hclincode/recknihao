# Iteration 1256 — Judge Feedback

## Verdict

**Overall: 4.578 PASS — THREE of FOUR aged watches close cleanly; the FOURTH (iter1230 EXISTS-over-warning) RECURS as 2nd instance under a DIFFERENT framing (DBA blanket-claim shape) — LIGHT FIX-A WARRANTED on findability/emphasis-imbalance at r28 §711 myth-row neighborhood. Q1 (4.5) DF-wait-timeout failure mode now surfaced verbatim — iter1239 DF-wait-timeout watch CLOSES. Q2 (4.9375) PARTITIONED canonical pin-perfect for BOTH-LARGE shape — iter1238 broadcast-hedge watch was scoped to SMALL-DIM shape (NOT re-probed here, REMAINS OPEN). Q4 (5.0) ::cast → CAST/TRY_CAST canonical with no `::` slip and no broken secondary — iter1230 ::cast watch CLOSES. Q3 (3.875) functional rewrite correct + correct EXPLAIN-verify advice BUT framing OVER-WARNS ("never use EXISTS in production / don't trust the optimizer even if EXPLAIN shows it got lucky") — amplifies the DBA's non-Trino import for THIS shape (simple equality EXISTS that Trino 467 reliably decorrelates).**

---

## Aged-watch closure ledger

| Watch (origin iter) | Outcome | Evidence |
|---|---|---|
| iter1239 Q1 dynamic-filtering wait-timeout (Iceberg, 1s default, build-side slow → probe-side starts unfiltered) | **CLOSES** | This iter Q1 surfaced exact property name + default + symptom verbatim ("iceberg.dynamic-filtering.wait-timeout, default ~1s; if build side slow, probe starts scanning unfiltered; increase to 10-20s"). |
| iter1238 Q3 broadcast-hedge on SMALL dim (PARTITIONED-safer wrong-direction recall on small dim + large fact) | **REMAINS OPEN** | This iter's Q2 was BOTH-LARGE shape (800M × 200M), where PARTITIONED IS the canonical lead. The iter1238 watched shape (small dim joining large fact + OOM) was NOT re-probed under that framing. Responder reads BOTH-LARGE shape correctly (no false-positive evidence of generalization), but no negative evidence the small-dim hedge is gone either. Re-probe under "small dim + large fact + OOM / how to broadcast" framing next sweep to close. |
| iter1230 Q2 EXISTS-over-warning (responder amplifies "EXISTS = O(N×M) on Trino, must rewrite") | **RECURS — 2nd instance, different framing** | This iter Q3 (DBA blanket-claim shape) reproduces the over-warning under a new framing: "Do NOT use EXISTS subqueries in production on Trino — rewrite to JOIN/IN even if EXPLAIN shows the optimizer got lucky." LIGHT FIX-A recommended below. |
| iter1230 Q3 ::cast slip (Postgres double-colon leaked into illustrative SQL) | **CLOSES** | This iter Q4 explicitly defanged `event_ts::DATE` as a Postgres/Snowflake-ism → CAST(event_ts AS DATE), affirmed TRY_CAST + try() distinctions correctly. No `::` slip anywhere in the four answers. |

---

## Per-question detail

### Q1 — DF confirmation metric + silent-not-fire reasons on 500M×12K star join

**Score: 4.5** (Acc 4.5 / Clar 4.5 / Prac 4.5 / Compl 4.5)

**What landed (FIX-A reach — iter1239 DF-wait-timeout watch CLOSES):**

- **Metric**: `EXPLAIN ANALYZE VERBOSE` → look at the `events` (fact) TableScan operator output for `dynamicFilterSplitsProcessed`; if 0, DF never reached the scan. Verified verbatim at [trino.io/docs/467/admin/dynamic-filtering.html](https://trino.io/docs/467/admin/dynamic-filtering.html): *"dynamicFilterSplitsProcessed records the number of splits processed after a dynamic filter is pushed down to the table scan"* (also documented in r28 §750 + r03 §483 + r22 §3214/§3282).
- **Reason 1 — JOIN-type limitation**: LEFT/FULL OUTER joins disable DF; only INNER and RIGHT (and semi/IN) participate — correct per docs (note: this fact factually correct but the engineer's symptom in the prompt was already an INNER star join, so this reason doesn't bite their case).
- **Reason 2 — Build-side size limit**: distinct-values-per-driver / bytes-per-driver thresholds (`dynamic-filtering.{small,small-partitioned,large,large-partitioned}.max-{distinct-values,size,range-row-limit}-per-driver`), `enable_large_dynamic_filters` default OFF → DF abandons when build exceeds the small-side budget — correct mental model.
- **Reason 3 — Collection TIMEOUT**: **`iceberg.dynamic-filtering.wait-timeout` (default 1s) — if the build side hasn't produced its bloom/value-set in 1s, probe-side TableScan begins UNFILTERED** and `dynamicFilterSplitsProcessed` reads 0 even though the rule was wired up. **The exact load-bearing failure mode iter1239 missed.** Verified at [raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/connector/iceberg.md](https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/connector/iceberg.md): *"`iceberg.dynamic-filtering.wait-timeout` — Maximum duration to wait for completion of dynamic filters during split generation. Default: `1s`"* (catalog-level config property in `etc/catalog/iceberg.properties`).
- **Reason 4 — File-level pruning**: filter didn't push to file level (min/max stats) — partly tangential to DF specifically but correct ambient guidance.
- **Routing for the 500M×12K-to-1-row case**: "likely a timeout — if `dynamicFilterSplitsProcessed=0`, raise the wait-timeout" — exactly the right diagnostic-to-action lever.

**Minor imprecision (-0.5 Acc):** The wait-timeout is a **catalog-level config property** (`etc/catalog/iceberg.properties`) — NOT a session property. The responder framed "increase to 10-20s" without naming the configuration surface (no SET SESSION form for this property; needs property file edit + coordinator restart, OR Trino dynamic config reload depending on deployment). On the on-prem k8s stack per `prod_info.md`, this requires a ConfigMap update + coordinator pod restart — non-trivial to spike-tune mid-incident.

**Minor structural note:** Hive connector has a sibling `hive.dynamic-filtering.wait-timeout` (different connector, same default 1s); JDBC connectors (Postgres/MySQL) also have analogous waits (often longer defaults). The responder named the iceberg-prefixed form correctly for this Iceberg-only stack.

**Verifies against:**
- [trino.io/docs/467/admin/dynamic-filtering.html](https://trino.io/docs/467/admin/dynamic-filtering.html) — `dynamicFilterSplitsProcessed` metric definition
- [raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/connector/iceberg.md](https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/connector/iceberg.md) — `iceberg.dynamic-filtering.wait-timeout` default 1s
- [trinodb/trino issue #11600](https://github.com/trinodb/trino/issues/11600) — cross-connector wait-timeout family

---

### Q2 — events 800M × sessions 200M, OOM / 40-min spill, both tables large

**Score: 4.9375** (Acc 5.0 / Clar 4.75 / Prac 5.0 / Compl 5.0)

**Pin-perfect PARTITIONED-for-BOTH-LARGE canonical.** All load-bearing facts correct:

- **Broadcast valid for large-to-large? NO — OOMs faster** because BROADCAST replicates the build side to every worker. With a 200M-row build, every worker gets the entire 200M (~5-50GB depending on column widths) into memory → OOMs faster than the spill-grind it was doing under AUTOMATIC.
- **Right strategy: PARTITIONED** (hash-shuffle BOTH sides by `session_id`) — bounds per-worker memory, only matching keys land on the same worker. The only viable choice for large-to-large joins at this scale.
- **Force**: `SET SESSION join_distribution_type = 'PARTITIONED'` (correct property name + valid values per [trino.io/docs/467/admin/properties-general.html](https://trino.io/docs/467/admin/properties-general.html) verbatim) OR dbt-trino `{{ config(pre_hook="SET SESSION join_distribution_type = 'PARTITIONED'") }}` for per-model pinning — production-stack-aligned.
- **NO query hints in Trino 467**: `/*+ BROADCAST */` is silently ignored as a block comment (verified at [trinodb/trino #9498](https://github.com/trinodb/trino/issues/9498) open since Oct 2021). Engineer who pastes Oracle/SQL Server hint syntax expects the hint to fire and gets no error AND no behavior change — important defang.
- **ANALYZE both tables** so CBO sees row-count + NDV — correct durable fix.
- **`EXPLAIN (TYPE DISTRIBUTED)`** → verify `Join[INNER][HASH]` / `RemoteExchange[REPARTITION]` (PARTITIONED) NOT `RemoteExchange[REPLICATE]` (BROADCAST).
- **Salt skew** — if one `session_id` holds disproportionately many rows (one worker bears 90% of the load), salt the join key with a random bucket → bounded fan-out + post-join re-aggregation. Correctly identified as the next lever if PARTITIONED still skews on one worker.

**Minor clarity shave (-0.25):** "rehashed both sides" terminology assumes the reader knows what hash-partitioning means; a one-sentence "each row routed to a specific worker by hash(session_id) so matching rows from both tables land on the same worker" would fully zero-assumption it (same shave as iter1203 Q1).

**iter1238 broadcast-hedge watch:** REMAINS OPEN — this iter's shape (both large) is OPPOSITE the iter1238 watched shape (small dim + large fact + OOM where responder hedged PARTITIONED-safer wrong-direction). Responder correctly recommended PARTITIONED here; small-dim shape not tested. Re-probe under "small dim + large fact + OOM / how to broadcast" framing next sweep to close the original watch direction.

**Verifies against:**
- [trino.io/docs/467/admin/properties-general.html](https://trino.io/docs/467/admin/properties-general.html) — `join_distribution_type` property valid values
- [trinodb/trino #9498](https://github.com/trinodb/trino/issues/9498) — no `/*+ */` hint support
- r28 §712 (the "BROADCAST faster than PARTITIONED" myth-row already correctly anchors the lever)

---

### Q3 — Oracle EXISTS simple-equality-correlated; DBA says "rewrite all correlated subqueries"

**Score: 3.875** (Acc 3.5 / Clar 4.0 / Prac 4.0 / Compl 4.0)

**The 2nd instance of EXISTS-over-warning (iter1230 was the 1st under "Postgres-instinct rewrite as JOIN" framing; iter1256 is the 2nd under "DBA blanket-claim" framing).**

**What's CORRECT in the responder's answer:**

- `EXPLAIN` to disambiguate `SemiJoin` (fast — decorrelation fired) vs `CorrelatedJoin` (slow — nested loop) — load-bearing diagnostic.
- Idiomatic rewrites: `INNER JOIN + DISTINCT` and `IN (SELECT ...)` (Trino converts to SemiJoin) — both functionally correct + equivalent for this shape.
- `NOT EXISTS` / `NOT IN` NULL-trap awareness implied (responder didn't explicitly warn about NULL but stayed within positive-EXISTS territory).

**What's WRONG / OVER-WARNING (the load-bearing slip):**

The engineer's EXISTS is **simple equality correlation** with a **non-correlated subquery filter**:
```sql
SELECT u.user_id, u.email
FROM users u
WHERE EXISTS (
  SELECT 1 FROM actions a
  WHERE a.user_id = u.user_id    -- equality correlation (simple)
    AND a.action_type = 'premium_upgrade'   -- non-correlated filter
)
```

**For THIS shape, Trino 467 RELIABLY decorrelates into SemiJoin.** This is verified by:
- r28 §849 conversion table verbatim: *"`SELECT ... FROM a WHERE EXISTS (SELECT 1 FROM b WHERE b.id = a.id)` → `SELECT a.* FROM a WHERE a.id IN (SELECT id FROM b)` (Trino converts to SemiJoin) OR explicit JOIN ... DISTINCT"* — the resource explicitly classifies THIS shape as the SemiJoin-converting one.
- r28 §711 myth-row lists the FAILING shapes: *"aggregates inside the correlated subquery referencing outer cols, correlated WHERE with non-equality conditions, complex outer-references"* — simple-equality EXISTS with a scalar filter is **none of those**.
- r23 §2793-2799 physical-operators reference: *"you want `SemiJoin` in your EXPLAIN output for IN / EXISTS / NOT EXISTS / NOT IN"* — confirms the canonical good shape for this pattern.
- Verified via [trino.io/episodes/7.html](https://trino.io/episodes/7.html) (Trino podcast ep 7 on decorrelation) + [trinodb/trino PR #1415](https://github.com/trinodb/trino/pull/1415) (decorrelate subqueries with Limit/TopN) + [trinodb/trino issue #21859](https://github.com/trinodb/trino/issues/21859) (open perf bug is on **NOT EXISTS specifically** — LeftJoin+Aggregation expansion — NOT plain EXISTS).

**So the DBA's blanket claim** *"correlated subqueries are slow in Trino, rewrite as join"* **is a NON-TRINO IMPORT for THIS shape.** It's a true-for-Oracle / true-for-Postgres-without-decorrelation rule that the DBA carried into the Trino conversation without scoping it to the failing-decorrelation shapes.

**The responder OVER-WARNED:**
- "Trino ATTEMPTS to decorrelate but when decorrelation FAILS you get CorrelatedJoin O(N×M)... 5M scans" — true conditionally, but the prompt's shape is in the **decorrelation-SUCCEEDS** branch, NOT the FAILS branch.
- "Do NOT rely on the optimizer. EXPLAIN; if SemiJoin → fast, if CorrelatedJoin → nested-loop 5M scans" — the EXPLAIN advice is sound, but the framing assumes the optimizer might fail on this shape (it won't).
- **"Idiomatic rewrite (use regardless, don't wait for EXPLAIN)... Do NOT use EXISTS subqueries in production on Trino — rewrite to JOIN/IN even if EXPLAIN shows the optimizer got lucky"** — this is the load-bearing slip. The responder amplifies the DBA's myth instead of debunking it. For simple equality EXISTS, the optimizer does NOT "get lucky" — it RELIABLY decorrelates. Telling the engineer to always rewrite is over-rewriting; some shapes (the one in front of them) are fine as-is.

**Engineer takeaway:** functionally correct (the rewrite works + is equivalent), so the migrated query is fine; but the engineer leaves with the wrong mental model — "Trino can't handle correlated EXISTS reliably, always rewrite" — which (a) costs reviewer attention on subsequent migrations they'd otherwise leave as-is, (b) reinforces the DBA's misclassification, (c) makes the responder unable to provide reassurance against the genuinely-non-Trino imports.

---

### Q3 FIX-A decision — LIGHT FIX-A on r28 findability/emphasis-imbalance

**RECOMMENDATION: LIGHT FIX-A — additive reassurance anchor at r28 §711 myth-row neighborhood.** The case for FIX-A vs FOLKLORE-NO-FIX:

**Case for FOLKLORE-NO-FIX (per pinned `feedback_responder_overwarning_folklore.md`):**
- Over-warning on a fine simple construct is recall-ceiling, NOT a resource defect.
- §849 already correctly classifies this shape as SemiJoin-converting.
- §711 already correctly lists the FAILING shapes (the responder didn't pick that nuance up).
- Adding more content risks `feedback_new_card_over_attracts_adjacent.md` over-attractor regression on neighboring "all correlated subqueries are bad" questions.
- Engineer arrives at a correct functional rewrite either way.

**Case for LIGHT FIX-A (escalation criteria met):**
- **2nd instance of the same over-warning class** under DIFFERENT framings (iter1230 Postgres-instinct + iter1256 DBA-blanket-claim). Two angles = pass-threshold escalation per rubric framing.
- The DOMINANT framing in r28 IS alarmist:
  - §15 "Correlated subqueries are the **migration-shaped slowness champion**" (lead-with-danger framing).
  - §711 myth-row "PARTIALLY TRUE and partially **DANGEROUS**" (danger-word).
  - §773 section header "Correlated subqueries — the **migration slowness champion**".
  - §775 "they look harmless in source, and they sometimes work fine... and sometimes catastrophically... **both shapes are common**; you can't tell which by reading the SQL".
  - That "you can't tell which by reading the SQL" line is the **specific framing that leads the responder to over-warn**. It's overstated: for the SIMPLE-EQUALITY EXISTS shape, you CAN tell by reading the SQL.
- §849 conversion table is correct-but-buried — a single row in a 6-row table at line 849, with no keyword-magnet for "is my EXISTS the kind that decorrelates" / "do I need to rewrite my simple equality EXISTS".
- **The reassurance anchor** ("SIMPLE equality EXISTS with non-aggregate, non-correlated-LIMIT/TopN subquery body RELIABLY decorrelates to SemiJoin — leave it alone") has ZERO keyword-magnet content in resources currently. Grep confirms: no "simple equality EXISTS" / "reliably decorrelates" / "leave it alone" / "don't over-rewrite" anywhere in r28 or r23.

**FIX-A SPEC (exact location + framing):**

**Location**: r28, immediately AFTER §711 myth-row (logical neighbor — keyword-magnet for "correlated subqueries Trino" question class lives in the §711 myth-table) AND/OR a small WHICH-X router at the top of §2 (the canonical "Correlated subqueries — the migration slowness champion" section header at §773).

**Content** (additive, ~6-10 lines):

```markdown
> **CRITICAL — "rewrite ALL correlated subqueries" is OVERSTATED for Trino 467.**
> A DBA carrying Oracle/Postgres habits may tell you "correlated subqueries are slow on Trino, rewrite as a JOIN" — that's a true-for-some-shapes / false-for-some-shapes generalization. Scope it correctly before rewriting.
>
> **The SIMPLE-EQUALITY EXISTS / IN shape RELIABLY DECORRELATES TO SEMIJOIN on Trino 467 — leave it alone:**
> ```sql
> SELECT u.* FROM users u
> WHERE EXISTS (
>   SELECT 1 FROM actions a
>   WHERE a.user_id = u.user_id          -- equality correlation
>     AND a.action_type = 'premium'      -- non-correlated scalar filter
> );
> ```
> EXPLAIN shows `SemiJoin[user_id = user_id]` not `CorrelatedJoin`. The rewrite-as-JOIN form is EQUIVALENT, not faster. **Do NOT spend review-cycles rewriting these.**
>
> **Rewrite ONLY when the inner subquery has:**
> - **An aggregate referencing outer cols** (`SELECT MAX(b.x) WHERE b.y = a.y`) — see §2.4 row 1.
> - **A non-equality correlation** (`WHERE b.dt <= a.dt` rather than `b.id = a.id`) — see §2.4 row 4.
> - **A correlated LIMIT/TopN without a strong unique-key signal** (decorrelation rule has a stats gate).
> - **A complex outer-reference** (nested correlated subqueries, multi-column correlations).
> - **A `NOT EXISTS` shape** — even simple-equality NOT EXISTS hits the LeftJoin+Aggregation slow path per [trinodb/trino #21859](https://github.com/trinodb/trino/issues/21859); see §2.4 row 3 anti-join rewrite.
>
> **Decision tool**: `EXPLAIN` your query first. If you see `SemiJoin` → leave it. If you see `CorrelatedJoin` → rewrite per §2.4. Never assume both are bad.
```

**Cross-ref**: add a one-line pointer FROM §15 ("the migration-shaped slowness champion") TO the new which-X router so the lead doesn't read as "always bad": "(Scope this rule: the SIMPLE-EQUALITY shape reliably decorrelates — see §2.0 below for the WHICH-X router.)"

**Defang risk mitigation per pinned `feedback_new_card_over_attracts_adjacent.md`:**
- Lead the WHICH-X with the **WHICH-X structure** ("simple equality EXISTS ✓ / aggregate ✗ / non-equality ✗ / NOT EXISTS ✗"), NOT with a copy-attractive RIGHT example alone. The structure is the keyword-magnet AND the defang.
- Explicit `EXPLAIN first` instruction so the engineer doesn't over-pattern-match on "EXISTS" alone.
- Keep §15 + §711 + §773 alarmist framing intact (the genuinely-failing shapes MUST stay flagged); only ADD the scoping nuance.

**Watch label**: `iter1256 Q3 EXISTS-over-warning LIGHT FIX-A — r28 §711+ WHICH-X router for simple equality EXISTS reliably decorrelates`. Re-probe within 4-8 iters under varied "DBA says rewrite my correlated EXISTS / Postgres instinct says rewrite EXISTS / migrated query has correlated EXISTS" framings; if the over-warning persists, escalate to stronger anchor (top-of-r28 lead-paragraph addendum or §15 inline scoping).

**Be careful NOT to:** invert into "EXISTS is always fine" — the FAILING shapes (aggregate-correlations, non-equality correlations, NOT EXISTS, correlated LIMIT) MUST stay clearly flagged. The reassurance is ONLY for the SIMPLE-EQUALITY positive-EXISTS shape.

**Verifies against:**
- [r28 §711 myth-row](resources/28-complex-sql-performance-trino-dbt.md) (current alarmist framing)
- [r28 §849 conversion table](resources/28-complex-sql-performance-trino-dbt.md) (correct-but-buried shape classification)
- [trino.io/episodes/7.html](https://trino.io/episodes/7.html) — decorrelation podcast
- [trinodb/trino PR #1415](https://github.com/trinodb/trino/pull/1415) — decorrelation of subqueries with equality predicates
- [trinodb/trino #21859](https://github.com/trinodb/trino/issues/21859) — NOT EXISTS-specific LeftJoin+Agg slow path

---

### Q4 — Postgres `::` cast in Trino 467 + TRY_CAST role

**Score: 5.0** (Acc 5.0 / Clar 5.0 / Prac 5.0 / Compl 5.0)

**Pin-perfect canonical, NO-OP.** All load-bearing facts correct:

- **No `::` cast operator in Trino 467** — verified at [trinodb/trino #23795](https://github.com/trinodb/trino/issues/23795) (open feature request from Oct 2024, NOT in 467 / NOT in 481 latest). Parse error: `mismatched input '::'`. Postgres / Snowflake / DuckDB only.
- **Use `CAST(expr AS type)`** — ANSI form; correct for `event_ts::DATE` → `CAST(event_ts AS DATE)`, `user_id::BIGINT` → `CAST(user_id AS BIGINT)`.
- **`TRY_CAST(expr AS type)`** — returns NULL on type-conversion failure rather than raising. Correct for VARCHAR-with-bad-data → number scenario where some rows have non-numeric strings.
- **`try(expr)`** — distinct function for catching arithmetic errors (div-by-zero, overflow) inside an expression; correctly disambiguated from TRY_CAST.

**Resource source check — CLEAN.** r27 §4.4A "TRINO-CAST-SYNTAX GUARDRAIL — Trino has NO `expr::type` cast operator" + DO-NOT-WRITE matrix at §663-670 + cross-dialect-spillover §47 are doing exactly what they were built to do. The responder routed cleanly to this canonical.

**iter1230 ::cast watch CLOSES** — no `::` slip anywhere in the 4 answers this iter; Q4 explicitly defanged the operator. 28th consecutive 1st/2nd-re-probe-CLOSE in the LIGHT-FIX-A-then-CLOSE pattern.

**Verifies against:**
- [trinodb/trino #23795](https://github.com/trinodb/trino/issues/23795) — `::` cast operator open feature request, NOT in 467
- [trino.io/docs/467/functions/conversion.html](https://trino.io/docs/467/functions/conversion.html) — `CAST` + `TRY_CAST` + `try()` canonical
- r27 §4.4A TRINO-CAST-SYNTAX GUARDRAIL (resource pin)

---

## Topic-score impact (rubric updates)

| Topic | Before | This iter | After |
|---|---|---|---|
| Query performance basics: partitioning, indexing strategy for analytics | 4.1602/35 | Q1 = 4.5 | (4.1602 × 35 + 4.5)/36 = **4.1697/36** (+0.0095, margin +0.6697, STILL thinnest) |
| Improving complex SQL performance on Trino with dbt | 4.4685/71 | Q2 = 4.9375 + Q3 = 3.875 | (4.4685 × 71 + 4.9375 + 3.875)/73 = (317.2635 + 8.8125)/73 = **4.4668/73** (-0.0017, margin +0.9668) |
| SQL query best practices for OLAP | 4.5864/292 | Q4 = 5.0 | (4.5864 × 292 + 5.0)/293 = **4.5878/293** (+0.0014, margin +1.0878) |

All required topics REMAIN PASSED. Thinnest topic margin: Query performance basics at +0.6697 (lifted slightly by Q1's 4.5).

---

## Open watches summary (going into iter1257)

| Watch | Origin iter | Status |
|---|---|---|
| iter1255 Q1 bloom-CREATE-TABLE-syntax slip | 1255 | SOFT, re-probe next sweep |
| iter1255 Q3 INSERT-OVERWRITE-broken-secondary | 1255 | SOFT, re-probe next sweep |
| iter1255 Q4 translate-empty-to-semantic-divergence | 1255 | SOFT, re-probe next sweep |
| iter1253 Q4 regexp_extract-2arg-misrecall | 1253 | SOFT, re-probe |
| iter1253 Q2 first-order-cohort-tie | 1253 | SOFT, re-probe |
| iter1249 Q3 dbt-snapshot SCD-2 recall variance | 1249 | SOFT, re-probe |
| iter1248 Q1 opener-vs-body coherence on partition-coarsening | 1248 | SOFT, re-probe |
| iter1248 Q3 MATCH_RECOGNIZE-adjacency | 1248 | SOFT, re-probe |
| iter1241 concat-auto-coerces | 1241 | SOFT, re-probe |
| iter1238 Q3 broadcast-vs-partitioned-lead-rec-hedge-on-small-dim | 1238 | REMAINS OPEN — different shape probed this iter |
| iter1236 rn=1-within-batch | 1236 | SOFT, re-probe |
| iter1215 strpos-3-arg CEILING | 1215 | SOFT, re-probe |
| iter1229 @v1-Spark | 1229 | SOFT, re-probe |
| **iter1256 Q3 EXISTS-over-warning LIGHT FIX-A — r28 §711 WHICH-X router for simple equality EXISTS reliably decorrelates** | **1256** | **NEW — LIGHT FIX-A recommended (see Q3 detail above)** |

**Watches CLOSED this iter:** iter1239 DF-wait-timeout (Q1 surfaced verbatim) + iter1230 ::cast (Q4 explicit defang).

---

## Recommended next iter (1257)

**Priority order:**

1. **Apply LIGHT FIX-A from Q3** at r28 §711 (immediately after the myth-row) + cross-link to §15 — additive WHICH-X router for the simple-equality-EXISTS-decorrelates-reliably reassurance, with explicit defang of "rewrite all correlated subqueries" rule. Per FIX-A SPEC above; keep §15 + §711 + §773 alarmist framing intact, only ADD scoping. Re-probe within 4-8 iters.

2. **Re-probe iter1238 small-dim broadcast-hedge** — this iter only confirmed the BOTH-LARGE shape; the original SMALL-DIM shape (50MB dim + 800M fact + OOM where responder hedged "PARTITIONED safer") was NOT tested. A targeted "small dim joining large fact OOMs — should I broadcast or partition?" question closes the watch one way or the other.

3. **Breadth-mode probes** on the soft-watch backlog as time permits (training deadline 2026-06-30 23:59 CST, ~36h remaining).

**Do NOT churn** on iter1239 DF-wait-timeout (closed cleanly) or iter1230 ::cast (closed cleanly).
