# Iter 452 Judge Feedback — Extended Phase, End-of-Iteration Only

## Overall verdict

**Average: 4.40625 / 5.0 — PASS (51st consecutive PASS in extended phase)**

Per-question:
| Q | Topic | Acc | Comp | Clar | Act | Avg | Verdict |
|---|---|---|---|---|---|---|---|
| Q1 | Iceberg branches/tags Trino vs Spark | 5.0 | 4.75 | 4.5 | 4.75 | **4.75** | STRONG PASS |
| Q2 | dbt incremental reprocessing diagnosis | 3.5 | 3.75 | 3.5 | 3.5 | **3.5625** | PASS-WITH-CAVEAT |
| Q3 | Multi-tenant OPA row isolation | 5.0 | 4.75 | 4.625 | 4.625 | **4.75** | STRONG PASS |
| Q4 | MinIO storage growth diagnosis | 5.0 | 4.5 | 4.5 | 4.25 | **4.5625** | STRONG PASS |

**Citation-hygiene streak BROKEN** at iter452 — two confident-inaccuracies in Q2 on load-bearing dbt-trino fix-recommendation syntax. Q1, Q3, Q4 all clean.

---

## CRITICAL — Q2 fabrications to reconcile in iter453

### FAB-1: `{% if execute %}` is the WRONG guard for incremental delta filter

**What the responder wrote:**
```sql
{% if execute %}
WHERE event_ts >= (SELECT COALESCE(MAX(event_ts), TIMESTAMP '1970-01-01') FROM {{this}})
{% endif %}
```

**Why it's wrong:**
- `execute` is a jinja context variable that is True whenever dbt compiles **with a connection** — that includes `dbt compile`, `dbt docs generate`, `dbt run`, `dbt build`. Source: docs.getdbt.com/reference/dbt-jinja-functions/execute.
- It does NOT distinguish first-build / `--full-refresh` runs from regular incremental runs. The incremental WHERE-clause would also fire during the very first model build (when `{{this}}` doesn't exist yet) and during `--full-refresh` (when it should NOT filter).
- The **canonical guard** for an incremental delta filter is `{% if is_incremental() %}`, which is True only when:
  1. The model exists as a relation in the target database
  2. The current run is NOT `--full-refresh`
  3. The model is configured as incremental
- Source: docs.getdbt.com/docs/build/incremental-models — the official is_incremental() macro definition.

**What teacher must do in iter453:**
- Find every `{% if execute %}` in resources/ that is used as a substitute for the incremental guard and rewrite to `{% if is_incremental() %}`.
- Add a DO-NOT-WRITE row to the canonical dbt-trino resource (likely r05 or r07 — locate the dbt incremental section) showing the difference:
  - WRONG: `{% if execute %}` (compiles fine, filters on first build, breaks `--full-refresh`)
  - RIGHT: `{% if is_incremental() %}` (canonical, gates only when the table already exists and not full-refresh)
- Cross-reference from the dbt-incremental section to docs.getdbt.com/reference/dbt-jinja-functions/execute so the responder's keyword match on "execute" lands on the correct guidance.

### FAB-2: `properties={'partitioning': "ARRAY['day(event_ts)']"}` — wrong dbt-trino config key

**What the responder wrote:**
```yaml
{{ config(
    materialized='incremental',
    incremental_strategy='merge',
    unique_key=['event_id'],
    properties={'partitioning': "ARRAY['day(event_ts)']"}
) }}
```

**Why it's wrong:**
- The dbt-trino documented property key for partitioning an Iceberg incremental model is **`partitioned_by`** (snake_case), not `partitioning`.
- Source: docs.getdbt.com/reference/resource-configs/trino-configs + github.com/starburstdata/dbt-trino issue #412.
- Note the surface confusion: bare-Trino `CREATE TABLE ... WITH (partitioning = ARRAY[...])` DOES use `partitioning` as the property name. But dbt-trino's `config(properties=...)` dictionary takes `partitioned_by` and translates internally. Engineer pasting the responder's snippet will get either silently-wrong behavior (no partitioning applied) or a property-not-recognized error.

**Canonical correct form:**
```yaml
{{ config(
    materialized='incremental',
    incremental_strategy='merge',
    unique_key=['event_id'],
    properties={
        "partitioned_by": "ARRAY['day(event_ts)']",
        "format": "'PARQUET'"
    }
) }}
```

**What teacher must do in iter453:**
- Locate the dbt-trino config worked example in resources/ (likely r05/r07/r27). If `properties={'partitioning': ...}` appears anywhere, replace with `partitioned_by`.
- Add a DO-NOT-WRITE row distinguishing the two surfaces:
  | Surface | Property key | Example |
  |---|---|---|
  | Bare Trino `CREATE TABLE ... WITH (...)` | `partitioning` | `WITH (partitioning = ARRAY['day(event_ts)'])` |
  | dbt-trino `config(properties=...)` | `partitioned_by` | `properties={"partitioned_by": "ARRAY['day(event_ts)']"}` |
- Source-cite docs.getdbt.com/reference/resource-configs/trino-configs.

---

## What went well (iter452 strengths to preserve)

- **Q1 Iceberg branches/tags** — clean version-gating call (Trino 467 cannot CREATE BRANCH, Spark form is correct, `FOR VERSION AS OF '<branch_name>'` read path is valid on 467, `$refs` columns canonical). The iter451 PR #24580 future-proofing note discipline carried into Q1 well — the responder correctly stated Trino 467 limitations without overreaching to claim Trino 477+ syntax.
- **Q3 Multi-tenant OPA** — correctly aligned with prod_info.md JWT+OPA stack, deferred specific policy rules to the external governance document, no fabricated `SET ROW FILTER` DDL (which would have been a Trino-invented clause). The iter451 r17 reinforcement work spilled over positively into the OPA mental model.
- **Q4 MinIO storage growth** — clean Spark-vs-Trino procedure boundary (correctly identified `rewrite_position_delete_files` as Spark-only `CALL`, NOT Trino `EXECUTE`). The iter449 r16 cost worked example + iter452 r16 myths-table reinforcement clearly LANDED — responder used the canonical 4-ranked-suspects framing.

---

## Teacher actions for iter453 (priority order)

### Priority 1 — Reconcile dbt-trino incremental syntax (Q2 fabrication recovery)

Find these patterns in resources/ and fix in-place (do NOT append):
- `{% if execute %}` used as incremental guard → rewrite to `{% if is_incremental() %}` everywhere.
- `properties={'partitioning': ...}` in a dbt-trino `config()` block → rewrite to `properties={"partitioned_by": ...}`.

Probable file targets to grep:
- resources/05-dbt-on-trino-config.md (or similar — dbt-trino config canonical file)
- resources/07-* (dbt incremental patterns)
- resources/27-oracle-plsql-to-dbt-trino.md (uses dbt incremental in migration contexts)
- Any worked example mentioning `incremental_strategy='merge'`

Add a leading "Canonical dbt incremental guard + dbt-trino properties" DO-NOT-WRITE block at the top of the most-findable dbt resource. Place it BEFORE existing worked examples so a Haiku responder keyword-matching on "dbt incremental", "is_incremental", "execute jinja", "incremental_strategy", "properties partitioning", or "partitioned_by" lands on the canonical syntax FIRST.

### Priority 2 — Breadth design for iter453

Iter452 did NOT probe federation (per directive); the federation row remains 4.49944/310. Iter453 should continue breadth design and NOT dedicate a federation probe (the topic is near-miss but stable; risk of regression > expected gain from another probe based on the 23+ iterations stuck below threshold). Prioritize one probe each from:
- **Postgres-to-Iceberg ingestion** (lost ground in iter452 from 4.4975 → 4.4914 on the Q2 fabrications — needs a clean re-probe to recover)
- **Iceberg table maintenance** (lost micro-ground 4.5128 → 4.5117; one clean re-probe to nudge back up)
- One of the unprobed-this-iter topics for breadth (column-oriented storage, OLAP vs OLTP, or Iceberg partition design)
- Lakehouse schema design or SQL query best practices for OLAP for the 4th probe

Avoid: federation (per directive), Trino CBO (already at 4.6707/12 with strong buffer), tools comparison (4.75/3 with light history).

### Priority 3 — Citation-hygiene streak recovery

iter452 broke the streak at iter451's 1-iter restoration. The two FAB-1 / FAB-2 patterns are NEW failure modes (neither appeared in iter410's QUALIFY-not-in-Trino slip or iter450's MAP angle-bracket slip). After reconciling, add a top-of-file cross-reference from any resource that mentions "incremental" / "dbt" / "is_incremental" pointing to the canonical dbt incremental guard worked example. This is the same pattern the iter451 r09 leading canonical worked example used to fix the MAP angle-bracket regression — it worked for schema-DDL and should work for dbt-trino syntax.

---

## Notes

- 51st consecutive overall PASS in extended phase (streak intact despite Q2 PASS-with-caveat).
- Federation: 4.49944/310, 23 consecutive iters stuck below 4.5 threshold (per-topic override).
- All required topics PASS — iter436 terminal milestone STILL holds.
- prod_info.md JWT+OPA alignment in Q3 was excellent — keep that framing as a model for future authz probes.
- Q4 docked slightly only for missing concrete success criteria (TB target, runtime estimate, concurrency caveat for expire on live table) — not a fabrication, just polish.
