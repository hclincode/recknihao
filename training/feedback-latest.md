# Iteration 1238 — Judge Feedback

## Verdict

**Overall: 4.72 — STRONG PASS. BOTH iter1237 LIGHT FIX-As REACHED ON FIRST RE-PROBE; BOTH WATCHES CLOSE.** Q1 (mode-per-group re-probe) and Q2 (dbt-snapshot re-probe) both land the canonical cleanly with all load-bearing facts correct. Q4 (Oracle DECODE → CASE WHEN with NULL caveat) is canonical-clean. Q3 (broadcast vs partitioned for 2M-row dim) is core-correct but has one framing slip — recommends "PARTITIONED likely safer" as the hedge for a 2M-row dim joining 800M-row fact, when broadcasting the small dim is the textbook lead.

The double FIX-A close decisively reverses the iter1237 2.91 dip; the loop returns to the 1st-re-probe-CLOSE pattern.

| Q | Score | Topic | Notes |
|---|---|---|---|
| Q1 | 5.0 | Analytical query patterns on Iceberg+Trino | **iter1237 r23 §1428 mode-per-group FIX-A REACHED, WATCH CLOSES** — canonical `max_by(category, cnt)` over `COUNT(*) GROUP BY (product_id, category)` subquery + `ROW(cnt, category)` deterministic tiebreaker; no window-COUNT-with-GROUP-BY anti-pattern this time |
| Q2 | 5.0 | dbt snapshots SCD2 | **iter1237 r27 §3.1 materializations-table 5th-snapshot-row FIX-A REACHED, WATCH CLOSES** — full `{% snapshot %}` block with timestamp strategy, all four `dbt_*` meta cols correct per docs.getdbt.com, validity-window as-of-date predicate correct, cited r09 |
| Q3 | 4.0 | Query performance basics (partitioning / join distribution) | Core facts correct: no `/*+ */` hint syntax in Trino 467 (silently ignored), session prop `join_distribution_type` with BROADCAST/PARTITIONED/AUTOMATIC values, AUTOMATIC default, ANALYZE for stats, dbt `pre_hook`. **Slip**: lead-rec hedge "PARTITIONED likely safer" for a 2M-row dim is counter to the canonical "broadcast the small dim" call; recall-ceiling not resource defect |
| Q4 | 4.875 | Oracle PL/SQL → dbt+Trino migration | Clean: Trino has no DECODE, CASE WHEN rewrite correct, **critical NULL-search-value subtlety correct** (Oracle DECODE matches NULL=NULL as TRUE, Trino `WHEN status = NULL` is UNKNOWN so write `WHEN status IS NULL THEN ... FIRST`) |

---

## Per-question detail

### Q1 — Mode-per-group: most-picked category per product → 5.0 (Analytical query patterns row)

**VERIFIED — iter1237 r23 §1428 DO-NOT-WRITE row FIX-A REACHED. WATCH CLOSES.**

Responder wrote the textbook canonical from r23 §1403:

```sql
SELECT product_id,
       max_by(category, cnt) AS most_picked_category
FROM (
    SELECT product_id, category, COUNT(*) AS cnt
    FROM iceberg.analytics.tickets
    GROUP BY product_id, category
)
GROUP BY product_id;
```

Plus the deterministic tiebreak via `max_by(category, ROW(cnt, category))` — verified at [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/467/functions/aggregate.html) (max_by accepts ROW for multi-key ordering; ROW comparison is lexicographic). Cited r23 mode LEADING CANONICAL.

**Why the FIX-A worked.** iter1237 broke specifically because the responder mixed `COUNT(*) OVER (PARTITION BY customer_id ORDER BY CAST(NULL AS INT))` with `GROUP BY customer_id, error_code` — a shape that returns DISTINCT-value-count-per-group (constant within group), tiebreaks on alphabetical, and produces the same wrong result as `MAX(error_code)`. The r23 §1428 DO-NOT-WRITE row added in iter1237 explicitly names this exact anti-pattern with the one-character fix (replace window `COUNT(*) OVER` with plain aggregate `COUNT(*)` in the inner GROUP BY). Plus the §1403 LEADING CANONICAL has massive keyword anchors (`the mode`, `mode per group`, `most-popular Y per X`, `most-frequent value per group`, `which X appears most often per Y`). Responder this iter reached the canonical directly — no window-mixing slip.

**No FIX-A needed. iter1237 Q2 mode-per-group window-COUNT+GROUP-BY-broken WATCH CLOSES on first re-probe.**

---

### Q2 — dbt snapshot SCD-2 for plan_tier history → 5.0 (dbt snapshots SCD2 row)

**VERIFIED — iter1237 r27 §3.1 materializations-table 5th-snapshot-row + bolded routing note FIX-A REACHED. WATCH CLOSES.**

Responder wrote the full canonical:

```sql
{% snapshot dim_customers_snapshot %}
  {{ config(
      target_schema='analytics',
      unique_key='customer_id',
      strategy='timestamp',
      updated_at='updated_at'
  ) }}
  SELECT customer_id, name, plan_tier, account_status, updated_at
  FROM {{ source('oracle','customers') }}
{% endsnapshot %}
```

Plus the four `dbt_*` meta columns: `dbt_valid_from`, `dbt_valid_to`, `dbt_scd_id`, `dbt_updated_at` — **VERIFIED against [docs.getdbt.com/docs/build/snapshots](https://docs.getdbt.com/docs/build/snapshots)** verbatim ("the configured `updated_at` column is used to populate the `dbt_valid_from`, `dbt_valid_to` and `dbt_updated_at` columns" + `dbt_scd_id` is the row-version UID). The validity-window as-of-date predicate is the canonical Type-2 form:

```sql
WHERE customer_id = <id>
  AND dbt_valid_from <= TIMESTAMP '2025-03-15 12:00:00'
  AND (dbt_valid_to IS NULL OR dbt_valid_to > TIMESTAMP '2025-03-15 12:00:00')
```

Cited r09. (The four-meta-cols rubric definition also includes the 1.9+ `dbt_is_deleted` for `hard_deletes='new_record'` — responder didn't surface but isn't load-bearing for the engineer's question of "plan_tier history", which is in-place UPDATEs not row deletions.)

**Why the FIX-A worked.** iter1237 the responder BAILED ("resources don't cover dbt snapshot resource type") after enumerating the four `materialized=` rows of the r27 §3.1 table. The iter1237 fix added a 5th `snapshot` row INSIDE that table — explicitly marked "a SEPARATE dbt resource type — NOT a `materialized=` value" — plus a bolded note RIGHT AFTER the table saying "do NOT conclude snapshots aren't covered" with a route to r09 §SCD. This iter the responder pulled the canonical, cited r09, and produced a clean answer. The fix landed at the EXACT spot the responder reached in iter1237 — text-book findability win.

**No FIX-A needed. iter1237 Q3 snapshot-not-in-materializations-list-bail WATCH CLOSES on first re-probe.**

---

### Q3 — 800M events JOIN 2M dim_users, 20 min then coordinator OOM; is broadcasting real, other OOM fixes → 4.0 (Query performance basics row)

**VERIFIED facts (via WebSearch + trino.io docs this iter):**

- Trino 467 has NO inline SQL hint syntax — VERIFIED at [trinodb/trino#9498](https://github.com/trinodb/trino/issues/9498) ("Support query hints", still open since Oct 2021). `/*+ BROADCAST */` is treated as a block comment and silently ignored. **Responder correct.**
- Session prop `join_distribution_type` with values `BROADCAST` / `PARTITIONED` / `AUTOMATIC`, default `AUTOMATIC` — VERIFIED at [trino.io/docs/current/admin/properties-general.html](https://trino.io/docs/current/admin/properties-general.html). **Responder correct.**
- BROADCAST semantics — right table replicated to all nodes that have left-side data; build side = right table. **Responder correct.**
- PARTITIONED semantics — both sides hash-redistributed on join key. **Responder correct.**
- ANALYZE for accurate stats so AUTOMATIC picks correctly — `ANALYZE iceberg.analytics.dim_users` (bare ANALYZE form, no TABLE token). **Responder correct.**
- dbt per-model knob via `pre_hook="SET SESSION join_distribution_type = '...'"` — **production-stack-aligned**.

**The framing slip.** The responder suggested "PARTITIONED likely safer if the OOM repeats." For a **2M-row dim** joining an **800M-row fact**, this is the wrong lead recommendation:

- 2M dim_users is small (~50-500MB depending on column width) — broadcasting it is the canonical optimization. The fact-dim broadcast is exactly what `join_distribution_type='BROADCAST'` was designed for.
- **PARTITIONED on this shape** forces both tables to hash-shuffle. Shuffling the 800M event rows is what's making the current run take 20 min — partitioned is likely **slower**, not safer.
- The coordinator OOM is more likely from dynamic-filter values (BROADCAST joins compute DF on the build side and ship to the probe-side TableScan; ~2M distinct user_ids in a DF could pressure coordinator memory) or planning blow-up from manifest counts, not from broadcasting the build side per se (build replication is worker→worker via exchanges, not via coordinator).
- The textbook lead for "broadcast the small table" on a 2M-vs-800M shape is: **(1) ANALYZE both tables → (2) let AUTOMATIC pick (it should pick BROADCAST) → (3) verify with EXPLAIN DISTRIBUTED for `Join[...][REPLICATED]` → (4) if AUTOMATIC still partitions, force `SET SESSION join_distribution_type='BROADCAST'`**. PARTITIONED is the fallback if BROADCAST itself OOMs because the build side is too big (~hundreds of MB+).

**Other OOM levers the responder could have surfaced.** The engineer asked "other ways to stop the OOM" — responder named ANALYZE + the two session-prop values but missed:
- `query_max_memory` / `query_max_memory_per_node` adjustment (cluster ceilings)
- `spill_enabled=true` to allow operator spill to disk for the join/aggregation
- WHERE-side pruning to reduce 800M input (the engineer didn't say the WHERE was already optimal — adding `event_date >= ...` partition filter could cut the build size by 10×)
- `dynamic_filtering_enabled` — actually relevant if coordinator OOM is from DF aggregation
- EXPLAIN ANALYZE to find which operator is OOMing (sometimes coordinator OOM is from `OutputBuffer` if the final SELECT is shipping too many rows)

**Net.** Core mechanics all correct, dbt routing correct, hint-comment defang correct. The "PARTITIONED safer" framing slip is a recall-ceiling responder-folklore slip (see `feedback_responder_overwarning_folklore.md` — Haiku over-warns the broader-shuffle option as "safer" on join-distribution questions), not a resource defect. r28 has the canonical "broadcast the small dim" pattern; responder reached the session-prop card but hedged on the recommendation.

**No FIX-A.** Recall ceiling, not resource-sourced. **SOFT WATCH** `iter1238 Q3 broadcast-vs-partitioned-lead-rec-hedge-on-small-dim`: re-probe under "small dim joining large fact + OOM / how to broadcast" framings 4-8 iters.

| Sub-dim | Score | Reason |
|---|---|---|
| Technical accuracy | 4 | Facts on hints/session prop/values/default all correct; PARTITIONED-safer framing wrong direction |
| Beginner clarity | 4 | Explains BROADCAST replicates build, PARTITIONED rehashes both; could distinguish coordinator vs worker memory |
| Practical applicability | 4 | Session SET + dbt pre_hook are correct knobs; lead-rec hedge could mislead engineer toward slower path |
| Completeness | 4 | Mentions ANALYZE but missing spill / query_max_memory / WHERE-pruning / dynamic filtering levers |

---

### Q4 — Oracle DECODE(status,'active',1,'trial',2,'churned',3,0) → Trino CASE WHEN → 4.875 (Oracle migration row)

**VERIFIED — clean canonical, NULL caveat is the load-bearing differentiator.**

- Trino 467 has NO `DECODE` function — [trino.io/docs/467/functions/conditional.html](https://trino.io/docs/467/functions/conditional.html) lists `CASE`, `IF`, `COALESCE`, `NULLIF`, `TRY` only. **Responder correct.**
- Direct rewrite `CASE WHEN status='active' THEN 1 WHEN status='trial' THEN 2 WHEN status='churned' THEN 3 ELSE 0 END` — **correct shape.**
- **NULL-search-value subtlety — VERIFIED critical:** Oracle DECODE's documented behavior is that "DECODE() acts as though two NULL values are equivalent" — `DECODE(x, NULL, 1, 2)` returns 1 when x IS NULL. In Trino (standard three-valued logic), `WHEN status = NULL` always evaluates to UNKNOWN and **never matches**. So the responder's instruction "if Oracle's DECODE has NULL as a search value you MUST write `WHEN status IS NULL THEN ...` FIRST in the CASE" is **exactly right** and is the load-bearing migration trap. Cited r23 §3.1E + r27 §4.1A.

**Minor potential add (-0.125):** could have mentioned that Oracle DECODE returns NULL when no match AND no default is provided, while Trino CASE returns NULL when no WHEN matches AND no ELSE clause is provided — same shape, so the `ELSE 0` in the engineer's Oracle code → `ELSE 0` in the Trino CASE works identically. (The responder included `ELSE 0`, so it's effectively correct — just didn't explicitly note the symmetry.)

No imported-prior slip, no broken-secondary, no over-warning. Cites r23 §3.1E + r27 §4.1A DECODE→CASE canonical.

| Sub-dim | Score | Reason |
|---|---|---|
| Technical accuracy | 5 | Trino-no-DECODE + CASE rewrite + Oracle NULL=NULL match + Trino IS NULL FIRST all correct |
| Beginner clarity | 5 | Walks through the rewrite, highlights NULL trap with engineer-relatable framing |
| Practical applicability | 5 | Engineer knows exactly what to change in every grep-hit DECODE call |
| Completeness | 4.5 | Could note ELSE-clause / no-match symmetry; not load-bearing |

---

## Pattern observations

1. **Both iter1237 LIGHT FIX-As CLOSE on 1st re-probe.** r23 §1428 DO-NOT-WRITE defang + §1403 canonical pulled Q1 to the right shape; r27 §3.1 5th-snapshot-row + bolded route pulled Q2 to r09. iter1237's findability diagnoses were correct on both counts; the fixes landed at the EXACT spots the responder reached in iter1237.
2. **The 21-of-22 recent-run 1st-re-probe-close pattern resumes.** iter1237 was the only 1st-re-probe-NON-close iteration in the last 22 sweeps; loop returns to the previous norm. The dbt-snapshots-SCD2 row (most-impacted by iter1237: 4.313 → 4.180) recovers this iter to 4.211 (`+0.031`); the analytical-patterns row recovers to 4.540 (`+0.003`).
3. **Q3 broadcast-vs-partitioned framing slip is responder-folklore-recall (not a resource gap).** This is the same family as `feedback_responder_overwarning_folklore.md` — Haiku reaches the correct mechanics but hedges the lead recommendation toward the more-conservative option ("PARTITIONED safer") even when the canonical for the scenario is the opposite ("broadcast the small dim"). Resources teach the broadcast-the-small-dim canonical clearly; responder reached the session-prop card. Soft watch, no resource fix.

---

## Recommendation to teacher

- **NO FIX-A this iter.** Both iter1237 watches CLOSE; Q3 slip is recall ceiling not resource defect; Q4 is clean.
- **CLOSE WATCHES**: `iter1237 Q2 window-COUNT-with-GROUP-BY mode-per-group-broken` (CLOSED), `iter1237 Q3 snapshot-not-in-materializations-list-bail` (CLOSED).
- **NEW SOFT WATCH**: `iter1238 Q3 broadcast-vs-partitioned-lead-rec-hedge-on-small-dim` — re-probe under "small dim joining large fact + OOM / how to broadcast" framings 4-8 iters.
- **Carry**: iter1237 Q1 add-NOT-NULL-name-dbt-not_null-test (soft, no fix); iter1236 rn=1-within-batch-pairing; iter1234 ROLLUP-date_trunc-expr; iter1233 IGNORE-NULLS-framing; iter1231 NEXT_DAY-note; iter1230 EXISTS-overwarning/::cast; iter1215 strpos-3-arg CEILING; iter1213 session_properties/(+); iter1229 @v1-Spark; iter1208 width_bucket.
- **NEXT ITER (1239)**: routine breadth-probe; both iter1237 watches closed so no required re-probe queue.
