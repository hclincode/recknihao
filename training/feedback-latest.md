# Judge Feedback — iter1274

**Overall**: 4 answers, average **3.797 PASS** (Q1 2.875 FAIL / Q2 2.75 FAIL / Q3 4.75 / Q4 4.8125). Both FAILs are watch re-probes that didn't close — one is a NON-REACH of an applied FIX-A (cross-file discoverability), one is the 2nd-occurrence of a different family that now ESCALATES to mandatory LIGHT FIX-A.

---

## Q1 — dbt source-freshness NARRATIVE re-probe (RE-PROBE of iter1273-Q3 watch) — **2.875 FAIL**

**Scores**: Acc 3.5 / Clar 3.0 / Prac 2.0 / Compl 3.0

**Verdict: 2nd consecutive hedge. iter1273 FIX-A landed correctly INSIDE r27 §6.7B but the responder STILL DID NOT REACH r27. The root cause is CROSS-FILE DISCOVERABILITY, not anchor wording — solving findability inside a file the responder doesn't open cannot help.**

### iter1273 FIX-A verified IN PLACE

I read `/Users/hclin/github/recknihao/resources/27-oracle-plsql-to-dbt-trino.md` lines 3179-3260. Line 3183 contains the teacher's narrative-shaped anchors verbatim:

- "our ingestion/Kafka/Spark pipeline silently fell behind and dashboards show stale numbers"
- "the `dbt run` / `dbt build` SUCCEEDS but the source data hasn't been updated in N hours"
- "no visible error when the upstream/raw/source table is stale or hasn't refreshed"
- "how do I make dbt FLAG or FAIL when source data is too old / stale / behind"
- "detect upstream lag / late-arriving source / source not updated"

Plus the explicit do-NOT-hedge directive: "Do NOT hedge or defer to external docs: the full YAML + command + worked example are in THIS block."

These are nearly word-for-word the keywords the engineer used (Fivetran silently stopped, dbt ran on stale data, reported success, FAIL/WARN pipeline). If the responder had opened r27, §6.7B's anchors would have fired.

### Responder did not open r27 — cross-file discoverability confirmed

Responder's hedge: "did not find guidance on dbt source freshness checks... that gap suggests this capability needs to be added or is outside scope." It described the correct mechanism in partial shape (declare `loaded_at_field`, set freshness thresholds, run `dbt source freshness` as a scheduled job) but deferred for full YAML to `docs.getdbt.com/docs/build/sources#source-freshness`.

### Grep evidence — source-freshness content is ISLAND-ONLY in r27 §6.7B

```
Grep for: source freshness | loaded_at_field | dbt source freshness | warn_after | error_after
Hits: resources/27-oracle-plsql-to-dbt-trino.md (full canonical §6.7B)
      resources/28-complex-sql-performance-trino-dbt.md (L1045 — single passing mention only)
NO HITS in r13 (postgres-to-iceberg-ingestion.md) — the file a Fivetran/Kafka/Spark ingestion-lag narrative would naturally open.
```

The filename `27-oracle-plsql-to-dbt-trino.md` does not contain "Fivetran" / "ingestion" / "stale" / "freshness" / "Kafka" — the file is not selected by the engineer's narrative keywords. Anchors inside the file cannot fire if the file is never opened.

### MANDATORY LIGHT FIX-A — exact location and shape

**File: `/Users/hclin/github/recknihao/resources/13-postgres-to-iceberg-ingestion.md`**

Add a **self-contained, compact** source-freshness card (NOT just a cross-ref pointer — cross-refs don't help if r13 itself isn't opened either, but r13 IS opened by Fivetran/Kafka/Spark-ingestion-lag narratives). The card should contain:

1. **Load-bearing narrative keywords** (must match what a Haiku does keyword-route on):
   - "Fivetran silently stopped writing"
   - "raw table not refreshing"
   - "ingestion fell behind"
   - "dbt run/build succeeds on stale source"
   - "make dbt flag/fail on stale upstream"
   - "detect upstream lag"
2. **Minimal canonical YAML** (paste-and-run shape):
   ```yaml
   freshness:
     warn_after:  {count: 12, period: hour}
     error_after: {count: 24, period: hour}
   loaded_at_field: ingested_at
   ```
3. **Separate-command fact**: `dbt source freshness` is NOT auto-run by `dbt run` / `dbt build` — gate it as its own CI step that exits non-zero on `error_after`.
4. **dbt-trino caveat**: must declare `loaded_at_field` explicitly (no warehouse-metadata fallback on Trino — Snowflake/Redshift/BigQuery 1.7.3+/Databricks Fusion only).
5. **Forward pointer**: "Full Q-pattern matcher + worked example: r27 §6.7B."

Length: ~15-25 lines. Place near the existing "stale data" / "lag" sections in r13 (lines 280-290 and lines 2640-2650 already discuss read-side staleness / replication lag — natural anchor zones).

### Why r13, not r28 or a new file

- r13 is the **ingestion** file — Fivetran/Kafka/Spark-write-side lag IS r13's domain.
- The teacher's iter1273 note said "Skipped r13 cross-ref (write-side lag content, misroute risk)" — but the 2nd-time hedge means that decision needs revisiting. The narrative IS write-side lag the engineer is trying to DETECT on the read side via dbt source freshness — these belong together.
- r28 (complex SQL perf with dbt) is a less-natural lexical match for a "Fivetran silently stopped" narrative.

### Watch update

NEW HARD WATCH: `iter1274-Q1 source-freshness CROSS-FILE r13 FIX-A reach test`. Re-probe within 2 iters using a Fivetran/Kafka/Spark-pipeline-stale narrative (no feature-name keywords). If the responder STILL hedges, the r13 placement was wrong direction — escalate to a third placement (likely a dbt-data-quality top-level section, or a top-of-r28 dbt-ops block).

---

## Q2 — Hierarchical drill-down ROLLUP miss (2ND OCCURRENCE of iter1273-Q2 watch) — **2.75 FAIL**

**Scores**: Acc 2.5 / Clar 4.0 / Prac 2.0 / Compl 2.5

**Verdict: 2nd occurrence of the ROLLUP-rejected-for-wrong-GROUPING-SETS family. Per iter1273-Q2 watch, ESCALATE to LIGHT FIX-A.**

### Engineer's ask = textbook ROLLUP

- Detail row per `(team, priority)` = the `(team, priority)` tuple
- Per-TEAM subtotal across all priorities = `(team)`
- ONE grand total = `()`

That is exactly `ROLLUP(team, priority)` = `GROUPING SETS ((team, priority), (team), ())`.

### Responder's answer = wrong-shape GROUPING SETS + ROLLUP not named

Responder wrote `GROUP BY GROUPING SETS ((team, priority), (team), (priority), ())`:
- Included `(team, priority)` detail (better than iter1273 which OMITTED the detail).
- Added a SPURIOUS `(priority)` per-priority margin the engineer did NOT request.
- Did NOT name ROLLUP as the canonical idiom for this hierarchy.
- Mentioned CUBE as "every combination" but did not route to ROLLUP.

Note: per r28 L508, `GROUPING SETS ((a,b),(a),(b),())` IS LITERALLY `CUBE(a,b)` — the responder essentially gave a CUBE answer. The engineer pastes the query and the ticket report has unwanted per-priority margin rows; business owner sees clutter.

### Verified

WebFetch of [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html) confirms `ROLLUP(a, b)` = `GROUPING SETS ((a, b), (a), ())` — exact 3 sets.

`/Users/hclin/github/recknihao/resources/28-complex-sql-performance-trino-dbt.md` L426 already has the verbatim router: "(detail + subtotals down a group hierarchy + grand total) (e.g. per-(region, product) detail, then a per-region subtotal, then the overall total — **NO per-product-only row**) -> `ROLLUP(region, product)`." The content EXISTS — the responder routed to adjacent CUBE-vs-ROLLUP defang (L479-505) instead.

### 2nd-occurrence pattern

- iter1273 Q2 (region + plan_tier): omitted (region, plan_tier) detail, used `((region),(plan_tier),())` — wrong because no detail.
- iter1274 Q2 (team + priority): included detail, but ADDED spurious (priority) margin — wrong because extra row.
- Both are the same family: responder synthesizes a list of GROUPING SETS by reasoning column-by-column instead of routing to ROLLUP as the named idiom for hierarchical drill-down.

### LIGHT FIX-A — exact location and shape

**File: `/Users/hclin/github/recknihao/resources/28-complex-sql-performance-trino-dbt.md` §419-449 router block.**

Two additions:

1. **Top-of-matrix explicit recipe** (insert just under L425 router or merge into L426):
   > "Asked for `(A, B) detail row` + `(A) subtotal across all B` + `()` grand total — this is a DRILL-DOWN HIERARCHY = `ROLLUP(A, B)`. Do NOT add a `(B)`-only set — that would create a per-B margin the report did NOT ask for. The 3-set list is EXACTLY `GROUPING SETS ((A, B), (A), ())` = `ROLLUP(A, B)`."

2. **Defang of the 4-tuple form UNDER THE HIERARCHY framing** (currently L508 defangs the 4-tuple only under the "if you don't want detail, omit (a,b)" framing — the responder synthesized in the opposite direction, so a complementary defang is needed):
   > "If you want `(a, b)` detail + per-`a` subtotal + grand total ONLY, do NOT write `GROUPING SETS ((a,b),(a),(b),())` — the 4-tuple form adds an UNWANTED `(b)`-only margin (and it IS literally `CUBE(a, b)`). Use `ROLLUP(a, b)` (3 sets) instead."

The fix is additive (no removal); ~6-10 lines max. Pattern: the responder grabbed adjacent decision-matrix content (the CUBE-defang at L508) and synthesized in the wrong direction — explicit hierarchy-framed defang of the 4-tuple form will close the gap.

### Watch update

CLOSE iter1273-Q2 watch (escalated to LIGHT FIX-A this iter). OPEN: `iter1274-Q2 ROLLUP-hierarchy LIGHT FIX-A reach test` — re-probe within 2-4 iters with (detail by 2 dims) + (per-first-dim subtotal) + (grand total) framing. If responder ROUTES TO `ROLLUP` and names it as the canonical idiom, close. If responder again synthesizes a 4-tuple GROUPING SETS or other non-ROLLUP shape, the LIGHT FIX-A failed and a stronger rewrite (potentially flipping the order of examples — ROLLUP example FIRST not after GROUPING SETS) is needed.

---

## Q3 — Iceberg snapshot maintenance + time-travel — **4.75 STRONG PASS**

**Scores**: Acc 4.5 / Clar 5.0 / Prac 5.0 / Compl 4.5

All facts verified via WebFetch of [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html):

- `ALTER TABLE ... EXECUTE optimize(file_size_threshold => '256MB')` — syntax verified verbatim (docs use `'128MB'` example; `'256MB'` is a valid argument value).
- `ALTER TABLE ... EXECUTE expire_snapshots(retention_threshold => '7d')` — verified verbatim; docs: "removes all snapshots and all related metadata and data files". `iceberg.expire-snapshots.min-retention` default 7d.
- `ALTER TABLE ... EXECUTE remove_orphan_files(retention_threshold => '7d')` — verified; `iceberg.remove-orphan-files.min-retention` default 7d.
- `CALL iceberg.system.rollback_to_snapshot('schema','table',snapshot_id)` — verified (3-arg form is the 467 form; `ALTER TABLE EXECUTE rollback_to_snapshot` is 469+ per pinned `reference_trino_rollback_snapshot_form.md`).
- MoR position-delete clearing via optimize with higher `file_size_threshold` — matches pinned `reference_trino_optimize_clears_position_deletes.md` (iter1194 PR #12617 / #24086 — SIZE-only candidate selection; raise threshold above already-large delete-bearing files to force-rewrite).
- Time-travel `FOR VERSION AS OF` breaks past retention — correct logical consequence (the docs don't state it explicitly, but expired snapshots have their data files deleted, so the time-travel query errors).

Minor Acc shave: time-travel breakage stated as a hard rule (docs don't quote it verbatim — it's a logical inference). Minor Compl shave: did not surface the `iceberg.expire-snapshots.min-retention` catalog-level floor (procedure refuses with `retention_threshold < min-retention`) or the alternative `CALL system.expire_snapshots(...)` procedure form.

No imported-prior, no broken-secondary, no over-warning, no fabrication. Cites r17.

---

## Q4 — Oracle LISTAGG → Trino listagg — **4.8125 STRONG PASS**

**Scores**: Acc 5.0 / Clar 4.75 / Prac 5.0 / Compl 4.5

All facts verified via WebFetch of [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/467/functions/aggregate.html):

- `LISTAGG( expression [, separator] [ON OVERFLOW overflow_behaviour]) WITHIN GROUP (ORDER BY sort_item, [...])` — exact syntax. Skips NULL inputs by default.
- 1 MiB limit verified verbatim ("the length of the output of the function exceeds `1048576` bytes" = 1 MiB).
- `ON OVERFLOW ERROR` and `ON OVERFLOW TRUNCATE '.....' WITH COUNT` both documented.
- No window form verified verbatim: "The current implementation of `listagg` function does not support window frames." Alternative `array_join(array_agg(x ORDER BY x), ', ')` is the correct windowed/per-row alternative.

Pinned `reference_trino_listagg_native.md` is the source of truth — responder routed correctly to it. Cites r27 §7A.2.

Minor Compl shave: did not mention that `listagg(DISTINCT x, ',')` is NOT supported on 467 — the Oracle DISTINCT idiom would need a CTE with DISTINCT first, then listagg. This matters because Oracle LISTAGG accepts DISTINCT and call sites may use it.

No imported-prior, no broken-secondary, no over-warning, no fabrication. Clean 1:1 migration answer.

---

## Patterns / watches

### NEW HARD WATCH — Cross-file discoverability for source-freshness narrative (Q1)

The iter1273 FIX-A added the right keyword anchors INSIDE r27 §6.7B, but the responder never opens r27 from a Fivetran/Kafka/Spark-ingestion-lag narrative. **Findability fails at the FILE level, not at the SECTION level.** This is a different failure mode from prior anchor-tweak fixes — it requires the canonical (or a substantive pointer card, not just a cross-ref line) to live in a file the narrative WOULD route to (r13 ingestion is the candidate). Re-probe within 2 iters with a Fivetran/Kafka narrative; if it still hedges, the r13 placement is wrong direction and the next attempt should be a dbt-data-quality top-level zone in r28.

### ESCALATED WATCH — ROLLUP hierarchy router (Q2)

iter1273-Q2 + iter1274-Q2 = 2 consecutive ROLLUP misses on hierarchy-fit questions. Per the iter1273-Q2 watch, ESCALATE to LIGHT FIX-A at r28 §419-449 (top-of-matrix explicit recipe + 4-tuple defang under the hierarchy framing). Re-probe within 2-4 iters. If the LIGHT FIX-A doesn't close, the next escalation is reordering r28 examples (ROLLUP example FIRST before GROUPING SETS to reset the keyword-magnet).

### Carry-forward un-probed watches

- iter1272-Q3 unit-test-free-tier-hallucination (un-probed)
- iter1271-Q2 streak (un-probed)
- iter1270-Q1 PRIMARY-KEY (un-probed)

### Continuity / quality notes

- Q3 and Q4 are clean strong-PASS answers — no defects, full verification clean against trino.io/docs/467 + pinned cards.
- The 2 FAILs are both watch re-probes; iteration-level "PASS at 3.797" hides that 50% of the answers shipped wrong output / unactionable hedges to the engineer.
- Both FAILs have **specific, narrow LIGHT FIX-A locations** (r13 for source-freshness pointer; r28 §419-449 for ROLLUP-hierarchy router + 4-tuple defang). Both are additive (no removal); ~6-25 lines each.

---

## Per-topic score history updated

- `dbt sources / source freshness`: 4.5554/13 -> 4.4354/14 PASSED (-0.1200, 2nd consecutive sub-4 score).
- `Analytical query patterns on Iceberg+Trino`: 4.4855/200 -> 4.4769/201 PASSED (-0.0086).
- `Iceberg table maintenance`: 4.4497/241 -> 4.4509/242 PASSED (+0.0012).
- `Oracle PL/SQL -> dbt + Trino SQL migration`: 4.5071/242 -> 4.5083/243 PASSED (+0.0012).

State.json NOT modified per directive (teacher will bump iteration).
